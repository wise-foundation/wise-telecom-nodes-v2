// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {IReferralHub} from "../../src/hub/pending/IReferralHub.sol";
import {HubLeverGrants} from "./utils/HubLeverGrants.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";
import {CohortFlushCodec} from "../../src/diamond/shared/pending/CohortFlushCodec.sol";
import {HubDiamondHarness} from "../hub/utils/HubDiamondHarness.sol";
import {ReferralHubReader} from "../../src/hub/pending/ReferralHubReader.sol";
import {ReferralHubDeclarations} from "../../src/hub/pending/ReferralHubDeclarations.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";

/**
 * @dev Unit suite for {ReferralHubRates} on the actual deployed
 * {ReferralHub}. Pins the genesis rate table (thresholds
 * 5k/10k/20k/30k/50k/100k/500k/1M USD 6-dec, tiers 100..800 bps,
 * Year-1 rate = min(tier(self) + tier(referred), capBps) over the
 * week's own bucket) at every threshold edge, both below
 * and exactly at each rung, for the referred and self components
 * separately as well as summed and capped. Exercises the
 * append-only, future-only `pushRateTable` governance path (every
 * `InvalidRateTable`/`TableNotFuture`/`TableNotOrdered` revert arm,
 * a tier below the rung beneath it refused and two equal
 * neighbouring tiers accepted,
 * the lever ordering `capBps >= y2RateBps >= mRateBps` refusing a
 * year-2 rate above the cap and a mature rate above the year-2 rate
 * and accepting all three levers equal at the bps denominator, the
 * `BotShareTooHigh` arm of the courier share with its at-cap
 * acceptance and its genesis value of 500 bps, and the master
 * gate) and the property that a table can never
 * retroactively reprice a closed week, even after a later table lands
 * and its own effective week arrives. Year-2 and mature rates pay only
 * in weeks where the referrer's uncapped ladder sum reaches `capBps`:
 * the cap-gate battery pins at-cap, one-rung-below and above-cap
 * referrers against the genesis tail rates (500/100 bps), tables
 * with zero tail rates or a zero cap (whose tail rates the ordering
 * forces to zero, so it pays nothing in any lane), and a cap raise
 * closing the gate for future weeks while already-priced past weeks
 * keep their verdict.
 * A week's inputs are set after the week closed, through the reporter
 * surface: a crumb whose weekly average is the referred input and a self
 * run whose average is the self input, both for that week alone.
 * `weeklyRatesRange` is pinned element by element against
 * `weeklyRates` over a window that spans empty weeks, the genesis
 * tail rates and a pushed table's tail rates, so consecutive entries
 * differ in every lane. A zero count returns three empty arrays
 * without reverting. `ladderStandingOf` agrees with `ladderInputsAt`
 * and `weeklyRates` and reports the tier and next threshold of each
 * input: mid ladder, on the top tier (next threshold zero), below the
 * floor (tier zero, next the first threshold), an unreported week
 * reading zero, and a pushed table applying from its effective week
 * only.
 */
