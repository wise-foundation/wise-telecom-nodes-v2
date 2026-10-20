// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralHubRates} from "./ReferralHubRates.sol";
import {ReferralHubFacetBase} from "./ReferralHubFacetBase.sol";
import {CohortWeeks} from "../../diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev ReferralHubRatesFacet: the rate reads and the master levers
 * `pushRateTable` (append only and future only), `setDelivererShareCap`
 * (zero means no cap) and the elevation whitelist: `elevateReferrer`
 * prices a referrer as at the cap from a future week on, open ended, and
 * is a grant (it runs only as the exact call master queued through
 * `proposeLeverChange` at least the lever delay earlier); `endElevation`
 * closes the window at a future week at once. Both act on future weeks
 * only, so a closed week keeps its verdict and a week already paid at the
 * elevated rate is never clawed back; a new grant after an end starts a
 * fresh window (a week of the ended window not yet priced then prices
 * naturally). The inputs are recorded regardless, so the natural rate
 * stays derivable.
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

    function elevateReferrer(
        address _referrer,
        uint256 _fromWeek
    )
        external
        onlyMaster
        onlyDelegateCall
    {
        require(
            _referrer != ZERO_ADDRESS,
            ZeroAddress()
        );

        _consumeLeverChange(
            keccak256(
                abi.encodeCall(
                    this.elevateReferrer,
                    (
                        _referrer,
                        _fromWeek
                    )
                )
            )
        );

        _requireWithinHorizon(
            _fromWeek
        );

        require(
            _fromWeek > block.timestamp / CohortWeeks.WEEK,
            ElevationNotFuture()
        );

        require(
            elevatedFromWeek[_referrer] == 0
                || elevatedUntilWeek[_referrer] != 0,
            AlreadyElevated()
        );

        elevatedFromWeek[_referrer] = _fromWeek;

        elevatedUntilWeek[_referrer] = 0;

        emit ReferrerElevated(
            _referrer,
            _fromWeek
        );
    }

    function endElevation(
        address _referrer,
        uint256 _untilWeek
    )
        external
        onlyMaster
        onlyDelegateCall
    {
        uint256 fromWeek = elevatedFromWeek[_referrer];

        require(
            fromWeek != 0
                && elevatedUntilWeek[_referrer] == 0,
            NotElevated()
        );

        _requireWithinHorizon(
            _untilWeek
        );

        require(
            _untilWeek > block.timestamp / CohortWeeks.WEEK
                && _untilWeek >= fromWeek,
            ElevationNotFuture()
        );

        elevatedUntilWeek[_referrer] = _untilWeek;

        emit ReferrerElevationEnded(
            _referrer,
            _untilWeek
        );
    }
}
