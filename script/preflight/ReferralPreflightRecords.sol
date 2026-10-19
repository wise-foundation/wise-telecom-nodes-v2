// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {VaultConfig} from "../vault/VaultConfig.sol";
import {WiseTelecomNodesDiamond} from "../../src/diamond/vault/WiseTelecomNodesDiamond.sol";

import {WiseTelecomNodesDiamondSelectors} from "../diamond/WiseTelecomNodesDiamondSelectors.sol";

/// @notice The verdict and record layer of {ReferralPreflight}: the run state (phase and the
/// three counters), the PASS, FAIL and SKIP lines, the phase gate of a due item, and every
/// lookup of the config records (products, networks, ranks, chain ids, the lane matrix, the
/// system tag of a record, the registry and hub records, the expected masters) plus the
/// selector batches of the three rounds. It reads files and live state only; nothing here
/// broadcasts or writes a file. `PREFLIGHT_PHASE` is required: a run without it reverts, so a
/// forgotten variable never reads as the most lenient phase. A master handoff in flight passes
/// only before its own phase; a contract with no handoff (the vaults) must name the expected
/// master outright.
///
/// The product list carries the Sovren vault as `wsnusdc` (vault system 1, record
/// `config/vault.wsnusdc.mainnet.json` with `"system": 1`); a product without a record on a
/// network is skipped there, so the Sovren checks start once that record exists. The batch
/// table covers every selector group of the diamond. Each round batch names its round's
/// phase (registry 2, flush 3, payout 4) and the build artifact of its facet: the thirteen
/// batches of the registry round in `propose()` order (the admin batch once, since the flush
/// and payout rounds re-propose the same build), the two flush batches and the two payout
/// batches. The bridge batch leaves out the legacy referral bridge pair, which the vault
/// layer judges alone because its retirement queues only those two selectors. The nine
/// groups no rollout step proposes (proxy, cashed interest, queue forecast, interest admin,
/// rescue, burn wise, multicall, queue admin, queue view) carry no round. `_matchesBuild`
/// compares deployed code with the artifact byte for byte, except where the artifact holds
/// a zero placeholder for an immutable and the deployed byte belongs to the deployed
/// address itself (the facets keep their own address as `_self`), so a match proves the
/// shipped build and nothing else. `_matchesBuildWith` writes a known value into the immutable
/// slots instead (the registry's chain rank, the reader's hub), and an artifact with no
/// immutables is compared as it is. The deployed code must have the artifact's length, and the
/// comparison leaves out the CBOR metadata trailer whose length the ARTIFACT gives (its last two
/// bytes), so moving a source out of a pending folder or editing a comment keeps a match, while
/// any change to the executable bytes, or bytes appended under a forged trailer, fails it.
/// `_remoteCall` reads a contract on another chain through `vm.rpc` on that chain's alias (the
/// keyed endpoint), so one chain's run can read the seed latch of every registry, the lane back
/// from a peer vault and the code a peer routes; every remote read first checks that the alias
/// answers with the expected chain id, since every vault sits at one address on every chain.
abstract contract ReferralPreflightRecords is VaultConfig {

    uint256 internal constant ARMED_BRIDGE_GAS_LIMIT = 5_000_000;

    uint256 internal constant GENESIS_BOT_SHARE_BPS = 500;

    uint256 internal constant SELECTOR_CHANGE_DELAY = 3 days;

    uint256 internal constant SOVREN_SYSTEM = 1;

    string internal constant SOVREN_PRODUCT = "wsnusdc";

    string internal constant HUB_NETWORK = "mainnet";

    uint256 internal constant NOT_A_ROLLOUT_BATCH = 0;

    uint256 internal constant REGISTRY_ROUND_PHASE = 2;

    uint256 internal constant FLUSH_ROUND_PHASE = 3;

    uint256 internal constant PAYOUT_ROUND_PHASE = 4;

    uint256 internal constant HUB_HANDOFF_PHASE = 4;

    uint256 internal constant REGISTRY_HANDOFF_PHASE = 5;

    uint256 internal constant NO_HANDOFF = type(uint256).max;

    string internal constant IMMUTABLE_REFERENCES = ".deployedBytecode.immutableReferences";

    struct ImmutableSlot {
        uint256 length;
        uint256 start;
    }

    struct Batch {
        string label;
        bytes4[] selectors;
        string artifact;
        uint256 roundPhase;
    }

    uint256 public phase;

    uint256 public passCount;

    uint256 public failCount;

    uint256 public skipCount;

    // ---- Verdicts ----

    function _begin()
        internal
    {
        phase = vm.envUint(
            "PREFLIGHT_PHASE"
        );

        passCount = 0;
        failCount = 0;
        skipCount = 0;

        console2.log(
            string.concat(
                "referral preflight, phase ",
                vm.toString(
                    phase
                ),
                ", chain id ",
                vm.toString(
                    block.chainid
                )
            )
        );
    }

    function _finish(
        string memory _scope
    )
        internal
        view
    {
        console2.log(
            string.concat(
                "PREFLIGHT ",
                _scope,
                ": PASS ",
                vm.toString(
                    passCount
                ),
                ", FAIL ",
                vm.toString(
                    failCount
                ),
                ", SKIP ",
                vm.toString(
                    skipCount
                )
            )
        );

        require(
            failCount == 0,
            "ReferralPreflight: at least one check failed"
        );
    }

    function _checkMasters(
        string memory _scope,
        address _master,
        address _proposedMaster,
        address _expectedMaster,
        uint256 _handoffPhase
    )
        internal
    {
        address deployKey = _meshDeployer(
            "usdc"
        );

        bool beforeHandoff = phase < _handoffPhase;

        bool handoff = _handoffPhase != NO_HANDOFF
            && beforeHandoff
            && _master == deployKey
            && _proposedMaster == _expectedMaster;

        bool settled = _master == _expectedMaster
            && (_handoffPhase == NO_HANDOFF || beforeHandoff || _master != deployKey);

        _verdict(
            settled || handoff,
            _scope,
            string.concat(
                "master ",
                vm.toString(
                    _master
                ),
                handoff
                    ? ", handoff to the expected master pending its claim"
                    : ""
            )
        );

        _verdict(
            _proposedMaster == address(0) || _proposedMaster == _expectedMaster,
            _scope,
            string.concat(
                "pending owner proposal ",
                vm.toString(
                    _proposedMaster
                )
            )
        );
    }

    function _checkPointer(
        string memory _scope,
        string memory _what,
        bool _isZero,
        bool _isExpected,
        uint256 _dueFrom
    )
        internal
    {
        if (_isZero) {
            _due(
                _dueFrom,
                _scope,
                _what
            );

            return;
        }

        _verdict(
            _isExpected,
            _scope,
            string.concat(
                _what,
                " matches the config record"
            )
        );
    }

    function _checkFlag(
        bool _set,
        string memory _scope,
        string memory _what,
        uint256 _dueFrom
    )
        internal
    {
        if (_set == false) {
            _due(
                _dueFrom,
                _scope,
                _what
            );

            return;
        }

        _pass(
            _scope,
            _what
        );
    }

    function _checkChainId(
        uint256 _actual,
        uint256 _expected,
        string memory _scope,
        string memory _what
    )
        internal
    {
        if (_actual == 0) {
            _due(
                3,
                _scope,
                _what
            );

            return;
        }

        _verdict(
            _actual == _expected,
            _scope,
            string.concat(
                _what,
                " at chain id ",
                vm.toString(
                    _actual
                )
            )
        );
    }

    function _due(
        uint256 _fromPhase,
        string memory _scope,
        string memory _what
    )
        internal
    {
        if (phase >= _fromPhase) {
            _fail(
                _scope,
                string.concat(
                    _what,
                    ": not set, due since phase ",
                    vm.toString(
                        _fromPhase
                    )
                )
            );

            return;
        }

        _skip(
            _scope,
            string.concat(
                _what,
                ": not set yet, due at phase ",
                vm.toString(
                    _fromPhase
                )
            )
        );
    }

    function _verdict(
        bool _ok,
        string memory _scope,
        string memory _what
    )
        internal
    {
        if (_ok) {
            _pass(
                _scope,
                _what
            );

            return;
        }

        _fail(
            _scope,
            _what
        );
    }

    function _pass(
        string memory _scope,
        string memory _what
    )
        internal
    {
        ++passCount;

        _line(
            "PASS ",
            _scope,
            _what
        );
    }

    function _fail(
        string memory _scope,
        string memory _what
    )
        internal
    {
        ++failCount;

        _line(
            "FAIL ",
            _scope,
            _what
        );
    }

    function _skip(
        string memory _scope,
        string memory _what
    )
        internal
    {
        ++skipCount;

        _line(
            "SKIP ",
            _scope,
            _what
        );
    }

    function _line(
        string memory _verdictWord,
        string memory _scope,
        string memory _what
    )
        internal
        pure
    {
        console2.log(
            string.concat(
                _verdictWord,
                _scope,
                ": ",
                _what
            )
        );
    }

    // ---- Records ----

    function _batches()
        internal
        pure
        returns (Batch[] memory batches)
    {
        batches = new Batch[](
            26
        );

        batches[0] = _batch(
            "admin",
            WiseTelecomNodesDiamondSelectors._adminSelectors(),
            "out/AdminFacet.sol/AdminFacet.json",
            REGISTRY_ROUND_PHASE
        );

        batches[1] = _batch(
            "user",
            WiseTelecomNodesDiamondSelectors._userSelectors(),
            "out/UserFacet.sol/UserFacet.json",
            REGISTRY_ROUND_PHASE
        );

        batches[2] = _batch(
            "permit2",
            WiseTelecomNodesDiamondSelectors._permit2Selectors(),
            "out/Permit2UserFacet.sol/Permit2UserFacet.json",
            REGISTRY_ROUND_PHASE
        );

        batches[3] = _batch(
            "move",
            WiseTelecomNodesDiamondSelectors._moveSelectors(),
            "out/MoveFacet.sol/MoveFacet.json",
            REGISTRY_ROUND_PHASE
        );

        batches[4] = _batch(
            "bridge",
            _withoutLegacyPair(
                WiseTelecomNodesDiamondSelectors._bridgeSelectors()
            ),
            "out/BridgeFacet.sol/BridgeFacet.json",
            REGISTRY_ROUND_PHASE
        );

        batches[5] = _batch(
            "queue join leave",
            WiseTelecomNodesDiamondSelectors._queueJoinLeaveSelectors(),
            "out/QueueJoinLeaveFacet.sol/QueueJoinLeaveFacet.json",
            REGISTRY_ROUND_PHASE
        );

        batches[6] = _batch(
            "queue fulfill",
            WiseTelecomNodesDiamondSelectors._queueFulfillSelectors(),
            "out/QueueFulfillFacet.sol/QueueFulfillFacet.json",
            REGISTRY_ROUND_PHASE
        );

        batches[7] = _batch(
            "referral",
            WiseTelecomNodesDiamondSelectors._referralSelectors(),
            "out/ReferralFacet.sol/ReferralFacet.json",
            REGISTRY_ROUND_PHASE
        );

        batches[8] = _batch(
            "permit2 referral",
            WiseTelecomNodesDiamondSelectors._permit2ReferralSelectors(),
            "out/Permit2ReferralFacet.sol/Permit2ReferralFacet.json",
            REGISTRY_ROUND_PHASE
        );

        batches[9] = _batch(
            "cohort recorder",
            WiseTelecomNodesDiamondSelectors._cohortRecorderSelectors(),
            "out/CohortRecorderFacet.sol/CohortRecorderFacet.json",
            REGISTRY_ROUND_PHASE
        );

        batches[10] = _batch(
            "cohort bridge hook",
            WiseTelecomNodesDiamondSelectors._cohortBridgeHookSelectors(),
            "out/CohortBridgeHookFacet.sol/CohortBridgeHookFacet.json",
            REGISTRY_ROUND_PHASE
        );

        batches[11] = _batch(
            "cohort move hook",
            WiseTelecomNodesDiamondSelectors._cohortMoveHookSelectors(),
            "out/CohortMoveHookFacet.sol/CohortMoveHookFacet.json",
            REGISTRY_ROUND_PHASE
        );

        batches[12] = _batch(
            "auto compound",
            WiseTelecomNodesDiamondSelectors._autoCompoundSelectors(),
            "out/AutoCompoundFacet.sol/AutoCompoundFacet.json",
            REGISTRY_ROUND_PHASE
        );

        batches[13] = _batch(
            "cohort flush",
            WiseTelecomNodesDiamondSelectors._cohortFlushSelectors(),
            "out/CohortFlushFacet.sol/CohortFlushFacet.json",
            FLUSH_ROUND_PHASE
        );

        batches[14] = _batch(
            "cohort flush policy",
            WiseTelecomNodesDiamondSelectors._cohortFlushPolicySelectors(),
            "out/CohortFlushPolicyFacet.sol/CohortFlushPolicyFacet.json",
            FLUSH_ROUND_PHASE
        );

        batches[15] = _batch(
            "sweep",
            WiseTelecomNodesDiamondSelectors._sweepSelectors(),
            "out/SweepFacet.sol/SweepFacet.json",
            PAYOUT_ROUND_PHASE
        );

        batches[16] = _batch(
            "referral payout",
            WiseTelecomNodesDiamondSelectors._referralPayoutSelectors(),
            "out/ReferralPayoutFacet.sol/ReferralPayoutFacet.json",
            PAYOUT_ROUND_PHASE
        );

        batches[17] = _batch(
            "proxy",
            WiseTelecomNodesDiamondSelectors._proxySelectors(),
            "",
            NOT_A_ROLLOUT_BATCH
        );

        batches[18] = _batch(
            "cashed interest",
            WiseTelecomNodesDiamondSelectors._cashedInterestSelectors(),
            "",
            NOT_A_ROLLOUT_BATCH
        );

        batches[19] = _batch(
            "queue forecast",
            WiseTelecomNodesDiamondSelectors._queueForecastSelectors(),
            "",
            NOT_A_ROLLOUT_BATCH
        );

        batches[20] = _batch(
            "interest admin",
            WiseTelecomNodesDiamondSelectors._interestAdminSelectors(),
            "",
            NOT_A_ROLLOUT_BATCH
        );

        batches[21] = _batch(
            "rescue",
            WiseTelecomNodesDiamondSelectors._rescueSelectors(),
            "",
            NOT_A_ROLLOUT_BATCH
        );

        batches[22] = _batch(
            "burn wise",
            WiseTelecomNodesDiamondSelectors._burnWiseSelectors(),
            "",
            NOT_A_ROLLOUT_BATCH
        );

        batches[23] = _batch(
            "multicall",
            WiseTelecomNodesDiamondSelectors._multicallSelectors(),
            "",
            NOT_A_ROLLOUT_BATCH
        );

        batches[24] = _batch(
            "queue admin",
            WiseTelecomNodesDiamondSelectors._queueAdminSelectors(),
            "",
            NOT_A_ROLLOUT_BATCH
        );

        batches[25] = _batch(
            "queue view",
            WiseTelecomNodesDiamondSelectors._queueViewSelectors(),
            "",
            NOT_A_ROLLOUT_BATCH
        );
    }

    function _batch(
        string memory _label,
        bytes4[] memory _selectors,
        string memory _artifact,
        uint256 _roundPhase
    )
        internal
        pure
        returns (Batch memory)
    {
        return Batch(
            _label,
            _selectors,
            _artifact,
            _roundPhase
        );
    }

    function _withoutLegacyPair(
        bytes4[] memory _selectors
    )
        internal
        pure
        returns (bytes4[] memory kept)
    {
        bytes4[] memory pair = WiseTelecomNodesDiamondSelectors._legacyReferralBridgeSelectors();

        kept = new bytes4[](
            _selectors.length - pair.length
        );

        uint256 next;

        for (uint256 i; i < _selectors.length; ++i) {
            if (_selectors[i] == pair[0] || _selectors[i] == pair[1]) {
                continue;
            }

            kept[next] = _selectors[i];

            ++next;
        }
    }

    function _matchesBuild(
        address _deployed,
        string memory _artifact
    )
        internal
        view
        returns (bool)
    {
        return _matchesBuildWith(
            _deployed,
            _artifact,
            bytes32(uint256(uint160(_deployed)))
        );
    }

    function _matchesBuildWith(
        address _deployed,
        string memory _artifact,
        bytes32 _immutableValue
    )
        internal
        view
        returns (bool)
    {
        return _codeMatchesBuild(
            _deployed.code,
            _artifact,
            _immutableValue
        );
    }

    function _codeMatchesBuild(
        bytes memory live,
        string memory _artifact,
        bytes32 _immutableValue
    )
        internal
        view
        returns (bool)
    {
        if (live.length == 0) {
            return false;
        }

        string memory json = vm.readFile(
            _artifact
        );

        bytes memory built = vm.parseJsonBytes(
            json,
            ".deployedBytecode.object"
        );

        if (live.length != built.length) {
            return false;
        }

        if (vm.keyExistsJson(json, IMMUTABLE_REFERENCES) == false) {
            return _sameExecutable(live, built);
        }

        string[] memory references = vm.parseJsonKeys(
            json,
            IMMUTABLE_REFERENCES
        );

        for (uint256 i; i < references.length; ++i) {
            ImmutableSlot[] memory slots = abi.decode(
                vm.parseJson(
                    json,
                    string.concat(
                        IMMUTABLE_REFERENCES,
                        ".",
                        references[i]
                    )
                ),
                (ImmutableSlot[])
            );

            _writeImmutable(
                built,
                slots,
                _immutableValue
            );
        }

        return _sameExecutable(live, built);
    }

    function _sameExecutable(
        bytes memory _live,
        bytes memory _built
    )
        internal
        pure
        returns (bool)
    {
        uint256 body = _executableLength(
            _built
        );

        return _prefixHash(_live, body) == _prefixHash(_built, body);
    }

    function _executableLength(
        bytes memory _code
    )
        internal
        pure
        returns (uint256)
    {
        uint256 length = _code.length;

        if (length < 2) {
            return length;
        }

        uint256 trailer = uint256(uint8(_code[length - 2])) << 8
            | uint256(uint8(_code[length - 1]));

        if (trailer + 2 > length) {
            return length;
        }

        return length
            - trailer
            - 2;
    }

    function _prefixHash(
        bytes memory _code,
        uint256 _length
    )
        internal
        pure
        returns (bytes32 hash)
    {
        assembly {
            hash := keccak256(add(_code, 32), _length)
        }
    }

    function _remoteCall(
        string memory _network,
        address _target,
        bytes memory _data
    )
        internal
        returns (bytes memory)
    {
        if (_sameString(_network, _networkName())) {
            (
                bool ok,
                bytes memory answer
            ) = _target.staticcall(
                _data
            );

            require(
                ok,
                "ReferralPreflight: local read reverted"
            );

            return answer;
        }

        _requireChain(
            _network
        );

        string memory params = string.concat(
            "[{\"to\":\"",
            vm.toString(
                _target
            ),
            "\",\"data\":\"",
            vm.toString(
                _data
            ),
            "\"},\"latest\"]"
        );

        return vm.rpc(
            _network,
            "eth_call",
            params
        );
    }

    function _remoteCode(
        string memory _network,
        address _target
    )
        internal
        returns (bytes memory)
    {
        if (_sameString(_network, _networkName())) {
            return _target.code;
        }

        _requireChain(
            _network
        );

        string memory params = string.concat(
            "[\"",
            vm.toString(
                _target
            ),
            "\",\"latest\"]"
        );

        return vm.rpc(
            _network,
            "eth_getCode",
            params
        );
    }

    function _requireChain(
        string memory _network
    )
        internal
    {
        bytes memory answer = vm.rpc(
            _network,
            "eth_chainId",
            "[]"
        );

        uint256 chainId;

        for (uint256 i; i < answer.length; ++i) {
            chainId = chainId << 8
                | uint256(uint8(answer[i]));
        }

        require(
            chainId == _chainIdOf(_network),
            "ReferralPreflight: an RPC alias answers for another chain"
        );
    }

    function _everyRegistryLatched()
        internal
        returns (bool)
    {
        string[] memory networks = _networks();

        for (uint256 i; i < networks.length; ++i) {
            address registry = _registryOf(
                networks[i]
            );

            if (registry == address(0)) {
                return false;
            }

            bytes memory answer = _remoteCall(
                networks[i],
                registry,
                abi.encodeWithSignature(
                    "seedsLatched()"
                )
            );

            if (answer.length != 32 || abi.decode(answer, (bool)) == false) {
                return false;
            }
        }

        return true;
    }

    function _writeImmutable(
        bytes memory _built,
        ImmutableSlot[] memory _slots,
        bytes32 _value
    )
        internal
        pure
    {
        for (uint256 i; i < _slots.length; ++i) {
            require(
                _slots[i].length == 32 && _slots[i].start + 32 <= _built.length,
                "ReferralPreflight: unexpected immutable reference"
            );

            uint256 start = _slots[i].start;

            assembly {
                mstore(add(add(_built, 32), start), _value)
            }
        }
    }

    function _products()
        internal
        pure
        returns (string[] memory products)
    {
        products = new string[](
            4
        );

        products[0] = "usdc";
        products[1] = "usdt";
        products[2] = "usdg";
        products[3] = SOVREN_PRODUCT;
    }

    function _networks()
        internal
        pure
        returns (string[] memory networks)
    {
        networks = new string[](
            4
        );

        networks[0] = "mainnet";
        networks[1] = "base";
        networks[2] = "arbitrum";
        networks[3] = "robinhood";
    }

    function _rankOf(
        string memory _network
    )
        internal
        pure
        returns (uint256)
    {
        string[] memory networks = _networks();

        for (uint256 i; i < networks.length; ++i) {
            if (_sameString(networks[i], _network)) {
                return i;
            }
        }

        revert(
            "ReferralPreflight: unknown network"
        );
    }

    function _chainIdOf(
        string memory _network
    )
        internal
        pure
        returns (uint256)
    {
        uint256[4] memory chainIds = [
            uint256(1),
            8453,
            42161,
            4663
        ];

        return chainIds[
            _rankOf(
                _network
            )
        ];
    }

    function _laneExpected(
        string memory _network,
        string memory _other
    )
        internal
        pure
        returns (bool)
    {
        bool arbitrumRobinhood = _sameString(_network, "arbitrum")
            && _sameString(_other, "robinhood");

        bool robinhoodArbitrum = _sameString(_network, "robinhood")
            && _sameString(_other, "arbitrum");

        return arbitrumRobinhood == false
            && robinhoodArbitrum == false;
    }

    function _hasVault(
        string memory _product,
        string memory _network
    )
        internal
        view
        returns (bool)
    {
        return vm.exists(
            _vaultConfigPath(
                _product,
                _network
            )
        );
    }

    function _systemOf(
        string memory _product,
        string memory _network
    )
        internal
        view
        returns (uint256)
    {
        string memory json = vm.readFile(
            _vaultConfigPath(
                _product,
                _network
            )
        );

        if (vm.keyExistsJson(json, ".system") == false) {
            return 0;
        }

        return vm.parseJsonUint(
            json,
            ".system"
        );
    }

    function _expectedSystem(
        string memory _product
    )
        internal
        pure
        returns (uint256)
    {
        if (_sameString(_product, SOVREN_PRODUCT)) {
            return SOVREN_SYSTEM;
        }

        return 0;
    }

    function _isPayoutVault(
        string memory _product,
        string memory _network
    )
        internal
        pure
        returns (bool)
    {
        return _sameString(_product, "usdc")
            && _sameString(_network, HUB_NETWORK);
    }

    function _registryOf(
        string memory _network
    )
        internal
        returns (address)
    {
        if (_registryConfigExists(_network) == false) {
            return address(0);
        }

        return _loadRegistry(
            _network
        );
    }

    function _hubOrZero()
        internal
        returns (address)
    {
        if (_hubConfigExists(HUB_NETWORK) == false) {
            return address(0);
        }

        return _loadHub(
            HUB_NETWORK
        );
    }

    function _routed(
        WiseTelecomNodesDiamond _d,
        bytes4 _selector
    )
        internal
        view
        returns (bool)
    {
        return _d.selectorToFacet(_selector) != address(0);
    }

    function _maturity(
        uint256 _queuedAt
    )
        internal
        view
        returns (string memory)
    {
        uint256 ready = _queuedAt + SELECTOR_CHANGE_DELAY;

        if (block.timestamp >= ready) {
            return "mature";
        }

        uint256 secondsLeft = ready
            - block.timestamp;

        uint256 hoursLeft = (secondsLeft + 1 hours - 1)
            / 1 hours;

        return string.concat(
            "matures in ",
            vm.toString(
                hoursLeft
            ),
            " hours"
        );
    }

    function _meshDeployer(
        string memory _product
    )
        internal
        view
        returns (address)
    {
        string memory path = string.concat(
            "config/vault_mesh.",
            _product,
            ".json"
        );

        if (vm.exists(path) == false) {
            path = "config/vault_mesh.usdc.json";
        }

        return vm.parseJsonAddress(
            vm.readFile(
                path
            ),
            ".deployerEOA"
        );
    }

    function _expectedVaultMaster(
        string memory _product
    )
        internal
        view
        returns (address)
    {
        return vm.envOr(
            "PREFLIGHT_VAULT_MASTER",
            _meshDeployer(
                _product
            )
        );
    }

    function _expectedRegistryMaster()
        internal
        view
        returns (address)
    {
        return vm.envOr(
            "PREFLIGHT_REGISTRY_MASTER",
            _meshDeployer(
                "usdc"
            )
        );
    }

    function _expectedHubMaster()
        internal
        view
        returns (address)
    {
        return vm.envOr(
            "PREFLIGHT_HUB_MASTER",
            _meshDeployer(
                "usdc"
            )
        );
    }
}
