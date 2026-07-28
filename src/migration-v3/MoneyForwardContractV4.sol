// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {OwnableMaster, NoValue} from "../diamond/shared/OwnableMaster.sol";

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
 * `address` parameter encodes identically. There is NO
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
}

/**
 * @dev Minimal slice of the live v2 ForwardVaultERC20 the forwarder
 * drives while it holds the old vault's ownership. Declared locally
 * so this contract stays in the =0.8.36 compilation cluster without
 * importing the read-only =0.8.29 legacy sources.
 */
interface IOldVault {

    function getTotalInterestUser(
        address _user
    )
        external
        view
        returns (uint256);

    function claimInterest()
        external
        returns (uint256);

    function mintSupply(
        address _user,
        uint256 _amount
    )
        external;

    function burnSupply(
        address _user,
        uint256 _amount
    )
        external;

    function proposeOwner(
        address _newOwner
    )
        external;

    function claimOwnership()
        external;

    function paused()
        external
        view
        returns (bool);

    function pauseDeposits()
        external;

    function unpauseDeposits()
        external;
}

interface IERC20Balance {

    function balanceOf(
        address _account
    )
        external
        view
        returns (uint256);
}

/**
 * @title MoneyForwardContractV4
 * @dev v2 → v3 buffer evacuator backed by a fee-free Uniswap v4
 * flash loan (take → settle inside one `unlock`; zero fee proven by
 * test/diamond/fork/UniswapV4FlashLoanFork.t.sol). The forwarder
 * takes ownership of the old vault, mints itself EXTRA supply, waits
 * off-chain until its accrued interest exceeds the vault's entire
 * USD balance, then `initiateEvacuation` borrows the shortfall,
 * donates it into the vault, claims the full interest (draining the
 * vault to exactly zero), repays the loan and forwards the leftover
 * — exactly the original buffer — to `NEW_VAULT_SYSTEM_ADDRESS`.
 *
 * Emergency escape: if the flash-loan path is broken for ANY reason,
 * `emergencyReturnOwnership` (master-only) proposes the old vault's
 * ownership back to the forwarder's master, so the live v2 system
 * can never be stranded under this contract, and
 * `emergencyRescueTokens` sweeps any token balance off it.
 */
