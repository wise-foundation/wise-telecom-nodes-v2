import { readFileSync } from 'node:fs';
import {
    encodeAbiParameters,
    parseAbiParameters,
    getAddress,
} from 'viem';

type Section = 'block' | 'summary' | 'pointers' | 'members';

function lineAfter(
    text: string,
    label: string
): string {
    const re = new RegExp(`^${label}\\s*\\n([^\\n]*)`, 'm');
    const m = text.match(re);
    if (!m) {
        throw new Error(`Section "${label}" missing or malformed`);
    }
    return m[1].trim();
}

function bracketed(
    text: string,
    label: string
): string {
    const re = new RegExp(`${label}\\s*\\n\\s*\\[(.*?)\\]`, 's');
    const m = text.match(re);
    if (!m) {
        throw new Error(`Section "${label}" missing or malformed`);
    }
    return m[1].trim();
}

function emitBlock(
    text: string
): string {
    const block = BigInt(lineAfter(text, 'Block:'));

    return encodeAbiParameters(
        parseAbiParameters('uint256'),
        [block]
    );
}

function emitSummary(
    text: string
): string {
    const totalActive  = BigInt(lineAfter(text, 'TotalActiveOrders:'));
    const negNotAllowed = lineAfter(text, 'NegativeIncentivesNotAllowed:').toLowerCase() === 'true';
    const minDeposit   = BigInt(lineAfter(text, 'MinDepositAmount:'));

    return encodeAbiParameters(
        parseAbiParameters('uint256, bool, uint256'),
        [totalActive, negNotAllowed, minDeposit]
    );
}

function emitPointers(
    text: string
): string {
    const incentivesList = bracketed(text, 'Incentives:');
    const earliestList   = bracketed(text, 'EarliestValid:');
    const currentList    = bracketed(text, 'CurrentOrderId:');
    const activeList     = bracketed(text, 'ActiveOrderCount:');
    const allowedList    = bracketed(text, 'IncentiveAllowed:');

    const incentives = incentivesList === ''
        ? []
        : incentivesList.split(',').map((s) => BigInt(s.trim()));
    const earliest = earliestList === ''
        ? []
        : earliestList.split(',').map((s) => BigInt(s.trim()));
    const current = currentList === ''
        ? []
        : currentList.split(',').map((s) => BigInt(s.trim()));
    const active = activeList === ''
        ? []
        : activeList.split(',').map((s) => BigInt(s.trim()));
    const allowed = allowedList === ''
        ? []
        : allowedList.split(',').map((s) => s.trim() === '1');

    if (
        incentives.length !== earliest.length ||
        incentives.length !== current.length  ||
        incentives.length !== active.length   ||
        incentives.length !== allowed.length
    ) {
        throw new Error(
            `Length mismatch: incentives=${incentives.length}, earliest=${earliest.length}, current=${current.length}, active=${active.length}, allowed=${allowed.length}`
        );
    }

    return encodeAbiParameters(
        parseAbiParameters('int256[], uint256[], uint256[], uint256[], bool[]'),
        [incentives, earliest, current, active, allowed]
    );
}

function emitMembers(
    text: string
): string {
    const headerIdx = text.indexOf('QueMembers:');
    if (headerIdx === -1) {
        throw new Error('Section "QueMembers:" missing');
    }

    const body  = text.slice(headerIdx + 'QueMembers:'.length).trim();
    const lines = body.length === 0
        ? []
        : body.split('\n').map((l) => l.trim()).filter((l) => l.length > 0);

    const incentives:   bigint[]            = [];
    const ids:          bigint[]            = [];
    const memberAddrs:  `0x${string}`[]     = [];
    const amounts:      bigint[]            = [];
    const tails:        bigint[]            = [];
    const heads:        bigint[]            = [];

    for (const line of lines) {
        const parts = line.split('|');
        if (parts.length !== 6) {
            throw new Error(`Malformed QueMembers line: "${line}"`);
        }
        incentives.push(BigInt(parts[0]));
        ids.push(BigInt(parts[1]));
        memberAddrs.push(getAddress(parts[2]));
        amounts.push(BigInt(parts[3]));
        tails.push(BigInt(parts[4]));
        heads.push(BigInt(parts[5]));
    }

    return encodeAbiParameters(
        parseAbiParameters('int256[], uint256[], address[], uint256[], uint256[], uint256[]'),
        [incentives, ids, memberAddrs, amounts, tails, heads]
    );
}

function main(): void {
    const filePath = process.argv[2];
    const section  = process.argv[3] as Section | undefined;

    if (!filePath || !section) {
        throw new Error('Usage: parse-que-state.ts <path-to-txt> <block|summary|pointers|members>');
    }

    const text = readFileSync(filePath, 'utf8');

    let encoded: string;
    if (section === 'block')         encoded = emitBlock(text);
    else if (section === 'summary')  encoded = emitSummary(text);
    else if (section === 'pointers') encoded = emitPointers(text);
    else if (section === 'members')  encoded = emitMembers(text);
    else throw new Error(`Unknown section "${section}"`);

    process.stdout.write(encoded);
}

main();
