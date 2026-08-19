// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ReferralHub} from "../../src/hub/pending/ReferralHub.sol";
import {ReferralHubDeclarations} from "../../src/hub/pending/ReferralHubDeclarations.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";

/**
 * @dev Unit and fuzz suite for {ReferralHubCheckpoints} on the actual
 * deployed {ReferralHub}. Driving writes go through `reportScores` —
 * the only source of checkpoint mutations exercised here. The hub is
 * deployed and wired with this test contract as both master and the
 * sole allowed reporter, so no `vm.prank` is needed for the happy
 * paths; only `stranger` calls are pranked for access-control reverts.
 *
 * Load-bearing properties under test: the opening-value read rule
 * (the last checkpoint entry with entryWeek STRICTLY before the
 * query week, zero before the first entry); the checkpoint discipline
 * that a week's tail entry updates in place while past entries never
 * change again (`checkpointCount` grows at most once per
 * referrer-week); the immutability of every past week's rate verdict
 * (`weeklyRates` triples and `openingScoresAt` pairs) even after
 * late-arriving data lands in a future week, pinned both by a
 * hand-built scenario and by a randomized seed-walk journal; the
 * score-report intake bounds and per-component diff discipline; and
 * the dwell-min policy knob, including its boundary-straddle
 * zero-for-two-weeks defense, its plain-opening behavior when
 * disabled, and the week-0 short-circuit that avoids an underflow on
 * `week - 1`.
 */
