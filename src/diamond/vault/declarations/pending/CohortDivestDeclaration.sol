// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Cohort-divest tail shard of the referral commission system.
 * `pendingDivestSync` is the one share sender whose divestment the
 * recorder has not observed yet. The entry contract runs the transfer
 * hook BEFORE the balance moves and hands it only the two addresses,
 * so at hook time the sender still holds everything and the clamp has
 * nothing to see; that ordering is frozen bytecode, not a facet
 * choice. The hook therefore parks the sender here, and the next
 * engine touchpoint by anyone (a hook run, a sync or credit stub, a
 * book settle, a same-chain move) drains the slot first: the parked
 * user is synced at the balance they hold by then, which is the exact
 * post-transfer balance, and the slot clears. Every way for shares to
 * leave the vault (queue join, bridge out, move out, a further
 * transfer) is such a touchpoint, so a divested referee is always
 * clamped before the shares can be sold on, which closes the
 * capital-free book stacking a plain transfer allowed: deposit under
 * a referrer, transfer the shares away, sell them at par, repeat.
 * Only a sender with tracked contribution is parked; a drained sync
 * that hits a failed registry lookup keeps the slot, and an occupied
 * slot skips a new park with an event instead of overwriting it, so
 * nothing is lost silently. Between the transfer and the drain the
 * referrer's book still counts principal that now sits with the
 * recipient, which is exactly what it would count had the sender kept
 * holding, so the gap carries no attacker premium. Default-off
 * convention: zeroed storage parks nothing, and the slot is touched
 * only while `cohortSyncEnabled`. Appended after
 * {CohortAttributionDeclaration} (slot 90) so it takes fresh tail
 * slot 91 and moves no pre-existing slot.
 */
abstract contract CohortDivestDeclaration {

    address internal pendingDivestSync;
}
