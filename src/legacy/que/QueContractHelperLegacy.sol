// SPDX-License-Identifier: -- WISE --
// @author: René Hochmuth

pragma solidity =0.8.29;

import "./QueContractLowLevelHelperLegacy.sol";

/**
 * @title QueContractHelper
 * @dev Helper contract containing the core logic for queue operations and order processing.
 *
 * This contract provides:
 * - Order processing logic for both full and partial fulfillments
 * - Queue traversal algorithms for order planning
 * - Cost calculation functions for order optimization
 * - Bulk order solving capabilities across multiple incentives
 *
 * The contract implements sophisticated order management that:
 * - Processes orders based on FIFO principles within each incentive level
 * - Handles both full and partial order fulfillments
 * - Optimizes order combinations for cost efficiency
 * - Supports bulk operations for gas efficiency
 *
 * @notice This contract inherits from QueContractLowLevelHelper which contains
 * the low-level helper functions and data structures.
 */
abstract contract QueContractHelper is QueContractLowLevelHelper {

    /**
     * @dev Modifier that sets the proxy benefactor for the forward vault during function execution.
     * Ensures the proxy benefactor is reset to zero address after the function completes.
     */
    modifier setProxyBenefactor() {
        _;

        _setProxyBenefactor(
            ZERO_ADDRESS
        );
    }

    /**
     * @dev Processes an order by validating it, calculating discounted amounts, and executing transfers.
     * Updates order state and emits an OrderProcessed event.
     * Returns the forward vault token amount and stablecoin token amount processed.
     *
     * @param _queMemberId The ID of the queue member to process
     * @param _incentive The incentive level of the order
     * @param _amount The amount to process (full amount for complete fulfillment, partial for partial fulfillment)
     * @param _isFullFulfill True if this is a complete fulfillment, false for partial
     * @return forwardVaultTokenAmount The amount of vault tokens transferred to the fulfiller
     * @return stableCoinTokenAmount The amount of USD tokens transferred to the queue member
     */
    function _processOrder(
        uint256 _queMemberId,
        int256 _incentive,
        uint256 _amount,
        bool _isFullFulfill
    )
        internal
        returns (
            uint256 forwardVaultTokenAmount,
            uint256 stableCoinTokenAmount
        )
    {
        _validateOrderProcessing(
            _queMemberId,
            _incentive,
            _amount,
            _isFullFulfill
        );

        QueMember storage member = QueMemberByIdAndIncentive[_queMemberId][_incentive];

        uint256 discountedAmount = _predictDiscountedAmount(
            _amount,
            _incentive
        );

        discountedAmount = discountedAmount == 0
            ? _amount
            : discountedAmount;

        address cashedMember = member.member;

        _changeProxyAccounting(
            _decreaseProxyBalance,
            cashedMember,
            _amount
        );

        _setProxyBenefactor(
            cashedMember
        );

        _executeTransfers(
            cashedMember,
            _amount,
            discountedAmount
        );

        if (_isFullFulfill) {
            currentOrderIdByIncentive[_incentive] = member.headPointer;

            _finalizeMemberRemoval(
                _queMemberId,
                member,
                _incentive,
                false
            );

        } else {
            member.amount -= _amount;
        }

        emit OrderProcessed(
            msg.sender,
            cashedMember,
            _queMemberId,
            _incentive,
            _amount,
            _isFullFulfill
        );

        return (
            _amount,
            discountedAmount
        );
    }

    /**
     * @dev Processes an order within a plan traversal.
     * Handles empty orders, full orders, and partial orders based on remaining amount.
     * Returns the new remaining amount and next starting ID.
     *
     * @param _v The plan variables containing traversal state
     * @param _tempFull Temporary array to store full order IDs
     * @param _amountLeft The remaining amount to process
     * @param _incentive The incentive level being processed
     * @return newAmountLeft The remaining amount after processing this order
     * @return nextStartingId The next order ID to start processing from
     */
    function _processOrderInPlan(
        PlanVars memory _v,
        uint256[] memory _tempFull,
        uint256 _amountLeft,
        int256 _incentive
    )
        internal
        view
        returns (
            uint256 newAmountLeft,
            uint256 nextStartingId
        )
    {
        QueMember storage entry = QueMemberByIdAndIncentive[_v.current][_incentive];
        uint256 amt = entry.amount;
        _v.ordersConsidered++;

        if (_isEmptyOrder(entry)) {
            (
                _v.current,
                nextStartingId
            ) = _moveToNextOrder(
                entry,
                _incentive
            );

            return (
                _amountLeft,
                nextStartingId
            );
        }

        if (_amountLeft >= amt) {
            _tempFull[_v.fullIndex] = _v.current;
            _v.fullIndex++;
            newAmountLeft = _amountLeft - amt;
            (
                _v.current,
                nextStartingId
            ) = _moveToNextOrder(
                entry,
                _incentive
            );

        } else {
            _v.partialId = _v.current;
            _v.hasPartial = true;
            newAmountLeft = 0;
            nextStartingId = _v.current;
        }
    }

    /**
     * @dev Traverses orders for a specific amount and incentive.
     * Builds arrays of full orders and identifies partial orders needed.
     * Returns temporary arrays and flags for order processing.
     *
     * @param _amount The amount of tokens to acquire
     * @param _incentive The incentive level to process
     * @return tempFull Array of full order IDs that can be completely fulfilled
     * @return partialId ID of the partial order (if needed)
     * @return hasPartial True if a partial order is needed
     * @return fullIndex Number of full orders found
     */
    function _traverseOrdersForAmount(
        uint256 _amount,
        int256 _incentive
    )
        internal
        view
        returns (
            uint256[] memory tempFull,
            uint256 partialId,
            bool hasPartial,
            uint256 fullIndex
        )
    {
        uint256 total = activeOrderCountByIncentive[_incentive];
        tempFull = new uint256[](total);
        uint256 current = currentOrderIdByIncentive[_incentive];
        uint256 amountLeft = _amount;

        while (amountLeft > 0 && current < earliestValidQueMemberByIncentive[_incentive] && fullIndex < total) {
            QueMember storage entry = QueMemberByIdAndIncentive[current][_incentive];

            if (_isEmptyOrder(entry)) {
                current = entry.headPointer;
                continue;
            }

            if (amountLeft >= entry.amount) {
                tempFull[fullIndex] = current;
                fullIndex++;
                amountLeft -= entry.amount;
                current = entry.headPointer;
            } else {
                partialId = current;
                hasPartial = true;
                break;
            }
        }
    }

    /**
     * @dev Processes all orders for a specific incentive during cost calculation.
     * Traverses the queue for the incentive and calculates total tokens and USD spent.
     *
     * @param _incentive The incentive level to process
     * @param _remainingUsd The remaining USD budget to spend
     * @return tokensReceived The total tokens that can be acquired
     * @return usdSpent The total USD that will be spent
     */
    function _processIncentiveForCost(
        int256 _incentive,
        uint256 _remainingUsd
    )
        internal
        view
        returns (
            uint256 tokensReceived,
            uint256 usdSpent
        )
    {
        uint256 currentOrderId = currentOrderIdByIncentive[_incentive];
        uint256 earliestId = earliestValidQueMemberByIncentive[_incentive];
        uint256 remainingBudget = _remainingUsd;

        while (currentOrderId < earliestId && remainingBudget > 0) {
            QueMember storage entry = QueMemberByIdAndIncentive[currentOrderId][_incentive];

            if (_isEmptyOrder(entry)) {
                currentOrderId = entry.headPointer;
                continue;
            }

            (
                uint256 tokens,
                uint256 spent
            ) = _processOrderForCost(
                entry,
                _incentive,
                remainingBudget
            );

            tokensReceived += tokens;
            remainingBudget -= spent;

            if (spent < _predictDiscountedAmount(entry.amount, _incentive)) {
                break;
            }

            currentOrderId = entry.headPointer;
        }

        usdSpent = _remainingUsd - remainingBudget;
    }

    /**
     * @dev Solves for the optimal order combination to fulfill a specific amount for a given incentive.
     * Returns arrays of full and partial order IDs that would be processed for that specific incentive.
     *
     * @param _amount The amount of tokens to acquire
     * @param _incentive The incentive level to process
     * @return fullOrderIds Array of full order IDs that can be completely fulfilled
     * @return partialOrderIds Array of partial order IDs (if needed)
     */
    function _solveForAmountWithIncentive(
        uint256 _amount,
        int256 _incentive
    )
        public
        view
        returns (
            uint256[] memory fullOrderIds,
            uint256[] memory partialOrderIds
        )
    {
        (
            uint256[] memory tempFull,
            uint256 partialId,
            bool hasPartial,
            uint256 fullIndex
        ) = _traverseOrdersForAmount(
            _amount,
            _incentive
        );

        fullOrderIds = new uint256[](fullIndex);

        for (uint256 i; i < fullIndex; i++) {
            fullOrderIds[i] = tempFull[i];
        }

        if (hasPartial) {
            partialOrderIds = new uint256[](1);
            partialOrderIds[0] = partialId;
        } else {
            partialOrderIds = new uint256[](0);
        }
    }

    /**
     * @dev Solves for the optimal order combination to fulfill a specific amount across all incentives.
     * Processes orders starting from the highest incentive down to the lowest.
     * Returns arrays of incentives, order IDs, and partial order IDs needed.
     *
     * @param _amount The amount of tokens to acquire
     * @param _allowNegativeIncentives Whether to consider negative incentives if positive ones are insufficient
     * @return incentives Array of incentive levels for each order
     * @return orders Array of full order IDs
     * @return partials Array of partial order IDs
     */
    function _solveForAmount(
        uint256 _amount,
        bool    _allowNegativeIncentives
    )
        internal
        view
        returns (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory partials
        )
    {
        SolveForAmountVars memory v = _initializeSolveVars();
        uint256 remainingAmount = _amount;

        int16[9] memory pos = _initializePositiveIncentivesArray();

        for (uint256 i; i < pos.length && remainingAmount > 0; ++i) {
            (
                uint256[] memory fullIds,
                uint256[] memory partialIds
            ) = _solveForAmountWithIncentive(remainingAmount, pos[i]);

            remainingAmount = _processFullOrdersForIncentive(
                v,
                fullIds,
                pos[i],
                remainingAmount
            );

            if (remainingAmount > 0 && partialIds.length != 0) {
                _processPartialOrderForIncentive(v, partialIds, pos[i]);
                remainingAmount = 0;
                break;
            }
        }

        if (_allowNegativeIncentives && remainingAmount > 0) {
            int16[8] memory neg = _initializeNegativeIncentivesArray();

            for (uint256 j; j < neg.length && remainingAmount > 0; ++j) {
                (
                    uint256[] memory fullIds,
                    uint256[] memory partialIds
                ) = _solveForAmountWithIncentive(remainingAmount, neg[j]);

                remainingAmount = _processFullOrdersForIncentive(
                    v,
                    fullIds,
                    neg[j],
                    remainingAmount
                );

                if (remainingAmount > 0 && partialIds.length != 0) {
                    _processPartialOrderForIncentive(v, partialIds, neg[j]);
                    remainingAmount = 0;
                    break;
                }
            }
        }

        return _buildSolveResults(
            v
        );
    }
}
