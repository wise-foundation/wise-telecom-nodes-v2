// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Cohort-attribution tail shard of the referral commission
 * system. `attributedContribution` is the slice of a user's tracked
 * contribution that was actually credited to a referrer's book: it
 * rises inside a credit only when a referrer was credited (a deposit
 * made while unreferred, or while the registry lookup failed, tracks
 * but attributes nothing), it rises on a carry landing by the lanes
 * the destination replants, and it is the ONLY quantity a clamp may
 * charge a referrer's book with. Every clamp charges
 * `min(deficit, attributed)` and lowers the counter by the charge
 * (the shares that leave are treated as the credited ones first), so
 * `attributedContribution <= trackedContribution` holds at all times
 * and a referrer assigned after a user's uncredited deposits can never
 * be charged for them. Without this counter the clamp charged
 * whichever referrer the registry named at clamp time by the whole
 * tracked deficit, which let anyone drain a chosen referrer's book
 * with a plain deposit, a one-unit referral deposit and a transfer.
 * `trackedContribution` keeps its wider role untouched (self-stake
 * ladder input, clamped to the held balance for every depositor).
 * Default-off convention: zeroed storage attributes nothing, so a
 * clamp on a live diamond charges nothing until credits land after
 * arming. Appended after {CohortFlushDeclaration} (slots 83-89) so it
 * takes fresh tail slot 90 and moves no pre-existing slot.
 */
abstract contract CohortAttributionDeclaration {

    mapping(address => uint256) internal attributedContribution;
}
