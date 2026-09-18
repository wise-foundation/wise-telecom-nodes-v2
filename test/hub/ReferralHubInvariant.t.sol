// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {ReferralHub} from "../../src/hub/pending/ReferralHub.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev Six-decimal mintable USD stand-in for the hub tests.
 */
contract MockUSD is ERC20 {

    constructor()
        ERC20("Mock USD", "MUSD")
    {}

    function decimals()
        public
        pure
        override
        returns (uint8)
    {
        return 6;
    }

    function mint(
        address _to,
        uint256 _amount
    )
        external
    {
        _mint(
            _to,
            _amount
        );
    }
}

/**
 * @dev Drives the mainnet referral hub through bounded random
 * `reportScores` / `deliverCrumbs` / `deliverGap` /
 * `warpWeeks` actions across a closed universe of 3 allowlisted
 * reporters and 6 referrers, matching the handler-plus-ghost shape of
 * `test/diamond/invariant/CohortRecorderInvariant.t.sol`. Crumb words
 * are driven through a per-(reporter, referrer, week) ghost that only
 * ever grows or replays, never regresses, mimicking the recorder's
 * "lanes only ever grow within a week" ring model (see the
 * CohortWeeks doc comment);
 * `deliverCrumbs` and the per-week loop inside `deliverGap` are
 * restricted to strictly-past weeks so the handler's pre-read of
 * `weeklyRates`/`paidCursorAt` is guaranteed stable against the exact
 * state the real call will observe (rates for a week are frozen once
 * the week's opening boundary passes: checkpoints written during or
 * after a week can no longer move its opening scores, and rate tables
 * are future-only, so for a strictly-past week the handler's view
 * read and the hub's pricing read can never diverge).
 *
 * The mailbox action (`deliverRemoteCrumbs`) drives the same cell
 * discipline through the cross-chain path: one registered remote
 * vault delivers single-crumb envelopes via a pranked router
 * `ccipReceive` followed immediately by the permissionless
 * `applyFlush`, alternating the stamped deliverer between a fixed
 * courier (bot-share split) and the referrer itself (own-book, no
 * split). Remote cursors live under the hashed source key the
 * address-derived `paidCursorAt` view cannot reach, so the handler
 * keeps a PURE ghost cursor for remote cells (it is the sole writer
 * of that source; the ghost is the truth) and the per-cell
 * hub-cursor assert skips them; the `totalAccrued` equality still
 * cross-checks their pricing exactly, and the split can never change
 * the accounting identity because deliverer share plus referrer
 * remainder always equals the priced amount. Remote envelope scores
 * are grow-only ghosts mirrored into `ghostRemoteReferred/Self` so
 * the I3 aggregate identity extends to the hashed source.
 *
 * Ghost state: `ghostCrumbWord` (per cell, last word this handler
 * chose to send, grow-or-replay only); `ghostCursorY1/Y2/M` and
 * `ghostTotalExpectedPaid` (per-cell high-water cursor and a running
 * total, both computed in the HANDLER by reading `paidCursorAt` and
 * `weeklyRates` immediately before every pricing call and replicating
 * `_laneIncrement` / `_advanceCursor` / `_payIncrements` verbatim;
 * this is what makes I4 an exact equality rather than a bound);
 * `touchedCells` (every (reporter, referrer, week) triple either
 * action has ever priced, deduplicated); `journaledWeeks` plus the
 * `journalY1Bps` / `journalY2Bps` / `journalMBps` /
 * `journalOpeningReferred` / `journalOpeningSelf` maps (a snapshot of
 * every referrer's `weeklyRates` triple and `openingScoresAt` pair,
 * taken the FIRST time each week crosses from current into fully past,
 * i.e. inside `warpWeeks` right after the warp, for exactly the weeks
 * newly left behind; re-verified every invariant check to prove no
 * later-arriving report or delivery can ever move a closed week's
 * rates or opening scores, per I5). I3 is checked by reading
 * `lastReportOf` for
 * each of the 3 reporters directly off the hub rather than mirroring
 * it in a second ghost mapping; the invariant already cross-checks
 * two independently-updated storage locations (`globalReferredScore`
 * / `globalSelfScore` against `lastSourceReport`) written by the same
 * `_applyScoreReport` call, so a shadow copy would only test itself.
 */
