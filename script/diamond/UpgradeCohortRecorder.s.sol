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

import {WiseTelecomNodesDiamondSelectors} from "./WiseTelecomNodesDiamondSelectors.sol";

/// @notice SUPERSEDED by {UpgradeReferralRegistry}: do not broadcast. The slot-77
/// registry-pointer shard recompiles every facet in this manifest and the referral facets now
/// write the per-chain standalone {ReferralRegistry}, so installing this
/// script's builds would route stale bytecode. Kept for the historical record; its full
/// per-chain fork rehearsal passed before it was superseded.
///
/// Installs the cohort recorder of the referral commission system on an
/// already-running, finalized diamond, and (because the recorder changes the compiled
/// bytecode of every balance-moving facet through the shared helper chain) redeploys the
/// full facet-change manifest in the same timelock round. Supersedes {UpgradeReferral}: the
/// never-installed referral groups ride this manifest (their facets recompile here anyway).
///
/// One round, three phases:
///   `propose()`  : deploys the 11 manifest facets, proposes all 10 selector batches AND the
///                  transfer-hook swap to {CohortHookFacet}; both 3-day clocks start together.
///   `execute()`  : after the timelocks: flips every batch, hook last. Address-free (the
///                  diamond reads its own proposal storage) and idempotent: each batch is
///                  guarded by its queuedAt stamp, so a partially-mined execute can be re-run.
///   `arm()`      : the separate go-live step: `setCohortSyncEnabled(true)` (probes the
///                  installed hook and reverts if it is not cohort-aware) and raises
///                  `bridgeGasLimit` to 1M so a dormant-book clamp inside `ccipReceive`
///                  always fits (keeper `advanceBook` cadence keeps the case
///                  rare, CCIP manual re-execution is the backstop).
///   `abort()`    : cancels every pending batch and the hook proposal (pre-execute only).
///   `status()`   : read-only sanity print for the runbook (no broadcast).
///
/// Every intermediate state is safe: all recorder touchpoints are gated no-ops until arm(),
/// so old-hook/new-facet mixtures behave exactly like today's live system; the only ungated
/// change at execute() is the referral-group install, which is write-once slot-67 state
/// rehearsed by {ReferralUpgradeFork}. Rollback: pre-execute abort(); post-arm
/// `setCohortSyncEnabled(false)` is instant, and the hook can be re-proposed back to
/// {GraceFreezeHookFacet} (DISARM FIRST: an armed diamond delegatecalls cohort selectors on
/// whatever hook is installed).
///
/// Per-vault invocation (9 live vaults; product via VAULT_PRODUCT env, chain via --rpc-url):
///   VAULT_PRODUCT=usdc forge script script/diamond/UpgradeCohortRecorder.s.sol --sig "propose()" --rpc-url mainnet --broadcast
///   ... wait 3 days ...
///   VAULT_PRODUCT=usdc forge script script/diamond/UpgradeCohortRecorder.s.sol --sig "execute()" --rpc-url mainnet --broadcast
///   VAULT_PRODUCT=usdc forge script script/diamond/UpgradeCohortRecorder.s.sol --sig "arm()" --rpc-url mainnet --broadcast
/// repeated for usdc/usdt/usdg on each of their chains (mainnet, base, arbitrum, robinhood).
///
/// NOTHING here may be broadcast until the owner gives the explicit go-ahead. After a REAL
/// broadcast is executed and verified, `git mv` the graduated
/// files out of src/diamond/vault/facets/pending/ in the same commit.
contract UpgradeCohortRecorder is VaultConfig {

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

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._adminSelectors(),
            adminFacet
        );

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._userSelectors(),
            userFacet
        );

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._permit2Selectors(),
            permit2UserFacet
        );

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._moveSelectors(),
            moveFacet
        );

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._bridgeSelectors(),
            bridgeFacet
        );

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._queueJoinLeaveSelectors(),
            queueJoinLeaveFacet
        );

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._queueFulfillSelectors(),
            queueFulfillFacet
        );

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._referralSelectors(),
            referralFacet
        );

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._permit2ReferralSelectors(),
            permit2ReferralFacet
        );

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._cohortRecorderSelectors(),
            cohortRecorderFacet
        );

        AdminFacet(diamond).proposeTransferHookFacet(
            cohortHookFacet
        );

        vm.stopBroadcast();

        console2.log(
            "proposed cohort-recorder upgrade on diamond",
            diamond
        );

        console2.log(
            "  AdminFacet          ",
            adminFacet
        );

        console2.log(
            "  UserFacet           ",
            userFacet
        );

        console2.log(
            "  Permit2UserFacet    ",
            permit2UserFacet
        );

        console2.log(
            "  MoveFacet           ",
            moveFacet
        );

        console2.log(
            "  BridgeFacet         ",
            bridgeFacet
        );

        console2.log(
            "  QueueJoinLeaveFacet ",
            queueJoinLeaveFacet
        );

        console2.log(
            "  QueueFulfillFacet   ",
            queueFulfillFacet
        );

        console2.log(
            "  ReferralFacet       ",
            referralFacet
        );

        console2.log(
            "  Permit2ReferralFacet",
            permit2ReferralFacet
        );

        console2.log(
            "  CohortRecorderFacet ",
            cohortRecorderFacet
        );

        console2.log(
            "  CohortHookFacet     ",
            cohortHookFacet
        );

        console2.log(
            "earliest execute()",
            block.timestamp + 3 days
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

        _executeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._adminSelectors()
        );

        _executeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._userSelectors()
        );

        _executeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._permit2Selectors()
        );

        _executeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._moveSelectors()
        );

        _executeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._bridgeSelectors()
        );

        _executeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._queueJoinLeaveSelectors()
        );

        _executeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._queueFulfillSelectors()
        );

        _executeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._referralSelectors()
        );

        _executeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._permit2ReferralSelectors()
        );

        _executeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._cohortRecorderSelectors()
        );

        if (WiseTelecomNodesDiamond(payable(diamond)).transferHookChangeQueuedAt() > 0) {
            AdminFacet(diamond).executeTransferHookFacetChange();
        }

        vm.stopBroadcast();

        console2.log(
            "executed cohort-recorder upgrade on diamond",
            diamond
        );

        console2.log(
            "run arm() to enable recording (separate go-live step)"
        );
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

        vm.startBroadcast(
            privKey
        );

        AdminFacet(diamond).setCohortSyncEnabled(
            true
        );

        BridgeFacet(diamond).setBridgeGasLimit(
            1_000_000
        );

        vm.stopBroadcast();

        console2.log(
            "armed cohort recorder on diamond",
            diamond
        );
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
            WiseTelecomNodesDiamondSelectors._adminSelectors()
        );

        _cancelGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._userSelectors()
        );

        _cancelGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._permit2Selectors()
        );

        _cancelGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._moveSelectors()
        );

        _cancelGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._bridgeSelectors()
        );

        _cancelGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._queueJoinLeaveSelectors()
        );

        _cancelGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._queueFulfillSelectors()
        );

        _cancelGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._referralSelectors()
        );

        _cancelGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._permit2ReferralSelectors()
        );

        _cancelGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors._cohortRecorderSelectors()
        );

        if (WiseTelecomNodesDiamond(payable(diamond)).transferHookChangeQueuedAt() > 0) {
            AdminFacet(diamond).cancelTransferHookFacetChange();
        }

        vm.stopBroadcast();

        console2.log(
            "aborted pending cohort-recorder upgrade on diamond",
            diamond
        );
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

        WiseTelecomNodesDiamond d = WiseTelecomNodesDiamond(
            payable(diamond)
        );

        console2.log(
            "diamond",
            diamond
        );

        console2.log(
            "admin group facet",
            d.selectorToFacet(
                WiseTelecomNodesDiamondSelectors._adminSelectors()[0]
            )
        );

        console2.log(
            "user group facet",
            d.selectorToFacet(
                WiseTelecomNodesDiamondSelectors._userSelectors()[0]
            )
        );

        console2.log(
            "cohort group facet",
            d.selectorToFacet(
                WiseTelecomNodesDiamondSelectors._cohortRecorderSelectors()[0]
            )
        );

        console2.log(
            "referral group facet",
            d.selectorToFacet(
                WiseTelecomNodesDiamondSelectors._referralSelectors()[0]
            )
        );

        console2.log(
            "transferHookFacet",
            d.transferHookFacet()
        );

        console2.log(
            "proposedTransferHookFacet",
            d.proposedTransferHookFacet()
        );

        if (d.selectorToFacet(WiseTelecomNodesDiamondSelectors._cohortRecorderSelectors()[0]) != address(0)) {
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
