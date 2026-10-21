# Frequently Asked Questions

Short answers, each with a link to the chapter that explains it in full.

If you only have a minute, this chapter answers the questions depositors, referrers, integrators and reviewers ask most often. Every answer is two to four sentences and points to the place where the full explanation lives.

## Depositor Questions

### How Do I Name a Referrer, and Can I Change It?

You name a referrer by depositing through a referral deposit entrypoint such as `depositWithReferral`, with the referrer address in the deposit; the first referrer you name is written once and shared by every vault of the chain. You cannot change it yourself afterwards. The operator can propose a different referrer, which you can veto for three days with `cancelCorrectReferrer`, so a change needs your consent. See [Naming a Referrer](for-depositors.md#naming-a-referrer) and [Can My Referrer Be Changed?](for-depositors.md#can-my-referrer-be-changed).

### What if I Deposit Without a Referrer?

Your deposit works exactly as before and nobody earns on it; your stake is tracked but attributed to no referrer. Because no referrer was written, a later deposit through a referral entrypoint can still name one, and from then on it earns on the stake you keep in the vaults. See [For Depositors](for-depositors.md).

### Does the Referral Cost Me Anything?

No. Your deposit, your interest and your exits are the plain vault flows, and the commission your referrer earns, like the courier share a flush bot earns, is paid from the protocol's own pot on mainnet. Nothing is deducted from your principal or your interest. See [Does a Referral Cost Me Anything?](for-depositors.md#does-a-referral-cost-me-anything).

### When Does My Referrer Earn, and When Can They Claim?

Your referrer earns from the second your deposit lands, measured in token seconds, at the rate of each week. A week's commission becomes claimable at the hub on mainnet once the week has closed, the vault has flushed its record and the hub has applied it. See [Your First Week: a Worked Example](for-referrers.md#your-first-week-a-worked-example).

### What Happens if I Join the Exit Queue or Withdraw?

Joining the queue is a withdrawal for commission purposes: the queued shares leave your referrer's book at the join, newest credit first, and leaving the queue unfilled restores nothing for the referrer. Your own position is unaffected, and a new deposit builds credit again. See [What if I Join the Exit Queue?](for-depositors.md#what-if-i-join-the-exit-queue).

## Referrer Questions

### What Are the Tiers and the Cap?

Your referred average and your own average are each placed on an eight rung ladder from 5,000 USD (1 percent) to 1,000,000 USD (8 percent), and the two tiers add up to your year one rate, capped at 10 percent. Year two credit pays 5 percent and mature credit 1 percent, only in weeks where your uncapped sum reaches the cap. See [What a Referrer Earns](for-referrers.md#what-a-referrer-earns).

### What Is an Elevated Referrer?

An elevated referrer is priced as at the cap for every week inside an elevation window the operator granted, whatever its inputs: 10 percent on year one credit, 5 percent on year two and 1 percent on mature credit. A grant waits three days and starts at a future week; it never reaches back. See [Elevated Referrers](for-referrers.md#elevated-referrers) and, for integrators, [The Elevated Referrer Address Rule](for-integrators.md#the-elevated-referrer-address-rule).

### Why 52 Weeks and 364 Days?

Everything in the system is counted in whole weeks, and the ring that ages credit has 52 weekly slots, so a cohort's year one is exactly 52 weeks and ends on a week boundary. Every rate is therefore a rate per 52 week year of 364 days, which reads about 0.34 percent higher against a calendar year, and that is the whole effect. See [The 52 Week Year](for-referrers.md#the-52-week-year).

### What Is a Flush, and Who Pays for It?

A flush is a transaction on a vault that ships a referrer's closed weeks to the hub, over CCIP from Base, Arbitrum and Robinhood and by direct call on mainnet. The caller pays the CCIP fee in the chain's native token, with any excess refunded; you may always flush your own book, and the operator's allowlisted bots flush everyone's. See [Shipping Weeks to the Hub](for-referrers.md#shipping-weeks-to-the-hub).

### What Is the Courier Share?

When an allowlisted bot delivers closed weeks that were not yet priced, the protocol pays the bot 5 percent of the commission those weeks earned, on top of your commission and never deducted from it. Your own flush earns no share, and no other address earns one either. See [Shipping Weeks to the Hub](for-referrers.md#shipping-weeks-to-the-hub).

### Why Does a Claim Sometimes Pay Less Than Claimable?

The pot is funded by the protocol and can be short between top ups. `claim` then reverts, while `claimUpTo` and `claimAll` pay what is covered in the order you list the buckets and leave the rest claimable, so nothing is lost. See [What if the Pot Is Short?](for-referrers.md#what-if-the-pot-is-short).

### Where Is My Commission Paid?

At the hub on Ethereum mainnet, in USDC, into one bucket per source chain and referrer. A mainnet bucket pays your own address by default; a Base, Arbitrum or Robinhood bucket pays only after you designate a payout address on that chain's registry and it reaches the hub, and a contract wallet must designate a nonzero mainnet address it controls. See [Your Payout Address per Chain](for-referrers.md#your-payout-address-per-chain).

### What Is the Sovren Vault, and Does It Count for My Ladder?

The Sovren vault (`wsnusdc` on mainnet, a USDC vault whose deposits finance Sovren infrastructure nodes) is vault system 1 of the same referral umbrella; the nine World Mobile vaults are system 0. Both run under one rate table, cap, ladder, courier share and payout pot, and your ladder inputs sum over every vault of every system, so 500,000 referred in each counts as 1,000,000. Money never moves between systems, and the Sovren vault joins the referral system after the World Mobile rollout. See [Several Vault Systems Under One Referral Umbrella](README.md#several-vault-systems-under-one-referral-umbrella).

### What Happens to My Commission if a Bot Flushes My Weeks First?

Nothing changes for you. The bot earns the courier share on top of your commission, and you are credited the full commission of every week it delivered. If you prefer to ship first, flush your own book, which advances the cursors a courier must stay above. See [Who Controls What Is Shipped?](for-referrers.md#who-controls-what-is-shipped).

## Integrator Questions

### How Am I Identified as a Referrer?

By the referrer address you write into the referrer field of every deposit you send, and by nothing else. Use one address on every chain and in every deposit, and tell us that address before your first deposit if you are to be elevated. See [The Elevated Referrer Address Rule](for-integrators.md#the-elevated-referrer-address-rule).

### Which Functions Do My Users Call?

The plain and referral deposit variants, the interest claim and compound calls, the exit queue, the moves and bridges, and on the hub the three claim calls; each is listed with its signature, caller and effect in [Functions Reference](for-integrators.md#functions-reference). The views and events a front end uses are tabled in [UI Integration](ui-integration.md).

### What Does the Referral Upgrade Change on the Vaults?

It adds timelocked selector routes for the new facets, swaps the transfer hook through its own three day timelock and points each vault at its registry and the hub through two new pointer trios. It revokes no admin function, and `mintSupply` and `burnSupply` stay master powers unless the one way `disAllowSupplyChangeByOwner` is called. See [Admin Functions and What the Referral Upgrade Changes](for-integrators.md#admin-functions-and-what-the-referral-upgrade-changes).

### What if Two People Refer Each Other Across Chains?

Two accounts cannot refer each other on one chain, and when it happens across two chains before the registries have talked, the earlier key dissolves the pair the moment a sync lands; anyone can send that sync and our courier does. The two can earn on each other only until then. See [Mutual Referrals Across Two Chains Earn Until a Sync Lands](safety-and-known-findings.md#mutual-referrals-across-two-chains-earn-until-a-sync-lands).

## Safety Questions

### What Can the Operator Change, and With What Notice?

We can publish a new rate table for future weeks only, grant reporters, sources, routers and elevations through a lever that waits three days and is public from the moment it is queued, route new facets through a three day selector timelock, and propose a referrer correction that you can veto for three days. We can never write a score, a cursor, a week bucket or a claimable, and nothing already credited is ever clawed back. See [The Trust Model](safety-and-known-findings.md#the-trust-model).

### Can a Closed Week Change?

Its rate can only rise, when a later record for the same week raises the inputs, and the hub tops up what it already paid. No commission already credited is ever clawed back, not even after a correction of the referrer. See [Can a Priced Week Change?](for-referrers.md#can-a-priced-week-change).

### Can Someone Take Money That Is Not Theirs?

No accepted finding lets anyone take another party's money; where a finding costs anything, it costs time, dust or an operator's gas. The full list, grouped by the question you would ask, is in [Safety and Known Findings](safety-and-known-findings.md).

### Where Do I Find the Addresses?

In the repository's configuration records, never in prose: the vault diamonds, USD tokens and CCIP routers are live today, and the registry, hub and reader rows are filled from the files the deploy scripts write. Read an address from its file and check it with `cast code` before you use it. See [Addresses](addresses.md).

### Conclusion

Name a referrer once, nothing is taken from you, and your referrer is paid by the protocol week by week in USDC at the hub. If an answer here is not enough, the linked chapter has the full mechanism and the exact numbers.
