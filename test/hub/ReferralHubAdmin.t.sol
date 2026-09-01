// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {ReferralHub} from "../../src/hub/pending/ReferralHub.sol";
import {ReferralHubDeclarations} from "../../src/hub/pending/ReferralHubDeclarations.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";
import {NotProposed} from "../../src/diamond/shared/OwnableMaster.sol";

/**
 * @dev Admin/access-control suite for {ReferralHub}: the
 * {OwnableMaster} two-step wiring, the reporter allowlist (grant,
 * revoke, zero-address guard, `ReporterAllowedSet`), the permissionless
 * `setPayoutAddress` registry (default self, explicit set, reset to
 * zero restoring self), and the `reportScores` zero-referrer guard.
 * Every `onlyMaster` entrypoint is also exercised once on its success
 * path so both the guard and the guarded body are covered, not just
 * the revert arm.
 */
contract ReferralHubAdminTest is Test {

    event ReporterAllowedSet(
        address indexed reporter,
        bool allowed
    );

    event PayoutAddressSet(
        uint256 indexed chainId,
        address indexed owner,
        address indexed payout
    );

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant WEEK = CohortWeeks.WEEK;

    address internal refA = address(0xB1);

    address internal reporter1 = address(0xD1);

    address internal stranger = address(0xC1);

    address internal newMaster = address(0xE1);

    address internal payoutAddr = address(0xF1);

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
    }

    // ---- helpers ----

    function _futureRateTable()
        internal
        view
        returns (ReferralHubDeclarations.RateTable memory table)
    {
        table.effectiveFromWeek = uint32(block.timestamp / WEEK + 1);
        table.capBps = 1_000;

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

    // ---- OwnableMaster wiring ----

    function test_master_isDeployerAfterConstruction()
        public
    {
        assertEq(hub.master(), address(this));
        assertEq(hub.proposedMaster(), address(0));
    }

    function test_ownership_proposeAndClaim_transfersMaster()
        public
    {
        hub.proposeOwner(
            newMaster
        );

        assertEq(hub.proposedMaster(), newMaster);

        vm.prank(
            newMaster
        );

        hub.claimOwnership();

        assertEq(hub.master(), newMaster);
    }

    function test_RevertWhen_claimOwnership_notProposed()
        public
    {
        hub.proposeOwner(
            newMaster
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotProposed.selector
        );

        hub.claimOwnership();
    }

    function test_RevertWhen_masterGatedFunctions_calledByStranger()
        public
    {
        uint256 flipWeek = block.timestamp / WEEK + 1;

        hub.scheduleDwellMin(
            flipWeek,
            false
        );

        assertFalse(hub.dwellMinAt(flipWeek));

        hub.pushRateTable(
            _futureRateTable()
        );

        assertEq(hub.rateTableCount(), 2);

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        hub.setAllowedReporter(
            reporter1,
            true
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        hub.scheduleDwellMin(
            flipWeek + 1,
            true
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        hub.pushRateTable(
            _futureRateTable()
        );
    }

    // ---- reporter allowlist ----

    function test_setAllowedReporter_grantEmitsEventAndEnablesReporter()
        public
    {
        assertFalse(hub.allowedReporter(reporter1));

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(hub)
        );

        emit ReporterAllowedSet(
            reporter1,
            true
        );

        hub.setAllowedReporter(
            reporter1,
            true
        );

        assertTrue(hub.allowedReporter(reporter1));

        vm.prank(
            reporter1
        );

        hub.reportScores(
            refA,
            1_000 * 1e6,
            0
        );
    }

    function test_setAllowedReporter_revokeEmitsEventAndBlocksReporter()
        public
    {
        hub.setAllowedReporter(
            reporter1,
            true
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(hub)
        );

        emit ReporterAllowedSet(
            reporter1,
            false
        );

        hub.setAllowedReporter(
            reporter1,
            false
        );

        assertFalse(hub.allowedReporter(reporter1));

        vm.prank(
            reporter1
        );

        vm.expectRevert(
            ReferralHubDeclarations.NotReporter.selector
        );

        hub.reportScores(
            refA,
            1_000 * 1e6,
            0
        );
    }

    function test_RevertWhen_setAllowedReporter_zeroAddress()
        public
    {
        vm.expectRevert(
            ReferralHubDeclarations.ZeroAddress.selector
        );

        hub.setAllowedReporter(
            address(0),
            true
        );
    }

    // ---- payout registry ----

    function test_payoutAddress_defaultSelfThenSetThenResetToSelf()
        public
    {
        assertEq(hub.payoutAddressOf(block.chainid, refA), refA);

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(hub)
        );

        emit PayoutAddressSet(
            block.chainid,
            refA,
            payoutAddr
        );

        vm.prank(
            refA
        );

        hub.setPayoutAddress(
            payoutAddr
        );

        assertEq(hub.payoutAddressOf(block.chainid, refA), payoutAddr);

        assertEq(hub.payoutStamp(block.chainid, refA), block.timestamp << 8);

        vm.prank(
            refA
        );

        hub.setPayoutAddress(
            address(0)
        );

        assertEq(hub.payoutAddressOf(block.chainid, refA), refA);
    }

    // ---- reportScores validation ----

    function test_RevertWhen_reportScores_zeroReferrer()
        public
    {
        hub.setAllowedReporter(
            address(this),
            true
        );

        vm.expectRevert(
            ReferralHubDeclarations.ZeroAddress.selector
        );

        hub.reportScores(
            address(0),
            1_000 * 1e6,
            0
        );
    }
}
