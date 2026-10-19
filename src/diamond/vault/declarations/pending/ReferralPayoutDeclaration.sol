// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Tail shard at slot 76: `pendingReferralPayout`, the commission
 * liability the payout hub booked on this vault. It is the one liability
 * term of `_calculateNeededBuffer`, written only by the hub gated writers;
 * zero by default.
 */
abstract contract ReferralPayoutDeclaration {

    uint256 internal pendingReferralPayout;
}
