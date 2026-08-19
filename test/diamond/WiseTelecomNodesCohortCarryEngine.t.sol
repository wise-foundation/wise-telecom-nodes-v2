// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {CohortCarryHarness} from "./utils/CohortCarryHarness.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";
import {ReferralRegistry} from "../../src/registry/pending/ReferralRegistry.sol";

/**
 * @dev Hostile registry mock whose `consumeCarry` answers with a
 * payload longer than `MAX_CARRY_WORDS` and a fresh `stagedAt`, so
 * the destination's wholesale payload validation is the only line
 * of defense left standing.
 */
contract OversizeCarryRegistry {

    function consumeCarry(
        address,
        address
    )
        external
        view
        returns (
            uint256 stagedAt,
            uint256[] memory payload
        )
    {
        stagedAt = block.timestamp;

        payload = new uint256[](
            CohortWeeks.MAX_CARRY_WORDS + 6
        );
    }
}

/**
 * @dev Engine-level suite for the same-chain move-carry machinery in
 * {CohortRecorderBase}, driven through two standalone
 * {CohortCarryHarness} instances sharing ONE {ReferralRegistry} — the
 * per-chain topology of production, without diamond wiring. Section A
 * proves the captured reduction walk: its `(ring, slot, take)` pairs
 * equal the exact storage delta the walk applied (every changed slot
 * appears exactly once, sums match the returned aggregates), and the
 * captured walk is storage-identical to the plain `_reduceBookCohort`
 * it refactors (snapshot differential). Section B proves the
 * capture→stage→apply seam end to end: exact-walk staging, the
 * min(delta, burned) cap with sale-like excess reduction, the
 * unreferred tracked-only envelope, per-slot conservation across
 * harnesses, and the engine-level A→B→A round trip returning the
 * source to byte-identical rings/book/tracked. Section C covers the
 * failure doctrine — every arm must degrade without reverting and
 * without blocking: pointer unset (clamp-as-unreferred + skip),
 * lookup failure (full retry semantics, nothing mutated), revoked
 * allowlist (clamp lands, staging skipped), stale payloads
 * (discarded), malformed payloads (validator rejects wholesale),
 * empty mailbox, codeless registry — plus the per-component floor
 * scaling and its lane-max cap.
 */
