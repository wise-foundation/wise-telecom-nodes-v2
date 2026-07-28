/**
 * rehearse-evacuation.ts — real-time testnet rehearsal driver for the
 * v2 -> v3 buffer evacuation.
 *
 * The migration's mint -> wait -> evacuate step cannot live in a forge
 * script for a LIVE run: forge broadcasts its transactions back-to-back
 * with no real-time gap and cannot `vm.warp` a live chain. So the mock
 * stand-up + takeover + mint + burn is done by
 * `script/migration/RehearseEvacuationTestnet.s.sol` (broadcast 1),
 * this driver then waits a genuine `t_min` in wall-clock time, re-reads
 * the threshold, sends `initiateEvacuation()` (broadcast 2), asserts the
 * mock vault drained to exactly zero and the buffer landed on the
 * migration deployer, and finally pauses the mock vault.
 *
 * It is deliberately fully automatic (mirroring the mainnet
 * `tools/migrate.ts`) with ONE safety interlock: it POLLS the live
 * `getTotalInterestUser(forwarder) > balanceOf(oldVault)` and only
 * fires the evacuation once the chain itself reports the threshold
 * crossed, so it never fires blind. Polling (rather than a fixed
 * wall-clock sleep) is deliberate: interest is a function of
 * `block.timestamp`, and on Arbitrum that is sequencer-set and does
 * not track wall-clock, so a fixed sleep would mis-time the crossing.
 * Every resolved setting is printed before the first transaction;
 * there are NO silent env fallbacks.
 *
 * Required env (no defaults — a missing value aborts):
 *   PRIVATE_KEY, RPC_URL,
 *   REHEARSAL_FORWARDER, REHEARSAL_MOCK_VAULT, REHEARSAL_USD,
 *   REHEARSAL_TMIN_SECONDS
 * Optional: REHEARSAL_WAIT_PADDING_SECONDS (default 60),
 *   REHEARSAL_POLL_SECONDS (default 15),
 *   REHEARSAL_MAX_EXTRA_WAIT_SECONDS (default 3600) — the poll gives
 *   up (aborts, never fires) after tMin + padding + this many seconds.
 */

import {
    createPublicClient,
    createWalletClient,
    http,
    parseAbi,
    getAddress,
    type Address,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

const FORWARDER_ABI = parseAbi([
    'function initiateEvacuation()',
    'function emergencyReturnOwnership()',
]);

const VAULT_ABI = parseAbi([
    'function getTotalInterestUser(address) view returns (uint256)',
    'function pauseDeposits()',
    'function claimOwnership()',
    'function master() view returns (address)',
]);

const ERC20_ABI = parseAbi([
    'function balanceOf(address) view returns (uint256)',
]);

function requireEnv(name: string): string {
    const v = process.env[name];
    if (v === undefined || v === '') {
        throw new Error(`rehearse-evacuation: missing required env ${name}`);
    }
    return v;
}

function requireAddress(name: string): Address {
    return getAddress(requireEnv(name));
}

function sleep(seconds: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, seconds * 1000));
}

