// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {IReferralHub} from "../../src/hub/pending/IReferralHub.sol";
import {HubLeverGrants} from "./utils/HubLeverGrants.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";
import {HubDiamondHarness} from "../hub/utils/HubDiamondHarness.sol";
import {ReferralHubReader} from "../../src/hub/pending/ReferralHubReader.sol";

/**
 * @dev Pins of the elevation window history. A grant after an end appends
 * a window instead of replacing the ended one, so every week of an earlier
 * window keeps its verdict for good: a week already paid at the cap rates
 * is settled again without a change, a week of the ended window delivered
 * only after the re-grant is still priced at the cap, the mirrored getters
 * report the latest window, and the reader's standing follows the
 * effective rates. The sequence of the first test is the one the stateful
 * suite found: elevate from week W, pay week W at the cap, end at U above
 * W, elevate again from V at or above U.
 */
contract ReferralHubElevationHistoryTest is Test, HubDiamondHarness {

    uint256 internal constant WEEK = 1 weeks;

    uint256 internal constant BASE_WEEK = 3_000;

    uint256 internal constant BASE_TIME = BASE_WEEK * WEEK + 1 hours;

    uint256 internal constant REFERRED_ABS = 4_000 * 1e6;

    address internal constant REFERRER = address(0xE6);

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
                    address(this),
                    true
                )
            )
        );
    }

    // ---- helpers ----

    function _elevate(
        uint256 _fromWeek
    )
        internal
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.elevateReferrer,
                (
                    REFERRER,
                    _fromWeek
                )
            )
        );
    }

    function _deliverWeek(
        uint256 _week
    )
        internal
    {
        uint256[] memory weeksArr = new uint256[](1);

        weeksArr[0] = _week;

        uint256[] memory words = new uint256[](1);

        words[0] = CohortWeeks._packLanes(
            REFERRED_ABS * WEEK,
            0,
            0
        );

        hub.deliverCrumbs(
            REFERRER,
            REFERRER,
            weeksArr,
            words
        );
    }

    function _warpToWeek(
        uint256 _weekOffset
    )
        internal
    {
        vm.warp(
            (BASE_WEEK + _weekOffset) * WEEK + 1 hours
        );
    }

    function _capPaidForOneWeek()
        internal
        pure
        returns (uint256)
    {
        return REFERRED_ABS
            * WEEK
            * 1_000
            / (10_000 * CohortWeeks.YEAR);
    }

    function _assertWeekRates(
        uint256 _week,
        bool _elevated
    )
        internal
        view
    {
        (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        ) = hub.weeklyRates(
            REFERRER,
            _week
        );

        assertEq(
            y1Bps,
            _elevated ? 1_000 : 0
        );

        assertEq(
            y2Bps,
            _elevated ? 500 : 0
        );

        assertEq(
            mBps,
            _elevated ? 100 : 0
        );
    }

    // ---- pins ----

    function test_elevateReferrer_regrantAfterEndKeepsEveryEarlierWindowVerdict()
        public
    {
        _elevate(
            BASE_WEEK + 1
        );

        _warpToWeek(
            2
        );

        _deliverWeek(
            BASE_WEEK + 1
        );

        uint256 paid = hub.claimable(
            block.chainid,
            REFERRER
        );

        assertEq(
            paid,
            _capPaidForOneWeek()
        );

        hub.endElevation(
            REFERRER,
            BASE_WEEK + 4
        );

        _elevate(
            BASE_WEEK + 6
        );

        assertEq(
            hub.elevatedFromWeek(
                REFERRER
            ),
            BASE_WEEK + 6
        );

        assertEq(
            hub.elevatedUntilWeek(
                REFERRER
            ),
            0
        );

        for (uint256 week = BASE_WEEK; week < BASE_WEEK + 8; ++week) {
            _assertWeekRates(
                week,
                (week >= BASE_WEEK + 1 && week < BASE_WEEK + 4)
                    || week >= BASE_WEEK + 6
            );
        }

        hub.settleWeeks(
            REFERRER,
            BASE_WEEK + 1,
            1
        );

        assertEq(
            hub.claimable(
                block.chainid,
                REFERRER
            ),
            paid
        );

        _warpToWeek(
            3
        );

        _deliverWeek(
            BASE_WEEK + 2
        );

        assertEq(
            hub.claimable(
                block.chainid,
                REFERRER
            ),
            paid * 2
        );

        ReferralHubReader.LadderStanding memory standing = reader.ladderStandingOf(
            REFERRER,
            BASE_WEEK + 1
        );

        assertTrue(
            standing.elevated
        );

        assertEq(
            standing.y1Bps,
            1_000
        );

        assertEq(
            standing.referredTierBps,
            0
        );

        assertEq(
            standing.elevatedFromWeek,
            BASE_WEEK + 6
        );

        assertEq(
            standing.elevatedUntilWeek,
            0
        );

        ReferralHubReader.LadderStanding memory gap = reader.ladderStandingOf(
            REFERRER,
            BASE_WEEK + 5
        );

        assertFalse(
            gap.elevated
        );

        assertEq(
            gap.y1Bps,
            0
        );
    }

    function test_elevateReferrer_regrantBeforeTheEndWeekLeavesNoGap()
        public
    {
        _elevate(
            BASE_WEEK + 1
        );

        _warpToWeek(
            2
        );

        hub.endElevation(
            REFERRER,
            BASE_WEEK + 5
        );

        _elevate(
            BASE_WEEK + 3
        );

        for (uint256 week = BASE_WEEK; week < BASE_WEEK + 9; ++week) {
            _assertWeekRates(
                week,
                week >= BASE_WEEK + 1
            );
        }

        hub.endElevation(
            REFERRER,
            BASE_WEEK + 4
        );

        assertEq(
            hub.elevatedUntilWeek(
                REFERRER
            ),
            BASE_WEEK + 4
        );

        for (uint256 week = BASE_WEEK; week < BASE_WEEK + 9; ++week) {
            _assertWeekRates(
                week,
                week >= BASE_WEEK + 1 && week < BASE_WEEK + 5
            );
        }
    }
}
