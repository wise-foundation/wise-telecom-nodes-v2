// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ReferralHub} from "../../../src/hub/pending/ReferralHub.sol";
import {IReferralHub} from "../../../src/hub/pending/IReferralHub.sol";
import {ReferralHubCheckpointsFacet} from "../../../src/hub/pending/ReferralHubCheckpointsFacet.sol";
import {ReferralHubRatesFacet} from "../../../src/hub/pending/ReferralHubRatesFacet.sol";
import {ReferralHubIntakeFacet} from "../../../src/hub/pending/ReferralHubIntakeFacet.sol";
import {ReferralHubMailboxFacet} from "../../../src/hub/pending/ReferralHubMailboxFacet.sol";
import {ReferralHubPayoutFacet} from "../../../src/hub/pending/ReferralHubPayoutFacet.sol";

import {ReferralHubSelectors} from "../../../script/hub/ReferralHubSelectors.sol";

/**
 * @dev Deploys the {ReferralHub} diamond the way the broadcast
 * deploy does: the five facets, the proxy (master = the deploying
 * test contract, genesis seeds in the constructor), the five wiring
 * rounds while uninitialized and `finalizeSetup`. Suites hold the
 * returned {IReferralHub}; every selector is the monolith's own.
 */
abstract contract HubDiamondHarness {

    function _deployHub(
        address _usdToken
    )
        internal
        returns (IReferralHub hub)
    {
        address checkpointsFacet;

        address ratesFacet;

        address intakeFacet;

        address mailboxFacet;

        address payoutFacet;

        (
            hub,
            checkpointsFacet,
            ratesFacet,
            intakeFacet,
            mailboxFacet,
            payoutFacet
        ) = _deployHubWithFacets(
            _usdToken
        );
    }

    function _deployHubWithFacets(
        address _usdToken
    )
        internal
        returns (
            IReferralHub hub,
            address checkpointsFacet,
            address ratesFacet,
            address intakeFacet,
            address mailboxFacet,
            address payoutFacet
        )
    {
        ReferralHubCheckpointsFacet checkpointsFacetContract = new ReferralHubCheckpointsFacet();

        ReferralHubRatesFacet ratesFacetContract = new ReferralHubRatesFacet();

        ReferralHubIntakeFacet intakeFacetContract = new ReferralHubIntakeFacet();

        ReferralHubMailboxFacet mailboxFacetContract = new ReferralHubMailboxFacet();

        ReferralHubPayoutFacet payoutFacetContract = new ReferralHubPayoutFacet();

        ReferralHub proxy = new ReferralHub(
            _usdToken
        );

        proxy.proposeSelectors(
            ReferralHubSelectors._checkpointsSelectors(),
            address(checkpointsFacetContract)
        );

        proxy.executeSelectorChanges(
            ReferralHubSelectors._checkpointsSelectors()
        );

        proxy.proposeSelectors(
            ReferralHubSelectors._ratesSelectors(),
            address(ratesFacetContract)
        );

        proxy.executeSelectorChanges(
            ReferralHubSelectors._ratesSelectors()
        );

        proxy.proposeSelectors(
            ReferralHubSelectors._intakeSelectors(),
            address(intakeFacetContract)
        );

        proxy.executeSelectorChanges(
            ReferralHubSelectors._intakeSelectors()
        );

        proxy.proposeSelectors(
            ReferralHubSelectors._mailboxSelectors(),
            address(mailboxFacetContract)
        );

        proxy.executeSelectorChanges(
            ReferralHubSelectors._mailboxSelectors()
        );

        proxy.proposeSelectors(
            ReferralHubSelectors._payoutSelectors(),
            address(payoutFacetContract)
        );

        proxy.executeSelectorChanges(
            ReferralHubSelectors._payoutSelectors()
        );

        proxy.finalizeSetup();

        hub = IReferralHub(
            address(proxy)
        );

        checkpointsFacet = address(checkpointsFacetContract);

        ratesFacet = address(ratesFacetContract);

        intakeFacet = address(intakeFacetContract);

        mailboxFacet = address(mailboxFacetContract);

        payoutFacet = address(payoutFacetContract);
    }
}
