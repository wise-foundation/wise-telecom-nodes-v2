// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "./FacetBase.sol";

/**
 * @dev Master-gated batch storage writer used only during the Phase-B
 * migration window to replicate a live v2 ForwardVaultERC20 +
 * QueContract onto this diamond. The facet is added post-deploy while
 * the diamond is still un-finalized (instant selector change), its
 * batch setters seed holder balances / interest / proxy locks and the
 * complete queue state, and its selectors are removed again before
 * `finalizeSetup` so the production diamond ships with zero migration
 * write-surface.
 *
 * Holder seeding mirrors the constructor migration precedent
 * line-for-line: `_mint` the balance, stamp `lastSyncTimeStamp` = seed
 * time, write `cashedInterest` = the old vault's total interest for
 * the holder, and keep `totalCashedInterest` in lockstep by the
 * per-address delta (so a repeated address cannot double-count).
 * Queue seeding mirrors the `QueContractMigratable` setter surface,
 * writing the identically-named diamond queue storage.
 */
contract MigrationSeedFacet is FacetBase {

    constructor()
        FacetBase()
    {}

    event HolderSeeded(
        address indexed holder,
        uint256 balance,
        uint256 cashedInterestAmount,
        uint256 proxyBalanceAmount
    );

    event QueMemberSeeded(
        uint256 indexed queMemberId,
        int256 indexed incentive,
        address indexed member,
        uint256 amount,
        uint256 tailPointer,
        uint256 headPointer
    );

    event PerIncentiveStateSeeded(
        int256 indexed incentive,
        uint256 earliestValid,
        uint256 currentOrderId,
        uint256 activeOrderCount
    );

    event QueueGlobalsSeeded(
        uint256 totalActiveOrders,
        uint256 minDepositAmount,
        bool negativeIncentivesNotAllowed
    );

    event QueTokensSeeded(
        uint256 amount
    );

    /**
     * @dev Seed a batch of holders. For each: mint `_balances[i]`
     * shares, stamp the sync timestamp to now, read the holder's
     * live total interest from the old vault IN THIS TX (exact at
     * the seed block — the same-block read is what makes
     * `getTotalInterestUser` parity hold at every later block, since
     * balance and rate match from here on), write it as
     * `cashedInterest` with a lockstep `totalCashedInterest` delta,
     * and set the proxy-locked portion. Uses raw `_mint` (no cap
     * check) so seeding a fully-migrated supply never reverts on the
     * deposit cap; the seeded `totalDepositCap` must be >= the summed
     * migrated supply, verified off-chain from the snapshot.
     */
    function seedHolders(
        address _oldVault,
        address[] calldata _holders,
        uint256[] calldata _balances,
        uint256[] calldata _proxyBalances
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        uint256 length = _holders.length;

        if (
            _balances.length != length
                || _proxyBalances.length != length
        ) {
            revert InvalidValue();
        }

        if (_oldVault.code.length == 0) {
            revert OldVaultNoCode();
        }

        for (uint256 i = 0; i < length; i++) {

            address holder = _holders[i];

            if (_balances[i] > 0) {
                _mint(
                    holder,
                    _balances[i]
                );
            }

            lastSyncTimeStamp[holder] = block.timestamp;

            uint256 migratedInterest = _readOldVaultInterest(
                _oldVault,
                holder
            );

            uint256 previousInterest = cashedInterest[holder];

            cashedInterest[holder] = migratedInterest;

            totalCashedInterest = totalCashedInterest
                + migratedInterest
                - previousInterest;

            proxyBalance[holder] = _proxyBalances[i];

            emit HolderSeeded(
                holder,
                _balances[i],
                migratedInterest,
                _proxyBalances[i]
            );
        }

        emit TotalCashedInterestChanged(
            totalCashedInterest
        );
    }

    function _readOldVaultInterest(
        address _oldVault,
        address _holder
    )
        internal
        view
        returns (uint256)
    {
        (
            bool ok,
            bytes memory returnValue
        ) = _oldVault.staticcall(
            abi.encodeWithSignature(
                "getTotalInterestUser(address)",
                _holder
            )
        );

        if (ok == false || returnValue.length != 32) {
            revert OldVaultBadResponse();
        }

        return abi.decode(
            returnValue,
            (uint256)
        );
    }

    /**
     * @dev Mint the orphaned queue-token balance so the diamond queue
     * holds exactly `balanceOf(oldQue)` shares (covers any tokens
     * transferred directly to the old QueContract on top of the sum
     * of member amounts). The diamond IS its own queue, so the mint
     * target is the diamond itself.
     */
    function seedQueTokens(
        uint256 _amount
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        if (_amount > 0) {
            _mint(
                address(this),
                _amount
            );
        }

        emit QueTokensSeeded(
            _amount
        );
    }

    /**
     * @dev Replicate a batch of queue-member slots bit-for-bit.
     * Takes the existing {QueMemberWithId} struct so the six member
     * fields travel as one calldata array (no parallel-array stack
     * pressure, no viaIR).
     */
    function seedQueMembers(
        QueMemberWithId[] calldata _members
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        for (uint256 i = 0; i < _members.length; i++) {

            QueMemberWithId calldata entry = _members[i];

            QueMemberByIdAndIncentive[entry.memberId][entry.incentive] = QueMember({
                member: entry.member,
                amount: entry.amount,
                tailPointer: entry.tailPointer,
                headPointer: entry.headPointer
            });

            emit QueMemberSeeded(
                entry.memberId,
                entry.incentive,
                entry.member,
                entry.amount,
                entry.tailPointer,
                entry.headPointer
            );
        }
    }

    /**
     * @dev Replicate the per-incentive pointers, counters and the
     * allow flag for a batch of incentive tiers.
     */
    function seedPerIncentiveState(
        int256[] calldata _incentives,
        uint256[] calldata _earliestValid,
        uint256[] calldata _currentOrderId,
        uint256[] calldata _activeOrderCount,
        bool[] calldata _allowed
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        uint256 length = _incentives.length;

        if (
            _earliestValid.length != length
                || _currentOrderId.length != length
                || _activeOrderCount.length != length
                || _allowed.length != length
        ) {
            revert InvalidValue();
        }

        for (uint256 i = 0; i < length; i++) {

            int256 incentive = _incentives[i];

            earliestValidQueMemberByIncentive[incentive] = _earliestValid[i];
            currentOrderIdByIncentive[incentive] = _currentOrderId[i];
            activeOrderCountByIncentive[incentive] = _activeOrderCount[i];
            incentiveAllowed[incentive] = _allowed[i];

            emit PerIncentiveStateSeeded(
                incentive,
                _earliestValid[i],
                _currentOrderId[i],
                _activeOrderCount[i]
            );
        }
    }

    /**
     * @dev Replicate the queue globals.
     */
    function seedQueueGlobals(
        uint256 _totalActiveOrders,
        uint256 _minDepositAmount,
        bool _negativeIncentivesNotAllowed
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        totalActiveOrders = _totalActiveOrders;
        minDepositAmount = _minDepositAmount;
        negativeIncentivesNotAllowed = _negativeIncentivesNotAllowed;

        emit QueueGlobalsSeeded(
            _totalActiveOrders,
            _minDepositAmount,
            _negativeIncentivesNotAllowed
        );
    }
}
