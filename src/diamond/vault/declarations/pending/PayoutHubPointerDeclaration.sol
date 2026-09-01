// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Referral payout-hub pointer tail shard. `payoutHub` is the
 * address of the mainnet referral hub (the standalone scoreboard
 * and paymaster that prices referral commissions and pays claims)
 * authorized to book payout liability into `pendingReferralPayout`
 * and to pull the USD that covers a claim through
 * `fundReferralPayout`. Commissions earned mesh-wide settle against
 * ONE vault's USD pool by design, so only that vault is ever
 * pointed at the hub. While the pointer is `ZERO_ADDRESS` (the
 * virgin default), both payout writers revert {NotPayoutHub}, so a
 * live diamond with virgin tail storage (and every intermediate
 * state of any upgrade sequence) behaves byte-for-byte as today
 * (default-off convention).
 *
 * `proposedPayoutHub` + `payoutHubChangeQueuedAt` back the
 * propose/execute/cancel flow cloned from
 * {ReferralRegistryPointerDeclaration}: instant while the diamond is
 * still in setup (before `finalizeSetup`), 3-day timelocked
 * afterwards, and proposing `ZERO_ADDRESS` reverts back to the off
 * default; detaching the hub is a deliberate, timelocked act that
 * freezes liability booking and claim funding until repointed.
 * Execute additionally shape-probes a non-zero candidate (staticcall
 * `USD_TOKEN()`, returndata must decode to this vault's own USD
 * token) beyond a `code.length` check, so a hub built for a
 * different asset (or any unrelated contract) cannot pass. The
 * timelocked pointer is the ONLY authorization for the payout
 * writers: never an ERC-20 allowance, which would let USD leave
 * without the liability accounting seeing it. The only writers are
 * the {AdminFacet} pointer trio through
 * {WiseTelecomNodesBaseHelper}; every mutation MUST emit the
 * matching {PayoutHubSet} / {PayoutHubProposed} /
 * {PayoutHubProposalCancelled} event. All fields are `internal`
 * rather than `public`: the live genesis dispatcher cannot route
 * auto-getters, so the external read surface is the routed
 * {AdminFacet} getter trio. Appended after
 * {ReferralRegistryPointerDeclaration} (slots 77-79) so it takes
 * fresh tail slots 80-82 and moves no pre-existing slot.
 */
abstract contract PayoutHubPointerDeclaration {

    address internal payoutHub;

    address internal proposedPayoutHub;

    uint256 internal payoutHubChangeQueuedAt;

    uint256 internal constant PAYOUT_HUB_CHANGE_DELAY = 3 days;
}
