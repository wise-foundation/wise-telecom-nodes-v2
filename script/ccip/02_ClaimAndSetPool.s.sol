// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {CCIPConfig} from "./CCIPConfig.sol";
import {RegistryModuleOwnerCustom} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/TokenAdminRegistry.sol";

/// @notice Step 2: register the token's CCIP admin (via getCCIPAdmin, which BurnMintERC20 sets
/// to the deployer), accept the admin role, and link the token to its pool.
contract ClaimAndSetPool is CCIPConfig {

    function run()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        string  memory network = _networkName();
        ChainCfg memory cfg     = _loadCfg(
            network
        );

        (address token, address pool) = _loadDeployed(
            network
        );

        vm.startBroadcast(
            privKey
        );

        RegistryModuleOwnerCustom(
            cfg.registryModuleOwnerCustom
        ).registerAdminViaGetCCIPAdmin(
            token
        );

        TokenAdminRegistry(
            cfg.tokenAdminRegistry
        ).acceptAdminRole(
            token
        );

        TokenAdminRegistry(
            cfg.tokenAdminRegistry
        ).setPool(
            token,
            pool
        );

        vm.stopBroadcast();

        console2.log("network    ", network);
        console2.log("token      ", token);
        console2.log("pool linked ", pool);
    }
}
