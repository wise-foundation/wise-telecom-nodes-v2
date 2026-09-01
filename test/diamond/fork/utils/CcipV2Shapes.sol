// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

/**
 * @dev Local mirrors of the CCIP 2.0 (CCV era) surfaces the off-ramp
 * scrape shim drives, transcribed from the VERIFIED mainnet
 * deployments of OnRamp 2.0.0 (0xc3423F3FB30857D9C14717b119884b1B63d250b7)
 * and OffRamp 2.0.0 (0x408428bca0e24A25ac8baAc1b70f64AF257717c3);
 * upstream `MessageV1Codec.sol` is MIT-licensed. Field ORDER and
 * types must stay byte-identical to upstream: every struct here is
 * abi-encoded into calldata for (or decoded from events of) the live
 * contracts, and the interface selectors are derived from these
 * tuple shapes. Only the scope names are local. `MessageV1` is the
 * chain-agnostic wire message (the event carries it length-prefix
 * packed, NOT abi-encoded; the harness ports the documented wire
 * layout in `decodeCcipV2Message`); `Receipt` is the fee breakdown
 * the 2.0 `CCIPMessageSent` event appends; the verifier interface
 * exists solely so the shim can compute the selectors it mocks.
 */
library CcipV2Shapes {

    struct MessageV1 {
        uint64 sourceChainSelector;
        uint64 destChainSelector;
        uint64 messageNumber;
        uint32 executionGasLimit;
        uint32 ccipReceiveGasLimit;
        bytes4 finality;
        bytes32 ccvAndExecutorHash;
        bytes onRampAddress;
        bytes offRampAddress;
        bytes sender;
        bytes receiver;
        bytes destBlob;
        TokenTransferV1[] tokenTransfer;
        bytes data;
    }

    struct TokenTransferV1 {
        uint256 amount;
        bytes sourcePoolAddress;
        bytes sourceTokenAddress;
        bytes destTokenAddress;
        bytes tokenReceiver;
        bytes extraData;
    }

    struct Receipt {
        address issuer;
        uint32 destGasLimit;
        uint32 destBytesOverhead;
        uint256 feeTokenAmount;
        bytes extraArgs;
    }
}

interface ICcipOnRampV2Events {

    event CCIPMessageSent(
        uint64 indexed destChainSelector,
        address indexed sender,
        bytes32 indexed messageId,
        address feeToken,
        uint256 tokenAmountBeforeTokenPoolFees,
        bytes encodedMessage,
        CcipV2Shapes.Receipt[] receipts,
        bytes[] verifierBlobs
    );
}

interface ICcipOffRampV2 {

    struct SourceChainConfig {
        address router;
        bool isEnabled;
        bytes[] onRamps;
        address[] defaultCCVs;
        address[] laneMandatedCCVs;
    }

    function getSourceChainConfig(
        uint64 sourceChainSelector
    )
        external
        view
        returns (SourceChainConfig memory);

    function getCCVsForMessage(
        bytes calldata encodedMessage
    )
        external
        view
        returns (
            address[] memory requiredCCVs,
            address[] memory optionalCCVs,
            uint8 threshold
        );

    function executeSingleMessage(
        CcipV2Shapes.MessageV1 calldata message,
        bytes32 messageId,
        address[] calldata ccvs,
        bytes[] calldata verifierResults,
        uint32 gasLimitOverride
    )
        external;
}

interface ICcipCrossChainVerifierV2 {

    function getInboundImplementation(
        bytes calldata verifierResults
    )
        external
        view
        returns (address);

    function verifyMessage(
        CcipV2Shapes.MessageV1 memory message,
        bytes32 messageId,
        bytes memory verifierResults
    )
        external;
}
