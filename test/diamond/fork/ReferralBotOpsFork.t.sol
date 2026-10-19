// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";

import {CohortFlushUpgradeForkBase, IWtnFlushVault} from "./CohortFlushUpgradeFork.t.sol";

import {ICcipBridgeVault} from "./utils/CcipForkInterfaces.sol";

import {WiseTelecomNodesDiamondErrors} from "../../../src/diamond/vault/WiseTelecomNodesDiamondErrors.sol";

import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev Operator-bot ordering rehearsal on the live flush transport.
 * The flush lane is sent with `allowOutOfOrderExecution: true`, so a
 * courier operating the spoke-to-hub pipeline relies on one property
 * this suite pins over real forked chains: VAULT-BUILT envelopes for
 * the same referrer converge to the same hub state in whatever order
 * they are delivered and applied. The hub prices a closed week only
 * from that week's own bucket and pays each (source, referrer, week)
 * the due of its cumulative cursor, so the property holds without
 * any choreography of build stamps or score windows.
 *
 * The convergence proof flushes two referrers with byte-for-byte
 * mirrored books (same deposits in the same block, one courier each
 * so the per-source courier buckets stay apart): an own flush that
 * stamps the send cursor, then two courier envelopes two weeks apart
 * with a second deposit landing between the builds. A courier batch
 * never writes the referrer's send cursor, so the later envelope
 * re-carries every week the earlier one did plus the new ones. One
 * referrer's pair is applied in send order, the mirror's in reverse,
 * and every register the bot economy reads (claimable, courier
 * bucket, the week buckets and the paid cursors of every flushed
 * week) must end identical, with the referrer's total equal to the
 * one-floor-per-week pricing of every closed crumb and the courier's
 * equal to its fee on every week it carried. The fee is paid on the
 * increment each delivery adds to a week's cursor, so the courier
 * earns it once on every week closed by the later build, the weeks
 * the earlier envelope also carried included, in either order.
 *
 * The duplicate scenario builds two courier envelopes an hour apart
 * from the same stored cursor, so they carry the same closed weeks
 * with equal words: whichever applies first prices them and pays the
 * courier fee, the other and any replay accrue nothing. The revert
 * gates a courier must parse (NotFlushBot on a foreign book,
 * InsufficientFlushFee on an underpaid send) are pinned on the exact
 * custom errors in-flow; the fee gate rides the live quote when the
 * quoter answers with a nonzero fee and a pinned nonzero quote
 * otherwise.
 *
 * Every reordered envelope is delivered through the pranked router
 * as the captured payload, because a held message's on-ramp log
 * cannot survive the earlier deliveries' log scrapes. Run this suite
 * ONE TEST AT A TIME: sibling fork rehearsals warp the same shared
 * destination fork clock.
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
        uint256 courierFromWeek;
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

        _deliverHeldWire(
            run.backlogB
        );

        _assertMirrorConverged(
            run
        );

        uint256 expected = _expectedTotalFor(
            run.refA
        );

        uint256 courierFee = _expectedCourierShareFor(
            run.refA,
            run.courierFromWeek,
            _wireStamp(
                run.freshA
            )
        );

        _onDst();

        assertEq(
            hub.claimable(
                src.chainId,
                run.refA
            ),
            expected,
            "every flushed week must accrue exactly once at its final word"
        );

        assertEq(
            hub.claimable(
                src.chainId,
                run.courierA
            ),
            courierFee,
            "the courier total must equal its fee on every week it carried"
        );

        assertGt(
            expected,
            0,
            "closed weeks must price real money"
        );

        assertGt(
            courierFee,
            0,
            "the courier fee must be nonzero for the rehearsed volume"
        );
    }

    function test_botOps_duplicateCourierEnvelopes_priceOnce()
        public
    {
        if (_laneUsable() == false) {

            vm.skip(
                true
            );

            return;
        }

        address refC = makeAddr(
            "botOpsReferrerC"
        );

        address courierC = makeAddr(
            "botOpsCourierC"
        );

        _allowFlushBot(
            courierC
        );

        _referredDepositFor(
            "botOpsDepositorC",
            refC,
            DEPOSIT_AMOUNT_UNITS
        );

        _ageSpokeWeeks(
            2
        );

        _deliverAndApply(
            _flushSpoke(
                refC,
                refC
            )
        );

        _pinFlushGateReverts(
            refC,
            makeAddr(
                "botOpsStranger"
            )
        );

        _ageSpokeWeeks(
            2
        );

        FlushWire memory first = _flushSpoke(
            refC,
            courierC
        );

        vm.warp(
            block.timestamp + 1 hours
        );

        FlushWire memory second = _flushSpoke(
            refC,
            courierC
        );

        _deliverHeldWire(
            second
        );

        _onDst();

        uint256 referrerAfter = hub.claimable(
            src.chainId,
            refC
        );

        uint256 courierAfter = hub.claimable(
            src.chainId,
            courierC
        );

        uint256 accruedAfter = hub.totalAccrued();

        assertGt(
            courierAfter,
            0,
            "the first applied courier envelope must earn the fee"
        );

        _deliverHeldWire(
            first
        );

        _onDst();

        hub.applyFlush(
            second.messageId,
            src.chainSelector,
            src.chainId,
            src.diamond,
            second.payload
        );

        assertEq(
            hub.claimable(
                src.chainId,
                refC
            ),
            referrerAfter,
            "a duplicate envelope or a replay must price nothing for the referrer"
        );

        assertEq(
            hub.claimable(
                src.chainId,
                courierC
            ),
            courierAfter,
            "a duplicate envelope or a replay must pay the courier nothing"
        );

        assertEq(
            hub.totalAccrued(),
            accruedAfter,
            "a duplicate envelope or a replay must accrue nothing"
        );

        assertEq(
            referrerAfter,
            _expectedTotalFor(
                refC
            ),
            "the referrer must hold the one-shot pricing of every flushed week"
        );
    }

    // ---- build and assertions ----

    function _mirrorBuild(
        MirrorRun memory _run
    )
        internal
    {
        _allowFlushBot(
            _run.courierA
        );

        _allowFlushBot(
            _run.courierB
        );

        _referredDepositFor(
            "botOpsDepositorA",
            _run.refA,
            DEPOSIT_AMOUNT_UNITS
        );

        _referredDepositFor(
            "botOpsDepositorB",
            _run.refB,
            DEPOSIT_AMOUNT_UNITS
        );

        _ageSpokeWeeks(
            2
        );

        FlushWire memory ownA = _flushSpoke(
            _run.refA,
            _run.refA
        );

        FlushWire memory ownB = _flushSpoke(
            _run.refB,
            _run.refB
        );

        _run.courierFromWeek = _wireStamp(
            ownA
        ) / CohortWeeks.WEEK;

        _deliverHeldWire(
            ownA
        );

        _deliverHeldWire(
            ownB
        );

        _ageSpokeWeeks(
            2
        );

        _run.backlogA = _flushSpoke(
            _run.refA,
            _run.courierA
        );

        _run.backlogB = _flushSpoke(
            _run.refB,
            _run.courierB
        );

        _referredDepositFor(
            "botOpsSecondDepositorA",
            _run.refA,
            SECOND_DEPOSIT_UNITS
        );

        _referredDepositFor(
            "botOpsSecondDepositorB",
            _run.refB,
            SECOND_DEPOSIT_UNITS
        );

        _ageSpokeWeeks(
            2
        );

        _run.freshA = _flushSpoke(
            _run.refA,
            _run.courierA
        );

        _run.freshB = _flushSpoke(
            _run.refB,
            _run.courierB
        );
    }

    function _assertMirrorConverged(
        MirrorRun memory _run
    )
        internal
    {
        _onSrc();

        uint256 lastWeek = block.timestamp / CohortWeeks.WEEK;

        _onDst();

        assertEq(
            hub.claimable(
                src.chainId,
                _run.refB
            ),
            hub.claimable(
                src.chainId,
                _run.refA
            ),
            "out-of-order application must converge to the in-order claimable"
        );

        assertEq(
            hub.claimable(
                src.chainId,
                _run.courierB
            ),
            hub.claimable(
                src.chainId,
                _run.courierA
            ),
            "the reversed courier must earn exactly the in-order courier total"
        );

        bytes32 source = hub.sourceKeyOf(
            src.chainId,
            src.diamond
        );

        for (uint256 week = lastWeek - CohortWeeks.MAX_SETTLE_BOUNDARIES; week < lastWeek; ++week) {

            (
                uint256 referredA,
                uint256 selfA
            ) = hub.ladderInputsAt(
                _run.refA,
                week
            );

            (
                uint256 referredB,
                uint256 selfB
            ) = hub.ladderInputsAt(
                _run.refB,
                week
            );

            assertEq(
                referredB,
                referredA,
                "the week buckets must converge across application orders"
            );

            assertEq(
                selfB,
                selfA,
                "the self buckets must converge across application orders"
            );

            assertEq(
                _cursorPacked(
                    source,
                    _run.refB,
                    week
                ),
                _cursorPacked(
                    source,
                    _run.refA,
                    week
                ),
                "the paid cursors must converge across application orders"
            );
        }
    }

    function _cursorPacked(
        bytes32 _source,
        address _referrer,
        uint256 _week
    )
        internal
        view
        returns (uint256)
    {
        (
            uint256 y1,
            uint256 y2,
            uint256 m
        ) = hub.paidCursorAtSource(
            _source,
            _referrer,
            _week
        );

        return CohortWeeks._packLanes(
            y1,
            y2,
            m
        );
    }

    function _allowFlushBot(
        address _bot
    )
        internal
    {
        _onSrc();

        vm.prank(
            ICcipBridgeVault(src.diamond).master()
        );

        IWtnFlushVault(src.diamond).setAllowedFlushBot(
            _bot,
            true
        );
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
