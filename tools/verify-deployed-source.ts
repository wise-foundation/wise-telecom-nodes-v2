import { createPublicClient, http, type PublicClient } from 'viem';
import { promises as fs } from 'node:fs';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';
import { CHAINS, type ChainKey } from './lib/chain-config.js';
import { fetchSourceCode } from './lib/etherscan.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname  = path.dirname(__filename);

interface Target {
    chain: ChainKey;
    addr: `0x${string}`;
    expectedName: 'ForwardVaultERC20' | 'QueContract';
    artifactPath: string;
    label: string;
}

const REPO_ROOT = path.resolve(__dirname, '..');

const FV_ARTIFACT  = 'out/ForwardVaultERC20Legacy.sol/ForwardVaultERC20.json';
const QUE_ARTIFACT = 'out/QueContractLegacy.sol/QueContract.json';

const TARGETS: Target[] = [
    { chain: 'eth', addr: '0x11cEeE394842d9492f2C97050f66dE0e3f89D3A6', expectedName: 'ForwardVaultERC20', artifactPath: FV_ARTIFACT,  label: 'ETH USDC ForwardVault' },
    { chain: 'eth', addr: '0x3Ed1f16BbE0eE2C58119c13517a88fe9ccedfd45', expectedName: 'ForwardVaultERC20', artifactPath: FV_ARTIFACT,  label: 'ETH USDT ForwardVault' },
    { chain: 'eth', addr: '0x4e601103590b8971c208bF06B64ba1ef1c85B7e6', expectedName: 'QueContract',       artifactPath: QUE_ARTIFACT, label: 'ETH USDC QueContract' },
    { chain: 'eth', addr: '0x0f63bDcE0f4f3531117E2ed2FE1484c5E40a75b5', expectedName: 'QueContract',       artifactPath: QUE_ARTIFACT, label: 'ETH USDT QueContract' },
    { chain: 'arb', addr: '0x025421D3e98D3bB7A33d6814Dd576eD8B9090077', expectedName: 'ForwardVaultERC20', artifactPath: FV_ARTIFACT,  label: 'ARB USDC ForwardVault' },
    { chain: 'arb', addr: '0xD69670d0eCaf032Ea8b1A6925E59dBacAA20f43A', expectedName: 'ForwardVaultERC20', artifactPath: FV_ARTIFACT,  label: 'ARB USDT ForwardVault' },
    { chain: 'arb', addr: '0xCfF3EdA95c3866bE10c8D3A29EDA665fc82EF72a', expectedName: 'QueContract',       artifactPath: QUE_ARTIFACT, label: 'ARB USDC QueContract' },
    { chain: 'arb', addr: '0xc7960021229aDbacddfb57990815ab599A275533', expectedName: 'QueContract',       artifactPath: QUE_ARTIFACT, label: 'ARB USDT QueContract' },
];

interface MetaCheckResult {
    ok: boolean;
    issues: string[];
}

async function checkMetadata(
    target: Target,
    apiKey: string
): Promise<MetaCheckResult> {
    const cfg = CHAINS[target.chain];
    const src = await fetchSourceCode(cfg.chainId, target.addr, apiKey);

    const issues: string[] = [];

    if (src.ContractName !== target.expectedName) {
        issues.push(`expected ContractName="${target.expectedName}", got "${src.ContractName}"`);
    }

    if (!src.CompilerVersion.startsWith('v0.8.29+')) {
        issues.push(`compiler version "${src.CompilerVersion}" does not start with v0.8.29+`);
    }

    if (src.OptimizationUsed !== '1') {
        issues.push(`optimizer not enabled (OptimizationUsed=${src.OptimizationUsed})`);
    }

    if (src.Runs !== '600000') {
        issues.push(`optimizer runs="${src.Runs}", expected 600000`);
    }

    if (src.EVMVersion && src.EVMVersion !== 'cancun' && src.EVMVersion !== 'default') {
        issues.push(`EVM version "${src.EVMVersion}" is not cancun`);
    }

    return {
        ok: issues.length === 0,
        issues,
    };
}

function stripCborMetadata(
    hexNo0x: string
): string {
    if (hexNo0x.length < 4) return hexNo0x;
    const metaLen = parseInt(hexNo0x.slice(-4), 16);
    const cutoff  = hexNo0x.length - 4 - metaLen * 2;
    return cutoff > 0 ? hexNo0x.slice(0, cutoff) : hexNo0x;
}

