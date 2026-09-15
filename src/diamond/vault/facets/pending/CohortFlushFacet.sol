// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";

import {FacetBase} from "../FacetBase.sol";
import {CohortWeeks} from "../../../shared/pending/CohortWeeks.sol";
import {IReferralRegistry} from "../../interfaces/pending/IReferralRegistry.sol";
import {IReferralFlushHub} from "../../interfaces/pending/IReferralFlushHub.sol";

/**
 * @dev CohortFlushFacet: the routed flush transport of the cohort
 * recorder: it carries this vault's referral book (the referred score
 * time-weighted over the last seven days, the absolute self score,
 * frozen weekly crumb words, compressed dormant gap
 * records, and the referrer's own-chain payout designation) to the
 * mainnet referral hub. Two delivery modes behind one planner: a
 * nonzero `flushHubChainSelector` packs a versioned flush envelope
 * (codec and caps in {CohortWeeks}) and sends it as a data-only CCIP
 * message to the hub's cross-chain mailbox, caller-paid with excess
 * refunded; a zero selector means the hub lives on this chain and
 * every entry is delivered by direct call through
 * {IReferralFlushHub}; the vault itself is the hub's allowed
 * reporter, no envelope or designation word exists on that path, and
 * hub reverts bubble on purpose. While the flush-hub pointer is
 * unset every flush entrypoint reverts {FlushHubNotSet}, so a live
 * diamond with virgin tail storage behaves byte-for-byte as today.
 *
 * Everything sent is STORAGE-DERIVED: the caller chooses only which
 * referrers to flush and when, never a single payload byte. Before
 * planning, each referrer's book is settled to the second through
 * the `COHORT_SETTLE_SELECTOR` engine-slice entrypoint (no engine
 * code is compiled here, so the flush path can never diverge from
 * the hook path); while the recorder is disarmed the settle stub
 * no-ops and the flush carries the frozen book unchanged. A
 * referrer's own-book flush is ungated forever; flushing someone
 * else's book requires the `allowedFlushBot` whitelist or the
 * `publicFlushEnabled` switch; the hub prices the courier's
 * cross-chain delivery share from the deliverer stamped into the
 * envelope header, so gating lives here and pricing lives there.
 *
 * The hub's per-lane paid-cursors make every delivery idempotent, so
 * the per-referrer cursors here (`flushedThroughWeek`, and the
 * gap-log index plus intra-record resume week packed into
 * `flushGapCursor`) are pure fee optimizations that only ever
 * advance (window re-sends keep the maximum). Bounds, each enforced
 * where the loop runs: at most MAX_FLUSH_ENTRIES referrers per
 * batch; the crumb scan covers at most MAX_SETTLE_BOUNDARIES weeks
 * per entry (a long-idle cursor catches up one window per flush);
 * gap records are sliced to at most MAX_SETTLE_BOUNDARIES weeks per
 * slice so each fully applies in one pass, with a slice's mature
 * principal clamped to the per-week lane ceiling exactly as a
 * saturated crumb would have been; and total work (crumb words plus
 * gap-sliced weeks) is capped at MAX_FLUSH_WORK per envelope, with
 * later entries degrading to scores-only until the next flush. The
 * payout designation is read from the slot-77 registry through a
 * guarded staticcall (32-byte-bounded words, dirty or missing data
 * degrades to "no designation word"; the registry's caller-paid
 * push is the recovery rail, so a skipped piggyback loses nothing).
 * `quoteFlushFee` plans on current storage without settling, so it
 * is a close lower-bound estimate; callers send margin and the
 * excess refunds. `previewFlushEnvelope` returns, for the caller as
 * deliverer, the exact envelope bytes that plan would send (local
 * mode delivers the same entries by direct call), so a bot can
 * simulate the hub apply before paying for a flush; it shares the
 * same no-settle lower-bound planning. `getFlushCursors` returns the
 * send cursors of a whole batch in one call, the pair a bot needs to
 * size its next envelope.
 *
 * The referred score of an entry is the lower of the instantaneous
 * book and its rolling seven-day average from the previous and
 * current week crumbs (`_referredScoreCohort`), so a snapshot can
 * never claim more presence than the book had: a stake toured
 * through vaults counts at most once across them, a book that left
 * reports its lower instantaneous value at once, and a book that
 * just arrived counts by its presence share until it has been held
 * a full week (a mid-week arrival is pro-rated across its arrival
 * week). The rolling average reads the crumbs the settle just wrote;
 * when the previous week sits inside a compressed dormant span it
 * reads that span's constant mature principal instead, and a week
 * that has neither (the book was empty) counts as absent, so an old
 * span can never vouch for a book that left and came back. While the
 * recorder is disarmed the frozen book is reported as is, since
 * nothing can move while it is off.
 */
