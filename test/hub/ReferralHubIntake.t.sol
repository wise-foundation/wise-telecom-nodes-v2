// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {ReferralHub} from "../../src/hub/pending/ReferralHub.sol";
import {ReferralHubDeclarations} from "../../src/hub/pending/ReferralHubDeclarations.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev Intake suite for the Phase-4 referral hub {ReferralHub} /
 * {ReferralHubIntake} — the crumb and gap pricing choke point. Covered:
 * exact-integer single-crumb pricing against the genesis R7 tier
 * ladder under the dwell-min W/W+1/W+2 activation schedule; growing
 * current-week words paying only the fresh increment; replay and
 * fuzzed-lane redelivery idempotency; reordered/duplicated delivery
 * sequences converging on the maximum-lane price regardless of order
 * (I4); a regressive lane emitting `CrumbLaneRegression` and pricing
 * zero while the cursor holds at its high-water mark; the absence
 * (word == 0) versus written-but-empty (word == CRUMB_WRITTEN_BIT)
 * versus real-word trichotomy; every `deliverCrumbs`/`deliverGap`
 * validation revert; per-source cursor and score isolation across two
 * independently allowed reporters; exact and windowed-resume gap
 * pricing (mRate genesis-zero, cursors still advance); and the I7
 * rational pricing bound `claimable * 10_000 * YEAR <= lanes * bps`
 * under arbitrary split-delivery sequences. `address(this)` is both
 * deployer/master and, once self-allowed in `setUp`, the default
 * reporter — `deliverer == address(this)` is therefore the default
 * assertion baseline; `reporter1`/`reporter2` are used only where
 * source isolation is itself under test.
 */
