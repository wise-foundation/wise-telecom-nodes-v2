// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralHubIntake} from "./ReferralHubIntake.sol";
import {CohortWeeks} from "../../diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev Cross-chain mailbox layer: the internals behind the hub's
 * CCIP receive surface. A flush envelope is never applied under the
 * source-paid delivery gas budget: `_receiveFlush` does O(1) work,
 * storing `keccak256(chainId, vault, payload)` into
 * `flushCommitment[messageId]` (a nonzero commitment doubles as the
 * replay guard) and emitting the full payload, so any keeper can
 * later call the permissionless apply with the payload from the
 * event. `_applyFlushEnvelope` proves the supplied bytes against the
 * commitment (the commitment binds origin chain, vault AND payload,
 * so nothing the applier passes is trusted), then walks the entries
 * through the SAME intake internals every local reporter uses,
 * under the reserved remote source key `keccak256(chainId, vault)`.
 *
 * Idempotence and ordering: applying an envelope any number of
 * times, in any order relative to other envelopes, converges: paid
 * cursors absorb crumb and gap re-sends, absolute score reports are
 * gated per (source, referrer) by the envelope's build stamp
 * (`appliedScoreStamp`, greater-or-equal so a re-apply of the
 * freshest envelope still reaches the intake) and stored under the
 * build stamp's WEEK as their freshness week, so a re-applied
 * envelope lands as the same report (a no-op) or, once its week has
 * aged past the intake's freshness window, as a dropped one: no
 * replay can re-stamp a source as fresh; and designations apply
 * latest-wins by their own stamps. The commitment entry is therefore
 * kept forever and apply never marks anything consumed; re-applying
 * is always safe and pays nothing twice.
 *
 * Validation is wholesale and strict: version and crumb-version
 * bytes, reserved bits, entry count, exact payload length, per-slice
 * gap spans and the total work cap all reject the entire envelope;
 * the sources are the system's own authenticated contracts, so a
 * malformed envelope is a bug to surface loudly, never data to
 * salvage; the spoke can always re-flush. One deliberate exception
 * inside a valid envelope: a week the intake still considers future
 * (spoke clocks may run seconds ahead of this chain near a week
 * boundary) reverts the apply, and the SAME apply call simply
 * succeeds once this chain crosses the boundary; lazy application
 * makes the revert self-healing. A designation pair with a zero or
 * far-future set-time or an overflowing rank is skipped with an
 * anomaly event instead: designations are an auxiliary word inside
 * an envelope that moves money, and the registry's caller-paid push
 * is their recovery rail.
 *
 * Designation pushes (`_receiveDesignationPush`) apply inline on
 * receive: one strict 160-byte versioned payload, one stamped
 * latest-wins write, cheap enough for the delivery budget and
 * idempotent by stamp, so the push path needs no replay guard and no
 * mailbox entry.
 */
