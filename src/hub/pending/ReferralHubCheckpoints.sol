// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralHubRanking} from "./ReferralHubRanking.sol";
import {CohortWeeks} from "../../diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev Historical-truth layer: the weekly cutoff log (port of
 * `test/fenwick/ReferralCutoffOracleDemo.sol` — review as a diff) and
 * the per-referrer checkpoint machinery that the sandbox deliberately
 * lacked. The sandbox's flagged divergence was that `qualifiedAt`
 * compared a historical cutoff against the referrer's CURRENT bucket;
 * here the week-w bucket is derived from the referrer's own
 * append-only checkpoint log, which is what makes every past week's
 * verdict immutable under late-arriving data.
 *
 * Checkpoint discipline: every score mutation calls
 * `_checkpointReferrer` AFTER applying the diff — the first mutation
 * of a week pushes a new entry, later same-week mutations update the
 * tail entry in place, so an entry always holds the referrer's
 * CLOSING values of its week and entries for past weeks can never
 * change again. The opening value of any week w is therefore the
 * value of the last entry with entryWeek < w (strict predecessor,
 * binary search), zero before the first entry — exact for every week
 * with no anchor entries and no live-value fallback. Buckets are
 * never checkpointed: `bucketAt` recomputes them from the checkpointed
 * score through the pure `_bucketFor`, so score and bucket history
 * cannot desync.
 *
 * Cutoff discipline (ported): `_snapshotCutoffIfNewWeek` runs
 * first-write-wins per week and must execute BEFORE any tree mutation
 * of a new week — {ReferralHubIntake}'s choke point enforces the
 * ordering the sandbox left to its tests. Quiet weeks carry the last
 * checkpoint forward exactly (sticky binary search); weeks before the
 * first snapshot resolve NOBODY_QUALIFIES, pessimistic and final.
 * Port hardening: an empty tree snapshots NOBODY_QUALIFIES rather
 * than the sandbox's 1 — with zero active referrers the target
 * ceil(0/10) is zero, so "nobody" is the truthful verdict rather
 * than one that merely prices nothing by accident.
 *
 * Dwell-min (hub-side policy knob, default ON): ladder inputs
 * for week w are min(opening(w), opening(w-1)) per component, so a
 * deposit straddling a weekly boundary must dwell a full week before
 * it can raise the rate; the decile cutoff deliberately uses the
 * plain opening snapshot. Every loop here is log-bounded binary
 * search; nothing iterates referrers or weeks.
 */
abstract contract ReferralHubCheckpoints is ReferralHubRanking {

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
        public
        view
        returns (bool)
    {
        uint256 cutoff = _cutoffAt(
            _week
        );

        if (cutoff > BUCKET_COUNT) {
            return false;
        }

        uint256 bucket = bucketAt(
            _referrer,
            _week
        );

        if (bucket == 0) {
            return false;
        }

        return bucket >= cutoff;
    }

    function bucketAt(
        address _referrer,
        uint256 _week
    )
        public
        view
        returns (uint256)
    {
        (
            uint256 referred,
        ) = _openingScoresAt(
            _referrer,
            _week
        );

        return bucketForScore(
            referred
        );
    }

    function openingScoresAt(
        address _referrer,
        uint256 _week
    )
        external
        view
        returns (
            uint256 referredScore,
            uint256 selfScore
        )
    {
        return _openingScoresAt(
            _referrer,
            _week
        );
    }

    function ladderInputsAt(
        address _referrer,
        uint256 _week
    )
        external
        view
        returns (
            uint256 referredInput,
            uint256 selfInput
        )
    {
        return _ladderInputsAt(
            _referrer,
            _week
        );
    }

    function checkpointCount(
        address _referrer
    )
        external
        view
        returns (uint256)
    {
        return referrerCheckpoints[_referrer].length;
    }

    function checkpointAt(
        address _referrer,
        uint256 _index
    )
        external
        view
        returns (
            uint256 week,
            uint256 referredScore,
            uint256 selfScore
        )
    {
        uint256 entry = referrerCheckpoints[_referrer][_index];

        return (
            entry >> CHECKPOINT_WEEK_SHIFT,
            (entry >> CHECKPOINT_REFERRED_SHIFT) & CHECKPOINT_VALUE_MASK,
            entry & CHECKPOINT_VALUE_MASK
        );
    }

    function _snapshotCutoffIfNewWeek()
        internal
    {
        uint256 week = block.timestamp / CohortWeeks.WEEK;

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

        if (active == 0) {
            return NOBODY_QUALIFIES;
        }

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

    function _checkpointReferrer(
        address _referrer
    )
        internal
    {
        uint256 week = block.timestamp / CohortWeeks.WEEK;

        uint256 referred = globalReferredScore[_referrer];

        uint256 selfScore = globalSelfScore[_referrer];

        uint256 packed = (week << CHECKPOINT_WEEK_SHIFT)
            | (referred << CHECKPOINT_REFERRED_SHIFT)
            | selfScore;

        uint256[] storage log = referrerCheckpoints[_referrer];

        uint256 length = log.length;

        if (length > 0 && log[length - 1] >> CHECKPOINT_WEEK_SHIFT == week) {
            log[length - 1] = packed;
        } else {
            log.push(packed);
        }

        emit ReferrerCheckpointed(
            _referrer,
            week,
            referred,
            selfScore
        );
    }

    function _openingScoresAt(
        address _referrer,
        uint256 _week
    )
        internal
        view
        returns (
            uint256 referredScore,
            uint256 selfScore
        )
    {
        uint256[] storage log = referrerCheckpoints[_referrer];

        uint256 length = log.length;

        if (length == 0) {
            return (0, 0);
        }

        if (log[0] >> CHECKPOINT_WEEK_SHIFT >= _week) {
            return (0, 0);
        }

        uint256 low;

        uint256 high = length - 1;

        while (low < high) {

            uint256 mid = (low + high + 1) / 2;

            if (log[mid] >> CHECKPOINT_WEEK_SHIFT < _week) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }

        uint256 entry = log[low];

        return (
            (entry >> CHECKPOINT_REFERRED_SHIFT) & CHECKPOINT_VALUE_MASK,
            entry & CHECKPOINT_VALUE_MASK
        );
    }

    function _ladderInputsAt(
        address _referrer,
        uint256 _week
    )
        internal
        view
        returns (
            uint256 referredInput,
            uint256 selfInput
        )
    {
        (
            uint256 referredNow,
            uint256 selfNow
        ) = _openingScoresAt(
            _referrer,
            _week
        );

        if (dwellMinEnabled == false || _week == 0) {
            return (referredNow, selfNow);
        }

        (
            uint256 referredPrev,
            uint256 selfPrev
        ) = _openingScoresAt(
            _referrer,
            _week - 1
        );

        return (
            referredNow < referredPrev
                ? referredNow
                : referredPrev,
            selfNow < selfPrev
                ? selfNow
                : selfPrev
        );
    }
}
