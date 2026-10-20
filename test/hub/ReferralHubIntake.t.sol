// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IReferralHub} from "../../src/hub/pending/IReferralHub.sol";
import {HubLeverGrants} from "./utils/HubLeverGrants.sol";
import {HubDiamondHarness} from "../hub/utils/HubDiamondHarness.sol";
import {ReferralHubReader} from "../../src/hub/pending/ReferralHubReader.sol";
import {ReferralHubDeclarations} from "../../src/hub/pending/ReferralHubDeclarations.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";
import {CohortFlushCodec} from "../../src/diamond/shared/pending/CohortFlushCodec.sol";

/**
 * @dev Intake suite for the mainnet referral hub {ReferralHub} /
 * {ReferralHubIntake}, the crumb and gap pricing choke point. Covered:
 * exact-integer single-crumb pricing against the genesis tier
 * ladder of the week's own bucket; one full week paying exactly one
 * fifty-second of the stated rate (a rate is per 52-week year);
 * growing words paying only the
 * fresh increment; replay and fuzzed-lane redelivery idempotency;
 * reordered/duplicated delivery sequences converging on the
 * maximum-lane price regardless of order (I4, cursor idempotency and
 * exact pricing: replayed, reordered or partially-overlapping
 * deliveries accrue exactly once, at exactly the rate the week's
 * bucket implies); a regressive lane emitting `CrumbLaneRegression`
 * and pricing zero while the cursor holds at its high-water mark; the
 * absence (word == 0) versus written-but-empty (word ==
 * CRUMB_WRITTEN_BIT) versus real-word trichotomy; every
 * `deliverCrumbs`/`deliverGap`/`reportSelf` validation revert, an
 * open week refused; per-source cursor isolation across two
 * independently allowed reporters; exact and windowed-resume gap
 * pricing; at-cap weeks (uncapped ladder sum reaching `capBps`)
 * unlocking the genesis year-2/mature rates for both crumb and gap
 * pricing, the gate opened by a second source's mature gap and a self
 * run for exactly the gated weeks; the week buckets themselves (a
 * crumb reports its own weekly referred average, every source's self
 * average adds to the week's self input whatever its vault system, a lower
 * re-report never lowers a bucket, a later report that raises a
 * week's rates only emits `WeekRatesRaised` and the permissionless
 * `settleWeek` tops up every source already paid for it exactly once,
 * so the settled price never depends on arrival order, and a top-up
 * pays no courier fee, not even when a later courier delivery of the
 * same source collects it (that fee covers the delivered increment
 * only), a
 * source's system tag frozen once it delivered); and the I7 rational
 * pricing bound (`claimable * 10_000 * YEAR <= lanes * bps`) under
 * arbitrary split-delivery sequences. `address(this)` is both
 * deployer/master and, once self-allowed in `setUp`, the default
 * reporter; every crumb and gap call names the referrer itself as the
 * deliverer (an own-book delivery), so the courier fee never moves an
 * asserted amount and the priced events carry the referrer as
 * deliverer; `reporter1`/`reporter2` are used where source isolation
 * or a second source is under test, and `reporter3` where the vault
 * system tags of the sources are.
 */