interface ImmutableSlot {
    start: number;
    length: number;
}

function flattenImmutableRefs(
    refs: Record<string, ImmutableSlot[]> | undefined
): ImmutableSlot[] {
    if (!refs) return [];
    const out: ImmutableSlot[] = [];
    for (const slots of Object.values(refs)) {
        out.push(...slots);
    }
    return out;
}

function maskBytes(
    hexNo0x: string,
    slots: ImmutableSlot[]
): string {
    const buf = Buffer.from(hexNo0x, 'hex');
    for (const { start, length } of slots) {
        for (let i = start; i < start + length; i++) {
            buf[i] = 0;
        }
    }
    return buf.toString('hex');
}

async function checkBytecode(
    target: Target,
    rpcClients: Record<ChainKey, PublicClient>
): Promise<MetaCheckResult> {
    const issues: string[] = [];

    const artifactFull = path.join(REPO_ROOT, target.artifactPath);
    let artifact: any;
    try {
        artifact = JSON.parse(await fs.readFile(artifactFull, 'utf8'));
    } catch (e) {
        return {
            ok: false,
            issues: [`failed to read artifact at ${target.artifactPath}: ${(e as Error).message}`],
        };
    }

    const localHex = (artifact.deployedBytecode?.object ?? '').replace(/^0x/, '');
    const slots    = flattenImmutableRefs(
        artifact.deployedBytecode?.immutableReferences as Record<string, ImmutableSlot[]> | undefined
    );

    const onChainHex = (await rpcClients[target.chain].getCode({
        address: target.addr,
    }) ?? '').replace(/^0x/, '');

    if (!onChainHex) {
        return {
            ok: false,
            issues: [`no on-chain bytecode found at ${target.addr}`],
        };
    }

    const localStripped   = stripCborMetadata(maskBytes(localHex,   slots));
    const onChainStripped = stripCborMetadata(maskBytes(onChainHex, slots));

    if (localStripped !== onChainStripped) {
        issues.push(
            `bytecode mismatch: local=${localStripped.length}b, deployed=${onChainStripped.length}b`
        );
    }

    return {
        ok: issues.length === 0,
        issues,
    };
}

async function main(): Promise<void> {
    const apiKey = process.env.ETHERSCAN_KEY;
    if (!apiKey) {
        throw new Error('Missing required environment variable: ETHERSCAN_KEY');
    }

    const wantBytecode = process.env.BYTECODE_CHECK === '1';

    let rpcClients: Record<ChainKey, PublicClient> | null = null;
    if (wantBytecode) {
        const rpcEth = process.env.MAINNET_RPC_URL  || CHAINS.eth.defaultRpcs[0];
        const rpcArb = process.env.ARBITRUM_RPC_URL || CHAINS.arb.defaultRpcs[0];
        rpcClients = {
            eth: createPublicClient({ chain: CHAINS.eth.viemChain, transport: http(rpcEth) }),
            arb: createPublicClient({ chain: CHAINS.arb.viemChain, transport: http(rpcArb) }),
        };
    }

    const allIssues: string[] = [];
    const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

    for (let idx = 0; idx < TARGETS.length; idx++) {
        const t = TARGETS[idx];
        if (idx > 0) await sleep(400);
        console.log(`\n=== ${t.label} (${t.addr}) ===`);
        const meta = await checkMetadata(t, apiKey);
        if (meta.ok) {
            console.log('  metadata: OK');
        } else {
            console.error('  metadata: FAIL');
            for (const i of meta.issues) {
                console.error(`    - ${i}`);
                allIssues.push(`${t.label}: ${i}`);
            }
        }

        if (rpcClients) {
            const code = await checkBytecode(t, rpcClients);
            if (code.ok) {
                console.log('  bytecode: OK');
            } else {
                console.error('  bytecode: FAIL');
                for (const i of code.issues) {
                    console.error(`    - ${i}`);
                    allIssues.push(`${t.label}: ${i}`);
                }
            }
        }
    }

    if (allIssues.length > 0) {
        console.error(`\nMISMATCHES DETECTED (${allIssues.length}):`);
        for (const i of allIssues) console.error(`  - ${i}`);
        process.exit(1);
    }

    console.log('\nAll 8 contracts verified.');
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
