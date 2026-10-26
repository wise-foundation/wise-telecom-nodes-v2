// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {IReferralHub} from "../../src/hub/pending/IReferralHub.sol";
import {HubLeverGrants} from "./utils/HubLeverGrants.sol";
import {HubDiamondHarness} from "./utils/HubDiamondHarness.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";
import {CohortFlushCodec} from "../../src/diamond/shared/pending/CohortFlushCodec.sol";

/**
 * @dev Umbrella suite for the referral hub: one referral ladder over several
 * vault systems. Three hub sources stand for three vault systems on one
 * chain (`worldMobileSource` system 0, `sovrenSource` system 1,
 * `nextSystemSource` system 2) and a fourth (`laterSystemSource`, system
 * 7, the last tag below MAX_SYSTEMS) joins after the others delivered.
 * Covered: the referred and self inputs of a week are the SUM over every
 * source of every system (500k referred in one system plus 500k in another
 * reads as 1M, which a per-system maximum would read as 500k); the summed
 * inputs reach the genesis cap (1M referred is the 800 bps tier, 10k self
 * the 200 bps tier), which opens the year-2 and mature rates no single
 * system reaches alone; every source of the referrer is paid at that summed
 * rate once `settleWeeks` ran, whatever the delivery order; the system tag
 * never moves a price (the same deliveries under all-zero tags pay the
 * same); a system added later under its own tag lifts the shared ladder and
 * tops up the sources already paid (a report that raises the rates tops up
 * only its own source at once; `settleWeeks` tops up the rest). Every delivery names the referrer as
 * its deliverer (an own-book delivery), so no courier fee moves an asserted
 * amount. That no move or bridge peer ever joins two systems is a vault
 * configuration rule the hub cannot see; the preflight checks it per vault.
 */
