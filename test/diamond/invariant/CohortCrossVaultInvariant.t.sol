// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {WiseTelecomNodesDiamond} from "../../../src/diamond/vault/WiseTelecomNodesDiamond.sol";
import {UserFacet} from "../../../src/diamond/vault/facets/UserFacet.sol";
import {MoveFacet} from "../../../src/diamond/vault/facets/MoveFacet.sol";
import {QueueJoinLeaveFacet} from "../../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {ReferralFacet} from "../../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {CohortRecorderFacet} from "../../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {ReferralRegistry} from "../../../src/registry/pending/ReferralRegistry.sol";

import {TwoVaultCohortHarness, TwoVaultMockUSD} from "../utils/TwoVaultCohortHarness.sol";

/**
 * @dev Drives TWO fully wired cohort diamonds sharing one
 * {ReferralRegistry} through bounded random deposits, transfers,
 * same-chain moves in both directions, queue join/switch/leave on
 * vault A, pokes, advances and three warp granularities. The closed
 * actor set mirrors {CohortRecorderHandler}: A1/A2 pinned to REF via
 * both-vault-visible registry write-once, U unreferred, OUTSIDER a
 * pure sink. Moves run WITHOUT try/catch (a move must
 * never revert on recorder grounds) and each move handler checks the
 * step-level netting property: a referred mover's move changes the
 * GLOBAL book sum (scoreA + scoreB) by exactly the mover's
 * pre-existing lazy deficits on BOTH vaults (the source's pre-burn
 * sync and the destination's pre-mint sync each clamp sale-like);
 * the moved amount itself relocates without loss; an unreferred move
 * never touches any book. A violation increments the sticky
 * `ghostMoveViolations` counter instead of reverting, because the
 * invariant runner tolerates handler-call reverts; the XC6
 * invariant then requires the counter to stay zero. Ghost accounting:
 * `ghostCreditedTotal` accumulates every referred credit ever
 * granted, bounding the global book from above; per-vault ghost crumb
 * snapshots freeze each finalized week's crumb word the moment its
 * settle cursor passes it. The move step also checks the tracked twin
 * of the netting equality for EVERY actor, the unreferred one
 * included: the mover's combined tracked across both vaults must drop
 * by exactly those pre-existing deficits, counted in the sticky
 * `ghostTrackedViolations`.
 */
