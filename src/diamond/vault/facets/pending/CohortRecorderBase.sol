// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "../FacetBase.sol";
import {CohortWeeks} from "../../../shared/pending/CohortWeeks.sol";

/**
 * @dev CohortRecorderBase — the cohort recorder engine, a 1:1 port of
 * the proven sandbox `test/fenwick/ReferralCommissionDemo.sol` onto
 * the diamond's packed tail-shard storage ({CohortContributionDeclaration},
 * {CohortBookDeclaration}). The engine is compiled once into
 * {CohortHookFacet} and reached exclusively through the
 * `transferHookFacet` pointer (ruling R17); nothing else in the
 * diamond carries this code.
 *
 * Ordering discipline (preserved verbatim from the sandbox): every
 * path that mutates a referrer's book settles it FIRST.
 * Settle-before-reduce keeps ring slot indices meaningful (rotations
 * current before the walk); settle-before-credit keeps crumb
 * time-weights exact (the elapsed window accrues at the balances that
 * actually existed). The clamp is one-way (ruling R4): `_syncRefereeCohort`
 * only ever lowers `trackedContribution` to the held balance — for
 * EVERY depositor, referred or not, because the self-stake ladder
 * input must stay honest — and reduces the referrer's book
 * newest-credit-first so a sell-plus-redeposit cycle can never upgrade
 * old credit while fresh cover exists.
 *
 * Never-block guarantee (ruling R5, invariant I6): the settle walk is
 * capped at MAX_SETTLE_BOUNDARIES = 104 steps — after 104 rotations
 * both rings are provably empty, so anything further is a closed-form
 * mature-only gap record plus one partial segment — and no function
 * here has a revert path: every lane operation saturates via
 * {CohortWeeks} and reports clips through {CohortLaneSaturated}
 * instead of reverting, because this code runs inside the transfer
 * hook where a revert would veto the transfer itself. The common
 * transfer stays cheap: `_syncRefereeCohort` exits on two reads when
 * the user holds at least their tracked contribution, before touching
 * any book state. Loop bounds: settle walk 104
 * (MAX_SETTLE_BOUNDARIES), reduction walks 52 each (RING_SLOTS) —
 * cited from {CohortWeeks} next to each loop.
 *
 * Packing deltas vs the sandbox: rings are uint64[52] (four lanes per
 * word); the book is one word of three 80-bit lanes sharing the crumb
 * geometry, so a settle segment reads all three sums in one SLOAD and
 * the referrer score is definitionally laneY1+laneY2+laneM (no
 * separate score variable to desync). The gap record's mature field is
 * structurally bounded by the 80-bit book lane, closing the sandbox's
 * unguarded-width review finding. `referrerOf` is read through the
 * single `_cohortReferrerOf` site so the Phase-1 chain-registry swap
 * is contained to one function plus a hook redeploy.
 */
