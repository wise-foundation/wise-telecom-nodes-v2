// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Hub-facing subset of the payout vault's routed referral
 * payout surface. `raisePendingReferralPayout` books freshly priced
 * commission as liability on the vault (called once per delivery
 * batch or catch-up poke); `fundReferralPayout` pulls the USD that
 * covers a claim and lowers the booked liability in the same call;
 * `getPendingReferralPayout` bounds a partial claim's fundable
 * amount. Both writers are gated vault-side to the timelocked hub
 * address. Failures bubble to the delivering or claiming
 * transaction on purpose: a booking or funding that cannot land
 * must never be silently dropped.
 */
interface IReferralPayoutVault {

    function raisePendingReferralPayout(
        uint256 _amount
    )
        external;

    function fundReferralPayout(
        uint256 _amount
    )
        external;

    function getPendingReferralPayout()
        external
        view
        returns (uint256);
}
