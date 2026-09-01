// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "../FacetBase.sol";
import {ReferralFacetBase} from "./ReferralFacetBase.sol";
import {IReferralRegistry} from "../../interfaces/pending/IReferralRegistry.sol";

/**
 * @dev Referral variants of the three plain deposit entrypoints.
 * Modifier stacks mirror {UserFacet} exactly; the write-once referral
 * assignment runs first (forwarded to the standalone
 * {ReferralRegistry}), then the flow is identical to
 * the non-referral path.
 * Also carries the routed referrer view surface `getReferrerOf` (the
 * post-genesis routed-getter naming, and a name the inherited slot-67
 * mapping identifier cannot shadow): an explicit getter reading
 * THROUGH the slot-77 pointer into the registry, never the
 * diamond's forever-virgin slot-67 mapping. With the pointer unset
 * it returns zero (byte-for-byte the virgin-slot read of the
 * pre-registry design); with a pointer set it uses a plain interface
 * staticcall that MAY revert against a hostile or detached registry,
 * a deliberate asymmetry against the cohort recorder's guarded
 * revert-free seam, because a view revert DoSes nothing and is more
 * informative to integrators than a fabricated zero.
 */
contract ReferralFacet is ReferralFacetBase {

    constructor()
        FacetBase()
    {}

    function getReferrerOf(
        address _user
    )
        external
        view
        returns (address)
    {
        address registry = referralRegistry;

        if (registry == ZERO_ADDRESS) {
            return ZERO_ADDRESS;
        }

        return IReferralRegistry(registry).referrerOf(
            _user
        );
    }

    function depositWithReferral(
        uint256 _amount,
        address _referrer
    )
        external
        onlyDelegateCall
        whenNotPaused
        nonReentrant
        assignInterest(msg.sender)
        registerLargeDeposit(msg.sender)
    {
        _handleReferral(
            _referrer
        );

        _deposit(
            _amount
        );
    }

    function depositAndClaimInterestWithReferral(
        uint256 _amount,
        address _referrer
    )
        external
        onlyDelegateCall
        whenNotPaused
        nonReentrant
        assignInterest(msg.sender)
        gracePeriodCheck(msg.sender)
        registerLargeDeposit(msg.sender)
        returns (uint256)
    {
        _handleReferral(
            _referrer
        );

        return _executeDepositAndClaim(
            _amount
        );
    }

    function depositAndCompoundInterestWithReferral(
        uint256 _amount,
        address _referrer
    )
        external
        onlyDelegateCall
        whenNotPaused
        nonReentrant
        assignInterest(msg.sender)
        gracePeriodCheck(msg.sender)
        registerLargeDeposit(msg.sender)
        returns (uint256)
    {
        _handleReferral(
            _referrer
        );

        return _executeDepositAndCompound(
            _amount
        );
    }
}
