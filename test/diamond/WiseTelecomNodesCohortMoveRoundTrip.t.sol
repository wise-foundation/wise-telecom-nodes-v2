// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {MoveFacet} from "../../src/diamond/vault/facets/MoveFacet.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";

import {TwoVaultCohortHarness} from "./utils/TwoVaultCohortHarness.sol";

/**
 * @dev Round-trip equivalence suite for the same-chain
 * attribution carry: moving A→B→A leaves the source
 * vault's referral schedule (rings, book lanes, tracked) byte-
 * identical to a world where the move never happened, which is the
 * age-reset-impossibility statement (replanted units graduate at the
 * exact boundary weeks they would have at home) and simultaneously
 * the wash-move-futility proof (a round trip achieves nothing and
 * costs gas). Controls are produced with `vm.snapshotState` /
 * `vm.revertToState`; both branches are settled to the same final
 * instant before comparison because rotation is settle-driven, while
 * `cohortLastSettle`, crumbs and the gap log stay excluded from the
 * equivalence set (honest per-vault history; the crumb conservation
 * test instead proves crumbA + crumbB equals the control crumb per
 * lane per finalized week). The partial-move test pins the
 * no-inflation cap: the destination gains exactly the walk output,
 * bounded by min(tracked, moved). The same-address property of
 * `moveBetweenVaults` (no recipient parameter exists; `mintFromPeer`
 * is always called with the mover) is pinned via the `MovedIn` event,
 * the invariant a future cross-chain bridge carry must replicate with
 * an
 * explicit recipient gate. The worst-case walk (all 104 ring slots
 * populated, full exit) gets a gas ceiling pin. Fuzz amounts stay
 * below the shipped `graceThresholdAmount` (10,000 units): a larger
 * deposit grace-stamps the user and `moveBetweenVaults` reverts
 * `GracePeriodNotElapsed` for 45 days, pre-existing product policy
 * the carry composes with, not a behavior of the carry itself.
 */
