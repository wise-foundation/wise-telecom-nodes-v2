// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {VerifyProbe} from "../../src/bridgetest/VerifyProbe.sol";

contract DeployVerifyProbe is Script {

    uint256 constant VERSION = 1;

    function run()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        vm.startBroadcast(
            privKey
        );

        VerifyProbe probe = new VerifyProbe(
            VERSION
        );

        vm.stopBroadcast();

        console2.log("chainid", block.chainid);
        console2.log("probe  ", address(probe));
    }
}
