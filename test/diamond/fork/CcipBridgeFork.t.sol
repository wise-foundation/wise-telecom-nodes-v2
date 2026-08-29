// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {CcipForkHarness} from "./utils/CcipForkHarness.sol";
import {ICcipBridgeVault} from "./utils/CcipForkInterfaces.sol";

import {WiseTelecomNodesDiamondErrors} from "../../../src/diamond/vault/WiseTelecomNodesDiamondErrors.sol";

/**
 * @dev End-to-end CCIP bridge rehearsal against the LIVE deployed
 * diamonds on a fork of each production chain. One directed lane per
 * concrete subclass; every scenario runs on real bytecode, real
 * routers and (under the default off-ramp engine) the real per-message
 * gas limit. Proves the bridge burns on the source, the message
 * routes to the destination, the destination mints the scaled amount
 * for the same user and marks the message processed, the fee quote is
 * live and nonzero, a replayed delivery reverts
 * {MessageAlreadyProcessed}, a non-router caller reverts
 * {NotCcipRouter}, and a delivery from a non-peer sender reverts
 * {CrossChainPeerMismatch}. Lane addresses come from config before
 * forking.
 */
abstract contract CcipBridgeForkBase is CcipForkHarness {

    address internal alice = address(0xA11CE);

    function test_ccipBridge_liveLaneEndToEnd()
        public
    {
        _onSrc();

        if (ICcipBridgeVault(src.diamond).crossChainPeerEnabled(dst.chainSelector) == false) {

            vm.skip(
                true
            );

            return;
        }

        uint256 amount = 1_000 * src.one;

        _prepShares(
            src,
            alice,
            amount
        );

        uint256 srcSupplyBefore = ICcipBridgeVault(src.diamond).totalSupply();

        _onDst();

        uint256 dstBalanceBefore = ICcipBridgeVault(dst.diamond).balanceOf(
            alice
        );

        SentMessage memory sent = _bridgeOut(
            alice,
            amount,
            ""
        );

        _onSrc();

        assertEq(
            ICcipBridgeVault(src.diamond).balanceOf(alice),
            0
        );

        assertEq(
            ICcipBridgeVault(src.diamond).totalSupply(),
            srcSupplyBefore - amount
        );

        _route(
            sent
        );

        _onDst();

        assertEq(
            ICcipBridgeVault(dst.diamond).balanceOf(alice) - dstBalanceBefore,
            sent.dstAmount
        );

        assertTrue(
            ICcipBridgeVault(dst.diamond).processedMessageId(sent.messageId)
        );
    }

    function test_ccipBridge_quoteBridgeFee_nonZero()
        public
    {
        _onSrc();

        if (ICcipBridgeVault(src.diamond).crossChainPeerEnabled(dst.chainSelector) == false) {

            vm.skip(
                true
            );

            return;
        }

        uint256 amount = 500 * src.one;

        uint256 vaultQuote = ICcipBridgeVault(src.diamond).quoteBridgeFee(
            dst.chainSelector,
            amount
        );

        assertGt(
            vaultQuote,
            0
        );
    }

    function test_ccipBridge_replayRejected()
        public
    {
        if (engine != RouteEngine.RouterShim) {

            vm.skip(
                true
            );

            return;
        }

        _onSrc();

        if (ICcipBridgeVault(src.diamond).crossChainPeerEnabled(dst.chainSelector) == false) {

            vm.skip(
                true
            );

            return;
        }

        uint256 amount = 1_000 * src.one;

        _prepShares(
            src,
            alice,
            amount
        );

        SentMessage memory sent = _bridgeOut(
            alice,
            amount,
            ""
        );

        _route(
            sent
        );

        _onDst();

        Client.Any2EVMMessage memory replay = Client.Any2EVMMessage({
            messageId: sent.messageId,
            sourceChainSelector: sent.srcChainSelector,
            sender: abi.encode(sent.srcDiamond),
            data: abi.encode(
                sent.user,
                sent.dstAmount,
                sent.referralData
            ),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(
            dst.router
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.MessageAlreadyProcessed.selector
        );

        ICcipBridgeVault(dst.diamond).ccipReceive(
            replay
        );
    }

    function test_ccipReceive_nonRouterRejected()
        public
    {
        _onDst();

        Client.Any2EVMMessage memory delivery = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: src.chainSelector,
            sender: abi.encode(src.diamond),
            data: abi.encode(alice, uint256(1), bytes("")),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(
            address(0xBAD)
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.NotCcipRouter.selector
        );

        ICcipBridgeVault(dst.diamond).ccipReceive(
            delivery
        );
    }

    function test_ccipReceive_wrongPeerRejected()
        public
    {
        _onDst();

        if (ICcipBridgeVault(dst.diamond).crossChainPeerEnabled(src.chainSelector) == false) {

            vm.skip(
                true
            );

            return;
        }

        Client.Any2EVMMessage memory delivery = Client.Any2EVMMessage({
            messageId: bytes32(uint256(2)),
            sourceChainSelector: src.chainSelector,
            sender: abi.encode(address(0xDEAD)),
            data: abi.encode(alice, uint256(1), bytes("")),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(
            dst.router
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.CrossChainPeerMismatch.selector
        );

        ICcipBridgeVault(dst.diamond).ccipReceive(
            delivery
        );
    }
}

contract CcipBridgeUsdcMainnetBaseFork is CcipBridgeForkBase {

    function _laneConfig()
        internal
        pure
        override
        returns (LaneCfg memory)
    {
        return LaneCfg({
            product: "usdc",
            srcNetwork: "mainnet",
            dstNetwork: "base",
            srcRpc: "mainnet",
            dstRpc: "base"
        });
    }
}

contract CcipBridgeUsdcBaseMainnetFork is CcipBridgeForkBase {

    function _laneConfig()
        internal
        pure
        override
        returns (LaneCfg memory)
    {
        return LaneCfg({
            product: "usdc",
            srcNetwork: "base",
            dstNetwork: "mainnet",
            srcRpc: "base",
            dstRpc: "mainnet"
        });
    }
}

contract CcipBridgeUsdcMainnetArbitrumFork is CcipBridgeForkBase {

    function _laneConfig()
        internal
        pure
        override
        returns (LaneCfg memory)
    {
        return LaneCfg({
            product: "usdc",
            srcNetwork: "mainnet",
            dstNetwork: "arbitrum",
            srcRpc: "mainnet",
            dstRpc: "arbitrum"
        });
    }
}

contract CcipBridgeUsdtMainnetBaseFork is CcipBridgeForkBase {

    function _laneConfig()
        internal
        pure
        override
        returns (LaneCfg memory)
    {
        return LaneCfg({
            product: "usdt",
            srcNetwork: "mainnet",
            dstNetwork: "base",
            srcRpc: "mainnet",
            dstRpc: "base"
        });
    }
}

contract CcipBridgeUsdtMainnetArbitrumFork is CcipBridgeForkBase {

    function _laneConfig()
        internal
        pure
        override
        returns (LaneCfg memory)
    {
        return LaneCfg({
            product: "usdt",
            srcNetwork: "mainnet",
            dstNetwork: "arbitrum",
            srcRpc: "mainnet",
            dstRpc: "arbitrum"
        });
    }
}

contract CcipBridgeUsdtBaseArbitrumFork is CcipBridgeForkBase {

    function _laneConfig()
        internal
        pure
        override
        returns (LaneCfg memory)
    {
        return LaneCfg({
            product: "usdt",
            srcNetwork: "base",
            dstNetwork: "arbitrum",
            srcRpc: "base",
            dstRpc: "arbitrum"
        });
    }
}
