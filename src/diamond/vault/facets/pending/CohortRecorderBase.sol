// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "../FacetBase.sol";
import {CohortWeeks} from "../../../shared/pending/CohortWeeks.sol";
import {IReferralRegistry} from "../../interfaces/pending/IReferralRegistry.sol";

/**
 * @dev CohortRecorderBase — the cohort recorder engine, a 1:1 port of
 * the proven sandbox `test/fenwick/ReferralCommissionDemo.sol` onto
 * the diamond's packed tail-shard storage ({CohortContributionDeclaration},
 * {CohortBookDeclaration}). One engine source, compiled into two
 * facet slices: the hot clamp/credit/settle/move paths land in
 * {CohortHookFacet} (reached through the `transferHookFacet` pointer),
 * and the cross-chain bridge-carry + referrer-flip closure lands in
 * {CohortBridgeHookFacet} (dispatcher-routed, reached by the helper
 * stubs through `selectorToFacet` under the same transient bracket) —
 * the split exists only because the whole engine outgrew one
 * EIP-170 deployment; both slices share this byte-identical storage
 * layout.
 *
 * Ordering discipline (preserved verbatim from the sandbox): every
 * path that mutates a referrer's book settles it FIRST.
 * Settle-before-reduce keeps ring slot indices meaningful (rotations
 * current before the walk); settle-before-credit keeps crumb
 * time-weights exact (the elapsed window accrues at the balances that
 * actually existed). The clamp is one-way: `_syncRefereeCohort`
 * only ever lowers `trackedContribution` to the held balance — for
 * EVERY depositor, referred or not, because the self-stake ladder
 * input must stay honest — and reduces the referrer's book
 * newest-credit-first so a sell-plus-redeposit cycle can never upgrade
 * old credit while fresh cover exists.
 *
 * Never-block guarantee: the settle walk is
 * capped at MAX_SETTLE_BOUNDARIES = 104 steps — after 104 rotations
 * both rings are provably empty, so anything further is a closed-form
 * mature-only gap record plus one partial segment — and no function
 * here has a revert path: every lane operation saturates via
 * {CohortWeeks} and reports clips through {CohortLaneSaturated}
 * instead of reverting, because this code runs inside the transfer
 * hook where a revert would veto the transfer itself. The common
 * transfer stays cheap: `_syncRefereeCohort` exits on two reads when
 * the user holds at least their tracked contribution, before touching
 * any book state. Loop bounds: settle walk 104
 * (MAX_SETTLE_BOUNDARIES), reduction walks 52 each (RING_SLOTS) —
 * cited from {CohortWeeks} next to each loop.
 *
 * Packing deltas vs the sandbox: rings are uint64[52] (four lanes per
 * word); the book is one word of three 80-bit lanes sharing the crumb
 * geometry, so a settle segment reads all three sums in one SLOAD and
 * the referrer score is definitionally laneY1+laneY2+laneM (no
 * separate score variable to desync). The gap record's mature field is
 * structurally bounded by the 80-bit book lane, closing a width gap
 * the sandbox left unguarded.
 *
 * Referrer resolution: the `_cohortReferrerOf` seam staticcalls the
 * standalone {ReferralRegistry} through the slot-77 pointer (the
 * bridge-out capture adds the sibling `_cohortReferrerPairOf` pair
 * read under the same guard discipline) — never the diamond's
 * forever-virgin slot-67 mapping. The read is guarded to
 * keep the hook path revert-free for ANY registry condition:
 * assembly staticcall into a
 * 32-byte scratch window (an oversized return can never force a
 * memory-expansion bomb), success requires exactly 32 bytes of
 * returndata with clean upper bits (a dirty word must not revert
 * through abi.decode), and an unset pointer short-circuits to
 * "unreferred" without a call — the documented off state, not an
 * anomaly. A FAILED lookup is returned as `ok == false`, distinct
 * from "no referrer", and each caller then skips its ENTIRE mutation
 * unit: `_syncRefereeCohort` leaves the clamp for a later retry
 * (folding failure into "unreferred" would clamp the referee while
 * never reducing the referrer's book — a permanent, unrecoverable
 * over-credit once the hub prices it), and
 * `_creditContributionCohort` credits nobody for that deposit while
 * still tracking the contribution (the protocol-favoring direction —
 * a later clamp can only over-reduce into the saturating clip, never
 * over-credit). Every failed lookup emits
 * {CohortReferrerLookupFailed} for monitoring. The routed
 * {ReferralFacet} view getter deliberately does NOT use this guarded
 * seam — a view revert DoSes nothing.
 *
 * Move carry: same-chain `moveBetweenVaults` is
 * a system relocation, not a sale, so the moved slice of the
 * referrer's book RELOCATES instead of being destroyed.
 * `_captureMoveOutCohort` replaces the move path's post-burn sync: it
 * clamps exactly like `_syncRefereeCohort`, but the reduction of
 * `carryDelta = min(delta, burnedAmount)` runs through the captured
 * walk, whose exact `(ring, slot, take)` pairs — plus the week-less
 * mature residual — are scaled per component to destination units
 * (floor division, sum-of-scaled-parts so the destination adds
 * exactly what it is told) and staged in the chain registry keyed
 * `(thisVault, dstVault, user)`. Any excess deficit beyond the burned
 * amount reduces sale-like first, so a pre-burn lookup failure can
 * never launder a sale deficit into the carry. On the destination,
 * `_applyMoveInCohort` drains the mailbox and replants: same slots,
 * same rings, same `block.timestamp` — a byte-identical graduation
 * schedule, which is what makes wash-moving A→B→A provably a no-op.
 * Unreferred movers stage a tracked-only envelope (the self-stake
 * ladder input survives relocation).
 *
 * Carry failure doctrine (the never-block guarantee extended to the
 * move path): the move
 * itself must NEVER be blocked by attribution machinery. Both
 * registry interactions are failure-tolerant — `_stageCarryGuarded`
 * try/catches the void call, `_consumeCarryGuarded` pre-checks
 * code.length then try/catches — and every non-applied outcome
 * degrades to attribution loss plus an anomaly event
 * ({CohortCarrySkipped} source-side, {CohortCarryDiscarded}
 * destination-side). A payload applies only when `stagedAt` equals
 * the destination's own `block.timestamp` (stage and consume are
 * synchronous inside one move transaction), which makes every orphan
 * from a not-yet-carry-aware or unarmed counterparty structurally
 * inert; `_carryPayloadValid` then rejects any malformed word
 * wholesale before a single lane is touched. Replants go through the
 * saturating helpers with {CohortLaneSaturated} on clip — never a
 * revert, because a destination revert would revert the source's
 * entire move. Loop bounds: capture and replant walk at most
 * MAX_CARRY_PAIRS = 104 pairs (52 per ring), payloads at most
 * MAX_CARRY_WORDS = 54 words — cited from {CohortWeeks} at each site.
 *
 * Bridge carry: a cross-chain bridge is the same system relocation in
 * aggregate form. `_captureBridgeOutCohort` mirrors the move capture
 * — identical clamp, identical `carryDelta = min(deficit, burned)`
 * law, identical excess-reduces-sale-like-first ordering — but the
 * reduction's three aggregate lane totals travel instead of slot
 * pairs, packed into the bridge wire's `referralData` bytes together
 * with the referrer's origin sync key (read through the guarded
 * `_cohortReferrerPairOf` staticcall). On arrival
 * `_applyBridgeInCohort` validates the payload wholesale
 * ({CohortWeeks.bridgeCarryValid} — including the conservation
 * ceiling `trackedDelta <= mintedAmount`, which prices forged book
 * credit at one-to-one in burned shares), always applies the tracked
 * delta, merges the carried origin key into the local registry
 * (guarded CALL, failure means the local answer stands), and lands
 * the lanes under WHATEVER the local registry answers afterwards —
 * clamp-consistent by construction, no collision branch. Landing is
 * oldest-position: ring slot `(arrivalWeek + 1) % 52` on both rings
 * plus the week-less mature lane, so relocation only ever accelerates
 * graduation. Every failure on the receive side degrades to an
 * anomaly event and never reverts — this path runs inside
 * `ccipReceive`, where a revert would strand an already-burned
 * bridge.
 *
 * Referrer flip migration: when the cross-chain earliest-assignment
 * merge changes a user's referrer, the registry marks the flip and
 * the recorder's referrer seam keeps answering the OLD referrer for
 * this vault until `_migrateReferrerCohort` (reached through the
 * registry's permissionless poke via {receiveReferrerFlip}) relocates
 * the user's local book credit: settle the old book, clamp against
 * the OLD referrer first (a lazy deficit is destroyed sale-like,
 * never laundered), capture the reduction's exact slot pairs and
 * replant them 1:1 at identical coordinates under the new referrer —
 * the one legitimate cross-referrer reuse of the same-chain pair
 * codec, valid because both books share this chain's
 * `block.timestamp` inside one transaction.
 */
