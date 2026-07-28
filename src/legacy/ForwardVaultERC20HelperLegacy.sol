// SPDX-License-Identifier: -- WISE --
// @author: René Hochmuth

pragma solidity =0.8.29;

import "./ForwardVaultERC20DeclarationsLegacy.sol";

/**
 * @title ForwardVaultERC20Helper
 * @dev Helper contract containing the core logic for the Forward Vault ERC20 system.
 *
 * This contract provides:
 * - Access control modifiers (owner, whitelist)
 * - Interest calculation and assignment logic
 * - Deposit and withdrawal processing
 * - Interest claiming and compounding mechanisms
 * - Proxy balance management
 * - ERC20 transfer overrides with interest handling
 *
 * The contract implements sophisticated interest tracking that:
 * - Calculates interest based on time-weighted balances
 * - Supports proxy balances for external integrations
 * - Handles interest transfer during token transfers
 * - Provides bulk operations for gas efficiency
 *
 * @notice This contract inherits from ForwardVaultERC20Declarations which contains
 * all the state variables, events, and error definitions.
 */
abstract contract ForwardVaultERC20Helper is ForwardVaultERC20Declarations {
    using SafeERC20 for IERC20;

    // ================
    // MODIFIERS
    // ================

    /**
     * @dev Modifier that restricts function access to whitelisted addresses only.
     */
    modifier onlyWhiteListed()
    {
        _onlyWhiteListed();
        _;
    }

    /**
     * @dev Modifier that assigns interest to a user before executing the function.
     * Ensures interest is calculated and assigned up to the current timestamp.
     *
     * @param _user The address of the user to assign interest to
     */
    modifier assignInterest(
        address _user
    )
    {
        _assignInterest(
            _user
        );
        _;
    }

    /**
     * @dev Modifier that ensures supply changes by the owner are still allowed.
     * Prevents mint/burn operations after the owner has disabled this functionality.
     */
    modifier supplyChangeAllowed()
    {
        _supplyChangeAllowed();
        _;
    }

    /**
     * @dev Internal function to check if supply changes by the owner are allowed.
     * Reverts if the owner has permanently disabled this functionality.
     */
    function _supplyChangeAllowed()
        internal
        view
    {
        require(
            supplyChangeByOwnerNotAllowed == false,
            SupplyChangeNotAllowed()
        );
    }

    /**
     * @dev Internal function to check if the caller is whitelisted.
     * Reverts with an error if the caller is not whitelisted.
     */
    function _onlyWhiteListed()
        internal
        view
    {
        require(
            isWhiteListed[msg.sender] == true,
            NotWhiteListed()
        );
    }

    /**
     * @dev Internal function to assign interest to a user.
     * Calculates pending interest and adds it to the user's cashed interest.
     * Handles special cases for proxy operations.
     *
     * @param _user The address of the user to assign interest to
     */
    function _assignInterest(
        address _user
    )
        internal
    {
        address userToAssign = _user;

        if (_user == InterestRateProxy) {
            userToAssign = currentProxyBenefactor;
        }

        if (userToAssign == ZERO_ADDRESS) {
            return;
        }

        uint256 interest = getPendingInterest(
            userToAssign
        );

        if (interest > 0) {
            cashedInterest[userToAssign] += interest;
        }

        lastSyncTimeStamp[userToAssign] = block.timestamp;
    }

    /**
     * @dev Internal function to move interest from one user to another.
     * Used during token transfers when interest should be transferred with the tokens.
     *
     * @param _user The address to move interest from
     * @param _destination The address to move interest to
     */
    function _moveInterest(
        address _user,
        address _destination
    )
        internal
    {
        if (_user == _destination) {
            return;
        }

        cashedInterest[_destination] += cashedInterest[_user];

        cashedInterest[_user] = 0;
    }

    // ================
    // INTERNAL HELPERS
    // ================

    /**
     * @dev Validates that the caller is the interest rate proxy.
     * Reverts if the caller is not the authorized interest rate proxy.
     */
    function _validateInterestRateProxy()
        internal
        view
    {
        require(
            msg.sender == InterestRateProxy,
            NotInterestRateProxy()
        );
    }

    /**
     * @dev Internal function to update the proxy benefactor address.
     *
     * @param _proxyBeneFactor The new proxy benefactor address
     */
    function _updateProxyBenefactor(
        address _proxyBeneFactor
    )
        internal
    {
        currentProxyBenefactor = _proxyBeneFactor;

        emit ProxyBenefactorSet(
            _proxyBeneFactor
        );
    }

    /**
     * @dev Internal function to update the interest rate.
     * Emits an InterestRateSet event with the new rate.
     *
     * @param _interestRate The new interest rate in basis points
     */
    function _updateInterestRate(
        uint256 _interestRate
    )
        internal
    {
        interestRate = _interestRate;

        emit InterestRateSet(
            _interestRate
        );
    }

    /**
     * @dev Internal function to validate and set the interest rate proxy.
     * Can only be set once and cannot be changed afterward.
     *
     * @param _interestRateProxy The address of the interest rate proxy contract
     */
    function _validateAndSetInterestRateProxy(
        address _interestRateProxy
    )
        internal
    {
        if (interestRateProxyPermanent == false) {
            require(
                InterestRateProxy == ZERO_ADDRESS,
                InterestRateProxyAlreadySet()
            );
        }

        InterestRateProxy = _interestRateProxy;

        emit InterestRateProxySet(
            _interestRateProxy
        );
    }

    /**
     * @dev Increases the proxy balance of a user.
     * Used by external contracts to manage user balances without direct token transfers.
     *
     * @param _proxyUser The address of the user whose balance is being increased
     * @param _amount The amount to increase the balance by
     */
    function _increaseProxyBalance(
        address _proxyUser,
        uint256 _amount
    )
        internal
    {
        proxyBalance[_proxyUser] += _amount;

        emit ProxyBalanceIncreased(
            _proxyUser,
            _amount
        );
    }

    /**
     * @dev Executes a partial claim and compound operation.
     * Claims the specified amount and compounds any remaining interest.
     *
     * @param _user The address of the user claiming interest
     * @param _amount The amount of interest to claim
     * @return totalClaimed The total amount of interest claimed
     */
    function _executePartialClaimAndCompound(
        address _user,
        uint256 _amount
    )
        internal
        returns (
            uint256 totalClaimed
        )
    {
        totalClaimed = _handleClaimExactAmount(
            _user,
            _amount
        );

        totalClaimed += _handleCompoundInterest(
            _user
        );
    }

    /**
     * @dev Decreases the proxy balance of a user.
     * Used by external contracts to manage user balances without direct token transfers.
     *
     * @param _proxyUser The address of the user whose balance is being decreased
     * @param _amount The amount to decrease the balance by
     */
    function _decreaseProxyBalance(
        address _proxyUser,
        uint256 _amount
    )
        internal
    {
        proxyBalance[_proxyUser] -= _amount;

        emit ProxyBalanceDecreased(
            _proxyUser,
            _amount
        );
    }

    /**
     * @dev Validates deposit parameters.
     * Checks that the amount is greater than zero and doesn't exceed the deposit cap.
     *
     * @param _amount The amount to validate for deposit
     */
    function _checkValuesDeposit(
        uint256 _amount
    )
        internal
        view
    {
        if (_amount == 0) {
            revert InvalidValue();
        }

        if (totalSupply() + _amount > totalDepositCap) {
            revert DepositExceedCap();
        }
    }

    /**
     * @dev Internal function to process a deposit.
     * Transfers USD tokens to the third-party address and mints vault tokens to the user.
     *
     * @param _amount The amount of USD tokens to deposit
     */
    function _deposit(
        uint256 _amount
    )
        internal
    {
        _checkValuesDeposit(
            _amount
        );

        USD_TOKEN.safeTransferFrom(
            msg.sender,
            thirdPartyAddress,
            _amount
        );

        _mint(
            msg.sender,
            _amount
        );

        emit Deposited(
            msg.sender,
            _amount
        );
    }

    /**
     * @dev Prepares a claim by retrieving the user's cashed interest.
     * Resets the cashed interest to zero and returns the amount.
     *
     * @param _user The address of the user claiming interest
     * @return interestAmount The amount of interest to be claimed
     */
    function _prepareClaim(
        address _user
    )
        internal
        returns (
            uint256 interestAmount
        )
    {
        interestAmount = cashedInterest[_user];

        if (interestAmount == 0) {
            revert NoInterest();
        }

        cashedInterest[_user] = 0;
    }

    /**
     * @dev Handles a simple interest claim.
     * Transfers the claimed interest to the user's address.
     *
     * @param _user The address of the user claiming interest
     * @return interest The amount of interest claimed
     */
    function _handleSimpleClaim(
        address _user
    )
        internal
        returns (
            uint256 interest
        )
    {
        interest = _prepareClaim(
            _user
        );

        USD_TOKEN.safeTransfer(
            _user,
            interest
        );

        emit ClaimInterestSimple(
            _user,
            interest
        );
    }

    /**
     * @dev Handles claiming an exact amount of interest.
     * Validates that the user has sufficient interest and transfers the specified amount.
     *
     * @param _user The address of the user claiming interest
     * @param _amount The exact amount of interest to claim
     * @return The amount of interest claimed
     */
    function _handleClaimExactAmount(
        address _user,
        uint256 _amount
    )
        internal
        returns (uint256)
    {
        _prepareExactAmountClaim(
            _user,
            _amount
        );

        USD_TOKEN.safeTransfer(
            _user,
            _amount
        );

        emit ClaimInterestExactAmount(
            _user,
            _amount
        );

        return _amount;
    }

    /**
     * @dev Prepares an exact amount claim by validating and reducing the user's cashed interest.
     *
     * @param _user The address of the user claiming interest
     * @param _amount The exact amount of interest to claim
     */
    function _prepareExactAmountClaim(
        address _user,
        uint256 _amount
    )
        internal
    {
        if (_amount == 0) {
            revert InvalidValue();
        }

        uint256 totalInterest = cashedInterest[_user];

        if (totalInterest < _amount) {
            revert InsufficientInterest();
        }

        cashedInterest[_user] = totalInterest - _amount;
    }

    /**
     * @dev Handles compounding interest by adding it to the user's principal balance.
     * Mints new vault tokens to the user and transfers USD to the third-party address.
     *
     * @param _user The address of the user compounding interest
     * @return interest The amount of interest that was compounded
     */
    function _handleCompoundInterest(
        address _user
    )
        internal
        returns (uint256 interest)
    {
        interest = _prepareClaim(
            _user
        );

        if (totalSupply() + interest > totalDepositCap) {
            revert DepositExceedCap();
        }

        _mint(
            _user,
            interest
        );

        USD_TOKEN.safeTransfer(
            thirdPartyAddress,
            interest
        );

        emit CompoundInterest(
            _user,
            interest
        );
    }

    /**
     * @dev Handles compounding interest with an incentive for the caller.
     * The caller receives a portion of the interest as an incentive for auto-compounding.
     *
     * @param _user The address of the user whose interest is being compounded
     * @return interest The total amount of interest that was processed
     */
    function _handleCompoundWithIncentive(
        address _user
    )
        internal
        returns (
            uint256 interest
        )
    {
        interest = _prepareClaim(
            _user
        );

        uint256 incentive = (interest * autoCompoundIncentive) /
            PRECISION_RATE;

        uint256 transferInterestAmount = interest - incentive;

        if (totalSupply() + transferInterestAmount > totalDepositCap) {
            revert DepositExceedCap();
        }

        _mint(
            _user,
            transferInterestAmount
        );

        if (incentive > 0) {
            USD_TOKEN.safeTransfer(
                msg.sender,
                incentive
            );
        }

        USD_TOKEN.safeTransfer(
            thirdPartyAddress,
            transferInterestAmount
        );

        emit ClaimInterestWithIncentive(
            _user,
            msg.sender,
            interest,
            incentive
        );
    }

    /**
     * @dev Decides whether to move interest during a token transfer.
     * Interest is moved if the user has opted to transfer it with tokens and the recipient isn't the interest rate proxy.
     *
     * @param _user The address transferring tokens
     * @param _to The address receiving tokens
     * @return True if interest should be moved, false otherwise
     */
    function _decideMoveInterest(
        address _user,
        address _to
    )
        internal
        view
        returns (bool)
    {
        return
            transferInterestWithTokens[_user] == true &&
            _to != InterestRateProxy && _user != InterestRateProxy;
    }

    /**
     * @dev Handles interest transfer during token transfers.
     * Moves interest from the sender to the recipient if conditions are met.
     *
     * @param _user The address transferring tokens
     * @param _to The address receiving tokens
     */
    function _handleInterestTransfer(
        address _user,
        address _to
    )
        internal
    {
        if (
            _decideMoveInterest(
                _user,
                _to
            )
        ) {
            _moveInterest(
                _user,
                _to
            );
        }
    }

    /**
     * @dev Calculates interest based on balance and time delta.
     * Uses a simple interest formula with annual rate and time weighting.
     *
     * @param _balance The balance to calculate interest on
     * @param _timeDelta The time delta in seconds
     * @return The calculated interest amount
     */
    function _calculateInterest(
        uint256 _balance,
        uint256 _timeDelta
    )
        internal
        view
        returns (uint256)
    {
        uint256 yearFactor = _timeDelta
            * PRECISION_FACTOR_E18
            / SECONDS_IN_YEAR;

        uint256 interest = _balance
            * interestRate
            * yearFactor
            / PRECISION_RATE
            / PRECISION_FACTOR_E18;

        return interest;
    }

    /**
     * @dev Internal function to set the withdrawal status for the vault.
     * Controls whether users can withdraw their deposits.
     *
     * @param _status True to allow withdrawals, false to disable them
     */
    function _setWithdrawStatus(
        bool _status
    )
        internal
    {
        withdrawAllowed = _status;

        emit WithdrawStatusChanged(
            _status
        );
    }

    /**
     * @dev Internal function to set the auto-compound status for a specific user.
     * Controls whether a user can have their interest auto-compounded by whitelisted addresses.
     *
     * @param _user The address of the user whose auto-compound status is being set
     * @param _status True to allow auto-compound, false to disable it
     */
    function _setAutoCompoundStatus(
        address _user,
        bool _status
    )
        internal
    {
        autoCompoundAllowed[_user] = _status;

        emit AutoCompoundAllowedSet(
            _user,
            _status
        );
    }

    /**
     * @dev Internal function to set the whitelist status for a specific user.
     * Controls access to administrative functions and special operations.
     *
     * @param _user The address of the user whose whitelist status is being set
     * @param _status True to whitelist the user, false to remove from whitelist
     */
    function _setWhitelistStatus(
        address _user,
        bool _status
    )
        internal
    {
        isWhiteListed[_user] = _status;

        emit WhiteListAddressSet(
            _user,
            _status
        );
    }

    /**
     * @dev Internal function to disable supply changes by the owner.
     * Sets a flag that prevents future mint and burn operations by the owner.
     */
    function _disableSupplyChangeByOwner()
        internal
    {
        supplyChangeByOwnerNotAllowed = true;

        emit SupplyChangeByOwnerNotAllowedSet(
            true
        );
    }

    /**
     * @dev Internal function to execute the minting of new vault tokens.
     * Mints tokens to the specified address and emits a MintSupply event.
     *
     * @param _to The address to receive the minted tokens
     * @param _amount The amount of tokens to mint
     */
    function _executeMintSupply(
        address _to,
        uint256 _amount
    )
        internal
    {
        _mint(
            _to,
            _amount
        );

        emit MintSupply(
            _to,
            _amount
        );
    }

    /**
     * @dev Internal function to execute the burning of vault tokens.
     * Burns tokens from the specified address and emits a BurnSupply event.
     *
     * @param _from The address from which to burn tokens
     * @param _amount The amount of tokens to burn
     */
    function _executeBurnSupply(
        address _from,
        uint256 _amount
    )
        internal
    {
        _burn(
            _from,
            _amount
        );

        emit BurnSupply(
            _from,
            _amount
        );
    }

    /**
     * @dev Internal function to execute deposit and claim operations.
     * Performs the deposit first, then claims any available interest.
     *
     * @param _amount The amount of USD tokens to deposit
     * @return The amount of interest claimed
     */
    function _executeDepositAndClaim(
        uint256 _amount
    )
        internal
        returns (uint256)
    {
        _deposit(
            _amount
        );

        return
            _handleSimpleClaim(
                msg.sender
            );
    }

    /**
     * @dev Internal function to execute deposit and compound operations.
     * Performs the deposit first, then compounds any available interest.
     *
     * @param _amount The amount of USD tokens to deposit
     * @return The amount of interest compounded
     */
    function _executeDepositAndCompound(
        uint256 _amount
    )
        internal
        returns (uint256)
    {
        _deposit(
            _amount
        );

        return
            _handleCompoundInterest(
                msg.sender
            );
    }

    /**
     * @dev Internal function to validate that auto-compound is allowed for a user.
     *
     * @param _user The address of the user to validate
     */
    function _validateAutoCompoundAllowed(
        address _user
    )
        internal
        view
    {
        require(
            autoCompoundAllowed[_user],
            CompoundNotAllowed()
        );
    }

    /**
     * @dev Internal function to validate withdrawal parameters.
     * Checks that withdrawals are allowed, user has sufficient balance, and contract has sufficient USD.
     *
     * @param _amount The amount the user is trying to withdraw
     */
    function _validateWithdrawal(
        uint256 _amount
    )
        internal
        view
    {
        require(
            withdrawAllowed,
            WithdrawNotAllowed()
        );

        require(
            balanceOf(msg.sender) >= _amount,
            InsufficientBalance()
        );

        require(
            USD_TOKEN.balanceOf(address(this)) >= _amount,
            InsufficientBalanceInContract(
                _amount,
                USD_TOKEN.balanceOf(address(this))
            )
        );
    }

    /**
     * @dev Internal function to execute the withdrawal operation.
     * Burns the user's vault tokens and transfers USD tokens to the user.
     *
     * @param _amount The amount of vault tokens to withdraw
     */
    function _executeWithdrawal(
        uint256 _amount
    )
        internal
    {
        _burn(
            msg.sender,
            _amount
        );

        USD_TOKEN.safeTransfer(
            msg.sender,
            _amount
        );

        emit Withdrawn(
            msg.sender,
            _amount
        );
    }

    /**
     * @dev Internal function to update the third-party address.
     *
     * @param _thirdPartyAddress The new third-party address
     */
    function _updateThirdPartyAddress(
        address _thirdPartyAddress
    )
        internal
    {
        thirdPartyAddress = _thirdPartyAddress;

        emit ThirdPartyAddressSet(
            _thirdPartyAddress
        );
    }

    /**
     * @dev Internal function to update the total deposit cap.
     *
     * @param _totalDepositCap The new total deposit cap
     */
    function _updateTotalDepositCap(
        uint256 _totalDepositCap
    )
        internal
    {
        totalDepositCap = _totalDepositCap;

        emit TotalDepositCapSet(
            _totalDepositCap
        );
    }

    /**
     * @dev Internal function to update the transfer interest with tokens setting for a user.
     *
     * @param _transferInterestWithTokens The new setting for interest handling during transfers
     */
    function _updateTransferInterestSetting(
        bool _transferInterestWithTokens
    )
        internal
    {
        transferInterestWithTokens[msg.sender] = _transferInterestWithTokens;

        emit TransferInterestWithTokensSet(
            msg.sender,
            _transferInterestWithTokens
        );
    }

    // ================
    // VIEW FUNCTIONS
    // ================

    /**
     * @dev Calculates pending interest for a user at a specific timestamp.
     * Includes both regular balance and proxy balance in the calculation.
     *
     * @param _user The address of the user
     * @param _timestamp The timestamp to calculate interest up to
     * @return The pending interest amount
     */
    function getPendingInterestByTimeStamp(
        address _user,
        uint256 _timestamp
    )
        public
        view
        returns (uint256)
    {
        if (_user == InterestRateProxy) {
            return 0;
        }

        uint256 currentBalance = balanceOf(_user)
            + proxyBalance[_user];

        if (currentBalance == 0) {
            return 0;
        }

        uint256 lastSync = lastSyncTimeStamp[_user];

        if (_timestamp <= lastSync) {
            return 0;
        }

        uint256 timeDelta = _timestamp - lastSync;

        return
            _calculateInterest(
                currentBalance,
                timeDelta
            );
    }

    /**
     * @dev Calculates pending interest for a user up to the current block timestamp.
     *
     * @param _user The address of the user
     * @return The pending interest amount
     */
    function getPendingInterest(
        address _user
    )
        public
        view
        returns (uint256)
    {
        return
            getPendingInterestByTimeStamp(
                _user,
                block.timestamp
            );
    }

    /**
     * @dev Calculates pending interest for multiple users at a specific timestamp.
     * Useful for bulk operations and gas efficiency.
     *
     * @param _users Array of user addresses
     * @param _timestamp The timestamp to calculate interest up to
     * @return Array of pending interest amounts for each user
     */
    function getPendingInterestBulkByTimeStamp(
        address[] memory _users,
        uint256 _timestamp
    )
        public
        view
        returns (uint256[] memory)
    {
        uint256[] memory pendingInterests = new uint256[](_users.length);

        for (uint256 i = 0; i < _users.length; i++) {
            pendingInterests[i] = getPendingInterestByTimeStamp(
                _users[i],
                _timestamp
            );
        }

        return pendingInterests;
    }

    /**
     * @dev Calculates pending interest for multiple users up to the current block timestamp.
     *
     * @param _users Array of user addresses
     * @return Array of pending interest amounts for each user
     */
    function getPendingInterestBulk(
        address[] memory _users
    )
        external
        view
        returns (uint256[] memory)
    {
        return
            getPendingInterestBulkByTimeStamp(
                _users,
                block.timestamp
            );
    }

    /**
     * @dev Calculates total interest (cashed + pending) for a user at a specific timestamp.
     *
     * @param _user The address of the user
     * @param _timestamp The timestamp to calculate interest up to
     * @return The total interest amount
     */
    function getTotalInterestUserByTimeStamp(
        address _user,
        uint256 _timestamp
    )
        public
        view
        returns (uint256)
    {
        return
            cashedInterest[_user] +
            getPendingInterestByTimeStamp(
                _user,
                _timestamp
            );
    }

    /**
     * @dev Calculates total interest (cashed + pending) for a user up to the current block timestamp.
     *
     * @param _user The address of the user
     * @return The total interest amount
     */
    function getTotalInterestUser(
        address _user
    )
        external
        view
        returns (uint256)
    {
        return
            getTotalInterestUserByTimeStamp(
                _user,
                block.timestamp
            );
    }

    /**
     * @dev Calculates total interest for multiple users at a specific timestamp.
     *
     * @param _users Array of user addresses
     * @param _timestamp The timestamp to calculate interest up to
     * @return Array of total interest amounts for each user
     */
    function getTotalInterestUserBulkByTimeStamp(
        address[] memory _users,
        uint256 _timestamp
    )
        public
        view
        returns (uint256[] memory)
    {
        uint256[] memory totalInterests = new uint256[](_users.length);

        for (uint256 i = 0; i < _users.length; i++) {
            totalInterests[i] = getTotalInterestUserByTimeStamp(
                _users[i],
                _timestamp
            );
        }

        return totalInterests;
    }

    /**
     * @dev Calculates total interest for multiple users up to the current block timestamp.
     *
     * @param _users Array of user addresses
     * @return Array of total interest amounts for each user
     */
    function getTotalInterestUserBulk(
        address[] memory _users
    )
        public
        view
        returns (uint256[] memory)
    {
        return
            getTotalInterestUserBulkByTimeStamp(
                _users,
                block.timestamp
            );
    }

    // ================
    // ERC20 OVERRIDES
    // ================

    /**
     * @dev Returns the number of decimals used by the vault token.
     *
     * @return The number of decimal places
     */
    function decimals()
        public
        view
        override
        returns (uint8)
    {
        return decimalsSet;
    }

    /**
     * @dev Overrides the ERC20 transfer function to handle interest assignment and transfer.
     * Assigns interest to both sender and recipient, and handles interest transfer based on user preferences.
     *
     * @param to The address to transfer tokens to
     * @param amount The amount of tokens to transfer
     * @return True if the transfer was successful
     */
    function transfer(
        address to,
        uint256 amount
    )
        public
        assignInterest(msg.sender)
        assignInterest(to)
        nonReentrant
        override
        returns (bool)
    {
        require(
            amount > 0,
            InvalidValue()
        );

        _handleInterestTransfer(
            msg.sender,
            to
        );

        return
            super.transfer(
                to,
                amount
            );
    }

    /**
     * @dev Overrides the ERC20 transferFrom function to handle interest assignment and transfer.
     * Assigns interest to both sender and recipient, and handles interest transfer based on user preferences.
     *
     * @param from The address to transfer tokens from
     * @param to The address to transfer tokens to
     * @param amount The amount of tokens to transfer
     * @return True if the transfer was successful
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    )
        public
        assignInterest(from)
        assignInterest(to)
        nonReentrant
        override
        returns (bool)
    {
        require(
            amount > 0,
            InvalidValue()
        );

        _handleInterestTransfer(
            from,
            to
        );

        return
            super.transferFrom(
                from,
                to,
                amount
            );
    }
}
