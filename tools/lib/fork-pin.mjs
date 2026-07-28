// Single source of truth for the fork blocks the live-v2 fork tests replay at.
//
// config/fork_pin.json freezes one block per chain, chosen as the last block
// before any v2 vault on that chain was paused for the v2->v3 migration. The
// migration has since completed, so head no longer satisfies the tests'
// preconditions (paused() is true, the old-vault buffer is 0) and the
// snapshots must not follow head any more.
//
// Consumed by fetch-que-state.ts and fetch-balances.ts (which block they read
// state at) and by refresh-live-state.mjs (which skips fetching entirely while
// a pin is present, so the committed snapshots stay byte-stable).

import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const PIN_FILE = join(
    dirname(fileURLToPath(import.meta.url)),
    '..',
    '..',
    'config',
    'fork_pin.json',
);

export function forkPin() {
    if (existsSync(PIN_FILE) === false) {
        return null;
    }

    const pin = JSON.parse(readFileSync(PIN_FILE, 'utf8'));

    if (Number.isInteger(pin.eth) === false || Number.isInteger(pin.arb) === false) {
        throw new Error(`fork-pin: config/fork_pin.json must carry integer "eth" and "arb" blocks`);
    }

    return pin;
}

export function forkPinFor(chainKey) {
    const pin = forkPin();

    return pin === null
        ? null
        : BigInt(pin[chainKey]);
}
