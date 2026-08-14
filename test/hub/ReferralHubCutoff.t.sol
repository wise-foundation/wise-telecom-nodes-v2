// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ReferralHub} from "../../src/hub/pending/ReferralHub.sol";

/**
 * @dev Port of the proven `test/fenwick/ReferralCutoffOracle.t.sol`
 * sandbox suite onto the real {ReferralHub} checkpoint/cutoff layer
 * ({ReferralHubCheckpoints}). The load-bearing property carried over
 * unchanged is the equivalence between the stored verdict and the
 * live predicate: for EVERY referrer, `bucket != 0 && bucket >=
 * qualifyingBucket()` must equal `isTopTenPercent(referrer)`, across
 * single-referrer, all-tied, straddling-bucket and top-bucket-
 * saturated distributions plus a randomized fuzz over 12 referrers
 * including inactive scores (`_assertDecileProperty`, reused verbatim
 * from the sandbox — it only reads live Ranking-layer state, which the
 * hub never changed).
 *
 * Two production hardenings the sandbox deliberately lacked drive
 * every adaptation in this file. First, an EMPTY tree now snapshots
 * `NOBODY_QUALIFIES` (2049) rather than the sandbox's bucket 1 — with
 * zero active referrers the target is zero, so "nobody" is the
 * truthful verdict. This shifts every assertion in
 * `test_cutoffAt_quietWeeksCarryForward` that resolves to the week
 * whose FIRST-EVER mutation opened an empty tree (`BASE_WEEK`) and its
 * quiet sticky successor (`BASE_WEEK + 1`) from the sandbox's `1` to
 * `NOBODY`; every later week, computed from an already non-empty live
 * tree, is untouched. Two tests are new relative to the sandbox,
 * covering this hardening directly on its own:
 * `test_snapshot_emptyTree_recordsNobody` and
 * `test_qualifyingBucket_emptyTree_returnsNobody`.
 *
 * Second, and more fundamentally, `qualifiedAt` derives the week-w
 * bucket from the referrer's append-only CHECKPOINT log (`bucketAt`,
 * strict-predecessor lookup) instead of the sandbox's CURRENT bucket —
 * a referrer whose score first appears during week W has
 * `bucketAt(referrer, W) == 0` (the opening value of a referrer's own
 * first week is always zero) and is therefore NOT qualified at W even
 * while saturated, only from W + 1 onward once that week's closing
 * value becomes W + 1's opening value. This is exercised explicitly in
 * the adapted `test_cutoffAt_quietWeeksCarryForward` (the saturated
 * cohort added mid-week now reads `qualifiedAt(week-added, .) ==
 * false` and `qualifiedAt(week-added + 1, .) == true`, where the
 * sandbox read `true` at the week it was added) and folded into
 * `_assertQualifiedAtMatches`, which now compares against
 * `hub.bucketAt(referrer, week)` rather than a live `referrerBucket`
 * read.
 *
 * Every driver call goes through `hub.reportScores`, gated by
 * `onlyReporter`; the test contract grants itself reporter status in
 * `setUp` (it is master by construction, since {ReferralHub}'s
 * constructor runs `OwnableMaster(msg.sender)`). `reportScores` itself
 * runs the SAME pre-mutation snapshot ordering
 * (`_snapshotCutoffIfNewWeek` before the diff is applied) that the
 * sandbox left to an explicit `snapshot()` call alone, so — unlike the
 * sandbox — every reportScores call in this suite can silently open a
 * new week's cutoff entry; every test below is sequenced so that any
 * assertion-bearing `snapshotWeek()` call is either the genuine first
 * mutation of its week or is knowingly exercising the resulting
 * no-op.
 */
