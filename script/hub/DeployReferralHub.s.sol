// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {VaultConfig} from "../vault/VaultConfig.sol";
import {WiseTelecomNodesDiamond} from "../../src/diamond/vault/WiseTelecomNodesDiamond.sol";
import {ReferralHub} from "../../src/hub/pending/ReferralHub.sol";
import {IReferralHub} from "../../src/hub/pending/IReferralHub.sol";
import {ReferralHubCheckpointsFacet} from "../../src/hub/pending/ReferralHubCheckpointsFacet.sol";
import {ReferralHubRatesFacet} from "../../src/hub/pending/ReferralHubRatesFacet.sol";
import {ReferralHubIntakeFacet} from "../../src/hub/pending/ReferralHubIntakeFacet.sol";
import {ReferralHubMailboxFacet} from "../../src/hub/pending/ReferralHubMailboxFacet.sol";
import {ReferralHubPayoutFacet} from "../../src/hub/pending/ReferralHubPayoutFacet.sol";
import {ReferralHubSelectors} from "./ReferralHubSelectors.sol";
import {ReferralHubReader} from "../../src/hub/pending/ReferralHubReader.sol";
import {IReferralPayoutVault} from "../../src/hub/pending/IReferralPayoutVault.sol";

import {WiseTelecomNodesDiamondSelectors} from "../diamond/WiseTelecomNodesDiamondSelectors.sol";

