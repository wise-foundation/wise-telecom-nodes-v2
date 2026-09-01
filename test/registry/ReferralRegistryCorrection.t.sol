// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {ReferralRegistry} from "../../src/registry/pending/ReferralRegistry.sol";
import {ReferralRegistryDeclarations} from "../../src/registry/pending/ReferralRegistryDeclarations.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

/**
 * @dev Vault stand-in for the correction suite's flip-migration
 * seam: records the last `receiveReferrerFlip` call and can be armed
 * to revert so the defer-and-retry path stays observable when a
 * correction rides the closure.
 */
contract MockCorrectionFlipVault {

    error FlipRejected();

    bool public shouldRevert;

    uint256 public flipCallCount;

    address public lastUser;

    address public lastOldReferrer;

    address public lastNewReferrer;

    function setShouldRevert(
        bool _shouldRevert
    )
        external
    {
        shouldRevert = _shouldRevert;
    }

    function receiveReferrerFlip(
        address _user,
        address _oldReferrer,
        address _newReferrer
    )
        external
    {
        require(
            shouldRevert == false,
            FlipRejected()
        );

        flipCallCount += 1;

        lastUser = _user;

        lastOldReferrer = _oldReferrer;

        lastNewReferrer = _newReferrer;
    }
}

/**
 * @dev Minimal CCIP router stand-in for the post-correction
 * broadcast test: fixed fee, records the last payload so the test
 * can decode what a corrected pair actually sends.
 */
contract MockCorrectionCcipRouter {

    error UnexpectedFeeValue();

    uint256 public fee;

    bytes public lastData;

    constructor(
        uint256 _fee
    ) {
        fee = _fee;
    }

    function getFee(
        uint64,
        Client.EVM2AnyMessage calldata
    )
        external
        view
        returns (uint256)
    {
        return fee;
    }

    function ccipSend(
        uint64 _destChainSelector,
        Client.EVM2AnyMessage calldata _message
    )
        external
        payable
        returns (bytes32)
    {
        require(
            msg.value == fee,
            UnexpectedFeeValue()
        );

        lastData = _message.data;

        return keccak256(
            abi.encode(
                _destChainSelector,
                lastData
            )
        );
    }
}

/**
 * @dev Correction-lane suite for {ReferralRegistry}: the
 * master-proposed, user-cancellable, 3-day-timelocked rewrite of a
 * mis-assigned `(user, referrer)` pair and the ONE-WAY latch (a
 * master action, intended for the moment payouts arm) that
 * permanently retires the lane. Pins: the propose
 * guards (master gate, assignment-shaped referrer validation
 * including the vault/registry laundering rejects, nothing-to-correct
 * arms), the unilateral user cancel plus master cancel with cancel
 * surviving the latch, the timelock boundary (fuzzed), and (the core
 * of the design) that execution rides the EXISTING flip closure:
 * identical pending-flip markers with keep-if-set, identical
 * `pokeMigration` migrate/defer arms, identical `effectiveReferrerOf`
 * redirect while a marker stands, and an untouched sync key so the
 * corrected pair ignores equal-key echoes of the old referrer
 * (collision-flagged), still loses to strictly earlier assignments,
 * and broadcasts the new referrer under the original key. Latch
 * one-way-ness is pinned by the propose/execute rejects after the
 * latch plus the absence of any unlatch surface. Mock flip vault and
 * router live at the top of this file.
 */
