// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

/**
 * @dev ReferralTopDecile — self-contained practice model for the upcoming
 * referral ranking feature. NOT production code and NOT wired into the
 * diamond; it lives under test/ (petdiamond precedent) so the mechanics can
 * be rehearsed and gas-profiled before a real facet is designed.
 *
 * Problem: answer "is referrer X in the top 10% by referred volume?" onchain
 * without ever looping over referrers, so the gas cost has a hard upper
 * bound that is independent of the referrer population size N.
 *
 * Mechanism: every referrer has a cumulative 6-decimal USD score
 * (referralScore). Referrers with score >= MIN_ACTIVE_SCORE (1,000 USD) are
 * "active" and counted in a histogram of BUCKET_COUNT = 2,048 fixed,
 * deploy-time-immutable score buckets: 32 power-of-two octaves
 * ([MIN * 2^e, MIN * 2^(e+1)) for e in 0..31), each split linearly into 64
 * sub-buckets computed on the raw score offset — full 64-way resolution in
 * every octave, including octave 0 where referrer density is highest.
 * Scores at or beyond MIN * 2^32 clamp monotonically into the top bucket.
 * The mapping is monotone in score, so bucket order is rank order.
 *
 * A classic 1-indexed Fenwick tree (binary indexed tree) over the bucket
 * counts makes both the histogram update and the rank query logarithmic in
 * the bucket count. Bucket ids double as Fenwick indices (1..2048); id 0 is
 * the inactive sentinel stored in referrerBucket, which also serves as the
 * activation flag. The all-zeros genesis state is a valid empty tree, so no
 * constructor is needed.
 *
 * Gas bound, by construction: every loop in this contract has a
 * compile-time-constant iteration bound. The Fenwick ascent
 * (i += lowbit(i)) visits at most FENWICK_ADD_STEPS = log2(2048) + 1 = 12
 * nodes (the unique worst chain starts at index 1: 1,2,4,...,2048); the
 * prefix-sum descent (i -= lowbit(i)) visits popcount(index) <= 11 nodes
 * (worst start: index 2047 = 0b111_1111_1111). The 11-step budget is
 * sufficient only for indices <= BUCKET_COUNT, which is why prefixCount
 * rejects larger inputs instead of returning a truncated sum — every
 * internal caller passes referrerBucket values already inside the range.
 * Because the tree size is a
 * power of two, every ascent terminates at node 2048, so a bucket move
 * (remove + add) touches at most 12 + 11 = 23 node writes over 22 distinct
 * slots. Worst-case storage ops per external function:
 * - isTopTenPercent: 2 bookkeeping SLOADs (referrerBucket,
 *   activeReferrerCount) + at most 11 Fenwick SLOADs (the query reads
 *   prefixSum(bucket - 1); the worst walk starts at index 2047, reached
 *   by a referrer in bucket 2048), zero SSTOREs.
 * - addVolume / removeVolume: 2 pre-SLOADs + score SSTORE + bucket SSTORE
 *   + at most 23 Fenwick node read-modify-writes (bucket move tier), or 12
 *   plus the activeReferrerCount RMW (activation / deactivation tiers), or
 *   zero tree ops (same-bucket tier). Nothing anywhere iterates referrers.
 *
 * Top-10% semantics: target = ceil(activeReferrerCount / 10), rounded
 * DOWN at the bucket boundary. Walking buckets from the top, a bucket
 * whose members would push the qualifying count past target is excluded
 * wholesale — bucket granularity cannot order referrers inside one
 * bucket, so the set never overshoots 10%; it can undershoot. In
 * predicate form: qualify when the count of referrers at or above the
 * caller's bucket fits within target (atOrAbove <= target), so an exact
 * fit counts and only a straddling bucket is cut. Worked example
 * (occupancy from the top: 20, 30, 120; N = 1,000; target = 100): the
 * 50 referrers in the top two buckets qualify; the 120 in the third
 * bucket would overshoot and are excluded. Corollary: if all N
 * referrers tie in one bucket and N > target, nobody qualifies — that
 * is the intended round-down semantics, not a bug.
 *
 * Storage choices: the tree is a mapping rather than uint256[2049] because
 * this rehearses a diamond facet — a mapping occupies one declared slot in
 * a declarations chain while a fixed array would occupy 2,049 contiguous
 * slots and dominate the layout snapshot. The per-node cost difference
 * (keccak vs add, ~40 gas per access) is noise next to the SSTOREs.
 * referrerBucket caches the occupied Fenwick index instead of recomputing
 * it from the score so removal always decrements exactly the node that was
 * incremented, even if the bucket formula ever drifted between writes.
 *
 * Threat notes for the real feature: top-10% is a relative rank, so sybil
 * wallets holding exactly MIN_ACTIVE_SCORE inflate activeReferrerCount and
 * therefore the target; rewards must be tied to score, never a flat amount
 * per qualifying wallet. Score writes here are permissionless because only
 * the test suite drives this contract — a real facet would only accrue
 * volume from its deposit path. Changing the bucket scheme after data
 * exists requires a new epoch or a full migration; it is deliberately
 * compile-time-frozen here. No external calls exist, so there is no
 * reentrancy surface.
 */
contract ReferralTopDecile {

    uint256 internal constant MIN_ACTIVE_SCORE = 1_000 * 1e6;

    uint256 internal constant SUB_BUCKETS = 64;

    uint256 internal constant EXPONENT_COUNT = 32;

    uint256 internal constant BUCKET_COUNT = 2_048;

    uint256 internal constant FENWICK_ADD_STEPS = 12;

    uint256 internal constant FENWICK_SUM_STEPS = 11;

    uint256 internal constant TOP_DIVISOR = 10;

    uint256 public activeReferrerCount;

    mapping(address => uint256) public referralScore;

    mapping(address => uint256) public referrerBucket;

    mapping(uint256 => uint256) internal fenwickTree;

    event ScoreUpdated(
        address indexed referrer,
        uint256 oldScore,
        uint256 newScore,
        uint256 oldBucket,
        uint256 newBucket
    );

    error ZeroAddress();

    error InsufficientScore();

    error InvalidBucket();

    function addVolume(
        address _referrer,
        uint256 _amount
    )
        external
        virtual
    {
        require(
            _referrer != address(0),
            ZeroAddress()
        );

        _setScore(
            _referrer,
            referralScore[_referrer] + _amount
        );
    }

    function removeVolume(
        address _referrer,
        uint256 _amount
    )
        external
        virtual
    {
        uint256 currentScore = referralScore[_referrer];

        require(
            _amount <= currentScore,
            InsufficientScore()
        );

        _setScore(
            _referrer,
            currentScore - _amount
        );
    }

    function isTopTenPercent(
        address _referrer
    )
        external
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

    function _setScore(
        address _referrer,
        uint256 _newScore
    )
        internal
    {
        uint256 oldScore = referralScore[_referrer];

        if (oldScore == _newScore) {
            return;
        }

        uint256 oldBucket = referrerBucket[_referrer];

        uint256 newBucket = _newScore >= MIN_ACTIVE_SCORE
            ? _bucketFor(_newScore)
            : 0;

        referralScore[_referrer] = _newScore;

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
