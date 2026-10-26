// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {
    ICcipBridgeVault,
    IUsdDecimals
} from "./utils/CcipForkInterfaces.sol";

/**
 * @dev Records the live CCIP lane baseline for one diamond per fork.
 * Reads every cross-chain peer field the vault exposes for each other
 * network in the product mesh and asserts the wiring invariants
 * (router matches config, an enabled lane points at the product's
 * canonical CREATE3 address with matching decimals) rather than
 * assuming them. Emits one console row per lane so the per-chain
 * enablement state becomes a recorded, re-runnable fact instead of
 * a guess. Single fork each so the suite runs one chain at a time
 * as RPC access allows.
 */
abstract contract CcipLaneDiscoveryForkBase is Test {

    struct Cfg {
        string product;
        string network;
        string rpc;
    }

    ICcipBridgeVault internal v;
    address internal canonical;
    uint256 internal decimalsUsd;

    function _config()
        internal
        pure
        virtual
        returns (Cfg memory);

    function _remoteNetworks()
        internal
        pure
        virtual
        returns (string[] memory);

    function setUp()
        public
    {
        Cfg memory cfg = _config();

        string memory vaultJson = vm.readFile(
            string.concat(
                "config/vault.",
                cfg.product,
                ".",
                cfg.network,
                ".json"
            )
        );

        canonical = vm.parseJsonAddress(
            vaultJson,
            ".diamond"
        );

        vm.createSelectFork(
            cfg.rpc
        );

        require(
            canonical.code.length > 0,
            "diamond not deployed on this fork"
        );

        v = ICcipBridgeVault(
            canonical
        );

        decimalsUsd = IUsdDecimals(v.USD_TOKEN()).decimals();
    }

    function test_ccipLanes_discoverAndAssertBaseline()
        public
    {
        Cfg memory cfg = _config();

        string memory ccipSelf = vm.readFile(
            string.concat(
                "config/ccip.",
                cfg.network,
                ".json"
            )
        );

        assertEq(
            v.ccipRouter(),
            vm.parseJsonAddress(
                ccipSelf,
                ".router"
            )
        );

        string[] memory remotes = _remoteNetworks();

        for (uint256 i; i < remotes.length; ++i) {

            string memory remoteCcip = vm.readFile(
                string.concat(
                    "config/ccip.",
                    remotes[i],
                    ".json"
                )
            );

            uint64 remoteSelector = uint64(
                vm.parseUint(
                    vm.parseJsonString(
                        remoteCcip,
                        ".chainSelector"
                    )
                )
            );

            bool enabled = v.crossChainPeerEnabled(
                remoteSelector
            );

            address peer = v.crossChainPeer(
                remoteSelector
            );

            uint8 peerDecimals = v.crossChainPeerDecimals(
                remoteSelector
            );

            if (enabled) {

                assertEq(
                    peer,
                    canonical
                );

                assertEq(
                    peerDecimals,
                    uint8(decimalsUsd)
                );
            }

            console2.log(
                "| lane |",
                cfg.product,
                cfg.network,
                remotes[i]
            );

            console2.log(
                "| selector |",
                remoteSelector
            );

            console2.log(
                "| enabled |",
                enabled
            );
        }
    }
}

contract CcipLaneDiscoveryUsdcMainnetFork is CcipLaneDiscoveryForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            product: "usdc",
            network: "mainnet",
            rpc: "mainnet"
        });
    }

    function _remoteNetworks()
        internal
        pure
        override
        returns (string[] memory remotes)
    {
        remotes = new string[](2);
        remotes[0] = "base";
        remotes[1] = "arbitrum";
    }
}

contract CcipLaneDiscoveryUsdcBaseFork is CcipLaneDiscoveryForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            product: "usdc",
            network: "base",
            rpc: "base"
        });
    }

    function _remoteNetworks()
        internal
        pure
        override
        returns (string[] memory remotes)
    {
        remotes = new string[](2);
        remotes[0] = "mainnet";
        remotes[1] = "arbitrum";
    }
}

contract CcipLaneDiscoveryUsdcArbitrumFork is CcipLaneDiscoveryForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            product: "usdc",
            network: "arbitrum",
            rpc: "arbitrum"
        });
    }

    function _remoteNetworks()
        internal
        pure
        override
        returns (string[] memory remotes)
    {
        remotes = new string[](2);
        remotes[0] = "mainnet";
        remotes[1] = "base";
    }
}

contract CcipLaneDiscoveryUsdtMainnetFork is CcipLaneDiscoveryForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            product: "usdt",
            network: "mainnet",
            rpc: "mainnet"
        });
    }

    function _remoteNetworks()
        internal
        pure
        override
        returns (string[] memory remotes)
    {
        remotes = new string[](2);
        remotes[0] = "base";
        remotes[1] = "arbitrum";
    }
}

contract CcipLaneDiscoveryUsdtBaseFork is CcipLaneDiscoveryForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            product: "usdt",
            network: "base",
            rpc: "base"
        });
    }

    function _remoteNetworks()
        internal
        pure
        override
        returns (string[] memory remotes)
    {
        remotes = new string[](2);
        remotes[0] = "mainnet";
        remotes[1] = "arbitrum";
    }
}

contract CcipLaneDiscoveryUsdtArbitrumFork is CcipLaneDiscoveryForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            product: "usdt",
            network: "arbitrum",
            rpc: "arbitrum"
        });
    }

    function _remoteNetworks()
        internal
        pure
        override
        returns (string[] memory remotes)
    {
        remotes = new string[](2);
        remotes[0] = "mainnet";
        remotes[1] = "base";
    }
}

contract CcipLaneDiscoveryUsdgMainnetFork is CcipLaneDiscoveryForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            product: "usdg",
            network: "mainnet",
            rpc: "mainnet"
        });
    }

    function _remoteNetworks()
        internal
        pure
        override
        returns (string[] memory remotes)
    {
        remotes = new string[](2);
        remotes[0] = "arbitrum";
        remotes[1] = "robinhood";
    }
}

contract CcipLaneDiscoveryUsdgArbitrumFork is CcipLaneDiscoveryForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            product: "usdg",
            network: "arbitrum",
            rpc: "arbitrum"
        });
    }

    function _remoteNetworks()
        internal
        pure
        override
        returns (string[] memory remotes)
    {
        remotes = new string[](2);
        remotes[0] = "mainnet";
        remotes[1] = "robinhood";
    }
}

contract CcipLaneDiscoveryUsdgRobinhoodFork is CcipLaneDiscoveryForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            product: "usdg",
            network: "robinhood",
            rpc: "robinhood"
        });
    }

    function _remoteNetworks()
        internal
        pure
        override
        returns (string[] memory remotes)
    {
        remotes = new string[](2);
        remotes[0] = "mainnet";
        remotes[1] = "base";
    }
}
