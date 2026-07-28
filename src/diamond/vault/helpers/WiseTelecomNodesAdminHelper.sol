// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {WiseTelecomNodesBaseHelper} from "./WiseTelecomNodesBaseHelper.sol";

/**
 * @dev Master-side supply controls. Mint/burn are gated by
 * `supplyChangeAllowed` at the facet boundary and become
 * permanently disabled once `disAllowSupplyChangeByOwner` is called.
 */
abstract contract WiseTelecomNodesAdminHelper is WiseTelecomNodesBaseHelper {

    function _executeMintSupply(
        address _to,
        uint256 _amount
    )
        internal
    {
        _checkDepositCap(
            _amount
        );

        _mint(
            _to,
            _amount
        );

        emit MintSupply(
            _to,
            _amount
        );
    }

    function _executeBurnSupply(
        address _from,
        uint256 _amount
    )
        internal
    {
        _burn(
            _from,
            _amount
        );

        emit BurnSupply(
            _from,
            _amount
        );
    }
}
