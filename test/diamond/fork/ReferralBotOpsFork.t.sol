// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";

import {CohortFlushUpgradeForkBase, IWtnFlushVault} from "./CohortFlushUpgradeFork.t.sol";

import {WiseTelecomNodesDiamondErrors} from "../../../src/diamond/vault/WiseTelecomNodesDiamondErrors.sol";

import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev Zero-fee recording stand-in for the CCIP router, etched over
 * the real router address for the duration of a single flush whose
 * live fee quoter refuses the warped fork clock. It answers `getFee`
 * with zero and captures the keccak hash of the envelope bytes the
 * facet hands to `ccipSend` into its first storage slot, so the test
 * can byte-assert its storage reconstruction against what the REAL
 * facet actually shipped even on the mock path. The caller saves and
 * restores the router's code and touched storage slot around the
 * etch window.
 */
contract FlushRouterRecorder {

    bytes32 public capturedDataHash;

    function getFee(
        uint64,
        Client.EVM2AnyMessage calldata
    )
        external
        pure
        returns (uint256)
    {
        return 0;
    }

    function ccipSend(
        uint64 _destChainSelector,
        Client.EVM2AnyMessage calldata _message
    )
        external
        payable
        returns (bytes32)
    {
        capturedDataHash = keccak256(
            _message.data
        );

        return keccak256(
            abi.encode(
                _destChainSelector,
                capturedDataHash
            )
        );
    }
}

/**
 * @dev Operator-bot ordering rehearsal on the live flush transport.
 * The flush lane is sent with `allowOutOfOrderExecution: true`, so a
 * courier operating the spoke-to-hub pipeline explicitly relies on
 * one property this suite pins over real forked chains: consecutive
 * VAULT-BUILT envelopes for the same referrer converge to the same
 * hub state no matter in which order they are delivered and applied.
 * The unit mailbox suite proves the stamp/cursor algebra only with
 * hand-packed payloads and the flush-upgrade rehearsals always
 * deliver in send order; this suite drives envelopes the live
 * spoke's own facet packed through the hub in REVERSED order.
 *
 * Methodology of the convergence proof: two referrers with byte-for-
 * byte mirrored books (same deposits, same timestamps, one courier
 * each so the per-source courier buckets stay apart) are flushed
 * twice at exact week boundaries; boundary alignment keeps the two
 * envelopes' crumb weeks disjoint, so per-lane floor dust cannot
 * differ between application orders and the convergence assertions
 * are EXACT. One referrer's pair is applied in send order, the
 * mirror's in reverse, and every register the bot economy reads
 * (per-source-chain claimable, courier bucket, global score, applied
 * score stamp) must end identical. A deposit lands between the two
 * builds so the reversed run also proves the stamp gate: the earlier
 * envelope's absolute score word, applied last, must be skipped
 * instead of regressing the freshly landed larger score.
 *
 * The mirrored baseline scores travel in ONE two-entry vault-built
 * envelope and every aging warp is anchored to the week the hub
 * ACTUALLY recorded that score checkpoint in, not to the spoke's
 * send-time week. Both choices are load-bearing under parallel test
 * execution: sibling fork rehearsals warping the same live lanes can
 * skew a fork clock between two separate deliveries, and a baseline
 * checkpoint drifting into a later week than its mirror's (or than
 * the assumed aging origin) would zero the dwell-gated rates of the
 * weeks this suite prices. One batched apply pins both checkpoints
 * to a single week by construction, and checkpoint-anchored warps
 * keep the priced weeks inside the rate window wherever that week
 * actually landed. Run this suite ONE TEST AT A TIME: the hub stores
 * a score report under the build week of its envelope and drops one
 * that is already older than its freshness window at apply, so a
 * sibling test that has warped the shared destination-fork clock
 * weeks ahead of the spoke turns the batched baseline scores into a
 * dropped stale report (a zero-score checkpoint, every rate zero)
 * where the same flow passes alone. Aligning the spoke clock up to
 * the hub before every build does not rescue the parallel run (the
 * routed wire then stops byte-matching its reconstruction), so one
 * test at a time is the supported mode.
 *
 * The second scenario overlaps the envelopes on purpose: two flushes
 * an hour apart inside one week re-ship the same in-progress crumb
 * at two sizes. Applying the grown word first and the stale envelope
 * afterwards pins the paid-cursor economics a courier eats: the
 * stale overlap word prices zero (lane regression, no accrual, no
 * courier share) while the stale envelope's genuinely unpriced
 * backlog weeks still pay in full, and a re-apply of the stale
 * envelope after all that accrues nothing.
 *
 * Wire fidelity follows the flush-upgrade rehearsal's doctrine: the
 * first flush of each referrer rides the real routed lane whenever
 * the live on-ramp supports the scrape, and the reordered pair is
 * delivered with the storage-reconstructed envelope through the
 * pranked router; a held message's on-ramp log cannot survive the
 * earlier deliveries' log scrapes anyway. Where the live fee quoter
 * refuses the aged clock, the flush still executes the REAL facet
 * (settle to the second, cursor advance, envelope packing) against a
 * zero-fee recording router etched over the real one for exactly
 * that call; the recorder captures the hash of the envelope the
 * facet hands to `ccipSend`, and every delivered reconstruction is
 * byte-asserted against that capture, so the mock-path envelopes can
 * never drift from what the deployed bytecode would ship. Revert
 * gates a courier must parse (NotFlushBot on a foreign book,
 * InsufficientFlushFee on an underpaid send) are pinned on the exact
 * custom errors in-flow; the fee gate rides the live quote when the
 * quoter answers with a nonzero fee and a pinned nonzero quote
 * otherwise, so neither pin is ever silently skipped.
 */
