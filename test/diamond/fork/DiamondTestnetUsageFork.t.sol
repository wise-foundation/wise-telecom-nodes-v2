// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

struct QueMemberRet {
    address member;
    uint256 amount;
    uint256 tailPointer;
    uint256 headPointer;
}

/**
 * @dev Minimal local surface of the deployed WiseTelecomNodes diamond
 * needed to drive the queue as an end user. Declared here so the test
 * calls the LIVE deployed bytecode through the diamond's own fallback
 * router, exactly as a real integration would.
 */
interface IWtnQueue {

    function joinQue(
        uint256 amount,
        int256 incentive
    )
        external
        returns (
            QueMemberRet memory,
            uint256 newId
        );

    function leaveQue(
        uint256 memberId,
        int256 incentive
    )
        external
        returns (
            QueMemberRet memory,
            uint256 leftOver
        );

    function fulfillOrder(
        uint256 memberId,
        int256 incentive
    )
        external
        returns (
            uint256 vaultTokens,
            uint256 usdSpent
        );

    function minDepositAmount() external view returns (uint256);
    function USD_TOKEN() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function paused() external view returns (bool);
    function activeOrderCountByIncentive(int256 incentive) external view returns (uint256);
    function currentOrderIdByIncentive(int256 incentive) external view returns (uint256);
    function earliestValidQueMemberByIncentive(int256 incentive) external view returns (uint256);
    function incentiveAllowed(int256 incentive) external view returns (bool);
    function predictDiscountedAmount(uint256 amount, int256 incentive) external view returns (uint256);
    function lastSyncTimeStamp(address user) external view returns (uint256);
}

/**
 * @title DiamondTestnetUsageForkBase
 * @dev Forks the LIVE testnet WiseTelecomNodes diamond (same canonical
 * CREATE3 address on Ethereum Sepolia and Arbitrum Sepolia) and proves
 * a real user can actually USE the queue: join, leave, and get an order
 * fulfilled. Shares are airdropped to genuine holder addresses from the
 * production snapshot and those users are impersonated with `vm.prank`,
 * so every call exercises the deployed bytecode end-to-end.
 */
