// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseTelecomNodesDiamond} from "../../src/diamond/vault/WiseTelecomNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {Permit2ReferralFacet} from "../../src/diamond/vault/facets/pending/Permit2ReferralFacet.sol";
import {GraceFreezeHookFacet} from "../../src/diamond/vault/facets/GraceFreezeHookFacet.sol";
import {IPermit2} from "../../src/diamond/vault/interfaces/IPermit2.sol";

import {WiseTelecomNodesDiamondErrors} from "../../src/diamond/vault/WiseTelecomNodesDiamondErrors.sol";
import {OnlyDelegateCall, SelectorTimelockNotElapsed} from "../../src/diamond/shared/DiamondErrors.sol";

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
 * @dev Mirror of the real Permit2 surface used for unit testing.
 * The signature is intentionally ignored — we only validate the
 * facet's call shape and the resulting token movement; real
 * signature verification is covered by the fork tests against the
 * canonical Permit2 deployment.
 */
contract MockPermit2 is IPermit2 {

    function permitTransferFrom(
        PermitTransferFrom calldata _permit,
        SignatureTransferDetails calldata _transferDetails,
        address _owner,
        bytes calldata
    )
        external
    {
        require(
            block.timestamp <= _permit.deadline,
            "deadline"
        );

        IERC20(_permit.permitted.token).transferFrom(
            _owner,
            _transferDetails.to,
            _transferDetails.requestedAmount
        );
    }
}

/**
 * @dev Tests for the referral registry: the six `...WithReferral`
 * deposit entrypoints on {ReferralFacet} / {Permit2ReferralFacet}
 * (validation, the write-once assignment rule — the first referrer
 * sticks forever, parity with the non-referral paths). The
 * registry is deposit-only by design — the deployed transfer-hook
 * interface carries no amount, so transfers deliberately never
 * touch `referrerOf`, pinned here under the production
 * {GraceFreezeHookFacet}. A live-upgrade simulation walks the exact
 * timelocked propose/execute sequence {UpgradeReferral} runs
 * against the production diamond.
 */
