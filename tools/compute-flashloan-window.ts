/**
 * compute-flashloan-window.ts (W5) — read-only, sends NO transactions.
 *
 * Per LIVE v2 vault, reads the interest buffer sitting in the vault and
 * the Uniswap v4 PoolManager's USD liquidity, then computes the mint
 * amount (EXTRA) and the [t_min, t_max] time window inside which the
 * buffer evacuation is safe to fire. Prints every number so the output
 * can be pasted straight into docs/MIGRATION_MAINNET.md.
 *
 * Math (the 2000 bps interest rate is baked into SECONDS_PER_YEAR_SCALED
 * = SECONDS_IN_YEAR 31_540_000 * 10_000 / 2000):
 *
 *   interest(t) = EXTRA * t / 157_700_000
 *   EXTRA  = buffer * 157_700_000 / T_TARGET     (T_TARGET = 600 s)
 *   t_min  = buffer * 157_700_000 / EXTRA         (= 600 by construction:
 *            the moment interest(t) first exceeds the whole buffer)
 *   t_max  = (buffer + L) * 157_700_000 / EXTRA   (the moment the flash
 *            shortfall interest(t)-buffer would exceed the pool's L)
 *
 * A bigger EXTRA shrinks the [t_min, t_max] headroom; T_TARGET = 600
 * keeps t_min at ten minutes with months of headroom above it.
 *
 * Required env (NO fallbacks — a missing value aborts):
 *   MAINNET_RPC_URL, ARBITRUM_RPC_URL
 */

import {
    createPublicClient,
    http,
    parseAbi,
    getAddress,
    type Address,
    type PublicClient,
} from 'viem';

const SECONDS_PER_YEAR_SCALED = 157_700_000n;
const T_TARGET_SECONDS = 600n;
const INTEREST_RATE_BPS = 2000n;

const ERC20_ABI = parseAbi([
    'function balanceOf(address) view returns (uint256)',
    'function decimals() view returns (uint8)',
    'function symbol() view returns (string)',
]);

const POOL_MANAGER_ETH = getAddress('0x000000000004444c5dc75cB358380D2e3dE08A90');
const POOL_MANAGER_ARB = getAddress('0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32');

type ChainKey = 'mainnet' | 'arbitrum';

interface Leg {
    name: string;
    chain: ChainKey;
    usd: Address;
    oldVault: Address;
    poolManager: Address;
}

const LEGS: Leg[] = [
    {
        name: 'eth-usdc',
        chain: 'mainnet',
        usd: getAddress('0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48'),
        oldVault: getAddress('0x11cEeE394842d9492f2C97050f66dE0e3f89D3A6'),
        poolManager: POOL_MANAGER_ETH,
    },
    {
        name: 'eth-usdt',
        chain: 'mainnet',
        usd: getAddress('0xdAC17F958D2ee523a2206206994597C13D831ec7'),
        oldVault: getAddress('0x3Ed1f16BbE0eE2C58119c13517a88fe9ccedfd45'),
        poolManager: POOL_MANAGER_ETH,
    },
    {
        name: 'arb-usdc',
        chain: 'arbitrum',
        usd: getAddress('0xaf88d065e77c8cC2239327C5EDb3A432268e5831'),
        oldVault: getAddress('0x025421D3e98D3bB7A33d6814Dd576eD8B9090077'),
        poolManager: POOL_MANAGER_ARB,
    },
    {
        name: 'arb-usdt',
        chain: 'arbitrum',
        usd: getAddress('0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9'),
        oldVault: getAddress('0xD69670d0eCaf032Ea8b1A6925E59dBacAA20f43A'),
        poolManager: POOL_MANAGER_ARB,
    },
];

function requireEnv(name: string): string {
    const value = process.env[name];

    if (value === undefined || value.trim() === '') {
        throw new Error(`missing required env ${name} (no fallback)`);
    }

    return value;
}

