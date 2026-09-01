// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {console2} from "forge-std/console2.sol";

import {Internal} from "@chainlink/contracts-ccip/contracts/libraries/Internal.sol";

import {
    CcipForkHarness,
    ICcipOffRampExec,
    ICcipOffRampDiscovery
} from "./utils/CcipForkHarness.sol";
import {
    ICcipBridgeVault,
    ICcipRouterView,
    IUsdDecimals
} from "./utils/CcipForkInterfaces.sol";

import {WiseTelecomNodesDiamondErrors} from "../../../src/diamond/vault/WiseTelecomNodesDiamondErrors.sol";

/**
 * @dev Rehearses the usdg mainnet <-> arbitrum vault peering against
 * the LIVE deployed diamonds on forks of both chains. The usdg product
 * shares one CREATE3 canonical address on every chain it lives on, and
 * the CCIP routers already carry a real mainnet <-> arbitrum lane;
 * only the VAULT-level peering may still be missing, which is exactly
 * what this suite proves and then repairs in rehearsal:
 *
 *   1. while a leg is un-peered, a funded bridge attempt on that side
 *      reverts {CrossChainPeerNotEnabled}; the baseline is asserted,
 *      not assumed, and the test self-skips if reality changed;
 *   2. the full timelocked peering ladder runs per missing side under
 *      the real master: propose, premature execute reverting
 *      {CrossChainPeerTimelockNotElapsed} (asserted whenever the live
 *      vault reports itself finalized), warp past the 3-day delay,
 *      execute; then a complete round trip bridges shares mainnet ->
 *      arbitrum and back through the real on-ramps and off-ramps;
 *   3. the usdg robinhood <-> arbitrum legs are recorded by discovery
 *      instead of assumed: the CCIP routers began carrying this lane
 *      in August 2026, while the usdg mesh still routes all vault
 *      value through mainnet. The test logs router support, on-ramp
 *      and vault peering per direction, asserts each router's support
 *      flag against its own on-ramp table, and pins any peered vault
 *      leg to the canonical address.
 *
 * Every timelock warp is rewound right after its execute so the real
 * fee quoter never sees an artificially stale gas price. The
 * end-to-end round trip runs only under the default off-ramp routing
 * engine, whose scraped-log delivery both legs reuse. If the router
 * lane itself is missing the suite reverts loudly instead of skipping.
 */
