// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {VaultConfig} from "./VaultConfig.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";

/// @notice Bridges `amount` vault shares like {BridgeVault} but through the referral-bytes
/// channel: `referralData` rides in the CCIP payload (capped at MAX_REFERRAL_BYTES = 256).
/// With `referralEnabled` off (the launch default) the destination decodes, carries and
/// ignores the bytes — mint and cap relocation identical to the plain path, `BridgeReceived`
/// emitted, `BridgeReferral` NOT emitted. Smoke both an empty payload (0x) and random noise
/// to prove the channel is inert. Track the returned messageId on https://ccip.chain.link.
contract BridgeVaultReferral is VaultConfig {

    function run(
        uint64  destChainSelector,
        uint256 amount,
        bytes calldata referralData
    )
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        (
            address diamond,
        ) = _loadVault(
            _networkName()
        );

        uint256 fee = BridgeFacet(address(diamond)).quoteBridgeFeeWithReferral(
            destChainSelector,
            amount,
            referralData
        );

        vm.startBroadcast(
            privKey
        );

        (
            uint256 dstAmount,
            bytes32 messageId
        ) = BridgeFacet(address(diamond)).bridgeToVaultWithReferral{value: fee}(
            destChainSelector,
            amount,
            referralData
        );

        vm.stopBroadcast();

        console2.log("dest selector ", destChainSelector);
        console2.log("src amount    ", amount);
        console2.log("dst amount    ", dstAmount);
        console2.log("native fee    ", fee);
        console2.log("referral bytes", referralData.length);
        console2.logBytes(referralData);
        console2.logBytes32(messageId);
    }
}
