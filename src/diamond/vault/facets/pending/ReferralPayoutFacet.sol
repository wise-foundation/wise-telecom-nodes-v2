// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Read surface for the referral-payout liability (the
 * vault half). `getPendingReferralPayout()` returns the one global
 * `pendingReferralPayout` accumulator — the USD the hub's priced
 * verdicts have awarded against this vault but referrers have not
 * yet claimed — which `_calculateNeededBuffer` reserves so the
 * sweeper-gated `sweepOverhang` cannot take pre-funded payout cash.
 * The backing slot lives in `ReferralPayoutDeclaration` (tail slot
 * 76) and this routed view is its single external surface. Pending:
 * installed by the future payout upgrade round (a dedicated upgrade
 * script, never the frozen genesis scripts)
 * and zero until that round's writer exists.
 *
 * DEPLOY-SLIM STORAGE MIRROR: instead of inheriting the full
 * declaration chain, only the single slot this view reads is
 * pinned, padded to its exact position in the deployed diamond
 * layout (pendingReferralPayout, tail slot 76). The pinned entry
 * is asserted label-for-label against the diamond's committed
 * layout snapshot by script/check_storage_layout.sh, so any drift
 * fails CI before it can ship.
 */
contract ReferralPayoutFacet {

    uint256[76] private __gap0;

    uint256 internal pendingReferralPayout;

    function getPendingReferralPayout()
        external
        view
        returns (uint256)
    {
        return pendingReferralPayout;
    }
}
