// Refreshes the data/*.txt live-state snapshots (holder balances + que
// state for all four chain/token pairs) by running fetch-que-state.ts and
// fetch-balances.ts, so the MoneyForward fork tests always replay the
// newest chain state.
//
// Invoked by test/helpers/LiveStateRefresher.sol via vm.ffi. stdout carries
// ONLY the abi-encoded status word; all fetcher output is routed to stderr.
//
// When config/fork_pin.json is present the snapshots are pinned to a
// pre-migration block instead of following head, and this wrapper reports them
// fresh without fetching. See tools/lib/fork-pin.mjs.
//
// Status word (uint256):
//   0 = snapshots fresh (refreshed within REFRESH_MAX_AGE_MINUTES, default 30,
//       or frozen by config/fork_pin.json)
//   1 = snapshots refreshed from live chain
//   2 = refresh unavailable (no ETHERSCAN_KEY, or SKIP_LIVE_REFRESH=1);
//       tests fall back to the committed snapshots
//
// A fetch attempt that fails exits non-zero so the test reverts loudly
// instead of silently running on stale data. ETHERSCAN_KEY (and optional
// MAINNET_RPC_URL / ARBITRUM_RPC_URL) are loaded from the repo-root .env
// when not already exported. Freshness is tracked via the gitignored
// data/.last-refresh marker, NOT file mtimes — a fresh git checkout
// resets mtimes but must still trigger a refresh.
//
// Concurrency: forge runs test suites in parallel, so several suites can
// invoke this wrapper at once. A gitignored data/.refresh-lock directory
// (mkdir is atomic) serializes them: the first caller refreshes while the
// others wait, then see the fresh marker and return status 0. There is
// deliberately NO stale-lock stealing — any steal heuristic races a slow
// but living owner and can corrupt the snapshot set. A lock release is
// guaranteed via a process 'exit' hook (which runs even on process.exit),
// so a lock can only strand on SIGKILL; waiters then fail loudly after
// LOCK_WAIT_MS with the recovery command in the message.
//
// Known accepted skews, both caught downstream by the tests' own guards
// (verify-que-live byte-diff + live holder-state parity): the que and
// balance snapshots of one pair pin blocks a few seconds apart, and a
// status-2 fallback cannot prove the on-disk set is one generation.

import { spawnSync } from 'node:child_process';
import {
    existsSync,
    readFileSync,
    writeFileSync,
    mkdirSync,
    rmdirSync,
} from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { abiEncodeStaticTuple } from './lib/abi-encode.mjs';
import { forkPin } from './lib/fork-pin.mjs';

const TOOLS_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(TOOLS_DIR, '..');
const DATA_DIR = join(REPO_ROOT, 'data');
const MARKER = join(DATA_DIR, '.last-refresh');
const LOCK_DIR = join(DATA_DIR, '.refresh-lock');
const TSX_CLI = join(TOOLS_DIR, 'node_modules', 'tsx', 'dist', 'cli.mjs');

const LOCK_POLL_MS = 2000;
const LOCK_WAIT_MS = 15 * 60_000;

const SNAPSHOT_FILES = [
    'que_state_eth_usdc.txt',
    'que_state_eth_usdt.txt',
    'que_state_arb_usdc.txt',
    'que_state_arb_usdt.txt',
    'USDCaddress_balances_eth.txt',
    'USDTaddress_balances_eth.txt',
    'USDCaddress_balances_arb.txt',
    'USDTaddress_balances_arb.txt',
];

let ownsLock = false;

process.on('exit', () => {
    if (ownsLock) releaseLock();
});

function emitStatus(status) {
    console.log(abiEncodeStaticTuple(['uint256'], [status]));
}

