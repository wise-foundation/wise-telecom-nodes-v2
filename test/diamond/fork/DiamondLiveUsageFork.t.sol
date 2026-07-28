// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct QueMemberRet {
    address member;
    uint256 amount;
    uint256 tailPointer;
    uint256 headPointer;
}

/**
 * @dev Minimal local surface of the LIVE migrated WiseTelecomNodes
 * diamond, driven through its own fallback router exactly as a real
 * integration would. Declared here so the test never depends on the
 * diamond's internal facet types.
 */
interface IWtnVault {

    function deposit(
        uint256 amount
    )
        external;

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

    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function USD_TOKEN() external view returns (address);
    function minDepositAmount() external view returns (uint256);
    function depositsDisabled() external view returns (bool);
    function paused() external view returns (bool);
    function activeOrderCountByIncentive(int256 incentive) external view returns (uint256);
    function currentOrderIdByIncentive(int256 incentive) external view returns (uint256);

    function QueMemberByIdAndIncentive(
        uint256 id,
        int256 incentive
    )
        external
        view
        returns (
            address member,
            uint256 amount,
            uint256 tailPointer,
            uint256 headPointer
        );
}

/**
 * @title DiamondLiveUsageForkBase
 * @dev Forks a LIVE, already-migrated + activated WiseTelecomNodes
 * diamond and proves two real end-user flows against the deployed
 * bytecode:
 *   1. a fresh user can DEPOSIT (approve the diamond, deposit USD,
 *      receive shares 1:1, USD leaves the depositor, supply rises), and
 *   2. a REAL existing queue member (impersonated, discovered live from
 *      the queue head) can LEAVE their order and REJOIN it.
 *
 * The queue moves need no token approval — they shuffle the caller's own
 * shares between their wallet and the diamond's escrow — while the
 * deposit does (USD.safeTransferFrom pulls from the depositor). USDT
 * legs return no data from `approve`, so the approval is issued with a
 * low-level call that tolerates both USDC and USDT.
 */
abstract contract DiamondLiveUsageForkBase is Test {

    IWtnVault internal v;
    IERC20 internal usd;

    struct Cfg {
        string rpc;
        address diamond;
    }

    function _config()
        internal
        pure
        virtual
        returns (Cfg memory);

    function setUp()
        public
    {
        Cfg memory cfg = _config();

        vm.createSelectFork(
            cfg.rpc
        );

        require(
            cfg.diamond.code.length > 0,
            "diamond not deployed on this fork"
        );

        v = IWtnVault(
            cfg.diamond
        );

        usd = IERC20(
            v.USD_TOKEN()
        );
    }

    function _diamond()
        internal
        view
        returns (address)
    {
        return address(v);
    }

    /**
     * @dev Approve the diamond to pull `_amount` USD from `_from`. USDT's
     * `approve` returns no data, so a bool-returning interface call would
     * revert on the decode; a low-level call that ignores the return
     * works for both USDC and USDT.
     */
    function _approveUsd(
        address _from,
        uint256 _amount
    )
        internal
    {
        vm.prank(
            _from
        );

        (
            bool ok,
        ) = address(usd).call(
            abi.encodeWithSignature(
                "approve(address,uint256)",
                _diamond(),
                _amount
            )
        );

        require(
            ok,
            "usd approve failed"
        );
    }

    // ---- test 1: deposit works on a live active vault ----

    function test_liveVault_depositWorks()
        public
    {
        require(
            v.depositsDisabled() == false,
            "vault is dormant - deposits disabled"
        );

        require(
            v.paused() == false,
            "vault is paused"
        );

        uint256 amount = 1_000_000_000;

        if (amount < v.minDepositAmount()) {
            amount = v.minDepositAmount();
        }

        address user = makeAddr(
            "liveDepositor"
        );

        deal(
            address(usd),
            user,
            amount
        );

        uint256 usdBefore = usd.balanceOf(
            user
        );

        uint256 sharesBefore = v.balanceOf(
            user
        );

        uint256 supplyBefore = v.totalSupply();

        _approveUsd(
            user,
            amount
        );

        vm.prank(
            user
        );

        v.deposit(
            amount
        );

        assertEq(
            usd.balanceOf(user),
            usdBefore - amount,
            "USD not pulled from the depositor"
        );

        assertEq(
            v.balanceOf(user),
            sharesBefore + amount,
            "shares not minted 1:1 on deposit"
        );

        assertEq(
            v.totalSupply(),
            supplyBefore + amount,
            "total supply did not rise by the deposit"
        );
    }

    // ---- test 2: a real queue member can leave and rejoin ----

    function test_liveVault_realQueMemberLeavesAndRejoins()
        public
    {
        (
            int256 inc,
            uint256 memberId,
            address member,
            uint256 amount
        ) = _findActiveHead();

        require(
            member != address(0),
            "no active queue order on this live vault to exercise"
        );

        uint256 balBefore = v.balanceOf(
            member
        );

        uint256 ordersBefore = v.activeOrderCountByIncentive(
            inc
        );

        vm.prank(
            member
        );

        (
            ,
            uint256 leftOver
        ) = v.leaveQue(
            memberId,
            inc
        );

        assertEq(
            leftOver,
            amount,
            "leaveQue returned the wrong escrowed amount"
        );

        assertEq(
            v.balanceOf(member),
            balBefore + amount,
            "escrowed shares not returned to the member on leave"
        );

        assertEq(
            v.activeOrderCountByIncentive(inc),
            ordersBefore - 1,
            "active order count did not fall on leave"
        );

        vm.prank(
            member
        );

        (
            ,
            uint256 newId
        ) = v.joinQue(
            amount,
            inc
        );

        assertGt(
            newId,
            0,
            "rejoin produced no new order id"
        );

        assertEq(
            v.balanceOf(member),
            balBefore,
            "shares not re-escrowed on rejoin"
        );

        assertEq(
            v.activeOrderCountByIncentive(inc),
            ordersBefore,
            "active order count did not return on rejoin"
        );
    }

    /**
     * @dev Scans the standard incentive tiers for the first with an
     * active order and returns its live head: the head order id equals
     * `currentOrderIdByIncentive`, and its member/amount come from the
     * public `QueMemberByIdAndIncentive` slot.
     */
    function _findActiveHead()
        internal
        view
        returns (
            int256 inc,
            uint256 memberId,
            address member,
            uint256 amount
        )
    {
        int256[17] memory incs = [
            int256(0), int256(100), int256(200), int256(300), int256(500),
            int256(1000), int256(1500), int256(2500), int256(5000),
            int256(-100), int256(-200), int256(-300), int256(-500),
            int256(-1000), int256(-1500), int256(-2500), int256(-5000)
        ];

        for (uint256 i; i < incs.length; ++i) {

            if (v.activeOrderCountByIncentive(incs[i]) == 0) {
                continue;
            }

            uint256 id = v.currentOrderIdByIncentive(
                incs[i]
            );

            (
                address m,
                uint256 amt,
                ,
            ) = v.QueMemberByIdAndIncentive(
                id,
                incs[i]
            );

            if (m != address(0) && amt > 0) {
                return (incs[i], id, m, amt);
            }
        }

        return (int256(0), 0, address(0), 0);
    }
}

contract DiamondLiveArbUsdcFork is DiamondLiveUsageForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "arbitrum",
            diamond: 0x7e1EFF4301defc24936470B30bd1c686D2a295dc
        });
    }
}

contract DiamondLiveEthUsdtFork is DiamondLiveUsageForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "mainnet",
            diamond: 0x7e1EBE1D25367C6D3bC0aA72A1f00fC5320a05d7
        });
    }
}
