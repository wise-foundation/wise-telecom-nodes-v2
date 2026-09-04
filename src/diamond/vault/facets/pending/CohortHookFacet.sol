// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {CohortRecorderBase} from "./CohortRecorderBase.sol";

/**
 * @dev CohortHookFacet: the transfer-hook slice of the cohort
 * recorder engine (its cross-chain bridge-carry and referrer-flip
 * closure lives in the dispatcher-routed {CohortBridgeHookFacet};
 * both compile from {CohortRecorderBase} and share its storage
 * layout). Installed as the `transferHookFacet` it
 * replaces {GraceFreezeHookFacet} while preserving its behavior
 * exactly: the grace-freeze check runs FIRST and may revert per
 * policy (`graceFreezeEnabled` gating, vault-escrow pass-through
 * because `address(this)` is never stamped, identical
 * `GracePeriodNotElapsed` revert); everything after it is the
 * revert-free recorder. With `cohortSyncEnabled` false this facet is
 * behaviorally identical to the grace-freeze hook, which is what
 * makes the hook swap safe to execute before arming.
 *
 * The six `applyCohort*` entrypoints are the targets of the
 * helper-chain stubs (`_cohortSync` / `_cohortCredit` /
 * `_cohortAdvance` / `_cohortMoveOut` / `_cohortMoveIn` /
 * `_cohortSettle` in {WiseTelecomNodesBaseHelper}), which reach
 * this facet through the same slot-45 pointer under the transient
 * `hookExecuting` bracket, so every hook-path and same-chain stub
 * mutation executes this one compiled slice against diamond storage,
 * while the bridge-carry and flip mutations execute the routed
 * {CohortBridgeHookFacet} slice of the same source under the same
 * bracket. The stubs gate on `cohortSyncEnabled`; `applyTransferHook`
 * gates internally because `_runTransferHook` calls it whenever the
 * hook is installed. Because that call lands BEFORE the balance
 * moves and carries no amount, `applyTransferHook` parks the
 * sender and every entrypoint here except the bounded
 * `applyCohortAdvance` drains the parked sender first (see
 * {CohortDivestDeclaration}; the advance keeps its chunked-walk
 * gas contract and stays the permissionless remedy that makes a
 * dormant parked book cheap to drain). Direct facet calls are
 * rejected by
 * `onlyDelegateCall`, non-bracketed delegatecalls by the
 * `hookExecuting` guard. The same-chain move pair
 * (`applyCohortMoveOut` / `applyCohortMoveIn`) runs only on the
 * `moveBetweenVaults` / `mintFromPeer` path (never inside the
 * transfer hook), and its registry CALLs are failure-tolerant, so
 * the move-path budget tolerates them while the hook path stays
 * external-call-free except the guarded referrer staticcall.
 *
 * All seven entrypoints are `payable`: the stubs delegatecall this
 * facet from inside `bridgeToVault` / `bridgeToVaultWithReferral`,
 * the diamond's only payable user-facing functions, and a
 * delegatecall inherits the ambient `msg.value`; a non-payable
 * target would revert on the
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

        address drained = _drainPendingDivestCohort();

        if (drained != _from) {
            _syncRefereeCohort(
                _from
            );
        }

        if (drained != _to) {
            _syncRefereeCohort(
                _to
            );
        }

        _parkDivestCohort(
            _from
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

        _syncAfterDrainCohort(
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

        _drainPendingDivestCohort();

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

    function applyCohortSettle(
        address _referrer
    )
        external
        payable
        onlyDelegateCall
    {
        require(
            hookExecuting,
            NotHookExecution()
        );

        _drainPendingDivestCohort();

        _settleBookCohort(
            _referrer
        );
    }

    function applyCohortMoveOut(
        address _user,
        address _dstVault,
        uint256 _burnedAmount,
        uint256 _scaleNumerator,
        uint256 _scaleDenominator
    )
        external
        payable
        onlyDelegateCall
    {
        require(
            hookExecuting,
            NotHookExecution()
        );

        _drainPendingDivestCohort();

        _captureMoveOutCohort(
            _user,
            _dstVault,
            _burnedAmount,
            _scaleNumerator,
            _scaleDenominator
        );
    }

    function applyCohortMoveIn(
        address _user,
        address _srcVault
    )
        external
        payable
        onlyDelegateCall
    {
        require(
            hookExecuting,
            NotHookExecution()
        );

        _drainPendingDivestCohort();

        _applyMoveInCohort(
            _user,
            _srcVault
        );
    }
}
