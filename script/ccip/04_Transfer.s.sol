// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {CCIPConfig} from "./CCIPConfig.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Step 4: bridge `amount` of the test token from this chain to `destChainSelector`
/// via Router.ccipSend, paying the CCIP fee in native gas (feeToken = address(0)) so no LINK
/// is required. Receiver is the broadcaster.
contract Transfer is CCIPConfig {

    function run(
        uint64  destChainSelector,
        uint256 amount
    )
        external
    {
        uint256 privKey  = vm.envUint(
            "PRIVATE_KEY"
        );

        address receiver = vm.addr(
            privKey
        );

        string  memory network = _networkName();
        ChainCfg memory cfg     = _loadCfg(
            network
        );

        (address token, ) = _loadDeployed(
            network
        );

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token:  token,
            amount: amount
        });

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver:     abi.encode(receiver),
            data:         "",
            tokenAmounts: tokenAmounts,
            feeToken:     address(0),
            extraArgs:    Client._argsToBytes(
                Client.GenericExtraArgsV2({
                    gasLimit:                 0,
                    allowOutOfOrderExecution: true
                })
            )
        });

        uint256 fee = IRouterClient(
            cfg.router
        ).getFee(
            destChainSelector,
            message
        );

        vm.startBroadcast(
            privKey
        );

        IERC20(token).approve(
            cfg.router,
            amount
        );

        bytes32 messageId = IRouterClient(
            cfg.router
        ).ccipSend{value: fee}(
            destChainSelector,
            message
        );

        vm.stopBroadcast();

        console2.log("from network ", network);
        console2.log("dest selector", destChainSelector);
        console2.log("amount       ", amount);
        console2.log("native fee   ", fee);
        console2.logBytes32(messageId);
    }
}