function loadDotEnv() {
    const envPath = join(REPO_ROOT, '.env');
    if (!existsSync(envPath)) return;
    for (const line of readFileSync(envPath, 'utf8').split('\n')) {
        const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/);
        if (!m) continue;
        const value = m[2].replace(/^["']|["']$/g, '');
        if (process.env[m[1]] === undefined) {
            process.env[m[1]] = value;
        }
    }
}

function allSnapshotsExist() {
    return SNAPSHOT_FILES.every((f) => existsSync(join(DATA_DIR, f)));
}

function markerIsFresh() {
    if (!existsSync(MARKER)) return false;
    const maxAgeMin = Number(process.env.REFRESH_MAX_AGE_MINUTES || '30');
    const stamp = Number(readFileSync(MARKER, 'utf8').trim());
    if (!Number.isFinite(stamp)) return false;
    return Date.now() - stamp < maxAgeMin * 60_000;
}

function sleepBlocking(ms) {
    const buf = new Int32Array(new SharedArrayBuffer(4));
    Atomics.wait(buf, 0, 0, ms);
}

function acquireLock() {
    const deadline = Date.now() + LOCK_WAIT_MS;
    while (true) {
        try {
            mkdirSync(LOCK_DIR);
            ownsLock = true;
            return;
        } catch (e) {
            if (e.code !== 'EEXIST') throw e;
        }
        if (Date.now() > deadline) {
            process.stderr.write(
                '[refresh-live-state] timed out waiting for another refresh to finish.\n' +
                `If no refresh is running (a previous one was killed), remove the stale lock:\n  rm -rf ${LOCK_DIR}\n`,
            );
            process.exit(1);
        }
        sleepBlocking(LOCK_POLL_MS);
    }
}

function releaseLock() {
    try {
        rmdirSync(LOCK_DIR);
    } catch {
        // already gone - nothing to release
    }
    ownsLock = false;
}

function runFetcher(script) {
    process.stderr.write(`[refresh-live-state] running ${script}\n`);
    const res = spawnSync(
        process.execPath,
        [TSX_CLI, script],
        { cwd: TOOLS_DIR, stdio: ['ignore', 2, 2], env: process.env },
    );
    if (res.status !== 0) {
        process.stderr.write(
            `[refresh-live-state] ${script} failed with exit code ${res.status}\n`,
        );
        process.exit(1);
    }
}

function main() {
    loadDotEnv();

    // While config/fork_pin.json is present the snapshots are frozen at a
    // pre-migration block and must not follow head: the v2 vaults are paused
    // and evacuated now, so a refreshed snapshot would replay a world the
    // tests' preconditions no longer hold in. Regenerate deliberately with
    // `npx tsx fetch-que-state.ts && npx tsx fetch-balances.ts`, which read
    // the same pin.
    if (forkPin() !== null) {
        if (!allSnapshotsExist()) {
            process.stderr.write(
                '[refresh-live-state] snapshots missing while config/fork_pin.json pins them; ' +
                'regenerate with: npx tsx fetch-que-state.ts && npx tsx fetch-balances.ts\n',
            );
            process.exit(1);
        }
        emitStatus(0);
        return;
    }

    if (allSnapshotsExist() && markerIsFresh()) {
        emitStatus(0);
        return;
    }

    if (process.env.SKIP_LIVE_REFRESH === '1' || !process.env.ETHERSCAN_KEY) {
        if (!allSnapshotsExist()) {
            process.stderr.write(
                '[refresh-live-state] snapshots missing and refresh unavailable\n',
            );
            process.exit(1);
        }
        emitStatus(2);
        return;
    }

    acquireLock();
    try {
        if (allSnapshotsExist() && markerIsFresh()) {
            emitStatus(0);
            return;
        }

        runFetcher('fetch-que-state.ts');
        runFetcher('fetch-balances.ts');

        if (!allSnapshotsExist()) {
            process.stderr.write(
                '[refresh-live-state] fetchers succeeded but snapshots are incomplete\n',
            );
            process.exit(1);
        }

        writeFileSync(MARKER, String(Date.now()));
        emitStatus(1);
    } finally {
        releaseLock();
    }
}

main();
