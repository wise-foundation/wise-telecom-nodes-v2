// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {WiseTelecomNodesDiamondErrors} from "../../../src/diamond/vault/WiseTelecomNodesDiamondErrors.sol";
import {ReferralRegistry} from "../../../src/registry/pending/ReferralRegistry.sol";
import {ReferralRegistryDeclarations} from "../../../src/registry/pending/ReferralRegistryDeclarations.sol";

/**
 * @dev Peer and bridge surface shared by the live diamonds of every vault system (the
 * Sovren diamond is the same genesis code under other names, so the selectors match).
 */
interface ISystemVault {

    function peerVault(
        address peer
    )
        external
        view
        returns (bool);

    function peerVaultChangeQueuedAt(
        address peer
    )
        external
        view
        returns (uint256);

    function crossChainPeer(
        uint64 chainSelector
    )
        external
        view
        returns (address);

    function crossChainPeerEnabled(
        uint64 chainSelector
    )
        external
        view
        returns (bool);

    function proposedCrossChainPeer(
        uint64 chainSelector
    )
        external
        view
        returns (address);

    function ccipRouter()
        external
        view
        returns (address);

    function master()
        external
        view
        returns (address);

    function paused()
        external
        view
        returns (bool);

    function unpauseDeposits()
        external;

    function moveBetweenVaults(
        address dstVault,
        uint256 amount
    )
        external
        returns (uint256);

    function mintFromPeer(
        address user,
        uint256 amount
    )
        external;

    function ccipReceive(
        Client.Any2EVMMessage calldata message
    )
        external;
}

/**
 * @dev Pins on forks of the live chains that vault systems never mix money while referral
 * stays one umbrella over all of them. A vault system is the `system` field of a vault
 * record (`config/vault.<product>.<network>.json`, absent = 0 for World Mobile; the Sovren
 * record `vault.wsnusdc.mainnet.json` is system 1). The suite is record driven: every
 * record with a CCIP config for its network is loaded, so a later system joins the pins by
 * its record alone, and one synthetic address stands for a future system whose vault does
 * not exist yet. Money crosses vaults only two ways, both peer gated on both ends:
 * - same chain `moveBetweenVaults`: the source requires `peerVault[dst]`, the destination
 *   `mintFromPeer` requires `peerVault[msg.sender]`; peers are enabled only through the
 *   master's three day `proposePeerVault` timelock;
 * - CCIP bridging: one `crossChainPeer` per source chain selector, out and in, and
 *   `ccipReceive` refuses any sender other than the enabled peer.
 * Per chain the suite reads the live state (no move peer, live or queued, toward any vault
 * address of another system, the canonical addresses reserved by CREATE3 included where no
 * code exists yet; every live or proposed bridge peer is a recorded vault of the vault's
 * own system on that chain) and drives the doors (a move toward, a peer mint from and a
 * CCIP message from another system's vault all revert at the peer gate; a vault that is
 * paused live is first pinned refusing both move doors with the pause, then unpaused by its
 * own master on the fork so the peer gate behind it is driven too). The registry
 * carry mailbox does not check systems itself: a carry is staged only after the source
 * passed its peer check and consumed only inside a peer mint, so the peer gate is the one
 * wall, which is why it is pinned here and by the preflight read.
 * The umbrella half on mainnet: one registry serves every system; a vault of a later system
 * joins only through the timelocked allow lane after sync setup, a referral written through
 * one system binds the user in all of them (write once), and no vault of any system can
 * be a referrer. The hub half (inputs summed over every source of every system, one ladder)
 * is pinned offline by `test/hub/ReferralHubUmbrella.t.sol`.
 * The forks follow the current head on purpose, like the preflight fork, because the pins
 * must hold for today's live state.
 */
