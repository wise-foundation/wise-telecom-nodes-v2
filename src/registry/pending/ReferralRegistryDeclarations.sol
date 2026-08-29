// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {OwnableMaster} from "../../diamond/shared/OwnableMaster.sol";

/**
 * @dev Storage, events and errors for the per-chain referral
 * registry — ONE standalone contract per chain,
 * the single source of referrer truth for every WiseTelecomNodes
 * vault on that chain; the diamonds' slot-67 `referrerOf` mapping
 * stays declared but forever virgin. Never a facet, never
 * delegatecalled, so this chain owns its layout outright and
 * `check_storage_layout.sh` deliberately does not cover it. Inherits
 * {OwnableMaster} (slots 0-1) as the house two-step ownership base.
 *
 * Threat model: assignments enter ONLY through `allowedVault`
 * (master-gated allowlist — at most the
 * chain's up-to-three CREATE3 diamonds, whose addresses repeat across
 * chains but never collide inside one chain's registry). Write-once
 * is enforced HERE for local writers, atomically with the write, so
 * no vault — however
 * buggy — can ever displace or clear an existing assignment, and two
 * vaults racing in one block resolve first-write-wins with the loser
 * silently ignored. The ONLY path that may ever change an existing
 * assignment is the cross-chain min-merge below, which is
 * algorithmic, strictly key-decreasing and equally immutable against
 * master. Reads are permissionless and the
 * `referrerOf` auto-getter must remain a plain mapping read forever —
 * the vaults' cohort recorder staticcalls the read path inside the
 * transfer hook's revert-free budget; never add logic,
 * gating or reverts to any read path (`effectiveReferrerOf` is a
 * plain two-read view for the same reason).
 *
 * Cross-chain referrer sync (the min-merge register): alongside
 * `referrerOf`, the registry stores a packed sync key
 * `referrerKey[user] = (assignedAt << 8) | originChainRank`, written
 * at first local assignment with this chain's own rank and
 * `block.timestamp`. Registries on peer chains exchange
 * `(user, referrer, assignedAt, rank)` pairs over CCIP: a received
 * pair OVERWRITES the local assignment if and only if its packed key
 * is STRICTLY smaller (earlier timestamp; ties broken by the fixed
 * chain rank, Ethereum mainnet rank 0 first). The stored value is
 * always the ORIGIN pair — a relayed key travels unchanged — which
 * makes the register state-based convergent: merges commute, repeat
 * harmlessly, and every connected registry converges to the global
 * minimum for each user regardless of delivery order or route. Local
 * deposit writes never overwrite; only authenticated merges may, and
 * only downward, so a user's referrer can flip at most once per peer
 * chain, ever.
 *
 * Flip coordination: when a merge changes an already-assigned
 * referrer, the receive path does O(1) work only — it records
 * `pendingFlip[vault][user] = oldReferrer` for every tracked vault
 * and returns. Until the permissionless `pokeMigration` relocates a
 * vault's book credit, `effectiveReferrerOf(user, vault)` answers the
 * OLD referrer for that vault, so every interim clamp, credit and
 * move keeps hitting the book that actually holds the cover; the
 * marker is cleared only by a successful (or degenerate) migration
 * and restored when a vault's migration call fails. The marker names
 * whoever physically holds the book, so sequential flips before a
 * poke keep the first marker.
 *
 * CCIP surface: the registry is its own CCIP endpoint. Sync truth
 * enters only from a peer registry (per-selector peer table, peer
 * address matched against the message sender, router-only caller,
 * replay map). The router is set once and never rotated; peers are
 * instant while wiring and 3-day timelocked after
 * `finalizeSyncSetup`, with an instant remove as the brake. A
 * compromised peer registry could forge arbitrarily early keys and
 * win merges globally — lane trust equals peer-registry trust, the
 * same class as the vault bridge mesh, mitigated by the timelock,
 * the remove brake and the validation floor (nonzero fields, bounded
 * rank, bounded future drift). The "pure storage plus event, no
 * external calls" posture applies to `assignReferrer`, the carry
 * mailbox and every read path — the sync surface (`broadcastSync`,
 * `pokeMigration`) makes router and vault calls by design and sits
 * outside the transfer-hook budget.
 *
 * Carry staging: same-chain `moveBetweenVaults`
 * attribution payloads stage here behind the SAME allowlist — slots
 * 4-5 hold `carryPayload`/`carryStagedAt` keyed
 * `[srcVault][dstVault][user]`, written by `stageCarry`
 * (delete-then-write, stamps `block.timestamp`) and drained by
 * `consumeCarry` (read + delete, deliberately NOT idempotent — a
 * payload is deliverable at most once). The registry never interprets
 * payload words (codec lives in the vaults' CohortWeeks library);
 * staleness is the DESTINATION's check (`stagedAt` must equal its own
 * `block.timestamp` — stage and consume are synchronous inside one
 * move transaction, so any orphan from a not-yet-carry-aware
 * destination is structurally inert and simply overwritten by the
 * next move on the same key). Consequence of
 * reusing the allowlist: `setAllowedVault(vault, false)` soft-disables
 * that vault's carry staging and consuming AND drops it from the
 * tracked-vault migration loop — the
 * vaults reach the carry functions through failure-tolerant guarded
 * CALLs, so a revoked vault's moves still succeed and only the
 * attribution degrades (anomaly event vault-side). The registry is
 * NEVER repointed once a vault's cohort recorder is armed against it.
 */
