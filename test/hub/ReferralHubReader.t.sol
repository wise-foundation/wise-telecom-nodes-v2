// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {IReferralHub} from "../../src/hub/pending/IReferralHub.sol";
import {HubLeverGrants} from "./utils/HubLeverGrants.sol";
import {HubDiamondHarness} from "../hub/utils/HubDiamondHarness.sol";
import {ReferralHubReader} from "../../src/hub/pending/ReferralHubReader.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";
import {CohortFlushCodec} from "../../src/diamond/shared/pending/CohortFlushCodec.sol";

/**
 * @dev Suite for the {ReferralHubReader} companion: the constructor
 * guard, the address-keyed `paidCursorAt` against the hub's
 * source-keyed view under the hub's own key derivation, and the week
 * bucket windows (`ladderInputsRange`, `weekReportsAtSource`) pinned
 * element by element against `ladderInputsAt` and `weekReportOf`,
 * empty weeks included, with a zero count returning empty arrays. The
 * other batch windows (`paidCursorsAtSource`, `claimableOf`,
 * `weeklyRatesRange`) are pinned against their single-value siblings
 * in the payout and rates suites, which call them through this reader.
 */
contract ReferralHubReaderTest is Test, HubDiamondHarness {

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant WEEK = CohortWeeks.WEEK;

    address internal refA = address(0xB1);

    address internal refB = address(0xB2);

    address internal reporter1 = address(0xD1);

    address internal reporter2 = address(0xD2);

    address internal usdToken = address(0xF01);

    IReferralHub internal hub;

    ReferralHubReader internal reader;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        hub = _deployHub(
            usdToken
        );

        reader = new ReferralHubReader(
            address(hub)
        );

        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    reporter1,
                    true
                )
            )
        );

        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    reporter2,
                    true
                )
            )
        );
    }

    // ---- constructor ----

    function test_constructor_storesHub()
        public
        view
    {
        assertEq(address(reader.HUB()), address(hub));
    }

    function test_RevertWhen_constructor_zeroHub()
        public
    {
        vm.expectRevert(
            ReferralHubReader.ZeroAddress.selector
        );

        new ReferralHubReader(
            address(0)
        );
    }

    // ---- address-keyed twins ----

    function test_paidCursorAt_matchesSourceKeyedView()
        public
    {
        uint256 week = block.timestamp / WEEK - 1;

        uint256[] memory weeksArr = new uint256[](1);
        weeksArr[0] = week;

        uint256[] memory words = new uint256[](1);
        words[0] = CohortWeeks._packLanes(
            11 * CohortWeeks.YEAR,
            22 * CohortWeeks.YEAR,
            33 * CohortWeeks.YEAR
        );

        vm.prank(
            reporter1
        );

        hub.deliverCrumbs(
            refA,
            refA,
            weeksArr,
            words
        );

        (
            uint256 y1Cursor,
            uint256 y2Cursor,
            uint256 mCursor
        ) = reader.paidCursorAt(
            reporter1,
            refA,
            week
        );

        (
            uint256 y1Keyed,
            uint256 y2Keyed,
            uint256 mKeyed
        ) = hub.paidCursorAtSource(
            hub.sourceKeyOf(
                block.chainid,
                reporter1
            ),
            refA,
            week
        );

        assertEq(y1Cursor, 11 * CohortWeeks.YEAR);
        assertEq(y2Cursor, 22 * CohortWeeks.YEAR);
        assertEq(mCursor, 33 * CohortWeeks.YEAR);
        assertEq(y1Cursor, y1Keyed);
        assertEq(y2Cursor, y2Keyed);
        assertEq(mCursor, mKeyed);
    }

    // ---- week bucket windows ----

    function test_ladderInputsRange_matchesLadderInputsAtEveryWeek()
        public
    {
        uint256 week = block.timestamp / WEEK;

        vm.warp(
            (week + 3) * WEEK + 1 hours
        );

        uint256[] memory weeksArr = new uint256[](2);

        weeksArr[0] = week;

        weeksArr[1] = week + 2;

        uint256[] memory words = new uint256[](2);

        words[0] = CohortWeeks._packLanes(
            7_000 * 1e6 * WEEK,
            0,
            0
        );

        words[1] = CohortWeeks._packLanes(
            9_000 * 1e6 * WEEK,
            0,
            0
        );

        vm.prank(
            reporter1
        );

        hub.deliverCrumbs(
            refA,
            refA,
            weeksArr,
            words
        );

        uint256[] memory runs = new uint256[](1);

        runs[0] = CohortFlushCodec._packSelfRun(
            week + 1,
            week + 3,
            20_000 * 1e6
        );

        vm.prank(
            reporter2
        );

        hub.reportSelf(
            refA,
            runs
        );

        (
            uint256[] memory referredInputs,
            uint256[] memory selfInputs
        ) = reader.ladderInputsRange(
            refA,
            week,
            4
        );

        assertEq(referredInputs.length, 4);
        assertEq(selfInputs.length, 4);

        for (uint256 i; i < 4; ++i) {

            (
                uint256 referredSingle,
                uint256 selfSingle
            ) = hub.ladderInputsAt(
                refA,
                week + i
            );

            assertEq(referredInputs[i], referredSingle);
            assertEq(selfInputs[i], selfSingle);
        }

        assertEq(referredInputs[0], 7_000 * 1e6);
        assertEq(referredInputs[1], 0);
        assertEq(referredInputs[2], 9_000 * 1e6);
        assertEq(selfInputs[0], 0);
        assertEq(selfInputs[1], 20_000 * 1e6);
        assertEq(selfInputs[2], 20_000 * 1e6);
        assertEq(selfInputs[3], 0);
    }

    function test_weekReportsAtSource_matchesWeekReportOfEveryWeek()
        public
    {
        uint256 week = block.timestamp / WEEK;

        vm.warp(
            (week + 2) * WEEK + 1 hours
        );

        uint256[] memory weeksArr = new uint256[](1);

        weeksArr[0] = week + 1;

        uint256[] memory words = new uint256[](1);

        words[0] = CohortWeeks._packLanes(
            12_000 * 1e6 * WEEK,
            0,
            0
        );

        vm.prank(
            reporter1
        );

        hub.deliverCrumbs(
            refA,
            refA,
            weeksArr,
            words
        );

        bytes32 source = hub.sourceKeyOf(
            block.chainid,
            reporter1
        );

        (
            uint256[] memory referredAverages,
            uint256[] memory paidUnits
        ) = reader.weekReportsAtSource(
            source,
            refA,
            week,
            2
        );

        assertEq(referredAverages.length, 2);
        assertEq(paidUnits.length, 2);

        for (uint256 i; i < 2; ++i) {

            (
                uint256 referredSingle,
                uint256 paidSingle
            ) = hub.weekReportOf(
                source,
                refA,
                week + i
            );

            assertEq(referredAverages[i], referredSingle);
            assertEq(paidUnits[i], paidSingle);
        }

        assertEq(referredAverages[0], 0);
        assertEq(referredAverages[1], 12_000 * 1e6);
        assertEq(paidUnits[1], hub.claimable(block.chainid, refA));
        assertGt(paidUnits[1], 0);
    }

    function test_rangeViews_zeroCount_returnEmpty()
        public
        view
    {
        (
            uint256[] memory referredInputs,
            uint256[] memory selfInputs
        ) = reader.ladderInputsRange(
            refA,
            3_000,
            0
        );

        (
            uint256[] memory referredAverages,
            uint256[] memory paidUnits
        ) = reader.weekReportsAtSource(
            bytes32(0),
            refA,
            3_000,
            0
        );

        assertEq(referredInputs.length, 0);
        assertEq(selfInputs.length, 0);
        assertEq(referredAverages.length, 0);
        assertEq(paidUnits.length, 0);
    }
}
