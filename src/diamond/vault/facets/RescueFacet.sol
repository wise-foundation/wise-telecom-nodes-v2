// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {WiseTelecomNodesDiamondErrors} from "../WiseTelecomNodesDiamondErrors.sol";
import {WiseTelecomNodesDiamondEvents} from "../WiseTelecomNodesDiamondEvents.sol";

import {NotMaster} from "../../shared/OwnableMaster.sol";
import {OnlyDelegateCall} from "../../shared/DiamondErrors.sol";

/**
 * @dev Master-only escape hatch for tokens stranded on the vault by
 * direct wallet transfers. Strictly excluded: the underlying
 * `USD_TOKEN`, whose vault balance backs interest claims and the
 * sweep-buffer reservation (its surplus leaves only through
 * `sweepOverhang` to the worker), and the vault's own share token.
 * Every other balance is invisible to vault accounting and can be
 * returned to its sender.
 *
 * No reentrancy guard: the single external call happens after all
 * checks, the function writes no vault storage, and the caller is
 * the master.
 *
 * DEPLOY-SLIM STORAGE MIRROR: instead of inheriting the full
 * declaration chain, only the two slots this facet reads are
 * pinned, padded to their exact positions in the deployed diamond
 * layout (master 0, USD_TOKEN 8). The pinned entries are asserted
 * label-for-label against the diamond's committed layout snapshot
 * by script/check_storage_layout.sh, so any drift fails CI before
 * it can ship.
 */
contract RescueFacet is
    WiseTelecomNodesDiamondErrors,
    WiseTelecomNodesDiamondEvents
{
    using SafeERC20 for IERC20;

    address internal master;

    uint256[7] private __gap1;

    IERC20 internal USD_TOKEN;

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

    function rescueToken(
        address _token,
        address _to,
        uint256 _amount
    )
        external
        onlyDelegateCall
        onlyMaster
    {
        require(
            _token != address(USD_TOKEN)
                && _token != address(this),
            ProtectedToken()
        );

        require(
            _to != address(0),
            InvalidValue()
        );

        IERC20(_token).safeTransfer(
            _to,
            _amount
        );

        emit TokenRescued(
            _token,
            _to,
            _amount
        );
    }
}
