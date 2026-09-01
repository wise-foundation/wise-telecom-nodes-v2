// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {ReferralHub} from "../../src/hub/pending/ReferralHub.sol";
import {ReferralHubDeclarations} from "../../src/hub/pending/ReferralHubDeclarations.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";

/**
 * @dev Unit suite for {ReferralHubRates} on the actual deployed
 * {ReferralHub}. Pins the genesis rate table (thresholds
 * 5k/10k/20k/30k/50k/100k/500k/1M USD 6-dec, tiers 100..800 bps,
 * Year-1 rate = min(tier(self) + tier(referred), capBps) over the
 * dwell-min ladder inputs) at every threshold edge, both below
 * and exactly at each rung, for the referred and self components
 * separately as well as summed and capped. Exercises the
 * append-only, future-only `pushRateTable` governance path (every
 * `InvalidRateTable`/`TableNotFuture`/`TableNotOrdered` revert arm
 * and the master gate) and the property that a table can never
 * retroactively reprice a week whose opening boundary has already
 * passed, even after a later table lands and its own effective week
 * arrives. Year-2 and mature rates pay only in weeks where the
 * referrer's uncapped ladder sum reaches a nonzero `capBps`: the
 * cap-gate battery pins at-cap, one-rung-below and above-cap
 * referrers against the genesis tail rates (500/100 bps), tables
 * with zero tail rates or a zero cap, the dwell-min delay before an
 * at-cap report qualifies, and a cap raise closing the gate for
 * future weeks while already-priced past weeks keep their verdict.
 * Reported scores need a full two-week dwell before they price under
 * the default-on dwell-min knob, so every tier-edge assertion warps
 * two weeks past its report before reading `weeklyRates`.
 */
