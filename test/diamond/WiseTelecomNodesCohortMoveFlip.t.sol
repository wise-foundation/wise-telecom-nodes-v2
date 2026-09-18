// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {WiseTelecomNodesDiamond} from "../../src/diamond/vault/WiseTelecomNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";

import {TwoVaultCohortHarness} from "./utils/TwoVaultCohortHarness.sol";

/**
 * @dev Same-chain move carry across a PARTIALLY migrated referrer
 * flip. The registry keeps one pending-flip marker per tracked vault
 * and `pokeMigration` clears a marker only when that vault's
 * migration succeeds, so a poke that finds one vault disarmed (the
 * same state an out-of-gas poke or a not-yet-routed flip selector
 * leaves behind) makes the two vaults of one chain name DIFFERENT
 * effective referrers for the same user. The suite drives a move
 * through that state in both directions and pins the destination
 * rule: carried lanes land under the referrer the destination's own
 * registry seam answers, never under the name the source wrote into
 * the envelope, so the book that receives the credit is the book
 * every later clamp on that vault charges. Source deferred: the
 * destination plants under the migrated referrer, a clamp there
 * empties it again, and recycling the same capital through deposit,
 * move and clamp never grows a book nobody can charge. Destination
 * deferred: the credit lands under the marker's old referrer and the
 * later poke relocates it exactly once, leaving a second referee's
 * credit under the old referrer untouched. Both markers standing:
 * the credit lands under the old referrer on both ends and one poke
 * migrates it. The applied event reports the effective referrer next
 * to the carried one so a divergence stays visible offchain. Every
 * scenario closes on the global identity: the four books across both
 * vaults equal the referees' attributed contribution.
 */
