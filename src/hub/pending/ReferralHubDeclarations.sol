// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {OwnableMaster} from "../../diamond/shared/OwnableMaster.sol";
import {CohortWeeks} from "../../diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev Storage, events, errors and constants for the mainnet
 * referral hub. One standalone mainnet contract (never a facet,
 * never delegatecalled), so this chain owns its layout outright and
 * `check_storage_layout.sh` deliberately does not cover it. Inherits
 * {OwnableMaster} (slots 0-1) as the house two-step ownership base;
 * governance here is plain `onlyMaster`; parameter timelocks are a
 * future hardening item.
 *
 * Keying: intake cursors and per-source score reports are keyed by
 * `bytes32 source`, not `address`, because CREATE3 gives each product
 * the SAME diamond address on every chain it runs on; address keys
 * would collide the day remote spokes report cross-chain. The local
 * form is `bytes32(uint256(uint160(reporter)))` (top 96 bits zero,
 * reserved); remote sources derive `keccak256(chainId, vault)`
 * instead. Claimable balances and payout designations are keyed per
 * source CHAIN (chain id → referrer/owner): a chain's designation
 * moves only money earned on the chain where control of the address
 * was proven, so a same-address stranger on another chain can never
 * redirect it. Local intake and designation write the executing
 * chain's bucket; remote deliveries thread their authenticated
 * origin chain through the mailbox. Score and rate aggregation stay
 * global per referrer address.
 *
 * Packed formats owned by this contract (the crumb/gap word formats
 * belong to {CohortWeeks} and are never restated):
 * - referrerCheckpoints entry: `week << 224 | referred << 112 | self`
 *   (u32 | u112 | u112). Values are the referrer's GLOBAL running
 *   scores after the last report of that week; entries for past weeks
 *   are immutable, the current week's tail entry updates in place.
 *   u112 is structurally unreachable: one source's report is bounded
 *   at intake to `3 × LANE_MASK_80` and a u112 fits ~1.4e9 such
 *   sources, so no guard (and no untestable revert arm) is needed.
 * - lastSourceReport entry: `referred << 128 | self` (both bounded to
 *   `3 × LANE_MASK_80` at intake, so each fits u128 exactly).
 * - dwellMinLog entry: `effectiveFromWeek << 1 | enabled`. Append-only
 *   and future-only exactly like `rateTables`, so the dwell setting
 *   that priced any week whose opening boundary has passed can never
 *   change.
 * - paidCursor entry: three 80-bit token-second lanes in the crumb
 *   geometry (Y1 at bit 0, Y2 at 80, M at 160), decoded with the
 *   {CohortWeeks} lane accessors.
 * - payoutStamp entry: `setAt << 8 | chainRank`, the freshness
 *   stamp of a payout designation. Local designations (this chain
 *   is the mesh's rank-0 chain) always overwrite and re-stamp;
 *   transported designations apply latest-wins/idempotent against
 *   the stored stamp; the strict-greater compare makes replays and
 *   reordered deliveries no-ops.
 *
 * Cross-chain flush mailbox: the hub is its own CCIP endpoint
 * (router set once, never rotated). Two master-registered source
 * classes per (chain selector, sender address) pair, each mapped to
 * its origin chain id: `flushSourceChainId` names the spoke VAULTS
 * whose flush envelopes are accepted, `designationSourceChainId`
 * the spoke REGISTRIES whose payout-designation pushes are. A flush
 * receive does O(1) work under the source-paid gas budget: it
 * stores `keccak256(chainId, vault, payload)` into
 * `flushCommitment[messageId]` (the commitment map doubles as the
 * replay guard) and emits the payload; the permissionless
 * `applyFlush` later re-supplies the payload, proves it against the
 * commitment, and walks the entries through the SAME intake
 * internals under the reserved remote source key
 * `keccak256(chainId, vault)`. Because envelopes may apply in any
 * order, `appliedScoreStamp` gates each entry's absolute score
 * report by the envelope's build stamp; crumbs, gaps and
 * designations need no such gate (cursors and designation stamps
 * already order them). A designation push applies inline on receive
 * (one stamped write, idempotent; replays need no guard).
 * `botShareBps` is the courier share deducted at delivery pricing
 * for remote deliveries whose stamped deliverer is not the referrer;
 * the share credits the deliverer's own (source chain, deliverer)
 * claimable bucket, so courier money follows the same
 * control-proven-on-source-chain rule as referrer money.
 *
 * Threat model: score truth enters ONLY through `allowedReporter`
 * (master-gated allowlist) and the master-registered flush sources;
 * one trust class: system-owned infrastructure, each contained to
 * its own source key by the cursors and per-source score diffs.
 * The spoke-side keeper-bot policy matrix gates who may BUILD a
 * flush; the hub prices whatever authenticated envelopes deliver.
 * Cursors make every delivery idempotent and replay-safe;
 * the append-only checkpoint log, the future-only rate tables and
 * the future-only dwell-min schedule together make every past week's
 * rates a pure function of frozen data, immutable even against
 * master. Pricing floors per lane so the hub can never overpay
 * exact.
 */
abstract contract ReferralHubDeclarations is OwnableMaster {

    uint256 internal constant CHECKPOINT_WEEK_SHIFT = 224;

    uint256 internal constant CHECKPOINT_REFERRED_SHIFT = 112;

    uint256 internal constant CHECKPOINT_VALUE_MASK = (1 << 112) - 1;

    uint256 internal constant REPORT_REFERRED_SHIFT = 128;

    uint256 internal constant REPORT_VALUE_MASK = (1 << 128) - 1;

    uint256 internal constant GAP_WEEK_MASK = (1 << 32) - 1;

    uint256 internal constant MAX_SOURCE_SCORE = 3 * CohortWeeks.LANE_MASK_80;

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    uint256 internal constant PAYOUT_STAMP_SHIFT = 8;

    uint256 internal constant DESIGNATION_VERSION = 1;

    uint256 internal constant DESIGNATION_PAYLOAD_LENGTH = 160;

    uint256 internal constant MAX_DESIGNATION_FUTURE_DRIFT = 1 hours;

    uint256 internal constant GENESIS_BOT_SHARE_BPS = 1_000;

    struct RateTable {
        uint32 effectiveFromWeek;
        uint16 capBps;
        uint16 y2RateBps;
        uint16 mRateBps;
        uint16[8] tierBps;
        uint96[8] thresholds;
    }

    // ---- Global scores ----

    mapping(address => uint256) public globalReferredScore;

    mapping(address => uint256) public globalSelfScore;

    // ---- Append-only history ----

    mapping(address => uint256[]) internal referrerCheckpoints;

    // ---- Per-source reports ----

    mapping(bytes32 => mapping(address => uint256)) internal lastSourceReport;

    // ---- Week-versioned rate tables ----

    RateTable[] internal rateTables;

    // ---- Intake cursors + claimables ----

    mapping(bytes32 => mapping(address => mapping(uint256 => uint256))) internal paidCursor;

    mapping(uint256 => mapping(address => uint256)) public claimable;

    uint256 public totalAccrued;

    uint256 public totalClaimed;

    uint256 public totalBooked;

    // ---- Access + policy knobs ----

    mapping(address => bool) public allowedReporter;

    uint256[] internal dwellMinLog;

    address public payoutVault;

    mapping(uint256 => mapping(address => address)) internal payoutAddress;

    mapping(uint256 => mapping(address => uint256)) public payoutStamp;

    // ---- Cross-chain flush mailbox ----

    address public ccipRouter;

    mapping(uint64 => mapping(address => uint256)) public flushSourceChainId;

    mapping(uint64 => mapping(address => uint256)) public designationSourceChainId;

    mapping(bytes32 => bytes32) public flushCommitment;

    mapping(bytes32 => mapping(address => uint256)) public appliedScoreStamp;

    uint256 public botShareBps;

    // ---- Events ----

    event SourceScoresReported(
        bytes32 indexed source,
        address indexed referrer,
        uint256 referredScore,
        uint256 selfScore
    );

    event ReferrerCheckpointed(
        address indexed referrer,
        uint256 indexed week,
        uint256 referredScore,
        uint256 selfScore
    );

    event RateTableScheduled(
        uint256 indexed index,
        uint256 effectiveFromWeek
    );

    event CrumbPriced(
        bytes32 indexed source,
        address indexed referrer,
        uint256 indexed week,
        address deliverer,
        uint256 y1Increment,
        uint256 y2Increment,
        uint256 mIncrement,
        uint256 paid
    );

    event GapPriced(
        bytes32 indexed source,
        address indexed referrer,
        address deliverer,
        uint256 fromWeek,
        uint256 toWeekExclusive,
        uint256 paid
    );

    event CrumbLaneRegression(
        bytes32 indexed source,
        address indexed referrer,
        uint256 indexed week,
        uint256 laneKind,
        uint256 incoming,
        uint256 cursor
    );

    event ReporterAllowedSet(
        address indexed reporter,
        bool allowed
    );

    event DwellMinScheduled(
        uint256 indexed effectiveFromWeek,
        bool enabled
    );

    event PayoutAddressSet(
        uint256 indexed chainId,
        address indexed owner,
        address indexed payout
    );

    event PayoutVaultSet(
        address payoutVault
    );

    event PayoutLiabilityBooked(
        uint256 amount
    );

    event PayoutClaimed(
        uint256 indexed chainId,
        address indexed referrer,
        address indexed payout,
        uint256 amount
    );

    event CcipRouterSet(
        address indexed router
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

    event FlushReceived(
        bytes32 indexed messageId,
        uint64 indexed srcChainSelector,
        address indexed vault,
        uint256 chainId,
        bytes payload
    );

    event FlushApplied(
        bytes32 indexed messageId,
        bytes32 indexed source,
        uint256 entryCount
    );

    event DesignationPushReceived(
        uint64 indexed srcChainSelector,
        uint256 indexed chainId,
        address indexed owner
    );

    event DelivererSharePaid(
        uint256 indexed chainId,
        address indexed deliverer,
        address indexed referrer,
        bytes32 messageId,
        uint256 amount
    );

    event FlushDesignationSkipped(
        uint256 indexed chainId,
        address indexed owner,
        uint256 stamp
    );

    event BotShareBpsSet(
        uint256 botShareBps
    );

    // ---- Errors ----

    error ZeroAddress();

    error NotReporter();

    error FutureWeek();

    error LengthMismatch();

    error BatchTooLarge();

    error InvalidCrumbWord();

    error InvalidGapRecord();

    error InvalidWindow();

    error ScoreReportOutOfRange();

    error TableNotFuture();

    error TableNotOrdered();

    error DwellMinNotFuture();

    error DwellMinNotOrdered();

    error InvalidRateTable();

    error NothingClaimable();

    error PotDry();

    error NotPayoutAuthorized();

    error NotCcipRouter();

    error RouterAlreadySet();

    error UnknownFlushSource();

    error FlushAlreadyReceived();

    error UnknownFlushCommitment();

    error FlushPayloadInvalid();

    error BotShareTooHigh();
}
