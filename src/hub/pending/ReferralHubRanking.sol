// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralHubDeclarations} from "./ReferralHubDeclarations.sol";

/**
 * @dev Fenwick top-decile ranking layer — a faithful port of the
 * proven sandbox `test/fenwick/ReferralTopDecile.sol` (review this
 * file as a diff against it): 2,048 fixed buckets (32 power-of-two
 * octaves × 64 linear sub-buckets over 6-decimal USD scores, monotone
 * so bucket order is rank order), a classic 1-indexed Fenwick tree
 * over the bucket counts, and round-down decile semantics (a bucket
 * straddling the ceil(N/10) boundary is excluded wholesale; an exact
 * fit counts). Every loop keeps the sandbox's compile-time bounds:
 * ascent ≤ 12 nodes, prefix descent ≤ 11, a bucket move ≤ 23 node
 * writes. `prefixCount` rejects indices above BUCKET_COUNT instead of
 * returning a truncated sum because the 11-step budget only covers
 * the valid range.
 *
 * Deliberate deviations from the sandbox, both port hardenings: the
 * permissionless `addVolume`/`removeVolume` test drivers are REMOVED
 * — on the hub every score write flows through the reporter-gated
 * choke point in {ReferralHubIntake}, which is also what lets the
 * checkpoint/cutoff discipline of {ReferralHubCheckpoints} hold; and
 * the driven score is `globalReferredScore` (the Σ-of-source-reports
 * aggregate), never a locally-owned counter. Constants live in
 * {ReferralHubDeclarations}. `referrerBucket` caches the occupied
 * Fenwick index so removal always decrements exactly the node that
 * was incremented. The bucket scheme is compile-time-frozen: changing
 * it after data exists needs a new epoch or full migration.
 */
abstract contract ReferralHubRanking is ReferralHubDeclarations {

    function isTopTenPercent(
        address _referrer
    )
        public
        view
        returns (bool)
    {
        uint256 bucket = referrerBucket[_referrer];

        if (bucket == 0) {
            return false;
        }

        uint256 active = activeReferrerCount;

        uint256 atOrAbove = active - _prefixSum(bucket - 1);

        return atOrAbove <= _targetTopCount(active);
    }

    function targetTopCount()
        external
        view
        returns (uint256)
    {
        return _targetTopCount(
            activeReferrerCount
        );
    }

    function bucketForScore(
        uint256 _score
    )
        public
        pure
        returns (uint256)
    {
        if (_score < MIN_ACTIVE_SCORE) {
            return 0;
        }

        return _bucketFor(
            _score
        );
    }

    function prefixCount(
        uint256 _bucket
    )
        external
        view
        returns (uint256)
    {
        require(
            _bucket <= BUCKET_COUNT,
            InvalidBucket()
        );

        return _prefixSum(
            _bucket
        );
    }

    function _setReferredScore(
        address _referrer,
        uint256 _newScore
    )
        internal
    {
        uint256 oldScore = globalReferredScore[_referrer];

        if (oldScore == _newScore) {
            return;
        }

        uint256 oldBucket = referrerBucket[_referrer];

        uint256 newBucket = _newScore >= MIN_ACTIVE_SCORE
            ? _bucketFor(_newScore)
            : 0;

        globalReferredScore[_referrer] = _newScore;

        if (oldBucket != newBucket) {

            if (oldBucket == 0) {
                activeReferrerCount += 1;
                _fenwickAdd(
                    newBucket
                );
            } else if (newBucket == 0) {
                activeReferrerCount -= 1;
                _fenwickSub(
                    oldBucket
                );
            } else {
                _fenwickSub(
                    oldBucket
                );
                _fenwickAdd(
                    newBucket
                );
            }

            referrerBucket[_referrer] = newBucket;
        }

        emit ScoreUpdated(
            _referrer,
            oldScore,
            _newScore,
            oldBucket,
            newBucket
        );
    }

    function _targetTopCount(
        uint256 _active
    )
        internal
        pure
        returns (uint256)
    {
        return (_active + TOP_DIVISOR - 1) / TOP_DIVISOR;
    }

    function _bucketFor(
        uint256 _score
    )
        internal
        pure
        returns (uint256)
    {
        uint256 normalized = _score / MIN_ACTIVE_SCORE;

        uint256 exponent = _msb(
            normalized
        );

        if (exponent >= EXPONENT_COUNT) {
            return BUCKET_COUNT;
        }

        uint256 lowerBound = MIN_ACTIVE_SCORE << exponent;

        uint256 subBucket = (_score - lowerBound) * SUB_BUCKETS / lowerBound;

        return exponent * SUB_BUCKETS + subBucket + 1;
    }

    function _msb(
        uint256 _value
    )
        internal
        pure
        returns (uint256)
    {
        uint256 value = _value;

        uint256 result;

        if (value >= 1 << 128) {
            value >>= 128;
            result += 128;
        }

        if (value >= 1 << 64) {
            value >>= 64;
            result += 64;
        }

        if (value >= 1 << 32) {
            value >>= 32;
            result += 32;
        }

        if (value >= 1 << 16) {
            value >>= 16;
            result += 16;
        }

        if (value >= 1 << 8) {
            value >>= 8;
            result += 8;
        }

        if (value >= 1 << 4) {
            value >>= 4;
            result += 4;
        }

        if (value >= 1 << 2) {
            value >>= 2;
            result += 2;
        }

        if (value >= 2) {
            result += 1;
        }

        return result;
    }

    function _lowbit(
        uint256 _index
    )
        internal
        pure
        returns (uint256)
    {
        unchecked {
            return _index & (~_index + 1);
        }
    }

    function _fenwickAdd(
        uint256 _index
    )
        internal
    {
        uint256 index = _index;

        for (uint256 step; step < FENWICK_ADD_STEPS; ++step) {

            fenwickTree[index] += 1;

            index += _lowbit(index);

            if (index > BUCKET_COUNT) {
                break;
            }
        }
    }

    function _fenwickSub(
        uint256 _index
    )
        internal
    {
        uint256 index = _index;

        for (uint256 step; step < FENWICK_ADD_STEPS; ++step) {

            fenwickTree[index] -= 1;

            index += _lowbit(index);

            if (index > BUCKET_COUNT) {
                break;
            }
        }
    }

    function _prefixSum(
        uint256 _index
    )
        internal
        view
        returns (uint256)
    {
        if (_index == 0) {
            return 0;
        }

        uint256 index = _index;

        uint256 sum;

        for (uint256 step; step < FENWICK_SUM_STEPS; ++step) {

            sum += fenwickTree[index];

            index -= _lowbit(index);

            if (index == 0) {
                break;
            }
        }

        return sum;
    }
}
