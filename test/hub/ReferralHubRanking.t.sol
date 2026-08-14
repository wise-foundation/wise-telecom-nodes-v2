// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ReferralHub} from "../../src/hub/pending/ReferralHub.sol";
import {ReferralHubDeclarations} from "../../src/hub/pending/ReferralHubDeclarations.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev Port of the proven `test/fenwick/ReferralTopDecile.t.sol` sandbox
 * suite onto the real {ReferralHub}: bucket-mapping edges, activation /
 * deactivation / reactivation crossings, Fenwick tree conservation and
 * the round-down top-10% boundary policy, including the 20/30/120
 * worked example from the design discussion, all driven through the
 * hub's reporter-gated `reportScores` intake instead of the sandbox's
 * permissionless `addVolume`/`removeVolume`.
 *
 * Scores are ABSOLUTE per source on the hub (never deltas), so every
 * driver call in this suite reads `globalReferredScore` first and
 * reports the new absolute total; `_addVolume` and `_removeVolume`
 * below are thin local wrappers reproducing the sandbox's
 * relative-amount driver ergonomics on top of that absolute API. The
 * test contract deploys {ReferralHub} in `setUp` (making it master by
 * construction, since the constructor runs `OwnableMaster(msg.sender)`)
 * and immediately grants itself reporter status, so every score write
 * in this file flows through the exact `onlyReporter` choke point a
 * production reporter would use.
 *
 * Two revert conditions replace the sandbox's `InsufficientScore`,
 * which has no absolute-API equivalent — there is no "remove more than
 * you have" left once every report is a fresh absolute value, only
 * `ZeroAddress` on the null referrer and `ScoreReportOutOfRange` on a
 * report exceeding `3 * LANE_MASK_80`. The sandbox's zero-amount no-op
 * test is ported as a same-value re-report: the hub's
 * `_applyScoreReport` short-circuits on `previous == packed` before any
 * state write or event, so a repeat report is silent exactly like a
 * zero-delta `addVolume` was. Revert selectors below are read off
 * {ReferralHubDeclarations} (the contract that actually declares them)
 * rather than the leaf {ReferralHub}: solc 0.8.36 only resolves a
 * custom error's `.selector` through the exact declaring contract, not
 * through an intermediate or leaf type in its inheritance chain.
 *
 * Coverage target: every line and branch of `ReferralHubRanking.sol`
 * (the checkpoint/cutoff surface above it is covered by the sibling
 * `ReferralHubCutoff.t.sol`).
 */