contract MoneyForwardContractV4 is OwnableMaster, IUnlockCallback {

    IOldVault public immutable OLD_VAULT;
    address public immutable USD_TOKEN;
    address public immutable ORIGINAL_VAULT_OWNER;
    address public immutable NEW_VAULT_SYSTEM_ADDRESS;
    IPoolManager public immutable POOL_MANAGER;

    bool private transferOngoing;

    error NotEvacuating();
    error OnlyPoolManager();
    error WouldNotEmptyVault();
    error NoLeftoverBalance();
    error OldVaultNotDrained();
    error ArrayLengthMismatch();
    error TransferFailed();

    event EvacuationExecuted(
        uint256 flashAmount,
        uint256 sweptAmount
    );

    event EmergencyOwnershipReturned(
        address indexed proposedTo
    );

    event TokensRescued(
        address indexed token,
        address indexed to,
        uint256 amount
    );

    constructor(
        address _oldVault,
        address _usdToken,
        address _originalVaultOwner,
        address _newVaultSystemAddress,
        address _poolManager
    )
        OwnableMaster(
            msg.sender
        )
    {
        if (
            _oldVault == ZERO_ADDRESS
                || _usdToken == ZERO_ADDRESS
                || _originalVaultOwner == ZERO_ADDRESS
                || _newVaultSystemAddress == ZERO_ADDRESS
                || _poolManager == ZERO_ADDRESS
        ) {
            revert NoValue();
        }

        OLD_VAULT = IOldVault(
            _oldVault
        );

        USD_TOKEN = _usdToken;
        ORIGINAL_VAULT_OWNER = _originalVaultOwner;
        NEW_VAULT_SYSTEM_ADDRESS = _newVaultSystemAddress;

        POOL_MANAGER = IPoolManager(
            _poolManager
        );
    }

    function mintSupply(
        uint256 _amount
    )
        external
        onlyMaster
    {
        OLD_VAULT.mintSupply(
            address(this),
            _amount
        );
    }

    /**
     * @dev Escape hatches so the master can drive the old vault's
     * deposit pause directly while the forwarder owns it. The
     * evacuation itself already lifts and restores the pause atomically
     * around `claimInterest`; these are for out-of-band recovery only.
     */
    function pauseOldVault()
        external
        onlyMaster
    {
        OLD_VAULT.pauseDeposits();
    }

    function unpauseOldVault()
        external
        onlyMaster
    {
        OLD_VAULT.unpauseDeposits();
    }

    function burnSupplyBulk(
        address[] calldata _users,
        uint256[] calldata _amounts
    )
        external
        onlyMaster
    {
        if (_users.length != _amounts.length) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i = 0; i < _users.length; i++) {
            OLD_VAULT.burnSupply(
                _users[i],
                _amounts[i]
            );
        }
    }

    function proposeOwnerOldVault(
        address _newOwner
    )
        external
        onlyMaster
    {
        OLD_VAULT.proposeOwner(
            _newOwner
        );
    }

    function acceptOwnerOldVault()
        external
        onlyMaster
    {
        OLD_VAULT.claimOwnership();
    }

    function emergencyReturnOwnership()
        external
        onlyMaster
    {
        OLD_VAULT.proposeOwner(
            master
        );

        emit EmergencyOwnershipReturned(
            master
        );
    }

    function emergencyRescueTokens(
        address _token,
        address _to
    )
        external
        onlyMaster
    {
        uint256 amount = IERC20Balance(_token).balanceOf(
            address(this)
        );

        _safeTransfer(
            _token,
            _to,
            amount
        );

        emit TokensRescued(
            _token,
            _to,
            amount
        );
    }

    function initiateEvacuation()
        external
        onlyMaster
    {
        uint256 totalInterestToClaim = OLD_VAULT.getTotalInterestUser(
            address(this)
        );

        uint256 cashedBalance = IERC20Balance(USD_TOKEN).balanceOf(
            address(OLD_VAULT)
        );

        if (totalInterestToClaim <= cashedBalance) {
            revert WouldNotEmptyVault();
        }

        uint256 flashAmount = totalInterestToClaim
            - cashedBalance;

        transferOngoing = true;

        POOL_MANAGER.unlock(
            abi.encode(
                flashAmount
            )
        );

        OLD_VAULT.proposeOwner(
            ORIGINAL_VAULT_OWNER
        );

        transferOngoing = false;
    }

    function unlockCallback(
        bytes calldata _data
    )
        external
        returns (bytes memory)
    {
        if (transferOngoing == false) {
            revert NotEvacuating();
        }

        if (msg.sender != address(POOL_MANAGER)) {
            revert OnlyPoolManager();
        }

        uint256 flashAmount = abi.decode(
            _data,
            (uint256)
        );

        POOL_MANAGER.take(
            USD_TOKEN,
            address(this),
            flashAmount
        );

        _safeTransfer(
            USD_TOKEN,
            address(OLD_VAULT),
            flashAmount
        );

        bool wasPaused = OLD_VAULT.paused();

        if (wasPaused == true) {
            OLD_VAULT.unpauseDeposits();
        }

        OLD_VAULT.claimInterest();

        if (wasPaused == true) {
            OLD_VAULT.pauseDeposits();
        }

        POOL_MANAGER.sync(
            USD_TOKEN
        );

        _safeTransfer(
            USD_TOKEN,
            address(POOL_MANAGER),
            flashAmount
        );

        POOL_MANAGER.settle();

        uint256 leftOverBalance = IERC20Balance(USD_TOKEN).balanceOf(
            address(this)
        );

        if (leftOverBalance == 0) {
            revert NoLeftoverBalance();
        }

        uint256 oldVaultBalance = IERC20Balance(USD_TOKEN).balanceOf(
            address(OLD_VAULT)
        );

        if (oldVaultBalance > 0) {
            revert OldVaultNotDrained();
        }

        _safeTransfer(
            USD_TOKEN,
            NEW_VAULT_SYSTEM_ADDRESS,
            leftOverBalance
        );

        emit EvacuationExecuted(
            flashAmount,
            leftOverBalance
        );

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
            abi.encodeWithSignature(
                "transfer(address,uint256)",
                _to,
                _amount
            )
        );

        if (
            success == false
                || (
                    returnData.length > 0
                        && abi.decode(returnData, (bool)) == false
                )
        ) {
            revert TransferFailed();
        }
    }
}
