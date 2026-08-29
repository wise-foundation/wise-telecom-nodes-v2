// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {ReferralRegistry} from "../../../src/registry/pending/ReferralRegistry.sol";

import {MockFlipVault} from "../ReferralRegistrySync.t.sol";

/**
 * @dev Drives four standalone {ReferralRegistry} instances (ranks 0
 * through 3, simulating one registry per chain) through bounded random
 * local assignments, honest pair relays (`deliverPair` reads a source
 * registry's stored origin pair and merges it into a destination via
 * `mergeReferrer`), stale re-deliveries from a bounded journal of
 * previously observed pairs, permissionless `pokeMigration` pokes and
 * time warps. The handler itself is the allowlisted driver on every
 * registry (so `mergeReferrer` needs no pranks) and implements a
 * success no-op `receiveReferrerFlip`, making it a healthy tracked
 * vault whose markers always clear on poke; registry zero additionally
 * tracks two {MockFlipVault} recorders, one of them toggled reverting
 * to exercise the defer-and-restore arm.
 *
 * Ghost machinery: after every action a journal sweep compares each
 * (registry, user) pair against its previous snapshot — a nonzero
 * sync key that grows or clears increments `ghostKeyViolations`, and
 * a referrer change without a strictly lower key (or to zero)
 * increments `ghostFlipViolations`. Step-level checks inside the
 * actions feed two more sticky counters: `ghostMarkViolations` (a
 * merge that flipped the stored referrer must leave a pending-flip
 * marker on every tracked vault of that registry) and
 * `ghostPokeViolations` (after a poke, a marker either clears with the
 * recorded relocation call, clears silently when old equals current,
 * or is restored untouched when the vault reverts). Violation
 * counters instead of reverts, because the invariant runner tolerates
 * handler-call reverts — the invariants then require all counters to
 * stay zero.
 */
