// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {WiseTelecomNodesDiamondErrors} from "../../WiseTelecomNodesDiamondErrors.sol";
import {WiseTelecomNodesDiamondEvents} from "../../WiseTelecomNodesDiamondEvents.sol";

import {OnlyDelegateCall} from "../../../shared/DiamondErrors.sol";

/**
 * @dev Vault half of the referral payout rail. The one global
 * `pendingReferralPayout` accumulator is the USD liability the
 * mainnet hub's priced verdicts have awarded against this vault but
 * referrers have not yet claimed; `_calculateNeededBuffer` reserves
 * it so the sweeper-gated `sweepOverhang` can never take cash that
 * backs pending payouts. Three surfaces: the routed
 * `getPendingReferralPayout()` view, the hub-gated
 * `raisePendingReferralPayout` booking writer (the hub sums each
 * delivery batch in memory and raises ONCE per delivery message),
 * and the hub-gated `fundReferralPayout`, which transfers USD to
 * the hub and lowers the liability in the same call: the vault's
 * USD balance and the reserved buffer drop together, so the sweep
 * inequality is untouched and the buffer tracks the debt at every
 * instant. Authorization is the timelocked `payoutHub` pointer
 * alone, never an ERC-20 allowance, which would let USD leave
 * without this accounting seeing it; while the pointer is zero both
 * writers revert {NotPayoutHub} and the vault behaves byte-for-byte
 * as before (default-off convention). Funding can never exceed the
 * booked liability ({ExceedsPendingPayout}), so pulls beyond what
 * verdicts awarded are structurally impossible even for the hub.
 * No reentrancy guard: the single external call is the USD transfer
 * to the timelocked hub, made after all state writes, and the token
 * is the vault's own trusted underlying.
 *
 * DEPLOY-SLIM STORAGE MIRROR: instead of inheriting the full
 * declaration chain, only the three slots this facet touches are
 * pinned, padded to their exact positions in the deployed diamond
 * layout (USD_TOKEN 8, pendingReferralPayout 76, payoutHub 80).
 * The pinned entries are asserted label-for-label against the
 * diamond's committed layout snapshot by
 * script/check_storage_layout.sh, so any drift fails CI before it
 * can ship.
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
