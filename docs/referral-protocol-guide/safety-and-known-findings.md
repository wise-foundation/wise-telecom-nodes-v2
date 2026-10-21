# Safety and Known Findings

Who can do what, what is behind a timelock, and every accepted review finding with its reason.

The referral code was reviewed many times before its first deployment. Every finding was either fixed or accepted with a reason. This chapter starts with the trust model, so you know who can do what and what waits three days, and then lists the accepted findings grouped by the question you would ask: can commission be lost, can it be paid twice, can a bot take my share, can someone take my claim, what can the operator do, and what about the year, the thresholds and the reads. Each entry states the finding plainly, names the mechanism in the code and gives the reason it is not a problem: a documented design choice, a trusted role, an effect bounded to dust or to time, or an operator procedure that covers it.

> No accepted finding lets anyone take another party's money. Where a finding costs anything, it costs time, dust or an operator's gas.

## The Trust Model

### Who Can Do What?

* **Master:** the protocol operator, a multisig from the deploy on the registry and the hub, and the only party that can grant anything. We can never write a score, a cursor, a week bucket or a claimable on the hub, can never change a referrer alone on the registry, and can never move a user's recorded stake on a vault except through the consent gated correction lane and the retroactive seed. At the time of writing the vault master is the deployer key; it moves to a multisig as the last step of the rollout.
* **A registered source:** a vault we wired into the hub as a reporter or as a CCIP flush source; its code builds every number it sends from its own storage. Every number the hub takes comes from a registered source, which is the system's standing trust boundary.
* **An allowlisted flush bot:** an address a vault's master allowed to flush other referrers' books; our policy is an allowlist with one courier address per vault and the public flush switch off.
* **The keeper:** our offchain process that pokes the permissionless settlement calls.
* **Everyone:** may deposit with a referrer, flush their own book, broadcast a referrer pair, apply a received envelope, settle weeks, poke a migration and claim their own buckets.

### What Waits Three Days?

Every lane that lets a new party write is behind three days, public from the moment it is queued and cancellable until it runs: the vaults' selector routes and hook, registry and hub pointers; the registry's peers, router, payout hub route and new allowed vaults; the hub's selector changes and every grant through `proposeLeverChange` (allowing a reporter, setting the router, setting a flush or designation source, elevating a referrer). The correction lane waits three days by construction and the user may cancel at any time. Revocations never wait. The details are in [Timelocks and Master Levers](architecture.md#timelocks-and-master-levers).

## Can Commission Be Lost?

### The First Flush Covers at Most the Last 104 Closed Weeks

`_cursorFromWeek` anchors a virgin cursor at the current week minus 103, the recorder's settle bound, so closed weeks older than that never enter an envelope. A book is a measurement of present stake and the permissionless `advanceBook` pre walks a dormant book at any time, so the bound is reached only by a referrer whose book nobody touched for two years. Our courier flushes every book regularly.

### The Spoke Advances Its Cursors Before the Hub Applies

`_commitFlush` writes the referrer's cursors in the vault transaction, while the hub applies the envelope lazily from its stored commitment. An envelope the hub could never apply would leave those weeks behind the cursor. The only sender is the vault itself, whose planner builds every envelope within the hub's bounds, and an envelope that CCIP did not deliver is recovered by executing it manually on the off ramp, which our runbook covers. The commitment store makes every received envelope applicable by anyone at any later time.

### A Zero Budget Own Flush Can Advance the Through Week Cursor

When the planner has no work budget left for the first week of a book, `_planWeeks` can still store the week before it as the through week, so a courier lane opens on an empty plan. Reaching a zero budget on a virgin cursor in one call was not shown to be reachable with the shipped caps, and the referrer's own window `flushReferralWindow` ships any week above the cursor on demand, so nothing is lost.

### The Gap Reserve Reads Only the Record at the Cursor

