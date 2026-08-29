// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Vm.sol";

import {WiseTelecomNodesDiamond} from "../../src/diamond/vault/WiseTelecomNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";

import {WiseTelecomNodesDiamondErrors} from "../../src/diamond/vault/WiseTelecomNodesDiamondErrors.sol";

import {TwoVaultCohortHarness} from "./utils/TwoVaultCohortHarness.sol";

/**
 * @dev End-to-end referrer-flip suite driving the cross-chain
 * min-merge through the REAL per-chain registry against two fully
 * wired vaults: an allowlisted vault relays a strictly-lower-key
 * pair via `mergeReferrer`, the registry records pending-flip
 * markers for every tracked vault, and the permissionless
 * `pokeMigration` relocates each vault's book credit through
 * `receiveReferrerFlip` into the flip engine. Proves the
 * conservation contract of the migration (rings and book lanes move
 * 1:1 at identical coordinates, `trackedContribution` untouched by
 * the relocation itself), the clamp-first ordering (a lazy deficit
 * is destroyed against the OLD referrer before anything replants),
 * the redirect window (`effectiveReferrerOf` answers the old
 * referrer while a marker stands, so interim clamps and credits
 * keep hitting the book that actually holds the cover), the
 * zero-tracked short-circuit, the defer-and-retry contract for a
 * disarmed vault, poke idempotence, and the marker-vs-current
 * reconciliation (`FlipCleared`, no engine call) when a key chain
 * lands back on the original referrer. Registry-caller
 * authentication on `receiveReferrerFlip` is pinned directly
 * against the routed selector. Every scenario closes with the
 * no-orphan identity: the effective referrer's book score accounts
 * for the sole referee's tracked contribution.
 */
