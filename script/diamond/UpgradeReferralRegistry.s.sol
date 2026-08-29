// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {VaultConfig} from "../vault/VaultConfig.sol";
import {WiseTelecomNodesDiamond} from "../../src/diamond/vault/WiseTelecomNodesDiamond.sol";

import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {Permit2UserFacet} from "../../src/diamond/vault/facets/Permit2UserFacet.sol";
import {MoveFacet} from "../../src/diamond/vault/facets/MoveFacet.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../src/diamond/vault/facets/QueueFulfillFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {Permit2ReferralFacet} from "../../src/diamond/vault/facets/pending/Permit2ReferralFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortBridgeHookFacet} from "../../src/diamond/vault/facets/pending/CohortBridgeHookFacet.sol";
import {ReferralRegistry} from "../../src/registry/pending/ReferralRegistry.sol";

import {WiseTelecomNodesDiamondSelectors} from "./WiseTelecomNodesDiamondSelectors.sol";

/// @notice Installs the referral-registry round
/// on an already-running, finalized diamond: the cohort recorder manifest
/// PLUS the slot-77 registry pointer. Supersedes {UpgradeCohortRecorder} (which superseded
/// {UpgradeReferral}): the slot-77 shard recompiles every facet in the manifest and the
/// referral facets now write the per-chain standalone {ReferralRegistry}, so installing the
/// older script's builds would route stale bytecode. The LIVE diamond entry contracts are
/// never redeployed and never migrated — this round only deploys NEW facet contracts and
/// routes selectors through the diamond's existing 3-day timelock, plus one pointer write.
///
/// Prerequisite (once per CHAIN, not per vault): {DeployReferralRegistry} has deployed the
/// chain's registry, allowlisted this diamond, and recorded the address in
/// `config/registry.<network>.json` — `propose()` fail-fasts if not.
///
/// TWO chained 3-day clocks per vault — the pointer trio selectors are NEW (not
/// genesis-routed), so `proposeReferralRegistry` only exists on the diamond after the
/// selector round executes:
///   `propose()`        — deploys the 12 manifest facets, proposes all 11 selector batches
///                        AND the transfer-hook swap to {CohortHookFacet}. Clock 1 starts.
///   `execute()`        — after 3 days: flips every batch, hook last. Idempotent
///                        (queuedAt-guarded), re-runnable after partial mining.
///   `proposePointer()` — same day as execute(): starts clock 2 through the freshly-routed
///                        {AdminFacet} trio, pointing at the config registry. Idempotent.
///   `executePointer()` — after 3 more days: executes the pointer change (code + shape
///                        probe onchain) and post-asserts pointer == config.
///   `arm()`            — the separate go-live step: pre-asserts pointer wired AND this
///                        diamond allowlisted on the registry, then
///                        `setCohortSyncEnabled(true)` (which itself requires the pointer
///                        onchain) and `bridgeGasLimit = 4M` (headroom for the atomic
///                        cross-chain carry apply on `ccipReceive`).
///   `abort()`          — cancels every pending selector batch, the hook proposal and the
///                        pointer proposal (each pre-execute only).
///   `status()`         — read-only sanity print for the runbook (no broadcast).
///
/// Ordering law the steps encode: registry deployed → diamond
/// allowlisted → selectors live → pointer wired → arm LAST. Every intermediate state is
/// default-off: recorder touchpoints are gated no-ops until arm(), `...WithReferral`
/// entrypoints revert {ReferralRegistryNotSet} while the pointer is unset (loud, no silent
/// referrer drop), and the recorder's registry read is a guarded staticcall that degrades
/// to "no referrer". Rollback: pre-execute abort(); post-arm `setCohortSyncEnabled(false)`
/// is instant (DISARM FIRST before any hook re-proposal).
///
/// Per-vault invocation (9 live vaults; product via VAULT_PRODUCT env, chain via --rpc-url):
///   VAULT_PRODUCT=usdc forge script script/diamond/UpgradeReferralRegistry.s.sol --sig "propose()" --rpc-url mainnet --broadcast
///   ... wait 3 days ...
///   VAULT_PRODUCT=usdc forge script script/diamond/UpgradeReferralRegistry.s.sol --sig "execute()" --rpc-url mainnet --broadcast
///   VAULT_PRODUCT=usdc forge script script/diamond/UpgradeReferralRegistry.s.sol --sig "proposePointer()" --rpc-url mainnet --broadcast
///   ... wait 3 days ...
///   VAULT_PRODUCT=usdc forge script script/diamond/UpgradeReferralRegistry.s.sol --sig "executePointer()" --rpc-url mainnet --broadcast
///   VAULT_PRODUCT=usdc forge script script/diamond/UpgradeReferralRegistry.s.sol --sig "arm()" --rpc-url mainnet --broadcast
/// repeated for usdc/usdt/usdg on each of their chains (mainnet, base, arbitrum, robinhood).
///
/// NOTHING here may be broadcast until the owner gives the explicit go-ahead. After a REAL
/// broadcast is executed and verified, `git mv` the graduated
/// files out of EVERY pending/ segment in the same commit — facets/pending/,
/// declarations/pending/ (the shards this round's facets were compiled with),
/// interfaces/pending/ and src/registry/pending/.
contract UpgradeReferralRegistry is VaultConfig {

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

        ReferralRegistry registry = ReferralRegistry(
            _loadRegistry(
                _networkName()
            )
        );

        require(
            address(registry).code.length > 0,
            "UpgradeReferralRegistry: chain registry not deployed (run DeployReferralRegistry first)"
        );

        require(
            registry.allowedVault(diamond),
            "UpgradeReferralRegistry: diamond not allowlisted on the registry (run allow())"
        );

        vm.startBroadcast(
            privKey
        );

        address adminFacet = address(new AdminFacet());
        address userFacet = address(new UserFacet());
        address permit2UserFacet = address(new Permit2UserFacet());
        address moveFacet = address(new MoveFacet());
        address bridgeFacet = address(new BridgeFacet());
        address queueJoinLeaveFacet = address(new QueueJoinLeaveFacet());
        address queueFulfillFacet = address(new QueueFulfillFacet());
        address referralFacet = address(new ReferralFacet());
        address permit2ReferralFacet = address(new Permit2ReferralFacet());
        address cohortRecorderFacet = address(new CohortRecorderFacet());
        address cohortHookFacet = address(new CohortHookFacet());
        address cohortBridgeHookFacet = address(new CohortBridgeHookFacet());

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.adminSelectors(),
            adminFacet
        );

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.userSelectors(),
            userFacet
        );

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.permit2Selectors(),
            permit2UserFacet
        );

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.moveSelectors(),
            moveFacet
        );

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.bridgeSelectors(),
            bridgeFacet
        );

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.queueJoinLeaveSelectors(),
            queueJoinLeaveFacet
        );

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.queueFulfillSelectors(),
            queueFulfillFacet
        );

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.referralSelectors(),
            referralFacet
        );

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.permit2ReferralSelectors(),
            permit2ReferralFacet
        );

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors(),
            cohortRecorderFacet
        );

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.cohortBridgeHookSelectors(),
            cohortBridgeHookFacet
        );

        AdminFacet(diamond).proposeTransferHookFacet(
            cohortHookFacet
        );

        vm.stopBroadcast();

        console2.log("proposed referral-registry upgrade on diamond", diamond);
        console2.log("  registry (per chain)", address(registry));
        console2.log("  AdminFacet          ", adminFacet);
        console2.log("  UserFacet           ", userFacet);
        console2.log("  Permit2UserFacet    ", permit2UserFacet);
        console2.log("  MoveFacet           ", moveFacet);
        console2.log("  BridgeFacet         ", bridgeFacet);
        console2.log("  QueueJoinLeaveFacet ", queueJoinLeaveFacet);
        console2.log("  QueueFulfillFacet   ", queueFulfillFacet);
        console2.log("  ReferralFacet       ", referralFacet);
        console2.log("  Permit2ReferralFacet", permit2ReferralFacet);
        console2.log("  CohortRecorderFacet ", cohortRecorderFacet);
        console2.log("  CohortHookFacet     ", cohortHookFacet);
        console2.log("  CohortBridgeHookFacet", cohortBridgeHookFacet);
        console2.log("earliest execute()", block.timestamp + 3 days);
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

        _executeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.adminSelectors()
        );

        _executeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.userSelectors()
        );

        _executeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.permit2Selectors()
        );

        _executeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.moveSelectors()
        );

        _executeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.bridgeSelectors()
        );

        _executeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.queueJoinLeaveSelectors()
        );

        _executeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.queueFulfillSelectors()
        );

        _executeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.referralSelectors()
        );

        _executeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.permit2ReferralSelectors()
        );

        _executeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors()
        );

        _executeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.cohortBridgeHookSelectors()
        );

        if (WiseTelecomNodesDiamond(payable(diamond)).transferHookChangeQueuedAt() > 0) {
            AdminFacet(diamond).executeTransferHookFacetChange();
        }

        vm.stopBroadcast();

        console2.log("executed referral-registry selector round on diamond", diamond);
        console2.log("run proposePointer() now (second 3-day clock)");
    }

    function proposePointer()
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

        address registry = _loadRegistry(
            _networkName()
        );

        WiseTelecomNodesDiamond d = WiseTelecomNodesDiamond(
            payable(diamond)
        );

        require(
            d.selectorToFacet(AdminFacet.proposeReferralRegistry.selector) != address(0),
            "UpgradeReferralRegistry: pointer trio not routed yet (run execute() first)"
        );

        if (AdminFacet(diamond).getReferralRegistryChangeQueuedAt() > 0) {
            console2.log("pointer proposal already pending on diamond", diamond);
            return;
        }

        vm.startBroadcast(
            privKey
        );

        AdminFacet(diamond).proposeReferralRegistry(
            registry
        );

        vm.stopBroadcast();

        console2.log("proposed registry pointer on diamond", diamond);
        console2.log("  registry", registry);
        console2.log("earliest executePointer()", block.timestamp + 3 days);
    }

    function executePointer()
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

        address registry = _loadRegistry(
            _networkName()
        );

        vm.startBroadcast(
            privKey
        );

        if (AdminFacet(diamond).getReferralRegistryChangeQueuedAt() > 0) {
            AdminFacet(diamond).executeReferralRegistryChange();
        }

        vm.stopBroadcast();

        require(
            AdminFacet(diamond).getReferralRegistry() == registry,
            "UpgradeReferralRegistry: pointer does not match config registry"
        );

        console2.log("registry pointer wired on diamond", diamond);
        console2.log("run arm() to enable recording (separate go-live step)");
    }

    function arm()
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

        ReferralRegistry registry = ReferralRegistry(
            _loadRegistry(
                _networkName()
            )
        );

        require(
            AdminFacet(diamond).getReferralRegistry() == address(registry),
            "UpgradeReferralRegistry: pointer not wired to the config registry"
        );

        require(
            registry.allowedVault(diamond),
            "UpgradeReferralRegistry: diamond not allowlisted on the registry"
        );

        vm.startBroadcast(
            privKey
        );

        AdminFacet(diamond).setCohortSyncEnabled(
            true
        );

        BridgeFacet(diamond).setBridgeGasLimit(
            4_000_000
        );

        vm.stopBroadcast();

        console2.log("armed cohort recorder on diamond", diamond);
    }

    function abort()
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

        _cancelGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.adminSelectors()
        );

        _cancelGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.userSelectors()
        );

        _cancelGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.permit2Selectors()
        );

        _cancelGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.moveSelectors()
        );

        _cancelGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.bridgeSelectors()
        );

        _cancelGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.queueJoinLeaveSelectors()
        );

        _cancelGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.queueFulfillSelectors()
        );

        _cancelGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.referralSelectors()
        );

        _cancelGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.permit2ReferralSelectors()
        );

        _cancelGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors()
        );

        _cancelGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.cohortBridgeHookSelectors()
        );

        if (WiseTelecomNodesDiamond(payable(diamond)).transferHookChangeQueuedAt() > 0) {
            AdminFacet(diamond).cancelTransferHookFacetChange();
        }

        WiseTelecomNodesDiamond d = WiseTelecomNodesDiamond(
            payable(diamond)
        );

        if (d.selectorToFacet(AdminFacet.getReferralRegistryChangeQueuedAt.selector) != address(0)) {
            if (AdminFacet(diamond).getReferralRegistryChangeQueuedAt() > 0) {
                AdminFacet(diamond).cancelReferralRegistryChange();
            }
        }

        vm.stopBroadcast();

        console2.log("aborted pending referral-registry upgrade on diamond", diamond);
    }

    function status()
        external
        view
    {
        (
            address diamond,
        ) = _loadVault(
            _networkName()
        );

        address registry = _loadRegistry(
            _networkName()
        );

        WiseTelecomNodesDiamond d = WiseTelecomNodesDiamond(
            payable(diamond)
        );

        console2.log("diamond", diamond);
        console2.log("config registry", registry);

        console2.log(
            "admin group facet",
            d.selectorToFacet(WiseTelecomNodesDiamondSelectors.adminSelectors()[0])
        );

        console2.log(
            "referral group facet",
            d.selectorToFacet(WiseTelecomNodesDiamondSelectors.referralSelectors()[0])
        );

        console2.log(
            "cohort group facet",
            d.selectorToFacet(WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors()[0])
        );

        console2.log(
            "transferHookFacet",
            d.transferHookFacet()
        );

        console2.log(
            "proposedTransferHookFacet",
            d.proposedTransferHookFacet()
        );

        if (d.selectorToFacet(AdminFacet.getReferralRegistry.selector) != address(0)) {

            console2.log(
                "onchain registry pointer",
                AdminFacet(diamond).getReferralRegistry()
            );

            console2.log(
                "proposed registry pointer",
                AdminFacet(diamond).getProposedReferralRegistry()
            );

            console2.log(
                "pointer queuedAt",
                AdminFacet(diamond).getReferralRegistryChangeQueuedAt()
            );
        }

        if (registry.code.length > 0) {
            console2.log(
                "diamond allowlisted on registry",
                ReferralRegistry(registry).allowedVault(diamond)
            );
        }

        if (d.selectorToFacet(WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors()[0]) != address(0)) {
            console2.log(
                "cohortSyncEnabled",
                CohortRecorderFacet(diamond).getCohortSyncEnabled()
            );
        }
    }

    function _proposeGroup(
        address _diamond,
        bytes4[] memory _sels,
        address _facet
    )
        internal
    {
        WiseTelecomNodesDiamond(payable(_diamond)).proposeSelectors(
            _sels,
            _facet
        );
    }

    function _executeGroup(
        address _diamond,
        bytes4[] memory _sels
    )
        internal
    {
        if (WiseTelecomNodesDiamond(payable(_diamond)).selectorChangeQueuedAt(_sels[0]) == 0) {
            return;
        }

        WiseTelecomNodesDiamond(payable(_diamond)).executeSelectorChanges(
            _sels
        );
    }

    function _cancelGroup(
        address _diamond,
        bytes4[] memory _sels
    )
        internal
    {
        for (uint256 i; i < _sels.length; ++i) {
            WiseTelecomNodesDiamond(payable(_diamond)).cancelSelectorProposal(
                _sels[i]
            );
        }
    }
}
