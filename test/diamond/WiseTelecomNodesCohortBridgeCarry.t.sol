// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";

import {WiseTelecomNodesDiamond} from "../../src/diamond/vault/WiseTelecomNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortBridgeHookFacet} from "../../src/diamond/vault/facets/pending/CohortBridgeHookFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {ReferralRegistry} from "../../src/registry/pending/ReferralRegistry.sol";

import {WiseTelecomNodesDiamondErrors} from "../../src/diamond/vault/WiseTelecomNodesDiamondErrors.sol";

import {WiseTelecomNodesDiamondSelectors} from "../../script/diamond/WiseTelecomNodesDiamondSelectors.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

contract CarryMockUSD is ERC20 {

    constructor()
        ERC20("Mock USD", "MUSD")
    {}

    function decimals()
        public
        pure
        override
        returns (uint8)
    {
        return 6;
    }

    function mint(
        address _to,
        uint256 _amount
    )
        external
    {
        _mint(
            _to,
            _amount
        );
    }
}

/**
 * @dev Simulates the CCIP router + DON for the bridge-carry suite:
 * `getFee` returns a flat fee and `ccipSend` records the outbound
 * message (data, sender, receiver, id) and then synchronously relays
 * it to the destination diamond's `ccipReceive` (as the DON would
 * after finality). Relay can be switched off so a recorded message
 * can be delivered later via `deliverLast`: after a warp, simulating
 * in-flight time, or a second time, simulating a replay. Each
 * registered diamond maps to the chain selector it lives on so the
 * relayed `Any2EVMMessage` carries the correct source selector.
 */
