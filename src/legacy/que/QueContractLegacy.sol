// SPDX-License-Identifier: -- WISE --
// @author: René Hochmuth

pragma solidity =0.8.29;

import "./QueContractUIHelperLegacy.sol";

/**
 * @title QueContract
 * @dev Main contract for the queue-based order fulfillment system.
 *
 * This contract implements a sophisticated queue mechanism that allows users to:
 * - Join a queue with vault tokens and specify an incentive rate
 * - Leave the queue and receive their tokens back
 * - Reduce their queue amount partially
 * - Fulfill orders by providing USD tokens in exchange for vault tokens
 *
 * The queue system features:
 * - Multiple incentive levels (positive and negative) for price discovery
 * - Doubly-linked list implementation for efficient order management
 * - Bulk order fulfillment for gas efficiency
 * - Partial order fulfillment capabilities
 * - Automatic order processing based on FIFO principles within each incentive level
 *
 * @notice This contract inherits from QueContractUIHelper which contains
 * the UI helper functions and order planning logic.
 */
contract QueContract is QueContractUIHelper {

    /**
     * @dev Constructor for the QueContract.
     * Initializes the queue contract with a reference to the forward vault.
     *
     * @param _forwardVault The address of the ForwardVaultERC20 contract
     */
    constructor(
        address _forwardVault
    )
        QueContractDeclarations(
            _forwardVault
        )
    {}

    /**
     * @dev Allows a user to join the queue with a specific amount and incentive.
     * Transfers tokens from the user to this contract and creates a new queue member.
     * Updates the proxy balance and emits a JoinQue event.
     * Returns the created queue member and the new member ID.
     *
     * @param _amount The amount of vault tokens to add to the queue
     * @param _incentive The incentive rate for this order (can be positive or negative)
     * @return member The created queue member structure
     * @return newId The unique ID assigned to this queue member
     */
    function joinQue(
        uint256 _amount,
        int256 _incentive
    )
        setProxyBenefactor
        nonReentrant
        external
        returns (
            QueMember memory,
            uint256
        )
    {
        if (negativeIncentivesNotAllowed == true) {
            require(
                _incentive >= 0,
                NegativeIncentiveNotAllowed()
            );
        }

        _validateJoinQue(
            _amount,
            _incentive
        );

        (
            QueMember memory member,
            uint256 newId
        ) = _createQueMember(
            _amount,
            _incentive
        );

        _updateJoinQueState(
            _amount,
            _incentive
        );

        _setProxyBenefactor(
            msg.sender
        );

        _transferTokensIn(
            _amount
        );

        emit JoinQue(
            msg.sender,
            _amount,
            _incentive,
            newId
        );

        return (
            member,
            newId
        );
    }

    /**
     * @dev Allows a user to leave the queue by removing their queue member.
     * Validates the member can leave, updates linked list pointers, and transfers tokens back to the user.
     * Emits a LeaveQue event with the cashed amount.
     * Returns the queue member and the withdrawn amount.
     *
     * @param _queMemberId The ID of the queue member to remove
     * @param _incentive The incentive level of the queue member
     * @return member The queue member structure that was removed
     * @return leftOverAmount The amount of tokens returned to the user
     */
    function leaveQue(
        uint256 _queMemberId,
        int256 _incentive
    )
        setProxyBenefactor
        nonReentrant
        external
        returns (
            QueMember memory,
            uint256 leftOverAmount
        )
    {
        _validateLeaveQue(
            _queMemberId,
            _incentive
        );

        QueMember storage member = QueMemberByIdAndIncentive[_queMemberId][_incentive];
        leftOverAmount = member.amount;

        _validateMemberCanLeave(
            member
        );

        _updateCurrentOrderIfNeeded(
            _queMemberId,
            _incentive,
            member
        );

        _finalizeMemberRemoval(
            _queMemberId,
            member,
            _incentive,
            true
        );

        _setProxyBenefactor(
            msg.sender
        );

        _transferTokensOut(
            msg.sender,
            leftOverAmount
        );

        emit LeaveQue(
            msg.sender,
            _queMemberId,
            _incentive,
            leftOverAmount
        );

        return (
            member,
            leftOverAmount
        );
    }

    /**
     * @dev Allows a user to reduce their queue amount by a specified amount.
     * Validates the reduction is possible, updates the member's amount, and transfers the reduced tokens out.
     * Ensures the remaining amount meets minimum deposit requirements.
     * Returns the queue member and the remaining amount after reduction.
     *
     * @param _queMemberId The ID of the queue member to reduce
     * @param _incentive The incentive level of the queue member
     * @param _reduceBy The amount to reduce the queue member by
     * @return member The updated queue member structure
     * @return leftOverAmount The remaining amount in the queue member
     */
    function reduceQueAmount(
        uint256 _queMemberId,
        int256 _incentive,
        uint256 _reduceBy
    )
        external
        setProxyBenefactor
        nonReentrant
        returns (
            QueMember memory,
            uint256 leftOverAmount
        )
    {
        _validateReduceAmount(
            _queMemberId,
            _incentive,
            _reduceBy
        );

        QueMember storage member = QueMemberByIdAndIncentive[_queMemberId][_incentive];

        _validateMemberCanReduce(
            member,
            _reduceBy
        );

        _executeReduction(
            member,
            _reduceBy
        );

        _setProxyBenefactor(
            msg.sender
        );

        _transferTokensOut(
            msg.sender,
            _reduceBy
        );

        emit ReduceQueAmount(
            msg.sender,
            _queMemberId,
            _incentive,
            _reduceBy
        );

        return (
            member,
            member.amount
        );
    }

    /**
     * @dev Fulfills a complete order for a specific queue member.
     * Processes the order by transferring discounted USD tokens to the member and vault tokens to the fulfiller.
     * Removes the member from the queue and updates the current order pointer.
     * Returns the forward vault token amount and stablecoin token amount processed.
     *
     * @param _queMemberId The ID of the queue member to fulfill
     * @param _incentive The incentive level of the queue member
     * @return forwardVaultTokenAmount The amount of vault tokens transferred to the fulfiller
     * @return stableCoinTokenAmount The amount of USD tokens transferred to the queue member
     */
    function fulfillOrder(
        uint256 _queMemberId,
        int256 _incentive
    )
        nonReentrant
        setProxyBenefactor
        external
        returns (
            uint256 forwardVaultTokenAmount,
            uint256 stableCoinTokenAmount
        )
    {
        return _processOrder(
            _queMemberId,
            _incentive,
            QueMemberByIdAndIncentive[_queMemberId][_incentive].amount,
            true
        );
    }

    /**
     * @dev Partially fulfills an order for a specific queue member with a specified amount.
     * Processes the partial order by transferring discounted USD tokens to the member and vault tokens to the fulfiller.
     * Reduces the member's amount but keeps them in the queue.
     * Returns the forward vault token amount and stablecoin token amount processed.
     *
     * @param _queMemberId The ID of the queue member to partially fulfill
     * @param _incentive The incentive level of the queue member
     * @param _amount The amount to fulfill (must be less than the member's total amount)
     * @return forwardVaultTokenAmount The amount of vault tokens transferred to the fulfiller
     * @return stableCoinTokenAmount The amount of USD tokens transferred to the queue member
     */
    function partiallyFulfillOrder(
        uint256 _queMemberId,
        int256 _incentive,
        uint256 _amount
    )
        nonReentrant
        setProxyBenefactor
        external
        returns (
            uint256 forwardVaultTokenAmount,
            uint256 stableCoinTokenAmount
        )
    {
        return _processOrder({
            _queMemberId: _queMemberId,
            _incentive: _incentive,
            _amount: _amount,
            _isFullFulfill: false
        });
    }

    /**
     * @dev Fulfills multiple orders in a single transaction for gas efficiency.
     * Processes a combination of full orders and partial orders across different incentives.
     * Validates that the total cost doesn't exceed the maximum USD spend and that the received amount meets minimum requirements.
     *
     * @param _incentives Array of incentive levels for each order
     * @param _memberIds Array of queue member IDs for full orders
     * @param _partialId Array of queue member IDs for partial orders
     * @param _partialAmount The amount to fulfill for the partial order
     * @param _minReceiveAmount Minimum amount of vault tokens that must be received
     * @param _maxUsdToSpend Maximum amount of USD tokens that can be spent
     * @return vaultTokensReceived Total amount of vault tokens received
     * @return usdSpent Total amount of USD tokens spent
     */
    function fulfillOrderBulk(
        int256[] calldata _incentives,
        uint256[] calldata _memberIds,
        uint256[] calldata _partialId,
        uint256 _partialAmount,
        uint256 _minReceiveAmount,
        uint256 _maxUsdToSpend
    )
        nonReentrant
        setProxyBenefactor
        external
        returns (
            uint256 vaultTokensReceived,
            uint256 usdSpent
        )
    {
        FulfillOrderBulkVars memory vars = FulfillOrderBulkVars({
            incentives: _incentives,
            orders: _memberIds,
            partials: _partialId,
            partialAmount: _partialAmount,
            minReceiveAmount: _minReceiveAmount,
            maxUsdToSpend: _maxUsdToSpend
        });

        require(
            _hasNoOrdersToProcess(vars.orders, vars.partials) == false,
            NoOrdersPresent()
        );

        for (uint256 i; i < vars.orders.length; ++i) {
            (
                uint256 vt,
                uint256 usd
            ) = _processOrder({
                _queMemberId: vars.orders[i],
                _incentive: vars.incentives[i],
                _amount: QueMemberByIdAndIncentive[vars.orders[i]][vars.incentives[i]].amount,
                _isFullFulfill: true
            });

            vaultTokensReceived += vt;
            usdSpent            += usd;
        }

        if (vars.partials.length > 0 && vars.partialAmount > 0) {

            (
                uint256 vt,
                uint256 usd
            ) = _processOrder({
                _queMemberId: vars.partials[0],
                _incentive: vars.incentives[vars.incentives.length - 1],
                _amount: vars.partialAmount,
                _isFullFulfill: false
            });

            vaultTokensReceived += vt;
            usdSpent            += usd;
         }

        require(
            vaultTokensReceived >= vars.minReceiveAmount,
            AmountReceivedTooLow()
        );

        require(
            usdSpent <= vars.maxUsdToSpend,
            AmountSpentTooHigh()
        );
    }

    /**
     * @dev Changes the minimum deposit amount for new queue members.
     * Only callable by the master account.
     *
     * @param _minDepositAmount The new minimum deposit amount
     */
    function changeMinDepositAmount(
        uint256 _minDepositAmount
    )
        external
        onlyMaster
    {
        minDepositAmount = _minDepositAmount;
    }

    /**
     * @dev Allows the master to set whether negative incentives are allowed.
     * Only callable by the master account.
     *
     * @param _negativeIncentivesNotAllowed The new value for negative incentives allowed
     */
    function setNegativeIncentivesNotAllowed(
        bool _negativeIncentivesNotAllowed
    )
        external
        onlyMaster
    {
        negativeIncentivesNotAllowed = _negativeIncentivesNotAllowed;
    }
}
