// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {ReferralRegistry} from "../../src/registry/pending/ReferralRegistry.sol";
import {ReferralRegistryDeclarations} from "../../src/registry/pending/ReferralRegistryDeclarations.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";
import {NotProposed} from "../../src/diamond/shared/OwnableMaster.sol";

/**
 * @dev Admin/access-control suite for {ReferralRegistry}: the
 * {OwnableMaster} two-step wiring (propose, claim, renounce) and the
 * vault allowlist (grant, revoke, zero-address guard,
 * `VaultAllowedSet`, master gating). Every `onlyMaster` entrypoint
 * is also exercised once on its success path so both the guard and
 * the guarded body are covered, not just the revert arm. The
 * read/write asymmetry pin lives here too: revoking a vault blocks
 * only NEW assignments while `referrerOf` reads stay permissionless,
 * and a renounced-master registry keeps serving reads and writes
 * from still-allowlisted vaults (inert-safe, only allowlist changes
 * are lost).
 */
contract ReferralRegistryAdminTest is Test {

    event VaultAllowedSet(
        address indexed vault,
        bool allowed
    );

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    address internal user1 = address(0xA1);

    address internal refA = address(0xB1);

    address internal stranger = address(0xC1);

    address internal vaultA = address(0xD1);

    address internal newMaster = address(0xE1);

    ReferralRegistry internal registry;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        registry = new ReferralRegistry(
            address(this),
            0
        );
    }

    // ---- OwnableMaster wiring ----

    function test_master_isDeployerAfterConstruction()
        public
    {
        assertEq(registry.master(), address(this));
        assertEq(registry.proposedMaster(), address(0));
    }

    function test_ownership_proposeAndClaim_transfersMaster()
        public
    {
        registry.proposeOwner(
            newMaster
        );

        assertEq(registry.proposedMaster(), newMaster);

        vm.prank(
            newMaster
        );

        registry.claimOwnership();

        assertEq(registry.master(), newMaster);
    }

    function test_RevertWhen_claimOwnership_notProposed()
        public
    {
        registry.proposeOwner(
            newMaster
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotProposed.selector
        );

        registry.claimOwnership();
    }

    function test_ownership_renounce_freezesAllowlistButKeepsAssignments()
        public
    {
        registry.setAllowedVault(
            vaultA,
            true
        );

        registry.renounceOwnership();

        assertEq(registry.master(), address(0));

        vm.expectRevert(
            NotMaster.selector
        );

        registry.setAllowedVault(
            vaultA,
            false
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

    // ---- vault allowlist ----

    function test_setAllowedVault_grantEmitsEventAndEnablesVault()
        public
    {
        assertFalse(registry.allowedVault(vaultA));

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(registry)
        );

        emit VaultAllowedSet(
            vaultA,
            true
        );

        registry.setAllowedVault(
            vaultA,
            true
        );

        assertTrue(registry.allowedVault(vaultA));

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        assertEq(registry.referrerOf(user1), refA);
    }

    function test_setAllowedVault_revokeEmitsEventAndBlocksNewAssignsOnly()
        public
    {
        registry.setAllowedVault(
            vaultA,
            true
        );

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(registry)
        );

        emit VaultAllowedSet(
            vaultA,
            false
        );

        registry.setAllowedVault(
            vaultA,
            false
        );

        assertFalse(registry.allowedVault(vaultA));

        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.NotAllowedVault.selector
        );

        registry.assignReferrer(
            refA,
            user1
        );

        assertEq(registry.referrerOf(user1), refA);
    }

    function test_RevertWhen_setAllowedVault_zeroVault()
        public
    {
        vm.expectRevert(
            ReferralRegistryDeclarations.ZeroAddress.selector
        );

        registry.setAllowedVault(
            address(0),
            true
        );
    }

    function test_RevertWhen_setAllowedVault_notMaster()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        registry.setAllowedVault(
            vaultA,
            true
        );
    }
}
