// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Referral-registry tail shard. `referrerOf` maps a user to the
 * address that referred them. Written only at deposit time by the
 * `...WithReferral` entrypoints on {ReferralFacet} and
 * {Permit2ReferralFacet} (zero and self-referral rejected; an
 * existing referrer is only displaced by a deposit strictly larger
 * than the user's pre-deposit balance, so the referrer backed by
 * more tokens stays). Transfers deliberately never touch the
 * registry: the deployed transfer-hook interface carries no amount,
 * so the bigger-amount-displaces rule cannot be evaluated on the
 * transfer path. Distinct from {ReferralDeclaration}, which only
 * transports opaque bridge payload bytes. Appended last of all
 * shards, after {InterestRemainderDeclaration} (slot 63) and the
 * transient {HookGuardDeclaration}, so it takes fresh tail slot 64
 * and moves no pre-existing slot.
 */
abstract contract ReferralRegistryDeclaration {

    mapping(address => address) public referrerOf;
}
