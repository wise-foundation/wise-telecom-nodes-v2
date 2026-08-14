// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "../FacetBase.sol";

/**
 * @dev Shared referral-assignment core for the two referral deposit
 * facets. Validates the referrer (non-zero, not the caller) and
 * applies the write-once assignment rule: the first referral deposit
 * sets `referrerOf` and any later value is permanently ignored — an
 * assigned referrer can never be displaced, not by a larger deposit,
 * not by any transfer, and only the referral deposit entrypoints can
 * take an address from unset to set. Validation runs before the
 * write-once check, so a zero or self referrer always reverts even
 * when an assignment already exists; a different valid referrer after
 * assignment is silently ignored and the deposit proceeds. Emits
 * {ReferralSet} only on the actual first-set storage change.
 */
abstract contract ReferralFacetBase is FacetBase {

    function _handleReferral(
        address _referrer
    )
        internal
    {
        require(
            _referrer != ZERO_ADDRESS,
            InvalidValue()
        );

        require(
            _referrer != msg.sender,
            SelfReferral()
        );

        if (referrerOf[msg.sender] != ZERO_ADDRESS) {
            return;
        }

        referrerOf[msg.sender] = _referrer;

        emit ReferralSet(
            msg.sender,
            _referrer
        );
    }
}
