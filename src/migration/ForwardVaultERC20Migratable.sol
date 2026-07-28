// SPDX-License-Identifier: -- WISE --
// @author: René Hochmuth

pragma solidity =0.8.29;

import {ForwardVaultERC20} from "../legacy/ForwardVaultERC20Legacy.sol";

/**
 * @title ForwardVaultERC20Migratable
 * @dev Thin extension of legacy ForwardVaultERC20 that exposes a master-only
 * setter for `proxyBalance`, used during the Phase-2 migration to replicate
 * QueContract-locked balances on a freshly deployed vault.
 *
 * The legacy contract is never modified. This inheritor only adds new external
 * functions; existing storage layout is preserved.
 */
contract ForwardVaultERC20Migratable is ForwardVaultERC20 {

    event ProxyBalanceMigrated(
        address indexed user,
        uint256 amount
    );

    constructor(
        address   _usdAddress,
        address   _thirdPartyAddress,
        address   _oldVault,
        address[] memory _initialDistributionAddresses,
        uint256[] memory _initialDistributionAmounts,
        uint256   _totalDepositCap,
        uint256   _interestRate,
        uint256   _autoCompoundIncentive,
        uint8     _decimals,
        string  memory _tokenName,
        string  memory _tokenSymbol
    )
        ForwardVaultERC20(
            _usdAddress,
            _thirdPartyAddress,
            _oldVault,
            _initialDistributionAddresses,
            _initialDistributionAmounts,
            _totalDepositCap,
            _interestRate,
            _autoCompoundIncentive,
            _decimals,
            _tokenName,
            _tokenSymbol
        )
    {}

    /**
     * @dev Master-only setter for `proxyBalance[user]`.
     * Used at Phase-2 migration time to seed the new vault with the
     * QueContract-locked balances of each user.
     *
     * @param _user The user whose proxy balance is being set.
     * @param _amount The new proxy balance value.
     */
    function setProxyBalance(
        address _user,
        uint256 _amount
    )
        external
        onlyMaster
    {
        proxyBalance[_user] = _amount;

        emit ProxyBalanceMigrated(
            _user,
            _amount
        );
    }
}
