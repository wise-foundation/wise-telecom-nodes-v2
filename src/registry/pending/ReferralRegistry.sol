// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralRegistryDeclarations} from "./ReferralRegistryDeclarations.sol";
import {IVaultCohortFlip} from "./IVaultCohortFlip.sol";
import {OwnableMaster} from "../../diamond/shared/OwnableMaster.sol";
import {CohortWeeks} from "../../diamond/shared/pending/CohortWeeks.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @dev The per-chain referral registry — ONE standalone
 * deployed contract closing the chain over
 * {ReferralRegistryDeclarations}. `assignReferrer` is the single
 * LOCAL write path: allowlisted vaults forward `(user, referrer)`
 * from their referral deposit entrypoints, and this contract alone
 * enforces the assignment semantics — zero rejected, self rejected,
 * first assignment sticks against every later local write, event only
 * on the actual first-set transition. The first set also stamps the
 * packed sync key `(block.timestamp << 8) | LOCAL_CHAIN_RANK`.
 * Validation runs BEFORE the write-once check so a zero/self
 * referrer reverts even for an already-assigned user, preserving
 * the vaults' revert priority. The hardening pair rejects the calling
 * vault and this registry as referrers so cohort credit can never be
 * laundered into system addresses. `assignReferrer` performs a pure
 * storage write plus event and makes NO external call — the vaults'
 * reentrancy reasoning relies on this staying true.
 *
 * Cross-chain min-merge: `_mergeReferrerPair` is the one place an
 * existing assignment can ever change. It is fed by two entrances —
 * `mergeReferrer` (an allowlisted vault relaying the pair carried on
 * a bridge message) and `ccipReceive` (a peer registry's sync
 * message) — and applies the strictly-decreasing key rule: adopt when
 * unassigned, overwrite when the incoming packed key is strictly
 * smaller, ignore otherwise. A flip records pending-flip markers per
 * tracked vault and nothing else; the book migration runs later via
 * the permissionless `pokeMigration`, whose per-vault calls are
 * failure-tolerant (a reverting vault gets its marker back and stays
 * retryable). `effectiveReferrerOf` answers the marker while it
 * stands so interim recorder activity keeps hitting the book that
 * holds the cover.
 *
 * `broadcastSync` is permissionless and caller-paid: it sends this
 * registry's stored origin pair for one user to any set of enabled
 * peer lanes, refunding excess fee at the end. Out-of-order execution
 * is explicitly allowed — merge order cannot matter.
 *
 * `setAllowedVault` is the master kill-switch for NEW assignments
 * from one vault; it is deliberately instant (no timelock) and
 * deliberately asymmetric: reads stay permissionless, so a revoked
 * vault's cohort recorder keeps resolving existing referrers and
 * only fresh `...WithReferral` deposits on that vault revert. The
 * allowlist doubles as the tracked-vault list the flip machinery
 * loops, bounded at `MAX_TRACKED_VAULTS`.
 *
 * Carry staging: `stageCarry`/`consumeCarry` are the
 * same-chain move-attribution mailbox (threat model and lifecycle in
 * the declarations block). `stageCarry`'s guards are guard-class only
 * — reachable solely through a buggy allowlisted vault, since the
 * vaults construct payloads from their own storage: nonzero
 * endpoints, no self-destination, payload length within
 * `(0, MAX_CARRY_WORDS]`. `consumeCarry` is deliberately guard-free:
 * an empty key returns an empty payload, the natural answer, and the
 * destination's `stagedAt == block.timestamp` check rejects
 * everything else. Consume keys the destination as `msg.sender`, so
 * a rogue allowlisted vault can only ever drain payloads addressed
 * to itself.
 */
