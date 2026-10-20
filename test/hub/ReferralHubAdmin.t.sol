// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {IReferralHub} from "../../src/hub/pending/IReferralHub.sol";
import {HubLeverGrants} from "./utils/HubLeverGrants.sol";
import {HubDiamondHarness} from "../hub/utils/HubDiamondHarness.sol";
import {ReferralHub} from "../../src/hub/pending/ReferralHub.sol";
import {ReferralHubIntakeFacet} from "../../src/hub/pending/ReferralHubIntakeFacet.sol";
import {ReferralHubSelectors} from "../../script/hub/ReferralHubSelectors.sol";
import {ReferralHubDeclarations} from "../../src/hub/pending/ReferralHubDeclarations.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";
import {CohortFlushCodec} from "../../src/diamond/shared/pending/CohortFlushCodec.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";
import {NotProposed} from "../../src/diamond/shared/OwnableMaster.sol";

/**
 * @dev Admin/access-control suite for {ReferralHub}: the
 * {OwnableMaster} two-step wiring, the reporter allowlist (grant,
 * revoke, zero-address guard, `ReporterAllowedSet`), the permissionless
 * `setPayoutAddress` registry (default self, explicit set, reset to
 * zero restoring self), the re-key
 * refusal of `setFlushSource` and `setDesignationSource` (a set pair
 * takes another chain id only after its removal with zero, and the
 * same chain id again is a no-op write that still emits),
 * the zero-referrer guards of `reportSelf`, `deliverCrumbs`
 * and `deliverGap`, and the lever timelock (a grant after
 * `finalizeSetup` runs only as the exact proposed call, once, at least
 * the delay after its proposal, keyed by canonical calldata so trailing
 * bytes authorize nothing; no proposal before `finalizeSetup`; a
 * revocation and a pre-finalize grant never wait; cancel and the master
 * guard).
 * Every `onlyMaster` entrypoint is also exercised once on its success
 * path so both the guard and the guarded body are covered, not just
 * the revert arm.
 */