`_gapWorkWaiting` turns the gap lane's reserve off when the record at the cursor is exhausted, even if a later gap record still waits, so the weekly crumbs may spend the whole budget in that flush and the waiting span moves one flush later. This is a delay of one flush per cycle, never a loss; the span is shipped by the next flush.

### The Book Advanced Gate Also Holds the Referrer's Own Batch

`_checkBookAdvanced` keys on a batch of more than one referrer, not on who calls, so a referrer's own multi referrer flush is refused with `FlushBookNotAdvanced` until the books are advanced. The permissionless `advanceBook` clears it, and a single referrer flush settles inline. The gate exists so one call never walks more than one book's week boundaries.

### A Vault That Is Paused or Disarmed Ships Nothing

While a vault is paused (`whenNotPaused`) or its recorder is disarmed, no crumb, gap slice, self run or designation leaves it, and third parties are refused for one day after the reopen (`FLUSH_OUTAGE_GRACE`). The weeks are not lost: the recorder zero weights the disarm span and the referrer's own flush ships everything once the vault is back. The pause and the disarm are master actions covered by our runbook.

### A Failed Registry Read Keeps a Parked Sender's Tracked Ledger High

When the registry lookup inside a park drain fails, the sender stays parked and its tracked contribution stays above its balance until the next entrypoint drains it, so a flush in between can report departed stake as self presence for that stretch. The registry is a master wired contract whose read paths never revert, the failure is reported by `CohortReferrerLookupFailed` and the very next entrypoint drains the park, so the effect is bounded to the time between two touchpoints.

### A Failed Designation Read Ships No Designation Word

`_readDesignationWord` returns zero on a failed or malformed registry answer and the envelope ships without a designation word, with no event. The real registry's view cannot fail that way, the referrer's designation travels with the next flush or with a direct `pushPayoutAddress`, and the reader's `claimablesOf` shows whether a bucket is claimable.

### The First Settle of a New Self Crumb Writes No Self Log Record

`_settleSelfPieceCohort` stamps a self crumb at its first settle without writing a self log record for the weeks before it, so a referrer's own presence counts from its first stamp onward. A presence record starts when the stake starts being recorded, by design; there is no retroactive presence anywhere in the system.

### A Move Whose Registry Lookup Fails Loses Its Carry

A same chain move whose destination lookup fails, or whose carried payload exceeds the mover's post mint headroom, discards the carry wholesale (`CohortCarryDiscarded`), and the single event shape covers the benign and the suspicious cases alike. The move itself always completes and the destination's one way clamp keeps the book consistent; attribution is the only loss, bounded by one mover's stake. The headroom ceiling is slack by a mover's untracked balance (a balance held before arming or received by plain transfer), so we seed existing holders before arming a vault.

### A Weekly Presence Above the 80 Bit Lane Clips

Every lane saturates at about 1.2e24 token seconds with a `CohortLaneSaturated` event instead of reverting, because the engine runs inside the transfer hook. At six decimals that is about two trillion USD present for a full week; every live product has six decimals.

### The Planner Clips a Gap Record Above the Lane Ceiling

`_clampGapMature` clamps a dormant span's mature quantity to the lane ceiling before packing it and advances the cursor past the record, so the excess above the ceiling is never priced. The ceiling is about 2e18 base units, two trillion USD at six decimals, unreachable on every live product.

### Each Priced Cell Keeps a Sub Unit Residue

The due of a cell is one floor over the three lanes, so at most one base unit per source, referrer and week is never paid; the remainder park is declared and unused. At six decimals this is at most one millionth of a dollar per cell.

### A Queue Leave Never Re Credits the Referrer

`joinQue` escrows the queued shares through an internal transfer that runs the transfer hook, so the referee's tracked stake is clamped to the balance still held and the referrer's attributed book is reduced by the queued amount at the join, newest credit first, exactly as a sale would reduce it; the presence counted for the referrer stops for that amount from that instant. `leaveQue` and `reduceQueAmount` return the shares to the referee as plain balance through the same hook, which only clamps and never credits, so the referrer's credit is not restored, and a buyer who fills the order receives escrowed shares that no referrer is credited for. This is accepted because the queue is an exit: the join is the moment of intent to sell. Re crediting at the leave instant would let a referee cycle fresh year one credit at will, by joining and leaving in one block to turn aged or untracked shares into new credit for the cost of gas, so a new deposit is the only way credit returns.

