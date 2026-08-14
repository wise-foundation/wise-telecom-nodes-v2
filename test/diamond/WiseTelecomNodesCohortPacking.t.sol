// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev Pure-function fuzz suite for {CohortWeeks}, the FROZEN lane-packing
 * library shared by the cohort book and every crumb word. Covers the
 * lane codec (pack/decode round trip, disjoint-OR composition, and
 * immunity to the crumb-written flag and any stray high bits above the
 * three 80-bit lanes), the three saturating helpers (clip-at-cap for
 * `saturatingAdd80`/`saturatingAdd64` and floor-at-zero for
 * `saturatingSub`, each proven to conserve the algebraic sum or
 * difference across `result` and `clipped`), and a pinned-constant
 * regression test so any accidental edit to the frozen crumb-word
 * geometry — consumed byte for byte by the mainnet hub from Phase 4
 * onward — fails loudly. No diamond harness is needed: every target
 * function is `pure`, so this suite calls the library directly and
 * relies on Solidity inlining internal library members into the
 * caller.
 */
contract WiseTelecomNodesCohortPackingTest is Test {

    uint256 internal constant MASK_80 = CohortWeeks.LANE_MASK_80;

    uint256 internal constant ADD_UPPER = 2 ** 128;

    function testFuzz_packLanes_laneRoundTripIdentity(
        uint256 _y1,
        uint256 _y2,
        uint256 _m
    )
        external
        pure
    {
        uint256 y1 = bound(
            _y1,
            0,
            MASK_80
        );

        uint256 y2 = bound(
            _y2,
            0,
            MASK_80
        );

        uint256 m = bound(
            _m,
            0,
            MASK_80
        );

        uint256 word = CohortWeeks.packLanes(
            y1,
            y2,
            m
        );

        assertEq(
            CohortWeeks.laneY1(word),
            y1
        );

        assertEq(
            CohortWeeks.laneY2(word),
            y2
        );

        assertEq(
            CohortWeeks.laneM(word),
            m
        );

        assertEq(
            word >> 240,
            0
        );
    }

    function testFuzz_laneDecode_ignoresWrittenBitAndHighBits(
        uint256 _y1,
        uint256 _y2,
        uint256 _m
    )
        external
        pure
    {
        uint256 y1 = bound(
            _y1,
            0,
            MASK_80
        );

        uint256 y2 = bound(
            _y2,
            0,
            MASK_80
        );

        uint256 m = bound(
            _m,
            0,
            MASK_80
        );

        uint256 word = CohortWeeks.packLanes(
            y1,
            y2,
            m
        ) | CohortWeeks.CRUMB_WRITTEN_BIT;

        assertEq(
            CohortWeeks.laneY1(word),
            y1
        );

        assertEq(
            CohortWeeks.laneY2(word),
            y2
        );

        assertEq(
            CohortWeeks.laneM(word),
            m
        );
    }

    function testFuzz_saturatingAdd80_neverExceedsMaskAndConserves(
        uint256 _lane,
        uint256 _add
    )
        external
        pure
    {
        uint256 lane = bound(
            _lane,
            0,
            MASK_80
        );

        uint256 add = bound(
            _add,
            0,
            ADD_UPPER
        );

        (
            uint256 result,
            uint256 clipped
        ) = CohortWeeks.saturatingAdd80(
            lane,
            add
        );

        assertLe(
            result,
            MASK_80
        );

        assertEq(
            result + clipped,
            lane + add
        );

        if (lane + add > MASK_80) {
            assertGt(
                clipped,
                0
            );
        } else {
            assertEq(
                clipped,
                0
            );

            assertEq(
                result,
                lane + add
            );
        }
    }

    function testFuzz_saturatingAdd64_neverExceedsMaskAndConserves(
        uint256 _lane,
        uint256 _add
    )
        external
        pure
    {
        uint256 lane = bound(
            _lane,
            0,
            CohortWeeks.RING_LANE_MAX
        );

        uint256 add = bound(
            _add,
            0,
            ADD_UPPER
        );

        (
            uint256 result,
            uint256 clipped
        ) = CohortWeeks.saturatingAdd64(
            lane,
            add
        );

        assertLe(
            result,
            CohortWeeks.RING_LANE_MAX
        );

        assertEq(
            result + clipped,
            lane + add
        );

        if (lane + add > CohortWeeks.RING_LANE_MAX) {
            assertGt(
                clipped,
                0
            );
        } else {
            assertEq(
                clipped,
                0
            );

            assertEq(
                result,
                lane + add
            );
        }
    }

    function testFuzz_saturatingSub_floorsAtZeroAndConserves(
        uint256 _value,
        uint256 _sub
    )
        external
        pure
    {
        uint256 value = bound(
            _value,
            0,
            ADD_UPPER
        );

        uint256 sub = bound(
            _sub,
            0,
            ADD_UPPER
        );

        (
            uint256 result,
            uint256 clipped
        ) = CohortWeeks.saturatingSub(
            value,
            sub
        );

        if (sub <= value) {
            assertEq(
                result,
                value - sub
            );

            assertEq(
                clipped,
                0
            );
        } else {
            assertEq(
                result,
                0
            );

            assertEq(
                clipped,
                sub - value
            );
        }
    }

    function testFuzz_packLanes_isDisjointOr(
        uint256 _y1,
        uint256 _y2,
        uint256 _m
    )
        external
        pure
    {
        uint256 y1 = bound(
            _y1,
            0,
            MASK_80
        );

        uint256 y2 = bound(
            _y2,
            0,
            MASK_80
        );

        uint256 m = bound(
            _m,
            0,
            MASK_80
        );

        uint256 shiftedY2 = y2 << CohortWeeks.LANE_Y2_SHIFT;

        uint256 shiftedM = m << CohortWeeks.LANE_M_SHIFT;

        assertEq(
            CohortWeeks.packLanes(
                y1,
                y2,
                m
            ),
            y1 | shiftedY2 | shiftedM
        );

        assertEq(
            y1 & shiftedY2,
            0
        );

        assertEq(
            y1 & shiftedM,
            0
        );

        assertEq(
            shiftedY2 & shiftedM,
            0
        );
    }

    function test_constants_pinned()
        external
        pure
    {
        assertEq(
            CohortWeeks.WEEK,
            1 weeks
        );

        assertEq(
            CohortWeeks.RING_SLOTS,
            52
        );

        assertEq(
            CohortWeeks.YEAR,
            52 weeks
        );

        assertEq(
            CohortWeeks.MAX_SETTLE_BOUNDARIES,
            104
        );

        assertEq(
            CohortWeeks.LANE_MASK_80,
            (1 << 80) - 1
        );

        assertEq(
            CohortWeeks.CRUMB_WRITTEN_BIT,
            1 << 252
        );

        assertEq(
            CohortWeeks.CRUMB_VERSION,
            1
        );

        assertEq(
            CohortWeeks.RING_LANE_MAX,
            type(uint64).max
        );

        assertEq(
            CohortWeeks.LANE_Y2_SHIFT,
            80
        );

        assertEq(
            CohortWeeks.LANE_M_SHIFT,
            160
        );

        assertEq(
            CohortWeeks.GAP_TO_SHIFT,
            32
        );

        assertEq(
            CohortWeeks.GAP_MATURE_SHIFT,
            64
        );
    }
}
