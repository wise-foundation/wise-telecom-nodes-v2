// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ReferralHub} from "../../src/hub/pending/ReferralHub.sol";
import {ReferralHubDeclarations} from "../../src/hub/pending/ReferralHubDeclarations.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";

/**
 * @dev Six-decimal mintable USD stand-in for the hub tests.
 */
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
 * @dev Hub-local payout-rail suite: the claim surface against a
 * pre-funded pot with NO payout vault wired: claim authorization
 * (referrer or resolved payout address, nobody else), full claims,
 * `claimUpTo` clamping to entitlement and to covered funds, the
 * dry-pot and nothing-claimable reverts, the `setPayoutVault`
 * master gate, the designation stamp, and the constructor
 * zero-token guard. The vault-coupled half of the rail (booking,
 * funding pulls, buffer interplay) lives in
 * `test/diamond/WiseTelecomNodesPayoutHub.t.sol` against the real
 * diamond. Accrual here reuses the intake recipe: absolute score
 * report, two dwell-min boundary crossings, one crumb delivery
 * whose lane quantity prices to an exact whole amount (no dust).
 */
contract ReferralHubPayoutTest is Test {

    event PayoutVaultSet(
        address payoutVault
    );

    event PayoutClaimed(
        uint256 indexed chainId,
        address indexed referrer,
        address indexed payout,
        uint256 amount
    );

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    address internal refA = address(0xB1);

    address internal designated = address(0xF2);

    address internal stranger = address(0xC1);

    MockUSD internal usd;

    ReferralHub internal hub;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        usd = new MockUSD();

        hub = new ReferralHub(
            address(usd)
        );

        hub.setAllowedReporter(
            address(this),
            true
        );
    }

    // ---- helpers ----

    function _accrueOneUsd()
        internal
        returns (uint256 expectedPaid)
    {
        hub.reportScores(
            refA,
            6_000 * 1e6,
            0
        );

        uint256 reportWeek = block.timestamp / CohortWeeks.WEEK;

        vm.warp(
            (reportWeek + 3) * CohortWeeks.WEEK + 1 hours
        );

        uint256[] memory weeksArr = new uint256[](1);
        weeksArr[0] = reportWeek + 2;

        uint256[] memory words = new uint256[](1);
        words[0] = CohortWeeks.packLanes(
            100 * CohortWeeks.YEAR * 1e6,
            0,
            0
        );

        hub.deliverCrumbs(
            refA,
            weeksArr,
            words
        );

        expectedPaid = 1e6;
    }

    // ---- constructor ----

    function test_constructor_storesUsdToken()
        public
    {
        assertEq(
            address(hub.USD_TOKEN()),
            address(usd)
        );
    }

    function test_RevertWhen_constructor_zeroToken()
        public
    {
        vm.expectRevert(
            ReferralHubDeclarations.ZeroAddress.selector
        );

        new ReferralHub(
            address(0)
        );
    }

    // ---- setPayoutVault ----

    function test_setPayoutVault_setsAndEmits()
        public
    {
        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(hub)
        );

        emit PayoutVaultSet(
            address(0xA7)
        );

        hub.setPayoutVault(
            address(0xA7)
        );

        assertEq(
            hub.payoutVault(),
            address(0xA7)
        );

        hub.setPayoutVault(
            address(0)
        );

        assertEq(
            hub.payoutVault(),
            address(0)
        );
    }

    function test_RevertWhen_setPayoutVault_calledByStranger()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        hub.setPayoutVault(
            address(0xA7)
        );
    }

    function test_bookLiability_noVault_isNoop()
        public
    {
        _accrueOneUsd();

        hub.bookLiability();

        assertEq(
            hub.totalBooked(),
            0
        );
    }

    // ---- claim ----

    function test_claim_paysFullBalanceFromPreFundedPot()
        public
    {
        uint256 expectedPaid = _accrueOneUsd();

        usd.mint(
            address(hub),
            expectedPaid
        );

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
            usd.balanceOf(refA),
            expectedPaid
        );

        assertEq(
            hub.claimable(block.chainid, refA),
            0
        );

        assertEq(
            hub.totalClaimed(),
            expectedPaid
        );

        assertEq(
            hub.totalAccrued(),
            expectedPaid
        );
    }

    function test_RevertWhen_claim_nothingClaimable()
        public
    {
        vm.prank(
            refA
        );

        vm.expectRevert(
            ReferralHubDeclarations.NothingClaimable.selector
        );

        hub.claim(
            block.chainid,
            refA
        );
    }

    function test_RevertWhen_claim_dryPotWithoutVault()
        public
    {
        _accrueOneUsd();

        vm.prank(
            refA
        );

        vm.expectRevert(
            ReferralHubDeclarations.PotDry.selector
        );

        hub.claim(
            block.chainid,
            refA
        );
    }

    function test_RevertWhen_claim_calledByStranger()
        public
    {
        uint256 expectedPaid = _accrueOneUsd();

        usd.mint(
            address(hub),
            expectedPaid
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            ReferralHubDeclarations.NotPayoutAuthorized.selector
        );

        hub.claim(
            block.chainid,
            refA
        );
    }

    function test_claim_referrerLockedOutAfterDesignation_payoutTriggers()
        public
    {
        uint256 expectedPaid = _accrueOneUsd();

        usd.mint(
            address(hub),
            expectedPaid
        );

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
            usd.balanceOf(designated),
            expectedPaid
        );
    }

    function test_claim_referrerStillAuthorizedAfterDesignation()
        public
    {
        uint256 expectedPaid = _accrueOneUsd();

        usd.mint(
            address(hub),
            expectedPaid
        );

        vm.prank(
            refA
        );

        hub.setPayoutAddress(
            designated
        );

        vm.prank(
            refA
        );

        hub.claim(
            block.chainid,
            refA
        );

        assertEq(
            usd.balanceOf(designated),
            expectedPaid
        );

        assertEq(
            usd.balanceOf(refA),
            0
        );
    }

    // ---- claimUpTo ----

    function test_claimUpTo_clampsToEntitlement()
        public
    {
        uint256 expectedPaid = _accrueOneUsd();

        usd.mint(
            address(hub),
            expectedPaid * 10
        );

        vm.prank(
            refA
        );

        hub.claimUpTo(
            block.chainid,
            refA,
            expectedPaid * 5
        );

        assertEq(
            usd.balanceOf(refA),
            expectedPaid
        );

        assertEq(
            hub.claimable(block.chainid, refA),
            0
        );
    }

    function test_claimUpTo_clampsToHubBalanceWithoutVault()
        public
    {
        uint256 expectedPaid = _accrueOneUsd();

        uint256 potFunds = expectedPaid / 4;

        usd.mint(
            address(hub),
            potFunds
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
            usd.balanceOf(refA),
            potFunds
        );

        assertEq(
            hub.claimable(block.chainid, refA),
            expectedPaid - potFunds
        );

        assertEq(
            hub.totalClaimed(),
            potFunds
        );
    }

    function test_RevertWhen_claimUpTo_nothingClaimable()
        public
    {
        vm.prank(
            refA
        );

        vm.expectRevert(
            ReferralHubDeclarations.NothingClaimable.selector
        );

        hub.claimUpTo(
            block.chainid,
            refA,
            1e6
        );
    }

    function test_RevertWhen_claimUpTo_dryPot()
        public
    {
        _accrueOneUsd();

        vm.prank(
            refA
        );

        vm.expectRevert(
            ReferralHubDeclarations.PotDry.selector
        );

        hub.claimUpTo(
            block.chainid,
            refA,
            1e6
        );
    }

    function test_RevertWhen_claimUpTo_calledByStranger()
        public
    {
        uint256 expectedPaid = _accrueOneUsd();

        usd.mint(
            address(hub),
            expectedPaid
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            ReferralHubDeclarations.NotPayoutAuthorized.selector
        );

        hub.claimUpTo(
            block.chainid,
            refA,
            expectedPaid
        );
    }

    // ---- designation keying ----

    function test_claim_otherChainBucketStaysUntouched()
        public
    {
        uint256 expectedPaid = _accrueOneUsd();

        usd.mint(
            address(hub),
            expectedPaid
        );

        uint256 otherChain = block.chainid + 1;

        assertEq(
            hub.claimable(otherChain, refA),
            0
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            ReferralHubDeclarations.NothingClaimable.selector
        );

        hub.claim(
            otherChain,
            refA
        );

        assertEq(
            hub.claimable(block.chainid, refA),
            expectedPaid
        );
    }

    function test_designation_isPerChain()
        public
    {
        vm.prank(
            refA
        );

        hub.setPayoutAddress(
            designated
        );

        assertEq(
            hub.payoutAddressOf(block.chainid, refA),
            designated
        );

        assertEq(
            hub.payoutAddressOf(block.chainid + 1, refA),
            refA
        );

        assertEq(
            hub.payoutStamp(block.chainid, refA),
            block.timestamp << 8
        );

        assertEq(
            hub.payoutStamp(block.chainid + 1, refA),
            0
        );
    }
}
