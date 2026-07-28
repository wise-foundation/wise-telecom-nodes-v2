import {
    parseAbi,
    getAddress,
} from 'viem';
import type { RpcPool } from './rpc-pool.js';

export const QUE_ABI = parseAbi([
    'function QueMemberByIdAndIncentive(uint256 id, int256 incentive) view returns (address member, uint256 amount, uint256 tailPointer, uint256 headPointer)',
    'function earliestValidQueMemberByIncentive(int256 incentive) view returns (uint256)',
    'function currentOrderIdByIncentive(int256 incentive) view returns (uint256)',
    'function activeOrderCountByIncentive(int256 incentive) view returns (uint256)',
    'function incentiveAllowed(int256 incentive) view returns (bool)',
    'function totalActiveOrders() view returns (uint256)',
    'function negativeIncentivesNotAllowed() view returns (bool)',
    'function minDepositAmount() view returns (uint256)',
]);

export const INCENTIVES: bigint[] = [
    100n, 200n, 300n, 500n, 1000n, 1500n, 2500n, 5000n,
    0n,
    -100n, -200n, -300n, -500n, -1000n, -1500n, -2500n, -5000n,
];

export const MULTICALL_CHUNK = 500;

export interface PerIncentive {
    incentive: bigint;
    earliestValid: bigint;
    currentOrderId: bigint;
    activeOrderCount: bigint;
    allowed: boolean;
}

export interface MemberRow {
    incentive: bigint;
    id: bigint;
    member: `0x${string}`;
    amount: bigint;
    tailPointer: bigint;
    headPointer: bigint;
}

export interface QueWalk {
    totalActiveOrders: bigint;
    negativeIncentivesNotAllowed: boolean;
    minDepositAmount: bigint;
    perIncentive: PerIncentive[];
    members: MemberRow[];
}

export type ReadExec = <T>(label: string, fn: () => Promise<T>) => Promise<T>;

/**
 * Walks the full QueContract state at a pinned block via Multicall3
 * batches: one call for the globals, one for all per-incentive pointers,
 * then the id domain 0..earliestValid per incentive in chunks. Shared by
 * fetch-que-state.ts (writes snapshots) and verify-que-live.ts (proves a
 * snapshot still matches live) so both sides walk identically.
 */
export async function walkQueState(
    pool: RpcPool,
    read: ReadExec,
    que: `0x${string}`,
    pinnedBlock: bigint
): Promise<QueWalk> {
    const summary = await read('summary', () =>
        pool.client.multicall({
            contracts: [
                { address: que, abi: QUE_ABI, functionName: 'totalActiveOrders' },
                { address: que, abi: QUE_ABI, functionName: 'negativeIncentivesNotAllowed' },
                { address: que, abi: QUE_ABI, functionName: 'minDepositAmount' },
            ] as const,
            allowFailure: false,
            blockNumber: pinnedBlock,
        })
    ) as unknown[];

    const pointers = await read('pointers', () =>
        pool.client.multicall({
            contracts: INCENTIVES.flatMap((incentive) => [
                { address: que, abi: QUE_ABI, functionName: 'earliestValidQueMemberByIncentive', args: [incentive] },
                { address: que, abi: QUE_ABI, functionName: 'currentOrderIdByIncentive', args: [incentive] },
                { address: que, abi: QUE_ABI, functionName: 'activeOrderCountByIncentive', args: [incentive] },
                { address: que, abi: QUE_ABI, functionName: 'incentiveAllowed', args: [incentive] },
            ] as const),
            allowFailure: false,
            blockNumber: pinnedBlock,
        })
    ) as unknown[];

    const perIncentive: PerIncentive[] = [];
    const members: MemberRow[] = [];

    for (let i = 0; i < INCENTIVES.length; i++) {
        const incentive = INCENTIVES[i];
        const base = i * 4;

        const perInc: PerIncentive = {
            incentive,
            earliestValid: pointers[base] as bigint,
            currentOrderId: pointers[base + 1] as bigint,
            activeOrderCount: pointers[base + 2] as bigint,
            allowed: pointers[base + 3] as boolean,
        };
        perIncentive.push(perInc);

        const upperId = perInc.earliestValid;

        for (let chunkStart = 0n; chunkStart <= upperId; chunkStart += BigInt(MULTICALL_CHUNK)) {
            const chunkEnd = chunkStart + BigInt(MULTICALL_CHUNK) - 1n < upperId
                ? chunkStart + BigInt(MULTICALL_CHUNK) - 1n
                : upperId;

            const ids: bigint[] = [];
            for (let id = chunkStart; id <= chunkEnd; id++) {
                ids.push(id);
            }

            const slots = await read(
                `slots(inc=${incentive},ids=${chunkStart}..${chunkEnd})`,
                () => pool.client.multicall({
                    contracts: ids.map((id) => ({
                        address: que,
                        abi: QUE_ABI,
                        functionName: 'QueMemberByIdAndIncentive',
                        args: [id, incentive],
                    } as const)),
                    allowFailure: false,
                    blockNumber: pinnedBlock,
                })
            ) as readonly (readonly [`0x${string}`, bigint, bigint, bigint])[];

            for (let j = 0; j < ids.length; j++) {
                const [member, amount, tailPointer, headPointer] = slots[j];

                const isEmpty =
                    member === '0x0000000000000000000000000000000000000000' &&
                    amount === 0n &&
                    tailPointer === 0n &&
                    headPointer === 0n;

                if (isEmpty) continue;

                members.push({
                    incentive,
                    id: ids[j],
                    member: getAddress(member),
                    amount,
                    tailPointer,
                    headPointer,
                });
            }
        }
    }

    return {
        totalActiveOrders: summary[0] as bigint,
        negativeIncentivesNotAllowed: summary[1] as boolean,
        minDepositAmount: summary[2] as bigint,
        perIncentive,
        members,
    };
}

/**
 * Renders the canonical que_state txt format. Byte-identical output for
 * identical walks — verify-que-live.ts diffs this against the on-disk
 * snapshot, so any format change here changes the file format everywhere.
 */
export function renderQueStateText(
    pinnedBlock: bigint,
    w: QueWalk
): string {
    return (
        'Block:\n' + pinnedBlock.toString() + '\n' +
        'TotalActiveOrders:\n' + w.totalActiveOrders.toString() + '\n' +
        'NegativeIncentivesNotAllowed:\n' + (w.negativeIncentivesNotAllowed ? 'true' : 'false') + '\n' +
        'MinDepositAmount:\n' + w.minDepositAmount.toString() + '\n' +
        'Incentives:\n[' +
        w.perIncentive.map((p) => p.incentive.toString()).join(',') +
        ']\nEarliestValid:\n[' +
        w.perIncentive.map((p) => p.earliestValid.toString()).join(',') +
        ']\nCurrentOrderId:\n[' +
        w.perIncentive.map((p) => p.currentOrderId.toString()).join(',') +
        ']\nActiveOrderCount:\n[' +
        w.perIncentive.map((p) => p.activeOrderCount.toString()).join(',') +
        ']\nIncentiveAllowed:\n[' +
        w.perIncentive.map((p) => (p.allowed ? '1' : '0')).join(',') +
        ']\nQueMembers:\n' +
        w.members.map((m) =>
            `${m.incentive.toString()}|${m.id.toString()}|${m.member}|${m.amount.toString()}|${m.tailPointer.toString()}|${m.headPointer.toString()}`
        ).join('\n') +
        (w.members.length > 0 ? '\n' : '')
    );
}
