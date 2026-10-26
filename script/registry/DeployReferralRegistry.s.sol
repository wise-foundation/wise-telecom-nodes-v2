// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {VaultConfig} from "../vault/VaultConfig.sol";
import {ReferralRegistry} from "../../src/registry/pending/ReferralRegistry.sol";

/// @notice Deploys the per-chain {ReferralRegistry}: ONE instance per CHAIN, never
/// per vault (one shared referrer book serving every diamond on the chain).
/// This is deliberately a separate script from the per-vault upgrade round: the round runs
/// once per VAULT_PRODUCT while the registry must exist exactly once per chain, and the
/// round's `proposePointer()` reads the address this script records in
/// `config/registry.<network>.json`.
///
/// Phases (chain via --rpc-url; only `allow()` reads VAULT_PRODUCT, `deploy()` scans all products):
///   `deploy()` : refuses to run if the chain's registry config already points at deployed
///                code (one registry per chain, ever). Broadcasts `new ReferralRegistry(master, rank)`
///                (master = broadcast key), then `setAllowedVault(diamond, true)` for every
///                product whose `config/vault.<product>.<network>.json` exists on this
///                chain (refusing a config address without code, so a phantom address can
///                never take one of the permanent tracked slots), and records the address in
///                `config/registry.<network>.json` (written only by a `--broadcast` run; a
///                simulation logs the address it would have recorded and leaves the file
///                untouched). The registry's sync key floor is a
///                compile-time constant every chain shares, and `deploy()` refuses a chain
///                whose clock sits below it, so every key it mints sorts above every
///                corrected key. The registry's merge refuses any sync key whose chain rank
///                sits above `maxSyncRank` (three at construction, the four-chain mesh); when
///                a fifth chain joins, master raises it on every existing registry with
///                `raiseMaxSyncRank` before the new peer is wired, or the new chain's keys
///                are refused.
///   `allow()`  : idempotent allowlist top-up for ONE later product on the same chain, named
///                through VAULT_PRODUCT (its diamond must have code). Instant while the sync
///                setup is unfinalized or for a diamond the registry ever allowed before;
///                once the sync setup is finalized, a new diamond takes the registry's 3-day
///                propose and execute lane (`proposeAllowedVault`, then
///                `executeAllowedVaultChange`): run it twice, three days apart.
///   `wirePayoutRoute()` : SPOKE chains only: points the registry's caller-paid
///                `pushPayoutAddress` at the mainnet hub (`proposePayoutHub(hub,
///                mainnetSelector)` + `executePayoutHubChange`; instant while the sync
///                setup is unfinalized, a second run after the 3-day window otherwise),
///                reading the hub from `config/hub.mainnet.json`. It executes only a
///                proposal that names exactly that (hub, selector) pair: a pending
///                proposal naming anything else is logged and overwritten by a fresh
///                one, which restarts the 3-day window once the sync setup is
///                finalized, and the wired route is asserted right after the execute.
///                With the route already wired, a mismatched pending proposal is logged
///                and cancelled. On the hub chain the
///                route deliberately stays detached: referrers there designate at the
///                hub directly. Requires `setCcipRouter` to have been run as part of the
///                sync wiring (the push shares the sync gas limit and router).
///   `latch()`   : fires the registry's ONE-WAY seed latch `latchSeeds` (idempotent: skips
///                when already latched), which ends the vaults' retroactive seed. It never
///                fires `latchCorrections`: the correction lane stays open after payouts arm,
///                guarded by the user veto, and closing it is a manual master call outside
///                every script. Runbook: run on EVERY chain's registry before payouts arm at
///                the hub; there is no unlatch, on purpose.
///   `status()` : read-only sanity print (no broadcast). It reverts while the registry's
///                `maxSyncRank` sits below the rank of any network in `_rankedNetworks()`
///                whose `config/registry.<network>.json` is recorded, so no registry is
///                peered with a chain whose keys it would refuse: run it on every existing
///                chain before `RegisterRegistrySyncPeers.wire()` proposes a new chain's peer.
///
///   forge script script/registry/DeployReferralRegistry.s.sol --sig "deploy()" --rpc-url mainnet --broadcast
///   forge script script/registry/DeployReferralRegistry.s.sol --sig "status()" --rpc-url mainnet
/// repeated per chain (mainnet, base, arbitrum, robinhood; 4 registries total).
///
/// Plain CREATE is used; CREATE3 (same registry address on all four chains, matching the
/// diamonds' own deployment style) remains an option at broadcast time; the config file is
/// the source of truth either way. Broadcast only after a fork rehearsal on every chain.
/// After a real broadcast is executed and verified, `git mv` the registry out of
/// src/registry/pending/ in the same commit.
contract DeployReferralRegistry is VaultConfig {

    uint256 internal constant SYNC_KEY_FLOOR = 1_700_000_000;

    function deploy()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        string memory network = _networkName();

        if (_registryConfigExists(network)) {

            address recorded = _loadRegistry(
                network
            );

            require(
                recorded.code.length == 0,
                "DeployReferralRegistry: registry already deployed on this chain"
            );
        }

        _requireDeployerIsVaultMaster(
            privKey,
            network
        );

        vm.startBroadcast(
            privKey
        );

        ReferralRegistry registry = new ReferralRegistry(
            vm.addr(
                privKey
            ),
            _localChainRank(
                network
            )
        );

        require(
            block.timestamp >= SYNC_KEY_FLOOR,
            "DeployReferralRegistry: chain clock below the sync key floor"
        );

        _allowKnownVaults(
            registry,
            network
        );

        vm.stopBroadcast();

        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            _saveRegistry(
                network,
                address(registry)
            );
        } else {
            console2.log(
                "simulation only: config/registry not written, it would record",
                address(registry)
            );
        }

        console2.log(
            "deployed ReferralRegistry",
            address(registry)
        );

        console2.log(
            "  network",
            network
        );

        console2.log(
            "  master ",
            registry.master()
        );
    }

    function allow()
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
            "DeployReferralRegistry: recorded registry has no code"
        );

        string memory product = vm.envString(
            "VAULT_PRODUCT"
        );

        require(
            vm.exists(
                _vaultConfigPath(
                    product,
                    network
                )
            ),
            "DeployReferralRegistry: no vault config for VAULT_PRODUCT on this chain"
        );

        address diamond = _loadVaultDiamond(
            product,
            network
        );

        require(
            diamond.code.length > 0,
            "DeployReferralRegistry: VAULT_PRODUCT diamond has no code on this chain"
        );

        if (registry.allowedVault(diamond)) {
            console2.log(
                "already allowed",
                product,
                diamond
            );

            return;
        }

        if (
            registry.syncInitialized() == false
                || registry.everAllowedVault(diamond)
        ) {
            vm.startBroadcast(
                privKey
            );

            registry.setAllowedVault(
                diamond,
                true
            );

            vm.stopBroadcast();

            console2.log(
                "allowlisted vault",
                product,
                diamond
            );

            return;
        }

        uint256 queuedAt = registry.allowedVaultQueuedAt(
            diamond
        );

        if (queuedAt == 0) {
            vm.startBroadcast(
                privKey
            );

            registry.proposeAllowedVault(
                diamond
            );

            vm.stopBroadcast();

            console2.log(
                "allowlisting proposed; re-run allow() after the 3-day window",
                product,
                diamond
            );

            return;
        }

        if (block.timestamp >= queuedAt + 3 days) {
            vm.startBroadcast(
                privKey
            );

            registry.executeAllowedVaultChange(
                diamond
            );

            vm.stopBroadcast();

            console2.log(
                "allowlisting executed",
                product,
                diamond
            );

            return;
        }

        console2.log(
            "allowlisting still timelocked; seconds remaining",
            queuedAt + 3 days - block.timestamp
        );
    }

    function wirePayoutRoute()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        string memory network = _networkName();

        require(
            _sameString(network, "mainnet") == false,
            "DeployReferralRegistry: the hub chain's registry keeps its payout route detached"
        );

        ReferralRegistry registry = ReferralRegistry(
            _loadRegistry(
                network
            )
        );

        require(
            address(registry).code.length > 0,
            "DeployReferralRegistry: recorded registry has no code"
        );

        address hub = _loadHub(
            "mainnet"
        );

        uint64 chainSelector = _loadCcipChainSelector(
            "mainnet"
        );

        _wirePayoutRoute(
            registry,
            hub,
            chainSelector,
            privKey
        );
    }

    function latch()
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
            "DeployReferralRegistry: recorded registry has no code"
        );

        if (registry.seedsLatched()) {
            console2.log(
                "seeds already latched on registry",
                address(registry)
            );

            return;
        }

        require(
            keccak256(bytes(vm.envOr("LATCH_CONFIRM", string("")))) == keccak256(bytes(network)),
            "DeployReferralRegistry: set LATCH_CONFIRM=<this network> to latch the seeds for good (there is no unlatch)"
        );

        _assertRecordedVaultsArmed(
            network
        );

        vm.startBroadcast(
            privKey
        );

        registry.latchSeeds();

        vm.stopBroadcast();

        console2.log(
            "seeds latched on registry",
            address(registry)
        );
    }

    function status()
        external
    {
        string memory network = _networkName();

        if (_registryConfigExists(network) == false) {
            console2.log(
                "no registry config for network",
                network
            );

            return;
        }

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
            "  code size",
            address(registry).code.length
        );

        if (address(registry).code.length == 0) {
            return;
        }

        console2.log(
            "  master",
            registry.master()
        );

        console2.log(
            "  seedsLatched",
            registry.seedsLatched()
        );

        console2.log(
            "  correctionsLatched",
            registry.correctionsLatched()
        );

        console2.log(
            "  syncKeyFloor",
            SYNC_KEY_FLOOR
        );

        console2.log(
            "  maxSyncRank",
            registry.maxSyncRank()
        );

        console2.log(
            "  trackedVaultCount",
            registry.trackedVaultCount()
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
                "  product",
                products[i]
            );

            console2.log(
                "    diamond",
                diamond
            );

            console2.log(
                "    allowed",
                registry.allowedVault(
                    diamond
                )
            );
        }

        string[] memory networks = _rankedNetworks();

        for (uint256 i; i < networks.length; ++i) {

            if (_registryConfigExists(networks[i]) == false) {
                continue;
            }

            require(
                registry.maxSyncRank() >= i,
                "DeployReferralRegistry: maxSyncRank below a recorded chain's rank (raiseMaxSyncRank before peering)"
            );
        }
    }

    /// @dev The decision logic of `wirePayoutRoute()`, with the registry, the hub, the chain
    /// selector and the broadcast key passed in, so a rehearsal drives the very code the
    /// script broadcasts without a PRIVATE_KEY variable or a config file. Only a proposal
    /// naming exactly (`_hub`, `_chainSelector`) is ever executed; any other pending
    /// proposal is logged and overwritten, or cancelled once the route is wired.
    function _wirePayoutRoute(
        ReferralRegistry _registry,
        address _hub,
        uint64 _chainSelector,
        uint256 _privKey
    )
        internal
    {
        bool pending = _registry.payoutHubChangeQueuedAt() > 0;

        bool pendingMatches = pending
            && _registry.proposedPayoutHub() == _hub
            && _registry.proposedPayoutHubChainSelector() == _chainSelector;

        if (
            _registry.payoutHub() == _hub
                && _registry.payoutHubChainSelector() == _chainSelector
        ) {
            console2.log(
                "payout route already wired",
                _hub
            );

            if (pending && pendingMatches == false) {
                console2.log(
                    "cancelling mismatched pending payout hub proposal",
                    _registry.proposedPayoutHub()
                );

                console2.log(
                    "  proposed chainSelector",
                    uint256(_registry.proposedPayoutHubChainSelector())
                );

                vm.startBroadcast(
                    _privKey
                );

                _registry.cancelPayoutHubChange();

                vm.stopBroadcast();
            }

            return;
        }

        require(
            _registry.ccipRouter() != address(0),
            "DeployReferralRegistry: sync router not set (run RegisterRegistrySyncPeers.wire() first)"
        );

        vm.startBroadcast(
            _privKey
        );

        if (pendingMatches == false) {

            if (pending) {
                console2.log(
                    "overwriting mismatched pending payout hub proposal",
                    _registry.proposedPayoutHub()
                );

                console2.log(
                    "  proposed chainSelector",
                    uint256(_registry.proposedPayoutHubChainSelector())
                );
            }

            _registry.proposePayoutHub(
                _hub,
                _chainSelector
            );
        }

        uint256 queuedAt = _registry.payoutHubChangeQueuedAt();

        if (
            _registry.syncInitialized() == false
                || block.timestamp >= queuedAt + 3 days
        ) {
            _registry.executePayoutHubChange();

            require(
                _registry.payoutHub() == _hub
                    && _registry.payoutHubChainSelector() == _chainSelector,
                "DeployReferralRegistry: executed payout route does not match the config hub"
            );

            console2.log(
                "payout route wired on registry",
                address(_registry)
            );
        } else {
            console2.log(
                "payout route proposed; re-run wirePayoutRoute() after the 3-day window, seconds remaining",
                queuedAt + 3 days - block.timestamp
            );
        }

        vm.stopBroadcast();

        console2.log(
            "  hub          ",
            _hub
        );

        console2.log(
            "  chainSelector",
            uint256(_chainSelector)
        );
    }

    function _allowKnownVaults(
        ReferralRegistry _registry,
        string memory _network
    )
        internal
    {
        string[3] memory products = _products();

        for (uint256 i; i < products.length; ++i) {

            if (vm.exists(_vaultConfigPath(products[i], _network)) == false) {
                continue;
            }

            address diamond = _loadVaultDiamond(
                products[i],
                _network
            );

            if (_registry.allowedVault(diamond)) {
                continue;
            }

            require(
                diamond.code.length > 0,
                "DeployReferralRegistry: vault config names an address without code"
            );

            _registry.setAllowedVault(
                diamond,
                true
            );

            console2.log(
                "allowlisted vault",
                products[i],
                diamond
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

    /// @dev Every network of the registry mesh in rank order: a network's index is its fixed
    /// sync tie-break rank, so a new chain is appended here and takes the next unused number.
    /// `_localChainRank` and the `status()` rank check both read this one list.
    function _rankedNetworks()
        internal
        pure
        returns (string[] memory networks)
    {
        networks = new string[](4);
        networks[0] = "mainnet";
        networks[1] = "base";
        networks[2] = "arbitrum";
        networks[3] = "robinhood";
    }

    /// @dev The fixed per-chain tie-break rank of the cross-chain
    /// referrer sync: Ethereum mainnet wins same-second ties, then the
    /// remaining chains in a deterministic lane-centrality order. Every
    /// chain's registry must be deployed with its own rank and the set
    /// must stay collision-free forever; a new chain takes the next
    /// unused number. The rank is the network's index in `_rankedNetworks()`.
    function _localChainRank(
        string memory _network
    )
        internal
        pure
        returns (uint256)
    {
        string[] memory networks = _rankedNetworks();

        for (uint256 i; i < networks.length; ++i) {

            if (_sameString(networks[i], _network)) {
                return i;
            }
        }

        revert(
            "DeployReferralRegistry: unknown network rank"
        );
    }

    function _requireDeployerIsVaultMaster(
        uint256 _privKey,
        string memory _network
    )
        internal
        view
    {
        string[3] memory products = _products();

        for (uint256 i; i < products.length; ++i) {
            if (vm.exists(_vaultConfigPath(products[i], _network)) == false) {
                continue;
            }

            address vault = _loadVaultDiamond(
                products[i],
                _network
            );

            (
                bool ok,
                bytes memory answer
            ) = vault.staticcall(
                abi.encodeWithSignature(
                    "master()"
                )
            );

            require(
                ok && answer.length == 32 && abi.decode(answer, (address)) == vm.addr(_privKey),
                "DeployReferralRegistry: PRIVATE_KEY is not the master of this chain's vaults (the deploy key must be the mesh deployer)"
            );

            return;
        }

        revert("DeployReferralRegistry: no vault record on this chain to check the deploy key against");
    }

    function _assertRecordedVaultsArmed(
        string memory _network
    )
        internal
        view
    {
        string[3] memory products = _products();

        for (uint256 i; i < products.length; ++i) {
            if (vm.exists(_vaultConfigPath(products[i], _network)) == false) {
                continue;
            }

            address vault = _loadVaultDiamond(
                products[i],
                _network
            );

            if (vault.code.length == 0) {
                continue;
            }

            (
                bool ok,
                bytes memory answer
            ) = vault.staticcall(
                abi.encodeWithSignature(
                    "getCohortSyncEnabled()"
                )
            );

            require(
                ok && answer.length == 32 && abi.decode(answer, (bool)),
                string.concat(
                    "DeployReferralRegistry: the ",
                    products[i],
                    " vault of this chain is not armed (seeds are placed only on armed vaults; latch after every planned seed)"
                )
            );
        }
    }
}
