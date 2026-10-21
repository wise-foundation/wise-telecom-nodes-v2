# For Integrators and Partners

Every function you call, the one address rule that makes you a referrer, and what the upgrade changes for your reviewers.

If you route deposits into a Wise Telecom Nodes vault, from your users' own wallets or from your own contract, you are an **integrator**. You can be the referrer of every deposit you send and earn the commission described in [For Referrers](for-referrers.md), and you can be elevated to the cap. This chapter gives your developers the functions reference and your reviewers the admin surface, what the referral upgrade changes and the notes they will ask for before an audit.

Every call goes to the vault diamond on the user's chain; the hub calls go to Ethereum mainnet. The signatures of every view and event, with the chain each is called on, are in [UI Integration](ui-integration.md).

## How it Works:

### The Elevated Referrer Address Rule:

An integrator is identified by one thing only: **the referrer address it writes into the referrer field of every deposit it sends.** That exact address is what the registry records for each depositor and what the hub prices, so choose one address and use it on every chain and in every deposit. If you are to be elevated, that is priced at the cap for every week of your window (10 percent on year one credit, 5 percent on year two credit and 1 percent from year three on under the genesis table), tell us that address before your first deposit. We then grant the elevation through the hub lever: `proposeLeverChange` with the exact `elevateReferrer(referrer, fromWeek)` call, three days, then `elevateReferrer` for a week in the future. The grant is never retroactive: weeks before its from week are priced on the ladder, and a window that was ended keeps its verdict for good.

Commission accrues per source chain and referrer at the hub, so an integrator earning on several chains holds one bucket per chain. A contract address used as referrer on Base, Arbitrum or Robinhood must designate a mainnet payout address with `setPayoutAddress` on that chain's registry and have it pushed to the hub (with the next flush of its book or with `pushPayoutAddress`), because the hub otherwise pays the referrer address itself on mainnet, where the same address may be undeployed or belong to someone else. On mainnet the bucket pays the referrer address by default and `setPayoutAddress` on the hub redirects it.

> Tell us the referrer address before the first deposit. An elevation granted later prices the earlier weeks on the ladder, and nothing is ever re priced.

## Functions Reference

This section lists every user facing function of a vault, grouped by what it does, with one sentence each on what it does, who may call it and what it changes.

### Entry

`deposit(uint256 _amount)` pulls the underlying token from the caller, mints shares one to one and credits the cohort recorder; anyone may call it while deposits are not paused. `depositAndClaimInterest(uint256 _amount)` and `depositAndCompoundInterest(uint256 _amount)` do the same and settle the caller's pending interest in the same transaction, paid out or compounded into shares. `depositWithPermit2(uint256 _amount, uint256 _nonce, uint256 _deadline, bytes _signature)` and its two combined variants pull the token through the Permit2 contract with the caller's signature instead of an allowance. `depositWithReferral(uint256 _amount, address _referrer)`, `depositAndClaimInterestWithReferral`, `depositAndCompoundInterestWithReferral` and the three `...WithPermit2WithReferral` variants record the caller's referrer in the registry first (write once, zero and self refused) and then run the matching deposit. A deposit that raises the caller's balance by the grace threshold or more stamps the caller's grace lock. `mintFromPeer(address _user, uint256 _amount)` and `ccipReceive` are the destination ends of a move and a bridge and are callable only by a peer vault or the CCIP router.

### Balance

`balanceOf(address)` and `totalSupply()` are the share token views; a share is one unit of the underlying. `getPendingInterest(address _user)`, `getPendingInterestBulk(address[] _users)`, `getTotalInterestUser(address _user)` and `getTotalInterestUserBulk(address[] _users)`, with their `...ByTimeStamp` variants, read the interest accrued and the total earned; `interestRate()` is the current rate; `getTotalCashedInterest()` is the sum of every settled interest bucket; `getBridgeableBalance(address _user)` and `getMoveableBalance(address _user)` read what a user may bridge or move. The recorder views `getTrackedContribution`, `getAttributedContribution`, `getCohortBook` and `getCohortScore` read the referral ledger; all of these change nothing.

### Compound

