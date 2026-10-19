// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralHubRates} from "./ReferralHubRates.sol";
import {ReferralHubFacetBase} from "./ReferralHubFacetBase.sol";

/**
 * @dev ReferralHubRatesFacet: the rate reads and the master levers
 * `pushRateTable` (append only and future only) and
 * `setDelivererShareCap` (zero means no cap).
 */
contract ReferralHubRatesFacet is
    ReferralHubRates,
    ReferralHubFacetBase
{

    function pushRateTable(
        RateTable calldata _table
    )
        external
        onlyMaster
        onlyDelegateCall
    {
        _pushRateTable(
            _table
        );
    }

    function setDelivererShareCap(
        uint256 _cap
    )
        external
        onlyMaster
        onlyDelegateCall
    {
        if (delivererShareCap == _cap) {
            return;
        }

        delivererShareCap = _cap;

        emit DelivererShareCapSet(
            _cap
        );
    }
}