contract ReferralHubAdminTest is Test, HubDiamondHarness {

    event ReporterAllowedSet(
        address indexed reporter,
        bool allowed
    );

    event PayoutAddressSet(
        uint256 indexed chainId,
        address indexed owner,
        address indexed payout
    );

    event FlushSourceSet(
        uint64 indexed chainSelector,
        address indexed vault,
        uint256 chainId
    );

    event DesignationSourceSet(
        uint64 indexed chainSelector,
        address indexed registry,
        uint256 chainId
    );

    event DelivererShareCapSet(
        uint256 cap
    );

    event SourceSystemSet(
        bytes32 indexed source,
        uint256 systemId
    );

    event LeverChangeProposed(
        bytes32 indexed changeHash,
        bytes call,
        uint256 executableAt
    );

    event LeverChangeCancelled(
        bytes32 indexed changeHash
    );

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant WEEK = CohortWeeks.WEEK;

    uint64 internal constant SEL_BASE = 10_001;

    uint256 internal constant CHAIN_BASE = 8_453;

    uint256 internal constant CHAIN_ARB = 42_161;

    uint256 internal constant HORIZON_WEEKS = 520;

    address internal refA = address(0xB1);

    address internal reporter1 = address(0xD1);

    address internal stranger = address(0xC1);

    address internal newMaster = address(0xE1);

    address internal payoutAddr = address(0xF1);

    address internal usdToken = address(0xF01);

    address internal spokeVault = address(0xA1);

    address internal spokeRegistry = address(0xA2);

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
    }

    // ---- helpers ----

    function _futureRateTable()
        internal
        view
        returns (ReferralHubDeclarations.RateTable memory table)
    {
        table.effectiveFromWeek = uint32(block.timestamp / WEEK + 1);
        table.capBps = 1_000;
        table.botShareBps = 1_000;

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
        assertEq(
            hub.master(),
            address(this)
        );

        assertEq(
            hub.proposedMaster(),
            address(0)
        );
    }

    function test_ownership_proposeAndClaim_transfersMaster()
        public
    {
        hub.proposeOwner(
            newMaster
        );

        assertEq(
            hub.proposedMaster(),
            newMaster
        );

        vm.prank(
            newMaster
        );

        hub.claimOwnership();

        assertEq(
            hub.master(),
            newMaster
        );
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
        hub.pushRateTable(
            _futureRateTable()
        );

        assertEq(
            hub.rateTableCount(),
            2
        );

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

        hub.pushRateTable(
            _futureRateTable()
        );
    }

    // ---- reporter allowlist ----

    function test_setAllowedReporter_grantEmitsEventAndEnablesReporter()
        public
    {
        assertFalse(
            hub.allowedReporter(
                reporter1
            )
        );

        HubLeverGrants._queue(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    reporter1,
                    true
                )
            )
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
            true
        );

        hub.setAllowedReporter(
            reporter1,
            true
        );

        assertTrue(
            hub.allowedReporter(
                reporter1
            )
        );

        vm.prank(
            reporter1
        );

        hub.reportSelf(
            refA,
            new uint256[](0)
        );
    }

    function test_setAllowedReporter_revokeEmitsEventAndBlocksReporter()
        public
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    reporter1,
                    true
                )
            )
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

        assertFalse(
            hub.allowedReporter(
                reporter1
            )
        );

        vm.prank(
            reporter1
        );

        vm.expectRevert(
            ReferralHubDeclarations.NotReporter.selector
        );

        hub.reportSelf(
            refA,
            new uint256[](0)
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

    // ---- courier share cap ----

    function test_setDelivererShareCap_genesisZero_setEmitsAndStores()
        public
    {
        assertEq(
            hub.delivererShareCap(),
            0
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(hub)
        );

        emit DelivererShareCapSet(
            1_000 * 1e6
        );

        hub.setDelivererShareCap(
            1_000 * 1e6
        );

        assertEq(
            hub.delivererShareCap(),
            1_000 * 1e6
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(hub)
        );

        emit DelivererShareCapSet(
            0
        );

        hub.setDelivererShareCap(
            0
        );

        assertEq(
            hub.delivererShareCap(),
            0
        );
    }

    function test_setDelivererShareCap_sameValue_emitsNothing()
        public
    {
        hub.setDelivererShareCap(
            5 * 1e6
        );

        vm.recordLogs();

        hub.setDelivererShareCap(
            5 * 1e6
        );

        assertEq(
            vm.getRecordedLogs().length,
            0
        );

        assertEq(
            hub.delivererShareCap(),
            5 * 1e6
        );
    }

    function test_RevertWhen_setDelivererShareCap_calledByStranger()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        hub.setDelivererShareCap(
            1
        );
    }

    // ---- vault system tags ----

    function test_setSourceSystem_genesisZero_setEmitsOnChangeOnly()
        public
    {
        bytes32 source = hub.sourceKeyOf(
            CHAIN_BASE,
            spokeVault
        );

        assertEq(
            hub.sourceSystemOf(
                source
            ),
            0
        );

        assertEq(
            hub.MAX_SYSTEMS(),
            8
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(hub)
        );

        emit SourceSystemSet(
            source,
            7
        );

        hub.setSourceSystem(
            source,
            7
        );

        assertEq(
            hub.sourceSystemOf(
                source
            ),
            7
        );

        vm.recordLogs();

        hub.setSourceSystem(
            source,
            7
        );

        assertEq(
            vm.getRecordedLogs().length,
            0
        );

        hub.setSourceSystem(
            source,
            0
        );

        assertEq(
            hub.sourceSystemOf(
                source
            ),
            0
        );
    }

    function test_RevertWhen_setSourceSystem_systemAtBound()
        public
    {
        bytes32 source = hub.sourceKeyOf(
            CHAIN_BASE,
            spokeVault
        );

        vm.expectRevert(
            ReferralHubDeclarations.SystemOutOfRange.selector
        );

        hub.setSourceSystem(
            source,
            8
        );
    }

    function test_RevertWhen_setSourceSystem_calledByStranger()
        public
    {
        bytes32 source = hub.sourceKeyOf(
            CHAIN_BASE,
            spokeVault
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        hub.setSourceSystem(
            source,
            1
        );
    }

    // ---- payout registry ----

    function test_payoutAddress_defaultSelfThenSetThenResetToSelf()
        public
    {
        assertEq(
            hub.payoutAddressOf(
                block.chainid,
                refA
            ),
            refA
        );

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

        assertEq(
            hub.payoutAddressOf(
                block.chainid,
                refA
            ),
            payoutAddr
        );

        assertEq(
            hub.payoutStamp(
                block.chainid,
                refA
            ),
            block.timestamp << 8
        );

        vm.prank(
            refA
        );

        hub.setPayoutAddress(
            address(0)
        );

        assertEq(
            hub.payoutAddressOf(
                block.chainid,
                refA
            ),
            refA
        );
    }

    // ---- source registration ----

    function test_RevertWhen_setFlushSource_rekeyOfSetPair()
        public
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setFlushSource,
                (
                    SEL_BASE,
                    spokeVault,
                    CHAIN_BASE
                )
            )
        );

        vm.expectRevert(
            ReferralHubDeclarations.SourceAlreadySet.selector
        );

        hub.setFlushSource(
            SEL_BASE,
            spokeVault,
            CHAIN_ARB
        );
    }

    function test_setFlushSource_sameChainIdAgain_isNoop()
        public
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setFlushSource,
                (
                    SEL_BASE,
                    spokeVault,
                    CHAIN_BASE
                )
            )
        );

        HubLeverGrants._queue(
            address(hub),
            abi.encodeCall(
                IReferralHub.setFlushSource,
                (
                    SEL_BASE,
                    spokeVault,
                    CHAIN_BASE
                )
            )
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(hub)
        );

        emit FlushSourceSet(
            SEL_BASE,
            spokeVault,
            CHAIN_BASE
        );

        hub.setFlushSource(
            SEL_BASE,
            spokeVault,
            CHAIN_BASE
        );

        assertEq(
            hub.flushSourceChainId(
                SEL_BASE,
                spokeVault
            ),
            CHAIN_BASE
        );
    }

    function test_setFlushSource_zeroThenNewChainId_allowed()
        public
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setFlushSource,
                (
                    SEL_BASE,
                    spokeVault,
                    CHAIN_BASE
                )
            )
        );

        hub.setFlushSource(
            SEL_BASE,
            spokeVault,
            0
        );

        assertEq(
            hub.flushSourceChainId(
                SEL_BASE,
                spokeVault
            ),
            0
        );

        HubLeverGrants._queue(
            address(hub),
            abi.encodeCall(
                IReferralHub.setFlushSource,
                (
                    SEL_BASE,
                    spokeVault,
                    CHAIN_ARB
                )
            )
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(hub)
        );

        emit FlushSourceSet(
            SEL_BASE,
            spokeVault,
            CHAIN_ARB
        );

        hub.setFlushSource(
            SEL_BASE,
            spokeVault,
            CHAIN_ARB
        );

        assertEq(
            hub.flushSourceChainId(
                SEL_BASE,
                spokeVault
            ),
            CHAIN_ARB
        );
    }

    function test_RevertWhen_setDesignationSource_rekeyOfSetPair()
        public
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setDesignationSource,
                (
                    SEL_BASE,
                    spokeRegistry,
                    CHAIN_BASE
                )
            )
        );

        vm.expectRevert(
            ReferralHubDeclarations.SourceAlreadySet.selector
        );

        hub.setDesignationSource(
            SEL_BASE,
            spokeRegistry,
            CHAIN_ARB
        );
    }

    function test_setDesignationSource_sameChainIdAgain_isNoop()
        public
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setDesignationSource,
                (
                    SEL_BASE,
                    spokeRegistry,
                    CHAIN_BASE
                )
            )
        );

        HubLeverGrants._queue(
            address(hub),
            abi.encodeCall(
                IReferralHub.setDesignationSource,
                (
                    SEL_BASE,
                    spokeRegistry,
                    CHAIN_BASE
                )
            )
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(hub)
        );

        emit DesignationSourceSet(
            SEL_BASE,
            spokeRegistry,
            CHAIN_BASE
        );

        hub.setDesignationSource(
            SEL_BASE,
            spokeRegistry,
            CHAIN_BASE
        );

        assertEq(
            hub.designationSourceChainId(
                SEL_BASE,
                spokeRegistry
            ),
            CHAIN_BASE
        );
    }

    function test_setDesignationSource_zeroThenNewChainId_allowed()
        public
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setDesignationSource,
                (
                    SEL_BASE,
                    spokeRegistry,
                    CHAIN_BASE
                )
            )
        );

        hub.setDesignationSource(
            SEL_BASE,
            spokeRegistry,
            0
        );

        assertEq(
            hub.designationSourceChainId(
                SEL_BASE,
                spokeRegistry
            ),
            0
        );

        HubLeverGrants._queue(
            address(hub),
            abi.encodeCall(
                IReferralHub.setDesignationSource,
                (
                    SEL_BASE,
                    spokeRegistry,
                    CHAIN_ARB
                )
            )
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(hub)
        );

        emit DesignationSourceSet(
            SEL_BASE,
            spokeRegistry,
            CHAIN_ARB
        );

        hub.setDesignationSource(
            SEL_BASE,
            spokeRegistry,
            CHAIN_ARB
        );

        assertEq(
            hub.designationSourceChainId(
                SEL_BASE,
                spokeRegistry
            ),
            CHAIN_ARB
        );
    }

    // ---- reporter entrypoint validation ----

    function test_RevertWhen_deliverCrumbs_zeroReferrer()
        public
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    address(this),
                    true
                )
            )
        );

        uint256[] memory weeksArr = new uint256[](1);
        weeksArr[0] = block.timestamp / WEEK - 1;

        uint256[] memory words = new uint256[](1);
        words[0] = CohortWeeks._packLanes(
            1,
            0,
            0
        );

        vm.expectRevert(
            ReferralHubDeclarations.ZeroAddress.selector
        );

        hub.deliverCrumbs(
            address(0),
            address(this),
            weeksArr,
            words
        );
    }

    function test_RevertWhen_deliverGap_zeroReferrer()
        public
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    address(this),
                    true
                )
            )
        );

        uint256 fromWeek = block.timestamp / WEEK - 3;

        uint256 record = fromWeek
            | ((fromWeek + 2) << CohortWeeks.GAP_TO_SHIFT)
            | (uint256(1) << CohortWeeks.GAP_MATURE_SHIFT);

        vm.expectRevert(
            ReferralHubDeclarations.ZeroAddress.selector
        );

        hub.deliverGap(
            address(0),
            address(this),
            record,
            fromWeek,
            2
        );
    }

    function test_RevertWhen_deliverCrumbs_zeroDeliverer()
        public
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    address(this),
                    true
                )
            )
        );

        uint256[] memory weeksArr = new uint256[](1);
        weeksArr[0] = block.timestamp / WEEK - 1;

        uint256[] memory words = new uint256[](1);
        words[0] = CohortWeeks._packLanes(
            1,
            0,
            0
        );

        vm.expectRevert(
            ReferralHubDeclarations.ZeroAddress.selector
        );

        hub.deliverCrumbs(
            address(0xB1),
            address(0),
            weeksArr,
            words
        );
    }

    function test_RevertWhen_deliverGap_zeroDeliverer()
        public
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    address(this),
                    true
                )
            )
        );

        uint256 fromWeek = block.timestamp / WEEK - 3;

        uint256 record = fromWeek
            | ((fromWeek + 2) << CohortWeeks.GAP_TO_SHIFT)
            | (uint256(1) << CohortWeeks.GAP_MATURE_SHIFT);

        vm.expectRevert(
            ReferralHubDeclarations.ZeroAddress.selector
        );

        hub.deliverGap(
            address(0xB1),
            address(0),
            record,
            fromWeek,
            2
        );
    }

    function test_RevertWhen_reportSelf_zeroReferrer()
        public
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    address(this),
                    true
                )
            )
        );

        vm.expectRevert(
            ReferralHubDeclarations.ZeroAddress.selector
        );

        hub.reportSelf(
            address(0),
            new uint256[](0)
        );
    }

    // ---- lever timelock ----

    function _reporterGrant(
        address _reporter
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(
            IReferralHub.setAllowedReporter,
            (
                _reporter,
                true
            )
        );
    }

    function test_proposeLeverChange_queuesAndEmitsTheCall()
        public
    {
        bytes memory grant = _reporterGrant(
            reporter1
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(hub)
        );

        emit LeverChangeProposed(
            keccak256(
                grant
            ),
            grant,
            block.timestamp + 3 days
        );

        hub.proposeLeverChange(
            grant
        );

        assertEq(
            hub.leverChangeQueuedAt(
                keccak256(
                    grant
                )
            ),
            block.timestamp
        );
    }

    function test_leverGrant_revertsWhenNotQueued()
        public
    {
        vm.expectRevert(
            ReferralHubDeclarations.LeverChangeNotQueued.selector
        );

        hub.setAllowedReporter(
            reporter1,
            true
        );

        vm.expectRevert(
            ReferralHubDeclarations.LeverChangeNotQueued.selector
        );

        hub.setCcipRouter(
            stranger
        );

        vm.expectRevert(
            ReferralHubDeclarations.LeverChangeNotQueued.selector
        );

        hub.setFlushSource(
            SEL_BASE,
            spokeVault,
            CHAIN_BASE
        );

        vm.expectRevert(
            ReferralHubDeclarations.LeverChangeNotQueued.selector
        );

        hub.setDesignationSource(
            SEL_BASE,
            spokeRegistry,
            CHAIN_BASE
        );
    }

    function test_leverGrant_revertsBeforeTheDelay()
        public
    {
        hub.proposeLeverChange(
            _reporterGrant(
                reporter1
            )
        );

        vm.warp(
            block.timestamp + 3 days - 1
        );

        vm.expectRevert(
            ReferralHubDeclarations.LeverTimelockNotElapsed.selector
        );

        hub.setAllowedReporter(
            reporter1,
            true
        );
    }

    function test_leverGrant_runsAtTheDelayOnce()
        public
    {
        hub.proposeLeverChange(
            _reporterGrant(
                reporter1
            )
        );

        vm.warp(
            block.timestamp + 3 days
        );

        hub.setAllowedReporter(
            reporter1,
            true
        );

        assertTrue(
            hub.allowedReporter(
                reporter1
            )
        );

        assertEq(
            hub.leverChangeQueuedAt(
                keccak256(
                    _reporterGrant(
                        reporter1
                    )
                )
            ),
            0
        );

        vm.expectRevert(
            ReferralHubDeclarations.LeverChangeNotQueued.selector
        );

        hub.setAllowedReporter(
            reporter1,
            true
        );
    }

    function test_leverGrant_proposalBindsItsArguments()
        public
    {
        hub.proposeLeverChange(
            _reporterGrant(
                reporter1
            )
        );

        vm.warp(
            block.timestamp + 3 days
        );

        vm.expectRevert(
            ReferralHubDeclarations.LeverChangeNotQueued.selector
        );

        hub.setAllowedReporter(
            stranger,
            true
        );
    }

    function test_cancelLeverChange_clearsAndEmits()
        public
    {
        bytes32 changeHash = keccak256(
            _reporterGrant(
                reporter1
            )
        );

        hub.proposeLeverChange(
            _reporterGrant(
                reporter1
            )
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(hub)
        );

        emit LeverChangeCancelled(
            changeHash
        );

        hub.cancelLeverChange(
            changeHash
        );

        assertEq(
            hub.leverChangeQueuedAt(
                changeHash
            ),
            0
        );

        vm.warp(
            block.timestamp + 3 days
        );

        vm.expectRevert(
            ReferralHubDeclarations.LeverChangeNotQueued.selector
        );

        hub.setAllowedReporter(
            reporter1,
            true
        );
    }

    function test_RevertWhen_cancelLeverChange_notQueued()
        public
    {
        vm.expectRevert(
            ReferralHubDeclarations.LeverChangeNotQueued.selector
        );

        hub.cancelLeverChange(
            keccak256(
                _reporterGrant(
                    reporter1
                )
            )
        );
    }

    function test_RevertWhen_leverProposalOrCancel_notMaster()
        public
    {
        bytes memory grant = _reporterGrant(
            reporter1
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        hub.proposeLeverChange(
            grant
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        hub.cancelLeverChange(
            keccak256(
                grant
            )
        );
    }

    function test_leverGrant_sourceReAddAfterRemovalWaits()
        public
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setFlushSource,
                (
                    SEL_BASE,
                    spokeVault,
                    CHAIN_BASE
                )
            )
        );

        hub.setFlushSource(
            SEL_BASE,
            spokeVault,
            0
        );

        assertEq(
            hub.flushSourceChainId(
                SEL_BASE,
                spokeVault
            ),
            0
        );

        vm.expectRevert(
            ReferralHubDeclarations.LeverChangeNotQueued.selector
        );

        hub.setFlushSource(
            SEL_BASE,
            spokeVault,
            CHAIN_ARB
        );
    }

    function test_leverGrant_beforeFinalizeRunsAtOnce()
        public
    {
        ReferralHub fresh = new ReferralHub(
            usdToken
        );

        ReferralHubIntakeFacet intakeFacet = new ReferralHubIntakeFacet();

        fresh.proposeSelectors(
            ReferralHubSelectors._intakeSelectors(),
            address(intakeFacet)
        );

        fresh.executeSelectorChanges(
            ReferralHubSelectors._intakeSelectors()
        );

        IReferralHub(
            address(fresh)
        ).setAllowedReporter(
            reporter1,
            true
        );

        assertTrue(
            IReferralHub(
                address(fresh)
            ).allowedReporter(
                reporter1
            )
        );
    }

    function test_RevertWhen_proposeLeverChange_beforeFinalize()
        public
    {
        ReferralHub fresh = new ReferralHub(
            usdToken
        );

        vm.expectRevert(
            ReferralHubDeclarations.SetupNotFinalized.selector
        );

        fresh.proposeLeverChange(
            _reporterGrant(
                reporter1
            )
        );
    }

    function test_leverGrant_trailingBytesProposalAuthorizesNothing()
        public
    {
        bytes memory padded = abi.encodePacked(
            _reporterGrant(
                reporter1
            ),
            bytes1(0x01)
        );

        hub.proposeLeverChange(
            padded
        );

        vm.warp(
            block.timestamp + 3 days
        );

        (
            bool success,
            bytes memory returnData
        ) = address(hub).call(
            padded
        );

        assertFalse(
            success
        );

        assertEq(
            bytes4(returnData),
            ReferralHubDeclarations.LeverChangeNotQueued.selector
        );

        vm.expectRevert(
            ReferralHubDeclarations.LeverChangeNotQueued.selector
        );

        hub.setAllowedReporter(
            reporter1,
            true
        );
    }
}
