// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ReferralTopDecile} from "./ReferralTopDecile.sol";

/**
 * @dev Thin test harness over ReferralTopDecile exposing raw Fenwick nodes
 * and the internal prefix sum for state-fold and conservation assertions.
 * The measured external functions are inherited unchanged, so gas numbers
 * taken against the harness are identical to the base contract.
 */
contract ReferralTopDecileHarness is ReferralTopDecile {

    function exposed_fenwickNode(
        uint256 _index
    )
        external
        view
        returns (uint256)
    {
        return fenwickTree[_index];
    }

    function exposed_prefixSum(
        uint256 _index
    )
        external
        view
        returns (uint256)
    {
        return _prefixSum(
            _index
        );
    }
}