contract ReferralHubInvariantHandler is Test {

    struct TouchedCell {
        address reporter;
        address referrer;
        uint256 week;
    }

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    uint256 internal constant MAX_SCORE = 2_000_000 * 1e6;

    uint256 internal constant MAX_MATURE = 1_000_000 * 1e6;

    uint256 internal constant MAX_LANE_DELTA = 5_000_000 * 1e6;

    address public constant REMOTE_VAULT = address(0xE1);

    uint64 public constant REMOTE_SELECTOR = 7_777;

    uint256 public constant REMOTE_CHAIN_ID = 8_453;

    address public constant COURIER = address(0xE7);

    address public constant ROUTER = address(0xF1);

    ReferralHub internal immutable hub;

    address[3] internal reporters;

    address[6] internal referrers;

    uint256 public journaledUpToExclusive;

    uint256[] public journaledWeeks;

    mapping(uint256 => mapping(address => uint256)) public journalY1Bps;

    mapping(uint256 => mapping(address => uint256)) public journalY2Bps;

    mapping(uint256 => mapping(address => uint256)) public journalMBps;

    mapping(uint256 => mapping(address => uint256)) public journalOpeningReferred;

    mapping(uint256 => mapping(address => uint256)) public journalOpeningSelf;

    mapping(bytes32 => uint256) internal ghostCrumbWord;

    mapping(bytes32 => bool) internal cellSeen;

    TouchedCell[] public touchedCells;

    mapping(bytes32 => uint256) public ghostCursorY1;

    mapping(bytes32 => uint256) public ghostCursorY2;

    mapping(bytes32 => uint256) public ghostCursorM;

    uint256 public ghostTotalExpectedPaid;

    mapping(address => uint256) public ghostRemoteReferred;

    mapping(address => uint256) public ghostRemoteSelf;

    uint256 public remoteNonce;

    constructor(
        ReferralHub _hub,
        address[3] memory _reporters,
        address[6] memory _referrers
    ) {
        hub = _hub;
        reporters = _reporters;
        referrers = _referrers;

        journaledUpToExclusive = block.timestamp / CohortWeeks.WEEK;
    }

    // ---- views for the invariant contract ----

    function touchedCellsLength()
        external
        view
        returns (uint256)
    {
        return touchedCells.length;
    }

    function journaledWeeksLength()
        external
        view
        returns (uint256)
    {
        return journaledWeeks.length;
    }

    function cellKey(
        address _reporter,
        address _referrer,
        uint256 _week
    )
        public
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(_reporter, _referrer, _week)
        );
    }

    // ---- actions ----

    function reportScores(
        uint256 _reporterSeed,
        uint256 _referrerSeed,
        uint256 _referredSeed,
        uint256 _selfSeed
    )
        external
    {
        address reporter = _pickReporter(_reporterSeed);
        address referrer = _pickReferrer(_referrerSeed);

        uint256 referred = bound(_referredSeed, 0, MAX_SCORE);
        uint256 self = bound(_selfSeed, 0, MAX_SCORE);

        vm.prank(
            reporter
        );

        hub.reportScores(
            referrer,
            referred,
            self
        );
    }

    function deliverCrumbs(
        uint256 _reporterSeed,
        uint256 _referrerSeed,
        uint256 _weekSeed,
        uint256 _growSeed,
        uint256 _y1DeltaSeed,
        uint256 _y2DeltaSeed,
        uint256 _mDeltaSeed
    )
        external
    {
        uint256 currentWeek = block.timestamp / CohortWeeks.WEEK;

        if (currentWeek == 0) {
            return;
        }

        address reporter = _pickReporter(_reporterSeed);
        address referrer = _pickReferrer(_referrerSeed);

        uint256 lo = currentWeek > 8
            ? currentWeek - 8
            : 0;

        uint256 week = bound(_weekSeed, lo, currentWeek - 1);

        bytes32 key = cellKey(reporter, referrer, week);

        uint256 word = ghostCrumbWord[key];

        bool grow = bound(_growSeed, 0, 9) < 7;

        if (grow) {

            uint256 y1 = _growLane(
                CohortWeeks.laneY1(word),
                bound(_y1DeltaSeed, 0, MAX_LANE_DELTA)
            );

            uint256 y2 = _growLane(
                CohortWeeks.laneY2(word),
                bound(_y2DeltaSeed, 0, MAX_LANE_DELTA)
            );

            uint256 m = _growLane(
                CohortWeeks.laneM(word),
                bound(_mDeltaSeed, 0, MAX_LANE_DELTA)
            );

            word = CohortWeeks.packLanes(y1, y2, m);
            ghostCrumbWord[key] = word;
        }

        if (word == 0) {
            return;
        }

        _touchCell(reporter, referrer, week);
        _accrueExpected(reporter, referrer, week, word);

        uint256[] memory weeksArg = new uint256[](1);
        weeksArg[0] = week;

        uint256[] memory words = new uint256[](1);
        words[0] = word | CohortWeeks.CRUMB_WRITTEN_BIT;

        vm.prank(
            reporter
        );

        hub.deliverCrumbs(
            referrer,
            weeksArg,
            words
        );
    }

    function deliverGap(
        uint256 _reporterSeed,
        uint256 _referrerSeed,
        uint256 _fromSeed,
        uint256 _spanSeed,
        uint256 _matureSeed
    )
        external
    {
        uint256 currentWeek = block.timestamp / CohortWeeks.WEEK;

        if (currentWeek < 2) {
            return;
        }

        address reporter = _pickReporter(_reporterSeed);
        address referrer = _pickReferrer(_referrerSeed);

        uint256 fromWeek = bound(_fromSeed, 0, currentWeek - 2);
        uint256 span = bound(_spanSeed, 1, 3);

        uint256 toWeekExclusive = fromWeek + span > currentWeek
            ? currentWeek
            : fromWeek + span;

        if (toWeekExclusive <= fromWeek) {
            return;
        }

        uint256 mature = bound(_matureSeed, 0, MAX_MATURE);

        uint256 quantityWord = CohortWeeks.packLanes(0, 0, mature * CohortWeeks.WEEK);

        for (uint256 week = fromWeek; week < toWeekExclusive; ++week) {
            _touchCell(reporter, referrer, week);
            _accrueExpected(reporter, referrer, week, quantityWord);
        }

        uint256 record = fromWeek
            | (toWeekExclusive << CohortWeeks.GAP_TO_SHIFT)
            | (mature << CohortWeeks.GAP_MATURE_SHIFT);

        vm.prank(
            reporter
        );

        hub.deliverGap(
            referrer,
            record,
            fromWeek,
            span
        );
    }

    function deliverRemoteCrumbs(
        uint256 _referrerSeed,
        uint256 _weekSeed,
        uint256 _growSeed,
        uint256 _y1DeltaSeed,
        uint256 _y2DeltaSeed,
        uint256 _mDeltaSeed,
        uint256 _delivererSeed,
        uint256 _scoreSeed
    )
        external
    {
        uint256 currentWeek = block.timestamp / CohortWeeks.WEEK;

        if (currentWeek == 0) {
            return;
        }

        address referrer = _pickReferrer(_referrerSeed);

        uint256 lo = currentWeek > 8
            ? currentWeek - 8
            : 0;

        uint256 week = bound(_weekSeed, lo, currentWeek - 1);

        bytes32 key = cellKey(REMOTE_VAULT, referrer, week);

        uint256 word = ghostCrumbWord[key];

        if (bound(_growSeed, 0, 9) < 7) {

            word = CohortWeeks.packLanes(
                _growLane(
                    CohortWeeks.laneY1(word),
                    bound(_y1DeltaSeed, 0, MAX_LANE_DELTA)
                ),
                _growLane(
                    CohortWeeks.laneY2(word),
                    bound(_y2DeltaSeed, 0, MAX_LANE_DELTA)
                ),
                _growLane(
                    CohortWeeks.laneM(word),
                    bound(_mDeltaSeed, 0, MAX_LANE_DELTA)
                )
            );

            ghostCrumbWord[key] = word;
        }

        if (word == 0) {
            return;
        }

        _touchCell(REMOTE_VAULT, referrer, week);
        _accrueExpectedRemote(referrer, week, word);

        ghostRemoteReferred[referrer] += bound(_scoreSeed, 0, MAX_SCORE);
        ghostRemoteSelf[referrer] += bound(_scoreSeed >> 8, 0, MAX_SCORE);

        address deliverer = bound(_delivererSeed, 0, 1) == 0
            ? COURIER
            : referrer;

        bytes memory payload = _packRemoteEnvelope(
            deliverer,
            referrer,
            week,
            word
        );

        bytes32 messageId = keccak256(
            abi.encode(REMOTE_VAULT, remoteNonce)
        );

        remoteNonce += 1;

        vm.prank(
            ROUTER
        );

        hub.ccipReceive(
            Client.Any2EVMMessage({
                messageId: messageId,
                sourceChainSelector: REMOTE_SELECTOR,
                sender: abi.encode(REMOTE_VAULT),
                data: payload,
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );

        hub.applyFlush(
            messageId,
            REMOTE_CHAIN_ID,
            REMOTE_VAULT,
            payload
        );
    }

    function claimUpTo(
        uint256 _referrerSeed,
        uint256 _amountSeed
    )
        external
    {
        address referrer = referrers[_referrerSeed % referrers.length];

        uint256 entitled = hub.claimable(
            block.chainid,
            referrer
        );

        if (entitled == 0) {
            return;
        }

        uint256 amount = bound(
            _amountSeed,
            1,
            entitled
        );

        vm.prank(
            referrer
        );

        hub.claimUpTo(
            block.chainid,
            referrer,
            amount
        );
    }

    function claimRemoteUpTo(
        uint256 _targetSeed,
        uint256 _amountSeed
    )
        external
    {
        uint256 pick = bound(
            _targetSeed,
            0,
            referrers.length
        );

        address target = pick == referrers.length
            ? COURIER
            : referrers[pick];

        uint256 entitled = hub.claimable(
            REMOTE_CHAIN_ID,
            target
        );

        if (entitled == 0) {
            return;
        }

        uint256 amount = bound(
            _amountSeed,
            1,
            entitled
        );

        vm.prank(
            target
        );

        hub.claimUpTo(
            REMOTE_CHAIN_ID,
            target,
            amount
        );
    }

    function warpWeeks(
        uint256 _seed
    )
        external
    {
        uint256 span = bound(_seed, 1, 4);

        vm.warp(
            block.timestamp + span * CohortWeeks.WEEK
        );

        _journalNewlyPastWeeks(
            block.timestamp / CohortWeeks.WEEK
        );
    }

    // ---- internal helpers ----

    function _pickReporter(
        uint256 _seed
    )
        internal
        view
        returns (address)
    {
        return reporters[bound(_seed, 0, reporters.length - 1)];
    }

    function _pickReferrer(
        uint256 _seed
    )
        internal
        view
        returns (address)
    {
        return referrers[bound(_seed, 0, referrers.length - 1)];
    }

    function _growLane(
        uint256 _current,
        uint256 _delta
    )
        internal
        pure
        returns (uint256)
    {
        uint256 sum = _current + _delta;

        return sum > CohortWeeks.LANE_MASK_80
            ? CohortWeeks.LANE_MASK_80
            : sum;
    }

    function _touchCell(
        address _reporter,
        address _referrer,
        uint256 _week
    )
        internal
    {
        bytes32 key = cellKey(_reporter, _referrer, _week);

        if (cellSeen[key]) {
            return;
        }

        cellSeen[key] = true;

        touchedCells.push(
            TouchedCell({
                reporter: _reporter,
                referrer: _referrer,
                week: _week
            })
        );
    }

    function _accrueExpected(
        address _reporter,
        address _referrer,
        uint256 _week,
        uint256 _word
    )
        internal
    {
        (
            uint256 y1Inc,
            uint256 y2Inc,
            uint256 mInc
        ) = _advanceGhostCursor(_reporter, _referrer, _week, _word);

        if (y1Inc == 0 && y2Inc == 0 && mInc == 0) {
            return;
        }

        ghostTotalExpectedPaid += _priceIncrements(
            _referrer,
            _week,
            y1Inc,
            y2Inc,
            mInc
        );
    }

    function _advanceGhostCursor(
        address _reporter,
        address _referrer,
        uint256 _week,
        uint256 _word
    )
        internal
        returns (
            uint256 y1Inc,
            uint256 y2Inc,
            uint256 mInc
        )
    {
        (
            uint256 y1Cursor,
            uint256 y2Cursor,
            uint256 mCursor
        ) = hub.paidCursorAt(_reporter, _referrer, _week);

        uint256 y1In = CohortWeeks.laneY1(_word);
        uint256 y2In = CohortWeeks.laneY2(_word);
        uint256 mIn = CohortWeeks.laneM(_word);

        y1Inc = y1In > y1Cursor ? y1In - y1Cursor : 0;
        y2Inc = y2In > y2Cursor ? y2In - y2Cursor : 0;
        mInc = mIn > mCursor ? mIn - mCursor : 0;

        bytes32 key = cellKey(_reporter, _referrer, _week);

        ghostCursorY1[key] = y1In > y1Cursor ? y1In : y1Cursor;
        ghostCursorY2[key] = y2In > y2Cursor ? y2In : y2Cursor;
        ghostCursorM[key] = mIn > mCursor ? mIn : mCursor;
    }

    function _accrueExpectedRemote(
        address _referrer,
        uint256 _week,
        uint256 _word
    )
        internal
    {
        bytes32 key = cellKey(REMOTE_VAULT, _referrer, _week);

        uint256 y1In = CohortWeeks.laneY1(_word);
        uint256 y2In = CohortWeeks.laneY2(_word);
        uint256 mIn = CohortWeeks.laneM(_word);

        uint256 y1Cursor = ghostCursorY1[key];
        uint256 y2Cursor = ghostCursorY2[key];
        uint256 mCursor = ghostCursorM[key];

        uint256 y1Inc = y1In > y1Cursor ? y1In - y1Cursor : 0;
        uint256 y2Inc = y2In > y2Cursor ? y2In - y2Cursor : 0;
        uint256 mInc = mIn > mCursor ? mIn - mCursor : 0;

        ghostCursorY1[key] = y1In > y1Cursor ? y1In : y1Cursor;
        ghostCursorY2[key] = y2In > y2Cursor ? y2In : y2Cursor;
        ghostCursorM[key] = mIn > mCursor ? mIn : mCursor;

        if (y1Inc == 0 && y2Inc == 0 && mInc == 0) {
            return;
        }

        ghostTotalExpectedPaid += _priceIncrements(
            _referrer,
            _week,
            y1Inc,
            y2Inc,
            mInc
        );
    }

    function _packRemoteEnvelope(
        address _deliverer,
        address _referrer,
        uint256 _week,
        uint256 _word
    )
        internal
        view
        returns (bytes memory)
    {
        uint256[] memory out = new uint256[](5);

        out[0] = CohortWeeks.packFlushHeader(
            _deliverer,
            1,
            block.timestamp
        );

        out[1] = CohortWeeks.packFlushEntry(
            _referrer,
            1,
            0,
            0
        );

        out[2] = CohortWeeks.packFlushScores(
            ghostRemoteReferred[_referrer],
            ghostRemoteSelf[_referrer]
        );

        out[3] = _week;

        out[4] = _word | CohortWeeks.CRUMB_WRITTEN_BIT;

        return abi.encodePacked(
            out
        );
    }

    function _priceIncrements(
        address _referrer,
        uint256 _week,
        uint256 _y1Inc,
        uint256 _y2Inc,
        uint256 _mInc
    )
        internal
        view
        returns (uint256 paid)
    {
        (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        ) = hub.weeklyRates(_referrer, _week);

        paid = _y1Inc * y1Bps / BPS_DENOMINATOR / CohortWeeks.YEAR
            + _y2Inc * y2Bps / BPS_DENOMINATOR / CohortWeeks.YEAR
            + _mInc * mBps / BPS_DENOMINATOR / CohortWeeks.YEAR;
    }

    function _journalNewlyPastWeeks(
        uint256 _currentWeek
    )
        internal
    {
        while (journaledUpToExclusive < _currentWeek) {

            uint256 week = journaledUpToExclusive;

            journaledWeeks.push(week);

            for (uint256 i; i < referrers.length; ++i) {

                address referrer = referrers[i];

                (
                    uint256 y1Bps,
                    uint256 y2Bps,
                    uint256 mBps
                ) = hub.weeklyRates(referrer, week);

                journalY1Bps[week][referrer] = y1Bps;
                journalY2Bps[week][referrer] = y2Bps;
                journalMBps[week][referrer] = mBps;

                (
                    uint256 referredScore,
                    uint256 selfScore
                ) = hub.openingScoresAt(referrer, week);

                journalOpeningReferred[week][referrer] = referredScore;
                journalOpeningSelf[week][referrer] = selfScore;
            }

            journaledUpToExclusive = week + 1;
        }
    }
}

/**
 * @dev Stateful-fuzz invariants for the mainnet referral hub
 * ({ReferralHub} / {ReferralHubIntake} / {ReferralHubRates} /
 * {ReferralHubCheckpoints}), driven by {ReferralHubInvariantHandler}.
 * I3 pins the source-report/global-aggregate identity that
 * `_refreshAggregates` must preserve at every mutation (the larger
 * of the two vouch-week buckets, displaced reports retained for the
 * earlier one, evaluated at the referrer's last checkpoint week); I4
 * pins cursor idempotency and exact pricing
 * (replayed, reordered or partially-overlapping deliveries must accrue
 * exactly once, at exactly the rate the ladder implies); I5 pins
 * rate and opening-score immutability for every week this run ever
 * watched cross into the past; the cap-gate invariant pins the rule
 * that year-2 and mature rates pay in exactly the weeks where the
 * referrer's uncapped ladder sum reaches a nonzero cap, recomputing
 * that sum from `ladderInputsAt` against the effective rate table
 * independently of `_weeklyRates`; the final invariant pins the
 * `totalAccrued == totalClaimed + Σ claimable` accounting identity
 * under randomly interleaved partial claims (the handler claims as
 * the referrer against a pre-funded pot, so a claim never runs dry
 * and never needs the payout vault). The mailbox action extends
 * every one of these identities across the cross-chain path: remote
 * envelopes price into per-source-chain claimable buckets, the
 * courier's bot share moves money between buckets but never changes
 * the accrued total, and the accounting identity closes over the
 * remote referrer buckets and the courier bucket alongside the
 * local ones.
 */
contract ReferralHubInvariantTest is Test {

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    MockUSD internal usdToken;

    ReferralHub internal hub;

    ReferralHubInvariantHandler internal handler;

    struct BucketSums {
        uint256 week;
        uint256 currentSum;
        uint256 previousSum;
        uint256 maxSelf;
    }

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        usdToken = new MockUSD();

        hub = new ReferralHub(
            address(usdToken)
        );

        usdToken.mint(
            address(hub),
            1e30
        );

        address[3] memory reporters = [
            address(0xD1),
            address(0xD2),
            address(0xD3)
        ];

        address[6] memory referrers = [
            address(0xB1),
            address(0xB2),
            address(0xB3),
            address(0xB4),
            address(0xB5),
            address(0xB6)
        ];

        for (uint256 i; i < reporters.length; ++i) {

            hub.setAllowedReporter(
                reporters[i],
                true
            );
        }

        handler = new ReferralHubInvariantHandler(
            hub,
            reporters,
            referrers
        );

        hub.setCcipRouter(
            handler.ROUTER()
        );

        hub.setFlushSource(
            handler.REMOTE_SELECTOR(),
            handler.REMOTE_VAULT(),
            handler.REMOTE_CHAIN_ID()
        );

        targetContract(
            address(handler)
        );
    }

    // ---- invariants ----

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 32
    function invariant_I3_globalEqualsSumOfSourceReports()
        public
        view
    {
        bytes32[4] memory sources = [
            hub.sourceKeyOf(block.chainid, address(0xD1)),
            hub.sourceKeyOf(block.chainid, address(0xD2)),
            hub.sourceKeyOf(block.chainid, address(0xD3)),
            hub.sourceKeyOf(
                handler.REMOTE_CHAIN_ID(),
                handler.REMOTE_VAULT()
            )
        ];

        address[6] memory referrers = [
            address(0xB1),
            address(0xB2),
            address(0xB3),
            address(0xB4),
            address(0xB5),
            address(0xB6)
        ];

        for (uint256 i; i < referrers.length; ++i) {

            uint256 count = hub.checkpointCount(referrers[i]);

            if (count == 0) {
                continue;
            }

            BucketSums memory sums;

            (
                sums.week,
                ,
            ) = hub.checkpointAt(referrers[i], count - 1);

            for (uint256 j; j < sources.length; ++j) {
                _bucketSource(
                    sources[j],
                    referrers[i],
                    sums
                );
            }

            assertEq(
                hub.globalReferredScore(referrers[i]),
                sums.currentSum > sums.previousSum
                    ? sums.currentSum
                    : sums.previousSum,
                "I3: globalReferredScore != max(current bucket, previous bucket)"
            );

            assertEq(
                hub.globalSelfScore(referrers[i]),
                sums.maxSelf,
                "I3: globalSelfScore != max(lastReportOf.self)"
            );
        }
    }

    function _bucketSource(
        bytes32 _source,
        address _referrer,
        BucketSums memory _sums
    )
        internal
        view
    {
        uint256 reportWeek = hub.lastReportWeekOf(_source, _referrer);

        (
            uint256 referred,
            uint256 selfScore
        ) = hub.lastReportOfSource(_source, _referrer);

        if (reportWeek + 1 < _sums.week) {
            return;
        }

        if (selfScore > _sums.maxSelf) {
            _sums.maxSelf = selfScore;
        }

        if (reportWeek < _sums.week) {
            _sums.previousSum += referred;
            return;
        }

        _sums.currentSum += referred;

        (
            uint256 retainedWeek,
            uint256 retainedReferred,
        ) = hub.previousReportOfSource(_source, _referrer);

        if (retainedWeek + 1 == _sums.week) {
            _sums.previousSum += retainedReferred;
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 32
    function invariant_I4_cursorsMonotone_paidMatchesGhost()
        public
        view
    {
        uint256 length = handler.touchedCellsLength();

        for (uint256 i; i < length; ++i) {

            (
                address reporter,
                address referrer,
                uint256 week
            ) = handler.touchedCells(i);

            if (reporter == handler.REMOTE_VAULT()) {
                continue;
            }

            (
                uint256 y1Cursor,
                uint256 y2Cursor,
                uint256 mCursor
            ) = hub.paidCursorAt(reporter, referrer, week);

            bytes32 key = handler.cellKey(reporter, referrer, week);

            assertEq(
                y1Cursor,
                handler.ghostCursorY1(key),
                "I4: y1 cursor != ghost max"
            );

            assertEq(
                y2Cursor,
                handler.ghostCursorY2(key),
                "I4: y2 cursor != ghost max"
            );

            assertEq(
                mCursor,
                handler.ghostCursorM(key),
                "I4: m cursor != ghost max"
            );
        }

        assertEq(
            hub.totalAccrued(),
            handler.ghostTotalExpectedPaid(),
            "I4: totalAccrued != ghost expected paid"
        );
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 32
    function invariant_I5_pastRatesFrozen()
        public
        view
    {
        address[6] memory referrers = [
            address(0xB1),
            address(0xB2),
            address(0xB3),
            address(0xB4),
            address(0xB5),
            address(0xB6)
        ];

        uint256 length = handler.journaledWeeksLength();

        for (uint256 i; i < length; ++i) {

            uint256 week = handler.journaledWeeks(i);

            for (uint256 j; j < referrers.length; ++j) {

                address referrer = referrers[j];

                (
                    uint256 y1Bps,
                    uint256 y2Bps,
                    uint256 mBps
                ) = hub.weeklyRates(referrer, week);

                assertEq(
                    y1Bps,
                    handler.journalY1Bps(week, referrer),
                    "I5: y1 rate drifted for a past week"
                );

                assertEq(
                    y2Bps,
                    handler.journalY2Bps(week, referrer),
                    "I5: y2 rate drifted for a past week"
                );

                assertEq(
                    mBps,
                    handler.journalMBps(week, referrer),
                    "I5: mature rate drifted for a past week"
                );

                (
                    uint256 referredScore,
                    uint256 selfScore
                ) = hub.openingScoresAt(referrer, week);

                assertEq(
                    referredScore,
                    handler.journalOpeningReferred(week, referrer),
                    "I5: opening referred score drifted for a past week"
                );

                assertEq(
                    selfScore,
                    handler.journalOpeningSelf(week, referrer),
                    "I5: opening self score drifted for a past week"
                );
            }
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 32
    function invariant_capGate_y2mPaidOnlyAtCap()
        public
        view
    {
        uint256 length = handler.touchedCellsLength();

        for (uint256 i; i < length; ++i) {

            (
                ,
                address referrer,
                uint256 week
            ) = handler.touchedCells(i);

            ReferralHub.RateTable memory table = _effectiveTable(
                week
            );

            (
                uint256 referredInput,
                uint256 selfInput
            ) = hub.ladderInputsAt(referrer, week);

            uint256 ladderSum = _tierBpsOf(table, selfInput)
                + _tierBpsOf(table, referredInput);

            (
                ,
                uint256 y2Bps,
                uint256 mBps
            ) = hub.weeklyRates(referrer, week);

            bool tailPaid = y2Bps != 0 || mBps != 0;

            bool gateOpen = table.capBps > 0
                && ladderSum >= table.capBps
                && (table.y2RateBps != 0 || table.mRateBps != 0);

            assertEq(
                tailPaid,
                gateOpen,
                "capGate: nonzero y2/m rates iff uncapped ladder sum reaches a nonzero cap"
            );
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 32
    function invariant_totalAccrued_equalsClaimedPlusClaimable()
        public
        view
    {
        address[6] memory referrers = [
            address(0xB1),
            address(0xB2),
            address(0xB3),
            address(0xB4),
            address(0xB5),
            address(0xB6)
        ];

        uint256 sumClaimable;
        uint256 sumPaidOut;

        uint256 remoteChainId = handler.REMOTE_CHAIN_ID();

        for (uint256 i; i < referrers.length; ++i) {
            sumClaimable += hub.claimable(block.chainid, referrers[i]);
            sumClaimable += hub.claimable(remoteChainId, referrers[i]);
            sumPaidOut += usdToken.balanceOf(referrers[i]);
        }

        sumClaimable += hub.claimable(
            remoteChainId,
            handler.COURIER()
        );

        sumPaidOut += usdToken.balanceOf(
            handler.COURIER()
        );

        assertEq(
            hub.totalAccrued(),
            hub.totalClaimed() + sumClaimable,
            "totalAccrued != totalClaimed + sum(claimable)"
        );

        assertEq(
            hub.totalClaimed(),
            sumPaidOut,
            "totalClaimed != sum of USD actually paid out"
        );
    }

    // ---- internal helpers ----

    function _effectiveTable(
        uint256 _week
    )
        internal
        view
        returns (ReferralHub.RateTable memory table)
    {
        uint256 count = hub.rateTableCount();

        table = hub.rateTableAt(0);

        for (uint256 i = 1; i < count; ++i) {

            ReferralHub.RateTable memory candidate = hub.rateTableAt(i);

            if (candidate.effectiveFromWeek <= _week) {
                table = candidate;
            }
        }
    }

    function _tierBpsOf(
        ReferralHub.RateTable memory _table,
        uint256 _value
    )
        internal
        pure
        returns (uint256)
    {
        for (uint256 i = 8; i > 0; --i) {

            if (_value >= _table.thresholds[i - 1]) {
                return _table.tierBps[i - 1];
            }
        }

        return 0;
    }
}
