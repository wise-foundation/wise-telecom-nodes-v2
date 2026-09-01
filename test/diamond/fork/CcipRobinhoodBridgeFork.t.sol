// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {console2} from "forge-std/console2.sol";

import {CcipForkHarness} from "./utils/CcipForkHarness.sol";
import {
    ICcipBridgeVault,
    ICcipRouterView,
    IUsdDecimals
} from "./utils/CcipForkInterfaces.sol";

/**
 * @dev Bridge rehearsal for the Robinhood chain: the usdg
 * robinhood -> mainnet lane against the LIVE deployed diamonds on
 * forks of both chains. Mainnet is the usdg mesh's routing hub, so
 * this is the directed robinhood lane that carries vault value — the
 * suite records the actual wiring instead of assuming it, and stays
 * valuable in both world-states:
 *
 *   1. discovery logs every vault peer field and router support flag
 *      in both directions, asserting the config-derived router match
 *      unconditionally and the canonical-peer + decimals invariants
 *      only where a lane reports itself enabled;
 *   2. when the vault peering is live in both directions, a full
 *      end-to-end bridge burns on robinhood, routes through the real
 *      ramps, and mints on mainnet — the bridge fee flows in the
 *      native gas coin, funded via `vm.deal` inside the harness;
 *   3. when the vault peering is missing on either side, the full
 *      timelocked ladder is rehearsed there first — propose,
 *      premature execute reverting {CrossChainPeerTimelockNotElapsed}
 *      (asserted whenever the live vault reports itself finalized),
 *      warp past the 3-day delay, execute — and the same end-to-end
 *      bridge then runs anyway.
 *
 * Every timelock warp is rewound right after its execute so the real
 * fee quoter never sees an artificially stale gas price. A missing
 * router-level lane reverts loudly instead of skipping.
 *
 * The robinhood -> mainnet lane was upgraded to OnRamp/OffRamp
 * 2.0.0 (the CCV era) in August 2026; the off-ramp scrape shim
 * speaks that generation (packed `MessageV1` wire decode + mocked
 * CCV attestation), so the end-to-end tests run under the DEFAULT
 * engine and exercise the real off-ramp and per-message gas limit.
 * The version gate stays as a guard: a future ramp generation the
 * shim does not speak yet skips loudly here, and the E2E runs with
 * `WTN_CCIP_ROUTE_ENGINE=router` until the shim learns it.
 */
