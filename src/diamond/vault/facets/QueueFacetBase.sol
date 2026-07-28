// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {WiseTelecomNodesQueueHelper} from "../helpers/WiseTelecomNodesQueueHelper.sol";
import {WiseTelecomNodesDeclarations} from "../declarations/WiseTelecomNodesDeclarations.sol";
import {WiseTelecomNodesInitParams} from "../WiseTelecomNodesDiamondStructs.sol";

import {OnlyDelegateCall} from "../../shared/DiamondErrors.sol";

/**
 * @dev Common base for the queue action facets (admin / join-leave /
 * fulfill). Carries the order-processing helper but not the heavier
 * UI/view layer, which lives only on {QueueViewFacet}. Mirrors
 * {FacetBase}: placeholder constructor args satisfy
 * `_validateConstructorInputs`, and `_self` lets `onlyDelegateCall`
 * reject direct calls — facet storage is never read because facets
 * are only entered via DELEGATECALL.
 */
abstract contract QueueFacetBase is WiseTelecomNodesQueueHelper {

    address internal immutable _self;

    constructor()
        WiseTelecomNodesDeclarations(
            WiseTelecomNodesInitParams({
                usdAddress: address(0x000000000000000000000000000000000000dEaD),
                thirdPartyAddress: address(0x000000000000000000000000000000000000dEaD),
                workerAddress: address(0x000000000000000000000000000000000000dEaD),
                oldVault: address(0),
                initialDistributionAddresses: new address[](0),
                initialDistributionAmounts: new uint256[](0),
                totalDepositCap: 1,
                interestRate: 1,
                decimalsValue: 18,
                tokenName: "FACET",
                tokenSymbol: "FACET"
            })
        )
    {
        _self = address(this);
    }

    modifier onlyDelegateCall() {
        _onlyDelegateCall();
        _;
    }

    function _onlyDelegateCall()
        internal
        view
    {
        if (address(this) != _self) {
            return;
        }

        revert OnlyDelegateCall();
    }
}
