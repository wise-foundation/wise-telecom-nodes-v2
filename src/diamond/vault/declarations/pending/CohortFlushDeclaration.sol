// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Cross-chain flush transport tail shard. `flushHub` +
 * `flushHubChainSelector` (packed into one slot) name the mainnet
 * referral hub the {CohortFlushFacet} delivers this vault's cohort
 * book to: a nonzero selector sends a CCIP flush envelope to the hub
 * on the selector's chain, a zero selector with a nonzero hub
 * delivers by direct local call (the hub-chain vaults themselves).
 * `flushedThroughWeek` and `flushGapCursor` (gap-log index in the
 * low 128 bits, intra-record resume week in the high 128) are
 * per-referrer send cursors: pure fee optimizations, because the
 * hub's paid-cursors make every re-send idempotent; they only mark
 * what has already been carried so builders skip it.
 * `allowedFlushBot` + `publicFlushEnabled` gate flushing OTHER
 * referrers' books (a referrer's own-book flush is ungated forever);
 * `flushGasLimit` is the CCIP destination gas budget (zero =
 * FLUSH_GAS_LIMIT default). While `flushHub` is `ZERO_ADDRESS` (the
 * virgin default), every flush entrypoint reverts {FlushHubNotSet},
 * so a live diamond with virgin tail storage (and every
 * intermediate state of any upgrade sequence) behaves byte-for-byte
 * as today (default-off convention).
 *
 * `proposedFlushHub` + `proposedFlushHubChainSelector` +
 * `flushHubChangeQueuedAt` back the propose/execute/cancel flow
 * cloned from {PayoutHubPointerDeclaration}: instant while the
 * diamond is still in setup (before `finalizeSetup`), 3-day
 * timelocked afterwards, and proposing `ZERO_ADDRESS` reverts back
 * to the off default. Unlike the payout-hub pointer there is NO
 * execute-time shape probe: the hub usually lives on another chain,
 * where no probe is possible, so the 3-day window itself is the
 * review period; a zero hub with a nonzero selector is the one
 * shape execute rejects. Nothing in this shard is touched by any
 * deposit, transfer, compound, queue or bridge path: the cursors and
 * policy fields are written only by the explicit flush entrypoints
 * and the {AdminFacet} surface, so the recorder's hot-path gas
 * envelope is untouched. The only pointer writers are the
 * {AdminFacet} trio through {WiseTelecomNodesBaseHelper}; every
 * mutation MUST emit the matching {FlushHubSet} / {FlushHubProposed}
 * / {FlushHubProposalCancelled} event. All fields are `internal`
 * rather than `public`: the live genesis dispatcher cannot route
 * auto-getters, so the external read surface is the routed
 * {AdminFacet} getter trio plus the {CohortFlushFacet} views.
 * Appended after {PayoutHubPointerDeclaration} (slots 80-82) so it
 * takes fresh tail slots 83-89 and moves no pre-existing slot.
 */
abstract contract CohortFlushDeclaration {

    address internal flushHub;

    uint64 internal flushHubChainSelector;

    address internal proposedFlushHub;

    uint64 internal proposedFlushHubChainSelector;

    uint256 internal flushHubChangeQueuedAt;

    mapping(address => uint256) internal flushedThroughWeek;

    mapping(address => uint256) internal flushGapCursor;

    mapping(address => bool) internal allowedFlushBot;

    bool internal publicFlushEnabled;

    uint64 internal flushGasLimit;

    uint256 internal constant FLUSH_HUB_CHANGE_DELAY = 3 days;

    uint256 internal constant FLUSH_GAP_CURSOR_WEEK_SHIFT = 128;

    uint64 internal constant FLUSH_GAS_LIMIT = 300_000;

    uint64 internal constant MAX_FLUSH_GAS_LIMIT = 2_000_000;
}