abstract contract CohortRecorderBase is FacetBase {

    function _cohortReferrerOf(
        address _user
    )
        internal
        returns (
            bool,
            address
        )
    {
        address registry = referralRegistry;

        if (registry == ZERO_ADDRESS) {
            return (
                true,
                ZERO_ADDRESS
            );
        }

        bytes4 selector = IReferralRegistry.effectiveReferrerOf.selector;

        bool success;
        uint256 word;

        assembly {
            let ptr := mload(0x40)

            mstore(ptr, selector)
            mstore(add(ptr, 0x04), _user)
            mstore(add(ptr, 0x24), address())

            success := staticcall(
                gas(),
                registry,
                ptr,
                0x44,
                0x00,
                0x00
            )

            if iszero(eq(returndatasize(), 32)) {
                success := 0
            }

            if success {
                returndatacopy(0x00, 0, 32)
                word := mload(0x00)
            }
        }

        if (success == false || word > type(uint160).max) {

            emit CohortReferrerLookupFailed(
                _user
            );

            return (
                false,
                ZERO_ADDRESS
            );
        }

        return (
            true,
            address(uint160(word))
        );
    }

    function _syncRefereeCohort(
        address _user
    )
        internal
    {
        uint256 tracked = trackedContribution[_user];

        uint256 held = balanceOf(
            _user
        );

        if (held >= tracked) {
            return;
        }

        uint256 delta = tracked - held;

        (
            bool lookupOk,
            address referrer
        ) = _cohortReferrerOf(
            _user
        );

        if (lookupOk == false) {
            return;
        }

        if (referrer != ZERO_ADDRESS) {
            _settleBookCohort(
                referrer
            );
        }

        trackedContribution[_user] = held;

        if (referrer != ZERO_ADDRESS) {
            _reduceBookCohort(
                referrer,
                delta
            );
        }

        emit CohortContributionSynced(
            _user,
            referrer,
            tracked,
            held
        );
    }

    function _creditContributionCohort(
        address _user,
        uint256 _amount
    )
        internal
    {
        if (_amount == 0) {
            return;
        }

        (
            ,
            address referrer
        ) = _cohortReferrerOf(
            _user
        );

        if (referrer != ZERO_ADDRESS) {

            _settleBookCohort(
                referrer
            );

            _creditRingCohort(
                referrer,
                _amount
            );
        }

        trackedContribution[_user] += _amount;

        emit CohortContributionCredited(
            _user,
            referrer,
            _amount
        );
    }

    function _creditRingCohort(
        address _referrer,
        uint256 _amount
    )
        internal
    {
        uint256 slot = (block.timestamp / CohortWeeks.WEEK) % CohortWeeks.RING_SLOTS;

        (
            uint256 newLane,
            uint256 clippedRing
        ) = CohortWeeks.saturatingAdd64(
            uint256(cohortRingYear1[_referrer][slot]),
            _amount
        );

        cohortRingYear1[_referrer][slot] = uint64(newLane);

        if (clippedRing > 0) {
            emit CohortLaneSaturated(
                _referrer,
                0,
                slot,
                clippedRing
            );
        }

        uint256 book = cohortBook[_referrer];

        (
            uint256 newYear1,
            uint256 clippedBook
        ) = CohortWeeks.saturatingAdd80(
            CohortWeeks.laneY1(book),
            _amount
        );

        cohortBook[_referrer] = CohortWeeks.packLanes(
            newYear1,
            CohortWeeks.laneY2(book),
            CohortWeeks.laneM(book)
        );

        if (clippedBook > 0) {
            emit CohortLaneSaturated(
                _referrer,
                2,
                0,
                clippedBook
            );
        }
    }

    function _settleBookCohort(
        address _referrer
    )
        internal
    {
        uint256 last = cohortLastSettle[_referrer];

        if (last == block.timestamp) {
            return;
        }

        if (last == 0) {
            cohortLastSettle[_referrer] = block.timestamp;
            return;
        }

        uint256 cursor = last;

        uint256 steps;

        while (steps < CohortWeeks.MAX_SETTLE_BOUNDARIES) {

            uint256 next = (cursor / CohortWeeks.WEEK + 1) * CohortWeeks.WEEK;

            if (next > block.timestamp) {
                break;
            }

            _recordSegmentCohort(
                _referrer,
                cursor,
                next
            );

            _rotateCohort(
                _referrer,
                next / CohortWeeks.WEEK
            );

            cursor = next;

            ++steps;
        }

        uint256 latestBoundary = (block.timestamp / CohortWeeks.WEEK) * CohortWeeks.WEEK;

        if (latestBoundary > cursor) {
            cursor = _recordGapCohort(
                _referrer,
                cursor,
                latestBoundary
            );
        }

        if (block.timestamp > cursor) {
            _recordSegmentCohort(
                _referrer,
                cursor,
                block.timestamp
            );
        }

        cohortLastSettle[_referrer] = block.timestamp;

        emit CohortBookSettled(
            _referrer,
            last,
            block.timestamp,
            steps
        );
    }

    function _advanceBookCohort(
        address _referrer,
        uint256 _maxBoundaries
    )
        internal
    {
        uint256 last = cohortLastSettle[_referrer];

        if (last == 0) {
            return;
        }

        uint256 cursor = last;

        uint256 steps;

        while (steps < _maxBoundaries && steps < CohortWeeks.MAX_SETTLE_BOUNDARIES) {

            uint256 next = (cursor / CohortWeeks.WEEK + 1) * CohortWeeks.WEEK;

            if (next > block.timestamp) {
                break;
            }

            _recordSegmentCohort(
                _referrer,
                cursor,
                next
            );

            _rotateCohort(
                _referrer,
                next / CohortWeeks.WEEK
            );

            cursor = next;

            ++steps;
        }

        if (cursor == last) {
            return;
        }

        cohortLastSettle[_referrer] = cursor;

        emit CohortBookSettled(
            _referrer,
            last,
            cursor,
            steps
        );
    }

    function _recordSegmentCohort(
        address _referrer,
        uint256 _from,
        uint256 _to
    )
        internal
    {
        uint256 book = cohortBook[_referrer];

        if (book == 0) {
            return;
        }

        uint256 dt = _to - _from;

        _writeCrumbCohort(
            _referrer,
            _from / CohortWeeks.WEEK,
            CohortWeeks.laneY1(book) * dt,
            CohortWeeks.laneY2(book) * dt,
            CohortWeeks.laneM(book) * dt
        );
    }

    function _writeCrumbCohort(
        address _referrer,
        uint256 _week,
        uint256 _y1Seconds,
        uint256 _y2Seconds,
        uint256 _mSeconds
    )
        internal
    {
        uint256 crumb = cohortWeekLog[_referrer][_week];

        if (crumb & CohortWeeks.CRUMB_WRITTEN_BIT == 0) {
            crumb = CohortWeeks.CRUMB_WRITTEN_BIT;
        }

        (
            uint256 year1Total,
            uint256 clippedYear1
        ) = CohortWeeks.saturatingAdd80(
            CohortWeeks.laneY1(crumb),
            _y1Seconds
        );

        (
            uint256 year2Total,
            uint256 clippedYear2
        ) = CohortWeeks.saturatingAdd80(
            CohortWeeks.laneY2(crumb),
            _y2Seconds
        );

        (
            uint256 matureTotal,
            uint256 clippedMature
        ) = CohortWeeks.saturatingAdd80(
            CohortWeeks.laneM(crumb),
            _mSeconds
        );

        cohortWeekLog[_referrer][_week] = (
            crumb & ~(
                CohortWeeks.LANE_MASK_80
                    | (CohortWeeks.LANE_MASK_80 << CohortWeeks.LANE_Y2_SHIFT)
                    | (CohortWeeks.LANE_MASK_80 << CohortWeeks.LANE_M_SHIFT)
            )
        )
            | CohortWeeks.packLanes(
                year1Total,
                year2Total,
                matureTotal
            );

        uint256 clippedTotal = clippedYear1 + clippedYear2 + clippedMature;

        if (clippedTotal > 0) {
            emit CohortLaneSaturated(
                _referrer,
                3,
                _week,
                clippedTotal
            );
        }
    }

    function _recordGapCohort(
        address _referrer,
        uint256 _from,
        uint256 _toBoundary
    )
        internal
        returns (uint256)
    {
        uint256 mature = CohortWeeks.laneM(
            cohortBook[_referrer]
        );

        uint256 fromWeek = _from / CohortWeeks.WEEK;

        uint256 toWeekExclusive = _toBoundary / CohortWeeks.WEEK;

        if (mature > 0) {

            cohortGapLog[_referrer].push(
                fromWeek
                    | (toWeekExclusive << CohortWeeks.GAP_TO_SHIFT)
                    | (mature << CohortWeeks.GAP_MATURE_SHIFT)
            );

            emit CohortGapRecorded(
                _referrer,
                fromWeek,
                toWeekExclusive,
                mature
            );
        }

        return _toBoundary;
    }

    function _rotateCohort(
        address _referrer,
        uint256 _boundaryWeek
    )
        internal
    {
        uint256 slot = _boundaryWeek % CohortWeeks.RING_SLOTS;

        uint256 graduatingYear2 = uint256(cohortRingYear2[_referrer][slot]);

        uint256 graduatingYear1 = uint256(cohortRingYear1[_referrer][slot]);

        if (graduatingYear1 == 0 && graduatingYear2 == 0) {
            return;
        }

        uint256 book = cohortBook[_referrer];

        uint256 year1 = CohortWeeks.laneY1(book);

        uint256 year2 = CohortWeeks.laneY2(book);

        uint256 mature = CohortWeeks.laneM(book);

        uint256 clippedTotal;

        uint256 clipped;

        if (graduatingYear2 > 0) {

            (mature, clipped) = CohortWeeks.saturatingAdd80(
                mature,
                graduatingYear2
            );

            clippedTotal += clipped;

            (year2, clipped) = CohortWeeks.saturatingSub(
                year2,
                graduatingYear2
            );

            clippedTotal += clipped;
        }

        if (graduatingYear1 > 0) {

            (year2, clipped) = CohortWeeks.saturatingAdd80(
                year2,
                graduatingYear1
            );

            clippedTotal += clipped;

            (year1, clipped) = CohortWeeks.saturatingSub(
                year1,
                graduatingYear1
            );

            clippedTotal += clipped;

            cohortRingYear1[_referrer][slot] = 0;
        }

        if (graduatingYear1 != graduatingYear2) {
            cohortRingYear2[_referrer][slot] = uint64(graduatingYear1);
        }

        cohortBook[_referrer] = CohortWeeks.packLanes(
            year1,
            year2,
            mature
        );

        if (clippedTotal > 0) {
            emit CohortLaneSaturated(
                _referrer,
                2,
                slot,
                clippedTotal
            );
        }
    }

    struct CarryPairBuffer {
        uint256[] pairs;
        uint256 count;
    }

    struct CarryStage {
        uint256[] pairs;
        uint256 pairCount;
        uint256 mature;
        uint256 year1Sum;
        uint256 year2Sum;
        uint256 trackedDelta;
    }

    struct BridgeCarryStage {
        address referrer;
        uint256 assignedAt;
        uint256 rank;
        uint256 year1;
        uint256 year2;
        uint256 mature;
        uint256 trackedDelta;
    }

    function _reduceBookCohort(
        address _referrer,
        uint256 _delta
    )
        internal
        returns (
            uint256 fromYear1,
            uint256 fromYear2,
            uint256 fromMature
        )
    {
        CarryPairBuffer memory buffer;

        return _reduceBookCohortCore(
            _referrer,
            _delta,
            buffer
        );
    }

    function _reduceBookCohortCaptured(
        address _referrer,
        uint256 _delta
    )
        internal
        returns (
            uint256[] memory pairs,
            uint256 pairCount,
            uint256 fromYear1,
            uint256 fromYear2,
            uint256 fromMature
        )
    {
        CarryPairBuffer memory buffer;

        buffer.pairs = new uint256[](
            CohortWeeks.MAX_CARRY_PAIRS
        );

        (
            fromYear1,
            fromYear2,
            fromMature
        ) = _reduceBookCohortCore(
            _referrer,
            _delta,
            buffer
        );

        pairs = buffer.pairs;

        pairCount = buffer.count;
    }

    function _reduceBookCohortCore(
        address _referrer,
        uint256 _delta,
        CarryPairBuffer memory _buffer
    )
        private
        returns (
            uint256 fromYear1,
            uint256 fromYear2,
            uint256 fromMature
        )
    {
        uint256 remaining;

        (
            fromYear1,
            fromYear2,
            remaining
        ) = _walkReduceRingsCohort(
            _referrer,
            _delta,
            _buffer
        );

        uint256 book = cohortBook[_referrer];

        uint256 year1 = CohortWeeks.laneY1(book);

        uint256 year2 = CohortWeeks.laneY2(book);

        uint256 mature = CohortWeeks.laneM(book);

        uint256 clippedTotal;

        uint256 clipped;

        if (fromYear1 > 0) {

            (year1, clipped) = CohortWeeks.saturatingSub(
                year1,
                fromYear1
            );

            clippedTotal += clipped;
        }

        if (fromYear2 > 0) {

            (year2, clipped) = CohortWeeks.saturatingSub(
                year2,
                fromYear2
            );

            clippedTotal += clipped;
        }

        if (remaining > 0) {

            (mature, clipped) = CohortWeeks.saturatingSub(
                mature,
                remaining
            );

            fromMature = remaining - clipped;

            if (clipped > 0) {
                emit CohortLaneSaturated(
                    _referrer,
                    5,
                    0,
                    clipped
                );
            }
        }

        cohortBook[_referrer] = CohortWeeks.packLanes(
            year1,
            year2,
            mature
        );

        if (clippedTotal > 0) {
            emit CohortLaneSaturated(
                _referrer,
                2,
                0,
                clippedTotal
            );
        }

        emit CohortBookReduced(
            _referrer,
            _delta,
            fromYear1,
            fromYear2,
            fromMature
        );
    }

    function _walkReduceRingsCohort(
        address _referrer,
        uint256 _delta,
        CarryPairBuffer memory _buffer
    )
        private
        returns (
            uint256 fromYear1,
            uint256 fromYear2,
            uint256 remaining
        )
    {
        remaining = _delta;

        uint256 currentWeek = block.timestamp / CohortWeeks.WEEK;

        for (uint256 back; back < CohortWeeks.RING_SLOTS; ++back) {

            if (remaining == 0 || back > currentWeek) {
                break;
            }

            uint256 slot = (currentWeek - back) % CohortWeeks.RING_SLOTS;

            uint256 held = uint256(cohortRingYear1[_referrer][slot]);

            if (held == 0) {
                continue;
            }

            uint256 take = held < remaining
                ? held
                : remaining;

            cohortRingYear1[_referrer][slot] = uint64(held - take);

            remaining -= take;

            fromYear1 += take;

            if (_buffer.pairs.length > 0) {

                _buffer.pairs[_buffer.count] = CohortWeeks.packCarryPair(
                    take,
                    slot,
                    CohortWeeks.CARRY_RING_YEAR1
                );

                ++_buffer.count;
            }
        }

        for (uint256 back; back < CohortWeeks.RING_SLOTS; ++back) {

            if (remaining == 0 || back > currentWeek) {
                break;
            }

            uint256 slot = (currentWeek - back) % CohortWeeks.RING_SLOTS;

            uint256 held = uint256(cohortRingYear2[_referrer][slot]);

            if (held == 0) {
                continue;
            }

            uint256 take = held < remaining
                ? held
                : remaining;

            cohortRingYear2[_referrer][slot] = uint64(held - take);

            remaining -= take;

            fromYear2 += take;

            if (_buffer.pairs.length > 0) {

                _buffer.pairs[_buffer.count] = CohortWeeks.packCarryPair(
                    take,
                    slot,
                    CohortWeeks.CARRY_RING_YEAR2
                );

                ++_buffer.count;
            }
        }
    }

    // ---- Move carry ----

    function _captureMoveOutCohort(
        address _user,
        address _dstVault,
        uint256 _burnedAmount,
        uint256 _scaleNumerator,
        uint256 _scaleDenominator
    )
        internal
    {
        uint256 tracked = trackedContribution[_user];

        uint256 held = balanceOf(
            _user
        );

        if (held >= tracked) {
            return;
        }

        if (referralRegistry == ZERO_ADDRESS) {

            _syncRefereeCohort(
                _user
            );

            emit CohortCarrySkipped(
                _user,
                _dstVault
            );

            return;
        }

        (
            bool lookupOk,
            address referrer
        ) = _cohortReferrerOf(
            _user
        );

        if (lookupOk == false) {

            emit CohortCarrySkipped(
                _user,
                _dstVault
            );

            return;
        }

        uint256 carryDelta = tracked - held < _burnedAmount
            ? tracked - held
            : _burnedAmount;

        if (referrer != ZERO_ADDRESS) {

            _settleBookCohort(
                referrer
            );

            if (tracked - held > carryDelta) {
                _reduceBookCohort(
                    referrer,
                    tracked - held - carryDelta
                );
            }
        }

        trackedContribution[_user] = held;

        _stageMoveCarryCohort(
            _user,
            _dstVault,
            referrer,
            carryDelta,
            _scaleNumerator,
            _scaleDenominator
        );

        emit CohortContributionSynced(
            _user,
            referrer,
            tracked,
            held
        );
    }

    function _stageMoveCarryCohort(
        address _user,
        address _dstVault,
        address _referrer,
        uint256 _carryDelta,
        uint256 _scaleNumerator,
        uint256 _scaleDenominator
    )
        internal
    {
        CarryStage memory stage;

        if (_referrer != ZERO_ADDRESS) {
            (
                stage.pairs,
                stage.pairCount,
                ,
                ,
                stage.mature
            ) = _reduceBookCohortCaptured(
                _referrer,
                _carryDelta
            );
        }

        stage.mature = _scaleCarryAmount(
            stage.mature,
            _scaleNumerator,
            _scaleDenominator,
            CohortWeeks.LANE_MASK_80
        );

        (
            stage.year1Sum,
            stage.year2Sum
        ) = _scaleCarryPairsCohort(
            stage.pairs,
            stage.pairCount,
            _scaleNumerator,
            _scaleDenominator
        );

        stage.trackedDelta = stage.year1Sum + stage.year2Sum + stage.mature;

        if (_referrer == ZERO_ADDRESS) {
            stage.trackedDelta = _scaleCarryAmount(
                _carryDelta,
                _scaleNumerator,
                _scaleDenominator,
                CohortWeeks.CARRY_HALF_MASK
            );
        }

        if (stage.trackedDelta == 0 && stage.pairCount == 0) {
            return;
        }

        if (
            _stageCarryGuarded(
                referralRegistry,
                _dstVault,
                _user,
                _packCarryPayloadCohort(
                    _referrer,
                    stage.pairs,
                    stage.pairCount,
                    stage.trackedDelta,
                    stage.mature
                )
            ) == false
        ) {

            emit CohortCarrySkipped(
                _user,
                _dstVault
            );

            return;
        }

        emit CohortCarryStaged(
            _user,
            _dstVault,
            _referrer,
            stage.trackedDelta,
            stage.year1Sum,
            stage.year2Sum,
            stage.mature,
            stage.pairCount
        );
    }

    function _scaleCarryPairsCohort(
        uint256[] memory _pairs,
        uint256 _pairCount,
        uint256 _scaleNumerator,
        uint256 _scaleDenominator
    )
        internal
        pure
        returns (
            uint256 year1Sum,
            uint256 year2Sum
        )
    {
        for (uint256 i; i < _pairCount; ++i) {

            uint256 pair = _pairs[i];

            uint256 scaledAmount = _scaleCarryAmount(
                CohortWeeks.carryPairAmount(pair),
                _scaleNumerator,
                _scaleDenominator,
                CohortWeeks.RING_LANE_MAX
            );

            uint256 ring = CohortWeeks.carryPairRing(pair);

            if (ring == CohortWeeks.CARRY_RING_YEAR1) {
                year1Sum += scaledAmount;
            } else {
                year2Sum += scaledAmount;
            }

            _pairs[i] = CohortWeeks.packCarryPair(
                scaledAmount,
                CohortWeeks.carryPairSlot(pair),
                ring
            );
        }
    }

    function _packCarryPayloadCohort(
        address _referrer,
        uint256[] memory _pairs,
        uint256 _pairCount,
        uint256 _trackedDelta,
        uint256 _mature
    )
        internal
        pure
        returns (uint256[] memory payload)
    {
        payload = new uint256[](
            2 + (_pairCount + 1) / 2
        );

        payload[0] = CohortWeeks.packCarryEnvelope(
            _referrer,
            _pairCount
        );

        payload[1] = CohortWeeks.packCarryAmounts(
            _trackedDelta,
            _mature
        );

        for (uint256 i; i < _pairCount; ++i) {

            uint256 wordIndex = 2 + i / 2;

            if (i % 2 == 0) {
                payload[wordIndex] = _pairs[i];
            } else {
                payload[wordIndex] = CohortWeeks.packCarryPairsWord(
                    payload[wordIndex],
                    _pairs[i]
                );
            }
        }
    }

    function _scaleCarryAmount(
        uint256 _amount,
        uint256 _scaleNumerator,
        uint256 _scaleDenominator,
        uint256 _cap
    )
        internal
        pure
        returns (uint256)
    {
        uint256 scaled = _amount * _scaleNumerator / _scaleDenominator;

        return scaled > _cap
            ? _cap
            : scaled;
    }

    function _stageCarryGuarded(
        address _registry,
        address _dstVault,
        address _user,
        uint256[] memory _payload
    )
        internal
        returns (bool)
    {
        try IReferralRegistry(_registry).stageCarry(
            _dstVault,
            _user,
            _payload
        ) {
            return true;
        } catch {
            return false;
        }
    }

    function _applyMoveInCohort(
        address _user,
        address _srcVault
    )
        internal
    {
        address registry = referralRegistry;

        if (registry == ZERO_ADDRESS) {
            return;
        }

        (
            bool consumeOk,
            uint256 stagedAt,
            uint256[] memory payload
        ) = _consumeCarryGuarded(
            registry,
            _srcVault,
            _user
        );

        if (
            consumeOk == false
            || stagedAt != block.timestamp
            || _carryPayloadValid(payload) == false
        ) {

            emit CohortCarryDiscarded(
                _user,
                _srcVault,
                stagedAt
            );

            return;
        }

        _applyCarryPayloadCohort(
            _user,
            _srcVault,
            payload
        );
    }

    function _applyCarryPayloadCohort(
        address _user,
        address _srcVault,
        uint256[] memory _payload
    )
        internal
    {
        address referrer = CohortWeeks.carryEnvelopeReferrer(
            _payload[0]
        );

        uint256 pairCount = CohortWeeks.carryEnvelopePairCount(
            _payload[0]
        );

        uint256 trackedDelta = CohortWeeks.carryTrackedDelta(
            _payload[1]
        );

        uint256 mature = CohortWeeks.carryMature(
            _payload[1]
        );

        trackedContribution[_user] += trackedDelta;

        uint256 year1Sum;

        uint256 year2Sum;

        if (referrer != ZERO_ADDRESS && (pairCount > 0 || mature > 0)) {

            _settleBookCohort(
                referrer
            );

            (
                year1Sum,
                year2Sum
            ) = _replantRingsCohort(
                referrer,
                _payload,
                pairCount
            );

            _replantBookCohort(
                referrer,
                year1Sum,
                year2Sum,
                mature
            );
        }

        emit CohortCarryApplied(
            _user,
            _srcVault,
            referrer,
            trackedDelta,
            year1Sum,
            year2Sum,
            mature,
            pairCount
        );
    }

    function _carryPayloadValid(
        uint256[] memory _payload
    )
        private
        pure
        returns (bool)
    {
        if (_payload.length < 2) {
            return false;
        }

        if (_payload.length > CohortWeeks.MAX_CARRY_WORDS) {
            return false;
        }

        uint256 envelope = _payload[0];

        if (CohortWeeks.carryEnvelopeVersion(envelope) != CohortWeeks.CARRY_VERSION) {
            return false;
        }

        uint256 pairCount = CohortWeeks.carryEnvelopePairCount(
            envelope
        );

        if (pairCount > CohortWeeks.MAX_CARRY_PAIRS) {
            return false;
        }

        if (_payload.length != 2 + (pairCount + 1) / 2) {
            return false;
        }

        for (uint256 i; i < pairCount; ++i) {

            uint256 word = _payload[2 + i / 2];

            uint256 pair = i % 2 == 0
                ? CohortWeeks.carryPairLo(word)
                : CohortWeeks.carryPairHi(word);

            if (CohortWeeks.carryPairSlot(pair) >= CohortWeeks.RING_SLOTS) {
                return false;
            }

            if (CohortWeeks.carryPairRing(pair) > CohortWeeks.CARRY_RING_YEAR2) {
                return false;
            }
        }

        if (pairCount % 2 == 1) {

            uint256 lastWord = _payload[_payload.length - 1];

            if (CohortWeeks.carryPairHi(lastWord) != 0) {
                return false;
            }
        }

        return true;
    }

    function _consumeCarryGuarded(
        address _registry,
        address _srcVault,
        address _user
    )
        internal
        returns (
            bool ok,
            uint256 stagedAt,
            uint256[] memory payload
        )
    {
        if (_registry.code.length == 0) {
            return (
                false,
                0,
                payload
            );
        }

        try IReferralRegistry(_registry).consumeCarry(
            _srcVault,
            _user
        ) returns (
            uint256 returnedStagedAt,
            uint256[] memory returnedPayload
        ) {
            return (
                true,
                returnedStagedAt,
                returnedPayload
            );
        } catch {
            return (
                false,
                0,
                payload
            );
        }
    }

    function _cohortReferrerPairOf(
        address _user
    )
        internal
        returns (
            bool,
            address,
            uint256,
            uint256
        )
    {
        address registry = referralRegistry;

        bytes4 selector = IReferralRegistry.getReferrerPair.selector;

        bool success;
        uint256 word0;
        uint256 word1;
        uint256 word2;

        assembly {
            let ptr := mload(0x40)

            mstore(ptr, selector)
            mstore(add(ptr, 0x04), _user)

            success := staticcall(
                gas(),
                registry,
                ptr,
                0x24,
                0x00,
                0x00
            )

            if iszero(eq(returndatasize(), 96)) {
                success := 0
            }

            if success {
                returndatacopy(ptr, 0, 96)
                word0 := mload(ptr)
                word1 := mload(add(ptr, 0x20))
                word2 := mload(add(ptr, 0x40))
            }
        }

        if (
            success == false
                || word0 > type(uint160).max
                || word1 > CohortWeeks.RING_LANE_MAX
                || word2 > CohortWeeks.CARRY_BYTE_MASK
        ) {

            emit CohortReferrerLookupFailed(
                _user
            );

            return (
                false,
                ZERO_ADDRESS,
                0,
                0
            );
        }

        return (
            true,
            address(uint160(word0)),
            word1,
            word2
        );
    }

    function _mergeReferrerGuarded(
        address _registry,
        address _user,
        address _referrer,
        uint256 _assignedAt,
        uint256 _rank
    )
        internal
        returns (bool)
    {
        try IReferralRegistry(_registry).mergeReferrer(
            _user,
            _referrer,
            _assignedAt,
            _rank
        ) {
            return true;
        } catch {
            return false;
        }
    }

    function _captureBridgeOutCohort(
        address _user,
        uint64 _dstChainSelector,
        uint256 _burnedAmount,
        uint256 _scaleNumerator,
        uint256 _scaleDenominator
    )
        internal
        returns (bytes memory)
    {
        uint256 tracked = trackedContribution[_user];

        uint256 held = balanceOf(
            _user
        );

        if (held >= tracked) {
            return "";
        }

        if (referralRegistry == ZERO_ADDRESS) {

            _syncRefereeCohort(
                _user
            );

            emit CohortBridgeCarrySkipped(
                _user,
                _dstChainSelector
            );

            return "";
        }

        BridgeCarryStage memory stage;

        address bookReferrer;

        {
            bool pairOk;
            bool effectiveOk;

            (
                pairOk,
                stage.referrer,
                stage.assignedAt,
                stage.rank
            ) = _cohortReferrerPairOf(
                _user
            );

            (
                effectiveOk,
                bookReferrer
            ) = _cohortReferrerOf(
                _user
            );

            if (pairOk == false || effectiveOk == false) {

                emit CohortBridgeCarrySkipped(
                    _user,
                    _dstChainSelector
                );

                return "";
            }
        }

        uint256 carryDelta = tracked - held < _burnedAmount
            ? tracked - held
            : _burnedAmount;

        if (bookReferrer != ZERO_ADDRESS) {

            _settleBookCohort(
                bookReferrer
            );

            if (tracked - held > carryDelta) {
                _reduceBookCohort(
                    bookReferrer,
                    tracked - held - carryDelta
                );
            }

            (
                stage.year1,
                stage.year2,
                stage.mature
            ) = _reduceBookCohort(
                bookReferrer,
                carryDelta
            );
        }

        trackedContribution[_user] = held;

        emit CohortContributionSynced(
            _user,
            bookReferrer,
            tracked,
            held
        );

        stage.year1 = _scaleCarryAmount(
            stage.year1,
            _scaleNumerator,
            _scaleDenominator,
            CohortWeeks.LANE_MASK_80
        );

        stage.year2 = _scaleCarryAmount(
            stage.year2,
            _scaleNumerator,
            _scaleDenominator,
            CohortWeeks.LANE_MASK_80
        );

        stage.mature = _scaleCarryAmount(
            stage.mature,
            _scaleNumerator,
            _scaleDenominator,
            CohortWeeks.LANE_MASK_80
        );

        stage.trackedDelta = stage.referrer == ZERO_ADDRESS
            ? _scaleCarryAmount(
                carryDelta,
                _scaleNumerator,
                _scaleDenominator,
                CohortWeeks.CARRY_HALF_MASK
            )
            : stage.year1 + stage.year2 + stage.mature;

        if (stage.trackedDelta == 0) {
            return "";
        }

        emit CohortBridgeCarrySent(
            _user,
            _dstChainSelector,
            stage.referrer,
            stage.trackedDelta,
            stage.year1,
            stage.year2,
            stage.mature
        );

        return CohortWeeks.packBridgeCarry(
            CohortWeeks.packBridgeCarryEnvelope(
                stage.referrer
            ),
            CohortWeeks.packBridgeCarryTracked(
                stage.trackedDelta,
                stage.assignedAt,
                stage.rank
            ),
            CohortWeeks.packCarryPairsWord(
                stage.year1,
                stage.year2
            ),
            stage.mature
        );
    }

    function _applyBridgeInCohort(
        address _user,
        uint64 _srcChainSelector,
        uint256 _mintedAmount,
        bytes memory _payload
    )
        internal
        returns (bool)
    {
        if (
            CohortWeeks.bridgeCarryValid(
                _payload,
                _mintedAmount
            ) == false
        ) {

            emit CohortBridgeCarryDiscarded(
                _user,
                _srcChainSelector
            );

            return false;
        }

        BridgeCarryStage memory stage;

        {
            (
                uint256 word0,
                uint256 word1,
                uint256 word2,
                uint256 word3
            ) = CohortWeeks.unpackBridgeCarry(
                _payload
            );

            stage.referrer = CohortWeeks.carryEnvelopeReferrer(
                word0
            );

            stage.trackedDelta = CohortWeeks.carryTrackedDelta(
                word1
            );

            stage.assignedAt = CohortWeeks.bridgeCarryAssignedAt(
                word1
            );

            stage.rank = CohortWeeks.bridgeCarryRank(
                word1
            );

            stage.year1 = CohortWeeks.carryPairLo(
                word2
            );

            stage.year2 = CohortWeeks.carryPairHi(
                word2
            );

            stage.mature = word3;
        }

        trackedContribution[_user] += stage.trackedDelta;

        if (stage.referrer == ZERO_ADDRESS) {

            emit CohortBridgeCarryApplied(
                _user,
                _srcChainSelector,
                ZERO_ADDRESS,
                ZERO_ADDRESS,
                stage.trackedDelta,
                0,
                0,
                0
            );

            return true;
        }

        address registry = referralRegistry;

        if (registry == ZERO_ADDRESS) {

            emit CohortBridgeCarryBookDropped(
                _user,
                _srcChainSelector,
                stage.referrer,
                stage.year1,
                stage.year2,
                stage.mature
            );

            return true;
        }

        _mergeReferrerGuarded(
            registry,
            _user,
            stage.referrer,
            stage.assignedAt,
            stage.rank
        );

        (
            bool lookupOk,
            address effectiveReferrer
        ) = _cohortReferrerOf(
            _user
        );

        if (lookupOk == false || effectiveReferrer == ZERO_ADDRESS) {

            emit CohortBridgeCarryBookDropped(
                _user,
                _srcChainSelector,
                stage.referrer,
                stage.year1,
                stage.year2,
                stage.mature
            );

            return true;
        }

        _settleBookCohort(
            effectiveReferrer
        );

        _landBridgeCarryCohort(
            effectiveReferrer,
            stage
        );

        emit CohortBridgeCarryApplied(
            _user,
            _srcChainSelector,
            effectiveReferrer,
            stage.referrer,
            stage.trackedDelta,
            stage.year1,
            stage.year2,
            stage.mature
        );

        return true;
    }

    function _landBridgeCarryCohort(
        address _referrer,
        BridgeCarryStage memory _stage
    )
        internal
    {
        uint256 slot = (block.timestamp / CohortWeeks.WEEK + 1) % CohortWeeks.RING_SLOTS;

        if (_stage.year1 > 0) {

            (
                uint256 newLane,
                uint256 clipped
            ) = CohortWeeks.saturatingAdd64(
                uint256(cohortRingYear1[_referrer][slot]),
                _stage.year1
            );

            cohortRingYear1[_referrer][slot] = uint64(newLane);

            if (clipped > 0) {
                emit CohortLaneSaturated(
                    _referrer,
                    0,
                    slot,
                    clipped
                );
            }
        }

        if (_stage.year2 > 0) {

            (
                uint256 newLane,
                uint256 clipped
            ) = CohortWeeks.saturatingAdd64(
                uint256(cohortRingYear2[_referrer][slot]),
                _stage.year2
            );

            cohortRingYear2[_referrer][slot] = uint64(newLane);

            if (clipped > 0) {
                emit CohortLaneSaturated(
                    _referrer,
                    1,
                    slot,
                    clipped
                );
            }
        }

        _replantBookCohort(
            _referrer,
            _stage.year1,
            _stage.year2,
            _stage.mature
        );
    }

    function _migrateReferrerCohort(
        address _user,
        address _oldReferrer,
        address _newReferrer
    )
        internal
    {
        if (_oldReferrer == ZERO_ADDRESS || _oldReferrer == _newReferrer) {
            return;
        }

        _settleBookCohort(
            _oldReferrer
        );

        uint256 tracked = trackedContribution[_user];

        uint256 held = balanceOf(
            _user
        );

        if (held < tracked) {

            trackedContribution[_user] = held;

            _reduceBookCohort(
                _oldReferrer,
                tracked - held
            );

            emit CohortContributionSynced(
                _user,
                _oldReferrer,
                tracked,
                held
            );

            tracked = held;
        }

        if (tracked == 0) {

            emit CohortReferrerFlipApplied(
                _user,
                _oldReferrer,
                _newReferrer,
                0,
                0,
                0,
                0
            );

            return;
        }

        (
            uint256[] memory pairs,
            uint256 pairCount,
            ,
            ,
            uint256 mature
        ) = _reduceBookCohortCaptured(
            _oldReferrer,
            tracked
        );

        uint256 year1Sum;

        uint256 year2Sum;

        if (pairCount > 0 || mature > 0) {

            _settleBookCohort(
                _newReferrer
            );

            (
                year1Sum,
                year2Sum
            ) = _replantPairsCohort(
                _newReferrer,
                pairs,
                pairCount
            );

            _replantBookCohort(
                _newReferrer,
                year1Sum,
                year2Sum,
                mature
            );
        }

        emit CohortReferrerFlipApplied(
            _user,
            _oldReferrer,
            _newReferrer,
            year1Sum,
            year2Sum,
            mature,
            pairCount
        );
    }

    function _replantPairsCohort(
        address _referrer,
        uint256[] memory _pairs,
        uint256 _pairCount
    )
        internal
        returns (
            uint256 year1Sum,
            uint256 year2Sum
        )
    {
        for (uint256 i; i < _pairCount; ++i) {

            uint256 pair = _pairs[i];

            if (CohortWeeks.carryPairAmount(pair) == 0) {
                continue;
            }

            uint256 slot = CohortWeeks.carryPairSlot(
                pair
            );

            (
                uint256 newLane,
                uint256 clipped
            ) = CohortWeeks.saturatingAdd64(
                CohortWeeks.carryPairRing(pair) == CohortWeeks.CARRY_RING_YEAR1
                    ? uint256(cohortRingYear1[_referrer][slot])
                    : uint256(cohortRingYear2[_referrer][slot]),
                CohortWeeks.carryPairAmount(pair)
            );

            if (CohortWeeks.carryPairRing(pair) == CohortWeeks.CARRY_RING_YEAR1) {

                cohortRingYear1[_referrer][slot] = uint64(newLane);

                year1Sum += CohortWeeks.carryPairAmount(pair);
            } else {

                cohortRingYear2[_referrer][slot] = uint64(newLane);

                year2Sum += CohortWeeks.carryPairAmount(pair);
            }

            if (clipped > 0) {
                emit CohortLaneSaturated(
                    _referrer,
                    CohortWeeks.carryPairRing(pair) == CohortWeeks.CARRY_RING_YEAR1
                        ? 0
                        : 1,
                    slot,
                    clipped
                );
            }
        }
    }

    function _replantRingsCohort(
        address _referrer,
        uint256[] memory _payload,
        uint256 _pairCount
    )
        internal
        returns (
            uint256 year1Sum,
            uint256 year2Sum
        )
    {
        for (uint256 i; i < _pairCount; ++i) {

            uint256 pair = i % 2 == 0
                ? CohortWeeks.carryPairLo(_payload[2 + i / 2])
                : CohortWeeks.carryPairHi(_payload[2 + i / 2]);

            if (CohortWeeks.carryPairAmount(pair) == 0) {
                continue;
            }

            uint256 slot = CohortWeeks.carryPairSlot(
                pair
            );

            (
                uint256 newLane,
                uint256 clipped
            ) = CohortWeeks.saturatingAdd64(
                CohortWeeks.carryPairRing(pair) == CohortWeeks.CARRY_RING_YEAR1
                    ? uint256(cohortRingYear1[_referrer][slot])
                    : uint256(cohortRingYear2[_referrer][slot]),
                CohortWeeks.carryPairAmount(pair)
            );

            if (CohortWeeks.carryPairRing(pair) == CohortWeeks.CARRY_RING_YEAR1) {

                cohortRingYear1[_referrer][slot] = uint64(newLane);

                year1Sum += CohortWeeks.carryPairAmount(pair);
            } else {

                cohortRingYear2[_referrer][slot] = uint64(newLane);

                year2Sum += CohortWeeks.carryPairAmount(pair);
            }

            if (clipped > 0) {
                emit CohortLaneSaturated(
                    _referrer,
                    CohortWeeks.carryPairRing(pair) == CohortWeeks.CARRY_RING_YEAR1
                        ? 0
                        : 1,
                    slot,
                    clipped
                );
            }
        }
    }

    function _replantBookCohort(
        address _referrer,
        uint256 _year1,
        uint256 _year2,
        uint256 _mature
    )
        internal
    {
        uint256 book = cohortBook[_referrer];

        uint256 clippedTotal;

        (
            uint256 newYear1,
            uint256 clipped
        ) = CohortWeeks.saturatingAdd80(
            CohortWeeks.laneY1(book),
            _year1
        );

        clippedTotal += clipped;

        uint256 newYear2;

        (
            newYear2,
            clipped
        ) = CohortWeeks.saturatingAdd80(
            CohortWeeks.laneY2(book),
            _year2
        );

        clippedTotal += clipped;

        uint256 newMature;

        (
            newMature,
            clipped
        ) = CohortWeeks.saturatingAdd80(
            CohortWeeks.laneM(book),
            _mature
        );

        clippedTotal += clipped;

        cohortBook[_referrer] = CohortWeeks.packLanes(
            newYear1,
            newYear2,
            newMature
        );

        if (clippedTotal > 0) {
            emit CohortLaneSaturated(
                _referrer,
                2,
                0,
                clippedTotal
            );
        }
    }
}
