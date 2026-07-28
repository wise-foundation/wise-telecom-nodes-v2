# Diamond invariants — fuzzed + formally verified

This suite proves properties of the non-legacy WiseTelecomNodes diamond:
the interest engine, the queue cursor law and the bridge-receive atomicity
law. The catalog these proofs belong to (with every known invariant, its
status and its recommended test vehicle) is
[`test/diamond/INVARIANTS.md`](../INVARIANTS.md).

The two headline interest guarantees
(`src/diamond/vault/helpers/WiseTelecomNodesInterestHelper.sol`):

1. **The contract never accumulates interest.** The diamond itself
   (`InterestRateProxy == address(this)`, constructor-fixed, no setter) holds
   zero pending and zero cashed interest in every reachable state.
2. **At a 20% rate, no user accrues more than 20% in a year.** With
   `interestRate = 2000` (= 20% of `PRECISION_RATE = 10000`), a user's pending
   interest over any window of at most one year is at most 20% of their
   interest base (`balanceOf + proxyBalance`).

Each property is checked by two independent engines on the **same** test
functions: Foundry fuzzing (random sampling) and Kontrol / KEVM symbolic
execution (every input, machine-checked).

## Files

| File | Role |
|------|------|
| `InterestProofHarness.sol` | Inherits the real `WiseTelecomNodesDiamond`; exposes the internal accrual primitives (incl. `exposedMoveInterestTo`) + narrow storage setters. No logic is altered. |
| `InterestProperties.t.sol` | 12 dual-engine properties (`testFuzz_*`) — the two interest guarantees, their adversarial boundaries, and the INT-1 `moveMyInterestTo` conservation laws. |
| `InterestStatefulInvariant.t.sol` | Foundry stateful invariants: a handler drives the real facets (fallback + DELEGATECALL) through random sequences, including adversarial moves, asserting the contract never accrues and that interest moves never change the cashed ledger sum (INT-1). |
| `SwitchProofHarness.sol` | Inherits the real queue helper chain; `exposedSwitchCore` replays the exact internal-helper sequence of `switchQueIncentive`. No logic is altered. |
| `SwitchProperties.t.sol` | 2 dual-engine properties (`testFuzz_*`) for `switchQueIncentive` — value-neutrality and order/amount conservation, over all amounts. |
| `CursorProofHarness.sol` | Inherits the real queue helper chain; seeds live orders via the real insert path, replays the `leaveQue` mutation sequence and calls the real `_processOrder` (USD leg over a minimal `MockStable`). No logic is altered. |
| `CursorProperties.t.sol` | 6 dual-engine properties for QUE-10, the strict-FIFO cursor law — one inductive lemma per queue mutation (join, leave-head, leave-mid, leave-last, full fulfill, partial fulfill), over all amounts. |
| `BridgeReceiveProofHarness.sol` | Inherits the real `WiseTelecomNodesDiamond`; forwards verbatim into `_executeBridgeReceive` + narrow storage writers that place a routed lane without walking the governance timelock. No logic is altered. |
| `BridgeReceiveProperties.t.sol` | 5 dual-engine properties for QLV-5, the bridge-receive atomicity law `processedMessageId[id] ⟺ mint succeeded`; each also pins the cap-relocation delta (`totalDepositCap` raised by exactly the minted amount, untouched on any revert). |
| `BridgeHeadroomProofHarness.sol` | Inherits the real `WiseTelecomNodesDiamond`; forwards verbatim into `_executeBridgeReceive` / `_executeBridgeOut` + writers that seed a routed lane and the deposit cap (`harnessSetCap`, bypassing only the setter's supply floor). No logic is altered. |
| `BridgeHeadroomProperties.t.sol` | 2 dual-engine properties for BRG-5, the cap-relocation room law `room := totalDepositCap − totalSupply`: a receive raises cap and supply by the same amount (room invariant), a bridge-out lowers both by the same amount (room invariant), each or reverts wholesale leaving both untouched. |
| `MoveOutProofHarness.sol` | Inherits the real `WiseTelecomNodesDiamond`; forwards verbatim into `_executeMoveOut` + writers that seed a registered same-chain peer, a symbolic cap and the mover's balance / last-sync. No logic is altered. |
| `MoveOutProperties.t.sol` | 1 dual-engine property + 1 concrete discriminator for MOV-1, the same-chain move-out cap-relocation law: a successful move lowers `totalDepositCap` and `totalSupply` by exactly the moved amount (room invariant, no interest mint at this layer), a reverting move touches neither; the concrete at-cap case fails against an implementation that forgets the cap reduce or cap-gates the move like a deposit. |

## `switchQueIncentive` proofs

`switchQueIncentive` / `switchQueIncentivePartial` move an order between incentive
queues without the leave-then-rejoin token round-trip. `SwitchProperties.t.sol`
proves, over **all** amounts (incentive tiers concrete `0 → 100` so mapping slots
stay concrete for the symbolic engine):

- `testFuzz_switchIsValueNeutral` — a switch mints/burns/transfers nothing and its
  `-amount`/`+amount` proxy accounting round-trips, so `totalSupply`, the owner's
  token balance and the owner's `proxyBalance` are invariant.
- `testFuzz_switchConservesOrders` — a switch moves exactly one order from the
  source count to the destination count, leaving `totalActiveOrders` and the moved
  amount unchanged (the queue-conservation invariant).

Byte-for-byte storage equivalence to the two-call baselines (`leaveQue`+`joinQue`,
`reduceQueAmount`+`joinQue`) is covered by example in
`test/diamond/WiseTelecomNodesSwitchQueIncentiveEquivalence.t.sol`; the stateful
conservation + "contract accrues nothing" guards live in
`test/diamond/invariant/QueueConservationInvariant.t.sol`.

## The interest formula

```
base     = balanceOf(user) + proxyBalance[user]
yearFac  = Δt * 1e18 / SECONDS_IN_YEAR          // SECONDS_IN_YEAR = 31_540_000
interest = base * interestRate * yearFac / PRECISION_RATE / 1e18
```

At `interestRate = 2000` and `Δt = 1 year`, `yearFac = 1e18` and
`interest = base * 2000 / 10000 = base / 5` exactly — 20%.

## Proven properties (all PASSED in Kontrol)

**Property 1 — contract never accrues**

- `testFuzz_ContractPendingInterestAlwaysZero` — for any contract balance,
  proxy balance, last-sync, query timestamp and rate, `getPendingInterest(contract) == 0`.
- `testFuzz_AssignInterestToContractKeepsCashedConstant` — running the proxy
  accrual path with the contract named as its **own benefactor** (the most
  dangerous configuration) leaves `cashedInterest[contract]` unchanged, for any
  balance / proxy balance / rate / pre-existing cashed amount.
- `testFuzz_TransferTokensToContractAccruesNoInterest` — end-to-end through the
  real ERC20 `transfer` override: a user pushes vault tokens to the contract, so
  it genuinely holds a balance; after any elapsed time it still owes 0 / 0.

**Property 2 — 20% cap at a 20% rate**

- `testFuzz_PendingNeverExceeds20PercentWithinOneYear` — for any base and any
  `Δt ≤ 1 year`, `pending ≤ base / 5`. *(Symbolic Δt — the nonlinear case.)*
- `testFuzz_PendingExactlyTwentyPercentAtOneYear` — at exactly one year,
  `pending == base / 5` exactly. The rate delivers precisely 20%/yr — never less
  through rounding, never more.
- `testFuzz_InterestNeverExceedsNominalLinear` — over any `Δt ≤ 100 years`, the
  credited interest never exceeds the exact linear entitlement
  `base * rate * Δt / (year * 10000)`. Integer flooring always rounds in the
  protocol's favour; no user is ever over-credited, even after decades.

**Adversarial / boundary ("try to break it")**

- `testFuzz_BoundaryTwoYearsExceedsTwentyPercent` — over two years the user is
  owed ~40% > 20%. The 20% guarantee is **per annum**; the one-year bound above
  is necessary, not incidental. (This is the counterexample Kontrol returns for
  an unbounded-time version of the cap.)
- `testFuzz_BoundaryProxyBalanceBeatsBalanceOfBound` — with proxy balance
  present, one-year interest exceeds 20% of the plain token balance while still
  respecting 20% of the full base. The cap is on `balanceOf + proxyBalance`, not
  `balanceOf` alone.

## `moveMyInterestTo` proofs (INT-1)

Over all ledger balances (≤ the overflow ceiling), all amounts and both move
modes (exact-amount / move-all):

- `testFuzz_INT1_moveConservesCashedSum` — a move debits the sender by exactly
  the moved amount, credits the target by exactly the same amount, and never
  changes the total cashed interest.
- `testFuzz_INT1_moveSelfIsNoOp` — a self-move touches nothing (the self-guard
  short-circuits before validation).
- `testFuzz_INT1_moveToForbiddenTargetReverts` — the zero address and the
  InterestRateProxy can never be credited; the attempt reverts state-free.
- `testFuzz_INT1_moveOverdrawReverts` — zero-moves and moves above the
  available balance revert state-free; the sender can never go negative.

The stateful complement is `invariant_INT1_moveNeverChangesCashedSum`
(`InterestStatefulInvariant.t.sol`): the handler routes `moveMyInterestTo`
through the real facet, nets out the accrual the `assignInterest` modifiers
legitimately bank, and accumulates any residual ledger drift into a ghost
that must stay zero.

## Cursor proofs (QUE-10)

The strict-FIFO cursor law: per incentive lane,
`currentOrderIdByIncentive == min{ id : amount(id) > 0 }`, and an empty lane
parks the cursor exactly at `earliestValidQueMemberByIncentive`. The proof is
the inductive step — one lemma per queue mutation, each seeding a small
concrete lane with fully symbolic amounts and asserting the predicate (plus
the exact expected cursor) afterwards:

- `testFuzz_QUE10_joinNeverMovesCursor` (also the base case: fresh lane ⇒
  cursor == edge == 0)
- `testFuzz_QUE10_leaveHeadAdvancesCursorToNextActive`
- `testFuzz_QUE10_leaveMidKeepsCursor`
- `testFuzz_QUE10_leaveLastRestoresEmptyForm`
- `testFuzz_QUE10_fullFulfillAdvancesCursor` (real `_processOrder`, USD
  payment included)
- `testFuzz_QUE10_partialFulfillKeepsCursor`

The stateful complement over all 17 tiers, including arbitrary-id (mid-list)
removals, is `test/diamond/invariant/QueueCursorInvariant.t.sol`.

## Bridge-receive proofs (QLV-5)

The atomicity law `processedMessageId[id] == true ⟺ the mint for id
succeeded` — the property that a share burned on the source chain can never
be destroyed in flight (a failed delivery leaves no state, so CCIP manual
re-execution can retry; a marked message can never mint again):

- `testFuzz_QLV5_replayAlwaysReverts` — a marked id can never mint, for any
  payload.
- `testFuzz_QLV5_successSetsFlagAndMintsExactly` — a routed, fresh, positive
  delivery marks the id and mints exactly the payload amount on top of any
  pre-existing balance.
- `testFuzz_QLV5_flagAndMintAreAtomic` — the full ⟺ over symbolic gates
  (lane-enabled × peer-match × already-processed × amount): success happens
  exactly when every gate passes, and either both effects land or neither
  does.
- `testFuzz_QLV5_secondDeliverySameIdReverts` — at-most-once end to end.
- `testFuzz_QLV5_referralShapeIsTransportOnly` — the referral-carrying payload
  shape obeys the same law and referral bytes never change the minted amount.

The delivery gate set is the ENTIRE revert surface: router auth, lane
enabled, peer match, replay flag, `amount > 0`. There is no economic gate —
the destination cap is raised by the minted amount before the mint
(`_raiseDepositCap`), so a delivery can never exceed the deposit cap.

## Bridge room proofs (BRG-5)

The cap-relocation law — relocations move `totalDepositCap` with the shares,
so room `totalDepositCap − totalSupply` is invariant under both bridge
directions — proven in the underflow-safe all-addition form:

- `testFuzz_BRG5_receivePreservesRoom` — a delivered `ccipReceive` raises
  `totalDepositCap` and `totalSupply` by the same `amount` (all-addition room
  equation `cap' + supplyBefore == cap + supply'`, exact mint to the payload
  user), or reverts wholesale leaving cap and supply untouched.
- `testFuzz_BRG5_bridgeOutPreservesRoom` — a burn-and-send lowers
  `totalDepositCap` and `totalSupply` by the same `amount` (addition form
  `cap' + amount == cap`), or reverts wholesale. Both lemmas pin the
  reachable-state precondition `supply ≤ cap` (the `setTotalDepositCap`
  supply floor makes the complement unconstructible on-chain).

## Same-chain move-out proof (MOV-1)

`moveBetweenVaults` relocates principal and its cap budget to a same-chain
peer; pending interest is banked to `cashedInterest` by the facet's
`assignInterest` modifier ABOVE the helper under proof, so `_executeMoveOut`
itself must touch no interest state:

- `testFuzz_MOV1_moveOutRelocatesCapWithPrincipal` — for any balance, move
  amount and reachable cap (`cap ≥ supply`), a successful move gives
  `cap' == cap − amount`, `supply' == supply − amount` (room invariant,
  `supply' ≤ cap'`) with `cashedInterest(mover)` still zero (no compound
  mint, no banking at this layer); a reverting move touches neither. The
  concrete one-year warp keeps a nonzero pending ready so any residual
  compound mint would break the exact supply delta.
- `test_MOV1_atCapMoveOutSucceedsRoomStaysZero` — concrete discriminator:
  at-cap move-out succeeds with room staying exactly 0 and the cap reduced
  by the full amount. Fails against an implementation that forgets
  `_reduceDepositCap`, cap-gates the move like a deposit, or reduces the cap
  before the burn-balance check.

## Assumptions & scope (a proof is only as strong as its preconditions)

- **`InterestRateProxy == address(this)`** is kept concrete, matching the
  constructor-fixed deployment fact (there is no setter).
- **Overflow ceilings**: the 20% proofs assume the interest base ≤ `1e40` (and
  `1e30` for the long-horizon proof) so `base * rate * yearFac` stays below
  2²⁵⁶. These dwarf any real supply (the deposit cap is `1e15` for a 6-decimal
  token); above them the checked-math multiplication simply reverts.
- **Symbolic-address scope**: `MoveInterestGuard` and `AssignInterest` fix the
  *counterparty/benefactor* address to a concrete representative (Kontrol does
  not terminate on a fully symbolic mapping key) while proving over all numeric
  state, all flags and — for the move guard — all destinations. The address
  dimension is covered by the fuzz campaign and the stateful invariant.
- **Constructor migration edge (not covered, flagged):** `_migrateInterest`
  (`WiseTelecomNodesDeclarations`) writes `cashedInterest[addr]` directly, and only
  runs when `oldVault != 0`. A deployer who lists the new vault's own address in
  `initialDistributionAddresses` with a non-zero `oldVault` could seed
  `cashedInterest[contract]` non-zero at construction. This is deployer-only and
  not reachable post-deployment; the operational invariant holds thereafter.
- **Cursor lemma scope:** lane *structure* (order count, ids, incentive tier
  0) is concrete so mapping slots stay concrete; the amounts are fully
  symbolic. The USD leg of the fulfill lemmas runs over a minimal concrete
  `MockStable`. The all-tier, arbitrary-shape coverage comes from the
  stateful invariant.
- **Bridge payload shapes and message id:** `_message.data` is pinned to its
  two length shapes — the 64-byte legacy `(address, uint256)` encoding and
  one referral-carrying `(address, uint256, bytes)` encoding — because the
  decode branch is selected purely by payload length; a fully
  symbolic-length `bytes` is intractable in KEVM. The message id is a
  concrete representative for the same reason the interest proofs use
  concrete counterparty addresses: a fully symbolic mapping key does not
  terminate. No code path reads the id's content (it is only a lookup key),
  and the Foundry fuzz campaign covers random ids. Amounts, pre-balances
  and gate flags stay symbolic. The harness writers place the routed lane
  directly (bypassing the governance timelock, which is proof-orthogonal)
  and `harnessSetRouter` bypasses only the set-once guard.
- **Move-out proof (MOV-1):** the mover is a concrete address (mapping keys stay
  concrete) holding a symbolic balance; a nonzero pending — pinned to
  `floor(balance/5)` via concrete `interestRate` 2000 and a concrete one-year
  sync delta — stands ready so any residual interest mint inside the helper
  would break the exact supply delta (the banking happens at the facet
  modifier, above the helper under proof, so the helper must touch no
  interest state and no USD moves). The destination peer is a minimal
  concrete mock (`mintFromPeer` a no-op at equal decimals so the amount
  scales 1:1). Move amount and cap stay symbolic, with the reachable-state
  assume `cap ≥ supply` (the setter floor makes the complement
  unconstructible). The decimals-scaling/dust dimension of the move (unequal
  peer decimals) is Foundry-covered in `WiseTelecomNodesMoveFacet.t.sol`.

## Reproduce

Foundry (fuzz, from repo root):

```bash
forge test --match-path 'test/diamond/kontrol/*'
```

Kontrol (symbolic proof, WSL):

```bash
export PATH="$HOME/.foundry/bin:$HOME/.nix-profile/bin:$PATH"
kontrol build
kontrol prove --match-test 'InterestPropertiesTest.testFuzz_' --workers 14
kontrol prove --match-test 'SwitchPropertiesTest.testFuzz_' --workers 14
kontrol prove --match-test 'CursorPropertiesTest.testFuzz_' --workers 14
kontrol prove --match-test 'BridgeReceivePropertiesTest.testFuzz_' --workers 14
kontrol prove --match-test 'BridgeHeadroomPropertiesTest.testFuzz_' --workers 14
kontrol prove --match-test 'MoveOutPropertiesTest.testFuzz_' --workers 14
kontrol list   # verdicts
```
