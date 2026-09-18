// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {ReferralRegistry} from "../../../src/registry/pending/ReferralRegistry.sol";
import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev Minimal external wrapper over the internal {CohortWeeks}
 * bridge-carry codec so the pure pack-and-validate lemmas can be
 * driven as single external calls by both engines (Foundry fuzzing
 * and Kontrol/KEVM symbolic execution). `exposedPackReferredCarry`
 * packs a referred envelope exactly the way the source vault does:
 * trackedDelta equals the lane sum, the origin sync key rides word1,
 * the year aggregates share word2 (year-1 low half, year-2 high
 * half) and the mature aggregate sits in word3's low half. Nothing
 * here alters codec logic; every function forwards verbatim into
 * the library internals under test.
 */
contract SyncMergeCodecHarness {

    function exposedPackReferredCarry(
        address _referrer,
        uint256 _assignedAt,
        uint256 _rank,
        uint256 _year1,
        uint256 _year2,
        uint256 _mature
    )
        external
        pure
        returns (bytes memory)
    {
        return CohortWeeks.packBridgeCarry(
            CohortWeeks.packBridgeCarryEnvelope(
                _referrer
            ),
            CohortWeeks.packBridgeCarryTracked(
                _year1 + _year2 + _mature,
                _assignedAt,
                _rank
            ),
            _year1 | (_year2 << CohortWeeks.CARRY_HALF_SHIFT),
            _mature
        );
    }

    function exposedBridgeCarryValid(
        bytes memory _data,
        uint256 _mintAmount
    )
        external
        pure
        returns (bool)
    {
        return CohortWeeks.bridgeCarryValid(
            _data,
            _mintAmount
        );
    }
}

/**
 * @dev MRG property family: dual-engine properties (Foundry fuzzing
 * today, Kontrol/KEVM symbolic execution on the SAME functions) for
 * the cross-chain min-merge core of {ReferralRegistry} plus the two
 * pure codec lemmas of {CohortWeeks} the bridge carry leans on.
 *
 * The merge register must behave as a state-based convergent
 * replicated register keyed by the packed sync key
 * `(assignedAt << 8) | rank`. MRG1: a merge never increases the
 * stored key and never clears an assignment. MRG2: the referrer
 * changes only under a strictly smaller incoming key, which is then
 * stored verbatim; otherwise both fields stay untouched. MRG3:
 * merging one pair twice equals merging it once. MRG4: two pairs
 * with distinct keys converge to the identical (referrer, key) in
 * either delivery order; exact key ties converge on the key alone:
 * the referrer tie-break is keep-first-delivery by design (the
 * no-op path that emits {SyncKeyCollision}), so the tie variant
 * pins that actual behavior instead of claiming full convergence.
 * MRG5: an equal-key different-referrer merge leaves referrer and
 * key untouched. MRG6: adopting into an empty slot stores exactly
 * the incoming origin key, never a local re-stamp from
 * block.timestamp or the local chain rank. MRG7: every honestly
 * packed referred bridge-carry payload passes
 * {CohortWeeks.bridgeCarryValid} for any mint amount at or above its
 * own lane-sum ceiling and fails it whenever the carried delta
 * exceeds the minted amount. MRG8: per-component floor scaling can
 * never sum above the floor-scaled total: the arithmetic reason an
 * honestly floor-scaled payload always satisfies the MRG7 ceiling.
 *
 * Kontrol tractability scope (mirrors the conventions of the other
 * dual-engine suites in test/diamond/kontrol and test/fenwick):
 * actor, vault and referrer addresses are concrete literals so every
 * mapping slot stays concrete for the symbolic engine;
 * block.timestamp is warped to one concrete base; assignedAt and
 * rank are the symbolic inputs, bounded inside the validation floor
 * the merge itself enforces: assignedAt in (0, now + 1 hour], rank
 * in [0, 15]; codec lanes are bounded to the 80-bit lane mask so all
 * intermediate sums stay far below 2^128. Every property drives at
 * most one state-mutating external call per assertion step, entering
 * through the allowlisted-vault `mergeReferrer` entrance;
 * `ccipReceive` reaches the identical internal merge after its
 * transport checks, so the merge algebra proven here covers both
 * entrances. The order-convergence properties compare two
 * independently deployed registries instead of rolling state back,
 * keeping each execution path linear for the prover.
 */
