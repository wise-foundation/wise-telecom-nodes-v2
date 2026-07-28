// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @dev The callback the singleton PoolManager invokes on whoever
 * called `unlock`. All pool interactions (here: `take`/`settle`)
 * are only permitted while the manager is unlocked, i.e. from
 * inside this callback.
 */
interface IUnlockCallback {

    function unlockCallback(
        bytes calldata data
    )
        external
        returns (bytes memory);
}

/**
 * @dev Minimal, ABI-compatible slice of the Uniswap v4 PoolManager.
 * `Currency` in the real ABI is `type Currency is address`, so an
 * `address` parameter encodes identically. Note there is NO
 * `flashLoan`/`flash` function: a flash loan is `take` (pull funds)
 * plus `settle` (repay) inside one `unlock`, with every currency
 * delta required to net to zero before the callback returns.
 */
interface IPoolManager {

    error CurrencyNotSettled();

    function unlock(
        bytes calldata data
    )
        external
        returns (bytes memory);

    function take(
        address currency,
        address to,
        uint256 amount
    )
        external;

    function sync(
        address currency
    )
        external;

    function settle()
        external
        payable
        returns (uint256 paid);

    function protocolFeesAccrued(
        address currency
    )
        external
        view
        returns (uint256);
}

/**
 * @dev A standalone flash borrower. It holds NO capital of its own:
 * everything it needs is taken from the singleton and repaid in the
 * same `unlock`. The required call sequence is exactly:
 *
 *   manager.unlock(data)                       // opens the lock
 *     -> manager.take(currency, this, amount)  // borrow (delta -= amount)
 *     -> manager.sync(currency)                // snapshot reserves
 *     -> currency.transfer(manager, amount)    // send repayment in
 *     -> manager.settle()                      // credit (delta += amount)
 *   // unlock reverts CurrencyNotSettled unless every delta == 0
 *
 * Repaying exactly what was borrowed satisfies the manager, which is
 * the on-chain proof that no protocol/LP/hook fee is charged.
 */
contract V4FlashBorrower is IUnlockCallback {

    struct FlashParams {
        address currency;
        uint256 borrowAmount;
        uint256 repayAmount;
    }

    IPoolManager public immutable MANAGER;

    uint256 public lastBorrowedBalance;

    constructor(
        IPoolManager _manager
    ) {
        MANAGER = _manager;
    }

    function flash(
        address _currency,
        uint256 _borrowAmount,
        uint256 _repayAmount
    )
        external
    {
        MANAGER.unlock(
            abi.encode(
                FlashParams({
                    currency: _currency,
                    borrowAmount: _borrowAmount,
                    repayAmount: _repayAmount
                })
            )
        );
    }

    function unlockCallback(
        bytes calldata _data
    )
        external
        returns (bytes memory)
    {
        require(
            msg.sender == address(MANAGER),
            "ONLY_MANAGER"
        );

        FlashParams memory params = abi.decode(
            _data,
            (FlashParams)
        );

        MANAGER.take(
            params.currency,
            address(this),
            params.borrowAmount
        );

        lastBorrowedBalance = IERC20(params.currency).balanceOf(
            address(this)
        );

        MANAGER.sync(
            params.currency
        );

        _safeTransfer(
            params.currency,
            address(MANAGER),
            params.repayAmount
        );

        MANAGER.settle();

        return "";
    }

    function _safeTransfer(
        address _token,
        address _to,
        uint256 _amount
    )
        internal
    {
        (
            bool success,
            bytes memory returnData
        ) = _token.call(
            abi.encodeWithSelector(
                IERC20.transfer.selector,
                _to,
                _amount
            )
        );

        require(
            success && (
                returnData.length == 0 || abi.decode(returnData, (bool))
            ),
            "TRANSFER_FAILED"
        );
    }
}

/**
 * @dev Mainnet-fork proof that a Uniswap v4 flash loan of real pool
 * liquidity is fee-free. Runs against the canonical PoolManager and
 * real USDC/USDT with no mocks: the only way the borrower can repay
 * exactly what it took (starting from a zero balance) is if the take
 * -> settle round trip charges nothing.
 */
contract UniswapV4FlashLoanForkTest is Test {

    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    V4FlashBorrower internal borrower;

    function setUp()
        public
    {
        vm.createSelectFork(
            "mainnet"
        );

        assertGt(
            POOL_MANAGER.code.length,
            0,
            "PoolManager has no bytecode on this fork"
        );

        borrower = new V4FlashBorrower(
            IPoolManager(POOL_MANAGER)
        );
    }

    function test_fork_v4FlashLoan_zeroFee_USDC()
        public
    {
        _assertZeroFeeFlashLoan(
            USDC,
            _poolBalance(USDC) / 2
        );
    }

    function test_fork_v4FlashLoan_zeroFee_USDT()
        public
    {
        _assertZeroFeeFlashLoan(
            USDT,
            _poolBalance(USDT) / 2
        );
    }

    function test_fork_v4FlashLoan_wholePool_USDC()
        public
    {
        _assertZeroFeeFlashLoan(
            USDC,
            _poolBalance(USDC)
        );
    }

    function test_fork_v4FlashLoan_revertsWhenUnderpaidByOneWei_USDC()
        public
    {
        uint256 borrowAmount = _poolBalance(USDC) / 2;

        vm.expectRevert(
            IPoolManager.CurrencyNotSettled.selector
        );

        borrower.flash(
            USDC,
            borrowAmount,
            borrowAmount - 1
        );
    }

    function _assertZeroFeeFlashLoan(
        address _token,
        uint256 _borrowAmount
    )
        internal
    {
        uint256 poolBefore = _poolBalance(_token);
        uint256 borrowerBefore = IERC20(_token).balanceOf(address(borrower));
        uint256 protocolFeesBefore = IPoolManager(POOL_MANAGER).protocolFeesAccrued(_token);

        assertEq(
            borrowerBefore,
            0,
            "borrower must start with zero capital"
        );

        borrower.flash(
            _token,
            _borrowAmount,
            _borrowAmount
        );

        assertEq(
            borrower.lastBorrowedBalance(),
            _borrowAmount,
            "take() did not deliver the borrowed funds"
        );

        assertEq(
            IERC20(_token).balanceOf(address(borrower)),
            0,
            "borrower paid a fee out of its own funds"
        );

        assertEq(
            _poolBalance(_token),
            poolBefore,
            "pool balance changed: a fee was taken or lost"
        );

        assertEq(
            IPoolManager(POOL_MANAGER).protocolFeesAccrued(_token),
            protocolFeesBefore,
            "a protocol fee accrued on the flash loan"
        );
    }

    function _poolBalance(
        address _token
    )
        internal
        view
        returns (uint256)
    {
        return IERC20(_token).balanceOf(POOL_MANAGER);
    }
}
