// ffi entry point for test/helpers/LiveStateRefresher.verifyQueFileMatchesLive:
// runs tools/verify-que-live.ts (tsx) with all child output routed to
// stderr, keeping stdout reserved for the abi-encoded status word.
// Emits abi.encode(uint256 1) on a byte-identical file-vs-live match;
// exits 1 (reverting the calling test) on drift or any failure.
// Loads repo-root .env for the optional MAINNET_RPC_URL / ARBITRUM_RPC_URL.
//
// Forge runs suites in parallel, so up to eight tests can request a
// verify at once - enough concurrent RPC walks to trip rate limits. A
// per-file result cache (data/.que-verified-<file>, stamped with the
// verified pinned block) plus one global data/.verify-lock directory
// collapse the burst: the first caller verifies, the rest wait briefly
// and hit the cache. A refresh rewrites the snapshot with a new block,
// which invalidates the stamp automatically. The lock is released via a
// process exit hook (runs even on process.exit); it can only strand on
// SIGKILL and waiters then fail loudly with the recovery command.

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
    existsSync,
    readFileSync,
    writeFileSync,
    mkdirSync,
    rmdirSync,
} from 'node:fs';
import { dirname, join, basename, isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';
import { abiEncodeStaticTuple } from './lib/abi-encode.mjs';

const TOOLS_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(TOOLS_DIR, '..');
const DATA_DIR = join(REPO_ROOT, 'data');
const LOCK_DIR = join(DATA_DIR, '.verify-lock');
const TSX_CLI = join(TOOLS_DIR, 'node_modules', 'tsx', 'dist', 'cli.mjs');

const LOCK_POLL_MS = 1000;
const LOCK_WAIT_MS = 10 * 60_000;

let ownsLock = false;

process.on('exit', () => {
    if (ownsLock) releaseLock();
});

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
                '[verify-que-live] timed out waiting for another verify to finish.\n' +
                `If none is running (a previous one was killed), remove the stale lock:\n  rm -rf ${LOCK_DIR}\n`,
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

function snapshotHash(filePath) {
    const content = readFileSync(filePath, 'utf8');
    if (!content.startsWith('Block:\n')) {
        process.stderr.write(`[verify-que-live] malformed snapshot: ${filePath}\n`);
        process.exit(1);
    }
    return createHash('sha256').update(content).digest('hex');
}

function cacheIsCurrent(cachePath, hash) {
    if (!existsSync(cachePath)) return false;
    return readFileSync(cachePath, 'utf8').trim() === hash;
}

function emitOk() {
    console.log(abiEncodeStaticTuple(['uint256'], [1]));
}

const fileArg = process.argv[2];
if (!fileArg) {
    process.stderr.write('[verify-que-live] missing que_state file argument\n');
    process.exit(1);
}

const resolvedFile = isAbsolute(fileArg) ? fileArg : join(REPO_ROOT, fileArg);
if (!existsSync(resolvedFile)) {
    process.stderr.write(`[verify-que-live] snapshot not found: ${resolvedFile}\n`);
    process.exit(1);
}

const cachePath = join(DATA_DIR, `.que-verified-${basename(resolvedFile)}`);

if (cacheIsCurrent(cachePath, snapshotHash(resolvedFile))) {
    emitOk();
    process.exit(0);
}

loadDotEnv();
acquireLock();

if (cacheIsCurrent(cachePath, snapshotHash(resolvedFile))) {
    emitOk();
    process.exit(0);
}

const res = spawnSync(
    process.execPath,
    [TSX_CLI, 'verify-que-live.ts', fileArg],
    { cwd: TOOLS_DIR, stdio: ['ignore', 2, 2], env: process.env },
);

if (res.status !== 0) {
    process.stderr.write(`[verify-que-live] verification failed for ${fileArg}\n`);
    process.exit(1);
}

writeFileSync(cachePath, snapshotHash(resolvedFile));
emitOk();
