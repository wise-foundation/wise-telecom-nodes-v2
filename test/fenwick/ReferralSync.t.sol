// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {
    ReferralSyncTokenDemo,
    ReferralSyncHookDemo
} from "./ReferralSyncTokenDemo.sol";

/**
 * @dev Unit and wide-range fuzz suite for the lazy-sync mechanism.
 * The tight-bound dual-engine lemmas proven by Kontrol live in
 * {ReferralSyncProperties.t.sol}; this file covers the concrete
 * scenario traces (wash cycle, deficit-caught-later, to-side sync,
 * immediate exit discredit) and a wide-amount randomized-operation
 * fuzz asserting the monotonicity theorem across arbitrary buckets.
 */
contract ReferralSyncTest is Test {

    uint256 internal constant MIN_SCORE = 1_000 * 1e6;

    ReferralSyncTokenDemo internal token;

    ReferralSyncHookDemo internal hook;

    address internal constant USER_A = address(0xA1);

    address internal constant USER_C = address(0xC1);

    address internal constant REF_B = address(0xB1);

    address internal constant REF_B2 = address(0xB2);

    function setUp()
        public
    {
        token = new ReferralSyncTokenDemo();
        hook = new ReferralSyncHookDemo();

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

    function test_washCycle_doesNotInflateScore()
        public
    {
        _deposit(
            USER_A,
            100_000 * 1e6,
            REF_B
        );

        vm.prank(
            USER_A
        );

        token.transfer(
            USER_C,
            100_000 * 1e6
        );

        _deposit(
            USER_A,
            100_000 * 1e6,
            REF_B
        );

        assertEq(token.referralScore(REF_B), 100_000 * 1e6);
        assertEq(token.referredContribution(USER_A), 100_000 * 1e6);
        assertEq(
            token.referredContribution(USER_A),
            token.balanceOf(USER_A)
        );
    }

    function test_transfer_deficitCaughtByPoke()
        public
    {
        _deposit(
            USER_A,
            100_000 * 1e6,
            REF_B
        );

        vm.prank(
            USER_A
        );

        token.transfer(
            USER_C,
            40_000 * 1e6
        );

        assertEq(token.referredContribution(USER_A), 100_000 * 1e6);
        assertEq(token.referralScore(REF_B), 100_000 * 1e6);

        token.syncReferee(
            USER_A
        );

        assertEq(token.referredContribution(USER_A), 60_000 * 1e6);
        assertEq(token.referralScore(REF_B), 60_000 * 1e6);

        token.syncReferee(
            USER_A
        );

        assertEq(token.referredContribution(USER_A), 60_000 * 1e6);
    }

    function test_hook_syncsToSideOnReceive()
        public
    {
        _deposit(
            USER_C,
            50_000 * 1e6,
            REF_B2
        );

        vm.prank(
            USER_C
        );

        token.moveBetweenVaultsExit(
            20_000 * 1e6
        );

        _deposit(
            USER_A,
            10_000 * 1e6,
            REF_B
        );

        vm.prank(
            USER_C
        );

        token.transfer(
            USER_A,
            30_000 * 1e6
        );

        assertEq(token.referredContribution(USER_C), 30_000 * 1e6);
        assertEq(token.referralScore(REF_B2), 30_000 * 1e6);
        assertEq(token.referredContribution(USER_A), 10_000 * 1e6);
        assertEq(token.referralScore(REF_B), 10_000 * 1e6);
    }

    function test_moveBetweenVaultsExit_discreditsImmediately()
        public
    {
        _deposit(
            USER_A,
            100_000 * 1e6,
            REF_B
        );

        vm.prank(
            USER_A
        );

        token.moveBetweenVaultsExit(
            40_000 * 1e6
        );

        assertEq(token.referredContribution(USER_A), 60_000 * 1e6);
        assertEq(token.referralScore(REF_B), 60_000 * 1e6);
        assertEq(token.balanceOf(USER_A), 60_000 * 1e6);
    }

    function test_compound_creditsReferrer()
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

        token.compound(
            2_000 * 1e6
        );

        assertEq(token.referredContribution(USER_A), 12_000 * 1e6);
        assertEq(token.referralScore(REF_B), 12_000 * 1e6);
    }

    function test_compound_withoutReferrer_mintsWithoutCredit()
        public
    {
        vm.prank(
            USER_C
        );

        token.compound(
            2_000 * 1e6
        );

        assertEq(token.balanceOf(USER_C), 2_000 * 1e6);
        assertEq(token.referredContribution(USER_C), 0);
    }

    function test_mint_neverCredits()
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
        assertEq(token.referralScore(REF_B), 10_000 * 1e6);
    }

    function test_rawDrivers_disabled()
        public
    {
        vm.expectRevert(
            ReferralSyncTokenDemo.DriverDisabled.selector
        );

        token.addVolume(
            REF_B,
            1
        );

        vm.expectRevert(
            ReferralSyncTokenDemo.DriverDisabled.selector
        );

        token.removeVolume(
            REF_B,
            1
        );
    }

    function test_syncReferee_unreferredIsNoop()
        public
    {
        token.mint(
            USER_C,
            1_000 * 1e6
        );

        token.syncReferee(
            USER_C
        );

        assertEq(token.referredContribution(USER_C), 0);
    }

    function test_referrerWriteOnce_secondReferrerIgnored()
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
        assertEq(token.referralScore(REF_B2), 0);
    }

    function testFuzz_monotone_randomOpsOnlyCreditPathsIncrease(
        uint256 _seed
    )
        public
    {
        address[2] memory referees = [USER_A, USER_C];

        for (uint256 i; i < 24; ++i) {
            uint256 roll = uint256(
                keccak256(abi.encode(_seed, i))
            );

            address actor = referees[roll % 2];
            address other = referees[(roll + 1) % 2];

            uint256 op = (roll >> 8) % 6;
            uint256 raw = roll >> 16;

            uint256 contribBefore = token.referredContribution(actor);
            uint256 scoreBefore = token.referralScore(REF_B);

            bool isCreditOp;

            if (op == 0) {
                isCreditOp = true;

                vm.prank(
                    actor
                );

                token.depositWithReferral(
                    bound(raw, 1, 1_000_000 * 1e6),
                    REF_B
                );
            } else if (op == 1) {
                isCreditOp = token.referrerOf(actor) != address(0);

                vm.prank(
                    actor
                );

                token.compound(
                    bound(raw, 1, 100_000 * 1e6)
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
                uint256 balance = token.balanceOf(actor);

                if (balance == 0) {
                    continue;
                }

                vm.prank(
                    actor
                );

                token.moveBetweenVaultsExit(
                    bound(raw, 1, balance)
                );
            } else if (op == 4) {
                token.mint(
                    actor,
                    bound(raw, 1, 100_000 * 1e6)
                );
            } else {
                token.syncReferee(
                    actor
                );
            }

            if (isCreditOp == false) {
                assertLe(
                    token.referredContribution(actor),
                    contribBefore,
                    "non-credit op increased contribution"
                );

                assertLe(
                    token.referralScore(REF_B),
                    scoreBefore,
                    "non-credit op increased score"
                );
            }
        }

        token.syncReferee(
            USER_A
        );

        token.syncReferee(
            USER_C
        );

        assertLe(
            token.referredContribution(USER_A),
            token.balanceOf(USER_A),
            "post-sync contribution above balance"
        );

        assertLe(
            token.referredContribution(USER_C),
            token.balanceOf(USER_C),
            "post-sync contribution above balance"
        );

        assertEq(
            token.referralScore(REF_B),
            token.referredContribution(USER_A) + token.referredContribution(USER_C),
            "score is not the sum of contributions"
        );
    }
}