contract ReferralHubIntakeTest is Test {

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

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant WEEK = CohortWeeks.WEEK;

    uint256 internal constant YEAR = CohortWeeks.YEAR;

    uint256 internal constant WRITTEN_BIT = CohortWeeks.CRUMB_WRITTEN_BIT;

    uint256 internal constant HIGH_SCORE = 100_000 * 1e6;

    uint256 internal constant TIER6_BPS = 600;

    address internal refA = address(0xB1);

    address internal reporter1 = address(0xD1);

    address internal reporter2 = address(0xD2);

    address internal stranger = address(0xC1);

    ReferralHub internal hub;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        hub = new ReferralHub();

        hub.setAllowedReporter(
            address(this),
            true
        );

        hub.setAllowedReporter(
            reporter1,
            true
        );
    }

    // ---- helpers ----

    function _word(
        uint256 _y1,
        uint256 _y2,
        uint256 _m
    )
        internal
        pure
        returns (uint256)
    {
        return CohortWeeks.packLanes(
            _y1,
            _y2,
            _m
        ) | WRITTEN_BIT;
    }

    function _sourceKeyOf(
        address _reporter
    )
        internal
        pure
        returns (bytes32)
    {
        return bytes32(
            uint256(
                uint160(
                    _reporter
                )
            )
        );
    }

    function _gapRecord(
        uint256 _fromWeek,
        uint256 _toWeekExclusive,
        uint256 _mature
    )
        internal
        pure
        returns (uint256)
    {
        return _fromWeek
            | (_toWeekExclusive << CohortWeeks.GAP_TO_SHIFT)
            | (_mature << CohortWeeks.GAP_MATURE_SHIFT);
    }

    function _deliverCrumbAs(
        address _reporter,
        address _referrer,
        uint256 _week,
        uint256 _word_
    )
        internal
    {
        uint256[] memory weeks_ = new uint256[](1);

        uint256[] memory words_ = new uint256[](1);

        weeks_[0] = _week;
        words_[0] = _word_;

        vm.prank(
            _reporter
        );

        hub.deliverCrumbs(
            _referrer,
            weeks_,
            words_
        );
    }

    function _reportScoresAs(
        address _reporter,
        address _referrer,
        uint256 _referredScore,
        uint256 _selfScore
    )
        internal
    {
        vm.prank(
            _reporter
        );

        hub.reportScores(
            _referrer,
            _referredScore,
            _selfScore
        );
    }

    function _reportAndWarpToTier(
        address _referrer,
        uint256 _referredScore
    )
        internal
        returns (uint256 week)
    {
        week = block.timestamp / WEEK;

        _reportScoresAs(
            address(this),
            _referrer,
            _referredScore,
            0
        );

        _reportScoresAs(
            address(this),
            _referrer,
            _referredScore,
            0
        );

        vm.warp(
            block.timestamp + 2 weeks
        );

        return week + 2;
    }

    function _permutationOf(
        uint256 _seed
    )
        internal
        pure
        returns (uint8[3] memory order)
    {
        uint256 index = _seed % 6;

        if (index == 0) {
            order = [uint8(0), 1, 2];
        } else if (index == 1) {
            order = [uint8(0), 2, 1];
        } else if (index == 2) {
            order = [uint8(1), 0, 2];
        } else if (index == 3) {
            order = [uint8(1), 2, 0];
        } else if (index == 4) {
            order = [uint8(2), 0, 1];
        } else {
            order = [uint8(2), 1, 0];
        }
    }

    // ---- exact-integer pricing ----

    function test_deliverCrumbs_exactSingleCrumb_pricesFullTier()
        public
    {
        uint256 week = _reportAndWarpToTier(
            refA,
            HIGH_SCORE
        );

        uint256 quantity = 1_000 * 1e6 * WEEK;

        uint256 expectedPaid = quantity * TIER6_BPS / 10_000 / YEAR;

        bytes32 source = _sourceKeyOf(
            address(this)
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(hub)
        );

        emit CrumbPriced(
            source,
            refA,
            week,
            address(this),
            quantity,
            0,
            0,
            expectedPaid
        );

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(quantity, 0, 0)
        );

        assertEq(hub.claimable(refA), expectedPaid);
        assertEq(hub.totalAccrued(), expectedPaid);
    }

    function test_deliverCrumbs_growingWord_paysOnlyFreshIncrement()
        public
    {
        uint256 week = _reportAndWarpToTier(
            refA,
            HIGH_SCORE
        );

        uint256 q1 = 400 * 1e6 * WEEK;

        uint256 q2 = 900 * 1e6 * WEEK;

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(q1, 0, 0)
        );

        uint256 expectedFirst = q1 * TIER6_BPS / 10_000 / YEAR;

        assertEq(hub.claimable(refA), expectedFirst);

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(q2, 0, 0)
        );

        uint256 expectedSecond = (q2 - q1) * TIER6_BPS / 10_000 / YEAR;

        assertEq(hub.claimable(refA), expectedFirst + expectedSecond);
    }

    // ---- replay / idempotency ----

    function test_deliverCrumbs_replay_sameWordTwice_secondIsNoop()
        public
    {
        uint256 week = _reportAndWarpToTier(
            refA,
            HIGH_SCORE
        );

        uint256 quantity = 1_000 * 1e6 * WEEK;

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(quantity, 0, 0)
        );

        uint256 claimableAfterFirst = hub.claimable(refA);

        (uint256 y1CursorBefore, , ) = hub.paidCursorAt(
            address(this),
            refA,
            week
        );

        vm.recordLogs();

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(quantity, 0, 0)
        );

        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(hub.claimable(refA), claimableAfterFirst);

        (uint256 y1CursorAfter, , ) = hub.paidCursorAt(
            address(this),
            refA,
            week
        );

        assertEq(y1CursorAfter, y1CursorBefore);
    }

    function testFuzz_redelivery_paysZero(
        uint256 _y1,
        uint256 _y2,
        uint256 _m
    )
        public
    {
        _y1 = bound(_y1, 0, CohortWeeks.LANE_MASK_80);
        _y2 = bound(_y2, 0, CohortWeeks.LANE_MASK_80);
        _m = bound(_m, 0, CohortWeeks.LANE_MASK_80);

        uint256 week = block.timestamp / WEEK;

        uint256 word = _word(_y1, _y2, _m);

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            word
        );

        uint256 claimableAfterFirst = hub.claimable(refA);

        (uint256 y1Before, uint256 y2Before, uint256 mBefore) = hub.paidCursorAt(
            address(this),
            refA,
            week
        );

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            word
        );

        assertEq(hub.claimable(refA), claimableAfterFirst);

        (uint256 y1After, uint256 y2After, uint256 mAfter) = hub.paidCursorAt(
            address(this),
            refA,
            week
        );

        assertEq(y1After, y1Before);
        assertEq(y2After, y2Before);
        assertEq(mAfter, mBefore);
    }

    // ---- reorder / duplicates ----

    function testFuzz_deliveryOrder_totalPayInvariant(
        uint256 _d1,
        uint256 _d2,
        uint256 _d3,
        uint256 _orderSeed
    )
        public
    {
        _d1 = bound(_d1, 1e6, 1e12);
        _d2 = bound(_d2, 1e6, 1e12);
        _d3 = bound(_d3, 1e6, 1e12);

        uint256 q1 = _d1;
        uint256 q2 = q1 + _d2;
        uint256 q3 = q2 + _d3;

        uint256 week = _reportAndWarpToTier(
            refA,
            HIGH_SCORE
        );

        uint256[3] memory values = [q1, q2, q3];

        uint8[3] memory order = _permutationOf(
            _orderSeed
        );

        uint256 cursor;

        uint256 expected;

        for (uint256 pass; pass < 2; ++pass) {

            for (uint256 i; i < 3; ++i) {

                uint256 value = values[order[i]];

                _deliverCrumbAs(
                    address(this),
                    refA,
                    week,
                    _word(value, 0, 0)
                );

                if (value > cursor) {
                    expected += (value - cursor) * TIER6_BPS / 10_000 / YEAR;
                    cursor = value;
                }
            }
        }

        assertEq(cursor, q3);
        assertEq(hub.claimable(refA), expected);
    }

    // ---- regression ----

    function test_deliverCrumbs_regression_paysZeroCursorStaysAtMax()
        public
    {
        uint256 week = _reportAndWarpToTier(
            refA,
            HIGH_SCORE
        );

        uint256 q1 = 200 * 1e6 * WEEK;

        uint256 q2 = 900 * 1e6 * WEEK;

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(q2, 0, 0)
        );

        uint256 claimableAfterFirst = hub.claimable(refA);

        bytes32 source = _sourceKeyOf(
            address(this)
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(hub)
        );

        emit CrumbLaneRegression(
            source,
            refA,
            week,
            0,
            q1,
            q2
        );

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(q1, 0, 0)
        );

        assertEq(hub.claimable(refA), claimableAfterFirst);

        (uint256 y1Cursor, , ) = hub.paidCursorAt(
            address(this),
            refA,
            week
        );

        assertEq(y1Cursor, q2);
    }

    // ---- absence / written-but-empty / real word trichotomy ----

    function test_deliverCrumbs_trichotomy_absenceAndEmptyWordsAreNoops()
        public
    {
        uint256 week = _reportAndWarpToTier(
            refA,
            HIGH_SCORE
        );

        vm.warp(
            block.timestamp + 1 weeks
        );

        vm.recordLogs();

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            0
        );

        assertEq(vm.getRecordedLogs().length, 0);

        (uint256 y1AfterAbsence, , ) = hub.paidCursorAt(
            address(this),
            refA,
            week
        );

        assertEq(y1AfterAbsence, 0);

        vm.recordLogs();

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            WRITTEN_BIT
        );

        assertEq(vm.getRecordedLogs().length, 0);

        (uint256 y1AfterEmpty, , ) = hub.paidCursorAt(
            address(this),
            refA,
            week
        );

        assertEq(y1AfterEmpty, 0);
        assertEq(hub.claimable(refA), 0);
    }

    // ---- crumb validation reverts ----

    function test_RevertWhen_deliverCrumbs_invalidBitsSet()
        public
    {
        uint256 week = block.timestamp / WEEK;

        uint256[] memory weeks_ = new uint256[](1);

        uint256[] memory words_ = new uint256[](1);

        weeks_[0] = week;
        words_[0] = WRITTEN_BIT | (1 << 240);

        vm.expectRevert(
            ReferralHubDeclarations.InvalidCrumbWord.selector
        );

        hub.deliverCrumbs(
            refA,
            weeks_,
            words_
        );

        words_[0] = WRITTEN_BIT | (1 << 253);

        vm.expectRevert(
            ReferralHubDeclarations.InvalidCrumbWord.selector
        );

        hub.deliverCrumbs(
            refA,
            weeks_,
            words_
        );
    }

    function test_RevertWhen_deliverCrumbs_weekInFuture()
        public
    {
        uint256 futureWeek = block.timestamp / WEEK + 1;

        uint256[] memory weeks_ = new uint256[](1);

        uint256[] memory words_ = new uint256[](1);

        weeks_[0] = futureWeek;
        words_[0] = _word(1, 0, 0);

        vm.expectRevert(
            ReferralHubDeclarations.FutureWeek.selector
        );

        hub.deliverCrumbs(
            refA,
            weeks_,
            words_
        );
    }

    function test_RevertWhen_deliverCrumbs_lengthMismatch()
        public
    {
        uint256[] memory weeks_ = new uint256[](2);

        uint256[] memory words_ = new uint256[](1);

        weeks_[0] = block.timestamp / WEEK;
        weeks_[1] = block.timestamp / WEEK;
        words_[0] = _word(1, 0, 0);

        vm.expectRevert(
            ReferralHubDeclarations.LengthMismatch.selector
        );

        hub.deliverCrumbs(
            refA,
            weeks_,
            words_
        );
    }

    function test_RevertWhen_deliverCrumbs_batchTooLarge()
        public
    {
        uint256 count = CohortWeeks.MAX_SETTLE_BOUNDARIES + 1;

        uint256[] memory weeks_ = new uint256[](count);

        uint256[] memory words_ = new uint256[](count);

        for (uint256 i; i < count; ++i) {
            weeks_[i] = block.timestamp / WEEK;
            words_[i] = _word(1, 0, 0);
        }

        vm.expectRevert(
            ReferralHubDeclarations.BatchTooLarge.selector
        );

        hub.deliverCrumbs(
            refA,
            weeks_,
            words_
        );
    }

    function test_RevertWhen_stranger_callsAnyReporterEntrypoint()
        public
    {
        uint256[] memory weeks_ = new uint256[](1);

        uint256[] memory words_ = new uint256[](1);

        weeks_[0] = block.timestamp / WEEK;
        words_[0] = _word(1, 0, 0);

        vm.prank(
            stranger
        );

        vm.expectRevert(
            ReferralHubDeclarations.NotReporter.selector
        );

        hub.reportScores(
            refA,
            HIGH_SCORE,
            0
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            ReferralHubDeclarations.NotReporter.selector
        );

        hub.deliverCrumbs(
            refA,
            weeks_,
            words_
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            ReferralHubDeclarations.NotReporter.selector
        );

        hub.deliverGap(
            refA,
            _gapRecord(0, 1, 0),
            0,
            1
        );
    }

    // ---- two-reporter source isolation ----

    function test_twoReporters_sameReferrerSameWeek_isolatedCursorsAndClaimableSum()
        public
    {
        hub.setAllowedReporter(
            reporter2,
            true
        );

        _reportScoresAs(
            reporter1,
            refA,
            HIGH_SCORE,
            0
        );

        vm.warp(
            block.timestamp + 2 weeks
        );

        uint256 week = block.timestamp / WEEK;

        uint256 q1 = 300 * 1e6 * WEEK;

        uint256 q2 = 700 * 1e6 * WEEK;

        _deliverCrumbAs(
            reporter1,
            refA,
            week,
            _word(q1, 0, 0)
        );

        _deliverCrumbAs(
            reporter2,
            refA,
            week,
            _word(q2, 0, 0)
        );

        uint256 expected1 = q1 * TIER6_BPS / 10_000 / YEAR;

        uint256 expected2 = q2 * TIER6_BPS / 10_000 / YEAR;

        assertEq(hub.claimable(refA), expected1 + expected2);

        (uint256 y1Reporter1, , ) = hub.paidCursorAt(reporter1, refA, week);
        (uint256 y1Reporter2, , ) = hub.paidCursorAt(reporter2, refA, week);

        assertEq(y1Reporter1, q1);
        assertEq(y1Reporter2, q2);

        (uint256 referred1, uint256 self1) = hub.lastReportOf(reporter1, refA);
        (uint256 referred2, uint256 self2) = hub.lastReportOf(reporter2, refA);

        assertEq(referred1, HIGH_SCORE);
        assertEq(self1, 0);
        assertEq(referred2, 0);
        assertEq(self2, 0);
    }

    // ---- gap synthesis ----

    function test_deliverGap_exactSynthesis_pricesFullSpanCursors()
        public
    {
        uint256 fromWeek = block.timestamp / WEEK;

        uint256 toWeekExclusive = fromWeek + 66;

        uint256 mature = 5_000 * 1e6;

        uint256 record = _gapRecord(
            fromWeek,
            toWeekExclusive,
            mature
        );

        vm.warp(
            block.timestamp + 70 weeks
        );

        bytes32 source = _sourceKeyOf(
            address(this)
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(hub)
        );

        emit GapPriced(
            source,
            refA,
            fromWeek,
            toWeekExclusive,
            0
        );

        hub.deliverGap(
            refA,
            record,
            fromWeek,
            66
        );

        uint256 expectedMCursor = mature * WEEK;

        (, , uint256 mCursorFirst) = hub.paidCursorAt(address(this), refA, fromWeek);
        (, , uint256 mCursorMid) = hub.paidCursorAt(address(this), refA, fromWeek + 33);
        (, , uint256 mCursorLast) = hub.paidCursorAt(address(this), refA, toWeekExclusive - 1);

        assertEq(mCursorFirst, expectedMCursor);
        assertEq(mCursorMid, expectedMCursor);
        assertEq(mCursorLast, expectedMCursor);

        assertEq(hub.claimable(refA), 0);
    }

    function test_deliverGap_windowedResume_coversFullSpanAndOverlapIsNoop()
        public
    {
        uint256 fromWeek = block.timestamp / WEEK;

        uint256 toWeekExclusive = fromWeek + 200;

        uint256 mature = 2_000 * 1e6;

        uint256 record = _gapRecord(
            fromWeek,
            toWeekExclusive,
            mature
        );

        vm.warp(
            block.timestamp + 205 weeks
        );

        hub.deliverGap(
            refA,
            record,
            fromWeek,
            104
        );

        hub.deliverGap(
            refA,
            record,
            fromWeek + 104,
            104
        );

        uint256 expectedMCursor = mature * WEEK;

        (, , uint256 cursorStart) = hub.paidCursorAt(address(this), refA, fromWeek);
        (, , uint256 cursorEndOfFirstChunk) = hub.paidCursorAt(address(this), refA, fromWeek + 103);
        (, , uint256 cursorStartOfSecondChunk) = hub.paidCursorAt(address(this), refA, fromWeek + 104);
        (, , uint256 cursorLast) = hub.paidCursorAt(address(this), refA, toWeekExclusive - 1);

        assertEq(cursorStart, expectedMCursor);
        assertEq(cursorEndOfFirstChunk, expectedMCursor);
        assertEq(cursorStartOfSecondChunk, expectedMCursor);
        assertEq(cursorLast, expectedMCursor);

        vm.recordLogs();

        hub.deliverGap(
            refA,
            record,
            fromWeek,
            104
        );

        assertEq(vm.getRecordedLogs().length, 0);
    }

    // ---- gap validation reverts ----

    function test_RevertWhen_deliverGap_invalidRecord()
        public
    {
        uint256 week = block.timestamp / WEEK;

        vm.expectRevert(
            ReferralHubDeclarations.InvalidGapRecord.selector
        );

        hub.deliverGap(
            refA,
            _gapRecord(week, week, 0),
            week,
            1
        );

        uint256 recordWithHighBit = _gapRecord(week, week + 1, 0) | (1 << 144);

        vm.expectRevert(
            ReferralHubDeclarations.InvalidGapRecord.selector
        );

        hub.deliverGap(
            refA,
            recordWithHighBit,
            week,
            1
        );

        uint256 tooLargeMature = CohortWeeks.LANE_MASK_80 / WEEK + 1;

        vm.expectRevert(
            ReferralHubDeclarations.InvalidGapRecord.selector
        );

        hub.deliverGap(
            refA,
            _gapRecord(week, week + 1, tooLargeMature),
            week,
            1
        );
    }

    function test_RevertWhen_deliverGap_futureWeek()
        public
    {
        uint256 week = block.timestamp / WEEK;

        uint256 record = _gapRecord(
            week,
            week + 1,
            0
        );

        vm.expectRevert(
            ReferralHubDeclarations.FutureWeek.selector
        );

        hub.deliverGap(
            refA,
            record,
            week,
            1
        );
    }

    function test_RevertWhen_deliverGap_invalidWindow()
        public
    {
        uint256 fromWeek = block.timestamp / WEEK;

        uint256 toWeekExclusive = fromWeek + 10;

        uint256 record = _gapRecord(
            fromWeek,
            toWeekExclusive,
            0
        );

        vm.warp(
            block.timestamp + 15 weeks
        );

        vm.expectRevert(
            ReferralHubDeclarations.InvalidWindow.selector
        );

        hub.deliverGap(
            refA,
            record,
            fromWeek,
            0
        );

        vm.expectRevert(
            ReferralHubDeclarations.InvalidWindow.selector
        );

        hub.deliverGap(
            refA,
            record,
            fromWeek - 1,
            1
        );

        vm.expectRevert(
            ReferralHubDeclarations.InvalidWindow.selector
        );

        hub.deliverGap(
            refA,
            record,
            toWeekExclusive,
            1
        );
    }

    // ---- I7 rational pricing bound ----

    function testFuzz_I7_totalPaidLeqLanesTimesRate(
        uint256 _d1,
        uint256 _d2,
        uint256 _d3
    )
        public
    {
        _d1 = bound(_d1, 0, 1e14);
        _d2 = bound(_d2, 0, 1e14);
        _d3 = bound(_d3, 0, 1e14);

        uint256 week = _reportAndWarpToTier(
            refA,
            HIGH_SCORE
        );

        uint256 total = _d1 + _d2 + _d3;

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(_d1, 0, 0)
        );

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(_d1 + _d2, 0, 0)
        );

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(total, 0, 0)
        );

        assertLe(
            hub.claimable(refA) * 10_000 * YEAR,
            total * TIER6_BPS
        );
    }
}