contract SyncMergePropertiesTest is Test {

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant MAX_ASSIGNED_AT = BASE_TIME + 1 hours;

    uint256 internal constant MID_ASSIGNED_AT = 1_500 weeks;

    uint256 internal constant MAX_RANK = 15;

    address internal constant USER = address(0xA1);

    address internal constant REF_A = address(0xB1);

    address internal constant REF_B = address(0xB2);

    address internal constant DRIVER = address(0xD1);

    ReferralRegistry internal registry;

    ReferralRegistry internal registryMirror;

    SyncMergeCodecHarness internal codec;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        registry = new ReferralRegistry(
            address(this),
            0
        );

        registryMirror = new ReferralRegistry(
            address(this),
            0
        );

        codec = new SyncMergeCodecHarness();

        registry.setAllowedVault(
            DRIVER,
            true
        );

        registryMirror.setAllowedVault(
            DRIVER,
            true
        );
    }

    // ---- helpers ----

    function _merge(
        ReferralRegistry _target,
        address _referrer,
        uint256 _assignedAt,
        uint256 _rank
    )
        internal
    {
        vm.prank(
            DRIVER
        );

        _target.mergeReferrer(
            USER,
            _referrer,
            _assignedAt,
            _rank
        );
    }

    function _packKey(
        uint256 _assignedAt,
        uint256 _rank
    )
        internal
        pure
        returns (uint256)
    {
        return (_assignedAt << 8) | _rank;
    }

    // ---- MRG merge algebra ----

    function testFuzz_MRG1_mergedKeyNeverIncreases(
        uint256 _seedAt,
        uint256 _seedRank,
        uint256 _incomingAt,
        uint256 _incomingRank,
        bool _sameReferrer
    )
        public
    {
        _seedAt = bound(
            _seedAt,
            1,
            MAX_ASSIGNED_AT
        );

        _seedRank = bound(
            _seedRank,
            0,
            MAX_RANK
        );

        _incomingAt = bound(
            _incomingAt,
            1,
            MAX_ASSIGNED_AT
        );

        _incomingRank = bound(
            _incomingRank,
            0,
            MAX_RANK
        );

        _merge(
            registry,
            REF_A,
            _seedAt,
            _seedRank
        );

        uint256 preKey = registry.referrerKey(
            USER
        );

        _merge(
            registry,
            _sameReferrer
                ? REF_A
                : REF_B,
            _incomingAt,
            _incomingRank
        );

        uint256 postKey = registry.referrerKey(
            USER
        );

        assert(postKey <= preKey);
        assert(postKey != 0);
        assert(registry.referrerOf(USER) != address(0));
    }

    function testFuzz_MRG2_referrerChangeImpliesStrictKeyDecrease(
        uint256 _seedAt,
        uint256 _seedRank,
        uint256 _incomingAt,
        uint256 _incomingRank
    )
        public
    {
        _seedAt = bound(
            _seedAt,
            1,
            MAX_ASSIGNED_AT
        );

        _seedRank = bound(
            _seedRank,
            0,
            MAX_RANK
        );

        _incomingAt = bound(
            _incomingAt,
            1,
            MAX_ASSIGNED_AT
        );

        _incomingRank = bound(
            _incomingRank,
            0,
            MAX_RANK
        );

        _merge(
            registry,
            REF_A,
            _seedAt,
            _seedRank
        );

        uint256 preKey = _packKey(
            _seedAt,
            _seedRank
        );

        uint256 incomingKey = _packKey(
            _incomingAt,
            _incomingRank
        );

        _merge(
            registry,
            REF_B,
            _incomingAt,
            _incomingRank
        );

        address postReferrer = registry.referrerOf(
            USER
        );

        uint256 postKey = registry.referrerKey(
            USER
        );

        if (postReferrer == REF_B) {
            assert(postKey == incomingKey);
            assert(postKey < preKey);
        } else {
            assert(postReferrer == REF_A);
            assert(postKey == preKey);
        }
    }

    function testFuzz_MRG3_sameMergeTwiceEqualsOnce(
        uint256 _seedAt,
        uint256 _seedRank,
        uint256 _incomingAt,
        uint256 _incomingRank,
        bool _seedFirst
    )
        public
    {
        _seedAt = bound(
            _seedAt,
            1,
            MAX_ASSIGNED_AT
        );

        _seedRank = bound(
            _seedRank,
            0,
            MAX_RANK
        );

        _incomingAt = bound(
            _incomingAt,
            1,
            MAX_ASSIGNED_AT
        );

        _incomingRank = bound(
            _incomingRank,
            0,
            MAX_RANK
        );

        if (_seedFirst) {
            _merge(
                registry,
                REF_A,
                _seedAt,
                _seedRank
            );
        }

        _merge(
            registry,
            REF_B,
            _incomingAt,
            _incomingRank
        );

        address referrerOnce = registry.referrerOf(
            USER
        );

        uint256 keyOnce = registry.referrerKey(
            USER
        );

        _merge(
            registry,
            REF_B,
            _incomingAt,
            _incomingRank
        );

        assert(registry.referrerOf(USER) == referrerOnce);
        assert(registry.referrerKey(USER) == keyOnce);
    }

    function testFuzz_MRG4_distinctKeysCommute(
        uint256 _earlyAt,
        uint256 _earlyRank,
        uint256 _lateAt,
        uint256 _lateRank
    )
        public
    {
        _earlyAt = bound(
            _earlyAt,
            1,
            MID_ASSIGNED_AT
        );

        _earlyRank = bound(
            _earlyRank,
            0,
            MAX_RANK
        );

        _lateAt = bound(
            _lateAt,
            MID_ASSIGNED_AT + 1,
            MAX_ASSIGNED_AT
        );

        _lateRank = bound(
            _lateRank,
            0,
            MAX_RANK
        );

        _merge(
            registry,
            REF_A,
            _earlyAt,
            _earlyRank
        );

        _merge(
            registry,
            REF_B,
            _lateAt,
            _lateRank
        );

        _merge(
            registryMirror,
            REF_B,
            _lateAt,
            _lateRank
        );

        _merge(
            registryMirror,
            REF_A,
            _earlyAt,
            _earlyRank
        );

        assert(registry.referrerOf(USER) == registryMirror.referrerOf(USER));
        assert(registry.referrerKey(USER) == registryMirror.referrerKey(USER));
        assert(registry.referrerOf(USER) == REF_A);
        assert(
            registry.referrerKey(USER) == _packKey(
                _earlyAt,
                _earlyRank
            )
        );
    }

    function testFuzz_MRG4_equalKeysConvergeOnKey(
        uint256 _assignedAt,
        uint256 _rank
    )
        public
    {
        _assignedAt = bound(
            _assignedAt,
            1,
            MAX_ASSIGNED_AT
        );

        _rank = bound(
            _rank,
            0,
            MAX_RANK
        );

        _merge(
            registry,
            REF_A,
            _assignedAt,
            _rank
        );

        _merge(
            registry,
            REF_B,
            _assignedAt,
            _rank
        );

        _merge(
            registryMirror,
            REF_B,
            _assignedAt,
            _rank
        );

        _merge(
            registryMirror,
            REF_A,
            _assignedAt,
            _rank
        );

        assert(registry.referrerKey(USER) == registryMirror.referrerKey(USER));
        assert(
            registry.referrerKey(USER) == _packKey(
                _assignedAt,
                _rank
            )
        );
        assert(registry.referrerOf(USER) == REF_A);
        assert(registryMirror.referrerOf(USER) == REF_B);
    }

    function testFuzz_MRG5_equalKeyDifferentReferrerKeepsLocal(
        uint256 _assignedAt,
        uint256 _rank
    )
        public
    {
        _assignedAt = bound(
            _assignedAt,
            1,
            MAX_ASSIGNED_AT
        );

        _rank = bound(
            _rank,
            0,
            MAX_RANK
        );

        _merge(
            registry,
            REF_A,
            _assignedAt,
            _rank
        );

        _merge(
            registry,
            REF_B,
            _assignedAt,
            _rank
        );

        assert(registry.referrerOf(USER) == REF_A);
        assert(
            registry.referrerKey(USER) == _packKey(
                _assignedAt,
                _rank
            )
        );
    }

    function testFuzz_MRG6_adoptStoresOriginKeyExactly(
        uint256 _assignedAt,
        uint256 _rank
    )
        public
    {
        _assignedAt = bound(
            _assignedAt,
            1,
            MAX_ASSIGNED_AT
        );

        _rank = bound(
            _rank,
            0,
            MAX_RANK
        );

        _merge(
            registry,
            REF_A,
            _assignedAt,
            _rank
        );

        assert(registry.referrerOf(USER) == REF_A);
        assert(
            registry.referrerKey(USER) == _packKey(
                _assignedAt,
                _rank
            )
        );

        (
            address referrer,
            uint256 assignedAt,
            uint256 rank
        ) = registry.getReferrerPair(
            USER
        );

        assert(referrer == REF_A);
        assert(assignedAt == _assignedAt);
        assert(rank == _rank);
    }

    // ---- MRG codec lemmas ----

    function testFuzz_MRG7_referredPayloadPassesValidation(
        uint256 _year1,
        uint256 _year2,
        uint256 _mature,
        uint256 _assignedAt,
        uint256 _rank,
        uint256 _mintAmount
    )
        public
        view
    {
        _year1 = bound(
            _year1,
            1,
            CohortWeeks.LANE_MASK_80
        );

        _year2 = bound(
            _year2,
            0,
            CohortWeeks.LANE_MASK_80
        );

        _mature = bound(
            _mature,
            0,
            CohortWeeks.LANE_MASK_80
        );

        _assignedAt = bound(
            _assignedAt,
            0,
            type(uint64).max
        );

        _rank = bound(
            _rank,
            0,
            MAX_RANK
        );

        uint256 laneSum = _year1
            + _year2
            + _mature;

        _mintAmount = bound(
            _mintAmount,
            laneSum,
            laneSum + (1 << 96)
        );

        bytes memory data = codec.exposedPackReferredCarry(
            REF_A,
            _assignedAt,
            _rank,
            _year1,
            _year2,
            _mature
        );

        assert(
            codec.exposedBridgeCarryValid(
                data,
                laneSum
            ) == true
        );

        assert(
            codec.exposedBridgeCarryValid(
                data,
                _mintAmount
            ) == true
        );
    }

    function testFuzz_MRG7_trackedDeltaAboveMintRejected(
        uint256 _year1,
        uint256 _year2,
        uint256 _mature,
        uint256 _assignedAt,
        uint256 _rank,
        uint256 _mintAmount
    )
        public
        view
    {
        _year1 = bound(
            _year1,
            1,
            CohortWeeks.LANE_MASK_80
        );

        _year2 = bound(
            _year2,
            0,
            CohortWeeks.LANE_MASK_80
        );

        _mature = bound(
            _mature,
            0,
            CohortWeeks.LANE_MASK_80
        );

        _assignedAt = bound(
            _assignedAt,
            0,
            type(uint64).max
        );

        _rank = bound(
            _rank,
            0,
            MAX_RANK
        );

        uint256 laneSum = _year1
            + _year2
            + _mature;

        _mintAmount = bound(
            _mintAmount,
            0,
            laneSum - 1
        );

        bytes memory data = codec.exposedPackReferredCarry(
            REF_A,
            _assignedAt,
            _rank,
            _year1,
            _year2,
            _mature
        );

        assert(
            codec.exposedBridgeCarryValid(
                data,
                _mintAmount
            ) == false
        );
    }

    function testFuzz_MRG8_flooredPartsNeverExceedFlooredTotal(
        uint256 _a,
        uint256 _b,
        uint256 _c,
        uint256 _num,
        uint256 _den
    )
        public
        pure
    {
        _a = bound(
            _a,
            0,
            CohortWeeks.LANE_MASK_80
        );

        _b = bound(
            _b,
            0,
            CohortWeeks.LANE_MASK_80
        );

        _c = bound(
            _c,
            0,
            CohortWeeks.LANE_MASK_80
        );

        _num = bound(
            _num,
            0,
            1_000_000_000_000
        );

        _den = bound(
            _den,
            1,
            1_000_000_000_000
        );

        uint256 scaledParts = _a * _num / _den
            + _b * _num / _den
            + _c * _num / _den;

        uint256 scaledTotal = (_a + _b + _c) * _num / _den;

        assert(scaledParts <= scaledTotal);
    }
}
