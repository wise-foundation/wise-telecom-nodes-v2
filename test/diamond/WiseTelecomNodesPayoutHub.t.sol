// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {WiseTelecomNodesDiamond} from "../../src/diamond/vault/WiseTelecomNodesDiamond.sol";
import {WiseTelecomNodesDiamondErrors} from "../../src/diamond/vault/WiseTelecomNodesDiamondErrors.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {SweepFacet} from "../../src/diamond/vault/facets/SweepFacet.sol";
import {ReferralPayoutFacet} from "../../src/diamond/vault/facets/pending/ReferralPayoutFacet.sol";
import {IReferralHub} from "../../src/hub/pending/IReferralHub.sol";
import {HubLeverGrants} from "../hub/utils/HubLeverGrants.sol";
import {HubDiamondHarness} from "../hub/utils/HubDiamondHarness.sol";
import {ReferralHubDeclarations} from "../../src/hub/pending/ReferralHubDeclarations.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";
import {OnlyDelegateCall} from "../../src/diamond/shared/DiamondErrors.sol";

import {WiseTelecomNodesDiamondSelectors} from "../../script/diamond/WiseTelecomNodesDiamondSelectors.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

contract MockUSD is ERC20 {

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
 * @dev Vault half of the referral payout rail: the payout-hub
 * pointer's propose/execute/cancel timelock (instant pre-finalize,
 * 3-day afterwards, shape probe asserting the candidate hub's
 * `USD_TOKEN()` equals the vault's own underlying), the hub-gated
 * `raisePendingReferralPayout` / `fundReferralPayout` writers on the
 * deploy-slim {ReferralPayoutFacet}, their interplay with the sweep
 * buffer reservation, and the full rail end-to-end against a REAL
 * standalone {ReferralHub}: score report → crumb pricing → liability
 * booked on the vault → claim pulls funding out of the vault's USD
 * pool and pays the referrer, leaving every accumulator consistent.
 * With a vault wired a claim pulls its FULL amount through the vault
 * (USD held by the hub itself is never spent and never lowers the
 * booked liability), books any unbooked accrual before it funds, and
 * `claimUpTo` covers from the vault alone.
 */
contract WiseTelecomNodesPayoutHubTest is DiamondTestHarness, HubDiamondHarness {

    event PendingReferralPayoutChanged(
        uint256 pendingReferralPayout
    );

    event PayoutHubSet(
        address payoutHub
    );

    event PayoutHubProposed(
        address indexed proposedPayoutHub,
        uint256 executableAt
    );

    event PayoutHubProposalCancelled(
        address indexed cancelledPayoutHub
    );

    event PayoutLiabilityBooked(
        uint256 amount
    );

    event PayoutClaimed(
        uint256 indexed chainId,
        address indexed referrer,
        address indexed payout,
        uint256 amount
    );

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant PAYOUT_HUB_DELAY = 3 days;

    uint256 internal constant POOL_FUNDS = 10_000 * 1e6;

    address internal refA = address(0xB1);

    address internal stranger = address(0xC1);

    MockUSD internal usd;

    WiseTelecomNodesDiamond internal diamond;

    ReferralPayoutFacet internal payoutFacet;

    IReferralHub internal hub;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        usd = new MockUSD();

        diamond = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            diamond
        );

        payoutFacet = new ReferralPayoutFacet();

        _wireOne(
            diamond,
            address(payoutFacet),
            WiseTelecomNodesDiamondSelectors._referralPayoutSelectors()
        );

        hub = _deployHub(
            address(usd)
        );

        AdminFacet(address(diamond)).proposePayoutHub(
            address(hub)
        );

        AdminFacet(address(diamond)).executePayoutHubChange();

        diamond.finalizeSetup();

        usd.mint(
            address(diamond),
            POOL_FUNDS
        );
    }

    // ---- helpers ----

    function _payout()
        internal
        view
        returns (ReferralPayoutFacet)
    {
        return ReferralPayoutFacet(
            address(diamond)
        );
    }

    function _admin()
        internal
        view
        returns (AdminFacet)
    {
        return AdminFacet(
            address(diamond)
        );
    }

    function _raiseAsHub(
        uint256 _amount
    )
        internal
    {
        vm.prank(
            address(hub)
        );

        _payout().raisePendingReferralPayout(
            _amount
        );
    }

    // ---- pointer lifecycle ----

    function test_payoutHubPointer_wiredInstantlyPreFinalize()
        public
        view
    {
        assertEq(
            _admin().getPayoutHub(),
            address(hub)
        );

        assertEq(
            _admin().getProposedPayoutHub(),
            address(0)
        );

        assertEq(
            _admin().getPayoutHubChangeQueuedAt(),
            0
        );
    }

    function test_payoutHubPointer_lifecycleGettersAndCancel()
        public
    {
        IReferralHub next = _deployHub(
            address(usd)
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit PayoutHubProposed(
            address(next),
            block.timestamp + PAYOUT_HUB_DELAY
        );

        _admin().proposePayoutHub(
            address(next)
        );

        assertEq(
            _admin().getProposedPayoutHub(),
            address(next)
        );

        assertEq(
            _admin().getPayoutHubChangeQueuedAt(),
            block.timestamp
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit PayoutHubProposalCancelled(
            address(next)
        );

        _admin().cancelPayoutHubChange();

        assertEq(
            _admin().getProposedPayoutHub(),
            address(0)
        );

        assertEq(
            _admin().getPayoutHubChangeQueuedAt(),
            0
        );

        assertEq(
            _admin().getPayoutHub(),
            address(hub)
        );
    }

    function test_payoutHubPointer_timelockedExecuteAfterFinalize()
        public
    {
        IReferralHub next = _deployHub(
            address(usd)
        );

        _admin().proposePayoutHub(
            address(next)
        );

        vm.warp(
            block.timestamp + PAYOUT_HUB_DELAY + 1
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(diamond)
        );

        emit PayoutHubSet(
            address(next)
        );

        _admin().executePayoutHubChange();

        assertEq(
            _admin().getPayoutHub(),
            address(next)
        );
    }

    function test_RevertWhen_executePayoutHubChange_nothingProposed()
        public
    {
        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.NoPayoutHubChangeProposed.selector
        );

        _admin().executePayoutHubChange();
    }

    function test_RevertWhen_executePayoutHubChange_timelockNotElapsed()
        public
    {
        _admin().proposePayoutHub(
            address(hub)
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.PayoutHubTimelockNotElapsed.selector
        );

        _admin().executePayoutHubChange();
    }

    function test_RevertWhen_payoutHubPointer_calledByStranger()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        _admin().proposePayoutHub(
            address(hub)
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        _admin().executePayoutHubChange();

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        _admin().cancelPayoutHubChange();
    }

    function test_payoutHubPointer_shapeProbe_rejectsCodelessWrongShapeAndWrongToken()
        public
    {
        _admin().proposePayoutHub(
            address(0xDEAD)
        );

        vm.warp(
            block.timestamp + PAYOUT_HUB_DELAY + 1
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.InvalidValue.selector
        );

        _admin().executePayoutHubChange();

        _admin().proposePayoutHub(
            address(usd)
        );

        vm.warp(
            block.timestamp + PAYOUT_HUB_DELAY + 1
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.InvalidValue.selector
        );

        _admin().executePayoutHubChange();

        IReferralHub wrongToken = _deployHub(
            address(0xBAD1)
        );

        _admin().proposePayoutHub(
            address(wrongToken)
        );

        vm.warp(
            block.timestamp + PAYOUT_HUB_DELAY + 1
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.InvalidValue.selector
        );

        _admin().executePayoutHubChange();

        assertEq(
            _admin().getPayoutHub(),
            address(hub)
        );
    }

    function test_payoutHubPointer_zeroProposal_revertsToOffState()
        public
    {
        _admin().proposePayoutHub(
            address(0)
        );

        vm.warp(
            block.timestamp + PAYOUT_HUB_DELAY + 1
        );

        _admin().executePayoutHubChange();

        assertEq(
            _admin().getPayoutHub(),
            address(0)
        );

        vm.prank(
            address(hub)
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.NotPayoutHub.selector
        );

        _payout().raisePendingReferralPayout(
            1
        );
    }

    // ---- facet writers ----

    function test_raisePendingReferralPayout_raisesAndEmits()
        public
    {
        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(diamond)
        );

        emit PendingReferralPayoutChanged(
            500 * 1e6
        );

        _raiseAsHub(
            500 * 1e6
        );

        assertEq(
            _payout().getPendingReferralPayout(),
            500 * 1e6
        );

        _raiseAsHub(
            250 * 1e6
        );

        assertEq(
            _payout().getPendingReferralPayout(),
            750 * 1e6
        );
    }

    function test_raisePendingReferralPayout_shrinksSweepOverhang()
        public
    {
        uint256 overhangBefore = SweepFacet(address(diamond)).getOverhang();

        _raiseAsHub(
            500 * 1e6
        );

        assertEq(
            SweepFacet(address(diamond)).getOverhang(),
            overhangBefore - 500 * 1e6
        );
    }

    function test_RevertWhen_raise_calledByStranger()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.NotPayoutHub.selector
        );

        _payout().raisePendingReferralPayout(
            1
        );
    }

    function test_RevertWhen_raise_zeroAmount()
        public
    {
        vm.prank(
            address(hub)
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.InvalidValue.selector
        );

        _payout().raisePendingReferralPayout(
            0
        );
    }

    function test_fundReferralPayout_transfersAndLowers()
        public
    {
        _raiseAsHub(
            800 * 1e6
        );

        uint256 overhangBefore = SweepFacet(address(diamond)).getOverhang();

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(diamond)
        );

        emit PendingReferralPayoutChanged(
            500 * 1e6
        );

        vm.prank(
            address(hub)
        );

        _payout().fundReferralPayout(
            300 * 1e6
        );

        assertEq(
            _payout().getPendingReferralPayout(),
            500 * 1e6
        );

        assertEq(
            usd.balanceOf(
                address(hub)
            ),
            300 * 1e6
        );

        assertEq(
            usd.balanceOf(
                address(diamond)
            ),
            POOL_FUNDS - 300 * 1e6
        );

        assertEq(
            SweepFacet(address(diamond)).getOverhang(),
            overhangBefore
        );
    }

    function test_RevertWhen_fund_exceedsPending()
        public
    {
        _raiseAsHub(
            100 * 1e6
        );

        vm.prank(
            address(hub)
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.ExceedsPendingPayout.selector
        );

        _payout().fundReferralPayout(
            100 * 1e6 + 1
        );
    }

    function test_RevertWhen_fund_zeroAmount()
        public
    {
        vm.prank(
            address(hub)
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.InvalidValue.selector
        );

        _payout().fundReferralPayout(
            0
        );
    }

    function test_RevertWhen_fund_calledByStranger()
        public
    {
        _raiseAsHub(
            100 * 1e6
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.NotPayoutHub.selector
        );

        _payout().fundReferralPayout(
            100 * 1e6
        );
    }

    function test_RevertWhen_fund_vaultBalanceShort()
        public
    {
        _raiseAsHub(
            POOL_FUNDS + 500 * 1e6
        );

        vm.prank(
            address(hub)
        );

        vm.expectRevert(
            "ERC20: transfer amount exceeds balance"
        );

        _payout().fundReferralPayout(
            POOL_FUNDS + 1
        );
    }

    function test_RevertWhen_facetWriters_calledDirectlyOnFacet()
        public
    {
        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        payoutFacet.raisePendingReferralPayout(
            1
        );

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        payoutFacet.fundReferralPayout(
            1
        );
    }

    function testFuzz_raiseThenFund_conservesLiability(
        uint256 _raise,
        uint256 _fund
    )
        public
    {
        _raise = bound(
            _raise,
            1,
            POOL_FUNDS
        );

        _fund = bound(
            _fund,
            1,
            _raise
        );

        _raiseAsHub(
            _raise
        );

        vm.prank(
            address(hub)
        );

        _payout().fundReferralPayout(
            _fund
        );

        assertEq(
            _payout().getPendingReferralPayout(),
            _raise - _fund
        );

        assertEq(
            usd.balanceOf(
                address(hub)
            ),
            _fund
        );
    }

    // ---- full rail end-to-end against the real hub ----

    function _accrueOneUsd()
        internal
        returns (uint256 expectedPaid)
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    address(this),
                    true
                )
            )
        );

        uint256 reportWeek = block.timestamp / CohortWeeks.WEEK;

        vm.warp(
            (reportWeek + 1) * CohortWeeks.WEEK + 1 hours
        );

        vm.warp(
            (reportWeek + 3) * CohortWeeks.WEEK + 1 hours
        );

        uint256[] memory weeksArr = new uint256[](1);
        weeksArr[0] = reportWeek + 2;

        uint256[] memory words = new uint256[](1);
        words[0] = CohortWeeks._packLanes(
            100 * CohortWeeks.YEAR * 1e6,
            0,
            0
        );

        hub.deliverCrumbs(
            refA,
            refA,
            weeksArr,
            words
        );

        expectedPaid = 1e6;
    }

    function test_rail_deliveryBooksLiabilityOnVault()
        public
    {
        vm.prank(
            refA
        );

        hub.setPayoutAddress(
            refA
        );

        hub.setPayoutVault(
            address(diamond)
        );

        uint256 expectedPaid = _accrueOneUsd();

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            expectedPaid
        );

        assertEq(
            hub.totalAccrued(),
            expectedPaid
        );

        assertEq(
            hub.totalBooked(),
            expectedPaid
        );

        assertEq(
            _payout().getPendingReferralPayout(),
            expectedPaid
        );
    }

    function test_rail_bookLiability_catchesUpAfterLateWiring()
        public
    {
        vm.prank(
            refA
        );

        hub.setPayoutAddress(
            refA
        );

        uint256 expectedPaid = _accrueOneUsd();

        assertEq(
            _payout().getPendingReferralPayout(),
            0
        );

        assertEq(
            hub.totalBooked(),
            0
        );

        hub.setPayoutVault(
            address(diamond)
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(hub)
        );

        emit PayoutLiabilityBooked(
            expectedPaid
        );

        hub.bookLiability();

        assertEq(
            hub.totalBooked(),
            expectedPaid
        );

        assertEq(
            _payout().getPendingReferralPayout(),
            expectedPaid
        );

        hub.bookLiability();

        assertEq(
            _payout().getPendingReferralPayout(),
            expectedPaid
        );
    }

    function test_rail_claimPullsFundingAndPaysReferrer()
        public
    {
        hub.setPayoutVault(
            address(diamond)
        );

        uint256 expectedPaid = _accrueOneUsd();

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(hub)
        );

        emit PayoutClaimed(
            block.chainid,
            refA,
            refA,
            expectedPaid
        );

        vm.prank(
            refA
        );

        hub.claim(
            block.chainid,
            refA
        );

        assertEq(
            usd.balanceOf(
                refA
            ),
            expectedPaid
        );

        assertEq(
            usd.balanceOf(
                address(hub)
            ),
            0
        );

        assertEq(
            usd.balanceOf(
                address(diamond)
            ),
            POOL_FUNDS - expectedPaid
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            0
        );

        assertEq(
            hub.totalClaimed(),
            expectedPaid
        );

        assertEq(
            _payout().getPendingReferralPayout(),
            0
        );
    }

    function test_rail_claimUpTo_partialLeavesRemainder()
        public
    {
        hub.setPayoutVault(
            address(diamond)
        );

        uint256 expectedPaid = _accrueOneUsd();

        uint256 half = expectedPaid / 2;

        vm.prank(
            refA
        );

        hub.claimUpTo(
            block.chainid,
            refA,
            half
        );

        assertEq(
            usd.balanceOf(
                refA
            ),
            half
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            expectedPaid - half
        );

        assertEq(
            _payout().getPendingReferralPayout(),
            expectedPaid - half
        );
    }

    function test_rail_claimUpTo_clampsToVaultBalance()
        public
    {
        hub.setPayoutVault(
            address(diamond)
        );

        uint256 expectedPaid = _accrueOneUsd();

        uint256 shortPool = expectedPaid / 4;

        vm.prank(
            address(diamond)
        );

        usd.transfer(
            address(0xDEAD),
            POOL_FUNDS - shortPool
        );

        vm.prank(
            refA
        );

        hub.claimUpTo(
            block.chainid,
            refA,
            expectedPaid
        );

        assertEq(
            usd.balanceOf(
                refA
            ),
            shortPool
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            expectedPaid - shortPool
        );
    }

    function test_rail_claimPaysDesignatedPayoutAddress()
        public
    {
        hub.setPayoutVault(
            address(diamond)
        );

        uint256 expectedPaid = _accrueOneUsd();

        address designated = address(0xF2);

        vm.prank(
            refA
        );

        hub.setPayoutAddress(
            designated
        );

        vm.prank(
            designated
        );

        hub.claim(
            block.chainid,
            refA
        );

        assertEq(
            usd.balanceOf(
                designated
            ),
            expectedPaid
        );

        assertEq(
            usd.balanceOf(
                refA
            ),
            0
        );
    }

    // ---- claim rail hardening: full pull through the vault, booking before funding ----

    function test_rail_claim_pullsFullAmountIgnoringHubHeldUsd()
        public
    {
        hub.setPayoutVault(
            address(diamond)
        );

        uint256 expectedPaid = _accrueOneUsd();

        usd.mint(
            address(hub),
            5 * expectedPaid
        );

        vm.prank(
            refA
        );

        hub.claim(
            block.chainid,
            refA
        );

        assertEq(
            usd.balanceOf(
                refA
            ),
            expectedPaid
        );

        assertEq(
            usd.balanceOf(
                address(hub)
            ),
            5 * expectedPaid
        );

        assertEq(
            usd.balanceOf(
                address(diamond)
            ),
            POOL_FUNDS - expectedPaid
        );

        assertEq(
            _payout().getPendingReferralPayout(),
            0
        );
    }

    function test_rail_claim_booksBeforeFundingAfterLateWiring()
        public
    {
        uint256 expectedPaid = _accrueOneUsd();

        hub.setPayoutVault(
            address(diamond)
        );

        assertEq(
            hub.totalBooked(),
            0
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(hub)
        );

        emit PayoutLiabilityBooked(
            expectedPaid
        );

        vm.prank(
            refA
        );

        hub.claim(
            block.chainid,
            refA
        );

        assertEq(
            usd.balanceOf(
                refA
            ),
            expectedPaid
        );

        assertEq(
            hub.totalBooked(),
            expectedPaid
        );

        assertEq(
            _payout().getPendingReferralPayout(),
            0
        );
    }

    function test_rail_claimUpTo_coversFromVaultNotHubBalance()
        public
    {
        hub.setPayoutVault(
            address(diamond)
        );

        uint256 expectedPaid = _accrueOneUsd();

        usd.mint(
            address(hub),
            5 * expectedPaid
        );

        uint256 shortPool = expectedPaid / 4;

        vm.prank(
            address(diamond)
        );

        usd.transfer(
            address(0xDEAD),
            POOL_FUNDS - shortPool
        );

        vm.prank(
            refA
        );

        hub.claimUpTo(
            block.chainid,
            refA,
            expectedPaid
        );

        assertEq(
            usd.balanceOf(
                refA
            ),
            shortPool
        );

        assertEq(
            usd.balanceOf(
                address(hub)
            ),
            5 * expectedPaid
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            expectedPaid - shortPool
        );

        assertEq(
            _payout().getPendingReferralPayout(),
            expectedPaid - shortPool
        );
    }

    function test_rail_claimUpTo_booksBeforeCoverAfterLateWiring()
        public
    {
        uint256 expectedPaid = _accrueOneUsd();

        hub.setPayoutVault(
            address(diamond)
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(hub)
        );

        emit PayoutLiabilityBooked(
            expectedPaid
        );

        vm.prank(
            refA
        );

        hub.claimUpTo(
            block.chainid,
            refA,
            expectedPaid
        );

        assertEq(
            usd.balanceOf(
                refA
            ),
            expectedPaid
        );

        assertEq(
            hub.totalBooked(),
            expectedPaid
        );

        assertEq(
            _payout().getPendingReferralPayout(),
            0
        );
    }

    function test_RevertWhen_rail_claimUpTo_vaultCoversZeroDespiteHubBalance()
        public
    {
        hub.setPayoutVault(
            address(diamond)
        );

        uint256 expectedPaid = _accrueOneUsd();

        usd.mint(
            address(hub),
            expectedPaid
        );

        vm.prank(
            address(diamond)
        );

        usd.transfer(
            address(0xDEAD),
            POOL_FUNDS
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            ReferralHubDeclarations.PotDry.selector
        );

        hub.claimUpTo(
            block.chainid,
            refA,
            expectedPaid
        );
    }
}
