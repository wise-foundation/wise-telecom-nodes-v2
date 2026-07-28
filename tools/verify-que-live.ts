import { promises as fs } from 'node:fs';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
    CHAINS,
    type ChainKey,
    type TokenKey,
} from './lib/chain-config.js';
import { buildRpcPool } from './lib/rpc-pool.js';
import { makeReadWithRotate } from './lib/read-rotate.js';
import {
    walkQueState,
    renderQueStateText,
} from './lib/que-walk.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname  = path.dirname(__filename);

/**
 * Proves a data/que_state_<chain>_<token>.txt snapshot still matches the
 * LIVE QueContract at the snapshot's own pinned block: re-walks the full
 * domain via Multicall3 (a handful of batched eth_calls instead of one
 * storage read per slot) and byte-compares the regenerated canonical text
 * against the on-disk file. Exit 0 = identical, exit 1 = drift/mismatch.
 *
 * Usage: tsx verify-que-live.ts <path-to-que-state-file>
 * All diagnostics go to stderr; this script is run by the ffi shim
 * tools/verify-que-live.mjs, which owns the stdout status word.
 */
async function main(): Promise<void> {
    const fileArg = process.argv[2];
    if (!fileArg) {
        throw new Error('usage: verify-que-live.ts <que_state file>');
    }

    const resolved = path.isAbsolute(fileArg)
        ? fileArg
        : path.resolve(__dirname, '..', fileArg);

    const m = path.basename(resolved).match(/^que_state_([a-z]+)_([a-z0-9]+)\.txt$/);
    if (!m) {
        throw new Error(`cannot derive chain/token from filename: ${resolved}`);
    }
    const chainKey = m[1] as ChainKey;
    const tokenKey = m[2] as TokenKey;

    const cfg = CHAINS[chainKey];
    if (!cfg || !cfg.vaults[tokenKey]) {
        throw new Error(`unknown chain/token pair: ${chainKey}/${tokenKey}`);
    }
    const target = cfg.vaults[tokenKey];

    const diskText = await fs.readFile(resolved, 'utf8');
    const lines = diskText.split('\n');
    if (lines[0] !== 'Block:') {
        throw new Error(`malformed snapshot (no Block header): ${resolved}`);
    }
    const pinnedBlock = BigInt(lines[1]);

    const envRpc = process.env[cfg.rpcEnv];
    const candidatesPool = envRpc ? [envRpc] : cfg.defaultRpcs;

    const pool = await buildRpcPool(
        candidatesPool,
        cfg.viemChain,
        target.que,
        `${chainKey}/${tokenKey}/verify`
    );

    const read = makeReadWithRotate(pool);

    const walk = await walkQueState(
        pool,
        read,
        target.que,
        pinnedBlock
    );

    const regenerated = renderQueStateText(pinnedBlock, walk);

    if (regenerated === diskText) {
        console.error(`[${chainKey}/${tokenKey}/verify] file matches live at block ${pinnedBlock} (${walk.members.length} member rows)`);
        return;
    }

    const diskLines = diskText.split('\n');
    const regenLines = regenerated.split('\n');
    const max = Math.max(diskLines.length, regenLines.length);
    for (let i = 0; i < max; i++) {
        if (diskLines[i] !== regenLines[i]) {
            console.error(`[${chainKey}/${tokenKey}/verify] DRIFT at line ${i + 1}:`);
            console.error(`  file: ${diskLines[i] ?? '<missing>'}`);
            console.error(`  live: ${regenLines[i] ?? '<missing>'}`);
            break;
        }
    }
    throw new Error('snapshot does not match live chain state');
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