### The Local Flush Trusts the Hub Routing

`_deliverFlushLocal` calls the hub's reporter surface after the vault's cursors advanced and does not verify a state change at the hub. The hub pointer on the vault is set behind a three day timelock and the deploy order wires the hub before any vault flushes.

## Can Commission Be Paid Twice?

### The Work Cap Is Checked After the Apply Loop

`_applyFlushEnvelope` prices every entry and then checks `MAX_FLUSH_WORK`, so an envelope above the cap would price everything and revert on every apply. Only a registered source, a master wired vault, can produce an envelope, and the vault planner bounds every envelope to 160 units on a spoke and 96 on the hub chain, so the check is a second guard against a source that does not exist.

### A Reporter That Shifts Lanes Between Two Deliveries Prices the Week Twice

A report merges the lane sum by maximum while the cursor merges each lane by maximum, so the same average with its lanes shifted between year one, year two and mature would price again on the shifted lane. Only a registered source can report, and its crumb words are written by the recorder with fixed lane geometry, so this needs a malicious trusted reporter.

### Mutual Referrals Across Two Chains Earn Until a Sync Lands

Two users who assign each other on two different chains before the registries exchange keys hold one direction of the pair on each chain, and each earns on the other's stake there until a sync arrives. The merge rule dissolves a mutual pair by key the moment either chain sees the other's pair, `broadcastSync` is permissionless and cheap, and our courier broadcasts every new assignment. A hub side check was not added because a blocked pair simply moves to two fresh wallets of the same owner; two wallets of one person that refer each other are two depositors who climb the ladder with their own stake, which is the ladder's purpose, and a user can never refer itself.

### The Local Cycle Walk Cannot See a Ring Through Another Chain

`_requireNoReferralCycle` walks the local `referrerOf` only, so a master assignment or two assignments on two chains can form a mutual pair that the local walks do not see. The merge dissolves such a pair by key the moment the syncs meet, exactly as for the deposit lane above, and the two wallet argument applies: a cycle longer than one hop is an offchain policy matter.

### One `reportSelf` Call Can Carry 104 Runs of 104 Weeks

The local reporter lane caps the run count and each run's span separately, so a maximal batch far exceeds one transaction's gas and never lands. The lane is open to master allowed vaults only and the vault planner bounds its own work; the CCIP lane is capped by work.

### The Mailbox Applies Every Self Run an Entry Names

The envelope lane loops an 8 bit run count and relies on the post loop work cap, so a hostile envelope could price many runs before reverting. Only a registered vault sends envelopes and its planner bounds the runs, so the cap is a second guard.

### A Self Run Above the Lane Ceiling Is Refused

`_applySelfRun` rejects a weekly self average above the 80 bit lane divided by one week, and the planner does not clamp before sending, so such an envelope would stay unappliable. The bound is about 2e12 USD of average own stake at six decimals; every live product has six decimals.

### The Hub Rejects a Self Run Whose Last Week It Has Not Closed

A spoke that crossed a week boundary before the hub's clock did ships a run the hub reads as future, and the apply reverts until the hub clock passes the boundary. Weeks are Unix weeks on every chain, so the skew is seconds, and a stored commitment is applied by anyone afterwards.

### A Written Bit Only Crumb Lists a Source While Delivering Nothing

A crumb word with only the written bit set passes the nonzero test, lists the source for the referrer and freezes its chain id. Zero lanes price zero, so no money moves; the source list of a referrer is bounded by the number of registered vaults, because only they can deliver.

### The Settle Walk Cost Grows With the Referrer's Source List