contract CarryMockRouter {

    uint256 public constant FIXED_FEE = 0.01 ether;

    uint256 internal nonce;

    bool public relayEnabled = true;

    bytes public lastData;

    address public lastSender;

    address public lastReceiver;

    bytes32 public lastMessageId;

    mapping(address => uint64) public selectorOf;

    function setSelector(
        address _diamond,
        uint64 _selector
    )
        external
    {
        selectorOf[_diamond] = _selector;
    }

    function setRelayEnabled(
        bool _enabled
    )
        external
    {
        relayEnabled = _enabled;
    }

    function getFee(
        uint64,
        Client.EVM2AnyMessage memory
    )
        external
        pure
        returns (uint256)
    {
        return FIXED_FEE;
    }

    function ccipSend(
        uint64 _destChainSelector,
        Client.EVM2AnyMessage calldata _message
    )
        external
        payable
        returns (bytes32 messageId)
    {
        address dest = abi.decode(
            _message.receiver,
            (address)
        );

        lastData = _message.data;
        lastSender = msg.sender;
        lastReceiver = dest;

        messageId = keccak256(
            abi.encode(
                msg.sender,
                _destChainSelector,
                nonce
            )
        );

        nonce++;

        lastMessageId = messageId;

        if (relayEnabled == false) {
            return messageId;
        }

        _deliver(
            dest,
            messageId,
            msg.sender,
            _message.data
        );
    }

    function deliverLast()
        external
    {
        _deliver(
            lastReceiver,
            lastMessageId,
            lastSender,
            lastData
        );
    }

    function _deliver(
        address _dest,
        bytes32 _messageId,
        address _srcSender,
        bytes memory _data
    )
        internal
    {
        IAny2EVMMessageReceiver(_dest).ccipReceive(
            Client.Any2EVMMessage({
                messageId: _messageId,
                sourceChainSelector: selectorOf[_srcSender],
                sender: abi.encode(_srcSender),
                data: _data,
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );
    }
}

/**
 * @dev End-to-end suite for the cross-chain cohort bridge carry. Two
 * fully wired diamonds simulate two chains on one EVM, each consulting
 * its OWN {ReferralRegistry} (the per-chain production topology, with
 * distinct chain ranks), joined by a {CarryMockRouter} that relays
 * synchronously so a bridge can be asserted end to end inside one
 * test transaction. Both diamonds route the
 * `cohortBridgeHookSelectors()` group and run {CohortHookFacet} as the
 * transfer hook, so the armed path exercises the real capture
 * (`_captureBridgeOutCohort`: clamp to held, reduce the source
 * referrer's book by exactly `carryDelta = min(deficit, burned)`,
 * aggregate lanes onto the wire) and the real apply
 * (`_applyBridgeInCohort`: wholesale payload validation with the
 * `trackedDelta <= mintedAmount` conservation ceiling, tracked always
 * applied, origin-key merge into the local registry, lanes landed
 * under the post-merge effective referrer at ring slot
 * `(arrivalWeek + 1) % 52`).
 *
 * Covered behaviors: per-lane conservation across a partial bridge; a
 * full round trip landing at the oldest ring position on each hop
 * without inflating any lane; tracked-only carry for unreferred users;
 * the earliest-key merge on arrival in both directions: a local
 * earlier key keeps the lanes under the local referrer, while a
 * carried earlier key flips the registry but defers the lanes to the
 * OLD referrer through the pending-flip marker (cover preservation)
 * until the permissionless poke migrates the book 1:1; the degrade
 * matrix (unarmed destination mints with zero recorder state, and
 * malformed or forged payloads (wrong length, wrong version, forged
 * tracked delta above the mint, referrer-zero with lanes) are
 * discarded while the mint stands); the armed source overriding
 * caller-supplied referral bytes with its own vault-built payload;
 * the unarmed source's carry-shape guard rejecting valid carry bytes
 * from callers while passing arbitrary bytes through; empty-payload
 * suppression for zero-deficit bridges; message replay; week-boundary
 * arrival landing at the ARRIVAL week; ring-lane saturation clipping
 * softly while the book keeps the full pre-clip aggregates; and the
 * applied carry suppressing the legacy `BridgeReferral` fallback even
 * with `referralEnabled` on.
 */
contract WiseTelecomNodesCohortBridgeCarryTest is DiamondTestHarness {

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant DEPOSIT = 5_000 * 1e6;

    uint256 internal constant DEPOSIT_B = 1_000 * 1e6;

    uint256 internal constant BRIDGE_AMOUNT = 2_000 * 1e6;

    uint256 internal constant FEE = 0.01 ether;

    uint64 internal constant SELECTOR_A = 1111;

    uint64 internal constant SELECTOR_B = 2222;

    bytes32 internal constant APPLIED_TOPIC = keccak256(
        "CohortBridgeCarryApplied(address,uint64,address,address,uint256,uint256,uint256,uint256)"
    );

    bytes32 internal constant DISCARDED_TOPIC = keccak256(
        "CohortBridgeCarryDiscarded(address,uint64)"
    );

    bytes32 internal constant BRIDGE_REFERRAL_TOPIC = keccak256(
        "BridgeReferral(address,uint64,bytes32,bytes)"
    );

    address internal user1 = address(0xA1);
    address internal buyer = address(0xC2);
    address internal refA = address(0xB1);
    address internal refB = address(0xB2);

    WiseTelecomNodesDiamond internal vaultA;
    WiseTelecomNodesDiamond internal vaultB;

    CarryMockUSD internal usdA;
    CarryMockUSD internal usdB;

    ReferralRegistry internal registryA;
    ReferralRegistry internal registryB;

    CarryMockRouter internal router;

    event CohortBridgeCarrySent(
        address indexed user,
        uint64 indexed dstChainSelector,
        address indexed referrer,
        uint256 trackedDelta,
        uint256 year1,
        uint256 year2,
        uint256 mature
    );

    event CohortBridgeCarryApplied(
        address indexed user,
        uint64 indexed srcChainSelector,
        address indexed effectiveReferrer,
        address carriedReferrer,
        uint256 trackedDelta,
        uint256 year1,
        uint256 year2,
        uint256 mature
    );

    event CohortBridgeCarryDiscarded(
        address indexed user,
        uint64 indexed srcChainSelector
    );

    event CohortLaneSaturated(
        address indexed referrer,
        uint256 laneKind,
        uint256 index,
        uint256 clippedAmount
    );

    event CohortReferrerFlipApplied(
        address indexed user,
        address indexed oldReferrer,
        address indexed newReferrer,
        uint256 year1,
        uint256 year2,
        uint256 mature,
        uint256 pairCount
    );

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        usdA = new CarryMockUSD();

        usdB = new CarryMockUSD();

        registryA = new ReferralRegistry(
            address(this),
            0
        );

        registryB = new ReferralRegistry(
            address(this),
            1
        );

        router = new CarryMockRouter();

        vaultA = _deployCarryVault(
            address(usdA),
            registryA
        );

        vaultB = _deployCarryVault(
            address(usdB),
            registryB
        );

        router.setSelector(
            address(vaultA),
            SELECTOR_A
        );

        router.setSelector(
            address(vaultB),
            SELECTOR_B
        );

        _wireBridge(
            vaultA,
            SELECTOR_B,
            address(vaultB)
        );

        _wireBridge(
            vaultB,
            SELECTOR_A,
            address(vaultA)
        );

        vaultA.finalizeSetup();
        vaultB.finalizeSetup();

        vm.deal(
            user1,
            100 ether
        );

        vm.deal(
            buyer,
            100 ether
        );
    }

    // ---- fixture helpers ----

    function _deployCarryVault(
        address _usd,
        ReferralRegistry _registry
    )
        internal
        returns (WiseTelecomNodesDiamond d)
    {
        d = _newDiamond(
            _usd
        );

        _wireAllFacets(
            d
        );

        _wireOne(
            d,
            address(new BridgeFacet()),
            WiseTelecomNodesDiamondSelectors.bridgeSelectors()
        );

        _wireOne(
            d,
            address(new ReferralFacet()),
            WiseTelecomNodesDiamondSelectors.referralSelectors()
        );

        _wireOne(
            d,
            address(new CohortRecorderFacet()),
            WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors()
        );

        _wireOne(
            d,
            address(new CohortBridgeHookFacet()),
            WiseTelecomNodesDiamondSelectors.cohortBridgeHookSelectors()
        );

        AdminFacet(address(d)).proposeTransferHookFacet(
            address(new CohortHookFacet())
        );

        AdminFacet(address(d)).executeTransferHookFacetChange();

        _wireReferralRegistryShared(
            d,
            _registry
        );
    }

    function _wireBridge(
        WiseTelecomNodesDiamond _vault,
        uint64 _peerSelector,
        address _peer
    )
        internal
    {
        BridgeFacet(address(_vault)).setCcipRouter(
            address(router)
        );

        BridgeFacet(address(_vault)).proposeCrossChainPeer(
            _peerSelector,
            _peer,
            6
        );

        BridgeFacet(address(_vault)).executeCrossChainPeerChange(
            _peerSelector
        );
    }

    function _armBoth()
        internal
    {
        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );

        AdminFacet(address(vaultB)).setCohortSyncEnabled(
            true
        );
    }

    function _armSource()
        internal
    {
        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );
    }

    function _armDest()
        internal
    {
        AdminFacet(address(vaultB)).setCohortSyncEnabled(
            true
        );
    }

    function _recorderOf(
        WiseTelecomNodesDiamond d
    )
        internal
        pure
        returns (CohortRecorderFacet)
    {
        return CohortRecorderFacet(
            address(d)
        );
    }

    function _usdOf(
        WiseTelecomNodesDiamond d
    )
        internal
        view
        returns (CarryMockUSD)
    {
        return d == vaultA
            ? usdA
            : usdB;
    }

    function _fundAndApproveOn(
        WiseTelecomNodesDiamond d,
        address _user,
        uint256 _amount
    )
        internal
    {
        _usdOf(d).mint(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        _usdOf(d).approve(
            address(d),
            _amount
        );
    }

    function _depositOn(
        WiseTelecomNodesDiamond d,
        address _user,
        uint256 _amount
    )
        internal
    {
        _fundAndApproveOn(
            d,
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        UserFacet(address(d)).deposit(
            _amount
        );
    }

    function _depositWithReferralOn(
        WiseTelecomNodesDiamond d,
        address _user,
        uint256 _amount,
        address _referrer
    )
        internal
    {
        _fundAndApproveOn(
            d,
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        ReferralFacet(address(d)).depositWithReferral(
            _amount,
            _referrer
        );
    }

    function _bridgeAs(
        address _user,
        WiseTelecomNodesDiamond _src,
        uint64 _destChainSelector,
        uint256 _amount
    )
        internal
    {
        vm.prank(
            _user
        );

        BridgeFacet(address(_src)).bridgeToVault{value: FEE}(
            _destChainSelector,
            _amount
        );
    }

    function _deliverCarry(
        uint256 _messageId,
        address _user,
        uint256 _amount,
        bytes memory _referralData
    )
        internal
    {
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(_messageId),
            sourceChainSelector: SELECTOR_A,
            sender: abi.encode(address(vaultA)),
            data: abi.encode(
                _user,
                _amount,
                _referralData
            ),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(
            address(router)
        );

        BridgeFacet(address(vaultB)).ccipReceive(
            message
        );
    }

    function _packCarry(
        address _referrer,
        uint256 _version,
        uint256 _trackedDelta,
        uint256 _assignedAt,
        uint256 _rank,
        uint256 _year1,
        uint256 _year2,
        uint256 _mature
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            uint256(uint160(_referrer)) | (_version << 160),
            _trackedDelta | (_assignedAt << 128) | (_rank << 192),
            _year1 | (_year2 << 128),
            _mature
        );
    }

    function _wireReferralBytes()
        internal
        view
        returns (bytes memory referralData)
    {
        (
            ,
            ,
            referralData
        ) = abi.decode(
            router.lastData(),
            (address, uint256, bytes)
        );
    }

    function _landSlot()
        internal
        view
        returns (uint256)
    {
        return (block.timestamp / 1 weeks + 1) % 52;
    }

    function _creditSlot()
        internal
        view
        returns (uint256)
    {
        return (block.timestamp / 1 weeks) % 52;
    }

    function _countTopic(
        Vm.Log[] memory _logs,
        bytes32 _topic
    )
        internal
        pure
        returns (uint256 count)
    {
        for (uint256 i; i < _logs.length; ++i) {
            if (_logs[i].topics.length > 0 && _logs[i].topics[0] == _topic) {
                ++count;
            }
        }
    }

    function _referralLogData(
        Vm.Log[] memory _logs
    )
        internal
        pure
        returns (bytes memory)
    {
        for (uint256 i; i < _logs.length; ++i) {
            if (_logs[i].topics.length > 0 && _logs[i].topics[0] == BRIDGE_REFERRAL_TOPIC) {
                return abi.decode(
                    _logs[i].data,
                    (bytes)
                );
            }
        }

        return "";
    }

    // ---- 1. referred partial bridge conserves the book per lane ----

    function test_bridgeToVault_referredPartial_carriesBookAcrossChains()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 landSlot = _landSlot();

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortBridgeCarrySent(
            user1,
            SELECTOR_B,
            refA,
            BRIDGE_AMOUNT,
            BRIDGE_AMOUNT,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refA,
            refA,
            BRIDGE_AMOUNT,
            BRIDGE_AMOUNT,
            0,
            0
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(vaultA).getTrackedContribution(user1),
            DEPOSIT - BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(vaultA).getCohortScore(refA),
            DEPOSIT - BRIDGE_AMOUNT
        );

        assertEq(
            vaultB.balanceOf(user1),
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(vaultB).getTrackedContribution(user1),
            BRIDGE_AMOUNT
        );

        (
            uint256 year1B,
            uint256 year2B,
            uint256 matureB,
        ) = _recorderOf(vaultB).getCohortBook(
            refA
        );

        assertEq(
            year1B,
            BRIDGE_AMOUNT
        );

        assertEq(
            year2B,
            0
        );

        assertEq(
            matureB,
            0
        );

        (
            uint64[52] memory ring1B,
            uint64[52] memory ring2B
        ) = _recorderOf(vaultB).getCohortRings(
            refA
        );

        assertEq(
            uint256(ring1B[landSlot]),
            BRIDGE_AMOUNT
        );

        assertEq(
            uint256(ring2B[landSlot]),
            0
        );

        assertEq(
            registryB.referrerOf(user1),
            refA
        );

        assertEq(
            _recorderOf(vaultA).getCohortScore(refA)
                + _recorderOf(vaultB).getCohortScore(refA),
            DEPOSIT
        );
    }

    // ---- 2. round trip lands oldest slot both hops, no inflation ----

    function test_bridgeToVault_roundTrip_landsOldestSlotNoInflation()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 creditSlot = _creditSlot();

        uint256 landSlot = _landSlot();

        uint256 controlScore = _recorderOf(vaultA).getCohortScore(
            refA
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            DEPOSIT
        );

        assertEq(
            _recorderOf(vaultA).getTrackedContribution(user1),
            0
        );

        assertEq(
            _recorderOf(vaultA).getCohortScore(refA),
            0
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refA),
            controlScore
        );

        (
            uint64[52] memory ring1B,
        ) = _recorderOf(vaultB).getCohortRings(
            refA
        );

        assertEq(
            uint256(ring1B[landSlot]),
            DEPOSIT
        );

        _bridgeAs(
            user1,
            vaultB,
            SELECTOR_A,
            DEPOSIT
        );

        assertEq(
            vaultA.balanceOf(user1),
            DEPOSIT
        );

        assertEq(
            _recorderOf(vaultA).getTrackedContribution(user1),
            DEPOSIT
        );

        assertEq(
            _recorderOf(vaultB).getTrackedContribution(user1),
            0
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refA),
            0
        );

        assertEq(
            _recorderOf(vaultA).getCohortScore(refA),
            controlScore
        );

        (
            uint64[52] memory ring1A,
        ) = _recorderOf(vaultA).getCohortRings(
            refA
        );

        assertEq(
            uint256(ring1A[landSlot]),
            DEPOSIT
        );

        assertEq(
            uint256(ring1A[creditSlot]),
            0
        );

        uint256 ringSum;

        for (uint256 i; i < 52; ++i) {
            ringSum += uint256(ring1A[i]);
        }

        assertEq(
            ringSum,
            DEPOSIT
        );
    }

    // ---- 3. unreferred bridge carries tracked only ----

    function test_bridgeToVault_unreferred_carriesTrackedOnly()
        public
    {
        _armBoth();

        _depositOn(
            vaultA,
            user1,
            DEPOSIT
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            address(0),
            address(0),
            BRIDGE_AMOUNT,
            0,
            0,
            0
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(vaultA).getTrackedContribution(user1),
            DEPOSIT - BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(vaultB).getTrackedContribution(user1),
            BRIDGE_AMOUNT
        );

        assertEq(
            registryB.referrerOf(user1),
            address(0)
        );

        bytes memory wireRef = _wireReferralBytes();

        assertEq(
            wireRef.length,
            128
        );

        (
            uint256 word0,
            uint256 word1,
            uint256 word2,
            uint256 word3
        ) = abi.decode(
            wireRef,
            (uint256, uint256, uint256, uint256)
        );

        assertEq(
            word0,
            uint256(1) << 160
        );

        assertEq(
            word1,
            BRIDGE_AMOUNT
        );

        assertEq(
            word2,
            0
        );

        assertEq(
            word3,
            0
        );

        (
            uint64[52] memory ring1B,
        ) = _recorderOf(vaultB).getCohortRings(
            address(0)
        );

        assertEq(
            uint256(ring1B[_landSlot()]),
            0
        );
    }

    // ---- 4. merge on arrival: local earlier key wins ----

    function test_ccipReceive_localEarlierKey_landsUnderLocalReferrer()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultB,
            user1,
            DEPOSIT_B,
            refB
        );

        uint256 localAssignedAt = block.timestamp;

        vm.warp(
            block.timestamp + 1 days
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 landSlot = _landSlot();

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refB,
            refA,
            BRIDGE_AMOUNT,
            BRIDGE_AMOUNT,
            0,
            0
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        assertEq(
            registryB.referrerOf(user1),
            refB
        );

        (
            address pairReferrer,
            uint256 pairAssignedAt,
            uint256 pairRank
        ) = registryB.getReferrerPair(
            user1
        );

        assertEq(
            pairReferrer,
            refB
        );

        assertEq(
            pairAssignedAt,
            localAssignedAt
        );

        assertEq(
            pairRank,
            1
        );

        assertEq(
            registryB.pendingFlip(
                address(vaultB),
                user1
            ),
            address(0)
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refB),
            DEPOSIT_B + BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refA),
            0
        );

        (
            uint64[52] memory ring1B,
        ) = _recorderOf(vaultB).getCohortRings(
            refB
        );

        assertEq(
            uint256(ring1B[landSlot]),
            BRIDGE_AMOUNT
        );
    }

    // ---- 5. merge on arrival: carried earlier key flips, lanes defer to
    // the old referrer until the poke migrates the book ----

    function test_ccipReceive_carriedEarlierKey_defersLanesToOldReferrerThenPokeMigrates()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 1 days
        );

        _depositWithReferralOn(
            vaultB,
            user1,
            DEPOSIT_B,
            refB
        );

        uint256 creditSlot = _creditSlot();

        uint256 landSlot = _landSlot();

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refB,
            refA,
            BRIDGE_AMOUNT,
            BRIDGE_AMOUNT,
            0,
            0
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        assertEq(
            registryB.referrerOf(user1),
            refA
        );

        assertEq(
            registryB.pendingFlip(
                address(vaultB),
                user1
            ),
            refB
        );

        assertEq(
            registryB.effectiveReferrerOf(
                user1,
                address(vaultB)
            ),
            refB
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refB),
            DEPOSIT_B + BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refA),
            0
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refB,
            refA,
            DEPOSIT_B + BRIDGE_AMOUNT,
            0,
            0,
            2
        );

        registryB.pokeMigration(
            user1
        );

        assertEq(
            registryB.pendingFlip(
                address(vaultB),
                user1
            ),
            address(0)
        );

        assertEq(
            registryB.effectiveReferrerOf(
                user1,
                address(vaultB)
            ),
            refA
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refB),
            0
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refA),
            DEPOSIT_B + BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(vaultB).getTrackedContribution(user1),
            DEPOSIT_B + BRIDGE_AMOUNT
        );

        (
            uint64[52] memory ring1B,
        ) = _recorderOf(vaultB).getCohortRings(
            refA
        );

        assertEq(
            uint256(ring1B[creditSlot]),
            DEPOSIT_B
        );

        assertEq(
            uint256(ring1B[landSlot]),
            BRIDGE_AMOUNT
        );
    }

    // ---- 6. unarmed destination mints with zero recorder state ----

    function test_bridgeToVault_destUnarmed_mintsWithoutRecorderState()
        public
    {
        _armSource();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.recordLogs();

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countTopic(
                logs,
                APPLIED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                BRIDGE_REFERRAL_TOPIC
            ),
            0
        );

        assertEq(
            vaultB.balanceOf(user1),
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(vaultB).getTrackedContribution(user1),
            0
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refA),
            0
        );

        BridgeFacet(address(vaultB)).setReferralEnabled(
            true
        );

        vm.recordLogs();

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            1_000 * 1e6
        );

        logs = vm.getRecordedLogs();

        assertEq(
            _countTopic(
                logs,
                BRIDGE_REFERRAL_TOPIC
            ),
            1
        );

        bytes memory fallbackData = _referralLogData(
            logs
        );

        assertEq(
            fallbackData.length,
            128
        );

        assertEq(
            keccak256(fallbackData),
            keccak256(_wireReferralBytes())
        );

        assertEq(
            _recorderOf(vaultB).getTrackedContribution(user1),
            0
        );
    }

    // ---- 7. garbage referral bytes are discarded, mint stands ----

    function test_ccipReceive_garbageReferralData_discardedMintFine()
        public
    {
        _armDest();

        bytes memory garbage = hex"deadbeef";

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryDiscarded(
            user1,
            SELECTOR_A
        );

        _deliverCarry(
            0x700,
            user1,
            1_000 * 1e6,
            garbage
        );

        assertEq(
            vaultB.balanceOf(user1),
            1_000 * 1e6
        );

        assertEq(
            _recorderOf(vaultB).getTrackedContribution(user1),
            0
        );
    }

    // ---- 8. version mismatch is discarded ----

    function test_ccipReceive_versionMismatch_discarded()
        public
    {
        _armDest();

        bytes memory payload = _packCarry(
            refA,
            2,
            1_000 * 1e6,
            block.timestamp,
            0,
            1_000 * 1e6,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryDiscarded(
            user1,
            SELECTOR_A
        );

        _deliverCarry(
            0x701,
            user1,
            1_000 * 1e6,
            payload
        );

        assertEq(
            vaultB.balanceOf(user1),
            1_000 * 1e6
        );

        assertEq(
            _recorderOf(vaultB).getTrackedContribution(user1),
            0
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refA),
            0
        );
    }

    // ---- 9. forged tracked delta above the mint is discarded ----

    function test_ccipReceive_trackedDeltaAboveMint_discarded()
        public
    {
        _armDest();

        uint256 amount = 1_000 * 1e6;

        bytes memory payload = _packCarry(
            refA,
            1,
            amount + 1,
            block.timestamp,
            0,
            amount + 1,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryDiscarded(
            user1,
            SELECTOR_A
        );

        _deliverCarry(
            0x702,
            user1,
            amount,
            payload
        );

        assertEq(
            vaultB.balanceOf(user1),
            amount
        );

        assertEq(
            _recorderOf(vaultB).getTrackedContribution(user1),
            0
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refA),
            0
        );
    }

    // ---- 10. zero referrer with lanes is discarded ----

    function test_ccipReceive_zeroReferrerWithLanes_discarded()
        public
    {
        _armDest();

        bytes memory payload = _packCarry(
            address(0),
            1,
            500 * 1e6,
            0,
            0,
            500 * 1e6,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryDiscarded(
            user1,
            SELECTOR_A
        );

        _deliverCarry(
            0x703,
            user1,
            500 * 1e6,
            payload
        );

        assertEq(
            vaultB.balanceOf(user1),
            500 * 1e6
        );

        assertEq(
            _recorderOf(vaultB).getTrackedContribution(user1),
            0
        );
    }

    // ---- 11. armed source ignores caller referral bytes ----

    function test_bridgeToVaultWithReferral_armedSource_ignoresUserBytes()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 assignedAt = block.timestamp;

        bytes memory userBytes = abi.encode(
            uint256(42),
            address(0xCAFE)
        );

        vm.prank(
            user1
        );

        BridgeFacet(address(vaultA)).bridgeToVaultWithReferral{value: FEE}(
            SELECTOR_B,
            BRIDGE_AMOUNT,
            userBytes
        );

        (
            address wireUser,
            uint256 wireAmount,
            bytes memory wireRef
        ) = abi.decode(
            router.lastData(),
            (address, uint256, bytes)
        );

        assertEq(
            wireUser,
            user1
        );

        assertEq(
            wireAmount,
            BRIDGE_AMOUNT
        );

        assertEq(
            wireRef.length,
            128
        );

        assertTrue(
            keccak256(wireRef) != keccak256(userBytes)
        );

        (
            uint256 word0,
            uint256 word1,
            uint256 word2,
            uint256 word3
        ) = abi.decode(
            wireRef,
            (uint256, uint256, uint256, uint256)
        );

        assertEq(
            address(uint160(word0)),
            refA
        );

        assertEq(
            (word0 >> 160) & 0xff,
            1
        );

        assertEq(
            word1 & ((uint256(1) << 128) - 1),
            BRIDGE_AMOUNT
        );

        assertEq(
            (word1 >> 128) & type(uint64).max,
            assignedAt
        );

        assertEq(
            (word1 >> 192) & 0xff,
            0
        );

        assertEq(
            word2 & ((uint256(1) << 128) - 1),
            BRIDGE_AMOUNT
        );

        assertEq(
            word2 >> 128,
            0
        );

        assertEq(
            word3,
            0
        );

        assertEq(
            _recorderOf(vaultB).getTrackedContribution(user1),
            BRIDGE_AMOUNT
        );
    }

    // ---- 12. unarmed source rejects valid carry bytes from callers ----

    function test_bridgeToVaultWithReferral_unarmedSource_validCarryBytes_reverts()
        public
    {
        _depositOn(
            vaultA,
            user1,
            DEPOSIT
        );

        bytes memory forged = _packCarry(
            address(0xBEEF),
            1,
            100,
            block.timestamp,
            0,
            100,
            0,
            0
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.ReferralDataReserved.selector
        );

        BridgeFacet(address(vaultA)).bridgeToVaultWithReferral{value: FEE}(
            SELECTOR_B,
            BRIDGE_AMOUNT,
            forged
        );
    }

    // ---- 13. unarmed source passes arbitrary bytes through ----

    function test_bridgeToVaultWithReferral_unarmedSource_arbitraryBytesPassThrough()
        public
    {
        BridgeFacet(address(vaultB)).setReferralEnabled(
            true
        );

        _depositOn(
            vaultA,
            user1,
            DEPOSIT
        );

        bytes memory userBytes = abi.encode(
            uint256(7),
            address(0xBEEF)
        );

        vm.recordLogs();

        vm.prank(
            user1
        );

        BridgeFacet(address(vaultA)).bridgeToVaultWithReferral{value: FEE}(
            SELECTOR_B,
            BRIDGE_AMOUNT,
            userBytes
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            keccak256(_wireReferralBytes()),
            keccak256(userBytes)
        );

        assertEq(
            vaultB.balanceOf(user1),
            BRIDGE_AMOUNT
        );

        assertEq(
            _countTopic(
                logs,
                BRIDGE_REFERRAL_TOPIC
            ),
            1
        );

        assertEq(
            keccak256(_referralLogData(logs)),
            keccak256(userBytes)
        );
    }

    // ---- 14. zero deficit suppresses the wire payload ----

    function test_bridgeToVault_zeroDeficit_emptyWirePayload()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.prank(
            user1
        );

        vaultA.transfer(
            buyer,
            BRIDGE_AMOUNT
        );

        uint256 scoreBefore = _recorderOf(vaultA).getCohortScore(
            refA
        );

        vm.recordLogs();

        _bridgeAs(
            buyer,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _wireReferralBytes().length,
            0
        );

        assertEq(
            vaultB.balanceOf(buyer),
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(vaultB).getTrackedContribution(buyer),
            0
        );

        assertEq(
            _recorderOf(vaultA).getCohortScore(refA),
            scoreBefore
        );

        assertEq(
            _countTopic(
                logs,
                APPLIED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                DISCARDED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                BRIDGE_REFERRAL_TOPIC
            ),
            0
        );
    }

    // ---- 15. a replayed carry message cannot apply twice ----

    function test_ccipReceive_replayedCarryMessage_reverts()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        uint256 trackedAfter = _recorderOf(vaultB).getTrackedContribution(
            user1
        );

        uint256 scoreAfter = _recorderOf(vaultB).getCohortScore(
            refA
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.MessageAlreadyProcessed.selector
        );

        router.deliverLast();

        assertEq(
            _recorderOf(vaultB).getTrackedContribution(user1),
            trackedAfter
        );

        assertEq(
            _recorderOf(vaultB).getCohortScore(refA),
            scoreAfter
        );
    }

    // ---- 16. a message in flight over a week boundary lands at the
    // arrival week ----

    function test_bridgeToVault_weekBoundaryInFlight_landsAtArrivalWeek()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 sendSlot = _landSlot();

        router.setRelayEnabled(
            false
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        assertEq(
            vaultB.balanceOf(user1),
            0
        );

        vm.warp(
            block.timestamp + 1 weeks
        );

        uint256 arrivalSlot = _landSlot();

        router.deliverLast();

        assertEq(
            arrivalSlot,
            (sendSlot + 1) % 52
        );

        assertEq(
            vaultB.balanceOf(user1),
            BRIDGE_AMOUNT
        );

        (
            uint64[52] memory ring1B,
        ) = _recorderOf(vaultB).getCohortRings(
            refA
        );

        assertEq(
            uint256(ring1B[arrivalSlot]),
            BRIDGE_AMOUNT
        );

        assertEq(
            uint256(ring1B[sendSlot]),
            0
        );
    }

    // ---- 17. ring lane saturation clips softly, book keeps the full
    // aggregates ----

    function test_ccipReceive_laneSaturation_clipsRingKeepsBook()
        public
    {
        _armDest();

        address fUser = address(0xF1);
        address fRef = address(0xB3);

        uint256 big = uint256(type(uint64).max) - 5;
        uint256 topUp = 100;

        uint256 slot = _landSlot();

        bytes memory first = _packCarry(
            fRef,
            1,
            big,
            block.timestamp,
            2,
            big,
            0,
            0
        );

        bytes memory second = _packCarry(
            fRef,
            1,
            topUp,
            block.timestamp,
            2,
            topUp,
            0,
            0
        );

        _deliverCarry(
            0x710,
            fUser,
            big,
            first
        );

        (
            uint64[52] memory ring1Before,
        ) = _recorderOf(vaultB).getCohortRings(
            fRef
        );

        assertEq(
            uint256(ring1Before[slot]),
            big
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(vaultB)
        );

        emit CohortLaneSaturated(
            fRef,
            0,
            slot,
            95
        );

        _deliverCarry(
            0x711,
            fUser,
            topUp,
            second
        );

        (
            uint64[52] memory ring1After,
        ) = _recorderOf(vaultB).getCohortRings(
            fRef
        );

        assertEq(
            uint256(ring1After[slot]),
            uint256(type(uint64).max)
        );

        (
            uint256 year1B,
            ,
            ,
        ) = _recorderOf(vaultB).getCohortBook(
            fRef
        );

        assertEq(
            year1B,
            big + topUp
        );

        assertEq(
            _recorderOf(vaultB).getTrackedContribution(fUser),
            big + topUp
        );
    }

    // ---- 18. an applied carry suppresses the legacy fallback event ----

    function test_ccipReceive_carryApplied_suppressesBridgeReferralFallback()
        public
    {
        _armBoth();

        BridgeFacet(address(vaultB)).setReferralEnabled(
            true
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.recordLogs();

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countTopic(
                logs,
                APPLIED_TOPIC
            ),
            1
        );

        assertEq(
            _countTopic(
                logs,
                BRIDGE_REFERRAL_TOPIC
            ),
            0
        );

        assertEq(
            _recorderOf(vaultB).getTrackedContribution(user1),
            BRIDGE_AMOUNT
        );
    }

    // ---- 19. bridge-out during a pending source flip reduces the
    // cover-holding referrer, never the flip winner's other referees ----

    function test_bridgeOut_duringPendingFlip_reducesCoverReferrerNotWinner()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        _depositWithReferralOn(
            vaultA,
            buyer,
            DEPOSIT,
            refB
        );

        uint256 winnerScoreBefore = _recorderOf(vaultA).getCohortScore(
            refB
        );

        uint256 coverScoreBefore = _recorderOf(vaultA).getCohortScore(
            refA
        );

        vm.prank(
            address(vaultA)
        );

        registryA.mergeReferrer(
            user1,
            refB,
            block.timestamp - 1_000,
            1
        );

        assertEq(
            registryA.referrerOf(user1),
            refB
        );

        assertEq(
            registryA.effectiveReferrerOf(
                user1,
                address(vaultA)
            ),
            refA
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(vaultA).getCohortScore(refB),
            winnerScoreBefore
        );

        assertEq(
            _recorderOf(vaultA).getCohortScore(refA),
            coverScoreBefore - BRIDGE_AMOUNT
        );
    }
}