contract CcipRobinhoodBridgeFork is CcipForkHarness {

    address internal alice = address(0xA11CE);

    function _laneConfig()
        internal
        pure
        override
        returns (LaneCfg memory)
    {
        return LaneCfg({
            product: "usdg",
            srcNetwork: "robinhood",
            dstNetwork: "mainnet",
            srcRpc: "robinhood",
            dstRpc: "mainnet"
        });
    }

    function test_robinhoodLane_discovery()
        public
    {
        _onSrc();

        ICcipBridgeVault srcVault = ICcipBridgeVault(
            src.diamond
        );

        assertEq(
            srcVault.ccipRouter(),
            src.router,
            "robinhood vault router must match config"
        );

        bool srcEnabled = srcVault.crossChainPeerEnabled(
            dst.chainSelector
        );

        address srcPeer = srcVault.crossChainPeer(
            dst.chainSelector
        );

        uint8 srcPeerDecimals = srcVault.crossChainPeerDecimals(
            dst.chainSelector
        );

        bool srcRouterSupports = ICcipRouterView(src.router).isChainSupported(
            dst.chainSelector
        );

        if (srcEnabled) {

            assertEq(
                srcPeer,
                dst.diamond,
                "enabled robinhood lane must point at the canonical peer"
            );

            assertEq(
                10 ** uint256(srcPeerDecimals),
                dst.one,
                "enabled robinhood lane must carry the remote decimals"
            );
        }

        console2.log(
            "| lane | robinhood -> mainnet"
        );

        console2.log(
            "| vault peer enabled |",
            srcEnabled
        );

        console2.log(
            "| vault peer |",
            srcPeer
        );

        console2.log(
            "| vault peer decimals |",
            srcPeerDecimals
        );

        console2.log(
            "| router supports remote |",
            srcRouterSupports
        );

        _onDst();

        ICcipBridgeVault dstVault = ICcipBridgeVault(
            dst.diamond
        );

        assertEq(
            dstVault.ccipRouter(),
            dst.router,
            "mainnet vault router must match config"
        );

        bool dstEnabled = dstVault.crossChainPeerEnabled(
            src.chainSelector
        );

        address dstPeer = dstVault.crossChainPeer(
            src.chainSelector
        );

        uint8 dstPeerDecimals = dstVault.crossChainPeerDecimals(
            src.chainSelector
        );

        bool dstRouterSupports = ICcipRouterView(dst.router).isChainSupported(
            src.chainSelector
        );

        if (dstEnabled) {

            assertEq(
                dstPeer,
                src.diamond,
                "enabled mainnet lane must point at the canonical peer"
            );

            assertEq(
                10 ** uint256(dstPeerDecimals),
                src.one,
                "enabled mainnet lane must carry the remote decimals"
            );
        }

        console2.log(
            "| lane | mainnet -> robinhood"
        );

        console2.log(
            "| vault peer enabled |",
            dstEnabled
        );

        console2.log(
            "| vault peer |",
            dstPeer
        );

        console2.log(
            "| vault peer decimals |",
            dstPeerDecimals
        );

        console2.log(
            "| router supports remote |",
            dstRouterSupports
        );
    }

    function test_robinhoodBridge_liveLaneEndToEnd()
        public
    {
        _onSrc();

        if (ICcipBridgeVault(src.diamond).crossChainPeerEnabled(dst.chainSelector) == false) {

            vm.skip(
                true
            );

            return;
        }

        _onDst();

        if (ICcipBridgeVault(dst.diamond).crossChainPeerEnabled(src.chainSelector) == false) {

            vm.skip(
                true
            );

            return;
        }

        _runLiveLaneEndToEnd();
    }

    function test_robinhoodBridge_peeringRehearsalWhenMissing()
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

        uint8 dstDecimals = IUsdDecimals(dst.usd).decimals();

        _onSrc();

        uint8 srcDecimals = IUsdDecimals(src.usd).decimals();

        if (srcPeered == false) {

            _peerLadder(
                src,
                dst.chainSelector,
                dst.diamond,
                dstDecimals
            );
        }

        if (dstPeered == false) {

            _peerLadder(
                dst,
                src.chainSelector,
                src.diamond,
                srcDecimals
            );
        }

        _runLiveLaneEndToEnd();
    }

    function _runLiveLaneEndToEnd()
        internal
    {
        _onSrc();

        address onRamp = ICcipRouterView(src.router).getOnRamp(
            dst.chainSelector
        );

        require(
            onRamp != address(0),
            "CCIP router lane missing: robinhood -> mainnet"
        );

        if (
            engine == RouteEngine.OffRampShim
            && _offRampScrapeSupported(onRamp) == false
        ) {

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
            0,
            "robinhood must burn the bridged shares"
        );

        assertEq(
            ICcipBridgeVault(src.diamond).totalSupply(),
            srcSupplyBefore - amount,
            "robinhood supply must drop by the burned amount"
        );

        _route(
            sent
        );

        _onDst();

        assertEq(
            ICcipBridgeVault(dst.diamond).balanceOf(alice) - dstBalanceBefore,
            sent.dstAmount,
            "mainnet must mint the scaled bridged amount"
        );

        assertTrue(
            ICcipBridgeVault(dst.diamond).processedMessageId(sent.messageId),
            "message not marked processed on mainnet"
        );
    }

}