contract ReferralHubRatesTest is Test {

    event RateTableScheduled(
        uint256 indexed index,
        uint256 effectiveFromWeek
    );

    uint256 internal constant WEEK = 1 weeks;

    uint256 internal constant BASE_WEEK = 3_000;

    uint256 internal constant BASE_TIME = BASE_WEEK * WEEK + 1 hours;

    address internal stranger = address(0xBEEF);

    address internal usdToken = address(0xF01);

    ReferralHub internal hub;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        hub = new ReferralHub(
            usdToken
        );

        hub.setAllowedReporter(
            address(this),
            true
        );
    }

    // ---- helpers ----

    function _report(
        address _referrer,
        uint256 _referredAbs,
        uint256 _selfAbs
    )
        internal
    {
        hub.reportScores(
            _referrer,
            _referredAbs,
            _selfAbs
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

    function _validTable(
        uint32 _effectiveFromWeek
    )
        internal
        pure
        returns (ReferralHub.RateTable memory table)
    {
        table.effectiveFromWeek = _effectiveFromWeek;
        table.capBps = 1_000;
        table.y2RateBps = 0;
        table.mRateBps = 0;

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

    function _tierAfterDwell(
        address _referrer,
        uint256 _referredAbs,
        uint256 _selfAbs
    )
        internal
        returns (uint256 y1Bps)
    {
        uint256 reportWeek = block.timestamp / WEEK;

        _report(
            _referrer,
            _referredAbs,
            _selfAbs
        );

        vm.warp(
            block.timestamp + 2 * WEEK
        );

        (
            y1Bps,
            ,
        ) = hub.weeklyRates(
            _referrer,
            reportWeek + 2
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
        assertEq(hub.rateTableCount(), 1);

        ReferralHub.RateTable memory table = hub.rateTableAt(0);

        assertEq(table.effectiveFromWeek, 0);
        assertEq(table.capBps, 1_000);
        assertEq(table.y2RateBps, 500);
        assertEq(table.mRateBps, 100);

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
            assertEq(table.tierBps[i], expectedTierBps[i]);
            assertEq(table.thresholds[i], expectedThresholds[i]);
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
                _tierAfterDwell(belowRef, thresholds[k] - 1, 0),
                expectedBelow
            );

            assertEq(
                _tierAfterDwell(atRef, thresholds[k], 0),
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
                _tierAfterDwell(belowRef, 0, thresholds[k] - 1),
                expectedBelow
            );

            assertEq(
                _tierAfterDwell(atRef, 0, thresholds[k]),
                tierBps[k]
            );
        }
    }

    function test_weeklyRates_sumOfTiers_capsAt1000Bps()
        public
    {
        address referrer = address(0xB1);

        uint256 y1Bps = _tierAfterDwell(
            referrer,
            1_000_000 * 1e6,
            1_000_000 * 1e6
        );

        assertEq(y1Bps, 1_000);
    }

    function test_weeklyRates_bothBelowFloor_returnsZero()
        public
    {
        address referrer = address(0xB2);

        uint256 y1Bps = _tierAfterDwell(
            referrer,
            4_999_999_999,
            4_999_999_999
        );

        assertEq(y1Bps, 0);
    }

    // ---- rate table governance ----

    function test_pushRateTable_happyPath_schedulesFutureTable()
        public
    {
        ReferralHub.RateTable memory table = _validTable(
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

        assertEq(hub.rateTableCount(), 2);

        ReferralHub.RateTable memory stored = hub.rateTableAt(1);

        assertEq(stored.effectiveFromWeek, BASE_WEEK + 3);
        assertEq(stored.capBps, 1_200);
        assertEq(stored.y2RateBps, 500);
        assertEq(stored.mRateBps, 250);
    }

    function test_pushRateTable_notFuture_reverts()
        public
    {
        ReferralHub.RateTable memory table = _validTable(
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
        ReferralHub.RateTable memory first = _validTable(
            uint32(BASE_WEEK + 3)
        );

        hub.pushRateTable(
            first
        );

        ReferralHub.RateTable memory second = _validTable(
            uint32(BASE_WEEK + 2)
        );

        vm.expectRevert(
            ReferralHubDeclarations.TableNotOrdered.selector
        );

        hub.pushRateTable(
            second
        );
    }

    function test_pushRateTable_capBpsTooLarge_reverts()
        public
    {
        ReferralHub.RateTable memory table = _validTable(
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
        ReferralHub.RateTable memory table = _validTable(
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
        ReferralHub.RateTable memory table = _validTable(
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

    function test_pushRateTable_tierBpsTooLarge_reverts()
        public
    {
        ReferralHub.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 3)
        );

        table.tierBps[3] = 10_001;

        vm.expectRevert(
            ReferralHubDeclarations.InvalidRateTable.selector
        );

        hub.pushRateTable(
            table
        );
    }

    function test_pushRateTable_thresholdsNotIncreasing_reverts()
        public
    {
        ReferralHub.RateTable memory table = _validTable(
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
        ReferralHub.RateTable memory table = _validTable(
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
        ReferralHub.RateTable memory table = _validTable(
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
            (BASE_WEEK - 2) * WEEK + 1 hours
        );

        _report(
            referrer,
            60_000 * 1e6,
            0
        );

        vm.warp(
            BASE_TIME
        );

        ReferralHub.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 3)
        );

        table.tierBps[4] = 510;

        hub.pushRateTable(
            table
        );

        _warpToWeek(5);

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

        assertEq(y1AtPlus1, 500);
        assertEq(y1AtPlus4, 510);
    }

    // ---- cap gate ----

    function test_weeklyRates_atCap_paysTailRates()
        public
    {
        address referrer = address(0xE1);

        _report(
            referrer,
            1_000_000 * 1e6,
            10_000 * 1e6
        );

        _warpToWeek(2);

        (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK + 2
        );

        assertEq(y1Bps, 1_000);
        assertEq(y2Bps, 500);
        assertEq(mBps, 100);
    }

    function test_weeklyRates_oneRungBelowCap_noTailRates()
        public
    {
        address referrer = address(0xE2);

        _report(
            referrer,
            1_000_000 * 1e6,
            5_000 * 1e6
        );

        _warpToWeek(2);

        (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK + 2
        );

        assertEq(y1Bps, 900);
        assertEq(y2Bps, 0);
        assertEq(mBps, 0);
    }

    function test_weeklyRates_aboveCap_paysTailRates()
        public
    {
        address referrer = address(0xE3);

        _report(
            referrer,
            1_000_000 * 1e6,
            1_000_000 * 1e6
        );

        _warpToWeek(2);

        (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK + 2
        );

        assertEq(y1Bps, 1_000);
        assertEq(y2Bps, 500);
        assertEq(mBps, 100);
    }

    function test_weeklyRates_zeroTailTable_atCapPaysZeroTail()
        public
    {
        address referrer = address(0xE4);

        _report(
            referrer,
            1_000_000 * 1e6,
            10_000 * 1e6
        );

        ReferralHub.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 2)
        );

        hub.pushRateTable(
            table
        );

        _warpToWeek(2);

        (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK + 2
        );

        assertEq(y1Bps, 1_000);
        assertEq(y2Bps, 0);
        assertEq(mBps, 0);
    }

    function test_weeklyRates_zeroCapTable_closesGate()
        public
    {
        address referrer = address(0xE5);

        _report(
            referrer,
            1_000_000 * 1e6,
            10_000 * 1e6
        );

        ReferralHub.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 2)
        );

        table.capBps = 0;
        table.y2RateBps = 500;
        table.mRateBps = 100;

        hub.pushRateTable(
            table
        );

        _warpToWeek(2);

        (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK + 2
        );

        assertEq(y1Bps, 0);
        assertEq(y2Bps, 0);
        assertEq(mBps, 0);
    }

    function test_weeklyRates_capGate_dwellMinDelaysQualification()
        public
    {
        address referrer = address(0xE6);

        _report(
            referrer,
            1_000_000 * 1e6,
            10_000 * 1e6
        );

        _warpToWeek(2);

        (
            uint256 y1AtPlus0,
            uint256 y2AtPlus0,
            uint256 mAtPlus0
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK
        );

        (
            uint256 y1AtPlus1,
            uint256 y2AtPlus1,
            uint256 mAtPlus1
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK + 1
        );

        (
            uint256 y1AtPlus2,
            uint256 y2AtPlus2,
            uint256 mAtPlus2
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK + 2
        );

        assertEq(y1AtPlus0, 0);
        assertEq(y2AtPlus0, 0);
        assertEq(mAtPlus0, 0);
        assertEq(y1AtPlus1, 0);
        assertEq(y2AtPlus1, 0);
        assertEq(mAtPlus1, 0);
        assertEq(y1AtPlus2, 1_000);
        assertEq(y2AtPlus2, 500);
        assertEq(mAtPlus2, 100);
    }

    function test_weeklyRates_capRaise_disqualifiesGoingForward()
        public
    {
        address referrer = address(0xE7);

        _report(
            referrer,
            1_000_000 * 1e6,
            10_000 * 1e6
        );

        ReferralHub.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 3)
        );

        table.capBps = 1_200;
        table.y2RateBps = 500;
        table.mRateBps = 100;

        hub.pushRateTable(
            table
        );

        _warpToWeek(5);

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

        assertEq(y1Before, 1_000);
        assertEq(y2Before, 500);
        assertEq(mBefore, 100);
        assertEq(y1After, 1_000);
        assertEq(y2After, 0);
        assertEq(mAfter, 0);

        (
            uint256 y1Replay,
            uint256 y2Replay,
            uint256 mReplay
        ) = hub.weeklyRates(
            referrer,
            BASE_WEEK + 2
        );

        assertEq(y1Replay, 1_000);
        assertEq(y2Replay, 500);
        assertEq(mReplay, 100);
    }

    function test_weeklyRates_pushedTailRates_paidAtGateOpen()
        public
    {
        address referrer = address(0xE8);

        _report(
            referrer,
            1_000_000 * 1e6,
            10_000 * 1e6
        );

        ReferralHub.RateTable memory table = _validTable(
            uint32(BASE_WEEK + 3)
        );

        table.y2RateBps = 600;
        table.mRateBps = 200;

        hub.pushRateTable(
            table
        );

        _warpToWeek(5);

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

        assertEq(y1Genesis, 1_000);
        assertEq(y2Genesis, 500);
        assertEq(mGenesis, 100);
        assertEq(y1Pushed, 1_000);
        assertEq(y2Pushed, 600);
        assertEq(mPushed, 200);
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

        _report(
            referrer,
            _referredAbs,
            _selfAbs
        );

        _warpToWeek(2);

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

        assertEq(y1Bps, ladderSum > 1_000 ? 1_000 : ladderSum);
        assertEq(y2Bps, ladderSum >= 1_000 ? 500 : 0);
        assertEq(mBps, ladderSum >= 1_000 ? 100 : 0);
    }
}
