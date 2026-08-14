// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {CohortRecorderBase} from "./CohortRecorderBase.sol";

/**
 * @dev CohortHookFacet — the single deployment of the cohort recorder
 * engine (ruling R17). Installed as the `transferHookFacet` it
 * replaces {GraceFreezeHookFacet} while preserving its behavior
 * exactly: the grace-freeze check runs FIRST and may revert per
 * policy (`graceFreezeEnabled` gating, vault-escrow pass-through
 * because `address(this)` is never stamped, identical
 * `GracePeriodNotElapsed` revert); everything after it is the
 * revert-free recorder. With `cohortSyncEnabled` false this facet is
 * behaviorally identical to the grace-freeze hook, which is what
 * makes the hook swap safe to execute before arming.
 *
 * The three `applyCohort*` entrypoints are the targets of the
 * helper-chain stubs (`_cohortSync` / `_cohortCredit` /
 * `_cohortAdvance` in {WiseTelecomNodesBaseHelper}), which reach this
 * facet through the same slot-45 pointer under the transient
 * `hookExecuting` bracket — so every recorder mutation, hook-driven
 * or stub-driven, executes this one compiled engine against diamond
 * storage. The stubs gate on `cohortSyncEnabled`; `applyTransferHook`
 * gates internally because `_runTransferHook` calls it whenever the
 * hook is installed. Direct facet calls are rejected by
 * `onlyDelegateCall`, non-bracketed delegatecalls by the
 * `hookExecuting` guard.
 *
 * All four entrypoints are `payable`: the stubs delegatecall this
 * facet from inside `bridgeToVault` / `bridgeToVaultWithReferral`,
 * the diamond's only payable functions, and a delegatecall inherits
 * the ambient `msg.value` — a non-payable target would revert on the
 * compiler's callvalue guard and DoS bridging out on every lane with
 * a nonzero CCIP fee. No ETH ever moves: under DELEGATECALL the value
 * stays with the diamond.
 */
contract CohortHookFacet is CohortRecorderBase {

    function applyTransferHook(
        address _from,
        address _to
    )
        external
        payable
        onlyDelegateCall
    {
        require(
            hookExecuting,
            NotHookExecution()
        );

        if (graceFreezeEnabled == true) {
            _checkGracePeriod(
                _from
            );
        }

        if (cohortSyncEnabled == false) {
            return;
        }

        _syncRefereeCohort(
            _from
        );

        _syncRefereeCohort(
            _to
        );
    }

    function applyCohortSync(
        address _user
    )
        external
        payable
        onlyDelegateCall
    {
        require(
            hookExecuting,
            NotHookExecution()
        );

        _syncRefereeCohort(
            _user
        );
    }

    function applyCohortCredit(
        address _user,
        uint256 _amount
    )
        external
        payable
        onlyDelegateCall
    {
        require(
            hookExecuting,
            NotHookExecution()
        );

        _creditContributionCohort(
            _user,
            _amount
        );
    }

    function applyCohortAdvance(
        address _referrer,
        uint256 _maxBoundaries
    )
        external
        payable
        onlyDelegateCall
    {
        require(
            hookExecuting,
            NotHookExecution()
        );

        _advanceBookCohort(
            _referrer,
            _maxBoundaries
        );
    }
}