abstract contract ReferralHubMailbox is ReferralHubIntake {

    struct FlushApplyContext {
        bytes32 source;
        uint256 chainId;
        address deliverer;
        uint256 stamp;
        uint256 cursor;
        uint256 work;
        bytes32 messageId;
    }

    function _receiveFlush(
        bytes32 _messageId,
        uint64 _srcChainSelector,
        address _vault,
        uint256 _chainId,
        bytes calldata _payload
    )
        internal
    {
        require(
            flushCommitment[_messageId] == bytes32(0),
            FlushAlreadyReceived()
        );

        flushCommitment[_messageId] = keccak256(
            abi.encode(
                _chainId,
                _vault,
                _payload
            )
        );

        emit FlushReceived(
            _messageId,
            _srcChainSelector,
            _vault,
            _chainId,
            _payload
        );
    }

    function _applyFlushEnvelope(
        bytes32 _messageId,
        uint256 _chainId,
        address _vault,
        bytes calldata _payload
    )
        internal
    {
        require(
            flushCommitment[_messageId] == keccak256(
                abi.encode(
                    _chainId,
                    _vault,
                    _payload
                )
            ),
            UnknownFlushCommitment()
        );

        uint256 header = _flushWordAt(
            _payload,
            0
        );

        require(
            CohortWeeks.flushHeaderVersion(header) == CohortWeeks.FLUSH_VERSION
                && CohortWeeks.flushHeaderCrumbVersion(header) == CohortWeeks.CRUMB_VERSION
                && header >> CohortWeeks.FLUSH_HEADER_RESERVED_SHIFT == 0,
            FlushPayloadInvalid()
        );

        uint256 entryCount = CohortWeeks.flushHeaderEntryCount(
            header
        );

        require(
            entryCount > 0
                && entryCount <= CohortWeeks.MAX_FLUSH_ENTRIES,
            FlushPayloadInvalid()
        );

        FlushApplyContext memory context = FlushApplyContext({
            source: keccak256(
                abi.encode(
                    _chainId,
                    _vault
                )
            ),
            chainId: _chainId,
            deliverer: CohortWeeks.flushHeaderDeliverer(
                header
            ),
            stamp: CohortWeeks.flushHeaderStamp(
                header
            ),
            cursor: 1,
            work: 0,
            messageId: _messageId
        });

        for (uint256 i; i < entryCount; ++i) {
            _applyFlushEntry(
                context,
                _payload
            );
        }

        require(
            context.cursor * 32 == _payload.length,
            FlushPayloadInvalid()
        );

        require(
            context.work <= CohortWeeks.MAX_FLUSH_WORK,
            FlushPayloadInvalid()
        );

        _bookAccrual();

        emit FlushApplied(
            _messageId,
            context.source,
            entryCount
        );
    }

    function _applyFlushEntry(
        FlushApplyContext memory _context,
        bytes calldata _payload
    )
        internal
    {
        uint256 entryWord = _flushWordAt(
            _payload,
            _context.cursor
        );

        require(
            entryWord >> CohortWeeks.FLUSH_ENTRY_RESERVED_SHIFT == 0,
            FlushPayloadInvalid()
        );

        address referrer = CohortWeeks.flushEntryReferrer(
            entryWord
        );

        require(
            referrer != ZERO_ADDRESS,
            FlushPayloadInvalid()
        );

        uint256 flags = CohortWeeks.flushEntryFlags(
            entryWord
        );

        require(
            flags & ~CohortWeeks.FLUSH_FLAG_DESIGNATION == 0,
            FlushPayloadInvalid()
        );

        uint256 scoresWord = _flushWordAt(
            _payload,
            _context.cursor + 1
        );

        require(
            scoresWord >> CohortWeeks.FLUSH_SCORE_RESERVED_SHIFT == 0,
            FlushPayloadInvalid()
        );

        _context.cursor += 2;

        if (_context.stamp >= appliedScoreStamp[_context.source][referrer]) {

            appliedScoreStamp[_context.source][referrer] = _context.stamp;

            _applyScoreReport(
                _context.source,
                referrer,
                CohortWeeks.flushScoreReferred(
                    scoresWord
                ),
                CohortWeeks.flushScoreSelf(
                    scoresWord
                ),
                _context.stamp / CohortWeeks.WEEK
            );
        }

        if (flags & CohortWeeks.FLUSH_FLAG_DESIGNATION != 0) {

            uint256 designationWord = _flushWordAt(
                _payload,
                _context.cursor
            );

            require(
                designationWord >> CohortWeeks.FLUSH_DESIGNATION_RESERVED_SHIFT == 0,
                FlushPayloadInvalid()
            );

            ++_context.cursor;

            _applyDesignationPair(
                _context.chainId,
                referrer,
                CohortWeeks.flushDesignationPayout(
                    designationWord
                ),
                CohortWeeks.flushDesignationSetAt(
                    designationWord
                ),
                CohortWeeks.flushDesignationRank(
                    designationWord
                )
            );
        }

        _applyFlushCrumbs(
            _context,
            _payload,
            referrer,
            CohortWeeks.flushEntryCrumbCount(
                entryWord
            )
        );

        _applyFlushGaps(
            _context,
            _payload,
            referrer,
            CohortWeeks.flushEntryGapCount(
                entryWord
            )
        );
    }

    function _applyFlushCrumbs(
        FlushApplyContext memory _context,
        bytes calldata _payload,
        address _referrer,
        uint256 _crumbCount
    )
        internal
    {
        for (uint256 k; k < _crumbCount; ++k) {

            uint256 week = _flushWordAt(
                _payload,
                _context.cursor
            );

            uint256 word = _flushWordAt(
                _payload,
                _context.cursor + 1
            );

            _deliverCrumb(
                _context.source,
                _referrer,
                week,
                word,
                _deliveryOrigin(
                    _context
                )
            );

            _context.cursor += 2;

            ++_context.work;
        }
    }

    function _applyFlushGaps(
        FlushApplyContext memory _context,
        bytes calldata _payload,
        address _referrer,
        uint256 _gapCount
    )
        internal
    {
        for (uint256 k; k < _gapCount; ++k) {

            uint256 record = _flushWordAt(
                _payload,
                _context.cursor
            );

            _applyFlushGap(
                _context,
                _referrer,
                record
            );

            ++_context.cursor;
        }
    }

    function _applyFlushGap(
        FlushApplyContext memory _context,
        address _referrer,
        uint256 _record
    )
        internal
    {
        uint256 fromWeek = CohortWeeks.gapRecordFromWeek(
            _record
        );

        uint256 toWeek = CohortWeeks.gapRecordToWeek(
            _record
        );

        require(
            toWeek > fromWeek
                && toWeek - fromWeek <= CohortWeeks.MAX_SETTLE_BOUNDARIES,
            FlushPayloadInvalid()
        );

        _deliverGap(
            _context.source,
            _referrer,
            _record,
            fromWeek,
            toWeek - fromWeek,
            _deliveryOrigin(
                _context
            )
        );

        _context.work += toWeek - fromWeek;
    }

    function _receiveDesignationPush(
        uint64 _srcChainSelector,
        uint256 _chainId,
        bytes calldata _data
    )
        internal
    {
        require(
            _data.length == DESIGNATION_PAYLOAD_LENGTH,
            FlushPayloadInvalid()
        );

        (
            uint256 version,
            address owner,
            address payout,
            uint256 setAt,
            uint256 rank
        ) = abi.decode(
            _data,
            (uint256, address, address, uint256, uint256)
        );

        require(
            version == DESIGNATION_VERSION,
            FlushPayloadInvalid()
        );

        require(
            owner != ZERO_ADDRESS,
            FlushPayloadInvalid()
        );

        emit DesignationPushReceived(
            _srcChainSelector,
            _chainId,
            owner
        );

        _applyDesignationPair(
            _chainId,
            owner,
            payout,
            setAt,
            rank
        );
    }

    function _applyDesignationPair(
        uint256 _chainId,
        address _owner,
        address _payout,
        uint256 _setAt,
        uint256 _rank
    )
        internal
    {
        uint256 stamp = (_setAt << PAYOUT_STAMP_SHIFT) | _rank;

        if (
            _setAt == 0
                || _setAt > block.timestamp + MAX_DESIGNATION_FUTURE_DRIFT
                || _rank > type(uint8).max
        ) {

            emit FlushDesignationSkipped(
                _chainId,
                _owner,
                stamp
            );

            return;
        }

        if (stamp <= payoutStamp[_chainId][_owner]) {
            return;
        }

        payoutAddress[_chainId][_owner] = _payout;

        payoutStamp[_chainId][_owner] = stamp;

        emit PayoutAddressSet(
            _chainId,
            _owner,
            _payout
        );
    }

    function _deliveryOrigin(
        FlushApplyContext memory _context
    )
        internal
        pure
        returns (DeliveryOrigin memory)
    {
        return DeliveryOrigin({
            chainId: _context.chainId,
            deliverer: _context.deliverer,
            messageId: _context.messageId
        });
    }

    function _flushWordAt(
        bytes calldata _payload,
        uint256 _index
    )
        internal
        pure
        returns (uint256)
    {
        require(
            (_index + 1) * 32 <= _payload.length,
            FlushPayloadInvalid()
        );

        return abi.decode(
            _payload[_index * 32:_index * 32 + 32],
            (uint256)
        );
    }
}
