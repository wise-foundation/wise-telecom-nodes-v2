// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ReferralTopDecile} from "./ReferralTopDecile.sol";

/**
 * @dev ReferralCutoffOracleDemo — sandbox for the HUB-side weekly
 * top-decile cutoff machinery (Phase 4 of
 * docs/referral-commission-implementation-plan.md). NOT production
 * code and NOT wired into the diamond. Under claim-at-hub (ruling
 * R10) ranking lives only in the mainnet hub, so this piece is kept
 * separate from the per-vault recorder sandbox
 * ({ReferralCommissionDemo}), which deliberately knows nothing about
 * rates or rank.
 *
 * The cutoff for week w is the minimal qualifying bucket b*: the
 * smallest Fenwick bucket b with activeReferrerCount − prefixSum(b−1)
 * <= ceil(activeReferrerCount / 10). Storing b* (a uint16 bucket id)
 * rather than a raw score is load-bearing: same-bucket referrers must
 * share one verdict (round-down semantics), and the nobody-qualifies
 * case b* = 2049 has no finite score representation because bucket
 * 2048 is unbounded above. Qualification for any referrer in week w
 * is then simply bucket >= cutoffAt(w).
 *
 * b* is found with an 11-step Fenwick lower-bound descent: position
 * accumulates the largest index whose prefix sum stays below
 * need = active − target, so position + 1 is the smallest index with
 * prefixSum >= need and b* = position + 2. Compile-time bounded like
 * every walk in the ranking contract.
 *
 * Snapshot discipline (the part the hub's score-write choke point
 * enforces in production, exposed here as an explicit function the
 * tests must call in the right order): the cutoff for week w must be
 * computed from the tree state AT the boundary opening week w — i.e.
 * `snapshot()` must run before any tree mutation in a new week.
 * Because the tree only moves inside transactions, weeks with no
 * mutation carry the previous checkpoint forward EXACTLY (sticky),
 * and `cutoffAt` resolves any past week by binary search over the
 * append-only checkpoint log. Weeks before the first checkpoint
 * report NOBODY_QUALIFIES — pessimistic and final, consistent with
 * ruling R9 (late data counts for later weeks, verdicts immutable).
 *
 * Deliberate sandbox simplifications versus the Phase-4 hub, both
 * flagged during review: `qualifiedAt` compares the historical cutoff
 * against the referrer's CURRENT bucket — the production hub instead
 * derives the week-w bucket from its append-only per-referrer score
 * checkpoints, which is what makes past verdicts immutable; and an
 * empty-tree snapshot (activeReferrerCount == 0) records cutoff 1,
 * which is harmless in production only because a week with no active
 * referrers also has no crumb quantities to price.
 */
contract ReferralCutoffOracleDemo is ReferralTopDecile {

    uint256 internal constant NOBODY_QUALIFIES = BUCKET_COUNT + 1;

    uint256 internal constant PACKED_BUCKET_MASK = (1 << 16) - 1;

    uint256 internal constant WEEK = 1 weeks;

    uint256[] internal cutoffLog;

    event CutoffSnapshot(
        uint256 indexed week,
        uint256 qualifyingBucket
    );

    function snapshot()
        external
    {
        _snapshotIfNewWeek();
    }

    function cutoffAt(
        uint256 _week
    )
        external
        view
        returns (uint256)
    {
        return _cutoffAt(
            _week
        );
    }

    function qualifyingBucket()
        external
        view
        returns (uint256)
    {
        return _qualifyingBucket();
    }

    function qualifiedAt(
        uint256 _week,
        address _referrer
    )
        external
        view
        returns (bool)
    {
        uint256 bucket = referrerBucket[_referrer];

        if (bucket == 0) {
            return false;
        }

        uint256 cutoff = _cutoffAt(
            _week
        );

        if (cutoff > BUCKET_COUNT) {
            return false;
        }

        return bucket >= cutoff;
    }

    function _snapshotIfNewWeek()
        internal
    {
        uint256 week = block.timestamp / WEEK;

        uint256 length = cutoffLog.length;

        if (length > 0 && cutoffLog[length - 1] >> 16 == week) {
            return;
        }

        uint256 bucket = _qualifyingBucket();

        cutoffLog.push(
            (week << 16) | bucket
        );

        emit CutoffSnapshot(
            week,
            bucket
        );
    }

    function _qualifyingBucket()
        internal
        view
        returns (uint256)
    {
        uint256 active = activeReferrerCount;

        uint256 need = active - _targetTopCount(active);

        if (need == 0) {
            return 1;
        }

        uint256 position;

        uint256 remaining = need;

        for (uint256 power = BUCKET_COUNT / 2; power > 0; power >>= 1) {

            uint256 probe = position + power;

            if (probe <= BUCKET_COUNT && fenwickTree[probe] < remaining) {
                position = probe;
                remaining -= fenwickTree[probe];
            }
        }

        return position + 2;
    }

    function _cutoffAt(
        uint256 _week
    )
        internal
        view
        returns (uint256)
    {
        uint256 length = cutoffLog.length;

        if (length == 0) {
            return NOBODY_QUALIFIES;
        }

        if (cutoffLog[0] >> 16 > _week) {
            return NOBODY_QUALIFIES;
        }

        uint256 low;

        uint256 high = length - 1;

        while (low < high) {

            uint256 mid = (low + high + 1) / 2;

            if (cutoffLog[mid] >> 16 <= _week) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }

        return cutoffLog[low] & PACKED_BUCKET_MASK;
    }
}
