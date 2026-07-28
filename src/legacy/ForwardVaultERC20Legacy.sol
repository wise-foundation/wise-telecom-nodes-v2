// SPDX-License-Identifier: -- WISE --
// @author: René Hochmuth

pragma solidity =0.8.29;

import "./ForwardVaultERC20HelperLegacy.sol";

/**
 * @title ForwardVaultERC20
 * @dev Main contract for the Forward Vault ERC20 token system.
 *
 * This contract implements a yield-bearing ERC20 token that allows users to:
 * - Deposit USD tokens and receive vault tokens representing their share
 * - Earn interest on their deposits through a configurable interest rate
 * - Claim or compound their earned interest
 * - Withdraw their deposits (when allowed)
 *
 * The contract includes features such as:
 * - Interest rate management with proxy support
 * - Auto-compound functionality for users
 * - Whitelist controls for administrative functions
 * - Pausable deposits for emergency situations
 * - Supply management by owner (mint/burn capabilities)
 * - Proxy balance tracking for external integrations
 *
 * @notice This contract inherits from ForwardVaultERC20Helper which contains
 * the core logic and helper functions for vault operations.
 */
contract ForwardVaultERC20 is ForwardVaultERC20Helper {

    using SafeERC20 for IERC20;

    /**
     * @dev Constructor for the ForwardVaultERC20 contract.
     * Initializes the vault with configuration parameters and performs initial token distribution.
     *
     * @param _usdAddress The address of the USD token contract (e.g., USDC, USDT)
     * @param _thirdPartyAddress The address for third-party integrations
     * @param _oldVault The address of the previous vault for migration purposes
     * @param _initialDistributionAddresses Array of addresses to receive initial token distribution
     * @param _initialDistributionAmounts Array of amounts corresponding to the distribution addresses
     * @param _totalDepositCap Maximum total amount that can be deposited in the vault
     * @param _interestRate Annual interest rate in basis points (e.g., 500 = 5%)
     * @param _autoCompoundIncentive Incentive rate for auto-compound operations
     * @param _decimals Number of decimal places for the vault token
     * @param _tokenName Name of the vault token
     * @param _tokenSymbol Symbol of the vault token
     */
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
        ForwardVaultERC20Declarations(
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

    /* ---------------------------------------------------------- */
    /*  OWNER‑ONLY ACTIONS                                        */
    /* ---------------------------------------------------------- */

    /**
     * @dev Allows the master to enable withdrawals for all users.
     * Can only be called by the contract master.
     */
    function allowWithdraw()
        external
        onlyMaster
        nonReentrant
    {
        _setWithdrawStatus(
            true
        );
    }

    /**
     * @dev Allows the master to disable withdrawals for all users.
     * Can only be called by the contract master.
     */
    function disallowWithdraw()
        external
        onlyMaster
        nonReentrant
    {
        _setWithdrawStatus(
            false
        );
    }

    /**
     * @dev Allows the master to permanently disable supply changes by the master.
     * Once called, the master can no longer mint or burn tokens.
     * Can only be called by the contract master.
     */
    function disAllowSupplyChangeByOwner()
        external
        onlyMaster
        nonReentrant
    {
        _disableSupplyChangeByOwner();
    }

    /**
     * @dev Allows the master to mint new vault tokens to a specific address.
     * Can only be called by the contract master and when supply changes are allowed.
     *
     * @param _to The address to receive the minted tokens
     * @param _amount The amount of tokens to mint
     */
    function mintSupply(
        address _to,
        uint256 _amount
    )
        external
        onlyMaster
        assignInterest(_to)
        nonReentrant
        supplyChangeAllowed
    {
        _executeMintSupply(
            _to,
            _amount
        );
    }

    /**
     * @dev Allows the master to burn vault tokens from a specific address.
     * Can only be called by the contract master and when supply changes are allowed.
     *
     * @param _from The address from which to burn tokens
     * @param _amount The amount of tokens to burn
     */
    function burnSupply(
        address _from,
        uint256 _amount
    )
        external
        onlyMaster
        assignInterest(_from)
        nonReentrant
        supplyChangeAllowed
    {
        _executeBurnSupply(
            _from,
            _amount
        );
    }

    /* ---------------------------------------------------------- */
    /*  PROXY FUNCTIONS                                           */
    /* ---------------------------------------------------------- */

    /**
     * @dev Allows the interest rate proxy to trigger interest assignment for a user.
     * This function is called by external contracts that manage interest rates.
     *
     * @param _user The address of the user for whom to assign interest
     */
    function triggerAssignInterest(
        address _user
    )
        external
    {
        _validateInterestRateProxy();

        _assignInterest(
            _user
        );
    }

    /**
     * @dev Allows the interest rate proxy to increase the proxy balance for a user.
     * Used by external contracts to manage user balances without direct token transfers.
     *
     * @param _proxyUser The address of the user whose proxy balance is being increased
     * @param _amount The amount to increase the proxy balance by
     */
    function increaseProxyBalance(
        address _proxyUser,
        uint256 _amount
    )
        external
    {
        _validateInterestRateProxy();

        _increaseProxyBalance(
            _proxyUser,
            _amount
        );
    }

    /**
     * @dev Allows the interest rate proxy to decrease the proxy balance for a user.
     * Used by external contracts to manage user balances without direct token transfers.
     *
     * @param _proxyUser The address of the user whose proxy balance is being decreased
     * @param _amount The amount to decrease the proxy balance by
     */
    function decreaseProxyBalance(
        address _proxyUser,
        uint256 _amount
    )
        external
        assignInterest(_proxyUser)
    {
        _validateInterestRateProxy();

        _decreaseProxyBalance(
            _proxyUser,
            _amount
        );
    }

    /* ---------------------------------------------------------- */
    /*  USER ACTIONS                                              */
    /* ---------------------------------------------------------- */

    /**
     * @dev Allows users to deposit USD tokens into the vault.
     * Users receive vault tokens representing their share of the vault.
     *
     * @param _amount The amount of USD tokens to deposit
     */
    function deposit(
        uint256 _amount
    )
        external
        whenNotPaused
        nonReentrant
        assignInterest(msg.sender)
    {
        _deposit(
            _amount
        );
    }

    /**
     * @dev Allows users to claim their earned interest.
     * Transfers the accumulated interest to the user's address.
     *
     * @return The amount of interest claimed
     */
    function claimInterest()
        external
        whenNotPaused
        nonReentrant
        assignInterest(msg.sender)
        returns (uint256)
    {
        return
            _handleSimpleClaim(
                msg.sender
            );
    }

    /**
     * @dev Allows users to claim a partial amount of their interest and compound the rest.
     * Useful for users who want to take some profits while reinvesting the remainder.
     *
     * @param _amount The amount of interest to claim (the rest will be compounded)
     * @return claimedAmount The amount of interest that was claimed
     */
    function claimInterestPartiallyAndCompound(
        uint256 _amount
    )
        external
        whenNotPaused
        nonReentrant
        assignInterest(msg.sender)
        returns (uint256 claimedAmount)
    {
        claimedAmount = _executePartialClaimAndCompound(
            msg.sender,
            _amount
        );
    }

    /**
     * @dev Allows users to claim an exact amount of their earned interest.
     * If the user has less interest than requested, the transaction will revert.
     *
     * @param _amount The exact amount of interest to claim
     * @return The amount of interest claimed
     */
    function claimInterestExactAmount(
        uint256 _amount
    )
        external
        whenNotPaused
        nonReentrant
        assignInterest(msg.sender)
        returns (uint256)
    {
        return
            _handleClaimExactAmount(
                msg.sender,
                _amount
            );
    }

    /**
     * @dev Allows users to deposit USD tokens and immediately claim their interest in one transaction.
     * Combines deposit and claim operations for gas efficiency.
     *
     * @param _amount The amount of USD tokens to deposit
     * @return The amount of interest claimed
     */
    function depositAndClaimInterest(
        uint256 _amount
    )
        external
        whenNotPaused
        nonReentrant
        assignInterest(msg.sender)
        returns (uint256)
    {
        return
            _executeDepositAndClaim(
                _amount
            );
    }

    /**
     * @dev Allows users to deposit USD tokens and immediately compound their interest in one transaction.
     * Combines deposit and compound operations for gas efficiency.
     *
     * @param _amount The amount of USD tokens to deposit
     * @return The amount of interest compounded
     */
    function depositAndCompoundInterest(
        uint256 _amount
    )
        external
        whenNotPaused
        nonReentrant
        assignInterest(msg.sender)
        returns (uint256)
    {
        return
            _executeDepositAndCompound(
                _amount
            );
    }

    /**
     * @dev Allows users to disable auto-compound functionality for their account.
     * Prevents whitelisted addresses from auto-compounding the user's interest.
     */
    function disallowAutoCompound()
        external
        nonReentrant
    {
        _setAutoCompoundStatus(
            msg.sender,
            false
        );
    }

    /**
     * @dev Allows users to enable auto-compound functionality for their account.
     * Allows whitelisted addresses to auto-compound the user's interest.
     */
    function allowAutoCompound()
        external
        nonReentrant
    {
        _setAutoCompoundStatus(
            msg.sender,
            true
        );
    }

    /**
     * @dev Allows users to set whether they want to transfer their interest with tokens.
     * If enabled, interest is transferred with tokens. If disabled, interest remains with the sender (default).
     *
     * @param _transferInterestWithTokens True to transfer interest with tokens, false to keep interest with sender
     */
    function setTransferInterestWithTokens(
        bool _transferInterestWithTokens
    )
        external
        nonReentrant
    {
        _updateTransferInterestSetting(
            _transferInterestWithTokens
        );
    }

    /**
     * @dev Allows users to compound their earned interest.
     * Adds the interest to the user's principal balance, increasing future interest earnings.
     *
     * @return The amount of interest that was compounded
     */
    function compoundInterest()
        public
        whenNotPaused
        nonReentrant
        assignInterest(msg.sender)
        returns (uint256)
    {
        return
            _handleCompoundInterest(
                msg.sender
            );
    }

    /**
     * @dev Allows whitelisted addresses to compound interest on behalf of a user.
     * Requires the user to have auto-compound enabled.
     *
     * @param _user The address of the user whose interest should be compounded
     * @return The amount of interest that was compounded
     */
    function compoundInterestOnBehalf(
        address _user
    )
        external
        whenNotPaused
        nonReentrant
        assignInterest(_user)
        assignInterest(msg.sender)
        onlyWhiteListed
        returns (uint256)
    {
        _validateAutoCompoundAllowed(
            _user
        );

        return
            _handleCompoundWithIncentive(
                _user
            );
    }

    /**
     * @dev Allows users to withdraw their vault tokens and receive USD tokens.
     * Requires withdrawals to be enabled and the user to have sufficient balance.
     *
     * @param _amount The amount of vault tokens to withdraw
     */
    function withdraw(
        uint256 _amount
    )
        external
        whenNotPaused
        nonReentrant
        assignInterest(msg.sender)
    {
        _validateWithdrawal(
            _amount
        );

        _executeWithdrawal(
            _amount
        );
    }

    /* ---------------------------------------------------------- */
    /*  ONLY MASTER ACTIONS                                */
    /* ---------------------------------------------------------- */

    /**
     * @dev Allows the master to pause deposits.
     * Useful for emergency situations or maintenance.
     */
    function pauseDeposits()
        external
        onlyMaster
        nonReentrant
    {
        _pause();
    }

    /**
     * @dev Allows the master to unpause deposits.
     * Resumes normal deposit functionality after a pause.
     */
    function unpauseDeposits()
        external
        onlyMaster
        nonReentrant
    {
        _unpause();
    }

    /**
     * @dev Allows the master to set the third-party address for integrations.
     *
     * @param _thirdPartyAddress The new third-party address
     */
    function setThirdPartyAddress(
        address _thirdPartyAddress
    )
        external
        onlyMaster
        nonReentrant
    {
        _updateThirdPartyAddress(
            _thirdPartyAddress
        );
    }

    /**
     * @dev Allows the master to set the interest rate for the vault.
     *
     * @param _interestRate The new interest rate in basis points
     */
    function setInterestRate(
        uint256 _interestRate
    )
        external
        onlyMaster
        nonReentrant
    {
        _updateInterestRate(
            _interestRate
        );
    }

    /**
     * @dev Allows the master to set the total deposit cap for the vault.
     *
     * @param _totalDepositCap The new total deposit cap
     */
    function setTotalDepositCap(
        uint256 _totalDepositCap
    )
        external
        onlyMaster
        nonReentrant
    {
        _updateTotalDepositCap(
            _totalDepositCap
        );
    }

    /**
     * @dev Allows the master to add an address to the whitelist.
     *
     * @param _friendlyUser The address to add to the whitelist
     */
    function whiteListAddress(
        address _friendlyUser
    )
        external
        onlyMaster
        nonReentrant
    {
        _setWhitelistStatus(
            _friendlyUser,
            true
        );
    }

    /**
     * @dev Allows the master to remove an address from the whitelist.
     *
     * @param _unfriendlyUser The address to remove from the whitelist
     */
    function removeWhiteListAddress(
        address _unfriendlyUser
    )
        external
        onlyMaster
        nonReentrant
    {
        _setWhitelistStatus(
            _unfriendlyUser,
            false
        );
    }

    /**
     * @dev Allows the master to set the interest rate proxy address.
     * Can only be set once and cannot be changed afterward.
     *
     * @param _interestRateProxy The address of the interest rate proxy contract
     */
    function setInterestRateProxy(
        address _interestRateProxy
    )
        external
        onlyMaster
        nonReentrant
    {
        _validateAndSetInterestRateProxy(
            _interestRateProxy
        );
    }

    /**
     * @dev Allows the master to permanently set the interest rate proxy.
     * Can only be set once and cannot be changed afterward.
     */
    function setInterestRateProxyPermanent()
        external
        onlyMaster
        nonReentrant
    {
        interestRateProxyPermanent = true;
    }

    /**
     * @dev Allows the interest rate proxy to set the current proxy benefactor.
     * Used by external contracts to manage proxy operations.
     *
     * @param _proxyBeneFactor The address of the proxy benefactor
     */
    function setProxyBenefactor(
        address _proxyBeneFactor
    )
        external
        nonReentrant
    {
        _validateInterestRateProxy();

        _updateProxyBenefactor(
            _proxyBeneFactor
        );
    }
}
