// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {VaultConfig} from "../vault/VaultConfig.sol";
import {ReferralRegistry} from "../../src/registry/pending/ReferralRegistry.sol";

/// @notice Wires the cross-chain referrer-sync mesh of the per-chain
/// {ReferralRegistry}: sets the chain's CCIP router (one-shot) and registers every
/// peer registry on a lane that actually exists. Run once per chain AFTER
/// `DeployReferralRegistry.deploy()` has recorded every chain's registry address in
/// `config/registry.<network>.json`; the peer table reads those files, so all four
/// registries must be deployed before any peering runs.
///
/// Lane matrix: every pair among mainnet, base and arbitrum, plus robinhood to
/// mainnet and base ONLY. NEVER register an arbitrum<->robinhood sync peer: that
/// leg stays deliberately unwired even though the CCIP routers began carrying the
/// lane in August 2026: the earliest-assignment merge converges through any
/// connected route, so the two-hop relay via mainnet or base already covers it.
///
/// Phases (chain via --rpc-url):
///   `wire()`   : setCcipRouter (skipped if already set) + propose/execute a sync peer
///                for every reachable remote registry (instant while the registry's
///                sync setup is not finalized). Idempotent: enabled peers are skipped.
///   `finalize()` : one-shot `finalizeSyncSetup()`; after this every peer change waits
///                the 3-day timelock. Run only after `status()` shows the full mesh and
///                no pending proposal. It refuses while any proposal is pending on the
///                registry (a sync peer on an expected lane, the CCIP router, the payout
///                hub, or the allowlisting of a vault recorded for this chain): a proposal
///                queued before the finalization keeps its queue time, so once that time
///                is three days old it would execute with no further wait.
///   `status()` : read-only print of router, finalized flag and per-lane peers, plus every
///                proposal with its queue time (the sync peer per lane, the CCIP router,
///                the payout hub, and the allowlisting of every vault recorded for this
///                chain).
///
/// Broadcast only after a fork rehearsal on every chain.
contract RegisterRegistrySyncPeers is VaultConfig {

    function wire()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        string memory network = _networkName();

        ReferralRegistry registry = ReferralRegistry(
            _loadRegistry(
                network
            )
        );

        require(
            address(registry).code.length > 0,
            "RegisterRegistrySyncPeers: local registry has no code"
        );

        address router = _loadCfg(
            network
        ).router;

        vm.startBroadcast(
            privKey
        );

        if (registry.ccipRouter() == address(0)) {
            registry.setCcipRouter(
                router
            );

            console2.log(
                "set registry ccip router",
                router
            );
        }

        string[] memory remotes = _remoteNetworks(
            network
        );

        for (uint256 i; i < remotes.length; ++i) {

            if (_registryConfigExists(remotes[i]) == false) {
                console2.log(
                    "skipping (no registry config)",
                    remotes[i]
                );

                continue;
            }

            address remoteRegistry = _loadRegistry(
                remotes[i]
            );

            uint64 remoteSelector = _loadCfg(
                remotes[i]
            ).chainSelector;

            if (registry.syncPeerEnabled(remoteSelector)) {
                console2.log(
                    "peer already enabled",
                    remotes[i]
                );

                continue;
            }

            registry.proposeSyncPeer(
                remoteSelector,
                remoteRegistry
            );

            registry.executeSyncPeerChange(
                remoteSelector
            );

            console2.log(
                "sync peer wired",
                remotes[i],
                remoteRegistry
            );
        }

        vm.stopBroadcast();
    }

    function finalize()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        string memory network = _networkName();

        ReferralRegistry registry = ReferralRegistry(
            _loadRegistry(
                network
            )
        );

        _assertNoPendingProposal(
            registry,
            network
        );

        vm.startBroadcast(
            privKey
        );

        registry.finalizeSyncSetup();

        vm.stopBroadcast();

        console2.log(
            "sync setup finalized; peer changes now timelocked 3 days"
        );
    }

    function status()
        external
        view
    {
        string memory network = _networkName();

        ReferralRegistry registry = ReferralRegistry(
            _loadRegistry(
                network
            )
        );

        console2.log(
            "registry",
            address(registry)
        );

        console2.log(
            "  router",
            registry.ccipRouter()
        );

        console2.log(
            "  finalized",
            registry.syncInitialized()
        );

        console2.log(
            "  local rank",
            registry.LOCAL_CHAIN_RANK()
        );

        string[] memory remotes = _remoteNetworks(
            network
        );

        for (uint256 i; i < remotes.length; ++i) {

            uint64 remoteSelector = _loadCfg(
                remotes[i]
            ).chainSelector;

            console2.log(
                "  lane",
                remotes[i]
            );

            console2.log(
                "    selector",
                remoteSelector
            );

            console2.log(
                "    peer",
                registry.syncPeer(
                    remoteSelector
                )
            );

            console2.log(
                "    enabled",
                registry.syncPeerEnabled(
                    remoteSelector
                )
            );

            console2.log(
                "    proposed peer",
                registry.proposedSyncPeer(
                    remoteSelector
                )
            );

            console2.log(
                "    peer queuedAt",
                registry.syncPeerChangeQueuedAt(
                    remoteSelector
                )
            );
        }

        console2.log(
            "  proposed router",
            registry.proposedCcipRouter()
        );

        console2.log(
            "  router queuedAt",
            registry.ccipRouterChangeQueuedAt()
        );

        console2.log(
            "  proposed payout hub",
            registry.proposedPayoutHub()
        );

        console2.log(
            "  payout hub queuedAt",
            registry.payoutHubChangeQueuedAt()
        );

        string[3] memory products = _products();

        for (uint256 i; i < products.length; ++i) {

            if (vm.exists(_vaultConfigPath(products[i], network)) == false) {
                continue;
            }

            address diamond = _loadVaultDiamond(
                products[i],
                network
            );

            console2.log(
                "  vault",
                products[i],
                diamond
            );

            console2.log(
                "    allow queuedAt",
                registry.allowedVaultQueuedAt(
                    diamond
                )
            );
        }
    }

    /// @dev Refuses the finalization while any proposal is pending on `_registry`: a sync
    /// peer on an expected lane of `_network`, the CCIP router, the payout hub, or the
    /// allowlisting of a vault recorded for `_network`. A proposal queued before the
    /// finalization keeps its queue time, so once that time is three days old it would
    /// execute with no further wait; execute or cancel it first.
    function _assertNoPendingProposal(
        ReferralRegistry _registry,
        string memory _network
    )
        internal
        view
    {
        string[] memory remotes = _remoteNetworks(
            _network
        );

        for (uint256 i; i < remotes.length; ++i) {

            uint64 remoteSelector = _loadCfg(
                remotes[i]
            ).chainSelector;

            require(
                _registry.syncPeerChangeQueuedAt(remoteSelector) == 0,
                string.concat(
                    "RegisterRegistrySyncPeers: sync peer proposal pending on lane ",
                    remotes[i]
                )
            );
        }

        require(
            _registry.ccipRouterChangeQueuedAt() == 0,
            "RegisterRegistrySyncPeers: ccip router proposal pending"
        );

        require(
            _registry.payoutHubChangeQueuedAt() == 0,
            "RegisterRegistrySyncPeers: payout hub proposal pending"
        );

        string[3] memory products = _products();

        for (uint256 i; i < products.length; ++i) {

            if (vm.exists(_vaultConfigPath(products[i], _network)) == false) {
                continue;
            }

            address diamond = _loadVaultDiamond(
                products[i],
                _network
            );

            require(
                _registry.allowedVaultQueuedAt(diamond) == 0,
                string.concat(
                    "RegisterRegistrySyncPeers: vault allowlisting proposal pending for ",
                    products[i]
                )
            );
        }
    }

    function _products()
        internal
        pure
        returns (string[3] memory)
    {
        return [
            "usdc",
            "usdt",
            "usdg"
        ];
    }

    function _remoteNetworks(
        string memory _network
    )
        internal
        pure
        returns (string[] memory remotes)
    {
        bytes32 tag = keccak256(
            bytes(_network)
        );

        if (tag == keccak256("mainnet")) {
            remotes = new string[](3);
            remotes[0] = "base";
            remotes[1] = "arbitrum";
            remotes[2] = "robinhood";
            return remotes;
        }

        if (tag == keccak256("base")) {
            remotes = new string[](3);
            remotes[0] = "mainnet";
            remotes[1] = "arbitrum";
            remotes[2] = "robinhood";
            return remotes;
        }

        if (tag == keccak256("arbitrum")) {
            remotes = new string[](2);
            remotes[0] = "mainnet";
            remotes[1] = "base";
            return remotes;
        }

        if (tag == keccak256("robinhood")) {
            remotes = new string[](2);
            remotes[0] = "mainnet";
            remotes[1] = "base";
            return remotes;
        }

        revert(
            "RegisterRegistrySyncPeers: unknown network"
        );
    }

}