abstract contract ReferralRegistryDeclarations is OwnableMaster {

    uint256 internal constant SYNC_VERSION = 1;

    uint256 internal constant SYNC_PAYLOAD_LENGTH = 160;

    uint256 internal constant KEY_RANK_SHIFT = 8;

    uint256 internal constant KEY_RANK_MASK = (1 << KEY_RANK_SHIFT) - 1;

    uint256 internal constant MAX_CHAIN_RANK = 15;

    uint256 internal constant MAX_SYNC_FUTURE_DRIFT = 1 hours;

    uint256 internal constant SYNC_PEER_CHANGE_DELAY = 3 days;

    uint64 internal constant SYNC_GAS_LIMIT = 300_000;

    uint64 internal constant MAX_SYNC_GAS_LIMIT = 2_000_000;

    uint256 internal constant MAX_SYNC_LANES = 8;

    uint256 internal constant MAX_TRACKED_VAULTS = 8;

    // ---- Referrer book ----

    mapping(address => address) public referrerOf;

    // ---- Writer allowlist ----

    mapping(address => bool) public allowedVault;

    // ---- Move-carry staging ----

    mapping(address => mapping(address => mapping(address => uint256[]))) internal carryPayload;

    mapping(address => mapping(address => mapping(address => uint256))) internal carryStagedAt;

    // ---- Sync key ----

    mapping(address => uint256) public referrerKey;

    // ---- CCIP wiring ----

    address public ccipRouter;

    bool public syncInitialized;

    uint64 public syncGasLimit;

    // ---- Sync peer table ----

    mapping(uint64 => address) public syncPeer;

    mapping(uint64 => bool) public syncPeerEnabled;

    mapping(uint64 => address) public proposedSyncPeer;

    mapping(uint64 => uint256) public syncPeerChangeQueuedAt;

    // ---- Replay guard ----

    mapping(bytes32 => bool) public processedSyncMessageId;

    // ---- Flip coordination ----

    mapping(address => mapping(address => address)) public pendingFlip;

    address[] internal trackedVaults;

    // ---- Events ----

    event ReferralAssigned(
        address indexed user,
        address indexed referrer,
        address indexed vault
    );

    event VaultAllowedSet(
        address indexed vault,
        bool allowed
    );

    event CarryStaged(
        address indexed srcVault,
        address indexed dstVault,
        address indexed user,
        uint256 words
    );

    event CarryConsumed(
        address indexed srcVault,
        address indexed dstVault,
        address indexed user,
        uint256 stagedAt
    );

    event ReferralSyncAdopted(
        address indexed user,
        address indexed referrer,
        uint256 syncKey
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

    event SyncKeyCollision(
        address indexed user,
        address indexed localReferrer,
        address indexed incomingReferrer,
        uint256 syncKey
    );

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

    event SyncReceived(
        uint64 indexed srcChainSelector,
        bytes32 indexed messageId,
        address indexed user
    );

    event SyncBroadcast(
        address indexed user,
        uint64 indexed destChainSelector,
        address indexed referrer,
        uint256 syncKey,
        bytes32 messageId
    );

    event CcipRouterSet(
        address indexed router
    );

    event SyncGasLimitSet(
        uint64 gasLimit
    );

    event SyncPeerProposed(
        uint64 indexed chainSelector,
        address indexed peer,
        uint256 queuedAt
    );

    event SyncPeerSet(
        uint64 indexed chainSelector,
        address indexed peer
    );

    event SyncPeerProposalCancelled(
        uint64 indexed chainSelector,
        address indexed peer
    );

    event SyncPeerRemoved(
        uint64 indexed chainSelector,
        address indexed peer
    );

    event SyncSetupFinalized();

    // ---- Errors ----

    error NotAllowedVault();

    error ZeroAddress();

    error SelfReferral();

    error InvalidReferrer();

    error CarryPayloadInvalid();

    error NotCcipRouter();

    error SyncPeerNotEnabled();

    error SyncPeerMismatch();

    error SyncAlreadyProcessed();

    error SyncPayloadInvalid();

    error SyncKeyInvalid();

    error NothingToSync();

    error TooManySyncLanes();

    error InsufficientSyncFee();

    error RouterNotSet();

    error RouterAlreadySet();

    error SyncSetupAlreadyFinalized();

    error SyncPeerTimelockNotElapsed();

    error NoSyncPeerProposed();

    error InvalidSyncGasLimit();

    error InvalidChainRank();

    error TooManyTrackedVaults();

    error SyncRefundFailed();
}
