# Diamond protocol invariants

A catalog of "X should always be Y" laws for the **non-legacy** WiseTelecomNodes
diamond (`src/diamond/` only — `src/legacy/` and `src/migration/` are out of
scope). Every entry is written to be turned directly into a test/proof pair:

1. a **Foundry stateful invariant** (random operation sequences through the
   real facets, predicate checked after every call), and
2. a **Kontrol dual-engine proof** (the same `testFuzz_*` function fuzzed by
   `forge test` and symbolically proven by `kontrol prove` — see
   [kontrol/README.md](kontrol/README.md) for methodology, engine setup and
   proof assumptions; they are not restated here).

**ID → test-name convention:** a new test for entry `QUE-10` is named
`invariant_QUE10_<slug>` (stateful) or `testFuzz_QUE10_<slug>` (dual-engine),
so coverage is greppable from the ID.

**Status legend:**
`PROVEN+FUZZED` — dual-engine Kontrol proof and/or stateful invariant exists
(pointer given). `GAP (Pn)` — not yet machine-checked; P0 is the highest
priority. Entries marked *(this pass)* were implemented together with this
document.

---

## System model in one page

- The diamond is one contract holding the ERC20 share token (1 share = 1 USD
  unit), the interest engine and the order-book queue; facets are entered via
  DELEGATECALL, storage is linearized by
  `src/diamond/vault/declarations/WiseTelecomNodesDeclarations.sol` (slot map:
  [../../src/diamond/STORAGE_LAYOUT.md](../../src/diamond/STORAGE_LAYOUT.md)).
- **Deposits forward the USD out** to `thirdPartyAddress` (the custodian); the
  vault keeps only a buffer from which interest claims and queue exits are
  paid. On-chain solvency of that buffer is a *liveness assumption on the
  custodian*, not a provable safety property (NI-5).
- **Interest** is per-user: `pending = (balanceOf + proxyBalance) · rate · Δt /
  (year · 10000)`, banked into the `cashedInterest` ledger by the
  `assignInterest` modifier on every mutating entry
  (`WiseTelecomNodesInterestHelper.sol`). `InterestRateProxy ==
  address(this)`, constructor-fixed, no setter.
- **Queue**: per-incentive doubly-linked FIFO lanes over a monotonic id space
  (17 tiers), shares escrowed to the diamond itself with a `proxyBalance`
  mirror, fulfillment strictly at the cursor with a `10000 ∓ incentive`
  discount factor.
- **Bridge**: burn on source, data-only CCIP message, mint on destination;
  `processedMessageId` replay guard; peer wiring timelocked after
  `finalizeSetup`.
- **Actors & trust**: `master` (timelocked config), custodian (off-chain
  backing), `workerAddress` (overhang sink), CCIP router (sole `ccipReceive`
  caller).

---

## SUP — supply, ERC20 & deposit cap

#### SUP-1 — supply never exceeds the deposit cap (global state invariant)
- **Predicate:** `totalSupply() ≤ totalDepositCap` — always, as a plain state
  invariant over every reachable state.
- **Why:** the cap check is the plain legacy form
  (`_checkDepositCap`: `totalSupply() + amount > totalDepositCap` reverts
  `DepositExceedCap`) on every local origination mint ({`deposit`, Permit2
  deposits, `mintSupply`, `compoundInterest`, compound-via-fulfill,
  constructor initial mint — supply starts 0}); relocations move cap and
  supply by the SAME amount on both ends (BRG-5: `_reduceDepositCap` after
  the relocation burn, `_raiseDepositCap` before the relocation mint);
  `burnSupply` only lowers supply; and `setTotalDepositCap` floors at the
  live `totalSupply()` (`DepositCapBelowSupply`). The predicate therefore
  holds inductively with no exception list — the former netting/exemption
  machinery (`bridgedInflow`, `_compoundPendingInterest`) is deleted, and
  the former NI-3 escape hatch is retired.
- **Foundry:** `invariant_supplyNeverExceedsCap` in
  `CapRelocationInvariant.t.sol` (handler drives deposits, compounds,
  bridge-out/deliver/replay, burnSupply and floored `setTotalDepositCap`).
- **Kontrol:** implied per-path by the BRG-5 room lemmas (exact cap/supply
  deltas) plus the floored-setter unit tests.
- **Status:** ACTIVE (stateful invariant; the old P0 gap is closed — the
  plain-state form became provable once NI-3 was retired).

#### SUP-2 — sum of balances equals totalSupply
- **Predicate:** `Σ_user balanceOf(user) == totalSupply()` across deposit /
  transfer / queue escrow / bridge / compound flows (benign
  transfer hook installed — see NI-8 for why the hook must be trusted).
- **Why:** all supply changes go through OZ `_mint`/`_burn`; transfers are
  balance-conserving; the queue moves shares to `address(this)` without
  minting.
- **Foundry:** ghost-sum handler over a closed actor set (actors + diamond +
  custodian + worker); assert equality in the invariant body.
- **Kontrol:** not a good symbolic target (unbounded actor set); rely on the
  stateful form.
- **Status:** GAP (P0).

#### SUP-3 — the owner-supply latch is monotone
- **Predicate:** once `supplyChangeByOwnerNotAllowed == true`, it stays true
  and `mintSupply`/`burnSupply` revert forever.
- **Why:** `disAllowSupplyChangeByOwner` sets the flag; nothing writes it
  false (`WiseTelecomNodesBaseHelper.sol`).
- **Foundry:** add `disallowSupplyChange` + mint/burn actions to the SUP-1
  handler; ghost-record the first flip; assert flag ∧ reverts thereafter.
- **Kontrol:** grep-level + one lemma: with flag set, both paths revert for
  all inputs.
- **Status:** GAP (P2).

#### SUP-4 — withdraw exactness
- **Status:** RETIRED. The direct principal `withdraw` surface
  (`withdraw`, `_validateWithdrawal`, `_executeWithdrawal`,
  `allowWithdraw`/`disallowWithdraw`) was removed from the diamond;
  the `withdrawAllowed` flag itself was deleted in the 2026-07 slot
  compaction (layout drift is caught by `script/check_storage_layout.sh`).
  Principal exits go through the exit queue (`leaveQue`/`reduceQueAmount`)
  and interest through the claim paths.

---

## INT — interest accrual, banking & moving

