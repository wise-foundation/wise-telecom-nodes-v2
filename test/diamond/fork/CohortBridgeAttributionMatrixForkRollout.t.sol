// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {ICcipBridgeVault} from "./utils/CcipForkInterfaces.sol";
import {IWtnCarryVault} from "./CcipCarryUpgradeRehearsalFork.t.sol";
import {
    CohortBridgeAttributionMatrixForkBase,
    IWtnMatrixVault
} from "./CohortBridgeAttributionMatrixFork.t.sol";

import {FacetNotFound} from "../../../src/diamond/shared/DiamondErrors.sol";
import {WiseTelecomNodesDiamondErrors} from "../../../src/diamond/vault/WiseTelecomNodesDiamondErrors.sol";

import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev The one genesis-reachable read the rollout group needs beyond
 * the matrix surfaces: the legacy referral surfacing switch is a
 * public auto-getter compiled into the diamond entry contract at
 * genesis, so it resolves on live bytecode before any facet
 * replacement and proves the switch flip on a fork that never
 * received the cohort round.
 */
interface IWtnRolloutVault {

    function referralEnabled()
        external
        view
        returns (bool);
}

/**
 * @dev Rollout-state group of the cross-chain attribution matrix.
 * The inherited setUp installs and arms the cohort round on both
 * forks, so a side that must run LIVE GENESIS bytecode is obtained
 * by forking the same chain a second time: the fresh fork carries
 * the untouched routing table, the untouched transfer hook and no
 * registry, and its fork id replaces the installed one in the lane
 * context for the scenario. Genesis is proven, never assumed: the
 * cohort switch getter and the registry pointer getter must both
 * miss the routing table before the side is used, and the installed
 * fork id is kept so a scenario can return to it.
 *
 * Rollout states pinned, each over a real CCIP lane:
 *   1. both sides genesis: the wire is the caller's bytes, verbatim,
 *      whether empty, junk or shaped exactly like a carry, because
 *      the live bytecode has no shape guard; the destination mints
 *      the full amount and surfaces nonempty bytes through the
 *      legacy event only. The shape guard lives in the replacement
 *      bridge facet alone, which the same scenario pins on the
 *      installed source with the switch off;
 *   2. armed source, genesis destination: the source removes the
 *      slice and sends the carry, the destination mints the full
 *      amount, cannot apply, and surfaces the carry bytes through
 *      the legacy event; the loss is exactly the carried slice;
 *   3. genesis source, armed destination: no carry exists, the mint
 *      lands as untracked headroom, no recorder state moves;
 *   4. genesis source, armed destination, forged carry: the live
 *      bytecode forwards a caller-built carry naming a stranger and
 *      the armed destination applies it, book credit priced one to
 *      one in burned shares. This is the window the operator order
 *      of replacing every bridge facet before arming any chain
 *      exists to close. Under the genesis bridge gas budget the
 *      apply runs out of gas inside the receiver, so the off-ramp
 *      reports a receiver error with empty data and the bridge is
 *      stranded with the shares burned on the source and nothing
 *      minted. Once the genesis source master raises its bridge gas
 *      limit to the armed budget, the same forged carry lands in
 *      full;
 *   5. both armed, destination registry pointer zeroed after arming
 *      (the pointer change accepts zero and leaves the switch on):
 *      the tracked delta lands, the book is dropped with the
 *      documented event, the legacy event stays silent, and a fresh
 *      arm attempt is refused without the pointer;
 *   6. a three lane book bridges and is delivered through the real
 *      off-ramp under the armed budget, with the routing gas logged.
 *
 * The three lane book is aged on the source by weekly warps between
 * referred deposits; before the bridge the live fee quoter is probed
 * and the source clock is rewound to the start of the aging if the
 * aged clock would trip a gas price staleness guard. The recorder
 * tolerates a clock that moves back (settle records nothing and
 * re-stamps), and the ring walk covers every slot, so the captured
 * lanes are the same either way. Assertion discipline follows the
 * matrix base; where attribution is lost, the loss is asserted
 * exactly and nothing is doubled.
 */
