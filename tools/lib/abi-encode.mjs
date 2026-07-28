// Dependency-free ABI encoder.
// Works on any Node 10.4+ (only requires BigInt).
//
// Supports the encodings we need for vm.ffi parsers:
//   - Static tuple of 32-byte words: (uint256, bool, uint256)
//   - All-dynamic-arrays tuple, with element types:
//       'uint256[]', 'int256[]', 'bool[]', 'address[]'

const TWO_POW_256 = 1n << 256n;

function toUnsignedHex32(value) {
    let bv = typeof value === 'bigint' ? value : BigInt(value);
    if (bv < 0n) bv = bv + TWO_POW_256;
    let h = bv.toString(16);
    if (h.length > 64) {
        throw new Error(`value too large to fit in uint256: ${value}`);
    }
    return '0'.repeat(64 - h.length) + h;
}

function checksumAddress(addr) {
    // Minimal checksum implementation per EIP-55 would need keccak256;
    // but Solidity's vm.parseAddress and abi.decode accept all-lowercase or
    // mixed-case as long as the bytes are right. We just normalise to a
    // lowercase 40-hex string with 0x prefix.
    if (typeof addr !== 'string' || !/^0x[0-9a-fA-F]{40}$/.test(addr)) {
        throw new Error(`bad address: ${addr}`);
    }
    return addr.toLowerCase();
}

function addressToHex32(addr) {
    const a = checksumAddress(addr).slice(2);
    return '0'.repeat(24) + a;
}

function boolToHex32(b) {
    return '0'.repeat(63) + (b ? '1' : '0');
}

function intToHex32(value) {
    return toUnsignedHex32(value);
}

function encodeArrayBody(itemType, items) {
    let out = toUnsignedHex32(items.length);
    for (const v of items) {
        switch (itemType) {
            case 'uint256':
            case 'int256':
                out += intToHex32(v);
                break;
            case 'address':
                out += addressToHex32(v);
                break;
            case 'bool':
                out += boolToHex32(v);
                break;
            default:
                throw new Error(`unsupported item type "${itemType}"`);
        }
    }
    return out;
}

/**
 * Encode a tuple where every element is a dynamic array.
 * @param {string[]} types e.g. ['address[]', 'uint256[]', 'bool[]']
 * @param {any[][]}  values parallel arrays of items
 */
export function abiEncodeDynamicArrays(types, values) {
    if (types.length !== values.length) {
        throw new Error('types/values length mismatch');
    }

    const headSizeBytes = BigInt(types.length) * 32n;
    let head = '';
    let body = '';
    let offset = headSizeBytes;

    for (let i = 0; i < types.length; i++) {
        const itemType = stripArraySuffix(types[i]);
        const enc = encodeArrayBody(itemType, values[i]);

        head += toUnsignedHex32(offset);
        body += enc;
        offset += BigInt(enc.length / 2);
    }

    return '0x' + head + body;
}

/**
 * Encode a tuple of static (32-byte word) elements.
 * @param {string[]} types e.g. ['uint256', 'bool', 'uint256']
 * @param {any[]}    values
 */
export function abiEncodeStaticTuple(types, values) {
    if (types.length !== values.length) {
        throw new Error('types/values length mismatch');
    }
    let out = '0x';
    for (let i = 0; i < types.length; i++) {
        switch (types[i]) {
            case 'uint256':
            case 'int256':
                out += intToHex32(values[i]);
                break;
            case 'bool':
                out += boolToHex32(values[i]);
                break;
            case 'address':
                out += addressToHex32(values[i]);
                break;
            default:
                throw new Error(`unsupported type "${types[i]}"`);
        }
    }
    return out;
}

function stripArraySuffix(t) {
    if (!t.endsWith('[]')) {
        throw new Error(`expected dynamic array type, got "${t}"`);
    }
    return t.slice(0, -2);
}

export { checksumAddress };
