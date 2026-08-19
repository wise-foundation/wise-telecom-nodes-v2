// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralHubRates} from "./ReferralHubRates.sol";
import {CohortWeeks} from "../../diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev Intake choke point: the ONLY writers of scores, cursors and
 * claimables in the whole chain. The future cross-chain mailbox and
 * mainnet-vault inline delivery are future CALLERS of these same
 * internals — one intake codepath, never a second topology. The
 * crumb WORD is the frozen interface: intake takes raw
 * recorder words (validated against the frozen geometry — any bit
 * outside the three 80-bit lanes and the written flag rejects); the
 * flush envelope and its `crumbVersion` are cross-chain message
 * artifacts that do not exist here. Quantities and increments travel through
 * the internal helpers as single packed lane-words in the crumb
 * geometry, decoded with the {CohortWeeks} accessors at the edges.
 *
 * Scores are ABSOLUTE per source, not deltas: `_applyScoreReport`
 * diffs the reported values against `lastSourceReport` and applies
 * the signed difference to the global aggregates.
 * Re-reports are idempotent no-ops, recorder clamp decreases
 * arrive as plain lower absolutes, and score consistency reduces to
 * the equality `globalReferredScore == Σ lastSourceReport` per
 * referrer. Ordering is load-bearing: apply diff → checkpoint
 * referrer (post-mutation closing value).
 *
 * Cursors enforce exactly-once accrual:
 * `paidCursor[source][referrer][week]` stores the
 * highest token-second quantity ever priced per lane; a delivery pays
 * only `incoming − cursor` when positive and advances the cursor to
 * the max, so replays, duplicates and reordered batches accrue
 * exactly once, and a growing current-week word pays only fresh
 * increments at the week's already-frozen rate (continuous
 * claims). A regressive lane emits the `CrumbLaneRegression` anomaly
 * and pays zero — never a revert.
 *
 * Pricing floors per lane: `inc × bps / 10_000 / YEAR`, dust
 * retained, so total paid per (source, referrer, week) can never
 * exceed lanes × frozen rate. Gap records decompress span
 * semantics (Y1 = Y2 = 0, M constant) through the SAME `_priceWeek`
 * path in caller-windowed chunks of at most MAX_SETTLE_BOUNDARIES
 * weeks — resume is just another call, because overlapping windows
 * are zero-increment no-ops on the cursors. A gap record whose
 * mature principal could not have come from the recorder — one whose
 * per-week token-seconds would overflow the frozen 80-bit lane —
 * rejects as invalid rather than corrupting cursor geometry.
 * `deliverer` is stamped from `msg.sender` into every pricing event;
 * the bot share applies only to future cross-chain transport
 * (mainnet deliveries are always 100% referrer), so the split
 * arithmetic deliberately does not exist here — it attaches at the
 * accrual site when a non-100% deliverer first becomes reachable.
 */
