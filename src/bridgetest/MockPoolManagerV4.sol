// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IUnlockCallback {

    function unlockCallback(
        bytes calldata data
    )
        external
        returns (bytes memory);
}

/**
 * @title MockPoolManagerV4
 * @dev Testnet stand-in for the Uniswap v4 singleton, reproducing the
 * flash-accounting semantics the real PoolManager was proven to have
 * in test/diamond/fork/UniswapV4FlashLoanFork.t.sol: a flash loan is
 * `take` (pull funds, caller's currency delta goes negative) plus
 * `settle` (repay, delta goes positive) inside one `unlock`, and the
 * unlock reverts `CurrencyNotSettled` unless every touched currency
 * delta is exactly zero when the callback returns. The mock charges
 * NO fee (repaying exactly what was taken settles the delta) and
 * `protocolFeesAccrued` is always zero, matching the on-chain proof.
 * Pre-fund it with the token to give it a realistic borrowable `L`.
 */
contract MockPoolManagerV4 {

    error CurrencyNotSettled();
    error AlreadyUnlocked();
    error NotUnlocked();
    error ManagerLocked();

    mapping(address => int256) private currencyDelta;

    address[] private touched;
    mapping(address => bool) private isTouched;

    address private syncedCurrency;
    uint256 private syncedReserves;

    bool private unlocked;

    function unlock(
        bytes calldata _data
    )
        external
        returns (bytes memory result)
    {
        if (unlocked) {
            revert AlreadyUnlocked();
        }

        unlocked = true;

        result = IUnlockCallback(msg.sender).unlockCallback(
            _data
        );

        uint256 length = touched.length;

        for (uint256 i = 0; i < length; i++) {
            if (currencyDelta[touched[i]] != 0) {
                revert CurrencyNotSettled();
            }
        }

        _clearTouched();

        syncedCurrency = address(0);
        syncedReserves = 0;
        unlocked = false;
    }

    function take(
        address _currency,
        address _to,
        uint256 _amount
    )
        external
    {
        if (unlocked == false) {
            revert NotUnlocked();
        }

        _touch(
            _currency
        );

        currencyDelta[_currency] -= int256(_amount);

        IERC20(_currency).transfer(
            _to,
            _amount
        );
    }

    function sync(
        address _currency
    )
        external
    {
        if (unlocked == false) {
            revert NotUnlocked();
        }

        syncedCurrency = _currency;

        syncedReserves = IERC20(_currency).balanceOf(
            address(this)
        );
    }

    function settle()
        external
        payable
        returns (uint256 paid)
    {
        if (unlocked == false) {
            revert NotUnlocked();
        }

        address currency = syncedCurrency;

        uint256 balanceNow = IERC20(currency).balanceOf(
            address(this)
        );

        paid = balanceNow - syncedReserves;

        _touch(
            currency
        );

        currencyDelta[currency] += int256(paid);
    }

    function protocolFeesAccrued(
        address
    )
        external
        pure
        returns (uint256)
    {
        return 0;
    }

    function _touch(
        address _currency
    )
        internal
    {
        if (isTouched[_currency] == false) {
            isTouched[_currency] = true;
            touched.push(_currency);
        }
    }

    function _clearTouched()
        internal
    {
        uint256 length = touched.length;

        for (uint256 i = 0; i < length; i++) {
            isTouched[touched[i]] = false;
            currencyDelta[touched[i]] = 0;
        }

        delete touched;
    }
}