contract ReferralHubCutoffTest is Test {

    uint256 internal constant WEEK = 1 weeks;

    uint256 internal constant BASE_WEEK = 3_000;

    uint256 internal constant MIN_SCORE = 1_000 * 1e6;

    uint256 internal constant BUCKET_COUNT = 2_048;

    uint256 internal constant NOBODY = 2_049;

    ReferralHub internal hub;

    event CutoffSnapshot(
        uint256 indexed week,
        uint256 qualifyingBucket
    );

    function setUp()
        public
    {
        vm.warp(
            BASE_WEEK * WEEK
        );

        hub = new ReferralHub();

        hub.setAllowedReporter(
            address(this),
            true
        );
    }

    // ---- Helpers ----

    function _addReferrers(
        uint256 _count,
        uint256 _score,
        uint256 _base
    )
        internal
        returns (address[] memory referrers)
    {
        referrers = new address[](_count);

        for (uint256 i; i < _count; ++i) {

            address referrer = address(
                uint160(_base + i)
            );

            referrers[i] = referrer;

            hub.reportScores(
                referrer,
                _score,
                0
            );
        }
    }

    function _assertDecileProperty(
        address[] memory _referrers
    )
        internal
        view
    {
        uint256 qualifying = hub.qualifyingBucket();

        for (uint256 i; i < _referrers.length; ++i) {

            uint256 bucket = hub.referrerBucket(
                _referrers[i]
            );

            assertEq(
                bucket != 0 && bucket >= qualifying,
                hub.isTopTenPercent(_referrers[i])
            );
        }
    }

    function _assertQualifiedAtMatches(
        address[] memory _referrers,
        uint256 _week
    )
        internal
        view
    {
        uint256 cutoff = hub.cutoffAt(
            _week
        );

        for (uint256 i; i < _referrers.length; ++i) {

            uint256 bucket = hub.bucketAt(
                _referrers[i],
                _week
            );

            bool expected = bucket != 0
                && cutoff <= BUCKET_COUNT
                && bucket >= cutoff;

            assertEq(
                hub.qualifiedAt(_week, _referrers[i]),
                expected
            );
        }
    }

    // ---- Live decile / qualifyingBucket parity ----

    function test_qualifyingBucket_singleReferrer_qualifies()
        public
    {
        address[] memory referrers = _addReferrers(
            1,
            5_000 * 1e6,
            0x1100
        );

        assertEq(
            hub.qualifyingBucket(),
            1
        );

        assertTrue(
            hub.isTopTenPercent(referrers[0])
        );

        _assertDecileProperty(
            referrers
        );
    }

    function test_qualifyingBucket_tenTiedReferrers_nobodyQualifies()
        public
    {
        address[] memory referrers = _addReferrers(
            10,
            MIN_SCORE,
            0x1100
        );

        assertEq(
            hub.qualifyingBucket(),
            2
        );

        for (uint256 i; i < referrers.length; ++i) {
            assertFalse(
                hub.isTopTenPercent(referrers[i])
            );
        }

        _assertDecileProperty(
            referrers
        );
    }

    function test_qualifyingBucket_straddlingBucketExcludedWholesale()
        public
    {
        address[] memory bottom = _addReferrers(
            15,
            MIN_SCORE,
            0x1100
        );

        address[] memory middle = _addReferrers(
            3,
            2_000 * 1e6,
            0x2100
        );

        address[] memory top = _addReferrers(
            2,
            4_000 * 1e6,
            0x3100
        );

        assertEq(
            hub.qualifyingBucket(),
            66
        );

        assertTrue(
            hub.isTopTenPercent(top[0])
        );

        assertTrue(
            hub.isTopTenPercent(top[1])
        );

        assertFalse(
            hub.isTopTenPercent(middle[0])
        );

        assertFalse(
            hub.isTopTenPercent(bottom[0])
        );

        _assertDecileProperty(
            bottom
        );

        _assertDecileProperty(
            middle
        );

        _assertDecileProperty(
            top
        );
    }

    function test_qualifyingBucket_allTiedInTopBucket_returnsNobody()
        public
    {
        address[] memory referrers = _addReferrers(
            20,
            MIN_SCORE << 32,
            0x1100
        );

        assertEq(
            hub.qualifyingBucket(),
            NOBODY
        );

        for (uint256 i; i < referrers.length; ++i) {
            assertEq(
                hub.referrerBucket(referrers[i]),
                BUCKET_COUNT
            );

            assertFalse(
                hub.isTopTenPercent(referrers[i])
            );
        }

        _assertDecileProperty(
            referrers
        );
    }

    function testFuzz_qualifyingBucket_matchesIsTopTenPercent(
        uint256 _seed
    )
        public
    {
        address[] memory referrers = new address[](12);

        for (uint256 i; i < 12; ++i) {

            uint256 roll = uint256(
                keccak256(
                    abi.encode(_seed, i)
                )
            );

            address referrer = address(
                uint160(0x5100 + i)
            );

            referrers[i] = referrer;

            hub.reportScores(
                referrer,
                bound(roll, 0, MIN_SCORE * 1_000),
                0
            );
        }

        _assertDecileProperty(
            referrers
        );
    }

    // ---- Snapshot discipline ----

    function test_snapshot_secondCallSameWeek_pushesNothing()
        public
    {
        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(hub)
        );

        emit CutoffSnapshot(
            BASE_WEEK,
            NOBODY
        );

        address[] memory referrers = _addReferrers(
            1,
            5_000 * 1e6,
            0x1100
        );

        assertEq(
            hub.cutoffAt(BASE_WEEK),
            NOBODY
        );

        vm.recordLogs();

        hub.snapshotWeek();

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            logs.length,
            0
        );

        assertEq(
            hub.cutoffAt(BASE_WEEK),
            NOBODY
        );

        assertTrue(
            hub.isTopTenPercent(referrers[0])
        );
    }

    function test_snapshot_beforeMutationInNewWeek_capturesPreMutationTree()
        public
    {
        _addReferrers(
            1,
            5_000 * 1e6,
            0x1100
        );

        vm.warp(
            (BASE_WEEK + 1) * WEEK
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(hub)
        );

        emit CutoffSnapshot(
            BASE_WEEK + 1,
            1
        );

        hub.snapshotWeek();

        _addReferrers(
            10,
            MIN_SCORE,
            0x2100
        );

        assertEq(
            hub.cutoffAt(BASE_WEEK + 1),
            1
        );

        assertEq(
            hub.qualifyingBucket(),
            2
        );

        vm.warp(
            (BASE_WEEK + 2) * WEEK
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(hub)
        );

        emit CutoffSnapshot(
            BASE_WEEK + 2,
            2
        );

        hub.snapshotWeek();

        assertEq(
            hub.cutoffAt(BASE_WEEK + 1),
            1
        );

        assertEq(
            hub.cutoffAt(BASE_WEEK + 2),
            2
        );
    }

    function test_snapshot_emptyTree_recordsNobody()
        public
    {
        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(hub)
        );

        emit CutoffSnapshot(
            BASE_WEEK,
            NOBODY
        );

        hub.snapshotWeek();

        assertEq(
            hub.cutoffAt(BASE_WEEK),
            NOBODY
        );
    }

    // ---- qualifyingBucket / cutoffAt edge states ----

    function test_qualifyingBucket_emptyTree_returnsNobody()
        public
        view
    {
        assertEq(
            hub.qualifyingBucket(),
            NOBODY
        );
    }

    function test_cutoffAt_beforeAnySnapshot_returnsNobody()
        public
        view
    {
        assertEq(
            hub.cutoffAt(0),
            NOBODY
        );

        assertEq(
            hub.cutoffAt(BASE_WEEK),
            NOBODY
        );

        assertEq(
            hub.cutoffAt(BASE_WEEK + 100),
            NOBODY
        );
    }

    // ---- Sticky resolution + checkpoint-based qualifiedAt ----

    function test_cutoffAt_quietWeeksCarryForward()
        public
    {
        hub.snapshotWeek();

        _addReferrers(
            10,
            MIN_SCORE,
            0x1100
        );

        vm.warp(
            (BASE_WEEK + 2) * WEEK
        );

        hub.snapshotWeek();

        address[] memory saturated = _addReferrers(
            10,
            MIN_SCORE << 32,
            0x3100
        );

        vm.warp(
            (BASE_WEEK + 5) * WEEK
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(hub)
        );

        emit CutoffSnapshot(
            BASE_WEEK + 5,
            NOBODY
        );

        hub.snapshotWeek();

        assertEq(
            hub.cutoffAt(BASE_WEEK - 1),
            NOBODY
        );

        assertEq(
            hub.cutoffAt(BASE_WEEK),
            NOBODY
        );

        assertEq(
            hub.cutoffAt(BASE_WEEK + 1),
            NOBODY
        );

        assertEq(
            hub.cutoffAt(BASE_WEEK + 2),
            2
        );

        assertEq(
            hub.cutoffAt(BASE_WEEK + 3),
            2
        );

        assertEq(
            hub.cutoffAt(BASE_WEEK + 4),
            2
        );

        assertEq(
            hub.cutoffAt(BASE_WEEK + 5),
            NOBODY
        );

        assertEq(
            hub.cutoffAt(BASE_WEEK + 50),
            NOBODY
        );

        assertEq(
            hub.referrerBucket(saturated[0]),
            BUCKET_COUNT
        );

        assertFalse(
            hub.qualifiedAt(BASE_WEEK + 5, saturated[0])
        );

        assertFalse(
            hub.qualifiedAt(BASE_WEEK + 2, saturated[0])
        );

        assertTrue(
            hub.qualifiedAt(BASE_WEEK + 3, saturated[0])
        );
    }

    function test_qualifiedAt_matchesManualBucketVersusCutoff()
        public
    {
        address[] memory bottom = _addReferrers(
            15,
            MIN_SCORE,
            0x1100
        );

        address[] memory middle = _addReferrers(
            3,
            2_000 * 1e6,
            0x2100
        );

        address[] memory top = _addReferrers(
            2,
            4_000 * 1e6,
            0x3100
        );

        hub.reportScores(
            address(0x4100),
            500 * 1e6,
            0
        );

        vm.warp(
            (BASE_WEEK + 1) * WEEK
        );

        hub.snapshotWeek();

        assertEq(
            hub.cutoffAt(BASE_WEEK + 1),
            66
        );

        _assertQualifiedAtMatches(
            bottom,
            BASE_WEEK + 1
        );

        _assertQualifiedAtMatches(
            middle,
            BASE_WEEK + 1
        );

        _assertQualifiedAtMatches(
            top,
            BASE_WEEK + 1
        );

        assertEq(
            hub.bucketAt(address(0x4100), BASE_WEEK + 1),
            0
        );

        assertFalse(
            hub.qualifiedAt(BASE_WEEK + 1, address(0x4100))
        );

        assertTrue(
            hub.qualifiedAt(BASE_WEEK + 1, top[0])
        );

        assertFalse(
            hub.qualifiedAt(BASE_WEEK + 1, middle[0])
        );

        assertFalse(
            hub.qualifiedAt(BASE_WEEK + 1, bottom[0])
        );

        assertFalse(
            hub.qualifiedAt(BASE_WEEK, top[0])
        );
    }
}
