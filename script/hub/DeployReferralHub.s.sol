// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {VaultConfig} from "../vault/VaultConfig.sol";
import {ReferralHub} from "../../src/hub/pending/ReferralHub.sol";

/// @notice Deploys the mainnet {ReferralHub}: ONE standalone instance on the hub chain,
/// never per vault. Separate from the per-vault payout upgrade round for the same reason
/// the registry deploy is: the round runs once per VAULT_PRODUCT while the hub exists
/// exactly once, and the round's `proposeHub()` reads the address this script records in
/// `config/hub.<network>.json`. The hub's USD token is a constructor immutable and MUST be
/// the payout vault's own underlying; the vault-side pointer execute shape-probes exactly
/// that, so a hub deployed against the wrong token can never be wired.
///
/// Phases (chain via --rpc-url; the payout vault is always the usdc product):
///   `deploy()` : refuses to run if the chain's hub config already points at deployed code.
///                Broadcasts `new ReferralHub(usd)` (master = broadcast key, usd from
///                `config/vault.usdc.<network>.json`) and records the address in
///                `config/hub.<network>.json`.
///   `wire()`   : hub-side master op, AFTER the vault-side pointer round executed:
///                `setPayoutVault(usdc diamond)` so deliveries book liability and claims
///                can pull funding. Idempotent.
///   `wireFlush()` : hub-side master op for the flush transport, AFTER the per-vault
///                cohort-flush rounds executed: sets the CCIP router (once), allowlists
///                every hub-chain vault as a local reporter, and registers every spoke
///                vault as a flush source and every spoke registry as a designation
///                source under its (chain selector, sender, chain id) triple, all read
///                from the committed config files. Fully idempotent and skip-tolerant:
///                a spoke whose vault or registry config does not exist yet is logged
///                and skipped, and re-running after it lands wires just the remainder.
///   `status()` : read-only sanity print (no broadcast).
///
///   forge script script/hub/DeployReferralHub.s.sol --sig "deploy()" --rpc-url mainnet --broadcast
///   forge script script/hub/DeployReferralHub.s.sol --sig "wireFlush()" --rpc-url mainnet --broadcast
///   forge script script/hub/DeployReferralHub.s.sol --sig "status()" --rpc-url mainnet
///
/// NOTHING here may be broadcast until the owner gives the explicit go-ahead. After a REAL
/// broadcast is executed and verified, `git mv` the hub chain out of src/hub/pending/ in
/// the same commit.
contract DeployReferralHub is VaultConfig {

    function deploy()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        string memory network = _networkName();

        if (_hubConfigExists(network)) {

            address recorded = _loadHub(
                network
            );

            require(
                recorded.code.length == 0,
                "DeployReferralHub: hub already deployed on this chain"
            );
        }

        address usd = _loadVaultUsd(
            "usdc",
            network
        );

        vm.startBroadcast(
            privKey
        );

        ReferralHub hub = new ReferralHub(
            usd
        );

        vm.stopBroadcast();

        _saveHub(
            network,
            address(hub)
        );

        console2.log("deployed ReferralHub", address(hub));
        console2.log("  network", network);
        console2.log("  usd    ", usd);
        console2.log("  master ", hub.master());
    }

    function wire()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        string memory network = _networkName();

        ReferralHub hub = ReferralHub(
            _loadHub(
                network
            )
        );

        require(
            address(hub).code.length > 0,
            "DeployReferralHub: recorded hub has no code"
        );

        address diamond = _loadVaultDiamond(
            "usdc",
            network
        );

        if (hub.payoutVault() == diamond) {
            console2.log("payout vault already wired", diamond);
            return;
        }

        vm.startBroadcast(
            privKey
        );

        hub.setPayoutVault(
            diamond
        );

        vm.stopBroadcast();

        console2.log("payout vault wired on hub", address(hub));
        console2.log("  vault", diamond);
    }

    function wireFlush()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        string memory network = _networkName();

        ReferralHub hub = ReferralHub(
            _loadHub(
                network
            )
        );

        require(
            address(hub).code.length > 0,
            "DeployReferralHub: recorded hub has no code"
        );

        vm.startBroadcast(
            privKey
        );

        _wireRouter(
            hub,
            network
        );

        _wireLocalReporters(
            hub,
            network
        );

        _wireSpokeNetwork(hub, "base");
        _wireSpokeNetwork(hub, "arbitrum");
        _wireSpokeNetwork(hub, "robinhood");

        vm.stopBroadcast();

        console2.log("flush wiring complete on hub", address(hub));
    }

    function status()
        external
    {
        string memory network = _networkName();

        if (_hubConfigExists(network) == false) {
            console2.log("no hub config for network", network);
            return;
        }

        ReferralHub hub = ReferralHub(
            _loadHub(
                network
            )
        );

        console2.log("hub", address(hub));
        console2.log("  code size", address(hub).code.length);

        if (address(hub).code.length == 0) {
            return;
        }

        console2.log("  master     ", hub.master());
        console2.log("  usd        ", address(hub.USD_TOKEN()));
        console2.log("  payoutVault", hub.payoutVault());
        console2.log("  totalAccrued", hub.totalAccrued());
        console2.log("  totalClaimed", hub.totalClaimed());
        console2.log("  totalBooked ", hub.totalBooked());
        console2.log("  ccipRouter  ", hub.ccipRouter());
        console2.log("  botShareBps ", hub.botShareBps());
    }

    function _wireRouter(
        ReferralHub _hub,
        string memory _network
    )
        internal
    {
        if (_hub.ccipRouter() != address(0)) {
            return;
        }

        _hub.setCcipRouter(
            _loadCcipRouter(
                _network
            )
        );

        console2.log("  router set", _hub.ccipRouter());
    }

    function _wireLocalReporters(
        ReferralHub _hub,
        string memory _network
    )
        internal
    {
        string[] memory products = _flushProductsOf(
            _network
        );

        for (uint256 i; i < products.length; ++i) {

            if (vm.exists(_vaultConfigPath(products[i], _network)) == false) {
                console2.log("  skipping local reporter, no vault config:", products[i]);
                continue;
            }

            address vault = _loadVaultDiamond(
                products[i],
                _network
            );

            if (_hub.allowedReporter(vault)) {
                continue;
            }

            _hub.setAllowedReporter(
                vault,
                true
            );

            console2.log("  local reporter allowed", vault);
        }
    }

    function _wireSpokeNetwork(
        ReferralHub _hub,
        string memory _spoke
    )
        internal
    {
        uint64 chainSelector = _loadCcipChainSelector(
            _spoke
        );

        uint256 chainId = _flushChainIdOf(
            _spoke
        );

        string[] memory products = _flushProductsOf(
            _spoke
        );

        for (uint256 i; i < products.length; ++i) {

            if (vm.exists(_vaultConfigPath(products[i], _spoke)) == false) {
                console2.log("  skipping flush source, no vault config:", _spoke, products[i]);
                continue;
            }

            address vault = _loadVaultDiamond(
                products[i],
                _spoke
            );

            if (_hub.flushSourceChainId(chainSelector, vault) != chainId) {

                _hub.setFlushSource(
                    chainSelector,
                    vault,
                    chainId
                );

                console2.log("  flush source set", _spoke, vault);
            }
        }

        if (_registryConfigExists(_spoke) == false) {
            console2.log("  skipping designation source, no registry config:", _spoke);
            return;
        }

        address registry = _loadRegistry(
            _spoke
        );

        if (_hub.designationSourceChainId(chainSelector, registry) != chainId) {

            _hub.setDesignationSource(
                chainSelector,
                registry,
                chainId
            );

            console2.log("  designation source set", _spoke, registry);
        }
    }

    function _flushProductsOf(
        string memory _network
    )
        internal
        pure
        returns (string[] memory products)
    {
        if (_sameString(_network, "base")) {
            products = new string[](2);
            products[0] = "usdc";
            products[1] = "usdt";
            return products;
        }

        if (_sameString(_network, "robinhood")) {
            products = new string[](1);
            products[0] = "usdg";
            return products;
        }

        products = new string[](3);
        products[0] = "usdc";
        products[1] = "usdt";
        products[2] = "usdg";
    }

    function _flushChainIdOf(
        string memory _network
    )
        internal
        pure
        returns (uint256)
    {
        if (_sameString(_network, "base")) {
            return 8453;
        }

        if (_sameString(_network, "arbitrum")) {
            return 42161;
        }

        if (_sameString(_network, "robinhood")) {
            return 4663;
        }

        revert(
            "DeployReferralHub: unknown spoke network"
        );
    }
}