#### INT-1 — moving banked interest conserves the ledger *(this pass)*
- **Predicate:** `moveMyInterestTo` debits the sender by exactly the moved
  amount, credits the target by exactly the same amount, and never changes
  `Σ cashedInterest`; self-move is a no-op; targets `address(0)` and
  `InterestRateProxy` are impossible; overdraw and zero-moves revert with no
  state change.
- **Why:** [WiseTelecomNodesInterestHelper.sol:54-96](../../src/diamond/vault/helpers/WiseTelecomNodesInterestHelper.sol)
  subtracts and adds the same `moveAmount` under a `moveAmount ≤ available`
  guard; the facet entry adds `assignInterest` on both parties
  (`UserFacet.sol:129`), which banks pending interest first — accrual,
  not leakage.
- **Foundry:** `invariant_INT1_moveNeverChangesCashedSum` in
  [kontrol/InterestStatefulInvariant.t.sol](kontrol/InterestStatefulInvariant.t.sol)
  — the handler's `moveInterestFor` routes through the real facet and
  accumulates any deviation from the accrual-adjusted expected sum into a
  ghost (`moveSumDrift`), asserted zero.
- **Kontrol:** `testFuzz_INT1_moveConservesCashedSum`, `_moveSelfIsNoOp`,
  `_moveToForbiddenTargetReverts`, `_moveOverdrawReverts` in
  [kontrol/InterestProperties.t.sol](kontrol/InterestProperties.t.sol) via
  `exposedMoveInterestTo`.
- **Status:** PROVEN+FUZZED *(this pass)*.

#### INT-2 — the contract never accrues interest to itself
- **Status:** PROVEN+FUZZED — three Kontrol properties + two stateful
  invariants + the queue-side guard; see
  [kontrol/README.md](kontrol/README.md).

#### INT-3 — at a 20% rate no user accrues more than 20%/yr
- **Status:** PROVEN+FUZZED — three Kontrol properties plus the two boundary
  counterexamples (per-annum, base includes `proxyBalance`); see
  [kontrol/README.md](kontrol/README.md).

#### INT-4 — claims pay out exactly what they debit
- **Predicate:** `claimInterest` zeroes `cashedInterest` and transfers exactly
  the zeroed amount; `claimInterestExactAmount(x)` debits exactly `x` and
  reverts if `x > cashedInterest`; no claim path pays more than was banked.
- **Why:** `_prepareClaim` / `_prepareExactAmountClaim` in
  `WiseTelecomNodesInterestHelper.sol` debit before `safeTransfer`.
- **Foundry:** delta-assertions in an interest handler action (USD balance
  delta == ledger debit).
- **Kontrol:** two lemmas on `InterestProofHarness` with a `MockStable` USD
  (pattern: [kontrol/CursorProofHarness.sol](kontrol/CursorProofHarness.sol)).
- **Status:** GAP (P1).

#### INT-5 — compounding is deposit-equivalent
- **Predicate:** every compound converts banked interest into shares 1:1 AND
  pushes the same USD amount from the vault buffer to the custodian; the
  with-incentive variant splits `incentive + custodianTransfer ==
  bankedInterest` and cap-checks the **net** mint only.
- **Why:** `_handleCompoundInterest` / `_handleCompoundWithIncentive`
  (`WiseTelecomNodesInterestHelper.sol`) mint then `safeTransfer` to
  `thirdPartyAddress`.
- **Foundry:** delta-assertions on {shares minted, ledger debit, vault USD
  out, custodian USD in} around compound actions.
- **Kontrol:** conservation lemma per variant, symbolic banked amount and
  incentive bps.
- **Status:** GAP (P1).

#### INT-6 — accrual banking is idempotent within a block
- **Predicate:** after `_assignInterest(user)`: pending == 0 and
  `lastSyncTimeStamp == block.timestamp`; running it again in the same block
  changes nothing.
- **Why:** pending is 0 whenever `timestamp ≤ lastSync`
  (`getPendingInterestByTimeStamp`).
- **Kontrol:** one lemma on `InterestProofHarness` (`exposedAssignInterest`
  twice, symbolic state).
- **Status:** GAP (P2).

#### INT-7 — the global cashed-interest accumulator never drifts *(this pass)*
- **Predicate:** `totalCashedInterest == Σ_user cashedInterest[user]` after
  every operation, from the constructor onward (migration seed included,
  duplicate distribution addresses included); `moveMyInterestTo` leaves it
  unchanged; accrual adds exactly the banked pending; every claim / compound
  variant subtracts exactly the debited amount; every mutation emits
  `TotalCashedInterestChanged` with the new total.
- **Why:** the accumulator is written in lockstep at the four ledger sites —
  accrual
  ([WiseTelecomNodesInterestHelper.sol:70](../../src/diamond/vault/helpers/WiseTelecomNodesInterestHelper.sol)),
  full claim (`_prepareClaim`), exact-amount claim
  (`_prepareExactAmountClaim`) and the constructor migration delta-add
  ([WiseTelecomNodesDeclarations.sol](../../src/diamond/vault/declarations/WiseTelecomNodesDeclarations.sol),
  `_migrateInterest`); `_executeMoveInterestTo` is user→user net-zero and
  deliberately untouched. The accumulator feeds `_calculateNeededBuffer`
  (BUF-2 / BUF-3), so any drift under- or over-reserves the sweeper-gated
  sweep. Exposed via `CashedInterestFacet.getTotalCashedInterest()`
  (slot 64, `CashedInterestTotalDeclaration`).
- **Foundry:** `invariant_INT7_totalCashedEqualsLedgerSum` in
  [kontrol/InterestStatefulInvariant.t.sol](kontrol/InterestStatefulInvariant.t.sol)
  (closed actor set + contract; `claimExactFor` / `compoundFor` /
  `claimPartialAndCompoundFor` handler actions close the exact-amount path);
  per-path lockstep units in
  [WiseTelecomNodesTotalCashedInterest.t.sol](WiseTelecomNodesTotalCashedInterest.t.sol);
  migration seed incl. the duplicate-address edge in
  [WiseTelecomNodesAdminCoverage.t.sol](WiseTelecomNodesAdminCoverage.t.sol);
  bridge banking asserts in
  [WiseTelecomNodesBridge.t.sol](WiseTelecomNodesBridge.t.sol).
- **Kontrol:** delta-form lemmas `testFuzz_INT7_*` in
  [kontrol/InterestProperties.t.sol](kontrol/InterestProperties.t.sol) via
  `exposedAssignInterest` / `exposedPrepareClaim` /
  `exposedPrepareExactAmountClaim` (concrete actors, symbolic amounts;
  `harnessSetCashedInterest` bypasses the global by design, so lemmas seed a
  consistent pre-state or assert deltas). Prove run deferred — Σ-over-mapping
  needs symbolic keys, which do not terminate in KEVM.
