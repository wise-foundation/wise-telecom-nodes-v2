// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import {ReferralPreflightRecords} from "./ReferralPreflightRecords.sol";
import {WiseTelecomNodesDiamond} from "../../src/diamond/vault/WiseTelecomNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {CohortFlushPolicyFacet} from "../../src/diamond/vault/facets/pending/CohortFlushPolicyFacet.sol";
import {ReferralRegistry} from "../../src/registry/pending/ReferralRegistry.sol";

import {WiseTelecomNodesDiamondSelectors} from "../diamond/WiseTelecomNodesDiamondSelectors.sol";

/// @notice The vault layer of {ReferralPreflight}: every check of one vault against its
/// config record. A getter that only a later round routes is read only once that round's
/// batch routes, so a vault before the registry round reports those items as not yet due
/// instead of reverting on an unrouted selector.
///
/// Per vault: the config diamond has code, its master and a pending owner proposal (none, or
/// the expected master), `finalizeSetup` done, the system tag of the record. For a World
/// Mobile vault (system 0) also every selector batch of the diamond (`_batches`): a pending
/// batch must be uniform, must target code equal to the shipped build of its round's facet
/// (an immutable placeholder of the artifact may hold the facet's own address) and fails
/// before phase 1; a batch no rollout step proposes fails whenever it is pending; from its
/// round's phase on, every selector of a round batch routes to one facet equal to the
/// shipped build, so a batch whose proposal went missing and kept its old facet fails. The
/// legacy referral bridge pair is judged alone: a proposal of it may name the shipped
/// BridgeFacet only before phase 2 (the registry round queues the pair with the bridge batch)
/// and the zero facet (the retirement) at any phase, and from phase 2 both selectors route to
/// zero, so a later proposal back to BridgeFacet, which would undo the retirement, fails. The transfer hook
/// proposal targets the shipped CohortHookFacet and from phase 2 the live hook is that
/// build; before phase 2 the auto compound route sits on one facet with code. Vaults of
/// another system are built from another repository, so their batches, routes and hooks are
/// skipped here. For every vault: no deposit hook proposal is pending, the registry pointer,
/// the arming state with `bridgeGasLimit` 5,000,000 while armed, the flush hub pointer (the
/// hub and selector 0 on mainnet, the hub and the mainnet selector on a spoke) and the payout
/// hub pointer (the hub on the usdc mainnet vault only, zero and unqueued elsewhere), each
/// with any queued change required to name the config record (a queued zero detach fails),
/// the allow lane on the chain's registry, and the rule that no vault peers a vault of
/// another vault system: the move peer flag and its queue on the same chain, and the bridge
/// peer and its proposal of every other chain, against every recorded vault whose system
/// differs, plus every live or queued bridge peer zero or the same product's recorded vault
/// (always zero on the excluded arbitrum and robinhood lane); a peer that `removeCrossChainPeer`
/// disabled keeps its address but reads as no peer; a live or queued peer carries the
/// `peerDecimals` of the product's mesh manifest (the usdc manifest for a product without one).
/// A round batch is compared with the build as soon as its round's marker selector routes
/// (the recorder for the registry round, the flush entry for the flush round), so a vault
/// cannot be armed or wired while one of its batches kept an old facet; the transfer hook follows the registry round the same way. Every enabled bridge
/// lane is read from the far side too (through the far chain's keyed RPC): the far vault must
/// have its lane back toward this vault enabled and naming it, since the receiving side
/// refuses a source whose own lane it disabled. Arming and flush access of another vault
/// system are checked from its own repository.
/// An armed vault also requires every vault of its chain to route the registry round (law 2)
/// and every live bridge peer to route the shipped BridgeFacet and both hook slices on its own
/// chain (law 1, read over that chain's RPC). The legacy pair may be proposed to BridgeFacet
/// only while this vault's own registry round is unexecuted, and a flush hub pointer set or
/// queued before this vault's flush round executed fails (law 5).
/// Once the flush policy batch routes, public flush stays off and no recorded vault is an
/// allowed flush bot (a vault cannot claim, so its courier share would be lost), and neither
/// is the shared Multicall3 forwarder (anyone could flush through it and designate its payout
/// address). The flush hub pointer is read as soon as its getter routes (the registry round
/// routes the admin batch), so an early or wrong pointer shows before the flush round.
abstract contract ReferralPreflightVault is ReferralPreflightRecords {

    string internal constant COHORT_HOOK_ARTIFACT = "out/CohortHookFacet.sol/CohortHookFacet.json";

    string internal constant BRIDGE_ARTIFACT = "out/BridgeFacet.sol/BridgeFacet.json";

    address internal constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;

    function _checkVault(
        string memory _product,
        string memory _network
    )
        internal
    {
        string memory scope = string.concat(
            "vault ",
            _product,
            "/",
            _network
        );

        if (_hasVault(_product, _network) == false) {
            _fail(
                scope,
                "no config record"
            );

            return;
        }

        address diamond = _loadVaultDiamond(
            _product,
            _network
        );

        if (diamond.code.length == 0) {
            _fail(
                scope,
                "config diamond has no code"
            );

            return;
        }

        WiseTelecomNodesDiamond d = WiseTelecomNodesDiamond(
            payable(diamond)
        );

        _checkIdentity(
            d,
            scope,
            _product,
            _network
        );

        if (d.paused()) {
            _skip(
                scope,
                "paused: both flush entrypoints revert until the vault is unpaused"
            );
        }

        _checkBuild(
            d,
            scope,
            _product
        );

        _checkDepositHook(
            d,
            scope
        );

        bool homeSystem = _expectedSystem(_product) == 0;

        if (_deferredRecord(_product, _network)) {
            _skip(
                scope,
                "rollout items deferred with this record (allow lane, pointers, reporter grant and tag follow its own rollout)"
            );
        } else {
            _checkRegistryPointer(
                d,
                scope,
                _network
            );

            if (homeSystem) {
                _checkArming(
                    d,
                    scope,
                    _network
                );
            }

            _checkFlushPointer(
                d,
                scope,
                _network
            );

            _checkAllowLane(
                d,
                scope,
                _network
            );
        }

        _checkNoCrossSystemPeer(
            d,
            scope,
            _product,
            _network
        );

        _checkBridgePeers(
            d,
            scope,
            _product,
            _network
        );

        if (homeSystem) {
            _checkFlushAccess(
                d,
                scope
            );
        }
    }

    function _checkIdentity(
        WiseTelecomNodesDiamond _d,
        string memory _scope,
        string memory _product,
        string memory _network
    )
        internal
    {
        address expectedMaster = _expectedVaultMaster(
            _product
        );

        _checkMasters(
            _scope,
            _d.master(),
            _d.proposedMaster(),
            expectedMaster,
            NO_HANDOFF
        );

        _verdict(
            _d.initialized(),
            _scope,
            "finalizeSetup done"
        );

        uint256 system = _systemOf(
            _product,
            _network
        );

        uint256 expectedSystem = _expectedSystem(
            _product
        );

        _verdict(
            system == expectedSystem,
            _scope,
            string.concat(
                "config record system tag ",
                vm.toString(
                    system
                )
            )
        );
    }

    function _checkBuild(
        WiseTelecomNodesDiamond _d,
        string memory _scope,
        string memory _product
    )
        internal
    {
        if (_expectedSystem(_product) != 0) {
            _skip(
                _scope,
                "batches, routes and hooks of another vault system are checked from its own repository"
            );

            return;
        }

        Batch[] memory batches = _batches();

        for (uint256 i; i < batches.length; ++i) {
            _checkBatch(
                _d,
                _scope,
                batches[i]
            );
        }

        _checkLegacyPair(
            _d,
            _scope
        );

        _checkTransferHook(
            _d,
            _scope
        );

        _checkAutoCompound(
            _d,
            _scope
        );
    }

    function _checkBatch(
        WiseTelecomNodesDiamond _d,
        string memory _scope,
        Batch memory _batch
    )
        internal
    {
        string memory what = string.concat(
            _batch.label,
            " batch"
        );

        (
            uint256 pending,
            bool uniform,
            uint256 queuedAt,
            address proposed
        ) = _pendingState(
            _d,
            _batch.selectors
        );

        if (pending != 0) {
            _checkPendingBatch(
                _scope,
                what,
                _batch,
                pending,
                uniform,
                queuedAt,
                proposed
            );
        }

        if (_batch.roundPhase == NOT_A_ROLLOUT_BATCH || _roundActive(_d, _batch.roundPhase) == false) {
            if (pending == 0) {
                _pass(
                    _scope,
                    string.concat(
                        what,
                        ": nothing pending"
                    )
                );
            }

            return;
        }

        _checkRoute(
            _d,
            _scope,
            what,
            _batch
        );
    }

    function _checkPendingBatch(
        string memory _scope,
        string memory _what,
        Batch memory _batch,
        uint256 _pending,
        bool _uniform,
        uint256 _queuedAt,
        address _proposed
    )
        internal
    {
        if (_uniform == false) {
            _fail(
                _scope,
                string.concat(
                    _what,
                    ": only ",
                    vm.toString(
                        _pending
                    ),
                    " of ",
                    vm.toString(
                        _batch.selectors.length
                    ),
                    " selectors pending"
                )
            );

            return;
        }

        if (_batch.roundPhase == NOT_A_ROLLOUT_BATCH) {
            _fail(
                _scope,
                string.concat(
                    _what,
                    ": pending to ",
                    vm.toString(
                        _proposed
                    ),
                    ", and no rollout step proposes this batch"
                )
            );

            return;
        }

        _checkProposal(
            _scope,
            _what,
            _proposed,
            _queuedAt,
            _batch.artifact
        );
    }

    function _checkRoute(
        WiseTelecomNodesDiamond _d,
        string memory _scope,
        string memory _what,
        Batch memory _batch
    )
        internal
    {
        address facet = _d.selectorToFacet(
            _batch.selectors[0]
        );

        bool sameFacet = true;

        for (uint256 i; i < _batch.selectors.length; ++i) {
            if (_d.selectorToFacet(_batch.selectors[i]) != facet) {
                sameFacet = false;
            }
        }

        bool shipped = sameFacet && _matchesBuild(facet, _batch.artifact);

        _verdict(
            shipped,
            _scope,
            string.concat(
                _what,
                ": routes the shipped build at ",
                vm.toString(
                    facet
                )
            )
        );
    }

    function _checkLegacyPair(
        WiseTelecomNodesDiamond _d,
        string memory _scope
    )
        internal
    {
        bytes4[] memory pair = WiseTelecomNodesDiamondSelectors._legacyReferralBridgeSelectors();

        (
            uint256 pending,
            bool uniform,
            uint256 queuedAt,
            address proposed
        ) = _pendingState(
            _d,
            pair
        );

        if (pending != 0) {
            bool roundPending = _roundActive(_d, REGISTRY_ROUND_PHASE) == false;

            bool shippedTarget = proposed == address(0)
                || (roundPending && _matchesBuild(proposed, BRIDGE_ARTIFACT));

            _checkRetirementProposal(
                _scope,
                uniform && shippedTarget,
                queuedAt
            );

            if (phase < REGISTRY_ROUND_PHASE) {
                return;
            }
        }

        bool retired = _d.selectorToFacet(pair[0]) == address(0)
            && _d.selectorToFacet(pair[1]) == address(0);

        _checkFlag(
            retired,
            _scope,
            "legacy referral bridge pair routed to zero",
            REGISTRY_ROUND_PHASE
        );
    }

    function _checkRetirementProposal(
        string memory _scope,
        bool _expectedTarget,
        uint256 _queuedAt
    )
        internal
    {
        string memory what = string.concat(
            "legacy referral bridge pair: proposal pending, ",
            _maturity(
                _queuedAt
            )
        );

        if (_expectedTarget == false) {
            _fail(
                _scope,
                "legacy referral bridge pair: pending to neither the zero facet nor the shipped BridgeFacet"
            );

            return;
        }

        if (phase == 0) {
            _fail(
                _scope,
                string.concat(
                    what,
                    ", queued before the rollout started"
                )
            );

            return;
        }

        _pass(
            _scope,
            what
        );
    }

    function _checkTransferHook(
        WiseTelecomNodesDiamond _d,
        string memory _scope
    )
        internal
    {
        uint256 queuedAt = _d.transferHookChangeQueuedAt();

        if (queuedAt == 0) {
            _pass(
                _scope,
                "transfer hook: nothing pending"
            );
        } else {
            _checkProposal(
                _scope,
                "transfer hook",
                _d.proposedTransferHookFacet(),
                queuedAt,
                COHORT_HOOK_ARTIFACT
            );
        }

        if (_roundActive(_d, REGISTRY_ROUND_PHASE) == false) {
            return;
        }

        address hook = _d.transferHookFacet();

        _verdict(
            _matchesBuild(hook, COHORT_HOOK_ARTIFACT),
            _scope,
            string.concat(
                "transfer hook is the shipped CohortHookFacet at ",
                vm.toString(
                    hook
                )
            )
        );
    }

    function _checkDepositHook(
        WiseTelecomNodesDiamond _d,
        string memory _scope
    )
        internal
    {
        uint256 queuedAt = _d.depositHookChangeQueuedAt();

        address proposed = _d.proposedDepositHookFacet();

        _verdict(
            queuedAt == 0,
            _scope,
            string.concat(
                "deposit hook: nothing pending (proposal reads ",
                vm.toString(
                    proposed
                ),
                ")"
            )
        );
    }

    function _checkProposal(
        string memory _scope,
        string memory _what,
        address _proposed,
        uint256 _queuedAt,
        string memory _artifact
    )
        internal
    {
        string memory target = string.concat(
            _what,
            ": pending to ",
            vm.toString(
                _proposed
            ),
            ", ",
            _maturity(
                _queuedAt
            )
        );

        if (_matchesBuild(_proposed, _artifact) == false) {
            _fail(
                _scope,
                string.concat(
                    target,
                    ", the target is not the shipped build"
                )
            );

            return;
        }

        if (phase == 0) {
            _fail(
                _scope,
                string.concat(
                    target,
                    ", queued before the rollout started"
                )
            );

            return;
        }

        _pass(
            _scope,
            target
        );
    }

    function _checkAutoCompound(
        WiseTelecomNodesDiamond _d,
        string memory _scope
    )
        internal
    {
        if (phase >= REGISTRY_ROUND_PHASE) {
            return;
        }

        bytes4[] memory selectors = WiseTelecomNodesDiamondSelectors._autoCompoundSelectors();

        address facet = _d.selectorToFacet(
            selectors[0]
        );

        bool sameFacet = true;

        for (uint256 i; i < selectors.length; ++i) {
            if (_d.selectorToFacet(selectors[i]) != facet) {
                sameFacet = false;
            }
        }

        _verdict(
            sameFacet && facet.code.length > 0,
            _scope,
            string.concat(
                "auto compound route ",
                vm.toString(
                    facet
                )
            )
        );
    }

    function _pendingState(
        WiseTelecomNodesDiamond _d,
        bytes4[] memory _selectors
    )
        internal
        view
        returns (
            uint256 pending,
            bool uniform,
            uint256 queuedAt,
            address proposed
        )
    {
        queuedAt = _d.selectorChangeQueuedAt(
            _selectors[0]
        );

        proposed = _d.proposedSelectorFacet(
            _selectors[0]
        );

        uniform = true;

        for (uint256 i; i < _selectors.length; ++i) {
            uint256 selectorQueuedAt = _d.selectorChangeQueuedAt(
                _selectors[i]
            );

            address selectorProposed = _d.proposedSelectorFacet(
                _selectors[i]
            );

            if (selectorQueuedAt != 0) {
                ++pending;
            }

            if (selectorQueuedAt != queuedAt || selectorProposed != proposed) {
                uniform = false;
            }
        }
    }

    function _checkRegistryPointer(
        WiseTelecomNodesDiamond _d,
        string memory _scope,
        string memory _network
    )
        internal
    {
        if (_routed(_d, AdminFacet.getReferralRegistry.selector) == false) {
            _due(
                REGISTRY_ROUND_PHASE,
                _scope,
                "registry pointer getter routed (registry round)"
            );

            return;
        }

        address expected = _registryOf(
            _network
        );

        address pointer = AdminFacet(address(_d)).getReferralRegistry();

        _checkPointer(
            _scope,
            "registry pointer",
            pointer == address(0),
            pointer == expected,
            REGISTRY_ROUND_PHASE
        );

        if (AdminFacet(address(_d)).getReferralRegistryChangeQueuedAt() == 0) {
            return;
        }

        address proposed = AdminFacet(address(_d)).getProposedReferralRegistry();

        _verdict(
            expected != address(0) && proposed == expected,
            _scope,
            string.concat(
                "queued registry pointer change names the config registry, reads ",
                vm.toString(
                    proposed
                )
            )
        );
    }

    function _checkArming(
        WiseTelecomNodesDiamond _d,
        string memory _scope,
        string memory _network
    )
        internal
    {
        uint256 gasLimit = _d.bridgeGasLimit();

        if (_routed(_d, WiseTelecomNodesDiamondSelectors._cohortRecorderSelectors()[0]) == false) {
            _due(
                REGISTRY_ROUND_PHASE,
                _scope,
                string.concat(
                    "recorder batch routed (bridgeGasLimit reads ",
                    vm.toString(
                        gasLimit
                    ),
                    ", 0 is the genesis 200,000)"
                )
            );

            return;
        }

        if (CohortRecorderFacet(address(_d)).getCohortSyncEnabled() == false) {
            _due(
                REGISTRY_ROUND_PHASE,
                _scope,
                "cohort sync armed"
            );

            return;
        }

        _pass(
            _scope,
            "cohort sync armed"
        );

        _verdict(
            gasLimit == ARMED_BRIDGE_GAS_LIMIT,
            _scope,
            string.concat(
                "bridgeGasLimit 5,000,000 while armed, reads ",
                vm.toString(
                    gasLimit
                )
            )
        );

        address registry = _registryOf(
            _network
        );

        bool allowed;

        if (registry.code.length > 0) {
            allowed = ReferralRegistry(registry).allowedVault(
                address(_d)
            );
        }

        _verdict(
            allowed,
            _scope,
            "armed vault allowlisted on its registry"
        );

        _checkArmOrder(
            _d,
            _scope,
            _network
        );
    }

    function _checkFlushPointer(
        WiseTelecomNodesDiamond _d,
        string memory _scope,
        string memory _network
    )
        internal
    {
        if (_routed(_d, AdminFacet.getFlushHub.selector) == false) {
            _due(
                REGISTRY_ROUND_PHASE,
                _scope,
                "flush hub pointer getter routed (registry round)"
            );

            return;
        }

        address expectedHub = _hubOrZero();

        uint64 expectedSelector;

        if (_sameString(_network, HUB_NETWORK) == false) {
            expectedSelector = _loadCcipChainSelector(
                HUB_NETWORK
            );
        }

        (
            address hubPointer,
            uint64 selector
        ) = AdminFacet(address(_d)).getFlushHub();

        bool pointerTouched = hubPointer != address(0)
            || AdminFacet(address(_d)).getFlushHubChangeQueuedAt() != 0;

        _verdict(
            pointerTouched == false || _roundActive(_d, FLUSH_ROUND_PHASE),
            _scope,
            "flush hub pointer set or queued only after this vault's flush round executed (law 5)"
        );

        _checkPointer(
            _scope,
            "flush hub pointer",
            hubPointer == address(0) && selector == 0,
            hubPointer == expectedHub && selector == expectedSelector,
            FLUSH_ROUND_PHASE
        );

        if (AdminFacet(address(_d)).getFlushHubChangeQueuedAt() == 0) {
            return;
        }

        (
            address proposedHub,
            uint64 proposedSelector
        ) = AdminFacet(address(_d)).getProposedFlushHub();

        _verdict(
            expectedHub != address(0) && proposedHub == expectedHub && proposedSelector == expectedSelector,
            _scope,
            string.concat(
                "queued flush hub change names the config hub, reads ",
                vm.toString(
                    proposedHub
                )
            )
        );
    }

    function _checkAllowLane(
        WiseTelecomNodesDiamond _d,
        string memory _scope,
        string memory _network
    )
        internal
    {
        address registry = _registryOf(
            _network
        );

        if (registry.code.length == 0) {
            _due(
                1,
                _scope,
                "registry deployed for the allow lane"
            );

            return;
        }

        bool allowed = ReferralRegistry(registry).allowedVault(
            address(_d)
        );

        _checkFlag(
            allowed,
            _scope,
            "vault allowlisted on its registry",
            1
        );
    }

    function _checkNoCrossSystemPeer(
        WiseTelecomNodesDiamond _d,
        string memory _scope,
        string memory _product,
        string memory _network
    )
        internal
    {
        uint256 system = _expectedSystem(
            _product
        );

        string[] memory networks = _networks();
        string[] memory products = _products();

        uint256 checked;
        bool clean = true;

        for (uint256 n; n < networks.length; ++n) {
            for (uint256 p; p < products.length; ++p) {
                if (_expectedSystem(products[p]) == system || _hasVault(products[p], networks[n]) == false) {
                    continue;
                }

                ++checked;

                address other = _loadVaultDiamond(
                    products[p],
                    networks[n]
                );

                if (_peersVault(_d, _network, networks[n], other)) {
                    clean = false;
                }
            }
        }

        if (checked == 0) {
            _skip(
                _scope,
                "no vault of another system recorded, no peer to check"
            );

            return;
        }

        _verdict(
            clean,
            _scope,
            string.concat(
                "no peer, live or queued, across vault systems (",
                vm.toString(
                    checked
                ),
                " vaults of other systems checked)"
            )
        );
    }

    function _peersVault(
        WiseTelecomNodesDiamond _d,
        string memory _network,
        string memory _otherNetwork,
        address _other
    )
        internal
        view
        returns (bool)
    {
        if (_sameString(_network, _otherNetwork)) {
            return _d.peerVault(_other)
                || _d.peerVaultChangeQueuedAt(_other) != 0;
        }

        uint64 selector = _loadCcipChainSelector(
            _otherNetwork
        );

        return _livePeer(_d, selector) == _other
            || _d.proposedCrossChainPeer(selector) == _other;
    }

    function _checkBridgePeers(
        WiseTelecomNodesDiamond _d,
        string memory _scope,
        string memory _product,
        string memory _network
    )
        internal
    {
        string[] memory networks = _networks();

        bool bound = true;
        bool twoWay = true;

        for (uint256 n; n < networks.length; ++n) {
            if (_sameString(networks[n], _network)) {
                continue;
            }

            (
                bool laneBound,
                bool laneTwoWay
            ) = _checkPeerLane(
                _d,
                _product,
                _network,
                networks[n]
            );

            bound = bound && laneBound;
            twoWay = twoWay && laneTwoWay;
        }

        _verdict(
            bound,
            _scope,
            "every live or queued bridge peer is zero or the same product's recorded vault, at the mesh decimals"
        );

        if (twoWay == false && _oneWayLanesAccepted(_product, _network)) {
            _skip(
                _scope,
                "one way bridge lanes accepted by the owner with this record (the vault is deactivated; re-check before any reactivation)"
            );

            return;
        }

        _verdict(
            twoWay,
            _scope,
            "every enabled bridge lane is enabled back toward this vault (a one way lane burns on send and reverts on receive)"
        );
    }

    function _checkPeerLane(
        WiseTelecomNodesDiamond _d,
        string memory _product,
        string memory _network,
        string memory _remote
    )
        internal
        returns (
            bool bound,
            bool twoWay
        )
    {
        address expected;

        if (_hasVault(_product, _remote) && _laneExpected(_network, _remote)) {
            expected = _loadVaultDiamond(
                _product,
                _remote
            );
        }

        uint64 selector = _loadCcipChainSelector(
            _remote
        );

        address peer = _livePeer(
            _d,
            selector
        );

        address proposed = _d.proposedCrossChainPeer(
            selector
        );

        uint8 meshDecimals = _meshPeerDecimals(
            _product
        );

        bound = (peer == address(0) || peer == expected)
            && (proposed == address(0) || proposed == expected)
            && (peer == address(0) || _d.crossChainPeerDecimals(selector) == meshDecimals)
            && (proposed == address(0) || _d.proposedCrossChainPeerDecimals(selector) == meshDecimals);

        twoWay = true;

        if (peer != address(0) && peer == expected) {
            uint64 homeSelector = _loadCcipChainSelector(
                _network
            );

            twoWay = _laneBack(
                _remote,
                peer,
                homeSelector,
                address(_d)
            );
        }
    }

    function _checkFlushAccess(
        WiseTelecomNodesDiamond _d,
        string memory _scope
    )
        internal
    {
        bytes4 policySelector = CohortFlushPolicyFacet.getPublicFlushEnabled.selector;

        if (_routed(_d, policySelector) == false) {
            return;
        }

        CohortFlushPolicyFacet policy = CohortFlushPolicyFacet(
            address(_d)
        );

        _verdict(
            policy.getPublicFlushEnabled() == false,
            _scope,
            "public flush off"
        );

        string[] memory networks = _networks();
        string[] memory products = _products();

        bool vaultBot;

        for (uint256 n; n < networks.length; ++n) {
            for (uint256 p; p < products.length; ++p) {
                if (_hasVault(products[p], networks[n]) == false) {
                    continue;
                }

                address vault = _loadVaultDiamond(
                    products[p],
                    networks[n]
                );

                if (policy.getAllowedFlushBot(vault)) {
                    vaultBot = true;
                }
            }
        }

        _verdict(
            vaultBot == false && policy.getAllowedFlushBot(MULTICALL3) == false,
            _scope,
            "no recorded vault and no shared forwarder is an allowed flush bot"
        );
    }

    function _livePeer(
        WiseTelecomNodesDiamond _d,
        uint64 _selector
    )
        internal
        view
        returns (address)
    {
        if (_d.crossChainPeerEnabled(_selector) == false) {
            return address(0);
        }

        return _d.crossChainPeer(
            _selector
        );
    }

    function _meshPeerDecimals(
        string memory _product
    )
        internal
        view
        returns (uint8)
    {
        string memory path = string.concat(
            "config/vault_mesh.",
            _product,
            ".json"
        );

        if (vm.exists(path) == false) {
            path = "config/vault_mesh.usdc.json";
        }

        uint256 decimals = vm.parseJsonUint(
            vm.readFile(
                path
            ),
            ".peerDecimals"
        );

        require(
            decimals <= type(uint8).max,
            "ReferralPreflight: mesh peerDecimals out of range"
        );

        return uint8(decimals);
    }

    function _roundActive(
        WiseTelecomNodesDiamond _d,
        uint256 _roundPhase
    )
        internal
        view
        returns (bool)
    {
        if (phase >= _roundPhase) {
            return true;
        }

        bytes4 marker = WiseTelecomNodesDiamondSelectors._cohortRecorderSelectors()[0];

        if (_roundPhase == FLUSH_ROUND_PHASE) {
            marker = WiseTelecomNodesDiamondSelectors._cohortFlushSelectors()[0];
        }

        return _routed(
            _d,
            marker
        );
    }

    function _laneBack(
        string memory _remoteNetwork,
        address _remoteVault,
        uint64 _homeSelector,
        address _homeVault
    )
        internal
        returns (bool)
    {
        bytes memory enabled = _remoteCall(
            _remoteNetwork,
            _remoteVault,
            abi.encodeWithSignature(
                "crossChainPeerEnabled(uint64)",
                _homeSelector
            )
        );

        bytes memory peer = _remoteCall(
            _remoteNetwork,
            _remoteVault,
            abi.encodeWithSignature(
                "crossChainPeer(uint64)",
                _homeSelector
            )
        );

        if (enabled.length != 32 || peer.length != 32) {
            return false;
        }

        return abi.decode(enabled, (bool))
            && abi.decode(peer, (address)) == _homeVault;
    }

    function _checkArmOrder(
        WiseTelecomNodesDiamond _d,
        string memory _scope,
        string memory _network
    )
        internal
    {
        string[] memory products = _products();

        bool siblingsReady = true;

        for (uint256 p; p < products.length; ++p) {
            if (_expectedSystem(products[p]) != 0 || _hasVault(products[p], _network) == false) {
                continue;
            }

            WiseTelecomNodesDiamond sibling = WiseTelecomNodesDiamond(
                payable(_loadVaultDiamond(products[p], _network))
            );

            if (_routed(sibling, WiseTelecomNodesDiamondSelectors._cohortRecorderSelectors()[0]) == false) {
                siblingsReady = false;
            }
        }

        _verdict(
            siblingsReady,
            _scope,
            "armed only after every vault of this chain executed the registry round (law 2)"
        );

        string[] memory networks = _networks();

        bool peersReady = true;

        for (uint256 n; n < networks.length; ++n) {
            if (_sameString(networks[n], _network)) {
                continue;
            }

            uint64 selector = _loadCcipChainSelector(
                networks[n]
            );

            address peer = _livePeer(
                _d,
                selector
            );

            if (peer == address(0)) {
                continue;
            }

            if (_peerRoundShipped(networks[n], peer) == false) {
                peersReady = false;
            }
        }

        _verdict(
            peersReady,
            _scope,
            "armed only after every bridge peer routes the shipped BridgeFacet and both hook slices (law 1)"
        );
    }

    function _peerRoundShipped(
        string memory _remoteNetwork,
        address _peer
    )
        internal
        returns (bool)
    {
        address bridgeFacet = _remoteRoute(
            _remoteNetwork,
            _peer,
            WiseTelecomNodesDiamondSelectors._bridgeSelectors()[0]
        );

        bytes memory code = _remoteCode(
            _remoteNetwork,
            bridgeFacet
        );

        bool shipped = _codeMatchesBuild(
            code,
            BRIDGE_ARTIFACT,
            bytes32(uint256(uint160(bridgeFacet)))
        );

        address bridgeHook = _remoteRoute(
            _remoteNetwork,
            _peer,
            WiseTelecomNodesDiamondSelectors._cohortBridgeHookSelectors()[0]
        );

        address moveHook = _remoteRoute(
            _remoteNetwork,
            _peer,
            WiseTelecomNodesDiamondSelectors._cohortMoveHookSelectors()[0]
        );

        return shipped
            && bridgeHook != address(0)
            && moveHook != address(0);
    }

    function _remoteRoute(
        string memory _remoteNetwork,
        address _diamond,
        bytes4 _selector
    )
        internal
        returns (address)
    {
        bytes memory answer = _remoteCall(
            _remoteNetwork,
            _diamond,
            abi.encodeWithSignature(
                "selectorToFacet(bytes4)",
                _selector
            )
        );

        if (answer.length != 32) {
            return address(0);
        }

        return abi.decode(
            answer,
            (address)
        );
    }
}