contract WiseTelecomNodesCohortMoveFlipTest is TwoVaultCohortHarness {

    event CohortCarryApplied(
        address indexed user,
        address indexed srcVault,
        address indexed referrer,
        address carriedReferrer,
        uint256 trackedDelta,
        uint256 year1,
        uint256 year2,
        uint256 mature,
        uint256 pairCount
    );

    event CohortReferrerFlipApplied(
        address indexed user,
        address indexed oldReferrer,
        address indexed newReferrer,
        uint256 year1,
        uint256 year2,
        uint256 mature,
        uint256 pairCount
    );

    uint256 internal constant STAKE = 1_000 * 1e6;

    uint256 internal constant SECOND_STAKE = 700 * 1e6;

    address internal user1 = address(0xA1);

    address internal user2 = address(0xA2);

    address internal refY = address(0xB1);

    address internal refX = address(0xB2);

    address internal outsider = address(0xC1);

    function setUp()
        public
    {
        _deployCohortPair();

        _armBoth();
    }

    // ---- helpers ----

    function _flipUser1ToRefX()
        internal
    {
        vm.prank(
            address(vaultA)
        );

        registry.mergeReferrer(
            user1,
            refX,
            block.timestamp - 1_000,
            1
        );
    }

    function _pokeWithDeferredOn(
        WiseTelecomNodesDiamond _deferred
    )
        internal
    {
        AdminFacet(address(_deferred)).setCohortSyncEnabled(
            false
        );

        registry.pokeMigration(
            user1
        );

        AdminFacet(address(_deferred)).setCohortSyncEnabled(
            true
        );
    }

    function _clampOutOf(
        WiseTelecomNodesDiamond _vault
    )
        internal
    {
        uint256 balance = _vault.balanceOf(
            user1
        );

        vm.prank(
            user1
        );

        _vault.transfer(
            outsider,
            balance
        );

        _recorderOf(_vault).syncReferee(
            user1
        );
    }

    function _expectApplied(
        address _effective,
        address _carried
    )
        internal
    {
        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortCarryApplied(
            user1,
            address(vaultA),
            _effective,
            _carried,
            STAKE,
            STAKE,
            0,
            0,
            1
        );
    }

    function _globalBook()
        internal
        view
        returns (uint256)
    {
        return _recorderOf(vaultA).getCohortScore(refY)
            + _recorderOf(vaultA).getCohortScore(refX)
            + _recorderOf(vaultB).getCohortScore(refY)
            + _recorderOf(vaultB).getCohortScore(refX);
    }

    function _globalAttributed()
        internal
        view
        returns (uint256)
    {
        return _recorderOf(vaultA).getAttributedContribution(user1)
            + _recorderOf(vaultB).getAttributedContribution(user1)
            + _recorderOf(vaultA).getAttributedContribution(user2)
            + _recorderOf(vaultB).getAttributedContribution(user2);
    }

    function _assertGlobalIdentity()
        internal
        view
    {
        assertEq(
            _globalBook(),
            _globalAttributed()
        );
    }

    // ---- source deferred, destination migrated ----

    function test_move_sourceDeferred_landsUnderDestinationReferrerAndClampsThere()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            STAKE,
            refY
        );

        _flipUser1ToRefX();

        _pokeWithDeferredOn(
            vaultA
        );

        assertEq(
            registry.effectiveReferrerOf(user1, address(vaultA)),
            refY
        );

        assertEq(
            registry.effectiveReferrerOf(user1, address(vaultB)),
            refX
        );

        _expectApplied(
            refX,
            refY
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            STAKE
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refX),
            STAKE
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refY),
            0
        );

        assertEq(
            _recorderOf(vaultA).getCohortScore(refY),
            0
        );

        assertEq(
            _recorderOf(vaultB).getAttributedContribution(user1),
            STAKE
        );

        _assertGlobalIdentity();

        _clampOutOf(
            vaultB
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refX),
            0
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refY),
            0
        );

        assertEq(
            _recorderOf(vaultB).getAttributedContribution(user1),
            0
        );

        _assertGlobalIdentity();
    }

    function test_move_sourceDeferred_recycledCapitalNeverStacksPhantomCredit()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            STAKE,
            refY
        );

        _flipUser1ToRefX();

        _pokeWithDeferredOn(
            vaultA
        );

        for (uint256 i; i < 3; ++i) {

            _moveAs(
                user1,
                vaultA,
                vaultB,
                STAKE
            );

            assertEq(
                _recorderOf(vaultB).getCohortScore(refY),
                0
            );

            assertEq(
                _recorderOf(vaultB).getCohortScore(refX),
                STAKE
            );

            _assertGlobalIdentity();

            _clampOutOf(
                vaultB
            );

            assertEq(
                _globalBook(),
                0
            );

            _assertGlobalIdentity();

            _depositOn(
                vaultA,
                user1,
                STAKE
            );

            assertEq(
                _recorderOf(vaultA).getCohortScore(refY),
                STAKE
            );

            _assertGlobalIdentity();
        }

        assertEq(
            vaultB.balanceOf(user1),
            0
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refY),
            0
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refX),
            0
        );
    }

    // ---- source migrated, destination deferred ----

    function test_move_destinationDeferred_landsUnderMarkerThenPokeMigratesOnce()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            STAKE,
            refY
        );

        _depositWithReferralOn(
            vaultB,
            user2,
            SECOND_STAKE,
            refY
        );

        _flipUser1ToRefX();

        _pokeWithDeferredOn(
            vaultB
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
            STAKE
        );

        _expectApplied(
            refY,
            refX
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            STAKE
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refY),
            STAKE + SECOND_STAKE
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refX),
            0
        );

        assertEq(
            _recorderOf(vaultB).getAttributedContribution(user1),
            STAKE
        );

        assertEq(
            _recorderOf(vaultB).getAttributedContribution(user2),
            SECOND_STAKE
        );

        _assertGlobalIdentity();

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
            STAKE,
            0,
            0,
            1
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refX),
            STAKE
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refY),
            SECOND_STAKE
        );

        assertEq(
            registry.effectiveReferrerOf(user1, address(vaultB)),
            refX
        );

        _assertGlobalIdentity();
    }

    // ---- both markers standing ----

    function test_move_bothMarkersStanding_landsUnderOldReferrerThenPokeMigrates()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            STAKE,
            refY
        );

        _flipUser1ToRefX();

        _expectApplied(
            refY,
            refY
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            STAKE
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refY),
            STAKE
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refX),
            0
        );

        _assertGlobalIdentity();

        registry.pokeMigration(
            user1
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refX),
            STAKE
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refY),
            0
        );

        assertEq(
            registry.effectiveReferrerOf(user1, address(vaultA)),
            refX
        );

        assertEq(
            registry.effectiveReferrerOf(user1, address(vaultB)),
            refX
        );

        _assertGlobalIdentity();
    }
}