contract ReferralHubRatesTest is Test, HubDiamondHarness {

    event RateTableScheduled(
        uint256 indexed index,
        uint256 effectiveFromWeek
    );

    event ReferrerElevated(
        address indexed referrer,
        uint256 fromWeek
    );

    event ReferrerElevationEnded(
        address indexed referrer,
        uint256 untilWeek
    );

    uint256 internal constant WEEK = 1 weeks;

    uint256 internal constant BASE_WEEK = 3_000;

    uint256 internal constant BASE_TIME = BASE_WEEK * WEEK + 1 hours;

    address internal stranger = address(0xBEEF);

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

    function _setWeekInputs(
        address _referrer,
        uint256 _week,
        uint256 _referredAbs,
        uint256 _selfAbs
    )
        internal
    {
        if (_referredAbs > 0) {

            uint256[] memory weeksArr = new uint256[](1);

            weeksArr[0] = _week;

            uint256[] memory words = new uint256[](1);

            words[0] = CohortWeeks._packLanes(
                _referredAbs * WEEK,
                0,
                0
            );

            hub.deliverCrumbs(
                _referrer,
                _referrer,
                weeksArr,
                words
            );
        }

        if (_selfAbs > 0) {

            uint256[] memory runs = new uint256[](1);

            runs[0] = CohortFlushCodec._packSelfRun(
                _week,
                _week + 1,
                _selfAbs
            );

            hub.reportSelf(
                _referrer,
                runs
            );
        }
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

    function _validTable(
        uint32 _effectiveFromWeek
    )
        internal
        pure
        returns (ReferralHubDeclarations.RateTable memory table)
    {
        table.effectiveFromWeek = _effectiveFromWeek;
        table.capBps = 1_000;
        table.y2RateBps = 0;
        table.mRateBps = 0;
        table.botShareBps = 1_000;

        table.tierBps = [
            uint16(100),
            200,
            300,
            400,
            500,
            600,
            700,
            800
        ];

        table.thresholds = [
            uint96(5_000 * 1e6),
            10_000 * 1e6,
            20_000 * 1e6,
            30_000 * 1e6,
            50_000 * 1e6,
            100_000 * 1e6,
            500_000 * 1e6,
            1_000_000 * 1e6
        ];
    }

    function _tierOfClosedWeek(
        address _referrer,
        uint256 _referredAbs,
        uint256 _selfAbs
    )
        internal
        returns (uint256 y1Bps)
    {
        uint256 week = block.timestamp / WEEK;

        vm.warp(
            (week + 1) * WEEK + 1 hours
        );

        _setWeekInputs(
            _referrer,
            week,
            _referredAbs,
            _selfAbs
        );

        (
            y1Bps,
            ,
        ) = hub.weeklyRates(
            _referrer,
            week
        );
    }

    function _genesisTierBps(
        uint256 _value
    )
        internal
        pure
        returns (uint256 tier)
    {
        uint256[8] memory thresholds = [
            uint256(5_000 * 1e6),
            10_000 * 1e6,
            20_000 * 1e6,
            30_000 * 1e6,
            50_000 * 1e6,
            100_000 * 1e6,
            500_000 * 1e6,
            1_000_000 * 1e6
        ];

        uint256[8] memory tierBps = [
            uint256(100),
            200,
            300,
            400,
            500,
            600,
            700,
            800
        ];

        for (uint256 i; i < 8; ++i) {

            if (_value >= thresholds[i]) {
                tier = tierBps[i];
            }
        }
    }

    // ---- genesis table ----

    function test_rateTableAt_genesis_matchesLaunchLadder()
        public
        view
    {
        assertEq(
            hub.rateTableCount(),
            1
        );

        ReferralHubDeclarations.RateTable memory table = hub.rateTableAt(
            0
        );

        assertEq(
            table.effectiveFromWeek,
            0
        );

        assertEq(
            table.capBps,
            1_000
        );

        assertEq(
            table.y2RateBps,
            500
        );

        assertEq(
            table.mRateBps,
            100
        );

        assertEq(
            table.botShareBps,
            500
        );

        uint16[8] memory expectedTierBps = [
            uint16(100),
            200,
            300,
            400,
            500,
            600,
            700,
            800
        ];

        uint96[8] memory expectedThresholds = [
            uint96(5_000 * 1e6),
            10_000 * 1e6,
            20_000 * 1e6,
            30_000 * 1e6,
            50_000 * 1e6,
            100_000 * 1e6,
            500_000 * 1e6,
            1_000_000 * 1e6
        ];

        for (uint256 i; i < 8; ++i) {
            assertEq(
                table.tierBps[i],
                expectedTierBps[i]
            );

            assertEq(
                table.thresholds[i],
                expectedThresholds[i]
            );
        }
    }

    // ---- tier edges ----

    function test_weeklyRates_tierEdges_referredAlone_pinnedAtEachThreshold()
        public
    {
        uint256[8] memory thresholds = [
            uint256(5_000 * 1e6),
            10_000 * 1e6,
            20_000 * 1e6,
            30_000 * 1e6,
            50_000 * 1e6,
            100_000 * 1e6,
            500_000 * 1e6,
            1_000_000 * 1e6
        ];

        uint256[8] memory tierBps = [
            uint256(100),
            200,
            300,
            400,
            500,
            600,
            700,
            800
        ];

        for (uint256 k; k < 8; ++k) {

            address belowRef = address(uint160(0xA100 + k));
            address atRef = address(uint160(0xA200 + k));

            uint256 expectedBelow = k == 0
                ? 0
                : tierBps[k - 1];

            assertEq(
                _tierOfClosedWeek(
                    belowRef,
                    thresholds[k] - 1,
                    0
                ),
                expectedBelow
            );

            assertEq(
                _tierOfClosedWeek(
                    atRef,
                    thresholds[k],
                    0
                ),
                tierBps[k]
            );
        }
    }

    function test_weeklyRates_tierEdges_selfAlone_pinnedAtEachThreshold()
        public
    {
        uint256[8] memory thresholds = [
            uint256(5_000 * 1e6),
            10_000 * 1e6,
            20_000 * 1e6,
            30_000 * 1e6,
            50_000 * 1e6,
            100_000 * 1e6,
            500_000 * 1e6,
            1_000_000 * 1e6
        ];

        uint256[8] memory tierBps = [
            uint256(100),
            200,
            300,
            400,
            500,
            600,
            700,
            800
        ];

        for (uint256 k; k < 8; ++k) {

            address belowRef = address(uint160(0xA300 + k));
            address atRef = address(uint160(0xA400 + k));

            uint256 expectedBelow = k == 0
                ? 0
                : tierBps[k - 1];

            assertEq(
                _tierOfClosedWeek(
                    belowRef,
                    0,
                    thresholds[k] - 1
                ),
                expectedBelow
            );

            assertEq(
                _tierOfClosedWeek(
                    atRef,
                    0,
                    thresholds[k]
                ),
                tierBps[k]
            );
        }
    }

    function test_weeklyRates_sumOfTiers_capsAt1000Bps()
        public
    {
        address referrer = address(0xB1);

        uint256 y1Bps = _tierOfClosedWeek(
            referrer,
            1_000_000 * 1e6,
            1_000_000 * 1e6
        );

        assertEq(
            y1Bps,
            1_000
        );
    }

    function test_weeklyRates_bothBelowFloor_returnsZero()
        public
    {
        address referrer = address(0xB2);

        uint256 y1Bps = _tierOfClosedWeek(
            referrer,
            4_999_999_999,
            4_999_999_999
        );

        assertEq(
            y1Bps,
            0
        );
    }

    // ---- rate table governance ----

    function test_pushRateTable_happyPath_schedulesFutureTable()
        public
    {
        ReferralHubDeclarations.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 3)
        );

        table.capBps = 1_200;
        table.y2RateBps = 500;
        table.mRateBps = 250;

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(hub)
        );

        emit RateTableScheduled(
            1,
            BASE_WEEK + 3
        );

        hub.pushRateTable(
            table
        );

        assertEq(
            hub.rateTableCount(),
            2
        );

        ReferralHubDeclarations.RateTable memory stored = hub.rateTableAt(
            1
        );

        assertEq(
            stored.effectiveFromWeek,
            BASE_WEEK + 3
        );

        assertEq(
            stored.capBps,
            1_200
        );

        assertEq(
            stored.y2RateBps,
            500
        );

        assertEq(
            stored.mRateBps,
            250
        );
    }

    function test_pushRateTable_notFuture_reverts()
        public
    {
        ReferralHubDeclarations.RateTable memory table = _validTable(
            uint32(BASE_WEEK)
        );

        vm.expectRevert(
            ReferralHubDeclarations.TableNotFuture.selector
        );

        hub.pushRateTable(
            table
        );
    }

    function test_pushRateTable_notOrdered_reverts()
        public
    {
        ReferralHubDeclarations.RateTable memory first = _validTable(
            uint32(BASE_WEEK + 3)
        );

        hub.pushRateTable(
            first
        );

        ReferralHubDeclarations.RateTable memory second = _validTable(
            uint32(BASE_WEEK + 2)
        );

        vm.expectRevert(
            ReferralHubDeclarations.TableNotOrdered.selector
        );

        hub.pushRateTable(
            second
        );
    }

    function test_pushRateTable_beyondHorizon_reverts()
        public
    {
        ReferralHubDeclarations.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 521)
        );

        vm.expectRevert(
            ReferralHubDeclarations.WeekOutOfRange.selector
        );

        hub.pushRateTable(
            table
        );
    }

    function test_pushRateTable_atHorizon_schedules()
        public
    {
        ReferralHubDeclarations.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 520)
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(hub)
        );

        emit RateTableScheduled(
            1,
            BASE_WEEK + 520
        );

        hub.pushRateTable(
            table
        );

        assertEq(
            hub.rateTableCount(),
            2
        );

        assertEq(
            hub.rateTableAt(
                1
            ).effectiveFromWeek,
            BASE_WEEK + 520
        );
    }

    function test_pushRateTable_capBpsTooLarge_reverts()
        public
    {
        ReferralHubDeclarations.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 3)
        );

        table.capBps = 10_001;

        vm.expectRevert(
            ReferralHubDeclarations.InvalidRateTable.selector
        );

        hub.pushRateTable(
            table
        );
    }

    function test_pushRateTable_y2RateBpsTooLarge_reverts()
        public
    {
        ReferralHubDeclarations.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 3)
        );

        table.y2RateBps = 10_001;

        vm.expectRevert(
            ReferralHubDeclarations.InvalidRateTable.selector
        );

        hub.pushRateTable(
            table
        );
    }

    function test_pushRateTable_mRateBpsTooLarge_reverts()
        public
    {
        ReferralHubDeclarations.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 3)
        );

        table.mRateBps = 10_001;

        vm.expectRevert(
            ReferralHubDeclarations.InvalidRateTable.selector
        );

        hub.pushRateTable(
            table
        );
    }

    function test_pushRateTable_y2RateBpsAboveCapBps_reverts()
        public
    {
        ReferralHubDeclarations.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 3)
        );

        table.y2RateBps = 1_001;

        vm.expectRevert(
            ReferralHubDeclarations.InvalidRateTable.selector
        );

        hub.pushRateTable(
            table
        );
    }

    function test_pushRateTable_mRateBpsAboveY2RateBps_reverts()
        public
    {
        ReferralHubDeclarations.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 3)
        );

        table.y2RateBps = 500;
        table.mRateBps = 501;

        vm.expectRevert(
            ReferralHubDeclarations.InvalidRateTable.selector
        );

        hub.pushRateTable(
            table
        );
    }

    function test_pushRateTable_leversEqualAtDenominator_schedules()
        public
    {
        ReferralHubDeclarations.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 3)
        );

        table.capBps = 10_000;
        table.y2RateBps = 10_000;
        table.mRateBps = 10_000;

        hub.pushRateTable(
            table
        );

        assertEq(
            hub.rateTableCount(),
            2
        );

        ReferralHubDeclarations.RateTable memory stored = hub.rateTableAt(
            1
        );

        assertEq(
            stored.capBps,
            10_000
        );

        assertEq(
            stored.y2RateBps,
            10_000
        );

        assertEq(
            stored.mRateBps,
            10_000
        );
    }

    function test_pushRateTable_botShareAboveCap_reverts()
        public
    {
        ReferralHubDeclarations.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 3)
        );

        table.botShareBps = 2_001;

        vm.expectRevert(
            ReferralHubDeclarations.BotShareTooHigh.selector
        );

        hub.pushRateTable(
            table
        );
    }

    function test_pushRateTable_botShareAtCap_schedules()
        public
    {
        ReferralHubDeclarations.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 3)
        );

        table.botShareBps = 2_000;

        hub.pushRateTable(
            table
        );

        assertEq(
            hub.rateTableCount(),
            2
        );

        assertEq(
            hub.rateTableAt(
                1
            ).botShareBps,
            2_000
        );
    }

    function test_pushRateTable_tierBpsTooLarge_reverts()
        public
    {
        ReferralHubDeclarations.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 3)
        );

        table.tierBps[7] = 10_001;

        vm.expectRevert(
            ReferralHubDeclarations.InvalidRateTable.selector
        );

        hub.pushRateTable(
            table
        );
    }

    function test_pushRateTable_tierBpsDecreasing_reverts()
        public
    {
        ReferralHubDeclarations.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 3)
        );

        table.tierBps[3] = 250;

        vm.expectRevert(
            ReferralHubDeclarations.InvalidRateTable.selector
        );

        hub.pushRateTable(
            table
        );
    }

    function test_pushRateTable_tierBpsEqualNeighbours_schedules()
        public
    {
        ReferralHubDeclarations.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 3)
        );

        table.tierBps[3] = 300;

        hub.pushRateTable(
            table
        );

        assertEq(
            hub.rateTableCount(),
            2
        );

        assertEq(
            hub.rateTableAt(
                1
            ).tierBps[2],
            300
        );

        assertEq(
            hub.rateTableAt(
                1
            ).tierBps[3],
            300
        );
    }

    function test_pushRateTable_thresholdsNotIncreasing_reverts()
        public
    {
        ReferralHubDeclarations.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 3)
        );

        table.thresholds[3] = table.thresholds[2];

        vm.expectRevert(
            ReferralHubDeclarations.InvalidRateTable.selector
        );

        hub.pushRateTable(
            table
        );
    }

    function test_pushRateTable_thresholdZero_reverts()
        public
    {
        ReferralHubDeclarations.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 3)
        );

        table.thresholds[0] = 0;

        vm.expectRevert(
            ReferralHubDeclarations.InvalidRateTable.selector
        );

        hub.pushRateTable(
            table
        );
    }

    function test_pushRateTable_nonMaster_reverts()
        public
    {
        ReferralHubDeclarations.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 3)
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        hub.pushRateTable(
            table
        );
    }

    // ---- table churn ----

    function test_weeklyRates_pastWeek_immutableUnderTableChurn()
        public
    {
        address referrer = address(0xC1);

        vm.warp(
            BASE_TIME
        );

        ReferralHubDeclarations.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 3)
        );

        table.tierBps[4] = 510;

        hub.pushRateTable(
            table
        );

        _warpToWeek(
            5
        );

        _setWeekInputs(
            referrer,
            BASE_WEEK + 1,
            60_000 * 1e6,
            0
        );

        _setWeekInputs(
            referrer,
            BASE_WEEK + 4,
            60_000 * 1e6,
            0
        );

        (
            uint256 y1AtPlus1,
            ,
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK + 1
        );

        (
            uint256 y1AtPlus4,
            ,
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK + 4
        );

        assertEq(
            y1AtPlus1,
            500
        );

        assertEq(
            y1AtPlus4,
            510
        );
    }

    // ---- cap gate ----

    function test_weeklyRates_atCap_paysTailRates()
        public
    {
        address referrer = address(0xE1);

        _warpToWeek(
            1
        );

        _setWeekInputs(
            referrer,
            BASE_WEEK,
            1_000_000 * 1e6,
            10_000 * 1e6
        );

        (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK
        );

        assertEq(
            y1Bps,
            1_000
        );

        assertEq(
            y2Bps,
            500
        );

        assertEq(
            mBps,
            100
        );
    }

    function test_weeklyRates_oneRungBelowCap_noTailRates()
        public
    {
        address referrer = address(0xE2);

        _warpToWeek(
            1
        );

        _setWeekInputs(
            referrer,
            BASE_WEEK,
            1_000_000 * 1e6,
            5_000 * 1e6
        );

        (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK
        );

        assertEq(
            y1Bps,
            900
        );

        assertEq(
            y2Bps,
            0
        );

        assertEq(
            mBps,
            0
        );
    }

    function test_weeklyRates_aboveCap_paysTailRates()
        public
    {
        address referrer = address(0xE3);

        _warpToWeek(
            1
        );

        _setWeekInputs(
            referrer,
            BASE_WEEK,
            1_000_000 * 1e6,
            1_000_000 * 1e6
        );

        (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK
        );

        assertEq(
            y1Bps,
            1_000
        );

        assertEq(
            y2Bps,
            500
        );

        assertEq(
            mBps,
            100
        );
    }

    function test_weeklyRates_zeroTailTable_atCapPaysZeroTail()
        public
    {
        address referrer = address(0xE4);

        ReferralHubDeclarations.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 2)
        );

        hub.pushRateTable(
            table
        );

        _warpToWeek(
            3
        );

        _setWeekInputs(
            referrer,
            BASE_WEEK + 2,
            1_000_000 * 1e6,
            10_000 * 1e6
        );

        (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK + 2
        );

        assertEq(
            y1Bps,
            1_000
        );

        assertEq(
            y2Bps,
            0
        );

        assertEq(
            mBps,
            0
        );
    }

    function test_weeklyRates_zeroCapTable_paysNothing()
        public
    {
        address referrer = address(0xE5);

        ReferralHubDeclarations.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 2)
        );

        table.capBps = 0;

        hub.pushRateTable(
            table
        );

        _warpToWeek(
            3
        );

        _setWeekInputs(
            referrer,
            BASE_WEEK + 2,
            1_000_000 * 1e6,
            10_000 * 1e6
        );

        (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK + 2
        );

        assertEq(
            y1Bps,
            0
        );

        assertEq(
            y2Bps,
            0
        );

        assertEq(
            mBps,
            0
        );
    }

    function test_weeklyRates_capRaise_disqualifiesGoingForward()
        public
    {
        address referrer = address(0xE7);

        ReferralHubDeclarations.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 3)
        );

        table.capBps = 1_200;
        table.y2RateBps = 500;
        table.mRateBps = 100;

        hub.pushRateTable(
            table
        );

        _warpToWeek(
            1
        );

        _warpToWeek(
            5
        );

        _setWeekInputs(
            referrer,
            BASE_WEEK + 2,
            1_000_000 * 1e6,
            10_000 * 1e6
        );

        _setWeekInputs(
            referrer,
            BASE_WEEK + 3,
            1_000_000 * 1e6,
            10_000 * 1e6
        );

        (
            uint256 y1Before,
            uint256 y2Before,
            uint256 mBefore
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK + 2
        );

        (
            uint256 y1After,
            uint256 y2After,
            uint256 mAfter
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK + 3
        );

        assertEq(
            y1Before,
            1_000
        );

        assertEq(
            y2Before,
            500
        );

        assertEq(
            mBefore,
            100
        );

        assertEq(
            y1After,
            1_000
        );

        assertEq(
            y2After,
            0
        );

        assertEq(
            mAfter,
            0
        );

        (
            uint256 y1Replay,
            uint256 y2Replay,
            uint256 mReplay
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK + 2
        );

        assertEq(
            y1Replay,
            1_000
        );

        assertEq(
            y2Replay,
            500
        );

        assertEq(
            mReplay,
            100
        );
    }

    function test_weeklyRates_pushedTailRates_paidAtGateOpen()
        public
    {
        address referrer = address(0xE8);

        ReferralHubDeclarations.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 3)
        );

        table.y2RateBps = 600;
        table.mRateBps = 200;

        hub.pushRateTable(
            table
        );

        _warpToWeek(
            1
        );

        _warpToWeek(
            5
        );

        _setWeekInputs(
            referrer,
            BASE_WEEK + 2,
            1_000_000 * 1e6,
            10_000 * 1e6
        );

        _setWeekInputs(
            referrer,
            BASE_WEEK + 3,
            1_000_000 * 1e6,
            10_000 * 1e6
        );

        (
            uint256 y1Genesis,
            uint256 y2Genesis,
            uint256 mGenesis
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK + 2
        );

        (
            uint256 y1Pushed,
            uint256 y2Pushed,
            uint256 mPushed
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK + 3
        );

        assertEq(
            y1Genesis,
            1_000
        );

        assertEq(
            y2Genesis,
            500
        );

        assertEq(
            mGenesis,
            100
        );

        assertEq(
            y1Pushed,
            1_000
        );

        assertEq(
            y2Pushed,
            600
        );

        assertEq(
            mPushed,
            200
        );
    }

    function testFuzz_weeklyRates_capGate_matchesLocalLadder(
        uint256 _referredAbs,
        uint256 _selfAbs
    )
        public
    {
        _referredAbs = bound(
            _referredAbs,
            0,
            1_100_000 * 1e6
        );

        _selfAbs = bound(
            _selfAbs,
            0,
            1_100_000 * 1e6
        );

        address referrer = address(0xF1);

        _warpToWeek(
            3
        );

        _setWeekInputs(
            referrer,
            BASE_WEEK + 2,
            _referredAbs,
            _selfAbs
        );

        (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK + 2
        );

        uint256 ladderSum = _genesisTierBps(
            _referredAbs
        ) + _genesisTierBps(
            _selfAbs
        );

        assertEq(
            y1Bps,
            ladderSum > 1_000 ? 1_000 : ladderSum
        );

        assertEq(
            y2Bps,
            ladderSum >= 1_000 ? 500 : 0
        );

        assertEq(
            mBps,
            ladderSum >= 1_000 ? 100 : 0
        );
    }

    // ---- range view ----

    function test_weeklyRatesRange_matchesWeeklyRatesAcrossWindow()
        public
    {
        address referrer = address(0xE9);

        ReferralHubDeclarations.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 3)
        );

        table.y2RateBps = 600;
        table.mRateBps = 200;

        hub.pushRateTable(
            table
        );

        _warpToWeek(
            1
        );

        _warpToWeek(
            5
        );

        _setWeekInputs(
            referrer,
            BASE_WEEK + 2,
            1_000_000 * 1e6,
            10_000 * 1e6
        );

        _setWeekInputs(
            referrer,
            BASE_WEEK + 3,
            1_000_000 * 1e6,
            10_000 * 1e6
        );

        (
            uint256[] memory y1Range,
            uint256[] memory y2Range,
            uint256[] memory mRange
        ) = reader.weeklyRatesRange(
            referrer,
            BASE_WEEK,
            5
        );

        assertEq(
            y1Range.length,
            5
        );

        assertEq(
            y2Range.length,
            5
        );

        assertEq(
            mRange.length,
            5
        );

        for (uint256 i; i < 5; ++i) {

            (
                uint256 y1Single,
                uint256 y2Single,
                uint256 mSingle
            ) = hub.weeklyRates(
                referrer,
                BASE_WEEK + i
            );

            assertEq(
                y1Range[i],
                y1Single
            );

            assertEq(
                y2Range[i],
                y2Single
            );

            assertEq(
                mRange[i],
                mSingle
            );
        }

        assertEq(
            y1Range[1],
            0
        );

        assertEq(
            y2Range[1],
            0
        );

        assertEq(
            mRange[1],
            0
        );

        assertEq(
            y1Range[2],
            1_000
        );

        assertEq(
            y2Range[2],
            500
        );

        assertEq(
            mRange[2],
            100
        );

        assertEq(
            y1Range[3],
            1_000
        );

        assertEq(
            y2Range[3],
            600
        );

        assertEq(
            mRange[3],
            200
        );

        assertEq(
            y1Range[4],
            0
        );

        assertEq(
            y2Range[4],
            0
        );

        assertEq(
            mRange[4],
            0
        );
    }

    function test_weeklyRatesRange_zeroCount_returnsEmpty()
        public
        view
    {
        (
            uint256[] memory y1Range,
            uint256[] memory y2Range,
            uint256[] memory mRange
        ) = reader.weeklyRatesRange(
            address(0xE9),
            BASE_WEEK,
            0
        );

        assertEq(
            y1Range.length,
            0
        );

        assertEq(
            y2Range.length,
            0
        );

        assertEq(
            mRange.length,
            0
        );
    }

    // ---- reader ladder standing ----

    function _assertStandingMatchesHub(
        address _referrer,
        uint256 _week,
        ReferralHubReader.LadderStanding memory _standing
    )
        internal
        view
    {
        (
            uint256 referredInput,
            uint256 selfInput
        ) = hub.ladderInputsAt(
            _referrer,
            _week
        );

        (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        ) = hub.weeklyRates(
            _referrer,
            _week
        );

        assertEq(
            _standing.referredInput,
            referredInput
        );

        assertEq(
            _standing.selfInput,
            selfInput
        );

        assertEq(
            _standing.y1Bps,
            y1Bps
        );

        assertEq(
            _standing.y2Bps,
            y2Bps
        );

        assertEq(
            _standing.mBps,
            mBps
        );
    }

    function test_ladderStandingOf_genesisTable_tiersAndNextThresholds()
        public
    {
        address referrer = address(0xEA);

        _warpToWeek(
            1
        );

        _setWeekInputs(
            referrer,
            BASE_WEEK,
            25_000 * 1e6,
            7_000 * 1e6
        );

        ReferralHubReader.LadderStanding memory standing = reader.ladderStandingOf(
            referrer,
            BASE_WEEK
        );

        _assertStandingMatchesHub(
            referrer,
            BASE_WEEK,
            standing
        );

        assertEq(
            standing.referredInput,
            25_000 * 1e6
        );

        assertEq(
            standing.selfInput,
            7_000 * 1e6
        );

        assertEq(
            standing.referredTierBps,
            300
        );

        assertEq(
            standing.selfTierBps,
            100
        );

        assertEq(
            standing.nextReferredThreshold,
            30_000 * 1e6
        );

        assertEq(
            standing.nextSelfThreshold,
            10_000 * 1e6
        );

        assertEq(
            standing.y1Bps,
            400
        );
    }

    function test_ladderStandingOf_topTierAndBelowFloor()
        public
    {
        address referrer = address(0xEB);

        _warpToWeek(
            1
        );

        _setWeekInputs(
            referrer,
            BASE_WEEK,
            1_000_000 * 1e6,
            4_999 * 1e6
        );

        ReferralHubReader.LadderStanding memory standing = reader.ladderStandingOf(
            referrer,
            BASE_WEEK
        );

        _assertStandingMatchesHub(
            referrer,
            BASE_WEEK,
            standing
        );

        assertEq(
            standing.referredTierBps,
            800
        );

        assertEq(
            standing.nextReferredThreshold,
            0
        );

        assertEq(
            standing.selfTierBps,
            0
        );

        assertEq(
            standing.nextSelfThreshold,
            5_000 * 1e6
        );

        assertEq(
            standing.y1Bps,
            800
        );
    }

    function test_ladderStandingOf_currentWeek_readsZeroUntilReported()
        public
        view
    {
        ReferralHubReader.LadderStanding memory standing = reader.ladderStandingOf(
            address(0xEC),
            BASE_WEEK
        );

        assertEq(
            standing.referredInput,
            0
        );

        assertEq(
            standing.selfInput,
            0
        );

        assertEq(
            standing.referredTierBps,
            0
        );

        assertEq(
            standing.nextReferredThreshold,
            5_000 * 1e6
        );

        assertEq(
            standing.y1Bps,
            0
        );
    }

    function test_ladderStandingOf_pushedTable_appliesFromItsWeekOnly()
        public
    {
        address referrer = address(0xED);

        ReferralHubDeclarations.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 3)
        );

        table.tierBps = [
            uint16(150),
            250,
            350,
            450,
            550,
            650,
            750,
            850
        ];

        hub.pushRateTable(
            table
        );

        _warpToWeek(
            1
        );

        _warpToWeek(
            5
        );

        _setWeekInputs(
            referrer,
            BASE_WEEK + 2,
            25_000 * 1e6,
            7_000 * 1e6
        );

        _setWeekInputs(
            referrer,
            BASE_WEEK + 3,
            25_000 * 1e6,
            7_000 * 1e6
        );

        ReferralHubReader.LadderStanding memory before = reader.ladderStandingOf(
            referrer,
            BASE_WEEK + 2
        );

        ReferralHubReader.LadderStanding memory afterPush = reader.ladderStandingOf(
            referrer,
            BASE_WEEK + 3
        );

        _assertStandingMatchesHub(
            referrer,
            BASE_WEEK + 2,
            before
        );

        _assertStandingMatchesHub(
            referrer,
            BASE_WEEK + 3,
            afterPush
        );

        assertEq(
            before.referredTierBps,
            300
        );

        assertEq(
            before.selfTierBps,
            100
        );

        assertEq(
            afterPush.referredTierBps,
            350
        );

        assertEq(
            afterPush.selfTierBps,
            150
        );

        assertEq(
            afterPush.y1Bps,
            afterPush.referredTierBps + afterPush.selfTierBps
        );
    }
    // ---- elevation whitelist ----

    function _elevate(
        address _referrer,
        uint256 _fromWeek
    )
        internal
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.elevateReferrer,
                (
                    _referrer,
                    _fromWeek
                )
            )
        );
    }

    function test_elevateReferrer_grantWaitsTheLever_thenPricesAtCapFromItsWeek()
        public
    {
        address referrer = address(0xE1);

        vm.expectRevert(
            ReferralHubDeclarations.LeverChangeNotQueued.selector
        );

        hub.elevateReferrer(
            referrer,
            BASE_WEEK + 1
        );

        HubLeverGrants._queue(
            address(hub),
            abi.encodeCall(
                IReferralHub.elevateReferrer,
                (
                    referrer,
                    BASE_WEEK + 1
                )
            )
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(hub)
        );

        emit ReferrerElevated(
            referrer,
            BASE_WEEK + 1
        );

        hub.elevateReferrer(
            referrer,
            BASE_WEEK + 1
        );

        assertEq(
            hub.elevatedFromWeek(
                referrer
            ),
            BASE_WEEK + 1
        );

        assertEq(
            hub.elevatedUntilWeek(
                referrer
            ),
            0
        );

        _warpToWeek(
            3
        );

        _setWeekInputs(
            referrer,
            BASE_WEEK,
            4_000 * 1e6,
            0
        );

        _setWeekInputs(
            referrer,
            BASE_WEEK + 1,
            4_000 * 1e6,
            0
        );

        (
            uint256 y1Before,
            uint256 y2Before,
            uint256 mBefore
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK
        );

        assertEq(
            y1Before,
            0
        );

        assertEq(
            y2Before,
            0
        );

        assertEq(
            mBefore,
            0
        );

        (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK + 1
        );

        assertEq(
            y1Bps,
            1_000
        );

        assertEq(
            y2Bps,
            500
        );

        assertEq(
            mBps,
            100
        );

        (
            uint256 y1Later,
            ,
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK + 40
        );

        assertEq(
            y1Later,
            1_000
        );
    }

    function test_elevateReferrer_revertsOnZeroCurrentWeekOrOpenWindow()
        public
    {
        address referrer = address(0xE2);

        vm.expectRevert(
            ReferralHubDeclarations.ZeroAddress.selector
        );

        hub.elevateReferrer(
            address(0),
            BASE_WEEK + 1
        );

        HubLeverGrants._queue(
            address(hub),
            abi.encodeCall(
                IReferralHub.elevateReferrer,
                (
                    referrer,
                    BASE_WEEK
                )
            )
        );

        vm.expectRevert(
            ReferralHubDeclarations.ElevationNotFuture.selector
        );

        hub.elevateReferrer(
            referrer,
            BASE_WEEK
        );

        _elevate(
            referrer,
            BASE_WEEK + 1
        );

        HubLeverGrants._queue(
            address(hub),
            abi.encodeCall(
                IReferralHub.elevateReferrer,
                (
                    referrer,
                    BASE_WEEK + 2
                )
            )
        );

        vm.expectRevert(
            ReferralHubDeclarations.AlreadyElevated.selector
        );

        hub.elevateReferrer(
            referrer,
            BASE_WEEK + 2
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        hub.elevateReferrer(
            referrer,
            BASE_WEEK + 3
        );
    }

    function test_endElevation_instantFutureWeekOnly_windowEdgesAndRegrant()
        public
    {
        address referrer = address(0xE3);

        vm.expectRevert(
            ReferralHubDeclarations.NotElevated.selector
        );

        hub.endElevation(
            referrer,
            BASE_WEEK + 1
        );

        _elevate(
            referrer,
            BASE_WEEK + 1
        );

        _warpToWeek(
            2
        );

        vm.expectRevert(
            ReferralHubDeclarations.ElevationNotFuture.selector
        );

        hub.endElevation(
            referrer,
            BASE_WEEK + 2
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(hub)
        );

        emit ReferrerElevationEnded(
            referrer,
            BASE_WEEK + 3
        );

        hub.endElevation(
            referrer,
            BASE_WEEK + 3
        );

        _warpToWeek(
            5
        );

        for (uint256 week = BASE_WEEK; week < BASE_WEEK + 5; ++week) {
            _setWeekInputs(
                referrer,
                week,
                4_000 * 1e6,
                0
            );

            (
                uint256 y1Bps,
                ,
            ) = hub.weeklyRates(
                referrer,
                week
            );

            assertEq(
                y1Bps,
                week >= BASE_WEEK + 1 && week < BASE_WEEK + 3 ? 1_000 : 0
            );
        }

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        hub.endElevation(
            referrer,
            BASE_WEEK + 9
        );

        vm.expectRevert(
            ReferralHubDeclarations.NotElevated.selector
        );

        hub.endElevation(
            referrer,
            BASE_WEEK + 9
        );

        _elevate(
            referrer,
            BASE_WEEK + 7
        );

        assertEq(
            hub.elevatedUntilWeek(
                referrer
            ),
            0
        );

        (
            uint256 y1Regrant,
            ,
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK + 7
        );

        assertEq(
            y1Regrant,
            1_000
        );
    }

    function test_endElevation_paidWeekKeepsItsVerdict()
        public
    {
        address referrer = address(0xE4);

        _elevate(
            referrer,
            BASE_WEEK + 1
        );

        _warpToWeek(
            2
        );

        _setWeekInputs(
            referrer,
            BASE_WEEK + 1,
            4_000 * 1e6,
            0
        );

        uint256 paid = hub.claimable(
            block.chainid,
            referrer
        );

        assertEq(
            paid,
            4_000 * 1e6 * WEEK * 1_000 / (10_000 * CohortWeeks.YEAR)
        );

        hub.endElevation(
            referrer,
            BASE_WEEK + 3
        );

        hub.settleWeeks(
            referrer,
            BASE_WEEK + 1,
            1
        );

        assertEq(
            hub.claimable(
                block.chainid,
                referrer
            ),
            paid
        );
    }

    function test_ladderStandingOf_showsTheWindowAndTheNaturalTiers()
        public
    {
        address referrer = address(0xE5);

        _elevate(
            referrer,
            BASE_WEEK + 1
        );

        _warpToWeek(
            2
        );

        _setWeekInputs(
            referrer,
            BASE_WEEK + 1,
            25_000 * 1e6,
            7_000 * 1e6
        );

        ReferralHubReader.LadderStanding memory standing = reader.ladderStandingOf(
            referrer,
            BASE_WEEK + 1
        );

        assertTrue(
            standing.elevated
        );

        assertEq(
            standing.elevatedFromWeek,
            BASE_WEEK + 1
        );

        assertEq(
            standing.elevatedUntilWeek,
            0
        );

        assertEq(
            standing.referredTierBps,
            300
        );

        assertEq(
            standing.selfTierBps,
            100
        );

        assertEq(
            standing.y1Bps,
            1_000
        );

        assertEq(
            standing.y2Bps,
            500
        );

        ReferralHubReader.LadderStanding memory before = reader.ladderStandingOf(
            referrer,
            BASE_WEEK
        );

        assertFalse(
            before.elevated
        );
    }
}
