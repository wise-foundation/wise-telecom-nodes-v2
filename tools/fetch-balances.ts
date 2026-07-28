import {
    parseAbi,
    getAddress,
} from 'viem';
import { promises as fs } from 'node:fs';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
    CHAINS,
    PAIRS,
    balanceFileName,
    type ChainKey,
    type TokenKey,
} from './lib/chain-config.js';
import {
    fetchAllTransferLogs,
    extractToAddresses,
} from './lib/etherscan.js';
import { buildRpcPool, type RpcPool } from './lib/rpc-pool.js';
import { forkPinFor } from './lib/fork-pin.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname  = path.dirname(__filename);

const VAULT_ABI = parseAbi([
    'function balanceOf(address) view returns (uint256)',
    'function proxyBalance(address) view returns (uint256)',
    'function cashedInterest(address) view returns (uint256)',
    'function getPendingInterest(address) view returns (uint256)',
    'function getTotalInterestUser(address) view returns (uint256)',
]);

const BLOCK_PIN_LAG       = 12n;
const ROTATION_BUDGET     = 5;
const SAME_RPC_RETRIES    = 2;
const RETRY_BACKOFF_MS    = 400;
const HOLDERS_PER_CHUNK   = 100;

const HOLDER_VIEWS = [
    'balanceOf',
    'proxyBalance',
    'cashedInterest',
    'getPendingInterest',
    'getTotalInterestUser',
] as const;

interface HolderRow {
    addr: `0x${string}`;
    bal: bigint;
    proxy: bigint;
    cashed: bigint;
    pending: bigint;
    total: bigint;
}

function requireEnv(
    name: string
): string {
    const v = process.env[name];
    if (!v) {
        throw new Error(`Missing required environment variable: ${name}`);
    }
    return v;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function readWithRotate<T>(
    pool: RpcPool,
    label: string,
    fn: () => Promise<T>
): Promise<T> {
    let lastErr: unknown;
    for (let rotation = 0; rotation <= ROTATION_BUDGET; rotation++) {
        const urlBefore = pool.rpcUrl();
        for (let attempt = 0; attempt < SAME_RPC_RETRIES; attempt++) {
            try {
                return await fn();
            } catch (e) {
                lastErr = e;
                const msg = (e as Error).message?.split('\n')[0] ?? '';
                if (attempt < SAME_RPC_RETRIES - 1) {
                    console.log(`  [${urlBefore}] retry ${attempt + 1} for ${label}: ${msg}`);
                    await sleep(RETRY_BACKOFF_MS * (attempt + 1));
                }
            }
        }
        if (rotation < ROTATION_BUDGET) {
            try {
                await pool.rotate(urlBefore);
            } catch (e) {
                console.error(`  pool exhausted: ${(e as Error).message}`);
                throw e;
            }
        }
    }
    throw lastErr;
}

async function readHolderStatesChunk(
    pool: RpcPool,
    vault: `0x${string}`,
    holders: readonly string[],
    blockNumber: bigint
): Promise<HolderRow[]> {
    const results = await readWithRotate(
        pool,
        `holderStates(${holders[0]}..${holders[holders.length - 1]})`,
        () => pool.client.multicall({
            contracts: holders.flatMap((holder) =>
                HOLDER_VIEWS.map((name) => ({
                    address: vault,
                    abi: VAULT_ABI,
                    functionName: name,
                    args: [holder as `0x${string}`],
                } as const))
            ),
            allowFailure: false,
            blockNumber,
        })
    ) as readonly bigint[];

    return holders.map((holder, i) => {
        const base = i * HOLDER_VIEWS.length;
        return {
            addr:    getAddress(holder),
            bal:     results[base],
            proxy:   results[base + 1],
            cashed:  results[base + 2],
            pending: results[base + 3],
            total:   results[base + 4],
        };
    });
}

async function fetchOne(
    chainKey: ChainKey,
    tokenKey: TokenKey,
    apiKey: string,
    outDir: string
): Promise<void> {
    const cfg     = CHAINS[chainKey];
    const target  = cfg.vaults[tokenKey];
    const envRpc  = process.env[cfg.rpcEnv];

    const candidatesPool = envRpc
        ? [envRpc]
        : cfg.defaultRpcs;

    if (envRpc) {
        console.log(`[${chainKey}/${tokenKey}] using env-supplied ${cfg.rpcEnv}`);
    } else {
        console.log(`[${chainKey}/${tokenKey}] using default RPC pool (${candidatesPool.length} candidates)`);
    }

    const pool = await buildRpcPool(
        candidatesPool,
        cfg.viemChain,
        target.vault,
        `${chainKey}/${tokenKey}`
    );

    const head        = await readWithRotate(pool, 'getBlockNumber', () => pool.client.getBlockNumber());
    const configPin   = forkPinFor(chainKey);
    const pinnedBlock = configPin ?? head - BLOCK_PIN_LAG;
    console.log(`[${chainKey}/${tokenKey}] head=${head}, pinned=${pinnedBlock}${configPin === null ? '' : ' (config/fork_pin.json)'}`);

    console.log(`[${chainKey}/${tokenKey}] enumerating Transfer events on ${target.vault}`);
    const logs = await fetchAllTransferLogs(
        cfg.chainId,
        target.vault,
        apiKey
    );

    const candidates = extractToAddresses(logs);
    console.log(`[${chainKey}/${tokenKey}] ${logs.length} transfers, ${candidates.length} unique recipients`);

    const rows: HolderRow[] = [];
    for (let i = 0; i < candidates.length; i += HOLDERS_PER_CHUNK) {
        const chunk = candidates.slice(i, i + HOLDERS_PER_CHUNK);
        const chunkRows = await readHolderStatesChunk(
            pool,
            target.vault,
            chunk,
            pinnedBlock
        );
        rows.push(...chunkRows);
        console.log(`  ${rows.length}/${candidates.length} read`);
    }

    const active = rows.filter(
        (r) => r.bal > 0n || r.proxy > 0n || r.cashed > 0n || r.pending > 0n
    );

    active.sort(
        (a, b) => (b.bal + b.proxy > a.bal + a.proxy ? 1 : -1)
    );

    const out =
        'Block:\n' + pinnedBlock.toString() + '\n' +
        'Addresses:\n[' +
        active.map((r) => r.addr).join(',') +
        ']\nBalances:\n[' +
        active.map((r) => r.bal.toString()).join(',') +
        ']\nProxyBalances:\n[' +
        active.map((r) => r.proxy.toString()).join(',') +
        ']\nCashedInterest:\n[' +
        active.map((r) => r.cashed.toString()).join(',') +
        ']\nPendingInterest:\n[' +
        active.map((r) => r.pending.toString()).join(',') +
        ']\nTotalInterest:\n[' +
        active.map((r) => r.total.toString()).join(',') +
        ']\n';

    const filename = balanceFileName(chainKey, tokenKey);
    const outPath  = path.join(outDir, filename);
    await fs.writeFile(outPath + '.tmp', out, 'utf8');
    await fs.rename(outPath + '.tmp', outPath);

    console.log(`[${chainKey}/${tokenKey}] wrote ${outPath} with ${active.length} active holders`);
}

async function main(): Promise<void> {
    const apiKey = requireEnv('ETHERSCAN_KEY');
    const outDir = path.resolve(__dirname, '..', 'data');

    await fs.mkdir(outDir, { recursive: true });

    for (const { chain, token } of PAIRS) {
        await fetchOne(chain, token, apiKey, outDir);
    }
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
