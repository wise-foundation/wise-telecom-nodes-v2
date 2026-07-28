// SPDX-License-Identifier: -- WISE --
// @author: René Hochmuth

pragma solidity =0.8.29;

import "../OwnableMasterLegacy.sol";
import "../IForwardVaultERC20Legacy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title QueContractDeclarations
 * @dev Declaration contract containing all state variables, events, and error definitions for the queue system.
 *
 * This contract defines:
 * - All state variables for queue management
 * - Events for tracking queue operations
 * - Custom errors for gas-efficient reverts
 * - Data structures for queue members and planning
 * - Mappings for order tracking and incentive management
 *
 * The contract serves as the foundation for:
 * - Queue member creation and management
 * - Order tracking across multiple incentive levels
 * - Doubly-linked list implementation for efficient traversal
 * - Bulk order processing and optimization
 *
 * @notice This contract inherits from OwnableMaster and ReentrancyGuard to provide
 * the necessary security and access control for the queue system.
 */
contract QueContractDeclarations is OwnableMaster, ReentrancyGuard {

    error ZeroAmount();
    error NotMember();
    error MemberAlreadyLeft();
    error IncentiveMismatch();
    error QueMemberIdTooHigh();
    error OrderNotReady();
    error AmountTooHigh();
    error IncentiveNotAllowed();
    error AmountTooLow();
    error NotProxyBenefactor();
    error AmountReceivedTooLow();
    error AmountSpentTooHigh();
    error NoOrdersPresent();
    error NegativeIncentiveNotAllowed();

    event JoinQue(
        address indexed member,
        uint256 amount,
        int256 incentive,
        uint256 queMemberId
    );

    event LeaveQue(
        address indexed member,
        uint256 queMemberId,
        int256 incentive,
        uint256 amount
    );

    event ReduceQueAmount(
        address indexed member,
        uint256 queMemberId,
        int256 incentive,
        uint256 reduceBy
    );

    event OrderProcessed(
        address indexed fulfiller,
        address indexed member,
        uint256 queMemberId,
        int256 incentive,
        uint256 amount,
        bool isFullFulfill
    );

    struct QueMember {
        address member;
        uint256 amount;
        uint256 tailPointer;
        uint256 headPointer;
    }

    struct SolveForAmountVars {
        int16[9] incs;
        int256[] tempIncentives;
        uint256[] tempOrders;
        uint256[] tempPartials;
        uint256 orderIndex;
        uint256 partialIndex;
    }

    struct PlanVars {
        uint256 arraySize;
        uint256 partialId;
        uint256 fullIndex;
        uint256 current;
        uint256 ordersConsidered;
        bool hasPartial;
    }

    struct FulfillOrderBulkVars {
        int256[] incentives;
        uint256[] orders;
        uint256[] partials;
        uint256 partialAmount;
        uint256 minReceiveAmount;
        uint256 maxUsdToSpend;
    }

    mapping(uint256 => mapping(int256 => QueMember)) public QueMemberByIdAndIncentive;

    mapping(int256 => uint256) public earliestValidQueMemberByIncentive;

    mapping(int256 => uint256) public currentOrderIdByIncentive;

    mapping(int256 => bool) public incentiveAllowed;

    mapping(int256 => uint256) public activeOrderCountByIncentive;

    uint256 public totalActiveOrders;

    uint256 constant PRECISION_RATE = 10_000;

    uint256 constant MAX_ORDERS_TO_CONSIDER_LIMIT = 100;

    uint256 public minDepositAmount;

    IForwardVaultERC20 public immutable forwardVault;

    IERC20 public immutable usdToken;

    bool public negativeIncentivesNotAllowed;

    bytes4 public constant IERC20Decimals = bytes4(
        keccak256("decimals()")
    );

    constructor(
        address _forwardVault
    )
        OwnableMaster(
            msg.sender
        )
    {
        _initializeIncentives();

        forwardVault = IForwardVaultERC20(
            _forwardVault
        );

        usdToken = IERC20(
            forwardVault.USD_TOKEN()
        );

        (
            bool success,
            bytes memory data
        ) = address(usdToken).staticcall(
            abi.encodeWithSelector(
                IERC20Decimals
            )
        );

        require(
            success,
            "Failed to get decimals"
        );

        minDepositAmount = 50 * 10 ** abi.decode(
            data,
            (uint8)
        );
    }

    function _initializeIncentives()
        internal
    {
        int256[] memory allowed = new int256[](17);
        allowed[0] = 0;
        allowed[1] = 100;
        allowed[2] = 200;
        allowed[3] = 300;
        allowed[4] = 500;
        allowed[5] = 1000;
        allowed[6] = 1500;
        allowed[7] = 2500;
        allowed[8] = 5000;
        allowed[9] = -100;
        allowed[10] = -200;
        allowed[11] = -300;
        allowed[12] = -500;
        allowed[13] = -1000;
        allowed[14] = -1500;
        allowed[15] = -2500;
        allowed[16] = -5000;

        for (uint256 i = 0; i < allowed.length; i++) {
            incentiveAllowed[allowed[i]] = true;
        }
    }
}