contract ReferralRegistryCorrectionTest is Test {

    event ReferralCorrectionProposed(
        address indexed user,
        address indexed oldReferrer,
        address indexed newReferrer,
        uint256 queuedAt
    );

    event ReferralCorrectionCancelled(
        address indexed user,
        address indexed newReferrer,
        address indexed cancelledBy
    );

    event ReferralCorrectionExecuted(
        address indexed user,
        address indexed oldReferrer,
        address indexed newReferrer
    );

    event CorrectionsLatched();

    event FlipMarked(
        address indexed vault,
        address indexed user,
        address indexed oldReferrer
    );

    event FlipCleared(
        address indexed vault,
        address indexed user,
        address indexed oldReferrer
    );

    event FlipMigrated(
        address indexed vault,
        address indexed user,
        address oldReferrer,
        address newReferrer
    );

    event FlipMigrationDeferred(
        address indexed vault,
        address indexed user,
        address oldReferrer,
        address newReferrer
    );

    event SyncKeyCollision(
        address indexed user,
        address indexed localReferrer,
        address indexed incomingReferrer,
        uint256 syncKey
    );

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant CORRECTION_DELAY = 3 days;

    uint64 internal constant SEL_ONE = 1_111;

    uint256 internal constant SYNC_FEE = 0.01 ether;

    address internal user1 = address(0xA1);

    address internal user2 = address(0xA2);

    address internal refA = address(0xB1);

    address internal refB = address(0xB2);

    address internal refC = address(0xB3);

    address internal stranger = address(0xC1);

    address internal vaultA = address(0xD1);

    address internal vaultB = address(0xD2);

    address internal peerOne = address(0xE2);

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

        registry.setAllowedVault(
            vaultA,
            true
        );

        registry.setAllowedVault(
            vaultB,
            true
        );
    }

    receive()
        external
        payable
    {}

    // ---- helpers ----

    function _key(
        uint256 _assignedAt,
        uint256 _rank
    )
        internal
        pure
        returns (uint256)
    {
        return (_assignedAt << 8) | _rank;
    }

    function _assign(
        address _user,
        address _referrer
    )
        internal
    {
        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            _user,
            _referrer
        );
    }

    function _proposeAndElapse(
        address _user,
        address _newReferrer
    )
        internal
    {
        registry.proposeCorrectReferrer(
            _user,
            _newReferrer
        );

        vm.warp(
            block.timestamp + CORRECTION_DELAY
        );
    }

    function _installFlipVault()
        internal
        returns (MockCorrectionFlipVault vault)
    {
        registry.setAllowedVault(
            vaultA,
            false
        );

        registry.setAllowedVault(
            vaultB,
            false
        );

        vault = new MockCorrectionFlipVault();

        registry.setAllowedVault(
            address(vault),
            true
        );
    }

    // ---- proposeCorrectReferrer ----

    function test_proposeCorrectReferrer_storesProposalAndEmits()
        public
    {
        _assign(
            user1,
            refA
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit ReferralCorrectionProposed(
            user1,
            refA,
            refB,
            block.timestamp
        );

        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        assertEq(registry.proposedCorrection(user1), refB);
        assertEq(registry.correctionQueuedAt(user1), block.timestamp);
    }

    function test_proposeCorrectReferrer_reproposeOverwritesAndRestartsClock()
        public
    {
        _assign(
            user1,
            refA
        );

        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        uint256 firstQueuedAt = registry.correctionQueuedAt(user1);

        vm.warp(
            block.timestamp + 2 days
        );

        registry.proposeCorrectReferrer(
            user1,
            refC
        );

        assertEq(registry.proposedCorrection(user1), refC);
        assertEq(registry.correctionQueuedAt(user1), firstQueuedAt + 2 days);

        vm.warp(
            firstQueuedAt + CORRECTION_DELAY
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.CorrectionTimelockNotElapsed.selector
        );

        registry.executeCorrectReferrer(
            user1
        );
    }

    function test_proposeCorrectReferrer_revertsWhenNotMaster()
        public
    {
        _assign(
            user1,
            refA
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        registry.proposeCorrectReferrer(
            user1,
            refB
        );
    }

    function test_proposeCorrectReferrer_revertsWhenZeroReferrer()
        public
    {
        _assign(
            user1,
            refA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.ZeroAddress.selector
        );

        registry.proposeCorrectReferrer(
            user1,
            address(0)
        );
    }

    function test_proposeCorrectReferrer_revertsWhenSelfReferral()
        public
    {
        _assign(
            user1,
            refA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.SelfReferral.selector
        );

        registry.proposeCorrectReferrer(
            user1,
            user1
        );
    }

    function test_proposeCorrectReferrer_revertsWhenRegistryReferrer()
        public
    {
        _assign(
            user1,
            refA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.proposeCorrectReferrer(
            user1,
            address(registry)
        );
    }

    function test_proposeCorrectReferrer_revertsWhenVaultReferrer()
        public
    {
        _assign(
            user1,
            refA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.proposeCorrectReferrer(
            user1,
            vaultB
        );
    }

    function test_proposeCorrectReferrer_revertsWhenUserUnassigned()
        public
    {
        vm.expectRevert(
            ReferralRegistryDeclarations.NothingToCorrect.selector
        );

        registry.proposeCorrectReferrer(
            user1,
            refB
        );
    }

    function test_proposeCorrectReferrer_revertsWhenSameAsCurrent()
        public
    {
        _assign(
            user1,
            refA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.NothingToCorrect.selector
        );

        registry.proposeCorrectReferrer(
            user1,
            refA
        );
    }

    function test_proposeCorrectReferrer_revertsWhenLatched()
        public
    {
        _assign(
            user1,
            refA
        );

        registry.latchCorrections();

        vm.expectRevert(
            ReferralRegistryDeclarations.CorrectionsDisabled.selector
        );

        registry.proposeCorrectReferrer(
            user1,
            refB
        );
    }

    function test_proposeCorrectReferrer_proposalDoesNotAffectReads()
        public
    {
        _assign(
            user1,
            refA
        );

        uint256 keyBefore = registry.referrerKey(user1);

        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        assertEq(registry.referrerOf(user1), refA);
        assertEq(registry.effectiveReferrerOf(user1, vaultA), refA);
        assertEq(registry.referrerKey(user1), keyBefore);
        assertEq(registry.pendingFlip(vaultA, user1), address(0));
    }

    // ---- cancelCorrectReferrer ----

    function test_cancelCorrectReferrer_byUserClearsProposal()
        public
    {
        _assign(
            user1,
            refA
        );

        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit ReferralCorrectionCancelled(
            user1,
            refB,
            user1
        );

        vm.prank(
            user1
        );

        registry.cancelCorrectReferrer(
            user1
        );

        assertEq(registry.proposedCorrection(user1), address(0));
        assertEq(registry.correctionQueuedAt(user1), 0);
    }

    function test_cancelCorrectReferrer_byMasterClearsProposal()
        public
    {
        _assign(
            user1,
            refA
        );

        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit ReferralCorrectionCancelled(
            user1,
            refB,
            address(this)
        );

        registry.cancelCorrectReferrer(
            user1
        );

        assertEq(registry.proposedCorrection(user1), address(0));
        assertEq(registry.correctionQueuedAt(user1), 0);
    }

    function test_cancelCorrectReferrer_revertsForStranger()
        public
    {
        _assign(
            user1,
            refA
        );

        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.NotCorrectionParty.selector
        );

        registry.cancelCorrectReferrer(
            user1
        );
    }

    function test_cancelCorrectReferrer_revertsWithoutProposal()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.NoCorrectionProposed.selector
        );

        registry.cancelCorrectReferrer(
            user1
        );
    }

    function test_cancelCorrectReferrer_allowedAfterLatch()
        public
    {
        _assign(
            user1,
            refA
        );

        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        registry.latchCorrections();

        vm.prank(
            user1
        );

        registry.cancelCorrectReferrer(
            user1
        );

        assertEq(registry.proposedCorrection(user1), address(0));
        assertEq(registry.correctionQueuedAt(user1), 0);
    }

    function test_cancelCorrectReferrer_cancelledProposalCannotExecute()
        public
    {
        _assign(
            user1,
            refA
        );

        _proposeAndElapse(
            user1,
            refB
        );

        vm.prank(
            user1
        );

        registry.cancelCorrectReferrer(
            user1
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.NoCorrectionProposed.selector
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(registry.referrerOf(user1), refA);
    }

    // ---- executeCorrectReferrer ----

    function test_executeCorrectReferrer_revertsBeforeDelay()
        public
    {
        _assign(
            user1,
            refA
        );

        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        vm.warp(
            block.timestamp + CORRECTION_DELAY - 1
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.CorrectionTimelockNotElapsed.selector
        );

        registry.executeCorrectReferrer(
            user1
        );
    }

    function test_executeCorrectReferrer_flipsThroughClosure()
        public
    {
        _assign(
            user1,
            refA
        );

        uint256 keyBefore = registry.referrerKey(user1);

        _proposeAndElapse(
            user1,
            refB
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit FlipMarked(
            vaultA,
            user1,
            refA
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit FlipMarked(
            vaultB,
            user1,
            refA
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit ReferralCorrectionExecuted(
            user1,
            refA,
            refB
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(registry.referrerOf(user1), refB);
        assertEq(registry.referrerKey(user1), keyBefore);
        assertEq(registry.pendingFlip(vaultA, user1), refA);
        assertEq(registry.pendingFlip(vaultB, user1), refA);
        assertEq(registry.proposedCorrection(user1), address(0));
        assertEq(registry.correctionQueuedAt(user1), 0);
        assertEq(registry.effectiveReferrerOf(user1, vaultA), refA);
    }

    function test_executeCorrectReferrer_keepsStandingFlipMarker()
        public
    {
        _assign(
            user1,
            refA
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            refC,
            BASE_TIME - 1 days,
            0
        );

        assertEq(registry.referrerOf(user1), refC);
        assertEq(registry.pendingFlip(vaultA, user1), refA);

        _proposeAndElapse(
            user1,
            refB
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(registry.referrerOf(user1), refB);
        assertEq(registry.pendingFlip(vaultA, user1), refA);
        assertEq(registry.effectiveReferrerOf(user1, vaultA), refA);
    }

    function test_executeCorrectReferrer_thenPokeMigration_equivalentToSyncFlip()
        public
    {
        MockCorrectionFlipVault vault = _installFlipVault();

        vm.prank(
            address(vault)
        );

        registry.assignReferrer(
            user1,
            refA
        );

        _proposeAndElapse(
            user1,
            refB
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(registry.pendingFlip(address(vault), user1), refA);
        assertEq(registry.effectiveReferrerOf(user1, address(vault)), refA);

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit FlipMigrated(
            address(vault),
            user1,
            refA,
            refB
        );

        registry.pokeMigration(
            user1
        );

        assertEq(registry.pendingFlip(address(vault), user1), address(0));
        assertEq(vault.flipCallCount(), 1);
        assertEq(vault.lastUser(), user1);
        assertEq(vault.lastOldReferrer(), refA);
        assertEq(vault.lastNewReferrer(), refB);
        assertEq(registry.effectiveReferrerOf(user1, address(vault)), refB);
    }

    function test_executeCorrectReferrer_deferredVaultRestoresMarker()
        public
    {
        MockCorrectionFlipVault vault = _installFlipVault();

        vm.prank(
            address(vault)
        );

        registry.assignReferrer(
            user1,
            refA
        );

        vault.setShouldRevert(
            true
        );

        _proposeAndElapse(
            user1,
            refB
        );

        registry.executeCorrectReferrer(
            user1
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit FlipMigrationDeferred(
            address(vault),
            user1,
            refA,
            refB
        );

        registry.pokeMigration(
            user1
        );

        assertEq(registry.pendingFlip(address(vault), user1), refA);
        assertEq(vault.flipCallCount(), 0);

        vault.setShouldRevert(
            false
        );

        registry.pokeMigration(
            user1
        );

        assertEq(registry.pendingFlip(address(vault), user1), address(0));
        assertEq(vault.flipCallCount(), 1);
    }

    function test_executeCorrectReferrer_revertsWhenNotMaster()
        public
    {
        _assign(
            user1,
            refA
        );

        _proposeAndElapse(
            user1,
            refB
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        registry.executeCorrectReferrer(
            user1
        );
    }

    function test_executeCorrectReferrer_revertsWithoutProposal()
        public
    {
        vm.expectRevert(
            ReferralRegistryDeclarations.NoCorrectionProposed.selector
        );

        registry.executeCorrectReferrer(
            user1
        );
    }

    function test_executeCorrectReferrer_revertsWhenLatched()
        public
    {
        _assign(
            user1,
            refA
        );

        _proposeAndElapse(
            user1,
            refB
        );

        registry.latchCorrections();

        vm.expectRevert(
            ReferralRegistryDeclarations.CorrectionsDisabled.selector
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(registry.referrerOf(user1), refA);
    }

    function test_executeCorrectReferrer_revertsWhenDriftedToTarget()
        public
    {
        _assign(
            user1,
            refA
        );

        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            refB,
            BASE_TIME - 1 days,
            0
        );

        vm.warp(
            block.timestamp + CORRECTION_DELAY
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.NothingToCorrect.selector
        );

        registry.executeCorrectReferrer(
            user1
        );
    }

    function test_executeCorrectReferrer_marksCurrentHolderAfterPokedInterimFlip()
        public
    {
        MockCorrectionFlipVault vault = _installFlipVault();

        vm.prank(
            address(vault)
        );

        registry.assignReferrer(
            user1,
            refA
        );

        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        vm.prank(
            address(vault)
        );

        registry.mergeReferrer(
            user1,
            refC,
            BASE_TIME - 1 days,
            0
        );

        registry.pokeMigration(
            user1
        );

        assertEq(registry.referrerOf(user1), refC);
        assertEq(registry.pendingFlip(address(vault), user1), address(0));

        vm.warp(
            block.timestamp + CORRECTION_DELAY
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit ReferralCorrectionExecuted(
            user1,
            refC,
            refB
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(registry.referrerOf(user1), refB);
        assertEq(registry.pendingFlip(address(vault), user1), refC);

        registry.pokeMigration(
            user1
        );

        assertEq(vault.flipCallCount(), 2);
        assertEq(vault.lastOldReferrer(), refC);
        assertEq(vault.lastNewReferrer(), refB);
    }

    function test_executeCorrectReferrer_reCorrectionCollapsesToSingleMigration()
        public
    {
        MockCorrectionFlipVault vault = _installFlipVault();

        vm.prank(
            address(vault)
        );

        registry.assignReferrer(
            user1,
            refA
        );

        uint256 keyBefore = registry.referrerKey(user1);

        _proposeAndElapse(
            user1,
            refB
        );

        registry.executeCorrectReferrer(
            user1
        );

        _proposeAndElapse(
            user1,
            refC
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(registry.referrerOf(user1), refC);
        assertEq(registry.referrerKey(user1), keyBefore);
        assertEq(registry.pendingFlip(address(vault), user1), refA);

        registry.pokeMigration(
            user1
        );

        assertEq(vault.flipCallCount(), 1);
        assertEq(vault.lastOldReferrer(), refA);
        assertEq(vault.lastNewReferrer(), refC);
        assertEq(registry.pendingFlip(address(vault), user1), address(0));
    }

    function test_executeCorrectReferrer_backToBookHolder_clearsViaPoke()
        public
    {
        MockCorrectionFlipVault vault = _installFlipVault();

        vm.prank(
            address(vault)
        );

        registry.assignReferrer(
            user1,
            refA
        );

        vm.prank(
            address(vault)
        );

        registry.mergeReferrer(
            user1,
            refB,
            BASE_TIME - 1 days,
            0
        );

        assertEq(registry.pendingFlip(address(vault), user1), refA);

        _proposeAndElapse(
            user1,
            refA
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(registry.referrerOf(user1), refA);
        assertEq(registry.pendingFlip(address(vault), user1), refA);

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit FlipCleared(
            address(vault),
            user1,
            refA
        );

        registry.pokeMigration(
            user1
        );

        assertEq(registry.pendingFlip(address(vault), user1), address(0));
        assertEq(vault.flipCallCount(), 0);
    }

    function test_executeCorrectReferrer_strandedProposalRevivesAfterFurtherDrift()
        public
    {
        _assign(
            user1,
            refA
        );

        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            refB,
            BASE_TIME - 1 days,
            0
        );

        vm.warp(
            block.timestamp + CORRECTION_DELAY
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.NothingToCorrect.selector
        );

        registry.executeCorrectReferrer(
            user1
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            refC,
            BASE_TIME - 2 days,
            0
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(registry.referrerOf(user1), refB);
        assertEq(registry.referrerKey(user1), _key(BASE_TIME - 2 days, 0));
        assertEq(registry.proposedCorrection(user1), address(0));
        assertEq(registry.correctionQueuedAt(user1), 0);
    }

    function test_executeCorrectReferrer_revertsWhenTargetBecameVault()
        public
    {
        _assign(
            user1,
            refA
        );

        _proposeAndElapse(
            user1,
            refB
        );

        registry.setAllowedVault(
            refB,
            true
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(registry.referrerOf(user1), refA);
    }

    function testFuzz_executeCorrectReferrer_timelockBoundary(
        uint256 _delay
    )
        public
    {
        uint256 delay = bound(
            _delay,
            0,
            10 days
        );

        _assign(
            user1,
            refA
        );

        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        vm.warp(
            BASE_TIME + delay
        );

        if (delay < CORRECTION_DELAY) {

            vm.expectRevert(
                ReferralRegistryDeclarations.CorrectionTimelockNotElapsed.selector
            );

            registry.executeCorrectReferrer(
                user1
            );

            assertEq(registry.referrerOf(user1), refA);

            return;
        }

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(registry.referrerOf(user1), refB);
    }

    // ---- latchCorrections ----

    function test_latchCorrections_setsAndEmits()
        public
    {
        assertFalse(registry.correctionsLatched());

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(registry)
        );

        emit CorrectionsLatched();

        registry.latchCorrections();

        assertTrue(registry.correctionsLatched());
    }

    function test_latchCorrections_revertsWhenNotMaster()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        registry.latchCorrections();
    }

    function test_latchCorrections_revertsWhenAlreadyLatched()
        public
    {
        registry.latchCorrections();

        vm.expectRevert(
            ReferralRegistryDeclarations.CorrectionsAlreadyLatched.selector
        );

        registry.latchCorrections();

        assertTrue(registry.correctionsLatched());
    }

    // ---- sync interplay after a correction ----

    function test_correction_equalKeyEchoIgnoredWithCollision()
        public
    {
        _assign(
            user1,
            refA
        );

        _proposeAndElapse(
            user1,
            refB
        );

        registry.executeCorrectReferrer(
            user1
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit SyncKeyCollision(
            user1,
            refB,
            refA,
            _key(
                BASE_TIME,
                0
            )
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            refA,
            BASE_TIME,
            0
        );

        assertEq(registry.referrerOf(user1), refB);
        assertEq(registry.referrerKey(user1), _key(BASE_TIME, 0));
    }

    function test_correction_lowerKeyStillFlips()
        public
    {
        _assign(
            user1,
            refA
        );

        _proposeAndElapse(
            user1,
            refB
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(registry.pendingFlip(vaultA, user1), refA);

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            refC,
            BASE_TIME - 1 days,
            0
        );

        assertEq(registry.referrerOf(user1), refC);
        assertEq(registry.referrerKey(user1), _key(BASE_TIME - 1 days, 0));
        assertEq(registry.pendingFlip(vaultA, user1), refA);
    }

    function test_correction_broadcastSendsNewReferrerWithOriginalKey()
        public
    {
        _assign(
            user1,
            refA
        );

        MockCorrectionCcipRouter router = new MockCorrectionCcipRouter(
            SYNC_FEE
        );

        registry.setCcipRouter(
            address(router)
        );

        registry.proposeSyncPeer(
            SEL_ONE,
            peerOne
        );

        registry.executeSyncPeerChange(
            SEL_ONE
        );

        _proposeAndElapse(
            user1,
            refB
        );

        registry.executeCorrectReferrer(
            user1
        );

        uint64[] memory lanes = new uint64[](1);

        lanes[0] = SEL_ONE;

        registry.broadcastSync{value: SYNC_FEE}(
            user1,
            lanes
        );

        (
            ,
            address sentUser,
            address sentReferrer,
            uint256 sentAssignedAt,
            uint256 sentRank
        ) = abi.decode(
            router.lastData(),
            (uint256, address, address, uint256, uint256)
        );

        assertEq(sentUser, user1);
        assertEq(sentReferrer, refB);
        assertEq(sentAssignedAt, BASE_TIME);
        assertEq(sentRank, 0);
    }

    function test_correction_ofMergeAdoptedReferrer_keepsForeignKey()
        public
    {
        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            refA,
            BASE_TIME - 5 days,
            3
        );

        uint256 foreignKey = _key(
            BASE_TIME - 5 days,
            3
        );

        assertEq(registry.referrerKey(user1), foreignKey);

        MockCorrectionCcipRouter router = new MockCorrectionCcipRouter(
            SYNC_FEE
        );

        registry.setCcipRouter(
            address(router)
        );

        registry.proposeSyncPeer(
            SEL_ONE,
            peerOne
        );

        registry.executeSyncPeerChange(
            SEL_ONE
        );

        _proposeAndElapse(
            user1,
            refB
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(registry.referrerOf(user1), refB);
        assertEq(registry.referrerKey(user1), foreignKey);

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit SyncKeyCollision(
            user1,
            refB,
            refA,
            foreignKey
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            refA,
            BASE_TIME - 5 days,
            3
        );

        assertEq(registry.referrerOf(user1), refB);

        uint64[] memory lanes = new uint64[](1);

        lanes[0] = SEL_ONE;

        registry.broadcastSync{value: SYNC_FEE}(
            user1,
            lanes
        );

        (
            ,
            address sentUser,
            address sentReferrer,
            uint256 sentAssignedAt,
            uint256 sentRank
        ) = abi.decode(
            router.lastData(),
            (uint256, address, address, uint256, uint256)
        );

        assertEq(sentUser, user1);
        assertEq(sentReferrer, refB);
        assertEq(sentAssignedAt, BASE_TIME - 5 days);
        assertEq(sentRank, 3);
    }

    function test_correction_multiUserProposalsIndependent()
        public
    {
        _assign(
            user1,
            refA
        );

        _assign(
            user2,
            refA
        );

        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        registry.proposeCorrectReferrer(
            user2,
            refC
        );

        vm.prank(
            user2
        );

        registry.cancelCorrectReferrer(
            user2
        );

        vm.warp(
            block.timestamp + CORRECTION_DELAY
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(registry.referrerOf(user1), refB);
        assertEq(registry.referrerOf(user2), refA);
        assertEq(registry.proposedCorrection(user2), address(0));
        assertEq(registry.pendingFlip(vaultA, user2), address(0));
    }

    function test_correction_assignReferrerStillIgnoredAfterCorrection()
        public
    {
        _assign(
            user1,
            refA
        );

        _proposeAndElapse(
            user1,
            refB
        );

        registry.executeCorrectReferrer(
            user1
        );

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refC
        );

        assertEq(registry.referrerOf(user1), refB);
    }
}