`compoundInterest()` settles the caller's pending interest and mints it as shares; `claimInterestPartiallyAndCompound(uint256 _amount)` pays part and compounds the rest. `compoundInterestOnBehalf(address _user)` on `AutoCompoundFacet` does the same for a user who opted in with `setAutoCompoundAllowed(true)`, is callable only by a master allowlisted bot, and keeps `autoCompoundFeeBps` of the compounded interest as the bot's reward in the underlying token; the net is minted to the user and credited to the recorder like a deposit. `compoundInterestViaFulfillBulk` compounds the caller's interest by buying queue orders with it.

### Claim

On the vault, `claimInterest()` pays the caller's whole pending interest in the underlying token, `claimInterestExactAmount(uint256 _amount)` pays part of it, and `moveMyInterestTo(uint256 _amount, address _target, bool _all)` moves settled interest to another account's bucket; all three are callable by the account owner and wait for the grace period after a large deposit. On the hub on mainnet, `claim(uint256 _chainId, address _referrer)`, `claimUpTo(uint256 _chainId, address _referrer, uint256 _amount)` and `claimAll(address _referrer, uint256[] _chainIds)` pay a referrer's commission buckets in USDC to the bucket's payout address, callable by the referrer or that payout address, and lower `claimable` and raise `totalClaimed`.

### Exit Queue

`joinQue(uint256 _amount, int256 _incentive)` escrows the caller's shares as an order at the chosen incentive and clamps them off any referrer's book; anyone with shares may call it while deposits are not paused. `leaveQue(uint256 _queMemberId, int256 _incentive)` returns an unfilled order's shares to the caller and `reduceQueAmount(uint256 _queMemberId, int256 _incentive, uint256 _reduceBy)` returns part of them, both callable by the order's owner at any time, without restoring referral credit. `switchQueIncentive` and `switchQueIncentivePartial` move an order to another incentive tier. On the buyer side `fulfillOrder`, `partiallyFulfillOrder` and `fulfillOrderBulk` pay the underlying token for queued shares, callable by anyone. The views `getAllOrdersfromAddressWithId`, `getAllOrdersOverallWithId`, `solveForAmount`, `getFulfillmentPlanForIncentive`, `predictCostForTokens`, `predictTokensForCost`, `predictDiscountedAmount` and `solveForAmountAfterFulfill` price and list orders and change nothing.

### Relocation

`moveBetweenVaults(address _dstVault, uint256 _amount)` burns the caller's shares and mints them in a peer vault of the same product on the same chain, carrying the referral attribution; `bridgeToVault(uint64 _destChainSelector, uint256 _amount)` and `bridgeToVaultWithReferral` burn them and send a CCIP message that mints them to the same address on the destination chain, with the attribution attached by the vault itself; `quoteBridgeFee` and `quoteBridgeFeeWithReferral` quote the native fee. Both relocations wait for the grace period after a large deposit.

### Referral

`flushReferrals(address[] _referrers)` and `flushReferralWindow(address _referrer, uint256 _fromWeek, uint256 _fromGapIndex)` ship a referrer's closed weeks to the hub, callable by the referrer for its own book and by allowlisted flush bots for any book, and advance the referrer's send cursors only on an own flush. `syncReferee(address _user)` and `advanceBook(address _referrer, uint256 _maxBoundaries)` are permissionless pokes that clamp a user and pre walk a book. On the registry, `setPayoutAddress(address _payout)`, `pushPayoutAddress(address _owner)`, `broadcastSync(address _user, uint64[] _selectors)`, `pokeMigration(address _user)` and `cancelCorrectReferrer(address _user)` are the user and public calls described in [UI Integration](ui-integration.md).

## Admin Functions and What the Referral Upgrade Changes

The master functions of a vault as they stand are these.

