// SPDX-License-Identifier: -- WISE --
pragma solidity =0.8.29;

/**
 * @title IForwardVaultERC20
 * @dev Interface for the Forward Vault ERC20 contract.
 *
 * This interface defines the external functions that can be called on the ForwardVaultERC20 contract.
 * It includes functions for:
 * - Interest rate queries and management
 * - Deposit and withdrawal operations
 * - Interest claiming and compounding
 * - Token transfer operations
 * - Supply management (mint/burn)
 * - Proxy balance management
 * - Ownership management
 *
 * @notice This interface is used by external contracts that need to interact with
 * the ForwardVaultERC20 contract, such as the QueContract.
 */
interface IForwardVaultERC20 {

    /**
     * @dev Returns the current interest rate in basis points.
     * @return The annual interest rate as a percentage (e.g., 500 = 5%)
     */
    function interestRate()
        external
        view
        returns (uint256);

    /**
     * @dev Allows users to deposit USD tokens into the vault.
     * @param _amount The amount of USD tokens to deposit
     */
    function deposit(
        uint256 _amount
    )
        external;

    /**
     * @dev Allows users to claim their earned interest.
     * @return The amount of interest claimed
     */
    function claimInterest()
        external
        returns (uint256);

    /**
     * @dev Returns the address of the USD token contract.
     * @return The address of the USD token (e.g., USDC, USDT)
     */
    function USD_TOKEN()
        external
        view
        returns (address);

    /**
     * @dev Transfers vault tokens to another address.
     * @param _to The address to transfer tokens to
     * @param _amount The amount of tokens to transfer
     * @return True if the transfer was successful
     */
    function transfer(
        address _to,
        uint256 _amount
    )
        external
        returns (bool);

    /**
     * @dev Transfers vault tokens from one address to another using allowance.
     * @param _from The address to transfer tokens from
     * @param _to The address to transfer tokens to
     * @param _amount The amount of tokens to transfer
     * @return True if the transfer was successful
     */
    function transferFrom(
        address _from,
        address _to,
        uint256 _amount
    )
        external
        returns (bool);

    /**
     * @dev Burns vault tokens from a specific address (owner only).
     * @param _user The address to burn tokens from
     * @param _amount The amount of tokens to burn
     */
    function burnSupply(
        address _user,
        uint256 _amount
    )
        external;

    /**
     * @dev Mints vault tokens to a specific address (owner only).
     * @param _user The address to mint tokens to
     * @param _amount The amount of tokens to mint
     */
    function mintSupply(
        address _user,
        uint256 _amount
    )
        external;

    /**
     * @dev Returns the total interest earned by a user (cashed + pending).
     * @param _user The address of the user
     * @return The total interest amount
     */
    function getTotalInterestUser(
        address _user
    )
        external
        view
        returns (uint256);

    /**
     * @dev Proposes a new owner for the contract.
     * @param _newOwner The address of the proposed new owner
     */
    function proposeOwner(
        address _newOwner
    )
        external;

    /**
     * @dev Claims ownership of the contract (must be the proposed owner).
     */
    function claimOwnership()
        external;

    /**
     * @dev Returns the current owner/master of the contract.
     * @return The address of the current owner
     */
    function master()
        external
        view
        returns (address);

    /**
     * @dev Sets whether interest should be transferred with tokens.
     * @param _transferInterestWithTokens True to transfer interest with tokens, false to keep with sender
     */
    function setTransferInterestWithTokens(
        bool _transferInterestWithTokens
    )
        external;

    /**
     * @dev Increases the proxy balance for a user (interest rate proxy only).
     * @param _proxyUser The address of the user whose balance is being increased
     * @param _amount The amount to increase the balance by
     */
    function increaseProxyBalance(
        address _proxyUser,
        uint256 _amount
    )
        external;

    /**
     * @dev Decreases the proxy balance for a user (interest rate proxy only).
     * @param _proxyUser The address of the user whose balance is being decreased
     * @param _amount The amount to decrease the balance by
     */
    function decreaseProxyBalance(
        address _proxyUser,
        uint256 _amount
    )
        external;

    /**
     * @dev Sets the current proxy benefactor (interest rate proxy only).
     * @param _proxyBeneFactor The address of the proxy benefactor
     */
    function setProxyBenefactor(
        address _proxyBeneFactor
    )
        external;

    /**
     * @dev Returns the current proxy benefactor address.
     * @return The address of the current proxy benefactor
     */
    function currentProxyBenefactor()
        external
        view
        returns (address);

    /**
     * @dev Triggers interest assignment for a user (interest rate proxy only).
     * @param _user The address of the user to assign interest to
     */
    function triggerAssignInterest(
        address _user
    )
        external;

    function totalDepositCap()
        external
        view
        returns (uint256);
}

