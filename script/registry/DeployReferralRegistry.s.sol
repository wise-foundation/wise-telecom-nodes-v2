// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {VaultConfig} from "../vault/VaultConfig.sol";
import {ReferralRegistry} from "../../src/registry/pending/ReferralRegistry.sol";

/// @notice Deploys the per-chain {ReferralRegistry} — ONE instance per CHAIN, never
/// per vault (one shared referrer book serving every diamond on the chain).
/// This is deliberately a separate script from the per-vault upgrade round: the round runs
/// once per VAULT_PRODUCT while the registry must exist exactly once per chain, and the
/// round's `proposePointer()` reads the address this script records in
/// `config/registry.<network>.json`.
///
/// Phases (chain via --rpc-url; VAULT_PRODUCT is NOT used — all products are scanned):
///   `deploy()` — refuses to run if the chain's registry config already points at deployed
///                code (one registry per chain, ever). Broadcasts `new ReferralRegistry(master, rank)`
///                (master = broadcast key), then `setAllowedVault(diamond, true)` for every
///                product whose `config/vault.<product>.<network>.json` exists on this
///                chain, and records the address in `config/registry.<network>.json`.
///   `allow()`  — idempotent allowlist top-up for a later product on the same chain.
///   `status()` — read-only sanity print (no broadcast).
///
///   forge script script/registry/DeployReferralRegistry.s.sol --sig "deploy()" --rpc-url mainnet --broadcast
///   forge script script/registry/DeployReferralRegistry.s.sol --sig "status()" --rpc-url mainnet
/// repeated per chain (mainnet, base, arbitrum, robinhood — 4 registries total).
///
/// Plain CREATE is used; CREATE3 (same registry address on all four chains, matching the
/// diamonds' own deployment style) remains an option at broadcast time — the config file is
/// the source of truth either way. NOTHING here may be broadcast until the owner gives the
/// explicit go-ahead. After a REAL
/// broadcast is executed and verified, `git mv` the registry out of
/// src/registry/pending/ in the same
/// commit.
contract DeployReferralRegistry is VaultConfig {

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

        _allowKnownVaults(
            registry,
            network
        );

        vm.stopBroadcast();

        _saveRegistry(
            network,
            address(registry)
        );

        console2.log("deployed ReferralRegistry", address(registry));
        console2.log("  network", network);
        console2.log("  master ", registry.master());
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

        vm.startBroadcast(
            privKey
        );

        _allowKnownVaults(
            registry,
            network
        );

        vm.stopBroadcast();
    }

    function status()
        external
    {
        string memory network = _networkName();

        if (_registryConfigExists(network) == false) {
            console2.log("no registry config for network", network);
            return;
        }

        ReferralRegistry registry = ReferralRegistry(
            _loadRegistry(
                network
            )
        );

        console2.log("registry", address(registry));
        console2.log("  code size", address(registry).code.length);

        if (address(registry).code.length == 0) {
            return;
        }

        console2.log("  master", registry.master());

        string[3] memory products = _products();

        for (uint256 i; i < products.length; ++i) {

            if (vm.exists(_vaultConfigPath(products[i], network)) == false) {
                continue;
            }

            address diamond = _loadVaultDiamond(
                products[i],
                network
            );

            console2.log("  product", products[i]);
            console2.log("    diamond", diamond);
            console2.log("    allowed", registry.allowedVault(diamond));
        }
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

            _registry.setAllowedVault(
                diamond,
                true
            );

            console2.log("allowlisted vault", products[i], diamond);
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

    /// @dev The fixed per-chain tie-break rank of the cross-chain
    /// referrer sync: Ethereum mainnet wins same-second ties, then the
    /// remaining chains in a deterministic lane-centrality order. Every
    /// chain's registry must be deployed with its own rank and the set
    /// must stay collision-free forever — a new chain takes the next
    /// unused number.
    function _localChainRank(
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
            return 0;
        }

        if (tag == keccak256("base")) {
            return 1;
        }

        if (tag == keccak256("arbitrum")) {
            return 2;
        }

        if (tag == keccak256("robinhood")) {
            return 3;
        }

        revert("DeployReferralRegistry: unknown network rank");
    }
}
