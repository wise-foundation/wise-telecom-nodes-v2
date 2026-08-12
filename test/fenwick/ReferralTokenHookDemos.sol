// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ReferralTokenDemo} from "./ReferralTokenDemo.sol";

/**
 * @dev Two swappable transfer-hook facets for the ReferralTokenDemo
 * sandbox, mirroring the production hook register (see
 * GraceFreezeHookFacet). Both inherit {ReferralTokenDemo} purely for
 * storage-layout alignment under DELEGATECALL and declare no storage
 * of their own; both require the transient `hookExecuting` flag so a
 * direct external call to the facet reverts — only the token's
 * `_runTransferHook` path can enter them, exactly like production.
 *
 * {RecordingTransferHookDemo} emits the full extent of what an
 * amount-less hook can ever observe: the two addresses plus whatever
 * it reads from host storage — here the PRE-transfer balances, which
 * also proves the hook runs before `super` moves tokens. The amount
 * being transferred is structurally unobservable.
 *
 * {FreezeTransferHookDemo} vetoes every transfer, demonstrating the
 * hook's revert-bubbling and that swapping hooks swaps policy without
 * touching the token.
 */
contract RecordingTransferHookDemo is ReferralTokenDemo {

    event TransferHookRan(
        address indexed from,
        address indexed to,
        uint256 fromBalanceBefore,
        uint256 toBalanceBefore
    );

    error NotHookExecution();

    function applyTransferHook(
        address _from,
        address _to
    )
        external
    {
        require(
            hookExecuting,
            NotHookExecution()
        );

        emit TransferHookRan(
            _from,
            _to,
            balanceOf(_from),
            balanceOf(_to)
        );
    }
}

contract FreezeTransferHookDemo is ReferralTokenDemo {

    error NotHookExecution();

    error TransfersFrozen();

    function applyTransferHook(
        address,
        address
    )
        external
        view
    {
        require(
            hookExecuting,
            NotHookExecution()
        );

        revert TransfersFrozen();
    }
}
