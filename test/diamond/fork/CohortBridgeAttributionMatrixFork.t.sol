// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Test.sol";

import {Internal} from "@chainlink/contracts-ccip/contracts/libraries/Internal.sol";

import {
    ICcipBridgeVault,
    ICcipRouterView,
    ICcipTypeAndVersion
} from "./utils/CcipForkInterfaces.sol";
import {CcipV2Shapes, ICcipOnRampV2Events} from "./utils/CcipV2Shapes.sol";
import {
    CcipCarryUpgradeRehearsalForkBase,
    IWtnCarryVault
} from "./CcipCarryUpgradeRehearsalFork.t.sol";

import {ReferralRegistry} from "../../../src/registry/pending/ReferralRegistry.sol";

import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";
import {BridgeCarryTestCodec} from "../utils/BridgeCarryTestCodec.sol";

/**
 * @dev The few extra entrypoints of the LIVE diamond the attribution
 * matrix drives beyond the carry rehearsal surface: the plain share
 * transfer that creates untracked headroom or a lazy deficit, the
 * packed book reader, and the master switch that surfaces the
 * legacy bridge-referral fallback so its silence can be asserted.
 */
interface IWtnMatrixVault {

    function transfer(
        address to,
        uint256 amount
    )
        external
        returns (bool);

    function getCohortBook(
        address referrer
    )
        external
        view
        returns (
            uint256 year1,
            uint256 year2,
            uint256 mature,
            uint256 lastSettleTimestamp
        );

    function setReferralEnabled(
        bool enabled
    )
        external;
}

/**
 * @dev Cross-chain attribution matrix over LIVE diamonds forked on
 * both ends of a real CCIP lane. The suite extends the carry
 * rehearsal base, so every fork runs the complete recorder, registry
 * and bridge-carry install ladder under the real master and the real
 * timelocks before a scenario starts. On top of that base it adds
 * the machinery the matrix needs: per-side arming control, a
 * referred seed with tracked cover, an untracked headroom seed by
 * plain transfer, a lazy deficit by transfer-away without a later
 * touchpoint, registry seams for a different referrer on the
 * destination with an earlier or later sync key, book and ring
 * readers on either fork, the destination poke, and a round trip
 * over the reverse lane where its on-ramp is scrape-supported.
 *
 * Install control. The inherited setUp installs and arms both forks
 * and is not overridable, so a side that must not be armed is
 * disarmed through the master switch after the install. That is the
 * live intermediate rollout state: routing and registry pointer
 * executed, cohort sync not yet flipped on. A disarmed source sends
 * caller bytes through and a disarmed destination mints without
 * recorder state, which is what later matrix groups pin.
 *
 * Wire discipline. Every bridge is scraped off the source fork's real
 * on-ramp log under either live ramp generation, and the decoded
 * `referralData` is asserted field by field against the carry codec
 * before the log is re-emitted for the routing engine. Assertion
 * discipline per bridge: per-lane book conservation scaled by the
 * lane decimals with floor, tracked conservation, registry pair and
 * pending-flip marker on both forks, the full destination mint, the
 * decoded wire, and the carry events on their forks with every
 * degrade event asserted absent. The wire length is the version 3
 * envelope's own length, three header words plus one word per two
 * carried pairs, the only shape the destination accepts; the fee
 * quote reserves `BRIDGE_CARRY_BYTES`, the 104 pair maximum, which is
 * never the length of a real send.
 *
 * Clock discipline. Warps persist per fork across fork switches, so
 * key ordering is created only by moving one fork forward, never by
 * moving any fork back. An earlier destination key comes from a
 * destination assignment at its natural clock followed by a source
 * clock advanced past it; a later destination key comes from the
 * mirror image. The destination clock is aligned to the source clock
 * before every delivery, exactly as the carry base does. The wire
 * carries the capture week, the source clock's week at the send,
 * which the wire assertion pins against the send stamp the harness
 * records with the message (`SentMessage.sentAt`), never against a
 * source clock read later, and the destination lands every carried
 * pair at its own slot, aged by the weekly boundaries crossed between
 * that week and its own clock; the aligned clocks keep that count at
 * zero in these lanes, so every landing expectation is the credit slot
 * of the capture week.
 */
