// SPDX-License-Identifier: -- WISE --
// @author: René Hochmuth

pragma solidity =0.8.29;

import {QueContract} from "../legacy/que/QueContractLegacy.sol";

/**
 * @title QueContractMigratable
 * @dev Thin extension of legacy QueContract that exposes master-only setters
 * for the queue state (member slots, linked-list pointers, per-incentive
 * counters, globals). Used at Phase-2 migration time to replicate the
 * deployed QueContract's storage onto a freshly deployed instance.
 *
 * The legacy contract is never modified. This inheritor only adds new
 * external functions; existing storage layout is preserved.
 */
contract QueContractMigratable is QueContract {

    event QueMemberMigrated(
        uint256 indexed queMemberId,
        int256  indexed incentive,
        address indexed member,
        uint256 amount,
        uint256 tailPointer,
        uint256 headPointer
    );

    event PerIncentiveStateMigrated(
        int256 indexed incentive,
        uint256 earliestValid,
        uint256 currentOrderId,
        uint256 activeOrderCount
    );

    event GlobalStateMigrated(
        uint256 totalActiveOrders,
        uint256 minDepositAmount,
        bool    negativeIncentivesNotAllowed
    );

    constructor(
        address _forwardVault
    )
        QueContract(
            _forwardVault
        )
    {}

    /**
     * @dev Master-only writer for a single queue-member slot.
     * Replicates `QueMemberByIdAndIncentive[id][incentive]` from the deployed
     * contract bit-for-bit (live members AND the sentinel slot whose
     * `tailPointer` is set when a new member would join).
     */
    function setQueMember(
        uint256 _queMemberId,
        int256  _incentive,
        address _member,
        uint256 _amount,
        uint256 _tailPointer,
        uint256 _headPointer
    )
        external
        onlyMaster
    {
        QueMemberByIdAndIncentive[_queMemberId][_incentive] = QueMember({
            member:      _member,
            amount:      _amount,
            tailPointer: _tailPointer,
            headPointer: _headPointer
        });

        emit QueMemberMigrated(
            _queMemberId,
            _incentive,
            _member,
            _amount,
            _tailPointer,
            _headPointer
        );
    }

    /**
     * @dev Master-only setter for `earliestValidQueMemberByIncentive[incentive]`.
     */
    function setEarliestValidQueMemberByIncentive(
        int256  _incentive,
        uint256 _value
    )
        external
        onlyMaster
    {
        earliestValidQueMemberByIncentive[_incentive] = _value;
    }

    /**
     * @dev Master-only setter for `currentOrderIdByIncentive[incentive]`.
     */
    function setCurrentOrderIdByIncentive(
        int256  _incentive,
        uint256 _value
    )
        external
        onlyMaster
    {
        currentOrderIdByIncentive[_incentive] = _value;
    }

    /**
     * @dev Master-only setter for `activeOrderCountByIncentive[incentive]`.
     */
    function setActiveOrderCountByIncentive(
        int256  _incentive,
        uint256 _value
    )
        external
        onlyMaster
    {
        activeOrderCountByIncentive[_incentive] = _value;
    }

    /**
     * @dev Master-only setter for the global `totalActiveOrders` counter.
     */
    function setTotalActiveOrders(
        uint256 _value
    )
        external
        onlyMaster
    {
        totalActiveOrders = _value;
    }

    /**
     * @dev Master-only setter for `minDepositAmount`. Provided alongside the
     * legacy `changeMinDepositAmount` for naming consistency with the other
     * migration setters.
     */
    function setMinDepositAmount(
        uint256 _value
    )
        external
        onlyMaster
    {
        minDepositAmount = _value;
    }

    /**
     * @dev Master-only setter for `incentiveAllowed[incentive]`. Defensive in
     * case any non-default incentive was added or removed on the deployed
     * contract (the legacy constructor seeds 17 standard incentives).
     */
    function setIncentiveAllowed(
        int256 _incentive,
        bool   _allowed
    )
        external
        onlyMaster
    {
        incentiveAllowed[_incentive] = _allowed;
    }

    /**
     * @dev Master-only convenience to apply per-incentive counters and the
     * `incentiveAllowed` flag in a single call. Reduces tx count during
     * the migration broadcast.
     */
    function setPerIncentiveState(
        int256  _incentive,
        uint256 _earliestValid,
        uint256 _currentOrderId,
        uint256 _activeOrderCount,
        bool    _allowed
    )
        external
        onlyMaster
    {
        earliestValidQueMemberByIncentive[_incentive] = _earliestValid;
        currentOrderIdByIncentive[_incentive]         = _currentOrderId;
        activeOrderCountByIncentive[_incentive]       = _activeOrderCount;
        incentiveAllowed[_incentive]                  = _allowed;

        emit PerIncentiveStateMigrated(
            _incentive,
            _earliestValid,
            _currentOrderId,
            _activeOrderCount
        );
    }

    /**
     * @dev Master-only convenience to apply all global state in a single call.
     */
    function setGlobalState(
        uint256 _totalActiveOrders,
        uint256 _minDepositAmount,
        bool    _negativeIncentivesNotAllowed
    )
        external
        onlyMaster
    {
        totalActiveOrders            = _totalActiveOrders;
        minDepositAmount             = _minDepositAmount;
        negativeIncentivesNotAllowed = _negativeIncentivesNotAllowed;

        emit GlobalStateMigrated(
            _totalActiveOrders,
            _minDepositAmount,
            _negativeIncentivesNotAllowed
        );
    }
}
