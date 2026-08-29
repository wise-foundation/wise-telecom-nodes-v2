// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev CohortWeeks — the single source of truth for every week-epoch
 * and lane-packing constant of the referral cohort recorder, shared by
 * the recorder facets today and by the planned mainnet hub and its
 * cross-chain flush messages. One epoch definition everywhere
 * (`week = timestamp / WEEK`, year = 52 weeks): a mismatch between
 * recorder and hub arithmetic would be a silent fund bug, so no other
 * contract may restate these numbers.
 *
 * Lane geometry: the packed book word and every crumb word share the
 * same three 80-bit lanes (year-1 at bit 0, year-2 at bit 80, mature
 * at bit 160). Crumb words additionally carry the written flag at bit
 * 252; bits 240..251 and 253..255 stay zero forever. The crumb word
 * format is FROZEN and consumed by the hub's pricing intake;
 * `CRUMB_VERSION` is stamped into every flush envelope so the
 * hub can accept version 1 forever. Ring slots pack four uint64 lanes
 * per storage word (52 slots = 13 words per ring per referrer).
 *
 * The saturating helpers return the clipped remainder alongside the
 * result so callers can emit the anomaly event on any clip; they never
 * revert, because they run inside the transfer hook where a revert
 * would veto the transfer itself. All members are `internal`, inlined
 * at compile time, and therefore safe under DELEGATECALL from any
 * facet.
 *
 * Carry codec (same-chain moves ONLY): the attribution-carry
 * payload staged through the chain registry during `moveBetweenVaults`
 * is word0 envelope `referrer(160) | version(8) | pairCount(8)`, word1
 * `trackedDelta(uint128 low) | mature(uint128 high)`, then two pairs
 * per word (low/high uint128 half each), pair = `amount(64) | slot(8)
 * | ring(8)` with ring 0 = year-1, 1 = year-2. Bounds: pairCount is at
 * most `MAX_CARRY_PAIRS` (52 slots per ring, both rings), so a payload
 * is at most `MAX_CARRY_WORDS`; amounts fit their lanes by
 * construction (ring lanes are uint64, book lanes 80-bit, tracked is
 * bounded by the vault deposit cap). SAME-CHAIN-ONLY ASSUMPTION: pairs
 * address ring slots by index, which is meaningful only while source
 * and destination share `block.timestamp` inside one atomic move
 * transaction. The cross-chain bridge carry MUST NOT reuse this
 * encoding: it carries the three aggregate lanes instead, landing
 * them at the oldest live position, and applies at all only when the
 * destination recipient equals the source owner (a different
 * recipient is an ownership change — the credit is destroyed, not
 * carried).
 *
 * Bridge carry codec (cross-chain ONLY): the aggregate payload that
 * rides the bridge wire's `referralData` field is exactly four packed
 * words = `BRIDGE_CARRY_BYTES`. word0 `referrer(160) | version(8)`
 * with bits 168+ zero; word1 `trackedDelta(uint128) |
 * assignedAt(uint64 at bit 128) | originRank(uint8 at bit 192)` with
 * bits 200+ zero; word2 `year1Aggregate(uint128 low) |
 * year2Aggregate(uint128 high)`; word3 `matureAggregate(uint128 low)`
 * with the high half zero. The assignedAt/rank pair is the ORIGIN
 * sync key of the user's referrer assignment and travels unchanged
 * through relays — the destination registry's earliest-wins merge
 * depends on never re-stamping it. `bridgeCarryValid` rejects a
 * payload wholesale unless every structural rule holds: exact length,
 * version match, reserved bits zero, an unreferred envelope
 * (referrer zero) carrying zero book lanes, a referred envelope whose
 * trackedDelta equals the lane sum exactly, a nonzero trackedDelta
 * or lane sum (a payload carrying only the sync key is rejected),
 * and trackedDelta bounded by the amount the same message
 * mints — the conservation ceiling that prices any forged book credit
 * at one-to-one in burned shares. Per-component floor scaling at the
 * source keeps the lane sum at or below the scaled burn, so every
 * honestly built payload passes the ceiling. Landing rule (the
 * destination applies after settling the effective referrer): the
 * year-1 aggregate lands in ring-1 slot `(arrivalWeek + 1) % 52` —
 * the cohort that graduates at the very next weekly boundary — the
 * year-2 aggregate in the same index on ring 2 (the cohort that
 * matures next), and the mature aggregate on the week-less mature
 * lane, all via the saturating helpers with the full pre-clip
 * aggregates added to the book word. Every hop therefore leaves at
 * most one week to the next graduation on each carried lane, so
 * relocation only ever accelerates the year-1 to year-2 to mature
 * walk and a round trip can never refresh a cohort's age.
 */
