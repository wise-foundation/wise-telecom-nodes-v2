// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {CohortRecorderBase} from "./CohortRecorderBase.sol";

/**
 * @dev CohortBridgeHookFacet: the cross-chain half of the cohort
 * recorder engine: the bridge-carry capture and apply plus the
 * referrer-flip migration. It lives in its OWN deployment because the
 * full engine no longer fits one EIP-170 contract; the compiler's
 * dead-code elimination gives each engine facet only the internals
 * its entrypoints reach, so the transfer-hook facet keeps the hot
 * clamp/credit/settle/move paths and this facet carries the
 * bridge-and-flip closure of the same {CohortRecorderBase} source:
 * one engine source, two compiled slices, byte-identical storage
 * layout.
 *
 * Unlike its slot-45 sibling this facet is reached through the
 * DISPATCHER routing table: the helper-chain stubs look up
 * `selectorToFacet[...]` for the three entrypoint selectors and
 * delegatecall the routed address under the same transient
 * `hookExecuting` bracket. Routing therefore shares the selector
 * timelock discipline every facet upgrade uses, and an unrouted
 * selector degrades exactly like an uninstalled hook: bridge capture
 * returns an empty payload, bridge apply reports failure (attribution
 * lost, mint unaffected), and the flip stub reverts so the registry
 * defers the migration. Although the selectors are routed, direct
 * external calls always revert; the `hookExecuting` bracket only
 * ever closes around the vault's own internal dispatch.
 *
 * All three entrypoints are `payable` for the same reason as the
 * slot-45 engine's: they execute inside `bridgeToVault` /
 * `bridgeToVaultWithReferral`, the diamond's payable functions, and a
 * delegatecall inherits the ambient `msg.value`. The bridge-apply
 * path runs inside `ccipReceive`, where a revert would strand an
 * already-burned bridge; every failure in it degrades to an anomaly
 * event, never a revert.
 */
contract CohortBridgeHookFacet is CohortRecorderBase {

    function applyCohortFlip(
        address _user,
        address _oldReferrer,
        address _newReferrer
    )
        external
        payable
        onlyDelegateCall
    {
        require(
            hookExecuting,
            NotHookExecution()
        );

        _migrateReferrerCohort(
            _user,
            _oldReferrer,
            _newReferrer
        );
    }

    function applyCohortBridgeOut(
        address _user,
        uint64 _dstChainSelector,
        uint256 _burnedAmount,
        uint256 _scaleNumerator,
        uint256 _scaleDenominator
    )
        external
        payable
        onlyDelegateCall
        returns (bytes memory)
    {
        require(
            hookExecuting,
            NotHookExecution()
        );

        return _captureBridgeOutCohort(
            _user,
            _dstChainSelector,
            _burnedAmount,
            _scaleNumerator,
            _scaleDenominator
        );
    }

    function applyCohortBridgeIn(
        address _user,
        uint64 _srcChainSelector,
        uint256 _mintedAmount,
        bytes calldata _payload
    )
        external
        payable
        onlyDelegateCall
        returns (bool)
    {
        require(
            hookExecuting,
            NotHookExecution()
        );

        return _applyBridgeInCohort(
            _user,
            _srcChainSelector,
            _mintedAmount,
            _payload
        );
    }
}
