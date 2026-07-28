// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.29;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForwardVaultERC20Migratable} from "../../../src/migration/ForwardVaultERC20Migratable.sol";
import {QueContractMigratable} from "../../../src/migration/QueContractMigratable.sol";
import {QueContract} from "../../../src/legacy/que/QueContractLegacy.sol";

import {WiseTelecomNodesDiamond} from "../../../src/diamond/vault/WiseTelecomNodesDiamond.sol";
import {WiseTelecomNodesInitParams} from "../../../src/diamond/vault/WiseTelecomNodesDiamondStructs.sol";
import {AdminFacet} from "../../../src/diamond/vault/facets/AdminFacet.sol";
import {ProxyFacet} from "../../../src/diamond/vault/facets/ProxyFacet.sol";
import {UserFacet} from "../../../src/diamond/vault/facets/UserFacet.sol";

import {QueueAdminFacet} from "../../../src/diamond/vault/facets/QueueAdminFacet.sol";
import {QueueJoinLeaveFacet} from "../../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../../src/diamond/vault/facets/QueueFulfillFacet.sol";
import {QueueViewFacet} from "../../../src/diamond/vault/facets/QueueViewFacet.sol";

import {WiseTelecomNodesDiamondSelectors} from "../../../script/diamond/WiseTelecomNodesDiamondSelectors.sol";

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
 * @dev Equivalence harness: deploys legacy (Migratable) and diamond
 * vault+queue pairs with identical constructor args, runs the same
 * sequence of actions on both, and asserts return values + state
 * match. Each action gets its own test so a divergence pinpoints
 * the exact code path that drifted.
 */
