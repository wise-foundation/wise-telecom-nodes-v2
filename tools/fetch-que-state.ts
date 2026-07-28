import { promises as fs } from 'node:fs';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
    CHAINS,
    PAIRS,
    type ChainKey,
    type TokenKey,
} from './lib/chain-config.js';
import { buildRpcPool } from './lib/rpc-pool.js';
import { makeReadWithRotate } from './lib/read-rotate.js';
import {
    walkQueState,
    renderQueStateText,
} from './lib/que-walk.js';
import { forkPinFor } from './lib/fork-pin.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname  = path.dirname(__filename);

const BLOCK_PIN_LAG = 12n;

async function fetchOne(
    chainKey: ChainKey,
    tokenKey: TokenKey,
    outDir: string
): Promise<void> {
    const cfg     = CHAINS[chainKey];
    const target  = cfg.vaults[tokenKey];
    const envRpc  = process.env[cfg.rpcEnv];

    const candidatesPool = envRpc ? [envRpc] : cfg.defaultRpcs;
    if (envRpc) {
        console.log(`[${chainKey}/${tokenKey}/que] using env-supplied ${cfg.rpcEnv}`);
    } else {
        console.log(`[${chainKey}/${tokenKey}/que] using default RPC pool (${candidatesPool.length} candidates)`);
    }

    const pool = await buildRpcPool(
        candidatesPool,
        cfg.viemChain,
        target.que,
        `${chainKey}/${tokenKey}/que`
    );

    const read = makeReadWithRotate(pool);

    const head        = await read('getBlockNumber', () => pool.client.getBlockNumber());
    const configPin   = forkPinFor(chainKey);
    const pinnedBlock = configPin ?? head - BLOCK_PIN_LAG;
    console.log(`[${chainKey}/${tokenKey}/que] head=${head}, pinned=${pinnedBlock}${configPin === null ? '' : ' (config/fork_pin.json)'}`);

    const walk = await walkQueState(
        pool,
        read,
        target.que,
        pinnedBlock
    );

    console.log(`[${chainKey}/${tokenKey}/que] totalActive=${walk.totalActiveOrders}, minDeposit=${walk.minDepositAmount}, negNotAllowed=${walk.negativeIncentivesNotAllowed}`);

    for (const p of walk.perIncentive) {
        console.log(`  inc=${p.incentive}: earliest=${p.earliestValid}, current=${p.currentOrderId}, active=${p.activeOrderCount}, slots-walked=${p.earliestValid + 1n}`);
    }

    const out = renderQueStateText(
        pinnedBlock,
        walk
    );

    const filename = `que_state_${chainKey}_${tokenKey}.txt`;
    const outPath  = path.join(outDir, filename);
    await fs.writeFile(outPath + '.tmp', out, 'utf8');
    await fs.rename(outPath + '.tmp', outPath);

    console.log(`[${chainKey}/${tokenKey}/que] wrote ${outPath} with ${walk.members.length} live member slots`);
}

async function main(): Promise<void> {
    const outDir = path.resolve(__dirname, '..', 'data');

    await fs.mkdir(outDir, { recursive: true });

    for (const { chain, token } of PAIRS) {
        await fetchOne(chain, token, outDir);
    }
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
