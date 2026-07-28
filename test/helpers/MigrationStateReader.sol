// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.29;

import {ForwardVaultERC20} from "../../src/legacy/ForwardVaultERC20Legacy.sol";
import {QueContract}       from "../../src/legacy/que/QueContractLegacy.sol";

/**
 * @title MigrationStateReader
 * @dev Stateless view-only batcher deployed once per test that bundles all
 * the per-holder vault reads and per-(incentive,id) queue reads into a
 * single eth_call. Foundry's fork mode resolves the storage slots once
 * during the call; subsequent reads of the same slots are cache-hits.
 *
 * On Arbitrum where inc=0 has earliestValid≈440 plus 16 inactive incentives,
 * the un-batched version issues ~7,500 eth_calls per test against the
 * forked old QueContract; this batcher collapses that to a single RPC.
 *
 * The standard 17 incentives are baked in (matches the QueContract
 * constructor's `_initializeIncentives()`).
 */
contract MigrationStateReader {

    struct PerIncentiveState {
        int256  incentive;
        uint256 earliestValid;
        uint256 currentOrderId;
        uint256 activeOrderCount;
        bool    allowed;
    }

    struct QueMemberSlot {
        int256  incentive;
        uint256 id;
        address member;
        uint256 amount;
        uint256 tailPointer;
        uint256 headPointer;
    }

    struct QueSnapshot {
        uint256                totalActiveOrders;
        uint256                minDepositAmount;
        bool                   negativeIncentivesNotAllowed;
        PerIncentiveState[17]  perIncentive;
        QueMemberSlot[]        slots;
    }

    struct VaultHolderState {
        address holder;
        uint256 balanceOf;
        uint256 proxyBalance;
        uint256 cashedInterest;
        uint256 lastSyncTimeStamp;
        uint256 pendingInterest;
        uint256 totalInterest;
    }

    function _standardIncentives()
        internal
        pure
        returns (int256[17] memory)
    {
        return [
            int256(100), int256(200), int256(300), int256(500), int256(1000),
            int256(1500), int256(2500), int256(5000),
            int256(0),
            int256(-100), int256(-200), int256(-300), int256(-500),
            int256(-1000), int256(-1500), int256(-2500), int256(-5000)
        ];
    }

    /**
     * @dev Returns the full QueContract storage snapshot in a single call.
     *
     * For each of the 17 standard incentives:
     *   - earliestValid / currentOrderId / activeOrderCount / allowed
     *   - every slot from id=0 through id=earliestValid (inclusive of the
     *     sentinel slot whose tailPointer is set when a member next joins)
     *
     * Plus the three globals (totalActiveOrders, minDepositAmount,
     * negativeIncentivesNotAllowed).
     */
    function readQueState(
        QueContract _que
    )
        external
        view
        returns (QueSnapshot memory snapshot)
    {
        snapshot.totalActiveOrders            = _que.totalActiveOrders();
        snapshot.minDepositAmount             = _que.minDepositAmount();
        snapshot.negativeIncentivesNotAllowed = _que.negativeIncentivesNotAllowed();

        int256[17] memory incs = _standardIncentives();

        uint256 totalSlotCount;

        for (uint256 i; i < incs.length; ++i) {
            int256  inc      = incs[i];
            uint256 earliest = _que.earliestValidQueMemberByIncentive(inc);

            snapshot.perIncentive[i] = PerIncentiveState({
                incentive:        inc,
                earliestValid:    earliest,
                currentOrderId:   _que.currentOrderIdByIncentive(inc),
                activeOrderCount: _que.activeOrderCountByIncentive(inc),
                allowed:          _que.incentiveAllowed(inc)
            });

            totalSlotCount += earliest + 1;
        }

        snapshot.slots = new QueMemberSlot[](totalSlotCount);
        uint256 idx;

        for (uint256 i; i < incs.length; ++i) {
            int256  inc      = incs[i];
            uint256 earliest = snapshot.perIncentive[i].earliestValid;

            for (uint256 id; id <= earliest; ++id) {
                (
                    address member,
                    uint256 amount,
                    uint256 tailPointer,
                    uint256 headPointer
                ) = _que.QueMemberByIdAndIncentive(id, inc);

                snapshot.slots[idx++] = QueMemberSlot({
                    incentive:   inc,
                    id:          id,
                    member:      member,
                    amount:      amount,
                    tailPointer: tailPointer,
                    headPointer: headPointer
                });
            }
        }
    }

    /**
     * @dev Reads per-holder vault state in a single batched call:
     *   balanceOf, proxyBalance, cashedInterest, lastSyncTimeStamp,
     *   pendingInterest (computed view), totalInterest (computed view).
     *
     * For 91 holders this collapses 6 × 91 = 546 individual eth_calls
     * down to one.
     */
    function readVaultHolderStates(
        ForwardVaultERC20  _vault,
        address[] calldata _holders
    )
        external
        view
        returns (VaultHolderState[] memory out)
    {
        out = new VaultHolderState[](_holders.length);

        for (uint256 i; i < _holders.length; ++i) {
            address h = _holders[i];

            out[i] = VaultHolderState({
                holder:            h,
                balanceOf:         _vault.balanceOf(h),
                proxyBalance:      _vault.proxyBalance(h),
                cashedInterest:    _vault.cashedInterest(h),
                lastSyncTimeStamp: _vault.lastSyncTimeStamp(h),
                pendingInterest:   _vault.getPendingInterest(h),
                totalInterest:     _vault.getTotalInterestUser(h)
            });
        }
    }

    /**
     * @dev Convenience: reads a single uint256 from balanceOf, used to read
     * the total vault tokens held by the QueContract in one call.
     */
    function readBalanceOf(
        ForwardVaultERC20 _vault,
        address           _account
    )
        external
        view
        returns (uint256)
    {
        return _vault.balanceOf(_account);
    }
}