contract ReferralHubIntakeTest is Test, HubDiamondHarness {

    event WeekReferredReported(
        bytes32 indexed source,
        address indexed referrer,
        uint256 indexed week,
        uint256 referredAverage
    );

    event WeekRatesRaised(
        address indexed referrer,
        uint256 indexed week
    );

    event WeekToppedUp(
        bytes32 indexed source,
        address indexed referrer,
        uint256 indexed week,
        uint256 amount
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

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant WEEK = CohortWeeks.WEEK;

    uint256 internal constant YEAR = CohortWeeks.YEAR;

    uint256 internal constant WRITTEN_BIT = CohortWeeks.CRUMB_WRITTEN_BIT;

    uint256 internal constant HIGH_SCORE = 100_000 * 1e6;

    uint256 internal constant TIER6_BPS = 600;

    uint256 internal constant AT_CAP_REFERRED = 1_000_000 * 1e6;

    uint256 internal constant AT_CAP_SELF = 10_000 * 1e6;

    uint256 internal constant OWN_STAKE = 10_000 * 1e6;

    uint256 internal constant CAP_BPS = 1_000;

    uint256 internal constant Y2_GENESIS_BPS = 500;

    uint256 internal constant M_GENESIS_BPS = 100;

    address internal refA = address(0xB1);

    address internal reporter1 = address(0xD1);

    address internal reporter2 = address(0xD2);

    address internal reporter3 = address(0xD3);

    address internal stranger = address(0xC1);

    address internal usdToken = address(0xF01);

    IReferralHub internal hub;

    ReferralHubReader internal reader;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        hub = _deployHub(
            usdToken
        );

        reader = new ReferralHubReader(
            address(hub)
        );

        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    address(this),
                    true
                )
            )
        );

        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    reporter1,
                    true
                )
            )
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
        return CohortWeeks._packLanes(
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
        uint256 _crumbWord
    )
        internal
    {
        uint256[] memory weeks_ = new uint256[](1);

        uint256[] memory words_ = new uint256[](1);

        weeks_[0] = _week;
        words_[0] = _crumbWord;

        vm.prank(
            _reporter
        );

        hub.deliverCrumbs(
            _referrer,
            _referrer,
            weeks_,
            words_
        );
    }

    function _setSelfAs(
        address _reporter,
        address _referrer,
        uint256 _fromWeek,
        uint256 _toWeekExclusive,
        uint256 _selfAverage
    )
        internal
    {
        uint256[] memory runs = new uint256[](1);

        runs[0] = CohortFlushCodec._packSelfRun(
            _fromWeek,
            _toWeekExclusive,
            _selfAverage
        );

        vm.prank(
            _reporter
        );

        hub.reportSelf(
            _referrer,
            runs
        );
    }

    function _reportAndWarpToTier(
        address _referrer,
        uint256 _selfScore
    )
        internal
        returns (uint256 week)
    {
        week = block.timestamp / WEEK;

        vm.warp(
            (week + 1) * WEEK + 1 hours
        );

        _setSelfAs(
            address(this),
            _referrer,
            week,
            week + 1,
            _selfScore
        );
    }

    function _gateAtCap(
        address _referrer,
        uint256 _fromWeek,
        uint256 _toWeekExclusive
    )
        internal
        returns (uint256 gatePaid)
    {
        uint256 accruedBefore = hub.totalAccrued();

        vm.prank(
            reporter2
        );

        hub.deliverGap(
            _referrer,
            _referrer,
            _gapRecord(
                _fromWeek,
                _toWeekExclusive,
                AT_CAP_REFERRED
            ),
            _fromWeek,
            _toWeekExclusive - _fromWeek
        );

        _setSelfAs(
            address(this),
            _referrer,
            _fromWeek,
            _toWeekExclusive,
            AT_CAP_SELF
        );

        gatePaid = hub.totalAccrued() - accruedBefore;
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
            refA,
            quantity,
            0,
            0,
            expectedPaid
        );

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(
                quantity,
                0,
                0
            )
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            expectedPaid
        );

        assertEq(
            hub.totalAccrued(),
            expectedPaid
        );
    }

    function test_deliverCrumbs_fullWeek_paysOneFiftySecondOfTheRate()
        public
    {
        uint256 week = _reportAndWarpToTier(
            refA,
            HIGH_SCORE
        );

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(
                1_000 * 1e6 * WEEK,
                0,
                0
            )
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            1_000 * 1e6 * TIER6_BPS / (10_000 * 52)
        );
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

        uint256 unit = 10_000 * YEAR;

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(
                q1,
                0,
                0
            )
        );

        uint256 firstNumerator = q1 * TIER6_BPS;

        uint256 expectedFirst = firstNumerator / unit;

        uint256 parked = firstNumerator % unit;

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            expectedFirst
        );

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(
                q2,
                0,
                0
            )
        );

        uint256 secondNumerator = (q2 - q1) * TIER6_BPS + parked;

        uint256 expectedSecond = secondNumerator / unit;

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            expectedFirst + expectedSecond
        );
    }

    function test_deliverCrumbs_interleavedLanes_paysTheCumulativeFloorOnce()
        public
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    reporter2,
                    true
                )
            )
        );

        uint256 week = block.timestamp / WEEK;

        vm.warp(
            block.timestamp + 4 weeks
        );

        uint256 gatePaid = _gateAtCap(
            refA,
            week,
            week + 1
        );

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(
                0,
                500_000_000,
                0
            )
        );

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(
                900_000_000,
                500_000_000,
                0
            )
        );

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(
                0,
                1_000_000_000,
                0
            )
        );

        uint256 expected = (
            900_000_000 * CAP_BPS
                + 1_000_000_000 * Y2_GENESIS_BPS
        ) / (10_000 * YEAR);

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            expected + gatePaid
        );
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
            _word(
                quantity,
                0,
                0
            )
        );

        uint256 claimableAfterFirst = hub.claimable(
            block.chainid,
            refA
        );

        (uint256 y1CursorBefore, , ) = reader.paidCursorAt(
            address(this),
            refA,
            week
        );

        vm.recordLogs();

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(
                quantity,
                0,
                0
            )
        );

        assertEq(
            vm.getRecordedLogs().length,
            0
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            claimableAfterFirst
        );

        (uint256 y1CursorAfter, , ) = reader.paidCursorAt(
            address(this),
            refA,
            week
        );

        assertEq(
            y1CursorAfter,
            y1CursorBefore
        );
    }

    function testFuzz_redelivery_paysZero(
        uint256 _y1,
        uint256 _y2,
        uint256 _m
    )
        public
    {
        _y1 = bound(
            _y1,
            0,
            CohortWeeks.LANE_MASK_80
        );

        _y2 = bound(
            _y2,
            0,
            CohortWeeks.LANE_MASK_80
        );

        _m = bound(
            _m,
            0,
            CohortWeeks.LANE_MASK_80
        );

        uint256 week = block.timestamp / WEEK - 1;

        uint256 word = _word(
            _y1,
            _y2,
            _m
        );

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            word
        );

        uint256 claimableAfterFirst = hub.claimable(
            block.chainid,
            refA
        );

        (
            uint256 y1Before,
            uint256 y2Before,
            uint256 mBefore
        ) = reader.paidCursorAt(
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

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            claimableAfterFirst
        );

        (
            uint256 y1After,
            uint256 y2After,
            uint256 mAfter
        ) = reader.paidCursorAt(
            address(this),
            refA,
            week
        );

        assertEq(
            y1After,
            y1Before
        );

        assertEq(
            y2After,
            y2Before
        );

        assertEq(
            mAfter,
            mBefore
        );
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
        _d1 = bound(
            _d1,
            1e6,
            1e12
        );

        _d2 = bound(
            _d2,
            1e6,
            1e12
        );

        _d3 = bound(
            _d3,
            1e6,
            1e12
        );

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

        uint256 unit = 10_000 * YEAR;

        uint256 parked;

        for (uint256 pass; pass < 2; ++pass) {

            for (uint256 i; i < 3; ++i) {

                uint256 value = values[order[i]];

                _deliverCrumbAs(
                    address(this),
                    refA,
                    week,
                    _word(
                        value,
                        0,
                        0
                    )
                );

                if (value > cursor) {

                    uint256 numerator = (value - cursor) * TIER6_BPS + parked;

                    expected += numerator / unit;

                    parked = numerator % unit;

                    cursor = value;
                }
            }
        }

        assertEq(
            cursor,
            q3
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            expected
        );
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
            _word(
                q2,
                0,
                0
            )
        );

        uint256 claimableAfterFirst = hub.claimable(
            block.chainid,
            refA
        );

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
            _word(
                q1,
                0,
                0
            )
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            claimableAfterFirst
        );

        (uint256 y1Cursor, , ) = reader.paidCursorAt(
            address(this),
            refA,
            week
        );

        assertEq(
            y1Cursor,
            q2
        );
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

        assertEq(
            vm.getRecordedLogs().length,
            0
        );

        (uint256 y1AfterAbsence, , ) = reader.paidCursorAt(
            address(this),
            refA,
            week
        );

        assertEq(
            y1AfterAbsence,
            0
        );

        vm.recordLogs();

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            WRITTEN_BIT
        );

        assertEq(
            vm.getRecordedLogs().length,
            0
        );

        (uint256 y1AfterEmpty, , ) = reader.paidCursorAt(
            address(this),
            refA,
            week
        );

        assertEq(
            y1AfterEmpty,
            0
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            0
        );
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

        words_[0] = _word(
            1,
            0,
            0
        );

        vm.expectRevert(
            ReferralHubDeclarations.WeekNotClosed.selector
        );

        hub.deliverCrumbs(
            refA,
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

        words_[0] = _word(
            1,
            0,
            0
        );

        vm.expectRevert(
            ReferralHubDeclarations.LengthMismatch.selector
        );

        hub.deliverCrumbs(
            refA,
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

            words_[i] = _word(
                1,
                0,
                0
            );
        }

        vm.expectRevert(
            ReferralHubDeclarations.BatchTooLarge.selector
        );

        hub.deliverCrumbs(
            refA,
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

        words_[0] = _word(
            1,
            0,
            0
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            ReferralHubDeclarations.NotReporter.selector
        );

        hub.reportSelf(
            refA,
            new uint256[](0)
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            ReferralHubDeclarations.NotReporter.selector
        );

        hub.deliverCrumbs(
            refA,
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
            refA,
            _gapRecord(
                0,
                1,
                0
            ),
            0,
            1
        );
    }

    // ---- two-reporter source isolation ----

    function test_twoReporters_sameReferrerSameWeek_isolatedCursorsAndClaimableSum()
        public
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    reporter2,
                    true
                )
            )
        );

        uint256 week = _reportAndWarpToTier(
            refA,
            HIGH_SCORE
        );

        uint256 q1 = 300 * 1e6 * WEEK;

        uint256 q2 = 700 * 1e6 * WEEK;

        _deliverCrumbAs(
            reporter1,
            refA,
            week,
            _word(
                q1,
                0,
                0
            )
        );

        _deliverCrumbAs(
            reporter2,
            refA,
            week,
            _word(
                q2,
                0,
                0
            )
        );

        uint256 expected1 = q1 * TIER6_BPS / 10_000 / YEAR;

        uint256 expected2 = q2 * TIER6_BPS / 10_000 / YEAR;

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            expected1 + expected2
        );

        (
            uint256 y1Reporter1,
            ,
        ) = reader.paidCursorAt(
            reporter1,
            refA,
            week
        );

        (
            uint256 y1Reporter2,
            ,
        ) = reader.paidCursorAt(
            reporter2,
            refA,
            week
        );

        assertEq(
            y1Reporter1,
            q1
        );

        assertEq(
            y1Reporter2,
            q2
        );

        (
            uint256 referred1,
            uint256 paid1
        ) = hub.weekReportOf(
            _sourceKeyOf(
                reporter1
            ),
            refA,
            week
        );

        (
            uint256 referred2,
            uint256 paid2
        ) = hub.weekReportOf(
            _sourceKeyOf(
                reporter2
            ),
            refA,
            week
        );

        assertEq(
            referred1,
            300 * 1e6
        );

        assertEq(
            referred2,
            700 * 1e6
        );

        assertEq(
            paid1,
            expected1
        );

        assertEq(
            paid2,
            expected2
        );

        (
            uint256 referredInput,
            uint256 selfInput
        ) = hub.ladderInputsAt(
            refA,
            week
        );

        assertEq(
            referredInput,
            1_000 * 1e6
        );

        assertEq(
            selfInput,
            HIGH_SCORE
        );
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
            refA,
            fromWeek,
            toWeekExclusive,
            0
        );

        hub.deliverGap(
            refA,
            refA,
            record,
            fromWeek,
            66
        );

        uint256 expectedMCursor = mature * WEEK;

        (
            ,
            ,
            uint256 mCursorFirst
        ) = reader.paidCursorAt(
            address(this),
            refA,
            fromWeek
        );

        (
            ,
            ,
            uint256 mCursorMid
        ) = reader.paidCursorAt(
            address(this),
            refA,
            fromWeek + 33
        );

        (
            ,
            ,
            uint256 mCursorLast
        ) = reader.paidCursorAt(
            address(this),
            refA,
            toWeekExclusive - 1
        );

        assertEq(
            mCursorFirst,
            expectedMCursor
        );

        assertEq(
            mCursorMid,
            expectedMCursor
        );

        assertEq(
            mCursorLast,
            expectedMCursor
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            0
        );
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
            refA,
            record,
            fromWeek,
            104
        );

        hub.deliverGap(
            refA,
            refA,
            record,
            fromWeek + 104,
            104
        );

        uint256 expectedMCursor = mature * WEEK;

        (
            ,
            ,
            uint256 cursorStart
        ) = reader.paidCursorAt(
            address(this),
            refA,
            fromWeek
        );

        (
            ,
            ,
            uint256 cursorEndOfFirstChunk
        ) = reader.paidCursorAt(
            address(this),
            refA,
            fromWeek + 103
        );

        (
            ,
            ,
            uint256 cursorStartOfSecondChunk
        ) = reader.paidCursorAt(
            address(this),
            refA,
            fromWeek + 104
        );

        (
            ,
            ,
            uint256 cursorLast
        ) = reader.paidCursorAt(
            address(this),
            refA,
            toWeekExclusive - 1
        );

        assertEq(
            cursorStart,
            expectedMCursor
        );

        assertEq(
            cursorEndOfFirstChunk,
            expectedMCursor
        );

        assertEq(
            cursorStartOfSecondChunk,
            expectedMCursor
        );

        assertEq(
            cursorLast,
            expectedMCursor
        );

        vm.recordLogs();

        hub.deliverGap(
            refA,
            refA,
            record,
            fromWeek,
            104
        );

        assertEq(
            vm.getRecordedLogs().length,
            0
        );
    }

    // ---- at-cap tail rates ----

    function test_deliverCrumbs_atCapReferrer_paysY2AndMAtGenesisRates()
        public
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    reporter2,
                    true
                )
            )
        );

        uint256 week = block.timestamp / WEEK;

        vm.warp(
            block.timestamp + 4 weeks
        );

        uint256 gatePaid = _gateAtCap(
            refA,
            week,
            week + 1
        );

        uint256 qY1 = 1_000 * 1e6 * WEEK;

        uint256 qY2 = 400 * 1e6 * WEEK;

        uint256 qM = 200 * 1e6 * WEEK;

        uint256 expectedPaid = (
            qY1 * CAP_BPS
                + qY2 * Y2_GENESIS_BPS
                + qM * M_GENESIS_BPS
        ) / (10_000 * YEAR);

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
            refA,
            qY1,
            qY2,
            qM,
            expectedPaid
        );

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(
                qY1,
                qY2,
                qM
            )
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            expectedPaid + gatePaid
        );

        assertEq(
            hub.totalAccrued(),
            expectedPaid + gatePaid
        );
    }

    function test_deliverGap_atCapReferrer_paysMatureAtGenesisRate()
        public
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    reporter2,
                    true
                )
            )
        );

        uint256 fromWeek = block.timestamp / WEEK;

        uint256 toWeekExclusive = fromWeek + 6;

        vm.warp(
            block.timestamp + 16 weeks
        );

        uint256 gatePaid = _gateAtCap(
            refA,
            fromWeek,
            toWeekExclusive
        );

        uint256 mature = 5_000 * 1e6;

        uint256 record = _gapRecord(
            fromWeek,
            toWeekExclusive,
            mature
        );

        uint256 perWeekPaid = mature * WEEK * M_GENESIS_BPS / 10_000 / YEAR;

        uint256 expectedPaid = perWeekPaid * 6;

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
            refA,
            fromWeek,
            toWeekExclusive,
            expectedPaid
        );

        hub.deliverGap(
            refA,
            refA,
            record,
            fromWeek,
            6
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            expectedPaid + gatePaid
        );

        assertEq(
            hub.totalAccrued(),
            expectedPaid + gatePaid
        );
    }

    function test_deliverGap_straddlesGateOpening_pricesPerWeekRates()
        public
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    reporter2,
                    true
                )
            )
        );

        uint256 fromWeek = block.timestamp / WEEK;

        uint256 gateOpenWeek = fromWeek + 2;

        uint256 toWeekExclusive = fromWeek + 4;

        vm.warp(
            block.timestamp + 14 weeks
        );

        uint256 gatePaid = _gateAtCap(
            refA,
            gateOpenWeek,
            toWeekExclusive
        );

        uint256 mature = 5_000 * 1e6;

        uint256 record = _gapRecord(
            fromWeek,
            toWeekExclusive,
            mature
        );

        uint256 perWeekPaid = mature * WEEK * M_GENESIS_BPS / 10_000 / YEAR;

        uint256 expectedPaid = perWeekPaid * 2;

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
            refA,
            fromWeek,
            toWeekExclusive,
            expectedPaid
        );

        hub.deliverGap(
            refA,
            refA,
            record,
            fromWeek,
            4
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            expectedPaid + gatePaid
        );

        assertEq(
            hub.totalAccrued(),
            expectedPaid + gatePaid
        );
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
            refA,
            _gapRecord(
                week,
                week,
                0
            ),
            week,
            1
        );

        uint256 recordWithHighBit = _gapRecord(week, week + 1, 0) | (1 << 144);

        vm.expectRevert(
            ReferralHubDeclarations.InvalidGapRecord.selector
        );

        hub.deliverGap(
            refA,
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
            refA,
            _gapRecord(
                week,
                week + 1,
                tooLargeMature
            ),
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
            refA,
            record,
            toWeekExclusive,
            1
        );
    }

    // ---- stale checkpoint pricing ----

    function test_deliverCrumbs_staleCheckpoint_pricesZeroAndAdvancesCursor()
        public
    {
        uint256 freshWeek = _reportAndWarpToTier(
            refA,
            HIGH_SCORE
        );

        uint256 quantity = 1_000 * 1e6 * WEEK;

        _deliverCrumbAs(
            address(this),
            refA,
            freshWeek,
            _word(
                quantity,
                0,
                0
            )
        );

        uint256 paidFresh = hub.claimable(
            block.chainid,
            refA
        );

        assertEq(
            paidFresh,
            quantity * TIER6_BPS / 10_000 / YEAR
        );

        vm.warp(
            block.timestamp + 2 weeks
        );

        uint256 staleWeek = freshWeek + 2;

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
            staleWeek,
            refA,
            quantity,
            0,
            0,
            0
        );

        _deliverCrumbAs(
            address(this),
            refA,
            staleWeek,
            _word(
                quantity,
                0,
                0
            )
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            paidFresh
        );

        assertEq(
            hub.totalAccrued(),
            paidFresh
        );

        (
            uint256 y1Cursor,
            ,
        ) = reader.paidCursorAt(
            address(this),
            refA,
            staleWeek
        );

        assertEq(
            y1Cursor,
            quantity
        );

        (
            uint256 y1Bps,
            ,
        ) = hub.weeklyRates(
            refA,
            staleWeek
        );

        assertEq(
            y1Bps,
            0
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
        _d1 = bound(
            _d1,
            0,
            1e14
        );

        _d2 = bound(
            _d2,
            0,
            1e14
        );

        _d3 = bound(
            _d3,
            0,
            1e14
        );

        uint256 week = _reportAndWarpToTier(
            refA,
            HIGH_SCORE
        );

        uint256 total = _d1
            + _d2
            + _d3;

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(
                _d1,
                0,
                0
            )
        );

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(
                _d1 + _d2,
                0,
                0
            )
        );

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(
                total,
                0,
                0
            )
        );

        assertLe(
            hub.claimable(block.chainid, refA) * 10_000 * YEAR,
            total * TIER6_BPS
        );
    }

    // ---- week buckets: week W is priced only from W's own reports ----

    function _localSourceOf(
        address _reporter
    )
        internal
        view
        returns (bytes32)
    {
        return hub.sourceKeyOf(
            block.chainid,
            _reporter
        );
    }

    function _allowThreeReportersAcrossTwoSystems()
        internal
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    reporter2,
                    true
                )
            )
        );

        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    reporter3,
                    true
                )
            )
        );

        hub.setSourceSystem(
            _localSourceOf(
                reporter2
            ),
            1
        );

        hub.setSourceSystem(
            _localSourceOf(
                reporter3
            ),
            1
        );
    }

    function test_deliverCrumb_reportsItsOwnWeeklyReferredAverage()
        public
    {
        uint256 week = block.timestamp / WEEK;

        vm.warp(
            (week + 1) * WEEK + 1 hours
        );

        uint256 quantity = 12_000 * 1e6 * WEEK;

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(hub)
        );

        emit WeekReferredReported(
            _sourceKeyOf(
                address(this)
            ),
            refA,
            week,
            12_000 * 1e6
        );

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(
                quantity,
                0,
                0
            )
        );

        (
            uint256 referredInput,
            uint256 selfInput
        ) = hub.ladderInputsAt(
            refA,
            week
        );

        assertEq(
            referredInput,
            12_000 * 1e6
        );

        assertEq(
            selfInput,
            0
        );

        (
            uint256 referredAverage,
            uint256 paidUnits
        ) = hub.weekReportOf(
            _sourceKeyOf(
                address(this)
            ),
            refA,
            week
        );

        assertEq(
            referredAverage,
            12_000 * 1e6
        );

        assertEq(
            paidUnits,
            quantity * 200 / (10_000 * YEAR)
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            paidUnits
        );
    }

    function test_reportSelf_sumsEverySourcesWeeklyAverage()
        public
    {
        _allowThreeReportersAcrossTwoSystems();

        uint256 week = block.timestamp / WEEK;

        vm.warp(
            (week + 1) * WEEK + 1 hours
        );

        _setSelfAs(
            address(this),
            refA,
            week,
            week + 1,
            30_000 * 1e6
        );

        _setSelfAs(
            reporter1,
            refA,
            week,
            week + 1,
            50_000 * 1e6
        );

        _setSelfAs(
            reporter2,
            refA,
            week,
            week + 1,
            20_000 * 1e6
        );

        _setSelfAs(
            reporter3,
            refA,
            week,
            week + 1,
            10_000 * 1e6
        );

        (
            ,
            uint256 selfInput
        ) = hub.ladderInputsAt(
            refA,
            week
        );

        assertEq(
            selfInput,
            110_000 * 1e6
        );

        assertEq(
            hub.weekSelfOf(
                _localSourceOf(
                    reporter1
                ),
                refA,
                week
            ),
            50_000 * 1e6
        );

        assertEq(
            hub.weekSelfOf(
                _localSourceOf(
                    reporter3
                ),
                refA,
                week
            ),
            10_000 * 1e6
        );
    }

    function test_weekBucket_settleWeekTopsUpTheEarlierSourceOnce()
        public
    {
        uint256 week = block.timestamp / WEEK;

        vm.warp(
            (week + 1) * WEEK + 1 hours
        );

        uint256 quantity = 1_000 * 1e6 * WEEK;

        uint256 expected = quantity * TIER6_BPS / (10_000 * YEAR);

        uint256 snapshot = vm.snapshotState();

        _deliverCrumbAs(
            reporter1,
            refA,
            week,
            _word(
                quantity,
                0,
                0
            )
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            0
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(hub)
        );

        emit WeekRatesRaised(
            refA,
            week
        );

        _setSelfAs(
            address(this),
            refA,
            week,
            week + 1,
            HIGH_SCORE
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            0
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(hub)
        );

        emit WeekToppedUp(
            _sourceKeyOf(
                reporter1
            ),
            refA,
            week,
            expected
        );

        vm.prank(
            stranger
        );

        hub.settleWeeks(
            refA,
            week,
            1
        );

        hub.settleWeeks(
            refA,
            week,
            1
        );

        uint256 crumbFirst = hub.claimable(
            block.chainid,
            refA
        );

        vm.revertToState(
            snapshot
        );

        _setSelfAs(
            address(this),
            refA,
            week,
            week + 1,
            HIGH_SCORE
        );

        _deliverCrumbAs(
            reporter1,
            refA,
            week,
            _word(
                quantity,
                0,
                0
            )
        );

        uint256 reportFirst = hub.claimable(
            block.chainid,
            refA
        );

        assertEq(
            crumbFirst,
            expected
        );

        assertEq(
            reportFirst,
            expected
        );

        assertEq(
            hub.totalAccrued(),
            expected
        );
    }

    function test_weekBucket_lowerReReportNeverLowersTheBucket()
        public
    {
        uint256 week = block.timestamp / WEEK;

        vm.warp(
            (week + 1) * WEEK + 1 hours
        );

        _setSelfAs(
            address(this),
            refA,
            week,
            week + 1,
            HIGH_SCORE
        );

        _setSelfAs(
            address(this),
            refA,
            week,
            week + 1,
            1_000 * 1e6
        );

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(
                9_000 * 1e6 * WEEK,
                0,
                0
            )
        );

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(
                2_000 * 1e6 * WEEK,
                0,
                0
            )
        );

        (
            uint256 referredInput,
            uint256 selfInput
        ) = hub.ladderInputsAt(
            refA,
            week
        );

        assertEq(
            referredInput,
            9_000 * 1e6
        );

        assertEq(
            selfInput,
            HIGH_SCORE
        );
    }

    function test_RevertWhen_deliverCrumbs_openWeek()
        public
    {
        uint256[] memory weeks_ = new uint256[](1);

        uint256[] memory words_ = new uint256[](1);

        weeks_[0] = block.timestamp / WEEK;

        words_[0] = _word(
            1,
            0,
            0
        );

        vm.expectRevert(
            ReferralHubDeclarations.WeekNotClosed.selector
        );

        hub.deliverCrumbs(
            refA,
            refA,
            weeks_,
            words_
        );
    }

    function test_RevertWhen_reportSelf_invalidRun()
        public
    {
        uint256 week = block.timestamp / WEEK;

        uint256[5] memory runs = [
            CohortFlushCodec._packSelfRun(week - 1, week - 1, 1),
            CohortFlushCodec._packSelfRun(
                week - 1,
                week + 1,
                1
            ),
            CohortFlushCodec._packSelfRun(
                week - 105,
                week,
                1
            ),
            CohortFlushCodec._packSelfRun(week - 1, week, 1) | (1 << CohortFlushCodec.SELF_RUN_RESERVED_SHIFT),
            CohortFlushCodec._packSelfRun(
                week - 1,
                week,
                CohortWeeks.LANE_MASK_80 / WEEK + 1
            )
        ];

        for (uint256 i; i < 5; ++i) {

            uint256[] memory batch = new uint256[](1);

            batch[0] = runs[i];

            vm.expectRevert(
                ReferralHubDeclarations.InvalidSelfRun.selector
            );

            hub.reportSelf(
                refA,
                batch
            );
        }
    }

    function test_RevertWhen_setSourceSystem_afterTheSourceDelivered()
        public
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    reporter2,
                    true
                )
            )
        );

        bytes32 source = _localSourceOf(
            reporter2
        );

        hub.setSourceSystem(
            source,
            1
        );

        uint256 week = block.timestamp / WEEK;

        vm.warp(
            (week + 1) * WEEK + 1 hours
        );

        _setSelfAs(
            reporter2,
            refA,
            week,
            week + 1,
            1_000 * 1e6
        );

        assertEq(
            hub.sourceChainIdOf(
                source
            ),
            block.chainid
        );

        vm.expectRevert(
            ReferralHubDeclarations.SourceAlreadySet.selector
        );

        hub.setSourceSystem(
            source,
            2
        );

        hub.setSourceSystem(
            source,
            1
        );
    }

    function test_topUp_paysNoCourierFee()
        public
    {
        uint256 week = block.timestamp / WEEK;

        vm.warp(
            (week + 1) * WEEK + 1 hours
        );

        uint256[] memory weeks_ = new uint256[](1);

        uint256[] memory words_ = new uint256[](1);

        weeks_[0] = week;

        words_[0] = _word(
            1_000 * 1e6 * WEEK,
            0,
            0
        );

        hub.deliverCrumbs(
            refA,
            stranger,
            weeks_,
            words_
        );

        _setSelfAs(
            address(this),
            refA,
            week,
            week + 1,
            HIGH_SCORE
        );

        hub.settleWeeks(
            refA,
            week,
            1
        );

        assertEq(
            hub.claimable(
                block.chainid,
                stranger
            ),
            0
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            1_000 * 1e6 * WEEK * TIER6_BPS / (10_000 * YEAR)
        );
    }

    function test_reportSelf_averageAtTheLaneBound_isAccepted()
        public
    {
        uint256 week = block.timestamp / WEEK;

        vm.warp(
            (week + 1) * WEEK + 1 hours
        );

        _setSelfAs(
            address(this),
            refA,
            week,
            week + 1,
            CohortWeeks.LANE_MASK_80 / WEEK
        );

        assertEq(
            hub.weekSelfOf(
                _sourceKeyOf(
                    address(this)
                ),
                refA,
                week
            ),
            CohortWeeks.LANE_MASK_80 / WEEK
        );
    }

    function test_deliverCrumbs_raiseWithoutLaneIncrement_topsUpOwnCell()
        public
    {
        uint256 week = block.timestamp / WEEK;

        vm.warp(
            (week + 1) * WEEK + 1 hours
        );

        uint256 lane = 5_000 * 1e6 * WEEK;

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(
                lane,
                0,
                0
            )
        );

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(
                0,
                0,
                lane
            )
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            lane * 100 / (10_000 * YEAR)
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(hub)
        );

        emit WeekToppedUp(
            _sourceKeyOf(
                address(this)
            ),
            refA,
            week,
            lane * 200 / (10_000 * YEAR) - lane * 100 / (10_000 * YEAR)
        );

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(
                lane,
                0,
                lane
            )
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            lane * 200 / (10_000 * YEAR)
        );
    }

    function test_courierDelivery_collectingAPendingTopUp_feeOnlyOnItsIncrement()
        public
    {
        uint256 week = block.timestamp / WEEK;

        vm.warp(
            (week + 1) * WEEK + 1 hours
        );

        uint256 first = 6_000 * 1e6 * WEEK;

        uint256 grown = 8_000 * 1e6 * WEEK;

        uint256[] memory weeks_ = new uint256[](1);

        uint256[] memory words_ = new uint256[](1);

        weeks_[0] = week;

        words_[0] = _word(
            first,
            0,
            0
        );

        hub.deliverCrumbs(
            refA,
            refA,
            weeks_,
            words_
        );

        _setSelfAs(
            reporter1,
            refA,
            week,
            week + 1,
            HIGH_SCORE
        );

        (
            uint256 y1Bps,
            ,
        ) = hub.weeklyRates(
            refA,
            week
        );

        assertEq(
            y1Bps,
            700
        );

        words_[0] = _word(
            grown,
            0,
            0
        );

        hub.deliverCrumbs(
            refA,
            stranger,
            weeks_,
            words_
        );

        uint256 increment = grown * 700 / (10_000 * YEAR)
            - first * 700 / (10_000 * YEAR);

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            grown * 700 / (10_000 * YEAR)
        );

        assertEq(
            hub.claimable(
                block.chainid,
                stranger
            ),
            increment * 500 / 10_000
        );
    }

    function test_reportSelf_raisingRates_topsUpOwnSourceInline_otherSourceWaitsForSettle()
        public
    {
        uint256 week = block.timestamp / WEEK;

        vm.warp(
            (week + 1) * WEEK + 1 hours
        );

        uint256 quantity = 6_000 * 1e6 * WEEK;

        _deliverCrumbAs(
            reporter1,
            refA,
            week,
            _word(
                quantity,
                0,
                0
            )
        );

        _deliverCrumbAs(
            address(this),
            refA,
            week,
            _word(
                quantity,
                0,
                0
            )
        );

        _setSelfAs(
            reporter1,
            refA,
            week,
            week + 1,
            HIGH_SCORE
        );

        (
            ,
            uint256 ownPaid
        ) = hub.weekReportOf(
            _localSourceOf(
                reporter1
            ),
            refA,
            week
        );

        (
            ,
            uint256 otherPaid
        ) = hub.weekReportOf(
            _localSourceOf(
                address(this)
            ),
            refA,
            week
        );

        uint256 raised = quantity * 800 / (10_000 * YEAR);

        assertEq(
            ownPaid,
            raised
        );

        assertEq(
            otherPaid,
            quantity * 200 / (10_000 * YEAR)
        );

        hub.settleWeeks(
            refA,
            week,
            1
        );

        (
            ,
            otherPaid
        ) = hub.weekReportOf(
            _localSourceOf(
                address(this)
            ),
            refA,
            week
        );

        assertEq(
            otherPaid,
            raised
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            2 * raised
        );
    }

    function test_RevertWhen_settleWeeks_batchTooLarge()
        public
    {
        vm.expectRevert(
            ReferralHubDeclarations.BatchTooLarge.selector
        );

        hub.settleWeeks(
            refA,
            3_000,
            105
        );
    }

    function test_RevertWhen_reportSelf_batchTooLarge()
        public
    {
        uint256 count = CohortWeeks.MAX_SETTLE_BOUNDARIES + 1;

        uint256[] memory runs = new uint256[](count);

        uint256 week = block.timestamp / WEEK - 1;

        for (uint256 i; i < count; ++i) {
            runs[i] = CohortFlushCodec._packSelfRun(
                week,
                week + 1,
                1
            );
        }

        vm.expectRevert(
            ReferralHubDeclarations.BatchTooLarge.selector
        );

        hub.reportSelf(
            refA,
            runs
        );
    }

    function test_settleWeeks_unlistedReferrer_isNoop()
        public
    {
        vm.recordLogs();

        hub.settleWeeks(
            stranger,
            3_000,
            104
        );

        assertEq(
            vm.getRecordedLogs().length,
            0
        );

        assertEq(
            hub.totalAccrued(),
            0
        );
    }

    function test_RevertWhen_setSourceSystem_afterCrumbDelivery()
        public
    {
        uint256 week = block.timestamp / WEEK;

        vm.warp(
            (week + 1) * WEEK + 1 hours
        );

        _deliverCrumbAs(
            reporter1,
            refA,
            week,
            _word(
                1_000 * 1e6 * WEEK,
                0,
                0
            )
        );

        bytes32 source = _localSourceOf(
            reporter1
        );

        vm.expectRevert(
            ReferralHubDeclarations.SourceAlreadySet.selector
        );

        hub.setSourceSystem(
            source,
            3
        );
    }

    function testFuzz_weekBucket_arrivalOrderNeverChangesThePrice(
        uint256 _seed,
        uint256 _q1,
        uint256 _q2,
        uint256 _self
    )
        public
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    reporter2,
                    true
                )
            )
        );

        uint256 q1 = bound(_q1, 1, 40_000 * 1e6) * WEEK;

        uint256 q2 = bound(_q2, 1, 40_000 * 1e6) * WEEK;

        uint256 selfAverage = bound(
            _self,
            0,
            1_100_000 * 1e6
        );

        uint256 week = block.timestamp / WEEK;

        vm.warp(
            (week + 1) * WEEK + 1 hours
        );

        uint8[3] memory order = _permutationOf(
            _seed
        );

        for (uint256 i; i < 3; ++i) {

            if (order[i] == 0) {
                _deliverCrumbAs(
                    reporter1,
                    refA,
                    week,
                    _word(
                        q1,
                        0,
                        0
                    )
                );
            } else if (order[i] == 1) {
                _deliverCrumbAs(
                    reporter2,
                    refA,
                    week,
                    _word(
                        q2,
                        0,
                        0
                    )
                );
            } else if (selfAverage > 0) {
                _setSelfAs(
                    address(this),
                    refA,
                    week,
                    week + 1,
                    selfAverage
                );
            }
        }

        hub.settleWeeks(
            refA,
            week,
            1
        );

        (
            uint256 y1Bps,
            ,
        ) = hub.weeklyRates(
            refA,
            week
        );

        uint256 expected = q1 * y1Bps / (10_000 * YEAR)
            + q2 * y1Bps / (10_000 * YEAR);

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            expected
        );

        assertEq(
            hub.totalAccrued(),
            expected
        );
    }
}
