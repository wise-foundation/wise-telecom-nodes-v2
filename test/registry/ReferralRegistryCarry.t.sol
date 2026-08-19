// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ReferralRegistry} from "../../src/registry/pending/ReferralRegistry.sol";
import {ReferralRegistryDeclarations} from "../../src/registry/pending/ReferralRegistryDeclarations.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev Carry-staging suite for {ReferralRegistry} — the
 * same-chain move-attribution mailbox. Covers the allowlist gate on
 * both writers (including the revoked-vault revert the vaults absorb
 * through their guarded CALL seams), the guard-class stage reverts
 * (zero endpoints, self-destination, empty and oversized payloads,
 * the exact MAX_CARRY_WORDS boundary), delete-then-write overwrite
 * semantics (a shorter re-stage leaves no trailing words behind),
 * `stagedAt` stamping, consume-as-drain (read + delete, second
 * consume empty, event only when something was actually drained),
 * and the keying isolation matrix: consume keys the CALLER as the
 * destination, so an allowlisted third vault cannot drain a payload
 * addressed to another vault, and payloads are isolated per source
 * vault and per user. The registry never interprets payload words,
 * so contents here are arbitrary fuzz words round-tripped verbatim.
 */
contract ReferralRegistryCarryTest is Test {

    event CarryStaged(
        address indexed srcVault,
        address indexed dstVault,
        address indexed user,
        uint256 words
    );

    event CarryConsumed(
        address indexed srcVault,
        address indexed dstVault,
        address indexed user,
        uint256 stagedAt
    );

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    address internal user1 = address(0xA1);

    address internal user2 = address(0xA2);

    address internal vaultA = address(0xD1);

    address internal vaultB = address(0xD2);

    address internal vaultC = address(0xD3);

    ReferralRegistry internal registry;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        registry = new ReferralRegistry();

        registry.setAllowedVault(
            vaultA,
            true
        );

        registry.setAllowedVault(
            vaultB,
            true
        );

        registry.setAllowedVault(
            vaultC,
            true
        );
    }

    // ---- helpers ----

    function _payload(
        uint256 _words,
        uint256 _seed
    )
        internal
        pure
        returns (uint256[] memory payload)
    {
        payload = new uint256[](_words);

        for (uint256 i; i < _words; ++i) {
            payload[i] = uint256(
                keccak256(
                    abi.encode(
                        _seed,
                        i
                    )
                )
            );
        }
    }

    function _stageAs(
        address _srcVault,
        address _dstVault,
        address _user,
        uint256[] memory _words
    )
        internal
    {
        vm.prank(
            _srcVault
        );

        registry.stageCarry(
            _dstVault,
            _user,
            _words
        );
    }

    function _consumedEventCount()
        internal
        returns (uint256 count)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic = keccak256(
            "CarryConsumed(address,address,address,uint256)"
        );

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic) {
                ++count;
            }
        }
    }

    // ---- allowlist gate ----

    function test_stageCarry_revertsWhenNotAllowedVault()
        public
    {
        uint256[] memory payload = _payload(
            1,
            1
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.NotAllowedVault.selector
        );

        vm.prank(
            address(0xE1)
        );

        registry.stageCarry(
            vaultB,
            user1,
            payload
        );
    }

    function test_consumeCarry_revertsWhenNotAllowedVault()
        public
    {
        vm.expectRevert(
            ReferralRegistryDeclarations.NotAllowedVault.selector
        );

        vm.prank(
            address(0xE1)
        );

        registry.consumeCarry(
            vaultA,
            user1
        );
    }

    function test_stageCarry_revertsWhenVaultRevoked()
        public
    {
        registry.setAllowedVault(
            vaultA,
            false
        );

        uint256[] memory payload = _payload(
            1,
            1
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.NotAllowedVault.selector
        );

        vm.prank(
            vaultA
        );

        registry.stageCarry(
            vaultB,
            user1,
            payload
        );
    }

    // ---- stage guards ----

    function test_stageCarry_revertsWhenZeroDstVault()
        public
    {
        uint256[] memory payload = _payload(
            1,
            1
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.ZeroAddress.selector
        );

        vm.prank(
            vaultA
        );

        registry.stageCarry(
            address(0),
            user1,
            payload
        );
    }

    function test_stageCarry_revertsWhenZeroUser()
        public
    {
        uint256[] memory payload = _payload(
            1,
            1
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.ZeroAddress.selector
        );

        vm.prank(
            vaultA
        );

        registry.stageCarry(
            vaultB,
            address(0),
            payload
        );
    }

    function test_stageCarry_revertsWhenSelfDestination()
        public
    {
        uint256[] memory payload = _payload(
            1,
            1
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.CarryPayloadInvalid.selector
        );

        vm.prank(
            vaultA
        );

        registry.stageCarry(
            vaultA,
            user1,
            payload
        );
    }

    function test_stageCarry_revertsWhenEmptyPayload()
        public
    {
        uint256[] memory payload = new uint256[](0);

        vm.expectRevert(
            ReferralRegistryDeclarations.CarryPayloadInvalid.selector
        );

        vm.prank(
            vaultA
        );

        registry.stageCarry(
            vaultB,
            user1,
            payload
        );
    }

    function test_stageCarry_revertsWhenPayloadOversized()
        public
    {
        uint256[] memory payload = _payload(
            CohortWeeks.MAX_CARRY_WORDS + 1,
            1
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.CarryPayloadInvalid.selector
        );

        vm.prank(
            vaultA
        );

        registry.stageCarry(
            vaultB,
            user1,
            payload
        );
    }

    function test_stageCarry_maxWordsSucceeds()
        public
    {
        uint256[] memory payload = _payload(
            CohortWeeks.MAX_CARRY_WORDS,
            1
        );

        _stageAs(
            vaultA,
            vaultB,
            user1,
            payload
        );

        (
            uint256 stagedAt,
            uint256[] memory stored
        ) = registry.getCarry(
            vaultA,
            vaultB,
            user1
        );

        assertEq(stagedAt, BASE_TIME);

        assertEq(stored.length, CohortWeeks.MAX_CARRY_WORDS);
    }

    // ---- stage semantics ----

    function test_stageCarry_storesStampsAndEmits()
        public
    {
        uint256[] memory payload = _payload(
            3,
            7
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit CarryStaged(
            vaultA,
            vaultB,
            user1,
            3
        );

        _stageAs(
            vaultA,
            vaultB,
            user1,
            payload
        );

        (
            uint256 stagedAt,
            uint256[] memory stored
        ) = registry.getCarry(
            vaultA,
            vaultB,
            user1
        );

        assertEq(stagedAt, BASE_TIME);

        assertEq(stored.length, 3);

        for (uint256 i; i < 3; ++i) {
            assertEq(stored[i], payload[i]);
        }
    }

    function test_stageCarry_overwriteReplacesPayloadAndStamp()
        public
    {
        _stageAs(
            vaultA,
            vaultB,
            user1,
            _payload(
                5,
                11
            )
        );

        vm.warp(
            BASE_TIME + 1 hours
        );

        uint256[] memory shorter = _payload(
            2,
            13
        );

        _stageAs(
            vaultA,
            vaultB,
            user1,
            shorter
        );

        (
            uint256 stagedAt,
            uint256[] memory stored
        ) = registry.getCarry(
            vaultA,
            vaultB,
            user1
        );

        assertEq(stagedAt, BASE_TIME + 1 hours);

        assertEq(stored.length, 2);

        for (uint256 i; i < 2; ++i) {
            assertEq(stored[i], shorter[i]);
        }
    }

    // ---- consume semantics ----

    function test_consumeCarry_emptyKeyReturnsZeroWithoutEvent()
        public
    {
        vm.recordLogs();

        vm.prank(
            vaultB
        );

        (
            uint256 stagedAt,
            uint256[] memory payload
        ) = registry.consumeCarry(
            vaultA,
            user1
        );

        assertEq(stagedAt, 0);

        assertEq(payload.length, 0);

        assertEq(_consumedEventCount(), 0);
    }

    function test_consumeCarry_drainsDeletesAndEmits()
        public
    {
        uint256[] memory payload = _payload(
            4,
            17
        );

        _stageAs(
            vaultA,
            vaultB,
            user1,
            payload
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit CarryConsumed(
            vaultA,
            vaultB,
            user1,
            BASE_TIME
        );

        vm.prank(
            vaultB
        );

        (
            uint256 stagedAt,
            uint256[] memory drained
        ) = registry.consumeCarry(
            vaultA,
            user1
        );

        assertEq(stagedAt, BASE_TIME);

        assertEq(drained.length, 4);

        for (uint256 i; i < 4; ++i) {
            assertEq(drained[i], payload[i]);
        }

        (
            uint256 stagedAtAfter,
            uint256[] memory storedAfter
        ) = registry.getCarry(
            vaultA,
            vaultB,
            user1
        );

        assertEq(stagedAtAfter, 0);

        assertEq(storedAfter.length, 0);

        vm.prank(
            vaultB
        );

        (
            uint256 stagedAtSecond,
            uint256[] memory drainedSecond
        ) = registry.consumeCarry(
            vaultA,
            user1
        );

        assertEq(stagedAtSecond, 0);

        assertEq(drainedSecond.length, 0);
    }

    // ---- keying isolation ----

    function test_consumeCarry_keyedByCallerOtherVaultCannotDrain()
        public
    {
        uint256[] memory payload = _payload(
            2,
            19
        );

        _stageAs(
            vaultA,
            vaultB,
            user1,
            payload
        );

        vm.prank(
            vaultC
        );

        (
            uint256 stagedAt,
            uint256[] memory drained
        ) = registry.consumeCarry(
            vaultA,
            user1
        );

        assertEq(stagedAt, 0);

        assertEq(drained.length, 0);

        (
            uint256 stagedAtIntact,
            uint256[] memory storedIntact
        ) = registry.getCarry(
            vaultA,
            vaultB,
            user1
        );

        assertEq(stagedAtIntact, BASE_TIME);

        assertEq(storedIntact.length, 2);
    }

    function test_consumeCarry_isolatedPerUser()
        public
    {
        _stageAs(
            vaultA,
            vaultB,
            user1,
            _payload(
                1,
                23
            )
        );

        _stageAs(
            vaultA,
            vaultB,
            user2,
            _payload(
                1,
                29
            )
        );

        vm.prank(
            vaultB
        );

        registry.consumeCarry(
            vaultA,
            user1
        );

        (
            uint256 stagedAt,
            uint256[] memory stored
        ) = registry.getCarry(
            vaultA,
            vaultB,
            user2
        );

        assertEq(stagedAt, BASE_TIME);

        assertEq(stored.length, 1);
    }

    function test_consumeCarry_isolatedPerSourceVault()
        public
    {
        _stageAs(
            vaultA,
            vaultC,
            user1,
            _payload(
                1,
                31
            )
        );

        _stageAs(
            vaultB,
            vaultC,
            user1,
            _payload(
                1,
                37
            )
        );

        vm.prank(
            vaultC
        );

        registry.consumeCarry(
            vaultA,
            user1
        );

        (
            uint256 stagedAt,
            uint256[] memory stored
        ) = registry.getCarry(
            vaultB,
            vaultC,
            user1
        );

        assertEq(stagedAt, BASE_TIME);

        assertEq(stored.length, 1);
    }

    // ---- round trip ----

    function testFuzz_stageConsume_payloadRoundTrip(
        uint256 _words,
        uint256 _seed,
        uint256 _delay
    )
        public
    {
        uint256 words = bound(
            _words,
            1,
            CohortWeeks.MAX_CARRY_WORDS
        );

        uint256 delay = bound(
            _delay,
            0,
            30 days
        );

        uint256[] memory payload = _payload(
            words,
            _seed
        );

        vm.warp(
            BASE_TIME + delay
        );

        _stageAs(
            vaultA,
            vaultB,
            user1,
            payload
        );

        vm.prank(
            vaultB
        );

        (
            uint256 stagedAt,
            uint256[] memory drained
        ) = registry.consumeCarry(
            vaultA,
            user1
        );

        assertEq(stagedAt, BASE_TIME + delay);

        assertEq(drained.length, words);

        for (uint256 i; i < words; ++i) {
            assertEq(drained[i], payload[i]);
        }
    }

    function test_getCarry_readOnlyDoesNotMutate()
        public
    {
        _stageAs(
            vaultA,
            vaultB,
            user1,
            _payload(
                2,
                41
            )
        );

        registry.getCarry(
            vaultA,
            vaultB,
            user1
        );

        (
            uint256 stagedAt,
            uint256[] memory stored
        ) = registry.getCarry(
            vaultA,
            vaultB,
            user1
        );

        assertEq(stagedAt, BASE_TIME);

        assertEq(stored.length, 2);
    }
}
