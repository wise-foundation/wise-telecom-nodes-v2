// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Referral-registry pointer tail shard (Phase 1 of the referral
 * commission plan, rulings R19/R20). `referralRegistry` is the
 * address of this chain's standalone {ReferralRegistry} — the single
 * source of referrer truth shared by every vault on the chain; the
 * legacy slot-64 mapping in {ReferralRegistryDeclaration} stays
 * declared but forever virgin. While the pointer is `ZERO_ADDRESS` —
 * the virgin default — the referral feature is off in both
 * directions: every `...WithReferral` deposit entrypoint reverts
 * {ReferralRegistryNotSet} (loud, no silent drop of a user's
 * referrer) and the cohort recorder's `_cohortReferrerOf`
 * short-circuits to "unreferred", so a live diamond with virgin tail
 * storage — and every intermediate state of any upgrade sequence —
 * behaves byte-for-byte as today on every non-referral path
 * (default-off convention).
 *
 * `proposedReferralRegistry` + `referralRegistryChangeQueuedAt` back
 * the propose/execute/cancel flow cloned from
 * {TransferHookDeclaration}: instant while the diamond is still in
 * setup (before `finalizeSetup`), 3-day timelocked afterwards, and
 * proposing `ZERO_ADDRESS` reverts back to the off default —
 * detaching a registry mid-flight is a deliberate, timelocked act
 * that pauses referral deposits and freezes recorder referrer
 * resolution until repointed. Execute additionally shape-probes a
 * non-zero candidate (staticcall `referrerOf`, 32-byte returndata
 * required) beyond the hook pattern's `code.length` check, so a
 * fat-fingered pointer to some other deployed contract cannot pass.
 * The only writers are the {AdminFacet} pointer trio through
 * {WiseTelecomNodesBaseHelper}; every mutation MUST emit the
 * matching {ReferralRegistrySet} / {ReferralRegistryProposed} /
 * {ReferralRegistryProposalCancelled} event. All fields are
 * `internal` rather than `public`: the live genesis dispatcher
 * cannot route auto-getters, so the external read surface is the
 * routed {AdminFacet} getter trio. Appended after
 * {ReferralPayoutDeclaration} (slot 73) so it takes fresh tail slots
 * 74-76 and moves no pre-existing slot.
 */
abstract contract ReferralRegistryPointerDeclaration {

    address internal referralRegistry;

    address internal proposedReferralRegistry;

    uint256 internal referralRegistryChangeQueuedAt;

    uint256 internal constant REFERRAL_REGISTRY_CHANGE_DELAY = 3 days;
}
