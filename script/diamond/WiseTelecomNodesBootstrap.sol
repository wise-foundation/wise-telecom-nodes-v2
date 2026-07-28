// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {WiseTelecomNodesDiamond} from "../../src/diamond/vault/WiseTelecomNodesDiamond.sol";
import {WiseTelecomNodesInitParams} from "../../src/diamond/vault/WiseTelecomNodesDiamondStructs.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";

import {WiseTelecomNodesDiamondSelectors} from "./WiseTelecomNodesDiamondSelectors.sol";

struct BootstrapFacets {
    address admin;
    address proxy;
    address user;
    address sweep;
    address cashedInterest;
    address burnWise;
    address move;
    address bridge;
    address permit2;
    address multicall;
    address queueAdmin;
    address queueJoinLeave;
    address queueFulfill;
    address queueView;
    address graceFreezeHook;
    address graceAccumHook;
}

/**
 * @dev One-shot bootstrap shim for the deterministic multichain
 * deploy. The shim itself is deployed through CreateX CREATE3, so its
 * address depends only on the deployer EOA and a salt — never on
 * bytecode or constructor args. Its constructor then plain-CREATEs
 * the diamond as its first creation (nonce 1), which pins the diamond
 * to `keccak256(rlp([shim, 1]))` — the same canonical address on
 * every chain, while the per-chain constructor args (underlying,
 * name, caps) remain free to differ.
 *
 * The indirection exists because the diamond binds
 * `OwnableMaster(msg.sender)` at construction: created directly via a
 * factory, its master would be an inert CREATE3 proxy and the
 * selector wiring could never run. Created by this shim, the shim is
 * master for the length of its own constructor — long enough to wire
 * all selectors (instant pre-finalize), install the grace-freeze
 * transfer hook and the grace-accumulator deposit hook (both instant
 * pre-finalize; the accumulator ships dormant since
 * `depositAccumWindow` is never set), grant the pending master as a
 * sweeper and revoke the shim's own constructor-seeded grant (the
 * diamond constructor seeds worker, third party and `msg.sender` —
 * here the shim), point the CCIP router,
 * set the WISE token when configured, close the deposit gate on
 * dormant chains, and propose the deployer as the real owner. The
 * deployer
 * claims ownership in the next transaction and the shim is inert
 * from then on. `finalizeSetup` deliberately stays a separate,
 * later phase so peers can still be wired instantly.
 */
contract WiseTelecomNodesBootstrap {

    WiseTelecomNodesDiamond public immutable diamond;

    constructor(
        WiseTelecomNodesInitParams memory _params,
        BootstrapFacets memory _facets,
        address _ccipRouter,
        address _wiseToken,
        bool _startDormant,
        address _pendingMaster
    ) {
        WiseTelecomNodesDiamond deployed = new WiseTelecomNodesDiamond(
            _params
        );

        _wireSelectors(
            deployed,
            _facets
        );

        AdminFacet(address(deployed)).proposeTransferHookFacet(
            _facets.graceFreezeHook
        );

        AdminFacet(address(deployed)).executeTransferHookFacetChange();

        AdminFacet(address(deployed)).proposeDepositHookFacet(
            _facets.graceAccumHook
        );

        AdminFacet(address(deployed)).executeDepositHookFacetChange();

        AdminFacet(address(deployed)).setSweeper(
            _pendingMaster,
            true
        );

        AdminFacet(address(deployed)).setSweeper(
            address(this),
            false
        );

        BridgeFacet(address(deployed)).setCcipRouter(
            _ccipRouter
        );

        if (_wiseToken != address(0)) {
            AdminFacet(address(deployed)).setWiseToken(
                _wiseToken
            );
        }

        if (_startDormant == true) {
            AdminFacet(address(deployed)).setDepositsDisabled(
                true
            );
        }

        deployed.proposeOwner(
            _pendingMaster
        );

        diamond = deployed;
    }

    function _wireSelectors(
        WiseTelecomNodesDiamond _diamond,
        BootstrapFacets memory _facets
    )
        internal
    {
        _wireOne(
            _diamond,
            _facets.admin,
            WiseTelecomNodesDiamondSelectors.adminSelectors()
        );

        _wireOne(
            _diamond,
            _facets.proxy,
            WiseTelecomNodesDiamondSelectors.proxySelectors()
        );

        _wireOne(
            _diamond,
            _facets.user,
            WiseTelecomNodesDiamondSelectors.userSelectors()
        );

        _wireOne(
            _diamond,
            _facets.sweep,
            WiseTelecomNodesDiamondSelectors.sweepSelectors()
        );

        _wireOne(
            _diamond,
            _facets.cashedInterest,
            WiseTelecomNodesDiamondSelectors.cashedInterestSelectors()
        );

        _wireOne(
            _diamond,
            _facets.burnWise,
            WiseTelecomNodesDiamondSelectors.burnWiseSelectors()
        );

        _wireOne(
            _diamond,
            _facets.move,
            WiseTelecomNodesDiamondSelectors.moveSelectors()
        );

        _wireOne(
            _diamond,
            _facets.bridge,
            WiseTelecomNodesDiamondSelectors.bridgeSelectors()
        );

        _wireOne(
            _diamond,
            _facets.permit2,
            WiseTelecomNodesDiamondSelectors.permit2Selectors()
        );

        _wireOne(
            _diamond,
            _facets.multicall,
            WiseTelecomNodesDiamondSelectors.multicallSelectors()
        );

        _wireOne(
            _diamond,
            _facets.queueAdmin,
            WiseTelecomNodesDiamondSelectors.queueAdminSelectors()
        );

        _wireOne(
            _diamond,
            _facets.queueJoinLeave,
            WiseTelecomNodesDiamondSelectors.queueJoinLeaveSelectors()
        );

        _wireOne(
            _diamond,
            _facets.queueFulfill,
            WiseTelecomNodesDiamondSelectors.queueFulfillSelectors()
        );

        _wireOne(
            _diamond,
            _facets.queueView,
            WiseTelecomNodesDiamondSelectors.queueViewSelectors()
        );
    }

    function _wireOne(
        WiseTelecomNodesDiamond _diamond,
        address _facet,
        bytes4[] memory _sels
    )
        internal
    {
        _diamond.proposeSelectors(
            _sels,
            _facet
        );

        _diamond.executeSelectorChanges(
            _sels
        );
    }
}
