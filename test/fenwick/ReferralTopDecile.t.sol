// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ReferralTopDecile} from "./ReferralTopDecile.sol";
import {ReferralTopDecileHarness} from "./ReferralTopDecileHarness.sol";

/**
 * @dev Correctness and fuzz suite for the ReferralTopDecile practice
 * contract: bucket-mapping edges, activation/deactivation crossings,
 * Fenwick tree conservation, and the round-down top-10% boundary policy
 * including the 20/30/120 worked example from the design discussion.
 */
contract ReferralTopDecileTest is Test {

    uint256 internal constant MIN_SCORE = 1_000 * 1e6;

    uint256 internal constant BUCKETS = 2_048;

    uint256 internal constant SUBS = 64;

    ReferralTopDecileHarness internal tracker;

    event ScoreUpdated(
        address indexed referrer,
        uint256 oldScore,
        uint256 newScore,
        uint256 oldBucket,
        uint256 newBucket
    );

    function setUp()
        public
    {
        tracker = new ReferralTopDecileHarness();
    }

    // ---- Helpers ----

    function _scoreForBucket(
        uint256 _bucket
    )
        internal
        view
        returns (uint256)
    {
        uint256 lo = MIN_SCORE;
        uint256 hi = type(uint256).max;

        while (lo < hi) {
            uint256 mid = lo + (hi - lo) / 2;

            if (tracker.bucketForScore(mid) >= _bucket) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }

        return lo;
    }

    function _refAddr(
        uint256 _i
    )
        internal
        pure
        returns (address)
    {
        return address(
            uint160(uint256(keccak256(abi.encode("fenwick.ref", _i))))
        );
    }

    function _treeFold()
        internal
        view
        returns (bytes32 acc)
    {
        for (uint256 i = 1; i <= BUCKETS; ++i) {
            acc = keccak256(
                abi.encode(acc, tracker.exposed_fenwickNode(i))
            );
        }
    }

    // ---- Bucket mapping ----

    function test_bucketForScore_belowMinIsZero()
        public
        view
    {
        assertEq(tracker.bucketForScore(0), 0);
        assertEq(tracker.bucketForScore(1), 0);
        assertEq(tracker.bucketForScore(MIN_SCORE - 1), 0);
    }

    function test_bucketForScore_exactMinIsFirstBucket()
        public
        view
    {
        assertEq(tracker.bucketForScore(MIN_SCORE), 1);
    }

    function test_bucketForScore_powerOfTwoBoundaries()
        public
        view
    {
        for (uint256 k; k < 32; ++k) {
            assertEq(
                tracker.bucketForScore(MIN_SCORE << k),
                k * SUBS + 1
            );

            assertEq(
                tracker.bucketForScore((MIN_SCORE << (k + 1)) - 1),
                (k + 1) * SUBS
            );
        }

        assertEq(tracker.bucketForScore(MIN_SCORE << 32), BUCKETS);
    }

    function test_bucketForScore_subBucketBoundaries()
        public
        view
    {
        uint256[4] memory samples = [uint256(2), 17, 512, 2_047];

        for (uint256 i; i < samples.length; ++i) {
            uint256 bucket = samples[i];
            uint256 lowest = _scoreForBucket(bucket);

            assertEq(tracker.bucketForScore(lowest), bucket);
            assertEq(tracker.bucketForScore(lowest - 1), bucket - 1);
        }
    }

    function test_bucketForScore_exponentCapClamps()
        public
        view
    {
        assertEq(tracker.bucketForScore(type(uint256).max), BUCKETS);
        assertEq(
            tracker.bucketForScore(_scoreForBucket(BUCKETS)),
            BUCKETS
        );
    }

    // ---- Activation / deactivation / moves ----

    function test_addVolume_belowMinStaysInactive()
        public
    {
        tracker.addVolume(
            address(0xA1),
            MIN_SCORE - 1
        );

        assertEq(tracker.activeReferrerCount(), 0);
        assertEq(tracker.referrerBucket(address(0xA1)), 0);
        assertEq(tracker.referralScore(address(0xA1)), MIN_SCORE - 1);
        assertEq(tracker.exposed_prefixSum(BUCKETS), 0);
    }

    function test_addVolume_crossingMinActivates()
        public
    {
        tracker.addVolume(
            address(0xA1),
            MIN_SCORE - 1
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(tracker)
        );

        emit ScoreUpdated(
            address(0xA1),
            MIN_SCORE - 1,
            MIN_SCORE,
            0,
            1
        );

        tracker.addVolume(
            address(0xA1),
            1
        );

        assertEq(tracker.activeReferrerCount(), 1);
        assertEq(tracker.referrerBucket(address(0xA1)), 1);
        assertEq(tracker.exposed_prefixSum(BUCKETS), 1);
    }

    function test_removeVolume_crossingBelowMinDeactivates()
        public
    {
        tracker.addVolume(
            address(0xA1),
            MIN_SCORE
        );

        tracker.removeVolume(
            address(0xA1),
            1
        );

        assertEq(tracker.activeReferrerCount(), 0);
        assertEq(tracker.referrerBucket(address(0xA1)), 0);
        assertEq(tracker.exposed_prefixSum(BUCKETS), 0);
        assertFalse(tracker.isTopTenPercent(address(0xA1)));
    }

    function test_addVolume_reactivationAfterDeactivation()
        public
    {
        tracker.addVolume(
            address(0xA1),
            MIN_SCORE
        );

        tracker.removeVolume(
            address(0xA1),
            1
        );

        tracker.addVolume(
            address(0xA1),
            1
        );

        assertEq(tracker.activeReferrerCount(), 1);
        assertEq(tracker.referralScore(address(0xA1)), MIN_SCORE);
        assertEq(tracker.referrerBucket(address(0xA1)), 1);
        assertEq(tracker.exposed_prefixSum(BUCKETS), 1);
    }

    function test_addVolume_sameBucketNoTreeChange()
        public
    {
        tracker.addVolume(
            address(0xA1),
            MIN_SCORE << 10
        );

        bytes32 foldBefore = _treeFold();

        tracker.addVolume(
            address(0xA1),
            1
        );

        assertEq(_treeFold(), foldBefore);
        assertEq(
            tracker.referrerBucket(address(0xA1)),
            10 * SUBS + 1
        );
    }

    function test_addVolume_bucketMoveUpdatesTree()
        public
    {
        uint256 scoreLow = _scoreForBucket(100);
        uint256 scoreHigh = _scoreForBucket(200);

        tracker.addVolume(
            address(0xA1),
            scoreLow
        );

        assertEq(tracker.referrerBucket(address(0xA1)), 100);

        tracker.addVolume(
            address(0xA1),
            scoreHigh - scoreLow
        );

        assertEq(tracker.referrerBucket(address(0xA1)), 200);
        assertEq(
            tracker.prefixCount(100) - tracker.prefixCount(99),
            0
        );
        assertEq(
            tracker.prefixCount(200) - tracker.prefixCount(199),
            1
        );
        assertEq(tracker.activeReferrerCount(), 1);
    }

    function test_removeVolume_bucketMoveDown()
        public
    {
        uint256 scoreLow = _scoreForBucket(100);
        uint256 scoreHigh = _scoreForBucket(200);

        tracker.addVolume(
            address(0xA1),
            scoreHigh
        );

        tracker.removeVolume(
            address(0xA1),
            scoreHigh - scoreLow
        );

        assertEq(tracker.referrerBucket(address(0xA1)), 100);
        assertEq(
            tracker.prefixCount(100) - tracker.prefixCount(99),
            1
        );
        assertEq(
            tracker.prefixCount(200) - tracker.prefixCount(199),
            0
        );
        assertEq(tracker.activeReferrerCount(), 1);
    }

    function test_addRemove_restoresTreeState()
        public
    {
        tracker.addVolume(
            address(0xA1),
            MIN_SCORE
        );

        bytes32 foldBefore = keccak256(
            abi.encode(
                _treeFold(),
                tracker.activeReferrerCount(),
                tracker.referralScore(address(0xA1)),
                tracker.referrerBucket(address(0xA1))
            )
        );

        uint256 delta = _scoreForBucket(1_025) - MIN_SCORE;

        tracker.addVolume(
            address(0xA1),
            delta
        );

        tracker.removeVolume(
            address(0xA1),
            delta
        );

        bytes32 foldAfter = keccak256(
            abi.encode(
                _treeFold(),
                tracker.activeReferrerCount(),
                tracker.referralScore(address(0xA1)),
                tracker.referrerBucket(address(0xA1))
            )
        );

        assertEq(foldAfter, foldBefore);
    }

    function test_removeVolume_overAmount_reverts()
        public
    {
        tracker.addVolume(
            address(0xA1),
            MIN_SCORE
        );

        vm.expectRevert(
            ReferralTopDecile.InsufficientScore.selector
        );

        tracker.removeVolume(
            address(0xA1),
            MIN_SCORE + 1
        );
    }

    function test_addVolume_zeroAddress_reverts()
        public
    {
        vm.expectRevert(
            ReferralTopDecile.ZeroAddress.selector
        );

        tracker.addVolume(
            address(0),
            1
        );
    }

    function test_prefixCount_aboveBucketCount_reverts()
        public
    {
        tracker.addVolume(
            address(0xA1),
            MIN_SCORE
        );

        assertEq(tracker.prefixCount(BUCKETS), 1);

        vm.expectRevert(
            ReferralTopDecile.InvalidBucket.selector
        );

        tracker.prefixCount(BUCKETS + 1);
    }

    function test_addVolume_zeroAmount_noopNoEvent()
        public
    {
        tracker.addVolume(
            address(0xA1),
            MIN_SCORE
        );

        vm.recordLogs();

        tracker.addVolume(
            address(0xA1),
            0
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0);
    }

    // ---- Top-decile semantics ----

    function test_isTopTenPercent_workedExample_50of1000()
        public
    {
        uint256 scoreA = _scoreForBucket(2_000);
        uint256 scoreB = _scoreForBucket(1_900);
        uint256 scoreC = _scoreForBucket(1_800);

        for (uint256 i; i < 20; ++i) {
            tracker.addVolume(
                _refAddr(i),
                scoreA
            );
        }

        for (uint256 i = 20; i < 50; ++i) {
            tracker.addVolume(
                _refAddr(i),
                scoreB
            );
        }

        for (uint256 i = 50; i < 170; ++i) {
            tracker.addVolume(
                _refAddr(i),
                scoreC
            );
        }

        for (uint256 i = 170; i < 1_000; ++i) {
            tracker.addVolume(
                _refAddr(i),
                MIN_SCORE << (i % 20)
            );
        }

        assertEq(tracker.activeReferrerCount(), 1_000);
        assertEq(tracker.targetTopCount(), 100);

        assertTrue(tracker.isTopTenPercent(_refAddr(0)));
        assertTrue(tracker.isTopTenPercent(_refAddr(20)));
        assertFalse(tracker.isTopTenPercent(_refAddr(50)));
        assertFalse(tracker.isTopTenPercent(_refAddr(170)));
    }

    function test_isTopTenPercent_singleReferrer()
        public
    {
        tracker.addVolume(
            address(0xA1),
            MIN_SCORE
        );

        assertTrue(tracker.isTopTenPercent(address(0xA1)));
    }

    function test_isTopTenPercent_fiveSameBucket()
        public
    {
        for (uint256 i; i < 5; ++i) {
            tracker.addVolume(
                _refAddr(i),
                MIN_SCORE * 3
            );
        }

        assertEq(tracker.targetTopCount(), 1);

        for (uint256 i; i < 5; ++i) {
            assertFalse(tracker.isTopTenPercent(_refAddr(i)));
        }
    }

    function test_isTopTenPercent_boundaryExactTarget()
        public
    {
        for (uint256 i; i < 10; ++i) {
            tracker.addVolume(
                _refAddr(i),
                MIN_SCORE << 10
            );
        }

        for (uint256 i = 10; i < 100; ++i) {
            tracker.addVolume(
                _refAddr(i),
                MIN_SCORE
            );
        }

        assertEq(tracker.targetTopCount(), 10);

        assertTrue(tracker.isTopTenPercent(_refAddr(0)));
        assertFalse(tracker.isTopTenPercent(_refAddr(10)));
    }

    function test_isTopTenPercent_sameScoreSameVerdict()
        public
    {
        tracker.addVolume(
            address(0xA1),
            MIN_SCORE * 5
        );

        tracker.addVolume(
            address(0xA2),
            MIN_SCORE * 5
        );

        for (uint256 i; i < 8; ++i) {
            tracker.addVolume(
                _refAddr(i),
                MIN_SCORE
            );
        }

        assertEq(
            tracker.isTopTenPercent(address(0xA1)),
            tracker.isTopTenPercent(address(0xA2))
        );
    }

    function test_isTopTenPercent_inactiveReferrerFalse()
        public
    {
        tracker.addVolume(
            address(0xA1),
            MIN_SCORE - 1
        );

        assertFalse(tracker.isTopTenPercent(address(0xA1)));
        assertFalse(tracker.isTopTenPercent(address(0xB2)));
    }

    // ---- Fuzz ----

    function testFuzz_bucketForScore_monotonic(
        uint256 _a,
        uint256 _b
    )
        public
        view
    {
        uint256 lo = _a < _b ? _a : _b;
        uint256 hi = _a < _b ? _b : _a;

        assertLe(
            tracker.bucketForScore(lo),
            tracker.bucketForScore(hi)
        );
    }

    function testFuzz_addRemove_preservesCountSum(
        uint256 _seed
    )
        public
    {
        address[4] memory actors = [
            address(0xA1),
            address(0xA2),
            address(0xA3),
            address(0xA4)
        ];

        for (uint256 i; i < 16; ++i) {
            uint256 roll = uint256(
                keccak256(abi.encode(_seed, i))
            );

            address actor = actors[roll % 4];

            if ((roll >> 8) % 2 == 0) {
                tracker.addVolume(
                    actor,
                    bound(roll >> 16, 0, MIN_SCORE * 4)
                );
            } else {
                tracker.removeVolume(
                    actor,
                    bound(
                        roll >> 16,
                        0,
                        tracker.referralScore(actor)
                    )
                );
            }
        }

        assertEq(
            tracker.exposed_prefixSum(BUCKETS),
            tracker.activeReferrerCount()
        );

        for (uint256 i; i < 4; ++i) {
            assertEq(
                tracker.referrerBucket(actors[i]),
                tracker.bucketForScore(
                    tracker.referralScore(actors[i])
                )
            );
        }
    }
}
