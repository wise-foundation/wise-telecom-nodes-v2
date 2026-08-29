// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test, Vm} from "forge-std/Test.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {Internal} from "@chainlink/contracts-ccip/contracts/libraries/Internal.sol";

import {
    ICcipBridgeVault,
    ICcipRouterView,
    ICcipTypeAndVersion,
    IUsdDecimals
} from "./CcipForkInterfaces.sol";

import {WiseTelecomNodesDiamondErrors} from "../../../../src/diamond/vault/WiseTelecomNodesDiamondErrors.sol";

interface ICcipOffRampExec {

    function executeSingleMessage(
        Internal.Any2EVMRampMessage memory message,
        bytes[] calldata offchainTokenData,
        uint32[] calldata tokenGasOverrides
    )
        external;
}

interface ICcipOffRampDiscovery {

    struct OffRamp {
        uint64 sourceChainSelector;
        address offRamp;
    }

    struct SourceChainConfig {
        address router;
        bool isEnabled;
        uint64 minSeqNr;
        bool isRMNVerificationDisabled;
        bytes onRamp;
    }

    function getOffRamps()
        external
        view
        returns (OffRamp[] memory);

    function getSourceChainConfig(
        uint64 sourceChainSelector
    )
        external
        view
        returns (SourceChainConfig memory);
}

/**
 * @dev Base harness for CCIP multi-fork tests. Forks two (or more)
 * live chains in one test process, seeds shares and bridges out on
 * the source fork, and delivers the resulting CCIP message on the
 * destination fork, exercising the LIVE deployed diamonds and real
 * routers end to end.
 *
 * Routing is pluggable behind {_route}, selected by the
 * `WTN_CCIP_ROUTE_ENGINE` environment variable (default "offramp"):
 *
 *  - OffRampShim (default): scrapes the real `CCIPMessageSent` log on
 *    the source fork, rebuilds the delivery with a 32-byte abi-encoded
 *    sender (the encoding the live off-ramp forwards and the vault
 *    decodes), pranks the real off-ramp on the destination fork and
 *    calls `executeSingleMessage`, so the message flows through the
 *    real off-ramp, the real router `routeMessage`, and the real
 *    per-message gas limit — the faithful pre-broadcast budget signal.
 *  - RouterShim: rebuilds the `Any2EVMMessage` from the bridge return
 *    values and pranks the router directly, independent of any on-ramp
 *    event ABI; the only engine able to craft hostile messages (wrong
 *    peer, replayed id, unknown selector, legacy payload).
 *
 * There is deliberately NO chainlink-local simulator engine: the
 * upstream fork simulator (0.2.9) packs a 20-byte sender the vault's
 * strict 32-byte decode rejects, so its deliveries silently fail
 * against this vault, and its vendored network-table contract exceeds
 * the EIP-3860 initcode limit, which would force the sizes gate to
 * carry an ignore flag. If upstream ever widens the sender encoding,
 * a simulator engine can be re-added as a third branch of {_route}.
 *
 * The diamond and router addresses are read from `config/` JSON before
 * any fork is created, so they can never drift to a stale hardcode.
 * Forks use HEAD (no pin): a lane rehearsal must see today's real
 * router, peer and gas state.
 */