- **Status:** FUZZED *(this pass)*; Kontrol prove deferred.

---

## QUE — order-book queue structure

#### QUE-1 … QUE-6 — existing machine-checked structure laws
| ID | Predicate | Coverage |
|----|-----------|----------|
| QUE-1 | `totalActiveOrders == Σ activeOrderCountByIncentive` | [invariant/QueueConservationInvariant.t.sol](invariant/QueueConservationInvariant.t.sol) |
| QUE-2 | `currentOrderIdByIncentive ≤ earliestValidQueMemberByIncentive` | same file |
| QUE-3 | linked-list walk from cursor counts exactly `activeOrderCountByIncentive` live nodes | same file |
| QUE-4 | `balanceOf(diamond) == Σ proxyBalance` (escrow conservation) | same file |
| QUE-5 | `switchQueIncentive` is value-neutral and order-conserving over all amounts | [kontrol/SwitchProperties.t.sol](kontrol/SwitchProperties.t.sol) + differential equivalence suite |
| QUE-6 | with-id views round-trip against storage and the id-less views | [invariant/OrdersWithIdInvariant.t.sol](invariant/OrdersWithIdInvariant.t.sol) |

#### QUE-7 — order ids are never reused
- **Predicate:** `earliestValidQueMemberByIncentive` strictly increases by 1
  on every insert and never decreases; a deleted id is never live again.
- **Why:** `_createQueMember` appends at the edge and post-increments it
  ([WiseTelecomNodesQueueLowLevelHelper.sol:97-131](../../src/diamond/vault/helpers/WiseTelecomNodesQueueLowLevelHelper.sol));
  nothing else writes the edge.
- **Foundry:** ghost `lastSeenEdge` per tier in the cursor handler; assert
  monotone; assert any id with `amount > 0` is `< edge`.
- **Status:** GAP (P1) — trivial addition to
  [invariant/QueueCursorInvariant.t.sol](invariant/QueueCursorInvariant.t.sol).

#### QUE-8 — only the cursor order can be processed
- **Predicate:** `fulfillOrder`/`partiallyFulfillOrder` succeed only for
  `id == currentOrderIdByIncentive` (strict FIFO; `OrderNotReady` otherwise).
- **Why:** `_validateOrderProcessing`
  ([WiseTelecomNodesQueueLowLevelHelper.sol:348-382](../../src/diamond/vault/helpers/WiseTelecomNodesQueueLowLevelHelper.sol)).
- **Kontrol:** one lemma: for any `id != cursor`, `_processOrder` reverts.
- **Status:** GAP (P2) — largely subsumed by QUE-10's fulfill lemmas.

#### QUE-9 — the discount round-trips exactly
- **Predicate:** a fulfillment pays `usd == amount · (10000 ∓ incentive) /
  10000` (floored, with the `discounted == 0 → amount` floor), and bulk
  fulfillment pays exactly the sum of its parts.
- **Why:** `_predictDiscountedAmount` / `_calculateDiscountFactor`
  (`WiseTelecomNodesQueueLowLevelHelper.sol`).
- **Kontrol:** pure-function lemma over symbolic amount × the 17 concrete
  tiers.
- **Status:** GAP (P2).

#### QUE-10 — the cursor is always the lowest live order id *(this pass)*
- **Predicate:** per incentive lane: `currentOrderIdByIncentive == min{ id :
  amount(id) > 0 }`; when the lane has no live order, the cursor is parked
  exactly at `earliestValidQueMemberByIncentive`. (This is the "earliest
  available member id is always the lowest unfulfilled order" law — strict
  FIFO expressed as state, not as an operation rule.)
- **Why:** ids append monotonically (QUE-7); the cursor moves **only** when
  the cursor node itself is removed, advancing to its `headPointer`
  ([WiseTelecomNodesQueueLowLevelHelper.sol:270-280](../../src/diamond/vault/helpers/WiseTelecomNodesQueueLowLevelHelper.sol),
  [WiseTelecomNodesQueueHelper.sol:70](../../src/diamond/vault/helpers/WiseTelecomNodesQueueHelper.sol));
  mid-list removals splice predecessor/successor pointers so the cursor
  node's forward chain always reaches the next live node, ending at the
  allocation edge.
- **Foundry:** `invariant_QUE10_cursorIsLowestActiveId` in
  [invariant/QueueCursorInvariant.t.sol](invariant/QueueCursorInvariant.t.sol)
  — extends the conservation handler with **arbitrary-id** leave / reduce /
  switch and partial-fulfill actions (the stock handler only ever touches the
  lane head, which could never desync the cursor).
- **Kontrol:** per-operation inductive lemmas in
  [kontrol/CursorProperties.t.sol](kontrol/CursorProperties.t.sol) — join,
  leave-head, leave-mid, leave-last (empty form), full fulfill (real
  `_processOrder`, USD leg included), partial fulfill — each over all
  amounts.
- **Status:** PROVEN+FUZZED *(this pass)*.

---

## QLV — liveness / no-stranding

#### QLV-1 — exit is unconditional
- **Predicate:** any queue member can always `leaveQue` (or `reduceQueAmount`)
  and receive exactly `member.amount` (`_reduceBy`) shares back in one
  transaction — regardless of pause state, `depositsDisabled`,
  `minDepositAmount` changes, or `negativeIncentivesNotAllowed`.
- **Why:** `leaveQue`/`reduceQueAmount` carry **no** `whenNotPaused` and no
  deposit gates — only membership + `nonReentrant`
  ([QueueJoinLeaveFacet.sol:76-188](../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol));
  compare `joinQue`/`switchQueIncentive`, which are `whenNotPaused`.
- **Foundry:** in the invariant body: snapshot → for every live order, prank
  the member and `leaveQue` → assert success and exact amount → revert
  snapshot. Run against a handler that toggles pause/gates adversarially.
- **Kontrol:** lemma: with pause flag symbolic and gates symbolic, the leave
  core succeeds for a valid member.
- **Status:** GAP (P0) — highest-value next test.

#### QLV-2 — exit survives lane blockage
- **Predicate:** even when the lane head cannot be *fulfilled* (e.g. the USD
  transfer to the head member reverts — token blocklist), every member
  including the head can still exit with full escrow.
