// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {WiseTelecomNodesDiamondErrors} from "../../WiseTelecomNodesDiamondErrors.sol";
import {WiseTelecomNodesDiamondEvents} from "../../WiseTelecomNodesDiamondEvents.sol";

import {OnlyDelegateCall} from "../../../shared/DiamondErrors.sol";

/**
 * @dev ReferralPayoutFacet: the vault half of the referral payout rail.
 * `pendingReferralPayout` is the liability the hub booked and referrers
 * have not claimed; `_calculateNeededBuffer` reserves it, so a sweep never
 * takes it. The hub gated `raisePendingReferralPayout` books it and
 * `fundReferralPayout` pays USD to the hub while lowering it by the same
 * amount, never beyond it. The timelocked `payoutHub` pointer is the only
 * authorization; while it is zero both writers revert NotPayoutHub. The one
 * external call is the USD transfer to the hub, after all state writes.
 *
 * Storage mirror: only the touched slots are pinned at their diamond
 * positions (USD_TOKEN 8, pendingReferralPayout 76, payoutHub 80), checked
 * label for label by script/check_storage_layout.sh.
 */
contract ReferralPayoutFacet is
    WiseTelecomNodesDiamondErrors,
    WiseTelecomNodesDiamondEvents
{
    using SafeERC20 for IERC20;

    uint256[8] private __gap0;

    IERC20 internal USD_TOKEN;

    uint256[67] private __gap9;

    uint256 internal pendingReferralPayout;

    uint256[3] private __gap77;

    address internal payoutHub;

    address internal immutable _self;

    constructor() {
        _self = address(this);
    }

    modifier onlyDelegateCall() {
        require(
            address(this) != _self,
            OnlyDelegateCall()
        );
        _;
    }

    modifier onlyPayoutHub() {
        require(
            msg.sender == payoutHub,
            NotPayoutHub()
        );
        _;
    }

    function getPendingReferralPayout()
        external
        view
        returns (uint256)
    {
        return pendingReferralPayout;
    }

    function raisePendingReferralPayout(
        uint256 _amount
    )
        external
        onlyDelegateCall
        onlyPayoutHub
    {
        require(
            _amount > 0,
            InvalidValue()
        );

        pendingReferralPayout = pendingReferralPayout
            + _amount;

        emit PendingReferralPayoutChanged(
            pendingReferralPayout
        );
    }

    function fundReferralPayout(
        uint256 _amount
    )
        external
        onlyDelegateCall
        onlyPayoutHub
    {
        require(
            _amount > 0,
            InvalidValue()
        );

        require(
            _amount <= pendingReferralPayout,
            ExceedsPendingPayout()
        );

        pendingReferralPayout = pendingReferralPayout
            - _amount;

        USD_TOKEN.safeTransfer(
            msg.sender,
            _amount
        );

        emit PendingReferralPayoutChanged(
            pendingReferralPayout
        );
    }
}
