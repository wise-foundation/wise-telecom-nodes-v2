// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {ReferralHub} from "../../src/hub/pending/ReferralHub.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev Drives the mainnet referral hub through bounded random
 * `reportScores` / `deliverCrumbs` / `deliverGap` / `snapshotWeek` /
 * `warpWeeks` actions across a closed universe of 3 allowlisted
 * reporters and 6 referrers, matching the handler-plus-ghost shape of
 * `test/diamond/invariant/CohortRecorderInvariant.t.sol`. Crumb words
 * are driven through a per-(reporter, referrer, week) ghost that only
 * ever grows or replays — never regresses — mimicking the recorder's
 * "lanes only ever grow within a week" ring model (see the
 * CohortWeeks doc comment);
 * `deliverCrumbs` and the per-week loop inside `deliverGap` are
 * restricted to strictly-past weeks so the handler's pre-read of
 * `weeklyRates`/`paidCursorAt` is guaranteed stable against the exact
 * state the real call will observe (a current-week delivery could
 * trigger a same-call `_snapshotCutoffIfNewWeek` the handler cannot
 * see from a separate view call — this suite sidesteps that seam
 * entirely rather than modeling it).
 *
 * Ghost state: `ghostCrumbWord` (per cell, last word this handler
 * chose to send, grow-or-replay only); `ghostCursorY1/Y2/M` and
 * `ghostTotalExpectedPaid` (per-cell high-water cursor and a running
 * total, both computed in the HANDLER by reading `paidCursorAt` and
 * `weeklyRates` immediately before every pricing call and replicating
 * `_laneIncrement` / `_advanceCursor` / `_payIncrements` verbatim —
 * this is what makes I4 an exact equality rather than a bound);
 * `touchedCells` (every (reporter, referrer, week) triple either
 * action has ever priced, deduplicated); `journaledWeeks` plus
 * `journalCutoff` / `journalBucket` / `journalQualified` (a snapshot
 * taken the FIRST time each week crosses from current into fully past,
 * i.e. inside `warpWeeks` right after the warp, for exactly the weeks
 * newly left behind — re-verified every invariant check to prove no
 * later-arriving report or delivery can ever move a closed week's
 * verdict, per I5). I3 is checked by reading `lastReportOf` for
 * each of the 3 reporters directly off the hub rather than mirroring
 * it in a second ghost mapping — the invariant already cross-checks
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

    ReferralHub internal immutable hub;

    address[3] internal reporters;

    address[6] internal referrers;

    uint256 public journaledUpToExclusive;

    uint256[] public journaledWeeks;

    mapping(uint256 => uint256) public journalCutoff;

    mapping(uint256 => mapping(address => uint256)) public journalBucket;

    mapping(uint256 => mapping(address => bool)) public journalQualified;

    mapping(bytes32 => uint256) internal ghostCrumbWord;

    mapping(bytes32 => bool) internal cellSeen;

    TouchedCell[] public touchedCells;

    mapping(bytes32 => uint256) public ghostCursorY1;

    mapping(bytes32 => uint256) public ghostCursorY2;

    mapping(bytes32 => uint256) public ghostCursorM;

    uint256 public ghostTotalExpectedPaid;

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

        hub.reportScores(referrer, referred, self);
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

        hub.deliverCrumbs(referrer, weeksArg, words);
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

        hub.deliverGap(referrer, record, fromWeek, span);
    }

    function pokeSnapshot()
        external
    {
        hub.snapshotWeek();
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

        ghostTotalExpectedPaid += _priceIncrements(_referrer, _week, y1Inc, y2Inc, mInc);
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
            journalCutoff[week] = hub.cutoffAt(week);

            for (uint256 i; i < referrers.length; ++i) {

                address referrer = referrers[i];

                journalBucket[week][referrer] = hub.bucketAt(referrer, week);
                journalQualified[week][referrer] = hub.qualifiedAt(week, referrer);
            }

            journaledUpToExclusive = week + 1;
        }
    }
}

/**
 * @dev Stateful-fuzz invariants for the mainnet referral hub
 * ({ReferralHub} / {ReferralHubIntake} / {ReferralHubRanking} /
 * {ReferralHubCheckpoints}), driven by {ReferralHubInvariantHandler}.
 * I3 pins the source-report/global-aggregate identity that
 * `_applyScoreReport`'s diff-and-apply arithmetic must preserve; the
 * Fenwick invariant pins the active-count/tree identity the ranking
 * layer must preserve under arbitrary activation, deactivation and
 * re-crossing sequences; I4 pins cursor idempotency and exact pricing
 * (replayed, reordered or partially-overlapping deliveries must accrue
 * exactly once, at exactly the rate the ladder implies); I5 pins
 * verdict immutability for every week this run ever watched cross into
 * the past; the final invariant pins the `claimable` / `totalAccrued`
 * accounting identity that will anchor the hub-to-vault payout
 * message once claims exist.
 */
contract ReferralHubInvariantTest is Test {

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant MIN_ACTIVE_SCORE = 1_000 * 1e6;

    uint256 internal constant BUCKET_COUNT = 2_048;

    ReferralHub internal hub;

    ReferralHubInvariantHandler internal handler;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        hub = new ReferralHub();

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

        for (uint256 i; i < referrers.length; ++i) {

            address referrer = referrers[i];

            uint256 sumReferred;
            uint256 sumSelf;

            for (uint256 j; j < reporters.length; ++j) {

                (
                    uint256 referred,
                    uint256 selfScore
                ) = hub.lastReportOf(reporters[j], referrer);

                sumReferred += referred;
                sumSelf += selfScore;
            }

            assertEq(
                hub.globalReferredScore(referrer),
                sumReferred,
                "I3: globalReferredScore != sum(lastReportOf.referred)"
            );

            assertEq(
                hub.globalSelfScore(referrer),
                sumSelf,
                "I3: globalSelfScore != sum(lastReportOf.self)"
            );
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 32
    function invariant_fenwick_countAndSumConsistent()
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

        uint256 activeCount;

        for (uint256 i; i < referrers.length; ++i) {

            if (hub.globalReferredScore(referrers[i]) >= MIN_ACTIVE_SCORE) {
                activeCount += 1;
            }
        }

        assertEq(
            hub.activeReferrerCount(),
            activeCount,
            "fenwick: activeReferrerCount != count(score >= MIN_ACTIVE_SCORE)"
        );

        assertEq(
            hub.prefixCount(BUCKET_COUNT),
            hub.activeReferrerCount(),
            "fenwick: prefixCount(2048) != activeReferrerCount"
        );
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
    function invariant_I5_pastVerdictsFrozen()
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

            assertEq(
                hub.cutoffAt(week),
                handler.journalCutoff(week),
                "I5: cutoffAt drifted for a past week"
            );

            for (uint256 j; j < referrers.length; ++j) {

                address referrer = referrers[j];

                assertEq(
                    hub.bucketAt(referrer, week),
                    handler.journalBucket(week, referrer),
                    "I5: bucketAt drifted for a past week"
                );

                assertEq(
                    hub.qualifiedAt(week, referrer),
                    handler.journalQualified(week, referrer),
                    "I5: qualifiedAt drifted for a past week"
                );
            }
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 32
    function invariant_totalAccrued_equalsSumClaimable()
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

        for (uint256 i; i < referrers.length; ++i) {
            sumClaimable += hub.claimable(referrers[i]);
        }

        assertEq(
            hub.totalAccrued(),
            sumClaimable,
            "totalAccrued != sum(claimable)"
        );
    }
}
