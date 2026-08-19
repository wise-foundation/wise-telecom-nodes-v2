// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {OwnableMaster} from "../../diamond/shared/OwnableMaster.sol";
import {CohortWeeks} from "../../diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev Storage, events, errors and constants for the mainnet
 * referral hub. One standalone mainnet contract — never a facet,
 * never delegatecalled — so this chain owns its layout outright and
 * `check_storage_layout.sh` deliberately does not cover it. Inherits
 * {OwnableMaster} (slots 0-1) as the house two-step ownership base;
 * governance here is plain `onlyMaster` — parameter timelocks are a
 * future hardening item.
 *
 * Keying: intake cursors and per-source score reports are keyed by
 * `bytes32 source`, not `address`, because CREATE3 gives each product
 * the SAME diamond address on every chain it runs on — address keys
 * would collide the day remote spokes report cross-chain. The local
 * form is `bytes32(uint256(uint160(reporter)))` (top 96 bits zero,
 * reserved); remote sources will derive `keccak256(chainId, vault)`
 * instead.
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
 *
 * Threat model: score truth enters ONLY through `allowedReporter`
 * (master-gated allowlist — the single trust boundary the hub
 * has; the keeper-bot policy matrix gates the cross-chain flush
 * transport, which does not
 * exist yet). Cursors make every delivery idempotent and replay-safe;
 * the append-only checkpoint log, the future-only rate tables and
 * the future-only dwell-min schedule together make every past week's
 * rates a pure function of frozen data — immutable even against
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

    mapping(address => uint256) public claimable;

    uint256 public totalAccrued;

    // ---- Access + policy knobs ----

    mapping(address => bool) public allowedReporter;

    uint256[] internal dwellMinLog;

    mapping(address => address) internal payoutAddress;

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
        address indexed owner,
        address indexed payout
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
}
