// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Cohort-book tail shard: the per-referrer commission
 * book — "three buckets, two rings" — ported from the proven
 * `test/fenwick/ReferralCommissionDemo.sol` sandbox with production
 * lane packing. The vault is a measuring instrument only: no rates,
 * no claimables live here (those are the mainnet hub's
 * business).
 *
 * `cohortBook` packs bookY1|bookY2|bookM into one word as three 80-bit
 * lanes (geometry shared with the crumb word via {CohortWeeks}), so
 * the settle walk reads all three sums in a single SLOAD.
 * `cohortLastSettle` of zero means never-touched: the first credit
 * stamps the current timestamp and starts the book there — no walk
 * from week zero. `cohortRingYear1/2` are 52-slot uint64 rings
 * (slot = week mod 52, compiler-packed four lanes per word, 13 words
 * per referrer per ring); the slot rotated at boundary b is exactly
 * b mod 52. `cohortWeekLog` holds the FROZEN crumb words (three
 * 80-bit token-second lanes + written bit 252). `cohortGapLog` packs
 * dormant fast-forward spans as `fromWeek | toWeekExclusive << 32 |
 * maturePrincipal << 64`; one record requires a preceding full
 * 104-boundary walk, so its growth is bounded and not attacker
 * inflatable.
 *
 * Saturation policy (the hook path must never revert): ring
 * lanes saturate at uint64 max, crumb and book and gap-mature lanes at
 * the 80-bit mask, reduction subtractions floor at zero — each clip
 * emits {CohortLaneSaturated} with `laneKind` 0 = ringYear1 lane,
 * 1 = ringYear2 lane, 2 = book word, 3 = crumb lane, 4 = gap mature,
 * 5 = reduction floor. Bound analysis: per-slot weekly referred inflow
 * is capped by `totalDepositCap` (1e15 units order) against a uint64
 * lane of 1.8e19 units; a crumb lane holds cap x WEEK ~ 6e20 against a
 * 2^80 mask of 1.2e24 — every saturation is unreachable under real
 * caps and exists as monitored fail-soft armor only. The
 * tracked-equals-book and ring-equals-book-lane identities
 * hold exactly on the non-saturated domain.
 *
 * Appended after {CohortContributionDeclaration} (slots 65-66) so it
 * takes fresh tail slots 67-72 and moves no pre-existing slot; all
 * fields are `internal` (auto-getters would be unreachable through the
 * live genesis dispatcher anyway — the routed view surface lives on
 * {CohortRecorderFacet}).
 */
abstract contract CohortBookDeclaration {

    mapping(address => uint256) internal cohortBook;

    mapping(address => uint256) internal cohortLastSettle;

    mapping(address => uint64[52]) internal cohortRingYear1;

    mapping(address => uint64[52]) internal cohortRingYear2;

    mapping(address => mapping(uint256 => uint256)) internal cohortWeekLog;

    mapping(address => uint256[]) internal cohortGapLog;
}
