// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {VaultConfig} from "../vault/VaultConfig.sol";
import {WiseTelecomNodesDiamond} from "../../src/diamond/vault/WiseTelecomNodesDiamond.sol";

import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {SweepFacet} from "../../src/diamond/vault/facets/SweepFacet.sol";
import {ReferralPayoutFacet} from "../../src/diamond/vault/facets/pending/ReferralPayoutFacet.sol";
import {ReferralHub} from "../../src/hub/pending/ReferralHub.sol";

import {WiseTelecomNodesDiamondSelectors} from "./WiseTelecomNodesDiamondSelectors.sol";

/// @notice Installs the referral-payout round on an already-running, finalized diamond:
/// the referralPayout selector group (the routed liability view plus the two hub-gated
/// writers `raisePendingReferralPayout` / `fundReferralPayout`), the AdminFacet redeploy
/// carrying the payout-hub pointer six, and the SweepFacet redeploy whose
/// `_calculateNeededBuffer` reserves `pendingReferralPayout`, the behavioral half of the
/// round, inert while the accumulator is zero. The LIVE diamond entry contracts are never
/// redeployed and never migrated: this round only deploys NEW facet contracts and routes
/// selectors through the diamond's existing 3-day timelock, plus one pointer write.
///
/// Prerequisite (once, on the hub chain): {DeployReferralHub} has deployed the hub against
/// the payout vault's own USD token and recorded the address in `config/hub.<network>.json`
/// (`propose()` fail-fasts if not), and `proposeHub()`/`executeHub()` only run for the ONE
/// payout vault (the usdc product on the hub chain); every other vault runs just
/// `propose()`/`execute()` so the fleet stays uniform while its writers stay dormant behind
/// the zero pointer.
///
/// TWO chained 3-day clocks on the payout vault; the pointer trio selectors are NEW (not
/// genesis-routed), so `proposePayoutHub` only exists on the diamond after the selector
/// round executes:
///   `propose()`    : deploys the 3 manifest facets, proposes all 3 selector batches.
///                    Clock 1 starts.
///   `execute()`    : after 3 days: flips every batch. Idempotent (queuedAt-guarded),
///                    re-runnable after partial mining.
///   `proposeHub()` : payout vault only, same day as execute(): starts clock 2 through the
///                    freshly-routed {AdminFacet} trio, pointing at the config hub.
///   `executeHub()` : after 3 more days: executes the pointer change (code + USD-token
///                    shape probe onchain) and post-asserts pointer == config. Then run
///                    {DeployReferralHub}.wire() so the hub books against this vault.
///   `abort()`      : cancels every pending selector batch and the pointer proposal (each
///                    pre-execute only).
///   `status()`     : read-only sanity print for the runbook (no broadcast).
///
/// Ordering law the steps encode: hub deployed (right token) → selectors live → pointer
/// wired → hub-side wire() LAST. Every intermediate state is default-off: the payout
/// writers revert {NotPayoutHub} while the pointer is unset, the buffer term is `+ 0`
/// while nothing is booked, and the hub in accrual-only mode (no payout vault wired) books
/// nothing and catches up through `bookLiability()` once wired. Rollback: pre-execute
/// abort(); post-wire, proposing the zero pointer detaches the hub after one more 3-day
/// clock.
///
/// Per-vault invocation (product via VAULT_PRODUCT env, chain via --rpc-url):
///   VAULT_PRODUCT=usdc forge script script/diamond/UpgradeReferralPayout.s.sol --sig "propose()" --rpc-url mainnet --broadcast
///   ... wait 3 days ...
///   VAULT_PRODUCT=usdc forge script script/diamond/UpgradeReferralPayout.s.sol --sig "execute()" --rpc-url mainnet --broadcast
///   VAULT_PRODUCT=usdc forge script script/diamond/UpgradeReferralPayout.s.sol --sig "proposeHub()" --rpc-url mainnet --broadcast
///   ... wait 3 days ...
///   VAULT_PRODUCT=usdc forge script script/diamond/UpgradeReferralPayout.s.sol --sig "executeHub()" --rpc-url mainnet --broadcast
///   forge script script/hub/DeployReferralHub.s.sol --sig "wire()" --rpc-url mainnet --broadcast
///
/// NOTHING here may be broadcast until the owner gives the explicit go-ahead. After a REAL
/// broadcast is executed and verified, `git mv` the graduated files out of EVERY pending/
/// segment in the same commit: facets/pending/ (ReferralPayoutFacet),
/// declarations/pending/ (the payout shards this round's facets were compiled with) and
/// src/hub/pending/.
contract UpgradeReferralPayout is VaultConfig {

    function propose()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        (
            address diamond,
            address usd
        ) = _loadVault(
            _networkName()
        );

        address hub;

        if (_isPayoutVault()) {

            require(
                _hubConfigExists(
                    _networkName()
                ),
                "UpgradeReferralPayout: no hub config for this chain (run DeployReferralHub first)"
            );

            hub = _loadHub(
                _networkName()
            );

            require(
                hub.code.length > 0,
                "UpgradeReferralPayout: recorded hub has no code"
            );

            require(
                address(ReferralHub(hub).USD_TOKEN()) == usd,
                "UpgradeReferralPayout: hub USD token does not match the payout vault underlying"
            );
        }

        vm.startBroadcast(
            privKey
        );

        address adminFacet = address(new AdminFacet());
        address sweepFacet = address(new SweepFacet());
        address referralPayoutFacet = address(new ReferralPayoutFacet());

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.adminSelectors(),
            adminFacet
        );

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.sweepSelectors(),
            sweepFacet
        );

        _proposeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.referralPayoutSelectors(),
            referralPayoutFacet
        );

        vm.stopBroadcast();

        console2.log("proposed referral-payout upgrade on diamond", diamond);
        console2.log("  hub (payout vault only)", hub);
        console2.log("  AdminFacet          ", adminFacet);
        console2.log("  SweepFacet          ", sweepFacet);
        console2.log("  ReferralPayoutFacet ", referralPayoutFacet);
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
            WiseTelecomNodesDiamondSelectors.sweepSelectors()
        );

        _executeGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.referralPayoutSelectors()
        );

        vm.stopBroadcast();

        console2.log("executed referral-payout selector round on diamond", diamond);

        if (_isPayoutVault()) {
            console2.log("run proposeHub() now (second 3-day clock)");
        } else {
            console2.log("non-payout vault: no pointer to wire, round complete");
        }
    }

    function proposeHub()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        require(
            _isPayoutVault(),
            "UpgradeReferralPayout: only the payout vault gets a hub pointer"
        );

        (
            address diamond,
        ) = _loadVault(
            _networkName()
        );

        address hub = _loadHub(
            _networkName()
        );

        WiseTelecomNodesDiamond d = WiseTelecomNodesDiamond(
            payable(diamond)
        );

        require(
            d.selectorToFacet(AdminFacet.proposePayoutHub.selector) != address(0),
            "UpgradeReferralPayout: pointer trio not routed yet (run execute() first)"
        );

        if (AdminFacet(diamond).getPayoutHubChangeQueuedAt() > 0) {
            console2.log("hub pointer proposal already pending on diamond", diamond);
            return;
        }

        vm.startBroadcast(
            privKey
        );

        AdminFacet(diamond).proposePayoutHub(
            hub
        );

        vm.stopBroadcast();

        console2.log("proposed payout hub pointer on diamond", diamond);
        console2.log("  hub", hub);
        console2.log("earliest executeHub()", block.timestamp + 3 days);
    }

    function executeHub()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        require(
            _isPayoutVault(),
            "UpgradeReferralPayout: only the payout vault gets a hub pointer"
        );

        (
            address diamond,
        ) = _loadVault(
            _networkName()
        );

        address hub = _loadHub(
            _networkName()
        );

        vm.startBroadcast(
            privKey
        );

        if (AdminFacet(diamond).getPayoutHubChangeQueuedAt() > 0) {
            AdminFacet(diamond).executePayoutHubChange();
        }

        vm.stopBroadcast();

        require(
            AdminFacet(diamond).getPayoutHub() == hub,
            "UpgradeReferralPayout: pointer does not match config hub"
        );

        console2.log("payout hub pointer wired on diamond", diamond);
        console2.log("run DeployReferralHub.wire() so the hub books against this vault");
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
            WiseTelecomNodesDiamondSelectors.sweepSelectors()
        );

        _cancelGroup(
            diamond,
            WiseTelecomNodesDiamondSelectors.referralPayoutSelectors()
        );

        WiseTelecomNodesDiamond d = WiseTelecomNodesDiamond(
            payable(diamond)
        );

        if (d.selectorToFacet(AdminFacet.getPayoutHubChangeQueuedAt.selector) != address(0)) {
            if (AdminFacet(diamond).getPayoutHubChangeQueuedAt() > 0) {
                AdminFacet(diamond).cancelPayoutHubChange();
            }
        }

        vm.stopBroadcast();

        console2.log("aborted pending referral-payout upgrade on diamond", diamond);
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

        console2.log("diamond", diamond);

        console2.log(
            "admin group facet",
            d.selectorToFacet(WiseTelecomNodesDiamondSelectors.adminSelectors()[0])
        );

        console2.log(
            "sweep group facet",
            d.selectorToFacet(WiseTelecomNodesDiamondSelectors.sweepSelectors()[0])
        );

        console2.log(
            "referralPayout group facet",
            d.selectorToFacet(WiseTelecomNodesDiamondSelectors.referralPayoutSelectors()[0])
        );

        if (d.selectorToFacet(AdminFacet.getPayoutHub.selector) != address(0)) {

            console2.log(
                "onchain hub pointer",
                AdminFacet(diamond).getPayoutHub()
            );

            console2.log(
                "proposed hub pointer",
                AdminFacet(diamond).getProposedPayoutHub()
            );

            console2.log(
                "pointer queuedAt",
                AdminFacet(diamond).getPayoutHubChangeQueuedAt()
            );
        }

        if (d.selectorToFacet(ReferralPayoutFacet.getPendingReferralPayout.selector) != address(0)) {
            console2.log(
                "pendingReferralPayout",
                ReferralPayoutFacet(diamond).getPendingReferralPayout()
            );
        }
    }

    function _isPayoutVault()
        internal
        view
        returns (bool)
    {
        bool isUsdcProduct = _sameString(
            _vaultProduct(),
            "usdc"
        );

        bool isMainnetHub = _sameString(
            _networkName(),
            "mainnet"
        );

        return isUsdcProduct && isMainnetHub;
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