`settleWeeks` re settles every listed source of a referrer for every week asked, so the keeper's cost after a rate raise grows with the sources a referrer is listed at. A referrer can be listed only at registered vaults (ten at the deploy), each call is bounded to 104 weeks, and the claimable only reads low until the keeper settles, never high.

### Anyone Can Walk Future Weeks Through `settleWeeks`

The call has no closed week bound, so a caller may walk weeks whose cursors are all zero and pay the gas for nothing. It is permissionless and idempotent by design; a walk over empty weeks changes nothing.

### The Gap Lane Relies on `settleWeeks` After a Rate Raise

The crumb lane tops up its own source's cell inline when its report raises the week's rates; the gap lane has no such arm and waits for `settleWeeks`. For the gap quantities the recorder produces the inline arm is not reachable, and the keeper's settle after every `WeekRatesRaised` covers both lanes.

### A Removed and Re Added Source Splits Its Bucket

A settle credits the chain id read at settle time while the source's chain id is written at its first listing, so removing a source and re adding it under another chain id moves later top ups into another bucket. A source is never re keyed without a removal first, and a removal is a deliberate master act with no operational reason today.

## Can a Bot Take My Share?

### An Allowlisted Bot That Delivers a Referrer's Closed Weeks First Keeps the Courier Share

Both flush paths, `flushReferrals` and `flushReferralWindow`, let an allowlisted bot ship a referrer's closed weeks above the referrer's stored cursors, and the hub pays the bot `botShareBps` of the commission of the weeks it priced first. The fee is paid by the protocol on top of the referrer's commission, never deducted from it, so the referrer receives the full commission whoever delivered the week. Which addresses may earn the fee is the allowlist policy of the vault's master, with one courier address per vault; a referrer who wants nothing shipped by the courier flushes its own book first, which advances the cursors the courier must stay above.

### A Referrer That Controls a Flush Bot Collects the Courier Share Itself

A referrer whose address is on a vault's flush bot allowlist, or who controls an allowlisted address, flushes its own book through it and is paid the share by `_payCourierFee`. The allowlist is master's policy and holds one operator courier per vault, so this is a choice master would have to make, and the share is a protocol paid delivery fee that was budgeted for the delivery either way. A referrer's own flush, from the referrer's address, earns nothing.

### An Allowed Reporter Names Any Deliverer

`deliverCrumbs` and `deliverGap` take the deliverer as a parameter, so a reporter could name any address and direct the courier share to it. Reporters are the mainnet vaults, allowed by master behind the lever timelock; their code passes the actual caller as deliverer and only when it is an allowlisted bot. The setter exists so a later mainnet product can be added, under the same multisig.

### A Registered Flush Source Authors the Designation Word

The designation word in an envelope comes from the source vault, and the hub applies it with no owner signature. The source is a master deployed vault whose code reads the designation from the registry, where only the owner's own call writes it, and this is the system's standing trust boundary: every number the hub takes comes from a registered source.

## Can Someone Take My Claim?

### The Full Claim Reverts on a Short Pot

`claim` sends the whole bucket and reverts `PotDry` when the hub holds less. This is the exact amount path by design; `claimUpTo` and `claimAll` pay the covered part and leave the rest claimable, and the reader shows both the bucket and the pot.

### One Claimant Takes the Shared Pot Cover

`_coveredAmount` is the hub's whole balance with no per bucket reservation, so a short pot pays the first claimants and the others wait. Every unpaid amount stays claimable, `totalPayable - totalClaimed` tells the funder exactly what the pot should hold, and nothing is lost.

### An Empty Pot Makes `claimAll` Report Nothing Claimable

With a zero balance every bucket clamps to zero and `claimAll` reverts `NothingClaimable`, the same error as empty buckets. The reader's `claimablesOf` and the hub's `claimable` distinguish the two cases before the call.

### `claimAll` Pays in the Caller's List Order

The buckets are paid in the order the caller lists them against the shrinking cover, so a payout address that calls `claimAll` can put its own chain first. The payout address was designated by the referrer and every bucket pays to the referrer's designations, so the order moves the referrer's own money between the referrer's own buckets.

