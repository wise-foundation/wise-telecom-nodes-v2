// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import {ReferralPreflightVault} from "./ReferralPreflightVault.sol";
import {ReferralRegistry} from "../../src/registry/pending/ReferralRegistry.sol";
import {IReferralHub} from "../../src/hub/pending/IReferralHub.sol";
import {ReferralHubDeclarations} from "../../src/hub/pending/ReferralHubDeclarations.sol";
import {ReferralHubReader} from "../../src/hub/pending/ReferralHubReader.sol";
import {ReferralHub} from "../../src/hub/pending/ReferralHub.sol";
import {ReferralHubRatesFacet} from "../../src/hub/pending/ReferralHubRatesFacet.sol";

import {ReferralHubSelectors} from "../hub/ReferralHubSelectors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Read-only preflight of the referral rollout. It never broadcasts and never writes a
/// file: every check reads a config record and compares it with the live contract it names,
/// prints one line per check, `PASS`, `FAIL` or `SKIP`, then a summary line, and reverts at
/// the end when any check failed, so the exit code of the run is the verdict.
///
/// Phases (chain via --rpc-url on the keyed endpoints; no key is read):
///   `vault()` : one vault, the product named by `VAULT_PRODUCT`, on the chain of the RPC.
///   `chain()` : the chain's registry, every vault recorded for the chain and, on mainnet,
///               the hub.
///   `hub()`   : the hub alone (mainnet).
///
/// `PREFLIGHT_PHASE` (required) names the last runbook phase completed on every vault: 0
/// before Phase 1, 1 after 1.5, 2 after the 2.7 arm, 3 after 3.8, 4 after 4.8 and 5 after
/// 5.2. An item a phase establishes is due from that phase on: a due item that reads unset
/// fails, an item not yet due that reads unset is skipped, and an item that reads set but
/// wrong fails in every phase. Masters default to the mesh deployer of the product's mesh
/// manifest (the usdc manifest when the product has none); `PREFLIGHT_VAULT_MASTER`,
/// `PREFLIGHT_REGISTRY_MASTER` and `PREFLIGHT_HUB_MASTER` override them once a master was
/// handed to a Safe.
///
/// The run refuses a chain outside the four networks and fails a chain with no vault record
/// or with two records naming one diamond. The registry, the hub entry contract and the reader
/// are compared with the shipped build like every facet (the registry with its chain rank and
/// the reader with its hub written into their immutables). The seed latch fails when it fired
/// before phase 3 (it would cut the seed window short). A spoke registry is never
/// also a flush source and a spoke vault never also a designation source, since the hub
/// dispatches a delivery by the role of its sender. Neither the deploy key nor the shared
/// Multicall3 forwarder is ever a hub reporter, live or queued as a lever, and neither of them
/// nor any product address (its mesh canonical, or its mainnet record for a product without a
/// mesh) is a flush or designation source on a chain where that product has no record. The genesis rate table is compared
/// field by field with the table a hub built from the shipped source seeds (the run deploys
/// such a reference hub inside its own simulation, which never broadcasts), since the
/// constructor writes the ladder and the runtime code does not carry it.
/// A master handoff in flight (the deployer is still master and the expected Safe is the
/// pending owner) passes until phase 7 (every master handoff, hub, registries and vaults, is the
/// last step of the program): from that phase on the deploy key may no longer be master, which
/// also catches a forgotten master override. The seed latch is informational (the rollout never
/// fires it: a latched chain reads PASS, an open one SKIP), the hub pot is due from phase 4,
/// and the sync rank bound reads 3 for the four-chain mesh.
/// Registry checks: the config registry has code, its master and pending owner proposal,
/// chain rank and CCIP router with any queued router change, the sync setup finalized, the
/// allow lane of every recorded vault, the tracked vault count equal to the allowed config
/// records (a vault allowed outside the records, or a revoked one, fails at once),
/// every expected sync peer enabled at the recorded registry with any queued peer change
/// naming it on an expected lane, the excluded arbitrum and robinhood lane never enabled, no
/// lane quarantined, the spoke payout route with any queued change (none, live or queued, on
/// the hub chain), the seed latch and the open correction lane.
/// Hub checks: the config hub has code, its master and pending owner proposal,
/// `finalizeSetup` done, the USD token of the usdc mainnet vault, a courier share of 500 bps in
/// every rate table and the courier share cap 0, the reader, the CCIP router, every hub
/// selector group routed to the shipped build of its facet with no change queued, every
/// mainnet vault a local reporter, every spoke vault a flush source and every spoke registry
/// a designation source at its chain id, the system tag of every source (0 for a World
/// Mobile vault, 1 for the Sovren vault; a source that delivered under a wrong tag fails at
/// once, since the tag freezes at the first delivery), and the pot (the hub holds USD, due
/// from phase 4; the hub is its own payout pot and never draws on a vault). The vault checks are listed on {ReferralPreflightVault}.
///
///   PREFLIGHT_PHASE=0 forge script script/preflight/ReferralPreflight.s.sol:ReferralPreflight --sig "chain()" --rpc-url mainnet
///   PREFLIGHT_PHASE=0 VAULT_PRODUCT=usdg forge script script/preflight/ReferralPreflight.s.sol:ReferralPreflight --sig "vault()" --rpc-url robinhood
contract ReferralPreflight is ReferralPreflightVault {

    string internal constant REGISTRY_ARTIFACT = "out/ReferralRegistry.sol/ReferralRegistry.json";

    string internal constant HUB_ARTIFACT = "out/ReferralHub.sol/ReferralHub.json";

    string internal constant READER_ARTIFACT = "out/ReferralHubReader.sol/ReferralHubReader.json";

    function vault()
        external
    {
        _begin();

        string memory network = _networkName();
        string memory product = _vaultProduct();

        _rankOf(
            network
        );

        _checkVault(
            product,
            network
        );

        _finish(
            string.concat(
                "vault ",
                product,
                " on ",
                network
            )
        );
    }

    function chain()
        external
    {
        _begin();

        string memory network = _networkName();

        _rankOf(
            network
        );

        _checkRegistry(
            network
        );

        string[] memory products = _products();

        uint256 recorded;

        for (uint256 i; i < products.length; ++i) {
            if (_hasVault(products[i], network) == false) {
                continue;
            }

            ++recorded;

            _checkVault(
                products[i],
                network
            );
        }

        _checkRecords(
            network,
            recorded
        );

        if (_sameString(network, HUB_NETWORK)) {
            _checkHub();
        }

        _finish(
            string.concat(
                "chain ",
                network
            )
        );
    }

    function hub()
        external
    {
        _begin();

        string memory network = _networkName();

        require(
            _sameString(network, HUB_NETWORK),
            "ReferralPreflight: the hub lives on mainnet"
        );

        _checkHub();

        _finish(
            "hub"
        );
    }

    // ---- Registry ----

    function _checkRegistry(
        string memory _network
    )
        internal
    {
        string memory scope = string.concat(
            "registry ",
            _network
        );

        address registryAddress = _registryOf(
            _network
        );

        if (registryAddress == address(0)) {
            _due(
                1,
                scope,
                "registry deployed (config/registry record)"
            );

            return;
        }

        if (registryAddress.code.length == 0) {
            _fail(
                scope,
                "config registry has no code"
            );

            return;
        }

        ReferralRegistry registry = ReferralRegistry(
            registryAddress
        );

        _checkRegistryIdentity(
            registry,
            scope,
            _network
        );

        _checkTrackedVaults(
            registry,
            scope,
            _network
        );

        _checkSyncPeers(
            registry,
            scope,
            _network
        );

        _checkPayoutRoute(
            registry,
            scope,
            _network
        );

        bool latched = registry.seedsLatched();

        if (latched) {
            _pass(
                scope,
                "seeds latched (the owner closed the seed lane on this chain)"
            );
        } else {
            _skip(
                scope,
                "seeds not latched (the rollout never fires the latch; the seed lane stays open)"
            );
        }

        _verdict(
            latched == false || phase >= FLUSH_ROUND_PHASE,
            scope,
            "seed latch not fired before the seed window can close (phase 3)"
        );

        _verdict(
            registry.correctionsLatched() == false,
            scope,
            "correction lane open"
        );
    }

    function _checkRegistryIdentity(
        ReferralRegistry _registry,
        string memory _scope,
        string memory _network
    )
        internal
    {
        address master = _registry.master();

        address expectedMaster = _expectedRegistryMaster();

        _checkMasters(
            _scope,
            master,
            _registry.proposedMaster(),
            expectedMaster,
            MASTER_HANDOFF_PHASE
        );

        bytes32 rankWord = bytes32(_rankOf(_network));

        _verdict(
            _matchesBuildWith(address(_registry), REGISTRY_ARTIFACT, rankWord),
            _scope,
            "registry code is the shipped build"
        );

        uint256 rankBound = _networks().length
            - 1;

        _verdict(
            _registry.maxSyncRank() == rankBound,
            _scope,
            string.concat(
                "sync rank bound ",
                vm.toString(
                    rankBound
                )
            )
        );

        uint256 rank = _rankOf(
            _network
        );

        _verdict(
            _registry.LOCAL_CHAIN_RANK() == rank,
            _scope,
            "chain rank"
        );

        address router = _loadCcipRouter(
            _network
        );

        address liveRouter = _registry.ccipRouter();

        _checkPointer(
            _scope,
            "registry CCIP router",
            liveRouter == address(0),
            liveRouter == router,
            1
        );

        if (_registry.ccipRouterChangeQueuedAt() != 0) {
            _verdict(
                _registry.proposedCcipRouter() == router,
                _scope,
                "queued CCIP router change names the config router"
            );
        }

        _checkFlag(
            _registry.syncInitialized(),
            _scope,
            "sync setup finalized",
            1
        );
    }

    function _checkTrackedVaults(
        ReferralRegistry _registry,
        string memory _scope,
        string memory _network
    )
        internal
    {
        string[] memory products = _products();

        uint256 recorded;
        uint256 allowedRecorded;

        for (uint256 i; i < products.length; ++i) {
            if (_hasVault(products[i], _network) == false) {
                continue;
            }

            ++recorded;

            address diamond = _loadVaultDiamond(
                products[i],
                _network
            );

            bool allowed = _registry.allowedVault(
                diamond
            );

            if (allowed) {
                ++allowedRecorded;
            }

            if (allowed == false && _deferredRecord(products[i], _network)) {
                _skip(
                    _scope,
                    string.concat(
                        "allow lane of ",
                        products[i],
                        " deferred with its record"
                    )
                );

                continue;
            }

            _checkFlag(
                allowed,
                _scope,
                string.concat(
                    "allow lane of ",
                    products[i]
                ),
                1
            );
        }

        uint256 tracked = _registry.trackedVaultCount();

        _verdict(
            tracked == allowedRecorded,
            _scope,
            string.concat(
                "tracked vaults ",
                vm.toString(
                    tracked
                ),
                " equal the allowed config records ",
                vm.toString(
                    allowedRecorded
                ),
                " of ",
                vm.toString(
                    recorded
                )
            )
        );
    }

    function _checkSyncPeers(
        ReferralRegistry _registry,
        string memory _scope,
        string memory _network
    )
        internal
    {
        string[] memory networks = _networks();

        for (uint256 i; i < networks.length; ++i) {
            if (_sameString(networks[i], _network)) {
                continue;
            }

            _checkSyncPeer(
                _registry,
                _scope,
                _network,
                networks[i]
            );
        }
    }

    function _checkSyncPeer(
        ReferralRegistry _registry,
        string memory _scope,
        string memory _network,
        string memory _remote
    )
        internal
    {
        uint64 selector = _loadCcipChainSelector(
            _remote
        );

        string memory lane = string.concat(
            "lane to ",
            _remote
        );

        bool quarantined = _registry.syncPeerQuarantined(
            selector
        );

        _verdict(
            quarantined == false || _laneExpected(_network, _remote) == false,
            _scope,
            string.concat(
                lane,
                " not quarantined (a quarantine is allowed only on the excluded lane)"
            )
        );

        bool enabled = _registry.syncPeerEnabled(
            selector
        );

        if (_registry.syncPeerChangeQueuedAt(selector) != 0) {
            address proposedPeer = _registry.proposedSyncPeer(
                selector
            );

            address recordedPeer = _registryOf(
                _remote
            );

            _verdict(
                _laneExpected(_network, _remote) && recordedPeer != address(0) && proposedPeer == recordedPeer,
                _scope,
                string.concat(
                    lane,
                    ": queued peer change names the recorded registry on an expected lane"
                )
            );
        }

        if (_laneExpected(_network, _remote) == false) {
            _verdict(
                enabled == false,
                _scope,
                string.concat(
                    lane,
                    " never enabled (excluded lane)"
                )
            );

            return;
        }

        if (enabled == false) {
            _due(
                1,
                _scope,
                string.concat(
                    lane,
                    " enabled"
                )
            );

            return;
        }

        address peer = _registry.syncPeer(
            selector
        );

        address expectedPeer = _registryOf(
            _remote
        );

        _verdict(
            peer == expectedPeer,
            _scope,
            string.concat(
                lane,
                " enabled at the recorded registry"
            )
        );
    }

    function _checkPayoutRoute(
        ReferralRegistry _registry,
        string memory _scope,
        string memory _network
    )
        internal
    {
        address payoutHub = _registry.payoutHub();

        uint256 queuedAt = _registry.payoutHubChangeQueuedAt();

        if (_sameString(_network, HUB_NETWORK)) {
            _verdict(
                payoutHub == address(0) && queuedAt == 0,
                _scope,
                "no payout route, live or queued, on the hub chain"
            );

            return;
        }

        address expectedHub = _hubOrZero();

        uint64 hubSelector = _loadCcipChainSelector(
            HUB_NETWORK
        );

        if (queuedAt != 0) {
            address proposedHub = _registry.proposedPayoutHub();

            uint64 proposedSelector = _registry.proposedPayoutHubChainSelector();

            _verdict(
                expectedHub != address(0) && proposedHub == expectedHub && proposedSelector == hubSelector,
                _scope,
                "queued payout route change names the config hub and the mainnet selector"
            );
        }

        if (payoutHub == address(0)) {
            _due(
                1,
                _scope,
                "payout route to the hub"
            );

            return;
        }

        _verdict(
            payoutHub == expectedHub && _registry.payoutHubChainSelector() == hubSelector,
            _scope,
            "payout route names the config hub and the mainnet selector"
        );
    }

    // ---- Hub ----

    function _checkHub()
        internal
    {
        string memory scope = "hub";

        address hubAddress = _hubOrZero();

        if (hubAddress == address(0)) {
            _due(
                1,
                scope,
                "hub deployed (config/hub.mainnet.json)"
            );

            return;
        }

        if (hubAddress.code.length == 0) {
            _fail(
                scope,
                "config hub has no code"
            );

            return;
        }

        IReferralHub referralHub = IReferralHub(
            hubAddress
        );

        _checkHubIdentity(
            referralHub,
            scope
        );

        _verdict(
            _matchesBuild(hubAddress, HUB_ARTIFACT),
            scope,
            "hub entry code is the shipped build"
        );

        _checkHubReader(
            hubAddress,
            scope
        );

        _checkHubRouter(
            referralHub,
            scope
        );

        _checkHubRoutes(
            referralHub,
            scope
        );

        string[] memory networks = _networks();

        for (uint256 i; i < networks.length; ++i) {
            _checkHubSources(
                referralHub,
                scope,
                networks[i]
            );
        }

        _checkHubPot(
            referralHub,
            scope
        );

        if (_everyRegistryLatched()) {
            _pass(
                scope,
                "every registry latched (seedsLatched read on the four chains)"
            );
        } else {
            _skip(
                scope,
                "not every registry latched (seedsLatched read on the four chains; the rollout never fires the latch)"
            );
        }

        _checkHubStrays(
            referralHub,
            scope
        );
    }

    function _checkHubIdentity(
        IReferralHub _hub,
        string memory _scope
    )
        internal
    {
        address master = _hub.master();

        address expectedMaster = _expectedHubMaster();

        _checkMasters(
            _scope,
            master,
            _hub.proposedMaster(),
            expectedMaster,
            MASTER_HANDOFF_PHASE
        );

        _verdict(
            _hub.initialized(),
            _scope,
            "finalizeSetup done"
        );

        address usd = _loadVaultUsd(
            "usdc",
            HUB_NETWORK
        );

        _verdict(
            address(_hub.USD_TOKEN()) == usd,
            _scope,
            "USD token of the usdc mainnet vault"
        );

        uint256 tableCount = _hub.rateTableCount();

        ReferralHubDeclarations.RateTable memory genesis = _hub.rateTableAt(
            0
        );

        ReferralHubDeclarations.RateTable memory shipped = _shippedGenesisTable(
            usd
        );

        bool genesisHeld = genesis.botShareBps == GENESIS_BOT_SHARE_BPS
            && _sameLevers(genesis, shipped);

        for (uint256 i = 1; i < tableCount; ++i) {
            if (_sameLevers(_hub.rateTableAt(i), genesis) == false) {
                genesisHeld = false;
            }
        }

        _verdict(
            genesisHeld,
            _scope,
            string.concat(
                "every rate table equals the shipped genesis table with courier share 500 bps (",
                vm.toString(
                    tableCount
                ),
                " tables)"
            )
        );

        _verdict(
            _hub.delivererShareCap() == 0,
            _scope,
            "courier share cap 0"
        );
    }

    function _checkHubReader(
        address _hub,
        string memory _scope
    )
        internal
    {
        string memory path = string.concat(
            "config/hub-reader.",
            HUB_NETWORK,
            ".json"
        );

        if (vm.exists(path) == false) {
            _due(
                1,
                _scope,
                "reader recorded"
            );

            return;
        }

        address reader = vm.parseJsonAddress(
            vm.readFile(
                path
            ),
            ".reader"
        );

        bool readsHub;

        if (reader.code.length > 0) {
            readsHub = address(ReferralHubReader(reader).HUB()) == _hub;
        }

        bytes32 hubWord = bytes32(uint256(uint160(_hub)));

        _verdict(
            readsHub && _matchesBuildWith(reader, READER_ARTIFACT, hubWord),
            _scope,
            "reader is the shipped build and reads this hub"
        );
    }

    function _checkHubRouter(
        IReferralHub _hub,
        string memory _scope
    )
        internal
    {
        address router = _hub.ccipRouter();

        if (router == address(0)) {
            _due(
                3,
                _scope,
                "CCIP router set"
            );

            return;
        }

        address expectedRouter = _loadCcipRouter(
            HUB_NETWORK
        );

        _verdict(
            router == expectedRouter,
            _scope,
            "CCIP router equals the config router"
        );
    }

    function _checkHubSources(
        IReferralHub _hub,
        string memory _scope,
        string memory _network
    )
        internal
    {
        string[] memory products = _products();

        bool hubChain = _sameString(
            _network,
            HUB_NETWORK
        );

        uint256 recorded;

        for (uint256 i; i < products.length; ++i) {
            if (_hasVault(products[i], _network) == false) {
                continue;
            }

            ++recorded;

            _checkHubSource(
                _hub,
                _scope,
                products[i],
                _network,
                hubChain
            );
        }

        if (hubChain || recorded == 0) {
            return;
        }

        _checkDesignationSource(
            _hub,
            _scope,
            _network
        );
    }

    function _checkHubSource(
        IReferralHub _hub,
        string memory _scope,
        string memory _product,
        string memory _network,
        bool _hubChain
    )
        internal
    {
        uint256 chainId = _chainIdOf(
            _network
        );

        address diamond = _loadVaultDiamond(
            _product,
            _network
        );

        string memory source = string.concat(
            _product,
            "/",
            _network
        );

        bool wired;

        if (_hubChain) {
            bool reporter = _hub.allowedReporter(
                diamond
            );

            if (reporter == false && _deferredRecord(_product, _network)) {
                _skip(
                    _scope,
                    string.concat(
                        "local reporter ",
                        source,
                        " deferred with its record"
                    )
                );

                return;
            }

            wired = reporter;

            _checkFlag(
                reporter,
                _scope,
                string.concat(
                    "local reporter ",
                    source
                ),
                3
            );
        } else {
            uint64 selector = _loadCcipChainSelector(
                _network
            );

            uint256 sourceChainId = _hub.flushSourceChainId(
                selector,
                diamond
            );

            wired = sourceChainId != 0;

            _verdict(
                _hub.designationSourceChainId(selector, diamond) == 0,
                _scope,
                string.concat(
                    "flush source ",
                    source,
                    " is not also a designation source"
                )
            );

            _checkChainId(
                sourceChainId,
                chainId,
                _scope,
                string.concat(
                    "flush source ",
                    source
                )
            );
        }

        bytes32 key = _hub.sourceKeyOf(
            chainId,
            diamond
        );

        uint256 expectedSystem = _expectedSystem(
            _product
        );

        _checkSystemTag(
            _hub,
            _scope,
            source,
            key,
            expectedSystem,
            wired
        );
    }

    function _checkDesignationSource(
        IReferralHub _hub,
        string memory _scope,
        string memory _network
    )
        internal
    {
        address registry = _registryOf(
            _network
        );

        if (registry == address(0)) {
            _due(
                1,
                _scope,
                string.concat(
                    "registry record of ",
                    _network
                )
            );

            return;
        }

        uint64 selector = _loadCcipChainSelector(
            _network
        );

        uint256 designationChainId = _hub.designationSourceChainId(
            selector,
            registry
        );

        _verdict(
            _hub.flushSourceChainId(selector, registry) == 0,
            _scope,
            string.concat(
                "registry/",
                _network,
                " is not also a flush source"
            )
        );

        uint256 chainId = _chainIdOf(
            _network
        );

        _checkChainId(
            designationChainId,
            chainId,
            _scope,
            string.concat(
                "designation source registry/",
                _network
            )
        );
    }

    function _checkSystemTag(
        IReferralHub _hub,
        string memory _scope,
        string memory _source,
        bytes32 _key,
        uint256 _expected,
        bool _wired
    )
        internal
    {
        uint256 system = _hub.sourceSystemOf(
            _key
        );

        string memory what = string.concat(
            "system tag ",
            vm.toString(
                _expected
            ),
            " of ",
            _source
        );

        if (system == 0 && _expected != 0 && _wired == false && _hub.sourceChainIdOf(_key) == 0) {
            _due(
                FLUSH_ROUND_PHASE,
                _scope,
                what
            );

            return;
        }

        _verdict(
            system == _expected,
            _scope,
            what
        );
    }

    function _checkHubPot(
        IReferralHub _hub,
        string memory _scope
    )
        internal
    {
        uint256 pot = IERC20(
            address(
                _hub.USD_TOKEN()
            )
        ).balanceOf(
            address(_hub)
        );

        if (pot == 0) {
            _due(
                HUB_POT_PHASE,
                _scope,
                "pot funded (the hub holds USD)"
            );

            return;
        }

        _pass(
            _scope,
            string.concat(
                "pot funded, the hub holds ",
                vm.toString(
                    pot
                ),
                " USD units"
            )
        );
    }

    function _checkHubRoutes(
        IReferralHub _hub,
        string memory _scope
    )
        internal
    {
        _checkHubGroup(
            _hub,
            _scope,
            "checkpoints",
            ReferralHubSelectors._checkpointsSelectors(),
            "out/ReferralHubCheckpointsFacet.sol/ReferralHubCheckpointsFacet.json"
        );

        _checkHubGroup(
            _hub,
            _scope,
            "rates",
            ReferralHubSelectors._ratesSelectors(),
            "out/ReferralHubRatesFacet.sol/ReferralHubRatesFacet.json"
        );

        _checkHubGroup(
            _hub,
            _scope,
            "intake",
            ReferralHubSelectors._intakeSelectors(),
            "out/ReferralHubIntakeFacet.sol/ReferralHubIntakeFacet.json"
        );

        _checkHubGroup(
            _hub,
            _scope,
            "mailbox",
            ReferralHubSelectors._mailboxSelectors(),
            "out/ReferralHubMailboxFacet.sol/ReferralHubMailboxFacet.json"
        );

        _checkHubGroup(
            _hub,
            _scope,
            "payout",
            ReferralHubSelectors._payoutSelectors(),
            "out/ReferralHubPayoutFacet.sol/ReferralHubPayoutFacet.json"
        );
    }

    function _checkHubGroup(
        IReferralHub _hub,
        string memory _scope,
        string memory _label,
        bytes4[] memory _selectors,
        string memory _artifact
    )
        internal
    {
        address facet = _hub.selectorToFacet(
            _selectors[0]
        );

        bool sameFacet = true;
        bool queued;

        for (uint256 i; i < _selectors.length; ++i) {
            if (_hub.selectorToFacet(_selectors[i]) != facet) {
                sameFacet = false;
            }

            if (_hub.selectorChangeQueuedAt(_selectors[i]) != 0) {
                queued = true;
            }
        }

        _verdict(
            queued == false,
            _scope,
            string.concat(
                "hub ",
                _label,
                " selectors: no change queued"
            )
        );

        bool shipped = sameFacet && _matchesBuild(facet, _artifact);

        _verdict(
            shipped,
            _scope,
            string.concat(
                "hub ",
                _label,
                " selectors route the shipped build at ",
                vm.toString(
                    facet
                )
            )
        );
    }

    function _sameLevers(
        ReferralHubDeclarations.RateTable memory _table,
        ReferralHubDeclarations.RateTable memory _genesis
    )
        internal
        pure
        returns (bool)
    {
        _table.effectiveFromWeek = _genesis.effectiveFromWeek;

        return keccak256(abi.encode(_table)) == keccak256(abi.encode(_genesis));
    }

    function _checkRecords(
        string memory _network,
        uint256 _recorded
    )
        internal
    {
        string memory scope = string.concat(
            "records ",
            _network
        );

        if (_recorded == 0) {
            _fail(
                scope,
                "no vault record for this chain"
            );

            return;
        }

        string[] memory products = _products();

        bool distinct = true;

        for (uint256 i; i < products.length; ++i) {
            for (uint256 j = i + 1; j < products.length; ++j) {
                if (_hasVault(products[i], _network) == false || _hasVault(products[j], _network) == false) {
                    continue;
                }

                address first = _loadVaultDiamond(
                    products[i],
                    _network
                );

                address second = _loadVaultDiamond(
                    products[j],
                    _network
                );

                if (first == second) {
                    distinct = false;
                }
            }
        }

        _verdict(
            distinct,
            scope,
            "every vault record names a distinct diamond"
        );
    }

    function _shippedGenesisTable(
        address _usd
    )
        internal
        returns (ReferralHubDeclarations.RateTable memory)
    {
        ReferralHub shippedHub = new ReferralHub(
            _usd
        );

        ReferralHubRatesFacet ratesFacet = new ReferralHubRatesFacet();

        bytes4[] memory rates = ReferralHubSelectors._ratesSelectors();

        shippedHub.proposeSelectors(
            rates,
            address(ratesFacet)
        );

        shippedHub.executeSelectorChanges(
            rates
        );

        return IReferralHub(address(shippedHub)).rateTableAt(
            0
        );
    }

    function _checkHubStrays(
        IReferralHub _hub,
        string memory _scope
    )
        internal
    {
        address deployKey = _meshDeployer(
            "usdc"
        );

        bytes32 deployKeyLever = keccak256(
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (deployKey, true)
            )
        );

        bytes32 forwarderLever = keccak256(
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (MULTICALL3, true)
            )
        );

        bool reportersClean = _hub.allowedReporter(deployKey) == false
            && _hub.allowedReporter(MULTICALL3) == false
            && _hub.leverChangeQueuedAt(deployKeyLever) == 0
            && _hub.leverChangeQueuedAt(forwarderLever) == 0;

        _verdict(
            reportersClean,
            _scope,
            "neither the deploy key nor the shared forwarder is a reporter, live or queued"
        );

        string[] memory networks = _networks();

        bool clean = true;

        for (uint256 n; n < networks.length; ++n) {
            if (_sameString(networks[n], HUB_NETWORK) == false && _spokeStraysClean(_hub, networks[n], deployKey) == false) {
                clean = false;
            }
        }

        _verdict(
            clean,
            _scope,
            "no stray address (deploy key, shared forwarder, a product address without a record on that chain) is a flush or designation source"
        );
    }

    function _spokeStraysClean(
        IReferralHub _hub,
        string memory _network,
        address _deployKey
    )
        internal
        view
        returns (bool clean)
    {
        uint64 selector = _loadCcipChainSelector(
            _network
        );

        clean = _notASource(_hub, selector, _deployKey)
            && _notASource(_hub, selector, MULTICALL3);

        string[] memory products = _products();

        for (uint256 p; p < products.length; ++p) {
            if (_hasVault(products[p], _network)) {
                continue;
            }

            address productAddress = _productAddress(
                products[p]
            );

            if (productAddress != address(0) && _notASource(_hub, selector, productAddress) == false) {
                clean = false;
            }
        }
    }

    function _notASource(
        IReferralHub _hub,
        uint64 _selector,
        address _sender
    )
        internal
        view
        returns (bool)
    {
        return _hub.flushSourceChainId(_selector, _sender) == 0
            && _hub.designationSourceChainId(_selector, _sender) == 0;
    }

    function _productAddress(
        string memory _product
    )
        internal
        view
        returns (address)
    {
        string memory mesh = string.concat(
            "config/vault_mesh.",
            _product,
            ".json"
        );

        if (vm.exists(mesh)) {
            return vm.parseJsonAddress(
                vm.readFile(
                    mesh
                ),
                ".canonical"
            );
        }

        if (_hasVault(_product, HUB_NETWORK)) {
            return _loadVaultDiamond(
                _product,
                HUB_NETWORK
            );
        }

        return address(0);
    }
}
