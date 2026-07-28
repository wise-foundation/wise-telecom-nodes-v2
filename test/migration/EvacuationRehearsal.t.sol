// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TestUSD} from "../../src/bridgetest/TestUSD.sol";
import {MockPoolManagerV4} from "../../src/bridgetest/MockPoolManagerV4.sol";
import {MoneyForwardContractV4} from "../../src/migration-v3/MoneyForwardContractV4.sol";

/**
 * @dev Live v2 vault surface used by the rehearsal. The concrete
 * contract is the real =0.8.29 `ForwardVaultERC20Migratable`, deployed
 * via `deployCode` so this =0.8.36 test never imports the legacy
 * source.
 */
interface IMockOldVault {

    function master()
        external
        view
        returns (address);

    function proposeOwner(
        address _newOwner
    )
        external;

    function balanceOf(
        address _account
    )
        external
        view
        returns (uint256);

    function getTotalInterestUser(
        address _user
    )
        external
        view
        returns (uint256);
}

/**
 * @dev A borrower that repays one wei short, to prove the mock
 * PoolManager enforces exact repayment with `CurrencyNotSettled`
 * (the same guard the real singleton was proven to have).
 */
contract UnderpayingBorrower {

    MockPoolManagerV4 internal immutable MANAGER;
    address internal immutable TOKEN;

    constructor(
        MockPoolManagerV4 _manager,
        address _token
    ) {
        MANAGER = _manager;
        TOKEN = _token;
    }

    function flash(
        uint256 _amount
    )
        external
    {
        MANAGER.unlock(
            abi.encode(
                _amount
            )
        );
    }

    function unlockCallback(
        bytes calldata _data
    )
        external
        returns (bytes memory)
    {
        uint256 amount = abi.decode(
            _data,
            (uint256)
        );

        MANAGER.take(
            TOKEN,
            address(this),
            amount
        );

        MANAGER.sync(
            TOKEN
        );

        IERC20(TOKEN).transfer(
            address(MANAGER),
            amount - 1
        );

        MANAGER.settle();

        return "";
    }
}

/**
 * @title EvacuationRehearsal
 * @dev Deterministic (non-fork, `vm.warp`) rehearsal of the v2 -> v3
 * buffer evacuation against a full mock v2 system: the REAL legacy
 * `ForwardVaultERC20Migratable` over `TestUSD`, drained via
 * {MoneyForwardContractV4} and a {MockPoolManagerV4}. Validates the
 * timing bounds and money flow before the real-time testnet run:
 * `initiateEvacuation` reverts before `t_min`, succeeds after,
 * drains the vault to exactly zero, lands the buffer on the migration
 * deployer, the emergency escape returns ownership, and the mock
 * PoolManager rejects a one-wei underpayment.
 */
contract EvacuationRehearsalTest is Test {

    uint256 internal constant SECONDS_PER_YEAR_SCALED = 157_700_000;
    uint256 internal constant CROSSING_TARGET_SECONDS = 600;

    uint256 internal constant BUFFER = 100_000 * 1e6;
    uint256 internal constant POOL_LIQUIDITY = 5_000_000 * 1e6;

    TestUSD internal usd;
    MockPoolManagerV4 internal poolManager;
    address internal oldVault;
    MoneyForwardContractV4 internal forwarder;

    address internal thirdParty = makeAddr("thirdParty");
    address internal migrationDeployer = makeAddr("migrationDeployer");
    address internal holder = makeAddr("holder");
    address internal stranger = makeAddr("stranger");

    address[] internal holders;
    uint256[] internal holderAmounts;

    function setUp()
        public
    {
        usd = new TestUSD(
            "Test USD",
            "tUSD",
            6
        );

        holders.push(
            holder
        );

        holderAmounts.push(
            50_000 * 1e6
        );

        oldVault = deployCode(
            "ForwardVaultERC20Migratable.sol:ForwardVaultERC20Migratable",
            abi.encode(
                address(usd),
                thirdParty,
                address(0),
                holders,
                holderAmounts,
                uint256(1e15),
                uint256(2000),
                uint256(500),
                uint8(6),
                "Mock V2 Vault",
                "MV2"
            )
        );

        usd.mint(
            oldVault,
            BUFFER
        );

        poolManager = new MockPoolManagerV4();

        usd.mint(
            address(poolManager),
            POOL_LIQUIDITY
        );

        forwarder = new MoneyForwardContractV4(
            oldVault,
            address(usd),
            IMockOldVault(oldVault).master(),
            migrationDeployer,
            address(poolManager)
        );

        IMockOldVault(oldVault).proposeOwner(
            address(forwarder)
        );

        forwarder.acceptOwnerOldVault();
    }

    function _mintAndBurn()
        internal
        returns (uint256 extra)
    {
        extra = BUFFER
            * SECONDS_PER_YEAR_SCALED
            / CROSSING_TARGET_SECONDS;

        forwarder.mintSupply(
            extra
        );

        forwarder.burnSupplyBulk(
            holders,
            holderAmounts
        );
    }

    function test_rehearsal_revertsBeforeThreshold()
        public
    {
        _mintAndBurn();

        vm.warp(
            block.timestamp + 300
        );

        vm.expectRevert(
            MoneyForwardContractV4.WouldNotEmptyVault.selector
        );

        forwarder.initiateEvacuation();
    }

    function test_rehearsal_drainsAfterThreshold()
        public
    {
        _mintAndBurn();

        vm.warp(
            block.timestamp + 900
        );

        uint256 deployerBefore = usd.balanceOf(
            migrationDeployer
        );

        forwarder.initiateEvacuation();

        assertEq(
            usd.balanceOf(oldVault),
            0,
            "old vault not drained to zero"
        );

        assertEq(
            usd.balanceOf(migrationDeployer),
            deployerBefore + BUFFER,
            "buffer did not land on the migration deployer"
        );

        assertEq(
            poolManager.protocolFeesAccrued(address(usd)),
            0,
            "mock charged a protocol fee"
        );
    }

    function test_rehearsal_emergencyReturnOwnership()
        public
    {
        vm.expectRevert(
            MoneyForwardContractV4.WouldNotEmptyVault.selector
        );

        forwarder.initiateEvacuation();

        vm.prank(
            stranger
        );

        vm.expectRevert();

        forwarder.emergencyReturnOwnership();

        forwarder.emergencyReturnOwnership();

        deployCodeClaimOwnership();

        assertEq(
            IMockOldVault(oldVault).master(),
            address(this),
            "ownership not returned to deployer"
        );
    }

    function deployCodeClaimOwnership()
        internal
    {
        (bool ok, ) = oldVault.call(
            abi.encodeWithSignature(
                "claimOwnership()"
            )
        );

        require(
            ok,
            "claimOwnership failed"
        );
    }

    function test_mockPoolManager_currencyNotSettledOnUnderpay()
        public
    {
        UnderpayingBorrower borrower = new UnderpayingBorrower(
            poolManager,
            address(usd)
        );

        vm.expectRevert(
            MockPoolManagerV4.CurrencyNotSettled.selector
        );

        borrower.flash(
            1_000 * 1e6
        );
    }

    function test_mockPoolManager_exactRepaySettles()
        public
    {
        uint256 poolBefore = usd.balanceOf(
            address(poolManager)
        );

        _mintAndBurn();

        vm.warp(
            block.timestamp + 900
        );

        forwarder.initiateEvacuation();

        assertEq(
            usd.balanceOf(address(poolManager)),
            poolBefore,
            "pool balance changed: a fee was taken or lost"
        );
    }
}
