// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Test.sol";

import {Internal} from "@chainlink/contracts-ccip/contracts/libraries/Internal.sol";

import {
    ICcipBridgeVault,
    ICcipTypeAndVersion
} from "./utils/CcipForkInterfaces.sol";
import {ICcipOffRampExec} from "./utils/CcipForkHarness.sol";
import {
    CcipV2Shapes,
    ICcipOffRampV2,
    ICcipOnRampV2Events
} from "./utils/CcipV2Shapes.sol";
import {
    CohortBridgeAttributionMatrixForkBase,
    IWtnMatrixVault
} from "./CohortBridgeAttributionMatrixFork.t.sol";

import {ReferralRegistry} from "../../../src/registry/pending/ReferralRegistry.sol";

import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev The one extra entrypoint of the LIVE diamond the state matrix
 * drives beyond the attribution base: the routed public settle that
 * rotates a referrer's rings up to a bounded number of weekly
 * boundaries, used to read an aged source book in settled lanes
 * before it is bridged.
 */
interface IWtnStatesVault {

    function advanceBook(
        address referrer,
        uint256 maxBoundaries
    )
        external;
}

/**
 * @dev Matrix group with both forks armed, probing the STATES a user's
 * tracked cover can be in when the bridge fires, on top of the plain
 * referred bridge the first group pins. Seven scenarios:
 *   1. a referred holder with untracked headroom bridges only the
 *      headroom: the wire carries empty referral bytes, the source
 *      tracked cover and book do not move, no clamp and no carry
 *      event fires, and the destination mints untracked with an
 *      unassigned registry;
 *   2. a lazy deficit pending from a transfer away without a later
 *      touchpoint is destroyed sale-like by the pre-burn clamp before
 *      the bridge carries the burned slice: the source emits the
 *      destroying reduction and clamp first, then the carried
 *      reduction, clamp and carry, and the destination gains exactly
 *      the carried slice while the destroyed part reaches nobody;
 *   3. an unreferred user bridges a tracked-only carry with a zero
 *      referrer and empty lanes, both registries stay unassigned and
 *      no book moves anywhere;
 *   4. a user whose cover sits in two ring slots bridges the full
 *      balance while a bystander shares the referrer: the whole user
 *      slice leaves as one aggregate that lands in one slot, and only
 *      the bystander's cover stays behind;
 *   5. a cohort aged past its first year rides the second-year lane
 *      and lands on ring two one week ahead of arrival;
 *   6. a cohort aged past its second year rides the mature lane and
 *      lands on the week-less mature lane without any ring write;
 *   7. a bridge there and back over the reverse lane returns the
 *      tracked cover and the book to the origin scaled there and back
 *      once, with the away side fully drained, the origin registry
 *      silent and no credit doubled; because the bridge entrypoint is
 *      pause-gated while the receive path is not, the return leg
 *      lifts a live deposit pause on the away vault under its real
 *      master exactly as the seeding rails do on the source.
 *
 * Aging discipline. The live fee quoters of every lane in this suite
 * run the 2.0 generation, which keeps no price staleness gate, so a
 * source clock warped weeks ahead still quotes and sends through the
 * real on-ramp. The aged scenarios settle the source book through the
 * routed advance entrypoint before reading it, so the per-lane
 * conservation compares settled lanes on both sides.
 *
 * Shared clock discipline. All scenarios of one run share one block
 * clock per fork: the clock a scenario leaves on a fork when it
 * switches away is the clock the next fork switch of any scenario
 * reads back. Every scenario therefore seeds, ages, settles, bridges
 * and reads the source in one stretch without switching forks, pins
 * the source clock right before the bridge, and rewinds an aged
 * source to its seed clock before the delivery, so no aged clock
 * ever leaks into the shared state. Deliveries run through an
 * aligned copy of the off-ramp shim that warps the destination
 * forward to the source clock only after its own fork switch, which
 * keeps the destination merge from ever running behind the registry
 * key it adopts. Landing slots are read back from the settle
 * timestamp the delivery stamps on the destination book, never
 * predicted from a clock read before a switch.
 *
 * Source log discipline. Scenarios that pin the ORDER of source-side
 * events scrape the wire from the recorded entries themselves,
 * through the base's per-generation ramp decoders, and keep the
 * entries for the event walk; the ramp log is re-emitted exactly as
 * the base does so the routing engine still finds it.
 *
 * Every scenario self-skips unless the lane is vault-peered in both
 * directions under the default off-ramp routing engine; the round
 * trip additionally self-skips when the reverse on-ramp generation is
 * not scrape-supported.
 */
