// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.29;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForwardVaultERC20Migratable} from "../../src/migration/ForwardVaultERC20Migratable.sol";
import {ForwardVaultERC20}            from "../../src/legacy/ForwardVaultERC20Legacy.sol";

contract MockUSD is ERC20 {
    constructor() ERC20("Mock USD", "MUSD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }
}

contract MockOldVault {
    mapping(address => uint256) public interestByUser;

    function setInterest(address _user, uint256 _amount) external {
        interestByUser[_user] = _amount;
    }

    function getTotalInterestUser(address _user) external view returns (uint256) {
        return interestByUser[_user];
    }
}

contract BadOldVault {
    function getTotalInterestUser(address) external pure returns (uint256) {
        revert("bad");
    }
}

/**
 * Exhaustive coverage of ForwardVaultERC20Legacy + ForwardVaultERC20HelperLegacy +
 * ForwardVaultERC20DeclarationsLegacy + OwnableMasterLegacy. Uses
 * ForwardVaultERC20Migratable as the test handle (a thin extension that adds
 * setProxyBalance without modifying any other behavior). Mirrors the existing
 * QueContractFunctional pattern.
 */
contract ForwardVaultERC20LegacyTest is Test {

    MockUSD                     usd;
    ForwardVaultERC20Migratable vault;

    address master    = address(this);
    address thirdPty  = address(0xCAFE);
    address user1     = address(0xA1);
    address user2     = address(0xA2);
    address user3     = address(0xA3);
    address attacker  = address(0xBEEF);
    address proxy     = address(0xC0DE);
    address benefactor = address(0xB1);

    uint256 constant TOTAL_DEPOSIT_CAP        = 1_000_000_000 * 1e6;
    uint256 constant INTEREST_RATE            = 2000;   // 20%
    uint256 constant AUTO_COMPOUND_INCENTIVE  = 500;    // 5%
    uint256 constant SECONDS_IN_YEAR          = 31_540_000;
    uint256 constant PRECISION                = 10_000;
    uint8   constant VAULT_DECIMALS           = 6;

    event ProxyBenefactorSet(address proxyBeneFactor);
    event TransferInterestWithTokensSet(address indexed user, bool transferInterestWithTokens);
    event WithdrawStatusChanged(bool withdrawAllowed);
    event InterestRateProxySet(address interestRateProxy);
    event SupplyChangeByOwnerNotAllowedSet(bool supplyChangeByOwnerNotAllowed);
    event MintSupply(address indexed to, uint256 amount);
    event BurnSupply(address indexed from, uint256 amount);
    event Deposited(address indexed user, uint256 amount);
    event ThirdPartyAddressSet(address thirdPartyAddress);
    event InterestRateSet(uint256 interestRate);
    event TotalDepositCapSet(uint256 totalDepositCap);
    event ClaimInterestSimple(address indexed user, uint256 interest);
    event ClaimInterestWithIncentive(address indexed user, address indexed destination, uint256 interest, uint256 incentive);
    event CompoundInterest(address indexed user, uint256 interest);
    event ClaimInterestExactAmount(address indexed user, uint256 amount);
    event AutoCompoundAllowedSet(address indexed user, bool isAllowed);
    event WhiteListAddressSet(address indexed user, bool isWhiteListed);
    event Withdrawn(address indexed user, uint256 amount);
    event ProxyBalanceIncreased(address indexed proxyUser, uint256 amount);
    event ProxyBalanceDecreased(address indexed proxyUser, uint256 amount);
    event MasterProposed(address indexed proposer, address indexed proposedMaster);
    event RenouncedOwnership(address indexed previousMaster);

    function setUp() public {
        usd = new MockUSD();

        address[] memory addrs = new address[](0);
        uint256[] memory amts  = new uint256[](0);

        vault = new ForwardVaultERC20Migratable(
            address(usd),
            thirdPty,
            address(0),
            addrs,
            amts,
            TOTAL_DEPOSIT_CAP,
            INTEREST_RATE,
            AUTO_COMPOUND_INCENTIVE,
            VAULT_DECIMALS,
            "Forward Vault",
            "FV"
        );

        usd.mint(address(vault), 100_000_000 * 1e6);

        vault.allowWithdraw();
    }

    // -------------------------------------------------------------------
    // 1. Constructor / Declarations
    // -------------------------------------------------------------------

    function _deployVault(
        address _usd,
        address _thirdPty,
        uint256 _cap,
        uint256 _rate
    ) internal returns (ForwardVaultERC20Migratable) {
        address[] memory addrs = new address[](0);
        uint256[] memory amts  = new uint256[](0);
        return new ForwardVaultERC20Migratable(
            _usd,
            _thirdPty,
            address(0),
            addrs,
            amts,
            _cap,
            _rate,
            AUTO_COMPOUND_INCENTIVE,
            VAULT_DECIMALS,
            "FV",
            "FV"
        );
    }

    function test_constructor_revertsOnZeroInterestRate() public {
        vm.expectRevert();
        _deployVault(address(usd), thirdPty, TOTAL_DEPOSIT_CAP, 0);
    }

    function test_constructor_revertsOnZeroCap() public {
        vm.expectRevert();
        _deployVault(address(usd), thirdPty, 0, INTEREST_RATE);
    }

    function test_constructor_revertsOnZeroUsdAddress() public {
        vm.expectRevert();
        _deployVault(address(0), thirdPty, TOTAL_DEPOSIT_CAP, INTEREST_RATE);
    }

    function test_constructor_revertsOnZeroThirdParty() public {
        vm.expectRevert();
        _deployVault(address(usd), address(0), TOTAL_DEPOSIT_CAP, INTEREST_RATE);
    }

    function test_constructor_initialDistribution() public {
        address[] memory addrs = new address[](2);
        addrs[0] = user1;
        addrs[1] = user2;
        uint256[] memory amts = new uint256[](2);
        amts[0] = 100 * 1e6;
        amts[1] = 250 * 1e6;

        ForwardVaultERC20Migratable v = new ForwardVaultERC20Migratable(
            address(usd),
            thirdPty,
            address(0),
            addrs,
            amts,
            TOTAL_DEPOSIT_CAP,
            INTEREST_RATE,
            AUTO_COMPOUND_INCENTIVE,
            VAULT_DECIMALS,
            "FV",
            "FV"
        );

        assertEq(v.balanceOf(user1), 100 * 1e6);
        assertEq(v.balanceOf(user2), 250 * 1e6);
        assertEq(v.lastSyncTimeStamp(user1), block.timestamp);
        assertEq(v.lastSyncTimeStamp(user2), block.timestamp);
        assertEq(v.totalSupply(), 350 * 1e6);
    }

    function test_constructor_migratesInterestFromOldVault() public {
        MockOldVault old = new MockOldVault();
        old.setInterest(user1, 12_345);
        old.setInterest(user2, 67_890);

        address[] memory addrs = new address[](2);
        addrs[0] = user1;
        addrs[1] = user2;
        uint256[] memory amts = new uint256[](2);
        amts[0] = 100 * 1e6;
        amts[1] = 200 * 1e6;

        ForwardVaultERC20Migratable v = new ForwardVaultERC20Migratable(
            address(usd),
            thirdPty,
            address(old),
            addrs,
            amts,
            TOTAL_DEPOSIT_CAP,
            INTEREST_RATE,
            AUTO_COMPOUND_INCENTIVE,
            VAULT_DECIMALS,
            "FV",
            "FV"
        );

        assertEq(v.cashedInterest(user1), 12_345);
        assertEq(v.cashedInterest(user2), 67_890);
    }

    function test_constructor_migrationRevertsOnBadOldVault() public {
        BadOldVault bad = new BadOldVault();

        address[] memory addrs = new address[](1);
        addrs[0] = user1;
        uint256[] memory amts = new uint256[](1);
        amts[0] = 100;

        vm.expectRevert();
        new ForwardVaultERC20Migratable(
            address(usd),
            thirdPty,
            address(bad),
            addrs,
            amts,
            TOTAL_DEPOSIT_CAP,
            INTEREST_RATE,
            AUTO_COMPOUND_INCENTIVE,
            VAULT_DECIMALS,
            "FV",
            "FV"
        );
    }

    function test_constants_immutables() public view {
        assertEq(address(vault.USD_TOKEN()), address(usd));
        assertEq(vault.interestRate(), INTEREST_RATE);
        assertEq(vault.autoCompoundIncentive(), AUTO_COMPOUND_INCENTIVE);
        assertEq(vault.totalDepositCap(), TOTAL_DEPOSIT_CAP);
        assertEq(vault.thirdPartyAddress(), thirdPty);
        assertEq(vault.master(), master);
        assertEq(vault.IERC20Decimals(), bytes4(keccak256("decimals()")));
        assertEq(vault.decimals(), VAULT_DECIMALS);
        assertEq(vault.name(), "Forward Vault");
        assertEq(vault.symbol(), "FV");
    }

    // -------------------------------------------------------------------
    // 2. OwnableMaster
    // -------------------------------------------------------------------

    function test_proposeOwner_master_emits() public {
        vm.expectEmit(true, true, false, true);
        emit MasterProposed(master, user1);
        vault.proposeOwner(user1);
        assertEq(vault.proposedMaster(), user1);
    }

    function test_proposeOwner_revertsOnZero() public {
        vm.expectRevert();
        vault.proposeOwner(address(0));
    }

    function test_proposeOwner_nonMasterReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.proposeOwner(user1);
    }

    function test_claimOwnership_proposedClaims() public {
        vault.proposeOwner(user1);
        vm.prank(user1);
        vault.claimOwnership();
        assertEq(vault.master(), user1);
    }

    function test_claimOwnership_nonProposedReverts() public {
        vault.proposeOwner(user1);
        vm.prank(user2);
        vm.expectRevert();
        vault.claimOwnership();
    }

    function test_renounceOwnership_master_clearsAll() public {
        vault.proposeOwner(user1);
        vm.expectEmit(true, false, false, true);
        emit RenouncedOwnership(master);
        vault.renounceOwnership();
        assertEq(vault.master(), address(0));
        assertEq(vault.proposedMaster(), address(0));
    }

    function test_renounceOwnership_nonMasterReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.renounceOwnership();
    }

    // -------------------------------------------------------------------
    // 3. Admin: master-only state setters
    // -------------------------------------------------------------------

    function test_allowWithdraw_emitsEvent() public {
        vault.disallowWithdraw();
        vm.expectEmit(false, false, false, true);
        emit WithdrawStatusChanged(true);
        vault.allowWithdraw();
        assertTrue(vault.withdrawAllowed());
    }

    function test_disallowWithdraw_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit WithdrawStatusChanged(false);
        vault.disallowWithdraw();
        assertFalse(vault.withdrawAllowed());
    }

    function test_allowWithdraw_nonMasterReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.allowWithdraw();
    }

    function test_disallowWithdraw_nonMasterReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.disallowWithdraw();
    }

    function test_disAllowSupplyChangeByOwner_setsFlag() public {
        vm.expectEmit(false, false, false, true);
        emit SupplyChangeByOwnerNotAllowedSet(true);
        vault.disAllowSupplyChangeByOwner();
        assertTrue(vault.supplyChangeByOwnerNotAllowed());
    }

    function test_disAllowSupplyChangeByOwner_blocksMint() public {
        vault.disAllowSupplyChangeByOwner();
        vm.expectRevert();
        vault.mintSupply(user1, 100);
    }

    function test_disAllowSupplyChangeByOwner_blocksBurn() public {
        vault.mintSupply(user1, 100 * 1e6);
        vault.disAllowSupplyChangeByOwner();
        vm.expectRevert();
        vault.burnSupply(user1, 1);
    }

    function test_disAllowSupplyChangeByOwner_nonMasterReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.disAllowSupplyChangeByOwner();
    }

    function test_mintSupply_master_emits() public {
        vm.expectEmit(true, false, false, true);
        emit MintSupply(user1, 500 * 1e6);
        vault.mintSupply(user1, 500 * 1e6);
        assertEq(vault.balanceOf(user1), 500 * 1e6);
        assertEq(vault.lastSyncTimeStamp(user1), block.timestamp);
    }

    function test_burnSupply_master_emits() public {
        vault.mintSupply(user1, 500 * 1e6);
        vm.expectEmit(true, false, false, true);
        emit BurnSupply(user1, 100 * 1e6);
        vault.burnSupply(user1, 100 * 1e6);
        assertEq(vault.balanceOf(user1), 400 * 1e6);
    }

    function test_mintSupply_nonMasterReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.mintSupply(user1, 1);
    }

    function test_burnSupply_nonMasterReverts() public {
        vault.mintSupply(user1, 1);
        vm.prank(attacker);
        vm.expectRevert();
        vault.burnSupply(user1, 1);
    }

    function test_pauseDeposits_blocksDeposit() public {
        vault.pauseDeposits();
        usd.mint(user1, 1_000 * 1e6);
        vm.prank(user1);
        usd.approve(address(vault), type(uint256).max);
        vm.prank(user1);
        vm.expectRevert();
        vault.deposit(100 * 1e6);
    }

    function test_unpauseDeposits_resumesDeposit() public {
        vault.pauseDeposits();
        vault.unpauseDeposits();
        usd.mint(user1, 1_000 * 1e6);
        vm.prank(user1);
        usd.approve(address(vault), type(uint256).max);
        vm.prank(user1);
        vault.deposit(100 * 1e6);
        assertEq(vault.balanceOf(user1), 100 * 1e6);
    }

    function test_pause_unpause_nonMasterReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.pauseDeposits();
        vault.pauseDeposits();
        vm.prank(attacker);
        vm.expectRevert();
        vault.unpauseDeposits();
    }

    function test_setThirdPartyAddress_master_emits() public {
        vm.expectEmit(false, false, false, true);
        emit ThirdPartyAddressSet(user1);
        vault.setThirdPartyAddress(user1);
        assertEq(vault.thirdPartyAddress(), user1);
    }

    function test_setThirdPartyAddress_nonMasterReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.setThirdPartyAddress(user1);
    }

    function test_setInterestRate_master_emits() public {
        vm.expectEmit(false, false, false, true);
        emit InterestRateSet(5000);
        vault.setInterestRate(5000);
        assertEq(vault.interestRate(), 5000);
    }

    function test_setInterestRate_nonMasterReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.setInterestRate(1);
    }

    function test_setTotalDepositCap_master_emits() public {
        vm.expectEmit(false, false, false, true);
        emit TotalDepositCapSet(9999);
        vault.setTotalDepositCap(9999);
        assertEq(vault.totalDepositCap(), 9999);
    }

    function test_setTotalDepositCap_nonMasterReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.setTotalDepositCap(1);
    }

    function test_whiteListAddress_emits_andRemoves() public {
        vm.expectEmit(true, false, false, true);
        emit WhiteListAddressSet(user1, true);
        vault.whiteListAddress(user1);
        assertTrue(vault.isWhiteListed(user1));

        vm.expectEmit(true, false, false, true);
        emit WhiteListAddressSet(user1, false);
        vault.removeWhiteListAddress(user1);
        assertFalse(vault.isWhiteListed(user1));
    }

    function test_whiteList_nonMasterReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.whiteListAddress(user1);
        vm.prank(attacker);
        vm.expectRevert();
        vault.removeWhiteListAddress(user1);
    }

    function test_setInterestRateProxy_setsOnce() public {
        vm.expectEmit(false, false, false, true);
        emit InterestRateProxySet(proxy);
        vault.setInterestRateProxy(proxy);
        assertEq(vault.InterestRateProxy(), proxy);

        vm.expectRevert();
        vault.setInterestRateProxy(user2);
    }

    function test_setInterestRateProxy_nonMasterReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.setInterestRateProxy(proxy);
    }

    function test_setInterestRateProxyPermanent_setsFlag_allowsChange() public {
        vault.setInterestRateProxy(proxy);
        vault.setInterestRateProxyPermanent();
        assertTrue(vault.interestRateProxyPermanent());

        vault.setInterestRateProxy(user2);
        assertEq(vault.InterestRateProxy(), user2);
    }

    function test_setInterestRateProxyPermanent_nonMasterReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.setInterestRateProxyPermanent();
    }

    function test_setProxyBenefactor_proxy_emits() public {
        vault.setInterestRateProxy(proxy);

        vm.expectEmit(false, false, false, true);
        emit ProxyBenefactorSet(benefactor);
        vm.prank(proxy);
        vault.setProxyBenefactor(benefactor);

        assertEq(vault.currentProxyBenefactor(), benefactor);
    }

    function test_setProxyBenefactor_nonProxyReverts() public {
        vault.setInterestRateProxy(proxy);
        vm.prank(attacker);
        vm.expectRevert();
        vault.setProxyBenefactor(benefactor);
    }

    // -------------------------------------------------------------------
    // 4. Proxy: triggerAssignInterest, increase/decrease proxy balance
    // -------------------------------------------------------------------

    function test_triggerAssignInterest_proxy_writesCashedInterest() public {
        vault.setInterestRateProxy(proxy);
        vault.mintSupply(user1, 1_000 * 1e6);

        vm.prank(proxy);
        vault.setProxyBenefactor(user1);

        vm.warp(block.timestamp + SECONDS_IN_YEAR);

        vm.prank(proxy);
        vault.triggerAssignInterest(proxy);

        uint256 expected = (1_000 * 1e6) * INTEREST_RATE / PRECISION;
        assertApproxEqAbs(vault.cashedInterest(user1), expected, 10);
        assertEq(vault.lastSyncTimeStamp(user1), block.timestamp);
    }

    function test_triggerAssignInterest_nonProxyReverts() public {
        vault.setInterestRateProxy(proxy);
        vm.prank(attacker);
        vm.expectRevert();
        vault.triggerAssignInterest(user1);
    }

    function test_increaseProxyBalance_proxy_emits() public {
        vault.setInterestRateProxy(proxy);
        vm.expectEmit(true, false, false, true);
        emit ProxyBalanceIncreased(user1, 500);
        vm.prank(proxy);
        vault.increaseProxyBalance(user1, 500);
        assertEq(vault.proxyBalance(user1), 500);
    }

    function test_increaseProxyBalance_nonProxyReverts() public {
        vault.setInterestRateProxy(proxy);
        vm.prank(attacker);
        vm.expectRevert();
        vault.increaseProxyBalance(user1, 1);
    }

    function test_decreaseProxyBalance_proxy_emits() public {
        vault.setInterestRateProxy(proxy);
        vm.prank(proxy);
        vault.increaseProxyBalance(user1, 500);

        vm.expectEmit(true, false, false, true);
        emit ProxyBalanceDecreased(user1, 200);
        vm.prank(proxy);
        vault.decreaseProxyBalance(user1, 200);
        assertEq(vault.proxyBalance(user1), 300);
    }

    function test_decreaseProxyBalance_nonProxyReverts() public {
        vault.setInterestRateProxy(proxy);
        vm.prank(attacker);
        vm.expectRevert();
        vault.decreaseProxyBalance(user1, 1);
    }

    // -------------------------------------------------------------------
    // 5. Deposits
    // -------------------------------------------------------------------

    function _setupUser(address _user, uint256 _amount) internal {
        usd.mint(_user, _amount);
        vm.prank(_user);
        usd.approve(address(vault), type(uint256).max);
    }

    function test_deposit_transfersAndMints_emits() public {
        _setupUser(user1, 1_000 * 1e6);

        uint256 before3rd = usd.balanceOf(thirdPty);

        vm.expectEmit(true, false, false, true);
        emit Deposited(user1, 100 * 1e6);

        vm.prank(user1);
        vault.deposit(100 * 1e6);

        assertEq(vault.balanceOf(user1), 100 * 1e6);
        assertEq(usd.balanceOf(thirdPty), before3rd + 100 * 1e6);
        assertEq(vault.lastSyncTimeStamp(user1), block.timestamp);
    }

    function test_deposit_zeroReverts() public {
        _setupUser(user1, 1_000 * 1e6);
        vm.prank(user1);
        vm.expectRevert();
        vault.deposit(0);
    }

    function test_deposit_overCapReverts() public {
        vault.setTotalDepositCap(100 * 1e6);
        _setupUser(user1, 1_000 * 1e6);
        vm.prank(user1);
        vm.expectRevert();
        vault.deposit(101 * 1e6);
    }

    function test_deposit_whenPausedReverts() public {
        vault.pauseDeposits();
        _setupUser(user1, 1_000 * 1e6);
        vm.prank(user1);
        vm.expectRevert();
        vault.deposit(1);
    }

    // -------------------------------------------------------------------
    // 6. Withdrawals
    // -------------------------------------------------------------------

    function test_withdraw_whenAllowed_burnsAndTransfers() public {
        vault.mintSupply(user1, 500 * 1e6);

        uint256 userUsdBefore = usd.balanceOf(user1);

        vm.expectEmit(true, false, false, true);
        emit Withdrawn(user1, 200 * 1e6);

        vm.prank(user1);
        vault.withdraw(200 * 1e6);

        assertEq(vault.balanceOf(user1), 300 * 1e6);
        assertEq(usd.balanceOf(user1), userUsdBefore + 200 * 1e6);
    }

    function test_withdraw_notAllowedReverts() public {
        vault.disallowWithdraw();
        vault.mintSupply(user1, 100 * 1e6);
        vm.prank(user1);
        vm.expectRevert();
        vault.withdraw(1);
    }

    function test_withdraw_insufficientBalance() public {
        vault.mintSupply(user1, 1);
        vm.prank(user1);
        vm.expectRevert();
        vault.withdraw(2);
    }

    function test_withdraw_insufficientContractUSD() public {
        ForwardVaultERC20Migratable v = _deployVault(address(usd), thirdPty, TOTAL_DEPOSIT_CAP, INTEREST_RATE);
        v.allowWithdraw();
        v.mintSupply(user1, 1_000 * 1e6);

        vm.prank(user1);
        vm.expectRevert();
        v.withdraw(500 * 1e6);
    }

    function test_withdraw_whenPausedReverts() public {
        vault.pauseDeposits();
        vault.mintSupply(user1, 100);
        vm.prank(user1);
        vm.expectRevert();
        vault.withdraw(1);
    }

    // -------------------------------------------------------------------
    // 7. Interest accrual + assignInterest modifier behavior
    // -------------------------------------------------------------------

    function test_pendingInterest_zeroBalance_returnsZero() public view {
        assertEq(vault.getPendingInterest(user1), 0);
    }

    function test_pendingInterest_basic() public {
        vault.mintSupply(user1, 1_000 * 1e6);
        vm.warp(block.timestamp + SECONDS_IN_YEAR);

        uint256 expected = (1_000 * 1e6) * INTEREST_RATE / PRECISION;
        assertApproxEqAbs(vault.getPendingInterest(user1), expected, 10);
    }

    function test_pendingInterest_proxyReturnsZero() public {
        vault.setInterestRateProxy(proxy);
        assertEq(vault.getPendingInterest(proxy), 0);
    }

    function test_pendingInterest_timestampBeforeSyncReturnsZero() public {
        vault.mintSupply(user1, 1_000);
        uint256 syncAt = vault.lastSyncTimeStamp(user1);
        assertEq(vault.getPendingInterestByTimeStamp(user1, syncAt), 0);
    }

    function test_pendingInterest_includesProxyBalance() public {
        vault.setInterestRateProxy(proxy);
        vm.prank(proxy);
        vault.increaseProxyBalance(user1, 1_000 * 1e6);
        // assignInterest only fires on state-changing fns; set sync manually via deposit-like flow
        vault.mintSupply(user1, 1);
        vm.warp(block.timestamp + SECONDS_IN_YEAR);

        // total balance is 1 + 1_000e6 ≈ 1_000e6
        uint256 expected = (1 + 1_000 * 1e6) * INTEREST_RATE / PRECISION;
        assertApproxEqAbs(vault.getPendingInterest(user1), expected, 100);
    }

    function test_getPendingInterestBulk_returnsArray() public {
        vault.mintSupply(user1, 1_000 * 1e6);
        vault.mintSupply(user2, 2_000 * 1e6);
        vm.warp(block.timestamp + SECONDS_IN_YEAR);

        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        uint256[] memory r = vault.getPendingInterestBulk(users);
        assertEq(r.length, 2);
        assertGt(r[0], 0);
        assertGt(r[1], 0);
        assertGt(r[1], r[0]);
    }

    function test_getPendingInterestBulkByTimeStamp_returnsArray() public {
        vault.mintSupply(user1, 1_000 * 1e6);
        vault.mintSupply(user2, 2_000 * 1e6);

        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        uint256 at = block.timestamp + SECONDS_IN_YEAR;

        uint256[] memory r = vault.getPendingInterestBulkByTimeStamp(users, at);
        assertEq(r.length, 2);
        assertGt(r[0], 0);
        assertGt(r[1], 0);
    }

    function test_getTotalInterestUser_includesCashed() public {
        vault.mintSupply(user1, 1_000 * 1e6);
        vm.warp(block.timestamp + SECONDS_IN_YEAR);

        // triggerAssignInterest moves pending → cashed
        vault.setInterestRateProxy(proxy);
        vm.prank(proxy);
        vault.setProxyBenefactor(user1);
        vm.prank(proxy);
        vault.triggerAssignInterest(proxy);

        // After assignment, pending is 0 but cashed > 0
        assertGt(vault.cashedInterest(user1), 0);
        assertEq(vault.getPendingInterest(user1), 0);
        assertGt(vault.getTotalInterestUser(user1), 0);
        assertEq(vault.getTotalInterestUser(user1), vault.cashedInterest(user1));
    }

    function test_getTotalInterestUserBulk_andByTimeStamp() public {
        vault.mintSupply(user1, 1_000 * 1e6);
        vault.mintSupply(user2, 1_500 * 1e6);

        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        uint256[] memory now1  = vault.getTotalInterestUserBulk(users);
        uint256[] memory then1 = vault.getTotalInterestUserBulkByTimeStamp(users, block.timestamp + SECONDS_IN_YEAR);

        assertEq(now1.length, 2);
        assertEq(then1.length, 2);
        assertEq(now1[0], 0);
        assertGt(then1[0], 0);
    }

    function test_assignInterest_proxyAssignsToBenefactor() public {
        vault.setInterestRateProxy(proxy);
        vault.mintSupply(user1, 100 * 1e6);
        vm.prank(proxy);
        vault.setProxyBenefactor(user1);

        vm.warp(block.timestamp + SECONDS_IN_YEAR / 2);

        vm.prank(proxy);
        vault.triggerAssignInterest(proxy);

        assertEq(vault.lastSyncTimeStamp(user1), block.timestamp);
        assertGt(vault.cashedInterest(user1), 0);
    }

    function test_assignInterest_zeroAddressBenefactor_noop() public {
        vault.setInterestRateProxy(proxy);
        // currentProxyBenefactor defaults to ZERO_ADDRESS
        vm.prank(proxy);
        vault.triggerAssignInterest(proxy);
        // no revert, no state change
        assertEq(vault.cashedInterest(address(0)), 0);
    }

    // -------------------------------------------------------------------
    // 8. claimInterest variants
    // -------------------------------------------------------------------

    function _cashInterest(address _user, uint256 _amount) internal {
        deal(address(vault), _user, _amount, false);
        // Use setter on storage if available, else mintSupply+warp+assign
        vm.store(
            address(vault),
            keccak256(abi.encode(_user, uint256(15))),
            bytes32(_amount)
        );
    }

    function _accrueRealInterest(address _user, uint256 _principal) internal returns (uint256) {
        vault.mintSupply(_user, _principal);
        vm.warp(block.timestamp + SECONDS_IN_YEAR);

        vault.setInterestRateProxy(proxy);
        vm.prank(proxy);
        vault.setProxyBenefactor(_user);
        vm.prank(proxy);
        vault.triggerAssignInterest(proxy);

        return vault.cashedInterest(_user);
    }

    function test_claimInterest_basic_emits_transfers() public {
        uint256 cached = _accrueRealInterest(user1, 1_000 * 1e6);
        uint256 usdBefore = usd.balanceOf(user1);

        vm.expectEmit(true, false, false, true);
        emit ClaimInterestSimple(user1, cached);

        vm.prank(user1);
        uint256 ret = vault.claimInterest();

        assertEq(ret, cached);
        assertEq(usd.balanceOf(user1), usdBefore + cached);
        assertEq(vault.cashedInterest(user1), 0);
    }

    function test_claimInterest_noInterestReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.claimInterest();
    }

    function test_claimInterest_whenPausedReverts() public {
        _accrueRealInterest(user1, 1_000 * 1e6);
        vault.pauseDeposits();
        vm.prank(user1);
        vm.expectRevert();
        vault.claimInterest();
    }

    function test_claimInterestExactAmount_basic() public {
        uint256 cached = _accrueRealInterest(user1, 1_000 * 1e6);
        uint256 toClaim = cached / 2;

        vm.expectEmit(true, false, false, true);
        emit ClaimInterestExactAmount(user1, toClaim);

        vm.prank(user1);
        uint256 ret = vault.claimInterestExactAmount(toClaim);

        assertEq(ret, toClaim);
        assertEq(vault.cashedInterest(user1), cached - toClaim);
    }

    function test_claimInterestExactAmount_zeroReverts() public {
        _accrueRealInterest(user1, 1_000 * 1e6);
        vm.prank(user1);
        vm.expectRevert();
        vault.claimInterestExactAmount(0);
    }

    function test_claimInterestExactAmount_insufficientReverts() public {
        uint256 cached = _accrueRealInterest(user1, 1_000 * 1e6);
        vm.prank(user1);
        vm.expectRevert();
        vault.claimInterestExactAmount(cached + 1);
    }

    function test_claimInterestPartiallyAndCompound_combines() public {
        uint256 cached = _accrueRealInterest(user1, 1_000 * 1e6);
        uint256 part = cached / 4;

        uint256 supplyBefore = vault.totalSupply();
        uint256 vaultBalanceBefore = vault.balanceOf(user1);

        vm.prank(user1);
        uint256 ret = vault.claimInterestPartiallyAndCompound(part);

        assertGt(ret, part);
        assertEq(vault.cashedInterest(user1), 0);
        assertGt(vault.totalSupply(), supplyBefore);
        assertGt(vault.balanceOf(user1), vaultBalanceBefore);
    }

    // -------------------------------------------------------------------
    // 9. compoundInterest variants
    // -------------------------------------------------------------------

    function test_compoundInterest_basic_mintsAndEmits() public {
        uint256 cached = _accrueRealInterest(user1, 1_000 * 1e6);
        uint256 supplyBefore = vault.totalSupply();
        uint256 userBalanceBefore = vault.balanceOf(user1);

        vm.expectEmit(true, false, false, true);
        emit CompoundInterest(user1, cached);

        vm.prank(user1);
        uint256 ret = vault.compoundInterest();

        assertEq(ret, cached);
        assertEq(vault.balanceOf(user1), userBalanceBefore + cached);
        assertEq(vault.totalSupply(), supplyBefore + cached);
        assertEq(vault.cashedInterest(user1), 0);
    }

    function test_compoundInterest_noInterestReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.compoundInterest();
    }

    function test_compoundInterest_overCapReverts() public {
        uint256 cached = _accrueRealInterest(user1, 1_000 * 1e6);
        vault.setTotalDepositCap(vault.totalSupply() + cached - 1);
        vm.prank(user1);
        vm.expectRevert();
        vault.compoundInterest();
    }

    function test_compoundInterestOnBehalf_whitelistedRequired() public {
        _accrueRealInterest(user1, 1_000 * 1e6);
        vm.prank(user1);
        vault.allowAutoCompound();

        // Not whitelisted
        vm.prank(attacker);
        vm.expectRevert();
        vault.compoundInterestOnBehalf(user1);
    }

    function test_compoundInterestOnBehalf_requiresAutoCompound() public {
        _accrueRealInterest(user1, 1_000 * 1e6);
        vault.whiteListAddress(user2);
        vm.prank(user2);
        vm.expectRevert();
        vault.compoundInterestOnBehalf(user1);
    }

    function test_compoundInterestOnBehalf_paysIncentive() public {
        uint256 cached = _accrueRealInterest(user1, 1_000 * 1e6);

        vm.prank(user1);
        vault.allowAutoCompound();
        vault.whiteListAddress(user2);

        uint256 expectedIncentive = cached * AUTO_COMPOUND_INCENTIVE / PRECISION;
        uint256 expectedCompound = cached - expectedIncentive;

        uint256 user2UsdBefore = usd.balanceOf(user2);

        vm.expectEmit(true, true, false, true);
        emit ClaimInterestWithIncentive(user1, user2, cached, expectedIncentive);

        vm.prank(user2);
        uint256 ret = vault.compoundInterestOnBehalf(user1);

        assertEq(ret, cached);
        assertEq(usd.balanceOf(user2), user2UsdBefore + expectedIncentive);
        assertEq(vault.cashedInterest(user1), 0);
        // user1 received expectedCompound mint
        assertEq(vault.balanceOf(user1), 1_000 * 1e6 + expectedCompound);
    }

    function test_compoundInterestOnBehalf_overCapReverts() public {
        uint256 cached = _accrueRealInterest(user1, 1_000 * 1e6);
        vm.prank(user1);
        vault.allowAutoCompound();
        vault.whiteListAddress(user2);

        uint256 expectedCompound = cached - (cached * AUTO_COMPOUND_INCENTIVE / PRECISION);
        vault.setTotalDepositCap(vault.totalSupply() + expectedCompound - 1);

        vm.prank(user2);
        vm.expectRevert();
        vault.compoundInterestOnBehalf(user1);
    }

    function test_depositAndClaimInterest_combined() public {
        uint256 cached = _accrueRealInterest(user1, 1_000 * 1e6);

        _setupUser(user1, 500 * 1e6);
        uint256 usdBefore = usd.balanceOf(user1);

        vm.prank(user1);
        uint256 ret = vault.depositAndClaimInterest(100 * 1e6);

        assertGt(ret, 0);
        // Final USD = before - deposited + claimed
        assertEq(usd.balanceOf(user1), usdBefore - 100 * 1e6 + ret);
        assertGe(ret, cached);
        assertEq(vault.cashedInterest(user1), 0);
    }

    function test_depositAndCompoundInterest_combined() public {
        uint256 cached = _accrueRealInterest(user1, 1_000 * 1e6);

        _setupUser(user1, 500 * 1e6);
        uint256 supplyBefore = vault.totalSupply();

        vm.prank(user1);
        uint256 ret = vault.depositAndCompoundInterest(100 * 1e6);

        assertGe(ret, cached);
        assertEq(vault.cashedInterest(user1), 0);
        // supply grew by deposit + compound
        assertGt(vault.totalSupply(), supplyBefore + 100 * 1e6);
    }

    // -------------------------------------------------------------------
    // 10. Auto-compound and transferInterestWithTokens user settings
    // -------------------------------------------------------------------

    function test_allowAutoCompound_emits() public {
        vm.expectEmit(true, false, false, true);
        emit AutoCompoundAllowedSet(user1, true);
        vm.prank(user1);
        vault.allowAutoCompound();
        assertTrue(vault.autoCompoundAllowed(user1));
    }

    function test_disallowAutoCompound_emits() public {
        vm.prank(user1);
        vault.allowAutoCompound();

        vm.expectEmit(true, false, false, true);
        emit AutoCompoundAllowedSet(user1, false);
        vm.prank(user1);
        vault.disallowAutoCompound();
        assertFalse(vault.autoCompoundAllowed(user1));
    }

    function test_setTransferInterestWithTokens_emits() public {
        vm.expectEmit(true, false, false, true);
        emit TransferInterestWithTokensSet(user1, true);
        vm.prank(user1);
        vault.setTransferInterestWithTokens(true);
        assertTrue(vault.transferInterestWithTokens(user1));
    }

    // -------------------------------------------------------------------
    // 11. ERC20 transfer / transferFrom overrides
    // -------------------------------------------------------------------

    function test_transfer_basic() public {
        vault.mintSupply(user1, 1_000 * 1e6);
        vm.prank(user1);
        bool ok = vault.transfer(user2, 200 * 1e6);
        assertTrue(ok);
        assertEq(vault.balanceOf(user1), 800 * 1e6);
        assertEq(vault.balanceOf(user2), 200 * 1e6);
    }

    function test_transfer_zeroReverts() public {
        vault.mintSupply(user1, 100);
        vm.prank(user1);
        vm.expectRevert();
        vault.transfer(user2, 0);
    }

    function test_transfer_movesInterestWhenFlagged() public {
        uint256 cached = _accrueRealInterest(user1, 1_000 * 1e6);
        vm.prank(user1);
        vault.setTransferInterestWithTokens(true);

        vm.prank(user1);
        vault.transfer(user2, 500 * 1e6);

        assertEq(vault.cashedInterest(user1), 0);
        assertEq(vault.cashedInterest(user2), cached);
    }

    function test_transfer_doesNotMoveInterestWhenUnflagged() public {
        uint256 cached = _accrueRealInterest(user1, 1_000 * 1e6);

        vm.prank(user1);
        vault.transfer(user2, 500 * 1e6);

        assertEq(vault.cashedInterest(user1), cached);
        assertEq(vault.cashedInterest(user2), 0);
    }

    function test_transfer_doesNotMoveInterestWhenToProxy() public {
        uint256 cached = _accrueRealInterest(user1, 1_000 * 1e6);

        vm.prank(user1);
        vault.setTransferInterestWithTokens(true);

        vm.prank(user1);
        vault.transfer(proxy, 100 * 1e6);

        assertEq(vault.cashedInterest(user1), cached);
        assertEq(vault.cashedInterest(proxy), 0);
    }

    function test_transferFrom_basic() public {
        vault.mintSupply(user1, 1_000 * 1e6);
        vm.prank(user1);
        vault.approve(user2, 500 * 1e6);

        vm.prank(user2);
        bool ok = vault.transferFrom(user1, user3, 200 * 1e6);
        assertTrue(ok);
        assertEq(vault.balanceOf(user1), 800 * 1e6);
        assertEq(vault.balanceOf(user3), 200 * 1e6);
    }

    function test_transferFrom_zeroReverts() public {
        vault.mintSupply(user1, 100);
        vm.prank(user1);
        vault.approve(user2, 100);
        vm.prank(user2);
        vm.expectRevert();
        vault.transferFrom(user1, user3, 0);
    }

    function test_transferFrom_movesInterestWhenFlagged() public {
        uint256 cached = _accrueRealInterest(user1, 1_000 * 1e6);
        vm.prank(user1);
        vault.setTransferInterestWithTokens(true);

        vm.prank(user1);
        vault.approve(user2, type(uint256).max);

        vm.prank(user2);
        vault.transferFrom(user1, user3, 500 * 1e6);

        assertEq(vault.cashedInterest(user1), 0);
        assertEq(vault.cashedInterest(user3), cached);
    }

    function test_transfer_sameAddress_moveInterestNoop() public {
        uint256 cached = _accrueRealInterest(user1, 1_000 * 1e6);
        vm.prank(user1);
        vault.setTransferInterestWithTokens(true);

        vm.prank(user1);
        vault.transfer(user1, 100);
        assertEq(vault.cashedInterest(user1), cached);
    }

    // -------------------------------------------------------------------
    // 12. Edge cases — back-to-back assignments, double increase/decrease
    // -------------------------------------------------------------------

    function test_decreaseProxyBalance_underflowReverts() public {
        vault.setInterestRateProxy(proxy);
        vm.prank(proxy);
        vm.expectRevert();
        vault.decreaseProxyBalance(user1, 1);
    }

    function test_setProxyBenefactor_changeBenefactorReassignsForNew() public {
        vault.setInterestRateProxy(proxy);
        vault.mintSupply(user1, 1_000 * 1e6);
        vault.mintSupply(user2, 1_500 * 1e6);

        vm.prank(proxy);
        vault.setProxyBenefactor(user1);

        vm.warp(block.timestamp + SECONDS_IN_YEAR);

        vm.prank(proxy);
        vault.triggerAssignInterest(proxy);

        uint256 user1Cached = vault.cashedInterest(user1);
        assertGt(user1Cached, 0);

        vm.prank(proxy);
        vault.setProxyBenefactor(user2);

        vm.warp(block.timestamp + SECONDS_IN_YEAR);

        vm.prank(proxy);
        vault.triggerAssignInterest(proxy);

        assertGt(vault.cashedInterest(user2), 0);
        // user1 should still have the prior cached amount
        assertEq(vault.cashedInterest(user1), user1Cached);
    }

    // -------------------------------------------------------------------
    // 13. Reentrancy guard sanity (nonReentrant marker presence)
    // -------------------------------------------------------------------

    function test_nonReentrant_doesNotBlockSequential() public {
        vault.mintSupply(user1, 1_000 * 1e6);
        vm.prank(user1);
        vault.transfer(user2, 100);

        vault.mintSupply(user1, 500);
        vm.prank(user1);
        vault.transfer(user2, 50);
    }
}
