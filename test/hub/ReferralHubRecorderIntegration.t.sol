// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {WiseTelecomNodesDiamond} from "../../src/diamond/vault/WiseTelecomNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";

import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";

import {ReferralHub} from "../../src/hub/pending/ReferralHub.sol";

import {WiseTelecomNodesDiamondSelectors} from "../../script/diamond/WiseTelecomNodesDiamondSelectors.sol";

import {DiamondTestHarness} from "../diamond/utils/DiamondTestHarness.sol";

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
 * @dev Anti-hand-built-vector suite for the mainnet referral hub: the
 * PRODUCER is the real cohort recorder running inside a real diamond
 * (deposits, warps, `advanceBook`, transfers + `syncReferee`), never a
 * hand-crafted word; the CONSUMER is a real standalone {ReferralHub}
 * fed exclusively through its public reporter surface
 * (`reportScores` / `deliverCrumbs` / `deliverGap`), never a direct
 * storage write. Every expected value is computed independently in
 * the test — replaying the hub's
 * pricing formula (`floor(laneIncrement * laneBps / 10_000 / YEAR)`)
 * against lanes decoded from REAL crumb/gap words via
 * {CohortWeeks}, and against rates read from the hub's own
 * `weeklyRates` view — never against the hub's private pricing
 * internals. Scenario replay is deliberate: the full-week, dormant-gap
 * and mixed-advance-and-gap scenarios mirror
 * `test/diamond/WiseTelecomNodesCohortCrumbs.t.sol` exactly, so any
 * future drift between the recorder's frozen word format and the
 * hub's decode of it fails here first. The reporter role throughout
 * is `address(this)` (the test contract), mirroring the mainnet-vault
 * inline-reporting integration path documented in
 * `src/hub/pending/ReferralHub.sol`.
 */
