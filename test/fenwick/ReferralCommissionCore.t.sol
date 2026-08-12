// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ReferralTopDecile} from "./ReferralTopDecile.sol";
import {ReferralTokenDemo} from "./ReferralTokenDemo.sol";
import {
    ReferralCommissionDemo,
    ReferralCommissionHookDemo
} from "./ReferralCommissionDemo.sol";

/**
 * @dev Core-engine suite for {ReferralCommissionDemo}: deposit
 * crediting into ring slot, bookY1, contribution and score; exact
 * floor-rate accrual rectangles in raw token-bps-seconds units;
 * week-quantized cohort graduation across the year-1 and year-2
 * boundaries; newest-first book reduction and its ring1 -> ring2 ->
 * mature spill; the queue discredit / no-recredit / fulfill rules;
 * the lazy pre-transfer clamp timing; bounded {advanceBook}
 * pre-walking with no double-accrual; the mint-never-credits rule;
 * and a randomized-operation fuzz asserting after every operation
 * that sum of referee contributions == bookY1 + bookY2 + bookM ==
 * referralScore. True-up, breadcrumb and gap mechanics are out of
 * scope here. All expected values mirror the contract's integer
 * formulas exactly: accruedRaw += principal * bps * seconds and
 * claims mint accruedRaw / RAW_SCALE with the remainder retained.
 */