* **On the diamond itself:** `proposeSelector`, `proposeSelectors`, `executeSelectorChange`, `executeSelectorChanges` and `cancelSelectorProposal` route selectors to facets behind a three day timelock after `finalizeSetup`.
* **On `AdminFacet`:** `pauseDeposits` and `unpauseDeposits`; `mintSupply(address _to, uint256 _amount)` and `burnSupply(address _from, uint256 _amount)`, and the one way `disAllowSupplyChangeByOwner()` that renounces both (and `setCashedInterest` with them) for good, which has not been called; `setInterestRate`, `setTotalDepositCap`, `setDepositsDisabled`, `setGracePeriodDuration`, `setGraceThresholdAmount`, `setGraceFreezeEnabled`, `setDepositAccumWindow`, `setSweeper` and `setWiseToken`; the three day propose, execute and cancel trios for the third party address, the worker address, the transfer hook facet, the deposit hook facet, the referral registry pointer and the flush hub pointer; and `setCohortSyncEnabled`, the instant arming switch of the recorder.
* **On `InterestAdminFacet`:** `setCashedInterest(address _user, uint256 _amount)`.
* **On `BridgeFacet`:** the one shot `setCcipRouter`, `setReferralEnabled`, `setBridgeGasLimit`, and the timelocked peer trio with the instant `removeCrossChainPeer`.
* **On `MoveFacet`:** the timelocked peer vault trio with the instant `removePeerVault`.
* **On `QueueAdminFacet`:** `changeMinDepositAmount` and `setNegativeIncentivesNotAllowed`.
* **On `AutoCompoundFacet`:** `setAutoCompoundBot` and `setAutoCompoundFeeBps`.
* **On `RescueFacet`:** `rescueToken`.
* **On `CohortFlushPolicyFacet`:** `setAllowedFlushBot`, `setPublicFlushEnabled` and `setFlushGasLimit`.
* **On `CohortRecorderFacet`:** `seedCohortContribution`, which dies with the registry's seed latch.

**The referral upgrade revokes no admin function.** It adds timelocked selector routes for the referral, recorder, flush and flush policy facets, installs `CohortHookFacet` as the transfer hook through the existing hook timelock, and points the vault at its registry and at the hub through two new pointer trios with the same three day delay. `mintSupply` and `burnSupply` stay master powers unless the one way `disAllowSupplyChangeByOwner` is called. At the time of writing the vault master is the deployer key; it moves to a multisig as the last step of the rollout.

The registry master levers are `setAllowedVault` (instant before `finalizeSyncSetup` and for vaults ever allowed; a new address takes `proposeAllowedVault`, three days, `executeAllowedVaultChange`), `proposeSyncPeer`, `executeSyncPeerChange`, `cancelSyncPeerChange` and the instant `removeSyncPeer`, the one shot `setCcipRouter` and the three day `proposeCcipRouter` and `executeCcipRouterChange`, `proposePayoutHub` and `executePayoutHubChange`, `setSyncGasLimit`, `raiseMaxSyncRank`, `finalizeSyncSetup`, the correction lane `proposeCorrectReferrer` and `executeCorrectReferrer` with its three day window, and the one way `latchCorrections` and `latchSeeds`. The hub master levers are the selector trio behind three days after `finalizeSetup`, `proposeLeverChange` and `cancelLeverChange`, and the setters listed in [Timelocks and Master Levers](architecture.md#timelocks-and-master-levers), every grant waiting three days and every revocation immediate. On the registry and the hub the master is a multisig from the deploy.

## Pre Audit Notes

* **Nothing deployed is edited:** the referral system is added to the vault diamonds as new facets routed through the three day selector timelock, and the transfer hook is swapped through its own three day timelock. The storage rules that make this safe are in [Storage Rules](architecture.md#storage-rules).
* **Every write path is permissionless and idempotent, or master only behind three days:** the hub's `applyFlush` and `settleWeeks`, the registry's `broadcastSync` and `pokeMigration` and the vault's `syncReferee` and `advanceBook` can be called by anyone and change nothing when called twice; every grant waits three days and is public from the moment it is queued.
* **Master can never write money:** we can never write a score, a cursor, a week bucket or a claimable on the hub, can never change a referrer alone on the registry, and can never move a user's recorded stake on a vault except through the consent gated correction lane and the retroactive seed.
* **Every loop has a constant bound next to it:** 104 week boundaries per settle, 52 ring slots, 16 entries and 160 work units per envelope (6 and 96 on the hub chain), 104 weeks per `settleWeeks` call, 8 tracked vaults per registry, 8 elevation windows per referrer, 520 weeks of schedule horizon.
* **The accepted findings are published:** every review finding that was accepted rather than fixed is listed with its mechanism and reason in [Safety and Known Findings](safety-and-known-findings.md).

### Conclusion

Use one referrer address in every deposit you send, tell us that address before the first deposit if you are to be elevated, and designate a mainnet payout address for any contract referrer on a spoke chain. Your reviewers will find that the upgrade adds timelocked routes and revokes nothing, that master cannot touch commission, and that every accepted finding is written down with its reason.