- **Why:** fulfillment pays USD directly
  (`_executeTransfers`,
  [WiseTelecomNodesQueueLowLevelHelper.sol:384-401](../../src/diamond/vault/helpers/WiseTelecomNodesQueueLowLevelHelper.sol))
  but exit moves only vault shares — no USD leg. Note the flip side, NI-12:
  lane *fulfillment* has no unblocking mechanism.
- **Foundry:** handler with a blocklisting `MockUSD`; assert fulfills revert
  while exits succeed for all members.
- **Status:** GAP (P0).

#### QLV-3 — every live order is reachable from the cursor
- **Predicate:** following `headPointer` from the cursor visits every live
  order of the lane before reaching the allocation edge.
- **Why:** splice correctness in `_updateLinkedListPointers`; QUE-3 checks the
  *count* matches, this strengthens it to *set* reachability, and QUE-10
  pins the walk's starting point.
- **Foundry:** extend the QUE-3 walk to collect ids and compare against a
  scan of all ids `< edge` with `amount > 0`.
- **Status:** GAP (P1).

#### QLV-4 — hook changes cannot ambush escrowed members
- **Predicate:** a transfer-hook change never takes effect less than 3 days
  after being proposed (post-`finalizeSetup`), and incentive switches never
  invoke the hook at all — so members always have an exit window before a
  hostile hook can run on their escrow pay-out.
- **Why:** escrow moves run the swappable hook on join AND exit
  (`_moveVaultTokens`,
  [WiseTelecomNodesQueueLowLevelHelper.sol:70-95](../../src/diamond/vault/helpers/WiseTelecomNodesQueueLowLevelHelper.sol));
  the hook facet swap is timelocked (`WiseTelecomNodesBaseHelper.sol:182`);
  switch paths are deliberately hook-free
  ([QueueJoinLeaveFacet.sol:190-199](../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol)).
- **Foundry:** unit on the pending-hook window (propose hostile hook → all
  members can still exit before `executeTransferHookFacetChange` is
  possible). Ties to NI-8.
- **Status:** GAP (P2).

#### QLV-5 — a bridged share is never stranded in flight *(this pass)*
- **Predicate:** `processedMessageId[id] == true ⟺ the mint for id
  succeeded`. Equivalently: a failed delivery reverts wholesale (flag unset,
  nothing minted — so CCIP manual re-execution can retry), a successful
  delivery marks and mints exactly the payload amount, and a marked message
  can never mint again.
- **Why:** the flag write and the mint share one transaction
  ([WiseTelecomNodesCrossChainHelper.sol:334-431](../../src/diamond/vault/helpers/WiseTelecomNodesCrossChainHelper.sol));
  EVM atomicity lifts the per-execution lemmas to the history-level ⟺.
  `ccipReceive` is deliberately not pausable, and after the cap-relocation
  redesign it has NO economic revert path at all — only the router-auth,
  peer-enabled/match, replay-flag and zero-amount guards can reject a
  delivery (the destination cap is raised by the minted amount, so the
  mint cannot exceed it). Residual stranding window: NI-13.
- **Foundry+Kontrol:** `testFuzz_QLV5_replayAlwaysReverts`,
  `_successSetsFlagAndMintsExactly`, `_flagAndMintAreAtomic` (full ⟺ over
  symbolic gate flags), `_secondDeliverySameIdReverts`,
  `_referralShapeIsTransportOnly` in
  [kontrol/BridgeReceiveProperties.t.sol](kontrol/BridgeReceiveProperties.t.sol)
  over the real `_executeBridgeReceive` via
  [kontrol/BridgeReceiveProofHarness.sol](kontrol/BridgeReceiveProofHarness.sol).
  Payload pinned to its two length shapes (64-byte legacy and one
  referral-carrying encoding) — the decode branch is selected purely by
  length; amounts, pre-balances and gates stay symbolic, the message id is
  a concrete representative (symbolic mapping keys do not terminate in
  KEVM; the id dimension is fuzz-covered).
- **Status:** PROVEN+FUZZED *(this pass)*.

---

## BRG — peer transports (same-chain move + CCIP bridge)

#### BRG-1 — at most one mint per message id, stateful form
- **Predicate:** over any delivery/redelivery sequence: Σ minted == Σ distinct
  successfully-delivered messages' amounts.
- **Coverage:** per-execution form is QLV-5 *(this pass)*; unit replay test
  exists in `WiseTelecomNodesBridge.t.sol`. Stateful form: add a
  duplicate-delivery action to `BridgeInvariantHandler`
  ([invariant/BridgeConservationInvariant.t.sol](invariant/BridgeConservationInvariant.t.sol)).
- **Status:** GAP (P1), narrowed by QLV-5.

#### BRG-2 — combined peer supply is conserved
- **Predicate:** `vaultA.totalSupply() + vaultB.totalSupply()` constant across
  bridge round-trips (equal decimals; see NI-4 for the dust exception).
- **Status:** PROVEN (stateful) —
  [invariant/BridgeConservationInvariant.t.sol](invariant/BridgeConservationInvariant.t.sol).

#### BRG-3 — decimal scaling is exact
- **Predicate:** downscale: `srcAmount == dstAmount · factor + dust ∧ dust <
  factor`; upscale/equal: exact with `dust == 0`. The move-helper and
  cross-chain-helper scalers agree on all inputs.
- **Why:** `_scaleAmountForCrossChainPeer`
  ([WiseTelecomNodesCrossChainHelper.sol:539-570](../../src/diamond/vault/helpers/WiseTelecomNodesCrossChainHelper.sol))
  and its `WiseTelecomNodesMoveHelper.sol` sibling are two implementations of
  the same law — a lockstep proof also guards future drift.
- **Kontrol:** pure-function lemma, symbolic amount × concrete decimal pairs.
- **Status:** GAP (P1) — cheapest remaining proof.

#### BRG-4 — interest never crosses chains
- **Predicate:** bridging out leaves the sender's `cashedInterest` (including
  the just-banked pending) fully claimable on the source chain; delivery
  banks the receiver's prior pending before minting.
- **Why:** `assignInterest(msg.sender)` before the burn (facet entry),
  `_assignInterest(user)` before the mint
  (`WiseTelecomNodesCrossChainHelper.sol:400`).
- **Foundry:** delta-assertions in the bridge handler.
- **Status:** GAP (P2).

