// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ReferralRegistry} from "../../src/registry/pending/ReferralRegistry.sol";
import {ReferralRegistryDeclarations} from "../../src/registry/pending/ReferralRegistryDeclarations.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @dev Minimal CCIP router stand-in for the broadcast tests: quotes
 * a fixed fee per message, requires each send to carry exactly that
 * fee, records the last send, and returns a deterministic message id
 * derived from the destination selector and a running send counter
 * so tests can predict emitted ids.
 */
contract MockSyncCcipRouter {

    error UnexpectedFeeValue();

    uint256 public fee;

    uint256 public sendCount;

    uint64 public lastSelector;

    bytes public lastReceiver;

    bytes public lastData;

    constructor(
        uint256 _fee
    ) {
        fee = _fee;
    }

    function getFee(
        uint64,
        Client.EVM2AnyMessage calldata
    )
        external
        view
        returns (uint256)
    {
        return fee;
    }

    function ccipSend(
        uint64 _destChainSelector,
        Client.EVM2AnyMessage calldata _message
    )
        external
        payable
        returns (bytes32)
    {
        require(
            msg.value == fee,
            UnexpectedFeeValue()
        );

        sendCount += 1;

        lastSelector = _destChainSelector;

        lastReceiver = _message.receiver;

        lastData = _message.data;

        return keccak256(
            abi.encode(
                _destChainSelector,
                sendCount
            )
        );
    }
}

/**
 * @dev Vault stand-in for the flip-migration seam: records the last
 * `receiveReferrerFlip` call and can be armed to revert so the
 * registry's defer-and-retry path is observable.
 */
contract MockFlipVault {

    error FlipRejected();

    bool public shouldRevert;

    uint256 public flipCallCount;

    address public lastUser;

    address public lastOldReferrer;

    address public lastNewReferrer;

    function setShouldRevert(
        bool _shouldRevert
    )
        external
    {
        shouldRevert = _shouldRevert;
    }

    function receiveReferrerFlip(
        address _user,
        address _oldReferrer,
        address _newReferrer
    )
        external
    {
        require(
            shouldRevert == false,
            FlipRejected()
        );

        flipCallCount += 1;

        lastUser = _user;

        lastOldReferrer = _oldReferrer;

        lastNewReferrer = _newReferrer;
    }
}

/**
 * @dev Caller without a receive function, used to force the excess
 * refund transfer inside `broadcastSync` to fail.
 */
contract RefundRejector {

    ReferralRegistry internal immutable REGISTRY;

    constructor(
        ReferralRegistry _registry
    ) {
        REGISTRY = _registry;
    }

    function trigger(
        address _user,
        uint64[] calldata _selectors
    )
        external
        payable
    {
        REGISTRY.broadcastSync{value: msg.value}(
            _user,
            _selectors
        );
    }
}

/**
 * @dev Cross-chain sync suite for {ReferralRegistry}: the packed
 * sync key stamped by first local assignment, the min-merge algebra
 * fed through `mergeReferrer` (allowlisted vaults) and `ccipReceive`
 * (router/peer/replay gate), the flip coordination machinery
 * (pending-flip markers with keep-if-set, `pokeMigration` with its
 * migrate/defer/clear arms, `effectiveReferrerOf` redirect), the
 * caller-paid `broadcastSync` fan-out with running-fee check and
 * excess refund, `quoteSyncFee`, and the sync admin surface
 * (one-shot router, gas-limit bounds, peer propose/execute lifecycle
 * that is instant before `finalizeSyncSetup` and 3-day timelocked
 * after, instant remove, tracked-vault list with its cap and
 * swap-remove). Merge convergence is pinned with fuzz: keys never
 * increase, merges of distinct keys commute, and repeat delivery of
 * the same pair is a silent no-op. The equal-key different-referrer
 * degenerate case is deliberately excluded from the commutation fuzz:
 * the register keeps the local side and flags the divergence with
 * {SyncKeyCollision}, which the dedicated collision test pins.
 * Mock router, flip vault and refund rejector live at the top of
 * this file.
 */
