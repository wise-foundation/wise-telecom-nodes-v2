// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralHubDeclarations} from "./ReferralHubDeclarations.sol";
import {CohortWeeks} from "../../diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev Historical-truth layer: the per-referrer checkpoint machinery
 * that makes every past week's rate inputs immutable under
 * late-arriving data.
 *
 * Checkpoint discipline: every score mutation calls
 * `_checkpointReferrer` AFTER applying the diff: the first mutation
 * of a week pushes a new entry, later same-week mutations update the
 * tail entry in place, so an entry always holds the referrer's
 * CLOSING values of its week and entries for past weeks can never
 * change again. The opening value of any week w is therefore the
 * value of the last entry with entryWeek < w (strict predecessor,
 * binary search), zero before the first entry; exact for every week
 * with no anchor entries and no live-value fallback.
 *
 * Dwell-min (hub-side policy knob, genesis ON): ladder inputs
 * for week w are min(opening(w), opening(w-1)) per component, so a
 * deposit straddling a weekly boundary must dwell a full week before
 * it can raise the rate. The knob is week-versioned in the
 * append-only, future-only `dwellMinLog` (the same discipline as
 * the rate tables), so the setting that prices any week is fixed
 * once that week's opening boundary passes, and a policy change can
 * never re-verdict an undelivered past week. Every loop here is
 * log-bounded binary search; nothing iterates referrers or weeks.
 */
abstract contract ReferralHubCheckpoints is ReferralHubDeclarations {

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

    function dwellMinAt(
        uint256 _week
    )
        external
        view
        returns (bool)
    {
        return _dwellMinAt(
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

        if (_week == 0 || _dwellMinAt(_week) == false) {
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

    function _seedGenesisDwellMin()
        internal
    {
        dwellMinLog.push(
            1
        );

        emit DwellMinScheduled(
            0,
            true
        );
    }

    function _scheduleDwellMin(
        uint256 _effectiveFromWeek,
        bool _enabled
    )
        internal
    {
        require(
            _effectiveFromWeek > block.timestamp / CohortWeeks.WEEK,
            DwellMinNotFuture()
        );

        require(
            _effectiveFromWeek > dwellMinLog[dwellMinLog.length - 1] >> 1,
            DwellMinNotOrdered()
        );

        dwellMinLog.push(
            (_effectiveFromWeek << 1) | (_enabled ? 1 : 0)
        );

        emit DwellMinScheduled(
            _effectiveFromWeek,
            _enabled
        );
    }

    function _dwellMinAt(
        uint256 _week
    )
        internal
        view
        returns (bool)
    {
        uint256 low;

        uint256 high = dwellMinLog.length - 1;

        while (low < high) {

            uint256 mid = (low + high + 1) / 2;

            if (dwellMinLog[mid] >> 1 <= _week) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }

        return dwellMinLog[low] & 1 == 1;
    }
}
