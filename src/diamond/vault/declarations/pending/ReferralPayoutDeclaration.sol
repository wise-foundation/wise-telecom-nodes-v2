// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Referral-payout liability tail shard (the vault half of the
 * referral payout accounting). `pendingReferralPayout` is the ONE
 * global USD liability the hub's priced verdicts have awarded against
 * this vault but referrers have not yet claimed — no per-user
 * breakdown, no separate pot: the money sits in the same vault USD
 * pool the sweep draws from. It enters `_calculateNeededBuffer` as one
 * more additive liability term, the exact `totalCashedInterest`
 * pattern, so the sweeper-gated `sweepOverhang` can never take cash
 * that backs pending referral payouts. While the slot is zero the term
 * is `+ 0`, so a live diamond with virgin tail storage — and every
 * intermediate state of any upgrade sequence — behaves byte-for-byte
 * as before (default-off convention).
 *
 * No mutation site exists yet: the future hub payout intake
 * (the still-open seam — how the hub's priced verdicts reach the
 * vault) will be its only writer, raising on accrual and lowering on
 * claim. Every future mutation MUST emit
 * `PendingReferralPayoutChanged(uint256 pendingReferralPayout)`,
 * appended to the accounting cluster directly after
 * `TotalCashedInterestChanged`. Gas discipline binding that writer:
 * the accumulator is read ONLY on the sweep surface, never in
 * user-facing paths, and writes must batch — ONE storage write per
 * hub delivery message (sum the batch in memory) and ONE per claim
 * transaction; never per-referrer or per-week loop writes, and never
 * a write inside deposit, transfer, compound, queue, or bridge paths.
 *
 * Declared `internal` rather than `public`: the live genesis
 * dispatcher cannot route auto-getters, so the single external
 * surface is `ReferralPayoutFacet.getPendingReferralPayout()`.
 * Appended after {CohortBookDeclaration} (slots 70-75) so it takes
 * fresh tail slot 76 and moves no pre-existing slot.
 */
abstract contract ReferralPayoutDeclaration {

    uint256 internal pendingReferralPayout;
}