contract ReferralHubRecorderIntegrationTest is DiamondTestHarness {

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

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    address internal user1 = address(0xA1);
    address internal refA = address(0xB1);
    address internal outsider = address(0xC1);
    address internal poker = address(0xD1);

    WiseTelecomNodesDiamond internal diamond;
    MockUSD internal usd;
    ReferralHub internal hub;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        usd = new MockUSD();

        diamond = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            diamond
        );

        _wireOne(
            diamond,
            address(new ReferralFacet()),
            WiseTelecomNodesDiamondSelectors.referralSelectors()
        );

        _wireOne(
            diamond,
            address(new CohortRecorderFacet()),
            WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors()
        );

        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(new CohortHookFacet())
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        _wireReferralRegistry(
            diamond
        );

        diamond.finalizeSetup();

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            true
        );

        hub = new ReferralHub(
            address(usd)
        );

        hub.setAllowedReporter(
            address(this),
            true
        );
    }

    // ---- helpers ----

    function _recorder()
        internal
        view
        returns (CohortRecorderFacet)
    {
        return CohortRecorderFacet(
            address(diamond)
        );
    }

    function _sourceKey()
        internal
        view
        returns (bytes32)
    {
        return bytes32(
            uint256(
                uint160(
                    address(this)
                )
            )
        );
    }

    function _depositWithReferralAs(
        address _user,
        uint256 _amount,
        address _referrer
    )
        internal
    {
        usd.mint(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        usd.approve(
            address(diamond),
            _amount
        );

        vm.prank(
            _user
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            _amount,
            _referrer
        );
    }

    function _depositAs(
        address _user,
        uint256 _amount
    )
        internal
    {
        usd.mint(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        usd.approve(
            address(diamond),
            _amount
        );

        vm.prank(
            _user
        );

        UserFacet(address(diamond)).deposit(
            _amount
        );
    }

    function _transferAs(
        address _from,
        address _to,
        uint256 _amount
    )
        internal
    {
        vm.prank(
            _from
        );

        diamond.transfer(
            _to,
            _amount
        );
    }

    function _cursorSum(
        address _referrer,
        uint256 _week
    )
        internal
        view
        returns (uint256)
    {
        (
            uint256 y1Cursor,
            uint256 y2Cursor,
            uint256 mCursor
        ) = hub.paidCursorAt(
            address(this),
            _referrer,
            _week
        );

        return y1Cursor + y2Cursor + mCursor;
    }

    function _expectedPay(
        uint256 _word,
        address _referrer,
        uint256 _week
    )
        internal
        view
        returns (uint256)
    {
        (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        ) = hub.weeklyRates(
            _referrer,
            _week
        );

        return CohortWeeks.laneY1(_word) * y1Bps / 10_000 / CohortWeeks.YEAR
            + CohortWeeks.laneY2(_word) * y2Bps / 10_000 / CohortWeeks.YEAR
            + CohortWeeks.laneM(_word) * mBps / 10_000 / CohortWeeks.YEAR;
    }

    function _deliverCrumbChunk(
        address _referrer,
        uint256 _fromWeekInclusive,
        uint256 _toWeekInclusive
    )
        internal
    {
        uint256 count = _toWeekInclusive - _fromWeekInclusive + 1;

        uint256[] memory weeksBatch = new uint256[](count);

        uint256[] memory wordsBatch = new uint256[](count);

        for (uint256 i; i < count; ++i) {

            weeksBatch[i] = _fromWeekInclusive + i;

            wordsBatch[i] = _recorder().getCohortWeekCrumb(
                _referrer,
                weeksBatch[i]
            );
        }

        hub.deliverCrumbs(
            _referrer,
            weeksBatch,
            wordsBatch
        );
    }

    function _runDepositCrumbsFlow(
        uint256 _principal
    )
        internal
        returns (
            uint256[] memory weeksOut,
            uint256[] memory wordsOut
        )
    {
        _depositWithReferralAs(
            user1,
            _principal,
            refA
        );

        hub.reportScores(
            refA,
            _principal,
            0
        );

        vm.warp(
            BASE_TIME + 4 weeks
        );

        _recorder().advanceBook(
            refA,
            104
        );

        weeksOut = new uint256[](4);
        wordsOut = new uint256[](4);

        for (uint256 i; i < 4; ++i) {

            weeksOut[i] = 3_000 + i;

            wordsOut[i] = _recorder().getCohortWeekCrumb(
                refA,
                weeksOut[i]
            );
        }
    }

    // ---- 1. deposit -> crumbs -> exact pricing ----

    function test_endToEnd_depositCrumbsPriceExactly()
        public
    {
        uint256 principal = 10_000 * 1e6;

        (
            uint256[] memory weeksBatch,
            uint256[] memory wordsBatch
        ) = _runDepositCrumbsFlow(
            principal
        );

        uint256 perWeekPaid = _expectedPay(
            wordsBatch[2],
            refA,
            weeksBatch[2]
        );

        bytes32 source = _sourceKey();

        vm.expectEmit(true, true, true, true, address(hub));
        emit CrumbPriced(source, refA, weeksBatch[0], address(this), CohortWeeks.laneY1(wordsBatch[0]), 0, 0, 0);

        vm.expectEmit(true, true, true, true, address(hub));
        emit CrumbPriced(source, refA, weeksBatch[1], address(this), CohortWeeks.laneY1(wordsBatch[1]), 0, 0, 0);

        vm.expectEmit(true, true, true, true, address(hub));
        emit CrumbPriced(source, refA, weeksBatch[2], address(this), CohortWeeks.laneY1(wordsBatch[2]), 0, 0, perWeekPaid);

        vm.expectEmit(true, true, true, true, address(hub));
        emit CrumbPriced(source, refA, weeksBatch[3], address(this), CohortWeeks.laneY1(wordsBatch[3]), 0, 0, perWeekPaid);

        hub.deliverCrumbs(
            refA,
            weeksBatch,
            wordsBatch
        );

        uint256 expected;

        for (uint256 i; i < weeksBatch.length; ++i) {
            expected += _expectedPay(
                wordsBatch[i],
                refA,
                weeksBatch[i]
            );
        }

        assertGt(
            expected,
            0
        );

        assertEq(
            hub.claimable(block.chainid, refA),
            expected
        );

        assertEq(
            hub.totalAccrued(),
            expected
        );
    }

    // ---- 2. dormant gap -> zero-rate pricing via cursors ----

    function test_endToEnd_gapRecordPricesViaCursors()
        public
    {
        uint256 principal = 10_000 * 1e6;

        _depositWithReferralAs(
            user1,
            principal,
            refA
        );

        vm.warp(
            BASE_TIME + 104 weeks + 1 hours
        );

        _recorder().advanceBook(
            refA,
            104
        );

        vm.warp(
            3_300 weeks + 2 hours
        );

        _depositWithReferralAs(
            user1,
            50 * 1e6,
            refA
        );

        assertEq(
            _recorder().getCohortGapLogLength(refA),
            1
        );

        uint256 gapRecord = _recorder().getCohortGapLogEntry(
            refA,
            0
        );

        uint256 claimableBefore = hub.claimable(block.chainid, refA);
        uint256 totalAccruedBefore = hub.totalAccrued();

        bytes32 source = _sourceKey();

        vm.expectEmit(true, true, false, true, address(hub));
        emit GapPriced(source, refA, address(this), 3_208, 3_258, 0);

        hub.deliverGap(
            refA,
            gapRecord,
            3_208,
            50
        );

        vm.expectEmit(true, true, false, true, address(hub));
        emit GapPriced(source, refA, address(this), 3_258, 3_300, 0);

        hub.deliverGap(
            refA,
            gapRecord,
            3_258,
            100
        );

        assertEq(
            hub.claimable(block.chainid, refA),
            claimableBefore
        );

        assertEq(
            hub.totalAccrued(),
            totalAccruedBefore
        );

        (, , uint256 mCursorStart) = hub.paidCursorAt(address(this), refA, 3_208);
        (, , uint256 mCursorMid) = hub.paidCursorAt(address(this), refA, 3_257);
        (, , uint256 mCursorLast) = hub.paidCursorAt(address(this), refA, 3_299);

        assertEq(mCursorStart, principal * 1 weeks);
        assertEq(mCursorMid, principal * 1 weeks);
        assertEq(mCursorLast, principal * 1 weeks);
    }

    // ---- 3. mixed advance + gap -> both encodings merge ----

    function test_endToEnd_mixedSpan_bothEncodingsMerge()
        public
    {
        uint256 principal = 10_000 * 1e6;

        _depositWithReferralAs(
            user1,
            principal,
            refA
        );

        hub.reportScores(
            refA,
            principal,
            0
        );

        vm.warp(
            BASE_TIME + 104 weeks + 1 hours
        );

        _recorder().advanceBook(
            refA,
            104
        );

        vm.warp(
            3_300 weeks + 2 hours
        );

        _recorder().advanceBook(
            refA,
            26
        );

        _depositWithReferralAs(
            user1,
            50 * 1e6,
            refA
        );

        assertEq(
            _recorder().getCohortGapLogLength(refA),
            1
        );

        uint256 gapRecord = _recorder().getCohortGapLogEntry(
            refA,
            0
        );

        _deliverCrumbChunk(refA, 3_000, 3_103);
        _deliverCrumbChunk(refA, 3_104, 3_207);
        _deliverCrumbChunk(refA, 3_208, 3_233);
        _deliverCrumbChunk(refA, 3_300, 3_300);

        hub.deliverGap(
            refA,
            gapRecord,
            3_234,
            66
        );

        uint256 claimableAfterFirst = hub.claimable(block.chainid, refA);
        uint256 totalAfterFirst = hub.totalAccrued();

        assertGt(
            claimableAfterFirst,
            0
        );

        assertGt(_cursorSum(refA, 3_129), 0);
        assertGt(_cursorSum(refA, 3_233), 0);
        assertGt(_cursorSum(refA, 3_234), 0);
        assertGt(_cursorSum(refA, 3_299), 0);
        assertGt(_cursorSum(refA, 3_300), 0);

        _deliverCrumbChunk(refA, 3_000, 3_103);
        _deliverCrumbChunk(refA, 3_104, 3_207);
        _deliverCrumbChunk(refA, 3_208, 3_233);
        _deliverCrumbChunk(refA, 3_300, 3_300);

        hub.deliverGap(
            refA,
            gapRecord,
            3_234,
            66
        );

        assertEq(
            hub.claimable(block.chainid, refA),
            claimableAfterFirst
        );

        assertEq(
            hub.totalAccrued(),
            totalAfterFirst
        );
    }

    // ---- 4. never-written weeks skip safely ----

    function test_absence_neverWrittenWeeksSkipSafely()
        public
    {
        uint256 principal = 10_000 * 1e6;

        _depositWithReferralAs(
            user1,
            principal,
            refA
        );

        hub.reportScores(
            refA,
            principal,
            0
        );

        vm.warp(
            BASE_TIME + 4 weeks
        );

        _recorder().advanceBook(
            refA,
            104
        );

        uint256[] memory weeksBatch = new uint256[](5);
        uint256[] memory wordsBatch = new uint256[](5);

        weeksBatch[0] = 3_000;
        weeksBatch[1] = 3_001;
        weeksBatch[2] = 3_004;
        weeksBatch[3] = 3_002;
        weeksBatch[4] = 3_003;

        for (uint256 i; i < 5; ++i) {
            wordsBatch[i] = _recorder().getCohortWeekCrumb(refA, weeksBatch[i]);
        }

        assertEq(
            wordsBatch[2],
            0
        );

        hub.deliverCrumbs(
            refA,
            weeksBatch,
            wordsBatch
        );

        assertEq(
            _cursorSum(refA, 3_004),
            0
        );

        uint256 expected;

        for (uint256 i; i < 5; ++i) {

            if (weeksBatch[i] == 3_004) {
                continue;
            }

            expected += _expectedPay(
                wordsBatch[i],
                refA,
                weeksBatch[i]
            );
        }

        assertGt(
            expected,
            0
        );

        assertEq(
            hub.claimable(block.chainid, refA),
            expected
        );
    }

    // ---- 5. recorder-side clamp flows through as an absolute re-report ----

    function test_scoreReporting_recorderClampFlowsThrough()
        public
    {
        uint256 principal = 8_000 * 1e6;

        _depositWithReferralAs(
            user1,
            principal,
            refA
        );

        uint256 firstScore = _recorder().getCohortScore(refA);

        hub.reportScores(
            refA,
            firstScore,
            0
        );

        vm.warp(
            BASE_TIME + 3 weeks
        );

        uint256 held = diamond.balanceOf(user1);

        _transferAs(
            user1,
            outsider,
            held / 4
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(user1);

        uint256 clampedScore = _recorder().getCohortScore(refA);

        assertLt(
            clampedScore,
            firstScore
        );

        hub.reportScores(
            refA,
            clampedScore,
            0
        );

        assertEq(
            hub.globalReferredScore(refA),
            clampedScore
        );

        (uint256 pastOpening, ) = hub.openingScoresAt(refA, 3_001);
        (uint256 currentWeekOpening, ) = hub.openingScoresAt(refA, 3_003);
        (uint256 futureOpening, ) = hub.openingScoresAt(refA, 3_004);

        assertEq(pastOpening, firstScore);
        assertEq(currentWeekOpening, firstScore);
        assertEq(futureOpening, clampedScore);
    }

    // ---- 6. self-stake tracked contribution feeds the referrer's own ladder ----

    function test_selfStake_trackedContributionFeedsLadder()
        public
    {
        uint256 referredAmount = 6_000 * 1e6;
        uint256 selfAmount = 12_000 * 1e6;

        _depositWithReferralAs(
            user1,
            referredAmount,
            refA
        );

        _depositAs(
            refA,
            selfAmount
        );

        hub.reportScores(
            refA,
            _recorder().getCohortScore(refA),
            _recorder().getTrackedContribution(refA)
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        (uint256 y1BpsDwellOne, , ) = hub.weeklyRates(refA, 3_001);
        (uint256 y1BpsDwellTwo, , ) = hub.weeklyRates(refA, 3_002);

        assertEq(y1BpsDwellOne, 0);
        assertEq(y1BpsDwellTwo, 100 + 200);
    }

    // ---- 7. producer guarantee: a written crumb word is never all-zero-lane ----

    /**
     * @dev {CohortRecorderBase._recordSegmentCohort} early-returns
     * without writing anything when `cohortBook[_referrer] == 0`, and
     * every call site passes a strictly positive `dt`
     * (`_to > _from`); so whenever the CRUMB_WRITTEN_BIT is set, at
     * least one of the three 80-bit lanes it was set alongside is
     * provably non-zero. A "written but all-lanes-zero" crumb word is
     * therefore unreachable from the real recorder — the hub's
     * `_word == 0` fast skip in `deliverCrumbs` is the only skip a
     * real caller can ever exercise.
     */
    function test_recorder_neverWritesEmptyCrumbWords()
        public
    {
        uint256 principal = 10_000 * 1e6;

        _depositWithReferralAs(
            user1,
            principal,
            refA
        );

        vm.warp(
            BASE_TIME + 10 weeks
        );

        _recorder().advanceBook(
            refA,
            104
        );

        for (uint256 week = 3_000; week < 3_010; ++week) {

            uint256 word = _recorder().getCohortWeekCrumb(refA, week);

            assertTrue(word & CohortWeeks.CRUMB_WRITTEN_BIT != 0);
            assertTrue(word != CohortWeeks.CRUMB_WRITTEN_BIT);
        }
    }

    // ---- 8. idempotent full replay ----

    function test_idempotentFullReplay()
        public
    {
        uint256 principal = 10_000 * 1e6;

        (
            uint256[] memory weeksBatch,
            uint256[] memory wordsBatch
        ) = _runDepositCrumbsFlow(
            principal
        );

        hub.deliverCrumbs(
            refA,
            weeksBatch,
            wordsBatch
        );

        uint256 claimableAfterFirst = hub.claimable(block.chainid, refA);
        uint256 totalAfterFirst = hub.totalAccrued();

        assertGt(
            claimableAfterFirst,
            0
        );

        hub.deliverCrumbs(
            refA,
            weeksBatch,
            wordsBatch
        );

        assertEq(
            hub.claimable(block.chainid, refA),
            claimableAfterFirst
        );

        assertEq(
            hub.totalAccrued(),
            totalAfterFirst
        );
    }
}
