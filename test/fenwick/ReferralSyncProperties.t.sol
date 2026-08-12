// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {
    ReferralSyncTokenDemo,
    ReferralSyncHookDemo
} from "./ReferralSyncTokenDemo.sol";

/**
 * @dev Dual-engine properties (Foundry fuzzing + Kontrol/KEVM
 * symbolic execution on the SAME functions) for the lazy-sync
 * referral theorem: `referredContribution` — and with it the
 * referrer's score — increases ONLY inside `depositWithReferral` /
 * `compound`, by exactly the credited amount; every other operation
 * (transfer, transferFrom, mint, moveBetweenVaultsExit, syncReferee)
 * leaves it unchanged or strictly decreases it, and the sync clamp
 * lands exactly on min(contribution, balance).
 *
 * Kontrol tractability scope (mirrors test/diamond/kontrol
 * conventions): actor addresses are concrete literals so mapping
 * slots stay concrete for the symbolic engine; amounts are fully
 * symbolic within stated bounds. The REFS family bounds amounts below
 * MIN_ACTIVE_SCORE, so the Fenwick tree is never touched and the
 * contribution/score algebra is proven with zero concrete-index
 * restrictions. The REFT family deposits exactly MIN_ACTIVE_SCORE
 * (Fenwick bucket 1 — a concrete 12-node walk) and clamps by a
 * symbolic partial amount, which always lands below the activation
 * threshold, so the deactivation walk is the same concrete node set —
 * every Fenwick storage key in every proof is concrete while all
 * clamp deltas stay symbolic. Arbitrary-bucket coverage of the same
 * theorem comes from the wide-range randomized fuzz in
 * {ReferralSync.t.sol} and the base contract's own suite.
 */