contract ReferralHubRankingTest is Test {

    uint256 internal constant MIN_SCORE = 1_000 * 1e6;

    uint256 internal constant BUCKETS = 2_048;

    uint256 internal constant SUBS = 64;

    uint256 internal constant WEEK = 1 weeks;

    uint256 internal constant BASE_WEEK = 3_000;

    uint256 internal constant MAX_SOURCE_SCORE = 3 * CohortWeeks.LANE_MASK_80;

    ReferralHub internal hub;

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
        vm.warp(
            BASE_WEEK * WEEK + 1
        );

        hub = new ReferralHub();

        hub.setAllowedReporter(
            address(this),
            true
        );
    }

    // ---- Helpers ----

    function _addVolume(
        address _referrer,
        uint256 _amount
    )
        internal
    {
        uint256 current = hub.globalReferredScore(
            _referrer
        );

        hub.reportScores(
            _referrer,
            current + _amount,
            0
        );
    }

    function _removeVolume(
        address _referrer,
        uint256 _amount
    )
        internal
    {
        uint256 current = hub.globalReferredScore(
            _referrer
        );

        hub.reportScores(
            _referrer,
            current - _amount,
            0
        );
    }

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

            uint256 bucket = hub.bucketForScore(
                mid
            );

            if (bucket >= _bucket) {
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
            uint160(
                uint256(
                    keccak256(
                        abi.encode(
                            "hub.ranking.ref",
                            _i
                        )
                    )
                )
            )
        );
    }

    function _treeFold()
        internal
        view
        returns (bytes32 acc)
    {
        for (uint256 i = 1; i <= BUCKETS; ++i) {

            acc = keccak256(
                abi.encode(
                    acc,
                    hub.prefixCount(i)
                )
            );
        }
    }

    // ---- Bucket mapping ----

    function test_bucketForScore_belowMinIsZero()
        public
        view
    {
        assertEq(
            hub.bucketForScore(0),
            0
        );

        assertEq(
            hub.bucketForScore(1),
            0
        );

        assertEq(
            hub.bucketForScore(MIN_SCORE - 1),
            0
        );
    }

    function test_bucketForScore_exactMinIsFirstBucket()
        public
        view
    {
        assertEq(
            hub.bucketForScore(MIN_SCORE),
            1
        );
    }

    function test_bucketForScore_powerOfTwoBoundaries()
        public
        view
    {
        for (uint256 k; k < 32; ++k) {

            assertEq(
                hub.bucketForScore(MIN_SCORE << k),
                k * SUBS + 1
            );

            assertEq(
                hub.bucketForScore((MIN_SCORE << (k + 1)) - 1),
                (k + 1) * SUBS
            );
        }

        assertEq(
            hub.bucketForScore(MIN_SCORE << 32),
            BUCKETS
        );
    }

    function test_bucketForScore_subBucketBoundaries()
        public
        view
    {
        uint256[4] memory samples = [uint256(2), 17, 512, 2_047];

        for (uint256 i; i < samples.length; ++i) {
            uint256 bucket = samples[i];
            uint256 lowest = _scoreForBucket(bucket);

            assertEq(
                hub.bucketForScore(lowest),
                bucket
            );

            assertEq(
                hub.bucketForScore(lowest - 1),
                bucket - 1
            );
        }
    }

    function test_bucketForScore_exponentCapClamps()
        public
        view
    {
        assertEq(
            hub.bucketForScore(type(uint256).max),
            BUCKETS
        );

        assertEq(
            hub.bucketForScore(_scoreForBucket(BUCKETS)),
            BUCKETS
        );
    }

    // ---- Activation / deactivation / moves ----

    function test_reportScores_belowMinStaysInactive()
        public
    {
        _addVolume(
            address(0xA1),
            MIN_SCORE - 1
        );

        assertEq(
            hub.activeReferrerCount(),
            0
        );

        assertEq(
            hub.referrerBucket(address(0xA1)),
            0
        );

        assertEq(
            hub.globalReferredScore(address(0xA1)),
            MIN_SCORE - 1
        );

        assertEq(
            hub.prefixCount(BUCKETS),
            0
        );
    }

    function test_reportScores_crossingMinActivates()
        public
    {
        _addVolume(
            address(0xA1),
            MIN_SCORE - 1
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(hub)
        );

        emit ScoreUpdated(
            address(0xA1),
            MIN_SCORE - 1,
            MIN_SCORE,
            0,
            1
        );

        _addVolume(
            address(0xA1),
            1
        );

        assertEq(
            hub.activeReferrerCount(),
            1
        );

        assertEq(
            hub.referrerBucket(address(0xA1)),
            1
        );

        assertEq(
            hub.prefixCount(BUCKETS),
            1
        );
    }

    function test_reportScores_crossingBelowMinDeactivates()
        public
    {
        _addVolume(
            address(0xA1),
            MIN_SCORE
        );

        _removeVolume(
            address(0xA1),
            1
        );

        assertEq(
            hub.activeReferrerCount(),
            0
        );

        assertEq(
            hub.referrerBucket(address(0xA1)),
            0
        );

        assertEq(
            hub.prefixCount(BUCKETS),
            0
        );

        assertFalse(
            hub.isTopTenPercent(address(0xA1))
        );
    }

    function test_reportScores_reactivationAfterDeactivation()
        public
    {
        _addVolume(
            address(0xA1),
            MIN_SCORE
        );

        _removeVolume(
            address(0xA1),
            1
        );

        _addVolume(
            address(0xA1),
            1
        );

        assertEq(
            hub.activeReferrerCount(),
            1
        );

        assertEq(
            hub.globalReferredScore(address(0xA1)),
            MIN_SCORE
        );

        assertEq(
            hub.referrerBucket(address(0xA1)),
            1
        );

        assertEq(
            hub.prefixCount(BUCKETS),
            1
        );
    }

    function test_reportScores_sameBucketNoTreeChange()
        public
    {
        _addVolume(
            address(0xA1),
            MIN_SCORE << 10
        );

        bytes32 foldBefore = _treeFold();

        _addVolume(
            address(0xA1),
            1
        );

        assertEq(
            _treeFold(),
            foldBefore
        );

        assertEq(
            hub.referrerBucket(address(0xA1)),
            10 * SUBS + 1
        );
    }

    function test_reportScores_bucketMoveUpdatesTree()
        public
    {
        uint256 scoreLow = _scoreForBucket(100);
        uint256 scoreHigh = _scoreForBucket(200);

        _addVolume(
            address(0xA1),
            scoreLow
        );

        assertEq(
            hub.referrerBucket(address(0xA1)),
            100
        );

        _addVolume(
            address(0xA1),
            scoreHigh - scoreLow
        );

        assertEq(
            hub.referrerBucket(address(0xA1)),
            200
        );

        assertEq(
            hub.prefixCount(100) - hub.prefixCount(99),
            0
        );

        assertEq(
            hub.prefixCount(200) - hub.prefixCount(199),
            1
        );

        assertEq(
            hub.activeReferrerCount(),
            1
        );
    }

    function test_reportScores_bucketMoveDown()
        public
    {
        uint256 scoreLow = _scoreForBucket(100);
        uint256 scoreHigh = _scoreForBucket(200);

        _addVolume(
            address(0xA1),
            scoreHigh
        );

        _removeVolume(
            address(0xA1),
            scoreHigh - scoreLow
        );

        assertEq(
            hub.referrerBucket(address(0xA1)),
            100
        );

        assertEq(
            hub.prefixCount(100) - hub.prefixCount(99),
            1
        );

        assertEq(
            hub.prefixCount(200) - hub.prefixCount(199),
            0
        );

        assertEq(
            hub.activeReferrerCount(),
            1
        );
    }

    function test_reportScores_addRemove_restoresTreeState()
        public
    {
        _addVolume(
            address(0xA1),
            MIN_SCORE
        );

        bytes32 foldBefore = keccak256(
            abi.encode(
                _treeFold(),
                hub.activeReferrerCount(),
                hub.globalReferredScore(address(0xA1)),
                hub.referrerBucket(address(0xA1))
            )
        );

        uint256 delta = _scoreForBucket(1_025) - MIN_SCORE;

        _addVolume(
            address(0xA1),
            delta
        );

        _removeVolume(
            address(0xA1),
            delta
        );

        bytes32 foldAfter = keccak256(
            abi.encode(
                _treeFold(),
                hub.activeReferrerCount(),
                hub.globalReferredScore(address(0xA1)),
                hub.referrerBucket(address(0xA1))
            )
        );

        assertEq(
            foldAfter,
            foldBefore
        );
    }

    function test_reportScores_outOfRange_reverts()
        public
    {
        hub.reportScores(
            address(0xA1),
            MAX_SOURCE_SCORE,
            0
        );

        assertEq(
            hub.globalReferredScore(address(0xA1)),
            MAX_SOURCE_SCORE
        );

        vm.expectRevert(
            ReferralHubDeclarations.ScoreReportOutOfRange.selector
        );

        hub.reportScores(
            address(0xA1),
            MAX_SOURCE_SCORE + 1,
            0
        );
    }

    function test_reportScores_zeroAddress_reverts()
        public
    {
        vm.expectRevert(
            ReferralHubDeclarations.ZeroAddress.selector
        );

        hub.reportScores(
            address(0),
            1,
            0
        );
    }

    function test_prefixCount_aboveBucketCount_reverts()
        public
    {
        _addVolume(
            address(0xA1),
            MIN_SCORE
        );

        assertEq(
            hub.prefixCount(BUCKETS),
            1
        );

        vm.expectRevert(
            ReferralHubDeclarations.InvalidBucket.selector
        );

        hub.prefixCount(BUCKETS + 1);
    }

    function test_reportScores_sameValue_noopNoEvent()
        public
    {
        _addVolume(
            address(0xA1),
            MIN_SCORE
        );

        uint256 current = hub.globalReferredScore(
            address(0xA1)
        );

        vm.recordLogs();

        hub.reportScores(
            address(0xA1),
            current,
            0
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            logs.length,
            0
        );
    }

    // ---- Top-decile semantics ----

    function test_isTopTenPercent_workedExample_50of1000()
        public
    {
        uint256 scoreA = _scoreForBucket(2_000);
        uint256 scoreB = _scoreForBucket(1_900);
        uint256 scoreC = _scoreForBucket(1_800);

        for (uint256 i; i < 20; ++i) {
            _addVolume(
                _refAddr(i),
                scoreA
            );
        }

        for (uint256 i = 20; i < 50; ++i) {
            _addVolume(
                _refAddr(i),
                scoreB
            );
        }

        for (uint256 i = 50; i < 170; ++i) {
            _addVolume(
                _refAddr(i),
                scoreC
            );
        }

        for (uint256 i = 170; i < 1_000; ++i) {
            _addVolume(
                _refAddr(i),
                MIN_SCORE << (i % 20)
            );
        }

        assertEq(
            hub.activeReferrerCount(),
            1_000
        );

        assertEq(
            hub.targetTopCount(),
            100
        );

        assertTrue(
            hub.isTopTenPercent(_refAddr(0))
        );

        assertTrue(
            hub.isTopTenPercent(_refAddr(20))
        );

        assertFalse(
            hub.isTopTenPercent(_refAddr(50))
        );

        assertFalse(
            hub.isTopTenPercent(_refAddr(170))
        );
    }

    function test_isTopTenPercent_singleReferrer()
        public
    {
        _addVolume(
            address(0xA1),
            MIN_SCORE
        );

        assertTrue(
            hub.isTopTenPercent(address(0xA1))
        );
    }

    function test_isTopTenPercent_fiveSameBucket()
        public
    {
        for (uint256 i; i < 5; ++i) {
            _addVolume(
                _refAddr(i),
                MIN_SCORE * 3
            );
        }

        assertEq(
            hub.targetTopCount(),
            1
        );

        for (uint256 i; i < 5; ++i) {
            assertFalse(
                hub.isTopTenPercent(_refAddr(i))
            );
        }
    }

    function test_isTopTenPercent_boundaryExactTarget()
        public
    {
        for (uint256 i; i < 10; ++i) {
            _addVolume(
                _refAddr(i),
                MIN_SCORE << 10
            );
        }

        for (uint256 i = 10; i < 100; ++i) {
            _addVolume(
                _refAddr(i),
                MIN_SCORE
            );
        }

        assertEq(
            hub.targetTopCount(),
            10
        );

        assertTrue(
            hub.isTopTenPercent(_refAddr(0))
        );

        assertFalse(
            hub.isTopTenPercent(_refAddr(10))
        );
    }

    function test_isTopTenPercent_sameScoreSameVerdict()
        public
    {
        _addVolume(
            address(0xA1),
            MIN_SCORE * 5
        );

        _addVolume(
            address(0xA2),
            MIN_SCORE * 5
        );

        for (uint256 i; i < 8; ++i) {
            _addVolume(
                _refAddr(i),
                MIN_SCORE
            );
        }

        assertEq(
            hub.isTopTenPercent(address(0xA1)),
            hub.isTopTenPercent(address(0xA2))
        );
    }

    function test_isTopTenPercent_inactiveReferrerFalse()
        public
    {
        _addVolume(
            address(0xA1),
            MIN_SCORE - 1
        );

        assertFalse(
            hub.isTopTenPercent(address(0xA1))
        );

        assertFalse(
            hub.isTopTenPercent(address(0xB2))
        );
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
            hub.bucketForScore(lo),
            hub.bucketForScore(hi)
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
                keccak256(
                    abi.encode(_seed, i)
                )
            );

            address actor = actors[roll % 4];

            if ((roll >> 8) % 2 == 0) {
                _addVolume(
                    actor,
                    bound(roll >> 16, 0, MIN_SCORE * 4)
                );
            } else {
                uint256 current = hub.globalReferredScore(
                    actor
                );

                _removeVolume(
                    actor,
                    bound(roll >> 16, 0, current)
                );
            }
        }

        assertEq(
            hub.prefixCount(BUCKETS),
            hub.activeReferrerCount()
        );

        for (uint256 i; i < 4; ++i) {
            uint256 score = hub.globalReferredScore(
                actors[i]
            );

            assertEq(
                hub.referrerBucket(actors[i]),
                hub.bucketForScore(score)
            );
        }
    }
}
