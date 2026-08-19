// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Cohort-contribution tail shard of the referral commission
 * system. `trackedContribution` is the per-user cumulative
 * deposit-and-compound ledger the one-way clamp maintains: it is
 * tracked for EVERY depositor — not only referred ones — because a
 * referrer's own stake is a rate-ladder input at the hub, and it is
 * lazily clamped down to `min(tracked, balanceOf)` at every balance
 * touchpoint. It only ever increases inside a deposit or compound and
 * only ever decreases through the clamp; nothing re-credits. Kept
 * full-word exact and never saturated — it is the accounting
 * root the packed book mirrors.
 *
 * `cohortSyncEnabled` is the instant master switch (precedent:
 * `graceFreezeEnabled`). Every recorder touchpoint stub early-returns
 * while it is false, so a live diamond with this shard's storage still
 * zeroed — and any intermediate state of the upgrade sequence —
 * behaves byte-for-byte as before until master arms the feature.
 * Arming requires the cohort-aware transfer hook to be installed: the
 * recorder engine is compiled once into {CohortHookFacet} and reached
 * exclusively through the `transferHookFacet` pointer (slot 45), which
 * the `COHORT_*` selectors below address. The same-chain
 * move-carry pair (`COHORT_MOVE_OUT_SELECTOR` /
 * `COHORT_MOVE_IN_SELECTOR`) extends the same pointer-only register:
 * like the original three these are deliberately absent from the
 * dispatcher and reachable solely through the transient
 * `hookExecuting` bracket. Constants take no storage — this shard
 * still occupies exactly slots 65-66. Appended after
 * {ReferralRegistryDeclaration} (slot 64) so it takes fresh tail slots
 * 65-66 and moves no pre-existing slot.
 */
abstract contract CohortContributionDeclaration {

    bool internal cohortSyncEnabled;

    mapping(address => uint256) internal trackedContribution;

    bytes4 internal constant COHORT_SYNC_SELECTOR = bytes4(
        keccak256(
            "applyCohortSync(address)"
        )
    );

    bytes4 internal constant COHORT_CREDIT_SELECTOR = bytes4(
        keccak256(
            "applyCohortCredit(address,uint256)"
        )
    );

    bytes4 internal constant COHORT_ADVANCE_SELECTOR = bytes4(
        keccak256(
            "applyCohortAdvance(address,uint256)"
        )
    );

    bytes4 internal constant COHORT_MOVE_OUT_SELECTOR = bytes4(
        keccak256(
            "applyCohortMoveOut(address,address,uint256,uint256,uint256)"
        )
    );

    bytes4 internal constant COHORT_MOVE_IN_SELECTOR = bytes4(
        keccak256(
            "applyCohortMoveIn(address,address)"
        )
    );
}
