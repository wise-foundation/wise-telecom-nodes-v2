// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev CohortWeeks — the single source of truth for every week-epoch
 * and lane-packing constant of the referral cohort recorder, shared by
 * the recorder facets today and by the mainnet hub and cross-chain
 * flush messages in later phases. One epoch definition everywhere
 * (`week = timestamp / WEEK`, year = 52 weeks): a mismatch between
 * recorder and hub arithmetic would be a silent fund bug, so no other
 * contract may restate these numbers.
 *
 * Lane geometry: the packed book word and every crumb word share the
 * same three 80-bit lanes (year-1 at bit 0, year-2 at bit 80, mature
 * at bit 160). Crumb words additionally carry the written flag at bit
 * 252; bits 240..251 and 253..255 stay zero forever. The crumb word
 * format is FROZEN as of Phase 2b and consumed by the hub in Phase 4;
 * `CRUMB_VERSION` is stamped into every Phase-5 flush envelope so the
 * hub can accept version 1 forever. Ring slots pack four uint64 lanes
 * per storage word (52 slots = 13 words per ring per referrer).
 *
 * The saturating helpers return the clipped remainder alongside the
 * result so callers can emit the anomaly event on any clip; they never
 * revert, because they run inside the transfer hook where a revert
 * would veto the transfer itself. All members are `internal`, inlined
 * at compile time, and therefore safe under DELEGATECALL from any
 * facet.
 */
library CohortWeeks {

    uint256 internal constant WEEK = 1 weeks;

    uint256 internal constant RING_SLOTS = 52;

    uint256 internal constant YEAR = RING_SLOTS * WEEK;

    uint256 internal constant MAX_SETTLE_BOUNDARIES = 104;

    uint256 internal constant LANE_MASK_80 = (1 << 80) - 1;

    uint256 internal constant LANE_Y2_SHIFT = 80;

    uint256 internal constant LANE_M_SHIFT = 160;

    uint256 internal constant CRUMB_WRITTEN_BIT = 1 << 252;

    uint256 internal constant CRUMB_VERSION = 1;

    uint256 internal constant GAP_TO_SHIFT = 32;

    uint256 internal constant GAP_MATURE_SHIFT = 64;

    uint256 internal constant RING_LANE_MAX = type(uint64).max;

    function laneY1(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return _word & LANE_MASK_80;
    }

    function laneY2(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> LANE_Y2_SHIFT) & LANE_MASK_80;
    }

    function laneM(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> LANE_M_SHIFT) & LANE_MASK_80;
    }

    function packLanes(
        uint256 _y1,
        uint256 _y2,
        uint256 _m
    )
        internal
        pure
        returns (uint256)
    {
        return _y1
            | (_y2 << LANE_Y2_SHIFT)
            | (_m << LANE_M_SHIFT);
    }

    function saturatingAdd80(
        uint256 _lane,
        uint256 _add
    )
        internal
        pure
        returns (
            uint256 result,
            uint256 clipped
        )
    {
        uint256 sum = _lane + _add;

        if (sum > LANE_MASK_80) {
            return (
                LANE_MASK_80,
                sum - LANE_MASK_80
            );
        }

        return (
            sum,
            0
        );
    }

    function saturatingAdd64(
        uint256 _lane,
        uint256 _add
    )
        internal
        pure
        returns (
            uint256 result,
            uint256 clipped
        )
    {
        uint256 sum = _lane + _add;

        if (sum > RING_LANE_MAX) {
            return (
                RING_LANE_MAX,
                sum - RING_LANE_MAX
            );
        }

        return (
            sum,
            0
        );
    }

    function saturatingSub(
        uint256 _value,
        uint256 _sub
    )
        internal
        pure
        returns (
            uint256 result,
            uint256 clipped
        )
    {
        if (_sub > _value) {
            return (
                0,
                _sub - _value
            );
        }

        return (
            _value - _sub,
            0
        );
    }
}