contract CohortCrossVaultHandler is Test {

    WiseTelecomNodesDiamond internal immutable vaultA;

    WiseTelecomNodesDiamond internal immutable vaultB;

    TwoVaultMockUSD internal immutable usdA;

    TwoVaultMockUSD internal immutable usdB;

    CohortRecorderFacet internal immutable recorderA;

    CohortRecorderFacet internal immutable recorderB;

    address internal immutable a1;

    address internal immutable a2;

    address internal immutable ref;

    address internal immutable u;

    address internal immutable outsider;

    int256 internal constant QUE_INCENTIVE_LOW = 100;

    int256 internal constant QUE_INCENTIVE_HIGH = 200;

    uint256 public ghostCreditedTotal;

    uint256 public ghostMoveViolations;

    uint256 public ghostTrackedViolations;

    uint256 public ghostStartWeek;

    uint256 public ghostNextWeekA;

    uint256 public ghostNextWeekB;

    mapping(uint256 => uint256) public ghostCrumbA;

    mapping(uint256 => uint256) public ghostCrumbB;

    mapping(address => bool) public queActive;

    mapping(address => uint256) public queOrderId;

    mapping(address => int256) public queIncentive;

    constructor(
        WiseTelecomNodesDiamond _vaultA,
        WiseTelecomNodesDiamond _vaultB,
        TwoVaultMockUSD _usdA,
        TwoVaultMockUSD _usdB,
        address[5] memory _actors,
        uint256 _initialCredited
    ) {
        ghostCreditedTotal = _initialCredited;

        vaultA = _vaultA;

        vaultB = _vaultB;

        usdA = _usdA;

        usdB = _usdB;

        recorderA = CohortRecorderFacet(
            address(_vaultA)
        );

        recorderB = CohortRecorderFacet(
            address(_vaultB)
        );

        a1 = _actors[0];

        a2 = _actors[1];

        ref = _actors[2];

        u = _actors[3];

        outsider = _actors[4];

        ghostStartWeek = block.timestamp / 1 weeks;

        ghostNextWeekA = ghostStartWeek;

        ghostNextWeekB = ghostStartWeek;
    }

    modifier captureGhost() {
        _captureFinalizedCrumbs();
        _;
        _captureFinalizedCrumbs();
    }

    function _captureFinalizedCrumbs()
        internal
    {
        (
            ,
            ,
            ,
            uint256 lastSettleA
        ) = recorderA.getCohortBook(
            ref
        );

        if (lastSettleA != 0) {

            uint256 finalizedUpTo = lastSettleA / 1 weeks;

            while (ghostNextWeekA < finalizedUpTo) {

                ghostCrumbA[ghostNextWeekA] = recorderA.getCohortWeekCrumb(
                    ref,
                    ghostNextWeekA
                );

                ++ghostNextWeekA;
            }
        }

        (
            ,
            ,
            ,
            uint256 lastSettleB
        ) = recorderB.getCohortBook(
            ref
        );

        if (lastSettleB != 0) {

            uint256 finalizedUpTo = lastSettleB / 1 weeks;

            while (ghostNextWeekB < finalizedUpTo) {

                ghostCrumbB[ghostNextWeekB] = recorderB.getCohortWeekCrumb(
                    ref,
                    ghostNextWeekB
                );

                ++ghostNextWeekB;
            }
        }
    }

    function _refereeActor(
        uint256 _seed
    )
        internal
        view
        returns (address)
    {
        return _seed % 2 == 0
            ? a1
            : a2;
    }

    function _closedActor(
        uint256 _seed
    )
        internal
        view
        returns (address)
    {
        uint256 i = _seed % 3;

        if (i == 0) {
            return a1;
        }

        if (i == 1) {
            return a2;
        }

        return u;
    }

    function _globalScore()
        internal
        view
        returns (uint256)
    {
        return recorderA.getCohortScore(ref)
            + recorderB.getCohortScore(ref);
    }

    function _depositReferredOn(
        WiseTelecomNodesDiamond _vault,
        TwoVaultMockUSD _usd,
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        internal
    {
        address actor = _refereeActor(
            _actorSeed
        );

        uint256 amount = bound(
            _amountSeed,
            50 * 1e6,
            5_000 * 1e6
        );

        _usd.mint(
            actor,
            amount
        );

        vm.prank(
            actor
        );

        _usd.approve(
            address(_vault),
            amount
        );

        vm.prank(
            actor
        );

        ReferralFacet(address(_vault)).depositWithReferral(
            amount,
            ref
        );

        ghostCreditedTotal += amount;
    }

    function depositReferredOnA(
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        external
        captureGhost
    {
        _depositReferredOn(
            vaultA,
            usdA,
            _actorSeed,
            _amountSeed
        );
    }

    function depositReferredOnB(
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        external
        captureGhost
    {
        _depositReferredOn(
            vaultB,
            usdB,
            _actorSeed,
            _amountSeed
        );
    }

    function depositUnreferredOnA(
        uint256 _amountSeed
    )
        external
        captureGhost
    {
        uint256 amount = bound(
            _amountSeed,
            50 * 1e6,
            5_000 * 1e6
        );

        usdA.mint(
            u,
            amount
        );

        vm.prank(
            u
        );

        usdA.approve(
            address(vaultA),
            amount
        );

        vm.prank(
            u
        );

        UserFacet(address(vaultA)).deposit(
            amount
        );
    }

    function _depositPlainRefereeOn(
        WiseTelecomNodesDiamond _vault,
        TwoVaultMockUSD _usd,
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        internal
    {
        address actor = _refereeActor(
            _actorSeed
        );

        uint256 amount = bound(
            _amountSeed,
            50 * 1e6,
            5_000 * 1e6
        );

        _usd.mint(
            actor,
            amount
        );

        vm.prank(
            actor
        );

        _usd.approve(
            address(_vault),
            amount
        );

        vm.prank(
            actor
        );

        UserFacet(address(_vault)).deposit(
            amount
        );

        if (ReferralFacet(address(_vault)).getReferrerOf(actor) != address(0)) {
            ghostCreditedTotal += amount;
        }
    }

    function depositPlainRefereeOnA(
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        external
        captureGhost
    {
        _depositPlainRefereeOn(
            vaultA,
            usdA,
            _actorSeed,
            _amountSeed
        );
    }

    function depositPlainRefereeOnB(
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        external
        captureGhost
    {
        _depositPlainRefereeOn(
            vaultB,
            usdB,
            _actorSeed,
            _amountSeed
        );
    }

    function transferOutA(
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        external
        captureGhost
    {
        address actor = _closedActor(
            _actorSeed
        );

        uint256 bal = vaultA.balanceOf(
            actor
        );

        if (bal == 0) {
            return;
        }

        uint256 amount = bound(
            _amountSeed,
            1,
            bal
        );

        vm.prank(
            actor
        );

        vaultA.transfer(
            outsider,
            amount
        );
    }

    function transferOutB(
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        external
        captureGhost
    {
        address actor = _closedActor(
            _actorSeed
        );

        uint256 bal = vaultB.balanceOf(
            actor
        );

        if (bal == 0) {
            return;
        }

        uint256 amount = bound(
            _amountSeed,
            1,
            bal
        );

        vm.prank(
            actor
        );

        vaultB.transfer(
            outsider,
            amount
        );
    }

    function _moveBetween(
        WiseTelecomNodesDiamond _src,
        WiseTelecomNodesDiamond _dst,
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        internal
    {
        address actor = _closedActor(
            _actorSeed
        );

        uint256 bal = _src.balanceOf(
            actor
        );

        if (bal == 0) {
            return;
        }

        uint256 amount = bound(
            _amountSeed,
            1,
            bal
        );

        uint256 preDeficit = _pendingDeficit(
            _src,
            actor
        ) + _pendingDeficit(
            _dst,
            actor
        );

        uint256 parkedCharge = _parkedCharge(
            _src,
            actor
        ) + _parkedCharge(
            _dst,
            actor
        );

        uint256 scoreBefore = _globalScore();

        uint256 trackedBefore = _combinedTracked(
            _src,
            _dst,
            actor
        );

        vm.prank(
            actor
        );

        MoveFacet(address(_src)).moveBetweenVaults(
            address(_dst),
            amount
        );

        uint256 expected = actor == u
            ? scoreBefore - parkedCharge
            : scoreBefore - preDeficit - parkedCharge;

        if (_globalScore() != expected) {
            ++ghostMoveViolations;
        }

        uint256 trackedAfter = _combinedTracked(
            _src,
            _dst,
            actor
        );

        if (trackedAfter != trackedBefore - preDeficit) {
            ++ghostTrackedViolations;
        }
    }

    function _pendingDeficit(
        WiseTelecomNodesDiamond _vault,
        address _actor
    )
        internal
        view
        returns (uint256)
    {
        uint256 tracked = CohortRecorderFacet(address(_vault)).getTrackedContribution(
            _actor
        );

        uint256 bal = _vault.balanceOf(
            _actor
        );

        return tracked > bal
            ? tracked - bal
            : 0;
    }

    function _parkedCharge(
        WiseTelecomNodesDiamond _vault,
        address _mover
    )
        internal
        view
        returns (uint256)
    {
        address parked = address(
            uint160(
                uint256(
                    vm.load(
                        address(_vault),
                        bytes32(uint256(91))
                    )
                )
            )
        );

        if (parked == address(0) || parked == _mover) {
            return 0;
        }

        uint256 deficit = _pendingDeficit(
            _vault,
            parked
        );

        uint256 attributed = CohortRecorderFacet(address(_vault)).getAttributedContribution(
            parked
        );

        return deficit < attributed
            ? deficit
            : attributed;
    }

    function _combinedTracked(
        WiseTelecomNodesDiamond _src,
        WiseTelecomNodesDiamond _dst,
        address _actor
    )
        internal
        view
        returns (uint256)
    {
        return CohortRecorderFacet(address(_src)).getTrackedContribution(
            _actor
        ) + CohortRecorderFacet(address(_dst)).getTrackedContribution(
            _actor
        );
    }

    function moveAToB(
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        external
        captureGhost
    {
        _moveBetween(
            vaultA,
            vaultB,
            _actorSeed,
            _amountSeed
        );
    }

    function moveBToA(
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        external
        captureGhost
    {
        _moveBetween(
            vaultB,
            vaultA,
            _actorSeed,
            _amountSeed
        );
    }

    function joinQueOnA(
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        external
        captureGhost
    {
        address actor = _refereeActor(
            _actorSeed
        );

        if (queActive[actor]) {
            return;
        }

        uint256 minDep = vaultA.minDepositAmount();

        uint256 bal = vaultA.balanceOf(
            actor
        );

        if (bal < minDep || bal == 0) {
            return;
        }

        uint256 amount = bound(
            _amountSeed,
            minDep,
            bal
        );

        vm.prank(
            actor
        );

        QueueJoinLeaveFacet(address(vaultA)).joinQue(
            amount,
            QUE_INCENTIVE_LOW
        );

        queActive[actor] = true;

        queOrderId[actor] = vaultA.earliestValidQueMemberByIncentive(
            QUE_INCENTIVE_LOW
        ) - 1;

        queIncentive[actor] = QUE_INCENTIVE_LOW;
    }

    function switchQueOnA(
        uint256 _actorSeed
    )
        external
        captureGhost
    {
        address actor = _refereeActor(
            _actorSeed
        );

        if (queActive[actor] == false) {
            return;
        }

        int256 oldIncentive = queIncentive[actor];

        int256 newIncentive = oldIncentive == QUE_INCENTIVE_LOW
            ? QUE_INCENTIVE_HIGH
            : QUE_INCENTIVE_LOW;

        uint256 id = queOrderId[actor];

        vm.prank(
            actor
        );

        QueueJoinLeaveFacet(address(vaultA)).switchQueIncentive(
            id,
            oldIncentive,
            newIncentive
        );

        queOrderId[actor] = vaultA.earliestValidQueMemberByIncentive(
            newIncentive
        ) - 1;

        queIncentive[actor] = newIncentive;
    }

    function leaveQueOnA(
        uint256 _actorSeed
    )
        external
        captureGhost
    {
        address actor = _refereeActor(
            _actorSeed
        );

        if (queActive[actor] == false) {
            return;
        }

        uint256 id = queOrderId[actor];

        int256 incentive = queIncentive[actor];

        vm.prank(
            actor
        );

        QueueJoinLeaveFacet(address(vaultA)).leaveQue(
            id,
            incentive
        );

        queActive[actor] = false;
    }

    function pokeA(
        uint256 _actorSeed
    )
        external
        captureGhost
    {
        address actor = _closedActor(
            _actorSeed
        );

        recorderA.syncReferee(
            actor
        );
    }

    function pokeB(
        uint256 _actorSeed
    )
        external
        captureGhost
    {
        address actor = _closedActor(
            _actorSeed
        );

        recorderB.syncReferee(
            actor
        );
    }

    function advanceA(
        uint256 _chunkSeed
    )
        external
        captureGhost
    {
        recorderA.advanceBook(
            ref,
            bound(
                _chunkSeed,
                1,
                104
            )
        );
    }

    function advanceB(
        uint256 _chunkSeed
    )
        external
        captureGhost
    {
        recorderB.advanceBook(
            ref,
            bound(
                _chunkSeed,
                1,
                104
            )
        );
    }

    function warpHours(
        uint256 _seed
    )
        external
        captureGhost
    {
        vm.warp(
            block.timestamp + bound(
                _seed,
                1 hours,
                2 days
            )
        );
    }

    function warpWeeks(
        uint256 _seed
    )
        external
        captureGhost
    {
        vm.warp(
            block.timestamp + bound(
                _seed,
                1 weeks,
                10 weeks
            )
        );
    }

    function warpDormant(
        uint256 _seed
    )
        external
        captureGhost
    {
        vm.warp(
            block.timestamp + bound(
                _seed,
                26 weeks,
                110 weeks
            )
        );
    }
}

/**
 * @dev Cross-vault stateful-fuzz invariants for the same-chain move
 * carry: XC1 is the tracked-equals-book identity held PER VAULT
 * while the carry moves tracked and
 * book together between vaults; XC2 is the chain-global conservation
 * statement (the two books together always equal the referees'
 * combined tracked contribution and never exceed the total credit
 * ever granted: moves relocate, clamps only destroy, nothing
 * inflates); XC3 pins the ring-to-lane identity on both vaults (a
 * replant that touched a ring without its book, or vice versa, breaks
 * it); XC4 re-verifies every finalized crumb word on BOTH vaults
 * against the handler's ghost snapshots (a replant may only ever
 * touch open weeks; closed token-second history is immutable); XC5
 * pins registry write-once under two vaults writing concurrently.
 * The per-move netting equality itself is asserted step-level inside
 * the handler's move actions, where the pre-existing deficit is
 * observable; XC7 additionally requires the handler's tracked-netting
 * counter to stay zero, the only place the unreferred mover's
 * self-stake netting across a move is checked.
 */
contract CohortCrossVaultInvariantTest is TwoVaultCohortHarness {

    uint256 internal constant PIN_DEPOSIT = 1_000 * 1e6;

    address internal constant A1 = address(0xA1);

    address internal constant A2 = address(0xA2);

    address internal constant REF = address(0xB1);

    address internal constant U = address(0xA3);

    address internal constant OUTSIDER = address(0xC1);

    CohortCrossVaultHandler internal handler;

    function setUp()
        public
    {
        _deployCohortPair();

        _armBoth();

        _depositWithReferralOn(
            vaultA,
            A1,
            PIN_DEPOSIT,
            REF
        );

        _depositWithReferralOn(
            vaultB,
            A2,
            PIN_DEPOSIT,
            REF
        );

        address[5] memory actors = [
            A1,
            A2,
            REF,
            U,
            OUTSIDER
        ];

        handler = new CohortCrossVaultHandler(
            vaultA,
            vaultB,
            usdA,
            usdB,
            actors,
            2 * PIN_DEPOSIT
        );

        targetContract(
            address(handler)
        );
    }

    // ---- invariants ----

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_XC1_perVaultTrackedSumEqualsBookEqualsScore()
        public
        view
    {
        _assertVaultI1(
            vaultA,
            "XC1-A"
        );

        _assertVaultI1(
            vaultB,
            "XC1-B"
        );
    }

    function _assertVaultI1(
        WiseTelecomNodesDiamond d,
        string memory _tag
    )
        internal
        view
    {
        uint256 attributedSum = _recorderOf(d).getAttributedContribution(A1)
            + _recorderOf(d).getAttributedContribution(A2);

        (
            uint256 year1,
            uint256 year2,
            uint256 mature,

        ) = _recorderOf(d).getCohortBook(REF);

        assertEq(
            attributedSum,
            year1 + year2 + mature,
            string.concat(
                _tag,
                ": attributed sum != book total"
            )
        );

        assertEq(
            _recorderOf(d).getCohortScore(REF),
            year1 + year2 + mature,
            string.concat(
                _tag,
                ": score != book total"
            )
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_XC8_attributedNeverExceedsTrackedBothVaults()
        public
        view
    {
        _assertAttributedBounded(
            vaultA,
            "XC8-A"
        );

        _assertAttributedBounded(
            vaultB,
            "XC8-B"
        );
    }

    function _assertAttributedBounded(
        WiseTelecomNodesDiamond d,
        string memory _tag
    )
        internal
        view
    {
        assertLe(
            _recorderOf(d).getAttributedContribution(A1),
            _recorderOf(d).getTrackedContribution(A1),
            string.concat(
                _tag,
                "-A1: attributed above tracked"
            )
        );

        assertLe(
            _recorderOf(d).getAttributedContribution(A2),
            _recorderOf(d).getTrackedContribution(A2),
            string.concat(
                _tag,
                "-A2: attributed above tracked"
            )
        );

        assertEq(
            _recorderOf(d).getAttributedContribution(U),
            0,
            string.concat(
                _tag,
                "-U: unreferred actor attributed"
            )
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_XC2_globalBookConservation()
        public
        view
    {
        uint256 globalScore = _recorderOf(vaultA).getCohortScore(REF)
            + _recorderOf(vaultB).getCohortScore(REF);

        uint256 globalAttributed = _recorderOf(vaultA).getAttributedContribution(A1)
            + _recorderOf(vaultA).getAttributedContribution(A2)
            + _recorderOf(vaultB).getAttributedContribution(A1)
            + _recorderOf(vaultB).getAttributedContribution(A2);

        assertEq(
            globalScore,
            globalAttributed,
            "XC2: global book != global referee attributed"
        );

        assertLe(
            globalScore,
            handler.ghostCreditedTotal(),
            "XC2: global book exceeds total credit ever granted"
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_XC3_ringLaneIdentityBothVaults()
        public
        view
    {
        _assertVaultRings(
            vaultA,
            "XC3-A"
        );

        _assertVaultRings(
            vaultB,
            "XC3-B"
        );
    }

    function _assertVaultRings(
        WiseTelecomNodesDiamond d,
        string memory _tag
    )
        internal
        view
    {
        (
            uint64[52] memory ring1,
            uint64[52] memory ring2
        ) = _recorderOf(d).getCohortRings(REF);

        uint256 ring1Sum;

        uint256 ring2Sum;

        for (uint256 i; i < 52; ++i) {
            ring1Sum += uint256(ring1[i]);

            ring2Sum += uint256(ring2[i]);
        }

        (
            uint256 year1,
            uint256 year2,
            ,

        ) = _recorderOf(d).getCohortBook(REF);

        assertEq(
            ring1Sum,
            year1,
            string.concat(
                _tag,
                ": ring1 sum != bookY1"
            )
        );

        assertEq(
            ring2Sum,
            year2,
            string.concat(
                _tag,
                ": ring2 sum != bookY2"
            )
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_XC4_finalizedCrumbsImmutableBothVaults()
        public
        view
    {
        uint256 start = handler.ghostStartWeek();

        uint256 nextA = handler.ghostNextWeekA();

        for (uint256 w = start; w < nextA; ++w) {
            assertEq(
                _recorderOf(vaultA).getCohortWeekCrumb(REF, w),
                handler.ghostCrumbA(w),
                "XC4-A: finalized crumb mutated"
            );
        }

        uint256 nextB = handler.ghostNextWeekB();

        for (uint256 w = start; w < nextB; ++w) {
            assertEq(
                _recorderOf(vaultB).getCohortWeekCrumb(REF, w),
                handler.ghostCrumbB(w),
                "XC4-B: finalized crumb mutated"
            );
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_XC6_moveNettingNeverViolated()
        public
        view
    {
        assertEq(
            handler.ghostMoveViolations(),
            0,
            "XC6: a move failed the netting equality"
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_XC7_moveTrackedNettingNeverViolated()
        public
        view
    {
        assertEq(
            handler.ghostTrackedViolations(),
            0,
            "XC7: a move failed the tracked netting equality"
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_XC5_registryReferrerImmutable()
        public
        view
    {
        assertEq(
            registry.referrerOf(A1),
            REF,
            "XC5: A1 referrer changed"
        );

        assertEq(
            registry.referrerOf(A2),
            REF,
            "XC5: A2 referrer changed"
        );

        assertEq(
            ReferralFacet(address(vaultA)).getReferrerOf(A1),
            REF,
            "XC5: vaultA routed getter drifted"
        );

        assertEq(
            ReferralFacet(address(vaultB)).getReferrerOf(A2),
            REF,
            "XC5: vaultB routed getter drifted"
        );
    }
}