contract ReferralRegistry is ReferralRegistryDeclarations, IAny2EVMMessageReceiver, IERC165 {

    uint256 public immutable LOCAL_CHAIN_RANK;

    modifier onlyAllowedVault() {
        require(
            allowedVault[msg.sender],
            NotAllowedVault()
        );
        _;
    }

    constructor(
        address _master,
        uint256 _localChainRank
    )
        OwnableMaster(
            _master
        )
    {
        require(
            _localChainRank <= MAX_CHAIN_RANK,
            InvalidChainRank()
        );

        LOCAL_CHAIN_RANK = _localChainRank;
    }

    function assignReferrer(
        address _user,
        address _referrer
    )
        external
        onlyAllowedVault
    {
        require(
            _user != ZERO_ADDRESS,
            ZeroAddress()
        );

        require(
            _referrer != ZERO_ADDRESS,
            ZeroAddress()
        );

        require(
            _referrer != _user,
            SelfReferral()
        );

        require(
            _referrer != msg.sender,
            InvalidReferrer()
        );

        require(
            _referrer != address(this),
            InvalidReferrer()
        );

        if (referrerOf[_user] != ZERO_ADDRESS) {
            return;
        }

        referrerOf[_user] = _referrer;

        referrerKey[_user] = _packSyncKey(
            block.timestamp,
            LOCAL_CHAIN_RANK
        );

        emit ReferralAssigned(
            _user,
            _referrer,
            msg.sender
        );
    }

    function getReferrerPair(
        address _user
    )
        external
        view
        returns (
            address referrer,
            uint256 assignedAt,
            uint256 rank
        )
    {
        referrer = referrerOf[_user];

        uint256 key = referrerKey[_user];

        assignedAt = key >> KEY_RANK_SHIFT;

        rank = key & KEY_RANK_MASK;
    }

    function effectiveReferrerOf(
        address _user,
        address _vault
    )
        external
        view
        returns (address)
    {
        address old = pendingFlip[_vault][_user];

        if (old != ZERO_ADDRESS) {
            return old;
        }

        return referrerOf[_user];
    }

    function mergeReferrer(
        address _user,
        address _referrer,
        uint256 _assignedAt,
        uint256 _rank
    )
        external
        onlyAllowedVault
    {
        require(
            _referrer != msg.sender,
            InvalidReferrer()
        );

        _mergeReferrerPair(
            _user,
            _referrer,
            _assignedAt,
            _rank
        );
    }

    function ccipReceive(
        Client.Any2EVMMessage calldata _message
    )
        external
    {
        require(
            msg.sender == ccipRouter,
            NotCcipRouter()
        );

        uint64 srcChainSelector = _message.sourceChainSelector;

        address srcPeer = abi.decode(
            _message.sender,
            (address)
        );

        require(
            syncPeerEnabled[srcChainSelector] == true,
            SyncPeerNotEnabled()
        );

        require(
            syncPeer[srcChainSelector] == srcPeer,
            SyncPeerMismatch()
        );

        require(
            processedSyncMessageId[_message.messageId] == false,
            SyncAlreadyProcessed()
        );

        processedSyncMessageId[_message.messageId] = true;

        require(
            _message.data.length == SYNC_PAYLOAD_LENGTH,
            SyncPayloadInvalid()
        );

        (
            uint256 version,
            address user,
            address referrer,
            uint256 assignedAt,
            uint256 rank
        ) = abi.decode(
            _message.data,
            (uint256, address, address, uint256, uint256)
        );

        require(
            version == SYNC_VERSION,
            SyncPayloadInvalid()
        );

        _mergeReferrerPair(
            user,
            referrer,
            assignedAt,
            rank
        );

        emit SyncReceived(
            srcChainSelector,
            _message.messageId,
            user
        );
    }

    function supportsInterface(
        bytes4 _interfaceId
    )
        external
        pure
        returns (bool)
    {
        return _interfaceId == type(IAny2EVMMessageReceiver).interfaceId
            || _interfaceId == type(IERC165).interfaceId;
    }

    function broadcastSync(
        address _user,
        uint64[] calldata _selectors
    )
        external
        payable
    {
        require(
            _selectors.length > 0,
            NothingToSync()
        );

        require(
            _selectors.length <= MAX_SYNC_LANES,
            TooManySyncLanes()
        );

        uint256 key = referrerKey[_user];

        require(
            key != 0,
            NothingToSync()
        );

        address router = ccipRouter;

        require(
            router != ZERO_ADDRESS,
            RouterNotSet()
        );

        address referrer = referrerOf[_user];

        uint256 spentFee;

        for (uint256 i; i < _selectors.length; ++i) {

            uint64 selector = _selectors[i];

            require(
                syncPeerEnabled[selector] == true,
                SyncPeerNotEnabled()
            );

            Client.EVM2AnyMessage memory message = _buildSyncMessage(
                syncPeer[selector],
                _user,
                referrer,
                key
            );

            uint256 fee = IRouterClient(router).getFee(
                selector,
                message
            );

            spentFee += fee;

            require(
                msg.value >= spentFee,
                InsufficientSyncFee()
            );

            bytes32 messageId = IRouterClient(router).ccipSend{value: fee}(
                selector,
                message
            );

            emit SyncBroadcast(
                _user,
                selector,
                referrer,
                key,
                messageId
            );
        }

        _refundExcessSyncFee(
            spentFee
        );
    }

    function quoteSyncFee(
        address _user,
        uint64[] calldata _selectors
    )
        external
        view
        returns (uint256 totalFee)
    {
        uint256 key = referrerKey[_user];

        address referrer = referrerOf[_user];

        for (uint256 i; i < _selectors.length; ++i) {

            uint64 selector = _selectors[i];

            require(
                syncPeerEnabled[selector] == true,
                SyncPeerNotEnabled()
            );

            totalFee += IRouterClient(ccipRouter).getFee(
                selector,
                _buildSyncMessage(
                    syncPeer[selector],
                    _user,
                    referrer,
                    key
                )
            );
        }
    }

    function pokeMigration(
        address _user
    )
        external
    {
        address current = referrerOf[_user];

        uint256 count = trackedVaults.length;

        for (uint256 i; i < count; ++i) {

            address vault = trackedVaults[i];

            address old = pendingFlip[vault][_user];

            if (old == ZERO_ADDRESS) {
                continue;
            }

            delete pendingFlip[vault][_user];

            if (old == current) {

                emit FlipCleared(
                    vault,
                    _user,
                    old
                );

                continue;
            }

            try IVaultCohortFlip(vault).receiveReferrerFlip(
                _user,
                old,
                current
            ) {
                emit FlipMigrated(
                    vault,
                    _user,
                    old,
                    current
                );
            } catch {

                pendingFlip[vault][_user] = old;

                emit FlipMigrationDeferred(
                    vault,
                    _user,
                    old,
                    current
                );
            }
        }
    }

    function setCcipRouter(
        address _router
    )
        external
        onlyMaster
    {
        require(
            _router != ZERO_ADDRESS,
            ZeroAddress()
        );

        require(
            ccipRouter == ZERO_ADDRESS,
            RouterAlreadySet()
        );

        ccipRouter = _router;

        emit CcipRouterSet(
            _router
        );
    }

    function setSyncGasLimit(
        uint64 _gasLimit
    )
        external
        onlyMaster
    {
        require(
            _gasLimit >= SYNC_GAS_LIMIT && _gasLimit <= MAX_SYNC_GAS_LIMIT,
            InvalidSyncGasLimit()
        );

        syncGasLimit = _gasLimit;

        emit SyncGasLimitSet(
            _gasLimit
        );
    }

    function proposeSyncPeer(
        uint64 _chainSelector,
        address _peer
    )
        external
        onlyMaster
    {
        require(
            _peer != ZERO_ADDRESS,
            ZeroAddress()
        );

        proposedSyncPeer[_chainSelector] = _peer;

        syncPeerChangeQueuedAt[_chainSelector] = block.timestamp;

        emit SyncPeerProposed(
            _chainSelector,
            _peer,
            block.timestamp
        );
    }

    function executeSyncPeerChange(
        uint64 _chainSelector
    )
        external
        onlyMaster
    {
        address peer = proposedSyncPeer[_chainSelector];

        require(
            peer != ZERO_ADDRESS,
            NoSyncPeerProposed()
        );

        if (syncInitialized) {
            require(
                block.timestamp >= syncPeerChangeQueuedAt[_chainSelector] + SYNC_PEER_CHANGE_DELAY,
                SyncPeerTimelockNotElapsed()
            );
        }

        syncPeer[_chainSelector] = peer;

        syncPeerEnabled[_chainSelector] = true;

        delete proposedSyncPeer[_chainSelector];

        delete syncPeerChangeQueuedAt[_chainSelector];

        emit SyncPeerSet(
            _chainSelector,
            peer
        );
    }

    function cancelSyncPeerChange(
        uint64 _chainSelector
    )
        external
        onlyMaster
    {
        address peer = proposedSyncPeer[_chainSelector];

        require(
            peer != ZERO_ADDRESS,
            NoSyncPeerProposed()
        );

        delete proposedSyncPeer[_chainSelector];

        delete syncPeerChangeQueuedAt[_chainSelector];

        emit SyncPeerProposalCancelled(
            _chainSelector,
            peer
        );
    }

    function removeSyncPeer(
        uint64 _chainSelector
    )
        external
        onlyMaster
    {
        address peer = syncPeer[_chainSelector];

        if (peer == ZERO_ADDRESS) {
            return;
        }

        syncPeerEnabled[_chainSelector] = false;

        delete syncPeer[_chainSelector];

        emit SyncPeerRemoved(
            _chainSelector,
            peer
        );
    }

    function finalizeSyncSetup()
        external
        onlyMaster
    {
        require(
            syncInitialized == false,
            SyncSetupAlreadyFinalized()
        );

        require(
            ccipRouter != ZERO_ADDRESS,
            RouterNotSet()
        );

        syncInitialized = true;

        emit SyncSetupFinalized();
    }

    function setAllowedVault(
        address _vault,
        bool _allowed
    )
        external
        onlyMaster
    {
        require(
            _vault != ZERO_ADDRESS,
            ZeroAddress()
        );

        allowedVault[_vault] = _allowed;

        if (_allowed) {
            _trackVault(
                _vault
            );
        } else {
            _untrackVault(
                _vault
            );
        }

        emit VaultAllowedSet(
            _vault,
            _allowed
        );
    }

    function stageCarry(
        address _dstVault,
        address _user,
        uint256[] calldata _payload
    )
        external
        onlyAllowedVault
    {
        require(
            _dstVault != ZERO_ADDRESS,
            ZeroAddress()
        );

        require(
            _user != ZERO_ADDRESS,
            ZeroAddress()
        );

        require(
            _dstVault != msg.sender,
            CarryPayloadInvalid()
        );

        require(
            _payload.length > 0,
            CarryPayloadInvalid()
        );

        require(
            _payload.length <= CohortWeeks.MAX_CARRY_WORDS,
            CarryPayloadInvalid()
        );

        delete carryPayload[msg.sender][_dstVault][_user];

        carryPayload[msg.sender][_dstVault][_user] = _payload;

        carryStagedAt[msg.sender][_dstVault][_user] = block.timestamp;

        emit CarryStaged(
            msg.sender,
            _dstVault,
            _user,
            _payload.length
        );
    }

    function consumeCarry(
        address _srcVault,
        address _user
    )
        external
        onlyAllowedVault
        returns (
            uint256 stagedAt,
            uint256[] memory payload
        )
    {
        stagedAt = carryStagedAt[_srcVault][msg.sender][_user];

        if (stagedAt == 0) {
            return (
                0,
                payload
            );
        }

        payload = carryPayload[_srcVault][msg.sender][_user];

        delete carryPayload[_srcVault][msg.sender][_user];

        delete carryStagedAt[_srcVault][msg.sender][_user];

        emit CarryConsumed(
            _srcVault,
            msg.sender,
            _user,
            stagedAt
        );
    }

    function getCarry(
        address _srcVault,
        address _dstVault,
        address _user
    )
        external
        view
        returns (
            uint256 stagedAt,
            uint256[] memory payload
        )
    {
        stagedAt = carryStagedAt[_srcVault][_dstVault][_user];

        payload = carryPayload[_srcVault][_dstVault][_user];
    }

    function _mergeReferrerPair(
        address _user,
        address _referrer,
        uint256 _assignedAt,
        uint256 _rank
    )
        internal
    {
        require(
            _user != ZERO_ADDRESS,
            ZeroAddress()
        );

        require(
            _referrer != ZERO_ADDRESS,
            ZeroAddress()
        );

        require(
            _referrer != _user,
            SelfReferral()
        );

        require(
            _referrer != address(this),
            InvalidReferrer()
        );

        require(
            _assignedAt > 0,
            SyncKeyInvalid()
        );

        require(
            _assignedAt <= block.timestamp + MAX_SYNC_FUTURE_DRIFT,
            SyncKeyInvalid()
        );

        require(
            _rank <= MAX_CHAIN_RANK,
            SyncKeyInvalid()
        );

        uint256 incomingKey = _packSyncKey(
            _assignedAt,
            _rank
        );

        uint256 localKey = referrerKey[_user];

        address localReferrer = referrerOf[_user];

        if (localKey == 0) {

            referrerOf[_user] = _referrer;

            referrerKey[_user] = incomingKey;

            emit ReferralSyncAdopted(
                _user,
                _referrer,
                incomingKey
            );

            return;
        }

        if (incomingKey >= localKey) {

            if (incomingKey == localKey && _referrer != localReferrer) {
                emit SyncKeyCollision(
                    _user,
                    localReferrer,
                    _referrer,
                    incomingKey
                );
            }

            return;
        }

        referrerKey[_user] = incomingKey;

        if (_referrer == localReferrer) {

            emit ReferralSyncKeyLowered(
                _user,
                _referrer,
                localKey,
                incomingKey
            );

            return;
        }

        referrerOf[_user] = _referrer;

        _markPendingFlips(
            _user,
            localReferrer
        );

        emit ReferralSyncFlipped(
            _user,
            localReferrer,
            _referrer,
            incomingKey
        );
    }

    function _markPendingFlips(
        address _user,
        address _oldReferrer
    )
        internal
    {
        uint256 count = trackedVaults.length;

        for (uint256 i; i < count; ++i) {

            address vault = trackedVaults[i];

            if (pendingFlip[vault][_user] != ZERO_ADDRESS) {
                continue;
            }

            pendingFlip[vault][_user] = _oldReferrer;

            emit FlipMarked(
                vault,
                _user,
                _oldReferrer
            );
        }
    }

    function _buildSyncMessage(
        address _peer,
        address _user,
        address _referrer,
        uint256 _key
    )
        internal
        view
        returns (Client.EVM2AnyMessage memory)
    {
        uint64 gasLimit = syncGasLimit == 0
            ? SYNC_GAS_LIMIT
            : syncGasLimit;

        return Client.EVM2AnyMessage({
            receiver: abi.encode(
                _peer
            ),
            data: abi.encode(
                SYNC_VERSION,
                _user,
                _referrer,
                _key >> KEY_RANK_SHIFT,
                _key & KEY_RANK_MASK
            ),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: ZERO_ADDRESS,
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({
                    gasLimit: gasLimit,
                    allowOutOfOrderExecution: true
                })
            )
        });
    }

    function _refundExcessSyncFee(
        uint256 _spentFee
    )
        internal
    {
        if (msg.value <= _spentFee) {
            return;
        }

        (
            bool ok,
        ) = msg.sender.call{
            value: msg.value - _spentFee
        }("");

        require(
            ok,
            SyncRefundFailed()
        );
    }

    function _trackVault(
        address _vault
    )
        internal
    {
        uint256 count = trackedVaults.length;

        for (uint256 i; i < count; ++i) {

            if (trackedVaults[i] == _vault) {
                return;
            }
        }

        require(
            count < MAX_TRACKED_VAULTS,
            TooManyTrackedVaults()
        );

        trackedVaults.push(
            _vault
        );
    }

    function _untrackVault(
        address _vault
    )
        internal
    {
        uint256 count = trackedVaults.length;

        for (uint256 i; i < count; ++i) {

            if (trackedVaults[i] != _vault) {
                continue;
            }

            trackedVaults[i] = trackedVaults[count - 1];

            trackedVaults.pop();

            return;
        }
    }

    function _packSyncKey(
        uint256 _assignedAt,
        uint256 _rank
    )
        internal
        pure
        returns (uint256)
    {
        return (_assignedAt << KEY_RANK_SHIFT) | _rank;
    }
}