contract ReferralHubCheckpointsTest is Test {

    event ReferrerCheckpointed(
        address indexed referrer,
        uint256 indexed week,
        uint256 referredScore,
        uint256 selfScore
    );

    event DwellMinScheduled(
        uint256 indexed effectiveFromWeek,
        bool enabled
    );

    uint256 internal constant WEEK = 1 weeks;

    uint256 internal constant BASE_WEEK = 3_000;

    uint256 internal constant BASE_TIME = BASE_WEEK * WEEK + 1 hours;

    uint256 internal constant MAX_JOURNAL_WEEKS = 24;

    uint256 internal constant MAX_SOURCE_SCORE = 3 * CohortWeeks.LANE_MASK_80;

    struct RateJournal {
        uint256[3] y1;
        uint256[3] y2;
        uint256[3] m;
    }

    address internal refA = address(0xC1);
    address internal refB = address(0xC2);
    address internal stranger = address(0xBEEF);

    ReferralHub internal hub;

    mapping(uint256 => bytes32) internal journalFoldA;
    mapping(uint256 => bytes32) internal journalFoldB;
    mapping(uint256 => bytes32) internal journalFoldC;

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
    }

    // ---- helpers ----

    function _report(
        address _referrer,
        uint256 _referredAbs,
        uint256 _selfAbs
    )
        internal
    {
        hub.reportScores(
            _referrer,
            _referredAbs,
            _selfAbs
        );
    }

    function _warpToWeek(
        uint256 _weekOffset
    )
        internal
    {
        vm.warp(
            (BASE_WEEK + _weekOffset) * WEEK + 1 hours
        );
    }

    function _applyRandomOp(
        uint256 _state,
        address[] memory _refs
    )
        internal
    {
        address referrer = _refs[_state % 3];

        uint256 branch = (_state >> 8) % 2;

        if (branch == 0) {

            uint256 referred = bound(
                _state >> 16,
                0,
                2_000_000 * 1e6
            );

            uint256 selfScore = bound(
                _state >> 96,
                0,
                2_000_000 * 1e6
            );

            _report(
                referrer,
                referred,
                selfScore
            );

        } else {

            uint256 weeksForward = bound(
                _state >> 16,
                0,
                2
            );

            if (weeksForward > 0) {

                vm.warp(
                    block.timestamp + weeksForward * WEEK
                );
            }
        }
    }

    function _verdictFold(
        address _referrer,
        uint256 _week
    )
        internal
        view
        returns (bytes32)
    {
        (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        ) = hub.weeklyRates(
            _referrer,
            _week
        );

        (
            uint256 referredOpening,
            uint256 selfOpening
        ) = hub.openingScoresAt(
            _referrer,
            _week
        );

        return keccak256(
            abi.encode(
                y1Bps,
                y2Bps,
                mBps,
                referredOpening,
                selfOpening
            )
        );
    }

    function _journalWeek(
        uint256 _w,
        address[] memory _refs
    )
        internal
    {
        uint256 week = BASE_WEEK + _w;

        journalFoldA[_w] = _verdictFold(_refs[0], week);
        journalFoldB[_w] = _verdictFold(_refs[1], week);
        journalFoldC[_w] = _verdictFold(_refs[2], week);
    }

    function _assertJournalWeek(
        uint256 _w,
        address[] memory _refs
    )
        internal
        view
    {
        uint256 week = BASE_WEEK + _w;

        assertEq(_verdictFold(_refs[0], week), journalFoldA[_w]);
        assertEq(_verdictFold(_refs[1], week), journalFoldB[_w]);
        assertEq(_verdictFold(_refs[2], week), journalFoldC[_w]);
    }

    // ---- opening scores & checkpoint history ----

    function test_openingScoresAt_multiReportWeek_exactValues()
        public
    {
        _report(
            refA,
            2_000 * 1e6,
            500 * 1e6
        );

        _report(
            refA,
            4_000 * 1e6,
            1_000 * 1e6
        );

        _report(
            refA,
            6_000 * 1e6,
            1_500 * 1e6
        );

        (
            uint256 referredAtW,
            uint256 selfAtW
        ) = hub.openingScoresAt(
            refA,
            BASE_WEEK
        );

        assertEq(referredAtW, 0);
        assertEq(selfAtW, 0);

        (
            uint256 referredAtW1,
            uint256 selfAtW1
        ) = hub.openingScoresAt(
            refA,
            BASE_WEEK + 1
        );

        assertEq(referredAtW1, 6_000 * 1e6);
        assertEq(selfAtW1, 1_500 * 1e6);

        assertEq(hub.checkpointCount(refA), 1);

        (
            uint256 week,
            uint256 referred,
            uint256 selfScore
        ) = hub.checkpointAt(
            refA,
            0
        );

        assertEq(week, BASE_WEEK);
        assertEq(referred, 6_000 * 1e6);
        assertEq(selfScore, 1_500 * 1e6);
    }

    function test_openingScoresAt_quietSpanCarriesForward()
        public
    {
        _report(
            refA,
            10_000 * 1e6,
            2_000 * 1e6
        );

        uint256[4] memory offsets = [
            uint256(1),
            5,
            20,
            50
        ];

        for (uint256 i; i < 4; ++i) {

            (
                uint256 referred,
                uint256 selfScore
            ) = hub.openingScoresAt(
                refA,
                BASE_WEEK + offsets[i]
            );

            assertEq(referred, 10_000 * 1e6);
            assertEq(selfScore, 2_000 * 1e6);
        }
    }

    function test_openingScoresAt_preHistory_returnsZero()
        public
    {
        _report(
            refA,
            60_000 * 1e6,
            5_000 * 1e6
        );

        (
            uint256 referredZero,
            uint256 selfZero
        ) = hub.openingScoresAt(
            refA,
            0
        );

        assertEq(referredZero, 0);
        assertEq(selfZero, 0);

        (
            uint256 referredPrev,
            uint256 selfPrev
        ) = hub.openingScoresAt(
            refA,
            BASE_WEEK - 1
        );

        assertEq(referredPrev, 0);
        assertEq(selfPrev, 0);

        (
            uint256 referredSame,
            uint256 selfSame
        ) = hub.openingScoresAt(
            refA,
            BASE_WEEK
        );

        assertEq(referredSame, 0);
        assertEq(selfSame, 0);
    }

    // ---- immutability under late data ----

    function test_weeklyRates_immutableUnderLateData()
        public
    {
        _report(
            refA,
            1_000_000 * 1e6,
            10_000 * 1e6
        );

        _report(
            refB,
            20_000 * 1e6,
            0
        );

        _warpToWeek(1);

        _report(
            refA,
            1_200_000 * 1e6,
            10_000 * 1e6
        );

        _warpToWeek(2);

        _report(
            refB,
            25_000 * 1e6,
            0
        );

        _warpToWeek(3);

        uint256[3] memory pastWeeks = [
            BASE_WEEK,
            BASE_WEEK + 1,
            BASE_WEEK + 2
        ];

        RateJournal memory journalA;
        RateJournal memory journalB;

        for (uint256 i; i < 3; ++i) {

            (journalA.y1[i], journalA.y2[i], journalA.m[i]) = hub.weeklyRates(refA, pastWeeks[i]);
            (journalB.y1[i], journalB.y2[i], journalB.m[i]) = hub.weeklyRates(refB, pastWeeks[i]);
        }

        assertEq(journalA.y1[2], 1_000);
        assertEq(journalA.y2[2], 500);
        assertEq(journalA.m[2], 100);

        _warpToWeek(5);

        _report(
            refA,
            2_000_000 * 1e6,
            0
        );

        _report(
            refB,
            1_500_000 * 1e6,
            0
        );

        for (uint256 i; i < 3; ++i) {

            (uint256 y1After, uint256 y2After, uint256 mAfter) = hub.weeklyRates(refA, pastWeeks[i]);

            assertEq(y1After, journalA.y1[i]);
            assertEq(y2After, journalA.y2[i]);
            assertEq(mAfter, journalA.m[i]);

            (y1After, y2After, mAfter) = hub.weeklyRates(refB, pastWeeks[i]);

            assertEq(y1After, journalB.y1[i]);
            assertEq(y2After, journalB.y2[i]);
            assertEq(mAfter, journalB.m[i]);
        }
    }

    function testFuzz_verdictJournal_neverRewrites(
        uint256 _seed
    )
        public
    {
        address[] memory refs = new address[](3);

        refs[0] = address(0xF1);
        refs[1] = address(0xF2);
        refs[2] = address(0xF3);

        uint256 state = _seed;

        for (uint256 i; i < 12; ++i) {

            state = uint256(
                keccak256(
                    abi.encode(
                        state,
                        i
                    )
                )
            );

            _applyRandomOp(
                state,
                refs
            );
        }

        uint256 currentWeek = block.timestamp / WEEK;

        uint256 pastWeekCount = currentWeek > BASE_WEEK
            ? currentWeek - BASE_WEEK
            : 0;

        if (pastWeekCount > MAX_JOURNAL_WEEKS) {
            pastWeekCount = MAX_JOURNAL_WEEKS;
        }

        for (uint256 w; w < pastWeekCount; ++w) {
            _journalWeek(w, refs);
        }

        for (uint256 i; i < 12; ++i) {

            state = uint256(
                keccak256(
                    abi.encode(
                        state,
                        i
                    )
                )
            );

            _applyRandomOp(
                state,
                refs
            );
        }

        for (uint256 w; w < pastWeekCount; ++w) {
            _assertJournalWeek(w, refs);
        }
    }

    // ---- dwell-min ----

    function test_ladderInputsAt_dwellMinBoundaryStraddle_zeroesTwoWeeks()
        public
    {
        _report(
            refA,
            60_000 * 1e6,
            15_000 * 1e6
        );

        (
            uint256 referredAtW,
            uint256 selfAtW
        ) = hub.ladderInputsAt(
            refA,
            BASE_WEEK
        );

        assertEq(referredAtW, 0);
        assertEq(selfAtW, 0);

        (
            uint256 referredAtW1,
            uint256 selfAtW1
        ) = hub.ladderInputsAt(
            refA,
            BASE_WEEK + 1
        );

        assertEq(referredAtW1, 0);
        assertEq(selfAtW1, 0);

        (
            uint256 referredAtW2,
            uint256 selfAtW2
        ) = hub.ladderInputsAt(
            refA,
            BASE_WEEK + 2
        );

        assertEq(referredAtW2, 60_000 * 1e6);
        assertEq(selfAtW2, 15_000 * 1e6);

        (uint256 y1AtW, , ) = hub.weeklyRates(refA, BASE_WEEK);
        (uint256 y1AtW1, , ) = hub.weeklyRates(refA, BASE_WEEK + 1);
        (uint256 y1AtW2, , ) = hub.weeklyRates(refA, BASE_WEEK + 2);

        assertEq(y1AtW, 0);
        assertEq(y1AtW1, 0);
        assertEq(y1AtW2, 700);
    }

    function test_ladderInputsAt_dwellMinDisabled_usesPlainOpening()
        public
    {
        hub.scheduleDwellMin(
            BASE_WEEK + 1,
            false
        );

        _report(
            refA,
            60_000 * 1e6,
            15_000 * 1e6
        );

        _warpToWeek(1);

        (
            uint256 referredInput,
            uint256 selfInput
        ) = hub.ladderInputsAt(
            refA,
            BASE_WEEK + 1
        );

        assertEq(referredInput, 60_000 * 1e6);
        assertEq(selfInput, 15_000 * 1e6);

        (uint256 y1Bps, , ) = hub.weeklyRates(refA, BASE_WEEK + 1);

        assertEq(y1Bps, 700);
    }

    function test_ladderInputsAt_week0_usesOpeningAlone()
        public
    {
        vm.warp(
            3 days
        );

        _report(
            refA,
            60_000 * 1e6,
            15_000 * 1e6
        );

        (
            uint256 referredInput,
            uint256 selfInput
        ) = hub.ladderInputsAt(
            refA,
            0
        );

        assertEq(referredInput, 0);
        assertEq(selfInput, 0);
    }

    function test_scheduleDwellMin_emitsEventAndTakesEffectAtWeek()
        public
    {
        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(hub)
        );

        emit DwellMinScheduled(
            BASE_WEEK + 2,
            false
        );

        hub.scheduleDwellMin(
            BASE_WEEK + 2,
            false
        );

        assertTrue(hub.dwellMinAt(0));
        assertTrue(hub.dwellMinAt(BASE_WEEK + 1));
        assertFalse(hub.dwellMinAt(BASE_WEEK + 2));
        assertFalse(hub.dwellMinAt(BASE_WEEK + 100));
    }

    function test_scheduleDwellMin_nonMaster_reverts()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        hub.scheduleDwellMin(
            BASE_WEEK + 2,
            false
        );
    }

    function test_scheduleDwellMin_notFuture_reverts()
        public
    {
        vm.expectRevert(
            ReferralHubDeclarations.DwellMinNotFuture.selector
        );

        hub.scheduleDwellMin(
            BASE_WEEK,
            false
        );
    }

    function test_scheduleDwellMin_notOrdered_reverts()
        public
    {
        hub.scheduleDwellMin(
            BASE_WEEK + 3,
            false
        );

        vm.expectRevert(
            ReferralHubDeclarations.DwellMinNotOrdered.selector
        );

        hub.scheduleDwellMin(
            BASE_WEEK + 2,
            true
        );
    }

    function test_scheduleDwellMin_pastWeeksKeepTheirSetting()
        public
    {
        _report(
            refA,
            60_000 * 1e6,
            15_000 * 1e6
        );

        _warpToWeek(1);

        (uint256 y1Dwelled, , ) = hub.weeklyRates(refA, BASE_WEEK + 1);

        assertEq(y1Dwelled, 0);

        hub.scheduleDwellMin(
            BASE_WEEK + 2,
            false
        );

        _warpToWeek(3);

        (uint256 y1Replay, , ) = hub.weeklyRates(refA, BASE_WEEK + 1);
        (uint256 y1Plain, , ) = hub.weeklyRates(refA, BASE_WEEK + 2);

        assertEq(y1Replay, 0);
        assertEq(y1Plain, 700);
    }

    // ---- checkpoint tail discipline ----

    function test_checkpointAt_sameWeekReports_updatesTailInPlace()
        public
    {
        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(hub)
        );

        emit ReferrerCheckpointed(
            refA,
            BASE_WEEK,
            1_000 * 1e6,
            200 * 1e6
        );

        _report(
            refA,
            1_000 * 1e6,
            200 * 1e6
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(hub)
        );

        emit ReferrerCheckpointed(
            refA,
            BASE_WEEK,
            2_000 * 1e6,
            300 * 1e6
        );

        _report(
            refA,
            2_000 * 1e6,
            300 * 1e6
        );

        assertEq(hub.checkpointCount(refA), 1);

        (
            uint256 week,
            uint256 referred,
            uint256 selfScore
        ) = hub.checkpointAt(
            refA,
            0
        );

        assertEq(week, BASE_WEEK);
        assertEq(referred, 2_000 * 1e6);
        assertEq(selfScore, 300 * 1e6);
    }

    function test_reportScores_identicalReport_noOp()
        public
    {
        _report(
            refA,
            1_000 * 1e6,
            200 * 1e6
        );

        assertEq(hub.checkpointCount(refA), 1);

        vm.recordLogs();

        _report(
            refA,
            1_000 * 1e6,
            200 * 1e6
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0);
        assertEq(hub.checkpointCount(refA), 1);
    }

    function test_checkpointCount_incrementsOncePerDistinctWeek()
        public
    {
        _report(
            refA,
            1_000 * 1e6,
            100 * 1e6
        );

        _report(
            refA,
            2_000 * 1e6,
            200 * 1e6
        );

        assertEq(hub.checkpointCount(refA), 1);

        _warpToWeek(1);

        _report(
            refA,
            3_000 * 1e6,
            300 * 1e6
        );

        assertEq(hub.checkpointCount(refA), 2);

        (
            uint256 week0,
            uint256 referred0,
            uint256 self0
        ) = hub.checkpointAt(
            refA,
            0
        );

        assertEq(week0, BASE_WEEK);
        assertEq(referred0, 2_000 * 1e6);
        assertEq(self0, 200 * 1e6);

        (
            uint256 week1,
            uint256 referred1,
            uint256 self1
        ) = hub.checkpointAt(
            refA,
            1
        );

        assertEq(week1, BASE_WEEK + 1);
        assertEq(referred1, 3_000 * 1e6);
        assertEq(self1, 300 * 1e6);
    }

    // ---- score report intake ----

    function test_reportScores_selfOnlyChange_referredScoreUntouched()
        public
    {
        _report(
            refA,
            10_000 * 1e6,
            2_000 * 1e6
        );

        _report(
            refA,
            10_000 * 1e6,
            3_500 * 1e6
        );

        assertEq(hub.globalReferredScore(refA), 10_000 * 1e6);
        assertEq(hub.globalSelfScore(refA), 3_500 * 1e6);
    }

    function test_RevertWhen_reportScores_scoreOutOfRange()
        public
    {
        _report(
            refA,
            MAX_SOURCE_SCORE,
            0
        );

        assertEq(hub.globalReferredScore(refA), MAX_SOURCE_SCORE);

        vm.expectRevert(
            ReferralHubDeclarations.ScoreReportOutOfRange.selector
        );

        hub.reportScores(
            refA,
            MAX_SOURCE_SCORE + 1,
            0
        );
    }
}