library CohortWeeks {

    uint256 internal constant WEEK = 1 weeks;

    uint256 internal constant RING_SLOTS = 52;

    uint256 internal constant YEAR = RING_SLOTS * WEEK;

    uint256 internal constant MAX_SETTLE_BOUNDARIES = 104;

    uint256 internal constant LANE_MASK_80 = (1 << 80) - 1;

    uint256 internal constant LANE_Y2_SHIFT = 80;

    uint256 internal constant LANE_M_SHIFT = 160;

    uint256 internal constant CRUMB_WRITTEN_BIT = 1 << 252;

    uint256 internal constant CRUMB_VERSION = 1;

    uint256 internal constant GAP_TO_SHIFT = 32;

    uint256 internal constant GAP_MATURE_SHIFT = 64;

    uint256 internal constant RING_LANE_MAX = type(uint64).max;

    uint256 internal constant CARRY_VERSION = 1;

    uint256 internal constant MAX_CARRY_PAIRS = 104;

    uint256 internal constant MAX_CARRY_WORDS = 54;

    uint256 internal constant CARRY_RING_YEAR1 = 0;

    uint256 internal constant CARRY_RING_YEAR2 = 1;

    uint256 internal constant CARRY_VERSION_SHIFT = 160;

    uint256 internal constant CARRY_PAIR_COUNT_SHIFT = 168;

    uint256 internal constant CARRY_BYTE_MASK = 0xff;

    uint256 internal constant CARRY_HALF_SHIFT = 128;

    uint256 internal constant CARRY_HALF_MASK = (1 << 128) - 1;

    uint256 internal constant CARRY_PAIR_SLOT_SHIFT = 64;

    uint256 internal constant CARRY_PAIR_RING_SHIFT = 72;

    uint256 internal constant BRIDGE_CARRY_VERSION = 1;

    uint256 internal constant BRIDGE_CARRY_WORDS = 4;

    uint256 internal constant BRIDGE_CARRY_BYTES = 128;

    uint256 internal constant BRIDGE_CARRY_ASSIGNED_AT_SHIFT = 128;

    uint256 internal constant BRIDGE_CARRY_RANK_SHIFT = 192;

    uint256 internal constant BRIDGE_CARRY_ENVELOPE_RESERVED_SHIFT = 168;

    uint256 internal constant BRIDGE_CARRY_TRACKED_RESERVED_SHIFT = 200;

    function packCarryEnvelope(
        address _referrer,
        uint256 _pairCount
    )
        internal
        pure
        returns (uint256)
    {
        return uint256(uint160(_referrer))
            | (CARRY_VERSION << CARRY_VERSION_SHIFT)
            | (_pairCount << CARRY_PAIR_COUNT_SHIFT);
    }

    function carryEnvelopeReferrer(
        uint256 _word
    )
        internal
        pure
        returns (address)
    {
        return address(
            uint160(_word)
        );
    }

    function carryEnvelopeVersion(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> CARRY_VERSION_SHIFT) & CARRY_BYTE_MASK;
    }

    function carryEnvelopePairCount(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> CARRY_PAIR_COUNT_SHIFT) & CARRY_BYTE_MASK;
    }

    function packCarryAmounts(
        uint256 _trackedDelta,
        uint256 _mature
    )
        internal
        pure
        returns (uint256)
    {
        return _trackedDelta
            | (_mature << CARRY_HALF_SHIFT);
    }

    function carryTrackedDelta(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return _word & CARRY_HALF_MASK;
    }

    function carryMature(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return _word >> CARRY_HALF_SHIFT;
    }

    function packCarryPair(
        uint256 _amount,
        uint256 _slot,
        uint256 _ring
    )
        internal
        pure
        returns (uint256)
    {
        return _amount
            | (_slot << CARRY_PAIR_SLOT_SHIFT)
            | (_ring << CARRY_PAIR_RING_SHIFT);
    }

    function carryPairAmount(
        uint256 _pair
    )
        internal
        pure
        returns (uint256)
    {
        return _pair & RING_LANE_MAX;
    }

    function carryPairSlot(
        uint256 _pair
    )
        internal
        pure
        returns (uint256)
    {
        return (_pair >> CARRY_PAIR_SLOT_SHIFT) & CARRY_BYTE_MASK;
    }

    function carryPairRing(
        uint256 _pair
    )
        internal
        pure
        returns (uint256)
    {
        return (_pair >> CARRY_PAIR_RING_SHIFT) & CARRY_BYTE_MASK;
    }

    function packCarryPairsWord(
        uint256 _pairLo,
        uint256 _pairHi
    )
        internal
        pure
        returns (uint256)
    {
        return _pairLo
            | (_pairHi << CARRY_HALF_SHIFT);
    }

    function carryPairLo(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return _word & CARRY_HALF_MASK;
    }

    function carryPairHi(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return _word >> CARRY_HALF_SHIFT;
    }

    function packBridgeCarryEnvelope(
        address _referrer
    )
        internal
        pure
        returns (uint256)
    {
        return uint256(uint160(_referrer))
            | (BRIDGE_CARRY_VERSION << CARRY_VERSION_SHIFT);
    }

    function packBridgeCarryTracked(
        uint256 _trackedDelta,
        uint256 _assignedAt,
        uint256 _rank
    )
        internal
        pure
        returns (uint256)
    {
        return _trackedDelta
            | (_assignedAt << BRIDGE_CARRY_ASSIGNED_AT_SHIFT)
            | (_rank << BRIDGE_CARRY_RANK_SHIFT);
    }

    function bridgeCarryAssignedAt(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> BRIDGE_CARRY_ASSIGNED_AT_SHIFT) & RING_LANE_MAX;
    }

    function bridgeCarryRank(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> BRIDGE_CARRY_RANK_SHIFT) & CARRY_BYTE_MASK;
    }

    function packBridgeCarry(
        uint256 _word0,
        uint256 _word1,
        uint256 _word2,
        uint256 _word3
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            _word0,
            _word1,
            _word2,
            _word3
        );
    }

    function unpackBridgeCarry(
        bytes memory _data
    )
        internal
        pure
        returns (
            uint256 word0,
            uint256 word1,
            uint256 word2,
            uint256 word3
        )
    {
        assembly {
            word0 := mload(add(_data, 0x20))
            word1 := mload(add(_data, 0x40))
            word2 := mload(add(_data, 0x60))
            word3 := mload(add(_data, 0x80))
        }
    }

    function bridgeCarryValid(
        bytes memory _data,
        uint256 _mintAmount
    )
        internal
        pure
        returns (bool)
    {
        if (_data.length != BRIDGE_CARRY_BYTES) {
            return false;
        }

        (
            uint256 word0,
            uint256 word1,
            uint256 word2,
            uint256 word3
        ) = unpackBridgeCarry(
            _data
        );

        if (carryEnvelopeVersion(word0) != BRIDGE_CARRY_VERSION) {
            return false;
        }

        if (word0 >> BRIDGE_CARRY_ENVELOPE_RESERVED_SHIFT != 0) {
            return false;
        }

        if (word1 >> BRIDGE_CARRY_TRACKED_RESERVED_SHIFT != 0) {
            return false;
        }

        if (word3 >> CARRY_HALF_SHIFT != 0) {
            return false;
        }

        uint256 trackedDelta = carryTrackedDelta(
            word1
        );

        uint256 laneSum = carryPairLo(word2)
            + carryPairHi(word2)
            + carryPairLo(word3);

        if (carryEnvelopeReferrer(word0) == address(0)) {

            if (laneSum != 0) {
                return false;
            }
        } else {

            if (trackedDelta != laneSum) {
                return false;
            }
        }

        if (trackedDelta == 0 && laneSum == 0) {
            return false;
        }

        if (trackedDelta > _mintAmount) {
            return false;
        }

        return true;
    }

    function laneY1(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return _word & LANE_MASK_80;
    }

    function laneY2(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> LANE_Y2_SHIFT) & LANE_MASK_80;
    }

    function laneM(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> LANE_M_SHIFT) & LANE_MASK_80;
    }

    function packLanes(
        uint256 _y1,
        uint256 _y2,
        uint256 _m
    )
        internal
        pure
        returns (uint256)
    {
        return _y1
            | (_y2 << LANE_Y2_SHIFT)
            | (_m << LANE_M_SHIFT);
    }

    function saturatingAdd80(
        uint256 _lane,
        uint256 _add
    )
        internal
        pure
        returns (
            uint256 result,
            uint256 clipped
        )
    {
        uint256 sum = _lane + _add;

        if (sum > LANE_MASK_80) {
            return (
                LANE_MASK_80,
                sum - LANE_MASK_80
            );
        }

        return (
            sum,
            0
        );
    }

    function saturatingAdd64(
        uint256 _lane,
        uint256 _add
    )
        internal
        pure
        returns (
            uint256 result,
            uint256 clipped
        )
    {
        uint256 sum = _lane + _add;

        if (sum > RING_LANE_MAX) {
            return (
                RING_LANE_MAX,
                sum - RING_LANE_MAX
            );
        }

        return (
            sum,
            0
        );
    }

    function saturatingSub(
        uint256 _value,
        uint256 _sub
    )
        internal
        pure
        returns (
            uint256 result,
            uint256 clipped
        )
    {
        if (_sub > _value) {
            return (
                0,
                _sub - _value
            );
        }

        return (
            _value - _sub,
            0
        );
    }
}