abstract contract CohortBridgeAttributionMatrixForkGroupB is CohortBridgeAttributionMatrixForkBase {

    struct DeficitTrace {
        uint256 firstReduced;
        uint256 firstSynced;
        uint256 secondReduced;
        uint256 secondSynced;
        uint256 carrySent;
    }

    struct RoundTrip {
        uint256 returned;
        uint256 awayClock;
        SentMessage sentBack;
        WireCapture wireBack;
        Vm.Log[] logsBack;
        SideState originAfter;
        SideState awayAfter;
    }

    event CohortBookReduced(
        address indexed referrer,
        uint256 amount,
        uint256 fromYear1,
        uint256 fromYear2,
        uint256 fromMature
    );

    uint256 internal constant HEADROOM_UNITS = 250;

    uint256 internal constant DEFICIT_TRACKED_UNITS = 100;

    uint256 internal constant DEFICIT_AWAY_UNITS = 30;

    uint256 internal constant DEFICIT_BRIDGE_UNITS = 50;

    uint256 internal constant BYSTANDER_UNITS = 300;

    uint256 internal constant FIRST_TRANCHE_UNITS = 400;

    uint256 internal constant SECOND_TRANCHE_UNITS = 600;

    uint256 internal constant YEAR2_AGE_WEEKS = 53;

    uint256 internal constant MATURE_AGE_WEEKS = 105;

    // ---- clocks ----

    function _pinSource(
        uint256 _clock
    )
        internal
    {
        _onSrc();

        vm.warp(
            _clock
        );
    }

    function _alignDestinationAtLeast(
        uint256 _clock
    )
        internal
    {
        if (block.timestamp < _clock) {

            vm.warp(
                _clock
            );
        }
    }

    function _advanceSourceBook(
        address _referrer
    )
        internal
    {
        _onSrc();

        IWtnStatesVault(src.diamond).advanceBook(
            _referrer,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );
    }

    // ---- live pause ----

    function _liftPause(
        ChainCtx storage _ctx
    )
        internal
    {
        vm.selectFork(
            _ctx.forkId
        );

        ICcipBridgeVault vault = ICcipBridgeVault(
            _ctx.diamond
        );

        if (vault.paused() == false) {
            return;
        }

        vm.prank(
            _ctx.master
        );

        vault.unpauseDeposits();
    }

    function _slotOf(
        uint256 _timestamp
    )
        internal
        pure
        returns (uint256)
    {
        return (_timestamp / CohortWeeks.WEEK) % CohortWeeks.RING_SLOTS;
    }

    function _lastSettleOn(
        ChainCtx storage _ctx,
        address _referrer
    )
        internal
        returns (uint256 lastSettle)
    {
        vm.selectFork(
            _ctx.forkId
        );

        (
            ,
            ,
            ,
            lastSettle
        ) = IWtnMatrixVault(_ctx.diamond).getCohortBook(
            _referrer
        );
    }

    function _landingSlotOn(
        ChainCtx storage _ctx,
        address _referrer
    )
        internal
        returns (uint256)
    {
        uint256 lastSettle = _lastSettleOn(
            _ctx,
            _referrer
        );

        return (lastSettle / CohortWeeks.WEEK + 1) % CohortWeeks.RING_SLOTS;
    }

    // ---- scaling ----

    function _scaleBackToSrc(
        uint256 _amount
    )
        internal
        view
        returns (uint256)
    {
        if (src.one >= dst.one) {
            return _amount * (src.one / dst.one);
        }

        return _amount / (dst.one / src.one);
    }

    // ---- readers ----

    function _awayState(
        address _who,
        address _bookReferrer
    )
        internal
        returns (SideState memory)
    {
        _onDst();

        return _sideState(
            dst,
            _who,
            _bookReferrer
        );
    }

    // ---- bridge keeping the source entries ----

    function _bridgeAndScrapeWithLogs(
        address _who,
        uint256 _amount,
        bytes memory _referralData
    )
        internal
        returns (
            SentMessage memory sent,
            WireCapture memory wire,
            Vm.Log[] memory srcLogs
        )
    {
        sent = _bridgeOut(
            _who,
            _amount,
            _referralData
        );

        srcLogs = vm.getRecordedLogs();

        wire = _scrapeEntries(
            srcLogs,
            sent
        );
    }

    function _scrapeEntries(
        Vm.Log[] memory _entries,
        SentMessage memory _sent
    )
        internal
        returns (WireCapture memory wire)
    {
        bool rampFound;

        for (uint256 i; i < _entries.length; ++i) {

            if (_entries[i].topics.length == 0) {
                continue;
            }

            if (_entries[i].topics[0] == CohortBridgeCarrySent.selector) {

                if (_entries[i].emitter != _sent.srcDiamond) {
                    continue;
                }

                _captureCarrySent(
                    _entries[i],
                    wire
                );

                continue;
            }

            if (_entries[i].topics[0] == CCIPMessageSent.selector) {

                if (
                    _scrapeRampV16(
                        _entries[i],
                        _sent,
                        wire
                    )
                ) {
                    rampFound = true;
                }

                continue;
            }

            if (_entries[i].topics[0] == ICcipOnRampV2Events.CCIPMessageSent.selector) {

                if (
                    _scrapeRampV20(
                        _entries[i],
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

    // ---- aligned delivery ----

    function _deliverAligned(
        SentMessage memory _sent,
        uint256 _floorClock
    )
        internal
        returns (Vm.Log[] memory logs)
    {
        _onSrc();

        bytes32 tag = keccak256(
            bytes(
                ICcipTypeAndVersion(_sent.srcOnRamp).typeAndVersion()
            )
        );

        if (tag == ON_RAMP_V20_TAG) {

            _deliverV20Aligned(
                _sent,
                _floorClock
            );
        } else {

            require(
                tag == ON_RAMP_V16_TAG,
                "aligned delivery understands OnRamp 1.6.0 and 2.0.0 only"
            );

            _deliverV16Aligned(
                _sent,
                _floorClock
            );
        }

        logs = vm.getRecordedLogs();
    }

    function _deliverV16Aligned(
        SentMessage memory _sent,
        uint256 _floorClock
    )
        internal
    {
        Internal.EVM2AnyRampMessage memory ramp = _scrapeRampMessage(
            _sent.messageId
        );

        _onDst();

        _alignDestinationAtLeast(
            _floorClock
        );

        address offRamp = _findOffRamp(
            _sent.srcChainSelector,
            _sent.srcOnRamp
        );

        require(
            offRamp != address(0),
            "off-ramp not found for lane"
        );

        Internal.Any2EVMRampMessage memory delivery = Internal.Any2EVMRampMessage({
            header: ramp.header,
            sender: abi.encode(ramp.sender),
            data: ramp.data,
            receiver: _decodeAddress(ramp.receiver),
            gasLimit: _gasLimitOf(ramp.extraArgs),
            tokenAmounts: new Internal.Any2EVMTokenTransfer[](0)
        });

        vm.prank(
            offRamp
        );

        ICcipOffRampExec(offRamp).executeSingleMessage(
            delivery,
            new bytes[](0),
            new uint32[](0)
        );
    }

    function _deliverV20Aligned(
        SentMessage memory _sent,
        uint256 _floorClock
    )
        internal
    {
        bytes memory encodedMessage = _scrapeV2EncodedMessage(
            _sent.messageId
        );

        CcipV2Shapes.MessageV1 memory message = this.decodeCcipV2Message(
            encodedMessage
        );

        _onDst();

        _alignDestinationAtLeast(
            _floorClock
        );

        address offRamp = _findOffRamp(
            _sent.srcChainSelector,
            _sent.srcOnRamp
        );

        require(
            offRamp != address(0),
            "off-ramp not found for lane"
        );

        (
            address[] memory ccvs,
            bytes[] memory verifierResults
        ) = _mockCcvQuorum(
            offRamp,
            encodedMessage
        );

        vm.prank(
            offRamp
        );

        ICcipOffRampV2(offRamp).executeSingleMessage(
            message,
            _sent.messageId,
            ccvs,
            verifierResults,
            0
        );
    }

    function _bridgeBackAligned(
        address _who,
        uint256 _amount,
        uint256 _awayClock
    )
        internal
        returns (
            SentMessage memory sent,
            WireCapture memory wire,
            Vm.Log[] memory logs
        )
    {
        _swapLaneDirection();

        _pinSource(
            _awayClock
        );

        _liftPause(
            src
        );

        (
            sent,
            wire
        ) = _bridgeAndScrape(
            _who,
            _amount,
            ""
        );

        logs = _deliverAligned(
            sent,
            _awayClock
        );

        _swapLaneDirection();
    }

    // ---- log walks ----

    function _indexOfNth(
        Vm.Log[] memory _logs,
        bytes32 _topic,
        address _emitter,
        uint256 _nth
    )
        internal
        pure
        returns (uint256)
    {
        uint256 seen;

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

            if (seen == _nth) {
                return i;
            }

            ++seen;
        }

        revert("requested log occurrence not found");
    }

    function _deficitTrace(
        Vm.Log[] memory _logs
    )
        internal
        view
        returns (DeficitTrace memory trace)
    {
        assertEq(
            _countFrom(
                _logs,
                CohortBookReduced.selector,
                src.diamond
            ),
            2,
            "exactly two reductions must fire on the source"
        );

        assertEq(
            _countFrom(
                _logs,
                CohortContributionSynced.selector,
                src.diamond
            ),
            2,
            "exactly two clamps must fire on the source"
        );

        assertEq(
            _countFrom(
                _logs,
                CohortBridgeCarrySent.selector,
                src.diamond
            ),
            1,
            "exactly one carry must leave the source"
        );

        trace.firstReduced = _indexOfNth(
            _logs,
            CohortBookReduced.selector,
            src.diamond,
            0
        );

        trace.secondReduced = _indexOfNth(
            _logs,
            CohortBookReduced.selector,
            src.diamond,
            1
        );

        trace.firstSynced = _indexOfNth(
            _logs,
            CohortContributionSynced.selector,
            src.diamond,
            0
        );

        trace.secondSynced = _indexOfNth(
            _logs,
            CohortContributionSynced.selector,
            src.diamond,
            1
        );

        trace.carrySent = _indexOfNth(
            _logs,
            CohortBridgeCarrySent.selector,
            src.diamond,
            0
        );
    }

    function _assertReducedAt(
        Vm.Log[] memory _logs,
        uint256 _index,
        uint256 _amount,
        string memory _label
    )
        internal
        view
    {
        assertEq(
            address(uint160(uint256(_logs[_index].topics[1]))),
            referrer,
            string.concat(
                "the ",
                _label,
                " reduction must hit the referrer's book"
            )
        );

        (
            uint256 amount,
            uint256 fromYear1,
            uint256 fromYear2,
            uint256 fromMature
        ) = abi.decode(
            _logs[_index].data,
            (uint256, uint256, uint256, uint256)
        );

        assertEq(
            amount,
            _amount,
            string.concat(
                "the ",
                _label,
                " reduction amount mismatch"
            )
        );

        assertEq(
            fromYear1,
            _amount,
            string.concat(
                "the ",
                _label,
                " reduction must come out of the first-year lane"
            )
        );

        assertEq(
            fromYear2 + fromMature,
            0,
            string.concat(
                "the ",
                _label,
                " reduction must touch no aged lane"
            )
        );
    }

    function _assertSyncedAt(
        Vm.Log[] memory _logs,
        uint256 _index,
        uint256 _old,
        uint256 _new
    )
        internal
        view
    {
        assertEq(
            address(uint160(uint256(_logs[_index].topics[1]))),
            user,
            "the clamp must name the user"
        );

        assertEq(
            address(uint160(uint256(_logs[_index].topics[2]))),
            referrer,
            "the clamp must name the referrer"
        );

        (
            uint256 oldContribution,
            uint256 newContribution
        ) = abi.decode(
            _logs[_index].data,
            (uint256, uint256)
        );

        assertEq(
            oldContribution,
            _old,
            "clamp old contribution mismatch"
        );

        assertEq(
            newContribution,
            _new,
            "clamp new contribution mismatch"
        );
    }

    function _assertDeficitTrace(
        Vm.Log[] memory _logs,
        uint256 _destroyed,
        uint256 _carriedSource
    )
        internal
        view
    {
        DeficitTrace memory trace = _deficitTrace(
            _logs
        );

        assertLt(
            trace.firstReduced,
            trace.firstSynced,
            "the destroying reduction must precede its clamp"
        );

        assertLt(
            trace.firstSynced,
            trace.secondReduced,
            "the destroying clamp must precede the carried reduction"
        );

        assertLt(
            trace.secondReduced,
            trace.secondSynced,
            "the carried reduction must precede the bridge clamp"
        );

        assertLt(
            trace.secondSynced,
            trace.carrySent,
            "the bridge clamp must precede the carry"
        );

        _assertReducedAt(
            _logs,
            trace.firstReduced,
            _destroyed,
            "destroying"
        );

        _assertReducedAt(
            _logs,
            trace.secondReduced,
            _carriedSource,
            "carried"
        );

        _assertSyncedAt(
            _logs,
            trace.firstSynced,
            DEFICIT_TRACKED_UNITS * src.one,
            DEFICIT_TRACKED_UNITS * src.one - _destroyed
        );

        _assertSyncedAt(
            _logs,
            trace.secondSynced,
            DEFICIT_TRACKED_UNITS * src.one - _destroyed,
            DEFICIT_TRACKED_UNITS * src.one - _destroyed - _carriedSource
        );
    }

    // ---- assertions ----

    function _assertEmptyWire(
        WireCapture memory _wire,
        SentMessage memory _sent
    )
        internal
        pure
    {
        assertFalse(
            _wire.carryFound,
            "no carry may be built while the balance covers the tracked cover"
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

        assertEq(
            _wire.referralData.length,
            0,
            "wire referralData must be empty when nothing is carried"
        );

        assertEq(
            keccak256(_wire.rampData),
            keccak256(
                abi.encode(
                    _sent.user,
                    _sent.dstAmount,
                    bytes("")
                )
            ),
            "the wire must be the plain three-field bridge payload"
        );
    }

    function _assertSourceUntouched(
        Run memory _run
    )
        internal
        pure
    {
        assertEq(
            _run.srcAfter.tracked,
            _run.srcBefore.tracked,
            "the source tracked cover must not move"
        );

        assertEq(
            _run.srcAfter.book.year1,
            _run.srcBefore.book.year1,
            "the source first-year lane must not move"
        );

        assertEq(
            _run.srcAfter.book.year2,
            _run.srcBefore.book.year2,
            "the source second-year lane must not move"
        );

        assertEq(
            _run.srcAfter.book.mature,
            _run.srcBefore.book.mature,
            "the source mature lane must not move"
        );

        assertEq(
            _run.srcAfter.ring1AtCredit,
            _run.srcBefore.ring1AtCredit,
            "the source credit slot must not move"
        );
    }

    function _assertDestinationUntouched(
        Run memory _run
    )
        internal
    {
        assertEq(
            _run.dstAfter.tracked,
            _run.dstBefore.tracked,
            "the destination must land untracked"
        );

        assertEq(
            _run.dstAfter.book.year1,
            _run.dstBefore.book.year1,
            "the destination first-year lane must not move"
        );

        assertEq(
            _run.dstAfter.book.year2,
            _run.dstBefore.book.year2,
            "the destination second-year lane must not move"
        );

        assertEq(
            _run.dstAfter.book.mature,
            _run.dstBefore.book.mature,
            "the destination mature lane must not move"
        );

        assertEq(
            _nonzeroRingSlots(
                dst,
                referrer
            ),
            0,
            "no destination ring slot may be written"
        );
    }

    function _assertLandedOn(
        ChainCtx storage _ctx,
        address _referrer,
        uint256 _year1,
        uint256 _year2
    )
        internal
    {
        uint256 slot = _landingSlotOn(
            _ctx,
            _referrer
        );

        (
            uint256 ring1,
            uint256 ring2
        ) = _ringOn(
            _ctx,
            _referrer,
            slot
        );

        assertEq(
            ring1,
            _year1,
            "the first-year aggregate must land one week ahead of the arrival week"
        );

        assertEq(
            ring2,
            _year2,
            "the second-year aggregate must land one week ahead of the arrival week"
        );

        uint256 expectedSlots = (_year1 > 0 ? 1 : 0) + (_year2 > 0 ? 1 : 0);

        assertEq(
            _nonzeroRingSlots(
                _ctx,
                _referrer
            ),
            expectedSlots,
            "the landing must touch exactly the carried rings"
        );
    }

    function _assertArrivalLanes(
        Run memory _run,
        uint256 _year1,
        uint256 _year2,
        uint256 _mature
    )
        internal
        pure
    {
        assertEq(
            _run.dstAfter.book.year1 - _run.dstBefore.book.year1,
            _year1,
            "destination first-year lane delta mismatch"
        );

        assertEq(
            _run.dstAfter.book.year2 - _run.dstBefore.book.year2,
            _year2,
            "destination second-year lane delta mismatch"
        );

        assertEq(
            _run.dstAfter.book.mature - _run.dstBefore.book.mature,
            _mature,
            "destination mature lane delta mismatch"
        );

        assertEq(
            _run.dstAfter.tracked - _run.dstBefore.tracked,
            _run.carried,
            "destination tracked must grow by the carried delta"
        );
    }

    function _assertNoCarryOnDestination(
        Vm.Log[] memory _logs,
        SentMessage memory _sent
    )
        internal
        pure
    {
        assertEq(
            _countFrom(
                _logs,
                CohortBridgeCarryApplied.selector,
                _sent.dstDiamond
            ),
            0,
            "nothing may apply without a carry on the wire"
        );

        assertEq(
            _countFrom(
                _logs,
                CohortBridgeCarryDiscarded.selector,
                _sent.dstDiamond
            ),
            0,
            "nothing may be discarded without a carry on the wire"
        );

        assertEq(
            _countFrom(
                _logs,
                CohortBridgeCarryBookDropped.selector,
                _sent.dstDiamond
            ),
            0,
            "no book may be dropped without a carry on the wire"
        );

        assertEq(
            _countFrom(
                _logs,
                BridgeReferral.selector,
                _sent.dstDiamond
            ),
            0,
            "empty referral bytes must not surface the legacy fallback"
        );
    }

    function _assertRegistrySilentOn(
        Vm.Log[] memory _logs,
        ReferralRegistry _registry
    )
        internal
        pure
    {
        assertEq(
            _countFrom(
                _logs,
                ReferralSyncAdopted.selector,
                address(_registry)
            ),
            0,
            "the registry must adopt nothing"
        );

        assertEq(
            _countFrom(
                _logs,
                ReferralSyncKeyLowered.selector,
                address(_registry)
            ),
            0,
            "the registry must lower no key"
        );

        assertEq(
            _countFrom(
                _logs,
                ReferralSyncFlipped.selector,
                address(_registry)
            ),
            0,
            "the registry must flip nothing"
        );

        assertEq(
            _countFrom(
                _logs,
                FlipMarked.selector,
                address(_registry)
            ),
            0,
            "the registry must mark no flip"
        );
    }

    // ---- scenarios ----

    function test_matrix_untrackedHeadroomOnly_emptyWireNoBookChange()
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

        run.amount = HEADROOM_UNITS * src.one;

        run.carried = _scaleToDst(
            run.amount
        );

        _onSrc();

        run.srcAt = _seedReferred(
            src,
            user,
            BRIDGE_UNITS * src.one,
            referrer
        );

        _transferIn(
            src,
            holder,
            user,
            run.amount
        );

        run.srcBefore = _sideState(
            src,
            user,
            referrer
        );

        assertEq(
            run.srcBefore.balance,
            BRIDGE_UNITS * src.one + run.amount,
            "the headroom must sit on top of the tracked cover"
        );

        assertEq(
            run.srcBefore.tracked,
            BRIDGE_UNITS * src.one,
            "a plain transfer in must never be tracked"
        );

        assertEq(
            run.srcBefore.book.year1,
            BRIDGE_UNITS * src.one,
            "the book must hold only the referred deposit"
        );

        run.dstBefore = _awayState(
            user,
            referrer
        );

        _assertUnassignedOn(
            dst,
            dstRegistry,
            user
        );

        assertEq(
            _nonzeroRingSlots(
                dst,
                referrer
            ),
            0,
            "destination rings must start empty"
        );

        _pinSource(
            run.srcAt
        );

        Vm.Log[] memory srcLogs;

        (
            run.sent,
            run.wire,
            srcLogs
        ) = _bridgeAndScrapeWithLogs(
            user,
            run.amount,
            ""
        );

        run.srcAfter = _sideState(
            src,
            user,
            referrer
        );

        assertEq(
            run.srcAfter.balance,
            BRIDGE_UNITS * src.one,
            "only the headroom may burn"
        );

        _assertSourceUntouched(
            run
        );

        _assertEmptyWire(
            run.wire,
            run.sent
        );

        assertEq(
            _countFrom(
                srcLogs,
                CohortContributionSynced.selector,
                src.diamond
            ),
            1,
            "only the parked headroom source clamps; the covered bridging user never does"
        );

        assertEq(
            _countFrom(
                srcLogs,
                CohortBookReduced.selector,
                src.diamond
            ),
            0,
            "no reduction may fire while the balance covers the tracked cover"
        );

        assertEq(
            _countFrom(
                srcLogs,
                CohortBridgeCarrySkipped.selector,
                src.diamond
            ),
            0,
            "a headroom bridge is not a skipped carry"
        );

        run.logs = _deliverAligned(
            run.sent,
            run.srcAt
        );

        run.dstAfter = _sideState(
            dst,
            user,
            referrer
        );

        _assertMinted(
            run
        );

        _assertConservation(
            run
        );

        _assertDestinationUntouched(
            run
        );

        _assertUnassignedOn(
            dst,
            dstRegistry,
            user
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

        _assertNoCarryOnDestination(
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

    function test_matrix_lazyDeficitPending_destroyedThenCarried()
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

        run.amount = DEFICIT_BRIDGE_UNITS * src.one;

        run.carried = _scaleToDst(
            run.amount
        );

        _onSrc();

        run.srcAt = _seedReferred(
            src,
            user,
            DEFICIT_TRACKED_UNITS * src.one,
            referrer
        );

        uint256 destroyed = DEFICIT_AWAY_UNITS * src.one;

        _transferAway(
            src,
            user,
            sink,
            destroyed
        );

        run.srcBefore = _sideState(
            src,
            user,
            referrer
        );

        assertEq(
            run.srcBefore.balance,
            DEFICIT_TRACKED_UNITS * src.one - destroyed,
            "the transfer away must lower the balance"
        );

        assertEq(
            run.srcBefore.tracked,
            DEFICIT_TRACKED_UNITS * src.one,
            "the deficit must stay lazy until the next touchpoint"
        );

        assertEq(
            run.srcBefore.book.year1,
            DEFICIT_TRACKED_UNITS * src.one,
            "the book must still hold the full cover before the touchpoint"
        );

        run.dstBefore = _awayState(
            user,
            referrer
        );

        _assertUnassignedOn(
            dst,
            dstRegistry,
            user
        );

        assertEq(
            _nonzeroRingSlots(
                dst,
                referrer
            ),
            0,
            "destination rings must start empty"
        );

        _pinSource(
            run.srcAt
        );

        Vm.Log[] memory srcLogs;

        (
            run.sent,
            run.wire,
            srcLogs
        ) = _bridgeAndScrapeWithLogs(
            user,
            run.amount,
            ""
        );

        run.srcAfter = _sideState(
            src,
            user,
            referrer
        );

        assertEq(
            run.srcAfter.balance,
            DEFICIT_TRACKED_UNITS * src.one - destroyed - run.amount,
            "the bridge must burn the bridged slice only"
        );

        assertEq(
            run.srcAfter.tracked,
            run.srcAfter.balance,
            "tracked must clamp to the remaining balance"
        );

        assertEq(
            run.srcAfter.book.year1,
            run.srcAfter.balance,
            "the book must keep exactly the remaining cover"
        );

        assertEq(
            run.srcAfter.ring1AtCredit,
            run.srcAfter.balance,
            "the credit slot must keep exactly the remaining cover"
        );

        _assertDeficitTrace(
            srcLogs,
            destroyed,
            run.amount
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

        run.logs = _deliverAligned(
            run.sent,
            run.srcAt
        );

        run.dstAfter = _sideState(
            dst,
            user,
            referrer
        );

        _assertMinted(
            run
        );

        _assertLandedOn(
            dst,
            referrer,
            run.carried,
            0
        );

        _assertArrivalLanes(
            run,
            run.carried,
            0,
            0
        );

        assertEq(
            run.srcBefore.book.year1 - run.srcAfter.book.year1,
            destroyed + run.amount,
            "the source book must lose the destroyed deficit plus the carried slice"
        );

        assertEq(
            run.dstAfter.book.year1 - run.dstBefore.book.year1,
            _scaleToDst(
                run.srcBefore.book.year1 - run.srcAfter.book.year1 - destroyed
            ),
            "the destroyed deficit must never reach the destination"
        );

        assertEq(
            run.srcBefore.tracked,
            run.srcAfter.tracked + destroyed + run.amount,
            "tracked must split into remaining, destroyed and carried"
        );

        assertEq(
            _scaleToDst(run.srcBefore.tracked - destroyed),
            _scaleToDst(run.srcAfter.tracked)
                + (run.dstAfter.tracked - run.dstBefore.tracked),
            "tracked must be conserved net of the destroyed deficit"
        );

        assertEq(
            run.srcAfter.book.year2 + run.srcAfter.book.mature,
            0,
            "no aged lane may move on the source"
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

    function test_matrix_unreferredUser_trackedOnlyCarry()
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

        _onSrc();

        _seedPlain(
            src,
            user,
            run.amount
        );

        run.srcAt = _clockOf(
            src
        );

        _assertUnassignedOn(
            src,
            srcRegistry,
            user
        );

        run.srcBefore = _sideState(
            src,
            user,
            referrer
        );

        assertEq(
            run.srcBefore.tracked,
            run.amount,
            "a plain deposit must still be tracked"
        );

        _assertBookZero(
            src,
            referrer,
            "an unreferred deposit must credit no source book"
        );

        run.dstBefore = _awayState(
            user,
            referrer
        );

        _assertUnassignedOn(
            dst,
            dstRegistry,
            user
        );

        assertEq(
            _nonzeroRingSlots(
                dst,
                referrer
            ),
            0,
            "destination rings must start empty"
        );

        _pinSource(
            run.srcAt
        );

        Vm.Log[] memory srcLogs;

        (
            run.sent,
            run.wire,
            srcLogs
        ) = _bridgeAndScrapeWithLogs(
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

        assertEq(
            _countFrom(
                srcLogs,
                CohortBookReduced.selector,
                src.diamond
            ),
            0,
            "no book may be reduced for an unreferred user"
        );

        assertEq(
            _countFrom(
                srcLogs,
                CohortContributionSynced.selector,
                src.diamond
            ),
            1,
            "the clamp must still fire once for an unreferred user"
        );

        _assertCarryWire(
            run.wire,
            run.sent,
            CarryExpect({
                referrer: address(0),
                assignedAt: 0,
                rank: 0,
                trackedDelta: run.carried,
                year1: 0,
                year2: 0,
                mature: 0
            })
        );

        run.logs = _deliverAligned(
            run.sent,
            run.srcAt
        );

        run.dstAfter = _sideState(
            dst,
            user,
            referrer
        );

        _assertMinted(
            run
        );

        _assertConservation(
            run
        );

        _assertArrivalLanes(
            run,
            0,
            0,
            0
        );

        _assertBookZero(
            dst,
            referrer,
            "an unreferred carry must credit no destination book"
        );

        assertEq(
            _nonzeroRingSlots(
                dst,
                referrer
            ),
            0,
            "no ring may move for an unreferred carry"
        );

        _assertUnassignedOn(
            dst,
            dstRegistry,
            user
        );

        _assertUnassignedOn(
            src,
            srcRegistry,
            user
        );

        _assertApplied(
            _findApplied(
                run.logs,
                run.sent
            ),
            AppliedExpect({
                effectiveReferrer: address(0),
                carriedReferrer: address(0),
                trackedDelta: run.carried,
                year1: 0,
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

    function test_matrix_fullBalance_bridgesEntireBook()
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

        run.amount = (FIRST_TRANCHE_UNITS + SECOND_TRANCHE_UNITS) * src.one;

        run.carried = _scaleToDst(
            run.amount
        );

        run.dstBefore = _awayState(
            user,
            referrer
        );

        _assertUnassignedOn(
            dst,
            dstRegistry,
            user
        );

        assertEq(
            _nonzeroRingSlots(
                dst,
                referrer
            ),
            0,
            "destination rings must start empty"
        );

        _onSrc();

        _seedReferred(
            src,
            holder,
            BYSTANDER_UNITS * src.one,
            referrer
        );

        run.srcAt = _seedReferred(
            src,
            user,
            FIRST_TRANCHE_UNITS * src.one,
            referrer
        );

        _pinSource(
            run.srcAt + CohortWeeks.WEEK
        );

        _seedReferred(
            src,
            user,
            SECOND_TRANCHE_UNITS * src.one,
            referrer
        );

        run.srcBefore = _sideState(
            src,
            user,
            referrer
        );

        assertEq(
            run.srcBefore.balance,
            run.amount,
            "both tranches must be held"
        );

        assertEq(
            run.srcBefore.tracked,
            run.amount,
            "both tranches must be tracked"
        );

        assertEq(
            run.srcBefore.book.year1,
            run.amount + BYSTANDER_UNITS * src.one,
            "the book must hold the user's and the bystander's cover"
        );

        assertEq(
            _nonzeroRingSlots(
                src,
                referrer
            ),
            2,
            "the two tranches must sit in two ring slots"
        );

        assertEq(
            run.srcBefore.ring1AtCredit,
            SECOND_TRANCHE_UNITS * src.one,
            "the current slot must hold the second tranche"
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

        assertEq(
            run.srcAfter.balance,
            0,
            "the full balance must burn"
        );

        assertEq(
            run.srcAfter.tracked,
            0,
            "the full tracked cover must leave"
        );

        assertEq(
            run.srcAfter.book.year1,
            BYSTANDER_UNITS * src.one,
            "only the bystander's cover may stay behind"
        );

        assertEq(
            run.srcAfter.book.year2 + run.srcAfter.book.mature,
            0,
            "no aged lane may exist on the source"
        );

        assertEq(
            run.srcAfter.ring1AtCredit,
            0,
            "the newest slot must drain first"
        );

        (
            uint256 olderSlotYear1,
        ) = _ringOn(
            src,
            referrer,
            _slotOf(
                run.srcAt
            )
        );

        assertEq(
            olderSlotYear1,
            BYSTANDER_UNITS * src.one,
            "the older slot must keep exactly the bystander's cover"
        );

        assertEq(
            _nonzeroRingSlots(
                src,
                referrer
            ),
            1,
            "one slot must survive holding the bystander's cover"
        );

        assertEq(
            _trackedOn(
                src,
                holder
            ),
            BYSTANDER_UNITS * src.one,
            "the bystander's tracked cover must not move"
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

        _pinSource(
            run.srcAt
        );

        run.logs = _deliverAligned(
            run.sent,
            run.srcAt
        );

        run.dstAfter = _sideState(
            dst,
            user,
            referrer
        );

        _assertMinted(
            run
        );

        _assertConservation(
            run
        );

        _assertLandedOn(
            dst,
            referrer,
            run.carried,
            0
        );

        _assertArrivalLanes(
            run,
            run.carried,
            0,
            0
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

    function test_matrix_agedYear2Cohort_landsInYear2Ring()
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

        run.dstBefore = _awayState(
            user,
            referrer
        );

        _assertUnassignedOn(
            dst,
            dstRegistry,
            user
        );

        assertEq(
            _nonzeroRingSlots(
                dst,
                referrer
            ),
            0,
            "destination rings must start empty"
        );

        _onSrc();

        run.srcAt = _seedReferred(
            src,
            user,
            run.amount,
            referrer
        );

        _pinSource(
            run.srcAt + YEAR2_AGE_WEEKS * CohortWeeks.WEEK
        );

        _advanceSourceBook(
            referrer
        );

        run.srcBefore = _sideState(
            src,
            user,
            referrer
        );

        assertEq(
            run.srcBefore.book.year1,
            0,
            "the cohort must have graduated out of the first-year lane"
        );

        assertEq(
            run.srcBefore.book.year2,
            run.amount,
            "the cohort must sit in the second-year lane"
        );

        assertEq(
            run.srcBefore.book.mature,
            0,
            "the cohort must not have matured yet"
        );

        (
            uint256 seedRing1,
            uint256 seedRing2
        ) = _ringOn(
            src,
            referrer,
            _slotOf(
                run.srcAt
            )
        );

        assertEq(
            seedRing1,
            0,
            "the seed slot must have rotated out of ring one"
        );

        assertEq(
            seedRing2,
            run.amount,
            "the seed slot must hold the cohort on ring two"
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

        assertEq(
            _nonzeroRingSlots(
                src,
                referrer
            ),
            0,
            "both source rings must drain"
        );

        _assertCarryWire(
            run.wire,
            run.sent,
            CarryExpect({
                referrer: referrer,
                assignedAt: run.srcAt,
                rank: _srcChainRank(),
                trackedDelta: run.carried,
                year1: 0,
                year2: run.carried,
                mature: 0
            })
        );

        _pinSource(
            run.srcAt
        );

        run.logs = _deliverAligned(
            run.sent,
            run.srcAt
        );

        run.dstAfter = _sideState(
            dst,
            user,
            referrer
        );

        _assertMinted(
            run
        );

        _assertConservation(
            run
        );

        _assertLandedOn(
            dst,
            referrer,
            0,
            run.carried
        );

        _assertArrivalLanes(
            run,
            0,
            run.carried,
            0
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
                year1: 0,
                year2: run.carried,
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

    function test_matrix_agedMatureCohort_landsOnMatureLaneNoRingWrite()
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

        run.dstBefore = _awayState(
            user,
            referrer
        );

        _assertUnassignedOn(
            dst,
            dstRegistry,
            user
        );

        assertEq(
            _nonzeroRingSlots(
                dst,
                referrer
            ),
            0,
            "destination rings must start empty"
        );

        _onSrc();

        run.srcAt = _seedReferred(
            src,
            user,
            run.amount,
            referrer
        );

        _pinSource(
            run.srcAt + MATURE_AGE_WEEKS * CohortWeeks.WEEK
        );

        _advanceSourceBook(
            referrer
        );

        run.srcBefore = _sideState(
            src,
            user,
            referrer
        );

        assertEq(
            run.srcBefore.book.year1,
            0,
            "the cohort must have left the first-year lane"
        );

        assertEq(
            run.srcBefore.book.year2,
            0,
            "the cohort must have left the second-year lane"
        );

        assertEq(
            run.srcBefore.book.mature,
            run.amount,
            "the cohort must have matured"
        );

        assertEq(
            _nonzeroRingSlots(
                src,
                referrer
            ),
            0,
            "a matured cohort leaves both rings empty"
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
                year1: 0,
                year2: 0,
                mature: run.carried
            })
        );

        _pinSource(
            run.srcAt
        );

        run.logs = _deliverAligned(
            run.sent,
            run.srcAt
        );

        run.dstAfter = _sideState(
            dst,
            user,
            referrer
        );

        _assertMinted(
            run
        );

        _assertConservation(
            run
        );

        _assertLandedOn(
            dst,
            referrer,
            0,
            0
        );

        _assertArrivalLanes(
            run,
            0,
            0,
            run.carried
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
                year1: 0,
                year2: 0,
                mature: run.carried
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

    function test_matrix_roundTrip_returnsToOrigin()
        public
    {
        if (_laneReady() == false) {

            vm.skip(
                true
            );

            return;
        }

        if (_reverseLaneScrapeSupported() == false) {

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

        run.dstBefore = _awayState(
            user,
            referrer
        );

        _assertUnassignedOn(
            dst,
            dstRegistry,
            user
        );

        assertEq(
            _nonzeroRingSlots(
                dst,
                referrer
            ),
            0,
            "away rings must start empty"
        );

        _onSrc();

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

        assertEq(
            _nonzeroRingSlots(
                src,
                referrer
            ),
            0,
            "the origin rings must drain on the way out"
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

        run.logs = _deliverAligned(
            run.sent,
            run.srcAt
        );

        run.dstAfter = _sideState(
            dst,
            user,
            referrer
        );

        _assertMinted(
            run
        );

        _assertConservation(
            run
        );

        _assertLandedOn(
            dst,
            referrer,
            run.carried,
            0
        );

        _assertArrivalLanes(
            run,
            run.carried,
            0,
            0
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

        RoundTrip memory trip;

        trip.returned = _scaleBackToSrc(
            run.carried
        );

        trip.awayClock = _lastSettleOn(
            dst,
            referrer
        );

        (
            trip.sentBack,
            trip.wireBack,
            trip.logsBack
        ) = _bridgeBackAligned(
            user,
            run.carried,
            trip.awayClock
        );

        trip.awayAfter = _awayState(
            user,
            referrer
        );

        trip.originAfter = _sideState(
            src,
            user,
            referrer
        );

        assertEq(
            trip.sentBack.dstAmount,
            trip.returned,
            "the return must scale back once"
        );

        assertEq(
            trip.returned,
            _scaleBackToSrc(
                _scaleToDst(
                    run.amount
                )
            ),
            "the origin must get back the amount scaled there and back once"
        );

        assertLe(
            trip.returned,
            run.amount,
            "the round trip can only lose the scaling dust"
        );

        _assertCarryWire(
            trip.wireBack,
            trip.sentBack,
            CarryExpect({
                referrer: referrer,
                assignedAt: run.srcAt,
                rank: _srcChainRank(),
                trackedDelta: trip.returned,
                year1: trip.returned,
                year2: 0,
                mature: 0
            })
        );

        assertEq(
            trip.awayAfter.balance,
            0,
            "the away side must burn the returned shares"
        );

        assertEq(
            trip.awayAfter.tracked,
            0,
            "the away side must clamp its tracked cover to zero"
        );

        assertEq(
            trip.awayAfter.book.year1 + trip.awayAfter.book.year2 + trip.awayAfter.book.mature,
            0,
            "the away book must be fully carried back"
        );

        assertEq(
            _nonzeroRingSlots(
                dst,
                referrer
            ),
            0,
            "the away rings must drain"
        );

        assertEq(
            trip.originAfter.balance,
            trip.returned,
            "the origin must mint the returned amount"
        );

        assertEq(
            trip.originAfter.tracked,
            trip.returned,
            "the origin tracked cover must be the returned amount and never doubled"
        );

        assertEq(
            trip.originAfter.book.year1,
            trip.returned,
            "the origin book must hold the returned slice exactly once"
        );

        assertEq(
            trip.originAfter.book.year2 + trip.originAfter.book.mature,
            0,
            "the round trip must not age the cohort"
        );

        _assertLandedOn(
            src,
            referrer,
            trip.returned,
            0
        );

        assertEq(
            trip.originAfter.tracked + trip.awayAfter.tracked,
            trip.returned,
            "no tracked cover may be doubled across the round trip"
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

        _assertRegistrySilentOn(
            trip.logsBack,
            srcRegistry
        );

        _assertApplied(
            _findApplied(
                trip.logsBack,
                trip.sentBack
            ),
            AppliedExpect({
                effectiveReferrer: referrer,
                carriedReferrer: referrer,
                trackedDelta: trip.returned,
                year1: trip.returned,
                year2: 0,
                mature: 0
            })
        );

        _assertNoDegrade(
            trip.logsBack,
            trip.sentBack
        );
    }
}

contract CohortBridgeMatrixUsdcMainnetBaseForkStates is CohortBridgeAttributionMatrixForkGroupB {

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

contract CohortBridgeMatrixUsdcBaseArbitrumForkStates is CohortBridgeAttributionMatrixForkGroupB {

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

contract CohortBridgeMatrixUsdgMainnetRobinhoodForkStates is CohortBridgeAttributionMatrixForkGroupB {

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

contract CohortBridgeMatrixUsdgArbitrumMainnetForkStates is CohortBridgeAttributionMatrixForkGroupB {

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
