# Vault and Referral UI Integration

Every call, view and event a front end needs, for the vaults and for the referral system.

This chapter is for front end and integration developers. The first part lists the ten vault UI integration guides that exist for the features already live, with the link to each, what your front end does with it and which facet it covers. The second part is the referral system guide in the same shape, written so that it can be published as the next guide beside them, with a reference of every read function and every event at the end.

> Every vault call goes to the vault diamond address of the product on the chain the user is on (the records in `config/vault.<product>.<network>.json`), never to a facet address. Every registry call goes to the registry of the chain the user is on. Every hub and reader call goes to Ethereum mainnet.

## Part One: The Vault UI Integration Guides

Ten guides cover the vault surface as it is live today. Each is one markdown file with worked web3.js examples, preconditions, error handling, events and gotchas, and the live addresses; nine are published as gists and the tenth ships as a gist with the next batch. The vault products are the World Mobile vaults `usdc` (mainnet, Base, Arbitrum), `usdt` (mainnet, Base, Arbitrum) and `usdg` (mainnet, Arbitrum, Robinhood), and the Sovren vault `wsnusdc` on mainnet; every vault has the same address on every chain it runs on and everything is six decimals.

### Permit2 Deposits

**Covers:** `Permit2UserFacet` (`depositWithPermit2`, `depositAndClaimInterestWithPermit2`, `depositAndCompoundInterestWithPermit2`).

Your front end lets a user deposit with a signature instead of a separate approve transaction, which matters for tokens without EIP 2612 such as USDT on mainnet. The user approves the Permit2 contract once, then signs a `PermitTransferFrom` per deposit with the amount, a nonce and a deadline, and the front end passes the signature to the deposit variant the user chose; the combined variants settle pending interest in the same transaction.

