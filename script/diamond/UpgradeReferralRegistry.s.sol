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
import {CohortMoveHookFacet} from "../../src/diamond/vault/facets/pending/CohortMoveHookFacet.sol";
import {ReferralRegistry} from "../../src/registry/pending/ReferralRegistry.sol";
import {IReferralRegistry} from "../../src/diamond/vault/interfaces/pending/IReferralRegistry.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";

import {WiseTelecomNodesDiamondSelectors} from "./WiseTelecomNodesDiamondSelectors.sol";

/// @notice Installs the referral-registry round
/// on an already-running, finalized diamond: the cohort recorder manifest
/// PLUS the slot-77 registry pointer. Supersedes {UpgradeCohortRecorder} (which superseded
/// {UpgradeReferral}): the slot-77 shard recompiles every facet in the manifest and the
/// referral facets now write the per-chain standalone {ReferralRegistry}, so installing the
/// older script's builds would route stale bytecode. The LIVE diamond entry contracts are
/// never redeployed and never migrated: this round only deploys NEW facet contracts and
/// routes selectors through the diamond's existing 3-day timelock, plus one pointer write.
///
/// Prerequisite (once per CHAIN, not per vault): {DeployReferralRegistry} has deployed the
/// chain's registry, allowlisted this diamond, and recorded the address in
/// `config/registry.<network>.json`; `propose()` fail-fasts if not.
///
/// TWO chained 3-day clocks per vault; the pointer trio selectors are NEW (not
/// genesis-routed), so `proposeReferralRegistry` only exists on the diamond after the
/// selector round executes:
///   `propose()`        : deploys the 13 manifest facets, proposes all 12 selector batches
///                        AND the transfer-hook swap to {CohortHookFacet}. Clock 1 starts.
///                        The routed move slice {CohortMoveHookFacet} ships in this round
///                        beside the routed bridge slice and the pointer swap, because the
///                        pointer facet forwards the move pair into it by selector.
///   `execute()`        : after 3 days: flips every batch, hook last. Idempotent
///                        (queuedAt-guarded), re-runnable after partial mining. Then
///                        asserts, in simulation and before anything is sent, that every
///                        selector of the twelve batches routes to a facet and has no
///                        proposal left queued (the legacy pair excepted, whose optional
///                        retirement routes it to zero). A batch that carries a selector
///                        the genesis dispatcher never routed (the admin batch's
///                        post-genesis selectors and the referral, permit2 referral,
///                        recorder, bridge hook and move hook batches) fails the run when
///                        its proposal was missing or cancelled, and a batch skipped
///                        because its first selector was cancelled fails it too. The user,
///                        permit2, move, bridge and both queue batches hold only genesis
///                        selectors and keep their genesis facet when their proposal is
///                        missing, so compare the per-batch facets `status()` prints with
///                        the ones `propose()` logged.
///   `proposePointer()` : same day as execute(): first runs the registry seam probe that
///                        `executePointer()` runs (below) against the config registry, so a
///                        registry that would fail it is refused three days earlier; then
///                        starts clock 2 through the freshly-routed {AdminFacet} trio,
///                        pointing at the config registry. A pending proposal of the config
///                        registry is reported and left; a pending proposal naming any other
///                        address is cancelled and the config registry proposed in the same
///                        broadcast, which restarts clock 2. With the pointer already wired
///                        to the config registry it proposes nothing and only cancels a
///                        mismatched pending proposal.
///   `executePointer()` : after 3 more days: first probes the config registry for every
///                        seam the vault calls (staticcalls of `referrerOf`,
///                        `effectiveReferrerOf`, `getReferrerPair`,
///                        `getPayoutDesignation`, `seedsLatched` and
///                        `syncPeerQuarantined` for every chain of the vault's mesh
///                        manifest, each answer held to the size and bounds the vault's
///                        own decoders apply, plus `allowedVault(diamond)` in place of the
///                        four write seams a staticcall cannot probe) and reverts on an
///                        unclean answer; then executes the pointer change (code + shape
///                        probe onchain) and post-asserts pointer == config. It refuses a
///                        registry whose sync setup is not finalized yet. On an armed vault the
///                        AdminFacet refuses the execute while a change is pending: disarm
///                        first, run `executePointer()`, then run `arm()` again.
///   `arm()`            : the separate go-live step: pre-asserts pointer wired, this diamond
///                        allowlisted on the registry, the registry's sync setup finalized,
///                        and every vault recorded for this chain (each product's vault
///                        config for this network; a product with no config here, or a
///                        recorded address without code, is skipped) routing the round's
///                        recorder, bridge hook and move hook batches. It then raises
///                        `bridgeGasLimit` to 4M (headroom for the atomic cross-chain carry
///                        apply on `ccipReceive`) BEFORE `setCohortSyncEnabled(true)` (which
///                        itself requires the pointer onchain), so no bridge ever leaves an
///                        armed vault under the 200k genesis budget, and post-asserts both
///                        values.
///   `proposeRetireLegacyReferralBridge()` : OPTIONAL, a rollout parameter decision, any
///                        day after execute(): proposes the genesis passthrough pair
///                        `bridgeToVaultWithReferral` / `quoteBridgeFeeWithReferral` to the
///                        zero facet. The armed carry never needs caller bytes (both bridge
///                        entrypoints send identical wires once armed) and the name misleads
///                        about the referral system, so the pair is pure surface. Its own
///                        3-day clock, independent of the pointer clock; guarded on the
///                        round being executed and no bridge-group proposal pending. A
///                        pending zero-facet proposal of both selectors is reported and
///                        left; a pending proposal of either selector naming anything else
///                        is cancelled and the retirement proposed in the same broadcast.
///   `executeRetireLegacyReferralBridge()` : after 3 days: the pair routes to zero and the
///                        live fallback reverts {FacetNotFound} for both; `bridgeToVault`
///                        and `quoteBridgeFee` are post-asserted untouched. Reversible by a
///                        normal proposal of the pair back to the round's BridgeFacet.
///   `abort()`          : while the round is unexecuted (the recorder batch routes to no
///                        facet), cancels every pending selector batch of the round and the
///                        hook proposal. Once the recorder batch routes it treats the round as
///                        executed and leaves every selector batch and the hook alone, because
///                        the flush and payout rounds re-propose the admin batch and the flush
///                        round the hook; a partially mined `execute()` is finished by running
///                        `execute()` again. It never touches a pending legacy retirement,
///                        which is proposable only after the round executed: cancel that with
///                        one master `cancelSelectorProposal` per selector of the pair. The
///                        pointer proposal is cancelled in both cases (pre-execute only); the
///                        log names the branch taken.
///   `status()`         : read-only sanity print for the runbook (no broadcast), including
///                        `bridgeGasLimit` and the facet each of the twelve batches routes to
///                        (batch order of `propose()`).
///
/// Ordering law the steps encode: registry deployed → diamond
/// allowlisted → selectors live → pointer wired → arm LAST. Every intermediate state is
/// default-off: recorder touchpoints are gated no-ops until arm(), `...WithReferral`
/// entrypoints revert {ReferralRegistryNotSet} while the pointer is unset (loud, no silent
/// referrer drop), and the recorder's registry read is a guarded staticcall whose failure,
/// an unset pointer included, is reported as a failed lookup that defers the mutation.
/// Rollback: pre-execute abort(); post-arm `setCohortSyncEnabled(false)`
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
/// files out of EVERY pending/ segment in the same commit: facets/pending/,
/// declarations/pending/ (the shards this round's facets were compiled with),
/// interfaces/pending/ and src/registry/pending/.
contract UpgradeReferralRegistry is VaultConfig {

    struct CohortEngineFacets {
        address recorderFacet;
        address hookFacet;
        address bridgeHookFacet;
        address moveHookFacet;
    }

    uint256 internal constant ARMED_BRIDGE_GAS_LIMIT = 4_000_000;

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

        CohortEngineFacets memory cohort;
        cohort.recorderFacet = address(new CohortRecorderFacet());
        cohort.hookFacet = address(new CohortHookFacet());
        cohort.bridgeHookFacet = address(new CohortBridgeHookFacet());
        cohort.moveHookFacet = address(new CohortMoveHookFacet());

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
            cohort.recorderFacet
        );

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.cohortBridgeHookSelectors(),
            cohort.bridgeHookFacet
        );

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.cohortMoveHookSelectors(),
            cohort.moveHookFacet
        );

        AdminFacet(diamond).proposeTransferHookFacet(
            cohort.hookFacet
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
        console2.log("  CohortRecorderFacet ", cohort.recorderFacet);
        console2.log("  CohortHookFacet     ", cohort.hookFacet);
        console2.log("  CohortBridgeHookFacet", cohort.bridgeHookFacet);
        console2.log("  CohortMoveHookFacet ", cohort.moveHookFacet);
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

        _executeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.cohortMoveHookSelectors()
        );

        if (WiseTelecomNodesDiamond(payable(diamond)).transferHookChangeQueuedAt() > 0) {
            AdminFacet(diamond).executeTransferHookFacetChange();
        }

        vm.stopBroadcast();

        bytes4[][] memory groups = _roundGroups();

        for (uint256 i; i < groups.length; ++i) {
            _assertGroupRouted(
                diamond,
                groups[i]
            );
        }

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

        _assertRegistrySeams(
            registry,
            diamond,
            _meshLaneSelectors()
        );

        bool pending = AdminFacet(diamond).getReferralRegistryChangeQueuedAt() > 0;

        address proposed = AdminFacet(diamond).getProposedReferralRegistry();

        if (pending && proposed == registry) {
            console2.log("pointer proposal for the config registry already pending on diamond", diamond);
            return;
        }

        bool wired = AdminFacet(diamond).getReferralRegistry() == registry;

        if (wired && pending == false) {
            console2.log("pointer already wired to the config registry on diamond", diamond);
            return;
        }

        if (pending) {
            console2.log("cancelling mismatched pending pointer proposal", proposed);
        }

        vm.startBroadcast(
            privKey
        );

        if (pending) {
            AdminFacet(diamond).cancelReferralRegistryChange();
        }

        if (wired) {
            vm.stopBroadcast();

            console2.log("pointer already wired to the config registry; cancelled the mismatched proposal only on diamond", diamond);
            return;
        }

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

        _assertRegistrySeams(
            registry,
            diamond,
            _meshLaneSelectors()
        );

        require(
            ReferralRegistry(registry).syncInitialized(),
            "UpgradeReferralRegistry: registry sync setup not finalized (run RegisterRegistrySyncPeers.finalize() first)"
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

        require(
            registry.syncInitialized(),
            "UpgradeReferralRegistry: registry sync setup not finalized (run RegisterRegistrySyncPeers.finalize() first)"
        );

        _assertChainRoundExecuted(
            _networkName()
        );

        vm.startBroadcast(
            privKey
        );

        BridgeFacet(diamond).setBridgeGasLimit(
            ARMED_BRIDGE_GAS_LIMIT
        );

        AdminFacet(diamond).setCohortSyncEnabled(
            true
        );

        vm.stopBroadcast();

        require(
            BridgeFacet(diamond).bridgeGasLimit() == ARMED_BRIDGE_GAS_LIMIT,
            "UpgradeReferralRegistry: bridgeGasLimit is not the armed budget after arm()"
        );

        require(
            CohortRecorderFacet(diamond).getCohortSyncEnabled(),
            "UpgradeReferralRegistry: cohortSyncEnabled is not true after arm()"
        );

        console2.log("armed cohort recorder on diamond", diamond);
        console2.log("  bridgeGasLimit", uint256(BridgeFacet(diamond).bridgeGasLimit()));
    }

    function proposeRetireLegacyReferralBridge()
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

        WiseTelecomNodesDiamond d = WiseTelecomNodesDiamond(
            payable(diamond)
        );

        bytes4[] memory pair = WiseTelecomNodesDiamondSelectors.legacyReferralBridgeSelectors();

        require(
            d.selectorToFacet(WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors()[0]) != address(0),
            "UpgradeReferralRegistry: registry round not executed yet (run execute() first)"
        );

        address bridgeFacet = d.selectorToFacet(
            BridgeFacet.bridgeToVault.selector
        );

        require(
            bridgeFacet != address(0)
                && d.selectorToFacet(pair[0]) == bridgeFacet
                && d.selectorToFacet(pair[1]) == bridgeFacet,
            "UpgradeReferralRegistry: legacy pair not on the round's BridgeFacet"
        );

        require(
            d.selectorChangeQueuedAt(BridgeFacet.bridgeToVault.selector) == 0,
            "UpgradeReferralRegistry: bridge group proposal still pending (execute() first)"
        );

        bool pending = d.selectorChangeQueuedAt(pair[0]) > 0
            || d.selectorChangeQueuedAt(pair[1]) > 0;

        bool pendingMatches = d.selectorChangeQueuedAt(pair[0]) > 0
            && d.selectorChangeQueuedAt(pair[1]) > 0
            && d.proposedSelectorFacet(pair[0]) == address(0)
            && d.proposedSelectorFacet(pair[1]) == address(0);

        if (pendingMatches) {
            console2.log("legacy referral bridge retirement already pending on diamond", diamond);
            return;
        }

        if (pending) {
            console2.log("cancelling mismatched pending proposal of the legacy pair, bridge selector facet", d.proposedSelectorFacet(pair[0]));
            console2.log("  quote selector facet", d.proposedSelectorFacet(pair[1]));
        }

        vm.startBroadcast(
            privKey
        );

        if (pending) {
            _cancelGroup(
                diamond,
                pair
            );
        }

        _proposeGroup(
            diamond,
            pair,
            address(0)
        );

        vm.stopBroadcast();

        console2.log("proposed legacy referral bridge retirement on diamond", diamond);
        console2.log("earliest executeRetireLegacyReferralBridge()", block.timestamp + 3 days);
    }

    function executeRetireLegacyReferralBridge()
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

        WiseTelecomNodesDiamond d = WiseTelecomNodesDiamond(
            payable(diamond)
        );

        bytes4[] memory pair = WiseTelecomNodesDiamondSelectors.legacyReferralBridgeSelectors();

        vm.startBroadcast(
            privKey
        );

        _executeGroup(
            diamond,
            pair
        );

        vm.stopBroadcast();

        require(
            d.selectorToFacet(pair[0]) == address(0)
                && d.selectorToFacet(pair[1]) == address(0),
            "UpgradeReferralRegistry: legacy pair still routed (propose the retirement first)"
        );

        require(
            d.selectorToFacet(BridgeFacet.bridgeToVault.selector) != address(0),
            "UpgradeReferralRegistry: bridgeToVault lost its route"
        );

        require(
            d.selectorToFacet(BridgeFacet.quoteBridgeFee.selector) != address(0),
            "UpgradeReferralRegistry: quoteBridgeFee lost its route"
        );

        console2.log("retired legacy referral bridge on diamond", diamond);
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

        WiseTelecomNodesDiamond d = WiseTelecomNodesDiamond(
            payable(diamond)
        );

        bool roundExecuted = d.selectorToFacet(WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors()[0]) != address(0);

        vm.startBroadcast(
            privKey
        );

        if (roundExecuted == false) {

            bytes4[][] memory groups = _roundGroups();

            for (uint256 i; i < groups.length; ++i) {
                _cancelGroup(
                    diamond,
                    groups[i]
                );
            }

            if (d.transferHookChangeQueuedAt() > 0) {
                AdminFacet(diamond).cancelTransferHookFacetChange();
            }
        }

        if (d.selectorToFacet(AdminFacet.getReferralRegistryChangeQueuedAt.selector) != address(0)) {
            if (AdminFacet(diamond).getReferralRegistryChangeQueuedAt() > 0) {
                AdminFacet(diamond).cancelReferralRegistryChange();
            }
        }

        vm.stopBroadcast();

        if (roundExecuted == false) {
            console2.log("round unexecuted: cancelled every selector batch, the hook proposal and any pointer proposal on diamond", diamond);
        } else {
            console2.log("round executed: left every selector batch, the hook and any legacy retirement alone, cancelled any pending pointer proposal on diamond", diamond);
        }
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
            "cohort move hook facet",
            d.selectorToFacet(WiseTelecomNodesDiamondSelectors.cohortMoveHookSelectors()[0])
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

        console2.log(
            "bridgeGasLimit",
            uint256(BridgeFacet(diamond).bridgeGasLimit())
        );

        bytes4[][] memory groups = _roundGroups();

        for (uint256 i; i < groups.length; ++i) {
            console2.log("round batch facet", i, d.selectorToFacet(groups[i][0]));
        }

        bytes4[] memory pair = WiseTelecomNodesDiamondSelectors.legacyReferralBridgeSelectors();

        console2.log(
            "legacy bridgeToVaultWithReferral facet",
            d.selectorToFacet(pair[0])
        );

        console2.log(
            "legacy retirement queuedAt",
            d.selectorChangeQueuedAt(pair[0])
        );
    }

    /// @dev Probes `_registry` for every seam the vault calls, before the vault's registry
    /// pointer may be proposed or executed toward it. Each read the vault makes is
    /// staticcalled and held to the size and bounds the vault's own decoder applies; the four
    /// write seams (`assignReferrer`, `mergeReferrer`, `stageCarry`, `consumeCarry`) cannot be
    /// staticcalled, since each writes and is gated to an allowlisted vault, so the read of
    /// `allowedVault(_diamond)` stands in for them. Every probe answers cleanly on the real
    /// {ReferralRegistry}, and a replacement registry must answer the same way.
    function _assertRegistrySeams(
        address _registry,
        address _diamond,
        uint64[] memory _laneSelectors
    )
        internal
        view
    {
        require(
            _registry.code.length > 0,
            "UpgradeReferralRegistry: config registry has no code"
        );

        uint256[] memory words = _probeRegistry(
            _registry,
            abi.encodeWithSelector(
                IReferralRegistry.referrerOf.selector,
                _diamond
            ),
            1
        );

        require(
            words[0] <= type(uint160).max,
            "UpgradeReferralRegistry: referrerOf answer is not a clean address"
        );

        words = _probeRegistry(
            _registry,
            abi.encodeWithSelector(
                IReferralRegistry.effectiveReferrerOf.selector,
                _diamond,
                _diamond
            ),
            1
        );

        require(
            words[0] <= type(uint160).max,
            "UpgradeReferralRegistry: effectiveReferrerOf answer is not a clean address"
        );

        words = _probeRegistry(
            _registry,
            abi.encodeWithSelector(
                IReferralRegistry.getReferrerPair.selector,
                _diamond
            ),
            3
        );

        require(
            words[0] <= type(uint160).max
                && words[1] <= CohortWeeks.RING_LANE_MAX
                && words[2] <= CohortWeeks.CARRY_BYTE_MASK,
            "UpgradeReferralRegistry: getReferrerPair answer outside the vault's decode bounds"
        );

        words = _probeRegistry(
            _registry,
            abi.encodeWithSelector(
                IReferralRegistry.getPayoutDesignation.selector,
                _diamond
            ),
            2
        );

        require(
            words[0] <= type(uint160).max
                && (words[1] >> CohortWeeks.DESIGNATION_STAMP_SHIFT) <= CohortWeeks.RING_LANE_MAX,
            "UpgradeReferralRegistry: getPayoutDesignation answer outside the vault's decode bounds"
        );

        words = _probeRegistry(
            _registry,
            abi.encodeWithSelector(
                IReferralRegistry.seedsLatched.selector
            ),
            1
        );

        require(
            words[0] <= 1,
            "UpgradeReferralRegistry: seedsLatched answer is not a clean bool"
        );

        for (uint256 i; i < _laneSelectors.length; ++i) {

            words = _probeRegistry(
                _registry,
                abi.encodeWithSelector(
                    IReferralRegistry.syncPeerQuarantined.selector,
                    _laneSelectors[i]
                ),
                1
            );

            require(
                words[0] <= 1,
                "UpgradeReferralRegistry: syncPeerQuarantined answer is not a clean bool"
            );

            console2.log("  lane selector", uint256(_laneSelectors[i]));
            console2.log("    quarantined", words[0] == 1);
        }

        require(
            ReferralRegistry(_registry).allowedVault(_diamond),
            "UpgradeReferralRegistry: diamond not allowlisted on the registry, so assignReferrer, mergeReferrer, stageCarry and consumeCarry would refuse it"
        );

        console2.log("registry seam probes clean", _registry);
    }

    function _probeRegistry(
        address _registry,
        bytes memory _calldata,
        uint256 _wordCount
    )
        internal
        view
        returns (uint256[] memory words)
    {
        (
            bool success,
            bytes memory returnData
        ) = _registry.staticcall(
            _calldata
        );

        require(
            success && returnData.length == _wordCount * 32,
            "UpgradeReferralRegistry: registry seam probe failed or returned the wrong size"
        );

        words = new uint256[](
            _wordCount
        );

        for (uint256 i; i < _wordCount; ++i) {

            uint256 word;

            assembly {
                word := mload(add(returnData, mul(add(i, 1), 32)))
            }

            words[i] = word;
        }
    }

    function _meshLaneSelectors()
        internal
        view
        returns (uint64[] memory selectors)
    {
        string[] memory chains = _loadMesh().chains;

        selectors = new uint64[](
            chains.length
        );

        for (uint256 i; i < chains.length; ++i) {
            selectors[i] = _loadCcipChainSelector(
                chains[i]
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

    /// @dev The twelve selector batches this round proposes and executes, in the order
    /// `propose()` and `execute()` handle them; `execute()` asserts them routed, `status()`
    /// prints their facets and `abort()` cancels them while the round is unexecuted.
    function _roundGroups()
        internal
        pure
        returns (bytes4[][] memory groups)
    {
        groups = new bytes4[][](
            12
        );

        groups[0] = WiseTelecomNodesDiamondSelectors.adminSelectors();
        groups[1] = WiseTelecomNodesDiamondSelectors.userSelectors();
        groups[2] = WiseTelecomNodesDiamondSelectors.permit2Selectors();
        groups[3] = WiseTelecomNodesDiamondSelectors.moveSelectors();
        groups[4] = WiseTelecomNodesDiamondSelectors.bridgeSelectors();
        groups[5] = WiseTelecomNodesDiamondSelectors.queueJoinLeaveSelectors();
        groups[6] = WiseTelecomNodesDiamondSelectors.queueFulfillSelectors();
        groups[7] = WiseTelecomNodesDiamondSelectors.referralSelectors();
        groups[8] = WiseTelecomNodesDiamondSelectors.permit2ReferralSelectors();
        groups[9] = WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors();
        groups[10] = WiseTelecomNodesDiamondSelectors.cohortBridgeHookSelectors();
        groups[11] = WiseTelecomNodesDiamondSelectors.cohortMoveHookSelectors();
    }

    /// @dev Asserts that every selector of `_sels` routes to a facet on `_diamond` and has
    /// no proposal left queued. A selector the genesis dispatcher never routed fails the
    /// route check when its batch proposal was missing or cancelled; a batch that
    /// `_executeGroup` skipped because only its first selector was cancelled fails the queue
    /// check. A selector the genesis dispatcher already routed passes the route check with
    /// its genesis facet, so the user, permit2, move, bridge and both queue batches, which
    /// hold only genesis selectors, are checked by comparing the batch facets `status()`
    /// prints with the ones `propose()` logged. The legacy referral bridge pair is exempt:
    /// its optional retirement queues it and routes it to zero on purpose, and `execute()`
    /// stays re-runnable after that retirement.
    function _assertGroupRouted(
        address _diamond,
        bytes4[] memory _sels
    )
        internal
        view
    {
        WiseTelecomNodesDiamond d = WiseTelecomNodesDiamond(
            payable(_diamond)
        );

        bytes4[] memory pair = WiseTelecomNodesDiamondSelectors.legacyReferralBridgeSelectors();

        for (uint256 i; i < _sels.length; ++i) {

            if (_sels[i] == pair[0] || _sels[i] == pair[1]) {
                continue;
            }

            require(
                d.selectorToFacet(_sels[i]) != address(0),
                "UpgradeReferralRegistry: a selector this round adds routes to no facet after execute() (its batch proposal was missing or cancelled)"
            );

            require(
                d.selectorChangeQueuedAt(_sels[i]) == 0,
                "UpgradeReferralRegistry: a round selector is still queued after execute() (its batch was skipped because its first selector was cancelled)"
            );
        }
    }

    /// @dev Holds the same-chain arming order before any vault of this chain arms: every
    /// vault recorded for `_network` (each product's `config/vault.<product>.<network>.json`;
    /// a product with no config on this chain is skipped, and so is a recorded address with
    /// no code) must already route the round's recorder, bridge hook and move hook batches,
    /// because the vaults of one chain are live same-chain peers that carry moves and queue
    /// traffic between each other.
    function _assertChainRoundExecuted(
        string memory _network
    )
        internal
        view
    {
        string[3] memory products = [
            "usdc",
            "usdt",
            "usdg"
        ];

        for (uint256 i; i < products.length; ++i) {

            if (vm.exists(_vaultConfigPath(products[i], _network)) == false) {
                continue;
            }

            address vault = _loadVaultDiamond(
                products[i],
                _network
            );

            if (vault.code.length == 0) {
                continue;
            }

            WiseTelecomNodesDiamond v = WiseTelecomNodesDiamond(
                payable(vault)
            );

            require(
                v.selectorToFacet(WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors()[0]) != address(0)
                    && v.selectorToFacet(WiseTelecomNodesDiamondSelectors.cohortBridgeHookSelectors()[0]) != address(0)
                    && v.selectorToFacet(WiseTelecomNodesDiamondSelectors.cohortMoveHookSelectors()[0]) != address(0),
                string.concat(
                    "UpgradeReferralRegistry: the ",
                    products[i],
                    " vault of this chain has not executed the registry round (run execute() on every vault of the chain before any arm())"
                )
            );

            console2.log("  same-chain vault round executed", products[i], vault);
        }
    }
}
