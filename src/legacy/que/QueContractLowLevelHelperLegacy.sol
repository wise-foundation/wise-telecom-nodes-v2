// SPDX-License-Identifier: -- WISE --
// @author: René Hochmuth

pragma solidity =0.8.29;

import "./QueContractDeclarationsLegacy.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title QueContractLowLevelHelper
 * @dev Low-level helper contract containing the foundational logic for queue operations.
 *
 * This contract provides:
 * - Queue member creation and management
 * - Token transfer operations with safety checks
 * - Validation functions for all queue operations
 * - Linked list manipulation for efficient queue traversal
 * - Order processing and fulfillment logic
 * - Cost calculation and optimization algorithms
 *
 * The contract implements sophisticated queue management that:
 * - Maintains doubly-linked lists for each incentive level
 * - Ensures queue integrity during member additions and removals
 * - Provides efficient order traversal and processing
 * - Handles complex order solving across multiple incentives
 * - Supports bulk operations for gas efficiency
 *
 * @notice This contract inherits from QueContractDeclarations which contains
 * all the state variables, events, and error definitions.
 */
abstract contract QueContractLowLevelHelper is QueContractDeclarations {

    using SafeERC20 for IERC20;

    /**
     * @dev Sets the proxy benefactor for the forward vault.
     * Internal function used by the setProxyBenefactor modifier.
     */
    function _setProxyBenefactor(
        address _user
    )
        internal
    {
        forwardVault.setProxyBenefactor(
            _user
        );
    }

    /**
     * @dev Validates the parameters for joining the queue.
     * Ensures amount is greater than zero, incentive is allowed, and amount meets minimum deposit requirements.
     */
    function _validateJoinQue(
        uint256 _amount,
        int256 _incentive
    )
        internal
        view
    {
        require(
            _amount > 0,
            ZeroAmount()
        );

        _requireIncentiveAllowed(
            _incentive
        );

        _requireMinDeposit(
            _amount
        );
    }

    /**
     * @dev Transfers vault tokens from the sender to this contract.
     * Uses SafeERC20 for secure token transfers.
     */
    function _transferTokensIn(
        uint256 _amount
    )
        internal
    {
        IERC20(address(forwardVault)).safeTransferFrom(
            msg.sender,
            address(this),
            _amount
        );
    }

    /**
     * @dev Creates a new queue member with the specified amount and incentive.
     * Ensures that both forward and back links are written so the
     * list remains well-formed even when the new slot is the current
     * "first-free" sentinel.
     */
    function _createQueMember(
        uint256 _amount,
        int256  _incentive
    )
        internal
        returns (
            QueMember memory member,
            uint256 newId
        )
    {
        newId = earliestValidQueMemberByIncentive[_incentive];
        QueMember storage hole = QueMemberByIdAndIncentive[newId][_incentive];

        uint256 prevId = hole.tailPointer;

        uint256 nextId = newId + 1;

        member = QueMember({
            member:      msg.sender,
            amount:      _amount,
            tailPointer: prevId,
            headPointer: nextId
        });

        QueMemberByIdAndIncentive[newId][_incentive] = member;

        if (prevId < earliestValidQueMemberByIncentive[_incentive]) {
            QueMemberByIdAndIncentive[prevId][_incentive].headPointer = newId;
        }

        QueMemberByIdAndIncentive[nextId][_incentive].tailPointer = newId;

        unchecked { ++earliestValidQueMemberByIncentive[_incentive]; }
    }

    /**
     * @dev Updates the state after a user joins the queue.
     * Increases the proxy balance for the user and increments order counters.
     */
    function _updateJoinQueState(
        uint256 _amount,
        int256 _incentive
    )
        internal
    {
        _changeProxyAccounting(
            _increaseProxyBalance,
            msg.sender,
            _amount
        );

        totalActiveOrders++;
        activeOrderCountByIncentive[_incentive]++;
    }

    /**
     * @dev Validates the parameters for leaving the queue.
     * Ensures the queue member ID is valid and the incentive is allowed.
     */
    function _validateLeaveQue(
        uint256 _queMemberId,
        int256 _incentive
    )
        internal
        view
    {
        _requireValidMemberId(
            _queMemberId,
            _incentive
        );

        _requireIncentiveAllowed(
            _incentive
        );
    }

    /**
     * @dev Validates a partial order by ensuring the fill amount is valid.
     * Checks that the partial fill amount is greater than zero and less than the order amount.
     */
    function _validatePartialOrder(
        uint256 _orderId,
        uint256 _partialFillAmount,
        int256 _incentive
    )
        internal
        view
    {
        require(
            _partialFillAmount > 0,
            ZeroAmount()
        );

        require(
            _partialFillAmount < QueMemberByIdAndIncentive[_orderId][_incentive].amount,
            AmountTooHigh()
        );

        _requireIncentiveAllowed(
            _incentive
        );

        _requireValidMemberId(
            _orderId,
            _incentive
        );
    }

    /**
     * @dev Checks if there are no orders to process.
     * Returns true if both orders and partials arrays are empty.
     */
    function _hasNoOrdersToProcess(
        uint256[] memory _orders,
        uint256[] memory _partials
    )
        internal
        pure
        returns (bool)
    {
        return _orders.length == 0 && _partials.length == 0;
    }

    /**
     * @dev Validates the parameters for reducing a queue amount.
     * Ensures the reduction amount is greater than zero, queue member ID is valid, and incentive is allowed.
     */
    function _validateReduceAmount(
        uint256 _queMemberId,
        int256 _incentive,
        uint256 _reduceBy
    )
        internal
        view
    {
        require(
            _reduceBy > 0,
            ZeroAmount()
        );

        _requireValidMemberId(
            _queMemberId,
            _incentive
        );

        _requireIncentiveAllowed(
            _incentive
        );
    }

    /**
     * @dev Executes the reduction of a member's queue amount.
     * Decreases the proxy balance and updates the member's amount.
     * Ensures the remaining amount meets minimum deposit requirements.
     */
    function _executeReduction(
        QueMember storage _member,
        uint256 _reduceBy
    )
        internal
    {
        _changeProxyAccounting(
            _decreaseProxyBalance,
            msg.sender,
            _reduceBy
        );

        _member.amount -= _reduceBy;

        _requireMinDeposit(
            _member.amount
        );
    }

    /**
     * @dev Increases the proxy balance for a user.
     */
    function _increaseProxyBalance(
        address _user,
        uint256 _amount
    )
        internal
    {
        forwardVault.increaseProxyBalance(
            _user,
            _amount
        );
    }

    /**
     * @dev Decreases the proxy balance for a user.
     */
    function _decreaseProxyBalance(
        address _user,
        uint256 _amount
    )
        internal
    {
        forwardVault.decreaseProxyBalance(
            _user,
            _amount
        );
    }

    /**
     * @dev Changes the proxy accounting for a user.
     * @param _changeProxyBalance The function to use for changing the proxy balance.
     * @param _user The address of the user whose balance is being changed.
     * @param _amount The amount to change the balance by.
     */
    function _changeProxyAccounting(
        function (address,uint256) internal _changeProxyBalance,
        address _user,
        uint256 _amount
    )
        internal
    {
        forwardVault.setProxyBenefactor(
            _user
        );

        forwardVault.triggerAssignInterest(
            _user
        );

        _changeProxyBalance(
            _user,
            _amount
        );
    }

    /**
     * @dev Validates that a member can reduce their queue amount.
     * Ensures the caller is the member, the member has a positive amount, and the reduction is valid.
     */
    function _validateMemberCanReduce(
        QueMember storage _member,
        uint256 _reduceBy
    )
        internal
        view
    {
        require(
            _member.member == msg.sender,
            NotMember()
        );

        require(
            _reduceBy < _member.amount,
            AmountTooHigh()
        );
    }

    /**
     * @dev Validates that a member can leave the queue.
     * Ensures the caller is the member and the member has a positive amount.
     */
    function _validateMemberCanLeave(
        QueMember storage _member
    )
        internal
        view
    {
        require(
            _member.member == msg.sender,
            NotMember()
        );
    }

    /**
     * @dev Updates the current order pointer if the leaving member is the current order.
     * Moves the current order pointer to the next member in the queue.
     */
    function _updateCurrentOrderIfNeeded(
        uint256 _queMemberId,
        int256 _incentive,
        QueMember storage _member
    )
        internal
    {
        if (_queMemberId == currentOrderIdByIncentive[_incentive]) {
            currentOrderIdByIncentive[_incentive] = _member.headPointer;
        }
    }

    /**
     * @dev Updates the linked list pointers when removing a member.
     * Connects the previous member's head pointer to the next member's tail pointer.
     */
    function _updateLinkedListPointers(
        uint256 _queMemberId,
        QueMember storage _member,
        int256 _incentive
    )
        internal
    {
        if (_queMemberId == currentOrderIdByIncentive[_incentive]) {
            QueMemberByIdAndIncentive[_member.headPointer][_incentive].tailPointer = _member.headPointer;
            return;
        }

        QueMemberByIdAndIncentive[_member.tailPointer][_incentive].headPointer = _member.headPointer;
        QueMemberByIdAndIncentive[_member.headPointer][_incentive].tailPointer = _member.tailPointer;
    }

    /**
     * @dev Transfers vault tokens from this contract to the specified _to address.
     * Uses SafeERC20 for secure token transfers.
     */
    function _transferTokensOut(
        address _to,
        uint256 _amount
    )
        internal
    {
        IERC20(address(forwardVault)).safeTransfer(
            _to,
            _amount
        );
    }

    /**
     * @dev Re-usable incentive check.
     */
    function _requireIncentiveAllowed(
        int256 _incentive
    )
        internal
        view
    {
        require(
            incentiveAllowed[_incentive],
            IncentiveNotAllowed()
        );
    }

    /**
     * @dev Shared min-deposit guard.
     */
    function _requireMinDeposit(
        uint256 _amount
    )
        internal
        view
    {
        require(
            _amount >= minDepositAmount,
            AmountTooLow()
        );
    }

    /**
     * @dev Shared ID-range guard.
     */
    function _requireValidMemberId(
        uint256 _id,
        int256 _incentive
    )
        internal
        view
    {
        require(
            _id < earliestValidQueMemberByIncentive[_incentive],
            QueMemberIdTooHigh()
        );
    }

    /**
     * @dev Validates order processing parameters.
     * Ensures the order is ready to be processed and the incentive is allowed.
     */
    function _validateOrderProcessing(
        uint256 _queMemberId,
        int256 _incentive,
        uint256 _amount,
        bool _isFullFulfill
    )
        internal
        view
    {
        _requireValidMemberId(
            _queMemberId,
            _incentive
        );

        if (!_isFullFulfill) {
            require(
                _amount > 0,
                ZeroAmount()
            );

            require(
                _amount < QueMemberByIdAndIncentive[_queMemberId][_incentive].amount,
                AmountTooHigh()
            );
        }

        _requireIncentiveAllowed(
            _incentive
        );

        require(
            currentOrderIdByIncentive[_incentive] == _queMemberId,
            OrderNotReady()
        );
    }

    /**
     * @dev Executes the token transfers for order fulfillment.
     * Transfers discounted USD tokens to the member and vault tokens to the fulfiller.
     */
    function _executeTransfers(
        address _cashedMember,
        uint256 _amount,
        uint256 _discountedAmount
    )
        internal
    {
        usdToken.safeTransferFrom(
            msg.sender,
            _cashedMember,
            _discountedAmount
        );

        _transferTokensOut(
            msg.sender,
            _amount
        );
    }

    /**
     * @dev Initializes an array containing negative incentives in ascending order.
     */
    function _initializeNegativeIncentivesArray()
        internal
        pure
        returns (int16[8] memory)
    {
        return [
            int16(-100),  int16(-200),  int16(-300),  int16(-500),
            int16(-1000), int16(-1500), int16(-2500), int16(-5000)
        ];
    }

    /**
     * @dev Initializes an array containing all allowed incentives in descending order.
     * Returns a fixed-size array with all positive and negative incentive values.
     */
    function _initializeAllIncentivesArray()
        internal
        pure
        returns (int256[] memory)
    {
        int256[] memory allIncentives = new int256[](17);

        allIncentives[0] = 5000;
        allIncentives[1] = 2500;
        allIncentives[2] = 1500;
        allIncentives[3] = 1000;
        allIncentives[4] = 500;
        allIncentives[5] = 300;
        allIncentives[6] = 200;
        allIncentives[7] = 100;
        allIncentives[8] = 0;
        allIncentives[9] = -100;
        allIncentives[10] = -200;
        allIncentives[11] = -300;
        allIncentives[12] = -500;
        allIncentives[13] = -1000;
        allIncentives[14] = -1500;
        allIncentives[15] = -2500;
        allIncentives[16] = -5000;

        return allIncentives;
    }

    /**
     * @dev Initializes an array containing only positive incentives in descending order.
     * Returns a fixed-size array with positive incentive values for cost calculations.
     */
    function _initializePositiveIncentivesArray()
        internal
        pure
        returns (int16[9] memory)
    {
        return [
            int16(5000), int16(2500), int16(1500), int16(1000),
            int16(500), int16(300), int16(200), int16(100), int16(0)
        ];
    }

    /**
     * @dev Calculates the discount factor for a given incentive.
     * Applies the incentive as a percentage to the precision rate.
     * Returns the factor used for discount calculations.
     */
    function _calculateDiscountFactor(
        int256 _incentive
    )
        internal
        pure
        returns (uint256)
    {
        return _incentive >= 0
            ? PRECISION_RATE - uint256(_incentive)
            : PRECISION_RATE + uint256(-_incentive);
    }

    /**
     * @dev Checks if a queue entry is empty (has zero amount).
     * Returns true if the entry has no amount, false otherwise.
     */
    function _isEmptyOrder(
        QueMember storage _entry
    )
        internal
        view
        returns (bool)
    {
        return _entry.amount == 0;
    }

    /**
     * @dev Moves to the next order in the queue.
     * Updates the current order pointer and returns the new current and next IDs.
     */
    function _moveToNextOrder(
        QueMember storage _entry,
        int256 _incentive
    )
        internal
        view
        returns (
            uint256 newCurrent,
            uint256 newNextId
        )
    {
        newCurrent = _entry.headPointer;
        if (newCurrent == 0 || newCurrent >= earliestValidQueMemberByIncentive[_incentive]) {
            newNextId = earliestValidQueMemberByIncentive[_incentive];
            newCurrent = earliestValidQueMemberByIncentive[_incentive];
        } else {
            newNextId = newCurrent;
        }
    }

    /**
     * @dev Determines if plan traversal should continue based on remaining amount and limits.
     * Checks if there's still amount to process, orders to consider, and if limits are respected.
     */
    function _shouldContinuePlanTraversal(
        uint256 _amountLeft,
        PlanVars memory _v,
        int256 _incentive,
        uint256 _maxOrdersToConsider,
        uint256 _considerationLimit
    )
        internal
        view
        returns (bool)
    {
        return _amountLeft > 0 &&
            _v.current < earliestValidQueMemberByIncentive[_incentive] &&
            _v.fullIndex < _v.arraySize &&
            (_maxOrdersToConsider == 0 || _v.ordersConsidered < _considerationLimit);
    }

    /**
     * @dev Builds the final order arrays from temporary storage.
     * Creates properly sized arrays for full orders and partial orders.
     * Returns the final arrays ready for processing.
     */
    function _buildFinalOrderArrays(
        PlanVars memory _v,
        uint256[] memory _tempFull
    )
        internal
        pure
        returns (
            uint256[] memory fullOrderIds,
            uint256[] memory partialOrderIds
        )
    {
        fullOrderIds = new uint256[](_v.fullIndex);

        for (uint256 i; i < _v.fullIndex; i++) {
            fullOrderIds[i] = _tempFull[i];
        }

        if (_v.hasPartial) {
            partialOrderIds = new uint256[](1);
            partialOrderIds[0] = _v.partialId;
        } else {
            partialOrderIds = new uint256[](0);
        }
    }

    /**
     * @dev Initializes plan variables based on active count and maximum orders to consider.
     * Sets the array size for temporary storage based on the provided limits.
     */
    function _initializePlanVars(
        uint256 _activeCount,
        uint256 _maxOrdersToConsider
    )
        internal
        pure
        returns (
            PlanVars memory v
        )
    {
        if (_maxOrdersToConsider == 0) {
            v.arraySize = _activeCount;
        } else {
            v.arraySize = _activeCount < _maxOrdersToConsider
                ? _activeCount
                : _maxOrdersToConsider;
        }
    }

    /**
     * @dev Initializes solve variables for amount solving operations.
     * Sets up arrays for incentives, orders, and partials with appropriate sizes.
     */
    function _initializeSolveVars()
        internal
        view
        returns (
            SolveForAmountVars memory v
        )
    {
        v.incs = _initializePositiveIncentivesArray();
        v.tempIncentives = new int256[](totalActiveOrders);
        v.tempOrders = new uint256[](totalActiveOrders);
        v.tempPartials = new uint256[](totalActiveOrders);
    }

    /**
     * @dev Processes full orders for a specific incentive during amount solving.
     * Populates temporary arrays with order information and updates remaining amount.
     * Returns the new remaining amount after processing full orders.
     */
    function _processFullOrdersForIncentive(
        SolveForAmountVars memory _v,
        uint256[] memory _fullIds,
        int256 _incentive,
        uint256 _remainingAmount
    )
        internal
        view
        returns (
            uint256 newRemainingAmount
        )
    {
        newRemainingAmount = _remainingAmount;

        for (uint256 j; j < _fullIds.length; j++) {
            if (newRemainingAmount == 0) {
                break;
            }

            uint256 id = _fullIds[j];
            uint256 amt = QueMemberByIdAndIncentive[id][_incentive].amount;

            if (amt == 0 || amt > newRemainingAmount) {
                continue;
            }

            _v.tempIncentives[_v.orderIndex] = _incentive;
            _v.tempOrders[_v.orderIndex] = id;
            _v.orderIndex++;
            newRemainingAmount -= amt;
        }
    }

    /**
     * @dev Processes partial orders for a specific incentive during amount solving.
     * Adds partial order information to temporary arrays for later processing.
     */
    function _processPartialOrderForIncentive(
        SolveForAmountVars memory _v,
        uint256[] memory _partialIds,
        int256 _incentive
    )
        internal
        pure
    {
        if (_partialIds.length != 0) {
            _v.tempPartials[_v.partialIndex] = _partialIds[0];
            _v.tempIncentives[_v.orderIndex + _v.partialIndex] = _incentive;
            _v.partialIndex++;
        }
    }

    /**
     * @dev Builds the final solve results from temporary arrays.
     * Creates properly sized arrays for incentives, orders, and partials.
     * Returns the final arrays ready for order fulfillment.
     */
    function _buildSolveResults(
        SolveForAmountVars memory _v
    )
        internal
        pure
        returns (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory partials
        )
    {
        incentives = new int256[](_v.orderIndex + _v.partialIndex);
        orders = new uint256[](_v.orderIndex);
        partials = new uint256[](_v.partialIndex);

        for (uint256 k; k < _v.orderIndex; k++) {
            incentives[k] = _v.tempIncentives[k];
            orders[k] = _v.tempOrders[k];
        }

        for (uint256 l; l < _v.partialIndex; l++) {
            incentives[_v.orderIndex + l] = _v.tempIncentives[_v.orderIndex + l];
            partials[l] = _v.tempPartials[l];
        }
    }

    /**
     * @dev Collects orders for a specific incentive and user.
     * Filters orders based on user address and active status.
     * Returns the new index after collecting orders.
     */
    function _collectOrdersForIncentive(
        int256 _currentIncentive,
        address _user,
        bool _checkUser,
        QueMember[] memory _tempOrders,
        int256[] memory _tempIncentives,
        uint256 _currentIndex
    )
        internal
        view
        returns (
            uint256 newIndex
        )
    {
        newIndex = _currentIndex;
        uint256 maxIdForIncentive = earliestValidQueMemberByIncentive[_currentIncentive];

        for (uint256 id = 0; id < maxIdForIncentive; id++) {
            QueMember storage member = QueMemberByIdAndIncentive[id][_currentIncentive];

            if (_shouldIncludeOrder(member, _user, _checkUser)) {
                _tempOrders[newIndex] = member;
                _tempIncentives[newIndex] = _currentIncentive;
                newIndex++;
            }
        }
    }

    /**
     * @dev Determines if an order should be included in collection results.
     * Checks user address and active status based on the checkUser flag.
     */
    function _shouldIncludeOrder(
        QueMember storage _member,
        address _user,
        bool _checkUser
    )
        internal
        view
        returns (bool)
    {
        return _checkUser
            ? (_member.member == _user && _member.amount > 0)
            : (_member.member != ZERO_ADDRESS && _member.amount > 0);
    }

    /**
     * @dev Copies temporary arrays to final arrays with actual length.
     * Creates properly sized arrays and copies data from temporary storage.
     */
    function _copyToFinalArrays(
        QueMember[] memory _tempOrders,
        int256[] memory _tempIncentives,
        uint256 _actualLength
    )
        internal
        pure
        returns (
            QueMember[] memory actualOrders,
            int256[] memory actualIncentives
        )
    {
        actualOrders = new QueMember[](_actualLength);
        actualIncentives = new int256[](_actualLength);

        for (uint256 j = 0; j < _actualLength; j++) {
            actualOrders[j] = _tempOrders[j];
            actualIncentives[j] = _tempIncentives[j];
        }
    }

    /**
     * @dev Collects all orders across all incentives for a specific user or all users.
     * Uses the checkUser flag to determine if filtering by user address is needed.
     */
    function _collectAllOrders(
        address _user,
        bool _checkUser
    )
        internal
        view
        returns (
            QueMember[] memory,
            int256[] memory
        )
    {
        int256[] memory allIncentives = _initializeAllIncentivesArray();
        QueMember[] memory tempOrders = new QueMember[](totalActiveOrders);
        int256[] memory tempIncentives = new int256[](totalActiveOrders);
        uint256 index = 0;

        for (uint256 i = 0; i < allIncentives.length; i++) {
            index = _collectOrdersForIncentive(
                allIncentives[i],
                _user,
                _checkUser,
                tempOrders,
                tempIncentives,
                index
            );
        }

        return _copyToFinalArrays(
            tempOrders,
            tempIncentives,
            index
        );
    }

    /**
     * @dev Calculates the total cost and tokens planned for full orders.
     * Sums up the discounted amounts and total tokens across all orders.
     */
    function _calculateFullOrdersCost(
        uint256[] memory _orders,
        int256[] memory _incentives
    )
        internal
        view
        returns (
            uint256 costInUsd,
            uint256 totalTokensPlanned
        )
    {
        for (uint256 i = 0; i < _orders.length; i++) {
            uint256 orderId = _orders[i];
            int256 incentive = _incentives[i];
            uint256 orderAmount = QueMemberByIdAndIncentive[orderId][incentive].amount;

            costInUsd += _predictDiscountedAmount(
                orderAmount,
                incentive
            );

            totalTokensPlanned += orderAmount;
        }
    }

    /**
     * @dev Predicts the discounted amount for a given base amount and incentive.
     * Applies the incentive factor to calculate the final discounted amount.
     */
    function _predictDiscountedAmount(
        uint256 _amount,
        int256 _incentive
    )
        internal
        pure
        returns (uint256)
    {
        uint256 factor = _calculateDiscountFactor(
            _incentive
        );

        return Math.mulDiv(
            _amount,
            factor,
            PRECISION_RATE
        );
    }

    /**
     * @dev Calculates the cost and tokens for partial orders.
     * Determines the remaining tokens needed and calculates the partial cost.
     */
    function _calculatePartialOrderCost(
        uint256[] memory _partials,
        int256[] memory _incentives,
        uint256 _ordersLength,
        uint256 _tokensToReceive,
        uint256 _totalTokensPlanned
    )
        internal
        pure
        returns (
            uint256 partialCost,
            uint256 partialTokens
        )
    {
        if (_partials.length > 0) {
            int256 partialIncentive = _incentives[_ordersLength];
            partialTokens = _tokensToReceive - _totalTokensPlanned;
            partialCost = _predictDiscountedAmount(
                partialTokens,
                partialIncentive
            );
        }
    }

    /**
     * @dev Processes an order for cost calculation.
     * Determines how many tokens can be acquired and how much USD will be spent.
     */
    function _processOrderForCost(
        QueMember storage _entry,
        int256 _incentive,
        uint256 _remainingUsd
    )
        internal
        view
        returns (
            uint256 tokensAcquired,
            uint256 usdSpent
        )
    {
        uint256 orderCost = _predictDiscountedAmount(
            _entry.amount,
            _incentive
        );

        if (_remainingUsd >= orderCost) {
            tokensAcquired = _entry.amount;
            usdSpent = orderCost;
        } else {
            uint256 factor = _calculateDiscountFactor(
                _incentive
            );

            tokensAcquired = Math.mulDiv(
                _remainingUsd,
                PRECISION_RATE,
                factor
            );

            usdSpent = _remainingUsd;
        }
    }

    /**
     * @dev Zero-outs an order after it leaves the book (leave or full-fill)
     * and always un-links it from the doubly-linked list so that
     * no live neighbour ever keeps a pointer to an empty "hole".
     *
     * - `_handleAccounting == true`  →  update proxy balances as well
     * - `_handleAccounting == false` →  proxy accounting was already
     *                                   handled earlier in the call
     *
     * Keeping the DLL tight guarantees that every iteration over
     * `headPointer`/`tailPointer` only visits live nodes, satisfying the
     * `invariant_linkedListsHealthy` check.
     */
    function _finalizeMemberRemoval(
        uint256 _queMemberId,
        QueMember storage _member,
        int256  _incentive,
        bool    _handleAccounting
    )
        internal
    {
        if (_handleAccounting) {
            _changeProxyAccounting(
                _decreaseProxyBalance,
                _member.member,
                _member.amount
            );
        }

        _updateLinkedListPointers(
            _queMemberId,
            _member,
            _incentive
        );

        delete QueMemberByIdAndIncentive[_queMemberId][_incentive];

        totalActiveOrders--;
        activeOrderCountByIncentive[_incentive]--;
    }
}