contract ReferralSyncHandler is Test {

    ReferralRegistry[] internal registries;

    MockFlipVault internal immutable flipVaultA;

    MockFlipVault internal immutable flipVaultB;

    address[4] internal users;

    address[4] internal referrers;

    uint256 internal constant OBSERVED_CAP = 128;

    uint256 public ghostKeyViolations;

    uint256 public ghostFlipViolations;

    uint256 public ghostMarkViolations;

    uint256 public ghostPokeViolations;

    mapping(uint256 => mapping(address => uint256)) public ghostKey;

    mapping(uint256 => mapping(address => address)) public ghostReferrer;

    struct ObservedPair {
        address user;
        address referrer;
        uint256 assignedAt;
        uint256 rank;
    }

    ObservedPair[] internal observedPairs;

    uint256 internal observedCursor;

    constructor(
        ReferralRegistry[] memory _registries,
        MockFlipVault _flipVaultA,
        MockFlipVault _flipVaultB,
        address[4] memory _users,
        address[4] memory _referrers
    ) {
        registries = _registries;

        flipVaultA = _flipVaultA;

        flipVaultB = _flipVaultB;

        users = _users;

        referrers = _referrers;
    }

    modifier journal() {
        _;
        _sweepJournal();
    }

    function receiveReferrerFlip(
        address,
        address,
        address
    )
        external
        pure
    {}

    function localAssign(
        uint256 _regSeed,
        uint256 _userSeed,
        uint256 _referrerSeed
    )
        external
        journal
    {
        ReferralRegistry reg = _pickRegistry(
            _regSeed
        );

        address user = users[_userSeed % 4];

        reg.assignReferrer(
            user,
            referrers[_referrerSeed % 4]
        );

        _recordObserved(
            reg,
            user
        );
    }

    function deliverPair(
        uint256 _srcSeed,
        uint256 _dstSeed,
        uint256 _userSeed
    )
        external
        journal
    {
        ReferralRegistry src = _pickRegistry(
            _srcSeed
        );

        address user = users[_userSeed % 4];

        (
            address referrer,
            uint256 assignedAt,
            uint256 rank
        ) = src.getReferrerPair(
            user
        );

        if (referrer == address(0)) {
            return;
        }

        _mergeChecked(
            _pickRegistry(
                _dstSeed
            ),
            user,
            referrer,
            assignedAt,
            rank
        );

        _recordObserved(
            src,
            user
        );
    }

    function deliverStale(
        uint256 _entrySeed,
        uint256 _dstSeed
    )
        external
        journal
    {
        uint256 count = observedPairs.length;

        if (count == 0) {
            return;
        }

        ObservedPair memory pair = observedPairs[_entrySeed % count];

        _mergeChecked(
            _pickRegistry(
                _dstSeed
            ),
            pair.user,
            pair.referrer,
            pair.assignedAt,
            pair.rank
        );
    }

    function pokeFlips(
        uint256 _regSeed,
        uint256 _userSeed
    )
        external
        journal
    {
        ReferralRegistry reg = _pickRegistry(
            _regSeed
        );

        address user = users[_userSeed % 4];

        address current = reg.referrerOf(
            user
        );

        bool primary = address(reg) == address(registries[0]);

        address oldMarkerA;

        address oldMarkerB;

        uint256 callsBeforeA;

        uint256 callsBeforeB;

        bool revertingB;

        if (primary) {

            oldMarkerA = reg.pendingFlip(
                address(flipVaultA),
                user
            );

            oldMarkerB = reg.pendingFlip(
                address(flipVaultB),
                user
            );

            callsBeforeA = flipVaultA.flipCallCount();

            callsBeforeB = flipVaultB.flipCallCount();

            revertingB = flipVaultB.shouldRevert();
        }

        reg.pokeMigration(
            user
        );

        if (reg.pendingFlip(address(this), user) != address(0)) {
            ++ghostPokeViolations;
        }

        if (primary == false) {
            return;
        }

        _checkPokeOutcome(
            reg,
            flipVaultA,
            user,
            current,
            oldMarkerA,
            callsBeforeA,
            false
        );

        _checkPokeOutcome(
            reg,
            flipVaultB,
            user,
            current,
            oldMarkerB,
            callsBeforeB,
            revertingB
        );
    }

    function toggleFlipRevert(
        uint256 _seed
    )
        external
        journal
    {
        flipVaultB.setShouldRevert(
            _seed % 2 == 0
        );
    }

    function warp(
        uint256 _seed
    )
        external
        journal
    {
        vm.warp(
            block.timestamp + bound(
                _seed,
                1,
                3 days
            )
        );
    }

    function _pickRegistry(
        uint256 _seed
    )
        internal
        view
        returns (ReferralRegistry)
    {
        return registries[_seed % registries.length];
    }

    function _mergeChecked(
        ReferralRegistry _dst,
        address _user,
        address _referrer,
        uint256 _assignedAt,
        uint256 _rank
    )
        internal
    {
        address referrerBefore = _dst.referrerOf(
            _user
        );

        _dst.mergeReferrer(
            _user,
            _referrer,
            _assignedAt,
            _rank
        );

        address referrerAfter = _dst.referrerOf(
            _user
        );

        if (referrerBefore == address(0) || referrerAfter == referrerBefore) {
            return;
        }

        if (_dst.pendingFlip(address(this), _user) == address(0)) {
            ++ghostMarkViolations;
        }

        if (address(_dst) != address(registries[0])) {
            return;
        }

        if (_dst.pendingFlip(address(flipVaultA), _user) == address(0)) {
            ++ghostMarkViolations;
        }

        if (_dst.pendingFlip(address(flipVaultB), _user) == address(0)) {
            ++ghostMarkViolations;
        }
    }

    function _checkPokeOutcome(
        ReferralRegistry _reg,
        MockFlipVault _vault,
        address _user,
        address _current,
        address _oldMarker,
        uint256 _callsBefore,
        bool _reverting
    )
        internal
    {
        address markerAfter = _reg.pendingFlip(
            address(_vault),
            _user
        );

        uint256 callsAfter = _vault.flipCallCount();

        if (_oldMarker == address(0) || _oldMarker == _current) {

            if (markerAfter != address(0) || callsAfter != _callsBefore) {
                ++ghostPokeViolations;
            }

            return;
        }

        if (_reverting) {

            if (markerAfter != _oldMarker || callsAfter != _callsBefore) {
                ++ghostPokeViolations;
            }

            return;
        }

        if (markerAfter != address(0)) {
            ++ghostPokeViolations;
        }

        if (callsAfter != _callsBefore + 1) {
            ++ghostPokeViolations;
        }

        if (
            _vault.lastUser() != _user
                || _vault.lastOldReferrer() != _oldMarker
                || _vault.lastNewReferrer() != _current
        ) {
            ++ghostPokeViolations;
        }
    }

    function _recordObserved(
        ReferralRegistry _reg,
        address _user
    )
        internal
    {
        (
            address referrer,
            uint256 assignedAt,
            uint256 rank
        ) = _reg.getReferrerPair(
            _user
        );

        if (referrer == address(0)) {
            return;
        }

        ObservedPair memory pair = ObservedPair({
            user: _user,
            referrer: referrer,
            assignedAt: assignedAt,
            rank: rank
        });

        if (observedPairs.length < OBSERVED_CAP) {

            observedPairs.push(
                pair
            );

            return;
        }

        observedPairs[observedCursor] = pair;

        observedCursor = (observedCursor + 1) % OBSERVED_CAP;
    }

    function _sweepJournal()
        internal
    {
        uint256 count = registries.length;

        for (uint256 r; r < count; ++r) {

            ReferralRegistry reg = registries[r];

            for (uint256 i; i < 4; ++i) {

                address user = users[i];

                uint256 key = reg.referrerKey(
                    user
                );

                address referrer = reg.referrerOf(
                    user
                );

                uint256 prevKey = ghostKey[r][user];

                address prevReferrer = ghostReferrer[r][user];

                if (prevKey != 0 && (key == 0 || key > prevKey)) {
                    ++ghostKeyViolations;
                }

                if (
                    prevReferrer != address(0)
                        && referrer != prevReferrer
                        && (referrer == address(0) || key >= prevKey)
                ) {
                    ++ghostFlipViolations;
                }

                ghostKey[r][user] = key;

                ghostReferrer[r][user] = referrer;
            }
        }
    }
}