async function main(): Promise<void> {
    const rpcUrl = requireEnv('RPC_URL');
    const pk = requireEnv('PRIVATE_KEY');
    const account = privateKeyToAccount(
        (pk.startsWith('0x') ? pk : `0x${pk}`) as `0x${string}`,
    );

    const forwarder = requireAddress('REHEARSAL_FORWARDER');
    const mockVault = requireAddress('REHEARSAL_MOCK_VAULT');
    const usd = requireAddress('REHEARSAL_USD');

    const tMin = Number(requireEnv('REHEARSAL_TMIN_SECONDS'));
    const padding = Number(process.env.REHEARSAL_WAIT_PADDING_SECONDS ?? '60');
    const pollSeconds = Number(process.env.REHEARSAL_POLL_SECONDS ?? '15');
    const maxWaitSeconds =
        tMin + padding + Number(process.env.REHEARSAL_MAX_EXTRA_WAIT_SECONDS ?? '3600');

    const publicClient = createPublicClient({ transport: http(rpcUrl) });
    const walletClient = createWalletClient({
        account,
        transport: http(rpcUrl),
    });

    console.log('[rehearse] resolved settings:');
    console.log('  rpc            :', rpcUrl);
    console.log('  deployer       :', account.address);
    console.log('  forwarder      :', forwarder);
    console.log('  mock vault     :', mockVault);
    console.log('  usd            :', usd);
    console.log('  t_min (s)      :', tMin);
    console.log('  poll every (s) :', pollSeconds);
    console.log('  max wait (s)   :', maxWaitSeconds);

    const buffer = await publicClient.readContract({
        address: usd,
        abi: ERC20_ABI,
        functionName: 'balanceOf',
        args: [mockVault],
    });

    const deployerBefore = await publicClient.readContract({
        address: usd,
        abi: ERC20_ABI,
        functionName: 'balanceOf',
        args: [account.address],
    });

    console.log('[rehearse] buffer on mock vault:', buffer.toString());

    // Poll the LIVE on-chain threshold instead of trusting a fixed
    // wall-clock sleep. `getTotalInterestUser` is a function of
    // `block.timestamp`, and on Arbitrum block.timestamp is
    // sequencer-set and does NOT track wall-clock (it can run ahead of
    // or behind real time within its L1 bounds). A fixed sleep would
    // therefore fire too early or abort spuriously; polling fires
    // exactly when the chain itself reports interest > buffer, and
    // never before. The evacuation tx is atomic, so the value read
    // here holds through the flashloan.
    const readInterest = (): Promise<bigint> =>
        publicClient.readContract({
            address: mockVault,
            abi: VAULT_ABI,
            functionName: 'getTotalInterestUser',
            args: [forwarder],
        });

    const startMs = Date.now();
    let interest = await readInterest();
    console.log(
        `[rehearse] interest ${interest} / buffer ${buffer} — polling every ${pollSeconds}s until crossed`,
    );

    while (interest <= buffer) {
        if ((Date.now() - startMs) / 1000 > maxWaitSeconds) {
            throw new Error(
                `[rehearse] ABORT: interest did not cross the buffer within ${maxWaitSeconds}s; ` +
                    'not firing evacuation. Check EXTRA / the buffer read.',
            );
        }
        await sleep(pollSeconds);
        interest = await readInterest();
        console.log(`[rehearse] interest ${interest} / buffer ${buffer}`);
    }

    console.log('[rehearse] threshold crossed — sending initiateEvacuation()');

    const evacHash = await walletClient.writeContract({
        address: forwarder,
        abi: FORWARDER_ABI,
        functionName: 'initiateEvacuation',
        chain: null,
    });

    await publicClient.waitForTransactionReceipt({ hash: evacHash });
    console.log('[rehearse] evacuation tx:', evacHash);

    const vaultAfter = await publicClient.readContract({
        address: usd,
        abi: ERC20_ABI,
        functionName: 'balanceOf',
        args: [mockVault],
    });

    const deployerAfter = await publicClient.readContract({
        address: usd,
        abi: ERC20_ABI,
        functionName: 'balanceOf',
        args: [account.address],
    });

    if (vaultAfter !== 0n) {
        throw new Error(
            `[rehearse] FAIL: mock vault not drained to zero (holds ${vaultAfter})`,
        );
    }

    const gained = deployerAfter - deployerBefore;
    if (gained !== buffer) {
        throw new Error(
            `[rehearse] FAIL: deployer gained ${gained}, expected buffer ${buffer}`,
        );
    }

    console.log('[rehearse] drain OK: vault == 0, deployer gained exactly the buffer');

    // The evacuation hands the mock vault's ownership back to the
    // original owner (the deployer) via a proposal; claim it before
    // pausing, since `pauseDeposits` is master-gated.
    const claimHash = await walletClient.writeContract({
        address: mockVault,
        abi: VAULT_ABI,
        functionName: 'claimOwnership',
        chain: null,
    });

    await publicClient.waitForTransactionReceipt({ hash: claimHash });
    console.log('[rehearse] reclaimed mock vault ownership:', claimHash);

    const pauseHash = await walletClient.writeContract({
        address: mockVault,
        abi: VAULT_ABI,
        functionName: 'pauseDeposits',
        chain: null,
    });

    await publicClient.waitForTransactionReceipt({ hash: pauseHash });
    console.log('[rehearse] mock vault paused:', pauseHash);
    console.log('[rehearse] DONE — evacuation rehearsal succeeded.');
}

main().catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
});
