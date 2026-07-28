import { readFileSync } from 'node:fs';
import {
    abiEncodeDynamicArrays,
    checksumAddress,
} from './lib/abi-encode.mjs';

function bracketed(text, label) {
    const re = new RegExp(`${label}\\s*\\n\\s*\\[(.*?)\\]`, 's');
    const m = text.match(re);
    if (!m) {
        throw new Error(`Section "${label}" missing or malformed`);
    }
    return m[1].trim();
}

function main() {
    const filePath = process.argv[2];
    if (!filePath) {
        throw new Error('Usage: parse-balance-file.mjs <path-to-txt>');
    }

    const text = readFileSync(filePath, 'utf8');

    const addressList = bracketed(text, 'Addresses:');
    const balanceList = bracketed(text, 'Balances:');
    const proxyList   = bracketed(text, 'ProxyBalances:');

    const addrs = addressList === ''
        ? []
        : addressList.split(',').map((s) => checksumAddress(s.trim()));

    const balances = balanceList === ''
        ? []
        : balanceList.split(',').map((s) => BigInt(s.trim()));

    const proxies = proxyList === ''
        ? []
        : proxyList.split(',').map((s) => BigInt(s.trim()));

    if (addrs.length !== balances.length) {
        throw new Error(`Length mismatch: ${addrs.length} addresses vs ${balances.length} balances`);
    }
    if (addrs.length !== proxies.length) {
        throw new Error(`Length mismatch: ${addrs.length} addresses vs ${proxies.length} proxyBalances`);
    }

    const encoded = abiEncodeDynamicArrays(
        ['address[]', 'uint256[]', 'uint256[]'],
        [addrs, balances, proxies]
    );

    process.stdout.write(encoded);
}

main();
