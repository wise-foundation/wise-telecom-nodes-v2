// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ReferralTopDecileHarness} from "./ReferralTopDecileHarness.sol";

/**
 * @dev Gas-bound proof for ReferralTopDecile. Five tracker instances are
 * populated with 0 / 10 / 100 / 1,000 / 10,000 referrers from the same
 * seeded keccak stream (octaves 0..19, so buckets 2047/2048 stay free for
 * crafted worst-case referrers). Forge runs setUp and each test as
 * separate transactions, so EIP-2929 access lists reset per test; because
 * every instance is a distinct address, one test function can take one
 * fully-cold measurement per instance in a single transaction and compare
 * them directly. Measurements are gasleft() deltas around a raw call
 * (payload encoded outside the window, logging strictly after), which
 * include the constant call overhead uniformly in every cell and exclude
 * end-of-transaction refunds — gross worst-case gas, the right metric for
 * an upper bound.
 *
 * Worst cases measured: query walk from Fenwick index 2047 (popcount 11,
 * the maximum node count for a prefix sum; isTopTenPercent reads
 * prefixSum(bucket - 1), so the crafted worst-case referrer sits in
 * bucket 2048); update walk from index 1 (the unique 12-node ascent
 * 1,2,4,...,2048); bucket move walk(1) union walk(1025) sharing only
 * node 2048 (23 writes over 22 distinct slots).
 * The gross-gas worst MOVE is the DOWNWARD direction 1025 -> 1 into a
 * virgin low chain, because only then does the 12-node walk(1) sit on the
 * add side where zero-to-nonzero SSTOREs (~22.1k each) land; the populated
 * fixtures cannot represent that state (MOVER and LEAVER occupy walk(1)
 * everywhere), so it is measured on tDown, a dedicated instance holding
 * exactly one referrer at bucket 1025.
 * Update gas is occupancy-dependent (zero-to-nonzero nodes cost ~22.1k vs
 * ~5k), so updates are MOST expensive on the empty tree and get cheaper as
 * N grows — the headline flatness assertions are gas(N=10k) within a small
 * epsilon of gas(N=10) for queries, and gas(N=10k) <= gas(N=10) + epsilon
 * for updates, plus hard constant ceilings enforced on every CI run.
 */
