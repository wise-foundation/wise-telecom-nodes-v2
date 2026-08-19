// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ReferralRegistry} from "../../src/registry/pending/ReferralRegistry.sol";
import {ReferralRegistryDeclarations} from "../../src/registry/pending/ReferralRegistryDeclarations.sol";

/**
 * @dev Assignment-semantics suite for {ReferralRegistry} — the
 * rules enforced registry-side: zero user/referrer
 * revert, self-referral revert, the InvalidReferrer hardening pair
 * (calling vault, the registry itself), write-once with the loser
 * silently ignored (across repeat calls, different referrers,
 * different vaults, and same-block races), the {ReferralAssigned}
 * event only on the actual first-set transition, and the
 * fixed validation-before-write-once revert
 * priority (a zero/self referrer reverts even for an
 * already-assigned user). Includes the two-allowed-vaults same-block
 * race pin: first write wins and exactly one event is ever emitted
 * per user.
 */
contract ReferralRegistryAssignTest is Test {

    event ReferralAssigned(
        address indexed user,
        address indexed referrer,
        address indexed vault
    );

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    address internal user1 = address(0xA1);

    address internal refA = address(0xB1);

    address internal refB = address(0xB2);

    address internal stranger = address(0xC1);

    address internal vaultA = address(0xD1);

    address internal vaultB = address(0xD2);

    ReferralRegistry internal registry;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        registry = new ReferralRegistry();

        registry.setAllowedVault(
            vaultA,
            true
        );

        registry.setAllowedVault(
            vaultB,
            true
        );
    }

    // ---- helpers ----

    function _assignedEventCount()
        internal
        returns (uint256 count)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic = keccak256(
            "ReferralAssigned(address,address,address)"
        );

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic) {
                ++count;
            }
        }
    }

    // ---- defaults ----

    function test_referrerOf_defaultZero()
        public
    {
        assertEq(registry.referrerOf(user1), address(0));
    }

    // ---- first assignment ----

    function test_assignReferrer_firstAssign_setsAndEmits()
        public
    {
        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit ReferralAssigned(
            user1,
            refA,
            vaultA
        );

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        assertEq(registry.referrerOf(user1), refA);
    }

    // ---- write-once ----

    function test_assignReferrer_secondDifferentReferrer_keepsFirstNoEvent()
        public
    {
        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        vm.recordLogs();

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refB
        );

        assertEq(_assignedEventCount(), 0);
        assertEq(registry.referrerOf(user1), refA);
    }

    function test_assignReferrer_sameReferrerAgain_noEvent()
        public
    {
        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        vm.recordLogs();

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        assertEq(_assignedEventCount(), 0);
        assertEq(registry.referrerOf(user1), refA);
    }

    function test_assignReferrer_secondVault_sameUser_keepsFirst()
        public
    {
        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        vm.prank(
            vaultB
        );

        registry.assignReferrer(
            user1,
            refB
        );

        assertEq(registry.referrerOf(user1), refA);
    }

    function test_assignReferrer_circularPair_bothStick()
        public
    {
        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            refA,
            user1
        );

        assertEq(registry.referrerOf(user1), refA);
        assertEq(registry.referrerOf(refA), user1);
    }

    // ---- validation ----

    function test_RevertWhen_assignReferrer_zeroUser()
        public
    {
        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.ZeroAddress.selector
        );

        registry.assignReferrer(
            address(0),
            refA
        );
    }

    function test_RevertWhen_assignReferrer_zeroReferrer()
        public
    {
        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.ZeroAddress.selector
        );

        registry.assignReferrer(
            user1,
            address(0)
        );
    }

    function test_RevertWhen_assignReferrer_selfReferral()
        public
    {
        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.SelfReferral.selector
        );

        registry.assignReferrer(
            user1,
            user1
        );
    }

    function test_RevertWhen_assignReferrer_referrerIsCallingVault()
        public
    {
        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.assignReferrer(
            user1,
            vaultA
        );
    }

    function test_RevertWhen_assignReferrer_referrerIsRegistry()
        public
    {
        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.assignReferrer(
            user1,
            address(registry)
        );
    }

    function test_assignReferrer_zeroReferrerRevertsEvenWhenAssigned()
        public
    {
        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.ZeroAddress.selector
        );

        registry.assignReferrer(
            user1,
            address(0)
        );

        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.SelfReferral.selector
        );

        registry.assignReferrer(
            user1,
            user1
        );
    }

    // ---- allowlist gating ----

    function test_RevertWhen_assignReferrer_callerNotAllowlisted()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.NotAllowedVault.selector
        );

        registry.assignReferrer(
            user1,
            refA
        );
    }

    function test_RevertWhen_assignReferrer_revokedVault()
        public
    {
        registry.setAllowedVault(
            vaultA,
            false
        );

        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.NotAllowedVault.selector
        );

        registry.assignReferrer(
            user1,
            refA
        );
    }

    // ---- fuzz ----

    function testFuzz_assignReferrer_writeOnceRule(
        address _secondReferrer,
        bool _useVaultB
    )
        public
    {
        _secondReferrer = address(
            uint160(
                bound(
                    uint256(uint160(_secondReferrer)),
                    1,
                    type(uint160).max
                )
            )
        );

        vm.assume(_secondReferrer != user1);
        vm.assume(_secondReferrer != vaultA);
        vm.assume(_secondReferrer != vaultB);
        vm.assume(_secondReferrer != address(registry));

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        vm.prank(
            _useVaultB
                ? vaultB
                : vaultA
        );

        registry.assignReferrer(
            user1,
            _secondReferrer
        );

        assertEq(registry.referrerOf(user1), refA);
    }

    function testFuzz_assignReferrer_twoVaultsSameBlock_firstWins(
        bool _vaultAFirst
    )
        public
    {
        address firstVault = _vaultAFirst
            ? vaultA
            : vaultB;

        address secondVault = _vaultAFirst
            ? vaultB
            : vaultA;

        address firstReferrer = _vaultAFirst
            ? refA
            : refB;

        address secondReferrer = _vaultAFirst
            ? refB
            : refA;

        vm.recordLogs();

        vm.prank(
            firstVault
        );

        registry.assignReferrer(
            user1,
            firstReferrer
        );

        vm.prank(
            secondVault
        );

        registry.assignReferrer(
            user1,
            secondReferrer
        );

        assertEq(_assignedEventCount(), 1);
        assertEq(registry.referrerOf(user1), firstReferrer);
    }
}
