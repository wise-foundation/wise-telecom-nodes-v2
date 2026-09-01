// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {WiseTelecomNodesDiamond} from "../../../src/diamond/vault/WiseTelecomNodesDiamond.sol";
import {AdminFacet} from "../../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../../src/diamond/vault/facets/UserFacet.sol";
import {MoveFacet} from "../../../src/diamond/vault/facets/MoveFacet.sol";
import {ReferralFacet} from "../../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {CohortHookFacet} from "../../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortBridgeHookFacet} from "../../../src/diamond/vault/facets/pending/CohortBridgeHookFacet.sol";
import {CohortRecorderFacet} from "../../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {ReferralRegistry} from "../../../src/registry/pending/ReferralRegistry.sol";

import {WiseTelecomNodesDiamondSelectors} from "../../../script/diamond/WiseTelecomNodesDiamondSelectors.sol";

import {DiamondTestHarness} from "./DiamondTestHarness.sol";

contract TwoVaultMockUSD is ERC20 {

    constructor()
        ERC20("Mock USD", "MUSD")
    {}

    function decimals()
        public
        pure
        override
        returns (uint8)
    {
        return 6;
    }

    function mint(
        address _to,
        uint256 _amount
    )
        external
    {
        _mint(
            _to,
            _amount
        );
    }
}

/**
 * @dev Two-real-diamond scaffolding for the two-vault cohort suites
 * (same-chain move-carry, referrer-flip and bridge-carry): two fully
 * wired vaults (all facets + queue + referral + cohort recorder +
 * routed {CohortBridgeHookFacet} + {CohortHookFacet} as transfer
 * hook) sharing ONE {ReferralRegistry} (the production per-chain
 * topology) and peer-registered in both directions through
 * the real 3-day `PEER_VAULT_CHANGE_DELAY` (a single shared warp).
 * The test contract is master of both diamonds and of the registry.
 *
 * `CohortSnap` + `_assertScheduleEq` define the round-trip
 * equivalence set: rings (both, all 52 slots), book lanes and
 * `trackedContribution` must match byte for byte, while
 * `cohortLastSettle`, crumbs and the gap log are deliberately
 * EXCLUDED (they are honest per-vault history: settle cursors move
 * with the settles a move itself triggers, and time served on each
 * vault is recorded where it was served).
 */
