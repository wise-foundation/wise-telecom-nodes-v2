// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {WiseTelecomNodesQueueUIHelper} from "../helpers/WiseTelecomNodesQueueUIHelper.sol";
import {WiseTelecomNodesDeclarations} from "../declarations/WiseTelecomNodesDeclarations.sol";
import {WiseTelecomNodesInitParams} from "../WiseTelecomNodesDiamondStructs.sol";

/**
 * @dev Read-only queue surface. Carries the heavy UI/view layer
 * (planning, prediction, order listing) on its own facet so the
 * action facets and the diamond entry stay lean. Every exposed
 * function is an inherited view; reached via DELEGATECALL it reads
 * the diamond's storage. Placeholder constructor args satisfy
 * `_validateConstructorInputs`.
 */
contract QueueViewFacet is WiseTelecomNodesQueueUIHelper {

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
    {}
}