contract CcipUsdgPeeringRehearsalFork is CcipForkHarness {

    address internal alice = address(0xA11CE);

    function _laneConfig()
        internal
        pure
        override
        returns (LaneCfg memory)
    {
        return LaneCfg({
            product: "usdg",
            srcNetwork: "mainnet",
            dstNetwork: "arbitrum",
            srcRpc: "mainnet",
            dstRpc: "arbitrum"
        });
    }

    function test_usdgBaseline_unPeeredLegReverts()
        public
    {
        _onSrc();

        bool srcPeered = ICcipBridgeVault(src.diamond).crossChainPeerEnabled(
            dst.chainSelector
        );

        _onDst();

        bool dstPeered = ICcipBridgeVault(dst.diamond).crossChainPeerEnabled(
            src.chainSelector
        );

        if (srcPeered && dstPeered) {
            return;
        }

        if (srcPeered == false) {

            _assertUnpeeredBridgeReverts(
                src,
                dst.chainSelector
            );
        }

        if (dstPeered == false) {

            _assertUnpeeredBridgeReverts(
                dst,
                src.chainSelector
            );
        }
    }

    function test_usdgPeeringRehearsal_endToEnd()
        public
    {
        if (engine != RouteEngine.OffRampShim) {

            vm.skip(
                true
            );

            return;
        }

        assertEq(
            src.diamond,
            dst.diamond,
            "usdg canonical CREATE3 address must match across chains"
        );

        _onSrc();

        require(
            ICcipRouterView(src.router).getOnRamp(dst.chainSelector) != address(0),
            "CCIP router lane missing: mainnet -> arbitrum"
        );

        _onDst();

        require(
            ICcipRouterView(dst.router).getOnRamp(src.chainSelector) != address(0),
            "CCIP router lane missing: arbitrum -> mainnet"
        );

        uint8 dstDecimals = IUsdDecimals(dst.usd).decimals();

        _onSrc();

        uint8 srcDecimals = IUsdDecimals(src.usd).decimals();

        if (ICcipBridgeVault(src.diamond).crossChainPeerEnabled(dst.chainSelector) == false) {

            _peerLadder(
                src,
                dst.chainSelector,
                dst.diamond,
                dstDecimals
            );
        }

        _onDst();

        if (ICcipBridgeVault(dst.diamond).crossChainPeerEnabled(src.chainSelector) == false) {

            _peerLadder(
                dst,
                src.chainSelector,
                src.diamond,
                srcDecimals
            );
        }

        _onSrc();

        uint256 amount = 1_000 * src.one;

        _prepShares(
            src,
            alice,
            amount
        );

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
            0,
            "source must burn the bridged shares"
        );

        _route(
            sent
        );

        _onDst();

        assertEq(
            ICcipBridgeVault(dst.diamond).balanceOf(alice) - dstBalanceBefore,
            sent.dstAmount,
            "destination must mint the scaled bridged amount"
        );

        assertTrue(
            ICcipBridgeVault(dst.diamond).processedMessageId(sent.messageId),
            "forward message not marked processed"
        );

        _prepBridgeReady(
            dst
        );

        SentMessage memory back = _bridgeOutFrom(
            dst,
            src,
            alice,
            sent.dstAmount
        );

        _onDst();

        assertEq(
            ICcipBridgeVault(dst.diamond).balanceOf(alice),
            dstBalanceBefore,
            "return leg must burn the round-tripped shares"
        );

        _routeBetween(
            dst,
            src,
            back
        );

        _onSrc();

        assertEq(
            ICcipBridgeVault(src.diamond).balanceOf(alice),
            back.dstAmount,
            "round trip must restore the source balance"
        );

        assertTrue(
            ICcipBridgeVault(src.diamond).processedMessageId(back.messageId),
            "return message not marked processed"
        );
    }

    function test_usdgRobinhoodArbitrum_laneDiscovery()
        public
    {
        string memory robinhoodCcip = vm.readFile(
            "config/ccip.robinhood.json"
        );

        address robinhoodRouter = vm.parseJsonAddress(
            robinhoodCcip,
            ".router"
        );

        uint64 robinhoodSelector = uint64(
            vm.parseUint(
                vm.parseJsonString(
                    robinhoodCcip,
                    ".chainSelector"
                )
            )
        );

        uint256 robinhoodForkId = vm.createFork(
            "robinhood"
        );

        vm.selectFork(
            robinhoodForkId
        );

        require(
            robinhoodRouter.code.length > 0,
            "ccip router not deployed on the robinhood fork"
        );

        require(
            src.diamond.code.length > 0,
            "usdg vault not deployed at the canonical address on robinhood"
        );

        bool robinhoodSupports = ICcipRouterView(robinhoodRouter).isChainSupported(
            dst.chainSelector
        );

        address robinhoodOnRamp = ICcipRouterView(robinhoodRouter).getOnRamp(
            dst.chainSelector
        );

        assertEq(
            robinhoodOnRamp != address(0),
            robinhoodSupports,
            "robinhood router support flag must match its on-ramp table"
        );

        bool robinhoodPeered = ICcipBridgeVault(src.diamond).crossChainPeerEnabled(
            dst.chainSelector
        );

        if (robinhoodPeered) {

            assertEq(
                ICcipBridgeVault(src.diamond).crossChainPeer(
                    dst.chainSelector
                ),
                dst.diamond,
                "peered robinhood leg must point at the canonical address"
            );
        }

        console2.log(
            "| lane | robinhood -> arbitrum"
        );

        console2.log(
            "| router supports remote |",
            robinhoodSupports
        );

        console2.log(
            "| router on-ramp |",
            robinhoodOnRamp
        );

        console2.log(
            "| vault peer enabled |",
            robinhoodPeered
        );

        _onDst();

        bool arbitrumSupports = ICcipRouterView(dst.router).isChainSupported(
            robinhoodSelector
        );

        address arbitrumOnRamp = ICcipRouterView(dst.router).getOnRamp(
            robinhoodSelector
        );

        assertEq(
            arbitrumOnRamp != address(0),
            arbitrumSupports,
            "arbitrum router support flag must match its on-ramp table"
        );

        bool arbitrumPeered = ICcipBridgeVault(dst.diamond).crossChainPeerEnabled(
            robinhoodSelector
        );

        if (arbitrumPeered) {

            assertEq(
                ICcipBridgeVault(dst.diamond).crossChainPeer(
                    robinhoodSelector
                ),
                src.diamond,
                "peered arbitrum leg must point at the canonical address"
            );
        }

        console2.log(
            "| lane | arbitrum -> robinhood"
        );

        console2.log(
            "| router supports remote |",
            arbitrumSupports
        );

        console2.log(
            "| router on-ramp |",
            arbitrumOnRamp
        );

        console2.log(
            "| vault peer enabled |",
            arbitrumPeered
        );
    }

    function _assertUnpeeredBridgeReverts(
        ChainCtx storage _side,
        uint64 _remoteSelector
    )
        internal
    {
        vm.selectFork(
            _side.forkId
        );

        uint256 amount = 1_000 * _side.one;

        _prepShares(
            _side,
            alice,
            amount
        );

        vm.deal(
            alice,
            1 ether
        );

        vm.prank(
            alice
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.CrossChainPeerNotEnabled.selector
        );

        ICcipBridgeVault(_side.diamond).bridgeToVault{value: 1 ether}(
            _remoteSelector,
            amount
        );
    }

    function _prepBridgeReady(
        ChainCtx storage _side
    )
        internal
    {
        vm.selectFork(
            _side.forkId
        );

        ICcipBridgeVault vault = ICcipBridgeVault(
            _side.diamond
        );

        if (vault.paused()) {

            vm.prank(
                _side.master
            );

            vault.unpauseDeposits();
        }

        vm.prank(
            _side.master
        );

        vault.setGraceFreezeEnabled(
            false
        );
    }

    function _bridgeOutFrom(
        ChainCtx storage _from,
        ChainCtx storage _to,
        address _user,
        uint256 _amount
    )
        internal
        returns (SentMessage memory sent)
    {
        vm.selectFork(
            _from.forkId
        );

        ICcipBridgeVault vault = ICcipBridgeVault(
            _from.diamond
        );

        uint256 fee = vault.quoteBridgeFee(
            _to.chainSelector,
            _amount
        );

        vm.deal(
            _user,
            fee
        );

        sent.srcOnRamp = ICcipRouterView(_from.router).getOnRamp(
            _to.chainSelector
        );

        require(
            sent.srcOnRamp != address(0),
            "CCIP router lane missing for this leg"
        );

        vm.recordLogs();

        vm.prank(
            _user
        );

        (
            uint256 dstAmount,
            bytes32 messageId
        ) = vault.bridgeToVault{value: fee}(
            _to.chainSelector,
            _amount
        );

        sent.messageId = messageId;
        sent.srcChainSelector = _from.chainSelector;
        sent.dstChainSelector = _to.chainSelector;
        sent.srcDiamond = _from.diamond;
        sent.dstDiamond = _to.diamond;
        sent.user = _user;
        sent.srcAmount = _amount;
        sent.dstAmount = dstAmount;
        sent.referralData = "";
    }

    function _routeBetween(
        ChainCtx storage _from,
        ChainCtx storage _to,
        SentMessage memory _sent
    )
        internal
    {
        Internal.EVM2AnyRampMessage memory ramp = _scrapeRampMessage(
            _sent.messageId
        );

        vm.selectFork(
            _to.forkId
        );

        address offRamp = _findOffRampOn(
            _to.router,
            _from.chainSelector,
            _sent.srcOnRamp
        );

        require(
            offRamp != address(0),
            "off-ramp not found for lane"
        );

        Internal.Any2EVMRampMessage memory delivery = Internal.Any2EVMRampMessage({
            header: ramp.header,
            sender: abi.encode(ramp.sender),
            data: ramp.data,
            receiver: _decodeAddress(ramp.receiver),
            gasLimit: _gasLimitOf(ramp.extraArgs),
            tokenAmounts: new Internal.Any2EVMTokenTransfer[](0)
        });

        vm.prank(
            offRamp
        );

        ICcipOffRampExec(offRamp).executeSingleMessage(
            delivery,
            new bytes[](0),
            new uint32[](0)
        );
    }

    function _findOffRampOn(
        address _router,
        uint64 _srcChainSelector,
        address _srcOnRamp
    )
        internal
        view
        returns (address)
    {
        ICcipOffRampDiscovery.OffRamp[] memory offRamps = ICcipOffRampDiscovery(
            _router
        ).getOffRamps();

        for (uint256 i = offRamps.length; i > 0; --i) {

            if (offRamps[i - 1].sourceChainSelector != _srcChainSelector) {
                continue;
            }

            address candidate = offRamps[i - 1].offRamp;

            try ICcipOffRampDiscovery(candidate).getSourceChainConfig(
                _srcChainSelector
            ) returns (
                ICcipOffRampDiscovery.SourceChainConfig memory cfg
            ) {
                if (cfg.isEnabled && cfg.onRamp.length == 32) {

                    address configuredOnRamp = _decodeAddress(
                        cfg.onRamp
                    );

                    if (configuredOnRamp == _srcOnRamp) {
                        return candidate;
                    }
                }
            } catch {}
        }

        return address(0);
    }
}
