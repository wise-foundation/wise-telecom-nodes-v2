// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ReferralTokenDemo} from "./ReferralTokenDemo.sol";
import {
    RecordingTransferHookDemo,
    FreezeTransferHookDemo
} from "./ReferralTokenHookDemos.sol";

/**
 * @dev Tests for the transfer-hook miniature: hook runs BEFORE the
 * balance move on both `transfer` and `transferFrom`, receives only
 * the two addresses (amount structurally unobservable), is swappable
 * at runtime including back to the no-hook default, bubbles hook
 * reverts verbatim, rejects direct facet entry via the transient
 * guard, and never runs on mint — all mirroring the live diamond.
 */
contract ReferralTokenDemoTest is Test {

    uint256 internal constant START_BALANCE = 1_000 * 1e6;

    ReferralTokenDemo internal token;

    RecordingTransferHookDemo internal recorder;

    FreezeTransferHookDemo internal freezer;

    event TransferHookRan(
        address indexed from,
        address indexed to,
        uint256 fromBalanceBefore,
        uint256 toBalanceBefore
    );

    bytes32 internal constant HOOK_RAN_TOPIC = keccak256(
        "TransferHookRan(address,address,uint256,uint256)"
    );

    function setUp()
        public
    {
        token = new ReferralTokenDemo();
        recorder = new RecordingTransferHookDemo();
        freezer = new FreezeTransferHookDemo();

        token.mint(
            address(0xA1),
            START_BALANCE
        );
    }

    function test_transfer_noHook_movesTokens()
        public
    {
        vm.prank(
            address(0xA1)
        );

        token.transfer(
            address(0xA2),
            400 * 1e6
        );

        assertEq(token.balanceOf(address(0xA1)), 600 * 1e6);
        assertEq(token.balanceOf(address(0xA2)), 400 * 1e6);
    }

    function test_transfer_zeroAmount_reverts()
        public
    {
        vm.prank(
            address(0xA1)
        );

        vm.expectRevert(
            ReferralTokenDemo.InvalidValue.selector
        );

        token.transfer(
            address(0xA2),
            0
        );
    }

    function test_transfer_freezeHook_reverts()
        public
    {
        token.setTransferHook(
            address(freezer)
        );

        vm.prank(
            address(0xA1)
        );

        vm.expectRevert(
            FreezeTransferHookDemo.TransfersFrozen.selector
        );

        token.transfer(
            address(0xA2),
            400 * 1e6
        );

        assertEq(token.balanceOf(address(0xA1)), START_BALANCE);
    }

    function test_transfer_recordingHook_seesPreTransferBalances()
        public
    {
        token.setTransferHook(
            address(recorder)
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(token)
        );

        emit TransferHookRan(
            address(0xA1),
            address(0xA2),
            START_BALANCE,
            0
        );

        vm.prank(
            address(0xA1)
        );

        token.transfer(
            address(0xA2),
            400 * 1e6
        );

        assertEq(token.balanceOf(address(0xA2)), 400 * 1e6);
    }

    function test_transferFrom_runsHook()
        public
    {
        token.setTransferHook(
            address(recorder)
        );

        vm.prank(
            address(0xA1)
        );

        token.approve(
            address(this),
            type(uint256).max
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(token)
        );

        emit TransferHookRan(
            address(0xA1),
            address(0xA2),
            START_BALANCE,
            0
        );

        token.transferFrom(
            address(0xA1),
            address(0xA2),
            300 * 1e6
        );

        assertEq(token.balanceOf(address(0xA2)), 300 * 1e6);
    }

    function test_transferFrom_freezeHook_reverts()
        public
    {
        token.setTransferHook(
            address(freezer)
        );

        vm.prank(
            address(0xA1)
        );

        token.approve(
            address(this),
            type(uint256).max
        );

        vm.expectRevert(
            FreezeTransferHookDemo.TransfersFrozen.selector
        );

        token.transferFrom(
            address(0xA1),
            address(0xA2),
            300 * 1e6
        );
    }

    function test_setTransferHook_swapsAndClears()
        public
    {
        token.setTransferHook(
            address(freezer)
        );

        vm.prank(
            address(0xA1)
        );

        vm.expectRevert(
            FreezeTransferHookDemo.TransfersFrozen.selector
        );

        token.transfer(
            address(0xA2),
            100 * 1e6
        );

        token.setTransferHook(
            address(recorder)
        );

        vm.prank(
            address(0xA1)
        );

        token.transfer(
            address(0xA2),
            100 * 1e6
        );

        assertEq(token.balanceOf(address(0xA2)), 100 * 1e6);

        token.setTransferHook(
            address(0)
        );

        vm.recordLogs();

        vm.prank(
            address(0xA1)
        );

        token.transfer(
            address(0xA2),
            100 * 1e6
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != HOOK_RAN_TOPIC
            );
        }

        assertEq(token.balanceOf(address(0xA2)), 200 * 1e6);
    }

    function test_applyTransferHook_directCall_reverts()
        public
    {
        vm.expectRevert(
            RecordingTransferHookDemo.NotHookExecution.selector
        );

        recorder.applyTransferHook(
            address(0xA1),
            address(0xA2)
        );

        vm.expectRevert(
            FreezeTransferHookDemo.NotHookExecution.selector
        );

        freezer.applyTransferHook(
            address(0xA1),
            address(0xA2)
        );
    }

    function test_mint_doesNotRunHook()
        public
    {
        token.setTransferHook(
            address(freezer)
        );

        token.mint(
            address(0xA2),
            500 * 1e6
        );

        assertEq(token.balanceOf(address(0xA2)), 500 * 1e6);
    }
}
