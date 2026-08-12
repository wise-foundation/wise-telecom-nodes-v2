// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {
    ReferralCommissionDemo,
    ReferralCommissionHookDemo
} from "./ReferralCommissionDemo.sol";

/**
 * @dev Crumb and gap-record suite for the per-vault recorder
 * {ReferralCommissionDemo} under the claim-at-hub architecture. A
 * crumb is one storage word per referrer per settled week: three
 * 80-bit token-seconds lanes (Y1 at shift 0, Y2 at 80, M at 160) plus
 * the written flag at bit 252 and NOTHING else — every full-word
 * assertion here is deliberately exact equality against
 * writtenBit | lanes so any stray bit in the 240..255 region fails
 * loudly. Covered: exact amount*WEEK lane weights across full weeks;
 * the lane shift as a cohort graduates Y1 -> Y2 at week 52 and
 * Y2 -> M at week 104; mid-week reductions splitting a week into
 * segments whose time-weights sum exactly; empty-book weeks writing
 * no crumb and no gap entry; partial-current-week lanes growing by
 * exactly balance*dt per settle with the written bit present before
 * the week closes; the dormant fast-forward gap record with its
 * 3-field packing (fromWeek | toWeekExclusive << 32 | mature << 64)
 * and empty rings afterwards; and a randomized-operation fuzz that a
 * finalized week's word never changes once lastSettle has crossed its
 * closing boundary. All expected values mirror the contract's integer
 * arithmetic exactly.
 */
