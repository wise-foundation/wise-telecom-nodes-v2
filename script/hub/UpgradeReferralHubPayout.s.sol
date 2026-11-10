// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {VaultConfig} from "../vault/VaultConfig.sol";
import {IReferralHub} from "../../src/hub/IReferralHub.sol";
import {ReferralHubIntakeFacet} from "../../src/hub/ReferralHubIntakeFacet.sol";
import {ReferralHubMailboxFacet} from "../../src/hub/ReferralHubMailboxFacet.sol";
import {ReferralHubPayoutFacet} from "../../src/hub/ReferralHubPayoutFacet.sol";
import {ReferralHubReader} from "../../src/hub/ReferralHubReader.sol";
import {ReferralHubSelectors} from "./ReferralHubSelectors.sol";

/// @notice Replaces the three routed facets of the live mainnet {ReferralHub} that compile the
/// shared intake ({ReferralHubIntakeFacet}, {ReferralHubMailboxFacet}, {ReferralHubPayoutFacet})
/// with new deployments behind their unchanged selector groups (intake 10, mailbox 6, payout 5)
/// through the hub's own 3-day selector timelock, and redeploys the stateless
/// {ReferralHubReader} companion. The new build changes one rule: a spoke chain bucket whose
/// owner never designated a payout address pays the owner's own address on the hub chain,
/// exactly as a stored zero designation already did, so `claim`, `claimUpTo` and `claimAll`
/// pay it, `payoutAddressOf` answers the owner, and every accrual counts toward `totalPayable`
/// at once: the intake keeps `totalPayable` equal to `totalAccrued` at every accrual and the
/// payout facet at every claim, so a backlog the old rule left outside the payable amount joins
/// it with the first accrual or claim after the flip. The backlog release phase and its event
/// are gone. Designations keep working: the registry's `setPayoutAddress` on a spoke, the hub's
/// on mainnet, the newest stamp wins. All three facets ship together because the intake and
/// the mailbox facets credit the buckets and apply the designations the payout facet pays.
/// No storage change, no selector change; the LIVE hub entry contract is never redeployed.
///
/// ONE 3-day clock on the hub chain:
///   `propose()` : deploys the three facets and proposes their selector batches. Refuses a key
///                 that is not the hub master and refuses to overwrite a pending proposal of any
///                 of the batches unless `UPGRADE_FORCE_REPROPOSE=true` is set on purpose (a
///                 second propose restarts the clock).
///   `execute()` : after 3 days: flips the three batches to their proposed facets (all three or
///                 none: a round with only some batches queued is refused, so the hub never runs
///                 a mixed build), post-asserts that each group routes to one facet with nothing
///                 queued, and deploys the new reader for the hub, recording it in
///                 `config/hub-reader.<network>.json` under `--broadcast` only (a simulation logs
///                 the address it would have recorded). Idempotent: a re-run with nothing queued
///                 flips nothing and deploys no second reader; if the reader deployment failed
///                 after the flips, remove the config file and run `DeployReferralHub.deployReader()`.
///   `abort()`   : cancels the pending batches (pre-execute only); the live facets stay.
///   `status()`  : read-only sanity print for the runbook (no broadcast).
///
///   forge script script/hub/UpgradeReferralHubPayout.s.sol --sig "propose()" --rpc-url mainnet --broadcast
///   ... wait 3 days ...
///   forge script script/hub/UpgradeReferralHubPayout.s.sol --sig "execute()" --rpc-url mainnet --broadcast
///
/// Broadcast only after the fork rehearsal on mainnet
/// (`test/diamond/fork/CourierOpenUpgradeFork.t.sol`), which drives this very script.
contract UpgradeReferralHubPayout is VaultConfig {

    function propose()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        IReferralHub hub = _liveHub();

        require(
            vm.addr(privKey) == hub.master(),
            "UpgradeReferralHubPayout: PRIVATE_KEY is not the hub master"
        );

        _requireNoPendingProposal(
            hub
        );

        vm.startBroadcast(
            privKey
        );

        address intakeFacet = address(new ReferralHubIntakeFacet());

        address mailboxFacet = address(new ReferralHubMailboxFacet());

        address payoutFacet = address(new ReferralHubPayoutFacet());

        hub.proposeSelectors(
            ReferralHubSelectors._intakeSelectors(),
            intakeFacet
        );

        hub.proposeSelectors(
            ReferralHubSelectors._mailboxSelectors(),
            mailboxFacet
        );

        hub.proposeSelectors(
            ReferralHubSelectors._payoutSelectors(),
            payoutFacet
        );

        vm.stopBroadcast();

        console2.log(
            "proposed the payout rule round on hub",
            address(hub)
        );

        console2.log(
            "  ReferralHubIntakeFacet ",
            intakeFacet
        );

        console2.log(
            "  ReferralHubMailboxFacet",
            mailboxFacet
        );

        console2.log(
            "  ReferralHubPayoutFacet ",
            payoutFacet
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

        string memory network = _networkName();

        IReferralHub hub = _liveHub();

        bytes4[][] memory groups = _groups();

        address[] memory proposed = new address[](
            groups.length
        );

        uint256 queuedGroups;

        for (uint256 i; i < groups.length; ++i) {

            proposed[i] = hub.proposedSelectorFacet(
                groups[i][0]
            );

            if (hub.selectorChangeQueuedAt(groups[i][0]) > 0) {
                ++queuedGroups;
            }
        }

        require(
            queuedGroups == 0
                || queuedGroups == groups.length,
            "UpgradeReferralHubPayout: only part of the round is queued (the three facets ship together; abort() the rest and propose again)"
        );

        bool flipped = queuedGroups > 0;

        vm.startBroadcast(
            privKey
        );

        for (uint256 i; i < groups.length && flipped; ++i) {
            hub.executeSelectorChanges(
                groups[i]
            );
        }

        address reader;

        if (flipped) {
            reader = address(
                new ReferralHubReader(
                    address(hub)
                )
            );
        }

        vm.stopBroadcast();

        for (uint256 i; i < groups.length; ++i) {
            _assertGroupRouted(
                hub,
                groups[i],
                proposed[i]
            );
        }

        if (flipped == false) {
            console2.log(
                "no payout rule batch queued on hub, nothing executed and no reader deployed",
                address(hub)
            );

            return;
        }

        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            _saveHubReader(
                network,
                reader
            );
        } else {
            console2.log(
                "simulation only: config/hub-reader not written, it would record",
                reader
            );
        }

        console2.log(
            "payout rule round routed on hub",
            address(hub)
        );

        console2.log(
            "  ReferralHubIntakeFacet ",
            hub.selectorToFacet(
                groups[0][0]
            )
        );

        console2.log(
            "  ReferralHubMailboxFacet",
            hub.selectorToFacet(
                groups[1][0]
            )
        );

        console2.log(
            "  ReferralHubPayoutFacet ",
            hub.selectorToFacet(
                groups[2][0]
            )
        );

        console2.log(
            "  ReferralHubReader      ",
            reader
        );

        console2.log(
            "  totalAccrued / totalPayable",
            hub.totalAccrued(),
            hub.totalPayable()
        );
    }

    function abort()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        IReferralHub hub = _liveHub();

        bytes4[][] memory groups = _groups();

        vm.startBroadcast(
            privKey
        );

        for (uint256 i; i < groups.length; ++i) {

            for (uint256 k; k < groups[i].length; ++k) {

                if (hub.selectorChangeQueuedAt(groups[i][k]) > 0) {
                    hub.cancelSelectorProposal(
                        groups[i][k]
                    );
                }
            }
        }

        vm.stopBroadcast();

        console2.log(
            "aborted the pending payout rule round on hub",
            address(hub)
        );
    }

    function status()
        external
        view
    {
        IReferralHub hub = _liveHub();

        bytes4[][] memory groups = _groups();

        console2.log(
            "hub",
            address(hub)
        );

        console2.log(
            "master",
            hub.master()
        );

        for (uint256 i; i < groups.length; ++i) {

            console2.log(
                "group",
                i
            );

            console2.log(
                "  routed facet",
                hub.selectorToFacet(
                    groups[i][0]
                )
            );

            console2.log(
                "  proposed facet",
                hub.proposedSelectorFacet(
                    groups[i][0]
                )
            );

            console2.log(
                "  batch queuedAt",
                hub.selectorChangeQueuedAt(
                    groups[i][0]
                )
            );
        }

        console2.log(
            "totalAccrued / totalPayable / totalClaimed",
            hub.totalAccrued(),
            hub.totalPayable(),
            hub.totalClaimed()
        );

        if (_hubReaderConfigExists(_networkName())) {
            console2.log(
                "recorded reader",
                _loadHubReader(
                    _networkName()
                )
            );
        }
    }

    /// @dev The three selector groups the round re-routes, in execute order: intake, mailbox,
    /// payout.
    function _groups()
        internal
        pure
        returns (bytes4[][] memory groups)
    {
        groups = new bytes4[][](3);

        groups[0] = ReferralHubSelectors._intakeSelectors();

        groups[1] = ReferralHubSelectors._mailboxSelectors();

        groups[2] = ReferralHubSelectors._payoutSelectors();
    }

    function _liveHub()
        internal
        view
        returns (IReferralHub hub)
    {
        address recorded = _loadHub(
            _networkName()
        );

        require(
            recorded.code.length > 0,
            "UpgradeReferralHubPayout: recorded hub has no code on this chain"
        );

        hub = IReferralHub(
            recorded
        );

        bytes4[][] memory groups = _groups();

        for (uint256 i; i < groups.length; ++i) {
            require(
                hub.selectorToFacet(groups[i][0]) != address(0),
                "UpgradeReferralHubPayout: a group of the round is not routed on this hub"
            );
        }
    }

    /// @dev A second propose overwrites a pending proposal and restarts its clock, so the
    /// round refuses one unless `UPGRADE_FORCE_REPROPOSE=true` is set on purpose.
    function _requireNoPendingProposal(
        IReferralHub _hub
    )
        internal
        view
    {
        if (vm.envOr("UPGRADE_FORCE_REPROPOSE", false)) {
            return;
        }

        bytes4[][] memory groups = _groups();

        for (uint256 i; i < groups.length; ++i) {
            require(
                _hub.selectorChangeQueuedAt(groups[i][0]) == 0,
                "UpgradeReferralHubPayout: a proposal of the round is already pending on the hub (a second propose would overwrite it and restart its clock; abort() first, or set UPGRADE_FORCE_REPROPOSE=true)"
            );
        }
    }

    function _assertGroupRouted(
        IReferralHub _hub,
        bytes4[] memory _sels,
        address _proposed
    )
        internal
        view
    {
        address routed = _hub.selectorToFacet(
            _sels[0]
        );

        require(
            routed != address(0)
                && routed.code.length > 0,
            "UpgradeReferralHubPayout: a group of the round routes to no code after execute()"
        );

        require(
            _proposed == address(0)
                || routed == _proposed,
            "UpgradeReferralHubPayout: a group of the round does not route to the proposed facet after execute()"
        );

        for (uint256 i; i < _sels.length; ++i) {
            require(
                _hub.selectorToFacet(_sels[i]) == routed,
                "UpgradeReferralHubPayout: a selector of the round routes to another facet after execute() (its proposal was missing or cancelled)"
            );

            require(
                _hub.selectorChangeQueuedAt(_sels[i]) == 0,
                "UpgradeReferralHubPayout: a selector of the round is still queued after execute()"
            );
        }
    }

    function _hubReaderPath(
        string memory _network
    )
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "config/hub-reader.",
            _network,
            ".json"
        );
    }

    function _hubReaderConfigExists(
        string memory _network
    )
        internal
        view
        returns (bool)
    {
        return vm.exists(
            _hubReaderPath(
                _network
            )
        );
    }

    function _saveHubReader(
        string memory _network,
        address _reader
    )
        internal
    {
        string memory obj = "reader";

        string memory out = vm.serializeAddress(
            obj,
            "reader",
            _reader
        );

        vm.writeJson(
            out,
            _hubReaderPath(
                _network
            )
        );
    }

    function _loadHubReader(
        string memory _network
    )
        internal
        view
        returns (address reader)
    {
        string memory json = vm.readFile(
            _hubReaderPath(
                _network
            )
        );

        reader = vm.parseJsonAddress(
            json,
            ".reader"
        );
    }
}