abstract contract VaultSystemIsolationForkBase is Test {

    struct VaultRecord {
        string product;
        string network;
        address diamond;
        uint256 system;
    }

    VaultRecord[] internal records;

    string[] internal networks;

    address internal futureSystemVault;

    address internal mover;

    function _network()
        internal
        pure
        virtual
        returns (string memory);

    function setUp()
        public
    {
        _loadRecords();

        futureSystemVault = makeAddr(
            "futureSystemVault"
        );

        mover = makeAddr(
            "systemMover"
        );

        vm.createSelectFork(
            _network()
        );
    }

    function test_isolation_recordsSpanSeveralSystems()
        public
        view
    {
        uint256 foreign;

        for (uint256 i; i < records.length; ++i) {
            if (records[i].system != 0) {
                ++foreign;
            }
        }

        assertGt(
            foreign,
            0,
            "no vault record of a second system"
        );

        VaultRecord[] memory local = _localVaults();

        assertGt(
            local.length,
            0,
            "no recorded vault on this chain"
        );

        for (uint256 i; i < local.length; ++i) {
            assertGt(
                local[i].diamond.code.length,
                0,
                "recorded vault has no code on this chain"
            );
        }
    }

    function test_isolation_noMovePeerAcrossSystems()
        public
        view
    {
        VaultRecord[] memory local = _localVaults();

        uint256 checked;

        for (uint256 i; i < local.length; ++i) {
            ISystemVault vault = ISystemVault(
                local[i].diamond
            );

            address[] memory others = _otherSystemAddresses(
                local[i].system
            );

            for (uint256 j; j < others.length; ++j) {
                assertFalse(
                    vault.peerVault(
                        others[j]
                    ),
                    "live move peer across vault systems"
                );

                assertEq(
                    vault.peerVaultChangeQueuedAt(
                        others[j]
                    ),
                    0,
                    "queued move peer across vault systems"
                );

                ++checked;
            }
        }

        assertGt(
            checked,
            0,
            "no cross system pair checked"
        );
    }

    function test_isolation_bridgePeersStayInsideTheirSystem()
        public
        view
    {
        VaultRecord[] memory local = _localVaults();

        uint256 liveLanes;

        for (uint256 i; i < local.length; ++i) {
            ISystemVault vault = ISystemVault(
                local[i].diamond
            );

            for (uint256 n; n < networks.length; ++n) {
                if (_same(networks[n], _network())) {
                    continue;
                }

                uint64 selector = _chainSelector(
                    networks[n]
                );

                address live = vault.crossChainPeerEnabled(selector)
                    ? vault.crossChainPeer(selector)
                    : address(0);

                address proposed = vault.proposedCrossChainPeer(
                    selector
                );

                assertTrue(
                    live == address(0) || _isSystemVault(live, local[i].system, networks[n]),
                    "live bridge peer outside the vault system"
                );

                assertTrue(
                    proposed == address(0) || _isSystemVault(proposed, local[i].system, networks[n]),
                    "proposed bridge peer outside the vault system"
                );

                if (live != address(0)) {
                    ++liveLanes;
                }
            }
        }

        assertGt(
            liveLanes,
            0,
            "no live bridge lane read on this chain"
        );
    }

    function test_isolation_crossSystemMoveAndPeerMintRevert()
        public
    {
        VaultRecord[] memory local = _localVaults();

        for (uint256 i; i < local.length; ++i) {
            ISystemVault vault = ISystemVault(
                local[i].diamond
            );

            address[] memory others = _otherSystemAddresses(
                local[i].system
            );

            if (vault.paused()) {
                bytes memory pausedReason = abi.encodeWithSignature(
                    "Error(string)",
                    "Pausable: paused"
                );

                _assertMoveDoorsShut(
                    vault,
                    others,
                    pausedReason,
                    pausedReason
                );

                vm.prank(
                    vault.master()
                );

                vault.unpauseDeposits();
            }

            _assertMoveDoorsShut(
                vault,
                others,
                abi.encodeWithSelector(
                    WiseTelecomNodesDiamondErrors.PeerVaultNotEnabled.selector
                ),
                abi.encodeWithSelector(
                    WiseTelecomNodesDiamondErrors.NotPeerVault.selector
                )
            );
        }
    }

    function _assertMoveDoorsShut(
        ISystemVault _vault,
        address[] memory _others,
        bytes memory _moveReason,
        bytes memory _mintReason
    )
        internal
    {
        for (uint256 j; j < _others.length; ++j) {
            vm.expectRevert(
                _moveReason
            );

            vm.prank(
                mover
            );

            _vault.moveBetweenVaults(
                _others[j],
                1
            );

            vm.expectRevert(
                _mintReason
            );

            vm.prank(
                _others[j]
            );

            _vault.mintFromPeer(
                mover,
                1
            );
        }
    }

    function test_isolation_crossSystemBridgeMessagesRevert()
        public
    {
        VaultRecord[] memory local = _localVaults();

        uint256 refused;

        for (uint256 i; i < local.length; ++i) {
            ISystemVault vault = ISystemVault(
                local[i].diamond
            );

            address router = vault.ccipRouter();

            address[] memory others = _otherSystemAddresses(
                local[i].system
            );

            for (uint256 n; n < networks.length; ++n) {
                if (_same(networks[n], _network())) {
                    continue;
                }

                uint64 selector = _chainSelector(
                    networks[n]
                );

                bytes4 expected = vault.crossChainPeerEnabled(selector)
                    ? WiseTelecomNodesDiamondErrors.CrossChainPeerMismatch.selector
                    : WiseTelecomNodesDiamondErrors.CrossChainPeerNotEnabled.selector;

                for (uint256 j; j < others.length; ++j) {
                    Client.Any2EVMMessage memory message = _message(
                        address(vault),
                        selector,
                        others[j]
                    );

                    vm.expectRevert(
                        expected
                    );

                    vm.prank(
                        router
                    );

                    vault.ccipReceive(
                        message
                    );

                    ++refused;
                }
            }
        }

        assertGt(
            refused,
            0,
            "no cross system message driven"
        );
    }

    function _loadRecords()
        internal
    {
        VmSafe.DirEntry[] memory entries = vm.readDir(
            "config"
        );

        for (uint256 i; i < entries.length; ++i) {
            string[] memory pathParts = vm.split(
                entries[i].path,
                "/"
            );

            uint256 last = pathParts.length
                - 1;

            string[] memory parts = vm.split(
                pathParts[last],
                "."
            );

            if (parts.length != 4 || _same(parts[0], "vault") == false || _same(parts[3], "json") == false) {
                continue;
            }

            if (vm.exists(string.concat("config/ccip.", parts[2], ".json")) == false) {
                continue;
            }

            string memory json = vm.readFile(
                entries[i].path
            );

            records.push(
                VaultRecord(
                    parts[1],
                    parts[2],
                    vm.parseJsonAddress(
                        json,
                        ".diamond"
                    ),
                    _systemOf(
                        json
                    )
                )
            );

            _addNetwork(
                parts[2]
            );
        }
    }

    function _systemOf(
        string memory _json
    )
        internal
        view
        returns (uint256)
    {
        if (vm.keyExistsJson(_json, ".system") == false) {
            return 0;
        }

        return vm.parseJsonUint(
            _json,
            ".system"
        );
    }

    function _addNetwork(
        string memory _name
    )
        internal
    {
        for (uint256 i; i < networks.length; ++i) {
            if (_same(networks[i], _name)) {
                return;
            }
        }

        networks.push(
            _name
        );
    }

    function _localVaults()
        internal
        view
        returns (VaultRecord[] memory local)
    {
        uint256 count;

        for (uint256 i; i < records.length; ++i) {
            if (_same(records[i].network, _network())) {
                ++count;
            }
        }

        local = new VaultRecord[](
            count
        );

        count = 0;

        for (uint256 i; i < records.length; ++i) {
            if (_same(records[i].network, _network())) {
                local[count] = records[i];

                ++count;
            }
        }
    }

    function _otherSystemAddresses(
        uint256 _system
    )
        internal
        view
        returns (address[] memory others)
    {
        address[] memory buffer = new address[](
            records.length + 1
        );

        uint256 count;

        for (uint256 i; i < records.length; ++i) {
            if (records[i].system == _system || _contains(buffer, count, records[i].diamond)) {
                continue;
            }

            buffer[count] = records[i].diamond;

            ++count;
        }

        buffer[count] = futureSystemVault;

        ++count;

        others = new address[](
            count
        );

        for (uint256 i; i < count; ++i) {
            others[i] = buffer[i];
        }
    }

    function _isSystemVault(
        address _vault,
        uint256 _system,
        string memory _onNetwork
    )
        internal
        view
        returns (bool)
    {
        for (uint256 i; i < records.length; ++i) {
            if (records[i].diamond == _vault && records[i].system == _system && _same(records[i].network, _onNetwork)) {
                return true;
            }
        }

        return false;
    }

    function _contains(
        address[] memory _list,
        uint256 _length,
        address _value
    )
        internal
        pure
        returns (bool)
    {
        for (uint256 i; i < _length; ++i) {
            if (_list[i] == _value) {
                return true;
            }
        }

        return false;
    }

    function _chainSelector(
        string memory _onNetwork
    )
        internal
        view
        returns (uint64)
    {
        return uint64(
            vm.parseJsonUint(
                vm.readFile(
                    string.concat(
                        "config/ccip.",
                        _onNetwork,
                        ".json"
                    )
                ),
                ".chainSelector"
            )
        );
    }

    function _message(
        address _vault,
        uint64 _sourceSelector,
        address _sender
    )
        internal
        view
        returns (Client.Any2EVMMessage memory)
    {
        return Client.Any2EVMMessage({
            messageId: keccak256(
                abi.encode(
                    _vault,
                    _sourceSelector,
                    _sender
                )
            ),
            sourceChainSelector: _sourceSelector,
            sender: abi.encode(
                _sender
            ),
            data: abi.encode(
                mover,
                uint256(1_000_000)
            ),
            destTokenAmounts: new Client.EVMTokenAmount[](
                0
            )
        });
    }

    function _same(
        string memory _a,
        string memory _b
    )
        internal
        pure
        returns (bool)
    {
        return keccak256(bytes(_a)) == keccak256(bytes(_b));
    }
}