contract ReferralCommissionCrumbsTest is Test {

    uint256 internal constant WEEK = 1 weeks;

    uint256 internal constant RING_SLOTS = 52;

    uint256 internal constant BASE_WEEK = 3_000;

    uint256 internal constant BASE_TIME = BASE_WEEK * WEEK;

    uint256 internal constant CRUMB_AMOUNT_MASK = (1 << 80) - 1;

    uint256 internal constant CRUMB_Y2_SHIFT = 80;

    uint256 internal constant CRUMB_M_SHIFT = 160;

    uint256 internal constant CRUMB_WRITTEN_BIT = 1 << 252;

    ReferralCommissionDemo internal token;

    ReferralCommissionHookDemo internal hook;

    address internal constant USER_A = address(0xA1);

    address internal constant USER_A2 = address(0xA2);

    address internal constant USER_C = address(0xC1);

    address internal constant REF_B = address(0xB1);

    address internal constant RANDO = address(0x51);

    event GapRecorded(
        address indexed referrer,
        uint256 fromWeek,
        uint256 toWeekExclusive,
        uint256 maturePrincipal
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

    function test_crumbs_fullWeeks_recordExactTimeWeights()
        public
    {
        _deposit(
            USER_A,
            10_000 * 1e6,
            REF_B
        );

        vm.warp(
            (BASE_WEEK + 1) * WEEK
        );

        _deposit(
            USER_A2,
            3_000 * 1e6,
            REF_B
        );

        vm.warp(
            (BASE_WEEK + 106) * WEEK
        );

        token.advanceBook(
            REF_B,
            60
        );

        token.advanceBook(
            REF_B,
            60
        );

        assertEq(token.weekLog(REF_B, BASE_WEEK + 106), 0);

        uint256 crumbFirst = token.weekLog(REF_B, BASE_WEEK + 52);

        assertEq(crumbFirst & CRUMB_AMOUNT_MASK, 3_000 * 1e6 * WEEK);
        assertEq((crumbFirst >> CRUMB_Y2_SHIFT) & CRUMB_AMOUNT_MASK, 10_000 * 1e6 * WEEK);
        assertEq((crumbFirst >> CRUMB_M_SHIFT) & CRUMB_AMOUNT_MASK, 0);
        assertTrue(crumbFirst & CRUMB_WRITTEN_BIT != 0);

        assertEq(
            token.weekLog(REF_B, BASE_WEEK + 51),
            CRUMB_WRITTEN_BIT | (13_000 * 1e6 * WEEK)
        );

        assertEq(
            crumbFirst,
            CRUMB_WRITTEN_BIT
                | (3_000 * 1e6 * WEEK)
                | ((10_000 * 1e6 * WEEK) << CRUMB_Y2_SHIFT)
        );

        assertEq(
            token.weekLog(REF_B, BASE_WEEK + 53),
            CRUMB_WRITTEN_BIT | ((13_000 * 1e6 * WEEK) << CRUMB_Y2_SHIFT)
        );

        assertEq(
            token.weekLog(REF_B, BASE_WEEK + 103),
            CRUMB_WRITTEN_BIT | ((13_000 * 1e6 * WEEK) << CRUMB_Y2_SHIFT)
        );

        assertEq(
            token.weekLog(REF_B, BASE_WEEK + 104),
            CRUMB_WRITTEN_BIT
                | ((3_000 * 1e6 * WEEK) << CRUMB_Y2_SHIFT)
                | ((10_000 * 1e6 * WEEK) << CRUMB_M_SHIFT)
        );

        assertEq(
            token.weekLog(REF_B, BASE_WEEK + 105),
            CRUMB_WRITTEN_BIT | ((13_000 * 1e6 * WEEK) << CRUMB_M_SHIFT)
        );

        assertEq(token.bookY1(REF_B), 0);
        assertEq(token.bookY2(REF_B), 0);
        assertEq(token.bookM(REF_B), 13_000 * 1e6);
    }

    function test_crumbs_graduation_shiftsLaneAcrossBoundaries()
        public
    {
        uint256 amount = 10_000 * 1e6;

        _deposit(
            USER_A,
            amount,
            REF_B
        );

        vm.warp(
            (BASE_WEEK + 106) * WEEK
        );

        token.advanceBook(
            REF_B,
            60
        );

        token.advanceBook(
            REF_B,
            60
        );

        assertEq(
            token.weekLog(REF_B, BASE_WEEK + 51),
            CRUMB_WRITTEN_BIT | (amount * WEEK)
        );

        assertEq(
            token.weekLog(REF_B, BASE_WEEK + 52),
            CRUMB_WRITTEN_BIT | ((amount * WEEK) << CRUMB_Y2_SHIFT)
        );

        assertEq(
            token.weekLog(REF_B, BASE_WEEK + 103),
            CRUMB_WRITTEN_BIT | ((amount * WEEK) << CRUMB_Y2_SHIFT)
        );

        assertEq(
            token.weekLog(REF_B, BASE_WEEK + 104),
            CRUMB_WRITTEN_BIT | ((amount * WEEK) << CRUMB_M_SHIFT)
        );

        assertEq(
            token.weekLog(REF_B, BASE_WEEK + 105),
            CRUMB_WRITTEN_BIT | ((amount * WEEK) << CRUMB_M_SHIFT)
        );
    }

    function test_crumbs_midWeekReduction_segmentsSumExactly()
        public
    {
        _deposit(
            USER_A,
            10_000 * 1e6,
            REF_B
        );

        vm.warp(
            (BASE_WEEK + 54) * WEEK
        );

        token.advanceBook(
            REF_B,
            104
        );

        assertEq(
            token.weekLog(REF_B, BASE_WEEK + 53),
            CRUMB_WRITTEN_BIT | ((10_000 * 1e6 * WEEK) << CRUMB_Y2_SHIFT)
        );

        vm.warp(
            (BASE_WEEK + 54) * WEEK + 3 days
        );

        vm.prank(
            USER_A
        );

        token.transfer(
            RANDO,
            4_000 * 1e6
        );

        token.syncReferee(
            USER_A
        );

        assertEq(
            token.weekLog(REF_B, BASE_WEEK + 54),
            CRUMB_WRITTEN_BIT | ((10_000 * 1e6 * 3 days) << CRUMB_Y2_SHIFT)
        );

        assertEq(token.bookY2(REF_B), 6_000 * 1e6);

        vm.warp(
            (BASE_WEEK + 55) * WEEK
        );

        token.advanceBook(
            REF_B,
            10
        );

        assertEq(
            token.weekLog(REF_B, BASE_WEEK + 54),
            CRUMB_WRITTEN_BIT
                | ((10_000 * 1e6 * 3 days + 6_000 * 1e6 * 4 days) << CRUMB_Y2_SHIFT)
        );
    }

    function test_crumbs_emptyBookWeeks_writeNoCrumb()
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
            10_000 * 1e6
        );

        assertEq(token.referralScore(REF_B), 0);

        vm.warp(
            (BASE_WEEK + 5) * WEEK
        );

        token.advanceBook(
            REF_B,
            104
        );

        for (uint256 i; i <= 5; ++i) {
            assertEq(token.weekLog(REF_B, BASE_WEEK + i), 0);
        }

        assertEq(token.lastSettle(REF_B), (BASE_WEEK + 5) * WEEK);
        assertEq(token.gapLogLength(REF_B), 0);

        vm.warp(
            (BASE_WEEK + 120) * WEEK
        );

        _deposit(
            USER_A,
            1_000 * 1e6,
            REF_B
        );

        assertEq(token.gapLogLength(REF_B), 0);
        assertEq(token.weekLog(REF_B, BASE_WEEK + 60), 0);
        assertEq(token.weekLog(REF_B, BASE_WEEK + 119), 0);
        assertEq(token.bookY1(REF_B), 1_000 * 1e6);
    }

    function test_crumbs_partialCurrentWeek_accumulatesIncrementally()
        public
    {
        _deposit(
            USER_A,
            10_000 * 1e6,
            REF_B
        );

        vm.warp(
            BASE_TIME + 2 days
        );

        vm.prank(
            USER_A
        );

        token.compound(
            2_000 * 1e6
        );

        assertEq(
            token.weekLog(REF_B, BASE_WEEK),
            CRUMB_WRITTEN_BIT | (10_000 * 1e6 * 2 days)
        );

        vm.warp(
            BASE_TIME + 5 days
        );

        vm.prank(
            USER_A
        );

        token.compound(
            1_000 * 1e6
        );

        assertEq(
            token.weekLog(REF_B, BASE_WEEK),
            CRUMB_WRITTEN_BIT
                | (10_000 * 1e6 * 2 days + 12_000 * 1e6 * 3 days)
        );

        vm.warp(
            (BASE_WEEK + 1) * WEEK + 1 days
        );

        token.advanceBook(
            REF_B,
            104
        );

        assertEq(
            token.weekLog(REF_B, BASE_WEEK),
            CRUMB_WRITTEN_BIT
                | (
                    10_000 * 1e6 * 2 days
                        + 12_000 * 1e6 * 3 days
                        + 13_000 * 1e6 * 2 days
                )
        );

        assertEq(token.weekLog(REF_B, BASE_WEEK + 1), 0);
    }

    function test_settle_fastForwardGap_recordsPackedGapEntry()
        public
    {
        _deposit(
            USER_A,
            5_000 * 1e6,
            REF_B
        );

        vm.warp(
            (BASE_WEEK + 204) * WEEK
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(token)
        );

        emit GapRecorded(
            REF_B,
            BASE_WEEK + 104,
            BASE_WEEK + 204,
            5_000 * 1e6
        );

        vm.prank(
            USER_A
        );

        token.moveBetweenVaultsExit(
            1
        );

        assertEq(token.gapLogLength(REF_B), 1);

        uint256 gap = token.gapLogEntry(REF_B, 0);

        assertEq(gap & type(uint32).max, BASE_WEEK + 104);
        assertEq((gap >> 32) & type(uint32).max, BASE_WEEK + 204);
        assertEq(gap >> 64, 5_000 * 1e6);

        assertEq(token.weekLog(REF_B, BASE_WEEK + 104), 0);
        assertEq(token.weekLog(REF_B, BASE_WEEK + 150), 0);
        assertEq(token.weekLog(REF_B, BASE_WEEK + 203), 0);

        assertEq(
            token.weekLog(REF_B, BASE_WEEK + 103),
            CRUMB_WRITTEN_BIT | ((5_000 * 1e6 * WEEK) << CRUMB_Y2_SHIFT)
        );

        for (uint256 slot; slot < RING_SLOTS; ++slot) {
            assertEq(token.ringYear1(REF_B, slot), 0);
            assertEq(token.ringYear2(REF_B, slot), 0);
        }

        assertEq(token.lastSettle(REF_B), (BASE_WEEK + 204) * WEEK);
        assertEq(token.bookM(REF_B), 5_000 * 1e6 - 1);
    }

    function testFuzz_crumbs_finalizedWeekWordNeverChanges(
        uint256 _seed
    )
        public
    {
        address[2] memory referees = [USER_A, USER_C];

        for (uint256 i; i < 12; ++i) {

            uint256 roll = uint256(
                keccak256(abi.encode(_seed, i))
            );

            address actor = referees[roll % 2];
            address other = referees[(roll + 1) % 2];

            uint256 op = (roll >> 8) % 5;
            uint256 raw = roll >> 16;

            if (op == 0) {
                vm.prank(
                    actor
                );

                token.depositWithReferral(
                    bound(raw, 1, 100_000 * 1e6),
                    REF_B
                );
            } else if (op == 1) {
                vm.prank(
                    actor
                );

                token.compound(
                    bound(raw, 1, 50_000 * 1e6)
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
                    other,
                    bound(raw, 1, balance)
                );
            } else if (op == 3) {
                vm.warp(
                    block.timestamp + bound(raw, 1 hours, 3 weeks)
                );

                token.advanceBook(
                    REF_B,
                    30
                );
            } else {
                token.syncReferee(
                    actor
                );
            }
        }

        vm.warp(
            block.timestamp + 2 * WEEK
        );

        _deposit(
            USER_A,
            1_000 * 1e6,
            REF_B
        );

        uint256 finalizedWeek = block.timestamp / WEEK - 1;

        uint256 word = token.weekLog(REF_B, finalizedWeek);

        _deposit(
            USER_C,
            5_000 * 1e6,
            REF_B
        );

        vm.prank(
            USER_A
        );

        token.transfer(
            USER_C,
            500 * 1e6
        );

        token.syncReferee(
            USER_A
        );

        vm.warp(
            block.timestamp + 3 weeks + 1 days
        );

        token.advanceBook(
            REF_B,
            104
        );

        _deposit(
            USER_A,
            1,
            REF_B
        );

        assertEq(
            token.weekLog(REF_B, finalizedWeek),
            word,
            "finalized crumb word changed after later operations"
        );
    }
}