contract CohortFlushFacet is FacetBase {

    struct FlushEntryData {
        address referrer;
        uint256 referredScore;
        uint256 selfScore;
        uint256 designationWord;
        uint256[] crumbWeeks;
        uint256[] crumbWords;
        uint256[] gapSlices;
        uint256 throughWeek;
        uint256 gapIndex;
        uint256 gapResumeWeek;
        uint256 workUsed;
    }

    function flushReferrals(
        address[] calldata _referrers
    )
        external
        payable
        onlyDelegateCall
        whenNotPaused
        nonReentrant
    {
        _checkFlushBatch(
            _referrers.length
        );

        for (uint256 i; i < _referrers.length; ++i) {

            _checkFlushCaller(
                _referrers[i]
            );

            if (cohortLastSettle[_referrers[i]] > 0) {
                _cohortSettle(
                    _referrers[i]
                );
            }
        }

        FlushEntryData[] memory entries = _planFlushBatch(
            _referrers
        );

        for (uint256 i; i < entries.length; ++i) {
            _advanceFlushCursors(
                entries[i]
            );
        }

        _dispatchFlush(
            entries
        );
    }

    function flushReferralWindow(
        address _referrer,
        uint256 _fromWeek,
        uint256 _fromGapIndex
    )
        external
        payable
        onlyDelegateCall
        whenNotPaused
        nonReentrant
    {
        require(
            flushHub != ZERO_ADDRESS,
            FlushHubNotSet()
        );

        _checkFlushCaller(
            _referrer
        );

        require(
            _fromWeek <= block.timestamp / CohortWeeks.WEEK,
            FlushWindowInvalid()
        );

        require(
            _fromGapIndex <= cohortGapLog[_referrer].length,
            FlushWindowInvalid()
        );

        if (cohortLastSettle[_referrer] > 0) {
            _cohortSettle(
                _referrer
            );
        }

        FlushEntryData[] memory entries = new FlushEntryData[](1);

        entries[0] = _planFlushEntry(
            _referrer,
            _fromWeek,
            _fromGapIndex,
            0,
            CohortWeeks.MAX_FLUSH_WORK
        );

        _advanceFlushCursors(
            entries[0]
        );

        _dispatchFlush(
            entries
        );
    }

    function quoteFlushFee(
        address[] calldata _referrers
    )
        external
        view
        returns (uint256)
    {
        _checkFlushBatch(
            _referrers.length
        );

        if (flushHubChainSelector == 0) {
            return 0;
        }

        require(
            ccipRouter != ZERO_ADDRESS,
            RouterNotSet()
        );

        FlushEntryData[] memory entries = _planFlushBatch(
            _referrers
        );

        return IRouterClient(ccipRouter).getFee(
            flushHubChainSelector,
            _buildFlushMessage(
                flushHub,
                _packFlushEnvelope(
                    entries
                )
            )
        );
    }

    function previewFlushEnvelope(
        address[] calldata _referrers
    )
        external
        view
        returns (bytes memory)
    {
        _checkFlushBatch(
            _referrers.length
        );

        return _packFlushEnvelope(
            _planFlushBatch(
                _referrers
            )
        );
    }

    function setAllowedFlushBot(
        address _bot,
        bool _allowed
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        require(
            _bot != ZERO_ADDRESS,
            InvalidValue()
        );

        allowedFlushBot[_bot] = _allowed;

        emit FlushBotAllowedSet(
            _bot,
            _allowed
        );
    }

    function setPublicFlushEnabled(
        bool _enabled
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        publicFlushEnabled = _enabled;

        emit PublicFlushEnabledSet(
            _enabled
        );
    }

    function setFlushGasLimit(
        uint64 _gasLimit
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        require(
            _gasLimit >= FLUSH_GAS_LIMIT
                && _gasLimit <= MAX_FLUSH_GAS_LIMIT,
            InvalidFlushGasLimit()
        );

        flushGasLimit = _gasLimit;

        emit FlushGasLimitSet(
            _gasLimit
        );
    }

    function getFlushedThroughWeek(
        address _referrer
    )
        external
        view
        returns (uint256)
    {
        return flushedThroughWeek[_referrer];
    }

    function getFlushGapCursor(
        address _referrer
    )
        external
        view
        returns (
            uint256 gapIndex,
            uint256 gapResumeWeek
        )
    {
        uint256 cursor = flushGapCursor[_referrer];

        return (
            cursor & CohortWeeks.CARRY_HALF_MASK,
            cursor >> FLUSH_GAP_CURSOR_WEEK_SHIFT
        );
    }

    function getFlushCursors(
        address[] calldata _referrers
    )
        external
        view
        returns (
            uint256[] memory throughWeeks,
            uint256[] memory gapIndexes,
            uint256[] memory gapResumeWeeks
        )
    {
        uint256 count = _referrers.length;

        throughWeeks = new uint256[](
            count
        );

        gapIndexes = new uint256[](
            count
        );

        gapResumeWeeks = new uint256[](
            count
        );

        for (uint256 i; i < count; ++i) {

            uint256 cursor = flushGapCursor[_referrers[i]];

            throughWeeks[i] = flushedThroughWeek[_referrers[i]];

            gapIndexes[i] = cursor & CohortWeeks.CARRY_HALF_MASK;

            gapResumeWeeks[i] = cursor >> FLUSH_GAP_CURSOR_WEEK_SHIFT;
        }
    }

    function getAllowedFlushBot(
        address _bot
    )
        external
        view
        returns (bool)
    {
        return allowedFlushBot[_bot];
    }

    function getPublicFlushEnabled()
        external
        view
        returns (bool)
    {
        return publicFlushEnabled;
    }

    function getFlushGasLimit()
        external
        view
        returns (uint64)
    {
        return flushGasLimit;
    }

    function _checkFlushBatch(
        uint256 _count
    )
        internal
        view
    {
        require(
            flushHub != ZERO_ADDRESS,
            FlushHubNotSet()
        );

        require(
            _count > 0,
            NothingToFlush()
        );

        require(
            _count <= CohortWeeks.MAX_FLUSH_ENTRIES,
            FlushBatchTooLarge()
        );
    }

    function _checkFlushCaller(
        address _referrer
    )
        internal
        view
    {
        require(
            _referrer != ZERO_ADDRESS,
            InvalidValue()
        );

        if (_referrer == msg.sender) {
            return;
        }

        require(
            publicFlushEnabled == true
                || allowedFlushBot[msg.sender] == true,
            NotFlushBot()
        );
    }

    function _planFlushBatch(
        address[] calldata _referrers
    )
        internal
        view
        returns (FlushEntryData[] memory entries)
    {
        uint256 currentWeek = block.timestamp / CohortWeeks.WEEK;

        uint256 budget = CohortWeeks.MAX_FLUSH_WORK;

        entries = new FlushEntryData[](
            _referrers.length
        );

        for (uint256 i; i < _referrers.length; ++i) {

            uint256 gapCursor = flushGapCursor[_referrers[i]];

            entries[i] = _planFlushEntry(
                _referrers[i],
                _cursorFromWeek(
                    _referrers[i],
                    currentWeek
                ),
                gapCursor & CohortWeeks.CARRY_HALF_MASK,
                gapCursor >> FLUSH_GAP_CURSOR_WEEK_SHIFT,
                budget
            );

            budget -= entries[i].workUsed;
        }
    }

    function _referredScoreCohort(
        address _referrer,
        uint256 _book
    )
        internal
        view
        returns (uint256)
    {
        uint256 instant = CohortWeeks.laneY1(_book)
            + CohortWeeks.laneY2(_book)
            + CohortWeeks.laneM(_book);

        if (cohortSyncEnabled == false) {
            return instant;
        }

        uint256 week = block.timestamp / CohortWeeks.WEEK;

        uint256 elapsed = block.timestamp - week * CohortWeeks.WEEK;

        uint256 current = _crumbSecondsCohort(
            cohortWeekLog[_referrer][week]
        );

        uint256 previous = _previousWeekSecondsCohort(
            _referrer,
            week - 1
        );

        uint256 rolling = (
            current
                + previous * (CohortWeeks.WEEK - elapsed) / CohortWeeks.WEEK
        ) / CohortWeeks.WEEK;

        return instant < rolling
            ? instant
            : rolling;
    }

    function _previousWeekSecondsCohort(
        address _referrer,
        uint256 _week
    )
        internal
        view
        returns (uint256)
    {
        uint256 crumb = cohortWeekLog[_referrer][_week];

        if (crumb & CohortWeeks.CRUMB_WRITTEN_BIT != 0) {
            return _crumbSecondsCohort(
                crumb
            );
        }

        uint256[] storage gaps = cohortGapLog[_referrer];

        if (gaps.length == 0) {
            return 0;
        }

        uint256 last = gaps[gaps.length - 1];

        if (
            CohortWeeks.gapRecordFromWeek(last) > _week
                || _week >= CohortWeeks.gapRecordToWeek(last)
        ) {
            return 0;
        }

        return CohortWeeks.gapRecordMature(last) * CohortWeeks.WEEK;
    }

    function _crumbSecondsCohort(
        uint256 _crumb
    )
        internal
        pure
        returns (uint256)
    {
        return CohortWeeks.laneY1(_crumb)
            + CohortWeeks.laneY2(_crumb)
            + CohortWeeks.laneM(_crumb);
    }

    function _planFlushEntry(
        address _referrer,
        uint256 _fromWeek,
        uint256 _gapIndex,
        uint256 _gapResumeWeek,
        uint256 _workBudget
    )
        internal
        view
        returns (FlushEntryData memory entry)
    {
        uint256 book = cohortBook[_referrer];

        entry.referrer = _referrer;

        entry.referredScore = _referredScoreCohort(
            _referrer,
            book
        );

        uint256 tracked = trackedContribution[_referrer];

        uint256 scoreCeiling = 3 * CohortWeeks.LANE_MASK_80;

        entry.selfScore = tracked < scoreCeiling
            ? tracked
            : scoreCeiling;

        entry.designationWord = _readDesignationWord(
            _referrer
        );

        uint256 crumbWork;

        (
            entry.crumbWeeks,
            entry.crumbWords,
            entry.throughWeek,
            crumbWork
        ) = _planCrumbs(
            _referrer,
            _fromWeek,
            _workBudget
        );

        uint256 gapWork;

        (
            entry.gapSlices,
            entry.gapIndex,
            entry.gapResumeWeek,
            gapWork
        ) = _planGaps(
            _referrer,
            _gapIndex,
            _gapResumeWeek,
            _workBudget - crumbWork
        );

        entry.workUsed = crumbWork + gapWork;
    }

    function _planCrumbs(
        address _referrer,
        uint256 _fromWeek,
        uint256 _workBudget
    )
        internal
        view
        returns (
            uint256[] memory crumbWeeks,
            uint256[] memory crumbWords,
            uint256 throughWeek,
            uint256 workUsed
        )
    {
        uint256 currentWeek = block.timestamp / CohortWeeks.WEEK;

        uint256 scanEnd = _fromWeek + CohortWeeks.MAX_SETTLE_BOUNDARIES - 1 < currentWeek
            ? _fromWeek + CohortWeeks.MAX_SETTLE_BOUNDARIES - 1
            : currentWeek;

        uint256 count;

        uint256 truncatedAt = type(uint256).max;

        for (uint256 week = _fromWeek; week <= scanEnd; ++week) {

            if (cohortWeekLog[_referrer][week] & ~CohortWeeks.CRUMB_WRITTEN_BIT == 0) {
                continue;
            }

            if (count == _workBudget) {
                truncatedAt = week;
                break;
            }

            ++count;
        }

        crumbWeeks = new uint256[](count);
        crumbWords = new uint256[](count);

        uint256 index;

        for (uint256 week = _fromWeek; index < count; ++week) {

            uint256 word = cohortWeekLog[_referrer][week];

            if (word & ~CohortWeeks.CRUMB_WRITTEN_BIT == 0) {
                continue;
            }

            crumbWeeks[index] = week;
            crumbWords[index] = word;

            ++index;
        }

        workUsed = count;

        if (truncatedAt != type(uint256).max) {
            throughWeek = truncatedAt > 0
                ? truncatedAt - 1
                : 0;
        } else {
            throughWeek = scanEnd == currentWeek
                ? currentWeek - 1
                : scanEnd;
        }
    }

    function _planGaps(
        address _referrer,
        uint256 _gapIndex,
        uint256 _gapResumeWeek,
        uint256 _workBudget
    )
        internal
        view
        returns (
            uint256[] memory slices,
            uint256 gapIndex,
            uint256 gapResumeWeek,
            uint256 workUsed
        )
    {
        (
            uint256 count,
            ,
            ,
        ) = _walkGapSlices(
            _referrer,
            _gapIndex,
            _gapResumeWeek,
            _workBudget,
            new uint256[](0)
        );

        slices = new uint256[](count);

        (
            ,
            gapIndex,
            gapResumeWeek,
            workUsed
        ) = _walkGapSlices(
            _referrer,
            _gapIndex,
            _gapResumeWeek,
            _workBudget,
            slices
        );
    }

    function _walkGapSlices(
        address _referrer,
        uint256 _gapIndex,
        uint256 _gapResumeWeek,
        uint256 _workBudget,
        uint256[] memory _fill
    )
        internal
        view
        returns (
            uint256 count,
            uint256 gapIndex,
            uint256 gapResumeWeek,
            uint256 workUsed
        )
    {
        uint256 length = cohortGapLog[_referrer].length;

        uint256 left = _workBudget;

        uint256 resume = _gapResumeWeek;

        uint256 index = _gapIndex;

        while (index < length && left > 0) {

            uint256 record = cohortGapLog[_referrer][index];

            uint256 sliceFrom = CohortWeeks.gapRecordFromWeek(record);

            if (resume > sliceFrom) {
                sliceFrom = resume;
            }

            uint256 sliceTo = CohortWeeks.gapRecordToWeek(record);

            if (sliceFrom >= sliceTo) {
                ++index;
                resume = 0;
                continue;
            }

            uint256 take = left < CohortWeeks.MAX_SETTLE_BOUNDARIES
                ? left
                : CohortWeeks.MAX_SETTLE_BOUNDARIES;

            if (take > sliceTo - sliceFrom) {
                take = sliceTo - sliceFrom;
            }

            if (_fill.length > 0) {
                _fill[count] = CohortWeeks.packGapRecord(
                    sliceFrom,
                    sliceFrom + take,
                    _clampGapMature(
                        CohortWeeks.gapRecordMature(
                            record
                        )
                    )
                );
            }

            ++count;

            left -= take;

            if (sliceFrom + take == sliceTo) {
                ++index;
                resume = 0;
            } else {
                resume = sliceFrom + take;
            }
        }

        return (
            count,
            index,
            resume,
            _workBudget - left
        );
    }

    function _clampGapMature(
        uint256 _mature
    )
        internal
        pure
        returns (uint256)
    {
        uint256 ceiling = CohortWeeks.LANE_MASK_80 / CohortWeeks.WEEK;

        return _mature < ceiling
            ? _mature
            : ceiling;
    }

    function _cursorFromWeek(
        address _referrer,
        uint256 _currentWeek
    )
        internal
        view
        returns (uint256)
    {
        uint256 stored = flushedThroughWeek[_referrer];

        if (stored == 0) {
            return _currentWeek >= CohortWeeks.MAX_SETTLE_BOUNDARIES
                ? _currentWeek - CohortWeeks.MAX_SETTLE_BOUNDARIES + 1
                : 0;
        }

        return stored + 1;
    }

    function _readDesignationWord(
        address _owner
    )
        internal
        view
        returns (uint256)
    {
        address registry = referralRegistry;

        if (registry == ZERO_ADDRESS) {
            return 0;
        }

        bytes4 selector = IReferralRegistry.getPayoutDesignation.selector;

        bool success;
        uint256 word0;
        uint256 word1;

        assembly {
            let ptr := mload(0x40)

            mstore(ptr, selector)
            mstore(add(ptr, 0x04), _owner)

            success := staticcall(
                gas(),
                registry,
                ptr,
                0x24,
                0x00,
                0x00
            )

            if iszero(eq(returndatasize(), 64)) {
                success := 0
            }

            if success {
                returndatacopy(ptr, 0, 64)
                word0 := mload(ptr)
                word1 := mload(add(ptr, 0x20))
            }
        }

        if (
            success == false
                || word0 > type(uint160).max
                || word1 == 0
                || (word1 >> CohortWeeks.DESIGNATION_STAMP_SHIFT) > CohortWeeks.RING_LANE_MAX
        ) {
            return 0;
        }

        return CohortWeeks.packFlushDesignation(
            address(uint160(word0)),
            word1 >> CohortWeeks.DESIGNATION_STAMP_SHIFT,
            word1 & CohortWeeks.CARRY_BYTE_MASK
        );
    }

    function _advanceFlushCursors(
        FlushEntryData memory _entry
    )
        internal
    {
        bool changed;

        if (_entry.throughWeek > flushedThroughWeek[_entry.referrer]) {
            flushedThroughWeek[_entry.referrer] = _entry.throughWeek;
            changed = true;
        }

        uint256 stored = flushGapCursor[_entry.referrer];

        uint256 storedIndex = stored & CohortWeeks.CARRY_HALF_MASK;

        uint256 storedResume = stored >> FLUSH_GAP_CURSOR_WEEK_SHIFT;

        if (
            _entry.gapIndex > storedIndex
                || (
                    _entry.gapIndex == storedIndex
                        && _entry.gapResumeWeek > storedResume
                )
        ) {
            flushGapCursor[_entry.referrer] = _entry.gapIndex
                | (_entry.gapResumeWeek << FLUSH_GAP_CURSOR_WEEK_SHIFT);

            changed = true;
        }

        if (changed == false) {
            return;
        }

        uint256 cursor = flushGapCursor[_entry.referrer];

        emit CohortReferrerFlushed(
            _entry.referrer,
            flushedThroughWeek[_entry.referrer],
            cursor & CohortWeeks.CARRY_HALF_MASK,
            cursor >> FLUSH_GAP_CURSOR_WEEK_SHIFT
        );
    }

    function _dispatchFlush(
        FlushEntryData[] memory _entries
    )
        internal
    {
        address hub = flushHub;

        uint64 destChainSelector = flushHubChainSelector;

        if (destChainSelector == 0) {

            _deliverFlushLocal(
                hub,
                _entries
            );

            _refundExcessFlushFee(
                0
            );

            emit CohortFlushDelivered(
                hub,
                msg.sender,
                _entries.length
            );

            return;
        }

        require(
            ccipRouter != ZERO_ADDRESS,
            RouterNotSet()
        );

        Client.EVM2AnyMessage memory message = _buildFlushMessage(
            hub,
            _packFlushEnvelope(
                _entries
            )
        );

        uint256 fee = IRouterClient(ccipRouter).getFee(
            destChainSelector,
            message
        );

        require(
            msg.value >= fee,
            InsufficientFlushFee()
        );

        bytes32 messageId = IRouterClient(ccipRouter).ccipSend{value: fee}(
            destChainSelector,
            message
        );

        _refundExcessFlushFee(
            fee
        );

        emit CohortFlushSent(
            messageId,
            destChainSelector,
            msg.sender,
            _entries.length
        );
    }

    function _deliverFlushLocal(
        address _hub,
        FlushEntryData[] memory _entries
    )
        internal
    {
        for (uint256 i; i < _entries.length; ++i) {

            IReferralFlushHub(_hub).reportScores(
                _entries[i].referrer,
                _entries[i].referredScore,
                _entries[i].selfScore
            );

            if (_entries[i].crumbWeeks.length > 0) {
                IReferralFlushHub(_hub).deliverCrumbs(
                    _entries[i].referrer,
                    _entries[i].crumbWeeks,
                    _entries[i].crumbWords
                );
            }

            for (uint256 k; k < _entries[i].gapSlices.length; ++k) {

                uint256 slice = _entries[i].gapSlices[k];

                IReferralFlushHub(_hub).deliverGap(
                    _entries[i].referrer,
                    slice,
                    CohortWeeks.gapRecordFromWeek(slice),
                    CohortWeeks.gapRecordToWeek(slice)
                        - CohortWeeks.gapRecordFromWeek(slice)
                );
            }
        }
    }

    function _packFlushEnvelope(
        FlushEntryData[] memory _entries
    )
        internal
        view
        returns (bytes memory)
    {
        uint256 total = 1;

        for (uint256 i; i < _entries.length; ++i) {
            total += 2
                + (_entries[i].designationWord != 0 ? 1 : 0)
                + _entries[i].crumbWeeks.length * 2
                + _entries[i].gapSlices.length;
        }

        uint256[] memory out = new uint256[](total);

        out[0] = CohortWeeks.packFlushHeader(
            msg.sender,
            _entries.length,
            block.timestamp
        );

        uint256 cursor = 1;

        for (uint256 i; i < _entries.length; ++i) {

            FlushEntryData memory entry = _entries[i];

            uint256 flags = entry.designationWord != 0
                ? CohortWeeks.FLUSH_FLAG_DESIGNATION
                : 0;

            out[cursor] = CohortWeeks.packFlushEntry(
                entry.referrer,
                entry.crumbWeeks.length,
                entry.gapSlices.length,
                flags
            );

            out[cursor + 1] = CohortWeeks.packFlushScores(
                entry.referredScore,
                entry.selfScore
            );

            cursor += 2;

            if (flags != 0) {
                out[cursor] = entry.designationWord;
                ++cursor;
            }

            for (uint256 k; k < entry.crumbWeeks.length; ++k) {
                out[cursor] = entry.crumbWeeks[k];
                out[cursor + 1] = entry.crumbWords[k];
                cursor += 2;
            }

            for (uint256 k; k < entry.gapSlices.length; ++k) {
                out[cursor] = entry.gapSlices[k];
                ++cursor;
            }
        }

        return abi.encodePacked(
            out
        );
    }

    function _buildFlushMessage(
        address _hub,
        bytes memory _payload
    )
        internal
        view
        returns (Client.EVM2AnyMessage memory)
    {
        uint64 gasLimit = flushGasLimit == 0
            ? FLUSH_GAS_LIMIT
            : flushGasLimit;

        return Client.EVM2AnyMessage({
            receiver: abi.encode(
                _hub
            ),
            data: _payload,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: ZERO_ADDRESS,
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({
                    gasLimit: gasLimit,
                    allowOutOfOrderExecution: true
                })
            )
        });
    }

    function _refundExcessFlushFee(
        uint256 _fee
    )
        internal
    {
        uint256 refund = msg.value - _fee;

        if (refund == 0) {
            return;
        }

        (
            bool ok,
        ) = payable(msg.sender).call{value: refund}(
            ""
        );

        require(
            ok,
            FlushRefundFailed()
        );
    }
}
