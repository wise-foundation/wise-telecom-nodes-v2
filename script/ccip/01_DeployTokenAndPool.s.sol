// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {CCIPConfig} from "./CCIPConfig.sol";
import {BridgeToken} from "../../src/bridgetest/BridgeToken.sol";
import {IBurnMintERC20} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/IBurnMintERC20.sol";
import {BurnMintTokenPool} from "@chainlink/contracts-ccip/contracts/pools/BurnMintTokenPool.sol";

/// @notice Step 1: deploy the minimal BridgeToken + its BurnMintTokenPool and set the pool as
/// the token's sole mint/burn authority. Persists token + pool to config/deployed.<network>.json.
contract DeployTokenAndPool is CCIPConfig {

    string  constant TOKEN_NAME     = "Bridge Test Token";

    string  constant TOKEN_SYMBOL   = "BTT";

    uint8   constant TOKEN_DECIMALS = 18;

    uint256 constant PRE_MINT       = 1_000_000e18;

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

        vm.startBroadcast(
            privKey
        );

        BridgeToken token = new BridgeToken(
            TOKEN_NAME,
            TOKEN_SYMBOL,
            PRE_MINT
        );

        address[] memory allowlist = new address[](0);

        BurnMintTokenPool pool = new BurnMintTokenPool(
            IBurnMintERC20(address(token)),
            TOKEN_DECIMALS,
            allowlist,
            cfg.rmnProxy,
            cfg.router
        );

        token.setPool(
            address(pool)
        );

        vm.stopBroadcast();

        _saveDeployed(
            network,
            address(token),
            address(pool)
        );

        console2.log("network    ", network);
        console2.log("token      ", address(token));
        console2.log("pool       ", address(pool));
    }
}