contract ReferralCommissionCoreTest is Test {

    uint256 internal constant WEEK = 1 weeks;

    uint256 internal constant RING_SLOTS = 52;

    uint256 internal constant RAW_SCALE = 52 weeks * 10_000;

    uint256 internal constant BASE_WEEK = 3_000;

    uint256 internal constant BASE_TIME = BASE_WEEK * WEEK;

    uint256 internal constant RATE_Y1 = 1_000;

    uint256 internal constant RATE_Y2_FLOOR = 300;

    uint256 internal constant RATE_Y2_TOP = 600;

    uint256 internal constant RATE_Y3_FLOOR = 100;

    uint256 internal constant RATE_Y3_TOP = 300;

    ReferralCommissionDemo internal token;

    ReferralCommissionHookDemo internal hook;

    address internal constant USER_A = address(0xA1);

    address internal constant USER_C = address(0xC1);

    address internal constant USER_D = address(0xD1);

    address internal constant REF_B = address(0xB1);

    address internal constant REF_B2 = address(0xB2);

    address internal constant OUTSIDER = address(0xE1);

    address internal constant BUYER = address(0xF1);

    event ReferralSet(
        address indexed user,
        address indexed referrer
    );

    event BookSettled(
        address indexed referrer,
        uint256 fromTimestamp,
        uint256 toTimestamp,
        uint256 boundariesWalked
    );

    event BookReduced(
        address indexed referrer,
        uint256 amount,
        uint256 fromYear1,
        uint256 fromYear2,
        uint256 fromMature
    );

    event CommissionClaimed(
        address indexed referrer,
        uint256 amount
    );

    event QueueJoined(
        address indexed user,
        uint256 amount
    );

    event QueueFulfilled(
        address indexed seller,
        address indexed buyer,
        uint256 amount
    );

    bytes32 internal constant REFERRAL_SET_TOPIC = keccak256(
        "ReferralSet(address,address)"
    );

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        token = new ReferralCommissionDemo();
        hook = new ReferralCommissionHookDemo();

        token.setTransferHook(
            address(hook)
        );

        token.setCommissionRates(
            RATE_Y1,
            RATE_Y1,
            RATE_Y2_FLOOR,
            RATE_Y2_TOP,
            RATE_Y3_FLOOR,
            RATE_Y3_TOP
        );
    }

    function _deposit(
        address _user,
        uint256 _amount,
        address _referrer
    )
        internal
    {
        vm.prank(
            _user
        );

        token.depositWithReferral(
            _amount,
            _referrer
        );
    }

    function _assertReferrerInvariant()
        internal
        view
    {
        uint256 bookTotal = token.bookY1(REF_B)
            + token.bookY2(REF_B)
            + token.bookM(REF_B);

        assertEq(
            token.referredContribution(USER_A) + token.referredContribution(USER_C),
            bookTotal,
            "contribution sum diverged from book total"
        );

        assertEq(
            bookTotal,
            token.referralScore(REF_B),
            "book total diverged from referral score"
        );
    }

    // ---- Deposit credit ----

    function test_depositWithReferral_creditsAllAccounts()
        public
    {
        uint256 amount = 10_000 * 1e6;

        uint256 slot = (block.timestamp / WEEK) % RING_SLOTS;

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(token)
        );

        emit ReferralSet(
            USER_A,
            REF_B
        );

        vm.prank(
            USER_A
        );

        token.depositWithReferral(
            amount,
            REF_B
        );

        assertEq(token.referrerOf(USER_A), REF_B);
        assertEq(token.ringYear1(REF_B, slot), amount);
        assertEq(token.bookY1(REF_B), amount);
        assertEq(token.referredContribution(USER_A), amount);
        assertEq(token.referralScore(REF_B), amount);
        assertEq(token.balanceOf(USER_A), amount);
    }

    function test_depositWithReferral_sameWeekDepositsShareOneRingSlot()
        public
    {
        uint256 slot = (block.timestamp / WEEK) % RING_SLOTS;

        _deposit(
            USER_A,
            4_000 * 1e6,
            REF_B
        );

        vm.warp(
            block.timestamp + 1 days
        );

        _deposit(
            USER_C,
            6_000 * 1e6,
            REF_B
        );

        assertEq(token.ringYear1(REF_B, slot), 10_000 * 1e6);
        assertEq(token.bookY1(REF_B), 10_000 * 1e6);
        assertEq(token.referralScore(REF_B), 10_000 * 1e6);
        assertEq(token.referredContribution(USER_A), 4_000 * 1e6);
        assertEq(token.referredContribution(USER_C), 6_000 * 1e6);
    }

    function test_depositWithReferral_secondDepositEmitsNoReferralSet()
        public
    {
        _deposit(
            USER_A,
            1_000 * 1e6,
            REF_B
        );

        vm.recordLogs();

        _deposit(
            USER_A,
            2_000 * 1e6,
            REF_B
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 found;

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == REFERRAL_SET_TOPIC) {
                ++found;
            }
        }

        assertEq(found, 0);
    }

    function test_depositWithReferral_revertsWhenZeroReferrer()
        public
    {
        vm.prank(
            USER_A
        );

        vm.expectRevert(
            ReferralTopDecile.ZeroAddress.selector
        );

        token.depositWithReferral(
            1_000 * 1e6,
            address(0)
        );

        _deposit(
            USER_A,
            1_000 * 1e6,
            REF_B
        );

        vm.prank(
            USER_A
        );

        vm.expectRevert(
            ReferralTopDecile.ZeroAddress.selector
        );

        token.depositWithReferral(
            1_000 * 1e6,
            address(0)
        );
    }

    function test_depositWithReferral_revertsWhenSelfReferral()
        public
    {
        vm.prank(
            USER_A
        );

        vm.expectRevert(
            ReferralCommissionDemo.SelfReferral.selector
        );

        token.depositWithReferral(
            1_000 * 1e6,
            USER_A
        );

        _deposit(
            USER_A,
            1_000 * 1e6,
            REF_B
        );

        vm.prank(
            USER_A
        );

        vm.expectRevert(
            ReferralCommissionDemo.SelfReferral.selector
        );

        token.depositWithReferral(
            1_000 * 1e6,
            USER_A
        );
    }

    function test_depositWithReferral_revertsWhenZeroAmount()
        public
    {
        vm.prank(
            USER_A
        );

        vm.expectRevert(
            ReferralTokenDemo.InvalidValue.selector
        );

        token.depositWithReferral(
            0,
            REF_B
        );
    }

    function test_depositWithReferral_secondReferrerIgnoredStillCreditsFirst()
        public
    {
        _deposit(
            USER_A,
            1_000 * 1e6,
            REF_B
        );

        _deposit(
            USER_A,
            2_000 * 1e6,
            REF_B2
        );

        assertEq(token.referrerOf(USER_A), REF_B);
        assertEq(token.referralScore(REF_B), 3_000 * 1e6);
        assertEq(token.bookY1(REF_B), 3_000 * 1e6);
        assertEq(token.referralScore(REF_B2), 0);
        assertEq(token.bookY1(REF_B2), 0);
    }

    // ---- Floor accrual rectangles ----

    function test_claimCommission_floorRectangleMintsExactAmount()
        public
    {
        uint256 amount = 100_000 * 1e6;

        _deposit(
            USER_A,
            amount,
            REF_B
        );

        vm.warp(
            block.timestamp + 10 * WEEK
        );

        uint256 expectedRaw = amount * RATE_Y1 * (10 * WEEK);

        uint256 expectedMint = expectedRaw / RAW_SCALE;

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(token)
        );

        emit CommissionClaimed(
            REF_B,
            expectedMint
        );

        vm.prank(
            REF_B
        );

        token.claimCommission();

        assertEq(token.balanceOf(REF_B), expectedMint);
        assertEq(token.accruedRaw(REF_B), expectedRaw - expectedMint * RAW_SCALE);
        assertGt(expectedRaw - expectedMint * RAW_SCALE, 0);
    }

    // ---- Graduation ----

    function test_graduation_movesCohortToYear2AtBoundary()
        public
    {
        uint256 amount = 10_000 * 1e6;

        uint256 slot = (block.timestamp / WEEK) % RING_SLOTS;

        _deposit(
            USER_A,
            amount,
            REF_B
        );

        vm.warp(
            BASE_TIME + 52 * WEEK + 1 hours
        );

        token.advanceBook(
            REF_B,
            104
        );

        assertEq(token.bookY1(REF_B), 0);
        assertEq(token.bookY2(REF_B), amount);
        assertEq(token.bookM(REF_B), 0);
        assertEq(token.ringYear1(REF_B, slot), 0);
        assertEq(token.ringYear2(REF_B, slot), amount);
        assertEq(token.referralScore(REF_B), amount);
        assertEq(token.accruedRaw(REF_B), amount * RATE_Y1 * (52 * WEEK));
    }

    function test_graduation_movesCohortToMatureAtSecondBoundary()
        public
    {
        uint256 amount = 10_000 * 1e6;

        uint256 slot = (block.timestamp / WEEK) % RING_SLOTS;

        _deposit(
            USER_A,
            amount,
            REF_B
        );

        vm.warp(
            BASE_TIME + 52 * WEEK + 1 hours
        );

        token.advanceBook(
            REF_B,
            104
        );

        vm.warp(
            BASE_TIME + 104 * WEEK + 1 hours
        );

        token.advanceBook(
            REF_B,
            104
        );

        assertEq(token.bookY1(REF_B), 0);
        assertEq(token.bookY2(REF_B), 0);
        assertEq(token.bookM(REF_B), amount);
        assertEq(token.ringYear2(REF_B, slot), 0);
        assertEq(token.referralScore(REF_B), amount);
        assertEq(
            token.accruedRaw(REF_B),
            amount * RATE_Y1 * (52 * WEEK) + amount * RATE_Y2_FLOOR * (52 * WEEK)
        );
    }

    function test_claimCommission_accrualAcrossGraduationIsWeekQuantized()
        public
    {
        uint256 amount = 100_000 * 1e6;

        vm.warp(
            BASE_TIME + 3 days
        );

        _deposit(
            USER_A,
            amount,
            REF_B
        );

        uint256 depositTime = block.timestamp;

        uint256 graduationTime = (BASE_WEEK + 52) * WEEK;

        vm.warp(
            graduationTime + 2 weeks + 12_345
        );

        uint256 expectedRaw = amount * RATE_Y1 * (graduationTime - depositTime)
            + amount * RATE_Y2_FLOOR * (block.timestamp - graduationTime);

        uint256 expectedMint = expectedRaw / RAW_SCALE;

        vm.prank(
            REF_B
        );

        token.claimCommission();

        assertEq(token.balanceOf(REF_B), expectedMint);
        assertEq(token.accruedRaw(REF_B), expectedRaw - expectedMint * RAW_SCALE);
        assertEq(token.bookY1(REF_B), 0);
        assertEq(token.bookY2(REF_B), amount);
    }

    // ---- Mixed-bucket rectangle ----

    function test_claimCommission_mixedBucketsRectangle()
        public
    {
        uint256 amountOld = 40_000 * 1e6;

        uint256 amountFresh = 25_000 * 1e6;

        _deposit(
            USER_A,
            amountOld,
            REF_B
        );

        vm.warp(
            BASE_TIME + 53 * WEEK
        );

        _deposit(
            USER_C,
            amountFresh,
            REF_B
        );

        vm.warp(
            block.timestamp + 4 * WEEK
        );

        uint256 expectedRaw = amountOld * RATE_Y1 * (52 * WEEK)
            + amountOld * RATE_Y2_FLOOR * (5 * WEEK)
            + amountFresh * RATE_Y1 * (4 * WEEK);

        uint256 expectedMint = expectedRaw / RAW_SCALE;

        vm.prank(
            REF_B
        );

        token.claimCommission();

        assertEq(token.balanceOf(REF_B), expectedMint);
        assertEq(token.accruedRaw(REF_B), expectedRaw - expectedMint * RAW_SCALE);
        assertEq(token.bookY1(REF_B), amountFresh);
        assertEq(token.bookY2(REF_B), amountOld);
    }

    // ---- Reduction ordering ----

    function test_syncReferee_consumesFreshSlotBeforeOldSlot()
        public
    {
        uint256 amountOld = 10_000 * 1e6;

        uint256 amountFresh = 5_000 * 1e6;

        uint256 oldSlot = (block.timestamp / WEEK) % RING_SLOTS;

        _deposit(
            USER_A,
            amountOld,
            REF_B
        );

        vm.warp(
            BASE_TIME + 30 * WEEK
        );

        uint256 freshSlot = (block.timestamp / WEEK) % RING_SLOTS;

        _deposit(
            USER_C,
            amountFresh,
            REF_B
        );

        vm.prank(
            USER_A
        );

        token.transfer(
            OUTSIDER,
            2_000 * 1e6
        );

        assertEq(token.bookY1(REF_B), 15_000 * 1e6);

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(token)
        );

        emit BookReduced(
            REF_B,
            2_000 * 1e6,
            2_000 * 1e6,
            0,
            0
        );

        token.syncReferee(
            USER_A
        );

        assertEq(token.ringYear1(REF_B, freshSlot), 3_000 * 1e6);
        assertEq(token.ringYear1(REF_B, oldSlot), amountOld);
        assertEq(token.bookY1(REF_B), 13_000 * 1e6);
        assertEq(token.referralScore(REF_B), 13_000 * 1e6);
        assertEq(token.referredContribution(USER_A), 8_000 * 1e6);
        assertEq(token.referredContribution(USER_C), amountFresh);
    }

    function test_syncReferee_reductionSpillsRingsThenMature()
        public
    {
        uint256 amountMature = 50_000 * 1e6;

        uint256 amountYear2 = 3_000 * 1e6;

        uint256 amountYear1 = 2_000 * 1e6;

        _deposit(
            USER_A,
            amountMature,
            REF_B
        );

        vm.warp(
            BASE_TIME + 53 * WEEK
        );

        _deposit(
            USER_C,
            amountYear2,
            REF_B
        );

        vm.warp(
            BASE_TIME + 105 * WEEK
        );

        _deposit(
            USER_D,
            amountYear1,
            REF_B
        );

        assertEq(token.bookY1(REF_B), amountYear1);
        assertEq(token.bookY2(REF_B), amountYear2);
        assertEq(token.bookM(REF_B), amountMature);

        vm.prank(
            USER_A
        );

        token.transfer(
            OUTSIDER,
            10_000 * 1e6
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(token)
        );

        emit BookReduced(
            REF_B,
            10_000 * 1e6,
            amountYear1,
            amountYear2,
            5_000 * 1e6
        );

        token.syncReferee(
            USER_A
        );

        assertEq(token.bookY1(REF_B), 0);
        assertEq(token.bookY2(REF_B), 0);
        assertEq(token.bookM(REF_B), 45_000 * 1e6);
        assertEq(token.referralScore(REF_B), 45_000 * 1e6);
        assertEq(token.referredContribution(USER_A), 40_000 * 1e6);
        assertEq(token.referredContribution(USER_C), amountYear2);
        assertEq(token.referredContribution(USER_D), amountYear1);
    }

    // ---- Queue ----

    function test_joinQue_discreditsImmediately()
        public
    {
        _deposit(
            USER_A,
            10_000 * 1e6,
            REF_B
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(token)
        );

        emit QueueJoined(
            USER_A,
            4_000 * 1e6
        );

        vm.prank(
            USER_A
        );

        token.joinQue(
            4_000 * 1e6
        );

        assertEq(token.queuedAmount(USER_A), 4_000 * 1e6);
        assertEq(token.balanceOf(USER_A), 6_000 * 1e6);
        assertEq(token.balanceOf(address(token)), 4_000 * 1e6);
        assertEq(token.referredContribution(USER_A), 6_000 * 1e6);
        assertEq(token.bookY1(REF_B), 6_000 * 1e6);
        assertEq(token.referralScore(REF_B), 6_000 * 1e6);
    }

    function test_leaveQue_returnsTokensWithoutRecredit()
        public
    {
        _deposit(
            USER_A,
            10_000 * 1e6,
            REF_B
        );

        vm.prank(
            USER_A
        );

        token.joinQue(
            4_000 * 1e6
        );

        vm.prank(
            USER_A
        );

        token.leaveQue();

        assertEq(token.queuedAmount(USER_A), 0);
        assertEq(token.balanceOf(USER_A), 10_000 * 1e6);
        assertEq(token.referredContribution(USER_A), 6_000 * 1e6);
        assertEq(token.bookY1(REF_B), 6_000 * 1e6);
        assertEq(token.referralScore(REF_B), 6_000 * 1e6);

        token.syncReferee(
            USER_A
        );

        assertEq(token.referredContribution(USER_A), 6_000 * 1e6);
        assertEq(token.referralScore(REF_B), 6_000 * 1e6);
    }

    function test_fulfillOrder_movesEscrowWithoutSellerCommissionChange()
        public
    {
        _deposit(
            USER_A,
            10_000 * 1e6,
            REF_B
        );

        vm.prank(
            USER_A
        );

        token.joinQue(
            4_000 * 1e6
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(token)
        );

        emit QueueFulfilled(
            USER_A,
            BUYER,
            4_000 * 1e6
        );

        token.fulfillOrder(
            USER_A,
            BUYER
        );

        assertEq(token.queuedAmount(USER_A), 0);
        assertEq(token.balanceOf(BUYER), 4_000 * 1e6);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.referredContribution(USER_A), 6_000 * 1e6);
        assertEq(token.bookY1(REF_B), 6_000 * 1e6);
        assertEq(token.referralScore(REF_B), 6_000 * 1e6);
        assertEq(token.referredContribution(BUYER), 0);
    }

    function test_leaveQue_revertsWhenNothingQueued()
        public
    {
        vm.prank(
            USER_A
        );

        vm.expectRevert(
            ReferralCommissionDemo.NothingQueued.selector
        );

        token.leaveQue();
    }

    function test_fulfillOrder_revertsWhenNothingQueued()
        public
    {
        vm.expectRevert(
            ReferralCommissionDemo.NothingQueued.selector
        );

        token.fulfillOrder(
            USER_A,
            BUYER
        );
    }

    // ---- Lazy transfer clamp ----

    function test_transfer_deficitLandsOnNextSyncNotThisTransfer()
        public
    {
        _deposit(
            USER_A,
            10_000 * 1e6,
            REF_B
        );

        vm.prank(
            USER_A
        );

        token.transfer(
            USER_C,
            3_000 * 1e6
        );

        assertEq(token.referredContribution(USER_A), 10_000 * 1e6);
        assertEq(token.bookY1(REF_B), 10_000 * 1e6);
        assertEq(token.referralScore(REF_B), 10_000 * 1e6);

        vm.prank(
            USER_A
        );

        token.transfer(
            USER_C,
            2_000 * 1e6
        );

        assertEq(token.referredContribution(USER_A), 7_000 * 1e6);
        assertEq(token.referralScore(REF_B), 7_000 * 1e6);

        token.syncReferee(
            USER_A
        );

        assertEq(token.referredContribution(USER_A), 5_000 * 1e6);
        assertEq(token.bookY1(REF_B), 5_000 * 1e6);
        assertEq(token.referralScore(REF_B), 5_000 * 1e6);
    }

    function test_moveBetweenVaultsExit_discreditsImmediately()
        public
    {
        _deposit(
            USER_A,
            10_000 * 1e6,
            REF_B
        );

        vm.prank(
            USER_A
        );

        token.moveBetweenVaultsExit(
            4_000 * 1e6
        );

        assertEq(token.balanceOf(USER_A), 6_000 * 1e6);
        assertEq(token.referredContribution(USER_A), 6_000 * 1e6);
        assertEq(token.bookY1(REF_B), 6_000 * 1e6);
        assertEq(token.referralScore(REF_B), 6_000 * 1e6);
    }

    // ---- advanceBook ----

    function test_advanceBook_walksExactlyRequestedBoundaries()
        public
    {
        uint256 amount = 10_000 * 1e6;

        _deposit(
            USER_A,
            amount,
            REF_B
        );

        vm.warp(
            BASE_TIME + 30 * WEEK + 1 days
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(token)
        );

        emit BookSettled(
            REF_B,
            BASE_TIME,
            BASE_TIME + 10 * WEEK,
            10
        );

        token.advanceBook(
            REF_B,
            10
        );

        assertEq(token.lastSettle(REF_B), BASE_TIME + 10 * WEEK);
        assertEq(token.accruedRaw(REF_B), amount * RATE_Y1 * (10 * WEEK));
    }

    function test_advanceBook_virginBookIsNoop()
        public
    {
        token.advanceBook(
            REF_B,
            10
        );

        assertEq(token.lastSettle(REF_B), 0);
        assertEq(token.accruedRaw(REF_B), 0);
    }

    function test_advanceBook_currentBookIsNoop()
        public
    {
        _deposit(
            USER_A,
            10_000 * 1e6,
            REF_B
        );

        token.advanceBook(
            REF_B,
            10
        );

        assertEq(token.lastSettle(REF_B), block.timestamp);
        assertEq(token.accruedRaw(REF_B), 0);
    }

    function test_advanceBook_thenFullSettleMatchesOneShotAccrual()
        public
    {
        uint256 amount = 10_000 * 1e6;

        _deposit(
            USER_A,
            amount,
            REF_B
        );

        vm.warp(
            BASE_TIME + 30 * WEEK + 1 days
        );

        token.advanceBook(
            REF_B,
            10
        );

        uint256 oneShotRaw = amount * RATE_Y1 * (30 * WEEK + 1 days);

        uint256 expectedMint = oneShotRaw / RAW_SCALE;

        vm.prank(
            REF_B
        );

        token.claimCommission();

        assertEq(token.balanceOf(REF_B), expectedMint);
        assertEq(token.accruedRaw(REF_B), oneShotRaw - expectedMint * RAW_SCALE);
        assertEq(token.lastSettle(REF_B), block.timestamp);
    }

    // ---- Mint driver ----

    function test_mint_neverCreditsContribution()
        public
    {
        _deposit(
            USER_A,
            10_000 * 1e6,
            REF_B
        );

        token.mint(
            USER_A,
            50_000 * 1e6
        );

        assertEq(token.referredContribution(USER_A), 10_000 * 1e6);
        assertEq(token.bookY1(REF_B), 10_000 * 1e6);
        assertEq(token.referralScore(REF_B), 10_000 * 1e6);

        token.syncReferee(
            USER_A
        );

        assertEq(token.referredContribution(USER_A), 10_000 * 1e6);
        assertEq(token.bookY1(REF_B), 10_000 * 1e6);
        assertEq(token.referralScore(REF_B), 10_000 * 1e6);
    }

    // ---- Invariant fuzz ----

    function testFuzz_invariant_contributionsMatchBooksAndScore(
        uint256 _seed
    )
        public
    {
        address[2] memory referees = [USER_A, USER_C];

        for (uint256 i; i < 16; ++i) {
            uint256 roll = uint256(
                keccak256(abi.encode(_seed, i))
            );

            address actor = referees[roll % 2];
            address other = referees[(roll + 1) % 2];

            uint256 op = (roll >> 8) % 6;
            uint256 raw = roll >> 16;

            if (op == 0) {
                vm.prank(
                    actor
                );

                token.depositWithReferral(
                    bound(raw, 1, 500_000 * 1e6),
                    REF_B
                );
            } else if (op == 1) {
                uint256 balance = token.balanceOf(actor);

                if (balance == 0) {
                    continue;
                }

                vm.prank(
                    actor
                );

                token.transfer(
                    other,
                    bound(raw, 1, balance)
                );
            } else if (op == 2) {
                uint256 balance = token.balanceOf(actor);

                if (balance == 0) {
                    continue;
                }

                vm.prank(
                    actor
                );

                token.transfer(
                    OUTSIDER,
                    bound(raw, 1, balance)
                );
            } else if (op == 3) {
                uint256 balance = token.balanceOf(actor);

                if (balance == 0) {
                    continue;
                }

                vm.prank(
                    actor
                );

                token.joinQue(
                    bound(raw, 1, balance)
                );
            } else if (op == 4) {
                if (token.queuedAmount(actor) == 0) {
                    continue;
                }

                vm.prank(
                    actor
                );

                token.leaveQue();
            } else {
                vm.warp(
                    block.timestamp + bound(raw, 1 hours, 6 weeks)
                );

                token.advanceBook(
                    REF_B,
                    20
                );

                token.syncReferee(
                    actor
                );
            }

            _assertReferrerInvariant();
        }
    }

    function test_rotate_afterReduction_graduatesRemainderWithoutUnderflow()
        public
    {
        uint256 amount = 10_000 * 1e6;

        uint256 slot = (block.timestamp / WEEK) % RING_SLOTS;

        _deposit(
            USER_A,
            amount,
            REF_B
        );

        vm.warp(
            BASE_TIME + 30 * WEEK
        );

        vm.prank(
            USER_A
        );

        token.transfer(
            OUTSIDER,
            4_000 * 1e6
        );

        token.syncReferee(
            USER_A
        );

        assertEq(token.ringYear1(REF_B, slot), 6_000 * 1e6);
        assertEq(token.bookY1(REF_B), 6_000 * 1e6);

        vm.warp(
            BASE_TIME + 53 * WEEK
        );

        token.advanceBook(
            REF_B,
            104
        );

        assertEq(token.ringYear1(REF_B, slot), 0);
        assertEq(token.ringYear2(REF_B, slot), 6_000 * 1e6);
        assertEq(token.bookY1(REF_B), 0);
        assertEq(token.bookY2(REF_B), 6_000 * 1e6);
        assertEq(token.bookM(REF_B), 0);

        vm.warp(
            BASE_TIME + 105 * WEEK
        );

        token.advanceBook(
            REF_B,
            104
        );

        assertEq(token.ringYear2(REF_B, slot), 0);
        assertEq(token.bookY2(REF_B), 0);
        assertEq(token.bookM(REF_B), 6_000 * 1e6);

        vm.prank(
            USER_A
        );

        token.transfer(
            OUTSIDER,
            5_000 * 1e6
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(token)
        );

        emit BookReduced(
            REF_B,
            5_000 * 1e6,
            0,
            0,
            5_000 * 1e6
        );

        token.syncReferee(
            USER_A
        );

        assertEq(token.bookM(REF_B), 1_000 * 1e6);
        assertEq(token.referralScore(REF_B), 1_000 * 1e6);
        assertEq(token.referredContribution(USER_A), 1_000 * 1e6);
    }
}
