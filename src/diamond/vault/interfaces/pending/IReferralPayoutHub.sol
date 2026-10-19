// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev The hub surface the payout hub pointer probes at execute time:
 * `USD_TOKEN()` must answer this vault's own USD token.
 */
interface IReferralPayoutHub {

    function USD_TOKEN()
        external
        view
        returns (address);
}