contract LegacyVsDiamondParityTest is Test {

    MockUSD usd;

    ForwardVaultERC20Migratable lVault;
    QueContractMigratable lQue;

    WiseTelecomNodesDiamond dVault;
    WiseTelecomNodesDiamond dQue;

    address master = address(this);
    address thirdPty = address(0xCAFE);
    address worker = address(0xD00D);
    address user1 = address(0xA1);
    address user2 = address(0xA2);
    address user3 = address(0xA3);
    address fulf = address(0xF1);

    uint256 constant TOTAL_DEPOSIT_CAP = 100_000_000 * 1e6;
    uint256 constant INTEREST_RATE = 2000;
    uint256 constant AUTO_COMPOUND_INC = 500;
    uint256 constant SECONDS_IN_YEAR = 31_540_000;

    function setUp()
        public
    {
        usd = new MockUSD();

        _deployLegacy();
        _deployDiamond();

        usd.mint(
            address(lVault),
            100_000_000 * 1e6
        );

        usd.mint(
            address(dVault),
            100_000_000 * 1e6
        );

        _fundUserBoth(
            user1,
            10_000 * 1e6
        );

        _fundUserBoth(
            user2,
            10_000 * 1e6
        );

        _fundUserBoth(
            user3,
            10_000 * 1e6
        );

        usd.mint(
            fulf,
            100_000 * 1e6
        );

        vm.prank(
            fulf
        );

        usd.approve(
            address(lQue),
            type(uint256).max
        );

        vm.prank(
            fulf
        );

        usd.approve(
            address(dQue),
            type(uint256).max
        );

    }

    function _deployLegacy()
        internal
    {
        address[] memory addrs = new address[](0);
        uint256[] memory amts = new uint256[](0);

        lVault = new ForwardVaultERC20Migratable(
            address(usd),
            thirdPty,
            address(0),
            addrs,
            amts,
            TOTAL_DEPOSIT_CAP,
            INTEREST_RATE,
            AUTO_COMPOUND_INC,
            6,
            "Vault",
            "V"
        );

        lQue = new QueContractMigratable(
            address(lVault)
        );

        lVault.setInterestRateProxy(
            address(lQue)
        );
    }

    function _deployDiamond()
        internal
    {
        AdminFacet vAdmin = new AdminFacet();
        ProxyFacet vProxy = new ProxyFacet();
        UserFacet vUser = new UserFacet();
        QueueAdminFacet qAdmin = new QueueAdminFacet();
        QueueJoinLeaveFacet qJL = new QueueJoinLeaveFacet();
        QueueFulfillFacet qFf = new QueueFulfillFacet();
        QueueViewFacet qView = new QueueViewFacet();

        address[] memory addrs = new address[](0);
        uint256[] memory amts = new uint256[](0);

        dVault = new WiseTelecomNodesDiamond(
            WiseTelecomNodesInitParams({
                usdAddress: address(usd),
                thirdPartyAddress: thirdPty,
                workerAddress: worker,
                oldVault: address(0),
                initialDistributionAddresses: addrs,
                initialDistributionAmounts: amts,
                totalDepositCap: TOTAL_DEPOSIT_CAP,
                interestRate: INTEREST_RATE,
                decimalsValue: 6,
                tokenName: "Vault",
                tokenSymbol: "V"
            })
        );

        _proposeAndExecute(
            WiseTelecomNodesDiamondSelectors.adminSelectors(),
            address(vAdmin)
        );

        _proposeAndExecute(
            WiseTelecomNodesDiamondSelectors.proxySelectors(),
            address(vProxy)
        );

        _proposeAndExecute(
            WiseTelecomNodesDiamondSelectors.userSelectors(),
            address(vUser)
        );

        _proposeAndExecute(
            WiseTelecomNodesDiamondSelectors.queueAdminSelectors(),
            address(qAdmin)
        );

        _proposeAndExecute(
            WiseTelecomNodesDiamondSelectors.queueJoinLeaveSelectors(),
            address(qJL)
        );

        _proposeAndExecute(
            WiseTelecomNodesDiamondSelectors.queueFulfillSelectors(),
            address(qFf)
        );

        _proposeAndExecute(
            WiseTelecomNodesDiamondSelectors.queueViewSelectors(),
            address(qView)
        );

        dVault.finalizeSetup();

        dQue = dVault;
    }

    function _proposeAndExecute(
        bytes4[] memory _selectors,
        address _facet
    )
        internal
    {
        dVault.proposeSelectors(
            _selectors,
            _facet
        );

        dVault.executeSelectorChanges(
            _selectors
        );
    }

    function _fundUserBoth(
        address _user,
        uint256 _amount
    )
        internal
    {
        lVault.mintSupply(
            _user,
            _amount
        );

        AdminFacet(address(dVault)).mintSupply(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        IERC20(address(lVault)).approve(
            address(lQue),
            type(uint256).max
        );

        vm.prank(
            _user
        );

        IERC20(address(dVault)).approve(
            address(dQue),
            type(uint256).max
        );
    }

    // ---- assertion helpers ----

    function _assertVaultParity(
        address _user
    )
        internal
        view
    {
        assertEq(
            lVault.balanceOf(_user),
            IERC20(address(dVault)).balanceOf(_user),
            "balanceOf mismatch"
        );

        assertEq(
            lVault.cashedInterest(_user),
            dVault.cashedInterest(_user),
            "cashedInterest mismatch"
        );

        assertEq(
            lVault.proxyBalance(_user),
            dVault.proxyBalance(_user),
            "proxyBalance mismatch"
        );

        assertEq(
            lVault.lastSyncTimeStamp(_user),
            dVault.lastSyncTimeStamp(_user),
            "lastSyncTimeStamp mismatch"
        );
    }

    function _assertVaultTotalsParity()
        internal
        view
    {
        assertEq(
            lVault.totalSupply(),
            IERC20(address(dVault)).totalSupply(),
            "totalSupply mismatch"
        );

        assertEq(
            usd.balanceOf(thirdPty),
            usd.balanceOf(thirdPty),
            "third-party balance mismatch (this should never trip)"
        );
    }

    function _assertQueueStateParity()
        internal
        view
    {
        assertEq(
            lQue.totalActiveOrders(),
            dQue.totalActiveOrders(),
            "totalActiveOrders mismatch"
        );
    }

    // ---- Test cases ----

    function test_parity_setup_initialState()
        public
        view
    {
        _assertVaultParity(
            user1
        );

        _assertVaultParity(
            user2
        );

        _assertVaultParity(
            user3
        );

        _assertVaultTotalsParity();
        _assertQueueStateParity();
    }

    function test_parity_deposit()
        public
    {
        usd.mint(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        usd.approve(
            address(lVault),
            type(uint256).max
        );

        vm.prank(
            user1
        );

        usd.approve(
            address(dVault),
            type(uint256).max
        );

        vm.prank(
            user1
        );

        lVault.deposit(
            500 * 1e6
        );

        vm.prank(
            user1
        );

        UserFacet(address(dVault)).deposit(
            500 * 1e6
        );

        _assertVaultParity(
            user1
        );

        _assertVaultTotalsParity();
    }

    function test_parity_accrueAndClaim()
        public
    {
        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        vm.prank(
            address(lQue)
        );

        lVault.setProxyBenefactor(
            user1
        );

        vm.prank(
            address(lQue)
        );

        lVault.triggerAssignInterest(
            address(lQue)
        );

        vm.prank(
            address(dQue)
        );

        AdminFacet(address(dVault)).setProxyBenefactor(
            user1
        );

        vm.prank(
            address(dQue)
        );

        ProxyFacet(address(dVault)).triggerAssignInterest(
            address(dQue)
        );

        _assertVaultParity(
            user1
        );

        vm.prank(
            user1
        );

        uint256 lClaimed = lVault.claimInterest();

        vm.prank(
            user1
        );

        uint256 dClaimed = UserFacet(address(dVault)).claimInterest();

        assertEq(
            lClaimed,
            dClaimed,
            "claim amount mismatch"
        );

        _assertVaultParity(
            user1
        );
    }

    function test_parity_compound()
        public
    {
        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        vm.prank(
            address(lQue)
        );

        lVault.setProxyBenefactor(
            user1
        );

        vm.prank(
            address(lQue)
        );

        lVault.triggerAssignInterest(
            address(lQue)
        );

        vm.prank(
            address(dQue)
        );

        AdminFacet(address(dVault)).setProxyBenefactor(
            user1
        );

        vm.prank(
            address(dQue)
        );

        ProxyFacet(address(dVault)).triggerAssignInterest(
            address(dQue)
        );

        vm.prank(
            user1
        );

        uint256 lComp = lVault.compoundInterest();

        vm.prank(
            user1
        );

        uint256 dComp = UserFacet(address(dVault)).compoundInterest();

        assertEq(
            lComp,
            dComp,
            "compound mismatch"
        );

        _assertVaultParity(
            user1
        );

        _assertVaultTotalsParity();
    }

    function test_parity_transfer_basic()
        public
    {
        vm.prank(
            user1
        );

        lVault.transfer(
            user2,
            500 * 1e6
        );

        vm.prank(
            user1
        );

        IERC20(address(dVault)).transfer(
            user2,
            500 * 1e6
        );

        _assertVaultParity(
            user1
        );

        _assertVaultParity(
            user2
        );

        _assertVaultTotalsParity();
    }

    function test_parity_joinQue()
        public
    {
        vm.prank(
            user1
        );

        (
            QueContract.QueMember memory lMember,
            uint256 lId
        ) = lQue.joinQue(
            1_000 * 1e6,
            0
        );

        vm.prank(
            user1
        );

        (
            ,
            uint256 dId
        ) = QueueJoinLeaveFacet(address(dQue)).joinQue(
            1_000 * 1e6,
            0
        );

        assertEq(
            lId,
            dId,
            "queMemberId mismatch"
        );

        assertEq(
            lMember.amount,
            1_000 * 1e6
        );

        _assertVaultParity(
            user1
        );

        _assertQueueStateParity();
    }

    function test_parity_leaveQue()
        public
    {
        vm.prank(
            user1
        );

        (
            ,
            uint256 lId
        ) = lQue.joinQue(
            1_000 * 1e6,
            0
        );

        vm.prank(
            user1
        );

        (
            ,
            uint256 dId
        ) = QueueJoinLeaveFacet(address(dQue)).joinQue(
            1_000 * 1e6,
            0
        );

        vm.prank(
            user1
        );

        lQue.leaveQue(
            lId,
            0
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(dQue)).leaveQue(
            dId,
            0
        );

        _assertVaultParity(
            user1
        );

        _assertQueueStateParity();
    }

    function test_parity_reduceQue()
        public
    {
        vm.prank(
            user1
        );

        (
            ,
            uint256 lId
        ) = lQue.joinQue(
            1_000 * 1e6,
            0
        );

        vm.prank(
            user1
        );

        (
            ,
            uint256 dId
        ) = QueueJoinLeaveFacet(address(dQue)).joinQue(
            1_000 * 1e6,
            0
        );

        vm.prank(
            user1
        );

        lQue.reduceQueAmount(
            lId,
            0,
            400 * 1e6
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(dQue)).reduceQueAmount(
            dId,
            0,
            400 * 1e6
        );

        _assertVaultParity(
            user1
        );

        _assertQueueStateParity();
    }

    function test_parity_fulfillOrder()
        public
    {
        vm.prank(
            user1
        );

        (
            ,
            uint256 lId
        ) = lQue.joinQue(
            1_000 * 1e6,
            0
        );

        vm.prank(
            user1
        );

        (
            ,
            uint256 dId
        ) = QueueJoinLeaveFacet(address(dQue)).joinQue(
            1_000 * 1e6,
            0
        );

        vm.prank(
            fulf
        );

        (
            uint256 lVt,
            uint256 lUsd
        ) = lQue.fulfillOrder(
            lId,
            0
        );

        vm.prank(
            fulf
        );

        (
            uint256 dVt,
            uint256 dUsd
        ) = QueueFulfillFacet(address(dQue)).fulfillOrder(
            dId,
            0
        );

        assertEq(
            lVt,
            dVt,
            "vault token mismatch"
        );

        assertEq(
            lUsd,
            dUsd,
            "USD amount mismatch"
        );

        _assertVaultParity(
            user1
        );

        _assertVaultParity(
            fulf
        );

        _assertQueueStateParity();
    }

    function test_parity_partiallyFulfillOrder()
        public
    {
        vm.prank(
            user1
        );

        (
            ,
            uint256 lId
        ) = lQue.joinQue(
            1_000 * 1e6,
            500
        );

        vm.prank(
            user1
        );

        (
            ,
            uint256 dId
        ) = QueueJoinLeaveFacet(address(dQue)).joinQue(
            1_000 * 1e6,
            500
        );

        vm.prank(
            fulf
        );

        (
            uint256 lVt,
            uint256 lUsd
        ) = lQue.partiallyFulfillOrder(
            lId,
            500,
            300 * 1e6
        );

        vm.prank(
            fulf
        );

        (
            uint256 dVt,
            uint256 dUsd
        ) = QueueFulfillFacet(address(dQue)).partiallyFulfillOrder(
            dId,
            500,
            300 * 1e6
        );

        assertEq(
            lVt,
            dVt,
            "vault token mismatch"
        );

        assertEq(
            lUsd,
            dUsd,
            "USD amount mismatch"
        );

        _assertVaultParity(
            user1
        );

        _assertVaultParity(
            fulf
        );

        _assertQueueStateParity();
    }

    function test_parity_fullSequence_depositCompoundTransferQueueFulfill()
        public
    {
        usd.mint(
            user1,
            4_000 * 1e6
        );

        vm.prank(
            user1
        );

        usd.approve(
            address(lVault),
            type(uint256).max
        );

        vm.prank(
            user1
        );

        usd.approve(
            address(dVault),
            type(uint256).max
        );

        vm.prank(
            user1
        );

        lVault.deposit(
            1_500 * 1e6
        );

        vm.prank(
            user1
        );

        UserFacet(address(dVault)).deposit(
            1_500 * 1e6
        );

        _assertVaultParity(
            user1
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR / 4
        );

        vm.prank(
            user1
        );

        (
            ,
            uint256 lId
        ) = lQue.joinQue(
            800 * 1e6,
            0
        );

        vm.prank(
            user1
        );

        (
            ,
            uint256 dId
        ) = QueueJoinLeaveFacet(address(dQue)).joinQue(
            800 * 1e6,
            0
        );

        _assertVaultParity(
            user1
        );

        _assertQueueStateParity();

        vm.prank(
            fulf
        );

        lQue.fulfillOrder(
            lId,
            0
        );

        vm.prank(
            fulf
        );

        QueueFulfillFacet(address(dQue)).fulfillOrder(
            dId,
            0
        );

        _assertVaultParity(
            user1
        );

        _assertVaultParity(
            fulf
        );

        _assertVaultTotalsParity();
        _assertQueueStateParity();
    }

    function test_parity_settersAlignState()
        public
    {
        lVault.setInterestRate(
            3000
        );

        AdminFacet(address(dVault)).setInterestRate(
            3000
        );

        assertEq(
            lVault.interestRate(),
            dVault.interestRate()
        );

        lVault.setTotalDepositCap(
            50_000_000 * 1e6
        );

        AdminFacet(address(dVault)).setTotalDepositCap(
            50_000_000 * 1e6
        );

        assertEq(
            lVault.totalDepositCap(),
            dVault.totalDepositCap()
        );

        lVault.setThirdPartyAddress(
            user3
        );

        AdminFacet(address(dVault)).proposeThirdPartyAddress(
            user3
        );

        vm.warp(
            block.timestamp + 3 days
        );

        AdminFacet(address(dVault)).executeThirdPartyAddressChange();

        assertEq(
            lVault.thirdPartyAddress(),
            dVault.thirdPartyAddress()
        );

        lQue.changeMinDepositAmount(
            100 * 1e6
        );

        QueueAdminFacet(address(dQue)).changeMinDepositAmount(
            100 * 1e6
        );

        assertEq(
            lQue.minDepositAmount(),
            dQue.minDepositAmount()
        );

        lQue.setNegativeIncentivesNotAllowed(
            true
        );

        QueueAdminFacet(address(dQue)).setNegativeIncentivesNotAllowed(
            true
        );

        assertEq(
            lQue.negativeIncentivesNotAllowed(),
            dQue.negativeIncentivesNotAllowed()
        );
    }
}