contract ReferralRegistrySyncTest is Test {

    event VaultAllowedSet(
        address indexed vault,
        bool allowed
    );

    event ReferralSyncAdopted(
        address indexed user,
        address indexed referrer,
        uint256 syncKey
    );

    event ReferralSyncKeyLowered(
        address indexed user,
        address indexed referrer,
        uint256 oldKey,
        uint256 newKey
    );

    event ReferralSyncFlipped(
        address indexed user,
        address indexed oldReferrer,
        address indexed newReferrer,
        uint256 syncKey
    );

    event SyncKeyCollision(
        address indexed user,
        address indexed localReferrer,
        address indexed incomingReferrer,
        uint256 syncKey
    );

    event FlipMarked(
        address indexed vault,
        address indexed user,
        address indexed oldReferrer
    );

    event FlipCleared(
        address indexed vault,
        address indexed user,
        address indexed oldReferrer
    );

    event FlipMigrated(
        address indexed vault,
        address indexed user,
        address oldReferrer,
        address newReferrer
    );

    event FlipMigrationDeferred(
        address indexed vault,
        address indexed user,
        address oldReferrer,
        address newReferrer
    );

    event SyncReceived(
        uint64 indexed srcChainSelector,
        bytes32 indexed messageId,
        address indexed user
    );

    event SyncBroadcast(
        address indexed user,
        uint64 indexed destChainSelector,
        address indexed referrer,
        uint256 syncKey,
        bytes32 messageId
    );

    event CcipRouterSet(
        address indexed router
    );

    event SyncGasLimitSet(
        uint64 gasLimit
    );

    event SyncPeerProposed(
        uint64 indexed chainSelector,
        address indexed peer,
        uint256 queuedAt
    );

    event SyncPeerSet(
        uint64 indexed chainSelector,
        address indexed peer
    );

    event SyncPeerProposalCancelled(
        uint64 indexed chainSelector,
        address indexed peer
    );

    event SyncPeerRemoved(
        uint64 indexed chainSelector,
        address indexed peer
    );

    event SyncSetupFinalized();

    struct MergeStep {
        address referrer;
        uint256 assignedAt;
        uint256 rank;
        address expectedReferrer;
        uint256 expectedKey;
    }

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint64 internal constant SEL_ONE = 1_111;

    uint64 internal constant SEL_TWO = 2_222;

    uint64 internal constant SEL_DEAD = 9_999;

    uint256 internal constant SYNC_FEE = 0.01 ether;

    address internal user1 = address(0xA1);

    address internal user2 = address(0xA2);

    address internal user3 = address(0xA3);

    address internal refA = address(0xB1);

    address internal refB = address(0xB2);

    address internal refC = address(0xB3);

    address internal stranger = address(0xC1);

    address internal vaultA = address(0xD1);

    address internal vaultB = address(0xD2);

    address internal vaultC = address(0xD3);

    address internal peerOne = address(0xE2);

    address internal peerTwo = address(0xE3);

    address internal routerEoa = address(0xF1);

    ReferralRegistry internal registry;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        registry = new ReferralRegistry(
            address(this),
            0
        );

        registry.setAllowedVault(
            vaultA,
            true
        );

        registry.setAllowedVault(
            vaultB,
            true
        );
    }

    receive()
        external
        payable
    {}

    // ---- helpers ----

    function _key(
        uint256 _assignedAt,
        uint256 _rank
    )
        internal
        pure
        returns (uint256)
    {
        return (_assignedAt << 8) | _rank;
    }

    function _enablePeer(
        uint64 _selector,
        address _peer
    )
        internal
    {
        registry.proposeSyncPeer(
            _selector,
            _peer
        );

        registry.executeSyncPeerChange(
            _selector
        );
    }

    function _lanes(
        uint64 _a
    )
        internal
        pure
        returns (uint64[] memory lanes)
    {
        lanes = new uint64[](1);

        lanes[0] = _a;
    }

    function _lanes(
        uint64 _a,
        uint64 _b
    )
        internal
        pure
        returns (uint64[] memory lanes)
    {
        lanes = new uint64[](2);

        lanes[0] = _a;

        lanes[1] = _b;
    }

    function _syncData(
        uint256 _version,
        address _user,
        address _referrer,
        uint256 _assignedAt,
        uint256 _rank
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            _version,
            _user,
            _referrer,
            _assignedAt,
            _rank
        );
    }

    function _syncMessage(
        bytes32 _messageId,
        uint64 _selector,
        address _peer,
        bytes memory _data
    )
        internal
        pure
        returns (Client.Any2EVMMessage memory)
    {
        return Client.Any2EVMMessage({
            messageId: _messageId,
            sourceChainSelector: _selector,
            sender: abi.encode(
                _peer
            ),
            data: _data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
    }

    function _armReceive()
        internal
    {
        registry.setCcipRouter(
            routerEoa
        );

        _enablePeer(
            SEL_ONE,
            peerOne
        );
    }

    function _armBroadcast()
        internal
        returns (MockSyncCcipRouter router)
    {
        router = new MockSyncCcipRouter(
            SYNC_FEE
        );

        registry.setCcipRouter(
            address(router)
        );

        _enablePeer(
            SEL_ONE,
            peerOne
        );

        _enablePeer(
            SEL_TWO,
            peerTwo
        );

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );
    }

    function _installFlipVault()
        internal
        returns (MockFlipVault vault)
    {
        registry.setAllowedVault(
            vaultA,
            false
        );

        registry.setAllowedVault(
            vaultB,
            false
        );

        vault = new MockFlipVault();

        registry.setAllowedVault(
            address(vault),
            true
        );
    }

    function _assignThenFlip(
        address _vaultCaller,
        address _user
    )
        internal
    {
        vm.prank(
            _vaultCaller
        );

        registry.assignReferrer(
            _user,
            refA
        );

        vm.prank(
            _vaultCaller
        );

        registry.mergeReferrer(
            _user,
            refB,
            BASE_TIME - 1 days,
            0
        );
    }

    // ---- constructor and key stamping ----

    function test_constructor_stampsLocalChainRank()
        public
    {
        ReferralRegistry ranked = new ReferralRegistry(
            address(this),
            15
        );

        assertEq(ranked.LOCAL_CHAIN_RANK(), 15);

        ranked.setAllowedVault(
            vaultA,
            true
        );

        vm.prank(
            vaultA
        );

        ranked.assignReferrer(
            user1,
            refA
        );

        (
            address referrer,
            uint256 assignedAt,
            uint256 rank
        ) = ranked.getReferrerPair(
            user1
        );

        assertEq(referrer, refA);
        assertEq(assignedAt, BASE_TIME);
        assertEq(rank, 15);
    }

    function test_constructor_revertsWhenRankTooHigh()
        public
    {
        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidChainRank.selector
        );

        new ReferralRegistry(
            address(this),
            16
        );
    }

    function test_assignReferrer_firstAssign_stampsSyncKey()
        public
    {
        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        assertEq(registry.referrerKey(user1), _key(BASE_TIME, 0));
    }

    function test_assignReferrer_secondAssign_keyUntouched()
        public
    {
        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        vm.warp(
            BASE_TIME + 5 days
        );

        vm.prank(
            vaultB
        );

        registry.assignReferrer(
            user1,
            refB
        );

        assertEq(registry.referrerOf(user1), refA);
        assertEq(registry.referrerKey(user1), _key(BASE_TIME, 0));
    }

    function test_getReferrerPair_roundTrip()
        public
    {
        (
            address referrer,
            uint256 assignedAt,
            uint256 rank
        ) = registry.getReferrerPair(
            user1
        );

        assertEq(referrer, address(0));
        assertEq(assignedAt, 0);
        assertEq(rank, 0);

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        (
            referrer,
            assignedAt,
            rank
        ) = registry.getReferrerPair(
            user1
        );

        assertEq(referrer, refA);
        assertEq(assignedAt, BASE_TIME);
        assertEq(rank, 0);
    }

    // ---- merge algebra ----

    function test_mergeReferrer_algebraTable()
        public
    {
        MergeStep[] memory steps = new MergeStep[](7);

        steps[0] = MergeStep({
            referrer: refA,
            assignedAt: BASE_TIME - 10,
            rank: 5,
            expectedReferrer: refA,
            expectedKey: _key(BASE_TIME - 10, 5)
        });

        steps[1] = MergeStep({
            referrer: refB,
            assignedAt: BASE_TIME - 5,
            rank: 3,
            expectedReferrer: refA,
            expectedKey: _key(BASE_TIME - 10, 5)
        });

        steps[2] = MergeStep({
            referrer: refA,
            assignedAt: BASE_TIME - 20,
            rank: 7,
            expectedReferrer: refA,
            expectedKey: _key(BASE_TIME - 20, 7)
        });

        steps[3] = MergeStep({
            referrer: refB,
            assignedAt: BASE_TIME - 20,
            rank: 7,
            expectedReferrer: refA,
            expectedKey: _key(BASE_TIME - 20, 7)
        });

        steps[4] = MergeStep({
            referrer: refB,
            assignedAt: BASE_TIME - 20,
            rank: 6,
            expectedReferrer: refB,
            expectedKey: _key(BASE_TIME - 20, 6)
        });

        steps[5] = MergeStep({
            referrer: refC,
            assignedAt: BASE_TIME - 30,
            rank: 0,
            expectedReferrer: refC,
            expectedKey: _key(BASE_TIME - 30, 0)
        });

        steps[6] = MergeStep({
            referrer: refC,
            assignedAt: BASE_TIME - 30,
            rank: 0,
            expectedReferrer: refC,
            expectedKey: _key(BASE_TIME - 30, 0)
        });

        for (uint256 i; i < steps.length; ++i) {

            vm.prank(
                vaultA
            );

            registry.mergeReferrer(
                user1,
                steps[i].referrer,
                steps[i].assignedAt,
                steps[i].rank
            );

            assertEq(registry.referrerOf(user1), steps[i].expectedReferrer);
            assertEq(registry.referrerKey(user1), steps[i].expectedKey);
        }
    }

    function test_mergeReferrer_adoptOnEmpty_storesOriginKey()
        public
    {
        uint256 incomingKey = _key(
            BASE_TIME - 1 days,
            7
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit ReferralSyncAdopted(
            user1,
            refA,
            incomingKey
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            refA,
            BASE_TIME - 1 days,
            7
        );

        assertEq(registry.referrerOf(user1), refA);
        assertEq(registry.referrerKey(user1), incomingKey);

        (
            address referrer,
            uint256 assignedAt,
            uint256 rank
        ) = registry.getReferrerPair(
            user1
        );

        assertEq(referrer, refA);
        assertEq(assignedAt, BASE_TIME - 1 days);
        assertEq(rank, 7);
    }

    function test_mergeReferrer_lowerKeySameReferrer_lowersKeyWithoutMarkers()
        public
    {
        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        uint256 oldKey = _key(
            BASE_TIME,
            0
        );

        uint256 newKey = _key(
            BASE_TIME - 2 days,
            4
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit ReferralSyncKeyLowered(
            user1,
            refA,
            oldKey,
            newKey
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            refA,
            BASE_TIME - 2 days,
            4
        );

        assertEq(registry.referrerOf(user1), refA);
        assertEq(registry.referrerKey(user1), newKey);
        assertEq(registry.pendingFlip(vaultA, user1), address(0));
        assertEq(registry.pendingFlip(vaultB, user1), address(0));
    }

    function test_mergeReferrer_lowerKeyDifferentReferrer_flipsAndMarks()
        public
    {
        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        uint256 newKey = _key(
            BASE_TIME - 1 days,
            3
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit FlipMarked(
            vaultA,
            user1,
            refA
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit FlipMarked(
            vaultB,
            user1,
            refA
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit ReferralSyncFlipped(
            user1,
            refA,
            refB,
            newKey
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            refB,
            BASE_TIME - 1 days,
            3
        );

        assertEq(registry.referrerOf(user1), refB);
        assertEq(registry.referrerKey(user1), newKey);
        assertEq(registry.pendingFlip(vaultA, user1), refA);
        assertEq(registry.pendingFlip(vaultB, user1), refA);
    }

    function test_mergeReferrer_secondFlip_keepsFirstMarker()
        public
    {
        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            refB,
            BASE_TIME - 1 days,
            0
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            refC,
            BASE_TIME - 2 days,
            0
        );

        assertEq(registry.referrerOf(user1), refC);
        assertEq(registry.referrerKey(user1), _key(BASE_TIME - 2 days, 0));
        assertEq(registry.pendingFlip(vaultA, user1), refA);
        assertEq(registry.pendingFlip(vaultB, user1), refA);
    }

    function test_mergeReferrer_equalKeyDifferentReferrer_collisionKeepsLocal()
        public
    {
        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        uint256 localKey = _key(
            BASE_TIME,
            0
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit SyncKeyCollision(
            user1,
            refA,
            refB,
            localKey
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            refB,
            BASE_TIME,
            0
        );

        assertEq(registry.referrerOf(user1), refA);
        assertEq(registry.referrerKey(user1), localKey);
        assertEq(registry.pendingFlip(vaultA, user1), address(0));
        assertEq(registry.pendingFlip(vaultB, user1), address(0));
    }

    function test_mergeReferrer_higherKey_silentNoOp()
        public
    {
        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            refA,
            BASE_TIME - 2 days,
            0
        );

        vm.recordLogs();

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            refB,
            BASE_TIME - 1 days,
            0
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0);
        assertEq(registry.referrerOf(user1), refA);
        assertEq(registry.referrerKey(user1), _key(BASE_TIME - 2 days, 0));
    }

    function test_mergeReferrer_rankZeroWinsEqualTimestamp()
        public
    {
        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            refA,
            BASE_TIME - 1,
            1
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            refB,
            BASE_TIME - 1,
            0
        );

        assertEq(registry.referrerOf(user1), refB);
        assertEq(registry.referrerKey(user1), _key(BASE_TIME - 1, 0));

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user2,
            refA,
            BASE_TIME - 1,
            0
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user2,
            refB,
            BASE_TIME - 1,
            1
        );

        assertEq(registry.referrerOf(user2), refA);
        assertEq(registry.referrerKey(user2), _key(BASE_TIME - 1, 0));
    }

    // ---- merge fuzz ----

    function testFuzz_merge_keyNeverIncreases(
        uint256 _seed
    )
        public
    {
        address[3] memory referrers = [
            refA,
            refB,
            refC
        ];

        uint256 previousKey;

        for (uint256 i; i < 5; ++i) {

            uint256 ts = bound(
                uint256(
                    keccak256(
                        abi.encode(
                            _seed,
                            i,
                            "ts"
                        )
                    )
                ),
                1,
                BASE_TIME + 1 hours
            );

            uint256 rank = bound(
                uint256(
                    keccak256(
                        abi.encode(
                            _seed,
                            i,
                            "rank"
                        )
                    )
                ),
                0,
                15
            );

            address referrer = referrers[
                bound(
                    uint256(
                        keccak256(
                            abi.encode(
                                _seed,
                                i,
                                "ref"
                            )
                        )
                    ),
                    0,
                    2
                )
            ];

            vm.prank(
                vaultA
            );

            registry.mergeReferrer(
                user1,
                referrer,
                ts,
                rank
            );

            uint256 key = registry.referrerKey(user1);

            assertGt(key, 0);

            if (previousKey != 0) {
                assertLe(key, previousKey);
            }

            previousKey = key;
        }
    }

    function testFuzz_merge_orderIndependent(
        uint256 _tsA,
        uint256 _tsB,
        uint256 _rankA,
        uint256 _rankB,
        bool _sameReferrer
    )
        public
    {
        uint256 tsA = bound(
            _tsA,
            1,
            BASE_TIME
        );

        uint256 tsB = bound(
            _tsB,
            1,
            BASE_TIME
        );

        uint256 rankA = bound(
            _rankA,
            0,
            15
        );

        uint256 rankB = bound(
            _rankB,
            0,
            15
        );

        address referrerA = refA;

        address referrerB = _sameReferrer
            ? refA
            : refB;

        if (_key(tsA, rankA) == _key(tsB, rankB)) {
            referrerB = referrerA;
        }

        ReferralRegistry mirror = new ReferralRegistry(
            address(this),
            0
        );

        mirror.setAllowedVault(
            vaultA,
            true
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            referrerA,
            tsA,
            rankA
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            referrerB,
            tsB,
            rankB
        );

        vm.prank(
            vaultA
        );

        mirror.mergeReferrer(
            user1,
            referrerB,
            tsB,
            rankB
        );

        vm.prank(
            vaultA
        );

        mirror.mergeReferrer(
            user1,
            referrerA,
            tsA,
            rankA
        );

        address mirrorReferrer = mirror.referrerOf(user1);

        uint256 mirrorKey = mirror.referrerKey(user1);

        assertEq(registry.referrerOf(user1), mirrorReferrer);
        assertEq(registry.referrerKey(user1), mirrorKey);
    }

    function testFuzz_merge_idempotent(
        uint256 _ts,
        uint256 _rank,
        bool _preAssigned
    )
        public
    {
        uint256 rank = bound(
            _rank,
            0,
            15
        );

        uint256 ts;

        if (_preAssigned) {

            ts = bound(
                _ts,
                1,
                BASE_TIME - 1
            );

            vm.prank(
                vaultA
            );

            registry.assignReferrer(
                user1,
                refA
            );
        } else {

            ts = bound(
                _ts,
                1,
                BASE_TIME + 1 hours
            );
        }

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            refB,
            ts,
            rank
        );

        address referrerAfterOnce = registry.referrerOf(user1);

        uint256 keyAfterOnce = registry.referrerKey(user1);

        address markerAfterOnce = registry.pendingFlip(vaultA, user1);

        vm.recordLogs();

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            refB,
            ts,
            rank
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0);
        assertEq(registry.referrerOf(user1), referrerAfterOnce);
        assertEq(registry.referrerKey(user1), keyAfterOnce);
        assertEq(registry.pendingFlip(vaultA, user1), markerAfterOnce);
    }

    // ---- merge guards ----

    function test_mergeReferrer_revertsWhenNotAllowedVault()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.NotAllowedVault.selector
        );

        registry.mergeReferrer(
            user1,
            refA,
            BASE_TIME - 1,
            0
        );
    }

    function test_mergeReferrer_revertsWhenReferrerIsCallingVault()
        public
    {
        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.mergeReferrer(
            user1,
            vaultA,
            BASE_TIME - 1,
            0
        );
    }

    function test_mergeReferrer_revertsWhenReferrerIsAllowedVault()
        public
    {
        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.mergeReferrer(
            user1,
            vaultB,
            BASE_TIME - 1,
            0
        );
    }

    function test_mergeReferrer_syncKeyInvalidArms()
        public
    {
        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.SyncKeyInvalid.selector
        );

        registry.mergeReferrer(
            user1,
            refA,
            0,
            0
        );

        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.SyncKeyInvalid.selector
        );

        registry.mergeReferrer(
            user1,
            refA,
            BASE_TIME + 1 hours + 1,
            0
        );

        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.SyncKeyInvalid.selector
        );

        registry.mergeReferrer(
            user1,
            refA,
            BASE_TIME - 1,
            16
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            refA,
            BASE_TIME + 1 hours,
            15
        );

        assertEq(registry.referrerOf(user1), refA);
        assertEq(registry.referrerKey(user1), _key(BASE_TIME + 1 hours, 15));
    }

    function test_mergeReferrer_zeroAndSelfArms()
        public
    {
        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.ZeroAddress.selector
        );

        registry.mergeReferrer(
            address(0),
            refA,
            BASE_TIME - 1,
            0
        );

        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.ZeroAddress.selector
        );

        registry.mergeReferrer(
            user1,
            address(0),
            BASE_TIME - 1,
            0
        );

        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.SelfReferral.selector
        );

        registry.mergeReferrer(
            user1,
            user1,
            BASE_TIME - 1,
            0
        );

        address registryAddress = address(registry);

        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.mergeReferrer(
            user1,
            registryAddress,
            BASE_TIME - 1,
            0
        );
    }

    // ---- ccipReceive ----

    function test_ccipReceive_happyPath_mergesAndEmits()
        public
    {
        _armReceive();

        bytes32 messageId = bytes32(
            uint256(0xAA01)
        );

        Client.Any2EVMMessage memory message = _syncMessage(
            messageId,
            SEL_ONE,
            peerOne,
            _syncData(
                1,
                user1,
                refA,
                BASE_TIME - 3 days,
                2
            )
        );

        uint256 incomingKey = _key(
            BASE_TIME - 3 days,
            2
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit ReferralSyncAdopted(
            user1,
            refA,
            incomingKey
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit SyncReceived(
            SEL_ONE,
            messageId,
            user1
        );

        vm.prank(
            routerEoa
        );

        registry.ccipReceive(
            message
        );

        assertEq(registry.referrerOf(user1), refA);
        assertEq(registry.referrerKey(user1), incomingKey);
        assertTrue(registry.processedSyncMessageId(messageId));
    }

    function test_ccipReceive_revertsWhenReplayed()
        public
    {
        _armReceive();

        Client.Any2EVMMessage memory message = _syncMessage(
            bytes32(
                uint256(0xAA02)
            ),
            SEL_ONE,
            peerOne,
            _syncData(
                1,
                user1,
                refA,
                BASE_TIME - 3 days,
                2
            )
        );

        vm.prank(
            routerEoa
        );

        registry.ccipReceive(
            message
        );

        vm.prank(
            routerEoa
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.SyncAlreadyProcessed.selector
        );

        registry.ccipReceive(
            message
        );
    }

    function test_ccipReceive_revertsWhenReferrerIsLocalAllowedVault()
        public
    {
        _armReceive();

        Client.Any2EVMMessage memory message = _syncMessage(
            bytes32(
                uint256(0xAA03)
            ),
            SEL_ONE,
            peerOne,
            _syncData(
                1,
                user1,
                vaultB,
                BASE_TIME - 3 days,
                2
            )
        );

        vm.prank(
            routerEoa
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.ccipReceive(
            message
        );

        assertEq(
            registry.referrerOf(user1),
            address(0)
        );
    }

    function test_ccipReceive_revertsWhenNotRouter()
        public
    {
        _armReceive();

        Client.Any2EVMMessage memory message = _syncMessage(
            bytes32(
                uint256(0xAA03)
            ),
            SEL_ONE,
            peerOne,
            _syncData(
                1,
                user1,
                refA,
                BASE_TIME - 3 days,
                2
            )
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.NotCcipRouter.selector
        );

        registry.ccipReceive(
            message
        );
    }

    function test_ccipReceive_revertsWhenPeerNotEnabled()
        public
    {
        _armReceive();

        Client.Any2EVMMessage memory message = _syncMessage(
            bytes32(
                uint256(0xAA04)
            ),
            SEL_TWO,
            peerOne,
            _syncData(
                1,
                user1,
                refA,
                BASE_TIME - 3 days,
                2
            )
        );

        vm.prank(
            routerEoa
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.SyncPeerNotEnabled.selector
        );

        registry.ccipReceive(
            message
        );
    }

    function test_ccipReceive_revertsWhenPeerMismatch()
        public
    {
        _armReceive();

        Client.Any2EVMMessage memory message = _syncMessage(
            bytes32(
                uint256(0xAA05)
            ),
            SEL_ONE,
            stranger,
            _syncData(
                1,
                user1,
                refA,
                BASE_TIME - 3 days,
                2
            )
        );

        vm.prank(
            routerEoa
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.SyncPeerMismatch.selector
        );

        registry.ccipReceive(
            message
        );
    }

    function test_ccipReceive_revertsWhenPayloadWrongLength()
        public
    {
        _armReceive();

        Client.Any2EVMMessage memory message = _syncMessage(
            bytes32(
                uint256(0xAA06)
            ),
            SEL_ONE,
            peerOne,
            abi.encode(
                uint256(1),
                user1,
                refA,
                BASE_TIME - 3 days
            )
        );

        vm.prank(
            routerEoa
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.SyncPayloadInvalid.selector
        );

        registry.ccipReceive(
            message
        );
    }

    function test_ccipReceive_revertsWhenPayloadWrongVersion()
        public
    {
        _armReceive();

        Client.Any2EVMMessage memory message = _syncMessage(
            bytes32(
                uint256(0xAA07)
            ),
            SEL_ONE,
            peerOne,
            _syncData(
                2,
                user1,
                refA,
                BASE_TIME - 3 days,
                2
            )
        );

        vm.prank(
            routerEoa
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.SyncPayloadInvalid.selector
        );

        registry.ccipReceive(
            message
        );
    }

    // ---- broadcastSync ----

    function test_broadcastSync_multiLane_sendsAndEmits()
        public
    {
        MockSyncCcipRouter router = _armBroadcast();

        uint256 key = _key(
            BASE_TIME,
            0
        );

        bytes32 firstId = keccak256(
            abi.encode(
                SEL_ONE,
                uint256(1)
            )
        );

        bytes32 secondId = keccak256(
            abi.encode(
                SEL_TWO,
                uint256(2)
            )
        );

        vm.deal(
            address(this),
            1 ether
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit SyncBroadcast(
            user1,
            SEL_ONE,
            refA,
            key,
            firstId
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit SyncBroadcast(
            user1,
            SEL_TWO,
            refA,
            key,
            secondId
        );

        registry.broadcastSync{value: 2 * SYNC_FEE}(
            user1,
            _lanes(
                SEL_ONE,
                SEL_TWO
            )
        );

        assertEq(router.sendCount(), 2);
        assertEq(router.lastSelector(), SEL_TWO);
        assertEq(address(router).balance, 2 * SYNC_FEE);
        assertEq(address(registry).balance, 0);

        assertEq(router.lastReceiver(), abi.encode(peerTwo));

        (
            uint256 version,
            address user,
            address referrer,
            uint256 assignedAt,
            uint256 rank
        ) = abi.decode(
            router.lastData(),
            (uint256, address, address, uint256, uint256)
        );

        assertEq(version, 1);
        assertEq(user, user1);
        assertEq(referrer, refA);
        assertEq(assignedAt, BASE_TIME);
        assertEq(rank, 0);
    }

    function test_broadcastSync_refundsExcess()
        public
    {
        MockSyncCcipRouter router = _armBroadcast();

        vm.deal(
            address(this),
            10 ether
        );

        uint256 balanceBefore = address(this).balance;

        registry.broadcastSync{value: 2 * SYNC_FEE + 0.5 ether}(
            user1,
            _lanes(
                SEL_ONE,
                SEL_TWO
            )
        );

        assertEq(address(this).balance, balanceBefore - 2 * SYNC_FEE);
        assertEq(address(router).balance, 2 * SYNC_FEE);
        assertEq(address(registry).balance, 0);
    }

    function test_broadcastSync_revertsWhenFeeInsufficient()
        public
    {
        _armBroadcast();

        vm.deal(
            address(this),
            1 ether
        );

        uint64[] memory lanes = _lanes(
            SEL_ONE,
            SEL_TWO
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InsufficientSyncFee.selector
        );

        registry.broadcastSync{value: 2 * SYNC_FEE - 1}(
            user1,
            lanes
        );
    }

    function test_broadcastSync_revertsWhenLaneDisabled()
        public
    {
        _armBroadcast();

        vm.deal(
            address(this),
            1 ether
        );

        uint64[] memory lanes = _lanes(
            SEL_ONE,
            SEL_DEAD
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.SyncPeerNotEnabled.selector
        );

        registry.broadcastSync{value: 2 * SYNC_FEE}(
            user1,
            lanes
        );
    }

    function test_broadcastSync_revertsWhenNoSelectors()
        public
    {
        uint64[] memory lanes = new uint64[](0);

        vm.expectRevert(
            ReferralRegistryDeclarations.NothingToSync.selector
        );

        registry.broadcastSync(
            user1,
            lanes
        );
    }

    function test_broadcastSync_revertsWhenTooManyLanes()
        public
    {
        uint64[] memory lanes = new uint64[](9);

        vm.expectRevert(
            ReferralRegistryDeclarations.TooManySyncLanes.selector
        );

        registry.broadcastSync(
            user1,
            lanes
        );
    }

    function test_broadcastSync_revertsWhenKeyZero()
        public
    {
        _armBroadcast();

        uint64[] memory lanes = _lanes(
            SEL_ONE
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.NothingToSync.selector
        );

        registry.broadcastSync(
            user2,
            lanes
        );
    }

    function test_broadcastSync_revertsWhenRouterNotSet()
        public
    {
        ReferralRegistry fresh = new ReferralRegistry(
            address(this),
            0
        );

        fresh.setAllowedVault(
            vaultA,
            true
        );

        vm.prank(
            vaultA
        );

        fresh.assignReferrer(
            user1,
            refA
        );

        uint64[] memory lanes = _lanes(
            SEL_ONE
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.RouterNotSet.selector
        );

        fresh.broadcastSync(
            user1,
            lanes
        );
    }

    function test_broadcastSync_revertsWhenRefundRejected()
        public
    {
        _armBroadcast();

        RefundRejector rejector = new RefundRejector(
            registry
        );

        vm.deal(
            address(this),
            1 ether
        );

        uint64[] memory lanes = _lanes(
            SEL_ONE
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.SyncRefundFailed.selector
        );

        rejector.trigger{value: SYNC_FEE + 0.1 ether}(
            user1,
            lanes
        );
    }

    // ---- quoteSyncFee ----

    function test_quoteSyncFee_sumsLaneFees()
        public
    {
        _armBroadcast();

        assertEq(
            registry.quoteSyncFee(
                user1,
                _lanes(
                    SEL_ONE,
                    SEL_TWO
                )
            ),
            2 * SYNC_FEE
        );

        uint64[] memory empty = new uint64[](0);

        assertEq(
            registry.quoteSyncFee(
                user1,
                empty
            ),
            0
        );
    }

    function test_quoteSyncFee_revertsWhenLaneDisabled()
        public
    {
        _armBroadcast();

        uint64[] memory lanes = _lanes(
            SEL_DEAD
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.SyncPeerNotEnabled.selector
        );

        registry.quoteSyncFee(
            user1,
            lanes
        );
    }

    // ---- pokeMigration ----

    function test_pokeMigration_migratesAndClearsMarker()
        public
    {
        MockFlipVault vault = _installFlipVault();

        _assignThenFlip(
            address(vault),
            user1
        );

        assertEq(registry.pendingFlip(address(vault), user1), refA);

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit FlipMigrated(
            address(vault),
            user1,
            refA,
            refB
        );

        registry.pokeMigration(
            user1
        );

        assertEq(registry.pendingFlip(address(vault), user1), address(0));
        assertEq(vault.flipCallCount(), 1);
        assertEq(vault.lastUser(), user1);
        assertEq(vault.lastOldReferrer(), refA);
        assertEq(vault.lastNewReferrer(), refB);
        assertEq(registry.effectiveReferrerOf(user1, address(vault)), refB);
    }

    function test_pokeMigration_revertingVaultDefersThenRetries()
        public
    {
        MockFlipVault vault = _installFlipVault();

        vault.setShouldRevert(
            true
        );

        _assignThenFlip(
            address(vault),
            user1
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit FlipMigrationDeferred(
            address(vault),
            user1,
            refA,
            refB
        );

        registry.pokeMigration(
            user1
        );

        assertEq(registry.pendingFlip(address(vault), user1), refA);
        assertEq(vault.flipCallCount(), 0);

        vault.setShouldRevert(
            false
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit FlipMigrated(
            address(vault),
            user1,
            refA,
            refB
        );

        registry.pokeMigration(
            user1
        );

        assertEq(registry.pendingFlip(address(vault), user1), address(0));
        assertEq(vault.flipCallCount(), 1);
    }

    function test_pokeMigration_oldEqualsCurrent_clearsWithoutCall()
        public
    {
        MockFlipVault vault = _installFlipVault();

        _assignThenFlip(
            address(vault),
            user1
        );

        vm.prank(
            address(vault)
        );

        registry.mergeReferrer(
            user1,
            refA,
            BASE_TIME - 2 days,
            0
        );

        assertEq(registry.referrerOf(user1), refA);
        assertEq(registry.pendingFlip(address(vault), user1), refA);

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit FlipCleared(
            address(vault),
            user1,
            refA
        );

        registry.pokeMigration(
            user1
        );

        assertEq(registry.pendingFlip(address(vault), user1), address(0));
        assertEq(vault.flipCallCount(), 0);
    }

    function test_pokeMigration_secondPoke_noOp()
        public
    {
        MockFlipVault vault = _installFlipVault();

        _assignThenFlip(
            address(vault),
            user1
        );

        registry.pokeMigration(
            user1
        );

        vm.recordLogs();

        registry.pokeMigration(
            user1
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0);
        assertEq(vault.flipCallCount(), 1);
    }

    function test_pokeMigration_revokedVaultMarkerUntouched()
        public
    {
        registry.setAllowedVault(
            vaultA,
            false
        );

        registry.setAllowedVault(
            vaultB,
            false
        );

        MockFlipVault keeper = new MockFlipVault();

        MockFlipVault dropped = new MockFlipVault();

        registry.setAllowedVault(
            address(keeper),
            true
        );

        registry.setAllowedVault(
            address(dropped),
            true
        );

        _assignThenFlip(
            address(keeper),
            user1
        );

        assertEq(registry.pendingFlip(address(dropped), user1), refA);

        registry.setAllowedVault(
            address(dropped),
            false
        );

        registry.pokeMigration(
            user1
        );

        assertEq(registry.pendingFlip(address(keeper), user1), address(0));
        assertEq(keeper.flipCallCount(), 1);
        assertEq(registry.pendingFlip(address(dropped), user1), refA);
        assertEq(dropped.flipCallCount(), 0);
    }

    // ---- effectiveReferrerOf ----

    function test_effectiveReferrerOf_markerRedirectAndFallThrough()
        public
    {
        assertEq(registry.effectiveReferrerOf(user2, vaultA), address(0));

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        assertEq(registry.effectiveReferrerOf(user1, vaultA), refA);

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            refB,
            BASE_TIME - 1 days,
            0
        );

        assertEq(registry.referrerOf(user1), refB);
        assertEq(registry.effectiveReferrerOf(user1, vaultA), refA);
        assertEq(registry.effectiveReferrerOf(user1, vaultB), refA);
        assertEq(registry.effectiveReferrerOf(user1, address(0xDD)), refB);
    }

    // ---- sync admin ----

    function test_setCcipRouter_oneShot()
        public
    {
        vm.expectRevert(
            ReferralRegistryDeclarations.ZeroAddress.selector
        );

        registry.setCcipRouter(
            address(0)
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(registry)
        );

        emit CcipRouterSet(
            routerEoa
        );

        registry.setCcipRouter(
            routerEoa
        );

        assertEq(registry.ccipRouter(), routerEoa);

        vm.expectRevert(
            ReferralRegistryDeclarations.RouterAlreadySet.selector
        );

        registry.setCcipRouter(
            address(0xF2)
        );
    }

    function test_setSyncGasLimit_bounds()
        public
    {
        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidSyncGasLimit.selector
        );

        registry.setSyncGasLimit(
            299_999
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidSyncGasLimit.selector
        );

        registry.setSyncGasLimit(
            2_000_001
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(registry)
        );

        emit SyncGasLimitSet(
            300_000
        );

        registry.setSyncGasLimit(
            300_000
        );

        assertEq(registry.syncGasLimit(), 300_000);

        registry.setSyncGasLimit(
            2_000_000
        );

        assertEq(registry.syncGasLimit(), 2_000_000);
    }

    function test_syncPeer_proposeExecuteInstantPreFinalize()
        public
    {
        vm.expectRevert(
            ReferralRegistryDeclarations.ZeroAddress.selector
        );

        registry.proposeSyncPeer(
            SEL_ONE,
            address(0)
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit SyncPeerProposed(
            SEL_ONE,
            peerOne,
            BASE_TIME
        );

        registry.proposeSyncPeer(
            SEL_ONE,
            peerOne
        );

        assertEq(registry.proposedSyncPeer(SEL_ONE), peerOne);
        assertEq(registry.syncPeerChangeQueuedAt(SEL_ONE), BASE_TIME);

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit SyncPeerSet(
            SEL_ONE,
            peerOne
        );

        registry.executeSyncPeerChange(
            SEL_ONE
        );

        assertEq(registry.syncPeer(SEL_ONE), peerOne);
        assertTrue(registry.syncPeerEnabled(SEL_ONE));
        assertEq(registry.proposedSyncPeer(SEL_ONE), address(0));
        assertEq(registry.syncPeerChangeQueuedAt(SEL_ONE), 0);
    }

    function test_executeSyncPeerChange_revertsWhenNoneProposed()
        public
    {
        vm.expectRevert(
            ReferralRegistryDeclarations.NoSyncPeerProposed.selector
        );

        registry.executeSyncPeerChange(
            SEL_ONE
        );
    }

    function test_syncPeer_timelockAfterFinalize()
        public
    {
        registry.setCcipRouter(
            routerEoa
        );

        registry.finalizeSyncSetup();

        registry.proposeSyncPeer(
            SEL_ONE,
            peerOne
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.SyncPeerTimelockNotElapsed.selector
        );

        registry.executeSyncPeerChange(
            SEL_ONE
        );

        vm.warp(
            BASE_TIME + 3 days + 1
        );

        registry.executeSyncPeerChange(
            SEL_ONE
        );

        assertEq(registry.syncPeer(SEL_ONE), peerOne);
        assertTrue(registry.syncPeerEnabled(SEL_ONE));
    }

    function test_cancelSyncPeerChange_clearsProposal()
        public
    {
        registry.proposeSyncPeer(
            SEL_ONE,
            peerOne
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit SyncPeerProposalCancelled(
            SEL_ONE,
            peerOne
        );

        registry.cancelSyncPeerChange(
            SEL_ONE
        );

        assertEq(registry.proposedSyncPeer(SEL_ONE), address(0));
        assertEq(registry.syncPeerChangeQueuedAt(SEL_ONE), 0);

        vm.expectRevert(
            ReferralRegistryDeclarations.NoSyncPeerProposed.selector
        );

        registry.executeSyncPeerChange(
            SEL_ONE
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.NoSyncPeerProposed.selector
        );

        registry.cancelSyncPeerChange(
            SEL_ONE
        );
    }

    function test_removeSyncPeer_instant()
        public
    {
        _enablePeer(
            SEL_ONE,
            peerOne
        );

        registry.setCcipRouter(
            routerEoa
        );

        registry.finalizeSyncSetup();

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit SyncPeerRemoved(
            SEL_ONE,
            peerOne
        );

        registry.removeSyncPeer(
            SEL_ONE
        );

        assertFalse(registry.syncPeerEnabled(SEL_ONE));
        assertEq(registry.syncPeer(SEL_ONE), address(0));
    }

    function test_removeSyncPeer_noopWhenUnsetStaysSilent()
        public
    {
        vm.recordLogs();

        registry.removeSyncPeer(
            SEL_ONE
        );

        assertEq(
            vm.getRecordedLogs().length,
            0
        );

        assertFalse(registry.syncPeerEnabled(SEL_ONE));
        assertEq(registry.syncPeer(SEL_ONE), address(0));
    }

    function test_finalizeSyncSetup_oneShotAndRequiresRouter()
        public
    {
        vm.expectRevert(
            ReferralRegistryDeclarations.RouterNotSet.selector
        );

        registry.finalizeSyncSetup();

        registry.setCcipRouter(
            routerEoa
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(registry)
        );

        emit SyncSetupFinalized();

        registry.finalizeSyncSetup();

        assertTrue(registry.syncInitialized());

        vm.expectRevert(
            ReferralRegistryDeclarations.SyncSetupAlreadyFinalized.selector
        );

        registry.finalizeSyncSetup();
    }

    function test_setAllowedVault_trackedListLifecycle()
        public
    {
        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(registry)
        );

        emit VaultAllowedSet(
            vaultC,
            true
        );

        registry.setAllowedVault(
            vaultC,
            true
        );

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            refB,
            BASE_TIME - 1 days,
            0
        );

        assertEq(registry.pendingFlip(vaultA, user1), refA);
        assertEq(registry.pendingFlip(vaultB, user1), refA);
        assertEq(registry.pendingFlip(vaultC, user1), refA);

        registry.setAllowedVault(
            vaultB,
            false
        );

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user2,
            refA
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user2,
            refB,
            BASE_TIME - 1 days,
            0
        );

        assertEq(registry.pendingFlip(vaultA, user2), refA);
        assertEq(registry.pendingFlip(vaultB, user2), address(0));
        assertEq(registry.pendingFlip(vaultC, user2), refA);

        registry.setAllowedVault(
            vaultB,
            true
        );

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user3,
            refA
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user3,
            refB,
            BASE_TIME - 1 days,
            0
        );

        assertEq(registry.pendingFlip(vaultA, user3), refA);
        assertEq(registry.pendingFlip(vaultB, user3), refA);
        assertEq(registry.pendingFlip(vaultC, user3), refA);
    }

    function test_setAllowedVault_capEight_ninthReverts()
        public
    {
        registry.setAllowedVault(
            vaultA,
            true
        );

        for (uint256 i; i < 6; ++i) {

            registry.setAllowedVault(
                address(
                    uint160(0xD3 + i)
                ),
                true
            );
        }

        vm.expectRevert(
            ReferralRegistryDeclarations.TooManyTrackedVaults.selector
        );

        registry.setAllowedVault(
            address(0xD9),
            true
        );

        assertFalse(registry.allowedVault(address(0xD9)));

        registry.setAllowedVault(
            vaultB,
            false
        );

        registry.setAllowedVault(
            address(0xD9),
            true
        );

        assertTrue(registry.allowedVault(address(0xD9)));
    }

    // ---- interface surface ----

    function test_supportsInterface_reportsCcipReceiverAndErc165()
        public
    {
        assertTrue(
            registry.supportsInterface(
                type(IAny2EVMMessageReceiver).interfaceId
            )
        );

        assertTrue(
            registry.supportsInterface(
                type(IERC165).interfaceId
            )
        );

        assertFalse(
            registry.supportsInterface(
                0xffffffff
            )
        );
    }
}