abstract contract TwoVaultCohortHarness is DiamondTestHarness {

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant PEER_VAULT_CHANGE_DELAY = 3 days;

    WiseTelecomNodesDiamond internal vaultA;

    WiseTelecomNodesDiamond internal vaultB;

    TwoVaultMockUSD internal usdA;

    TwoVaultMockUSD internal usdB;

    ReferralRegistry internal registry;

    struct CohortSnap {
        uint256 tracked;
        uint256 year1;
        uint256 year2;
        uint256 mature;
        uint256 lastSettle;
        uint64[52] ring1;
        uint64[52] ring2;
    }

    function _deployCohortPair()
        internal
    {
        vm.warp(
            BASE_TIME
        );

        usdA = new TwoVaultMockUSD();

        usdB = new TwoVaultMockUSD();

        registry = new ReferralRegistry(
            address(this),
            0
        );

        vaultA = _deployCohortVault(
            address(usdA)
        );

        vaultB = _deployCohortVault(
            address(usdB)
        );

        _peerBothDirections();
    }

    function _deployCohortVault(
        address _usd
    )
        internal
        returns (WiseTelecomNodesDiamond d)
    {
        d = _newDiamond(
            _usd
        );

        _wireAllFacets(
            d
        );

        _wireQueueFacets(
            d
        );

        _wireOne(
            d,
            address(new ReferralFacet()),
            WiseTelecomNodesDiamondSelectors.referralSelectors()
        );

        _wireOne(
            d,
            address(new CohortRecorderFacet()),
            WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors()
        );

        _wireOne(
            d,
            address(new CohortBridgeHookFacet()),
            WiseTelecomNodesDiamondSelectors.cohortBridgeHookSelectors()
        );

        AdminFacet(address(d)).proposeTransferHookFacet(
            address(new CohortHookFacet())
        );

        AdminFacet(address(d)).executeTransferHookFacetChange();

        _wireReferralRegistryShared(
            d,
            registry
        );

        d.finalizeSetup();
    }

    function _peerBothDirections()
        internal
    {
        MoveFacet(address(vaultA)).proposePeerVault(
            address(vaultB)
        );

        MoveFacet(address(vaultB)).proposePeerVault(
            address(vaultA)
        );

        vm.warp(
            block.timestamp + PEER_VAULT_CHANGE_DELAY
        );

        MoveFacet(address(vaultA)).executePeerVaultChange(
            address(vaultB)
        );

        MoveFacet(address(vaultB)).executePeerVaultChange(
            address(vaultA)
        );
    }

    function _armBoth()
        internal
    {
        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );

        AdminFacet(address(vaultB)).setCohortSyncEnabled(
            true
        );
    }

    function _recorderOf(
        WiseTelecomNodesDiamond d
    )
        internal
        pure
        returns (CohortRecorderFacet)
    {
        return CohortRecorderFacet(
            address(d)
        );
    }

    function _usdOf(
        WiseTelecomNodesDiamond d
    )
        internal
        view
        returns (TwoVaultMockUSD)
    {
        return d == vaultA
            ? usdA
            : usdB;
    }

    function _fundAndApproveOn(
        WiseTelecomNodesDiamond d,
        address _user,
        uint256 _amount
    )
        internal
    {
        _usdOf(d).mint(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        _usdOf(d).approve(
            address(d),
            _amount
        );
    }

    function _depositOn(
        WiseTelecomNodesDiamond d,
        address _user,
        uint256 _amount
    )
        internal
    {
        _fundAndApproveOn(
            d,
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        UserFacet(address(d)).deposit(
            _amount
        );
    }

    function _depositWithReferralOn(
        WiseTelecomNodesDiamond d,
        address _user,
        uint256 _amount,
        address _referrer
    )
        internal
    {
        _fundAndApproveOn(
            d,
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        ReferralFacet(address(d)).depositWithReferral(
            _amount,
            _referrer
        );
    }

    function _moveAs(
        address _user,
        WiseTelecomNodesDiamond _src,
        WiseTelecomNodesDiamond _dst,
        uint256 _amount
    )
        internal
    {
        vm.prank(
            _user
        );

        MoveFacet(address(_src)).moveBetweenVaults(
            address(_dst),
            _amount
        );
    }

    function _captureCohort(
        WiseTelecomNodesDiamond d,
        address _referrer,
        address _user
    )
        internal
        view
        returns (CohortSnap memory snap)
    {
        snap.tracked = _recorderOf(d).getTrackedContribution(
            _user
        );

        (
            snap.year1,
            snap.year2,
            snap.mature,
            snap.lastSettle
        ) = _recorderOf(d).getCohortBook(
            _referrer
        );

        (
            snap.ring1,
            snap.ring2
        ) = _recorderOf(d).getCohortRings(
            _referrer
        );
    }

    function _assertScheduleEq(
        CohortSnap memory _left,
        CohortSnap memory _right
    )
        internal
        pure
    {
        assertEq(_left.tracked, _right.tracked);

        assertEq(_left.year1, _right.year1);

        assertEq(_left.year2, _right.year2);

        assertEq(_left.mature, _right.mature);

        for (uint256 i; i < 52; ++i) {

            assertEq(_left.ring1[i], _right.ring1[i]);

            assertEq(_left.ring2[i], _right.ring2[i]);
        }
    }

    function _assertScheduleEmpty(
        CohortSnap memory _snap
    )
        internal
        pure
    {
        assertEq(_snap.tracked, 0);

        assertEq(_snap.year1, 0);

        assertEq(_snap.year2, 0);

        assertEq(_snap.mature, 0);

        for (uint256 i; i < 52; ++i) {

            assertEq(_snap.ring1[i], 0);

            assertEq(_snap.ring2[i], 0);
        }
    }
}
