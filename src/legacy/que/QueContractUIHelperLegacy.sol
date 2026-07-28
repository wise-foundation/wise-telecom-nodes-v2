// SPDX-License-Identifier: -- WISE --
// @author: René Hochmuth

pragma solidity =0.8.29;

import "./QueContractHelperLegacy.sol";

/**
 * @title QueContractUIHelper
 * @dev UI helper contract providing user-friendly functions for queue interaction and order planning.
 *
 * This contract provides:
 * - Order fulfillment planning and simulation
 * - Cost prediction functions for user interface
 * - Order retrieval functions for display purposes
 * - Bulk order analysis capabilities
 *
 * The contract implements user-friendly functions that:
 * - Allow users to predict costs before placing orders
 * - Enable order planning without execution
 * - Provide comprehensive order book visibility
 * - Support efficient bulk operations for UIs
 *
 * @notice This contract inherits from QueContractHelper which contains
 * the core order processing and solving logic.
 */
abstract contract QueContractUIHelper is QueContractHelper {

    /**
     * @dev Generates a fulfillment plan for a specific amount and incentive.
     * Traverses the queue to determine which orders need to be fulfilled to meet the requested amount.
     * Returns arrays of full and partial order IDs that would be processed.
     *
     * @param _amount The amount of vault tokens to acquire
     * @param _incentive The incentive level to process
     * @param _maxOrdersToConsider Maximum number of orders to consider (0 for unlimited)
     * @return fullOrderIds Array of full order IDs that can be completely fulfilled
     * @return partialOrderIds Array of partial order IDs (if needed)
     * @return nextStartingId The next order ID to start processing from after this plan
     */
    function getFulfillmentPlanForIncentive(
        uint256 _amount,
        int256 _incentive,
        uint256 _maxOrdersToConsider
    )
        public
        view
        returns (
            uint256[] memory fullOrderIds,
            uint256[] memory partialOrderIds,
            uint256 nextStartingId
        )
    {
        uint256 considerationLimit = _maxOrdersToConsider;

        if (considerationLimit == 0 || considerationLimit > MAX_ORDERS_TO_CONSIDER_LIMIT) {
            considerationLimit = MAX_ORDERS_TO_CONSIDER_LIMIT;
        }

        uint256 activeCount = activeOrderCountByIncentive[_incentive];
        if (activeCount == 0) {
            fullOrderIds = new uint256[](0);
            partialOrderIds = new uint256[](0);
            nextStartingId = currentOrderIdByIncentive[_incentive];
            return (
                fullOrderIds,
                partialOrderIds,
                nextStartingId
            );
        }

        PlanVars memory v = _initializePlanVars(
            activeCount,
            _maxOrdersToConsider
        );

        uint256[] memory tempFull = new uint256[](v.arraySize);
        v.current = currentOrderIdByIncentive[_incentive];
        nextStartingId = v.current;
        uint256 amountLeft = _amount;

        while (_shouldContinuePlanTraversal(amountLeft, v, _incentive, _maxOrdersToConsider, considerationLimit)) {
            (
                amountLeft,
                nextStartingId
            ) = _processOrderInPlan(
                v,
                tempFull,
                amountLeft,
                _incentive
            );
        }

        (
            fullOrderIds,
            partialOrderIds
        ) = _buildFinalOrderArrays(
            v,
            tempFull
        );
    }

    /**
     * @dev Solves for the optimal order combination to fulfill a specific amount across all incentives.
     * Returns arrays of incentives, order IDs, and partial order IDs needed to fulfill the amount.
     * Orders are prioritized by incentive level (highest to lowest).
     *
     * @param _amount The amount of vault tokens to acquire
     * @return incentives Array of incentive levels for each order
     * @return orders Array of full order IDs
     * @return partials Array of partial order IDs
     */
    function solveForAmount(
        uint256 _amount
    )
        public
        view
        returns (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory partials
        )
    {
        return _solveForAmount(
            _amount,
            true
        );
    }

    /**
     * @dev Calculates the discounted amount for a given base amount and incentive.
     * Applies the incentive as a percentage discount or premium to the base amount.
     * Returns the final amount after applying the incentive factor.
     *
     * @param _amount The base amount to apply the incentive to
     * @param _incentive The incentive rate (positive for discount, negative for premium)
     * @return discountedAmount The final amount after applying the incentive
     */
    function predictDiscountedAmount(
        uint256 _amount,
        int256 _incentive
    )
        public
        pure
        returns (
            uint256 discountedAmount
        )
    {
        return _predictDiscountedAmount(
            _amount,
            _incentive
        );
    }

    /**
     * @notice Predicts the exact USDC cost to receive a specific amount of vault tokens.
     * @dev This function simulates a call to `fulfillOrderBySolveForAmount` by using the same
     * `solveForAmount` plan and `predictDiscountedAmount` calculations.
     *
     * @param _tokensToReceive The desired amount of vault tokens
     * @return costInUsd The exact cost in USDC to acquire the tokens
     * @return tokensAcquirable The actual amount of tokens that can be acquired. This may be less than
     * `_tokensToReceive` if the queue has insufficient liquidity
     */
    function predictCostForTokens(
        uint256 _tokensToReceive
    )
        public
        view
        returns (
            uint256 costInUsd,
            uint256 tokensAcquirable
        )
    {
        (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory partials
        ) = solveForAmount(
            _tokensToReceive
        );

        uint256 totalTokensPlanned;

        (
            costInUsd,
            totalTokensPlanned
        ) = _calculateFullOrdersCost(
            orders,
            incentives
        );

        (
            uint256 partialCost,
            uint256 partialTokens
        ) = _calculatePartialOrderCost(
            partials,
            incentives,
            orders.length,
            _tokensToReceive,
            totalTokensPlanned
        );

        costInUsd += partialCost;
        tokensAcquirable = totalTokensPlanned + partialTokens;
    }

    /**
     * @dev Solves for the optimal order combination to fulfill a specific amount for a given incentive.
     * Returns arrays of full and partial order IDs that would be processed for that specific incentive.
     * Useful for planning order fulfillment within a single incentive level.
     *
     * @param _amount The amount of vault tokens to acquire
     * @param _incentive The incentive level to process
     * @return fullOrderIds Array of full order IDs that can be completely fulfilled
     * @return partialOrderIds Array of partial order IDs (if needed)
     */
    function solveForAmountWithIncentive(
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
        return _solveForAmountWithIncentive(
            _amount,
            _incentive
        );
    }

    /**
     * @notice Predicts the exact amount of vault tokens that will be received for a given USDC cost.
     * @dev This function simulates "spending" a USDC budget against the order book, starting
     * from the highest incentive, to calculate the total tokens acquired.
     *
     * @param _costInUsd The amount of USDC a user is willing to send
     * @return tokensReceived The exact amount of vault tokens that will be received
     */
    function predictTokensForCost(
        uint256 _costInUsd
    )
        public
        view
        returns (
            uint256 tokensReceived
        )
    {
        uint256 remainingUsd = _costInUsd;
        int16[9] memory incs = _initializePositiveIncentivesArray();

        for (uint256 i = 0; i < incs.length; i++) {
            if (remainingUsd == 0) break;

            (
                uint256 tokens,
                uint256 spent
            ) = _processIncentiveForCost(
                incs[i],
                remainingUsd
            );

            tokensReceived += tokens;
            remainingUsd -= spent;
        }

        return tokensReceived;
    }

    /**
     * @dev Retrieves all active orders for a specific user address.
     * Returns arrays of QueMember structs and their corresponding incentives.
     * Only includes orders where the member matches the specified user address.
     *
     * @param _user The address of the user whose orders to retrieve
     * @return Array of QueMember structs for the user's orders
     * @return Array of incentive levels corresponding to each order
     */
    function getAllOrdersfromAddress(
        address _user
    )
        public
        view
        returns (
            QueMember[] memory,
            int256[] memory
        )
    {
        return _collectAllOrders(
            _user,
            true
        );
    }

    /**
     * @dev Retrieves all active orders across all users in the system.
     * Returns arrays of QueMember structs and their corresponding incentives.
     * Includes all orders regardless of the member address.
     *
     * @return Array of QueMember structs for all active orders
     * @return Array of incentive levels corresponding to each order
     */
    function getAllOrdersOverall()
        public
        view
        returns (
            QueMember[] memory,
            int256[] memory
        )
    {
        return _collectAllOrders(
            address(0),
            false
        );
    }
}
