// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

/**
 * @dev Local view + drive surfaces the CCIP fork harness needs, kept
 * in one file so the harness and its subclasses share one declaration
 * of each. The vault surface is the minimal slice of the LIVE
 * WiseTelecomNodes diamond exercised by the bridge suites, driven
 * through the diamond's own dispatcher and fallback router; the CCIP
 * surfaces mirror the onchain Router 1.2.0 and OffRamp 1.6.0 shapes
 * the message-routing engines call into.
 */
interface ICcipBridgeVault {

    function master()
        external
        view
        returns (address);

    function USD_TOKEN()
        external
        view
        returns (address);

    function balanceOf(
        address account
    )
        external
        view
        returns (uint256);

    function totalSupply()
        external
        view
        returns (uint256);

    function depositsDisabled()
        external
        view
        returns (bool);

    function paused()
        external
        view
        returns (bool);

    function ccipRouter()
        external
        view
        returns (address);

    function crossChainPeer(
        uint64 chainSelector
    )
        external
        view
        returns (address);

    function crossChainPeerEnabled(
        uint64 chainSelector
    )
        external
        view
        returns (bool);

    function crossChainPeerDecimals(
        uint64 chainSelector
    )
        external
        view
        returns (uint8);

    function processedMessageId(
        bytes32 messageId
    )
        external
        view
        returns (bool);

    function bridgeGasLimit()
        external
        view
        returns (uint64);

    function unpauseDeposits()
        external;

    function setDepositsDisabled(
        bool disabled
    )
        external;

    function setTotalDepositCap(
        uint256 newCap
    )
        external;

    function setGraceFreezeEnabled(
        bool enabled
    )
        external;

    function setBridgeGasLimit(
        uint256 gasLimit
    )
        external;

    function proposeCrossChainPeer(
        uint64 chainSelector,
        address peer,
        uint8 peerDecimals
    )
        external;

    function executeCrossChainPeerChange(
        uint64 chainSelector
    )
        external;

    function deposit(
        uint256 amount
    )
        external;

    function bridgeToVault(
        uint64 destChainSelector,
        uint256 amount
    )
        external
        payable
        returns (
            uint256 dstAmount,
            bytes32 messageId
        );

    function bridgeToVaultWithReferral(
        uint64 destChainSelector,
        uint256 amount,
        bytes calldata referralData
    )
        external
        payable
        returns (
            uint256 dstAmount,
            bytes32 messageId
        );

    function ccipReceive(
        Client.Any2EVMMessage calldata message
    )
        external;

    function quoteBridgeFee(
        uint64 destChainSelector,
        uint256 amount
    )
        external
        view
        returns (uint256);

    function quoteBridgeFeeWithReferral(
        uint64 destChainSelector,
        uint256 amount,
        bytes calldata referralData
    )
        external
        view
        returns (uint256);
}

interface ICcipRouterView {

    function getOnRamp(
        uint64 destChainSelector
    )
        external
        view
        returns (address);

    function isChainSupported(
        uint64 chainSelector
    )
        external
        view
        returns (bool);
}

interface ICcipTypeAndVersion {

    function typeAndVersion()
        external
        view
        returns (string memory);
}

interface IUsdDecimals {

    function decimals()
        external
        view
        returns (uint8);
}