abstract contract ReferralBotOpsForkBase is CohortFlushUpgradeForkBase {

    struct MirrorRun {
        address refA;
        address refB;
        address courierA;
        address courierB;
        FlushWire backlogA;
        FlushWire backlogB;
        FlushWire freshA;
        FlushWire freshB;
        uint256 grownScore;
        uint256 checkpointWeek;
        uint256 backlogFromWeek;
        uint256 freshWeek;
    }

    uint256 internal constant SECOND_DEPOSIT_UNITS = 4_000;

    // ---- scenarios ----

    function test_botOps_outOfOrderDelivery_convergesWithInOrder()
        public
    {
        if (_laneUsable() == false) {

            vm.skip(
                true
            );

            return;
        }

        MirrorRun memory run;

        run.refA = makeAddr(
            "botOpsReferrerA"
        );

        run.refB = makeAddr(
            "botOpsReferrerB"
        );

        run.courierA = makeAddr(
            "botOpsCourierA"
        );

        run.courierB = makeAddr(
            "botOpsCourierB"
        );

        _mirrorBuild(
            run
        );

        _deliverHeldWire(
            run.backlogA
        );

        _deliverHeldWire(
            run.freshA
        );

        _deliverHeldWire(
            run.freshB
        );

        (
            uint256 freshPaid,
            uint256 freshShare
        ) = _priceSpokeRangeAtHub(
            run.refB,
            run.freshWeek,
            run.freshWeek
        );

        _onDst();

        assertEq(
            hub.globalReferredScore(run.refB),
            run.grownScore,
            "the later-stamp envelope applied first must land the grown absolute score"
        );

        assertEq(
            hub.claimable(src.chainId, run.refB),
            freshPaid - freshShare,
            "the later envelope's crumb week must price in full on first application"
        );

        assertEq(
            hub.claimable(src.chainId, run.courierB),
            freshShare,
            "the stamped courier must earn the split on the freshly priced week"
        );

        assertGt(
            freshPaid,
            0,
            "the fresh week must price at real rates"
        );

        uint256 stampAfterFresh = hub.appliedScoreStamp(
            _sourceKey(),
            run.refB
        );

        _deliverHeldWire(
            run.backlogB
        );

        _onDst();

        assertEq(
            hub.globalReferredScore(run.refB),
            run.grownScore,
            "the stale-stamp score word must be skipped, never regressing the score"
        );

        assertEq(
            hub.appliedScoreStamp(_sourceKey(), run.refB),
            stampAfterFresh,
            "the stale stamp must not overwrite the freshest applied stamp"
        );

        assertEq(
            hub.claimable(src.chainId, run.refB),
            hub.claimable(src.chainId, run.refA),
            "out-of-order application must converge to the in-order claimable"
        );

        assertEq(
            hub.claimable(src.chainId, run.courierB),
            hub.claimable(src.chainId, run.courierA),
            "the courier stamped in both envelopes must earn exactly the in-order total"
        );

        assertEq(
            hub.globalReferredScore(run.refB),
            hub.globalReferredScore(run.refA),
            "the absolute scores must converge across application orders"
        );

        (
            uint256 fullPaid,
            uint256 fullShare
        ) = _priceSpokeRangeAtHub(
            run.refA,
            run.backlogFromWeek,
            run.freshWeek
        );

        _onDst();

        assertEq(
            hub.claimable(src.chainId, run.refA) + hub.claimable(src.chainId, run.courierA),
            fullPaid,
            "every flushed week must accrue exactly once at its final word"
        );

        assertEq(
            hub.claimable(src.chainId, run.courierA),
            fullShare,
            "the courier total must equal the per-week split of the one-shot pricing"
        );

        assertGt(
            hub.claimable(src.chainId, run.refA),
            0,
            "aged weeks past the score checkpoint must have priced real money"
        );

        assertGt(
            hub.claimable(src.chainId, run.courierA),
            0,
            "the courier split must be nonzero for the rehearsed volume"
        );
    }

    function test_botOps_staleEnvelopeAfterFreshDelivery_paysOnlyUnpricedWeeks()
        public
    {
        if (_laneUsable() == false) {

            vm.skip(
                true
            );

            return;
        }

        _referredDepositOnSpoke();

        _ageSpokeWeeks(
            2
        );

        _onSrc();

        vm.prank(
            src.master
        );

        IWtnFlushVault(src.diamond).setAllowedFlushBot(
            bot,
            true
        );

        _deliverAndApply(
            _flushSpoke(
                referrer,
                referrer
            )
        );

        uint256 overlapWeek = _scoresCheckpointWeek(
            referrer
        ) + 3;

        _warpSrcInsideWeek(
            overlapWeek
        );

        uint256 backlogFromWeek = _cursorFromWeekOnSpoke(
            referrer
        );

        FlushWire memory stale = _flushSpokeForced(
            referrer,
            bot
        );

        uint256 partialWord = _spokeCrumb(
            referrer,
            overlapWeek
        );

        assertGt(
            partialWord,
            0,
            "the in-progress week must have settled a partial crumb into the stale envelope"
        );

        _drainWireLogs();

        _onSrc();

        vm.warp(
            block.timestamp + 1 hours
        );

        FlushWire memory fresh = _flushSpokeForced(
            referrer,
            bot
        );

        assertGt(
            _spokeCrumb(referrer, overlapWeek),
            partialWord,
            "the extra hour of dwell must grow the in-progress week's crumb"
        );

        _deliverAndApply(
            fresh
        );

        (
            uint256 overlapPaid,
            uint256 overlapShare
        ) = _priceSpokeRangeAtHub(
            referrer,
            overlapWeek,
            overlapWeek
        );

        _onDst();

        assertEq(
            hub.claimable(src.chainId, referrer),
            overlapPaid - overlapShare,
            "the later envelope applied first must price its grown week in full"
        );

        assertEq(
            hub.claimable(src.chainId, bot),
            overlapShare,
            "the courier split must attach to the freshly priced grown week"
        );

        assertGt(
            overlapPaid,
            0,
            "the grown week must price at real rates"
        );

        uint256 accruedBefore = hub.totalAccrued();

        uint256 stampBefore = hub.appliedScoreStamp(
            _sourceKey(),
            referrer
        );

        uint256 scoreBefore = hub.globalReferredScore(
            referrer
        );

        _deliverHeldWire(
            stale
        );

        (
            uint256 backlogPaid,
            uint256 backlogShare
        ) = _priceSpokeRangeAtHub(
            referrer,
            backlogFromWeek,
            overlapWeek - 1
        );

        _onDst();

        assertEq(
            hub.claimable(src.chainId, referrer),
            (overlapPaid - overlapShare) + (backlogPaid - backlogShare),
            "the stale envelope must pay exactly its not-yet-priced weeks"
        );

        assertEq(
            hub.claimable(src.chainId, bot),
            overlapShare + backlogShare,
            "the courier must earn nothing on the already-priced overlap week"
        );

        assertEq(
            hub.totalAccrued(),
            accruedBefore + backlogPaid,
            "the overlap week's smaller crumb must accrue zero against the advanced paid cursor"
        );

        assertEq(
            hub.globalReferredScore(referrer),
            scoreBefore,
            "the stale score word must be skipped after the fresher stamp"
        );

        assertEq(
            hub.appliedScoreStamp(_sourceKey(), referrer),
            stampBefore,
            "the stale stamp must never lower the applied score stamp"
        );

        assertGt(
            backlogPaid,
            0,
            "the settled backlog weeks must price real money"
        );

        hub.applyFlush(
            stale.messageId,
            src.chainId,
            src.diamond,
            stale.payload
        );

        assertEq(
            hub.totalAccrued(),
            accruedBefore + backlogPaid,
            "re-applying the stale envelope must accrue nothing further"
        );

        assertEq(
            hub.claimable(src.chainId, referrer),
            (overlapPaid - overlapShare) + (backlogPaid - backlogShare),
            "re-applying the stale envelope must not move the referrer bucket"
        );

        assertEq(
            hub.claimable(src.chainId, bot),
            overlapShare + backlogShare,
            "re-applying the stale envelope must not move the courier bucket"
        );

        assertEq(
            hub.appliedScoreStamp(_sourceKey(), referrer),
            stampBefore,
            "re-applying the stale envelope must leave the applied stamp untouched"
        );
    }

    // ---- mirror choreography ----

    function _mirrorBuild(
        MirrorRun memory _run
    )
        internal
    {
        _referredDepositFor(
            "botOpsUserA1",
            _run.refA,
            DEPOSIT_AMOUNT_UNITS
        );

        _referredDepositFor(
            "botOpsUserB1",
            _run.refB,
            DEPOSIT_AMOUNT_UNITS
        );

        _pinFlushGateReverts(
            _run.refA,
            _run.courierA
        );

        vm.prank(
            src.master
        );

        IWtnFlushVault(src.diamond).setAllowedFlushBot(
            _run.courierA,
            true
        );

        vm.prank(
            src.master
        );

        IWtnFlushVault(src.diamond).setAllowedFlushBot(
            _run.courierB,
            true
        );

        _onSrc();

        _warpSrcToBoundaryOfWeek(
            block.timestamp / CohortWeeks.WEEK + 2
        );

        _flushSpokeForced(
            _run.refA,
            _run.courierA
        );

        _flushSpokeForced(
            _run.refB,
            _run.courierA
        );

        _deliverAndApply(
            _flushMirrorScores(
                _run
            )
        );

        _run.checkpointWeek = _scoresCheckpointWeek(
            _run.refA
        );

        assertEq(
            _scoresCheckpointWeek(_run.refB),
            _run.checkpointWeek,
            "the batched score envelope must checkpoint both referrers in one week"
        );

        _warpSrcToBoundaryOfWeek(
            _run.checkpointWeek + 4
        );

        _run.backlogFromWeek = _cursorFromWeekOnSpoke(
            _run.refA
        );

        _run.backlogA = _flushSpokeForced(
            _run.refA,
            _run.courierA
        );

        _drainWireLogs();

        _run.backlogB = _flushSpokeForced(
            _run.refB,
            _run.courierB
        );

        _drainWireLogs();

        _referredDepositFor(
            "botOpsUserA2",
            _run.refA,
            SECOND_DEPOSIT_UNITS
        );

        _referredDepositFor(
            "botOpsUserB2",
            _run.refB,
            SECOND_DEPOSIT_UNITS
        );

        _run.grownScore = IWtnFlushVault(src.diamond).getCohortScore(
            _run.refA
        );

        assertEq(
            IWtnFlushVault(src.diamond).getCohortScore(_run.refB),
            _run.grownScore,
            "the mirrored books must stay identical"
        );

        _warpSrcToBoundaryOfWeek(
            _run.checkpointWeek + 5
        );

        _run.freshWeek = _run.checkpointWeek + 4;

        _run.freshA = _flushSpokeForced(
            _run.refA,
            _run.courierA
        );

        _drainWireLogs();

        _run.freshB = _flushSpokeForced(
            _run.refB,
            _run.courierB
        );

        _drainWireLogs();
    }

    function _pinFlushGateReverts(
        address _referrer,
        address _stranger
    )
        internal
    {
        _onSrc();

        address[] memory referrers = new address[](1);
        referrers[0] = _referrer;

        vm.prank(
            _stranger
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.NotFlushBot.selector
        );

        IWtnFlushVault(src.diamond).flushReferrals(
            referrers
        );

        uint256 fee;

        if (_spokeQuoteWorks(referrers)) {

            fee = IWtnFlushVault(src.diamond).quoteFlushFee(
                referrers
            );
        }

        if (fee == 0) {

            fee = 1 ether;

            vm.mockCall(
                src.router,
                abi.encodeWithSelector(
                    IRouterClient.getFee.selector
                ),
                abi.encode(
                    fee
                )
            );
        }

        vm.deal(
            _referrer,
            fee
        );

        vm.prank(
            _referrer
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.InsufficientFlushFee.selector
        );

        IWtnFlushVault(src.diamond).flushReferrals{value: fee - 1}(
            referrers
        );

        vm.clearMockedCalls();
    }

    // ---- deterministic flush + delivery helpers ----

    function _recordedMockFlush(
        address _caller,
        address[] memory _referrers
    )
        internal
        returns (bytes32 capturedHash)
    {
        bytes memory routerCode = src.router.code;

        bytes32 routerSlotZero = vm.load(
            src.router,
            bytes32(0)
        );

        vm.etch(
            src.router,
            address(new FlushRouterRecorder()).code
        );

        vm.prank(
            _caller
        );

        IWtnFlushVault(src.diamond).flushReferrals(
            _referrers
        );

        capturedHash = FlushRouterRecorder(src.router).capturedDataHash();

        vm.etch(
            src.router,
            routerCode
        );

        vm.store(
            src.router,
            bytes32(0),
            routerSlotZero
        );
    }

    function _flushMirrorScores(
        MirrorRun memory _run
    )
        internal
        returns (FlushWire memory wire)
    {
        _onSrc();

        address[] memory referrers = new address[](2);
        referrers[0] = _run.refA;
        referrers[1] = _run.refB;

        if (_spokeQuoteWorks(referrers) == false) {

            wire.messageId = keccak256(
                abi.encode(src.diamond, syntheticNonce)
            );

            syntheticNonce += 1;

            wire.synthetic = true;

            bytes32 capturedHash = _recordedMockFlush(
                _run.courierA,
                referrers
            );

            wire.payload = _mirrorScoresEnvelope(
                _run
            );

            assertEq(
                keccak256(wire.payload),
                capturedHash,
                "the mock-path scores envelope must byte-match the facet's ccipSend payload"
            );

            return wire;
        }

        uint256 fee = IWtnFlushVault(src.diamond).quoteFlushFee(
            referrers
        );

        vm.deal(
            _run.courierA,
            fee * 2 + 1 ether
        );

        vm.recordLogs();

        vm.prank(
            _run.courierA
        );

        IWtnFlushVault(src.diamond).flushReferrals{value: fee * 2 + 1 ether}(
            referrers
        );

        wire = _scrapeFlushWire(
            _mirrorScoresEnvelope(
                _run
            )
        );
    }

    function _mirrorScoresEnvelope(
        MirrorRun memory _run
    )
        internal
        view
        returns (bytes memory)
    {
        uint256[] memory out = new uint256[](5);

        out[0] = CohortWeeks.packFlushHeader(
            _run.courierA,
            2,
            block.timestamp
        );

        out[1] = CohortWeeks.packFlushEntry(
            _run.refA,
            0,
            0,
            0
        );

        out[2] = CohortWeeks.packFlushScores(
            _spokeBookSum(
                _run.refA
            ),
            _spokeSelfScore(
                _run.refA
            )
        );

        out[3] = CohortWeeks.packFlushEntry(
            _run.refB,
            0,
            0,
            0
        );

        out[4] = CohortWeeks.packFlushScores(
            _spokeBookSum(
                _run.refB
            ),
            _spokeSelfScore(
                _run.refB
            )
        );

        return abi.encodePacked(
            out
        );
    }

    function _flushSpokeForced(
        address _referrer,
        address _caller
    )
        internal
        returns (FlushWire memory wire)
    {
        _onSrc();

        address[] memory referrers = new address[](1);
        referrers[0] = _referrer;

        if (_spokeQuoteWorks(referrers)) {

            wire = _flushSpoke(
                _referrer,
                _caller
            );

            return wire;
        }

        FlushPlanSnapshot memory plan;

        plan.fromWeek = _cursorFromWeekOnSpoke(
            _referrer
        );

        plan.flushedAt = block.timestamp;

        wire.messageId = keccak256(
            abi.encode(src.diamond, syntheticNonce)
        );

        syntheticNonce += 1;

        wire.synthetic = true;

        bytes32 capturedHash = _recordedMockFlush(
            _caller,
            referrers
        );

        wire.payload = _reconstructEnvelope(
            _referrer,
            _caller,
            plan
        );

        assertEq(
            keccak256(wire.payload),
            capturedHash,
            "the mock-path envelope must byte-match the facet's ccipSend payload"
        );
    }

    function _deliverHeldWire(
        FlushWire memory _wire
    )
        internal
    {
        _wire.synthetic = true;

        _deliverAndApply(
            _wire
        );
    }

    function _drainWireLogs()
        internal
    {
        vm.recordLogs();

        vm.getRecordedLogs();
    }

    function _referredDepositFor(
        string memory _name,
        address _referrer,
        uint256 _amountUnits
    )
        internal
        returns (address depositor)
    {
        _onSrc();

        depositor = makeAddr(
            _name
        );

        uint256 amount = _amountUnits * src.one;

        _prepDepositRails(
            depositor,
            amount
        );

        vm.prank(
            depositor
        );

        IWtnFlushVault(src.diamond).depositWithReferral(
            amount,
            _referrer
        );
    }

    // ---- clock + pricing helpers ----

    function _scoresCheckpointWeek(
        address _referrer
    )
        internal
        returns (uint256 week)
    {
        _onDst();

        (
            week,
            ,
        ) = hub.checkpointAt(
            _referrer,
            0
        );
    }

    function _warpSrcToBoundaryOfWeek(
        uint256 _week
    )
        internal
    {
        _onSrc();

        vm.warp(
            _week * CohortWeeks.WEEK
        );
    }

    function _warpSrcInsideWeek(
        uint256 _week
    )
        internal
    {
        _onSrc();

        vm.warp(
            _week * CohortWeeks.WEEK + 3 days
        );
    }

    function _sourceKey()
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(src.chainId, src.diamond)
        );
    }

    function _priceSpokeRangeAtHub(
        address _referrer,
        uint256 _fromWeek,
        uint256 _toWeek
    )
        internal
        returns (
            uint256 paidTotal,
            uint256 shareTotal
        )
    {
        _onSrc();

        uint256[] memory flushedWeeks = new uint256[](
            _toWeek - _fromWeek + 1
        );

        uint256[] memory words = new uint256[](
            _toWeek - _fromWeek + 1
        );

        uint256 count;

        for (uint256 week = _fromWeek; week <= _toWeek; ++week) {

            uint256 word = _spokeCrumb(
                _referrer,
                week
            );

            if (word == 0) {
                continue;
            }

            flushedWeeks[count] = week;
            words[count] = word;

            ++count;
        }

        _onDst();

        uint256 shareBps = hub.botShareBps();

        for (uint256 i; i < count; ++i) {

            (
                uint256 y1Bps,
                uint256 y2Bps,
                uint256 mBps
            ) = hub.weeklyRates(
                _referrer,
                flushedWeeks[i]
            );

            uint256 paid = CohortWeeks.laneY1(words[i]) * y1Bps / 10_000 / CohortWeeks.YEAR
                + CohortWeeks.laneY2(words[i]) * y2Bps / 10_000 / CohortWeeks.YEAR
                + CohortWeeks.laneM(words[i]) * mBps / 10_000 / CohortWeeks.YEAR;

            paidTotal += paid;

            shareTotal += paid * shareBps / 10_000;
        }
    }
}

contract ReferralBotOpsUsdcBaseMainnetFork is ReferralBotOpsForkBase {

    function _laneConfig()
        internal
        pure
        override
        returns (LaneCfg memory)
    {
        return LaneCfg({
            product: "usdc",
            srcNetwork: "base",
            dstNetwork: "mainnet",
            srcRpc: "base",
            dstRpc: "mainnet"
        });
    }

    function _spokeChainRank()
        internal
        pure
        override
        returns (uint256)
    {
        return 1;
    }
}
