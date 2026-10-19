// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {VaultConfig} from "../vault/VaultConfig.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {Permit2UserFacet} from "../../src/diamond/vault/facets/Permit2UserFacet.sol";
import {MoveFacet} from "../../src/diamond/vault/facets/MoveFacet.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../src/diamond/vault/facets/QueueFulfillFacet.sol";
import {AutoCompoundFacet} from "../../src/diamond/vault/facets/AutoCompoundFacet.sol";
import {SweepFacet} from "../../src/diamond/vault/facets/SweepFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {Permit2ReferralFacet} from "../../src/diamond/vault/facets/pending/Permit2ReferralFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortBridgeHookFacet} from "../../src/diamond/vault/facets/pending/CohortBridgeHookFacet.sol";
import {CohortMoveHookFacet} from "../../src/diamond/vault/facets/pending/CohortMoveHookFacet.sol";
import {CohortFlushFacet} from "../../src/diamond/vault/facets/pending/CohortFlushFacet.sol";
import {CohortFlushPolicyFacet} from "../../src/diamond/vault/facets/pending/CohortFlushPolicyFacet.sol";
import {ReferralPayoutFacet} from "../../src/diamond/vault/facets/pending/ReferralPayoutFacet.sol";
import {ReferralRegistry} from "../../src/registry/pending/ReferralRegistry.sol";
import {ReferralHub} from "../../src/hub/pending/ReferralHub.sol";
import {ReferralHubReader} from "../../src/hub/pending/ReferralHubReader.sol";
import {ReferralHubCheckpointsFacet} from "../../src/hub/pending/ReferralHubCheckpointsFacet.sol";
import {ReferralHubRatesFacet} from "../../src/hub/pending/ReferralHubRatesFacet.sol";
import {ReferralHubIntakeFacet} from "../../src/hub/pending/ReferralHubIntakeFacet.sol";
import {ReferralHubMailboxFacet} from "../../src/hub/pending/ReferralHubMailboxFacet.sol";
import {ReferralHubPayoutFacet} from "../../src/hub/pending/ReferralHubPayoutFacet.sol";

/// @notice Explorer verification rehearsal on Sepolia: deploys one copy of every contract the
/// referral rollout deploys on the live chains (the eighteen vault facets of the registry,
/// flush and payout rounds, the registry, the five hub facets, the hub and its reader), from
/// the same sources and compiler profile, so `--verify` proves before Phase 1 that each one
/// verifies on Etherscan V2. Nothing is wired: the contracts stay standalone, no config file
/// is written, and the copies are never used after the rehearsal. The run refuses any chain
/// but Sepolia. The hub takes the Sepolia vault's USD token from `config/vault.sepolia.json`.
///
///   forge script script/verify/RehearseReferralVerify.s.sol:RehearseReferralVerify --rpc-url sepolia
///   forge script script/verify/RehearseReferralVerify.s.sol:RehearseReferralVerify --rpc-url sepolia --broadcast --slow --verify
///   bash script/verify/verify_referral_broadcast.sh RehearseReferralVerify.s.sol sepolia
contract RehearseReferralVerify is VaultConfig {

    uint256 internal constant REHEARSAL_CHAIN_RANK = 0;

    function run()
        external
    {
        require(
            block.chainid == SEPOLIA_ID,
            "RehearseReferralVerify: Sepolia only"
        );

        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        address usd = vm.parseJsonAddress(
            vm.readFile(
                "config/vault.sepolia.json"
            ),
            ".usd"
        );

        vm.startBroadcast(
            privKey
        );

        new AdminFacet();
        new UserFacet();
        new Permit2UserFacet();
        new MoveFacet();
        new BridgeFacet();
        new QueueJoinLeaveFacet();
        new QueueFulfillFacet();
        new AutoCompoundFacet();
        new SweepFacet();
        new ReferralFacet();
        new Permit2ReferralFacet();
        new CohortRecorderFacet();
        new CohortHookFacet();
        new CohortBridgeHookFacet();
        new CohortMoveHookFacet();
        new CohortFlushFacet();
        new CohortFlushPolicyFacet();
        new ReferralPayoutFacet();

        new ReferralRegistry(
            vm.addr(
                privKey
            ),
            REHEARSAL_CHAIN_RANK
        );

        new ReferralHubCheckpointsFacet();
        new ReferralHubRatesFacet();
        new ReferralHubIntakeFacet();
        new ReferralHubMailboxFacet();
        new ReferralHubPayoutFacet();

        ReferralHub hub = new ReferralHub(
            usd
        );

        new ReferralHubReader(
            address(hub)
        );

        vm.stopBroadcast();

        console2.log(
            "rehearsal hub",
            address(hub)
        );
    }
}