#### BRG-5 — relocations move the deposit cap with the shares (room neutrality)
- **Predicate:** define `room := totalDepositCap − totalSupply()` (both
  quantities uint; `totalSupply() ≤ totalDepositCap` by SUP-1). Every
  relocation is room-neutral on BOTH ends: a relocation burn
  (`_executeBridgeOut`, `_executeMoveOut`) drops `totalSupply` by `amount`
  and lowers `totalDepositCap` by the same `amount` via `_reduceDepositCap`;
  a relocation mint (`ccipReceive` receive, same-chain `mintFromPeer`)
  raises `totalDepositCap` by the minted amount via `_raiseDepositCap`
  BEFORE the `_mint` of the same amount. Consequently: (a) room is invariant
  under every user relocation, so no bridge/move can ever grant or strand
  local deposit budget (kills both the round-trip over-mint and the
  local-burn cap-tightening DoS of the former exemption-ledger model);
  (b) the mesh-wide `Σ totalDepositCap` is conserved by user flows — only
  master `setTotalDepositCap` calls change it (decimal-truncation dust and
  in-flight CCIP messages deflate it, never inflate); (c) `burnSupply` is a
  plain burn (cap untouched) — the one supply change that FREES room. Every
  relocation cap write emits `DepositCapRelocated(newTotalDepositCap)`.
- **Why:** the cap deltas are the exact local `_burn` / `_mint` amounts at
  the four relocation sites
  ([WiseTelecomNodesCrossChainHelper.sol](../../src/diamond/vault/helpers/WiseTelecomNodesCrossChainHelper.sol),
  [WiseTelecomNodesMoveHelper.sol](../../src/diamond/vault/helpers/WiseTelecomNodesMoveHelper.sol),
  mutators in
  [WiseTelecomNodesBaseHelper.sol](../../src/diamond/vault/helpers/WiseTelecomNodesBaseHelper.sol));
  the checked `-=` in `_reduceDepositCap` cannot underflow because
  `amount ≤ balanceOf(sender) ≤ totalSupply() ≤ totalDepositCap` (SUP-1)
  at the call site.
- **Foundry:** `invariant_relocationPreservesRoom`,
  `invariant_supplyNeverExceedsCap`
  ([invariant/CapRelocationInvariant.t.sol](invariant/CapRelocationInvariant.t.sol));
  `invariant_combinedCapConserved`
  ([invariant/BridgeConservationInvariant.t.sol](invariant/BridgeConservationInvariant.t.sol));
  unit suite
  [WiseTelecomNodesCapRelocation.t.sol](WiseTelecomNodesCapRelocation.t.sol)
  (incl. the audit-DoS repro and round-trip conservation regressions).
- **Kontrol:** `testFuzz_BRG5_receivePreservesRoom`,
  `testFuzz_BRG5_bridgeOutPreservesRoom` (dual-engine,
  [kontrol/BridgeHeadroomProperties.t.sol](kontrol/BridgeHeadroomProperties.t.sol)
  over its own inherit harness so the cached QLV-5 proofs stay valid).
- **Status:** FUZZED (units + stateful) *(this pass)*; Kontrol symbolic
  re-run pending (proof sources updated, `kontrol prove` not yet re-run).