contract WiseTelecomNodesCohortMoveRoundTripTest is TwoVaultCohortHarness {

    event MovedIn(
        address indexed user,
        address indexed srcVault,
        uint256 amount
    );

    uint256 internal constant DEPOSIT = 5_000 * 1e6;

    uint256 internal constant WORST_CASE_MOVE_GAS_BUDGET = 3_000_000;

    address internal user1 = address(0xA1);

    address internal user2 = address(0xA2);

    address internal refA = address(0xB1);

    address internal outsider = address(0xC1);

    function setUp()
        public
    {
        _deployCohortPair();

        _armBoth();
    }

    // ---- helpers ----

    function _advanceBoth(
        address _referrer
    )
        internal
    {
        _recorderOf(vaultA).advanceBook(
            _referrer,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        _recorderOf(vaultB).advanceBook(
            _referrer,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );
    }

    // ---- same-block round trip ----

    function test_roundTrip_sameBlock_scheduleByteIdentical()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refA
        );

        vm.warp(
            block.timestamp + 10 weeks
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            2_000 * 1e6,
            refA
        );

        vm.warp(
            block.timestamp + 5 weeks
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            500 * 1e6,
            refA
        );

        CohortSnap memory origin = _captureCohort(
            vaultA,
            refA,
            user1
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            3_500 * 1e6
        );

        _moveAs(
            user1,
            vaultB,
            vaultA,
            3_500 * 1e6
        );

        CohortSnap memory finalA = _captureCohort(
            vaultA,
            refA,
            user1
        );

        _assertScheduleEq(
            finalA,
            origin
        );

        _assertScheduleEmpty(
            _captureCohort(
                vaultB,
                refA,
                user1
            )
        );
    }

    // ---- across week boundaries vs control ----

    function test_roundTrip_acrossWeekBoundary_scheduleMatchesControl()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 snapshot = vm.snapshotState();

        vm.warp(
            block.timestamp + 3 weeks
        );

        vm.warp(
            block.timestamp + 4 weeks
        );

        _recorderOf(vaultA).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        CohortSnap memory control = _captureCohort(
            vaultA,
            refA,
            user1
        );

        vm.revertToState(
            snapshot
        );

        vm.warp(
            block.timestamp + 3 weeks
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            DEPOSIT
        );

        vm.warp(
            block.timestamp + 4 weeks
        );

        _moveAs(
            user1,
            vaultB,
            vaultA,
            DEPOSIT
        );

        _recorderOf(vaultA).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        CohortSnap memory finalA = _captureCohort(
            vaultA,
            refA,
            user1
        );

        _assertScheduleEq(
            finalA,
            control
        );

        _assertScheduleEmpty(
            _captureCohort(
                vaultB,
                refA,
                user1
            )
        );
    }

    // ---- graduation happens away from home ----

    function test_roundTrip_acrossGraduation_slotPairCarriesY2()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 depositSlot = (block.timestamp / 1 weeks) % 52;

        uint256 snapshot = vm.snapshotState();

        vm.warp(
            block.timestamp + 60 weeks
        );

        _recorderOf(vaultA).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        CohortSnap memory control = _captureCohort(
            vaultA,
            refA,
            user1
        );

        vm.revertToState(
            snapshot
        );

        vm.warp(
            block.timestamp + 10 weeks
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            DEPOSIT
        );

        vm.warp(
            block.timestamp + 50 weeks
        );

        _moveAs(
            user1,
            vaultB,
            vaultA,
            DEPOSIT
        );

        _recorderOf(vaultA).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        CohortSnap memory finalA = _captureCohort(
            vaultA,
            refA,
            user1
        );

        assertEq(
            uint256(finalA.ring2[depositSlot]),
            DEPOSIT
        );

        assertEq(finalA.year2, DEPOSIT);

        assertEq(finalA.year1, 0);

        _assertScheduleEq(
            finalA,
            control
        );
    }

    // ---- crumb conservation ----

    function test_roundTrip_crumbConservation_perLanePerWeek()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 startWeek = block.timestamp / 1 weeks;

        uint256 snapshot = vm.snapshotState();

        vm.warp(
            block.timestamp + 2 weeks + 3 days
        );

        vm.warp(
            block.timestamp + 4 weeks - 3 days
        );

        _recorderOf(vaultA).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        uint256[6] memory controlCrumbs;

        for (uint256 i; i < 6; ++i) {
            controlCrumbs[i] = _recorderOf(vaultA).getCohortWeekCrumb(
                refA,
                startWeek + i
            );
        }

        vm.revertToState(
            snapshot
        );

        vm.warp(
            block.timestamp + 2 weeks + 3 days
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            2_500 * 1e6
        );

        vm.warp(
            block.timestamp + 4 weeks - 3 days
        );

        _recorderOf(vaultA).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        _recorderOf(vaultB).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        for (uint256 i; i < 6; ++i) {

            uint256 crumbA = _recorderOf(vaultA).getCohortWeekCrumb(
                refA,
                startWeek + i
            );

            uint256 crumbB = _recorderOf(vaultB).getCohortWeekCrumb(
                refA,
                startWeek + i
            );

            assertEq(
                CohortWeeks.laneY1(crumbA) + CohortWeeks.laneY1(crumbB),
                CohortWeeks.laneY1(controlCrumbs[i])
            );

            assertEq(
                CohortWeeks.laneY2(crumbA) + CohortWeeks.laneY2(crumbB),
                CohortWeeks.laneY2(controlCrumbs[i])
            );

            assertEq(
                CohortWeeks.laneM(crumbA) + CohortWeeks.laneM(crumbB),
                CohortWeeks.laneM(controlCrumbs[i])
            );
        }
    }

    // ---- partial move: exact walk output, no inflation ----

    function test_move_partial_walkOutputBoundedByMinTrackedMoved()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            3_000 * 1e6,
            refA
        );

        _depositOn(
            vaultA,
            user2,
            2_000 * 1e6
        );

        vm.prank(
            user2
        );

        vaultA.transfer(
            user1,
            2_000 * 1e6
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            4_000 * 1e6
        );

        assertEq(
            _recorderOf(vaultA).getTrackedContribution(user1),
            1_000 * 1e6
        );

        assertEq(
            _recorderOf(vaultA).getCohortScore(refA),
            1_000 * 1e6
        );

        assertEq(
            _recorderOf(vaultB).getTrackedContribution(user1),
            2_000 * 1e6
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refA),
            2_000 * 1e6
        );
    }

    // ---- same-address property (bridge-carry forward pin) ----

    function test_moveBetweenVaults_alwaysSameAddressBothEnds()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultB)
        );

        emit MovedIn(
            user1,
            address(vaultA),
            DEPOSIT
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            DEPOSIT
        );

        assertEq(
            vaultB.balanceOf(user1),
            DEPOSIT
        );

        assertEq(
            _recorderOf(vaultB).getTrackedContribution(user1),
            DEPOSIT
        );
    }

    // ---- fuzz: round trip vs control with warps + interleaves ----

    struct RoundTripRun {
        uint256 amount;
        uint256 warp1;
        uint256 warp2;
        uint256 interleave;
        uint256 snapshot;
        uint256 sojournBalance;
        CohortSnap control;
        CohortSnap finalA;
    }

    function testFuzz_roundTrip_scheduleEquivalentToControl(
        uint256 _amountSeed,
        uint256 _warp1Seed,
        uint256 _warp2Seed,
        uint256 _interleaveSeed
    )
        public
    {
        RoundTripRun memory run;

        run.amount = bound(
            _amountSeed,
            50 * 1e6,
            9_999 * 1e6
        );

        run.warp1 = bound(
            _warp1Seed,
            0,
            120 weeks
        );

        run.warp2 = bound(
            _warp2Seed,
            0,
            120 weeks
        );

        run.interleave = bound(
            _interleaveSeed,
            0,
            2
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            run.amount,
            refA
        );

        run.snapshot = vm.snapshotState();

        vm.warp(
            block.timestamp + run.warp1
        );

        _controlInterleave(
            run
        );

        vm.warp(
            block.timestamp + run.warp2
        );

        _recorderOf(vaultA).syncReferee(
            user1
        );

        _recorderOf(vaultA).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        run.control = _captureCohort(
            vaultA,
            refA,
            user1
        );

        vm.revertToState(
            run.snapshot
        );

        vm.warp(
            block.timestamp + run.warp1
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            run.amount
        );

        _moveInterleave(
            run
        );

        vm.warp(
            block.timestamp + run.warp2
        );

        run.sojournBalance = vaultB.balanceOf(
            user1
        );

        _moveAs(
            user1,
            vaultB,
            vaultA,
            run.sojournBalance
        );

        _recorderOf(vaultA).syncReferee(
            user1
        );

        _recorderOf(vaultA).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        run.finalA = _captureCohort(
            vaultA,
            refA,
            user1
        );

        _assertScheduleEq(
            run.finalA,
            run.control
        );

        _assertScheduleEmpty(
            _captureCohort(
                vaultB,
                refA,
                user1
            )
        );
    }

    function _controlInterleave(
        RoundTripRun memory _run
    )
        internal
    {
        if (_run.interleave == 1 || _run.interleave == 2) {
            _depositWithReferralOn(
                vaultA,
                user1,
                777 * 1e6,
                refA
            );
        }
    }

    function _moveInterleave(
        RoundTripRun memory _run
    )
        internal
    {
        if (_run.interleave == 1) {
            _depositWithReferralOn(
                vaultA,
                user1,
                777 * 1e6,
                refA
            );
        }

        if (_run.interleave == 2) {
            _depositWithReferralOn(
                vaultB,
                user1,
                777 * 1e6,
                refA
            );
        }
    }

    // ---- worst-case walk gas pin ----

    function test_moveGas_worstCase104Pairs_underBudget()
        public
    {
        for (uint256 i; i < 104; ++i) {

            _depositWithReferralOn(
                vaultA,
                user1,
                1_000 * 1e6,
                refA
            );

            vm.warp(
                block.timestamp + 1 weeks
            );
        }

        _recorderOf(vaultA).syncReferee(
            user1
        );

        uint256 balance = vaultA.balanceOf(
            user1
        );

        vm.prank(
            user1
        );

        uint256 gasBefore = gasleft();

        MoveFacet(address(vaultA)).moveBetweenVaults(
            address(vaultB),
            balance
        );

        uint256 gasUsed = gasBefore - gasleft();

        assertLt(
            gasUsed,
            WORST_CASE_MOVE_GAS_BUDGET
        );

        assertEq(
            _recorderOf(vaultA).getCohortScore(refA),
            0
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refA),
            104_000 * 1e6
        );
    }
}