function formatUnits(raw: bigint, decimals: number): string {
    const unit = 10n ** BigInt(decimals);
    const whole = raw / unit;
    const frac = (raw % unit).toString().padStart(decimals, '0');

    return `${whole.toString()}.${frac}`;
}

async function main(): Promise<void> {
    const rpcUrls: Record<ChainKey, string> = {
        mainnet: requireEnv('MAINNET_RPC_URL'),
        arbitrum: requireEnv('ARBITRUM_RPC_URL'),
    };

    console.log('compute-flashloan-window (read-only — sends no transactions)');
    console.log(`  SECONDS_PER_YEAR_SCALED = ${SECONDS_PER_YEAR_SCALED}`);
    console.log(`  T_TARGET = ${T_TARGET_SECONDS} s   interestRate = ${INTEREST_RATE_BPS} bps`);
    console.log(`  mainnet  RPC = ${rpcUrls.mainnet}`);
    console.log(`  arbitrum RPC = ${rpcUrls.arbitrum}`);

    const clients: Record<ChainKey, PublicClient> = {
        mainnet: createPublicClient({ transport: http(rpcUrls.mainnet) }),
        arbitrum: createPublicClient({ transport: http(rpcUrls.arbitrum) }),
    };

    for (const leg of LEGS) {
        const client = clients[leg.chain];

        const [buffer, poolLiquidity, decimals, symbol] = await Promise.all([
            client.readContract({ address: leg.usd, abi: ERC20_ABI, functionName: 'balanceOf', args: [leg.oldVault] }) as Promise<bigint>,
            client.readContract({ address: leg.usd, abi: ERC20_ABI, functionName: 'balanceOf', args: [leg.poolManager] }) as Promise<bigint>,
            client.readContract({ address: leg.usd, abi: ERC20_ABI, functionName: 'decimals' }) as Promise<number>,
            client.readContract({ address: leg.usd, abi: ERC20_ABI, functionName: 'symbol' }) as Promise<string>,
        ]);

        if (buffer === 0n) {
            throw new Error(`${leg.name}: buffer is zero — nothing to evacuate`);
        }

        if (poolLiquidity <= buffer) {
            throw new Error(`${leg.name}: pool liquidity ${poolLiquidity} <= buffer ${buffer} — unsafe, aborting`);
        }

        const extra = (buffer * SECONDS_PER_YEAR_SCALED) / T_TARGET_SECONDS;
        const tMin = (buffer * SECONDS_PER_YEAR_SCALED) / extra;
        const tMax = ((buffer + poolLiquidity) * SECONDS_PER_YEAR_SCALED) / extra;

        const tFire = tMin + 300n;
        const interestAtFire = (extra * tFire) / SECONDS_PER_YEAR_SCALED;
        const flashAtFire = interestAtFire > buffer ? interestAtFire - buffer : 0n;

        console.log(`\n=== ${leg.name} (${symbol}, ${decimals} dp) ===`);
        console.log(`  oldVault         ${leg.oldVault}`);
        console.log(`  poolManager      ${leg.poolManager}`);
        console.log(`  buffer           ${buffer}  (${formatUnits(buffer, decimals)})`);
        console.log(`  pool L           ${poolLiquidity}  (${formatUnits(poolLiquidity, decimals)})`);
        console.log(`  EXTRA to mint    ${extra}  (${formatUnits(extra, decimals)})`);
        console.log(`  t_min            ${tMin} s   (fire no earlier)`);
        console.log(`  t_max            ${tMax} s   (${Number(tMax) / 86_400} days; unsafe beyond — flash > L)`);
        console.log(`  window           ${tMax - tMin} s`);
        console.log(`  flash @ t_min+300s ${flashAtFire}  (${formatUnits(flashAtFire, decimals)})  ${flashAtFire < poolLiquidity ? 'OK << L' : 'DANGER >= L'}`);
    }
}

main().catch((error) => {
    console.error(error);
    process.exit(1);
});