Link: [Permit2 Deposits, UI Integration Guide](https://gist.github.com/vonMangoldt/b5874a8588be9ab0dc3182ce9d33b108)

### Compound via Queue

**Covers:** `QueueFulfillFacet` (`compoundInterestViaFulfillBulk`) with the queue views `solveForAmount` and `predictTokensForCost`.

Instead of compounding accrued interest at par, your front end spends it on discounted vault tokens from the exit queue in one transaction, and whatever interest is left over is compounded automatically. The guide covers planning the fill with the solver views and the slippage bounds the call takes.

Link: [Compound via Queue, UI Integration Guide](https://gist.github.com/vonMangoldt/ffda33f1a1cc7106ad98362197575de8)

### Deposit and Compound via Queue in One Transaction

**Covers:** `MulticallFacet` (`multicall`) chaining `compoundInterestViaFulfillBulk` and `depositWithPermit2`.

Your front end replaces `depositAndCompoundInterestWithPermit2` with one `multicall` that deposits fresh stablecoin and puts the user's interest to work on the queue in the same transaction. The order of the two legs matters, and the guide explains why.

Link: [Deposit and Compound via Queue in One Transaction, UI Integration Guide](https://gist.github.com/vonMangoldt/6fffeba6ba4ecf86ace059c70fb888be)

### Switching an Order's Incentive

**Covers:** `QueueJoinLeaveFacet` (`switchQueIncentive`, `switchQueIncentivePartial`) with `getAllOrdersfromAddressWithId`.

Your front end lets a user reprice an active queue order without leaving and rejoining: one transaction, no share movement, whole or in part, with the partial variant peeling part of an order into another tier while the rest keeps its place. Because no shares move, a switch has no effect on referral credit.

Link: [Switching an Order's Incentive, UI Integration Guide](https://gist.github.com/vonMangoldt/e0cd6d7a867e16b1255eba302a371984)

### Move Between Vaults

**Covers:** `MoveFacet` (`moveBetweenVaults`, `getMoveableBalance`, `peerVault`).

Your front end relocates a position to the same chain peer vault, for example from the usdt vault into the usdc vault and back: the source burns the shares and the destination mints them, the deposit cap travels with the shares, and referral attribution follows them with exactly the age it had.

Link: [Move Between Vaults, UI Integration Guide](https://gist.github.com/vonMangoldt/6f79a1422e856f5c4ca39f947fe6139b)

### Cross Chain Bridging

**Covers:** `BridgeFacet` (`bridgeToVault`, `bridgeToVaultWithReferral`, `quoteBridgeFee`, `quoteBridgeFeeWithReferral`, `getBridgeableBalance`).

Your front end quotes the CCIP fee in the native token, sends the bridge with the fee as value and tracks the delivery; the shares burn on the source chain and mint to the same address on the destination chain. While the referral recorder is armed, the vault itself attaches the referral attribution of the bridged shares to the message, so the front end passes no referral data, and the credit travels only when the destination recipient is the sender's own address.

Link: [Cross Chain Bridging, UI Integration Guide](https://gist.github.com/vonMangoldt/cce2fdc186a6f993a4d03fb31c6add01)

### WISE Burn

**Covers:** `BurnWiseFacet` (`burnWise`, `getBurnableWise`, `getNextBurnPercentage`).

Your front end shows the burn state of the Ethereum usdc vault and offers the permissionless `burnWise` button: a rotating slice of the WISE the vault holds is burned, reducing WISE total supply, with a per caller cooldown between burns.

Link: [WISE Burn, UI Integration Guide](https://gist.github.com/vonMangoldt/4bde487f791f074c03e42e938c57db5c)

### Queue Forecast

**Covers:** `QueueForecastFacet` (`solveForAmountAfterFulfill`).

Your front end quotes a queue purchase against the book as it will look after another fill lands, which prices a second fill while a first is still pending and plans the later legs of a `multicall` batch before any of it has executed. The view returns the `fulfillOrderBulk` arrays plus the post fill amounts the chain cannot show yet.

Link: [Queue Forecast, UI Integration Guide](https://gist.github.com/vonMangoldt/8a7fcda79aeef0138a8efe6aeab9c4c6)

### Grace Period Countdown

**Covers:** the grace views compiled into the diamond (`graceThresholdAmount`, `gracePeriodDuration`, `lastLargeDepositAt`, `depositAccumWindow`) and the `GracePeriodNotElapsed` error.

Your front end shows the interest lock timer a large deposit starts: the three views to wire, the exact gate formula, the warning to show before a deposit crosses the threshold, and which functions the lock gates (interest extraction and relocation) and which it does not (deposits and exits).

Link: [Grace Period Countdown, UI Integration Guide](https://gist.github.com/vonMangoldt/66a8ed87ad6c7d7989ec6ed1e1987a81)

### Exit an Order and Move to the Peer Vault in One Transaction

**Covers:** `MulticallFacet` (`multicall`) chaining `leaveQue` and `moveBetweenVaults`, with `getAllOrdersfromAddressWithId` and `getMoveableBalance`.

Your front end lets a user with an active queue order pull it and relocate the freed shares to the same chain peer vault atomically. For referral credit this is a leave followed by a move: the leave restores nothing and the move carries whatever credit the shares still hold. This guide ships as a gist with the next batch.

## Part Two: Referral UI Integration Guide

The referral system lets a depositor name a referrer with a deposit and pays that referrer a weekly commission at the hub on mainnet. Your front end has five jobs: pass the referrer into the deposit, show a user their referrer, show a referrer their standing and claimables, offer the flush and claim buttons, and let a user veto a correction. Everything else is reading views and listening to events.

### The Referral Link:

A referral link carries the referrer's address. Keep that address and write it into the referrer field of the deposit call you send; **that exact address is what the chain's registry records for the depositor and what the hub prices**, so a referrer is identified by nothing but the address in that field.

The referral deposit entrypoints on the vault, all on the user's chain, are these.

```solidity
depositWithReferral(uint256 _amount, address _referrer)
depositAndClaimInterestWithReferral(uint256 _amount, address _referrer) returns (uint256)
depositAndCompoundInterestWithReferral(uint256 _amount, address _referrer) returns (uint256)
depositWithPermit2WithReferral(uint256 _amount, uint256 _nonce, uint256 _deadline, bytes _signature, address _referrer)
depositAndClaimInterestWithPermit2WithReferral(uint256 _amount, uint256 _nonce, uint256 _deadline, bytes _signature, address _referrer) returns (uint256)
depositAndCompoundInterestWithPermit2WithReferral(uint256 _amount, uint256 _nonce, uint256 _deadline, bytes _signature, address _referrer) returns (uint256)
```

Each is the plain deposit variant with the referrer assignment run first. The call reverts when the referrer is the zero address or the depositor itself, when the vault's registry pointer is not set, and when the registry refuses the referrer (a vault, the registry, the hub, or an address whose own referral chain leads back to the depositor). A depositor who already has a referrer is kept on it and the deposit still succeeds, so read the user's referrer first and show it rather than the link's address when they differ.

### Reading a User's Referrer:

On the vault, `getReferrerOf(address _user) returns (address)` reads through the registry pointer and returns zero while no referrer is set. On the registry of the same chain you can read more.

```solidity
referrerOf(address _user) returns (address)
getReferrerPair(address _user) returns (address referrer, uint256 assignedAt, uint256 rank)
effectiveReferrerOf(address _user, address _vault) returns (address)
```

`getReferrerPair` returns the assignment time and the rank of the chain that made it; an `assignedAt` below 1,700,000,000 marks a pair written by the correction lane. `effectiveReferrerOf` returns the referrer a given vault still credits while a cross chain flip is pending for that vault; it equals `referrerOf` once the flip is delivered.

### The Referrer Dashboard:

All reader calls go to the `ReferralHubReader` contract on mainnet; the hub views named here are on the hub diamond on mainnet. Weeks are Unix weeks: the current week number is the current timestamp divided by 604,800.

```solidity
ladderStandingOf(address _referrer, uint256 _week) returns (LadderStanding standing)
claimablesOf(address _referrer, uint256[] _chainIds) returns (uint256[] amounts, address[] payouts, uint256 total, uint256 claimableNow)
claimableOf(uint256 _chainId, address[] _referrers) returns (uint256[] amounts)
weeklyRatesRange(address _referrer, uint256 _fromWeek, uint256 _count) returns (uint256[] y1Bps, uint256[] y2Bps, uint256[] mBps)
weeklyRates(address _referrer, uint256 _week) returns (uint256 y1Bps, uint256 y2Bps, uint256 mBps)
```

* **`ladderStandingOf`:** the referred and self inputs of a closed week, the tier each reaches, the next threshold of each (zero at the top tier), the three effective rates in basis points, the referrer's latest elevation window and an `elevated` flag. The current week reads zero until it closes and its records land.
* **`claimablesOf`:** one bucket per source chain with the address a claim would pay; a zero address means the bucket cannot be claimed yet because no payout designation from that chain has reached the hub. `total` sums every bucket and `claimableNow` only the designated ones, both before the pot's funding.
* **`weeklyRates` and `weeklyRatesRange`:** the three rates of a week in basis points, on the hub itself and batched on the reader.

On each vault, the flush views show what the vault has already shipped for a referrer.

```solidity
getFlushCursors(address[] _referrers) returns (uint256[] throughWeeks, uint256[] gapIndexes, uint256[] gapResumeWeeks)
getFlushedThroughWeek(address _referrer) returns (uint256)
getFlushGapCursor(address _referrer) returns (uint256 gapIndex, uint256 gapResumeWeek)
previewFlushEnvelope(address[] _referrers) returns (bytes)
quoteFlushFee(address[] _referrers) returns (uint256)
getAllowedFlushBot(address _bot) returns (bool)
getPublicFlushEnabled() returns (bool)
```

The through week is the last closed week shipped; a closed week above it has not reached the hub yet. `previewFlushEnvelope` and `quoteFlushFee` plan on storage as it is before the settle a real flush performs, so they are lower bounds. `quoteFlushFee` returns zero on mainnet, where delivery is a direct call.

### The Flush Buttons:

```solidity
flushReferrals(address[] _referrers) payable
flushReferralWindow(address _referrer, uint256 _fromWeek, uint256 _fromGapIndex) payable
```

Both go to the vault on the chain where the book lives. Send the quoted fee as value on Base, Arbitrum and Robinhood and nothing on mainnet; any excess is refunded. A referrer may always flush its own book; for another referrer's book the caller must be an allowlisted flush bot (`getAllowedFlushBot`) unless the public flush switch is on, which ships off. A batch of more than one referrer takes only books already advanced to the current week (`advanceBook(address _referrer, uint256 _maxBoundaries)` on the vault is permissionless), and on mainnet a batch holds at most six referrers. The window form ships one referrer from a chosen week and gap record onward; a referrer uses it to ship a book older than two years or to ship a particular span. Only the referrer's own flush writes the vault's cursors.

> A referrer flushing its own book earns no courier share. An allowlisted bot earns 5 percent (the genesis courier share) of the commission of the closed weeks it priced first, paid by the protocol on top of the referrer's full commission.

### The Payout Designation:

Commission accrues at the hub per source chain and referrer. On mainnet a referrer's bucket pays the referrer's own address unless the referrer sets another with `setPayoutAddress(address _payout)` on the hub. On Base, Arbitrum and Robinhood a bucket pays nothing until a designation from that chain has reached the hub.

On the spoke chain's registry:

```solidity
setPayoutAddress(address _payout)
pushPayoutAddress(address _owner) payable
quotePushPayoutFee(address _owner) returns (uint256)
getPayoutDesignation(address _owner) returns (address payout, uint256 stamp)
```

`setPayoutAddress` records the designation under the caller's address; a second designation in the same second reverts, so a correction waits one block. The designation travels to the hub with the next flush of the referrer's book on that chain, or at once through `pushPayoutAddress` with the quoted CCIP fee as value, which anyone may send for any owner. The newest designation wins at the hub. Offer the push button when `claimablesOf` shows a zero payout for a chain with a nonzero amount.

A designation of the zero address is valid and pays the referrer's own address on mainnet. A referrer that is a contract wallet on a spoke chain must designate a nonzero mainnet address it controls. A vault address can never designate.

### The Claim Buttons:

All on the hub on mainnet.

```solidity
claim(uint256 _chainId, address _referrer)
claimUpTo(uint256 _chainId, address _referrer, uint256 _amount)
claimAll(address _referrer, uint256[] _chainIds) returns (uint256 total)
payoutAddressOf(uint256 _chainId, address _owner) returns (address)
claimable(uint256 _chainId, address _account) returns (uint256)
```

* **`claim`:** pays one bucket in full and reverts `PotDry` when the pot holds less.
* **`claimUpTo`:** pays up to the given amount and up to the pot's balance.
* **`claimAll`:** pays every listed bucket that can pay, in list order against the pot's cover, and reverts `NothingClaimable` only when nothing was paid.

A claim may be sent by the referrer or by the bucket's payout address and always pays the payout address. Show `claimable` per chain, the hub's USDC balance as the cover, and offer `claimAll` with the chains that have a nonzero amount and a nonzero `payoutAddressOf`.

### The Correction Veto:

When we propose a different referrer for a user, the user has three days to refuse. Watch `ReferralCorrectionProposed(user, oldReferrer, newReferrer, queuedAt)` on the registry of the user's chain and show a cancel button that calls, on that registry:

```solidity
cancelCorrectReferrer(address _user)
```

The pending proposal is readable with `proposedCorrection(address _user) returns (address)` and `correctionQueuedAt(address _user) returns (uint256)`. For a user who already has a referrer the proposal appears on the chain whose rank the user's key carries; for a user without a referrer it may appear on any chain.

### Reference: Every Read Function

The tables below list every read function a front end or an indexer can use, with its signature, the chain it is called on and the statistic it feeds. Vault calls go to the vault diamond of the product on the user's chain, registry calls to that chain's registry, hub and reader calls to mainnet. A week argument is a Unix week number.

#### Vault: Referral and Recorder Views

| Function | Chain | Feeds |
|---|---|---|
| `getReferrerOf(address _user) returns (address)` | vault chain | A user's referrer as the vault reads it from the registry, zero while unset or while the pointer is unset. |
| `getReferralRegistry() returns (address)`, `getProposedReferralRegistry() returns (address)`, `getReferralRegistryChangeQueuedAt() returns (uint256)` | vault chain | Which registry the vault consults and whether a pointer change is pending. |
| `getFlushHub() returns (address, uint64)`, `getProposedFlushHub() returns (address, uint64)`, `getFlushHubChangeQueuedAt() returns (uint256)` | vault chain | Which hub the vault flushes to; a zero chain selector means delivery by direct call on mainnet. |
| `getCohortSyncEnabled() returns (bool)` | vault chain | Whether the recorder is armed; nothing is measured while it is off. |
| `getTrackedContribution(address _user) returns (uint256)` | vault chain | A user's stake as the recorder tracks it, the user's own stake input to the ladder. |
| `getAttributedContribution(address _user) returns (uint256)` | vault chain | The part of a user's tracked stake credited to a referrer's book, the amount a referrer earns on for this user. |
| `getCohortSelfCrumb(address _user) returns (uint256 settledAt, uint256 currentWeekSeconds, uint256 previousWeekSeconds)` | vault chain | A referrer's own presence in the current and the previous week in token seconds, the self input before it is flushed. |
| `getCohortBook(address _referrer) returns (uint256 year1, uint256 year2, uint256 mature, uint256 lastSettleTimestamp)` | vault chain | The referred stake credited to a referrer in this vault by age lane, and when the book was last settled. |
| `getCohortScore(address _referrer) returns (uint256)` | vault chain | The three lanes summed, the referred amount a referrer currently holds in this vault. |
| `getCohortRings(address _referrer) returns (uint64[52] year1, uint64[52] year2)` | vault chain | Per week slot, how much of the referrer's credit graduates at each coming week boundary. |
| `getCohortWeekCrumb(address _referrer, uint256 _week) returns (uint256)` | vault chain | One closed week's referred token seconds (three 80 bit lanes plus the written bit), the record the hub prices. |
| `getCohortWeekCrumbs(address _referrer, uint256 _fromWeek, uint256 _count) returns (uint256[] crumbs)` | vault chain | A range of closed weeks' records, for a per week chart of referred stake. |
| `getCohortGapLogLength(address _referrer) returns (uint256)`, `getCohortGapLogEntry(address _referrer, uint256 _index) returns (uint256)` | vault chain | Dormant spans recorded as one gap record each (from week, to week, mature principal). |
| `getFlushedThroughWeek(address _referrer) returns (uint256)` | vault chain | The last closed week shipped to the hub from this vault; weeks above it are pending. |
| `getFlushGapCursor(address _referrer) returns (uint256 gapIndex, uint256 gapResumeWeek)` | vault chain | How far the dormant spans have been shipped. |
| `getFlushCursors(address[] _referrers) returns (uint256[] throughWeeks, uint256[] gapIndexes, uint256[] gapResumeWeeks)` | vault chain | The same two cursors for many referrers in one call. |
| `previewFlushEnvelope(address[] _referrers) returns (bytes)` | vault chain | The envelope a flush would send, planned on storage before the settle, for inspection. |
| `quoteFlushFee(address[] _referrers) returns (uint256)` | vault chain | The native fee a CCIP flush costs; zero on mainnet. |
| `getAllowedFlushBot(address _bot) returns (bool)`, `getPublicFlushEnabled() returns (bool)`, `getFlushGasLimit() returns (uint64)` | vault chain | Who may flush other referrers' books and the CCIP gas budget of a flush message. |

#### Registry: Every Getter

| Function | Chain | Feeds |
|---|---|---|
| `referrerOf(address _user) returns (address)` | registry chain | A user's referrer. |
| `referrerKey(address _user) returns (uint256)` | registry chain | The packed key `(assignedAt << 8) or rank`; the time since when the user has this referrer and the chain that recorded it. |
| `getReferrerPair(address _user) returns (address referrer, uint256 assignedAt, uint256 rank)` | registry chain | The same, unpacked; an `assignedAt` below 1,700,000,000 marks a pair written by the correction lane (decode it as 3,399,999,999 minus the value). |
| `effectiveReferrerOf(address _user, address _vault) returns (address)` | registry chain | The referrer a vault still credits while a flip is pending there. |
| `pendingFlip(address _vault, address _user) returns (address)` | registry chain | The old referrer a vault has not yet migrated away from, zero when no flip is pending. |
| `LOCAL_CHAIN_RANK() returns (uint256)`, `maxSyncRank() returns (uint256)` | registry chain | This chain's rank and the highest rank the merge accepts. |
| `allowedVault(address _vault) returns (bool)`, `everAllowedVault(address _vault) returns (bool)`, `allowedVaultQueuedAt(address _vault) returns (uint256)`, `trackedVaultCount() returns (uint256)` | registry chain | Which vaults may write, which ever could, and pending allow proposals. |
| `payoutAddress(address _owner) returns (address)`, `payoutStamp(address _owner) returns (uint256)`, `getPayoutDesignation(address _owner) returns (address payout, uint256 stamp)` | registry chain | A referrer's payout designation on this chain and when it was set (the stamp is `(setAt << 8) or rank`). |
| `payoutHub() returns (address)`, `payoutHubChainSelector() returns (uint64)`, `proposedPayoutHub()`, `proposedPayoutHubChainSelector()`, `payoutHubChangeQueuedAt()` | registry chain | The hub a designation push goes to and any pending change. |
| `quotePushPayoutFee(address _owner) returns (uint256)`, `quoteSyncFee(address _user, uint64[] _selectors) returns (uint256)` | registry chain | The native fee of a designation push or a referrer broadcast. |
| `proposedCorrection(address _user) returns (address)`, `correctionQueuedAt(address _user) returns (uint256)`, `proposedCorrectionKey(address _user) returns (uint256)` | registry chain | The correction proposal open against a user: the proposed referrer, when the three days started, and the key it is bound to. |
| `correctionsLatched() returns (bool)`, `seedsLatched() returns (bool)` | registry chain | Whether the correction lane and the retroactive seed are closed on this chain. |
| `ccipRouter() returns (address)`, `syncInitialized() returns (bool)`, `syncGasLimit() returns (uint64)`, `proposedCcipRouter()`, `ccipRouterChangeQueuedAt()` | registry chain | The registry's CCIP wiring and any pending router change. |
| `syncPeer(uint64 _chainSelector) returns (address)`, `syncPeerEnabled(uint64) returns (bool)`, `proposedSyncPeer(uint64)`, `syncPeerChangeQueuedAt(uint64)`, `syncPeerQuarantined(uint64) returns (bool)` | registry chain | The peer registries this chain syncs with, pending peer changes and braked lanes. |
| `processedSyncMessageId(bytes32 _messageId) returns (bool)` | registry chain | Whether a CCIP sync message was already applied. |
| `getCarry(address _srcVault, address _dstVault, address _user) returns (uint256 stagedAt, uint256[] payload)` | registry chain | A same chain move carry staged and not yet consumed (normally empty). |
| `master() returns (address)`, `proposedMaster() returns (address)` | registry chain | The registry's master and a pending handover. |

#### Hub: Every View of `IReferralHub`

| Function | Chain | Feeds |
|---|---|---|
| `claimable(uint256 _chainId, address _account) returns (uint256)` | mainnet | Commission (or courier share) accrued and not yet claimed, per source chain and address. |
| `payoutAddressOf(uint256 _chainId, address _owner) returns (address)` | mainnet | The address a claim of that bucket pays; zero means the spoke bucket cannot be claimed yet. |
| `payoutStamp(uint256 _chainId, address _owner) returns (uint256)` | mainnet | The stamp of the designation the hub holds for that bucket; zero means none. |
| `totalAccrued() returns (uint256)`, `totalClaimed() returns (uint256)`, `totalPayable() returns (uint256)` | mainnet | Protocol totals: everything priced (commission and courier share), everything paid out, and the amount owed to buckets that can claim; `totalPayable - totalClaimed` is what the pot should hold. |
| `USD_TOKEN() returns (IERC20)` | mainnet | The pot's token; its `balanceOf(hub)` is the cover for claims. |
| `weeklyRates(address _referrer, uint256 _week) returns (uint256 y1Bps, uint256 y2Bps, uint256 mBps)` | mainnet | The three rates of a closed week in basis points, elevation included. |
| `ladderInputsAt(address _referrer, uint256 _week) returns (uint256 referredInput, uint256 selfInput)` | mainnet | A referrer's referred and own average stake of a week, summed over every source. |
| `weekReportOf(bytes32 _source, address _referrer, uint256 _week) returns (uint256 referredAverage, uint256 paidUnits)` | mainnet | One source's reported referred average for a week and the commission units already paid for it. |
| `weekSelfOf(bytes32 _source, address _referrer, uint256 _week) returns (uint256)` | mainnet | One source's reported self average for a week. |
| `paidCursorAtSource(bytes32 _source, address _referrer, uint256 _week) returns (uint256 y1Cursor, uint256 y2Cursor, uint256 mCursor)` | mainnet | How much of a week's referred token seconds a source has had priced, per lane; compare with the vault's crumb to see what is still pending. |
| `sourceKeyOf(uint256 _chainId, address _vault) returns (bytes32)` | mainnet | The source key of a vault on a chain, the argument of the per source views. |
| `sourceCountOf(address _referrer) returns (uint256)`, `sourceOfAt(address _referrer, uint256 _index) returns (bytes32)` | mainnet | The sources (vaults on chains) that ever reported for a referrer. |
| `sourceChainIdOf(bytes32 _source) returns (uint256)`, `sourceSystemOf(bytes32 _source) returns (uint256)`, `MAX_SYSTEMS() returns (uint256)` | mainnet | The chain a source credits and the vault system it belongs to. |
| `elevatedFromWeek(address _referrer) returns (uint256)`, `elevatedUntilWeek(address _referrer) returns (uint256)` | mainnet | The latest elevation window of a referrer (until week zero means open; from week zero means never elevated). |
| `rateTableCount() returns (uint256)`, `rateTableAt(uint256 _index) returns (RateTable)` | mainnet | The published rate tables: effective week, cap, year two and mature rates, courier share, tiers and thresholds. |
| `delivererShareCap() returns (uint256)` | mainnet | The per delivery cap on the courier share, zero meaning none. |
| `allowedReporter(address _reporter) returns (bool)` | mainnet | Whether a mainnet vault may report directly. |
| `ccipRouter() returns (address)`, `flushSourceChainId(uint64 _chainSelector, address _sender) returns (uint256)`, `designationSourceChainId(uint64 _chainSelector, address _sender) returns (uint256)` | mainnet | The hub's CCIP wiring: which vaults and registries on which chains it accepts. |
| `flushCommitment(bytes32 _messageId) returns (bytes32)` | mainnet | Whether a flush envelope was received; nonzero until applied and after. |
| `leverChangeQueuedAt(bytes32 _changeHash) returns (uint256)`, `selectorToFacet(bytes4)`, `proposedSelectorFacet(bytes4)`, `selectorChangeQueuedAt(bytes4)`, `initialized() returns (bool)` | mainnet | Pending grants and selector changes behind the three day timelock. |
| `master() returns (address)`, `proposedMaster() returns (address)` | mainnet | The hub's master and a pending handover. |

#### Reader: Every View of `ReferralHubReader`

| Function | Chain | Feeds |
|---|---|---|
| `HUB() returns (IReferralHub)` | mainnet | The hub this reader reads. |
| `ladderStandingOf(address _referrer, uint256 _week) returns (LadderStanding)` | mainnet | A referrer's standing in a closed week: both inputs, the tier each reaches, the next threshold of each, the three effective rates, the latest elevation window and the `elevated` flag. |
| `ladderInputsRange(address _referrer, uint256 _fromWeek, uint256 _count) returns (uint256[] referredInputs, uint256[] selfInputs)` | mainnet | Referred and own amounts per week for a chart. |
| `weeklyRatesRange(address _referrer, uint256 _fromWeek, uint256 _count) returns (uint256[] y1Bps, uint256[] y2Bps, uint256[] mBps)` | mainnet | Rates per week for a chart. |
| `weekReportsAtSource(bytes32 _source, address _referrer, uint256 _fromWeek, uint256 _count) returns (uint256[] referredAverages, uint256[] paidUnits)` | mainnet | One vault's reported averages and paid units per week, the settled weeks of a source. |
| `paidCursorAt(address _reporter, address _referrer, uint256 _week) returns (uint256 y1Cursor, uint256 y2Cursor, uint256 mCursor)` | mainnet | The paid cursor of a mainnet vault by address. |
| `paidCursorsAtSource(bytes32 _source, address _referrer, uint256 _fromWeek, uint256 _count) returns (uint256[] cursorWords)` | mainnet | Paid cursors per week as packed lane words, the pending versus settled picture of a source. |
| `claimableOf(uint256 _chainId, address[] _referrers) returns (uint256[] amounts)` | mainnet | Claimable amounts of many referrers on one chain, for leaderboards. |
| `claimablesOf(address _referrer, uint256[] _chainIds) returns (uint256[] amounts, address[] payouts, uint256 total, uint256 claimableNow)` | mainnet | One referrer's buckets across chains with the payout address each pays and the claimable now total. |

### Reference: Every Event

The tables list every event with its indexed fields marked and what a dashboard derives from it. With them an indexer can build complete per user and per referrer statistics: deposit attribution, flushes sent and applied, weeks priced, claims paid, designations, corrections, elevations and rate tables.

#### Vault Cohort Facets (Emitted by the Vault Diamond on Its Chain)

| Event | Derived statistic |
|---|---|
| `CohortContributionCredited(address indexed user, address indexed referrer, uint256 amount)` | A deposit, compound, seed or relocation credited this amount of the user's stake to the referrer: deposit attribution per user and per referrer. |
| `CohortContributionSeeded(address indexed user, uint256 amount)` | Master credited a user's existing balance from this instant on. |
| `CohortContributionSynced(address indexed user, address indexed referrer, uint256 oldContribution, uint256 newContribution)` | The user's tracked stake was clamped to the balance held; the difference left the referrer's reach. |
| `CohortAttributionCharged(address indexed user, address indexed referrer, uint256 charged, uint256 uncharged)` | How much of a clamp was taken from the referrer's book and how much was never attributed. |
| `CohortDivestParked(address indexed user)`, `CohortDivestDrained(address indexed user)`, `CohortDivestParkSkipped(address indexed user, address indexed parked)` | A share sender awaiting its clamp, the clamp catching up, and a second sender that had to wait. |
| `CohortBookSettled(address indexed referrer, uint256 fromTimestamp, uint256 toTimestamp, uint256 boundariesWalked)` | The referrer's book was brought up to date across this many week boundaries. |
| `CohortBookReduced(address indexed referrer, uint256 amount, uint256 fromYear1, uint256 fromYear2, uint256 fromMature)` | Referred credit left the book, by age lane, through a sale, a queue join, a burn or a relocation. |
| `CohortGapRecorded(address indexed referrer, uint256 fromWeek, uint256 toWeekExclusive, uint256 maturePrincipal)` | A dormant span was compressed into one record. |
| `CohortLaneSaturated(address indexed referrer, uint256 laneKind, uint256 index, uint256 clippedAmount)` | A lane hit its ceiling; an anomaly signal. |
| `CohortReferrerLookupFailed(address indexed user)` | The registry read failed and the mutation was skipped; an anomaly signal. |
| `CohortSyncEnabledSet(bool enabled)`, `CohortDisarmSpanSet(uint256 disarmedAt, uint256 rearmedAt)` | The recorder was armed or disarmed; weeks inside a disarm span count no presence. |
| `CohortCarryStaged(address indexed user, address indexed dstVault, address indexed referrer, uint256 trackedDelta, uint256 year1, uint256 year2, uint256 mature, uint256 pairCount)` | A same chain move captured this much credit for the destination vault. |
| `CohortCarryApplied(address indexed user, address indexed srcVault, address indexed referrer, address carriedReferrer, uint256 trackedDelta, uint256 year1, uint256 year2, uint256 mature, uint256 pairCount)` | The destination landed the carried credit under the referrer it credits. |
| `CohortCarrySkipped(address indexed user, address indexed dstVault)`, `CohortCarryDiscarded(address indexed user, address indexed srcVault, uint256 stagedAt)`, `CohortCarryBookDropped(address indexed user, address indexed srcVault, address carriedReferrer, uint256 trackedDelta, uint256 mature, uint256 pairCount)` | A move whose carry did not land or landed without a book; attribution lost for that move. |
| `CohortReferrerFlipApplied(address indexed user, address indexed oldReferrer, address indexed newReferrer, uint256 year1, uint256 year2, uint256 mature, uint256 pairCount)` | A user's credit moved from the old referrer's book to the new one after a sync flip or a correction. |
| `CohortBridgeCarrySent(address indexed user, uint64 indexed dstChainSelector, address indexed referrer, uint256 trackedDelta, uint256 year1, uint256 year2, uint256 mature, address bookReferrer)` | A bridge took this much credit out of the source book. |
| `CohortBridgeCarryApplied(address indexed user, uint64 indexed srcChainSelector, address indexed effectiveReferrer, address carriedReferrer, uint256 trackedDelta, uint256 year1, uint256 year2, uint256 mature)` | The destination landed the bridged credit. |
| `CohortBridgeCarryDiscarded(address indexed user, uint64 indexed srcChainSelector)`, `CohortBridgeCarryBookDropped(address indexed user, uint64 indexed srcChainSelector, address carriedReferrer, uint256 year1, uint256 year2, uint256 mature)`, `CohortBridgeCarrySkipped(address indexed user, uint64 indexed dstChainSelector)`, `CohortBridgeHookFailed(address indexed user, uint64 indexed srcChainSelector)`, `CohortQuarantineReadFailed(address indexed user, uint64 indexed srcChainSelector)` | Bridges whose attribution did not travel; the shares always arrive. |
| `CohortSelfCrumbSettled(address indexed user, uint256 settledAt, uint256 currentWeekSeconds, uint256 previousWeekSeconds)`, `CohortSelfLogged(address indexed user, uint256 fromWeek, uint256 completedSeconds, uint256 stake)` | A referrer's own presence per week, the self input as it is written. |
| `CohortFlushSent(bytes32 indexed messageId, uint64 indexed destChainSelector, address indexed deliverer, uint256 entryCount)` | A CCIP flush left the vault; match `messageId` with the hub's `FlushReceived` and `FlushApplied`. |
| `CohortFlushDelivered(address indexed flushHub, address indexed deliverer, uint256 entryCount)` | A mainnet flush was delivered by direct call. |
| `CohortReferrerFlushed(address indexed referrer, uint256 flushedThroughWeek, uint256 flushedGapIndex, uint256 gapResumeWeek)` | The referrer's own flush advanced the cursors to these values. |
| `FlushHubSet(address flushHub, uint64 flushHubChainSelector)`, `FlushHubProposed(address indexed proposedFlushHub, uint64 proposedFlushHubChainSelector, uint256 executableAt)`, `FlushHubProposalCancelled(address indexed cancelledFlushHub)` | The hub pointer and its timelock. |
| `FlushBotAllowedSet(address indexed bot, bool allowed)`, `PublicFlushEnabledSet(bool enabled)`, `FlushGasLimitSet(uint64 flushGasLimit)` | The flush policy of the vault. |
| `ReferralRegistrySet(address referralRegistry)`, `ReferralRegistryProposed(address indexed proposedReferralRegistry, uint256 executableAt)`, `ReferralRegistryProposalCancelled(address indexed cancelledReferralRegistry)` | The registry pointer and its timelock. |

#### Registry (Emitted by the Registry on Its Chain)

| Event | Derived statistic |
|---|---|
| `ReferralAssigned(address indexed user, address indexed referrer, address indexed vault)` | A depositor's first referrer and the vault whose deposit recorded it: the referral count per referrer. |
| `ReferralSyncAdopted(address indexed user, address indexed referrer, uint256 syncKey)` | A pair arrived from another chain for a user with none here. |
| `ReferralSyncKeyLowered(address indexed user, address indexed referrer, uint256 oldKey, uint256 newKey)` | The same referrer with an earlier key; the since when of the pair moved earlier. |
| `ReferralSyncFlipped(address indexed user, address indexed oldReferrer, address indexed newReferrer, uint256 syncKey)` | An earlier assignment elsewhere replaced the local referrer. |
| `SyncKeyCollision(address indexed user, address indexed localReferrer, address indexed incomingReferrer, uint256 syncKey)` | Two different referrers with an equal key; the local one stands. |
| `ReferralMutualDissolved(address indexed user, address indexed oldReferrer, uint256 winnerKey)` | A mutual pair was resolved; this user's edge was dropped. |
| `FlipMarked(address indexed vault, address indexed user, address indexed oldReferrer)`, `FlipCleared(...)`, `FlipMigrated(address indexed vault, address indexed user, address oldReferrer, address newReferrer)`, `FlipMigrationDeferred(...)` | The delivery of a flip to each vault: pending, cleared, migrated or deferred until the vault is armed. |
| `SyncBroadcast(address indexed user, uint64 indexed destChainSelector, address indexed referrer, uint256 syncKey, bytes32 messageId)`, `SyncReceived(uint64 indexed srcChainSelector, bytes32 indexed messageId, address indexed user)` | Referrer pairs sent to and received from peer chains. |
| `ReferralCorrectionProposed(address indexed user, address indexed oldReferrer, address indexed newReferrer, uint256 queuedAt)` | A correction or a master assignment opened against the user; the three day veto window starts at `queuedAt`. |
| `ReferralCorrectionCancelled(address indexed user, address indexed newReferrer, address indexed cancelledBy)` | Who cancelled it: the user, master, or the registry itself on a mutual dissolve. |
| `ReferralCorrectionExecuted(address indexed user, address indexed oldReferrer, address indexed newReferrer, uint256 syncKey)` | The correction took effect; a zero `oldReferrer` is an assignment of a user who had none. |
| `CorrectionsLatched()`, `SeedsLatched()` | The lane or the seed was closed for good on this chain. |
| `PayoutAddressSet(address indexed owner, address indexed payout, uint256 stamp)` | A referrer designated a payout address on this chain. |
| `PayoutPushed(address indexed owner, uint64 indexed destChainSelector, address payout, uint256 stamp, bytes32 messageId)` | The designation was pushed to the hub. |
| `CarryStaged(address indexed srcVault, address indexed dstVault, address indexed user, uint256 words)`, `CarryConsumed(address indexed srcVault, address indexed dstVault, address indexed user, uint256 stagedAt)` | A same chain move staged and consumed its carry. |
| `VaultAllowedSet(address indexed vault, bool allowed)`, `VaultAllowProposed(address indexed vault, uint256 queuedAt)`, `VaultAllowProposalCancelled(address indexed vault)` | The vault allowlist and its timelock. |
| `SyncPeerProposed(uint64 indexed chainSelector, address indexed peer, uint256 queuedAt)`, `SyncPeerSet(uint64 indexed chainSelector, address indexed peer)`, `SyncPeerProposalCancelled(...)`, `SyncPeerRemoved(uint64 indexed chainSelector, address indexed peer)`, `SyncPeerQuarantined(uint64 indexed chainSelector)`, `SyncPeerQuarantineLifted(uint64 indexed chainSelector)` | The peer table, its timelock and braked lanes. |
| `CcipRouterSet(address indexed router)`, `CcipRouterProposed(address indexed router, uint256 queuedAt)`, `CcipRouterProposalCancelled(address indexed router)`, `SyncGasLimitSet(uint64 gasLimit)`, `SyncSetupFinalized()`, `MaxSyncRankRaised(uint256 rank)` | The CCIP wiring and the rank bound. |
| `PayoutHubProposed(address indexed hub, uint64 chainSelector, uint256 queuedAt)`, `PayoutHubSet(address indexed hub, uint64 chainSelector)`, `PayoutHubProposalCancelled(address indexed hub)` | The designation route to the hub. |

#### Hub (Emitted by the Hub Diamond on Mainnet)

| Event | Derived statistic |
|---|---|
| `FlushReceived(bytes32 indexed messageId, uint64 indexed srcChainSelector, address indexed vault, uint256 chainId, bytes payload)` | A flush envelope arrived from a spoke; the payload holds every entry, so an indexer can decode what was shipped before it is applied. |
| `FlushApplied(bytes32 indexed messageId, bytes32 indexed source, uint256 entryCount)` | The envelope was priced; the flush count per source. |
| `SourceListed(address indexed referrer, bytes32 indexed source, uint256 chainId)` | A vault on a chain reported for a referrer for the first time. |
| `WeekReferredReported(bytes32 indexed source, address indexed referrer, uint256 indexed week, uint256 referredAverage)`, `WeekSelfReported(bytes32 indexed source, address indexed referrer, uint256 indexed week, uint256 selfAverage)` | A source's referred and self averages for a week: the referred and self amounts per week per referrer, summed over sources. |
| `WeekRatesRaised(address indexed referrer, uint256 indexed week)` | A later report raised the week's rates; top ups follow. |
| `WeekToppedUp(bytes32 indexed source, address indexed referrer, uint256 indexed week, uint256 amount)` | A source's cell was paid the difference after a rate rise. |
| `CrumbPriced(bytes32 indexed source, address indexed referrer, uint256 indexed week, address deliverer, uint256 y1Increment, uint256 y2Increment, uint256 mIncrement, uint256 paid)` | A week's referred token seconds were priced for a source: the commission per week per referrer and who delivered it. |
| `GapPriced(bytes32 indexed source, address indexed referrer, address deliverer, uint256 fromWeek, uint256 toWeekExclusive, uint256 paid)` | A dormant span was priced across several weeks at once. |
| `CrumbLaneRegression(bytes32 indexed source, address indexed referrer, uint256 indexed week, uint256 laneKind, uint256 incoming, uint256 cursor)` | A delivery below the paid cursor; nothing paid, an anomaly signal. |
| `DelivererSharePaid(uint256 indexed chainId, address indexed deliverer, address indexed referrer, bytes32 messageId, uint256 amount)` | The courier share earned per courier, per referrer and per envelope. |
| `PayoutAddressSet(uint256 indexed chainId, address indexed owner, address indexed payout)` | A designation reached the hub for a bucket; the state of the payout designation per chain. |
| `DesignationPushReceived(uint64 indexed srcChainSelector, uint256 indexed chainId, address indexed owner)`, `FlushDesignationSkipped(uint256 indexed chainId, address indexed owner, uint256 stamp)` | A pushed designation arrived, or a designation word was rejected for its stamp. |
| `PayoutBacklogReleased(uint256 indexed chainId, address indexed owner, uint256 amount)` | A bucket became claimable and its backlog joined the amount owed. |
| `PayoutClaimed(uint256 indexed chainId, address indexed referrer, address indexed payout, uint256 amount)` | A claim was paid: claimed per chain, per referrer and per payout address. |
| `ReferrerElevated(address indexed referrer, uint256 fromWeek)`, `ReferrerElevationEnded(address indexed referrer, uint256 untilWeek)` | Elevation windows per referrer; replayed in order they give the whole history. |
| `RateTableScheduled(uint256 indexed index, uint256 effectiveFromWeek)` | A rate table was published for a future week; read it with `rateTableAt(index)`. |
| `DelivererShareCapSet(uint256 cap)`, `ReporterAllowedSet(address indexed reporter, bool allowed)`, `SourceSystemSet(bytes32 indexed source, uint256 systemId)` | Policy changes on the courier cap, the reporters and the system tags. |
| `CcipRouterSet(address indexed router)`, `FlushSourceSet(uint64 indexed chainSelector, address indexed vault, uint256 chainId)`, `DesignationSourceSet(uint64 indexed chainSelector, address indexed registry, uint256 chainId)` | The hub's CCIP wiring. |
| `LeverChangeProposed(bytes32 indexed changeHash, bytes call, uint256 executableAt)`, `LeverChangeCancelled(bytes32 indexed changeHash)` | A grant was queued or dropped; `call` is the exact setter call, so a dashboard can show pending grants in plain words. |
| `SelectorProposed(bytes4 indexed selector, address indexed facet, uint256 executableAt)`, `SelectorsProposed(bytes4[] selectors, address indexed facet, uint256 executableAt)`, `SelectorUpdated(bytes4 indexed selector, address indexed facet)`, `SelectorProposalCancelled(bytes4 indexed selector)`, `SetupFinalized()` | The hub's own upgrade timelock. |

### Which Views for Which Screen

* **A depositor's profile:** read `getReferrerPair` on the user's chain for the referrer and the time since when, `proposedCorrection` and `correctionQueuedAt` for an open proposal to veto, and `getAttributedContribution` on each vault for how much of the user's stake is credited.
* **A referrer's overview:** read `claimablesOf` on the reader for accrued and claimable per chain, `ladderStandingOf` for the current tier and rates, `ladderInputsRange` and `weeklyRatesRange` for the week charts, and `getPayoutDesignation` on each spoke registry beside `payoutAddressOf` on the hub for the designation state.
* **A per vault detail:** read `getCohortBook`, `getCohortWeekCrumbs` and `getFlushCursors` for pending versus shipped weeks and `weekReportsAtSource` with `paidCursorsAtSource` on the reader for shipped versus settled weeks.
* **A courier console:** read `getFlushCursors` and `quoteFlushFee` on each vault and `claimable` on the hub for the shares it earned.
* **An indexer:** build the history from `ReferralAssigned`, `CohortContributionCredited`, `CohortFlushSent`, `FlushApplied`, `CrumbPriced`, `GapPriced`, `WeekToppedUp`, `DelivererSharePaid`, `PayoutAddressSet`, `PayoutClaimed`, the correction events and the elevation events.

### Conclusion

Pass the referrer address into the deposit, read the registry for the user's referrer, read the reader for the referrer's standing and claimables, and offer the flush, designation, claim and veto buttons on the chain each call belongs to. The reference tables give you every view and every event with its signature, so a dashboard and an indexer can show the whole picture without guessing at anything.
