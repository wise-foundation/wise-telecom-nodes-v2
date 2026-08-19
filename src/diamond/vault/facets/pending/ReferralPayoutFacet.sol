// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "../FacetBase.sol";

/**
 * @dev Read surface for the referral-payout liability (the
 * vault half). `getPendingReferralPayout()` returns the one global
 * `pendingReferralPayout` accumulator — the USD the hub's priced
 * verdicts have awarded against this vault but referrers have not
 * yet claimed — which `_calculateNeededBuffer` reserves so the
 * sweeper-gated `sweepOverhang` cannot take pre-funded payout cash.
 * The backing slot lives in `ReferralPayoutDeclaration` (tail slot
 * 73) and this routed view is its single external surface. Pending:
 * installed by the future payout upgrade round (a dedicated upgrade
 * script, never the frozen genesis scripts)
 * and zero until that round's writer exists.
 */
contract ReferralPayoutFacet is FacetBase {

    constructor()
        FacetBase()
    {}

    function getPendingReferralPayout()
        external
        view
        returns (uint256)
    {
        return pendingReferralPayout;
    }
}
