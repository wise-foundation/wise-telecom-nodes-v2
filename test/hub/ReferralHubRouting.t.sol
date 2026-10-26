// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {IReferralHub} from "../../src/hub/pending/IReferralHub.sol";
import {HubDiamondHarness} from "./utils/HubDiamondHarness.sol";

import {ReferralHubCheckpointsFacet} from "../../src/hub/pending/ReferralHubCheckpointsFacet.sol";
import {ReferralHubRatesFacet} from "../../src/hub/pending/ReferralHubRatesFacet.sol";
import {ReferralHubIntakeFacet} from "../../src/hub/pending/ReferralHubIntakeFacet.sol";
import {ReferralHubMailboxFacet} from "../../src/hub/pending/ReferralHubMailboxFacet.sol";
import {ReferralHubPayoutFacet} from "../../src/hub/pending/ReferralHubPayoutFacet.sol";

import {ReferralHubSelectors} from "../../script/hub/ReferralHubSelectors.sol";

import {
    NoSelectorChangeQueued,
    SelectorTimelockNotElapsed,
    OnlyDelegateCall,
    AlreadyInitialized,
    FacetNotFound
} from "../../src/diamond/shared/DiamondErrors.sol";
import {ReferralHubDeclarations} from "../../src/hub/pending/ReferralHubDeclarations.sol";

import {MockUSD} from "./ReferralHubPayout.t.sol";

/**
 * @dev Routing proof of the {ReferralHub} diamond: every selector the
 * selector library wires lands on its own facet through the proxy
 * (the storage getters and the machinery stay proxy native and are
 * served by the proxy's own dispatcher, so nothing asserts them
 * here), the setup is finalized (the timelock is armed), and a
 * selector nobody proposed refuses to execute. The vault diamond's
 * own routing suite keeps its shape; this is the hub's twin.
 */
contract ReferralHubRoutingTest is Test, HubDiamondHarness {

    address internal usd;

    IReferralHub internal hub;

    address internal checkpointsFacet;

    address internal ratesFacet;

    address internal intakeFacet;

    address internal mailboxFacet;

    address internal payoutFacet;

    function setUp()
        public
    {
        usd = address(
            new MockUSD()
        );

        (
            hub,
            checkpointsFacet,
            ratesFacet,
            intakeFacet,
            mailboxFacet,
            payoutFacet
        ) = _deployHubWithFacets(
            usd
        );
    }

    function test_routing_everySelectorServesItsFacet()
        public
        view
    {
        bytes4[] memory group = ReferralHubSelectors._checkpointsSelectors();

        for (uint256 i; i < group.length; ++i) {
            assertEq(
                hub.selectorToFacet(group[i]),
                checkpointsFacet,
                "checkpoints selector misrouted"
            );
        }

        group = ReferralHubSelectors._ratesSelectors();

        for (uint256 i; i < group.length; ++i) {
            assertEq(
                hub.selectorToFacet(group[i]),
                ratesFacet,
                "rates selector misrouted"
            );
        }

        group = ReferralHubSelectors._intakeSelectors();

        for (uint256 i; i < group.length; ++i) {
            assertEq(
                hub.selectorToFacet(group[i]),
                intakeFacet,
                "intake selector misrouted"
            );
        }

        group = ReferralHubSelectors._mailboxSelectors();

        for (uint256 i; i < group.length; ++i) {
            assertEq(
                hub.selectorToFacet(group[i]),
                mailboxFacet,
                "mailbox selector misrouted"
            );
        }

        group = ReferralHubSelectors._payoutSelectors();

        for (uint256 i; i < group.length; ++i) {
            assertEq(
                hub.selectorToFacet(group[i]),
                payoutFacet,
                "payout selector misrouted"
            );
        }
    }

    function test_setup_finalizedAfterWiring()
        public
        view
    {
        assertTrue(
            hub.initialized()
        );
    }

    function test_RevertWhen_intakeFacetCalledDirectly()
        public
    {
        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        ReferralHubIntakeFacet(intakeFacet).setSourceSystem(
            bytes32(uint256(1)),
            1
        );
    }

    function test_RevertWhen_ratesFacetCalledDirectly()
        public
    {
        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        ReferralHubRatesFacet(ratesFacet).setDelivererShareCap(
            1
        );
    }

    function test_RevertWhen_finalizeSetupTwice()
        public
    {
        vm.expectRevert(
            AlreadyInitialized.selector
        );

        hub.finalizeSetup();
    }

    function test_RevertWhen_executeSelectorChange_toCodelessFacet()
        public
    {
        hub.proposeSelector(
            bytes4(
                0xdeadbeef
            ),
            address(0xBEEF)
        );

        vm.warp(
            block.timestamp + 3 days + 1 seconds
        );

        vm.expectRevert(
            ReferralHubDeclarations.ZeroAddress.selector
        );

        hub.executeSelectorChange(
            bytes4(
                0xdeadbeef
            )
        );
    }

    function test_RevertWhen_unroutedSelectorCalled()
        public
    {
        (
            bool success,
            bytes memory returned
        ) = address(hub).call(
            abi.encodeWithSelector(
                bytes4(
                    0xdeadbeef
                )
            )
        );

        assertFalse(success);
        assertEq(bytes4(returned), FacetNotFound.selector);
    }

    function test_RevertWhen_executeUnproposedSelector()
        public
    {
        vm.expectRevert(
            NoSelectorChangeQueued.selector
        );

        hub.executeSelectorChange(
            bytes4(
                0xdeadbeef
            )
        );
    }

    function test_RevertWhen_executeSelectorChange_beforeTimelock()
        public
    {
        hub.proposeSelector(
            bytes4(
                0xdeadbeef
            ),
            checkpointsFacet
        );

        vm.warp(
            block.timestamp + 2 days
        );

        vm.expectRevert(
            SelectorTimelockNotElapsed.selector
        );

        hub.executeSelectorChange(
            bytes4(
                0xdeadbeef
            )
        );

        vm.warp(
            block.timestamp + 1 days + 1 seconds
        );

        hub.executeSelectorChange(
            bytes4(
                0xdeadbeef
            )
        );

        assertEq(
            hub.selectorToFacet(
                bytes4(
                    0xdeadbeef
                )
            ),
            checkpointsFacet
        );
    }

    function test_cancelSelectorProposal_clearsQueueAndRefusesUnproposed()
        public
    {
        vm.expectRevert(
            NoSelectorChangeQueued.selector
        );

        hub.cancelSelectorProposal(
            bytes4(
                0xdeadbeef
            )
        );

        hub.proposeSelector(
            bytes4(
                0xdeadbeef
            ),
            checkpointsFacet
        );

        hub.cancelSelectorProposal(
            bytes4(
                0xdeadbeef
            )
        );

        vm.expectRevert(
            NoSelectorChangeQueued.selector
        );

        hub.executeSelectorChange(
            bytes4(
                0xdeadbeef
            )
        );
    }
}
