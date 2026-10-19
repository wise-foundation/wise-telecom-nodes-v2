// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {VaultConfig} from "../vault/VaultConfig.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {Permit2ReferralFacet} from "../../src/diamond/vault/facets/pending/Permit2ReferralFacet.sol";
import {WiseTelecomNodesDiamond} from "../../src/diamond/vault/WiseTelecomNodesDiamond.sol";

import {WiseTelecomNodesDiamondSelectors} from "./WiseTelecomNodesDiamondSelectors.sol";

/// @notice SUPERSEDED twice over; do not broadcast: first by {UpgradeCohortRecorder}, now by
/// {UpgradeReferralRegistry} (the referral facets write the per-chain
/// standalone {ReferralRegistry}; this script's slot-67 flow no longer exists in the facets).
/// Kept for the historical record; its fork rehearsal was retired with the registry rework.
///
/// Installs the referral feature on an already-running, finalized diamond. Two phases,
/// mirroring the diamond's own propose/execute timelock: `propose()` deploys the two new
/// facets and proposes both selector batches (the six `...WithReferral` deposits plus the
/// routed `referrerOf` getter). After the 3-day SELECTOR_CHANGE_DELAY, `execute()` flips them
/// in; it needs no addresses because the diamond reads its own proposal storage. The transfer
/// hook is deliberately untouched: referrals are written by deposits only and are write-once,
/// so transfers can neither assign nor change them. Slot 64 (`referrerOf`) is virgin tail
/// storage on the live
/// diamond, so behavior is unchanged until the new entrypoints are used.
///
///   forge script script/diamond/UpgradeReferral.s.sol --sig "propose()" --rpc-url ... --broadcast
///   ... wait 3 days ...
///   forge script script/diamond/UpgradeReferral.s.sol --sig "execute()" --rpc-url ... --broadcast
contract UpgradeReferral is VaultConfig {

    function propose()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        (
            address diamond,
        ) = _loadVault(
            _networkName()
        );

        vm.startBroadcast(
            privKey
        );

        ReferralFacet referral = new ReferralFacet();

        Permit2ReferralFacet permit2Referral = new Permit2ReferralFacet();

        WiseTelecomNodesDiamond(payable(diamond)).proposeSelectors(
            WiseTelecomNodesDiamondSelectors._referralSelectors(),
            address(referral)
        );

        WiseTelecomNodesDiamond(payable(diamond)).proposeSelectors(
            WiseTelecomNodesDiamondSelectors._permit2ReferralSelectors(),
            address(permit2Referral)
        );

        vm.stopBroadcast();

        console2.log(
            "proposed referral upgrade on diamond",
            diamond
        );

        console2.log(
            "  ReferralFacet       ",
            address(referral)
        );

        console2.log(
            "  Permit2ReferralFacet",
            address(permit2Referral)
        );

        console2.log(
            "run execute() after the 3-day timelock"
        );
    }

    function execute()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        (
            address diamond,
        ) = _loadVault(
            _networkName()
        );

        vm.startBroadcast(
            privKey
        );

        WiseTelecomNodesDiamond(payable(diamond)).executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors._referralSelectors()
        );

        WiseTelecomNodesDiamond(payable(diamond)).executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors._permit2ReferralSelectors()
        );

        vm.stopBroadcast();

        console2.log(
            "executed referral upgrade on diamond",
            diamond
        );
    }
}