contract VaultSystemIsolationMainnetFork is VaultSystemIsolationForkBase {

    function _network()
        internal
        pure
        override
        returns (string memory)
    {
        return "mainnet";
    }

    function test_umbrella_oneRegistryAcrossSystems()
        public
    {
        (
            address[] memory home,
            address[] memory foreign
        ) = _splitBySystem();

        ReferralRegistry registry = new ReferralRegistry(
            address(this),
            0
        );

        registry.setCcipRouter(
            vm.parseJsonAddress(
                vm.readFile(
                    "config/ccip.mainnet.json"
                ),
                ".router"
            )
        );

        for (uint256 i; i < home.length; ++i) {
            registry.setAllowedVault(
                home[i],
                true
            );
        }

        registry.finalizeSyncSetup();

        _joinThroughAllowLane(
            registry,
            foreign
        );

        _assertOneIdentity(
            registry,
            home,
            foreign
        );
    }

    function _splitBySystem()
        internal
        view
        returns (
            address[] memory home,
            address[] memory foreign
        )
    {
        VaultRecord[] memory local = _localVaults();

        uint256 homeCount;

        for (uint256 i; i < local.length; ++i) {
            if (local[i].system == 0) {
                ++homeCount;
            }
        }

        home = new address[](
            homeCount
        );

        foreign = new address[](
            local.length - homeCount
        );

        uint256 h;
        uint256 f;

        for (uint256 i; i < local.length; ++i) {
            if (local[i].system == 0) {
                home[h] = local[i].diamond;

                ++h;

                continue;
            }

            foreign[f] = local[i].diamond;

            ++f;
        }

        assertGt(
            home.length,
            0,
            "no home system vault on mainnet"
        );

        assertGt(
            foreign.length,
            0,
            "no vault of another system on mainnet"
        );
    }

    function _joinThroughAllowLane(
        ReferralRegistry _registry,
        address[] memory _foreign
    )
        internal
    {
        for (uint256 i; i < _foreign.length; ++i) {
            vm.expectRevert(
                ReferralRegistryDeclarations.VaultNotTracked.selector
            );

            _registry.setAllowedVault(
                _foreign[i],
                true
            );

            _registry.proposeAllowedVault(
                _foreign[i]
            );

            vm.expectRevert(
                ReferralRegistryDeclarations.VaultAllowTimelockNotElapsed.selector
            );

            _registry.executeAllowedVaultChange(
                _foreign[i]
            );
        }

        vm.warp(
            block.timestamp + 3 days
        );

        for (uint256 i; i < _foreign.length; ++i) {
            _registry.executeAllowedVaultChange(
                _foreign[i]
            );

            assertTrue(
                _registry.allowedVault(
                    _foreign[i]
                ),
                "allow lane did not admit the vault of another system"
            );
        }
    }

    function _assertOneIdentity(
        ReferralRegistry _registry,
        address[] memory _home,
        address[] memory _foreign
    )
        internal
    {
        address userA = makeAddr(
            "umbrellaUserA"
        );

        address userB = makeAddr(
            "umbrellaUserB"
        );

        address referrerA = makeAddr(
            "umbrellaReferrerA"
        );

        address referrerB = makeAddr(
            "umbrellaReferrerB"
        );

        address intruder = makeAddr(
            "umbrellaSecondReferrer"
        );

        vm.prank(
            _foreign[0]
        );

        _registry.assignReferrer(
            userA,
            referrerA
        );

        vm.prank(
            _home[0]
        );

        _registry.assignReferrer(
            userB,
            referrerB
        );

        for (uint256 i; i < _home.length; ++i) {
            vm.prank(
                _home[i]
            );

            _registry.assignReferrer(
                userA,
                intruder
            );
        }

        for (uint256 i; i < _foreign.length; ++i) {
            vm.prank(
                _foreign[i]
            );

            _registry.assignReferrer(
                userB,
                intruder
            );
        }

        assertEq(
            _registry.referrerOf(
                userA
            ),
            referrerA,
            "referral written through one system rebound by another"
        );

        assertEq(
            _registry.referrerOf(
                userB
            ),
            referrerB,
            "referral written through the home system rebound by another"
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        vm.prank(
            _home[0]
        );

        _registry.assignReferrer(
            intruder,
            _foreign[0]
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        vm.prank(
            _foreign[0]
        );

        _registry.assignReferrer(
            intruder,
            _home[0]
        );
    }
}

contract VaultSystemIsolationBaseFork is VaultSystemIsolationForkBase {

    function _network()
        internal
        pure
        override
        returns (string memory)
    {
        return "base";
    }
}

contract VaultSystemIsolationArbitrumFork is VaultSystemIsolationForkBase {

    function _network()
        internal
        pure
        override
        returns (string memory)
    {
        return "arbitrum";
    }
}

contract VaultSystemIsolationRobinhoodFork is VaultSystemIsolationForkBase {

    function _network()
        internal
        pure
        override
        returns (string memory)
    {
        return "robinhood";
    }
}
