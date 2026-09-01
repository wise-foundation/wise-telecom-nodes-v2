// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "../FacetBase.sol";
import {IReferralRegistry} from "../../interfaces/pending/IReferralRegistry.sol";

/**
 * @dev Shared referral-assignment core for the two referral deposit
 * facets. Validates the referrer (non-zero, not the caller) with a
 * fixed revert priority (a zero or self referrer always
 * reverts, even when an assignment already exists), then forwards
 * `(msg.sender, referrer)` to this chain's standalone
 * {ReferralRegistry} through the slot-77 pointer (the
 * registry is the single source of referrer truth; the diamond's
 * slot-67 mapping stays forever virgin). The write-once rule, the
 * silent-ignore of later different referrers and the
 * {ReferralAssigned} first-set event all live registry-side,
 * atomically with the write; the vault emits nothing because the
 * vault changes no state. An unset pointer reverts
 * {ReferralRegistryNotSet} (loud, never a silent drop of a user's
 * referrer) and is reachable only in a mis-sequenced upgrade
 * because the referral selectors and the pointer ship in the same
 * round. The high-level CALL lets registry reverts (unallowlisted
 * vault, zero/self defense-in-depth) bubble into the deposit, and
 * solc's extcodesize guard on void-returning calls rejects a
 * codeless pointer instead of silently succeeding.
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

        address registry = referralRegistry;

        require(
            registry != ZERO_ADDRESS,
            ReferralRegistryNotSet()
        );

        IReferralRegistry(registry).assignReferrer(
            msg.sender,
            _referrer
        );
    }
}
