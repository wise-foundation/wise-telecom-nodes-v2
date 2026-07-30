// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "./FacetBase.sol";

/**
 * @dev Shared referral-assignment core for the two referral deposit
 * facets. Validates the referrer (non-zero, not the caller) and
 * applies the deposit-time assignment rule against the pre-deposit
 * balance: a first referrer always sets; an existing referrer is
 * displaced only when the incoming deposit is strictly larger than
 * the caller's current balance, so the referrer backed by more
 * tokens stays. Runs before any mint in every entrypoint, which is
 * what makes `balanceOf` the pre-deposit balance. Emits
 * {ReferralSet} only on an actual storage change.
 */
abstract contract ReferralFacetBase is FacetBase {

    function _handleReferral(
        uint256 _amount,
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

        address currentReferrer = referrerOf[msg.sender];

        if (currentReferrer == _referrer) {
            return;
        }

        if (currentReferrer != ZERO_ADDRESS) {
            if (_amount <= balanceOf(msg.sender)) {
                return;
            }
        }

        referrerOf[msg.sender] = _referrer;

        emit ReferralSet(
            msg.sender,
            _referrer
        );
    }
}