### A Zero Payout Designation Pays the Referrer's Own Address on Mainnet

The registry accepts the zero address as a payout and the hub stores it with a valid stamp, so the bucket pays the referrer's own address on the hub chain. The referrer set that designation itself; a contract wallet on a spoke designates a nonzero mainnet address it controls, as [Your Payout Address per Chain](for-referrers.md#your-payout-address-per-chain) says.

### The Hub Local Setter Writes Under an Equal Stamp and Loses an Equal Second Tie

`setPayoutAddress` on the hub has no newer stamp check and packs rank zero, so a spoke push of the same second outranks it for that bucket. Both writers act on the owner's own buckets; a spoke designation can only reach the hub from the owner's own address on that spoke.

### The Previous Payout Address Can Claim While a Newer Designation Is in Flight

A piggybacked designation is read at plan time and applied when the envelope is applied, so for the CCIP delay the earlier address keeps the claim right. The earlier address was the owner's own earlier designation; `pushPayoutAddress` lands a designation directly.

### A Designation That Fails the Clock Check Is Skipped While the Entry Prices

A stamp more than one hour ahead of the hub clock is skipped with `FlushDesignationSkipped` and the entry's weeks still price, so a spoke bucket stays unclaimable until a designation lands. No chain pair drifts by an hour, and `pushPayoutAddress` lands a fresh designation on demand.

### A Second Designation Inside One Second Reverts

`setPayoutAddress` on a registry requires a strictly newer stamp, so a user who corrects a wrong payout address in the same second reverts with `PayoutStampNotNewer` and tries in the next block. The strict rule is what keeps two designations from racing under one stamp.

### No Path Cancels a Stored Flush Commitment

`_receiveFlush` writes the commitment before any payload validation and nothing clears it, so a malformed envelope stays committed. The only sender is the vault whose planner keeps envelopes well formed, an unapplied commitment pays nothing, and a hub facet can be replaced through the selector timelock if a recovery is ever needed.

### One Sender in Both Source Maps Routes Pushes Into the Flush Path

`ccipReceive` consults the flush map first, so a sender registered both as a flush source and a designation source would have its pushes decoded as envelopes. Flush sources are vaults and designation sources are registries, distinct addresses, the setters refuse re keying, and the wiring is scripted.

## What Can the Operator Do?

### A Master Assignment May Be Proposed on Any Chain, and the User Vetoes per Chain

For a user without a referrer, `proposeCorrectReferrer` runs on any chain of the mesh, so a chain that never synced a user's existing pair reads that user as unassigned and master could propose there. This is our chosen shape for the assignment lane. The execute mints a mirrored key that wins every later merge, we converge a user's pair mesh wide (one `broadcastSync`) before proposing, the user may cancel for three days on that chain, and a first referral deposit or an arriving sync during the window changes the user's key and kills the proposal with `NothingToCorrect`.

### The User Vetoes Every Correction Without Limit

`cancelCorrectReferrer` has no deadline and no count: a user can cancel every proposal for ever, and master can only propose again. This is the design of a consent gated lane. **The registry is immutable against master alone and changes only with the user's consent**, so a user who refuses can never be bound.

### A Matured Proposal Never Expires

`executeCorrectReferrer` checks only that three days have passed, so master may execute a proposal long after it matured. The user keeps the cancel right until the execute, the proposal is bound to the user's exact key so any change of the user's state kills it, every proposal and cancellation is an event, and the lane is master only.

### A Corrected Pair Flips Every Peer Registry Without a Veto There

After an execute, one `broadcastSync` carries the corrected pair to every peer, where the merge adopts it without a window. The veto was exercised on the origin chain, the chain whose rank the user's key carries, where the user has already acted; a referrer is one fact mesh wide, so a per chain veto would let one chain hold a stale pair for ever.

### A User Address That Cannot Call Keeps No Veto

