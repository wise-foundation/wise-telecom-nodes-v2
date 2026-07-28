// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import {Script} from "forge-std/Script.sol";

/// @notice SUPERSEDED — this script deployed the diamond with plain CREATE, which yields a
/// different address on every chain. Production deploys now go through
/// {DeployVaultDeterministic} (CreateX CREATE3 via {WiseTelecomNodesBootstrap}) so the diamond
/// lands at the canonical cross-chain address recorded in config/vault_mesh.<product>.json.
/// This stub reverts on purpose so a stale runbook cannot broadcast a non-canonical deploy.
contract DeployVaultMainnet is Script {

    function run()
        external
        pure
    {
        revert(
            "DeployVaultMainnet is superseded: use DeployVaultDeterministic (see script/vault/ADD_A_CHAIN.md)"
        );
    }
}
