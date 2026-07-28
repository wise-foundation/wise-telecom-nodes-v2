import { readFileSync } from 'node:fs';
import {
    encodeAbiParameters,
    parseAbiParameters,
    getAddress,
} from 'viem';

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

function main(): void {
    const filePath = process.argv[2];
    if (!filePath) {
        throw new Error('Usage: parse-balance-file.ts <path-to-txt>');
    }

    const text = readFileSync(filePath, 'utf8');

    const addressList = bracketed(text, 'Addresses:');
    const balanceList = bracketed(text, 'Balances:');
    const proxyList   = bracketed(text, 'ProxyBalances:');

    const addrs = addressList === ''
        ? []
        : addressList.split(',').map((s) => getAddress(s.trim()));

    const balances = balanceList === ''
        ? []
        : balanceList.split(',').map((s) => BigInt(s.trim()));

    const proxies = proxyList === ''
        ? []
        : proxyList.split(',').map((s) => BigInt(s.trim()));

    if (addrs.length !== balances.length) {
        throw new Error(
            `Length mismatch: ${addrs.length} addresses vs ${balances.length} balances`
        );
    }

    if (addrs.length !== proxies.length) {
        throw new Error(
            `Length mismatch: ${addrs.length} addresses vs ${proxies.length} proxyBalances`
        );
    }

    const encoded = encodeAbiParameters(
        parseAbiParameters('address[], uint256[], uint256[]'),
        [addrs as readonly `0x${string}`[], balances, proxies]
    );

    process.stdout.write(encoded);
}

main();