abstract contract ReferralHubIntake is ReferralHubRates {

    function _applyScoreReport(
        bytes32 _source,
        address _referrer,
        uint256 _referredAbs,
        uint256 _selfAbs
    )
        internal
    {
        require(
            _referredAbs <= MAX_SOURCE_SCORE
                && _selfAbs <= MAX_SOURCE_SCORE,
            ScoreReportOutOfRange()
        );

        uint256 packed = (_referredAbs << REPORT_REFERRED_SHIFT) | _selfAbs;

        uint256 previous = lastSourceReport[_source][_referrer];

        if (previous == packed) {
            return;
        }

        lastSourceReport[_source][_referrer] = packed;

        globalReferredScore[_referrer] = globalReferredScore[_referrer]
            - (previous >> REPORT_REFERRED_SHIFT)
            + _referredAbs;

        globalSelfScore[_referrer] = globalSelfScore[_referrer]
            - (previous & REPORT_VALUE_MASK)
            + _selfAbs;

        _checkpointReferrer(
            _referrer
        );

        emit SourceScoresReported(
            _source,
            _referrer,
            _referredAbs,
            _selfAbs
        );
    }

    function _deliverCrumb(
        bytes32 _source,
        address _referrer,
        uint256 _week,
        uint256 _word
    )
        internal
    {
        if (_word == 0) {
            return;
        }

        require(
            _word & ~_crumbWordMask() == 0,
            InvalidCrumbWord()
        );

        require(
            _week <= block.timestamp / CohortWeeks.WEEK,
            FutureWeek()
        );

        (
            uint256 paid,
            uint256 incrementWord
        ) = _priceWeek(
            _source,
            _referrer,
            _week,
            _word & ~CohortWeeks.CRUMB_WRITTEN_BIT
        );

        if (incrementWord == 0) {
            return;
        }

        emit CrumbPriced(
            _source,
            _referrer,
            _week,
            msg.sender,
            CohortWeeks.laneY1(incrementWord),
            CohortWeeks.laneY2(incrementWord),
            CohortWeeks.laneM(incrementWord),
            paid
        );
    }

    function _deliverGap(
        bytes32 _source,
        address _referrer,
        uint256 _record,
        uint256 _fromWeek,
        uint256 _maxWeeks
    )
        internal
    {
        (
            uint256 toWeekExclusive,
            uint256 mature
        ) = _parseGapRecord(
            _record,
            _fromWeek,
            _maxWeeks
        );

        uint256 end = _windowEnd(
            _fromWeek,
            _maxWeeks,
            toWeekExclusive
        );

        (
            uint256 paidTotal,
            uint256 incrementTotal
        ) = _priceGapWindow(
            _source,
            _referrer,
            mature * CohortWeeks.WEEK,
            _fromWeek,
            end
        );

        if (incrementTotal == 0) {
            return;
        }

        emit GapPriced(
            _source,
            _referrer,
            _fromWeek,
            end,
            paidTotal
        );
    }

    function _parseGapRecord(
        uint256 _record,
        uint256 _fromWeek,
        uint256 _maxWeeks
    )
        internal
        view
        returns (
            uint256 toWeekExclusive,
            uint256 mature
        )
    {
        uint256 fromWeek = _record & GAP_WEEK_MASK;

        toWeekExclusive = (_record >> CohortWeeks.GAP_TO_SHIFT) & GAP_WEEK_MASK;

        mature = (_record >> CohortWeeks.GAP_MATURE_SHIFT) & CohortWeeks.LANE_MASK_80;

        require(
            fromWeek < toWeekExclusive
                && _record >> (CohortWeeks.GAP_MATURE_SHIFT + 80) == 0
                && mature <= CohortWeeks.LANE_MASK_80 / CohortWeeks.WEEK,
            InvalidGapRecord()
        );

        require(
            toWeekExclusive <= block.timestamp / CohortWeeks.WEEK,
            FutureWeek()
        );

        require(
            _maxWeeks > 0
                && _fromWeek >= fromWeek
                && _fromWeek < toWeekExclusive,
            InvalidWindow()
        );
    }

    function _windowEnd(
        uint256 _fromWeek,
        uint256 _maxWeeks,
        uint256 _toWeekExclusive
    )
        internal
        pure
        returns (uint256)
    {
        uint256 window = _maxWeeks < CohortWeeks.MAX_SETTLE_BOUNDARIES
            ? _maxWeeks
            : CohortWeeks.MAX_SETTLE_BOUNDARIES;

        return _fromWeek + window < _toWeekExclusive
            ? _fromWeek + window
            : _toWeekExclusive;
    }

    function _priceGapWindow(
        bytes32 _source,
        address _referrer,
        uint256 _mQuantity,
        uint256 _fromWeek,
        uint256 _end
    )
        internal
        returns (
            uint256 paidTotal,
            uint256 incrementTotal
        )
    {
        uint256 quantityWord = CohortWeeks.packLanes(
            0,
            0,
            _mQuantity
        );

        for (uint256 week = _fromWeek; week < _end; ++week) {

            (
                uint256 paid,
                uint256 incrementWord
            ) = _priceWeek(
                _source,
                _referrer,
                week,
                quantityWord
            );

            paidTotal += paid;

            incrementTotal += incrementWord;
        }
    }

    function _priceWeek(
        bytes32 _source,
        address _referrer,
        uint256 _week,
        uint256 _quantityWord
    )
        internal
        returns (
            uint256 paid,
            uint256 incrementWord
        )
    {
        incrementWord = _cursorIncrements(
            _source,
            _referrer,
            _week,
            _quantityWord
        );

        if (incrementWord == 0) {
            return (0, 0);
        }

        _advanceCursor(
            _source,
            _referrer,
            _week,
            _quantityWord
        );

        paid = _payIncrements(
            _referrer,
            _week,
            incrementWord
        );
    }

    function _cursorIncrements(
        bytes32 _source,
        address _referrer,
        uint256 _week,
        uint256 _quantityWord
    )
        internal
        returns (uint256 incrementWord)
    {
        uint256 cursorWord = paidCursor[_source][_referrer][_week];

        incrementWord = CohortWeeks.packLanes(
            _laneIncrement(
                _source,
                _referrer,
                _week,
                0,
                CohortWeeks.laneY1(_quantityWord),
                CohortWeeks.laneY1(cursorWord)
            ),
            _laneIncrement(
                _source,
                _referrer,
                _week,
                1,
                CohortWeeks.laneY2(_quantityWord),
                CohortWeeks.laneY2(cursorWord)
            ),
            _laneIncrement(
                _source,
                _referrer,
                _week,
                2,
                CohortWeeks.laneM(_quantityWord),
                CohortWeeks.laneM(cursorWord)
            )
        );
    }

    function _advanceCursor(
        bytes32 _source,
        address _referrer,
        uint256 _week,
        uint256 _quantityWord
    )
        internal
    {
        uint256 cursorWord = paidCursor[_source][_referrer][_week];

        paidCursor[_source][_referrer][_week] = CohortWeeks.packLanes(
            _max(
                CohortWeeks.laneY1(_quantityWord),
                CohortWeeks.laneY1(cursorWord)
            ),
            _max(
                CohortWeeks.laneY2(_quantityWord),
                CohortWeeks.laneY2(cursorWord)
            ),
            _max(
                CohortWeeks.laneM(_quantityWord),
                CohortWeeks.laneM(cursorWord)
            )
        );
    }

    function _payIncrements(
        address _referrer,
        uint256 _week,
        uint256 _incrementWord
    )
        internal
        returns (uint256 paid)
    {
        (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        ) = _weeklyRates(
            _referrer,
            _week
        );

        paid = CohortWeeks.laneY1(_incrementWord) * y1Bps / BPS_DENOMINATOR / CohortWeeks.YEAR
            + CohortWeeks.laneY2(_incrementWord) * y2Bps / BPS_DENOMINATOR / CohortWeeks.YEAR
            + CohortWeeks.laneM(_incrementWord) * mBps / BPS_DENOMINATOR / CohortWeeks.YEAR;

        if (paid > 0) {
            claimable[_referrer] += paid;
            totalAccrued += paid;
        }
    }

    function _laneIncrement(
        bytes32 _source,
        address _referrer,
        uint256 _week,
        uint256 _laneKind,
        uint256 _incoming,
        uint256 _cursor
    )
        internal
        returns (uint256)
    {
        if (_incoming > _cursor) {
            return _incoming - _cursor;
        }

        if (_incoming < _cursor) {

            emit CrumbLaneRegression(
                _source,
                _referrer,
                _week,
                _laneKind,
                _incoming,
                _cursor
            );
        }

        return 0;
    }

    function _crumbWordMask()
        internal
        pure
        returns (uint256)
    {
        return CohortWeeks.LANE_MASK_80
            | (CohortWeeks.LANE_MASK_80 << CohortWeeks.LANE_Y2_SHIFT)
            | (CohortWeeks.LANE_MASK_80 << CohortWeeks.LANE_M_SHIFT)
            | CohortWeeks.CRUMB_WRITTEN_BIT;
    }

    function _max(
        uint256 _a,
        uint256 _b
    )
        internal
        pure
        returns (uint256)
    {
        return _a > _b
            ? _a
            : _b;
    }
}
