import { mainnet, arbitrum } from 'viem/chains';
import type { Chain } from 'viem';

export type ChainKey = 'eth' | 'arb';
export type TokenKey = 'usdc' | 'usdt';

export interface VaultPair {
    vault: `0x${string}`;
    que: `0x${string}`;
    token: `0x${string}`;
}

export interface ChainConfig {
    chainId: 1 | 42161;
    rpcEnv: 'MAINNET_RPC_URL' | 'ARBITRUM_RPC_URL';
    defaultRpcs: string[];
    viemChain: Chain;
    vaults: Record<TokenKey, VaultPair>;
}

export const CHAINS: Record<ChainKey, ChainConfig> = {
    eth: {
        chainId: 1,
        rpcEnv: 'MAINNET_RPC_URL',
        defaultRpcs: [
            'https://eth.llamarpc.com',
            'https://ethereum-rpc.publicnode.com',
            'https://rpc.ankr.com/eth',
            'https://cloudflare-eth.com',
            'https://eth.drpc.org',
        ],
        viemChain: mainnet,
        vaults: {
            usdc: {
                vault: '0x11cEeE394842d9492f2C97050f66dE0e3f89D3A6',
                que:   '0x4e601103590b8971c208bF06B64ba1ef1c85B7e6',
                token: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
            },
            usdt: {
                vault: '0x3Ed1f16BbE0eE2C58119c13517a88fe9ccedfd45',
                que:   '0x0f63bDcE0f4f3531117E2ed2FE1484c5E40a75b5',
                token: '0xdAC17F958D2ee523a2206206994597C13D831ec7',
            },
        },
    },
    arb: {
        chainId: 42161,
        rpcEnv: 'ARBITRUM_RPC_URL',
        defaultRpcs: [
            'https://arb1.arbitrum.io/rpc',
            'https://arbitrum.llamarpc.com',
            'https://arbitrum-one-rpc.publicnode.com',
            'https://arbitrum.drpc.org',
            'https://rpc.ankr.com/arbitrum',
        ],
        viemChain: arbitrum,
        vaults: {
            usdc: {
                vault: '0x025421D3e98D3bB7A33d6814Dd576eD8B9090077',
                que:   '0xCfF3EdA95c3866bE10c8D3A29EDA665fc82EF72a',
                token: '0xaf88d065e77c8cC2239327C5EDb3A432268e5831',
            },
            usdt: {
                vault: '0xD69670d0eCaf032Ea8b1A6925E59dBacAA20f43A',
                que:   '0xc7960021229aDbacddfb57990815ab599A275533',
                token: '0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9',
            },
        },
    },
};

export const ETHERSCAN_V2_BASE = 'https://api.etherscan.io/v2/api';

export const TRANSFER_TOPIC =
    '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';

export const PAIRS: Array<{ chain: ChainKey; token: TokenKey }> = [
    { chain: 'eth', token: 'usdc' },
    { chain: 'eth', token: 'usdt' },
    { chain: 'arb', token: 'usdc' },
    { chain: 'arb', token: 'usdt' },
];

export function balanceFileName(
    chain: ChainKey,
    token: TokenKey
): string {
    return `${token.toUpperCase()}address_balances_${chain}.txt`;
}