/**
 * @dev Stateful-fuzz invariants for the cross-registry min-merge
 * register, driven by {ReferralSyncHandler} over four registries with
 * distinct chain ranks: RS1 is the monotone key law (a stored sync
 * key never increases and never clears, journaled ghost-side after
 * every action); RS2 requires every observed referrer change to be
 * justified by a strictly decreasing key; RS3 pins convergence at the
 * frontier — all registries holding the global minimum key for a user
 * agree on the referrer; RS4 is the stronger binding law behind it
 * (keys are minted once, at one origin, so equal nonzero keys anywhere
 * must bind the same referrer — honest relays can never fork a key);
 * RS5 is well-formedness (key zero exactly when unassigned, stored
 * rank within the deployed rank set, stored timestamp nonzero and
 * never in the future); RS6 and RS7 assert the step-level flip-marker
 * and poke-migration counters stayed zero.
 */
contract ReferralSyncInvariantTest is Test {

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant REGISTRY_COUNT = 4;

    uint256 internal constant KEY_RANK_MASK = 0xff;

    uint256 internal constant KEY_RANK_SHIFT = 8;

    ReferralRegistry[] internal registries;

    MockFlipVault internal flipVaultA;

    MockFlipVault internal flipVaultB;

    ReferralSyncHandler internal handler;

    address[4] internal users;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        users = [
            address(0xA1),
            address(0xA2),
            address(0xA3),
            address(0xA4)
        ];

        address[4] memory referrers = [
            address(0xB1),
            address(0xB2),
            address(0xB3),
            address(0xB4)
        ];

        for (uint256 i; i < REGISTRY_COUNT; ++i) {
            registries.push(
                new ReferralRegistry(
                    address(this),
                    i
                )
            );
        }

        flipVaultA = new MockFlipVault();

        flipVaultB = new MockFlipVault();

        handler = new ReferralSyncHandler(
            registries,
            flipVaultA,
            flipVaultB,
            users,
            referrers
        );

        for (uint256 i; i < REGISTRY_COUNT; ++i) {
            registries[i].setAllowedVault(
                address(handler),
                true
            );
        }

        registries[0].setAllowedVault(
            address(flipVaultA),
            true
        );

        registries[0].setAllowedVault(
            address(flipVaultB),
            true
        );

        targetContract(
            address(handler)
        );
    }

    // ---- invariants ----

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_RS1_syncKeyNeverRegresses()
        public
        view
    {
        assertEq(
            handler.ghostKeyViolations(),
            0,
            "RS1: a stored sync key increased or cleared"
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_RS2_flipRequiresStrictlyLowerKey()
        public
        view
    {
        assertEq(
            handler.ghostFlipViolations(),
            0,
            "RS2: a referrer changed without a strictly lower key"
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_RS3_globalMinKeyHoldersAgree()
        public
        view
    {
        for (uint256 u; u < 4; ++u) {

            address user = users[u];

            uint256 minKey = type(uint256).max;

            for (uint256 r; r < REGISTRY_COUNT; ++r) {

                uint256 key = registries[r].referrerKey(
                    user
                );

                if (key != 0 && key < minKey) {
                    minKey = key;
                }
            }

            if (minKey == type(uint256).max) {
                continue;
            }

            address expected;

            for (uint256 r; r < REGISTRY_COUNT; ++r) {

                if (registries[r].referrerKey(user) != minKey) {
                    continue;
                }

                address referrer = registries[r].referrerOf(
                    user
                );

                if (expected == address(0)) {

                    expected = referrer;

                    continue;
                }

                assertEq(
                    referrer,
                    expected,
                    "RS3: global min-key holders disagree on referrer"
                );
            }
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_RS4_equalKeysBindOneReferrer()
        public
        view
    {
        for (uint256 u; u < 4; ++u) {

            address user = users[u];

            for (uint256 i; i < REGISTRY_COUNT; ++i) {

                uint256 keyI = registries[i].referrerKey(
                    user
                );

                if (keyI == 0) {
                    continue;
                }

                for (uint256 j = i + 1; j < REGISTRY_COUNT; ++j) {

                    if (registries[j].referrerKey(user) != keyI) {
                        continue;
                    }

                    assertEq(
                        registries[i].referrerOf(user),
                        registries[j].referrerOf(user),
                        "RS4: equal sync keys bind different referrers"
                    );
                }
            }
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_RS5_keyWellFormedIffAssigned()
        public
        view
    {
        for (uint256 r; r < REGISTRY_COUNT; ++r) {

            for (uint256 u; u < 4; ++u) {

                address user = users[u];

                uint256 key = registries[r].referrerKey(
                    user
                );

                address referrer = registries[r].referrerOf(
                    user
                );

                assertEq(
                    key == 0,
                    referrer == address(0),
                    "RS5: key/referrer zero-state mismatch"
                );

                if (key == 0) {
                    continue;
                }

                assertLe(
                    key & KEY_RANK_MASK,
                    REGISTRY_COUNT - 1,
                    "RS5: stored rank outside the deployed rank set"
                );

                assertGt(
                    key >> KEY_RANK_SHIFT,
                    0,
                    "RS5: stored assignedAt is zero"
                );

                assertLe(
                    key >> KEY_RANK_SHIFT,
                    block.timestamp,
                    "RS5: stored assignedAt is in the future"
                );
            }
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_RS6_flipsMarkEveryTrackedVault()
        public
        view
    {
        assertEq(
            handler.ghostMarkViolations(),
            0,
            "RS6: a flip left a tracked vault without a pending marker"
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_RS7_pokeMigrationMarkerDiscipline()
        public
        view
    {
        assertEq(
            handler.ghostPokeViolations(),
            0,
            "RS7: a poke cleared, kept or relayed a marker incorrectly"
        );
    }
}
