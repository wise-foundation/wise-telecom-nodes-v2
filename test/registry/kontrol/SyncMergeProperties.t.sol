// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {ReferralRegistry} from "../../../src/registry/pending/ReferralRegistry.sol";
import {ReferralRegistryDeclarations} from "../../../src/registry/pending/ReferralRegistryDeclarations.sol";
import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";
import {BridgeCarryTestCodec} from "../../diamond/utils/BridgeCarryTestCodec.sol";

/**
 * @dev Minimal external wrapper over the internal {CohortWeeks}
 * bridge-carry codec so the pure pack-and-validate lemmas can be
 * driven as single external calls by both engines (Foundry fuzzing
 * and Kontrol/KEVM symbolic execution). `exposedPackReferredCarry`
 * packs a referred envelope exactly the way the source vault does:
 * the envelope word carries the referrer beside the capture week
 * (the source chain's week number at capture, passed in first),
 * trackedDelta equals the lane sum, the origin sync key rides word1,
 * the year aggregates share word2 (year-1 low half, year-2 high
 * half) and the mature aggregate sits in word3's low half. Nothing
 * here alters codec logic; every function forwards verbatim into
 * the library internals under test.
 */
contract SyncMergeCodecHarness {

    function exposedPackReferredCarry(
        uint256 _captureWeek,
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
        return BridgeCarryTestCodec._pack(
            _referrer,
            CohortWeeks.BRIDGE_CARRY_VERSION,
            _captureWeek,
            _year1 + _year2 + _mature,
            _assignedAt,
            _rank,
            _year1,
            _year2,
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
        return CohortWeeks._bridgeCarryValid(
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
 * `(assignedAt << 8) | rank`. The key namespace has a floor: every
 * genuine key carries a timestamp at or above SYNC_KEY_FLOOR
 * (1_700_000_000), and a correction executed at clock T mints the
 * mirrored timestamp SYNC_KEY_MIRROR - T with the executing
 * registry's rank, where SYNC_KEY_MIRROR = 2 * SYNC_KEY_FLOOR - 1 =
 * 3_399_999_999. The merge admits a key iff
 * assignedAt + now + 1 hour >= SYNC_KEY_MIRROR, so at BASE_TIME
 * (1_814_403_600) the lowest admissible timestamp is
 * MIN_ASSIGNED_AT = 3_399_999_999 - 1_814_403_600 - 3_600 =
 * 1_585_592_799, and MID_ASSIGNED_AT = SYNC_KEY_FLOOR - 1 splits the
 * admissible range into the corrected region below the floor and the
 * genuine region at or above it. MRG0: at that clock the merge
 * adopts exactly the keys with assignedAt at or above
 * MIN_ASSIGNED_AT and reverts {SyncKeyInvalid} on every deeper one.
 * MRG1: a merge never increases the
 * stored key and never clears an assignment. MRG2: the referrer
 * changes only under a strictly smaller incoming key, which is then
 * stored verbatim; otherwise both fields stay untouched. MRG3:
 * merging one pair twice equals merging it once. MRG4: two pairs
 * with distinct keys converge to the identical (referrer, key) in
 * either delivery order; the early pair is drawn from the corrected
 * region and the late pair from the genuine region, so the same
 * proof shows a corrected key beating a genuine one in either
 * delivery order. The genuine variant draws both pairs at or above
 * the floor (the early pair at or below the base clock, the late
 * pair above it), so genuine keys commute among themselves too.
 * Exact key ties converge on the key alone:
 * the referrer tie-break is keep-first-delivery by design (the
 * no-op path that emits {SyncKeyCollision}), so the tie variant
 * pins that actual behavior instead of claiming full convergence.
 * MRG5: an equal-key different-referrer merge leaves referrer and
 * key untouched. MRG6: adopting into an empty slot stores exactly
 * the incoming origin key, never a local re-stamp from
 * block.timestamp or the local chain rank. MRG9: a correction the
 * master executes after the 3-day timelock stores exactly the
 * mirrored key with the local rank, strictly below the genuine key it
 * replaces, and no later genuine key of the old referrer (timestamp
 * at or above the floor), at any rank, can undo it. MRG9b: the
 * proposal is bound to the key held at propose, so a strictly
 * lower merge landing during the
 * timelock (a key lowering for the same referrer or a flip to any
 * referrer) kills it and execute reverts {NothingToCorrect}. MRG7:
 * every honestly
 * packed referred bridge-carry payload, at any capture week, passes
 * {CohortWeeks._bridgeCarryValid} for any mint amount at or above its
 * own lane-sum ceiling and fails it whenever the carried delta
 * exceeds the minted amount. MRG8: per-component floor scaling can
 * never sum above the floor-scaled total: the arithmetic reason an
 * honestly floor-scaled payload always satisfies the MRG7 ceiling.
 *
 * Kontrol tractability scope (mirrors the conventions of the other
 * dual-engine suites in test/diamond/kontrol):
 * actor, vault and referrer addresses are concrete literals so every
 * mapping slot stays concrete for the symbolic engine;
 * block.timestamp is warped to one concrete base; assignedAt and
 * rank are the symbolic inputs, bounded inside the validation floor
 * the merge itself enforces: assignedAt in
 * [MIN_ASSIGNED_AT, now + 1 hour], rank in [0, 3], the deployed set bound
 * the merge enforces (MRG0 alone spans [1, now + 1 hour] to pin the
 * floor edge); the codec lemmas draw the rank byte over [0, 15]; codec
 * lanes are bounded
 * to the 80-bit lane mask so all intermediate sums stay far below
 * 2^128, and the codec capture week is bounded to the envelope's
 * 32-bit capture week mask. Every
 * property drives at most one state-mutating external call per
 * assertion step, entering
 * through the allowlisted-vault `mergeReferrer` entrance (MRG9 and
 * MRG9b additionally drive the correction lane, propose then execute
 * after a concrete warp past the timelock, as the test contract is
 * each registry's master);
 * `ccipReceive` reaches the identical internal merge after its
 * transport checks, so the merge algebra proven here covers both
 * entrances. The order-convergence properties compare two
 * independently deployed registries instead of rolling state back,
 * keeping each execution path linear for the prover.
 */
contract SyncMergePropertiesTest is Test {

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant MAX_ASSIGNED_AT = BASE_TIME + 1 hours;

    uint256 internal constant SYNC_KEY_FLOOR = 1_700_000_000;

    uint256 internal constant SYNC_KEY_MIRROR = 2 * SYNC_KEY_FLOOR - 1;

    uint256 internal constant MIN_ASSIGNED_AT = 1_585_592_799;

    uint256 internal constant MID_ASSIGNED_AT = 1_699_999_999;

    uint256 internal constant EXECUTE_TIME = BASE_TIME + 3 days;

    uint256 internal constant MAX_RANK = 15;

    uint256 internal constant MAX_SYNC_RANK = 3;

    address internal constant USER = address(0xA1);

    address internal constant REF_A = address(0xB1);

    address internal constant REF_B = address(0xB2);

    address internal constant REF_C = address(0xB3);

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

    function _correctedAt(
        uint256 _at
    )
        internal
        pure
        returns (uint256)
    {
        return SYNC_KEY_MIRROR - _at;
    }

    // ---- MRG merge algebra ----

    function testFuzz_MRG0_floorExactness(
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
            MAX_SYNC_RANK
        );

        if (_assignedAt < MIN_ASSIGNED_AT) {
            vm.prank(
                DRIVER
            );

            vm.expectRevert(
                ReferralRegistryDeclarations.SyncKeyInvalid.selector
            );

            registry.mergeReferrer(
                USER,
                REF_A,
                _assignedAt,
                _rank
            );

            assert(registry.referrerOf(USER) == address(0));
            assert(registry.referrerKey(USER) == 0);

            return;
        }

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
    }

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
            MIN_ASSIGNED_AT,
            MAX_ASSIGNED_AT
        );

        _seedRank = bound(
            _seedRank,
            0,
            MAX_SYNC_RANK
        );

        _incomingAt = bound(
            _incomingAt,
            MIN_ASSIGNED_AT,
            MAX_ASSIGNED_AT
        );

        _incomingRank = bound(
            _incomingRank,
            0,
            MAX_SYNC_RANK
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

        assert(
            postKey <= preKey
        );

        assert(
            postKey != 0
        );

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
            MIN_ASSIGNED_AT,
            MAX_ASSIGNED_AT
        );

        _seedRank = bound(
            _seedRank,
            0,
            MAX_SYNC_RANK
        );

        _incomingAt = bound(
            _incomingAt,
            MIN_ASSIGNED_AT,
            MAX_ASSIGNED_AT
        );

        _incomingRank = bound(
            _incomingRank,
            0,
            MAX_SYNC_RANK
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
            assert(
                postKey == incomingKey
            );

            assert(
                postKey < preKey
            );
        } else {
            assert(
                postReferrer == REF_A
            );

            assert(
                postKey == preKey
            );
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
            MIN_ASSIGNED_AT,
            MAX_ASSIGNED_AT
        );

        _seedRank = bound(
            _seedRank,
            0,
            MAX_SYNC_RANK
        );

        _incomingAt = bound(
            _incomingAt,
            MIN_ASSIGNED_AT,
            MAX_ASSIGNED_AT
        );

        _incomingRank = bound(
            _incomingRank,
            0,
            MAX_SYNC_RANK
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
            MIN_ASSIGNED_AT,
            MID_ASSIGNED_AT
        );

        _earlyRank = bound(
            _earlyRank,
            0,
            MAX_SYNC_RANK
        );

        _lateAt = bound(
            _lateAt,
            MID_ASSIGNED_AT + 1,
            MAX_ASSIGNED_AT
        );

        _lateRank = bound(
            _lateRank,
            0,
            MAX_SYNC_RANK
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

    function testFuzz_MRG4_distinctGenuineKeysCommute(
        uint256 _earlyAt,
        uint256 _earlyRank,
        uint256 _lateAt,
        uint256 _lateRank
    )
        public
    {
        _earlyAt = bound(
            _earlyAt,
            SYNC_KEY_FLOOR,
            BASE_TIME
        );

        _earlyRank = bound(
            _earlyRank,
            0,
            MAX_SYNC_RANK
        );

        _lateAt = bound(
            _lateAt,
            BASE_TIME + 1,
            MAX_ASSIGNED_AT
        );

        _lateRank = bound(
            _lateRank,
            0,
            MAX_SYNC_RANK
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
            MIN_ASSIGNED_AT,
            MAX_ASSIGNED_AT
        );

        _rank = bound(
            _rank,
            0,
            MAX_SYNC_RANK
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
            MIN_ASSIGNED_AT,
            MAX_ASSIGNED_AT
        );

        _rank = bound(
            _rank,
            0,
            MAX_SYNC_RANK
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
            MIN_ASSIGNED_AT,
            MAX_ASSIGNED_AT
        );

        _rank = bound(
            _rank,
            0,
            MAX_SYNC_RANK
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

        assert(
            referrer == REF_A
        );

        assert(
            assignedAt == _assignedAt
        );

        assert(
            rank == _rank
        );
    }

    function testFuzz_MRG9_correctionBeatsEveryGenuineKey(
        uint256 _seedAt,
        uint256 _incomingAt,
        uint256 _incomingRank
    )
        public
    {
        _seedAt = bound(
            _seedAt,
            SYNC_KEY_FLOOR,
            MAX_ASSIGNED_AT
        );

        _merge(
            registry,
            REF_A,
            _seedAt,
            0
        );

        uint256 seededKey = registry.referrerKey(
            USER
        );

        registry.proposeCorrectReferrer(
            USER,
            REF_B
        );

        vm.warp(
            EXECUTE_TIME
        );

        registry.executeCorrectReferrer(
            USER
        );

        uint256 correctedAt = _correctedAt(
            EXECUTE_TIME
        );

        uint256 correctedKey = _packKey(
            correctedAt,
            0
        );

        assert(registry.referrerOf(USER) == REF_B);
        assert(registry.referrerKey(USER) == correctedKey);

        assert(
            correctedKey < seededKey
        );

        _incomingAt = bound(
            _incomingAt,
            SYNC_KEY_FLOOR,
            EXECUTE_TIME + 1 hours
        );

        _incomingRank = bound(
            _incomingRank,
            0,
            MAX_SYNC_RANK
        );

        _merge(
            registry,
            REF_A,
            _incomingAt,
            _incomingRank
        );

        assert(registry.referrerOf(USER) == REF_B);
        assert(registry.referrerKey(USER) == correctedKey);
    }

    function testFuzz_MRG9b_bindingKillsOvertakenProposal(
        uint256 _seedAt,
        uint256 _incomingAt,
        bool _flip
    )
        public
    {
        _seedAt = bound(
            _seedAt,
            SYNC_KEY_FLOOR,
            MAX_ASSIGNED_AT
        );

        _incomingAt = bound(
            _incomingAt,
            MIN_ASSIGNED_AT,
            _seedAt - 1
        );

        _merge(
            registry,
            REF_A,
            _seedAt,
            0
        );

        registry.proposeCorrectReferrer(
            USER,
            REF_B
        );

        _merge(
            registry,
            _flip
                ? REF_C
                : REF_A,
            _incomingAt,
            1
        );

        assert(
            registry.referrerKey(USER) == _packKey(
                _incomingAt,
                1
            )
        );

        vm.warp(
            EXECUTE_TIME
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.NothingToCorrect.selector
        );

        registry.executeCorrectReferrer(
            USER
        );
    }

    // ---- MRG codec lemmas ----

    function testFuzz_MRG7_referredPayloadPassesValidation(
        uint256 _year1,
        uint256 _year2,
        uint256 _mature,
        uint256 _assignedAt,
        uint256 _rank,
        uint256 _mintAmount,
        uint256 _captureWeek
    )
        public
        view
    {
        _captureWeek = bound(
            _captureWeek,
            0,
            CohortWeeks.BRIDGE_CARRY_CAPTURE_WEEK_MASK
        );

        _year1 = bound(
            _year1,
            1,
            CohortWeeks.RING_LANE_MAX
        );

        _year2 = bound(
            _year2,
            0,
            CohortWeeks.RING_LANE_MAX
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
            _captureWeek,
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
        uint256 _mintAmount,
        uint256 _captureWeek
    )
        public
        view
    {
        _captureWeek = bound(
            _captureWeek,
            0,
            CohortWeeks.BRIDGE_CARRY_CAPTURE_WEEK_MASK
        );

        _year1 = bound(
            _year1,
            1,
            CohortWeeks.RING_LANE_MAX
        );

        _year2 = bound(
            _year2,
            0,
            CohortWeeks.RING_LANE_MAX
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
            _captureWeek,
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

        assert(
            scaledParts <= scaledTotal
        );
    }
}
