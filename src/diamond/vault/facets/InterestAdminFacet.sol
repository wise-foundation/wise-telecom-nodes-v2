// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {WiseTelecomNodesDiamondErrors} from "../WiseTelecomNodesDiamondErrors.sol";
import {WiseTelecomNodesDiamondEvents} from "../WiseTelecomNodesDiamondEvents.sol";

import {NotMaster} from "../../shared/OwnableMaster.sol";
import {OnlyDelegateCall} from "../../shared/DiamondErrors.sol";

/**
 * @dev Master-only setter for a wallet's settled interest bucket,
 * for positions whose owner can no longer sign (lost keys) and for
 * deliberate grants or write-offs. Writes `cashedInterest[user]`
 * directly and keeps the `totalCashedInterest` accumulator in
 * lockstep with the delta, exactly like every organic write site,
 * so the INT-7 sum law and the sweep-buffer reservation hold in
 * both directions.
 *
 * The setter touches ONLY the settled bucket: pending accrual is
 * not banked first and keeps accruing on top for a wallet that
 * still holds shares. A wallet-to-wallet rescue is two calls, read
 * the source bucket, set it to zero, set the destination to the
 * read value; the accumulator nets out unchanged.
 *
 * Gated by the same one-way `supplyChangeByOwnerNotAllowed` latch
 * as `mintSupply`/`burnSupply`: throwing the latch renounces every
 * master balance-surgery power, this one included. No reentrancy
 * guard: the function makes no external calls.
 *
 * DEPLOY-SLIM STORAGE MIRROR: instead of inheriting the full
 * declaration chain, only the four slots this facet touches are
 * pinned, padded to their exact positions in the deployed diamond
 * layout (master 0, supplyChangeByOwnerNotAllowed 12/20,
 * cashedInterest 15, totalCashedInterest 60). The pinned entries
 * are asserted label-for-label against the diamond's committed
 * layout snapshot by script/check_storage_layout.sh, so any drift
 * fails CI before it can ship.
 */
contract InterestAdminFacet is
    WiseTelecomNodesDiamondErrors,
    WiseTelecomNodesDiamondEvents
{

    address internal master;

    uint256[11] private __gap1;

    address private __pad12;
    bool internal supplyChangeByOwnerNotAllowed;

    uint256[2] private __gap13;

    mapping(address => uint256) internal cashedInterest;

    uint256[44] private __gap16;

    uint256 internal totalCashedInterest;

    address internal immutable _self;

    constructor() {
        _self = address(this);
    }

    modifier onlyDelegateCall() {
        require(
            address(this) != _self,
            OnlyDelegateCall()
        );
        _;
    }

    modifier onlyMaster() {
        require(
            msg.sender == master,
            NotMaster()
        );
        _;
    }

    modifier supplyChangeAllowed() {
        require(
            supplyChangeByOwnerNotAllowed == false,
            SupplyChangeNotAllowed()
        );
        _;
    }

    function setCashedInterest(
        address _user,
        uint256 _amount
    )
        external
        onlyDelegateCall
        onlyMaster
        supplyChangeAllowed
    {
        require(
            _user != address(0)
                && _user != address(this),
            InvalidValue()
        );

        uint256 previous = cashedInterest[_user];

        cashedInterest[_user] = _amount;

        totalCashedInterest = totalCashedInterest
            + _amount
            - previous;

        emit CashedInterestSet(
            _user,
            previous,
            _amount
        );

        emit TotalCashedInterestChanged(
            totalCashedInterest
        );
    }
}