contract WiseTelecomNodesCohortFlipTest is TwoVaultCohortHarness {

    event CohortReferrerFlipApplied(
        address indexed user,
        address indexed oldReferrer,
        address indexed newReferrer,
        uint256 year1,
        uint256 year2,
        uint256 mature,
        uint256 pairCount
    );

    event CohortContributionSynced(
        address indexed user,
        address indexed referrer,
        uint256 oldContribution,
        uint256 newContribution
    );

    event CohortContributionCredited(
        address indexed user,
        address indexed referrer,
        uint256 amount
    );

    event ReferralSyncFlipped(
        address indexed user,
        address indexed oldReferrer,
        address indexed newReferrer,
        uint256 syncKey
    );

    event FlipMarked(
        address indexed vault,
        address indexed user,
        address indexed oldReferrer
    );

    event FlipCleared(
        address indexed vault,
        address indexed user,
        address indexed oldReferrer
    );

    event FlipMigrated(
        address indexed vault,
        address indexed user,
        address oldReferrer,
        address newReferrer
    );

    event FlipMigrationDeferred(
        address indexed vault,
        address indexed user,
        address oldReferrer,
        address newReferrer
    );

    uint256 internal constant SEEDED_TOTAL = 3_500 * 1e6;

    address internal user1 = address(0xA1);

    address internal refY = address(0xB1);

    address internal refX = address(0xB2);

    address internal refZ = address(0xB3);

    address internal outsider = address(0xC1);

    function setUp()
        public
    {
        _deployCohortPair();

        _armBoth();
    }

    // ---- helpers ----

    function _mergeAsVaultA(
        address _newReferrer,
        uint256 _assignedAt
    )
        internal
    {
        vm.prank(
            address(vaultA)
        );

        registry.mergeReferrer(
            user1,
            _newReferrer,
            _assignedAt,
            1
        );
    }

    function _seedThreeWeekSchedule()
        internal
        returns (uint256 stampTime)
    {
        stampTime = block.timestamp;

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        vm.warp(
            block.timestamp + 2 weeks
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            2_000 * 1e6,
            refY
        );

        vm.warp(
            block.timestamp + 1 weeks
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            500 * 1e6,
            refY
        );
    }

    function _assertReferrerBookEmpty(
        WiseTelecomNodesDiamond d,
        address _referrer
    )
        internal
        view
    {
        assertEq(
            _recorderOf(d).getCohortScore(_referrer),
            0
        );

        (
            uint64[52] memory ring1,
            uint64[52] memory ring2
        ) = _recorderOf(d).getCohortRings(
            _referrer
        );

        for (uint256 i; i < 52; ++i) {

            assertEq(ring1[i], 0);

            assertEq(ring2[i], 0);
        }
    }

    function _assertNoOrphan(
        WiseTelecomNodesDiamond d,
        address _user
    )
        internal
        view
    {
        address effective = registry.effectiveReferrerOf(
            _user,
            address(d)
        );

        assertEq(
            _recorderOf(d).getCohortScore(effective),
            _recorderOf(d).getTrackedContribution(_user)
        );
    }

    // ---- merge marks and redirects ----

    function test_mergeReferrer_lowerKey_flipsAndMarksAllVaults()
        public
    {
        uint256 stampTime = block.timestamp;

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        uint256 assignedAt = stampTime - 1_000;

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit FlipMarked(
            address(vaultA),
            user1,
            refY
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit FlipMarked(
            address(vaultB),
            user1,
            refY
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit ReferralSyncFlipped(
            user1,
            refY,
            refX,
            (assignedAt << 8) | 1
        );

        _mergeAsVaultA(
            refX,
            assignedAt
        );

        assertEq(
            registry.referrerOf(user1),
            refX
        );

        assertEq(
            registry.pendingFlip(address(vaultA), user1),
            refY
        );

        assertEq(
            registry.pendingFlip(address(vaultB), user1),
            refY
        );

        assertEq(
            registry.effectiveReferrerOf(user1, address(vaultA)),
            refY
        );

        assertEq(
            registry.effectiveReferrerOf(user1, address(vaultB)),
            refY
        );

        (
            address referrer,
            uint256 pairAssignedAt,
            uint256 rank
        ) = registry.getReferrerPair(
            user1
        );

        assertEq(referrer, refX);

        assertEq(pairAssignedAt, assignedAt);

        assertEq(rank, 1);
    }

    // ---- full-path conservation ----

    function test_pokeMigration_fullPath_movesScheduleOneToOne()
        public
    {
        uint256 stampTime = _seedThreeWeekSchedule();

        CohortSnap memory beforeY = _captureCohort(
            vaultA,
            refY,
            user1
        );

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        registry.pokeMigration(
            user1
        );

        CohortSnap memory afterX = _captureCohort(
            vaultA,
            refX,
            user1
        );

        _assertScheduleEq(
            afterX,
            beforeY
        );

        assertEq(
            _recorderOf(vaultA).getTrackedContribution(user1),
            SEEDED_TOTAL
        );

        _assertReferrerBookEmpty(
            vaultA,
            refY
        );

        assertEq(
            registry.effectiveReferrerOf(user1, address(vaultA)),
            refX
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }

    function test_pokeMigration_fullPath_emitsFlipEventsInOrder()
        public
    {
        uint256 stampTime = _seedThreeWeekSchedule();

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refY,
            refX,
            SEEDED_TOTAL,
            0,
            0,
            3
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit FlipMigrated(
            address(vaultA),
            user1,
            refY,
            refX
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refY,
            refX,
            0,
            0,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit FlipMigrated(
            address(vaultB),
            user1,
            refY,
            refX
        );

        registry.pokeMigration(
            user1
        );
    }

    // ---- clamp-first: interim exit resolves the OLD referrer ----

    function test_interimWindow_clampResolvesOldReferrer_thenPokeMovesResidual()
        public
    {
        uint256 stampTime = block.timestamp;

        _depositWithReferralOn(
            vaultA,
            user1,
            3_000 * 1e6,
            refY
        );

        vm.warp(
            block.timestamp + 1 weeks
        );

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        vm.prank(
            user1
        );

        vaultA.transfer(
            outsider,
            1_000 * 1e6
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultA)
        );

        emit CohortContributionSynced(
            user1,
            refY,
            3_000 * 1e6,
            2_000 * 1e6
        );

        _recorderOf(vaultA).syncReferee(
            user1
        );

        assertEq(
            _recorderOf(vaultA).getCohortScore(refY),
            2_000 * 1e6
        );

        assertEq(
            _recorderOf(vaultA).getCohortScore(refX),
            0
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refY,
            refX,
            2_000 * 1e6,
            0,
            0,
            1
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            _recorderOf(vaultA).getCohortScore(refX),
            2_000 * 1e6
        );

        _assertReferrerBookEmpty(
            vaultA,
            refY
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }

    // ---- interim deposits credit old, post-poke deposits credit new ----

    function test_interimWindow_depositCreditsOldReferrer_newAfterPoke()
        public
    {
        uint256 stampTime = block.timestamp;

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        _fundAndApproveOn(
            vaultA,
            user1,
            500 * 1e6
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultA)
        );

        emit CohortContributionCredited(
            user1,
            refY,
            500 * 1e6
        );

        vm.prank(
            user1
        );

        UserFacet(address(vaultA)).deposit(
            500 * 1e6
        );

        assertEq(
            _recorderOf(vaultA).getCohortScore(refY),
            1_500 * 1e6
        );

        assertEq(
            _recorderOf(vaultA).getCohortScore(refX),
            0
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            _recorderOf(vaultA).getCohortScore(refX),
            1_500 * 1e6
        );

        _fundAndApproveOn(
            vaultA,
            user1,
            300 * 1e6
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultA)
        );

        emit CohortContributionCredited(
            user1,
            refX,
            300 * 1e6
        );

        vm.prank(
            user1
        );

        UserFacet(address(vaultA)).deposit(
            300 * 1e6
        );

        assertEq(
            _recorderOf(vaultA).getCohortScore(refX),
            1_800 * 1e6
        );

        _assertReferrerBookEmpty(
            vaultA,
            refY
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }

    // ---- zero tracked: degenerate migration touches no books ----

    function test_pokeMigration_zeroTrackedVault_booksUntouched()
        public
    {
        uint256 stampTime = block.timestamp;

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        CohortSnap memory beforeYOnB = _captureCohort(
            vaultB,
            refY,
            user1
        );

        CohortSnap memory beforeXOnB = _captureCohort(
            vaultB,
            refX,
            user1
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refY,
            refX,
            0,
            0,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit FlipMigrated(
            address(vaultB),
            user1,
            refY,
            refX
        );

        registry.pokeMigration(
            user1
        );

        _assertScheduleEq(
            _captureCohort(
                vaultB,
                refY,
                user1
            ),
            beforeYOnB
        );

        _assertScheduleEq(
            _captureCohort(
                vaultB,
                refX,
                user1
            ),
            beforeXOnB
        );

        assertEq(
            registry.pendingFlip(address(vaultB), user1),
            address(0)
        );
    }

    // ---- receiveReferrerFlip authentication ----

    function test_receiveReferrerFlip_nonRegistryCaller_reverts()
        public
    {
        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.NotReferralRegistry.selector
        );

        CohortRecorderFacet(address(vaultA)).receiveReferrerFlip(
            user1,
            refY,
            refX
        );
    }

    // ---- disarmed vault defers, marker keeps redirecting ----

    function test_pokeMigration_disarmedVault_defersAndKeepsMarker()
        public
    {
        uint256 stampTime = block.timestamp;

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        _depositWithReferralOn(
            vaultB,
            user1,
            2_000 * 1e6,
            refY
        );

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        AdminFacet(address(vaultB)).setCohortSyncEnabled(
            false
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit FlipMigrated(
            address(vaultA),
            user1,
            refY,
            refX
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit FlipMigrationDeferred(
            address(vaultB),
            user1,
            refY,
            refX
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            registry.effectiveReferrerOf(user1, address(vaultA)),
            refX
        );

        assertEq(
            registry.effectiveReferrerOf(user1, address(vaultB)),
            refY
        );

        assertEq(
            _recorderOf(vaultA).getCohortScore(refX),
            1_000 * 1e6
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refY),
            2_000 * 1e6
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refX),
            0
        );
    }

    function test_pokeMigration_rearmedVault_migratesOnSecondPoke()
        public
    {
        uint256 stampTime = block.timestamp;

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        _depositWithReferralOn(
            vaultB,
            user1,
            2_000 * 1e6,
            refY
        );

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        AdminFacet(address(vaultB)).setCohortSyncEnabled(
            false
        );

        registry.pokeMigration(
            user1
        );

        AdminFacet(address(vaultB)).setCohortSyncEnabled(
            true
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit FlipMigrated(
            address(vaultB),
            user1,
            refY,
            refX
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refX),
            2_000 * 1e6
        );

        _assertReferrerBookEmpty(
            vaultB,
            refY
        );

        assertEq(
            registry.effectiveReferrerOf(user1, address(vaultB)),
            refX
        );

        _assertNoOrphan(
            vaultB,
            user1
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }

    // ---- poke idempotence ----

    function test_pokeMigration_secondCall_noEventsNoStateChange()
        public
    {
        uint256 stampTime = _seedThreeWeekSchedule();

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        registry.pokeMigration(
            user1
        );

        CohortSnap memory afterX = _captureCohort(
            vaultA,
            refX,
            user1
        );

        vm.recordLogs();

        registry.pokeMigration(
            user1
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            logs.length,
            0
        );

        _assertScheduleEq(
            _captureCohort(
                vaultA,
                refX,
                user1
            ),
            afterX
        );

        _assertReferrerBookEmpty(
            vaultA,
            refY
        );
    }

    // ---- key chain landing back on the original referrer ----

    function test_pokeMigration_keyChainBackToOriginal_clearsWithoutMigration()
        public
    {
        uint256 stampTime = block.timestamp;

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        CohortSnap memory beforeY = _captureCohort(
            vaultA,
            refY,
            user1
        );

        _mergeAsVaultA(
            refX,
            stampTime - 100
        );

        _mergeAsVaultA(
            refZ,
            stampTime - 200
        );

        _mergeAsVaultA(
            refY,
            stampTime - 300
        );

        assertEq(
            registry.referrerOf(user1),
            refY
        );

        assertEq(
            registry.pendingFlip(address(vaultA), user1),
            refY
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit FlipCleared(
            address(vaultA),
            user1,
            refY
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit FlipCleared(
            address(vaultB),
            user1,
            refY
        );

        registry.pokeMigration(
            user1
        );

        _assertScheduleEq(
            _captureCohort(
                vaultA,
                refY,
                user1
            ),
            beforeY
        );

        _assertReferrerBookEmpty(
            vaultA,
            refX
        );

        _assertReferrerBookEmpty(
            vaultA,
            refZ
        );

        assertEq(
            registry.pendingFlip(address(vaultA), user1),
            address(0)
        );

        assertEq(
            registry.pendingFlip(address(vaultB), user1),
            address(0)
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }

    // ---- fuzz: conservation across settle horizons ----

    function testFuzz_pokeMigration_conservationAcrossWarp(
        uint256 _amountSeed,
        uint256 _warpSeed
    )
        public
    {
        uint256 amount = bound(
            _amountSeed,
            1e6,
            9_999 * 1e6
        );

        uint256 warp = bound(
            _warpSeed,
            0,
            160 weeks
        );

        uint256 stampTime = block.timestamp;

        _depositWithReferralOn(
            vaultA,
            user1,
            amount,
            refY
        );

        vm.warp(
            block.timestamp + warp
        );

        _recorderOf(vaultA).advanceBook(
            refY,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        CohortSnap memory beforeY = _captureCohort(
            vaultA,
            refY,
            user1
        );

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        registry.pokeMigration(
            user1
        );

        _assertScheduleEq(
            _captureCohort(
                vaultA,
                refX,
                user1
            ),
            beforeY
        );

        _assertReferrerBookEmpty(
            vaultA,
            refY
        );

        assertEq(
            _recorderOf(vaultA).getTrackedContribution(user1),
            amount
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }
}