contract WiseTelecomNodesReferralFacetTest is DiamondTestHarness {

    event ReferralSet(
        address indexed user,
        address indexed referrer
    );

    event Deposited(
        address indexed user,
        uint256 amount
    );

    uint256 internal constant THRESHOLD = 10_000 * 1e6;
    uint256 internal constant SELECTOR_DELAY = 3 days;

    bytes32 internal constant REFERRAL_SET_TOPIC = keccak256(
        "ReferralSet(address,address)"
    );

    address internal user1 = address(0xA1);
    address internal user2 = address(0xA2);
    address internal refA = address(0xB1);
    address internal refB = address(0xB2);

    WiseTelecomNodesDiamond internal diamond;
    MockUSD internal usd;

    function setUp()
        public
    {
        vm.warp(
            1_700_000_000
        );

        usd = new MockUSD();

        MockPermit2 mock = new MockPermit2();

        vm.etch(
            CANONICAL_PERMIT2,
            address(mock).code
        );

        diamond = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            diamond
        );

        _wireOne(
            diamond,
            address(new ReferralFacet()),
            WiseTelecomNodesDiamondSelectors.referralSelectors()
        );

        _wireOne(
            diamond,
            address(new Permit2ReferralFacet()),
            WiseTelecomNodesDiamondSelectors.permit2ReferralSelectors()
        );

        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(new GraceFreezeHookFacet())
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        diamond.finalizeSetup();

        usd.mint(
            address(diamond),
            100_000_000 * 1e6
        );

        vm.prank(
            user1
        );

        usd.approve(
            CANONICAL_PERMIT2,
            type(uint256).max
        );

        vm.prank(
            user2
        );

        usd.approve(
            CANONICAL_PERMIT2,
            type(uint256).max
        );
    }

    // ---- helpers ----

    function _fundAndApprove(
        WiseTelecomNodesDiamond _d,
        address _user,
        uint256 _amount
    )
        internal
    {
        usd.mint(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        usd.approve(
            address(_d),
            _amount
        );
    }

    function _depositWithReferralAs(
        WiseTelecomNodesDiamond _d,
        address _user,
        uint256 _amount,
        address _referrer
    )
        internal
    {
        _fundAndApprove(
            _d,
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        ReferralFacet(address(_d)).depositWithReferral(
            _amount,
            _referrer
        );
    }

    function _permit2DepositWithReferral(
        address _user,
        uint256 _amount,
        uint256 _nonce,
        address _referrer
    )
        internal
    {
        usd.mint(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        Permit2ReferralFacet(address(diamond)).depositWithPermit2WithReferral(
            _amount,
            _nonce,
            block.timestamp + 1 hours,
            hex"",
            _referrer
        );
    }

    // ---- 1. wiring, getter, delegatecall guards ----

    function test_referrerOf_defaultZero()
        public
        view
    {
        assertEq(
            diamond.referrerOf(user1),
            address(0)
        );
    }

    function test_referralFacet_directCall_reverts()
        public
    {
        ReferralFacet facet = new ReferralFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        facet.depositWithReferral(
            1_000 * 1e6,
            refA
        );
    }

    function test_permit2ReferralFacet_directCall_reverts()
        public
    {
        Permit2ReferralFacet facet = new Permit2ReferralFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        facet.depositWithPermit2WithReferral(
            1_000 * 1e6,
            0,
            block.timestamp + 1 hours,
            hex"",
            refA
        );
    }

    // ---- 2. referrer validation ----

    function test_depositWithReferral_zeroReferrer_reverts()
        public
    {
        _fundAndApprove(
            diamond,
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.InvalidValue.selector
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            1_000 * 1e6,
            address(0)
        );
    }

    function test_depositWithReferral_selfReferral_reverts()
        public
    {
        _fundAndApprove(
            diamond,
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.SelfReferral.selector
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            1_000 * 1e6,
            user1
        );
    }

    function test_depositAndClaimInterestWithReferral_zeroReferrer_reverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.InvalidValue.selector
        );

        ReferralFacet(address(diamond)).depositAndClaimInterestWithReferral(
            1_000 * 1e6,
            address(0)
        );
    }

    function test_depositAndCompoundInterestWithReferral_selfReferral_reverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.SelfReferral.selector
        );

        ReferralFacet(address(diamond)).depositAndCompoundInterestWithReferral(
            1_000 * 1e6,
            user1
        );
    }

    function test_depositWithPermit2WithReferral_zeroReferrer_reverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.InvalidValue.selector
        );

        Permit2ReferralFacet(address(diamond)).depositWithPermit2WithReferral(
            1_000 * 1e6,
            0,
            block.timestamp + 1 hours,
            hex"",
            address(0)
        );
    }

    function test_depositWithPermit2WithReferral_selfReferral_reverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.SelfReferral.selector
        );

        Permit2ReferralFacet(address(diamond)).depositWithPermit2WithReferral(
            1_000 * 1e6,
            0,
            block.timestamp + 1 hours,
            hex"",
            user1
        );
    }

    function test_depositWithReferral_referrerValidatedBeforeAmount()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.SelfReferral.selector
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            0,
            user1
        );
    }

    // ---- 3. deposit-time assignment rule ----

    function test_depositWithReferral_firstDeposit_setsReferrerAndEmits()
        public
    {
        _fundAndApprove(
            diamond,
            user1,
            1_000 * 1e6
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit ReferralSet(
            user1,
            refA
        );

        vm.prank(
            user1
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            1_000 * 1e6,
            refA
        );

        assertEq(
            diamond.referrerOf(user1),
            refA
        );
    }

    function test_depositWithReferral_smallerSecondDeposit_keepsReferrer()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            1_000 * 1e6,
            refA
        );

        _fundAndApprove(
            diamond,
            user1,
            500 * 1e6
        );

        vm.prank(
            user1
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            500 * 1e6,
            refB
        );

        assertEq(
            diamond.referrerOf(user1),
            refA
        );

        assertEq(
            diamond.balanceOf(user1),
            1_500 * 1e6
        );
    }

    function test_depositWithReferral_equalSecondDeposit_keepsReferrer()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            1_000 * 1e6,
            refA
        );

        _fundAndApprove(
            diamond,
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            1_000 * 1e6,
            refB
        );

        assertEq(
            diamond.referrerOf(user1),
            refA
        );
    }

    function test_depositWithReferral_largerSecondDeposit_keepsReferrer()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            1_000 * 1e6,
            refA
        );

        _fundAndApprove(
            diamond,
            user1,
            2_000 * 1e6
        );

        vm.recordLogs();

        vm.prank(
            user1
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            2_000 * 1e6,
            refB
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != REFERRAL_SET_TOPIC
            );
        }

        assertEq(
            diamond.referrerOf(user1),
            refA
        );
    }

    function test_depositWithReferral_aboveBalanceSecondDeposit_keepsReferrer()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            1_000 * 1e6,
            refA
        );

        _depositWithReferralAs(
            diamond,
            user1,
            1_000 * 1e6 + 1,
            refB
        );

        assertEq(
            diamond.referrerOf(user1),
            refA
        );

        assertEq(
            diamond.balanceOf(user1),
            2_000 * 1e6 + 1
        );
    }

    function test_depositWithReferral_sameReferrerAgain_noEvent()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            1_000 * 1e6,
            refA
        );

        _fundAndApprove(
            diamond,
            user1,
            2_000 * 1e6
        );

        vm.recordLogs();

        vm.prank(
            user1
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            2_000 * 1e6,
            refA
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != REFERRAL_SET_TOPIC
            );
        }

        assertEq(
            diamond.referrerOf(user1),
            refA
        );
    }

    function testFuzz_depositWithReferral_writeOnceRule(
        uint256 _first,
        uint256 _second
    )
        public
    {
        _first = bound(
            _first,
            1,
            400_000 * 1e6
        );

        _second = bound(
            _second,
            1,
            400_000 * 1e6
        );

        _depositWithReferralAs(
            diamond,
            user1,
            _first,
            refA
        );

        _depositWithReferralAs(
            diamond,
            user1,
            _second,
            refB
        );

        assertEq(
            diamond.referrerOf(user1),
            refA
        );
    }

    // ---- 4. plain referral deposits: parity + modifier stacks ----

    function test_depositWithReferral_mintsSharesAndPullsUsd()
        public
    {
        _fundAndApprove(
            diamond,
            user1,
            1_000 * 1e6
        );

        uint256 before3rd = usd.balanceOf(
            thirdPty
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit Deposited(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            1_000 * 1e6,
            refA
        );

        assertEq(
            diamond.balanceOf(user1),
            1_000 * 1e6
        );

        assertEq(
            usd.balanceOf(thirdPty),
            before3rd + 1_000 * 1e6
        );

        assertEq(
            diamond.lastSyncTimeStamp(user1),
            block.timestamp
        );
    }

    function test_depositAndClaimInterestWithReferral_claimsInterest()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            1_000 * 1e6,
            refA
        );

        vm.warp(
            block.timestamp + 365 days
        );

        _fundAndApprove(
            diamond,
            user1,
            1_000 * 1e6
        );

        uint256 beforeUsd = usd.balanceOf(
            user1
        );

        vm.prank(
            user1
        );

        uint256 claimed = ReferralFacet(address(diamond)).depositAndClaimInterestWithReferral(
            1_000 * 1e6,
            refA
        );

        assertGt(
            claimed,
            0
        );

        assertEq(
            usd.balanceOf(user1),
            beforeUsd - 1_000 * 1e6 + claimed
        );
    }

    function test_depositAndCompoundInterestWithReferral_compoundsInterest()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            1_000 * 1e6,
            refA
        );

        vm.warp(
            block.timestamp + 365 days
        );

        _fundAndApprove(
            diamond,
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        uint256 compounded = ReferralFacet(address(diamond)).depositAndCompoundInterestWithReferral(
            1_000 * 1e6,
            refA
        );

        assertGt(
            compounded,
            0
        );

        assertEq(
            diamond.balanceOf(user1),
            2_000 * 1e6 + compounded
        );
    }

    function test_depositWithReferral_depositsDisabled_reverts()
        public
    {
        AdminFacet(address(diamond)).setDepositsDisabled(
            true
        );

        _fundAndApprove(
            diamond,
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.DepositsDisabled.selector
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            1_000 * 1e6,
            refA
        );
    }

    function test_depositWithReferral_whenPaused_reverts()
        public
    {
        AdminFacet(address(diamond)).pauseDeposits();

        _fundAndApprove(
            diamond,
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert();

        ReferralFacet(address(diamond)).depositWithReferral(
            1_000 * 1e6,
            refA
        );
    }

    function test_depositWithReferral_largeDeposit_stampsGrace()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            THRESHOLD,
            refA
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            block.timestamp
        );
    }

    function test_depositWithReferral_graceLocked_stillAllowed()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            THRESHOLD,
            refA
        );

        _depositWithReferralAs(
            diamond,
            user1,
            1_000 * 1e6,
            refA
        );

        assertEq(
            diamond.balanceOf(user1),
            THRESHOLD + 1_000 * 1e6
        );
    }

    function test_depositAndClaimInterestWithReferral_graceLocked_reverts()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            THRESHOLD,
            refA
        );

        _fundAndApprove(
            diamond,
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        ReferralFacet(address(diamond)).depositAndClaimInterestWithReferral(
            1_000 * 1e6,
            refA
        );
    }

    function test_depositAndCompoundInterestWithReferral_graceLocked_reverts()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            THRESHOLD,
            refA
        );

        _fundAndApprove(
            diamond,
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        ReferralFacet(address(diamond)).depositAndCompoundInterestWithReferral(
            1_000 * 1e6,
            refA
        );
    }

    // ---- 5. permit2 referral deposits ----

    function test_depositWithPermit2WithReferral_setsReferrerAndDeposits()
        public
    {
        uint256 before3rd = usd.balanceOf(
            thirdPty
        );

        _permit2DepositWithReferral(
            user1,
            1_000 * 1e6,
            0,
            refA
        );

        assertEq(
            diamond.referrerOf(user1),
            refA
        );

        assertEq(
            diamond.balanceOf(user1),
            1_000 * 1e6
        );

        assertEq(
            usd.balanceOf(thirdPty),
            before3rd + 1_000 * 1e6
        );
    }

    function test_depositAndClaimInterestWithPermit2WithReferral_claims()
        public
    {
        _permit2DepositWithReferral(
            user1,
            1_000 * 1e6,
            0,
            refA
        );

        vm.warp(
            block.timestamp + 365 days
        );

        usd.mint(
            user1,
            1_000 * 1e6
        );

        uint256 beforeUsd = usd.balanceOf(
            user1
        );

        vm.prank(
            user1
        );

        uint256 claimed = Permit2ReferralFacet(address(diamond)).depositAndClaimInterestWithPermit2WithReferral(
            1_000 * 1e6,
            1,
            block.timestamp + 1 hours,
            hex"",
            refA
        );

        assertGt(
            claimed,
            0
        );

        assertEq(
            usd.balanceOf(user1),
            beforeUsd - 1_000 * 1e6 + claimed
        );
    }

    function test_depositAndCompoundInterestWithPermit2WithReferral_compounds()
        public
    {
        _permit2DepositWithReferral(
            user1,
            1_000 * 1e6,
            0,
            refA
        );

        vm.warp(
            block.timestamp + 365 days
        );

        usd.mint(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        uint256 compounded = Permit2ReferralFacet(address(diamond)).depositAndCompoundInterestWithPermit2WithReferral(
            1_000 * 1e6,
            1,
            block.timestamp + 1 hours,
            hex"",
            refA
        );

        assertGt(
            compounded,
            0
        );

        assertEq(
            diamond.balanceOf(user1),
            2_000 * 1e6 + compounded
        );
    }

    function test_depositWithPermit2WithReferral_writeOnceRule()
        public
    {
        _permit2DepositWithReferral(
            user1,
            1_000 * 1e6,
            0,
            refA
        );

        _permit2DepositWithReferral(
            user1,
            2_000 * 1e6,
            1,
            refB
        );

        assertEq(
            diamond.referrerOf(user1),
            refA
        );
    }

    function test_depositWithPermit2WithReferral_expiredDeadline_reverts()
        public
    {
        usd.mint(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            bytes("deadline")
        );

        Permit2ReferralFacet(address(diamond)).depositWithPermit2WithReferral(
            1_000 * 1e6,
            0,
            block.timestamp - 1,
            hex"",
            refA
        );
    }

    function test_depositAndClaimInterestWithPermit2WithReferral_graceLocked_reverts()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            THRESHOLD,
            refA
        );

        usd.mint(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        Permit2ReferralFacet(address(diamond)).depositAndClaimInterestWithPermit2WithReferral(
            1_000 * 1e6,
            0,
            block.timestamp + 1 hours,
            hex"",
            refA
        );
    }

    function test_permit2ReferralFacetConstructor_revertsWhenPermit2Missing()
        public
    {
        vm.etch(
            CANONICAL_PERMIT2,
            hex""
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.Permit2NotDeployed.selector
        );

        new Permit2ReferralFacet();
    }

    // ---- 6. transfers never touch the registry ----

    function test_transfer_doesNotAffectReferrals()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            5_000 * 1e6,
            refA
        );

        vm.prank(
            user1
        );

        diamond.transfer(
            user2,
            1_000 * 1e6
        );

        assertEq(
            diamond.balanceOf(user2),
            1_000 * 1e6
        );

        assertEq(
            diamond.referrerOf(user2),
            address(0)
        );

        assertEq(
            diamond.referrerOf(user1),
            refA
        );
    }

    // ---- 7. live-upgrade simulation ----

    function test_liveUpgrade_timelockedInstall_endToEnd()
        public
    {
        WiseTelecomNodesDiamond live = _deployDiamond(
            address(usd)
        );

        address referral = address(
            new ReferralFacet()
        );

        address permit2Referral = address(
            new Permit2ReferralFacet()
        );

        live.proposeSelectors(
            WiseTelecomNodesDiamondSelectors.referralSelectors(),
            referral
        );

        live.proposeSelectors(
            WiseTelecomNodesDiamondSelectors.permit2ReferralSelectors(),
            permit2Referral
        );

        vm.expectRevert(
            SelectorTimelockNotElapsed.selector
        );

        live.executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors.referralSelectors()
        );

        vm.warp(
            block.timestamp + SELECTOR_DELAY + 1
        );

        live.executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors.referralSelectors()
        );

        live.executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors.permit2ReferralSelectors()
        );

        assertEq(
            live.selectorToFacet(
                bytes4(
                    keccak256("referrerOf(address)")
                )
            ),
            referral
        );

        _depositWithReferralAs(
            live,
            user1,
            5_000 * 1e6,
            refA
        );

        assertEq(
            live.referrerOf(user1),
            refA
        );

        vm.prank(
            user1
        );

        live.transfer(
            user2,
            1_000 * 1e6
        );

        assertEq(
            live.referrerOf(user2),
            address(0)
        );
    }
}
