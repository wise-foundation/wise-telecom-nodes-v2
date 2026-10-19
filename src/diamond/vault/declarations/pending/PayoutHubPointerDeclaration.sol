// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Tail shard at slots 80 to 82: the payout hub pointer and its
 * timelocked change. The pointer is the only authorization of the hub
 * gated writers, never an allowance; a zero pointer, the virgin default,
 * reverts NotPayoutHub.
 */
abstract contract PayoutHubPointerDeclaration {

    address internal payoutHub;

    address internal proposedPayoutHub;

    uint256 internal payoutHubChangeQueuedAt;

    uint256 internal constant PAYOUT_HUB_CHANGE_DELAY = 3 days;
}