/// @notice Deploys the mainnet {ReferralHub}: ONE standalone instance on the hub chain,
/// never per vault. Separate from the per-vault payout upgrade round for the same reason
/// the registry deploy is: the round runs once per VAULT_PRODUCT while the hub exists
/// exactly once, and the round's `proposeHub()` reads the address this script records in
/// `config/hub.<network>.json`. The hub's USD token is a constructor immutable and MUST be
/// the payout vault's own underlying; the vault-side pointer execute shape-probes exactly
/// that, so a hub deployed against the wrong token can never be wired.
///
/// Phases (chain via --rpc-url; the payout vault is always the usdc product):
///   `deploy()` : refuses to run if the chain's hub config already points at deployed code.
///                Broadcasts the five hub facets (checkpoints, rates, intake, mailbox,
///                payout), then `new ReferralHub(usd)` (the diamond proxy, master =
///                broadcast key, usd from `config/vault.usdc.<network>.json`), wires
///                every facet selector group while uninitialized (no timelock before
///                `finalizeSetup`), finalizes the setup (three-day timelock on every
///                later selector change) and records the address in
///                `config/hub.<network>.json`, then `new ReferralHubReader(hub)`, the
///                stateless read companion, recorded in `config/hub-reader.<network>.json`.
///                Both files are written only by a `--broadcast` run; a simulation logs
///                the addresses it would have recorded and leaves the config untouched,
///                so a dry run never leaves a never-deployed address for a later script
///                to wire.
///   `deployReader()` : deploys the reader alone for the recorded hub when no live reader
///                is recorded; to replace a live one (it holds no state), remove
///                `config/hub-reader.<network>.json` first, then run it again. Like
///                `deploy()`, it writes the file only under `--broadcast`.
///   `wire()`   : hub-side master op, AFTER the vault-side pointer round executed:
///                `setPayoutVault(usdc diamond)` so deliveries book liability and claims
///                can pull funding. Idempotent. Refuses unless the vault routes all three
///                payout selectors (`raisePendingReferralPayout`, `fundReferralPayout`,
///                `getPendingReferralPayout`; `selectorToFacet` nonzero for each), because
///                a hub wired to a vault that refuses the raise reverts every delivery,
///                every `applyFlush` and every claim. Also refuses to rotate away from a
///                wired vault while booked liability is outstanding (`totalBooked` above
///                `totalClaimed`) and that vault still reports a pending payout: the hub
///                never migrates booked liability, so the new vault could not fund those
///                claims. From the unwired state it attaches only when nothing is
///                outstanding or this vault already reserves the whole outstanding
///                amount, so a first wire passes and a re-attach goes back only to the
///                vault that holds the booked liability.
///   `wireFlush()` : hub-side master op for the flush transport, AFTER the per-vault
///                cohort-flush rounds executed: sets the CCIP router (re-pointed whenever
///                the config differs from the hub), allowlists every hub-chain vault as a
///                local reporter, and registers every spoke vault as a flush source and
///                every spoke registry as a designation source under its (chain selector,
///                sender, chain id) triple, all read from the committed config files.
///                Idempotent: a spoke with no vault config at all is logged and skipped,
///                and re-running after it lands wires just the remainder. A spoke that
///                has vault configs but no registry config REVERTS, because its courier
///                and referrer buckets would stay unclaimable until master wires the
///                source and every failed designation push is re-executed.
///   `status()` : read-only sanity print (no broadcast). For every spoke network and product
///                `wireFlush()` handles it prints whether that vault is registered as a
///                flush source, and for every spoke whether its registry is registered as a
///                designation source, under the (chain selector, chain id) pair
///                `wireFlush()` uses.
///
///   forge script script/hub/DeployReferralHub.s.sol --sig "deploy()" --rpc-url mainnet --broadcast
///   forge script script/hub/DeployReferralHub.s.sol --sig "wireFlush()" --rpc-url mainnet --broadcast
///   forge script script/hub/DeployReferralHub.s.sol --sig "status()" --rpc-url mainnet
///
/// NOTHING here may be broadcast until the owner gives the explicit go-ahead. After a REAL
/// broadcast is executed and verified, `git mv` the hub chain out of src/hub/pending/ in
/// the same commit.
contract DeployReferralHub is VaultConfig {

    /// @notice The shared flush work cap both sides bake into their bytecode
    /// (`CohortFlushCodec.MAX_FLUSH_WORK`); mirrored here so the deploy checklist
    /// compares the deployed constants against the measured bound. 160 work
    /// units (16 entries x 10 crumbs) measured about 12.9M execution gas plus
    /// about 130k calldata on a cold, aged, sparse-crumb max apply, about 3.7M
    /// under the EIP-7825 transaction gas cap of 16,777,216, and 13,874,274 when
    /// the whole work is gap weeks (the heaviest unit); the pre-bound cap
    /// of 208 measured over that cap and could commit envelopes that never
    /// apply.
    uint256 internal constant MAX_FLUSH_WORK_LITERAL = 160;

    function deploy()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        string memory network = _networkName();

        if (_hubConfigExists(network)) {

            address recorded = _loadHub(
                network
            );

            require(
                recorded.code.length == 0,
                "DeployReferralHub: hub already deployed on this chain"
            );
        }

        address usd = _loadVaultUsd(
            "usdc",
            network
        );

        vm.startBroadcast(
            privKey
        );

        ReferralHubCheckpointsFacet checkpointsFacet = new ReferralHubCheckpointsFacet();

        ReferralHubRatesFacet ratesFacet = new ReferralHubRatesFacet();

        ReferralHubIntakeFacet intakeFacet = new ReferralHubIntakeFacet();

        ReferralHubMailboxFacet mailboxFacet = new ReferralHubMailboxFacet();

        ReferralHubPayoutFacet payoutFacet = new ReferralHubPayoutFacet();

        ReferralHub hub = new ReferralHub(
            usd
        );

        hub.proposeSelectors(
            ReferralHubSelectors._checkpointsSelectors(),
            address(checkpointsFacet)
        );

        hub.executeSelectorChanges(
            ReferralHubSelectors._checkpointsSelectors()
        );

        hub.proposeSelectors(
            ReferralHubSelectors._ratesSelectors(),
            address(ratesFacet)
        );

        hub.executeSelectorChanges(
            ReferralHubSelectors._ratesSelectors()
        );

        hub.proposeSelectors(
            ReferralHubSelectors._intakeSelectors(),
            address(intakeFacet)
        );

        hub.executeSelectorChanges(
            ReferralHubSelectors._intakeSelectors()
        );

        hub.proposeSelectors(
            ReferralHubSelectors._mailboxSelectors(),
            address(mailboxFacet)
        );

        hub.executeSelectorChanges(
            ReferralHubSelectors._mailboxSelectors()
        );

        hub.proposeSelectors(
            ReferralHubSelectors._payoutSelectors(),
            address(payoutFacet)
        );

        hub.executeSelectorChanges(
            ReferralHubSelectors._payoutSelectors()
        );

        hub.finalizeSetup();

        ReferralHubReader reader = new ReferralHubReader(
            address(hub)
        );

        vm.stopBroadcast();

        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {

            _saveHub(
                network,
                address(hub)
            );

            _saveHubReader(
                network,
                address(reader)
            );
        } else {
            console2.log(
                "simulation only: config/hub not written, it would record",
                address(hub)
            );

            console2.log(
                "simulation only: config/hub-reader not written, it would record",
                address(reader)
            );
        }

        console2.log(
            "deployed ReferralHub",
            address(hub)
        );

        console2.log(
            "deployed ReferralHubReader",
            address(reader)
        );

        console2.log(
            "  network",
            network
        );

        console2.log(
            "  usd    ",
            usd
        );

        console2.log(
            "  master ",
            hub.master()
        );
    }

    function deployReader()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        string memory network = _networkName();

        address hub = _loadHub(
            network
        );

        require(
            hub.code.length > 0,
            "DeployReferralHub: recorded hub has no code"
        );

        if (_hubReaderConfigExists(network)) {

            address recorded = _loadHubReader(
                network
            );

            require(
                recorded.code.length == 0,
                "DeployReferralHub: reader already deployed on this chain"
            );
        }

        vm.startBroadcast(
            privKey
        );

        ReferralHubReader reader = new ReferralHubReader(
            hub
        );

        vm.stopBroadcast();

        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            _saveHubReader(
                network,
                address(reader)
            );
        } else {
            console2.log(
                "simulation only: config/hub-reader not written, it would record",
                address(reader)
            );
        }

        console2.log(
            "deployed ReferralHubReader",
            address(reader)
        );

        console2.log(
            "  hub",
            hub
        );
    }

    function wire()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        string memory network = _networkName();

        IReferralHub hub = IReferralHub(
            _loadHub(
                network
            )
        );

        require(
            address(hub).code.length > 0,
            "DeployReferralHub: recorded hub has no code"
        );

        address diamond = _loadVaultDiamond(
            "usdc",
            network
        );

        address currentVault = hub.payoutVault();

        if (currentVault == diamond) {
            console2.log(
                "payout vault already wired",
                diamond
            );

            return;
        }

        if (currentVault != address(0)) {
            require(
                hub.totalBooked() == hub.totalClaimed()
                    || IReferralPayoutVault(currentVault).getPendingReferralPayout() == 0,
                "DeployReferralHub: the wired payout vault still reserves booked liability, which a rotation would strand (claim it out first)"
            );
        }

        WiseTelecomNodesDiamond d = WiseTelecomNodesDiamond(
            payable(diamond)
        );

        bytes4[] memory payoutSelectors = WiseTelecomNodesDiamondSelectors._referralPayoutSelectors();

        for (uint256 i; i < payoutSelectors.length; ++i) {

            require(
                d.selectorToFacet(payoutSelectors[i]) != address(0),
                "DeployReferralHub: payout selectors not routed on the vault (run UpgradeReferralPayout.execute() first)"
            );
        }

        if (currentVault == address(0)) {
            require(
                hub.totalBooked() == hub.totalClaimed()
                    || IReferralPayoutVault(diamond).getPendingReferralPayout() >= hub.totalBooked() - hub.totalClaimed(),
                "DeployReferralHub: booked liability is outstanding and the config vault does not reserve it, so wiring it would strand those claims (re-attach the vault that holds it)"
            );
        }

        vm.startBroadcast(
            privKey
        );

        hub.setPayoutVault(
            diamond
        );

        vm.stopBroadcast();

        console2.log(
            "payout vault wired on hub",
            address(hub)
        );

        console2.log(
            "  vault",
            diamond
        );
    }

    function proposeFlushWiring()
        external
    {
        _wireFlush(
            true
        );
    }

    function wireFlush()
        external
    {
        _wireFlush(
            false
        );
    }

    function _wireFlush(
        bool _propose
    )
        internal
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        string memory network = _networkName();

        IReferralHub hub = IReferralHub(
            _loadHub(
                network
            )
        );

        require(
            address(hub).code.length > 0,
            "DeployReferralHub: recorded hub has no code"
        );

        vm.startBroadcast(
            privKey
        );

        _wireRouter(
            hub,
            network,
            _propose
        );

        _wireLocalReporters(
            hub,
            network,
            _propose
        );

        string[] memory spokes = _spokeNetworks();

        for (uint256 i; i < spokes.length; ++i) {
            _wireSpokeNetwork(
                hub,
                spokes[i],
                _propose
            );
        }

        vm.stopBroadcast();

        if (_propose) {
            console2.log(
                "flush wiring proposed on hub, executable after the lever delay",
                address(hub)
            );

            return;
        }

        console2.log(
            "flush wiring complete on hub",
            address(hub)
        );
    }

    function status()
        external
    {
        string memory network = _networkName();

        if (_hubConfigExists(network) == false) {
            console2.log(
                "no hub config for network",
                network
            );

            return;
        }

        IReferralHub hub = IReferralHub(
            _loadHub(
                network
            )
        );

        console2.log(
            "hub",
            address(hub)
        );

        console2.log(
            "  code size",
            address(hub).code.length
        );

        if (address(hub).code.length == 0) {
            return;
        }

        console2.log(
            "  master     ",
            hub.master()
        );

        console2.log(
            "  usd        ",
            address(hub.USD_TOKEN())
        );

        console2.log(
            "  payoutVault",
            hub.payoutVault()
        );

        console2.log(
            "  totalAccrued",
            hub.totalAccrued()
        );

        console2.log(
            "  totalClaimed",
            hub.totalClaimed()
        );

        console2.log(
            "  totalBooked ",
            hub.totalBooked()
        );

        console2.log(
            "  totalPayable",
            hub.totalPayable()
        );

        console2.log(
            "  ccipRouter  ",
            hub.ccipRouter()
        );

        console2.log(
            "  latest table botShareBps",
            hub.rateTableAt(
                hub.rateTableCount() - 1
            ).botShareBps
        );

        console2.log(
            "  latest table effectiveFromWeek",
            hub.rateTableAt(
                hub.rateTableCount() - 1
            ).effectiveFromWeek
        );

        string[] memory spokes = _spokeNetworks();

        for (uint256 i; i < spokes.length; ++i) {
            _printSpokeSources(
                hub,
                spokes[i]
            );
        }

        if (_hubReaderConfigExists(network) == false) {
            console2.log(
                "  reader      none recorded"
            );

            return;
        }

        address reader = _loadHubReader(
            network
        );

        console2.log(
            "  reader      ",
            reader
        );

        console2.log(
            "  reader code size",
            reader.code.length
        );
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

    function _applyLever(
        IReferralHub _hub,
        bytes memory _call,
        bool _propose
    )
        internal
    {
        if (_propose) {
            _hub.proposeLeverChange(
                _call
            );
            return;
        }

        (
            bool success,
            bytes memory returnData
        ) = address(_hub).call(
            _call
        );

        if (success == false) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }

    function _wireRouter(
        IReferralHub _hub,
        string memory _network,
        bool _propose
    )
        internal
    {
        address router = _loadCcipRouter(
            _network
        );

        if (_hub.ccipRouter() == router) {
            return;
        }

        _applyLever(
            _hub,
            abi.encodeCall(
                IReferralHub.setCcipRouter,
                (
                    router
                )
            ),
            _propose
        );

        console2.log(
            "  router",
            _propose ? "proposed" : "set",
            router
        );
    }

    function _wireLocalReporters(
        IReferralHub _hub,
        string memory _network,
        bool _propose
    )
        internal
    {
        string[] memory products = _flushProductsOf(
            _network
        );

        for (uint256 i; i < products.length; ++i) {

            if (vm.exists(_vaultConfigPath(products[i], _network)) == false) {
                console2.log(
                    "  skipping local reporter, no vault config:",
                    products[i]
                );

                continue;
            }

            address vault = _loadVaultDiamond(
                products[i],
                _network
            );

            if (_hub.allowedReporter(vault)) {
                continue;
            }

            _applyLever(
                _hub,
                abi.encodeCall(
                    IReferralHub.setAllowedReporter,
                    (
                        vault,
                        true
                    )
                ),
                _propose
            );

            console2.log(
                "  local reporter",
                _propose ? "proposed" : "allowed",
                vault
            );
        }
    }

    function _wireSpokeNetwork(
        IReferralHub _hub,
        string memory _spoke,
        bool _propose
    )
        internal
    {
        uint64 chainSelector = _loadCcipChainSelector(
            _spoke
        );

        uint256 chainId = _flushChainIdOf(
            _spoke
        );

        string[] memory products = _flushProductsOf(
            _spoke
        );

        uint256 flushSources;

        for (uint256 i; i < products.length; ++i) {

            if (vm.exists(_vaultConfigPath(products[i], _spoke)) == false) {
                console2.log(
                    "  skipping flush source, no vault config:",
                    _spoke,
                    products[i]
                );

                continue;
            }

            ++flushSources;

            address vault = _loadVaultDiamond(
                products[i],
                _spoke
            );

            if (_hub.flushSourceChainId(chainSelector, vault) != chainId) {

                _applyLever(
                    _hub,
                    abi.encodeCall(
                        IReferralHub.setFlushSource,
                        (
                            chainSelector,
                            vault,
                            chainId
                        )
                    ),
                    _propose
                );

                console2.log(
                    "  flush source",
                    _propose ? "proposed" : "set",
                    _spoke
                );
            }
        }

        if (_registryConfigExists(_spoke) == false) {

            require(
                flushSources == 0,
                "DeployReferralHub: spoke has flush sources but no registry config"
            );

            console2.log(
                "  skipping designation source, no vault and no registry config:",
                _spoke
            );

            return;
        }

        address registry = _loadRegistry(
            _spoke
        );

        if (_hub.designationSourceChainId(chainSelector, registry) != chainId) {

            _applyLever(
                _hub,
                abi.encodeCall(
                    IReferralHub.setDesignationSource,
                    (
                        chainSelector,
                        registry,
                        chainId
                    )
                ),
                _propose
            );

            console2.log(
                "  designation source",
                _propose ? "proposed" : "set",
                _spoke
            );
        }
    }

    function _printSpokeSources(
        IReferralHub _hub,
        string memory _spoke
    )
        internal
    {
        uint64 chainSelector = _loadCcipChainSelector(
            _spoke
        );

        uint256 chainId = _flushChainIdOf(
            _spoke
        );

        string[] memory products = _flushProductsOf(
            _spoke
        );

        for (uint256 i; i < products.length; ++i) {

            string memory label = string.concat(
                _spoke,
                " ",
                products[i]
            );

            if (vm.exists(_vaultConfigPath(products[i], _spoke)) == false) {
                console2.log(
                    "  flush source",
                    label,
                    "no vault config"
                );

                continue;
            }

            address vault = _loadVaultDiamond(
                products[i],
                _spoke
            );

            console2.log("  flush source registered", label, vault, _hub.flushSourceChainId(chainSelector, vault) == chainId);
        }

        if (_registryConfigExists(_spoke) == false) {
            console2.log(
                "  designation source",
                _spoke,
                "no registry config"
            );

            return;
        }

        address registry = _loadRegistry(
            _spoke
        );

        console2.log("  designation source registered", _spoke, registry, _hub.designationSourceChainId(chainSelector, registry) == chainId);
    }

    function _spokeNetworks()
        internal
        pure
        returns (string[] memory spokes)
    {
        spokes = new string[](3);
        spokes[0] = "base";
        spokes[1] = "arbitrum";
        spokes[2] = "robinhood";
    }

    function _flushProductsOf(
        string memory _network
    )
        internal
        pure
        returns (string[] memory products)
    {
        if (_sameString(_network, "base")) {
            products = new string[](2);
            products[0] = "usdc";
            products[1] = "usdt";
            return products;
        }

        if (_sameString(_network, "robinhood")) {
            products = new string[](1);
            products[0] = "usdg";
            return products;
        }

        products = new string[](3);
        products[0] = "usdc";
        products[1] = "usdt";
        products[2] = "usdg";
    }

    function _flushChainIdOf(
        string memory _network
    )
        internal
        pure
        returns (uint256)
    {
        if (_sameString(_network, "base")) {
            return 8453;
        }

        if (_sameString(_network, "arbitrum")) {
            return 42161;
        }

        if (_sameString(_network, "robinhood")) {
            return 4663;
        }

        revert(
            "DeployReferralHub: unknown spoke network"
        );
    }
}