#### BRG-6 — RETIRED: chain-wide global supply cap
- **Status:** RETIRED *(this pass)*. The `globalSupplyCap`/`globalCapVaults`
  import gate (former slots 65–66, `_checkGlobalSupplyCap`, the
  `GlobalSupplyCapExceeded` revert and the armed-cap-retryability lemma) was
  removed together with the exemption-ledger cap model: under cap-relocation
  the mesh-wide `Σ totalDepositCap` is conserved by user flows (BRG-5), so
  the per-chain caps ARE the global budget and the separate chain-wide
  ceiling is redundant — and an armed per-chain ceiling would false-positive
  on legitimate bridge-ins (a chain's cap legitimately grows with imports).
  Accepted trade-off: no belt-and-suspenders bound against a compromised
  peer vault minting via `ccipReceive` (peers share the master trust domain;
  the peer registry itself is timelocked).

---

## TLK — governance timelocks & latches

#### TLK-1 — one state machine, six families
- **Predicate:** for every timelocked change — thirdParty
  (`WiseTelecomNodesBaseHelper.sol:115`), transferHook (`:182`), worker
  (`:232`), crossChainPeer
  ([WiseTelecomNodesCrossChainHelper.sol:118-215](../../src/diamond/vault/helpers/WiseTelecomNodesCrossChainHelper.sol)),
  peerVault (`WiseTelecomNodesMoveHelper.sol`), selector routing
  ([WiseTelecomNodesDiamond.sol:72-135](../../src/diamond/vault/WiseTelecomNodesDiamond.sol)) —
  the same law holds: *execute* requires `queuedAt > 0 ∧ now ≥ queuedAt +
  DELAY` (crossChainPeer and selector routing skip the delay only while
  `initialized == false`); *execute* applies exactly the proposed value;
  *execute*/*cancel*/*remove* reset the staging slots to zero; the live value
  changes **only** on execute.
- **Foundry:** one table-driven stateful test parametrized over the six
  families (propose/execute/cancel/warp actions; assert staged-vs-live at
  every step). Units exist per family across 8 test files; the table form is
  the gap.
- **Kontrol:** per-family lemmas: `execute` before the deadline reverts;
  post-execute state equals proposed.
- **Status:** GAP (P0).

#### TLK-2 — `initialized` is a monotone latch
- **Predicate:** once `finalizeSetup` runs
  ([WiseTelecomNodesDiamond.sol:39](../../src/diamond/vault/WiseTelecomNodesDiamond.sol)),
  `initialized` never resets and every fast path (instant selector change,
  instant peer enable) is dead forever.
- **Status:** GAP (P2).

---

## BWI — WISE burn rotation

#### BWI-1 — the rotation index cycles exactly
- **Predicate:** `burnWiseIndex ∈ [0,5]` always; each successful `burnWise`
  advances it by exactly `+1 mod 6`.
- **Foundry:** small dedicated handler (burn + warp actions); ghost-track the
  index sequence.
- **Status:** GAP (P1).

#### BWI-2 — the per-caller cooldown holds
- **Predicate:** two successful `burnWise` calls from the same address are
  ≥ 1 day apart (`BURN_WISE_COOLDOWN`); a first-ever call is always allowed.
- **Foundry:** same handler as BWI-1; record per-caller success timestamps.
- **Status:** GAP (P1).

#### BWI-3 — the burn slice matches the schedule
- **Predicate:** burn amount == `balance · sliceBps / 10000` for the schedule
  `[500, 1000, 2000, 1500, 500, 100]`, or the full balance when it is
  ≤ 50e18 (`BurnWiseFacet.sol`).
- **Status:** covered by units (`WiseTelecomNodesBurnWiseFacet*.t.sol`);
  see NI-9 for the view-function caveat.

---

## BUF — buffer & overhang sweep

#### BUF-1 — the buffer rate never falls below the live rate
- **Predicate:** `bufferInterestRate ≥ interestRate` always;
  `bufferInterestRate` is monotone non-decreasing.
- **Why:** the only writes are the constructor and the ratchet in
  `_updateInterestRate` (`WiseTelecomNodesBaseHelper.sol:78`), which raises it
  and never lowers it; `interestRate ≤ MAX_INTEREST_RATE = 20_000`
  ([ConfigDeclaration.sol:44](../../src/diamond/vault/declarations/ConfigDeclaration.sol)).
- **Foundry:** trivial ghost in any handler with a `setRate` action (the
  interest handler already has one).
- **Kontrol:** one lemma on `_updateInterestRate` with symbolic old/new rates.
- **Status:** GAP (P1) — cheapest stateful add.

#### BUF-2 — sweeping pays only the worker and only the true overhang *(this pass)*
- **Predicate:** after a successful `sweepOverhang`: vault USD balance ==
  `totalSupply · bufferInterestRate · 14d / year + totalCashedInterest` — the
  two-week forward buffer **plus** the settled, already-claimable interest
  liability — the entire difference went to `workerAddress`, and no shares
  moved. With `totalSupply == 0` the needed buffer is exactly
  `totalCashedInterest`.
- **Why:** `_calculateNeededBuffer` (`WiseTelecomNodesBufferHelper.sol`)
  reserves the banked `cashedInterest` ledger via the INT-7 accumulator, so
  the sweep can no longer strand accrued claims; `_executeSweepOverhang` additionally
  gates the caller on the master-set `isSweeper` allowlist (`NotSweeper`;
  seeded at genesis with worker, third party and deployer — pending master
  on the bootstrap path, which revokes the inert shim — further grants via
  the instant `setSweeper`). `getOverhang` stays an open view.
- **Foundry:** repro + boundary units in
  [WiseTelecomNodesSweepFacet.t.sol](WiseTelecomNodesSweepFacet.t.sol)
  (reserve exactness, claim-after-sweep liveness, `NoOverhang` at the full
  reserve, zero-supply-with-liability, ratchet + liability compounding).
- **Status:** covered by units *(this pass)*; the stateful form is BUF-3.

#### BUF-3 — a sweep never takes the balance below the reserved liability *(this pass)*
- **Predicate:** across any operation sequence, every successful
  `sweepOverhang` leaves `USD.balanceOf(vault)` exactly equal to the needed
  buffer at that moment (⇒ never below `totalCashedInterest`). Sweep-local
  only: `balance ≥ totalCashedInterest` is NOT a global invariant — claims,
  compounds and queue exits legitimately spend the buffer (custodian model,
  NI-5).
- **Foundry:** `invariant_BUF3_sweepNeverTakesReservedLiability` — `sweep`
  handler action (top-up, sweep, mirrored-reserve check) + violation ghost in
  [kontrol/InterestStatefulInvariant.t.sol](kontrol/InterestStatefulInvariant.t.sol).
- **Kontrol:** not this pass; the fuzz form plus the BUF-2 units are adequate.
- **Status:** FUZZED *(this pass)*.

---

## REF — referral transport scaffold

#### REF-1 — referral bytes are transport-only
- **Predicate:** referral data never changes what is minted; payloads longer
  than `MAX_REFERRAL_BYTES = 256` cannot be sent; 64-byte legacy payloads
  decode referral-free; `referralEnabled == false` behaves exactly
  pre-referral except for event emission.
- **Coverage:** the receive-side half is proven by
  `testFuzz_QLV5_referralShapeIsTransportOnly` *(this pass)*; the send-side
  length cap and a full send→receive differential remain.
- **Status:** partially PROVEN *(this pass)*; remainder GAP (P2) until the
  referral system lands.

---

## Non-invariants & deliberate asymmetries (NI)

Things that **look** like invariants but are false or conditional — each is a
wrong test someone would naively write.

- **NI-1 — `ccipReceive` minting is never blocked by the deposit cap.**
  Deliberate: already-burned source shares must always be mintable; a cap
  revert would strand them (see `test_ccipReceive_atFullCap_stillMints()` in
  `WiseTelecomNodesBridge.t.sol`). Under cap-relocation this is structural,
  not an exemption: `_raiseDepositCap(amount)` runs before the `_mint`, so
  the delivery can mathematically never violate SUP-1 and no cap check
  exists on the path — `ccipReceive` has no economic revert condition at
  all (QLV-5). Don't naively test "receive reverts at cap": the cap moves.
- **NI-2 — same-chain `mintFromPeer` is relocation-neutral, NOT cap-gated.**
  Like `ccipReceive` (NI-1), the move-in path
  ([WiseTelecomNodesMoveHelper.sol](../../src/diamond/vault/helpers/WiseTelecomNodesMoveHelper.sol))
  raises the destination `totalDepositCap` by the minted amount before the
  mint (BRG-5): a `moveBetweenVaults` takes the source's cap budget with the
  burned shares (`_reduceDepositCap` after the burn) and lands it on the
  destination, so the move is room-neutral on both ends, never reverts
  `DepositExceedCap`, and never bricks a migration into a zero-room peer.
- **NI-3 — RETIRED: `setTotalDepositCap` now floors at the live supply.**
  The former no-floor behavior (cap below supply, supply legally exceeding
  it) is gone — the setter reverts `DepositCapBelowSupply` when
  `newCap < totalSupply()`, which is what makes SUP-1 a plain global state
  invariant and the relocation `-=` underflow-free. The hard deposit freeze
  remains `depositsDisabled`, not the cap (a cap equal to supply gives room
  0 but still admits inbound relocations).
- **NI-4 — cross-chain supply is conserved only modulo dust.** Downscaling
  decimals drops `srcAmount % factor` (burned at source, never minted;
  `MoveDust` emitted). Equal-decimal lanes conserve exactly (BRG-2).
- **NI-5 — buffer solvency is custodian liveness, not on-chain safety.**
  Deposits forward USD out; claims and queue exits depend on the custodian
  refilling the buffer. Don't write an "always solvent" invariant.
- **NI-6 — the 20% interest bound is per annum, not absolute.** Two years
  accrues ~40%. The boundary proofs pin this
  ([kontrol/README.md](kontrol/README.md)).
- **NI-7 — the min-deposit floor is entry-only.** `joinQue` and
  `reduceQueAmount` enforce it, but a partial fulfillment decrements
  `member.amount` with no remainder floor
  (`_processOrder` vs `_executeReduction`,
  [WiseTelecomNodesQueueLowLevelHelper.sol:200-217](../../src/diamond/vault/helpers/WiseTelecomNodesQueueLowLevelHelper.sol))
  — a live order below `minDepositAmount` is reachable. **Open question for
  the maintainer:** is the missing remainder floor on partial fulfill
  intended?
- **NI-8 — Σ-balances conservation is not defensible against a malicious
  transfer hook.** The hook is a raw delegatecall
  (`_runTransferHook`,
  [WiseTelecomNodesInterestHelper.sol:98-126](../../src/diamond/vault/helpers/WiseTelecomNodesInterestHelper.sol))
  that can write any slot; the guard is the 3-day timelock + master trust
  (QLV-4). SUP-2 tests must install a benign hook.
- **NI-9 — `getNextBurnPercentage` ignores the ≤ 50-WISE full-sweep
  override.** The view reports the schedule slice; the actual burn may be
  100%.
- **NI-10 — RESOLVED (2026-07 slot compaction).** The never-written gap
  fields (`transferInterestWithTokens`, `interestRateProxyPermanent`,
  `withdrawAllowed`, `autoCompoundAllowed`, `autoCompoundIncentive`,
  `isWhiteListed`) were deleted and the layout renumbered; facet layout
  identity is now enforced by `script/check_storage_layout.sh` in CI.
- **NI-11 — `ProxyFacet` is unreachable surface.** Its gate requires
  `msg.sender == InterestRateProxy == address(this)`, which no external
  caller can satisfy (no setter exists). A cheap invariant: all three
  selectors revert for every caller.
- **NI-12 — lane fulfillment is not DoS-proof.** Strict FIFO + direct USD
  payment means a payment-reverting head (e.g. a blocklisted address) blocks
  its lane's fulfillment indefinitely: bulk fulfill is atomic with no skip
  (`_fulfillOrderBulk`,
  [WiseTelecomNodesQueueHelper.sol:97-153](../../src/diamond/vault/helpers/WiseTelecomNodesQueueHelper.sol))
  and `QueueAdminFacet` has no eviction. Exits stay open (QLV-2).
  **Open question for the maintainer:** is a skip/eviction mechanism wanted?
- **NI-13 — in-flight bridge messages can be stranded ≥ 3 days.**
  `removeCrossChainPeer` disables a lane instantly; re-enabling takes the
  timelock. Messages in flight during the window fail delivery but stay
  retryable (QLV-5 guarantees the flag is not consumed). Under
  cap-relocation an in-flight message also carries cap budget (source cap
  already reduced, destination not yet raised), so a permanently
  undelivered message deflates the mesh Σ caps by the burned amount —
  conservative direction; master recovers via `setTotalDepositCap` on the
  intended destination.
- **NI-14 — the deposit accumulator ships dormant.** Genesis deploys install
  `GraceAccumHookFacet` as `depositHookFacet`, but no script ever sets
  `depositAccumWindow`; at `0` the hook reproduces the inline single-call
  threshold check exactly, so split deposits still dodge the grace stamp
  until master arms the window (`setDepositAccumWindow`, instant, no
  timelock, capped at `MAX_GRACE_PERIOD`). An upgraded diamond that never
  installs the facet keeps the inline path byte for byte. Armed, the
  accumulator is two-bucket adjacent-sum: per-user buckets of `W` seconds,
  with the previous bucket's total always tested together with the current
  one, so deposits ≤ `W` apart are guaranteed to co-count (a boundary
  straddle cannot split them), deposits up to `2W − 1` apart may co-count,
  and deposits ≥ `2W` apart never do. Known residuals once armed: shrinking
  an armed window below half its current value in one step opens a one-shot
  straddle around the admin tx (ops rule: shrink in at most halving steps,
  spaced ≥ the new window apart; growing and disarm/re-arm are safe),
  splitting across peer vaults / chains still dodges (`mintFromPeer` /
  `ccipReceive` never stamp, by design), and compound-minted deltas count
  toward the buckets — principal above `10k · 365d / (APR · 2W)`
  accumulates to threshold by routine compounding (at 20% APR: W=45d →
  ~203k, W=7d → ~1.3M, W=1d → ~9.13M), so arm with a short burst window
  (≤ 7d); halving W recovers the old compounding envelope while keeping a
  strictly stronger split guarantee.
- **NI-15 — RESOLVED (cap-relocation): mesh-wide origination IS bounded by
  Σ per-chain caps.** Under the former exemption-ledger model, bridging out
  freed local budget, so lifetime mesh origination could exceed `Σ caps`.
  Under cap-relocation the budget travels with the shares: room is invariant
  under every relocation (BRG-5), so `Σ totalSupply ≤ Σ totalDepositCap`
  holds mesh-wide and `Σ totalDepositCap` changes only via master
  `setTotalDepositCap`. The per-chain caps are therefore the global budget
  split — the open pre-genesis sizing question in ADD_A_CHAIN.md is settled
  by construction. (The mesh-wide sum invariant IS now a valid test target:
  `invariant_combinedCapConserved`.)
- **NI-16 — same-chain `moveBetweenVaults` is fully relocation-neutral.**
  The source's `_executeMoveOut` burns and lowers its cap by the full moved
  amount (`_reduceDepositCap`), the destination's `_executeMintFromPeer`
  raises its cap by the scaled amount before minting (NI-2) — room invariant
  on both ends, machine-checked as **MOV-1** in
  [kontrol/MoveOutProperties.t.sol](kontrol/MoveOutProperties.t.sol).
  Pending interest no longer interacts with the move at all: the
  `assignInterest(msg.sender)` modifier banks it into `cashedInterest` on
  the source (exactly like `bridgeToVault`; the former force-compound with
  burn-netting and its `_compoundPendingInterest` helper are deleted), so a
  move can never revert `DepositExceedCap` and banked interest stays
  claimable on the source. Note the moved cap budget crosses product
  boundaries on a chain (wtnUSDC⇄wtnUSDT pairs) — mesh Σ caps is still
  conserved. `MoveFacet` is not wired in the production deploy scripts
  today, but the accounting keeps SUP-1 sound if the facet is ever
  installed.

---

## Coverage map (file → IDs)

| File | Covers |
|------|--------|
| [kontrol/InterestProperties.t.sol](kontrol/InterestProperties.t.sol) | INT-1 (proof), INT-2, INT-3, INT-7 (delta lemmas) |
| [kontrol/InterestStatefulInvariant.t.sol](kontrol/InterestStatefulInvariant.t.sol) | INT-1 (stateful), INT-2, INT-7 (stateful), BUF-3 |
| [kontrol/SwitchProperties.t.sol](kontrol/SwitchProperties.t.sol) | QUE-5 |
| [kontrol/CursorProperties.t.sol](kontrol/CursorProperties.t.sol) | QUE-10 (proof), QUE-8 (partially) |
| [kontrol/BridgeReceiveProperties.t.sol](kontrol/BridgeReceiveProperties.t.sol) | QLV-5, BRG-1 (per-execution), REF-1 (receive side) |
| [kontrol/BridgeHeadroomProperties.t.sol](kontrol/BridgeHeadroomProperties.t.sol) | BRG-5 (dual-engine room-neutrality lemmas, both directions) |
| [kontrol/MoveOutProperties.t.sol](kontrol/MoveOutProperties.t.sol) | MOV-1 / BRG-5 room neutrality under same-chain move-out (dual-engine + concrete discriminator) |
| [invariant/QueueConservationInvariant.t.sol](invariant/QueueConservationInvariant.t.sol) | QUE-1..4, INT-2 (queue side) |
| [invariant/QueueCursorInvariant.t.sol](invariant/QueueCursorInvariant.t.sol) | QUE-10 (stateful) |
| [invariant/OrdersWithIdInvariant.t.sol](invariant/OrdersWithIdInvariant.t.sol) | QUE-6 |
| [invariant/BridgeConservationInvariant.t.sol](invariant/BridgeConservationInvariant.t.sol) | BRG-2, BRG-5 (Σ-cap conservation) |
| [invariant/CapRelocationInvariant.t.sol](invariant/CapRelocationInvariant.t.sol) | BRG-5 (stateful room neutrality), SUP-1 (stateful) |
| [WiseTelecomNodesCapRelocation.t.sol](WiseTelecomNodesCapRelocation.t.sol) | BRG-5 (units, DoS-repro + round-trip regressions), SUP-1 (boundaries) |
| `WiseTelecomNodesSwitchQueIncentiveEquivalence.t.sol` | QUE-5 (differential) |
| `WiseTelecomNodesBridge.t.sol` | BRG-1 (unit), NI-1 (intent), INT-7 (bridge banking) |
| `WiseTelecomNodesBurnWiseFacet*.t.sol` | BWI-3 (units) |
| [WiseTelecomNodesTotalCashedInterest.t.sol](WiseTelecomNodesTotalCashedInterest.t.sol) | INT-7 (per-path units) |
| `WiseTelecomNodesSweepFacet.t.sol` | BUF-2 (units) |
| `WiseTelecomNodesAdminCoverage.t.sol` | INT-7 (migration seed) |

Proof methodology, engine setup and assumptions:
[kontrol/README.md](kontrol/README.md) — single source, not restated here.

---

## Fixtures to reuse

| Fixture | Where | Use for |
|---------|-------|---------|
| `DiamondTestHarness` | [utils/DiamondTestHarness.sol](utils/DiamondTestHarness.sol) | deploy + wire + finalize any diamond variant |
| `QueueInvariantHandler` | [invariant/QueueConservationInvariant.t.sol](invariant/QueueConservationInvariant.t.sol) | queue action driving; subclass for new actions (see `QueueCursorHandler`) |
| `QueueCursorHandler` | [invariant/QueueCursorInvariant.t.sol](invariant/QueueCursorInvariant.t.sol) | queue driving incl. arbitrary-id removals |
| `BridgeInvariantHandler` + `MockCCIPRouter` | [invariant/BridgeConservationInvariant.t.sol](invariant/BridgeConservationInvariant.t.sol) | two-vault bridge sequences |
| `InterestInvariantHandler` | [kontrol/InterestStatefulInvariant.t.sol](kontrol/InterestStatefulInvariant.t.sol) | interest flows incl. adversarial moves + INT-1 ghost |
| `InterestProofHarness` | [kontrol/InterestProofHarness.sol](kontrol/InterestProofHarness.sol) | Kontrol lemmas over interest internals |
| `SwitchProofHarness` / `CursorProofHarness` | kontrol/ | Kontrol lemmas over queue internals (+ `MockStable` for USD legs) |
| `BridgeReceiveProofHarness` | [kontrol/BridgeReceiveProofHarness.sol](kontrol/BridgeReceiveProofHarness.sol) | Kontrol lemmas over `ccipReceive` |

Budget convention: inline `/// forge-config: default.invariant.runs` /
`.depth` comments (existing suites use 64–128 × 30–64); there is no global
`[invariant]` section in `foundry.toml`.

---

## Priority queue for new tests

| Rank | ID | One-liner |
|------|----|-----------|
| P0 | QLV-1 | every member can always exit with exactly their escrow |
| P0 | QLV-2 | exits survive a fulfillment-blocked lane |
| P0 | SUP-1 | cap post-condition across every gated mint path |
| P0 | SUP-2 | Σ balances == totalSupply (benign hook) |
| P0 | TLK-1 | table-driven six-family timelock state machine |
| P1 | BRG-3 | scaling/dust exactness (cheapest proof) |
| P1 | BUF-1 | buffer-rate ratchet (cheapest stateful add) |
| P1 | INT-4, INT-5 | claim/compound exactness |
| P1 | QUE-7, QLV-3 | id non-reuse + cursor reachability (extend cursor suite) |
| P1 | BRG-1 | replay guard, stateful form |
| P1 | BWI-1, BWI-2 | burn rotation + cooldown |
| P2 | rest | SUP-3/4, INT-6, QUE-8/9, QLV-4, BRG-4, TLK-2, REF-1 |

Implemented with this document: **QUE-10**, **INT-1**, **QLV-5** (each as a
Foundry test + Kontrol dual-engine proof); **INT-7**, **BUF-2**, **BUF-3**
*(sweep-liability pass: units + stateful fuzz, Kontrol prove deferred)*.
