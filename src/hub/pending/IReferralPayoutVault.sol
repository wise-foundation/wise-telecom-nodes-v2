// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev The payout vault surface the hub calls. Both writers are gated to
 * the vault's timelocked hub, and their failures bubble so a booking or a
 * funding can never be dropped silently.
 */
interface IReferralPayoutVault {

    function USD_TOKEN()
        external
        view
        returns (address);

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

    function getPayoutHub()
        external
        view
        returns (address);
}