The veto is a plain call from the user's address, so a contract with fixed logic, or a contract account not deployed on the origin chain, cannot exercise it and the lane is master only for such users. Master is a multisig, every proposal is public for three days through `ReferralCorrectionProposed`, and everything already priced stays with the old referrer.

### The Old Referrer Has No Veto

Only the user and master may cancel a correction; the old referrer is never a party. The referrer is the user's choice, the lane exists to let a user correct a wrong one with master's agreement, and the old referrer keeps every week already priced.

### A First Assignment During the Window Kills the Proposal

A vault assignment or a sync adoption during the three days changes the user's key, so the execute reverts with `NothingToCorrect` and the dead proposal stays queued until master proposes again or cancels. The bind to the held key is what prevents a stale proposal from overriding a choice the user made in the meantime.

### A Second Proposal Overwrites the Pending One

`proposeCorrectReferrer` for a user with an open proposal overwrites the target and restarts the window with no distinct event. Only master proposes, every proposal emits `ReferralCorrectionProposed` with its target, and the restart only lengthens the user's veto window.

### A Master Assignment Emits No `ReferralAssigned`

An execute for a user without a referrer emits `ReferralCorrectionExecuted` with a zero old referrer and no `ReferralAssigned`. An indexer follows both events to see every pair; the distinction records which lane wrote it.

### A Master Assignment Marks No Flip

The assignment branch of the execute skips the flip markers because there is no old referrer whose book could hold the user's stake. A dissolved mutual edge leaves no attributed stake under a zero referrer either: its marker was set at the dissolve and is delivered by `pokeMigration`.

### The Mirrored Assignment Key Beats a Referrer the User Names Later

A master assignment carries the mirrored key, so a referrer the user names in a later deposit on another chain loses the merge. This is the intended effect: the lane assigns a referrer with the user's three day consent, and the result is one pair mesh wide. A user who disagrees cancels within the window.

### An Assignment on a High Rank Chain Never Lands on a Low Rank Peer

An execute on a chain whose rank exceeds a peer's `maxSyncRank` mints a key that peer refuses. Every live chain has rank 3 or below and every registry accepts rank 3; before a fifth chain is peered, we raise `maxSyncRank` on every registry, which the deploy script asserts.

### A Sync Key Above `maxSyncRank` Reverts the Delivery on Every Retry

`ccipReceive` reverts `SyncKeyInvalid` for a rank above `maxSyncRank` and the revert also unwinds the replay marker, so the delivery keeps failing until master raises the rank. No live chain mints such a key; the guard exists to refuse injected ranks that no registry holds, and raising the rank before peering a new chain is a deploy step.

### The Timelocked Allow Lane Can Track a Codeless Address

`executeAllowedVaultChange` does not probe `code.length` before `_trackVault` takes one of the eight permanent tracked slots. The deploy script refuses a codeless configuration address, the lane is master only behind three days, and `pokeMigration` never calls a tracked entry without code, so a slip burns a slot and nothing else.

### Wiring Before `finalizeSyncSetup` Is Instant

The sync peer, router, payout hub and allow lanes wait three days only after `finalizeSyncSetup`, so during the wiring phase master proposes and executes in one transaction. The wiring phase is a scripted deploy step run by the multisig master, the preflight checks that no proposal is pending at finalization, and after finalization every lane waits.

### Proposals on Master Lanes Never Expire

The lever queue, the selector queue and the registry queues keep a matured proposal until it is executed or cancelled, and a deploy script that applies a lever executes whatever matching proposal is queued. Every lane is master only, every proposal is public from the moment it is queued (`LeverChangeProposed` carries the full call), and every lane has a cancel.

### The Elevation History Holds Eight Windows, and an Empty Window Takes a Slot

`elevateReferrer` appends a window and reverts `ElevationHistoryFull` after `MAX_ELEVATION_WINDOWS` (8); `endElevation` accepts an until week equal to the from week, which stores a window that holds no week and still takes a slot. Both calls are master only, a window is a deliberate grant, and the capacity exists so pricing a week costs a bounded scan. The history is part of the hub from its first deployment, so no earlier window exists outside it.