contract ReferralSyncPropertiesTest is Test {

    uint256 internal constant MIN_SCORE = 1_000 * 1e6;

    ReferralSyncTokenDemo internal token;

    ReferralSyncHookDemo internal hook;

    address internal constant USER_A = address(0xA1);

    address internal constant USER_C = address(0xC1);

    address internal constant REF_B = address(0xB1);

    address internal constant SPENDER = address(0x5E1);

    function setUp()
        public
    {
        token = new ReferralSyncTokenDemo();
        hook = new ReferralSyncHookDemo();

        token.setTransferHook(
            address(hook)
        );
    }

    function _depositA(
        uint256 _amount
    )
        internal
    {
        vm.prank(
            USER_A
        );

        token.depositWithReferral(
            _amount,
            REF_B
        );
    }

    // ---- REFS: fully symbolic amounts, sub-activation (no tree) ----

    function testFuzz_REFS1_transferNeverIncreasesContributionOrScore(
        uint256 _deposit,
        uint256 _send
    )
        public
    {
        vm.assume(
            _deposit > 0 && _deposit < MIN_SCORE
        );

        vm.assume(
            _send > 0 && _send <= _deposit
        );

        _depositA(
            _deposit
        );

        uint256 contribBefore = token.referredContribution(USER_A);
        uint256 scoreBefore = token.referralScore(REF_B);

        vm.prank(
            USER_A
        );

        token.transfer(
            USER_C,
            _send
        );

        assert(token.referredContribution(USER_A) <= contribBefore);
        assert(token.referralScore(REF_B) <= scoreBefore);
        assert(token.referredContribution(USER_C) == 0);
    }

    function testFuzz_REFS2_syncClampsExactlyToBalance(
        uint256 _deposit,
        uint256 _send
    )
        public
    {
        vm.assume(
            _deposit > 0 && _deposit < MIN_SCORE
        );

        vm.assume(
            _send > 0 && _send <= _deposit
        );

        _depositA(
            _deposit
        );

        vm.prank(
            USER_A
        );

        token.transfer(
            USER_C,
            _send
        );

        token.syncReferee(
            USER_A
        );

        assert(token.referredContribution(USER_A) == _deposit - _send);
        assert(token.referralScore(REF_B) == _deposit - _send);

        token.syncReferee(
            USER_A
        );

        assert(token.referredContribution(USER_A) == _deposit - _send);
        assert(token.referralScore(REF_B) == _deposit - _send);
    }

    function testFuzz_REFS3_transferFromNeverIncreasesContribution(
        uint256 _deposit,
        uint256 _send
    )
        public
    {
        vm.assume(
            _deposit > 0 && _deposit < MIN_SCORE
        );

        vm.assume(
            _send > 0 && _send <= _deposit
        );

        _depositA(
            _deposit
        );

        vm.prank(
            USER_A
        );

        token.approve(
            SPENDER,
            _send
        );

        uint256 contribBefore = token.referredContribution(USER_A);
        uint256 scoreBefore = token.referralScore(REF_B);

        vm.prank(
            SPENDER
        );

        token.transferFrom(
            USER_A,
            USER_C,
            _send
        );

        assert(token.referredContribution(USER_A) <= contribBefore);
        assert(token.referralScore(REF_B) <= scoreBefore);
        assert(token.referredContribution(USER_C) == 0);
    }

    function testFuzz_REFS4_mintNeverChangesContributionOrScore(
        uint256 _deposit,
        uint256 _mintAmount
    )
        public
    {
        vm.assume(
            _deposit > 0 && _deposit < MIN_SCORE
        );

        vm.assume(
            _mintAmount > 0 && _mintAmount < MIN_SCORE
        );

        _depositA(
            _deposit
        );

        token.mint(
            USER_A,
            _mintAmount
        );

        assert(token.referredContribution(USER_A) == _deposit);
        assert(token.referralScore(REF_B) == _deposit);
    }

    function testFuzz_REFS5_moveOutDiscreditsImmediatelyAndExactly(
        uint256 _deposit,
        uint256 _out
    )
        public
    {
        vm.assume(
            _deposit > 0 && _deposit < MIN_SCORE
        );

        vm.assume(
            _out > 0 && _out <= _deposit
        );

        _depositA(
            _deposit
        );

        vm.prank(
            USER_A
        );

        token.moveBetweenVaultsExit(
            _out
        );

        assert(token.referredContribution(USER_A) == _deposit - _out);
        assert(token.referralScore(REF_B) == _deposit - _out);
        assert(token.balanceOf(USER_A) == _deposit - _out);
    }

    function testFuzz_REFS6_depositAndCompoundCreditExactly(
        uint256 _deposit,
        uint256 _compound
    )
        public
    {
        vm.assume(
            _deposit > 0 && _deposit < MIN_SCORE / 2
        );

        vm.assume(
            _compound > 0 && _compound < MIN_SCORE / 2
        );

        _depositA(
            _deposit
        );

        assert(token.referredContribution(USER_A) == _deposit);

        vm.prank(
            USER_A
        );

        token.compound(
            _compound
        );

        assert(token.referredContribution(USER_A) == _deposit + _compound);
        assert(token.referralScore(REF_B) == _deposit + _compound);
    }

    function testFuzz_REFS7_syncOnUnreferredIsNoop(
        uint256 _mintAmount
    )
        public
    {
        vm.assume(
            _mintAmount > 0 && _mintAmount < MIN_SCORE
        );

        token.mint(
            USER_C,
            _mintAmount
        );

        token.syncReferee(
            USER_C
        );

        assert(token.referredContribution(USER_C) == 0);
        assert(token.balanceOf(USER_C) == _mintAmount);
    }

    // ---- REFT: concrete bucket-1 activation, symbolic clamp ----

    function testFuzz_REFT1_clampBelowMinDeactivatesReferrer(
        uint256 _send
    )
        public
    {
        vm.assume(
            _send > 0 && _send <= MIN_SCORE
        );

        _depositA(
            MIN_SCORE
        );

        assert(token.activeReferrerCount() == 1);
        assert(token.referrerBucket(REF_B) == 1);

        vm.prank(
            USER_A
        );

        token.transfer(
            USER_C,
            _send
        );

        token.syncReferee(
            USER_A
        );

        assert(token.referredContribution(USER_A) == MIN_SCORE - _send);
        assert(token.referralScore(REF_B) == MIN_SCORE - _send);
        assert(token.activeReferrerCount() == 0);
        assert(token.referrerBucket(REF_B) == 0);
        assert(token.isTopTenPercent(REF_B) == false);
    }

    function testFuzz_REFT2_moveOutClampDeactivatesImmediately(
        uint256 _out
    )
        public
    {
        vm.assume(
            _out > 0 && _out <= MIN_SCORE
        );

        _depositA(
            MIN_SCORE
        );

        vm.prank(
            USER_A
        );

        token.moveBetweenVaultsExit(
            _out
        );

        assert(token.referredContribution(USER_A) == MIN_SCORE - _out);
        assert(token.referralScore(REF_B) == MIN_SCORE - _out);
        assert(token.activeReferrerCount() == 0);
        assert(token.referrerBucket(REF_B) == 0);
    }
}
