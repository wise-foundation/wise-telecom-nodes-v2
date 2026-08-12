// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "./FacetBase.sol";
import {ReferralFacetBase} from "./ReferralFacetBase.sol";

/**
 * @dev Referral variants of the three plain deposit entrypoints.
 * Modifier stacks mirror {UserFacet} exactly; the write-once referral
 * assignment runs first, then the flow is identical to the
 * non-referral path.
 * Also carries the routed `referrerOf` getter surface: on a live
 * diamond the entry contract keeps its genesis bytecode, so the
 * auto-getter added to the declaration chain is only reachable
 * through the selector routing pointed at this facet.
 */
contract ReferralFacet is ReferralFacetBase {

    constructor()
        FacetBase()
    {}

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