### The Grace Freeze Switch Ships Off

`CohortHookFacet` keeps the live transfer hook's grace freeze check and honours `graceFreezeEnabled`, which stays false at the deploy. The freeze is an existing vault policy that master can switch on at any time; shipping it off is the standing configuration, not a gap in the hook.

### The Deployment Scripts Are Operator Tooling

The deploy scripts are run by master. A peer wiring script re run after finalization queues a proposal and resets its clock instead of converging; an abort of the flush upgrade round can leave the transfer hook proposal queued and emits cancellation events for selectors already executed; the flush hub propose phase keeps any pending proposal without comparing its target. Each of these is visible in the events and in the read only preflight that our runbook runs before every step, and every queued proposal is cancellable, so they are procedure items for the operator rather than protocol risks.

## What About the Year, the Thresholds and the Reads?

### Pricing Divides Yearly Rates by a 364 Day Year

`ReferralHubIntake._dueOf` divides each week's commission by `BPS_DENOMINATOR` times `CohortWeeks.YEAR`, and `CohortWeeks.YEAR` is 52 weeks, 364 days, so a rate read against a calendar year of 365.25 days pays about 0.34 percent more than the stated figure (365.25 divided by 364). This is accepted because the 52 week year is the documented rate unit of the whole system. Every quantity is counted in whole weeks keyed by the Unix timestamp divided by one week: crumbs, cursors, flush envelopes, rate tables and elevation windows. The ring that ages credit from year one into year two and then mature has `CohortWeeks.RING_SLOTS` (52) slots, one per week, so a cohort's year one is exactly 52 weeks and ends on a week boundary; a calendar year would end mid week and one week would need two rates at once. The hub pays each week as amount times rate times seven days over 364 days, so a referrer on the 10 percent tier earns 10 percent of its weekly averages over 52 weeks. The ring and the denominator agree, so no week is paid twice or skipped, and the 0.34 percent is the whole effect. The referrer chapter explains the same thing for readers in [The 52 Week Year](for-referrers.md#the-52-week-year).

### The Genesis Ladder Thresholds Are Six Decimal Units

The thresholds compare against native unit week averages, so an 18 decimal product would top the ladder at one millionth of a token. Every live product has six decimals, a future non USD or differently scaled vault converts before it reports, and we can publish a table for future weeks at any time.

### The Rate Table Search Assumes One Table

`_lastAtOrBefore` sets its upper bound to the array length minus one, so an empty table array would panic. The constructor seeds the genesis table and tables are only ever appended, so the array is never empty.

### No Getter Exposes the Elevation History

`elevationWindowsOf` is internal and the hub exposes only `elevatedFromWeek` and `elevatedUntilWeek`, the mirror of the latest window. Replaying `ReferrerElevated` and `ReferrerElevationEnded` per referrer reconstructs every window, and the effective rates of any week are read exactly from `weeklyRates`.

### The Reader's Elevated Flag Is an Inference for Earlier Windows

`ladderStandingOf` reports `elevated` from the latest window and otherwise infers it from an effective rate at the cap while the natural tiers do not reach it, so a week whose ladder reaches the cap on its own reads as not elevated, and a zero cap table disables the inference. The flag is display only; the rates the reader returns are the hub's own, and payments never read the flag.

### Recorder Getters Answer Zeros on a Direct Facet Call

The `CohortRecorderFacet` views carry no delegatecall guard, so a call to the facet address itself reads the facet's own empty storage. Every integrator calls the vault diamond, which routes the selector to the facet under the diamond's storage; the addresses to call are the vault addresses in [Addresses](addresses.md).

### Conclusion

Every accepted finding falls into one of four classes: a design choice the guide documents elsewhere, an action only the multisig master or a master wired vault could take, an effect bounded to dust or to a delay, or a step our runbook covers. None of them lets a third party take money that is not theirs, lower a closed week's verdict or move a user's stake without consent.