contract ReferralHubUmbrellaTest is Test, HubDiamondHarness {

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant WEEK = CohortWeeks.WEEK;

    uint256 internal constant YEAR = CohortWeeks.YEAR;

    uint256 internal constant WRITTEN_BIT = CohortWeeks.CRUMB_WRITTEN_BIT;

    uint256 internal constant CAP_BPS = 1_000;

    uint256 internal constant Y2_GENESIS_BPS = 500;

    uint256 internal constant M_GENESIS_BPS = 100;

    uint256 internal constant TIER1_BPS = 100;

    uint256 internal constant TIER7_BPS = 700;

    uint256 internal constant HALF_A_MILLION = 500_000 * 1e6;

    uint256 internal constant ONE_MILLION = 1_000_000 * 1e6;

    uint256 internal constant SELF_HALF = 5_000 * 1e6;

    uint256 internal constant SELF_AT_CAP = 10_000 * 1e6;

    address internal refA = address(0xB1);

    address internal stranger = address(0xC1);

    address internal worldMobileSource = address(0xA1);

    address internal sovrenSource = address(0xA2);

    address internal nextSystemSource = address(0xA3);

    address internal laterSystemSource = address(0xA4);

    address internal usdToken = address(0xF01);

    IReferralHub internal hub;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        hub = _deployHub(
            usdToken
        );

        _allowReporter(
            worldMobileSource
        );

        _allowReporter(
            sovrenSource
        );

        _allowReporter(
            nextSystemSource
        );

        hub.setSourceSystem(
            _localSourceOf(
                sovrenSource
            ),
            1
        );

        hub.setSourceSystem(
            _localSourceOf(
                nextSystemSource
            ),
            2
        );
    }

    // ---- helpers ----

    function _allowReporter(
        address _reporter
    )
        internal
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    _reporter,
                    true
                )
            )
        );
    }

    function _localSourceOf(
        address _reporter
    )
        internal
        view
        returns (bytes32)
    {
        return hub.sourceKeyOf(
            block.chainid,
            _reporter
        );
    }

    function _closeWeek()
        internal
        returns (uint256 week)
    {
        week = block.timestamp / WEEK;

        vm.warp(
            (week + 1) * WEEK + 1 hours
        );
    }

    function _deliverReferredAs(
        address _reporter,
        uint256 _week,
        uint256 _y1,
        uint256 _y2,
        uint256 _m
    )
        internal
    {
        uint256[] memory weeks_ = new uint256[](1);

        uint256[] memory words_ = new uint256[](1);

        weeks_[0] = _week;
        words_[0] = CohortWeeks._packLanes(
            _y1,
            _y2,
            _m
        ) | WRITTEN_BIT;

        vm.prank(
            _reporter
        );

        hub.deliverCrumbs(
            refA,
            refA,
            weeks_,
            words_
        );
    }

    function _reportSelfAs(
        address _reporter,
        uint256 _week,
        uint256 _selfAverage
    )
        internal
    {
        uint256[] memory runs = new uint256[](1);

        runs[0] = CohortFlushCodec._packSelfRun(
            _week,
            _week + 1,
            _selfAverage
        );

        vm.prank(
            _reporter
        );

        hub.reportSelf(
            refA,
            runs
        );
    }

    function _dueAtCap(
        uint256 _y1,
        uint256 _y2,
        uint256 _m
    )
        internal
        pure
        returns (uint256)
    {
        return (
            _y1 * CAP_BPS
                + _y2 * Y2_GENESIS_BPS
                + _m * M_GENESIS_BPS
        ) / (10_000 * YEAR);
    }

    function _threeSystemDue()
        internal
        pure
        returns (uint256)
    {
        uint256 nextSystemDue = _dueAtCap(
            150_000 * 1e6 * WEEK,
            40_000 * 1e6 * WEEK,
            10_000 * 1e6 * WEEK
        );

        uint256 sovrenDue = _dueAtCap(
            200_000 * 1e6 * WEEK,
            80_000 * 1e6 * WEEK,
            20_000 * 1e6 * WEEK
        );

        uint256 worldMobileDue = _dueAtCap(
            300_000 * 1e6 * WEEK,
            150_000 * 1e6 * WEEK,
            50_000 * 1e6 * WEEK
        );

        return nextSystemDue
            + sovrenDue
            + worldMobileDue;
    }

    function _paidUnitsOf(
        address _reporter,
        uint256 _week
    )
        internal
        view
        returns (uint256 paidUnits)
    {
        (
            ,
            paidUnits
        ) = hub.weekReportOf(
            _localSourceOf(
                _reporter
            ),
            refA,
            _week
        );
    }

    function _assertRates(
        uint256 _week,
        uint256 _y1Bps,
        uint256 _y2Bps,
        uint256 _mBps
    )
        internal
        view
    {
        (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        ) = hub.weeklyRates(
            refA,
            _week
        );

        assertEq(
            y1Bps,
            _y1Bps
        );

        assertEq(
            y2Bps,
            _y2Bps
        );

        assertEq(
            mBps,
            _mBps
        );
    }

    function _assertInputs(
        uint256 _week,
        uint256 _referred,
        uint256 _self
    )
        internal
        view
    {
        (
            uint256 referredInput,
            uint256 selfInput
        ) = hub.ladderInputsAt(
            refA,
            _week
        );

        assertEq(
            referredInput,
            _referred
        );

        assertEq(
            selfInput,
            _self
        );
    }

    function _runThreeSystemWeek()
        internal
        returns (
            uint256 week,
            uint256 expected
        )
    {
        week = _closeWeek();

        _deliverReferredAs(
            nextSystemSource,
            week,
            150_000 * 1e6 * WEEK,
            40_000 * 1e6 * WEEK,
            10_000 * 1e6 * WEEK
        );

        _deliverReferredAs(
            sovrenSource,
            week,
            200_000 * 1e6 * WEEK,
            80_000 * 1e6 * WEEK,
            20_000 * 1e6 * WEEK
        );

        _deliverReferredAs(
            worldMobileSource,
            week,
            300_000 * 1e6 * WEEK,
            150_000 * 1e6 * WEEK,
            50_000 * 1e6 * WEEK
        );

        _reportSelfAs(
            worldMobileSource,
            week,
            5_000 * 1e6
        );

        _reportSelfAs(
            sovrenSource,
            week,
            3_000 * 1e6
        );

        _reportSelfAs(
            nextSystemSource,
            week,
            2_000 * 1e6
        );

        vm.prank(
            stranger
        );

        hub.settleWeeks(
            refA,
            week,
            1
        );

        expected = _threeSystemDue();
    }

    // ---- the ladder sums over systems ----

    function test_umbrella_halfAMillionInEachOfTwoSystems_countsAsOneMillion()
        public
    {
        uint256 week = _closeWeek();

        uint256 snapshot = vm.snapshotState();

        _deliverReferredAs(
            worldMobileSource,
            week,
            HALF_A_MILLION * WEEK,
            0,
            0
        );

        _reportSelfAs(
            worldMobileSource,
            week,
            SELF_HALF
        );

        _assertInputs(
            week,
            HALF_A_MILLION,
            SELF_HALF
        );

        _assertRates(
            week,
            TIER7_BPS + TIER1_BPS,
            0,
            0
        );

        vm.revertToState(
            snapshot
        );

        _deliverReferredAs(
            worldMobileSource,
            week,
            HALF_A_MILLION * WEEK,
            0,
            0
        );

        _deliverReferredAs(
            sovrenSource,
            week,
            HALF_A_MILLION * WEEK,
            0,
            0
        );

        _reportSelfAs(
            worldMobileSource,
            week,
            SELF_HALF
        );

        _reportSelfAs(
            sovrenSource,
            week,
            SELF_HALF
        );

        _assertInputs(
            week,
            ONE_MILLION,
            SELF_AT_CAP
        );

        _assertRates(
            week,
            CAP_BPS,
            Y2_GENESIS_BPS,
            M_GENESIS_BPS
        );

        assertEq(
            hub.sourceSystemOf(
                _localSourceOf(
                    worldMobileSource
                )
            ),
            0
        );

        assertEq(
            hub.sourceSystemOf(
                _localSourceOf(
                    sovrenSource
                )
            ),
            1
        );
    }

    function test_umbrella_threeSystems_everySourcePaidAtTheSummedRate()
        public
    {
        (
            uint256 week,
            uint256 expected
        ) = _runThreeSystemWeek();

        _assertInputs(
            week,
            ONE_MILLION,
            SELF_AT_CAP
        );

        _assertRates(
            week,
            CAP_BPS,
            Y2_GENESIS_BPS,
            M_GENESIS_BPS
        );

        assertEq(
            _paidUnitsOf(
                nextSystemSource,
                week
            ),
            _dueAtCap(
                150_000 * 1e6 * WEEK,
                40_000 * 1e6 * WEEK,
                10_000 * 1e6 * WEEK
            )
        );

        assertEq(
            _paidUnitsOf(
                sovrenSource,
                week
            ),
            _dueAtCap(
                200_000 * 1e6 * WEEK,
                80_000 * 1e6 * WEEK,
                20_000 * 1e6 * WEEK
            )
        );

        assertEq(
            _paidUnitsOf(
                worldMobileSource,
                week
            ),
            _dueAtCap(
                300_000 * 1e6 * WEEK,
                150_000 * 1e6 * WEEK,
                50_000 * 1e6 * WEEK
            )
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            expected
        );

        assertEq(
            hub.totalAccrued(),
            expected
        );

        hub.settleWeeks(
            refA,
            week,
            1
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            expected
        );
    }

    function test_umbrella_systemTagNeverMovesThePrice()
        public
    {
        uint256 snapshot = vm.snapshotState();

        (
            uint256 week,
            uint256 expected
        ) = _runThreeSystemWeek();

        uint256 taggedClaimable = hub.claimable(
            block.chainid,
            refA
        );

        vm.revertToState(
            snapshot
        );

        hub.setSourceSystem(
            _localSourceOf(
                sovrenSource
            ),
            0
        );

        hub.setSourceSystem(
            _localSourceOf(
                nextSystemSource
            ),
            0
        );

        (
            uint256 untaggedWeek,
            uint256 untaggedExpected
        ) = _runThreeSystemWeek();

        assertEq(
            untaggedWeek,
            week
        );

        assertEq(
            untaggedExpected,
            expected
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            taggedClaimable
        );

        assertEq(
            taggedClaimable,
            expected
        );

        _assertInputs(
            week,
            ONE_MILLION,
            SELF_AT_CAP
        );
    }

    function test_umbrella_systemAddedLater_joinsTheSameLadder()
        public
    {
        uint256 week = _closeWeek();

        _deliverReferredAs(
            worldMobileSource,
            week,
            300_000 * 1e6 * WEEK,
            150_000 * 1e6 * WEEK,
            50_000 * 1e6 * WEEK
        );

        _deliverReferredAs(
            sovrenSource,
            week,
            200_000 * 1e6 * WEEK,
            80_000 * 1e6 * WEEK,
            20_000 * 1e6 * WEEK
        );

        _reportSelfAs(
            worldMobileSource,
            week,
            5_000 * 1e6
        );

        _reportSelfAs(
            sovrenSource,
            week,
            3_000 * 1e6
        );

        _assertRates(
            week,
            TIER7_BPS + TIER1_BPS,
            0,
            0
        );

        uint256 before = hub.claimable(
            block.chainid,
            refA
        );

        assertEq(
            before,
            300_000 * 1e6 * WEEK
                * (TIER7_BPS + TIER1_BPS)
                / (10_000 * YEAR)
                + 200_000 * 1e6 * WEEK
                * TIER7_BPS
                / (10_000 * YEAR)
        );

        _allowReporter(
            laterSystemSource
        );

        hub.setSourceSystem(
            _localSourceOf(
                laterSystemSource
            ),
            hub.MAX_SYSTEMS() - 1
        );

        _deliverReferredAs(
            laterSystemSource,
            week,
            150_000 * 1e6 * WEEK,
            40_000 * 1e6 * WEEK,
            10_000 * 1e6 * WEEK
        );

        _reportSelfAs(
            laterSystemSource,
            week,
            2_000 * 1e6
        );

        _assertInputs(
            week,
            ONE_MILLION,
            SELF_AT_CAP
        );

        _assertRates(
            week,
            CAP_BPS,
            Y2_GENESIS_BPS,
            M_GENESIS_BPS
        );

        vm.prank(
            stranger
        );

        hub.settleWeeks(
            refA,
            week,
            1
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            _threeSystemDue()
        );

        assertEq(
            hub.sourceSystemOf(
                _localSourceOf(
                    laterSystemSource
                )
            ),
            7
        );

        assertEq(
            hub.sourceSystemOf(
                _localSourceOf(
                    sovrenSource
                )
            ),
            1
        );
    }
}
