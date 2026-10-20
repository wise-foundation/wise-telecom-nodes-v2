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
 * mis-assigned `(user, referrer)` pair, the ONE-WAY corrections
 * latch that permanently retires the lane (a manual master action
 * that no rollout step fires, so the lane stays open after payouts
 * arm), and the separate ONE-WAY seed latch that closes the vaults'
 * retroactive seeding while leaving the correction lane open. Pins:
 * the propose guards (master gate, assignment-shaped referrer
 * validation including the vault and registry laundering rejects,
 * where a revoked vault stays a vault and can never become the
 * corrected referrer at propose or at execute, nothing-to-correct
 * arms), the unilateral user cancel plus master cancel with cancel
 * surviving the latch, the timelock boundary (fuzzed), the seed
 * latch section (master gate, one-way revert, propose and execute
 * still working after it, the two latches never setting each other,
 * and the corrections latch still closing the lane when both are
 * set), and (the core of the design) that execution rides the
 * EXISTING flip closure: identical pending-flip markers with
 * keep-if-set, identical `pokeMigration` migrate/defer arms,
 * identical `effectiveReferrerOf` redirect while a marker stands.
 *
 * The corrected key. Every genuine key carries a timestamp at or
 * above SYNC_KEY_FLOOR (1_700_000_000). A correction executed at
 * clock T mints the key whose timestamp field is T mirrored below the
 * floor, SYNC_KEY_MIRROR minus T, where SYNC_KEY_MIRROR is twice the
 * floor minus one (3_399_999_999), packed with the executing
 * registry's rank (`_correctedAt` computes the mirrored field). The
 * pins show the minted key in storage, in `getReferrerPair`, in the
 * executed event and in the broadcast payload; that a re-correction
 * sorts strictly below the first; that stale genuine echoes of the
 * old pair, earlier genuine keys and even the earliest possible
 * genuine key (the floor itself) are ignored silently afterwards;
 * that a later peer correction (smaller key) flips, an earlier one is
 * ignored and a same-target one only lowers the key; and that three
 * registries of ranks 0, 1 and 2 converge on the corrected pair
 * whichever of the corrected and the stale genuine pair arrives
 * first. Relayed peer corrections arrive with the clock warped to the
 * peer's execution time, because the merge admits a key only while
 * its timestamp plus the local clock plus the one-hour drift
 * allowance reaches the mirror.
 *
 * The binding and the origin gate. Propose stores the exact key the
 * user holds; execute requires that key still held, so an interim
 * flip, an interim key lowering to the same referrer, or a drift to
 * the target kills the proposal with NothingToCorrect and it never
 * revives. Propose requires the held key's rank to be this
 * registry's rank (WrongCorrectionChain otherwise), so a user adopted
 * from a foreign rank, or moved to one by an interim flip, is
 * corrected only on the chain that minted the held key.
 *
 * The horizon. A correction executed one second before the clock
 * reaches the mirror mints timestamp field 1; one executed at the
 * mirror (also on a registry of rank 2), past it, or against a held
 * genuine key below the floor reverts CorrectionKeyNotLower.
 *
 * Latch one-way-ness is pinned by the propose/execute rejects after
 * the latch plus the absence of any unlatch surface. Mock flip vault
 * and router live at the top of this file.
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
        address indexed newReferrer,
        uint256 syncKey
    );

    event CorrectionsLatched();

    event SeedsLatched();

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

    event ReferralSyncKeyLowered(
        address indexed user,
        address indexed referrer,
        uint256 oldKey,
        uint256 newKey
    );

    event ReferralSyncFlipped(
        address indexed user,
        address indexed oldReferrer,
        address indexed newReferrer,
        uint256 syncKey
    );

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant CORRECTION_DELAY = 3 days;

    uint256 internal constant SYNC_KEY_FLOOR = 1_700_000_000;

    uint256 internal constant SYNC_KEY_MIRROR = 2 * SYNC_KEY_FLOOR - 1;

    uint256 internal constant KEY_RANK_MASK = 255;

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

    address internal hubAddress = address(0xE1);

    uint64 internal constant SEL_HUB = 50_001;

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

    function _correctedAt(
        uint256 _at
    )
        internal
        pure
        returns (uint256)
    {
        return SYNC_KEY_MIRROR - _at;
    }

    function _relay(
        ReferralRegistry _target,
        address _user,
        address _referrer,
        uint256 _assignedAt,
        uint256 _rank
    )
        internal
    {
        vm.prank(
            vaultA
        );

        _target.mergeReferrer(
            _user,
            _referrer,
            _assignedAt,
            _rank
        );
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

        assertEq(
            registry.proposedCorrection(
                user1
            ),
            refB
        );

        assertEq(
            registry.correctionQueuedAt(
                user1
            ),
            block.timestamp
        );
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

        uint256 firstQueuedAt = registry.correctionQueuedAt(
            user1
        );

        vm.warp(
            block.timestamp + 2 days
        );

        registry.proposeCorrectReferrer(
            user1,
            refC
        );

        assertEq(
            registry.proposedCorrection(
                user1
            ),
            refC
        );

        assertEq(
            registry.correctionQueuedAt(
                user1
            ),
            firstQueuedAt + 2 days
        );

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

    function test_proposeCorrectReferrer_revertsWhenRevokedVaultReferrer()
        public
    {
        _assign(
            user1,
            refA
        );

        registry.setAllowedVault(
            vaultB,
            false
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.proposeCorrectReferrer(
            user1,
            vaultB
        );

        assertEq(
            registry.proposedCorrection(
                user1
            ),
            address(0)
        );

        assertEq(
            registry.correctionQueuedAt(
                user1
            ),
            0
        );
    }

    function test_proposeCorrectReferrer_assignsUnassignedUser()
        public
    {
        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit ReferralCorrectionProposed(
            user1,
            address(0),
            refB,
            block.timestamp
        );

        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        assertEq(
            registry.proposedCorrection(
                user1
            ),
            refB
        );

        assertEq(
            registry.proposedCorrectionKey(
                user1
            ),
            0
        );
    }

    function test_executeCorrectReferrer_assignsUnassignedUserWithMirroredKey()
        public
    {
        _proposeAndElapse(
            user1,
            refB
        );

        uint256 mintedKey = _key(
            _correctedAt(
                block.timestamp
            ),
            0
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
            address(0),
            refB,
            mintedKey
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refB
        );

        assertEq(
            registry.referrerKey(
                user1
            ),
            mintedKey
        );

        assertEq(
            registry.pendingFlip(
                vaultA,
                user1
            ),
            address(0)
        );

        assertEq(
            registry.correctionQueuedAt(
                user1
            ),
            0
        );
    }

    function test_executeCorrectReferrer_unassignedUserVetoCancels()
        public
    {
        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        vm.prank(
            user1
        );
        registry.cancelCorrectReferrer(
            user1
        );

        vm.warp(
            block.timestamp + CORRECTION_DELAY
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.NoCorrectionProposed.selector
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            address(0)
        );
    }

    function test_executeCorrectReferrer_unassignedUserSelfAssignedDuringWindowReverts()
        public
    {
        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        _assign(
            user1,
            refA
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

    function test_RevertWhen_proposeCorrectReferrer_ringThroughCorrectionLane()
        public
    {
        _assign(
            refA,
            user1
        );

        _assign(
            refB,
            refA
        );

        _assign(
            refC,
            refB
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.proposeCorrectReferrer(
            user1,
            refC
        );

        assertEq(
            registry.proposedCorrection(
                user1
            ),
            address(0)
        );
    }

    function test_RevertWhen_proposeCorrectReferrer_payoutHubAsReferrer()
        public
    {
        _assign(
            user1,
            refA
        );

        registry.proposePayoutHub(
            hubAddress,
            SEL_HUB
        );

        registry.executePayoutHubChange();

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.proposeCorrectReferrer(
            user1,
            hubAddress
        );
    }

    function test_RevertWhen_proposeCorrectReferrer_mutualPair()
        public
    {
        _assign(
            refB,
            user1
        );

        _assign(
            user1,
            refA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        assertEq(
            registry.proposedCorrection(
                user1
            ),
            address(0)
        );
    }

    function test_RevertWhen_executeCorrectReferrer_pairFormedInsideWindow()
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

        _assign(
            refB,
            user1
        );

        vm.warp(
            block.timestamp + CORRECTION_DELAY
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refA
        );
    }

    function test_executeCorrectReferrer_assignsUnassignedUserOnNonZeroRank()
        public
    {
        ReferralRegistry rankTwo = new ReferralRegistry(
            address(this),
            2
        );

        rankTwo.proposeCorrectReferrer(
            user1,
            refB
        );

        vm.warp(
            block.timestamp + CORRECTION_DELAY
        );

        rankTwo.executeCorrectReferrer(
            user1
        );

        assertEq(
            rankTwo.referrerOf(
                user1
            ),
            refB
        );

        assertEq(
            rankTwo.referrerKey(
                user1
            ),
            _key(
                _correctedAt(
                    block.timestamp
                ),
                2
            )
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

        uint256 keyBefore = registry.referrerKey(
            user1
        );

        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refA
        );

        assertEq(
            registry.effectiveReferrerOf(
                user1,
                vaultA
            ),
            refA
        );

        assertEq(
            registry.referrerKey(
                user1
            ),
            keyBefore
        );

        assertEq(
            registry.pendingFlip(
                vaultA,
                user1
            ),
            address(0)
        );
    }

    function test_proposeCorrectReferrer_storesHeldKey()
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

        assertEq(
            registry.proposedCorrectionKey(
                user1
            ),
            registry.referrerKey(
                user1
            )
        );

        assertEq(
            registry.proposedCorrectionKey(
                user1
            ),
            _key(
                BASE_TIME,
                0
            )
        );
    }

    function test_proposeCorrectReferrer_revertsWhenHeldKeyIsForeign()
        public
    {
        _relay(
            registry,
            user1,
            refA,
            BASE_TIME - 5 days,
            3
        );

        uint256 foreignKey = _key(
            BASE_TIME - 5 days,
            3
        );

        assertEq(
            registry.referrerKey(
                user1
            ),
            foreignKey
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.WrongCorrectionChain.selector
        );

        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refA
        );

        assertEq(
            registry.referrerKey(
                user1
            ),
            foreignKey
        );

        assertEq(
            registry.proposedCorrection(
                user1
            ),
            address(0)
        );

        assertEq(
            registry.proposedCorrectionKey(
                user1
            ),
            0
        );
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

        assertEq(
            registry.proposedCorrection(
                user1
            ),
            address(0)
        );

        assertEq(
            registry.correctionQueuedAt(
                user1
            ),
            0
        );
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

        assertEq(
            registry.proposedCorrection(
                user1
            ),
            address(0)
        );

        assertEq(
            registry.correctionQueuedAt(
                user1
            ),
            0
        );
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

        assertEq(
            registry.proposedCorrection(
                user1
            ),
            address(0)
        );

        assertEq(
            registry.correctionQueuedAt(
                user1
            ),
            0
        );
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

        assertEq(
            registry.referrerOf(
                user1
            ),
            refA
        );
    }

    function test_cancelCorrectReferrer_clearsHeldKey()
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

        assertEq(
            registry.proposedCorrectionKey(
                user1
            ),
            _key(
                BASE_TIME,
                0
            )
        );

        vm.prank(
            user1
        );

        registry.cancelCorrectReferrer(
            user1
        );

        assertEq(
            registry.proposedCorrectionKey(
                user1
            ),
            0
        );
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

        _proposeAndElapse(
            user1,
            refB
        );

        uint256 executedAt = block.timestamp;

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
            refB,
            _key(
                _correctedAt(
                    executedAt
                ),
                0
            )
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refB
        );

        assertEq(
            registry.referrerKey(
                user1
            ),
            _key(
                _correctedAt(
                    executedAt
                ),
                0
            )
        );

        assertEq(
            registry.pendingFlip(
                vaultA,
                user1
            ),
            refA
        );

        assertEq(
            registry.pendingFlip(
                vaultB,
                user1
            ),
            refA
        );

        assertEq(
            registry.proposedCorrection(
                user1
            ),
            address(0)
        );

        assertEq(
            registry.correctionQueuedAt(
                user1
            ),
            0
        );

        assertEq(
            registry.effectiveReferrerOf(
                user1,
                vaultA
            ),
            refA
        );

        (
            address referrer,
            uint256 assignedAt,
            uint256 rank
        ) = registry.getReferrerPair(
            user1
        );

        assertEq(
            referrer,
            refB
        );

        assertEq(
            assignedAt,
            _correctedAt(
                executedAt
            )
        );

        assertEq(
            rank,
            0
        );
    }

    function test_executeCorrectReferrer_clearsHeldKey()
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

        assertEq(
            registry.proposedCorrectionKey(
                user1
            ),
            0
        );
    }

    function test_executeCorrectReferrer_mintsMirroredKey()
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

        uint256 mintedKey = _key(
            _correctedAt(
                block.timestamp
            ),
            0
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
            refB,
            mintedKey
        );

        registry.executeCorrectReferrer(
            user1
        );

        (
            address referrer,
            uint256 assignedAt,
            uint256 rank
        ) = registry.getReferrerPair(
            user1
        );

        assertEq(
            registry.referrerKey(
                user1
            ),
            mintedKey
        );

        assertEq(
            referrer,
            refB
        );

        assertEq(
            assignedAt,
            _correctedAt(
                block.timestamp
            )
        );

        assertEq(
            rank,
            0
        );

        assertLt(
            mintedKey,
            _key(
                SYNC_KEY_FLOOR,
                0
            )
        );

        assertGt(
            mintedKey,
            0
        );
    }

    function test_executeCorrectReferrer_correctedKeyRankIsLocal()
        public
    {
        ReferralRegistry rankTwo = new ReferralRegistry(
            address(this),
            2
        );

        rankTwo.setAllowedVault(
            vaultA,
            true
        );

        _assign(
            user1,
            refA
        );

        vm.prank(
            vaultA
        );

        rankTwo.assignReferrer(
            user1,
            refA
        );

        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        rankTwo.proposeCorrectReferrer(
            user1,
            refB
        );

        vm.warp(
            block.timestamp + CORRECTION_DELAY
        );

        registry.executeCorrectReferrer(
            user1
        );

        rankTwo.executeCorrectReferrer(
            user1
        );

        assertEq(registry.referrerKey(user1) & KEY_RANK_MASK, 0);
        assertEq(rankTwo.referrerKey(user1) & KEY_RANK_MASK, 2);

        assertEq(
            registry.referrerKey(
                user1
            ),
            _key(
                _correctedAt(
                    block.timestamp
                ),
                0
            )
        );

        assertEq(
            rankTwo.referrerKey(
                user1
            ),
            _key(
                _correctedAt(
                    block.timestamp
                ),
                2
            )
        );
    }

    function test_executeCorrectReferrer_lastSecondBeforeHorizonMintsKeyOne()
        public
    {
        vm.warp(
            SYNC_KEY_MIRROR - 1 - CORRECTION_DELAY
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
            SYNC_KEY_MIRROR - 1
        );

        registry.executeCorrectReferrer(
            user1
        );

        (
            address referrer,
            uint256 assignedAt,
            uint256 rank
        ) = registry.getReferrerPair(
            user1
        );

        assertEq(
            referrer,
            refB
        );

        assertEq(
            assignedAt,
            1
        );

        assertEq(
            rank,
            0
        );

        assertEq(
            registry.referrerKey(
                user1
            ),
            _key(
                1,
                0
            )
        );
    }

    function test_executeCorrectReferrer_revertsAtHorizon()
        public
    {
        vm.warp(
            SYNC_KEY_MIRROR - 1 - CORRECTION_DELAY
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
            SYNC_KEY_MIRROR
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.CorrectionKeyNotLower.selector
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refA
        );

        assertEq(
            registry.proposedCorrection(
                user1
            ),
            refB
        );
    }

    function test_executeCorrectReferrer_revertsAtHorizonOnNonZeroRank()
        public
    {
        ReferralRegistry rankTwo = new ReferralRegistry(
            address(this),
            2
        );

        rankTwo.setAllowedVault(
            vaultA,
            true
        );

        vm.warp(
            SYNC_KEY_MIRROR - CORRECTION_DELAY
        );

        vm.prank(
            vaultA
        );

        rankTwo.assignReferrer(
            user1,
            refA
        );

        rankTwo.proposeCorrectReferrer(
            user1,
            refB
        );

        vm.warp(
            SYNC_KEY_MIRROR
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.CorrectionKeyNotLower.selector
        );

        rankTwo.executeCorrectReferrer(
            user1
        );

        assertEq(
            rankTwo.referrerOf(
                user1
            ),
            refA
        );

        assertEq(
            rankTwo.referrerKey(
                user1
            ),
            _key(
                SYNC_KEY_MIRROR - CORRECTION_DELAY,
                2
            )
        );
    }

    function test_executeCorrectReferrer_revertsPastHorizon()
        public
    {
        vm.warp(
            SYNC_KEY_MIRROR - CORRECTION_DELAY
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
            SYNC_KEY_MIRROR + 1
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.CorrectionKeyNotLower.selector
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refA
        );

        assertEq(
            registry.referrerKey(
                user1
            ),
            _key(
                SYNC_KEY_MIRROR - CORRECTION_DELAY,
                0
            )
        );
    }

    function test_executeCorrectReferrer_revertsWhenHeldKeyBelowFloor()
        public
    {
        vm.warp(
            1_000_000
        );

        ReferralRegistry early = new ReferralRegistry(
            address(this),
            0
        );

        early.setAllowedVault(
            vaultA,
            true
        );

        vm.prank(
            vaultA
        );

        early.assignReferrer(
            user1,
            refA
        );

        early.proposeCorrectReferrer(
            user1,
            refB
        );

        vm.warp(
            block.timestamp + CORRECTION_DELAY
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.CorrectionKeyNotLower.selector
        );

        early.executeCorrectReferrer(
            user1
        );

        assertEq(
            early.referrerOf(
                user1
            ),
            refA
        );

        assertEq(
            early.referrerKey(
                user1
            ),
            _key(
                1_000_000,
                0
            )
        );
    }

    function test_executeCorrectReferrer_revokedVaultStillMarkedAndMigrated()
        public
    {
        MockCorrectionFlipVault vault = _installFlipVault();

        MockCorrectionFlipVault revoked = new MockCorrectionFlipVault();

        registry.setAllowedVault(
            address(revoked),
            true
        );

        _assign(
            user1,
            refA
        );

        registry.setAllowedVault(
            address(revoked),
            false
        );

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
            address(revoked),
            user1,
            refA
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(
            registry.pendingFlip(
                address(revoked),
                user1
            ),
            refA
        );

        assertEq(
            registry.effectiveReferrerOf(
                user1,
                address(revoked)
            ),
            refA
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            registry.pendingFlip(
                address(revoked),
                user1
            ),
            address(0)
        );

        assertEq(
            revoked.flipCallCount(),
            1
        );

        assertEq(
            revoked.lastNewReferrer(),
            refB
        );

        assertEq(
            vault.flipCallCount(),
            1
        );
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

        assertEq(
            registry.referrerOf(
                user1
            ),
            refC
        );

        assertEq(
            registry.pendingFlip(
                vaultA,
                user1
            ),
            refA
        );

        _proposeAndElapse(
            user1,
            refB
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refB
        );

        assertEq(
            registry.pendingFlip(
                vaultA,
                user1
            ),
            refA
        );

        assertEq(
            registry.effectiveReferrerOf(
                user1,
                vaultA
            ),
            refA
        );
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

        assertEq(
            registry.pendingFlip(
                address(vault),
                user1
            ),
            refA
        );

        assertEq(
            registry.effectiveReferrerOf(
                user1,
                address(vault)
            ),
            refA
        );

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

        assertEq(
            registry.pendingFlip(
                address(vault),
                user1
            ),
            address(0)
        );

        assertEq(
            vault.flipCallCount(),
            1
        );

        assertEq(
            vault.lastUser(),
            user1
        );

        assertEq(
            vault.lastOldReferrer(),
            refA
        );

        assertEq(
            vault.lastNewReferrer(),
            refB
        );

        assertEq(
            registry.effectiveReferrerOf(
                user1,
                address(vault)
            ),
            refB
        );
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

        assertEq(
            registry.pendingFlip(
                address(vault),
                user1
            ),
            refA
        );

        assertEq(
            vault.flipCallCount(),
            0
        );

        vault.setShouldRevert(
            false
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            registry.pendingFlip(
                address(vault),
                user1
            ),
            address(0)
        );

        assertEq(
            vault.flipCallCount(),
            1
        );
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

        assertEq(
            registry.referrerOf(
                user1
            ),
            refA
        );
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

    function test_executeCorrectReferrer_revertsWhenSameReferrerKeyLoweredDuringWindow()
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

        _relay(
            registry,
            user1,
            refA,
            BASE_TIME - 1 days,
            1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refA
        );

        assertEq(
            registry.referrerKey(
                user1
            ),
            _key(
                BASE_TIME - 1 days,
                1
            )
        );

        assertEq(
            registry.pendingFlip(
                vaultA,
                user1
            ),
            address(0)
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

        vm.expectRevert(
            ReferralRegistryDeclarations.WrongCorrectionChain.selector
        );

        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refA
        );

        assertEq(
            registry.referrerKey(
                user1
            ),
            _key(
                BASE_TIME - 1 days,
                1
            )
        );
    }

    function test_executeCorrectReferrer_interimFlipKillsProposalAndMovesLane()
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
            1
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refC
        );

        assertEq(
            registry.pendingFlip(
                address(vault),
                user1
            ),
            address(0)
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

        vm.expectRevert(
            ReferralRegistryDeclarations.WrongCorrectionChain.selector
        );

        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refC
        );

        assertEq(
            registry.referrerKey(
                user1
            ),
            _key(
                BASE_TIME - 1 days,
                1
            )
        );

        assertEq(
            registry.pendingFlip(
                address(vault),
                user1
            ),
            address(0)
        );

        assertEq(
            vault.flipCallCount(),
            1
        );

        assertEq(
            vault.lastOldReferrer(),
            refA
        );

        assertEq(
            vault.lastNewReferrer(),
            refC
        );
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

        _proposeAndElapse(
            user1,
            refB
        );

        registry.executeCorrectReferrer(
            user1
        );

        uint256 firstCorrectedKey = registry.referrerKey(
            user1
        );

        _proposeAndElapse(
            user1,
            refC
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refC
        );

        assertLt(
            registry.referrerKey(
                user1
            ),
            firstCorrectedKey
        );

        assertEq(
            registry.referrerKey(
                user1
            ),
            _key(
                _correctedAt(
                    block.timestamp
                ),
                0
            )
        );

        assertEq(
            registry.pendingFlip(
                address(vault),
                user1
            ),
            refA
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            vault.flipCallCount(),
            1
        );

        assertEq(
            vault.lastOldReferrer(),
            refA
        );

        assertEq(
            vault.lastNewReferrer(),
            refC
        );

        assertEq(
            registry.pendingFlip(
                address(vault),
                user1
            ),
            address(0)
        );
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

        assertEq(
            registry.pendingFlip(
                address(vault),
                user1
            ),
            refA
        );

        _proposeAndElapse(
            user1,
            refA
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refA
        );

        assertEq(
            registry.pendingFlip(
                address(vault),
                user1
            ),
            refA
        );

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

        assertEq(
            registry.pendingFlip(
                address(vault),
                user1
            ),
            address(0)
        );

        assertEq(
            vault.flipCallCount(),
            0
        );
    }

    function test_executeCorrectReferrer_strandedProposalStaysDeadAfterFurtherDrift()
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

        vm.expectRevert(
            ReferralRegistryDeclarations.NothingToCorrect.selector
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refC
        );

        assertEq(
            registry.referrerKey(
                user1
            ),
            _key(
                BASE_TIME - 2 days,
                0
            )
        );

        assertEq(
            registry.proposedCorrection(
                user1
            ),
            refB
        );

        assertEq(
            registry.correctionQueuedAt(
                user1
            ),
            BASE_TIME
        );

        assertEq(
            registry.proposedCorrectionKey(
                user1
            ),
            _key(
                BASE_TIME,
                0
            )
        );
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

        assertEq(
            registry.referrerOf(
                user1
            ),
            refA
        );
    }

    function test_executeCorrectReferrer_revertsWhenTargetIsRevokedVault()
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

        registry.setAllowedVault(
            refB,
            false
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refA
        );

        assertEq(
            registry.proposedCorrection(
                user1
            ),
            refB
        );
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

            assertEq(
                registry.referrerOf(
                    user1
                ),
                refA
            );

            return;
        }

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refB
        );
    }

    // ---- latchCorrections ----

    function test_latchCorrections_setsAndEmits()
        public
    {
        assertFalse(
            registry.correctionsLatched()
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(registry)
        );

        emit CorrectionsLatched();

        registry.latchCorrections();

        assertTrue(
            registry.correctionsLatched()
        );
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

        assertTrue(
            registry.correctionsLatched()
        );
    }

    // ---- latchSeeds ----

    function test_latchSeeds_setsAndEmits()
        public
    {
        assertFalse(
            registry.seedsLatched()
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(registry)
        );

        emit SeedsLatched();

        registry.latchSeeds();

        assertTrue(
            registry.seedsLatched()
        );
    }

    function test_latchSeeds_revertsWhenNotMaster()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        registry.latchSeeds();
    }

    function test_latchSeeds_revertsWhenAlreadyLatched()
        public
    {
        registry.latchSeeds();

        vm.expectRevert(
            ReferralRegistryDeclarations.SeedsAlreadyLatched.selector
        );

        registry.latchSeeds();

        assertTrue(
            registry.seedsLatched()
        );
    }

    function test_latchSeeds_doesNotBlockProposeOrExecute()
        public
    {
        _assign(
            user1,
            refA
        );

        registry.latchSeeds();

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
            refA,
            refB,
            _key(
                _correctedAt(
                    block.timestamp
                ),
                0
            )
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refB
        );
    }

    function test_latchSeeds_doesNotSetCorrectionsLatch()
        public
    {
        registry.latchSeeds();

        assertTrue(
            registry.seedsLatched()
        );

        assertFalse(
            registry.correctionsLatched()
        );

        ReferralRegistry fresh = new ReferralRegistry(
            address(this),
            0
        );

        fresh.latchCorrections();

        assertTrue(
            fresh.correctionsLatched()
        );

        assertFalse(
            fresh.seedsLatched()
        );
    }

    function test_latchCorrections_afterSeedsLatched_stillClosesLane()
        public
    {
        _assign(
            user1,
            refA
        );

        registry.latchSeeds();

        registry.latchCorrections();

        assertTrue(
            registry.seedsLatched()
        );

        assertTrue(
            registry.correctionsLatched()
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.CorrectionsDisabled.selector
        );

        registry.proposeCorrectReferrer(
            user1,
            refB
        );
    }

    // ---- sync interplay after a correction ----

    function test_correction_staleGenuineEchoIgnoredSilently()
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

        uint256 executedAt = block.timestamp;

        registry.executeCorrectReferrer(
            user1
        );

        vm.recordLogs();

        _relay(
            registry,
            user1,
            refA,
            BASE_TIME,
            0
        );

        assertEq(
            vm.getRecordedLogs().length,
            0
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refB
        );

        assertEq(
            registry.referrerKey(
                user1
            ),
            _key(
                _correctedAt(
                    executedAt
                ),
                0
            )
        );
    }

    function test_correction_earlierGenuineKeyNoLongerFlips()
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

        uint256 executedAt = block.timestamp;

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(
            registry.pendingFlip(
                vaultA,
                user1
            ),
            refA
        );

        _relay(
            registry,
            user1,
            refC,
            BASE_TIME - 1 days,
            1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refB
        );

        assertEq(
            registry.referrerKey(
                user1
            ),
            _key(
                _correctedAt(
                    executedAt
                ),
                0
            )
        );

        assertEq(
            registry.pendingFlip(
                vaultA,
                user1
            ),
            refA
        );
    }

    function test_correction_genuineKeyNeverOverrides()
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

        uint256 executedAt = block.timestamp;

        registry.executeCorrectReferrer(
            user1
        );

        vm.recordLogs();

        _relay(
            registry,
            user1,
            refC,
            SYNC_KEY_FLOOR,
            1
        );

        assertEq(
            vm.getRecordedLogs().length,
            0
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refB
        );

        assertEq(
            registry.referrerKey(
                user1
            ),
            _key(
                _correctedAt(
                    executedAt
                ),
                0
            )
        );
    }

    function test_correction_laterPeerCorrectionFlips()
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

        uint256 executedAt = block.timestamp;

        registry.executeCorrectReferrer(
            user1
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            registry.pendingFlip(
                address(vault),
                user1
            ),
            address(0)
        );

        vm.warp(
            executedAt + 1 days
        );

        uint256 peerKey = _key(
            _correctedAt(
                executedAt + 1 days
            ),
            1
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit FlipMarked(
            address(vault),
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

        emit ReferralSyncFlipped(
            user1,
            refB,
            refC,
            peerKey
        );

        vm.prank(
            address(vault)
        );

        registry.mergeReferrer(
            user1,
            refC,
            _correctedAt(
                executedAt + 1 days
            ),
            1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refC
        );

        assertEq(
            registry.referrerKey(
                user1
            ),
            peerKey
        );

        assertEq(
            registry.pendingFlip(
                address(vault),
                user1
            ),
            refB
        );

        assertEq(
            registry.pendingFlip(
                vaultA,
                user1
            ),
            refB
        );

        assertEq(
            registry.effectiveReferrerOf(
                user1,
                address(vault)
            ),
            refB
        );
    }

    function test_correction_earlierPeerCorrectionIgnored()
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

        uint256 executedAt = block.timestamp;

        registry.executeCorrectReferrer(
            user1
        );

        vm.recordLogs();

        _relay(
            registry,
            user1,
            refC,
            _correctedAt(
                executedAt - 1 days
            ),
            1
        );

        assertEq(
            vm.getRecordedLogs().length,
            0
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refB
        );

        assertEq(
            registry.referrerKey(
                user1
            ),
            _key(
                _correctedAt(
                    executedAt
                ),
                0
            )
        );
    }

    function test_correction_sameTargetPeerCorrectionLowersKeyOnly()
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

        uint256 executedAt = block.timestamp;

        registry.executeCorrectReferrer(
            user1
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            registry.pendingFlip(
                address(vault),
                user1
            ),
            address(0)
        );

        vm.warp(
            executedAt + 1 days
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit ReferralSyncKeyLowered(
            user1,
            refB,
            _key(
                _correctedAt(
                    executedAt
                ),
                0
            ),
            _key(
                _correctedAt(
                    executedAt + 1 days
                ),
                1
            )
        );

        vm.prank(
            address(vault)
        );

        registry.mergeReferrer(
            user1,
            refB,
            _correctedAt(
                executedAt + 1 days
            ),
            1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refB
        );

        assertEq(
            registry.referrerKey(
                user1
            ),
            _key(
                _correctedAt(
                    executedAt + 1 days
                ),
                1
            )
        );

        assertEq(
            registry.pendingFlip(
                address(vault),
                user1
            ),
            address(0)
        );

        assertEq(
            registry.pendingFlip(
                vaultA,
                user1
            ),
            address(0)
        );

        assertEq(
            vault.flipCallCount(),
            1
        );
    }

    function test_correction_meshConvergesInBothDeliveryOrders()
        public
    {
        ReferralRegistry rankOne = new ReferralRegistry(
            address(this),
            1
        );

        ReferralRegistry rankTwo = new ReferralRegistry(
            address(this),
            2
        );

        rankOne.setAllowedVault(
            vaultA,
            true
        );

        rankTwo.setAllowedVault(
            vaultA,
            true
        );

        _assign(
            user1,
            refA
        );

        _relay(
            rankOne,
            user1,
            refA,
            BASE_TIME,
            0
        );

        _relay(
            rankTwo,
            user1,
            refA,
            BASE_TIME,
            0
        );

        _proposeAndElapse(
            user1,
            refB
        );

        uint256 correctedAssignedAt = _correctedAt(
            block.timestamp
        );

        registry.executeCorrectReferrer(
            user1
        );

        _relay(
            rankOne,
            user1,
            refB,
            correctedAssignedAt,
            0
        );

        _relay(
            rankOne,
            user1,
            refA,
            BASE_TIME,
            0
        );

        _relay(
            rankTwo,
            user1,
            refA,
            BASE_TIME,
            0
        );

        _relay(
            rankTwo,
            user1,
            refB,
            correctedAssignedAt,
            0
        );

        ReferralRegistry[3] memory mesh = [
            registry,
            rankOne,
            rankTwo
        ];

        for (uint256 i; i < mesh.length; ++i) {

            (
                address referrer,
                uint256 assignedAt,
                uint256 rank
            ) = mesh[i].getReferrerPair(
                user1
            );

            assertEq(
                referrer,
                refB
            );

            assertEq(
                assignedAt,
                correctedAssignedAt
            );

            assertEq(
                rank,
                0
            );
        }
    }

    function test_correction_broadcastSendsNewReferrerWithCorrectedKey()
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

        uint256 executedAt = block.timestamp;

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

        assertEq(
            sentUser,
            user1
        );

        assertEq(
            sentReferrer,
            refB
        );

        assertEq(
            sentAssignedAt,
            _correctedAt(
                executedAt
            )
        );

        assertEq(
            sentRank,
            0
        );
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

        assertEq(
            registry.referrerOf(
                user1
            ),
            refB
        );

        assertEq(
            registry.referrerOf(
                user2
            ),
            refA
        );

        assertEq(
            registry.proposedCorrection(
                user2
            ),
            address(0)
        );

        assertEq(
            registry.pendingFlip(
                vaultA,
                user2
            ),
            address(0)
        );
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

        assertEq(
            registry.referrerOf(
                user1
            ),
            refB
        );
    }
}