abstract contract CohortRecorderBase is FacetBase {

    function _cohortReferrerOf(
        address _user
    )
        internal
        view
        returns (address)
    {
        return referrerOf[_user];
    }

    function _syncRefereeCohort(
        address _user
    )
        internal
    {
        uint256 tracked = trackedContribution[_user];

        uint256 held = balanceOf(
            _user
        );

        if (held >= tracked) {
            return;
        }

        uint256 delta = tracked - held;

        address referrer = _cohortReferrerOf(
            _user
        );

        if (referrer != ZERO_ADDRESS) {
            _settleBookCohort(
                referrer
            );
        }

        trackedContribution[_user] = held;

        if (referrer != ZERO_ADDRESS) {
            _reduceBookCohort(
                referrer,
                delta
            );
        }

        emit CohortContributionSynced(
            _user,
            referrer,
            tracked,
            held
        );
    }

    function _creditContributionCohort(
        address _user,
        uint256 _amount
    )
        internal
    {
        if (_amount == 0) {
            return;
        }

        address referrer = _cohortReferrerOf(
            _user
        );

        if (referrer != ZERO_ADDRESS) {

            _settleBookCohort(
                referrer
            );

            _creditRingCohort(
                referrer,
                _amount
            );
        }

        trackedContribution[_user] += _amount;

        emit CohortContributionCredited(
            _user,
            referrer,
            _amount
        );
    }

    function _creditRingCohort(
        address _referrer,
        uint256 _amount
    )
        internal
    {
        uint256 slot = (block.timestamp / CohortWeeks.WEEK) % CohortWeeks.RING_SLOTS;

        (
            uint256 newLane,
            uint256 clippedRing
        ) = CohortWeeks.saturatingAdd64(
            uint256(cohortRingYear1[_referrer][slot]),
            _amount
        );

        cohortRingYear1[_referrer][slot] = uint64(newLane);

        if (clippedRing > 0) {
            emit CohortLaneSaturated(
                _referrer,
                0,
                slot,
                clippedRing
            );
        }

        uint256 book = cohortBook[_referrer];

        (
            uint256 newYear1,
            uint256 clippedBook
        ) = CohortWeeks.saturatingAdd80(
            CohortWeeks.laneY1(book),
            _amount
        );

        cohortBook[_referrer] = CohortWeeks.packLanes(
            newYear1,
            CohortWeeks.laneY2(book),
            CohortWeeks.laneM(book)
        );

        if (clippedBook > 0) {
            emit CohortLaneSaturated(
                _referrer,
                2,
                0,
                clippedBook
            );
        }
    }

    function _settleBookCohort(
        address _referrer
    )
        internal
    {
        uint256 last = cohortLastSettle[_referrer];

        if (last == block.timestamp) {
            return;
        }

        if (last == 0) {
            cohortLastSettle[_referrer] = block.timestamp;
            return;
        }

        uint256 cursor = last;

        uint256 steps;

        while (steps < CohortWeeks.MAX_SETTLE_BOUNDARIES) {

            uint256 next = (cursor / CohortWeeks.WEEK + 1) * CohortWeeks.WEEK;

            if (next > block.timestamp) {
                break;
            }

            _recordSegmentCohort(
                _referrer,
                cursor,
                next
            );

            _rotateCohort(
                _referrer,
                next / CohortWeeks.WEEK
            );

            cursor = next;

            ++steps;
        }

        uint256 latestBoundary = (block.timestamp / CohortWeeks.WEEK) * CohortWeeks.WEEK;

        if (latestBoundary > cursor) {
            cursor = _recordGapCohort(
                _referrer,
                cursor,
                latestBoundary
            );
        }

        if (block.timestamp > cursor) {
            _recordSegmentCohort(
                _referrer,
                cursor,
                block.timestamp
            );
        }

        cohortLastSettle[_referrer] = block.timestamp;

        emit CohortBookSettled(
            _referrer,
            last,
            block.timestamp,
            steps
        );
    }

    function _advanceBookCohort(
        address _referrer,
        uint256 _maxBoundaries
    )
        internal
    {
        uint256 last = cohortLastSettle[_referrer];

        if (last == 0) {
            return;
        }

        uint256 cursor = last;

        uint256 steps;

        while (steps < _maxBoundaries && steps < CohortWeeks.MAX_SETTLE_BOUNDARIES) {

            uint256 next = (cursor / CohortWeeks.WEEK + 1) * CohortWeeks.WEEK;

            if (next > block.timestamp) {
                break;
            }

            _recordSegmentCohort(
                _referrer,
                cursor,
                next
            );

            _rotateCohort(
                _referrer,
                next / CohortWeeks.WEEK
            );

            cursor = next;

            ++steps;
        }

        if (cursor == last) {
            return;
        }

        cohortLastSettle[_referrer] = cursor;

        emit CohortBookSettled(
            _referrer,
            last,
            cursor,
            steps
        );
    }

    function _recordSegmentCohort(
        address _referrer,
        uint256 _from,
        uint256 _to
    )
        internal
    {
        uint256 book = cohortBook[_referrer];

        if (book == 0) {
            return;
        }

        uint256 dt = _to - _from;

        _writeCrumbCohort(
            _referrer,
            _from / CohortWeeks.WEEK,
            CohortWeeks.laneY1(book) * dt,
            CohortWeeks.laneY2(book) * dt,
            CohortWeeks.laneM(book) * dt
        );
    }

    function _writeCrumbCohort(
        address _referrer,
        uint256 _week,
        uint256 _y1Seconds,
        uint256 _y2Seconds,
        uint256 _mSeconds
    )
        internal
    {
        uint256 crumb = cohortWeekLog[_referrer][_week];

        if (crumb & CohortWeeks.CRUMB_WRITTEN_BIT == 0) {
            crumb = CohortWeeks.CRUMB_WRITTEN_BIT;
        }

        (
            uint256 year1Total,
            uint256 clippedYear1
        ) = CohortWeeks.saturatingAdd80(
            CohortWeeks.laneY1(crumb),
            _y1Seconds
        );

        (
            uint256 year2Total,
            uint256 clippedYear2
        ) = CohortWeeks.saturatingAdd80(
            CohortWeeks.laneY2(crumb),
            _y2Seconds
        );

        (
            uint256 matureTotal,
            uint256 clippedMature
        ) = CohortWeeks.saturatingAdd80(
            CohortWeeks.laneM(crumb),
            _mSeconds
        );

        cohortWeekLog[_referrer][_week] = (
            crumb & ~(
                CohortWeeks.LANE_MASK_80
                    | (CohortWeeks.LANE_MASK_80 << CohortWeeks.LANE_Y2_SHIFT)
                    | (CohortWeeks.LANE_MASK_80 << CohortWeeks.LANE_M_SHIFT)
            )
        )
            | CohortWeeks.packLanes(
                year1Total,
                year2Total,
                matureTotal
            );

        uint256 clippedTotal = clippedYear1 + clippedYear2 + clippedMature;

        if (clippedTotal > 0) {
            emit CohortLaneSaturated(
                _referrer,
                3,
                _week,
                clippedTotal
            );
        }
    }

    function _recordGapCohort(
        address _referrer,
        uint256 _from,
        uint256 _toBoundary
    )
        internal
        returns (uint256)
    {
        uint256 mature = CohortWeeks.laneM(
            cohortBook[_referrer]
        );

        uint256 fromWeek = _from / CohortWeeks.WEEK;

        uint256 toWeekExclusive = _toBoundary / CohortWeeks.WEEK;

        if (mature > 0) {

            cohortGapLog[_referrer].push(
                fromWeek
                    | (toWeekExclusive << CohortWeeks.GAP_TO_SHIFT)
                    | (mature << CohortWeeks.GAP_MATURE_SHIFT)
            );

            emit CohortGapRecorded(
                _referrer,
                fromWeek,
                toWeekExclusive,
                mature
            );
        }

        return _toBoundary;
    }

    function _rotateCohort(
        address _referrer,
        uint256 _boundaryWeek
    )
        internal
    {
        uint256 slot = _boundaryWeek % CohortWeeks.RING_SLOTS;

        uint256 graduatingYear2 = uint256(cohortRingYear2[_referrer][slot]);

        uint256 graduatingYear1 = uint256(cohortRingYear1[_referrer][slot]);

        if (graduatingYear1 == 0 && graduatingYear2 == 0) {
            return;
        }

        uint256 book = cohortBook[_referrer];

        uint256 year1 = CohortWeeks.laneY1(book);

        uint256 year2 = CohortWeeks.laneY2(book);

        uint256 mature = CohortWeeks.laneM(book);

        uint256 clippedTotal;

        uint256 clipped;

        if (graduatingYear2 > 0) {

            (mature, clipped) = CohortWeeks.saturatingAdd80(
                mature,
                graduatingYear2
            );

            clippedTotal += clipped;

            (year2, clipped) = CohortWeeks.saturatingSub(
                year2,
                graduatingYear2
            );

            clippedTotal += clipped;
        }

        if (graduatingYear1 > 0) {

            (year2, clipped) = CohortWeeks.saturatingAdd80(
                year2,
                graduatingYear1
            );

            clippedTotal += clipped;

            (year1, clipped) = CohortWeeks.saturatingSub(
                year1,
                graduatingYear1
            );

            clippedTotal += clipped;

            cohortRingYear1[_referrer][slot] = 0;
        }

        if (graduatingYear1 != graduatingYear2) {
            cohortRingYear2[_referrer][slot] = uint64(graduatingYear1);
        }

        cohortBook[_referrer] = CohortWeeks.packLanes(
            year1,
            year2,
            mature
        );

        if (clippedTotal > 0) {
            emit CohortLaneSaturated(
                _referrer,
                2,
                slot,
                clippedTotal
            );
        }
    }

    function _reduceBookCohort(
        address _referrer,
        uint256 _delta
    )
        internal
        returns (
            uint256 fromYear1,
            uint256 fromYear2,
            uint256 fromMature
        )
    {
        uint256 remaining = _delta;

        uint256 currentWeek = block.timestamp / CohortWeeks.WEEK;

        for (uint256 back; back < CohortWeeks.RING_SLOTS; ++back) {

            if (remaining == 0 || back > currentWeek) {
                break;
            }

            uint256 slot = (currentWeek - back) % CohortWeeks.RING_SLOTS;

            uint256 held = uint256(cohortRingYear1[_referrer][slot]);

            if (held == 0) {
                continue;
            }

            uint256 take = held < remaining
                ? held
                : remaining;

            cohortRingYear1[_referrer][slot] = uint64(held - take);

            remaining -= take;

            fromYear1 += take;
        }

        for (uint256 back; back < CohortWeeks.RING_SLOTS; ++back) {

            if (remaining == 0 || back > currentWeek) {
                break;
            }

            uint256 slot = (currentWeek - back) % CohortWeeks.RING_SLOTS;

            uint256 held = uint256(cohortRingYear2[_referrer][slot]);

            if (held == 0) {
                continue;
            }

            uint256 take = held < remaining
                ? held
                : remaining;

            cohortRingYear2[_referrer][slot] = uint64(held - take);

            remaining -= take;

            fromYear2 += take;
        }

        uint256 book = cohortBook[_referrer];

        uint256 year1 = CohortWeeks.laneY1(book);

        uint256 year2 = CohortWeeks.laneY2(book);

        uint256 mature = CohortWeeks.laneM(book);

        uint256 clippedTotal;

        uint256 clipped;

        if (fromYear1 > 0) {

            (year1, clipped) = CohortWeeks.saturatingSub(
                year1,
                fromYear1
            );

            clippedTotal += clipped;
        }

        if (fromYear2 > 0) {

            (year2, clipped) = CohortWeeks.saturatingSub(
                year2,
                fromYear2
            );

            clippedTotal += clipped;
        }

        if (remaining > 0) {

            (mature, clipped) = CohortWeeks.saturatingSub(
                mature,
                remaining
            );

            fromMature = remaining - clipped;

            if (clipped > 0) {
                emit CohortLaneSaturated(
                    _referrer,
                    5,
                    0,
                    clipped
                );
            }
        }

        cohortBook[_referrer] = CohortWeeks.packLanes(
            year1,
            year2,
            mature
        );

        if (clippedTotal > 0) {
            emit CohortLaneSaturated(
                _referrer,
                2,
                0,
                clippedTotal
            );
        }

        emit CohortBookReduced(
            _referrer,
            _delta,
            fromYear1,
            fromYear2,
            fromMature
        );
    }
}
