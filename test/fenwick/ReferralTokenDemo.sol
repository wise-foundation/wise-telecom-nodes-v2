// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ReferralTopDecile} from "./ReferralTopDecile.sol";

/**
 * @dev Extends the fenwick practice sandbox with a faithful miniature
 * of the live diamond's transfer-hook mechanics, so referral-hook
 * ideas can be rehearsed against the real constraints. A plain
 * 6-decimal ERC20 hosts the ReferralTopDecile score storage, and both
 * `transfer` and `transferFrom` mirror the production overrides in
 * WiseTelecomNodesHelper exactly: non-zero amount check, then the
 * pre-transfer hook, then `super`. The hook mirrors
 * WiseTelecomNodesInterestHelper._runTransferHook byte for byte in
 * shape: `transferHookFacet` is DELEGATECALLed with the selector of
 * `applyTransferHook(address,address)` — the interface carries ONLY
 * the two addresses, never the amount, which is the structural reason
 * per-transfer score accounting is impossible on the live diamonds.
 * `address(0)` (the default) means no hook and a bare transfer; a
 * transient `hookExecuting` flag brackets the delegatecall so a hook
 * can require it only ever runs inside this path; hook reverts bubble
 * verbatim.
 *
 * Hook facets must inherit this contract purely for storage-layout
 * alignment under DELEGATECALL and must declare NO storage of their
 * own — the diamond-facet discipline in miniature.
 *
 * Deliberate divergences from production, all process not mechanics:
 * `setTransferHook` swaps instantly where the live diamond gates the
 * swap behind a 3-day propose/execute timelock; the interest and
 * reentrancy modifiers are omitted (no interest system here); `mint`
 * is an open test driver. Faithfully preserved instead: mint- and
 * burn-based movements run NO hook, matching the live rule that
 * `_burn`-based exits and deposit mints never touch the hook path.
 */
contract ReferralTokenDemo is ERC20, ReferralTopDecile {

    address public transferHookFacet;

    bool internal transient hookExecuting;

    bytes4 internal constant TRANSFER_HOOK_SELECTOR = bytes4(
        keccak256(
            "applyTransferHook(address,address)"
        )
    );

    event TransferHookSet(
        address hookFacet
    );

    error InvalidValue();

    constructor()
        ERC20(
            "Referral Demo Node",
            "RDN"
        )
    {}

    function decimals()
        public
        pure
        override
        returns (uint8)
    {
        return 6;
    }

    function mint(
        address _to,
        uint256 _amount
    )
        external
    {
        _mint(
            _to,
            _amount
        );
    }

    function setTransferHook(
        address _facet
    )
        external
    {
        transferHookFacet = _facet;

        emit TransferHookSet(
            _facet
        );
    }

    function transfer(
        address to,
        uint256 amount
    )
        public
        override
        returns (bool)
    {
        require(
            amount > 0,
            InvalidValue()
        );

        _runTransferHook(
            msg.sender,
            to
        );

        return super.transfer(
            to,
            amount
        );
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    )
        public
        override
        returns (bool)
    {
        require(
            amount > 0,
            InvalidValue()
        );

        _runTransferHook(
            from,
            to
        );

        return super.transferFrom(
            from,
            to,
            amount
        );
    }

    function _runTransferHook(
        address _from,
        address _to
    )
        internal
    {
        address facet = transferHookFacet;

        if (facet == address(0)) {
            return;
        }

        hookExecuting = true;

        (
            bool success,
            bytes memory returnData
        ) = facet.delegatecall(
            abi.encodeWithSelector(
                TRANSFER_HOOK_SELECTOR,
                _from,
                _to
            )
        );

        hookExecuting = false;

        if (success == false) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }
}