contract WiseTelecomNodesCohortCarryEngineTest is Test {

    event CohortCarryStaged(
        address indexed user,
        address indexed dstVault,
        address indexed referrer,
        uint256 trackedDelta,
        uint256 year1,
        uint256 year2,
        uint256 mature,
        uint256 pairCount
    );

    event CohortCarryApplied(
        address indexed user,
        address indexed srcVault,
        address indexed referrer,
        uint256 trackedDelta,
        uint256 year1,
        uint256 year2,
        uint256 mature,
        uint256 pairCount
    );

    event CohortCarrySkipped(
        address indexed user,
        address indexed dstVault
    );

    event CohortCarryDiscarded(
        address indexed user,
        address indexed srcVault,
        uint256 stagedAt
    );

    uint256 internal constant BASE_WEEK = 3_000;

    uint256 internal constant BASE_TIME = BASE_WEEK * 1 weeks + 1 hours;

    address internal user1 = address(0xA1);

    address internal refA = address(0xB1);

    CohortCarryHarness internal harnessA;

    CohortCarryHarness internal harnessB;

    ReferralRegistry internal registry;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        harnessA = new CohortCarryHarness();

        harnessB = new CohortCarryHarness();

        registry = new ReferralRegistry();

        registry.setAllowedVault(
            address(harnessA),
            true
        );

        registry.setAllowedVault(
            address(harnessB),
            true
        );

        registry.setAllowedVault(
            address(this),
            true
        );

        harnessA.harnessSetRegistry(
            address(registry)
        );

        harnessB.harnessSetRegistry(
            address(registry)
        );
    }

    // ---- helpers ----

    function _warpToWeek(
        uint256 _week
    )
        internal
    {
        vm.warp(
            _week * 1 weeks + 1 hours
        );
    }

    function _referUser1()
        internal
    {
        registry.assignReferrer(
            user1,
            refA
        );
    }

    function _creditAt(
        CohortCarryHarness _harness,
        uint256 _week,
        uint256 _amount
    )
        internal
    {
        _warpToWeek(
            _week
        );

        _harness.exposedCreditContribution(
            user1,
            _amount
        );
    }

    function _ringSnapshot(
        CohortCarryHarness _harness,
        address _referrer
    )
        internal
        view
        returns (
            uint64[52] memory ring1,
            uint64[52] memory ring2
        )
    {
        for (uint256 i; i < 52; ++i) {
            ring1[i] = _harness.viewRingYear1(
                _referrer,
                i
            );

            ring2[i] = _harness.viewRingYear2(
                _referrer,
                i
            );
        }
    }

    function _assertRingsEqual(
        uint64[52] memory _left1,
        uint64[52] memory _left2,
        uint64[52] memory _right1,
        uint64[52] memory _right2
    )
        internal
        pure
    {
        for (uint256 i; i < 52; ++i) {
            assertEq(_left1[i], _right1[i]);

            assertEq(_left2[i], _right2[i]);
        }
    }

    function _carryTopicCount(
        bytes32 _topic
    )
        internal
        returns (uint256 count)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == _topic) {
                ++count;
            }
        }
    }

    // ---- Section A: captured walk ----

    struct WalkCheck {
        uint256 total;
        uint256 delta;
        uint256 pairCount;
        uint256 fromYear1;
        uint256 fromYear2;
        uint256 fromMature;
        uint256 pairYear1;
        uint256 pairYear2;
        uint64[52] before1;
        uint64[52] before2;
        uint64[52] after1;
        uint64[52] after2;
        uint256[] pairs;
    }

    function _seedRings(
        uint256 _slotSeed,
        uint256 _amountSeed
    )
        internal
        returns (uint256 total)
    {
        for (uint256 i; i < 6; ++i) {

            uint256 slot = uint256(
                keccak256(
                    abi.encode(
                        _slotSeed,
                        i
                    )
                )
            ) % 52;

            uint256 amount = bound(
                uint256(
                    keccak256(
                        abi.encode(
                            _amountSeed,
                            i
                        )
                    )
                ),
                1,
                1_000_000 * 1e6
            );

            if (i % 2 == 0) {

                uint256 currentYear1 = harnessA.viewRingYear1(
                    refA,
                    slot
                );

                harnessA.harnessSetRingYear1(
                    refA,
                    slot,
                    uint64(currentYear1 + amount)
                );
            } else {

                uint256 currentYear2 = harnessA.viewRingYear2(
                    refA,
                    slot
                );

                harnessA.harnessSetRingYear2(
                    refA,
                    slot,
                    uint64(currentYear2 + amount)
                );
            }

            total += amount;
        }
    }

    function _seedBookFromRings()
        internal
    {
        uint256 year1Total;

        uint256 year2Total;

        for (uint256 i; i < 52; ++i) {
            year1Total += uint256(
                harnessA.viewRingYear1(
                    refA,
                    i
                )
            );

            year2Total += uint256(
                harnessA.viewRingYear2(
                    refA,
                    i
                )
            );
        }

        harnessA.harnessSetBookLanes(
            refA,
            year1Total,
            year2Total,
            0
        );
    }

    function testFuzz_reduceBookCaptured_pairsEqualStorageDelta(
        uint256 _slotSeed,
        uint256 _amountSeed,
        uint256 _deltaSeed
    )
        public
    {
        WalkCheck memory check;

        check.total = _seedRings(
            _slotSeed,
            _amountSeed
        );

        _seedBookFromRings();

        (
            check.before1,
            check.before2
        ) = _ringSnapshot(
            harnessA,
            refA
        );

        check.delta = bound(
            _deltaSeed,
            1,
            check.total
        );

        (
            check.pairs,
            check.pairCount,
            check.fromYear1,
            check.fromYear2,
            check.fromMature
        ) = harnessA.exposedReduceBookCaptured(
            refA,
            check.delta
        );

        assertEq(check.fromMature, 0);

        assertEq(check.fromYear1 + check.fromYear2, check.delta);

        assertLe(check.pairCount, CohortWeeks.MAX_CARRY_PAIRS);

        (
            check.after1,
            check.after2
        ) = _ringSnapshot(
            harnessA,
            refA
        );

        for (uint256 i; i < check.pairCount; ++i) {

            uint256 pair = check.pairs[i];

            uint256 slot = CohortWeeks.carryPairSlot(pair);

            if (CohortWeeks.carryPairRing(pair) == CohortWeeks.CARRY_RING_YEAR1) {

                assertEq(
                    uint256(check.before1[slot]) - uint256(check.after1[slot]),
                    CohortWeeks.carryPairAmount(pair)
                );

                check.pairYear1 += CohortWeeks.carryPairAmount(pair);
            } else {

                assertEq(
                    uint256(check.before2[slot]) - uint256(check.after2[slot]),
                    CohortWeeks.carryPairAmount(pair)
                );

                check.pairYear2 += CohortWeeks.carryPairAmount(pair);
            }
        }

        assertEq(check.pairYear1, check.fromYear1);

        assertEq(check.pairYear2, check.fromYear2);

        for (uint256 i; i < 52; ++i) {

            if (check.before1[i] != check.after1[i]) {
                assertTrue(
                    _slotInPairs(
                        check.pairs,
                        check.pairCount,
                        i,
                        CohortWeeks.CARRY_RING_YEAR1
                    )
                );
            }

            if (check.before2[i] != check.after2[i]) {
                assertTrue(
                    _slotInPairs(
                        check.pairs,
                        check.pairCount,
                        i,
                        CohortWeeks.CARRY_RING_YEAR2
                    )
                );
            }
        }
    }

    function _slotInPairs(
        uint256[] memory _pairs,
        uint256 _pairCount,
        uint256 _slot,
        uint256 _ring
    )
        internal
        pure
        returns (bool)
    {
        for (uint256 i; i < _pairCount; ++i) {

            if (
                CohortWeeks.carryPairSlot(_pairs[i]) == _slot
                && CohortWeeks.carryPairRing(_pairs[i]) == _ring
            ) {
                return true;
            }
        }

        return false;
    }

    struct DiffCheck {
        uint256 total;
        uint256 delta;
        uint256 snapshot;
        uint256 plainYear1;
        uint256 plainYear2;
        uint256 plainMature;
        uint256 plainBook;
        uint64[52] plain1;
        uint64[52] plain2;
    }

    function testFuzz_reduceBookCaptured_equalsPlainReduce(
        uint256 _slotSeed,
        uint256 _amountSeed,
        uint256 _deltaSeed
    )
        public
    {
        DiffCheck memory check;

        check.total = _seedRings(
            _slotSeed,
            _amountSeed
        );

        harnessA.harnessSetBookLanes(
            refA,
            check.total,
            check.total,
            1_000 * 1e6
        );

        check.delta = bound(
            _deltaSeed,
            1,
            check.total + 1_000 * 1e6
        );

        check.snapshot = vm.snapshotState();

        (
            check.plainYear1,
            check.plainYear2,
            check.plainMature
        ) = harnessA.exposedReduceBook(
            refA,
            check.delta
        );

        (
            check.plain1,
            check.plain2
        ) = _ringSnapshot(
            harnessA,
            refA
        );

        check.plainBook = harnessA.viewBookWord(
            refA
        );

        vm.revertToState(
            check.snapshot
        );

        (
            ,
            ,
            uint256 capturedYear1,
            uint256 capturedYear2,
            uint256 capturedMature
        ) = harnessA.exposedReduceBookCaptured(
            refA,
            check.delta
        );

        assertEq(capturedYear1, check.plainYear1);

        assertEq(capturedYear2, check.plainYear2);

        assertEq(capturedMature, check.plainMature);

        assertEq(
            harnessA.viewBookWord(refA),
            check.plainBook
        );

        (
            uint64[52] memory captured1,
            uint64[52] memory captured2
        ) = _ringSnapshot(
            harnessA,
            refA
        );

        _assertRingsEqual(
            captured1,
            captured2,
            check.plain1,
            check.plain2
        );
    }

    function test_reduceBookCaptured_matureResidualPairless()
        public
    {
        harnessA.harnessSetBookLanes(
            refA,
            0,
            0,
            5_000 * 1e6
        );

        (
            ,
            uint256 pairCount,
            uint256 fromYear1,
            uint256 fromYear2,
            uint256 fromMature
        ) = harnessA.exposedReduceBookCaptured(
            refA,
            2_000 * 1e6
        );

        assertEq(pairCount, 0);

        assertEq(fromYear1, 0);

        assertEq(fromYear2, 0);

        assertEq(fromMature, 2_000 * 1e6);
    }

    // ---- Section B: capture → stage → apply ----

    function test_captureApply_referredFull_conservesPerSlot()
        public
    {
        _referUser1();

        _creditAt(
            harnessA,
            BASE_WEEK,
            1_000 * 1e6
        );

        _creditAt(
            harnessA,
            BASE_WEEK + 10,
            2_000 * 1e6
        );

        _creditAt(
            harnessA,
            BASE_WEEK + 20,
            500 * 1e6
        );

        (
            uint64[52] memory before1,
            uint64[52] memory before2
        ) = _ringSnapshot(
            harnessA,
            refA
        );

        uint256 bookBefore = harnessA.viewBookWord(
            refA
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(harnessA)
        );

        emit CohortCarryStaged(
            user1,
            address(harnessB),
            refA,
            3_500 * 1e6,
            3_500 * 1e6,
            0,
            0,
            3
        );

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            3_500 * 1e6,
            1,
            1
        );

        assertEq(
            harnessA.viewTracked(user1),
            0
        );

        harnessB.harnessMintBalance(
            user1,
            3_500 * 1e6
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(harnessB)
        );

        emit CohortCarryApplied(
            user1,
            address(harnessA),
            refA,
            3_500 * 1e6,
            3_500 * 1e6,
            0,
            0,
            3
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(harnessA)
        );

        assertEq(
            harnessB.viewTracked(user1),
            3_500 * 1e6
        );

        (
            uint64[52] memory afterA1,
            uint64[52] memory afterA2
        ) = _ringSnapshot(
            harnessA,
            refA
        );

        (
            uint64[52] memory afterB1,
            uint64[52] memory afterB2
        ) = _ringSnapshot(
            harnessB,
            refA
        );

        for (uint256 i; i < 52; ++i) {

            assertEq(
                uint256(before1[i]) - uint256(afterA1[i]),
                uint256(afterB1[i])
            );

            assertEq(
                uint256(before2[i]) - uint256(afterA2[i]),
                uint256(afterB2[i])
            );
        }

        uint256 bookAfterA = CohortWeeks.laneY1(
            harnessA.viewBookWord(
                refA
            )
        );

        uint256 bookAfterB = CohortWeeks.laneY1(
            harnessB.viewBookWord(
                refA
            )
        );

        assertEq(
            CohortWeeks.laneY1(bookBefore) - bookAfterA,
            bookAfterB
        );

        (
            uint256 stagedAt,
            uint256[] memory leftover
        ) = registry.getCarry(
            address(harnessA),
            address(harnessB),
            user1
        );

        assertEq(stagedAt, 0);

        assertEq(leftover.length, 0);
    }

    function test_captureMoveOut_excessBeyondBurn_reducesSaleLikeFirst()
        public
    {
        _referUser1();

        _creditAt(
            harnessA,
            BASE_WEEK,
            5_000 * 1e6
        );

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            2_000 * 1e6,
            1,
            1
        );

        assertEq(
            harnessA.viewTracked(user1),
            0
        );

        assertEq(
            CohortWeeks.laneY1(
                harnessA.viewBookWord(
                    refA
                )
            ),
            0
        );

        (
            ,
            uint256[] memory payload
        ) = registry.getCarry(
            address(harnessA),
            address(harnessB),
            user1
        );

        assertEq(
            CohortWeeks.carryTrackedDelta(payload[1]),
            2_000 * 1e6
        );
    }

    function test_captureApply_unreferred_stagesTrackedOnly()
        public
    {
        _creditAt(
            harnessA,
            BASE_WEEK,
            4_000 * 1e6
        );

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            4_000 * 1e6,
            1,
            1
        );

        (
            ,
            uint256[] memory payload
        ) = registry.getCarry(
            address(harnessA),
            address(harnessB),
            user1
        );

        assertEq(payload.length, 2);

        assertEq(
            CohortWeeks.carryEnvelopePairCount(payload[0]),
            0
        );

        assertEq(
            CohortWeeks.carryTrackedDelta(payload[1]),
            4_000 * 1e6
        );

        harnessB.harnessMintBalance(
            user1,
            4_000 * 1e6
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(harnessA)
        );

        assertEq(
            harnessB.viewTracked(user1),
            4_000 * 1e6
        );

        assertEq(
            harnessB.viewBookWord(refA),
            0
        );
    }

    function test_captureApply_engineRoundTrip_byteIdentical()
        public
    {
        _referUser1();

        _creditAt(
            harnessA,
            BASE_WEEK,
            1_500 * 1e6
        );

        _creditAt(
            harnessA,
            BASE_WEEK + 30,
            2_500 * 1e6
        );

        (
            uint64[52] memory origin1,
            uint64[52] memory origin2
        ) = _ringSnapshot(
            harnessA,
            refA
        );

        uint256 originBook = harnessA.viewBookWord(
            refA
        );

        uint256 originTracked = harnessA.viewTracked(
            user1
        );

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            4_000 * 1e6,
            1,
            1
        );

        harnessB.harnessMintBalance(
            user1,
            4_000 * 1e6
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(harnessA)
        );

        harnessB.harnessBurnBalance(
            user1,
            4_000 * 1e6
        );

        harnessB.exposedCaptureMoveOut(
            user1,
            address(harnessA),
            4_000 * 1e6,
            1,
            1
        );

        harnessA.harnessMintBalance(
            user1,
            4_000 * 1e6
        );

        harnessA.exposedApplyMoveIn(
            user1,
            address(harnessB)
        );

        (
            uint64[52] memory final1,
            uint64[52] memory final2
        ) = _ringSnapshot(
            harnessA,
            refA
        );

        _assertRingsEqual(
            final1,
            final2,
            origin1,
            origin2
        );

        assertEq(
            harnessA.viewBookWord(refA),
            originBook
        );

        assertEq(
            harnessA.viewTracked(user1),
            originTracked
        );

        assertEq(
            harnessB.viewBookWord(refA),
            0
        );

        assertEq(
            harnessB.viewTracked(user1),
            0
        );
    }

    // ---- Section C: failure doctrine + scaling ----

    function test_captureMoveOut_zeroDeficit_noop()
        public
    {
        _referUser1();

        harnessA.harnessMintBalance(
            user1,
            1_000 * 1e6
        );

        vm.recordLogs();

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            500 * 1e6,
            1,
            1
        );

        assertEq(
            _carryTopicCount(
                keccak256(
                    "CohortCarryStaged(address,address,address,uint256,uint256,uint256,uint256,uint256)"
                )
            ),
            0
        );
    }

    function test_captureMoveOut_registryUnset_clampsAsUnreferredAndSkips()
        public
    {
        _referUser1();

        _creditAt(
            harnessA,
            BASE_WEEK,
            3_000 * 1e6
        );

        harnessA.harnessSetRegistry(
            address(0)
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(harnessA)
        );

        emit CohortCarrySkipped(
            user1,
            address(harnessB)
        );

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            3_000 * 1e6,
            1,
            1
        );

        assertEq(
            harnessA.viewTracked(user1),
            0
        );

        assertEq(
            CohortWeeks.laneY1(
                harnessA.viewBookWord(
                    refA
                )
            ),
            3_000 * 1e6
        );
    }

    function test_captureMoveOut_lookupFails_skipsEntirelyThenRetries()
        public
    {
        _referUser1();

        _creditAt(
            harnessA,
            BASE_WEEK,
            3_000 * 1e6
        );

        bytes memory realCode = address(registry).code;

        vm.etch(
            address(registry),
            hex"60006000fd"
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(harnessA)
        );

        emit CohortCarrySkipped(
            user1,
            address(harnessB)
        );

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            3_000 * 1e6,
            1,
            1
        );

        assertEq(
            harnessA.viewTracked(user1),
            3_000 * 1e6
        );

        assertEq(
            CohortWeeks.laneY1(
                harnessA.viewBookWord(
                    refA
                )
            ),
            3_000 * 1e6
        );

        vm.etch(
            address(registry),
            realCode
        );

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            3_000 * 1e6,
            1,
            1
        );

        assertEq(
            harnessA.viewTracked(user1),
            0
        );

        assertEq(
            CohortWeeks.laneY1(
                harnessA.viewBookWord(
                    refA
                )
            ),
            0
        );
    }

    function test_captureMoveOut_revokedVault_clampLandsStagingSkipped()
        public
    {
        _referUser1();

        _creditAt(
            harnessA,
            BASE_WEEK,
            3_000 * 1e6
        );

        registry.setAllowedVault(
            address(harnessA),
            false
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(harnessA)
        );

        emit CohortCarrySkipped(
            user1,
            address(harnessB)
        );

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            3_000 * 1e6,
            1,
            1
        );

        assertEq(
            harnessA.viewTracked(user1),
            0
        );

        assertEq(
            CohortWeeks.laneY1(
                harnessA.viewBookWord(
                    refA
                )
            ),
            0
        );

        (
            uint256 stagedAt,
        ) = registry.getCarry(
            address(harnessA),
            address(harnessB),
            user1
        );

        assertEq(stagedAt, 0);
    }

    function test_applyMoveIn_staleStage_discardsAndDrains()
        public
    {
        _referUser1();

        _creditAt(
            harnessA,
            BASE_WEEK,
            3_000 * 1e6
        );

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            3_000 * 1e6,
            1,
            1
        );

        uint256 stagedTime = block.timestamp;

        vm.warp(
            block.timestamp + 1
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(harnessB)
        );

        emit CohortCarryDiscarded(
            user1,
            address(harnessA),
            stagedTime
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(harnessA)
        );

        assertEq(
            harnessB.viewTracked(user1),
            0
        );

        assertEq(
            harnessB.viewBookWord(refA),
            0
        );

        (
            uint256 stagedAt,
        ) = registry.getCarry(
            address(harnessA),
            address(harnessB),
            user1
        );

        assertEq(stagedAt, 0);
    }

    function test_applyMoveIn_emptyMailbox_discardsWithZero()
        public
    {
        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(harnessB)
        );

        emit CohortCarryDiscarded(
            user1,
            address(harnessA),
            0
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(harnessA)
        );

        assertEq(
            harnessB.viewTracked(user1),
            0
        );
    }

    function test_applyMoveIn_registryUnset_returnsSilently()
        public
    {
        harnessB.harnessSetRegistry(
            address(0)
        );

        vm.recordLogs();

        harnessB.exposedApplyMoveIn(
            user1,
            address(harnessA)
        );

        assertEq(
            _carryTopicCount(
                keccak256(
                    "CohortCarryDiscarded(address,address,uint256)"
                )
            ),
            0
        );
    }

    function test_applyMoveIn_codelessRegistry_discards()
        public
    {
        harnessB.harnessSetRegistry(
            address(0xDEAD)
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(harnessB)
        );

        emit CohortCarryDiscarded(
            user1,
            address(harnessA),
            0
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(harnessA)
        );
    }

    function test_applyMoveIn_malformedPayloads_discardedWholesale()
        public
    {
        uint256[][] memory bads = new uint256[][](5);

        bads[0] = new uint256[](2);

        bads[0][0] = CohortWeeks.packCarryEnvelope(
            refA,
            0
        ) ^ (1 << CohortWeeks.CARRY_VERSION_SHIFT);

        bads[1] = new uint256[](2);

        bads[1][0] = CohortWeeks.packCarryEnvelope(
            refA,
            4
        );

        bads[2] = new uint256[](3);

        bads[2][0] = CohortWeeks.packCarryEnvelope(
            refA,
            1
        );

        bads[2][2] = CohortWeeks.packCarryPair(
            1_000,
            52,
            CohortWeeks.CARRY_RING_YEAR1
        );

        bads[3] = new uint256[](3);

        bads[3][0] = CohortWeeks.packCarryEnvelope(
            refA,
            1
        );

        bads[3][2] = CohortWeeks.packCarryPair(
            1_000,
            10,
            2
        );

        bads[4] = new uint256[](3);

        bads[4][0] = CohortWeeks.packCarryEnvelope(
            refA,
            1
        );

        bads[4][2] = CohortWeeks.packCarryPairsWord(
            CohortWeeks.packCarryPair(
                1_000,
                10,
                CohortWeeks.CARRY_RING_YEAR1
            ),
            CohortWeeks.packCarryPair(
                999,
                11,
                CohortWeeks.CARRY_RING_YEAR1
            )
        );

        for (uint256 i; i < bads.length; ++i) {

            registry.stageCarry(
                address(harnessB),
                user1,
                bads[i]
            );

            vm.expectEmit(
                true,
                true,
                false,
                true,
                address(harnessB)
            );

            emit CohortCarryDiscarded(
                user1,
                address(this),
                block.timestamp
            );

            harnessB.exposedApplyMoveIn(
                user1,
                address(this)
            );

            assertEq(
                harnessB.viewTracked(user1),
                0
            );

            assertEq(
                harnessB.viewBookWord(refA),
                0
            );
        }
    }

    function test_captureMoveOut_scaleDown_floorsPerComponent()
        public
    {
        _referUser1();

        _creditAt(
            harnessA,
            BASE_WEEK,
            1_500
        );

        _creditAt(
            harnessA,
            BASE_WEEK + 1,
            2_500
        );

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            4_000,
            1,
            1_000
        );

        (
            ,
            uint256[] memory payload
        ) = registry.getCarry(
            address(harnessA),
            address(harnessB),
            user1
        );

        assertEq(
            CohortWeeks.carryTrackedDelta(payload[1]),
            3
        );

        assertEq(
            CohortWeeks.carryEnvelopePairCount(payload[0]),
            2
        );

        harnessB.harnessMintBalance(
            user1,
            4
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(harnessA)
        );

        assertEq(
            harnessB.viewTracked(user1),
            3
        );

        assertEq(
            CohortWeeks.laneY1(
                harnessB.viewBookWord(
                    refA
                )
            ),
            3
        );
    }

    function test_captureMoveOut_unreferredScaledToZero_stagesNothing()
        public
    {
        _creditAt(
            harnessA,
            BASE_WEEK,
            500
        );

        vm.recordLogs();

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            500,
            1,
            1_000_000
        );

        assertEq(
            _carryTopicCount(
                keccak256(
                    "CohortCarryStaged(address,address,address,uint256,uint256,uint256,uint256,uint256)"
                )
            ),
            0
        );

        assertEq(
            harnessA.viewTracked(user1),
            0
        );

        (
            uint256 stagedAt,
        ) = registry.getCarry(
            address(harnessA),
            address(harnessB),
            user1
        );

        assertEq(stagedAt, 0);
    }

    function test_applyMoveIn_lengthOnePayload_discards()
        public
    {
        uint256[] memory payload = new uint256[](1);

        payload[0] = CohortWeeks.packCarryEnvelope(
            refA,
            0
        );

        registry.stageCarry(
            address(harnessB),
            user1,
            payload
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(harnessB)
        );

        emit CohortCarryDiscarded(
            user1,
            address(this),
            block.timestamp
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(this)
        );

        assertEq(
            harnessB.viewTracked(user1),
            0
        );
    }

    function test_applyMoveIn_pairCountOverflow_discards()
        public
    {
        uint256[] memory payload = new uint256[](
            CohortWeeks.MAX_CARRY_WORDS
        );

        payload[0] = CohortWeeks.packCarryEnvelope(
            refA,
            200
        );

        registry.stageCarry(
            address(harnessB),
            user1,
            payload
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(harnessB)
        );

        emit CohortCarryDiscarded(
            user1,
            address(this),
            block.timestamp
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(this)
        );

        assertEq(
            harnessB.viewTracked(user1),
            0
        );
    }

    function test_applyMoveIn_oversizeFromHostileRegistry_discards()
        public
    {
        OversizeCarryRegistry hostile = new OversizeCarryRegistry();

        harnessB.harnessSetRegistry(
            address(hostile)
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(harnessB)
        );

        emit CohortCarryDiscarded(
            user1,
            address(harnessA),
            block.timestamp
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(harnessA)
        );

        assertEq(
            harnessB.viewTracked(user1),
            0
        );
    }

    function test_applyMoveIn_zeroAmountPairSkipped()
        public
    {
        uint256[] memory payload = new uint256[](3);

        payload[0] = CohortWeeks.packCarryEnvelope(
            refA,
            1
        );

        payload[1] = CohortWeeks.packCarryAmounts(
            7,
            0
        );

        payload[2] = CohortWeeks.packCarryPair(
            0,
            5,
            CohortWeeks.CARRY_RING_YEAR1
        );

        registry.stageCarry(
            address(harnessB),
            user1,
            payload
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(this)
        );

        assertEq(
            harnessB.viewTracked(user1),
            7
        );

        assertEq(
            harnessB.viewRingYear1(
                refA,
                5
            ),
            0
        );

        assertEq(
            harnessB.viewBookWord(refA),
            0
        );
    }

    function test_applyMoveIn_matureOverflow_clipsBookLane()
        public
    {
        uint256[] memory payload = new uint256[](2);

        payload[0] = CohortWeeks.packCarryEnvelope(
            refA,
            0
        );

        payload[1] = CohortWeeks.packCarryAmounts(
            1 << 100,
            1 << 100
        );

        registry.stageCarry(
            address(harnessB),
            user1,
            payload
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(this)
        );

        assertEq(
            CohortWeeks.laneM(
                harnessB.viewBookWord(
                    refA
                )
            ),
            CohortWeeks.LANE_MASK_80
        );

        assertEq(
            harnessB.viewTracked(user1),
            1 << 100
        );
    }

    function test_captureMoveOut_scaleUp_capsAtLaneMax()
        public
    {
        _referUser1();

        _creditAt(
            harnessA,
            BASE_WEEK,
            1_000_000 * 1e6
        );

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            1_000_000 * 1e6,
            1e12,
            1
        );

        (
            ,
            uint256[] memory payload
        ) = registry.getCarry(
            address(harnessA),
            address(harnessB),
            user1
        );

        assertEq(
            CohortWeeks.carryPairAmount(
                CohortWeeks.carryPairLo(payload[2])
            ),
            CohortWeeks.RING_LANE_MAX
        );
    }
}