abstract contract CohortBridgeAttributionMatrixForkBase is CcipCarryUpgradeRehearsalForkBase {

    enum InstallSide {
        Both,
        SourceOnly,
        DestinationOnly
    }

    struct Book {
        uint256 year1;
        uint256 year2;
        uint256 mature;
    }

    struct RingPair {
        uint64[52] ring1;
        uint64[52] ring2;
    }

    struct SideState {
        uint256 balance;
        uint256 tracked;
        Book book;
        uint256 creditSlot;
        uint256 landSlot;
        uint256 ring1AtCredit;
        uint256 ring1AtLand;
        uint256 ring2AtLand;
        uint256 ring1Sum;
        uint256 ring2Sum;
    }

    struct WireCapture {
        bool carryFound;
        address carryUser;
        uint64 carryDstSelector;
        address carryReferrer;
        uint256 carryTrackedDelta;
        uint256 carryYear1;
        uint256 carryYear2;
        uint256 carryMature;
        address carryBookReferrer;
        address wireUser;
        uint256 wireAmount;
        bytes referralData;
        bytes rampData;
    }

    struct CarryPayload {
        address referrer;
        uint256 version;
        uint256 trackedDelta;
        uint256 assignedAt;
        uint256 rank;
        uint256 year1;
        uint256 year2;
        uint256 mature;
        uint256 captureWeek;
        uint256 pairCount;
    }

    struct CarryExpect {
        address referrer;
        uint256 assignedAt;
        uint256 rank;
        uint256 trackedDelta;
        uint256 year1;
        uint256 year2;
        uint256 mature;
    }

    struct AppliedCapture {
        bool found;
        address effectiveReferrer;
        address carriedReferrer;
        uint256 trackedDelta;
        uint256 year1;
        uint256 year2;
        uint256 mature;
    }

    struct AppliedExpect {
        address effectiveReferrer;
        address carriedReferrer;
        uint256 trackedDelta;
        uint256 year1;
        uint256 year2;
        uint256 mature;
    }

    struct RegistryExpect {
        address referrer;
        uint256 assignedAt;
        uint256 rank;
        address pending;
    }

    struct Run {
        uint256 amount;
        uint256 carried;
        uint256 srcAt;
        uint256 dstAt;
        SideState srcBefore;
        SideState srcAfter;
        SideState dstBefore;
        SideState dstAfter;
        SentMessage sent;
        WireCapture wire;
        Vm.Log[] logs;
    }

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

    event FlipMarked(
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

    event CohortReferrerFlipApplied(
        address indexed user,
        address indexed oldReferrer,
        address indexed newReferrer,
        uint256 year1,
        uint256 year2,
        uint256 mature,
        uint256 pairCount
    );

    event CohortBridgeCarryDiscarded(
        address indexed user,
        uint64 indexed srcChainSelector
    );

    event CohortBridgeCarryBookDropped(
        address indexed user,
        uint64 indexed srcChainSelector,
        address carriedReferrer,
        uint256 year1,
        uint256 year2,
        uint256 mature
    );

    event CohortBridgeCarrySkipped(
        address indexed user,
        uint64 indexed dstChainSelector
    );

    event BridgeReferral(
        address indexed user,
        uint64 indexed srcChainSelector,
        bytes32 indexed messageId,
        bytes referralData
    );

    event CohortContributionSynced(
        address indexed user,
        address indexed referrer,
        uint256 oldContribution,
        uint256 newContribution
    );

    uint256 internal constant BRIDGE_UNITS = 1_000;

    uint256 internal constant DESTINATION_UNITS = 500;

    address internal dstReferrer = makeAddr(
        "matrixDestinationReferrer"
    );

    address internal thirdReferrer = makeAddr(
        "matrixThirdReferrer"
    );

    address internal forger = makeAddr(
        "matrixForger"
    );

    address internal holder = makeAddr(
        "matrixHolder"
    );

    address internal sink = makeAddr(
        "matrixSink"
    );

    // ---- install control ----

    function _installSide()
        internal
        pure
        virtual
        returns (InstallSide)
    {
        return InstallSide.Both;
    }

    function _prepareLane()
        internal
    {
        _armSides(
            _installSide()
        );

        _onDst();

        vm.prank(
            dst.master
        );

        IWtnMatrixVault(dst.diamond).setReferralEnabled(
            true
        );
    }

    function _armSides(
        InstallSide _side
    )
        internal
    {
        _setArmed(
            src,
            _side != InstallSide.DestinationOnly
        );

        _setArmed(
            dst,
            _side != InstallSide.SourceOnly
        );
    }

    function _setArmed(
        ChainCtx storage _ctx,
        bool _armed
    )
        internal
    {
        vm.selectFork(
            _ctx.forkId
        );

        IWtnCarryVault v = IWtnCarryVault(
            _ctx.diamond
        );

        if (v.getCohortSyncEnabled() == _armed) {
            return;
        }

        vm.prank(
            _ctx.master
        );

        v.setCohortSyncEnabled(
            _armed
        );

        assertEq(
            v.getCohortSyncEnabled(),
            _armed,
            "cohort sync arming state mismatch"
        );
    }

    // ---- seeding ----

    function _seedReferred(
        ChainCtx storage _ctx,
        address _who,
        uint256 _amount,
        address _referrer
    )
        internal
        returns (uint256 seededAt)
    {
        _prepDepositRails(
            _ctx,
            _who,
            _amount
        );

        vm.prank(
            _who
        );

        IWtnCarryVault(_ctx.diamond).depositWithReferral(
            _amount,
            _referrer
        );

        seededAt = block.timestamp;
    }

    function _seedPlain(
        ChainCtx storage _ctx,
        address _who,
        uint256 _amount
    )
        internal
    {
        vm.selectFork(
            _ctx.forkId
        );

        _prepShares(
            _ctx,
            _who,
            _amount
        );
    }

    function _transferIn(
        ChainCtx storage _ctx,
        address _from,
        address _to,
        uint256 _amount
    )
        internal
    {
        _seedPlain(
            _ctx,
            _from,
            _amount
        );

        vm.prank(
            _from
        );

        IWtnMatrixVault(_ctx.diamond).transfer(
            _to,
            _amount
        );
    }

    function _transferAway(
        ChainCtx storage _ctx,
        address _from,
        address _to,
        uint256 _amount
    )
        internal
    {
        vm.selectFork(
            _ctx.forkId
        );

        vm.prank(
            _from
        );

        IWtnMatrixVault(_ctx.diamond).transfer(
            _to,
            _amount
        );
    }

    // ---- registry seams ----

    function _assignOnRegistry(
        ChainCtx storage _ctx,
        ReferralRegistry _registry,
        address _who,
        address _referrer,
        uint256 _at
    )
        internal
    {
        vm.selectFork(
            _ctx.forkId
        );

        vm.warp(
            _at
        );

        vm.prank(
            _ctx.diamond
        );

        _registry.assignReferrer(
            _who,
            _referrer
        );
    }

    function _foreignRank()
        internal
        pure
        returns (uint256)
    {
        for (uint256 rank; rank < 4; ++rank) {

            if (rank != _srcChainRank() && rank != _dstChainRank()) {
                return rank;
            }
        }

        return 0;
    }

    function _mergeOnRegistry(
        ChainCtx storage _ctx,
        ReferralRegistry _registry,
        address _who,
        address _referrer,
        uint256 _assignedAt,
        uint256 _rank
    )
        internal
    {
        vm.selectFork(
            _ctx.forkId
        );

        vm.prank(
            _ctx.diamond
        );

        _registry.mergeReferrer(
            _who,
            _referrer,
            _assignedAt,
            _rank
        );
    }

    function _pokeDestination(
        address _who
    )
        internal
    {
        _onDst();

        dstRegistry.pokeMigration(
            _who
        );
    }

    // ---- clocks ----

    function _clockOf(
        ChainCtx storage _ctx
    )
        internal
        returns (uint256)
    {
        vm.selectFork(
            _ctx.forkId
        );

        return block.timestamp;
    }

    function _advancePast(
        ChainCtx storage _ctx,
        uint256 _floor
    )
        internal
        returns (uint256)
    {
        vm.selectFork(
            _ctx.forkId
        );

        if (block.timestamp <= _floor + 1) {

            vm.warp(
                _floor + 2
            );
        }

        return block.timestamp;
    }

    function _sourceWeekOf(
        SentMessage memory _sent
    )
        internal
        pure
        returns (uint256)
    {
        return _sent.sentAt / CohortWeeks.WEEK;
    }

    // ---- readers ----

    function _bookOn(
        ChainCtx storage _ctx,
        address _referrer
    )
        internal
        returns (Book memory book)
    {
        vm.selectFork(
            _ctx.forkId
        );

        (
            book.year1,
            book.year2,
            book.mature,
        ) = IWtnMatrixVault(_ctx.diamond).getCohortBook(
            _referrer
        );
    }

    function _trackedOn(
        ChainCtx storage _ctx,
        address _who
    )
        internal
        returns (uint256)
    {
        vm.selectFork(
            _ctx.forkId
        );

        return IWtnCarryVault(_ctx.diamond).getTrackedContribution(
            _who
        );
    }

    function _balanceOn(
        ChainCtx storage _ctx,
        address _who
    )
        internal
        returns (uint256)
    {
        vm.selectFork(
            _ctx.forkId
        );

        return ICcipBridgeVault(_ctx.diamond).balanceOf(
            _who
        );
    }

    function _ringOn(
        ChainCtx storage _ctx,
        address _referrer,
        uint256 _slot
    )
        internal
        returns (
            uint256 year1,
            uint256 year2
        )
    {
        vm.selectFork(
            _ctx.forkId
        );

        (
            uint64[52] memory ring1,
            uint64[52] memory ring2
        ) = IWtnCarryVault(_ctx.diamond).getCohortRings(
            _referrer
        );

        year1 = uint256(ring1[_slot]);

        year2 = uint256(ring2[_slot]);
    }

    function _nonzeroRingSlots(
        ChainCtx storage _ctx,
        address _referrer
    )
        internal
        returns (uint256 count)
    {
        vm.selectFork(
            _ctx.forkId
        );

        (
            uint64[52] memory ring1,
            uint64[52] memory ring2
        ) = IWtnCarryVault(_ctx.diamond).getCohortRings(
            _referrer
        );

        for (uint256 i; i < CohortWeeks.RING_SLOTS; ++i) {

            if (ring1[i] > 0) {
                ++count;
            }

            if (ring2[i] > 0) {
                ++count;
            }
        }
    }

    function _ringPairOn(
        ChainCtx storage _ctx,
        address _referrer
    )
        internal
        returns (RingPair memory rings)
    {
        (
            rings.ring1,
            rings.ring2
        ) = _ringsOn(
            _ctx,
            _referrer
        );
    }

    function _assertReplanted(
        RingPair memory _old,
        RingPair memory _newBefore,
        RingPair memory _newAfter
    )
        internal
        pure
    {
        for (uint256 s; s < CohortWeeks.RING_SLOTS; ++s) {

            assertEq(
                uint256(_newAfter.ring1[s]),
                uint256(_newBefore.ring1[s]) + uint256(_old.ring1[s]),
                "poke must replant every first-year slot at the same slot"
            );

            assertEq(
                uint256(_newAfter.ring2[s]),
                uint256(_newBefore.ring2[s]) + uint256(_old.ring2[s]),
                "poke must replant every second-year slot at the same slot"
            );
        }
    }

    function _ringsOn(
        ChainCtx storage _ctx,
        address _referrer
    )
        internal
        returns (
            uint64[52] memory ring1,
            uint64[52] memory ring2
        )
    {
        vm.selectFork(
            _ctx.forkId
        );

        (
            ring1,
            ring2
        ) = IWtnCarryVault(_ctx.diamond).getCohortRings(
            _referrer
        );
    }

    function _sideState(
        ChainCtx storage _ctx,
        address _who,
        address _bookReferrer
    )
        internal
        returns (SideState memory state)
    {
        vm.selectFork(
            _ctx.forkId
        );

        state.balance = ICcipBridgeVault(_ctx.diamond).balanceOf(
            _who
        );

        state.tracked = IWtnCarryVault(_ctx.diamond).getTrackedContribution(
            _who
        );

        state.book = _bookOn(
            _ctx,
            _bookReferrer
        );

        state.creditSlot = (block.timestamp / CohortWeeks.WEEK) % CohortWeeks.RING_SLOTS;

        state.landSlot = (block.timestamp / CohortWeeks.WEEK + 1) % CohortWeeks.RING_SLOTS;

        (
            state.ring1AtCredit,
        ) = _ringOn(
            _ctx,
            _bookReferrer,
            state.creditSlot
        );

        (
            state.ring1AtLand,
            state.ring2AtLand
        ) = _ringOn(
            _ctx,
            _bookReferrer,
            state.landSlot
        );

        (
            uint64[52] memory ring1,
            uint64[52] memory ring2
        ) = _ringsOn(
            _ctx,
            _bookReferrer
        );

        for (uint256 s; s < CohortWeeks.RING_SLOTS; ++s) {

            state.ring1Sum += uint256(ring1[s]);

            state.ring2Sum += uint256(ring2[s]);
        }
    }

    function _dstState(
        address _who,
        address _bookReferrer
    )
        internal
        returns (SideState memory)
    {
        _alignDstClock();

        return _sideState(
            dst,
            _who,
            _bookReferrer
        );
    }

    function _scaleToDst(
        uint256 _amount
    )
        internal
        view
        returns (uint256)
    {
        if (dst.one >= src.one) {
            return _amount * (dst.one / src.one);
        }

        return _amount / (src.one / dst.one);
    }

    // ---- bridge, wire and delivery ----

    function _bridgeAndScrape(
        address _who,
        uint256 _amount,
        bytes memory _referralData
    )
        internal
        returns (
            SentMessage memory sent,
            WireCapture memory wire
        )
    {
        sent = _bridgeOut(
            _who,
            _amount,
            _referralData
        );

        wire = _scrapeWire(
            sent
        );
    }

    function _scrapeWire(
        SentMessage memory _sent
    )
        internal
        returns (WireCapture memory wire)
    {
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bool rampFound;

        for (uint256 i; i < entries.length; ++i) {

            if (entries[i].topics.length == 0) {
                continue;
            }

            if (entries[i].topics[0] == CohortBridgeCarrySent.selector) {

                if (entries[i].emitter != _sent.srcDiamond) {
                    continue;
                }

                _captureCarrySent(
                    entries[i],
                    wire
                );

                continue;
            }

            if (entries[i].topics[0] == CCIPMessageSent.selector) {

                if (
                    _scrapeRampV16(
                        entries[i],
                        _sent,
                        wire
                    )
                ) {
                    rampFound = true;
                }

                continue;
            }

            if (entries[i].topics[0] == ICcipOnRampV2Events.CCIPMessageSent.selector) {

                if (
                    _scrapeRampV20(
                        entries[i],
                        _sent,
                        wire
                    )
                ) {
                    rampFound = true;
                }
            }
        }

        require(
            rampFound,
            "CCIPMessageSent log not found for the bridge message"
        );
    }

    function _captureCarrySent(
        Vm.Log memory _entry,
        WireCapture memory _wire
    )
        internal
        pure
    {
        _wire.carryFound = true;

        _wire.carryUser = address(
            uint160(uint256(_entry.topics[1]))
        );

        _wire.carryDstSelector = uint64(
            uint256(_entry.topics[2])
        );

        _wire.carryReferrer = address(
            uint160(uint256(_entry.topics[3]))
        );

        (
            _wire.carryTrackedDelta,
            _wire.carryYear1,
            _wire.carryYear2,
            _wire.carryMature,
            _wire.carryBookReferrer
        ) = abi.decode(
            _entry.data,
            (uint256, uint256, uint256, uint256, address)
        );
    }

    function _scrapeRampV16(
        Vm.Log memory _entry,
        SentMessage memory _sent,
        WireCapture memory _wire
    )
        internal
        returns (bool)
    {
        Internal.EVM2AnyRampMessage memory ramp = abi.decode(
            _entry.data,
            (Internal.EVM2AnyRampMessage)
        );

        if (ramp.header.messageId != _sent.messageId) {
            return false;
        }

        _decodeRampData(
            ramp.data,
            _wire
        );

        emit CCIPMessageSent(
            ramp.header.destChainSelector,
            ramp.header.sequenceNumber,
            ramp
        );

        return true;
    }

    function _scrapeRampV20(
        Vm.Log memory _entry,
        SentMessage memory _sent,
        WireCapture memory _wire
    )
        internal
        returns (bool)
    {
        if (_entry.topics.length < 4 || _entry.topics[3] != _sent.messageId) {
            return false;
        }

        (
            address feeToken,
            uint256 amountBeforeFees,
            bytes memory encodedMessage,
            CcipV2Shapes.Receipt[] memory receipts,
            bytes[] memory verifierBlobs
        ) = abi.decode(
            _entry.data,
            (address, uint256, bytes, CcipV2Shapes.Receipt[], bytes[])
        );

        CcipV2Shapes.MessageV1 memory message = this.decodeCcipV2Message(
            encodedMessage
        );

        _decodeRampData(
            message.data,
            _wire
        );

        emit ICcipOnRampV2Events.CCIPMessageSent(
            uint64(uint256(_entry.topics[1])),
            address(uint160(uint256(_entry.topics[2]))),
            _entry.topics[3],
            feeToken,
            amountBeforeFees,
            encodedMessage,
            receipts,
            verifierBlobs
        );

        return true;
    }

    function _decodeRampData(
        bytes memory _data,
        WireCapture memory _wire
    )
        internal
        pure
    {
        _wire.rampData = _data;

        (
            _wire.wireUser,
            _wire.wireAmount,
            _wire.referralData
        ) = abi.decode(
            _data,
            (address, uint256, bytes)
        );
    }

    function _decodeCarry(
        bytes memory _referralData
    )
        internal
        pure
        returns (CarryPayload memory payload)
    {
        require(
            _referralData.length >= CohortWeeks.BRIDGE_CARRY_HEADER_BYTES,
            "wire referralData is not a carry payload"
        );

        uint256[] memory words = CohortWeeks._unpackBridgeCarry(
            _referralData
        );

        uint256 word0 = words[0];

        uint256 word1 = words[1];

        payload.referrer = CohortWeeks._carryEnvelopeReferrer(
            word0
        );

        payload.version = CohortWeeks._carryEnvelopeVersion(
            word0
        );

        payload.trackedDelta = CohortWeeks._carryTrackedDelta(
            word1
        );

        payload.assignedAt = CohortWeeks._bridgeCarryAssignedAt(
            word1
        );

        payload.rank = CohortWeeks._bridgeCarryRank(
            word1
        );

        (
            payload.year1,
            payload.year2
        ) = CohortWeeks._carryPairSums(
            words,
            CohortWeeks.BRIDGE_CARRY_HEADER_WORDS,
            CohortWeeks._bridgeCarryPairCount(
                word0
            )
        );

        payload.mature = words[2];

        payload.captureWeek = CohortWeeks._bridgeCarryCaptureWeek(
            word0
        );

        payload.pairCount = CohortWeeks._bridgeCarryPairCount(
            word0
        );
    }

    function _deliver(
        SentMessage memory _sent
    )
        internal
        returns (Vm.Log[] memory logs)
    {
        _alignDstClock();

        _route(
            _sent
        );

        logs = vm.getRecordedLogs();
    }

    function _findApplied(
        Vm.Log[] memory _logs,
        SentMessage memory _sent
    )
        internal
        pure
        returns (AppliedCapture memory applied)
    {
        for (uint256 i; i < _logs.length; ++i) {

            if (_logs[i].topics.length == 0) {
                continue;
            }

            if (_logs[i].topics[0] != CohortBridgeCarryApplied.selector) {
                continue;
            }

            if (_logs[i].emitter != _sent.dstDiamond) {
                continue;
            }

            if (address(uint160(uint256(_logs[i].topics[1]))) != _sent.user) {
                continue;
            }

            if (uint256(_logs[i].topics[2]) != uint256(_sent.srcChainSelector)) {
                continue;
            }

            applied.found = true;

            applied.effectiveReferrer = address(
                uint160(uint256(_logs[i].topics[3]))
            );

            (
                applied.carriedReferrer,
                applied.trackedDelta,
                applied.year1,
                applied.year2,
                applied.mature
            ) = abi.decode(
                _logs[i].data,
                (address, uint256, uint256, uint256, uint256)
            );

            return applied;
        }
    }

    function _countFrom(
        Vm.Log[] memory _logs,
        bytes32 _topic,
        address _emitter
    )
        internal
        pure
        returns (uint256 count)
    {
        for (uint256 i; i < _logs.length; ++i) {

            if (_logs[i].topics.length == 0) {
                continue;
            }

            if (_logs[i].topics[0] != _topic) {
                continue;
            }

            if (_logs[i].emitter != _emitter) {
                continue;
            }

            ++count;
        }
    }

    function _junkBytes()
        internal
        pure
        returns (bytes memory junk)
    {
        junk = new bytes(256);

        for (uint256 i; i < 8; ++i) {

            bytes32 word = keccak256(
                abi.encode(
                    "matrix junk word",
                    i
                )
            );

            for (uint256 j; j < 32; ++j) {
                junk[i * 32 + j] = word[j];
            }
        }
    }

    // ---- reverse lane ----

    function _reverseLaneScrapeSupported()
        internal
        returns (bool)
    {
        _onDst();

        address onRamp = ICcipRouterView(dst.router).getOnRamp(
            src.chainSelector
        );

        if (onRamp == address(0)) {
            return false;
        }

        bytes32 tag = keccak256(
            bytes(
                ICcipTypeAndVersion(onRamp).typeAndVersion()
            )
        );

        return tag == ON_RAMP_V16_TAG || tag == ON_RAMP_V20_TAG;
    }

    function _swapLaneDirection()
        internal
    {
        ChainCtx memory held = src;

        src = dst;

        dst = held;

        ReferralRegistry heldRegistry = srcRegistry;

        srcRegistry = dstRegistry;

        dstRegistry = heldRegistry;
    }

    function _bridgeBackAndDeliver(
        address _who,
        uint256 _amount
    )
        internal
        returns (
            SentMessage memory sent,
            WireCapture memory wire,
            Vm.Log[] memory logs
        )
    {
        _swapLaneDirection();

        (
            sent,
            wire
        ) = _bridgeAndScrape(
            _who,
            _amount,
            ""
        );

        logs = _deliver(
            sent
        );

        _swapLaneDirection();
    }

    // ---- assertions ----

    function _assertUnassignedOn(
        ChainCtx storage _ctx,
        ReferralRegistry _registry,
        address _who
    )
        internal
    {
        vm.selectFork(
            _ctx.forkId
        );

        assertEq(
            _registry.referrerOf(
                _who
            ),
            address(0),
            "registry must start unassigned"
        );

        assertEq(
            _registry.referrerKey(
                _who
            ),
            0,
            "registry key must start empty"
        );

        assertEq(
            _registry.pendingFlip(
                _ctx.diamond,
                _who
            ),
            address(0),
            "pending flip marker must start empty"
        );
    }

    function _assertSourceSliceGone(
        Run memory _run
    )
        internal
        pure
    {
        assertEq(
            _run.srcAfter.balance,
            0,
            "source must burn the bridged shares"
        );

        assertEq(
            _run.srcAfter.tracked,
            0,
            "bridge-out capture must clamp the source tracked contribution"
        );

        assertEq(
            _run.srcAfter.book.year1,
            0,
            "source first-year lane must be fully carried"
        );

        assertEq(
            _run.srcAfter.book.year2,
            0,
            "source second-year lane must be empty"
        );

        assertEq(
            _run.srcAfter.book.mature,
            0,
            "source mature lane must be empty"
        );

        assertEq(
            _run.srcAfter.ring1AtCredit,
            0,
            "source credit slot must be drained"
        );
    }

    function _assertCarryWire(
        WireCapture memory _wire,
        SentMessage memory _sent,
        CarryExpect memory _expect
    )
        internal
        pure
    {
        assertTrue(
            _wire.carryFound,
            "CohortBridgeCarrySent not emitted on the source"
        );

        assertEq(
            _wire.carryUser,
            _sent.user,
            "carry-sent user mismatch"
        );

        assertEq(
            uint256(_wire.carryDstSelector),
            uint256(_sent.dstChainSelector),
            "carry-sent destination selector mismatch"
        );

        assertEq(
            _wire.carryReferrer,
            _expect.referrer,
            "carry-sent referrer mismatch"
        );

        assertEq(
            _wire.carryTrackedDelta,
            _expect.trackedDelta,
            "carry-sent tracked delta mismatch"
        );

        assertEq(
            _wire.carryYear1,
            _expect.year1,
            "carry-sent first-year lane mismatch"
        );

        assertEq(
            _wire.carryYear2,
            _expect.year2,
            "carry-sent second-year lane mismatch"
        );

        assertEq(
            _wire.carryMature,
            _expect.mature,
            "carry-sent mature lane mismatch"
        );

        assertEq(
            _wire.carryBookReferrer,
            _expect.referrer,
            "carry-sent book referrer must be the source book the capture charged"
        );

        assertEq(
            _wire.wireUser,
            _sent.user,
            "wire user mismatch"
        );

        assertEq(
            _wire.wireAmount,
            _sent.dstAmount,
            "wire amount mismatch"
        );

        CarryPayload memory payload = _decodeCarry(
            _wire.referralData
        );

        assertEq(
            _wire.referralData.length,
            CohortWeeks.BRIDGE_CARRY_HEADER_BYTES + (payload.pairCount + 1) / 2 * 32,
            "wire referralData must be the carry header plus one word per two pairs"
        );

        assertEq(
            payload.referrer,
            _expect.referrer,
            "wire envelope referrer mismatch"
        );

        assertEq(
            payload.version,
            CohortWeeks.BRIDGE_CARRY_VERSION,
            "wire envelope version mismatch"
        );

        assertEq(
            payload.captureWeek,
            _sourceWeekOf(
                _sent
            ),
            "wire capture week must be the source week at the send"
        );

        assertEq(
            payload.trackedDelta,
            _expect.trackedDelta,
            "wire tracked delta mismatch"
        );

        assertEq(
            payload.assignedAt,
            _expect.assignedAt,
            "wire origin assignment time mismatch"
        );

        assertEq(
            payload.rank,
            _expect.rank,
            "wire origin chain rank mismatch"
        );

        assertEq(
            payload.year1,
            _expect.year1,
            "wire first-year aggregate mismatch"
        );

        assertEq(
            payload.year2,
            _expect.year2,
            "wire second-year aggregate mismatch"
        );

        assertEq(
            payload.mature,
            _expect.mature,
            "wire mature aggregate mismatch"
        );

        assertTrue(
            CohortWeeks._bridgeCarryValid(
                _wire.referralData,
                _sent.dstAmount
            ),
            "wire payload must pass the destination validation against the mint"
        );
    }

    function _assertMinted(
        Run memory _run
    )
        internal
    {
        _onDst();

        assertEq(
            _run.dstAfter.balance - _run.dstBefore.balance,
            _run.sent.dstAmount,
            "destination must mint the bridged amount"
        );

        assertEq(
            _run.sent.dstAmount,
            _run.carried,
            "minted amount must be the lane-scaled bridge amount"
        );

        assertTrue(
            ICcipBridgeVault(dst.diamond).processedMessageId(
                _run.sent.messageId
            ),
            "message not marked processed on the destination"
        );
    }

    function _assertConservation(
        Run memory _run
    )
        internal
        view
    {
        assertEq(
            _scaleToDst(
                _run.srcBefore.book.year1 - _run.srcAfter.book.year1
            ),
            _run.dstAfter.book.year1 - _run.dstBefore.book.year1,
            "first-year lane not conserved across the lane"
        );

        assertEq(
            _scaleToDst(
                _run.srcBefore.book.year2 - _run.srcAfter.book.year2
            ),
            _run.dstAfter.book.year2 - _run.dstBefore.book.year2,
            "second-year lane not conserved across the lane"
        );

        assertEq(
            _scaleToDst(
                _run.srcBefore.book.mature - _run.srcAfter.book.mature
            ),
            _run.dstAfter.book.mature - _run.dstBefore.book.mature,
            "mature lane not conserved across the lane"
        );

        assertEq(
            _scaleToDst(
                _run.srcBefore.tracked
            ),
            _scaleToDst(
                _run.srcAfter.tracked
            )
                + (_run.dstAfter.tracked - _run.dstBefore.tracked),
            "tracked contribution not conserved across the lane"
        );
    }

    function _assertLanded(
        Run memory _run
    )
        internal
        pure
    {
        assertEq(
            _run.dstAfter.ring1AtCredit - _run.dstBefore.ring1AtCredit,
            _run.carried,
            "carried slice must land at the credit slot of its capture week"
        );

        assertEq(
            _run.dstAfter.ring2AtLand,
            _run.dstBefore.ring2AtLand,
            "second-year ring must not move on a first-year carry"
        );

        assertEq(
            _run.dstAfter.ring1AtLand,
            _run.dstBefore.ring1AtLand,
            "the next graduating slot must not move on arrival"
        );

        assertEq(
            _run.dstAfter.tracked - _run.dstBefore.tracked,
            _run.carried,
            "destination tracked must grow by the carried delta"
        );
    }

    function _assertRegistryOn(
        ChainCtx storage _ctx,
        ReferralRegistry _registry,
        address _who,
        RegistryExpect memory _expect
    )
        internal
    {
        vm.selectFork(
            _ctx.forkId
        );

        assertEq(
            _registry.referrerOf(
                _who
            ),
            _expect.referrer,
            "registry referrer mismatch"
        );

        (
            address pairReferrer,
            uint256 assignedAt,
            uint256 rank
        ) = _registry.getReferrerPair(
            _who
        );

        assertEq(
            pairReferrer,
            _expect.referrer,
            "registry pair referrer mismatch"
        );

        assertEq(
            assignedAt,
            _expect.assignedAt,
            "registry pair assignment time mismatch"
        );

        assertEq(
            rank,
            _expect.rank,
            "registry pair chain rank mismatch"
        );

        assertEq(
            _registry.pendingFlip(
                _ctx.diamond,
                _who
            ),
            _expect.pending,
            "pending flip marker mismatch"
        );

        assertEq(
            _registry.effectiveReferrerOf(
                _who,
                _ctx.diamond
            ),
            _expect.pending == address(0)
                ? _expect.referrer
                : _expect.pending,
            "effective referrer mismatch"
        );

        assertEq(
            IWtnCarryVault(_ctx.diamond).getReferrerOf(
                _who
            ),
            _expect.referrer,
            "diamond referrer view mismatch"
        );
    }

    function _assertApplied(
        AppliedCapture memory _applied,
        AppliedExpect memory _expect
    )
        internal
        pure
    {
        assertTrue(
            _applied.found,
            "CohortBridgeCarryApplied not emitted on the destination"
        );

        assertEq(
            _applied.effectiveReferrer,
            _expect.effectiveReferrer,
            "carry-applied effective referrer mismatch"
        );

        assertEq(
            _applied.carriedReferrer,
            _expect.carriedReferrer,
            "carry-applied carried referrer mismatch"
        );

        assertEq(
            _applied.trackedDelta,
            _expect.trackedDelta,
            "carry-applied tracked delta mismatch"
        );

        assertEq(
            _applied.year1,
            _expect.year1,
            "carry-applied first-year lane mismatch"
        );

        assertEq(
            _applied.year2,
            _expect.year2,
            "carry-applied second-year lane mismatch"
        );

        assertEq(
            _applied.mature,
            _expect.mature,
            "carry-applied mature lane mismatch"
        );
    }

    function _assertNoDegrade(
        Vm.Log[] memory _logs,
        SentMessage memory _sent
    )
        internal
        pure
    {
        assertEq(
            _countFrom(
                _logs,
                CohortBridgeCarryDiscarded.selector,
                _sent.dstDiamond
            ),
            0,
            "carry must not be discarded"
        );

        assertEq(
            _countFrom(
                _logs,
                CohortBridgeCarryBookDropped.selector,
                _sent.dstDiamond
            ),
            0,
            "carry book must not be dropped"
        );

        assertEq(
            _countFrom(
                _logs,
                BridgeReferral.selector,
                _sent.dstDiamond
            ),
            0,
            "applied carry must silence the bridge-referral fallback"
        );
    }

    function _assertBookZero(
        ChainCtx storage _ctx,
        address _referrer,
        string memory _message
    )
        internal
    {
        Book memory book = _bookOn(
            _ctx,
            _referrer
        );

        assertEq(
            book.year1 + book.year2 + book.mature,
            0,
            _message
        );
    }

    function _assertRegistryCounts(
        Vm.Log[] memory _logs,
        uint256 _adopted,
        uint256 _lowered,
        uint256 _flipped,
        uint256 _marked
    )
        internal
        view
    {
        assertEq(
            _countFrom(
                _logs,
                ReferralSyncAdopted.selector,
                address(dstRegistry)
            ),
            _adopted,
            "registry adopt event count mismatch"
        );

        assertEq(
            _countFrom(
                _logs,
                ReferralSyncKeyLowered.selector,
                address(dstRegistry)
            ),
            _lowered,
            "registry key-lowered event count mismatch"
        );

        assertEq(
            _countFrom(
                _logs,
                ReferralSyncFlipped.selector,
                address(dstRegistry)
            ),
            _flipped,
            "registry flip event count mismatch"
        );

        assertEq(
            _countFrom(
                _logs,
                FlipMarked.selector,
                address(dstRegistry)
            ),
            _marked,
            "registry flip-marked event count mismatch"
        );
    }

    function _pokeAndAssertMigration(
        address _who,
        address _oldReferrer,
        address _newReferrer
    )
        internal
    {
        uint256 pairs = _nonzeroRingSlots(
            dst,
            _oldReferrer
        );

        Book memory oldBook = _bookOn(
            dst,
            _oldReferrer
        );

        Book memory newBookBefore = _bookOn(
            dst,
            _newReferrer
        );

        RingPair memory oldRings = _ringPairOn(
            dst,
            _oldReferrer
        );

        RingPair memory newRingsBefore = _ringPairOn(
            dst,
            _newReferrer
        );

        uint256 trackedBefore = _trackedOn(
            dst,
            _who
        );

        assertEq(
            oldBook.year1 + oldBook.year2 + oldBook.mature,
            trackedBefore,
            "old book must hold exactly the user's tracked cover before the poke"
        );

        _onDst();

        vm.expectEmit(
            true,
            true,
            true,
            true,
            dst.diamond
        );

        emit CohortReferrerFlipApplied(
            _who,
            _oldReferrer,
            _newReferrer,
            oldBook.year1,
            oldBook.year2,
            oldBook.mature,
            pairs
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(dstRegistry)
        );

        emit FlipMigrated(
            dst.diamond,
            _who,
            _oldReferrer,
            _newReferrer
        );

        dstRegistry.pokeMigration(
            _who
        );

        assertEq(
            dstRegistry.pendingFlip(
                dst.diamond,
                _who
            ),
            address(0),
            "poke must clear the pending flip marker"
        );

        assertEq(
            dstRegistry.effectiveReferrerOf(
                _who,
                dst.diamond
            ),
            _newReferrer,
            "poke must make the winner effective"
        );

        _assertBookZero(
            dst,
            _oldReferrer,
            "poke must drain the old book"
        );

        Book memory newBookAfter = _bookOn(
            dst,
            _newReferrer
        );

        assertEq(
            newBookAfter.year1,
            newBookBefore.year1 + oldBook.year1,
            "poke must move the first-year lane total"
        );

        assertEq(
            newBookAfter.year2,
            newBookBefore.year2 + oldBook.year2,
            "poke must move the second-year lane total"
        );

        assertEq(
            newBookAfter.mature,
            newBookBefore.mature + oldBook.mature,
            "poke must move the mature lane total"
        );

        _assertReplanted(
            oldRings,
            newRingsBefore,
            _ringPairOn(
                dst,
                _newReferrer
            )
        );

        assertEq(
            _trackedOn(
                dst,
                _who
            ),
            trackedBefore,
            "poke must not move the tracked contribution"
        );

        assertEq(
            _nonzeroRingSlots(
                dst,
                _oldReferrer
            ),
            0,
            "poke must empty the old rings"
        );
    }

    /**
     * @dev The three end-to-end tests inherited from the carry rehearsal
     * base scrape the wire with its 1.6-only reader, which cannot find
     * the on-ramp log on the OnRamp 2.0 lanes this matrix runs on. They
     * keep running in their own suite; here every lane contract skips
     * them, because group A pins the same claims (referred end to end,
     * unreferred tracked-only, delivery under the armed budget) through
     * the generation-aware scrape of this base.
     */
    function test_carryBridge_referredUserEndToEnd()
        public
        virtual
        override
    {
        vm.skip(
            true
        );
    }

    function test_carryBridge_unreferredUser_trackedOnly()
        public
        virtual
        override
    {
        vm.skip(
            true
        );
    }

    function test_carryBridge_gasUnderArmedBudget()
        public
        virtual
        override
    {
        vm.skip(
            true
        );
    }
}

/**
 * @dev Matrix group with both forks armed. Seven scenarios over one
 * referred bridge of a user who carries the whole tracked cover:
 *   1. the plain bridge adopts the source pair on an unassigned
 *      destination and lands the slice one week ahead of arrival;
 *   2. caller junk bytes on the referral entrypoint leave the wire
 *      byte-identical to the plain bridge, proven from one snapshot
 *      of the source fork;
 *   3. a structurally valid forged carry naming a stranger is
 *      replaced by the vault-built payload and the stranger gains
 *      nothing anywhere;
 *   4. a destination already holding the same referrer merges the
 *      books under it, lowering the sync key without a flip marker;
 *   5. a destination holding a different referrer with the earlier
 *      key keeps it, the carried referrer gains nothing there and
 *      the source book still lost the slice;
 *   6. a destination holding a different referrer with the later key
 *      flips to the carried referrer, marks the destination vault
 *      pending, lands the lanes under the old book holder and
 *      replants every pair at its own slot on the poke;
 *   7. a destination whose flip is already pending keeps the first
 *      marker through a second flip, lands under the old book holder
 *      and moves everything to the final winner on the poke.
 * Every scenario self-skips unless the lane is vault-peered in both
 * directions under the default off-ramp routing engine.
 */
abstract contract CohortBridgeAttributionMatrixForkGroupA is CohortBridgeAttributionMatrixForkBase {

    function test_matrix_bridgeToVault_referredAdoptsOnDestination()
        public
    {
        if (_laneReady() == false) {

            vm.skip(
                true
            );

            return;
        }

        _prepareLane();

        Run memory run;

        run.amount = BRIDGE_UNITS * src.one;

        run.carried = _scaleToDst(
            run.amount
        );

        run.srcAt = _seedReferred(
            src,
            user,
            run.amount,
            referrer
        );

        run.srcBefore = _sideState(
            src,
            user,
            referrer
        );

        assertEq(
            run.srcBefore.tracked,
            run.amount,
            "referred deposit must be tracked on the source"
        );

        assertEq(
            run.srcBefore.book.year1,
            run.amount,
            "referred deposit must credit the source first-year lane"
        );

        run.dstBefore = _dstState(
            user,
            referrer
        );

        _assertUnassignedOn(
            dst,
            dstRegistry,
            user
        );

        (
            run.sent,
            run.wire
        ) = _bridgeAndScrape(
            user,
            run.amount,
            ""
        );

        run.srcAfter = _sideState(
            src,
            user,
            referrer
        );

        _assertSourceSliceGone(
            run
        );

        _assertCarryWire(
            run.wire,
            run.sent,
            CarryExpect({
                referrer: referrer,
                assignedAt: run.srcAt,
                rank: _srcChainRank(),
                trackedDelta: run.carried,
                year1: run.carried,
                year2: 0,
                mature: 0
            })
        );

        run.logs = _deliver(
            run.sent
        );

        run.dstAfter = _dstState(
            user,
            referrer
        );

        _assertMinted(
            run
        );

        _assertConservation(
            run
        );

        _assertLanded(
            run
        );

        _assertRegistryOn(
            dst,
            dstRegistry,
            user,
            RegistryExpect({
                referrer: referrer,
                assignedAt: run.srcAt,
                rank: _srcChainRank(),
                pending: address(0)
            })
        );

        _assertRegistryOn(
            src,
            srcRegistry,
            user,
            RegistryExpect({
                referrer: referrer,
                assignedAt: run.srcAt,
                rank: _srcChainRank(),
                pending: address(0)
            })
        );

        _assertApplied(
            _findApplied(
                run.logs,
                run.sent
            ),
            AppliedExpect({
                effectiveReferrer: referrer,
                carriedReferrer: referrer,
                trackedDelta: run.carried,
                year1: run.carried,
                year2: 0,
                mature: 0
            })
        );

        _assertNoDegrade(
            run.logs,
            run.sent
        );

        _assertRegistryCounts(
            run.logs,
            1,
            0,
            0,
            0
        );
    }

    function test_matrix_withReferralJunkBytes_wireByteIdenticalToPlainBridge()
        public
    {
        if (_laneReady() == false) {

            vm.skip(
                true
            );

            return;
        }

        _prepareLane();

        Run memory run;

        run.amount = BRIDGE_UNITS * src.one;

        run.carried = _scaleToDst(
            run.amount
        );

        run.srcAt = _seedReferred(
            src,
            user,
            run.amount,
            referrer
        );

        run.srcBefore = _sideState(
            src,
            user,
            referrer
        );

        run.dstBefore = _dstState(
            user,
            referrer
        );

        _onSrc();

        uint256 snap = vm.snapshotState();

        (
            SentMessage memory plainSent,
            WireCapture memory plainWire
        ) = _bridgeAndScrape(
            user,
            run.amount,
            ""
        );

        _assertCarryWire(
            plainWire,
            plainSent,
            CarryExpect({
                referrer: referrer,
                assignedAt: run.srcAt,
                rank: _srcChainRank(),
                trackedDelta: run.carried,
                year1: run.carried,
                year2: 0,
                mature: 0
            })
        );

        _onSrc();

        assertTrue(
            vm.revertToState(
                snap
            ),
            "source fork snapshot must revert"
        );

        vm.getRecordedLogs();

        assertEq(
            _balanceOn(
                src,
                user
            ),
            run.amount,
            "revert must restore the pre-bridge source balance"
        );

        bytes memory junk = _junkBytes();

        (
            run.sent,
            run.wire
        ) = _bridgeAndScrape(
            user,
            run.amount,
            junk
        );

        assertEq(
            run.sent.messageId,
            plainSent.messageId,
            "junk bytes must not change the message id"
        );

        assertEq(
            keccak256(
                run.wire.rampData
            ),
            keccak256(
                plainWire.rampData
            ),
            "junk bytes must leave the wire data byte-identical"
        );

        assertEq(
            keccak256(
                run.wire.referralData
            ),
            keccak256(
                plainWire.referralData
            ),
            "junk bytes must leave the referral payload byte-identical"
        );

        assertTrue(
            keccak256(run.wire.referralData) != keccak256(junk),
            "junk bytes must never reach the wire"
        );

        _assertCarryWire(
            run.wire,
            run.sent,
            CarryExpect({
                referrer: referrer,
                assignedAt: run.srcAt,
                rank: _srcChainRank(),
                trackedDelta: run.carried,
                year1: run.carried,
                year2: 0,
                mature: 0
            })
        );

        run.srcAfter = _sideState(
            src,
            user,
            referrer
        );

        _assertSourceSliceGone(
            run
        );

        run.logs = _deliver(
            run.sent
        );

        run.dstAfter = _dstState(
            user,
            referrer
        );

        _assertMinted(
            run
        );

        _assertConservation(
            run
        );

        _assertLanded(
            run
        );

        _assertRegistryOn(
            dst,
            dstRegistry,
            user,
            RegistryExpect({
                referrer: referrer,
                assignedAt: run.srcAt,
                rank: _srcChainRank(),
                pending: address(0)
            })
        );

        _assertApplied(
            _findApplied(
                run.logs,
                run.sent
            ),
            AppliedExpect({
                effectiveReferrer: referrer,
                carriedReferrer: referrer,
                trackedDelta: run.carried,
                year1: run.carried,
                year2: 0,
                mature: 0
            })
        );

        _assertNoDegrade(
            run.logs,
            run.sent
        );
    }

    function test_matrix_withReferralForgedCarry_ignoredWhenArmed()
        public
    {
        if (_laneReady() == false) {

            vm.skip(
                true
            );

            return;
        }

        _prepareLane();

        Run memory run;

        run.amount = BRIDGE_UNITS * src.one;

        run.carried = _scaleToDst(
            run.amount
        );

        run.srcAt = _seedReferred(
            src,
            user,
            run.amount,
            referrer
        );

        bytes memory forged = BridgeCarryTestCodec._pack(
            forger,
            CohortWeeks.BRIDGE_CARRY_VERSION,
            block.timestamp / CohortWeeks.WEEK,
            run.carried,
            1,
            0,
            run.carried,
            0,
            0
        );

        assertTrue(
            CohortWeeks._bridgeCarryValid(
                forged,
                run.carried
            ),
            "forged payload must be structurally valid so only the source override keeps it off the wire"
        );

        run.srcBefore = _sideState(
            src,
            user,
            referrer
        );

        run.dstBefore = _dstState(
            user,
            referrer
        );

        _assertUnassignedOn(
            dst,
            dstRegistry,
            user
        );

        (
            run.sent,
            run.wire
        ) = _bridgeAndScrape(
            user,
            run.amount,
            forged
        );

        assertTrue(
            keccak256(run.wire.referralData) != keccak256(forged),
            "forged carry must never reach the wire"
        );

        _assertCarryWire(
            run.wire,
            run.sent,
            CarryExpect({
                referrer: referrer,
                assignedAt: run.srcAt,
                rank: _srcChainRank(),
                trackedDelta: run.carried,
                year1: run.carried,
                year2: 0,
                mature: 0
            })
        );

        run.srcAfter = _sideState(
            src,
            user,
            referrer
        );

        _assertSourceSliceGone(
            run
        );

        run.logs = _deliver(
            run.sent
        );

        run.dstAfter = _dstState(
            user,
            referrer
        );

        _assertMinted(
            run
        );

        _assertConservation(
            run
        );

        _assertLanded(
            run
        );

        _assertRegistryOn(
            dst,
            dstRegistry,
            user,
            RegistryExpect({
                referrer: referrer,
                assignedAt: run.srcAt,
                rank: _srcChainRank(),
                pending: address(0)
            })
        );

        _assertBookZero(
            dst,
            forger,
            "forged referrer must hold no destination book"
        );

        _assertBookZero(
            src,
            forger,
            "forged referrer must hold no source book"
        );

        _assertApplied(
            _findApplied(
                run.logs,
                run.sent
            ),
            AppliedExpect({
                effectiveReferrer: referrer,
                carriedReferrer: referrer,
                trackedDelta: run.carried,
                year1: run.carried,
                year2: 0,
                mature: 0
            })
        );

        _assertNoDegrade(
            run.logs,
            run.sent
        );

        _assertRegistryCounts(
            run.logs,
            1,
            0,
            0,
            0
        );
    }

    function test_matrix_destinationHasSameReferrer_booksMergeUnderIt()
        public
    {
        if (_laneReady() == false) {

            vm.skip(
                true
            );

            return;
        }

        _prepareLane();

        Run memory run;

        run.amount = BRIDGE_UNITS * src.one;

        run.carried = _scaleToDst(
            run.amount
        );

        run.srcAt = _seedReferred(
            src,
            user,
            run.amount,
            referrer
        );

        _advancePast(
            dst,
            run.srcAt
        );

        run.dstAt = _seedReferred(
            dst,
            user,
            DESTINATION_UNITS * dst.one,
            referrer
        );

        assertGt(
            run.dstAt,
            run.srcAt,
            "destination assignment must carry the later clock"
        );

        _assertRegistryOn(
            dst,
            dstRegistry,
            user,
            RegistryExpect({
                referrer: referrer,
                assignedAt: run.dstAt,
                rank: _dstChainRank(),
                pending: address(0)
            })
        );

        run.srcBefore = _sideState(
            src,
            user,
            referrer
        );

        run.dstBefore = _dstState(
            user,
            referrer
        );

        assertEq(
            run.dstBefore.book.year1,
            DESTINATION_UNITS * dst.one,
            "destination deposit must credit the shared referrer first"
        );

        (
            run.sent,
            run.wire
        ) = _bridgeAndScrape(
            user,
            run.amount,
            ""
        );

        run.srcAfter = _sideState(
            src,
            user,
            referrer
        );

        _assertSourceSliceGone(
            run
        );

        _assertCarryWire(
            run.wire,
            run.sent,
            CarryExpect({
                referrer: referrer,
                assignedAt: run.srcAt,
                rank: _srcChainRank(),
                trackedDelta: run.carried,
                year1: run.carried,
                year2: 0,
                mature: 0
            })
        );

        run.logs = _deliver(
            run.sent
        );

        run.dstAfter = _dstState(
            user,
            referrer
        );

        _assertMinted(
            run
        );

        _assertConservation(
            run
        );

        _assertLanded(
            run
        );

        assertEq(
            run.dstAfter.book.year1,
            DESTINATION_UNITS * dst.one + run.carried,
            "destination book must merge the carried slice under the shared referrer"
        );

        _assertRegistryOn(
            dst,
            dstRegistry,
            user,
            RegistryExpect({
                referrer: referrer,
                assignedAt: run.srcAt,
                rank: _srcChainRank(),
                pending: address(0)
            })
        );

        _assertApplied(
            _findApplied(
                run.logs,
                run.sent
            ),
            AppliedExpect({
                effectiveReferrer: referrer,
                carriedReferrer: referrer,
                trackedDelta: run.carried,
                year1: run.carried,
                year2: 0,
                mature: 0
            })
        );

        _assertNoDegrade(
            run.logs,
            run.sent
        );

        _assertRegistryCounts(
            run.logs,
            0,
            1,
            0,
            0
        );
    }

    function test_matrix_destinationHasEarlierDifferentReferrer_destinationKeeps()
        public
    {
        if (_laneReady() == false) {

            vm.skip(
                true
            );

            return;
        }

        _prepareLane();

        Run memory run;

        run.amount = BRIDGE_UNITS * src.one;

        run.carried = _scaleToDst(
            run.amount
        );

        run.dstAt = _clockOf(
            dst
        );

        _assignOnRegistry(
            dst,
            dstRegistry,
            user,
            dstReferrer,
            run.dstAt
        );

        _advancePast(
            src,
            run.dstAt
        );

        run.srcAt = _seedReferred(
            src,
            user,
            run.amount,
            referrer
        );

        assertGt(
            run.srcAt,
            run.dstAt,
            "source assignment must carry the later clock"
        );

        run.srcBefore = _sideState(
            src,
            user,
            referrer
        );

        run.dstBefore = _dstState(
            user,
            dstReferrer
        );

        (
            run.sent,
            run.wire
        ) = _bridgeAndScrape(
            user,
            run.amount,
            ""
        );

        run.srcAfter = _sideState(
            src,
            user,
            referrer
        );

        _assertSourceSliceGone(
            run
        );

        _assertCarryWire(
            run.wire,
            run.sent,
            CarryExpect({
                referrer: referrer,
                assignedAt: run.srcAt,
                rank: _srcChainRank(),
                trackedDelta: run.carried,
                year1: run.carried,
                year2: 0,
                mature: 0
            })
        );

        run.logs = _deliver(
            run.sent
        );

        run.dstAfter = _dstState(
            user,
            dstReferrer
        );

        _assertMinted(
            run
        );

        _assertConservation(
            run
        );

        _assertLanded(
            run
        );

        _assertRegistryOn(
            dst,
            dstRegistry,
            user,
            RegistryExpect({
                referrer: dstReferrer,
                assignedAt: run.dstAt,
                rank: _dstChainRank(),
                pending: address(0)
            })
        );

        _assertRegistryOn(
            src,
            srcRegistry,
            user,
            RegistryExpect({
                referrer: referrer,
                assignedAt: run.srcAt,
                rank: _srcChainRank(),
                pending: address(0)
            })
        );

        _assertBookZero(
            dst,
            referrer,
            "carried referrer must gain nothing on the destination"
        );

        _assertApplied(
            _findApplied(
                run.logs,
                run.sent
            ),
            AppliedExpect({
                effectiveReferrer: dstReferrer,
                carriedReferrer: referrer,
                trackedDelta: run.carried,
                year1: run.carried,
                year2: 0,
                mature: 0
            })
        );

        _assertNoDegrade(
            run.logs,
            run.sent
        );

        _assertRegistryCounts(
            run.logs,
            0,
            0,
            0,
            0
        );
    }

    function test_matrix_destinationHasLaterDifferentReferrer_carriedKeyFlipsAndMarksPending()
        public
    {
        if (_laneReady() == false) {

            vm.skip(
                true
            );

            return;
        }

        _prepareLane();

        Run memory run;

        run.amount = BRIDGE_UNITS * src.one;

        run.carried = _scaleToDst(
            run.amount
        );

        run.srcAt = _seedReferred(
            src,
            user,
            run.amount,
            referrer
        );

        _advancePast(
            dst,
            run.srcAt
        );

        run.dstAt = _seedReferred(
            dst,
            user,
            DESTINATION_UNITS * dst.one,
            dstReferrer
        );

        assertGt(
            run.dstAt,
            run.srcAt,
            "destination assignment must carry the later clock"
        );

        run.srcBefore = _sideState(
            src,
            user,
            referrer
        );

        run.dstBefore = _dstState(
            user,
            dstReferrer
        );

        assertEq(
            run.dstBefore.book.year1,
            DESTINATION_UNITS * dst.one,
            "destination deposit must credit the destination referrer first"
        );

        (
            run.sent,
            run.wire
        ) = _bridgeAndScrape(
            user,
            run.amount,
            ""
        );

        run.srcAfter = _sideState(
            src,
            user,
            referrer
        );

        _assertSourceSliceGone(
            run
        );

        _assertCarryWire(
            run.wire,
            run.sent,
            CarryExpect({
                referrer: referrer,
                assignedAt: run.srcAt,
                rank: _srcChainRank(),
                trackedDelta: run.carried,
                year1: run.carried,
                year2: 0,
                mature: 0
            })
        );

        run.logs = _deliver(
            run.sent
        );

        run.dstAfter = _dstState(
            user,
            dstReferrer
        );

        _assertMinted(
            run
        );

        _assertConservation(
            run
        );

        _assertLanded(
            run
        );

        _assertRegistryOn(
            dst,
            dstRegistry,
            user,
            RegistryExpect({
                referrer: referrer,
                assignedAt: run.srcAt,
                rank: _srcChainRank(),
                pending: dstReferrer
            })
        );

        _assertBookZero(
            dst,
            referrer,
            "winner must hold nothing on the destination before the poke"
        );

        _assertApplied(
            _findApplied(
                run.logs,
                run.sent
            ),
            AppliedExpect({
                effectiveReferrer: dstReferrer,
                carriedReferrer: referrer,
                trackedDelta: run.carried,
                year1: run.carried,
                year2: 0,
                mature: 0
            })
        );

        _assertNoDegrade(
            run.logs,
            run.sent
        );

        _assertRegistryCounts(
            run.logs,
            0,
            0,
            1,
            1
        );

        _pokeAndAssertMigration(
            user,
            dstReferrer,
            referrer
        );

        _assertRegistryOn(
            dst,
            dstRegistry,
            user,
            RegistryExpect({
                referrer: referrer,
                assignedAt: run.srcAt,
                rank: _srcChainRank(),
                pending: address(0)
            })
        );

        (
            uint256 creditRing,
        ) = _ringOn(
            dst,
            referrer,
            run.dstAfter.creditSlot
        );

        (
            uint256 landRing,
        ) = _ringOn(
            dst,
            referrer,
            run.dstAfter.landSlot
        );

        assertEq(
            creditRing,
            run.carried + run.dstBefore.ring1AtCredit,
            "poke must keep the carried slice and the deposit at their credit slot"
        );

        assertEq(
            landRing,
            run.dstBefore.ring1AtLand,
            "poke must not move anything onto the next graduating slot"
        );
    }

    function test_matrix_destinationFlipAlreadyPending_landsUnderOldUntilPoke()
        public
    {
        if (_laneReady() == false) {

            vm.skip(
                true
            );

            return;
        }

        _prepareLane();

        Run memory run;

        run.amount = BRIDGE_UNITS * src.one;

        run.carried = _scaleToDst(
            run.amount
        );

        run.srcAt = _seedReferred(
            src,
            user,
            run.amount,
            referrer
        );

        _advancePast(
            dst,
            run.srcAt
        );

        run.dstAt = _seedReferred(
            dst,
            user,
            DESTINATION_UNITS * dst.one,
            dstReferrer
        );

        assertGt(
            run.dstAt,
            run.srcAt + 1,
            "destination assignment must leave room for the relayed key"
        );

        _mergeOnRegistry(
            dst,
            dstRegistry,
            user,
            thirdReferrer,
            run.srcAt + 1,
            _foreignRank()
        );

        _assertRegistryOn(
            dst,
            dstRegistry,
            user,
            RegistryExpect({
                referrer: thirdReferrer,
                assignedAt: run.srcAt + 1,
                rank: _foreignRank(),
                pending: dstReferrer
            })
        );

        run.srcBefore = _sideState(
            src,
            user,
            referrer
        );

        run.dstBefore = _dstState(
            user,
            dstReferrer
        );

        (
            run.sent,
            run.wire
        ) = _bridgeAndScrape(
            user,
            run.amount,
            ""
        );

        run.srcAfter = _sideState(
            src,
            user,
            referrer
        );

        _assertSourceSliceGone(
            run
        );

        _assertCarryWire(
            run.wire,
            run.sent,
            CarryExpect({
                referrer: referrer,
                assignedAt: run.srcAt,
                rank: _srcChainRank(),
                trackedDelta: run.carried,
                year1: run.carried,
                year2: 0,
                mature: 0
            })
        );

        run.logs = _deliver(
            run.sent
        );

        run.dstAfter = _dstState(
            user,
            dstReferrer
        );

        _assertMinted(
            run
        );

        _assertConservation(
            run
        );

        _assertLanded(
            run
        );

        _assertRegistryOn(
            dst,
            dstRegistry,
            user,
            RegistryExpect({
                referrer: referrer,
                assignedAt: run.srcAt,
                rank: _srcChainRank(),
                pending: dstReferrer
            })
        );

        _assertBookZero(
            dst,
            referrer,
            "final winner must hold nothing on the destination before the poke"
        );

        _assertBookZero(
            dst,
            thirdReferrer,
            "overtaken relayed referrer must hold nothing on the destination"
        );

        _assertApplied(
            _findApplied(
                run.logs,
                run.sent
            ),
            AppliedExpect({
                effectiveReferrer: dstReferrer,
                carriedReferrer: referrer,
                trackedDelta: run.carried,
                year1: run.carried,
                year2: 0,
                mature: 0
            })
        );

        _assertNoDegrade(
            run.logs,
            run.sent
        );

        _assertRegistryCounts(
            run.logs,
            0,
            0,
            1,
            0
        );

        _pokeAndAssertMigration(
            user,
            dstReferrer,
            referrer
        );

        _assertRegistryOn(
            dst,
            dstRegistry,
            user,
            RegistryExpect({
                referrer: referrer,
                assignedAt: run.srcAt,
                rank: _srcChainRank(),
                pending: address(0)
            })
        );

        _assertBookZero(
            dst,
            thirdReferrer,
            "overtaken relayed referrer must hold nothing after the poke"
        );
    }
}

contract CohortBridgeMatrixUsdcMainnetBaseFork is CohortBridgeAttributionMatrixForkGroupA {

    function _laneConfig()
        internal
        pure
        override
        returns (LaneCfg memory)
    {
        return LaneCfg({
            product: "usdc",
            srcNetwork: "mainnet",
            dstNetwork: "base",
            srcRpc: "mainnet",
            dstRpc: "base"
        });
    }

    function _srcChainRank()
        internal
        pure
        override
        returns (uint256)
    {
        return 0;
    }

    function _dstChainRank()
        internal
        pure
        override
        returns (uint256)
    {
        return 1;
    }
}

contract CohortBridgeMatrixUsdcBaseArbitrumFork is CohortBridgeAttributionMatrixForkGroupA {

    function _laneConfig()
        internal
        pure
        override
        returns (LaneCfg memory)
    {
        return LaneCfg({
            product: "usdc",
            srcNetwork: "base",
            dstNetwork: "arbitrum",
            srcRpc: "base",
            dstRpc: "arbitrum"
        });
    }

    function _srcChainRank()
        internal
        pure
        override
        returns (uint256)
    {
        return 1;
    }

    function _dstChainRank()
        internal
        pure
        override
        returns (uint256)
    {
        return 2;
    }
}

contract CohortBridgeMatrixUsdgMainnetRobinhoodFork is CohortBridgeAttributionMatrixForkGroupA {

    function _laneConfig()
        internal
        pure
        override
        returns (LaneCfg memory)
    {
        return LaneCfg({
            product: "usdg",
            srcNetwork: "mainnet",
            dstNetwork: "robinhood",
            srcRpc: "mainnet",
            dstRpc: "robinhood"
        });
    }

    function _srcChainRank()
        internal
        pure
        override
        returns (uint256)
    {
        return 0;
    }

    function _dstChainRank()
        internal
        pure
        override
        returns (uint256)
    {
        return 3;
    }
}

contract CohortBridgeMatrixUsdgArbitrumMainnetFork is CohortBridgeAttributionMatrixForkGroupA {

    function _laneConfig()
        internal
        pure
        override
        returns (LaneCfg memory)
    {
        return LaneCfg({
            product: "usdg",
            srcNetwork: "arbitrum",
            dstNetwork: "mainnet",
            srcRpc: "arbitrum",
            dstRpc: "mainnet"
        });
    }

    function _srcChainRank()
        internal
        pure
        override
        returns (uint256)
    {
        return 2;
    }

    function _dstChainRank()
        internal
        pure
        override
        returns (uint256)
    {
        return 0;
    }
}
