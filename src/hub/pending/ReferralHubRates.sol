// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralHubCheckpoints} from "./ReferralHubCheckpoints.sol";
import {CohortWeeks} from "../../diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev Rate policy module: every
 * dwell-min, cap and table lookup sits behind the single internal
 * `_weeklyRates`, so pending rate decisions and future ladder
 * changes are
 * hub-only changes with week-versioned history — nothing else in the
 * chain may compute a rate. Rates are expressed in bps of ANNUAL
 * commission on referred principal; pricing divides token-seconds by
 * `CohortWeeks.YEAR` in {ReferralHubIntake}.
 *
 * `rateTables` is append-only and future-only: `_pushRateTable`
 * requires a strictly future effective week that strictly exceeds the
 * previous entry's, so the table that priced any week whose opening
 * boundary has passed can never change — past-verdict immutability
 * under table churn holds
 * by construction, with no second freezing mechanism. The genesis
 * entry seeds the launch ladder exactly: thresholds 5k/10k/20k/30k/
 * 50k/100k/
 * 500k/1M USD (6-dec), tiers 1..8% (100..800 bps), Year-1 rate =
 * min(tier(self) + tier(referred), capBps = 1000) over dwell-min
 * ladder inputs, floor 0 implicit. Year-2 and mature rates are 0
 * until decided — the decile gate (`qualifiedAt`) is WIRED and
 * multiplies whatever the week's table holds, so landing them is one
 * `pushRateTable` call, zero code. Both loops here are fixed-bound
 * (8-rung tier walk) or log-bounded (table binary search).
 */
abstract contract ReferralHubRates is ReferralHubCheckpoints {

    function weeklyRates(
        address _referrer,
        uint256 _week
    )
        external
        view
        returns (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        )
    {
        return _weeklyRates(
            _referrer,
            _week
        );
    }

    function rateTableCount()
        external
        view
        returns (uint256)
    {
        return rateTables.length;
    }

    function rateTableAt(
        uint256 _index
    )
        external
        view
        returns (RateTable memory)
    {
        return rateTables[_index];
    }

    function _seedGenesisRateTable()
        internal
    {
        rateTables.push(
            RateTable({
                effectiveFromWeek: 0,
                capBps: 1_000,
                y2RateBps: 0,
                mRateBps: 0,
                tierBps: [
                    uint16(100),
                    200,
                    300,
                    400,
                    500,
                    600,
                    700,
                    800
                ],
                thresholds: [
                    uint96(5_000 * 1e6),
                    10_000 * 1e6,
                    20_000 * 1e6,
                    30_000 * 1e6,
                    50_000 * 1e6,
                    100_000 * 1e6,
                    500_000 * 1e6,
                    1_000_000 * 1e6
                ]
            })
        );

        emit RateTableScheduled(
            0,
            0
        );
    }

    function _pushRateTable(
        RateTable memory _table
    )
        internal
    {
        require(
            _table.effectiveFromWeek > block.timestamp / CohortWeeks.WEEK,
            TableNotFuture()
        );

        require(
            _table.effectiveFromWeek > rateTables[rateTables.length - 1].effectiveFromWeek,
            TableNotOrdered()
        );

        require(
            _table.capBps <= BPS_DENOMINATOR
                && _table.y2RateBps <= BPS_DENOMINATOR
                && _table.mRateBps <= BPS_DENOMINATOR,
            InvalidRateTable()
        );

        for (uint256 i; i < 8; ++i) {

            require(
                _table.tierBps[i] <= BPS_DENOMINATOR,
                InvalidRateTable()
            );

            require(
                _table.thresholds[i] > 0
                    && (i == 0 || _table.thresholds[i] > _table.thresholds[i - 1]),
                InvalidRateTable()
            );
        }

        rateTables.push(
            _table
        );

        emit RateTableScheduled(
            rateTables.length - 1,
            _table.effectiveFromWeek
        );
    }

    function _weeklyRates(
        address _referrer,
        uint256 _week
    )
        internal
        view
        returns (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        )
    {
        RateTable storage table = _tableFor(
            _week
        );

        (
            uint256 referredInput,
            uint256 selfInput
        ) = _ladderInputsAt(
            _referrer,
            _week
        );

        y1Bps = _tierBps(
            table,
            selfInput
        ) + _tierBps(
            table,
            referredInput
        );

        if (y1Bps > table.capBps) {
            y1Bps = table.capBps;
        }

        if (table.y2RateBps > 0 || table.mRateBps > 0) {

            if (qualifiedAt(_week, _referrer)) {
                y2Bps = table.y2RateBps;
                mBps = table.mRateBps;
            }
        }
    }

    function _tableFor(
        uint256 _week
    )
        internal
        view
        returns (RateTable storage)
    {
        uint256 low;

        uint256 high = rateTables.length - 1;

        while (low < high) {

            uint256 mid = (low + high + 1) / 2;

            if (rateTables[mid].effectiveFromWeek <= _week) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }

        return rateTables[low];
    }

    function _tierBps(
        RateTable storage _table,
        uint256 _value
    )
        internal
        view
        returns (uint256)
    {
        for (uint256 i = 8; i > 0; --i) {

            if (_value >= _table.thresholds[i - 1]) {
                return _table.tierBps[i - 1];
            }
        }

        return 0;
    }
}