abstract contract CohortBridgeAttributionMatrixForkGroupC is CohortBridgeAttributionMatrixForkBase {

    struct GenesisRun {
        uint256 amount;
        uint256 carried;
        uint256 dstBalanceBefore;
        uint256 dstSupplyBefore;
        SentMessage sent;
        WireCapture wire;
        Vm.Log[] logs;
    }

    struct BookDroppedCapture {
        bool found;
        address carriedReferrer;
        uint256 year1;
        uint256 year2;
        uint256 mature;
    }

    struct LaneExpect {
        uint256 year1;
        uint256 year2;
        uint256 mature;
        uint256 total;
    }

    event CohortBridgeHookFailed(
        address indexed user,
        uint64 indexed srcChainSelector
    );

    error ReceiverError(bytes err);

    uint256 internal constant MATURE_UNITS = 1_000;

    uint256 internal constant SECOND_YEAR_UNITS = 700;

    uint256 internal constant FIRST_YEAR_UNITS = 300;

    uint256 internal constant LANE_AGE = 53 weeks;

    uint256 internal constant FORGED_ASSIGNED_AT = 1;

    uint256 internal constant FORGED_RANK = 0;

    uint256 internal installedSrcFork;

    uint256 internal installedDstFork;

    // ---- genesis sides ----

    function _genesisSource()
        internal
    {
        installedSrcFork = src.forkId;

        LaneCfg memory cfg = _laneConfig();

        _genesisSide(
            src,
            cfg.srcRpc
        );
    }

    function _genesisDestination()
        internal
    {
        installedDstFork = dst.forkId;

        LaneCfg memory cfg = _laneConfig();

        _genesisSide(
            dst,
            cfg.dstRpc
        );
    }

    function _genesisSide(
        ChainCtx storage _ctx,
        string memory _rpc
    )
        internal
    {
        vm.selectFork(
            _ctx.forkId
        );

        uint256 installedBlock = block.number;

        _ctx.forkId = vm.createFork(
            _rpc
        );

        vm.selectFork(
            _ctx.forkId
        );

        console2.log(
            "genesis side forked (installed fork block, genesis fork block):",
            installedBlock,
            block.number
        );

        _assertGenesisRouting(
            _ctx
        );
    }

    function _assertGenesisRouting(
        ChainCtx storage _ctx
    )
        internal
    {
        vm.selectFork(
            _ctx.forkId
        );

        IWtnCarryVault v = IWtnCarryVault(
            _ctx.diamond
        );

        vm.expectRevert(
            FacetNotFound.selector
        );

        v.getCohortSyncEnabled();

        vm.expectRevert(
            FacetNotFound.selector
        );

        v.getReferralRegistry();

        assertTrue(
            _ctx.diamond.code.length > 0,
            "genesis diamond must be deployed on the fresh fork"
        );
    }

    function _enableLegacyReferral(
        ChainCtx storage _ctx
    )
        internal
    {
        vm.selectFork(
            _ctx.forkId
        );

        vm.prank(
            _ctx.master
        );

        IWtnMatrixVault(_ctx.diamond).setReferralEnabled(
            true
        );

        assertTrue(
            IWtnRolloutVault(_ctx.diamond).referralEnabled(),
            "legacy referral surfacing must be switched on"
        );
    }

    // ---- registry pointer ----

    function _zeroDestinationRegistry()
        internal
    {
        _onDst();

        IWtnCarryVault v = IWtnCarryVault(
            dst.diamond
        );

        uint256 queuedAt = block.timestamp;

        vm.prank(
            dst.master
        );

        v.proposeReferralRegistry(
            address(0)
        );

        vm.prank(
            dst.master
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.ReferralRegistryTimelockNotElapsed.selector
        );

        v.executeReferralRegistryChange();

        vm.warp(
            queuedAt + 3 days + 1
        );

        vm.prank(
            dst.master
        );

        v.executeReferralRegistryChange();

        vm.warp(
            queuedAt + 2
        );

        assertEq(
            v.getReferralRegistry(),
            address(0),
            "registry pointer must be zeroed"
        );

        assertTrue(
            v.getCohortSyncEnabled(),
            "zeroing the registry pointer must leave cohort sync armed"
        );
    }

    function _assertRearmRequiresRegistry()
        internal
    {
        _onDst();

        IWtnCarryVault v = IWtnCarryVault(
            dst.diamond
        );

        vm.prank(
            dst.master
        );

        v.setCohortSyncEnabled(
            false
        );

        vm.prank(
            dst.master
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.ReferralRegistryNotSet.selector
        );

        v.setCohortSyncEnabled(
            true
        );

        assertFalse(
            v.getCohortSyncEnabled(),
            "arming without the registry pointer must be refused"
        );
    }

    // ---- three lane seed ----

    function _laneExpect(
        uint256 _year1,
        uint256 _year2,
        uint256 _mature
    )
        internal
        view
        returns (LaneExpect memory expect)
    {
        expect.year1 = _scaleToDst(
            _year1
        );

        expect.year2 = _scaleToDst(
            _year2
        );

        expect.mature = _scaleToDst(
            _mature
        );

        expect.total = expect.year1 + expect.year2 + expect.mature;
    }

    function _seedThreeLanes(
        address _who,
        address _referrer,
        Book memory _lanes
    )
        internal
        returns (uint256 seededAt)
    {
        _onSrc();

        uint256 startClock = block.timestamp;

        seededAt = _seedReferred(
            src,
            _who,
            _lanes.mature,
            _referrer
        );

        _onSrc();

        vm.warp(
            block.timestamp + LANE_AGE
        );

        _seedReferred(
            src,
            _who,
            _lanes.year2,
            _referrer
        );

        _onSrc();

        vm.warp(
            block.timestamp + LANE_AGE
        );

        _seedReferred(
            src,
            _who,
            _lanes.year1,
            _referrer
        );

        Book memory book = _bookOn(
            src,
            _referrer
        );

        assertEq(
            book.year1,
            _lanes.year1,
            "aged seed must leave the youngest deposit in the first-year lane"
        );

        assertEq(
            book.year2,
            _lanes.year2,
            "aged seed must graduate the middle deposit to the second-year lane"
        );

        assertEq(
            book.mature,
            _lanes.mature,
            "aged seed must mature the oldest deposit"
        );

        _settleSourceClockForBridge(
            startClock,
            _lanes.year1 + _lanes.year2 + _lanes.mature
        );
    }

    function _settleSourceClockForBridge(
        uint256 _startClock,
        uint256 _amount
    )
        internal
    {
        _onSrc();

        try ICcipBridgeVault(src.diamond).quoteBridgeFeeWithReferral(
            dst.chainSelector,
            _amount,
            ""
        ) returns (uint256) {
            return;
        } catch {
            vm.warp(
                _startClock + 90
            );
        }
    }

    // ---- forged carry ----

    function _forgedCarry(
        uint256 _carried
    )
        internal
        view
        returns (bytes memory forged)
    {
        forged = CohortWeeks.packBridgeCarry(
            CohortWeeks.packBridgeCarryEnvelope(
                forger
            ),
            CohortWeeks.packBridgeCarryTracked(
                _carried,
                FORGED_ASSIGNED_AT,
                FORGED_RANK
            ),
            CohortWeeks.packCarryPairsWord(
                _carried,
                0
            ),
            0
        );

        assertTrue(
            CohortWeeks.bridgeCarryValid(
                forged,
                _carried
            ),
            "forged payload must be structurally valid against the mint"
        );
    }

    // ---- log readers ----

    function _findBridgeReferral(
        Vm.Log[] memory _logs,
        SentMessage memory _sent
    )
        internal
        pure
        returns (
            bool found,
            bytes memory referralData
        )
    {
        for (uint256 i; i < _logs.length; ++i) {

            if (_logs[i].topics.length != 4) {
                continue;
            }

            if (_logs[i].topics[0] != BridgeReferral.selector) {
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

            if (_logs[i].topics[3] != _sent.messageId) {
                continue;
            }

            found = true;

            referralData = abi.decode(
                _logs[i].data,
                (bytes)
            );

            return (
                found,
                referralData
            );
        }
    }

    function _findBookDropped(
        Vm.Log[] memory _logs,
        SentMessage memory _sent
    )
        internal
        pure
        returns (BookDroppedCapture memory dropped)
    {
        for (uint256 i; i < _logs.length; ++i) {

            if (_logs[i].topics.length != 3) {
                continue;
            }

            if (_logs[i].topics[0] != CohortBridgeCarryBookDropped.selector) {
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

            dropped.found = true;

            (
                dropped.carriedReferrer,
                dropped.year1,
                dropped.year2,
                dropped.mature
            ) = abi.decode(
                _logs[i].data,
                (address, uint256, uint256, uint256)
            );

            return dropped;
        }
    }

    // ---- assertions ----

    function _assertPassthroughWire(
        WireCapture memory _wire,
        SentMessage memory _sent,
        bytes memory _referralData
    )
        internal
        pure
    {
        assertFalse(
            _wire.carryFound,
            "genesis source must never build a carry"
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
            _referralData.length,
            "genesis source must forward the caller byte count verbatim"
        );

        assertEq(
            keccak256(_wire.referralData),
            keccak256(_referralData),
            "genesis source must forward the caller bytes verbatim"
        );
    }

    function _assertGenesisMint(
        GenesisRun memory _run
    )
        internal
    {
        _onDst();

        ICcipBridgeVault vault = ICcipBridgeVault(
            dst.diamond
        );

        assertEq(
            vault.balanceOf(user) - _run.dstBalanceBefore,
            _run.sent.dstAmount,
            "destination must mint the bridged amount"
        );

        assertEq(
            vault.totalSupply() - _run.dstSupplyBefore,
            _run.sent.dstAmount,
            "destination supply must grow by exactly the mint"
        );

        assertEq(
            _run.sent.dstAmount,
            _run.carried,
            "minted amount must be the lane-scaled bridge amount"
        );

        assertTrue(
            vault.processedMessageId(_run.sent.messageId),
            "message not marked processed on the destination"
        );
    }

    function _assertDestinationRecorderSilent(
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
            "no carry may apply on this destination"
        );

        assertEq(
            _countFrom(
                _logs,
                CohortBridgeCarryDiscarded.selector,
                _sent.dstDiamond
            ),
            0,
            "no carry may be discarded on this destination"
        );

        assertEq(
            _countFrom(
                _logs,
                CohortBridgeCarryBookDropped.selector,
                _sent.dstDiamond
            ),
            0,
            "no carry book may be dropped on this destination"
        );

        assertEq(
            _countFrom(
                _logs,
                CohortBridgeHookFailed.selector,
                _sent.dstDiamond
            ),
            0,
            "the bridge hook must not report a failure on this destination"
        );
    }

    function _assertSurfaced(
        Vm.Log[] memory _logs,
        SentMessage memory _sent,
        bytes memory _expected
    )
        internal
        pure
    {
        (
            bool surfaced,
            bytes memory surfacedData
        ) = _findBridgeReferral(
            _logs,
            _sent
        );

        assertTrue(
            surfaced,
            "legacy bridge-referral event must surface the wire bytes"
        );

        assertEq(
            surfacedData.length,
            _expected.length,
            "surfaced byte count mismatch"
        );

        assertEq(
            keccak256(surfacedData),
            keccak256(_expected),
            "surfaced bytes must equal the wire bytes"
        );

        assertEq(
            _countFrom(
                _logs,
                BridgeReferral.selector,
                _sent.dstDiamond
            ),
            1,
            "exactly one legacy surfacing per delivery"
        );
    }

    function _assertNotSurfaced(
        Vm.Log[] memory _logs,
        SentMessage memory _sent,
        string memory _message
    )
        internal
        pure
    {
        (
            bool surfaced,
        ) = _findBridgeReferral(
            _logs,
            _sent
        );

        assertFalse(
            surfaced,
            _message
        );
    }

    function _assertDestinationBookUntouched(
        Run memory _run
    )
        internal
        pure
    {
        assertEq(
            _run.dstAfter.book.year1,
            _run.dstBefore.book.year1,
            "destination first-year lane must not move"
        );

        assertEq(
            _run.dstAfter.book.year2,
            _run.dstBefore.book.year2,
            "destination second-year lane must not move"
        );

        assertEq(
            _run.dstAfter.book.mature,
            _run.dstBefore.book.mature,
            "destination mature lane must not move"
        );

        assertEq(
            _run.dstAfter.ring1AtLand,
            _run.dstBefore.ring1AtLand,
            "destination landing slot must not move on the first-year ring"
        );

        assertEq(
            _run.dstAfter.ring2AtLand,
            _run.dstBefore.ring2AtLand,
            "destination landing slot must not move on the second-year ring"
        );

        assertEq(
            _run.dstAfter.ring1AtCredit,
            _run.dstBefore.ring1AtCredit,
            "destination credit slot must not move"
        );
    }

    function _assertThreeLaneLanded(
        Run memory _run,
        LaneExpect memory _expect
    )
        internal
        pure
    {
        assertEq(
            _run.dstAfter.ring1AtLand - _run.dstBefore.ring1AtLand,
            _expect.year1,
            "first-year aggregate must land one week ahead on the first-year ring"
        );

        assertEq(
            _run.dstAfter.ring2AtLand - _run.dstBefore.ring2AtLand,
            _expect.year2,
            "second-year aggregate must land one week ahead on the second-year ring"
        );

        assertEq(
            _run.dstAfter.ring1AtCredit,
            _run.dstBefore.ring1AtCredit,
            "destination credit slot must not move on arrival"
        );

        assertEq(
            _run.dstAfter.book.year1 - _run.dstBefore.book.year1,
            _expect.year1,
            "first-year lane must gain the carried aggregate"
        );

        assertEq(
            _run.dstAfter.book.year2 - _run.dstBefore.book.year2,
            _expect.year2,
            "second-year lane must gain the carried aggregate"
        );

        assertEq(
            _run.dstAfter.book.mature - _run.dstBefore.book.mature,
            _expect.mature,
            "mature lane must gain the carried aggregate"
        );

        assertEq(
            _run.dstAfter.tracked - _run.dstBefore.tracked,
            _expect.total,
            "destination tracked must grow by the carried lane sum"
        );
    }

    // ---- genesis passthrough leg ----

    function _passthroughLeg(
        GenesisRun memory _run,
        bytes memory _referralData
    )
        internal
    {
        _seedPlain(
            src,
            user,
            _run.amount
        );

        assertEq(
            _balanceOn(
                src,
                user
            ),
            _run.amount,
            "genesis source seed must hold exactly the bridge amount"
        );

        _run.dstBalanceBefore = _balanceOn(
            dst,
            user
        );

        _run.dstSupplyBefore = ICcipBridgeVault(dst.diamond).totalSupply();

        (
            _run.sent,
            _run.wire
        ) = _bridgeAndScrape(
            user,
            _run.amount,
            _referralData
        );

        _assertPassthroughWire(
            _run.wire,
            _run.sent,
            _referralData
        );

        assertEq(
            _balanceOn(
                src,
                user
            ),
            0,
            "genesis source must burn the bridged shares"
        );

        _run.logs = _deliver(
            _run.sent
        );

        _assertGenesisMint(
            _run
        );

        _assertDestinationRecorderSilent(
            _run.logs,
            _run.sent
        );

        if (_referralData.length == 0) {

            _assertNotSurfaced(
                _run.logs,
                _run.sent,
                "empty wire bytes must not surface"
            );

            return;
        }

        _assertSurfaced(
            _run.logs,
            _run.sent,
            _referralData
        );
    }

    function _assertInstalledUnarmedSourceRejectsCarryShape(
        uint256 _amount,
        bytes memory _forged
    )
        internal
    {
        src.forkId = installedSrcFork;

        _setArmed(
            src,
            false
        );

        _seedPlain(
            src,
            user,
            _amount
        );

        _onSrc();

        ICcipBridgeVault vault = ICcipBridgeVault(
            src.diamond
        );

        uint256 fee = vault.quoteBridgeFeeWithReferral(
            dst.chainSelector,
            _amount,
            _forged
        );

        vm.deal(
            user,
            fee
        );

        vm.prank(
            user
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.ReferralDataReserved.selector
        );

        vault.bridgeToVaultWithReferral{value: fee}(
            dst.chainSelector,
            _amount,
            _forged
        );

        assertEq(
            _balanceOn(
                src,
                user
            ),
            _amount,
            "rejected bridge must leave the shares in place"
        );
    }

    // ---- stranded delivery ----

    function deliverForTest(
        SentMessage memory _sent
    )
        external
    {
        require(
            msg.sender == address(this),
            "self-call only"
        );

        _deliver(
            _sent
        );
    }

    function _deliverExpectingReceiverError(
        SentMessage memory _sent
    )
        internal
        returns (bytes memory inner)
    {
        try this.deliverForTest(
            _sent
        ) {
            fail(
                "delivery must fail at the off-ramp under the genesis bridge gas budget"
            );
        } catch (bytes memory reason) {
            inner = _receiverErrorInner(
                reason
            );
        }
    }

    function _receiverErrorInner(
        bytes memory _reason
    )
        internal
        pure
        returns (bytes memory inner)
    {
        assertGe(
            _reason.length,
            4,
            "revert payload must carry a selector"
        );

        assertEq(
            bytes32(bytes4(_reason)),
            bytes32(ReceiverError.selector),
            "delivery must fail with the off-ramp receiver error"
        );

        bytes memory tail = new bytes(
            _reason.length - 4
        );

        for (uint256 i = 4; i < _reason.length; ++i) {
            tail[i - 4] = _reason[i];
        }

        inner = abi.decode(
            tail,
            (bytes)
        );
    }

    // ---- scenarios ----

    function test_rollout_unarmedToUnarmed_legacyPassthroughOnly()
        public
    {
        if (_laneReady() == false) {

            vm.skip(
                true
            );

            return;
        }

        _genesisSource();

        _genesisDestination();

        _enableLegacyReferral(
            dst
        );

        GenesisRun memory run;

        run.amount = BRIDGE_UNITS * src.one;

        run.carried = _scaleToDst(
            run.amount
        );

        _passthroughLeg(
            run,
            ""
        );

        _passthroughLeg(
            run,
            _junkBytes()
        );

        bytes memory forged = _forgedCarry(
            run.carried
        );

        _passthroughLeg(
            run,
            forged
        );

        _assertInstalledUnarmedSourceRejectsCarryShape(
            run.amount,
            forged
        );
    }

    function test_rollout_armedSourceUnarmedDestination_attributionLostConservatively()
        public
    {
        if (_laneReady() == false) {

            vm.skip(
                true
            );

            return;
        }

        _genesisDestination();

        _setArmed(
            src,
            true
        );

        _enableLegacyReferral(
            dst
        );

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

        GenesisRun memory genesis;

        genesis.amount = run.amount;

        genesis.carried = run.carried;

        genesis.dstBalanceBefore = _balanceOn(
            dst,
            user
        );

        genesis.dstSupplyBefore = ICcipBridgeVault(dst.diamond).totalSupply();

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

        genesis.sent = run.sent;

        _assertGenesisMint(
            genesis
        );

        _assertDestinationRecorderSilent(
            run.logs,
            run.sent
        );

        _assertSurfaced(
            run.logs,
            run.sent,
            run.wire.referralData
        );

        assertEq(
            run.srcBefore.book.year1 - run.srcAfter.book.year1,
            run.amount,
            "the loss must be exactly the carried slice"
        );

        assertEq(
            run.srcBefore.book.year2,
            run.srcAfter.book.year2,
            "second-year lane must not move on the source"
        );

        assertEq(
            run.srcBefore.book.mature,
            run.srcAfter.book.mature,
            "mature lane must not move on the source"
        );

        assertEq(
            run.srcBefore.tracked - run.srcAfter.tracked,
            run.amount,
            "tracked cover lost on the source must equal the bridged amount"
        );

        assertEq(
            _nonzeroRingSlots(
                src,
                referrer
            ),
            0,
            "source rings must be empty after the whole cover left"
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
    }

    function test_rollout_unarmedSourceArmedDestination_landsUntracked()
        public
    {
        if (_laneReady() == false) {

            vm.skip(
                true
            );

            return;
        }

        _genesisSource();

        _setArmed(
            dst,
            true
        );

        _enableLegacyReferral(
            dst
        );

        _onSrc();

        console2.log(
            "genesis source bridge gas limit (zero means the 200k default):",
            uint256(ICcipBridgeVault(src.diamond).bridgeGasLimit())
        );

        Run memory run;

        run.amount = BRIDGE_UNITS * src.one;

        run.carried = _scaleToDst(
            run.amount
        );

        _seedPlain(
            src,
            user,
            run.amount
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

        _assertPassthroughWire(
            run.wire,
            run.sent,
            ""
        );

        assertEq(
            _balanceOn(
                src,
                user
            ),
            0,
            "genesis source must burn the bridged shares"
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

        assertEq(
            run.dstAfter.tracked,
            run.dstBefore.tracked,
            "a genesis source carries no tracked cover"
        );

        assertEq(
            run.dstAfter.balance - run.dstAfter.tracked,
            run.dstBefore.balance - run.dstBefore.tracked + run.carried,
            "the mint must land as untracked headroom"
        );

        _assertDestinationBookUntouched(
            run
        );

        _assertBookZero(
            dst,
            referrer,
            "destination referrer book must stay empty"
        );

        _assertUnassignedOn(
            dst,
            dstRegistry,
            user
        );

        _assertDestinationRecorderSilent(
            run.logs,
            run.sent
        );

        _assertNotSurfaced(
            run.logs,
            run.sent,
            "empty wire bytes must not surface"
        );

        _assertRegistryCounts(
            run.logs,
            0,
            0,
            0,
            0
        );
    }

    function test_rollout_unarmedSourceArmedDestination_forgedCarryStrandsUnderGenesisGas()
        public
    {
        if (_laneReady() == false) {

            vm.skip(
                true
            );

            return;
        }

        _genesisSource();

        _setArmed(
            dst,
            true
        );

        _enableLegacyReferral(
            dst
        );

        _onSrc();

        assertEq(
            uint256(ICcipBridgeVault(src.diamond).bridgeGasLimit()),
            0,
            "genesis source must still stamp the 200k default bridge gas budget"
        );

        Run memory run;

        run.amount = BRIDGE_UNITS * src.one;

        run.carried = _scaleToDst(
            run.amount
        );

        bytes memory forged = _forgedCarry(
            run.carried
        );

        _seedPlain(
            src,
            user,
            run.amount
        );

        run.dstBefore = _dstState(
            user,
            forger
        );

        _assertUnassignedOn(
            dst,
            dstRegistry,
            user
        );

        _assertBookZero(
            dst,
            forger,
            "forged referrer must start with no destination book"
        );

        (
            run.sent,
            run.wire
        ) = _bridgeAndScrape(
            user,
            run.amount,
            forged
        );

        _assertPassthroughWire(
            run.wire,
            run.sent,
            forged
        );

        assertEq(
            _balanceOn(
                src,
                user
            ),
            0,
            "genesis source must burn the bridged shares"
        );

        bytes memory inner = _deliverExpectingReceiverError(
            run.sent
        );

        assertEq(
            inner.length,
            0,
            "an out of gas apply must surface as a receiver error with empty data"
        );

        run.dstAfter = _dstState(
            user,
            forger
        );

        assertEq(
            run.dstAfter.balance,
            run.dstBefore.balance,
            "a stranded bridge must mint nothing on the destination"
        );

        assertEq(
            run.dstAfter.tracked,
            run.dstBefore.tracked,
            "a stranded bridge must move no tracked cover"
        );

        _assertDestinationBookUntouched(
            run
        );

        _assertBookZero(
            dst,
            forger,
            "a stranded forged carry must leave the forged referrer without a book"
        );

        _assertUnassignedOn(
            dst,
            dstRegistry,
            user
        );

        _onDst();

        assertFalse(
            ICcipBridgeVault(dst.diamond).processedMessageId(run.sent.messageId),
            "a stranded message must not be marked processed on the destination"
        );

        assertEq(
            _balanceOn(
                src,
                user
            ),
            0,
            "the burned shares stay burned while the bridge is stranded"
        );
    }

    function test_rollout_unarmedSourceArmedDestination_forgedCarryAppliesOnceGasRaised()
        public
    {
        if (_laneReady() == false) {

            vm.skip(
                true
            );

            return;
        }

        _genesisSource();

        _setArmed(
            dst,
            true
        );

        _enableLegacyReferral(
            dst
        );

        _raiseBridgeGasLimit(
            src,
            4_000_000
        );

        assertEq(
            uint256(ICcipBridgeVault(src.diamond).bridgeGasLimit()),
            4_000_000,
            "genesis source must stamp the raised bridge gas budget"
        );

        Run memory run;

        run.amount = BRIDGE_UNITS * src.one;

        run.carried = _scaleToDst(
            run.amount
        );

        bytes memory forged = _forgedCarry(
            run.carried
        );

        _seedPlain(
            src,
            user,
            run.amount
        );

        run.dstBefore = _dstState(
            user,
            forger
        );

        _assertUnassignedOn(
            dst,
            dstRegistry,
            user
        );

        _assertBookZero(
            dst,
            forger,
            "forged referrer must start with no destination book"
        );

        (
            run.sent,
            run.wire
        ) = _bridgeAndScrape(
            user,
            run.amount,
            forged
        );

        _assertPassthroughWire(
            run.wire,
            run.sent,
            forged
        );

        run.logs = _deliver(
            run.sent
        );

        run.dstAfter = _dstState(
            user,
            forger
        );

        _assertMinted(
            run
        );

        _assertLanded(
            run
        );

        assertEq(
            run.dstAfter.book.year1 - run.dstBefore.book.year1,
            run.carried,
            "forged first-year credit must land under the forged referrer"
        );

        _assertRegistryOn(
            dst,
            dstRegistry,
            user,
            RegistryExpect({
                referrer: forger,
                assignedAt: FORGED_ASSIGNED_AT,
                rank: FORGED_RANK,
                pending: address(0)
            })
        );

        _assertApplied(
            _findApplied(
                run.logs,
                run.sent
            ),
            AppliedExpect({
                effectiveReferrer: forger,
                carriedReferrer: forger,
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

    function test_rollout_armedBothButDestinationRegistryUnwired_bookDropped()
        public
    {
        if (_laneReady() == false) {

            vm.skip(
                true
            );

            return;
        }

        _prepareLane();

        _zeroDestinationRegistry();

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

        assertEq(
            run.dstAfter.tracked - run.dstBefore.tracked,
            run.carried,
            "the tracked delta must land even though the book is dropped"
        );

        _assertDestinationBookUntouched(
            run
        );

        _assertBookZero(
            dst,
            referrer,
            "dropped book must leave the carried referrer empty"
        );

        _assertUnassignedOn(
            dst,
            dstRegistry,
            user
        );

        BookDroppedCapture memory dropped = _findBookDropped(
            run.logs,
            run.sent
        );

        assertTrue(
            dropped.found,
            "CohortBridgeCarryBookDropped not emitted on the destination"
        );

        assertEq(
            dropped.carriedReferrer,
            referrer,
            "dropped carried referrer mismatch"
        );

        assertEq(
            dropped.year1,
            run.carried,
            "dropped first-year lane mismatch"
        );

        assertEq(
            dropped.year2,
            0,
            "dropped second-year lane mismatch"
        );

        assertEq(
            dropped.mature,
            0,
            "dropped mature lane mismatch"
        );

        assertEq(
            _countFrom(
                run.logs,
                CohortBridgeCarryBookDropped.selector,
                run.sent.dstDiamond
            ),
            1,
            "exactly one book drop per delivery"
        );

        assertFalse(
            _findApplied(
                run.logs,
                run.sent
            ).found,
            "a dropped carry must not report as applied"
        );

        assertEq(
            _countFrom(
                run.logs,
                CohortBridgeCarryDiscarded.selector,
                run.sent.dstDiamond
            ),
            0,
            "a valid carry must not be discarded"
        );

        assertEq(
            _countFrom(
                run.logs,
                CohortBridgeHookFailed.selector,
                run.sent.dstDiamond
            ),
            0,
            "the bridge hook must not report a failure"
        );

        _assertNotSurfaced(
            run.logs,
            run.sent,
            "a consumed carry must silence the legacy surfacing even while enabled"
        );

        assertEq(
            _scaleToDst(run.srcBefore.book.year1 - run.srcAfter.book.year1),
            run.carried,
            "the source must have lost exactly the carried slice"
        );

        assertEq(
            _scaleToDst(run.srcBefore.tracked),
            _scaleToDst(run.srcAfter.tracked)
                + (run.dstAfter.tracked - run.dstBefore.tracked),
            "tracked cover must be conserved across the lane"
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

        _assertRegistryCounts(
            run.logs,
            0,
            0,
            0,
            0
        );

        _assertRearmRequiresRegistry();
    }

    function test_rollout_maxCarryDeliveryUnderArmedGasBudget()
        public
    {
        if (_laneReady() == false) {

            vm.skip(
                true
            );

            return;
        }

        _prepareLane();

        Book memory lanes;

        lanes.year1 = FIRST_YEAR_UNITS * src.one;

        lanes.year2 = SECOND_YEAR_UNITS * src.one;

        lanes.mature = MATURE_UNITS * src.one;

        LaneExpect memory expect = _laneExpect(
            lanes.year1,
            lanes.year2,
            lanes.mature
        );

        Run memory run;

        run.amount = lanes.year1 + lanes.year2 + lanes.mature;

        run.carried = _scaleToDst(
            run.amount
        );

        run.srcAt = _seedThreeLanes(
            user,
            referrer,
            lanes
        );

        run.srcBefore = _sideState(
            src,
            user,
            referrer
        );

        assertEq(
            run.srcBefore.tracked,
            run.amount,
            "three referred deposits must be fully tracked on the source"
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

        assertEq(
            _nonzeroRingSlots(
                src,
                referrer
            ),
            0,
            "source rings must be empty after the whole three lane cover left"
        );

        _assertCarryWire(
            run.wire,
            run.sent,
            CarryExpect({
                referrer: referrer,
                assignedAt: run.srcAt,
                rank: _srcChainRank(),
                trackedDelta: expect.total,
                year1: expect.year1,
                year2: expect.year2,
                mature: expect.mature
            })
        );

        _onSrc();

        assertEq(
            uint256(ICcipBridgeVault(src.diamond).bridgeGasLimit()),
            4_000_000,
            "the wire must carry the armed 4M gas budget"
        );

        _alignDstClock();

        uint256 gasBefore = gasleft();

        _route(
            run.sent
        );

        uint256 gasUsed = gasBefore - gasleft();

        run.logs = vm.getRecordedLogs();

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

        _assertThreeLaneLanded(
            run,
            expect
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
                trackedDelta: expect.total,
                year1: expect.year1,
                year2: expect.year2,
                mature: expect.mature
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

        console2.log(
            "routed three lane ccipReceive delivery gas (test-side routing overhead included):",
            gasUsed
        );
    }
}

contract CohortBridgeMatrixUsdcMainnetBaseForkRollout is CohortBridgeAttributionMatrixForkGroupC {

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

contract CohortBridgeMatrixUsdcBaseArbitrumForkRollout is CohortBridgeAttributionMatrixForkGroupC {

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

contract CohortBridgeMatrixUsdgMainnetRobinhoodForkRollout is CohortBridgeAttributionMatrixForkGroupC {

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

contract CohortBridgeMatrixUsdgArbitrumMainnetForkRollout is CohortBridgeAttributionMatrixForkGroupC {

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