contract ReferralTopDecileGasTest is Test {

    uint256 internal constant MIN_SCORE = 1_000 * 1e6;

    uint256 internal constant BUCKETS = 2_048;

    uint256 internal constant QUERY_GAS_CEILING = 45_000;

    uint256 internal constant ACTIVATION_GAS_CEILING = 430_000;

    uint256 internal constant MOVE_GAS_CEILING = 405_000;

    uint256 internal constant SAME_BUCKET_GAS_CEILING = 18_000;

    uint256 internal constant DEACTIVATION_GAS_CEILING = 110_000;

    uint256 internal constant QUERY_BAND = 500;

    uint256 internal constant UPDATE_BAND = 1_000;

    address internal constant WORST_2048 = address(0xBEE2);

    address internal constant MOVER = address(0xBEE3);

    address internal constant SITTER = address(0xBEE4);

    address internal constant LEAVER = address(0xBEE5);

    address internal constant DOWN_MOVER = address(0xBEE6);

    address internal constant FRESH = address(0xF9E5);

    ReferralTopDecileHarness internal t0;

    ReferralTopDecileHarness internal t10;

    ReferralTopDecileHarness internal t100;

    ReferralTopDecileHarness internal t1k;

    ReferralTopDecileHarness internal t10k;

    ReferralTopDecileHarness internal tDown;

    uint256 internal score2048;

    uint256 internal score1025;

    function setUp()
        public
    {
        t0 = new ReferralTopDecileHarness();
        t10 = new ReferralTopDecileHarness();
        t100 = new ReferralTopDecileHarness();
        t1k = new ReferralTopDecileHarness();
        t10k = new ReferralTopDecileHarness();

        score2048 = _scoreForBucket(2_048);
        score1025 = _scoreForBucket(1_025);

        _populate(t10, 10);
        _populate(t100, 100);
        _populate(t1k, 1_000);
        _populate(t10k, 10_000);

        _craft(t10);
        _craft(t100);
        _craft(t1k);
        _craft(t10k);

        tDown = new ReferralTopDecileHarness();

        tDown.addVolume(
            DOWN_MOVER,
            score1025
        );
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

            if (t0.bucketForScore(mid) >= _bucket) {
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

    function _populate(
        ReferralTopDecileHarness _t,
        uint256 _n
    )
        internal
    {
        for (uint256 i; i < _n; ++i) {
            uint256 roll = uint256(
                keccak256(abi.encode("fenwick.score", i))
            );

            uint256 exponent = roll % 20;

            uint256 offset = (roll >> 16) % (MIN_SCORE << exponent);

            _t.addVolume(
                _refAddr(i),
                (MIN_SCORE << exponent) + offset
            );
        }
    }

    function _craft(
        ReferralTopDecileHarness _t
    )
        internal
    {
        _t.addVolume(
            WORST_2048,
            score2048
        );

        _t.addVolume(
            MOVER,
            MIN_SCORE
        );

        _t.addVolume(
            SITTER,
            MIN_SCORE << 10
        );

        _t.addVolume(
            LEAVER,
            MIN_SCORE
        );
    }

    function _measure(
        address _target,
        bytes memory _payload
    )
        internal
        returns (uint256)
    {
        uint256 before = gasleft();

        (bool ok, ) = _target.call(_payload);

        uint256 used = before - gasleft();

        assertTrue(ok);

        return used;
    }

    function _band(
        uint256[4] memory _g
    )
        internal
        pure
        returns (uint256 lo, uint256 hi)
    {
        lo = type(uint256).max;

        for (uint256 i; i < 4; ++i) {
            if (_g[i] < lo) {
                lo = _g[i];
            }

            if (_g[i] > hi) {
                hi = _g[i];
            }
        }
    }

    function _logRow(
        string memory _label,
        uint256[4] memory _g,
        uint256 _ceiling
    )
        internal
        view
    {
        console.log(
            string.concat(
                "GAS_TABLE|",
                _label,
                "|",
                vm.toString(_g[0]),
                "|",
                vm.toString(_g[1]),
                "|",
                vm.toString(_g[2]),
                "|",
                vm.toString(_g[3]),
                "|",
                vm.toString(_ceiling)
            )
        );
    }

    // ---- Query gas: the O(1) proof ----

    function test_gas_isTopTenPercent_worstBucket()
        public
    {
        bytes memory payload = abi.encodeCall(
            t0.isTopTenPercent,
            (WORST_2048)
        );

        uint256[4] memory g = [
            _measure(address(t10), payload),
            _measure(address(t100), payload),
            _measure(address(t1k), payload),
            _measure(address(t10k), payload)
        ];

        (uint256 lo, uint256 hi) = _band(g);

        assertLe(hi - lo, QUERY_BAND);
        assertLe(hi, QUERY_GAS_CEILING);

        _logRow(
            "isTopTenPercent (worst-case bucket 2048)",
            g,
            QUERY_GAS_CEILING
        );
    }

    function test_gas_isTopTenPercent_typical()
        public
    {
        uint256[4] memory g = [
            _measure(
                address(t10),
                abi.encodeCall(
                    t0.isTopTenPercent,
                    (_refAddr(5))
                )
            ),
            _measure(
                address(t100),
                abi.encodeCall(
                    t0.isTopTenPercent,
                    (_refAddr(50))
                )
            ),
            _measure(
                address(t1k),
                abi.encodeCall(
                    t0.isTopTenPercent,
                    (_refAddr(500))
                )
            ),
            _measure(
                address(t10k),
                abi.encodeCall(
                    t0.isTopTenPercent,
                    (_refAddr(5_000))
                )
            )
        ];

        (, uint256 hi) = _band(g);

        assertLe(hi, QUERY_GAS_CEILING);

        _logRow(
            "isTopTenPercent (typical mid-population referrer)",
            g,
            QUERY_GAS_CEILING
        );
    }

    // ---- Update gas tiers ----

    function test_gas_addVolume_firstActivation()
        public
    {
        bytes memory payload = abi.encodeCall(
            t0.addVolume,
            (FRESH, MIN_SCORE)
        );

        uint256 gEmpty = _measure(address(t0), payload);

        uint256[4] memory g = [
            _measure(address(t10), payload),
            _measure(address(t100), payload),
            _measure(address(t1k), payload),
            _measure(address(t10k), payload)
        ];

        assertLe(g[3], g[0] + UPDATE_BAND);
        assertLe(g[0], gEmpty);
        assertLe(g[1], gEmpty);
        assertLe(g[2], gEmpty);
        assertLe(g[3], gEmpty);
        assertLe(gEmpty, ACTIVATION_GAS_CEILING);

        _logRow(
            "addVolume (first activation, bucket 1)",
            g,
            ACTIVATION_GAS_CEILING
        );

        console.log(
            string.concat(
                "GAS_NOTE|addVolume first activation on EMPTY tree (N=0): ",
                vm.toString(gEmpty),
                " gas (true worst case: all 12 Fenwick nodes zero)"
            )
        );
    }

    function test_gas_addVolume_bucketMove()
        public
    {
        bytes memory payload = abi.encodeCall(
            t0.addVolume,
            (MOVER, score1025 - MIN_SCORE)
        );

        uint256[4] memory g = [
            _measure(address(t10), payload),
            _measure(address(t100), payload),
            _measure(address(t1k), payload),
            _measure(address(t10k), payload)
        ];

        assertLe(g[3], g[0] + UPDATE_BAND);

        (, uint256 hi) = _band(g);

        assertLe(hi, MOVE_GAS_CEILING);

        _logRow(
            "addVolume (bucket move 1 -> 1025, 22 distinct nodes)",
            g,
            MOVE_GAS_CEILING
        );
    }

    function test_gas_addVolume_sameBucket()
        public
    {
        bytes memory payload = abi.encodeCall(
            t0.addVolume,
            (SITTER, 1)
        );

        uint256[4] memory g = [
            _measure(address(t10), payload),
            _measure(address(t100), payload),
            _measure(address(t1k), payload),
            _measure(address(t10k), payload)
        ];

        (uint256 lo, uint256 hi) = _band(g);

        assertLe(hi - lo, QUERY_BAND);
        assertLe(hi, SAME_BUCKET_GAS_CEILING);

        _logRow(
            "addVolume (same bucket, zero tree ops)",
            g,
            SAME_BUCKET_GAS_CEILING
        );
    }

    function test_gas_removeVolume_worstBucketMoveDown()
        public
    {
        bytes memory payload = abi.encodeCall(
            t0.removeVolume,
            (DOWN_MOVER, score1025 - MIN_SCORE)
        );

        uint256 gDown = _measure(address(tDown), payload);

        assertLe(gDown, MOVE_GAS_CEILING);

        console.log(
            string.concat(
                "GAS_NOTE|removeVolume worst-case DOWNWARD move 1025 -> 1 ",
                "(virgin low chain, 11 zero->nonzero node writes): ",
                vm.toString(gDown),
                " gas"
            )
        );
    }

    function test_gas_removeVolume_deactivation()
        public
    {
        bytes memory payload = abi.encodeCall(
            t0.removeVolume,
            (LEAVER, 1)
        );

        uint256[4] memory g = [
            _measure(address(t10), payload),
            _measure(address(t100), payload),
            _measure(address(t1k), payload),
            _measure(address(t10k), payload)
        ];

        assertLe(g[3], g[0] + UPDATE_BAND);

        (, uint256 hi) = _band(g);

        assertLe(hi, DEACTIVATION_GAS_CEILING);

        _logRow(
            "removeVolume (deactivation, bucket 1, pre-refund)",
            g,
            DEACTIVATION_GAS_CEILING
        );
    }
}