abstract contract CcipForkHarness is Test {

    enum RouteEngine {
        OffRampShim,
        RouterShim
    }

    struct LaneCfg {
        string product;
        string srcNetwork;
        string dstNetwork;
        string srcRpc;
        string dstRpc;
    }

    struct ChainCtx {
        uint256 forkId;
        uint256 chainId;
        uint64 chainSelector;
        address router;
        address diamond;
        address master;
        address usd;
        uint256 one;
    }

    struct SentMessage {
        bytes32 messageId;
        address srcOnRamp;
        uint64 srcChainSelector;
        uint64 dstChainSelector;
        address srcDiamond;
        address dstDiamond;
        address user;
        uint256 srcAmount;
        uint256 dstAmount;
        bytes referralData;
    }

    event CCIPMessageSent(
        uint64 indexed destChainSelector,
        uint64 indexed sequenceNumber,
        Internal.EVM2AnyRampMessage message
    );

    ChainCtx internal src;
    ChainCtx internal dst;
    RouteEngine internal engine;

    function _laneConfig()
        internal
        pure
        virtual
        returns (LaneCfg memory);

    function _afterForksReady()
        internal
        virtual
    {}

    function setUp()
        public
    {
        LaneCfg memory cfg = _laneConfig();

        (
            src.diamond,
            src.router,
            src.chainSelector,
            src.chainId
        ) = _readChainConfig(
            cfg.product,
            cfg.srcNetwork
        );

        (
            dst.diamond,
            dst.router,
            dst.chainSelector,
            dst.chainId
        ) = _readChainConfig(
            cfg.product,
            cfg.dstNetwork
        );

        src.forkId = vm.createFork(
            cfg.srcRpc
        );

        dst.forkId = vm.createFork(
            cfg.dstRpc
        );

        engine = _resolveEngine();

        _hydrate(
            src
        );

        _hydrate(
            dst
        );

        _afterForksReady();
    }

    function _readChainConfig(
        string memory _product,
        string memory _network
    )
        internal
        view
        returns (
            address diamond,
            address router,
            uint64 chainSelector,
            uint256 chainId
        )
    {
        string memory vaultJson = vm.readFile(
            string.concat(
                "config/vault.",
                _product,
                ".",
                _network,
                ".json"
            )
        );

        diamond = vm.parseJsonAddress(
            vaultJson,
            ".diamond"
        );

        string memory ccipJson = vm.readFile(
            string.concat(
                "config/ccip.",
                _network,
                ".json"
            )
        );

        router = vm.parseJsonAddress(
            ccipJson,
            ".router"
        );

        chainSelector = uint64(
            vm.parseUint(
                vm.parseJsonString(
                    ccipJson,
                    ".chainSelector"
                )
            )
        );

        chainId = _chainIdOf(
            _network
        );
    }

    function _chainIdOf(
        string memory _network
    )
        internal
        pure
        returns (uint256)
    {
        bytes32 tag = keccak256(
            bytes(_network)
        );

        if (tag == keccak256("mainnet")) {
            return 1;
        }

        if (tag == keccak256("base")) {
            return 8453;
        }

        if (tag == keccak256("arbitrum")) {
            return 42161;
        }

        if (tag == keccak256("robinhood")) {
            return 4663;
        }

        revert("unknown network");
    }

    function _hydrate(
        ChainCtx storage _ctx
    )
        internal
    {
        vm.selectFork(
            _ctx.forkId
        );

        require(
            _ctx.diamond.code.length > 0,
            "diamond not deployed on this fork"
        );

        require(
            _ctx.router.code.length > 0,
            "router not deployed on this fork"
        );

        ICcipBridgeVault vault = ICcipBridgeVault(
            _ctx.diamond
        );

        require(
            vault.ccipRouter() == _ctx.router,
            "router config mismatch on fork"
        );

        _ctx.master = vault.master();

        _ctx.usd = vault.USD_TOKEN();

        _ctx.one = 10 ** IUsdDecimals(_ctx.usd).decimals();
    }

    function _resolveEngine()
        internal
        view
        returns (RouteEngine)
    {
        string memory choice = vm.envOr(
            "WTN_CCIP_ROUTE_ENGINE",
            string("offramp")
        );

        bytes32 tag = keccak256(
            bytes(choice)
        );

        if (tag == keccak256("router")) {
            return RouteEngine.RouterShim;
        }

        return RouteEngine.OffRampShim;
    }

    function _onSrc()
        internal
    {
        vm.selectFork(
            src.forkId
        );
    }

    function _onDst()
        internal
    {
        vm.selectFork(
            dst.forkId
        );
    }

    function _prepShares(
        ChainCtx storage _ctx,
        address _user,
        uint256 _amount
    )
        internal
    {
        ICcipBridgeVault vault = ICcipBridgeVault(
            _ctx.diamond
        );

        if (vault.paused()) {

            vm.prank(
                _ctx.master
            );

            vault.unpauseDeposits();
        }

        if (vault.depositsDisabled()) {

            vm.prank(
                _ctx.master
            );

            vault.setDepositsDisabled(
                false
            );
        }

        vm.prank(
            _ctx.master
        );

        vault.setGraceFreezeEnabled(
            false
        );

        uint256 liftedCap = vault.totalSupply() + 100 * _amount;

        vm.prank(
            _ctx.master
        );

        vault.setTotalDepositCap(
            liftedCap
        );

        deal(
            _ctx.usd,
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        (
            bool ok,
        ) = _ctx.usd.call(
            abi.encodeWithSignature(
                "approve(address,uint256)",
                _ctx.diamond,
                type(uint256).max
            )
        );

        require(
            ok,
            "usd approve failed"
        );

        vm.prank(
            _user
        );

        vault.deposit(
            _amount
        );
    }

    function _bridgeOut(
        address _user,
        uint256 _amount,
        bytes memory _referralData
    )
        internal
        returns (SentMessage memory sent)
    {
        _onSrc();

        ICcipBridgeVault vault = ICcipBridgeVault(
            src.diamond
        );

        uint256 fee = vault.quoteBridgeFeeWithReferral(
            dst.chainSelector,
            _amount,
            _referralData
        );

        vm.deal(
            _user,
            fee
        );

        sent.srcOnRamp = ICcipRouterView(src.router).getOnRamp(
            dst.chainSelector
        );

        vm.recordLogs();

        vm.prank(
            _user
        );

        (
            uint256 dstAmount,
            bytes32 messageId
        ) = _referralData.length == 0
            ? vault.bridgeToVault{value: fee}(
                dst.chainSelector,
                _amount
            )
            : vault.bridgeToVaultWithReferral{value: fee}(
                dst.chainSelector,
                _amount,
                _referralData
            );

        sent.messageId = messageId;
        sent.srcChainSelector = src.chainSelector;
        sent.dstChainSelector = dst.chainSelector;
        sent.srcDiamond = src.diamond;
        sent.dstDiamond = dst.diamond;
        sent.user = _user;
        sent.srcAmount = _amount;
        sent.dstAmount = dstAmount;
        sent.referralData = _referralData;
    }

    function _route(
        SentMessage memory _sent
    )
        internal
    {
        if (engine == RouteEngine.OffRampShim) {

            _routeViaOffRamp(
                _sent
            );

            return;
        }

        _routeViaRouter(
            _sent
        );
    }

    function _routeViaRouter(
        SentMessage memory _sent
    )
        internal
    {
        Client.Any2EVMMessage memory delivery = Client.Any2EVMMessage({
            messageId: _sent.messageId,
            sourceChainSelector: _sent.srcChainSelector,
            sender: abi.encode(_sent.srcDiamond),
            data: abi.encode(
                _sent.user,
                _sent.dstAmount,
                _sent.referralData
            ),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        _onDst();

        vm.prank(
            dst.router
        );

        ICcipBridgeVault(dst.diamond).ccipReceive(
            delivery
        );
    }

    function _offRampScrapeSupported(
        address _onRamp
    )
        internal
        returns (bool)
    {
        _onSrc();

        string memory rampVersion = ICcipTypeAndVersion(_onRamp).typeAndVersion();

        return keccak256(bytes(rampVersion)) == keccak256("OnRamp 1.6.0");
    }

    /**
     * @dev The scrape shim decodes the `CCIPMessageSent` event of
     * OnRamp 1.6.0 — a lane whose on-ramp has been upgraded past that
     * emits a different encoding and the scrape would fail with an
     * unhelpful "log not found", so the version is probed first and
     * the failure names the live version and the RouterShim fallback.
     */
    function _routeViaOffRamp(
        SentMessage memory _sent
    )
        internal
    {
        _onSrc();

        string memory rampVersion = ICcipTypeAndVersion(_sent.srcOnRamp).typeAndVersion();

        require(
            keccak256(bytes(rampVersion)) == keccak256("OnRamp 1.6.0"),
            string.concat(
                "off-ramp scrape shim understands OnRamp 1.6.0 only; this lane runs '",
                rampVersion,
                "' - rerun with WTN_CCIP_ROUTE_ENGINE=router until the shim learns it"
            )
        );

        Internal.EVM2AnyRampMessage memory ramp = _scrapeRampMessage(
            _sent.messageId
        );

        _onDst();

        address offRamp = _findOffRamp(
            _sent.srcChainSelector,
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

    function _scrapeRampMessage(
        bytes32 _messageId
    )
        internal
        view
        returns (Internal.EVM2AnyRampMessage memory ramp)
    {
        Vm.Log[] memory entries = vm.getRecordedLogs();

        for (uint256 i; i < entries.length; ++i) {

            if (entries[i].topics[0] != CCIPMessageSent.selector) {
                continue;
            }

            Internal.EVM2AnyRampMessage memory candidate = abi.decode(
                entries[i].data,
                (Internal.EVM2AnyRampMessage)
            );

            if (candidate.header.messageId == _messageId) {
                return candidate;
            }
        }

        revert("CCIPMessageSent log not found");
    }

    function _findOffRamp(
        uint64 _srcChainSelector,
        address _srcOnRamp
    )
        internal
        view
        returns (address)
    {
        ICcipOffRampDiscovery.OffRamp[] memory offRamps = ICcipOffRampDiscovery(
            dst.router
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

    function _gasLimitOf(
        bytes memory _extraArgs
    )
        internal
        pure
        returns (uint256)
    {
        if (_extraArgs.length == 0) {
            return 200_000;
        }

        bytes4 tag = bytes4(
            _extraArgs
        );

        bytes memory tail = new bytes(
            _extraArgs.length - 4
        );

        for (uint256 i = 4; i < _extraArgs.length; ++i) {
            tail[i - 4] = _extraArgs[i];
        }

        if (tag == Client.GENERIC_EXTRA_ARGS_V2_TAG) {

            Client.GenericExtraArgsV2 memory args = abi.decode(
                tail,
                (Client.GenericExtraArgsV2)
            );

            return args.gasLimit;
        }

        return abi.decode(
            tail,
            (uint256)
        );
    }

    function _decodeAddress(
        bytes memory _encoded
    )
        internal
        pure
        returns (address)
    {
        if (_encoded.length == 32) {

            return abi.decode(
                _encoded,
                (address)
            );
        }

        if (_encoded.length == 20) {
            return address(uint160(bytes20(_encoded)));
        }

        revert("bad address encoding");
    }

    function _raiseBridgeGasLimit(
        ChainCtx storage _ctx,
        uint256 _gasLimit
    )
        internal
    {
        vm.selectFork(
            _ctx.forkId
        );

        vm.prank(
            _ctx.master
        );

        ICcipBridgeVault(_ctx.diamond).setBridgeGasLimit(
            _gasLimit
        );
    }

    /**
     * @dev Full timelocked vault-peering ladder for one side of a
     * lane, run under the real master: propose, a premature execute
     * asserted to revert {CrossChainPeerTimelockNotElapsed} whenever
     * the live vault reports itself finalized, warp past the 3-day
     * delay, execute — then the warp is rewound so the real fee
     * quoter never sees an artificially stale gas price.
     */
    function _peerLadder(
        ChainCtx storage _side,
        uint64 _remoteSelector,
        address _peer,
        uint8 _peerDecimals
    )
        internal
    {
        vm.selectFork(
            _side.forkId
        );

        ICcipBridgeVault vault = ICcipBridgeVault(
            _side.diamond
        );

        uint256 startTime = block.timestamp;

        vm.prank(
            _side.master
        );

        vault.proposeCrossChainPeer(
            _remoteSelector,
            _peer,
            _peerDecimals
        );

        if (_isFinalized(_side.diamond)) {

            vm.prank(
                _side.master
            );

            vm.expectRevert(
                WiseTelecomNodesDiamondErrors.CrossChainPeerTimelockNotElapsed.selector
            );

            vault.executeCrossChainPeerChange(
                _remoteSelector
            );
        }

        vm.warp(
            startTime + 3 days + 1
        );

        vm.prank(
            _side.master
        );

        vault.executeCrossChainPeerChange(
            _remoteSelector
        );

        vm.warp(
            startTime + 2
        );

        assertTrue(
            vault.crossChainPeerEnabled(_remoteSelector),
            "peer not enabled after the timelocked execute"
        );

        assertEq(
            vault.crossChainPeer(_remoteSelector),
            _peer,
            "peer address mismatch after the timelocked execute"
        );

        assertEq(
            vault.crossChainPeerDecimals(_remoteSelector),
            _peerDecimals,
            "peer decimals mismatch after the timelocked execute"
        );
    }

    function _isFinalized(
        address _diamond
    )
        internal
        view
        returns (bool)
    {
        (
            bool ok,
            bytes memory ret
        ) = _diamond.staticcall(
            abi.encodeWithSignature(
                "initialized()"
            )
        );

        return ok && ret.length == 32 && abi.decode(ret, (bool));
    }
}