abstract contract DiamondTestnetUsageForkBase is Test {

    using stdStorage for StdStorage;

    address internal constant DIAMOND = 0xb375bB64b068817030729B05bBda7eF25C0270Ab;

    // Real WiseTelecomNodes holder addresses (from the live USDC snapshot).
    address internal constant JOINER = 0x56b668F57624661BA9387bAb7D06c5F4698a9225;
    address internal constant FULFILLER = 0x4C333c8853F6B6766AF0EE357DdA74B2c7D06341;

    int256[9] internal POSITIVE_INCENTIVES = [
        int256(0), int256(100), int256(200), int256(300), int256(500),
        int256(1000), int256(1500), int256(2500), int256(5000)
    ];

    IWtnQueue internal q = IWtnQueue(DIAMOND);
    IERC20 internal usd;

    function _rpcUrl()
        internal
        view
        virtual
        returns (string memory);

    function setUp()
        public
    {
        vm.createSelectFork(
            _rpcUrl()
        );

        require(
            DIAMOND.code.length > 0,
            "diamond not deployed on this fork"
        );

        require(
            q.paused() == false,
            "diamond is paused"
        );

        usd = IERC20(
            q.USD_TOKEN()
        );
    }

    /**
     * @dev Airdrops vault shares to a real user and stamps their
     * interest clock to now so no phantom interest accrues from a zero
     * `lastSyncTimeStamp` on first interaction.
     */
    function _airdropShares(
        address _user,
        uint256 _amount
    )
        internal
    {
        deal(
            DIAMOND,
            _user,
            _amount
        );

        stdstore
            .target(DIAMOND)
            .sig("lastSyncTimeStamp(address)")
            .with_key(_user)
            .checked_write(block.timestamp);
    }

    /**
     * @dev First allowed positive incentive whose queue is empty at the
     * head (currentOrderId == earliestValid), so a freshly joined order
     * becomes the head and is immediately fulfillable.
     */
    function _emptyHeadIncentive()
        internal
        view
        returns (int256)
    {
        for (uint256 i; i < POSITIVE_INCENTIVES.length; ++i) {

            int256 inc = POSITIVE_INCENTIVES[i];

            bool empty = q.incentiveAllowed(inc)
                && q.activeOrderCountByIncentive(inc) == 0
                && q.currentOrderIdByIncentive(inc) == q.earliestValidQueMemberByIncentive(inc);

            if (empty) {
                return inc;
            }
        }

        revert("no empty allowed incentive on this diamond");
    }

    function _joinAmount()
        internal
        view
        returns (uint256 amount)
    {
        amount = q.minDepositAmount();

        if (amount == 0) {
            amount = 1_000_000;
        }
    }

    function test_realUser_canJoinAndLeaveQue()
        public
    {
        int256 inc = _emptyHeadIncentive();
        uint256 amount = _joinAmount();

        _airdropShares(
            JOINER,
            amount
        );

        uint256 balBefore = q.balanceOf(JOINER);
        uint256 ordersBefore = q.activeOrderCountByIncentive(inc);

        vm.prank(JOINER);
        (
            ,
            uint256 memberId
        ) = q.joinQue(
            amount,
            inc
        );

        assertEq(
            q.balanceOf(JOINER),
            balBefore - amount,
            "shares not escrowed on join"
        );

        assertEq(
            q.activeOrderCountByIncentive(inc),
            ordersBefore + 1,
            "active order count did not rise on join"
        );

        vm.prank(JOINER);
        (
            ,
            uint256 leftOver
        ) = q.leaveQue(
            memberId,
            inc
        );

        assertEq(
            leftOver,
            amount,
            "leaveQue returned the wrong amount"
        );

        assertEq(
            q.balanceOf(JOINER),
            balBefore,
            "shares not returned to user on leave"
        );

        assertEq(
            q.activeOrderCountByIncentive(inc),
            ordersBefore,
            "active order count did not fall on leave"
        );
    }

    function test_realUser_canFulfillOrder()
        public
    {
        int256 inc = _emptyHeadIncentive();
        uint256 amount = _joinAmount();

        _airdropShares(
            JOINER,
            amount
        );

        vm.prank(JOINER);
        (
            ,
            uint256 memberId
        ) = q.joinQue(
            amount,
            inc
        );

        assertEq(
            q.currentOrderIdByIncentive(inc),
            memberId,
            "joined order is not the fulfillable head"
        );

        uint256 usdCost = q.predictDiscountedAmount(
            amount,
            inc
        );

        if (usdCost == 0) {
            usdCost = amount;
        }

        deal(
            address(usd),
            FULFILLER,
            usdCost
        );

        uint256 joinerUsdBefore = usd.balanceOf(JOINER);
        uint256 fulfillerSharesBefore = q.balanceOf(FULFILLER);

        vm.startPrank(FULFILLER);
        usd.approve(
            DIAMOND,
            usdCost
        );

        (
            uint256 vaultTokens,
            uint256 usdSpent
        ) = q.fulfillOrder(
            memberId,
            inc
        );
        vm.stopPrank();

        assertEq(
            vaultTokens,
            amount,
            "fulfiller did not receive the full escrowed share amount"
        );

        assertEq(
            q.balanceOf(FULFILLER),
            fulfillerSharesBefore + amount,
            "fulfiller shares not credited"
        );

        assertEq(
            usd.balanceOf(JOINER),
            joinerUsdBefore + usdSpent,
            "queue member did not receive the USD payment"
        );

        assertEq(
            q.activeOrderCountByIncentive(inc),
            0,
            "order not removed after full fulfillment"
        );
    }
}

contract DiamondArbitrumSepoliaUsageFork is DiamondTestnetUsageForkBase {

    function _rpcUrl()
        internal
        pure
        override
        returns (string memory)
    {
        return "https://sepolia-rollup.arbitrum.io/rpc";
    }
}

contract DiamondSepoliaUsageFork is DiamondTestnetUsageForkBase {

    function _rpcUrl()
        internal
        pure
        override
        returns (string memory)
    {
        return "https://ethereum-sepolia-rpc.publicnode.com";
    }
}
