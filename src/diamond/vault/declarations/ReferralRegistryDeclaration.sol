// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Referral-registry tail shard — declared but FOREVER VIRGIN
 * (ruling R19). Referrer truth lives in the per-chain standalone
 * {ReferralRegistry}, reached through the slot-74 pointer in
 * {ReferralRegistryPointerDeclaration}; no shipped code path reads
 * or writes this mapping and the fork rehearsals assert it stays
 * zero even after assignments. It is kept only to preserve the live
 * storage layout (removing it would renumber slots 65-73). Declared
 * `internal` so freshly compiled diamonds carry no auto-getter: a
 * `public` mapping here would give test diamonds a live
 * `referrerOf(address)` answering from this dead storage while live
 * diamonds (frozen genesis bytecode) have no such surface — the flip
 * keeps both worlds on the identical registry-reading code path, the
 * routed {ReferralFacet} `getReferrerOf`. Distinct from {ReferralDeclaration},
 * which only transports opaque bridge payload bytes. Appended after
 * {InterestRemainderDeclaration} (slot 63) and the transient
 * {HookGuardDeclaration}, so it takes fresh tail slot 64 and moves
 * no pre-existing slot.
 */
abstract contract ReferralRegistryDeclaration {

    mapping(address => address) internal referrerOf;
}
