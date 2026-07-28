// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {CCIPConfig} from "./CCIPConfig.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";

/// @notice Step 3: wire this chain's pool to the other two chains in the mesh. Reads each
/// remote's selector (config/ccip.<remote>.json) and token+pool (config/deployed.<remote>.json).
/// Rate limits are left disabled for the test.
contract ApplyChainUpdates is CCIPConfig {

    function run()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        string memory self = _networkName();

        ( , address localPool) = _loadDeployed(
            self
        );

        string[] memory mesh = _meshNetworks();

        TokenPool.ChainUpdate[] memory adds = new TokenPool.ChainUpdate[](2);

        uint256 j;

        for (uint256 i; i < mesh.length; ++i) {

            if (
                keccak256(bytes(mesh[i])) == keccak256(bytes(self))
            ) {
                continue;
            }

            ChainCfg memory remoteCfg = _loadCfg(
                mesh[i]
            );

            (address remoteToken, address remotePool) = _loadDeployed(
                mesh[i]
            );

            bytes[] memory remotePoolAddresses = new bytes[](1);
            remotePoolAddresses[0] = abi.encode(
                remotePool
            );

            adds[j] = TokenPool.ChainUpdate({
                remoteChainSelector:       remoteCfg.chainSelector,
                remotePoolAddresses:       remotePoolAddresses,
                remoteTokenAddress:        abi.encode(remoteToken),
                outboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0}),
                inboundRateLimiterConfig:  RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0})
            });

            console2.log("wiring remote", mesh[i]);

            ++j;
        }

        uint64[] memory removes = new uint64[](0);

        vm.startBroadcast(
            privKey
        );

        TokenPool(
            localPool
        ).applyChainUpdates(
            removes,
            adds
        );

        vm.stopBroadcast();

        console2.log("network    ", self);
        console2.log("pool wired ", localPool);
    }
}
