// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ReferralCutoffOracleDemo} from "./ReferralCutoffOracleDemo.sol";

/**
 * @dev Suite for the hub-side weekly cutoff oracle
 * {ReferralCutoffOracleDemo}. The load-bearing property is the
 * equivalence between the stored verdict and the live predicate: for
 * EVERY referrer, bucket != 0 && bucket >= qualifyingBucket() must
 * equal isTopTenPercent(referrer), across single-referrer, all-tied,
 * straddling-bucket and top-bucket-saturated distributions plus a
 * randomized fuzz over 12 referrers including inactive scores. The
 * snapshot discipline half covers: exactly one checkpoint per week
 * with the second call a silent no-op; a snapshot taken BEFORE the
 * first tree mutation of a new week capturing the pre-mutation state
 * even as the live predicate moves on; quiet weeks carrying the
 * previous checkpoint forward exactly; NOBODY_QUALIFIES (2049) both
 * as the pre-history default and as a storable verdict; and
 * qualifiedAt reproducing the manual bucket-versus-cutoff comparison
 * including the inactive bucket-0 case. The inherited raw
 * addVolume/removeVolume drivers are permissionless on this contract
 * and serve as the test drivers.
 */
contract ReferralCutoffOracleTest is Test {

    uint256 internal constant WEEK = 1 weeks;

    uint256 internal constant BASE_WEEK = 3_000;

    uint256 internal constant MIN_SCORE = 1_000 * 1e6;

    uint256 internal constant BUCKET_COUNT = 2_048;

    uint256 internal constant NOBODY = 2_049;

    ReferralCutoffOracleDemo internal oracle;

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

        oracle = new ReferralCutoffOracleDemo();
    }

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

            oracle.addVolume(
                referrer,
                _score
            );
        }
    }

    function _assertDecileProperty(
        address[] memory _referrers
    )
        internal
        view
    {
        uint256 qualifying = oracle.qualifyingBucket();

        for (uint256 i; i < _referrers.length; ++i) {

            uint256 bucket = oracle.referrerBucket(
                _referrers[i]
            );

            assertEq(
                bucket != 0 && bucket >= qualifying,
                oracle.isTopTenPercent(
                    _referrers[i]
                )
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
        uint256 cutoff = oracle.cutoffAt(
            _week
        );

        for (uint256 i; i < _referrers.length; ++i) {

            uint256 bucket = oracle.referrerBucket(
                _referrers[i]
            );

            bool expected = bucket != 0
                && cutoff <= BUCKET_COUNT
                && bucket >= cutoff;

            assertEq(
                oracle.qualifiedAt(
                    _week,
                    _referrers[i]
                ),
                expected
            );
        }
    }

    function test_qualifyingBucket_singleReferrer_qualifies()
        public
    {
        address[] memory referrers = _addReferrers(
            1,
            5_000 * 1e6,
            0x1100
        );

        assertEq(oracle.qualifyingBucket(), 1);
        assertTrue(oracle.isTopTenPercent(referrers[0]));

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

        assertEq(oracle.qualifyingBucket(), 2);

        for (uint256 i; i < referrers.length; ++i) {
            assertFalse(oracle.isTopTenPercent(referrers[i]));
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

        assertEq(oracle.qualifyingBucket(), 66);

        assertTrue(oracle.isTopTenPercent(top[0]));
        assertTrue(oracle.isTopTenPercent(top[1]));
        assertFalse(oracle.isTopTenPercent(middle[0]));
        assertFalse(oracle.isTopTenPercent(bottom[0]));

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

        assertEq(oracle.qualifyingBucket(), NOBODY);

        for (uint256 i; i < referrers.length; ++i) {
            assertEq(oracle.referrerBucket(referrers[i]), BUCKET_COUNT);
            assertFalse(oracle.isTopTenPercent(referrers[i]));
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

            oracle.addVolume(
                referrer,
                bound(roll, 0, MIN_SCORE * 1_000)
            );
        }

        _assertDecileProperty(
            referrers
        );
    }

    function test_snapshot_secondCallSameWeek_pushesNothing()
        public
    {
        _addReferrers(
            1,
            5_000 * 1e6,
            0x1100
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(oracle)
        );

        emit CutoffSnapshot(
            BASE_WEEK,
            1
        );

        oracle.snapshot();

        assertEq(oracle.cutoffAt(BASE_WEEK), 1);

        vm.recordLogs();

        oracle.snapshot();

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0);
        assertEq(oracle.cutoffAt(BASE_WEEK), 1);
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
            address(oracle)
        );

        emit CutoffSnapshot(
            BASE_WEEK + 1,
            1
        );

        oracle.snapshot();

        _addReferrers(
            10,
            MIN_SCORE,
            0x2100
        );

        assertEq(oracle.cutoffAt(BASE_WEEK + 1), 1);
        assertEq(oracle.qualifyingBucket(), 2);

        vm.warp(
            (BASE_WEEK + 2) * WEEK
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(oracle)
        );

        emit CutoffSnapshot(
            BASE_WEEK + 2,
            2
        );

        oracle.snapshot();

        assertEq(oracle.cutoffAt(BASE_WEEK + 1), 1);
        assertEq(oracle.cutoffAt(BASE_WEEK + 2), 2);
    }

    function test_cutoffAt_quietWeeksCarryForward()
        public
    {
        oracle.snapshot();

        _addReferrers(
            10,
            MIN_SCORE,
            0x1100
        );

        vm.warp(
            (BASE_WEEK + 2) * WEEK
        );

        oracle.snapshot();

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
            address(oracle)
        );

        emit CutoffSnapshot(
            BASE_WEEK + 5,
            NOBODY
        );

        oracle.snapshot();

        assertEq(oracle.cutoffAt(BASE_WEEK - 1), NOBODY);
        assertEq(oracle.cutoffAt(BASE_WEEK), 1);
        assertEq(oracle.cutoffAt(BASE_WEEK + 1), 1);
        assertEq(oracle.cutoffAt(BASE_WEEK + 2), 2);
        assertEq(oracle.cutoffAt(BASE_WEEK + 3), 2);
        assertEq(oracle.cutoffAt(BASE_WEEK + 4), 2);
        assertEq(oracle.cutoffAt(BASE_WEEK + 5), NOBODY);
        assertEq(oracle.cutoffAt(BASE_WEEK + 50), NOBODY);

        assertEq(oracle.referrerBucket(saturated[0]), BUCKET_COUNT);
        assertFalse(oracle.qualifiedAt(BASE_WEEK + 5, saturated[0]));
        assertTrue(oracle.qualifiedAt(BASE_WEEK + 2, saturated[0]));
    }

    function test_cutoffAt_beforeAnySnapshot_returnsNobody()
        public
        view
    {
        assertEq(oracle.cutoffAt(0), NOBODY);
        assertEq(oracle.cutoffAt(BASE_WEEK), NOBODY);
        assertEq(oracle.cutoffAt(BASE_WEEK + 100), NOBODY);
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

        oracle.addVolume(
            address(0x4100),
            500 * 1e6
        );

        vm.warp(
            (BASE_WEEK + 1) * WEEK
        );

        oracle.snapshot();

        assertEq(oracle.cutoffAt(BASE_WEEK + 1), 66);

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

        assertEq(oracle.referrerBucket(address(0x4100)), 0);
        assertFalse(oracle.qualifiedAt(BASE_WEEK + 1, address(0x4100)));

        assertTrue(oracle.qualifiedAt(BASE_WEEK + 1, top[0]));
        assertFalse(oracle.qualifiedAt(BASE_WEEK + 1, middle[0]));
        assertFalse(oracle.qualifiedAt(BASE_WEEK + 1, bottom[0]));

        assertFalse(oracle.qualifiedAt(BASE_WEEK, top[0]));
    }
}
