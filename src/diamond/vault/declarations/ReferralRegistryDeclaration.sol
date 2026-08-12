// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Referral-registry tail shard. `referrerOf` maps a user to the
 * address that referred them. Written only at deposit time by the
 * `...WithReferral` entrypoints on {ReferralFacet} and
 * {Permit2ReferralFacet} (zero and self-referral rejected; the
 * assignment is write-once — the first referrer sticks forever and
 * no later deposit of any size displaces it). Transfers
 * deliberately never touch the registry: they can neither assign a
 * referrer to a fresh address nor change an existing one.
 * Distinct from {ReferralDeclaration}, which only
 * transports opaque bridge payload bytes. Appended last of all
 * shards, after {InterestRemainderDeclaration} (slot 63) and the
 * transient {HookGuardDeclaration}, so it takes fresh tail slot 64
 * and moves no pre-existing slot.
 */
abstract contract ReferralRegistryDeclaration {

    mapping(address => address) public referrerOf;
}
