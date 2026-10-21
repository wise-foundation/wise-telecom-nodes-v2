# For Referrers

What you earn, how it is counted and how you collect it.

As a **referrer** you earn a commission on the principal of the depositors who named you, for as long as it stays in the vaults. The commission is a yearly rate on the referred stake, counted week by week, priced at the hub on Ethereum mainnet and paid to you in USDC. Your own stake never earns commission, but it raises your rate.

How a depositor names you, and how the earliest assignment wins across chains, is in [For Depositors](for-depositors.md). This chapter covers the money: the tiers and rates, elevated status, how weeks are priced, how your weeks reach the hub, how you claim and what to expect.

## How it Works:

### What a Referrer Earns:

You earn commission on the **referred principal** present in the vaults, that is on the stake of the depositors who named you. Your own stake never earns commission; it only raises the rate. The commission is a yearly rate applied to the referred stake for the time it was present, week by week.

Every week has its own rate for every referrer, computed from two inputs the hub measures for that week alone: the average referred stake and the average own stake, each summed over every vault of every chain. Each input is placed on the ladder below and gives a tier. **The year one rate is the sum of the two tiers, capped at the cap.**

| Average stake in USD (six decimal units) | Tier |
|---|---|
| 5,000 or more | 1 percent |
| 10,000 or more | 2 percent |
| 20,000 or more | 3 percent |
| 30,000 or more | 4 percent |
| 50,000 or more | 5 percent |
| 100,000 or more | 6 percent |
| 500,000 or more | 7 percent |
| 1,000,000 or more | 8 percent |

The genesis cap is **10 percent** (1,000 basis points). Every rate is a nominal rate per 52 week year; read against a calendar year the 10 percent cap is about 10.03 percent, and the commission is paid out in USDC rather than compounded.

* **Worked example one:** you hold 50,000 of your own stake and your referees hold 100,000 in a week. Your tiers are 5 and 6, so your year one rate is capped to 10 percent on year one credit for that week. On 100,000 of year one credit the week pays 100,000 times 10 percent times 7 over 364, about 192 USDC.
* **Worked example two:** you hold no own stake and your referees hold 20,000. Your rate is 3 percent on year one credit, about 11.5 USDC for the week.
* **Worked example three:** you hold 5,000 of your own stake and your referees hold 4,000. Your own stake reaches the 1 percent tier but 4,000 of referred stake is below the first threshold, so the week pays 1 percent on the 4,000, about 0.77 USDC.

Referred credit ages. A deposit is **year one credit** from the week it was made until the 52nd week boundary after the start of its credit week, **year two credit** for the 52 weeks after that, and **mature credit** from then on. Year one credit pays the ladder rate described above. Year two credit pays 5 percent (500 basis points) and mature credit pays 1 percent (100 basis points), but only in weeks where your uncapped ladder sum reaches the cap. A referrer below the cap earns nothing on year two and mature credit that week.

The ladder, the cap and the two tail rates are one rate table. We can publish a new table with `pushRateTable`, but only for a future week, and every past week keeps the table that was in force when it closed. The first table is the genesis table above.

### Elevated Referrers:

We can **elevate** a referrer. An elevated referrer is priced as at the cap for every week inside its elevation window whatever its inputs are: 10 percent on year one credit, 5 percent on year two credit and 1 percent on mature credit under the genesis table. A grant opens at a future week and waits the same three day timelock as every other grant on the hub. An end closes the window at a future week and takes effect at once. A closed week keeps its verdict, so an elevation can never lower what you were already paid, and a week inside an ended window stays elevated for good even when it is delivered to the hub later. A referrer's history holds at most eight windows.

If you are an integrator or partner who is to be elevated, the one rule that matters is the address you use as referrer; it is explained in [The Elevated Referrer Address Rule](for-integrators.md#the-elevated-referrer-address-rule).

### The 52 Week Year:

Every quantity in the system is counted in whole weeks: the crumbs a vault writes, the cursors a flush advances, the envelopes the hub receives, the rate tables and the elevation windows are all keyed by the week number, which is the Unix timestamp divided by one week. The ring that ages a referee's credit from year one into year two and then into mature credit has 52 slots, one per week, so a cohort's year one is exactly 52 weeks long and ends on a week boundary. A calendar year would end in the middle of a week, and that week would need two rates at once.

The year the rates refer to is therefore the **52 week year of 364 days**, and every rate in the rate table is a rate per 52 week year. The hub pays each week as the stake present that week multiplied by the week's rate and by seven days over 364 days: a referrer on the 10 percent tier earns 10 percent of its weekly averages summed over 52 weeks. Read against a calendar year of 365.25 days this is about 0.34 percent more than the stated figure (365.25 divided by 364), and that is the whole effect. The ring and the pricing use the same year, so no week is ever paid twice or skipped.

> A full week of referred stake pays one fifty second of the yearly rate on it, floored once per week.

The commission of one vault, one referrer and one week is the referred token seconds of each lane multiplied by that lane's rate for the week and divided by the 364 day year and by 10,000 basis points, floored once per week.

### How Weeks Are Priced:

The vaults measure and the hub prices. For every referrer and every closed week, each vault writes a record of the referred stake present during that week in token seconds, split into the year one, year two and mature lanes, and a record of your own stake present during that week. The hub reads a week's referred average from that week's own record, never from a sample of another week, so a week is priced on what was actually present during it.

**A week's rate never falls.** When another vault's record for the same week arrives later and raises the inputs, the week's rate rises and the hub tops up what it already paid for that week. Anyone can trigger that top up with `settleWeeks`, and our keeper does so after every rate rise. Until then a claimable balance may read low, never high.

### Your First Week: a Worked Example

The rule is short. A week's commission is the week's **time weighted referred average**, times the tier rate that average reaches, times 7 over 364. The tier is read from the summed average of all your referees over that week (plus the tier your own stake reaches). A deposit counts from the second it lands, in token seconds, so a deposit made during a week is present for only the remaining fraction of that week. Weeks start on Thursday at 00:00 UTC, because the week number is the Unix timestamp divided by one week.

* **Example (a), one referee deposits exactly 5,000 on a Monday:** the week began the previous Thursday at 00:00 UTC, so a deposit at Monday 00:00 UTC is present for the remaining three of seven days, about 43 percent of the week. The week's average is about 2,143, below the first rung of 5,000, so that week pays 0. Every following full week averages 5,000, reaches the first rung of 1 percent, and pays 5,000 times 1 percent times 7 over 364, about 0.96 USDC.
* **Example (b), one referee deposits 8,000 when 25 percent of the week has elapsed:** the stake is present for 75 percent of the week, so the average is 6,000, above the first rung. That first week pays 6,000 times 1 percent times 7 over 364, about 1.15 USDC, and every following full week pays 8,000 times 1 percent times 7 over 364, about 1.54 USDC.
* **Example (c), the rung is on the sum:** two referees at 3,000 each for a full week average 6,000 together and reach the first rung, although neither alone does. The week pays about 1.15 USDC.

> A partial first week that falls under the first rung pays nothing and carries nothing over; the week's average is what it was, and the next week starts fresh.

Commission for a week becomes claimable only after the week closes, its crumb is flushed to the hub and the envelope is applied there. Until then the week is measured but not yet priced.

### Building and Losing Credit:

Deposits and compounded interest build referred credit. Any movement that changes ownership or leaves the vault destroys it: a transfer, a withdrawal, a sale through the withdrawal queue (the join is the moment of intent to sell), and a burn. **The destruction is permanent.** Credit is never rebuilt by a transfer back, by a queue leave or by a purchase through the queue; only a new deposit or compound builds credit again.

Two movements keep credit: a move between two vaults of the same product on the same chain, and a bridge to the same owner's address on another chain. In both cases the credit lands in the destination vault with exactly the age it had, so a relocation never makes a cohort younger or older. What a queue join does to your book, step by step, is in [What if I Join the Exit Queue?](for-depositors.md#what-if-i-join-the-exit-queue).

### Shipping Weeks to the Hub:

Nothing is paid on the vault. Each vault holds a book per referrer and ships it to the hub as a **flush envelope**. A flush is a transaction on the vault that settles the referrer's book, plans the closed weeks not yet shipped and sends them. From a vault on Base, Arbitrum or Robinhood the envelope travels to the hub over Chainlink CCIP; you pay the CCIP fee in the chain's native token and any excess is refunded. From a vault on mainnet the envelope is delivered to the hub in the same transaction by a direct call.

* **Who may flush:** you may always flush your own book. Otherwise only the flush bots we allowlisted may flush a referrer's book. The vaults also carry a public flush switch; it ships off and our policy is an allowlist with one courier address per vault.
* **The courier share:** when an allowlisted bot delivers closed weeks that were not yet priced, the protocol pays the bot a courier share of 5 percent (500 basis points under the genesis table) of the commission those weeks earned. The share is paid on top of your commission, never deducted from it. A referrer flushing its own book earns no share, and a flush from any address that is not an allowlisted bot earns none either. We can bound the share per delivery with `setDelivererShareCap`.
* **Only closed weeks travel:** the current week is never shipped, so nobody can gain by flushing at a particular moment inside a week. Each envelope carries at most 16 referrers and a bounded amount of work, so every accepted flush fits one transaction at the hub.

### Claiming Your Commission:

Commission accrues at the hub in USDC into a claimable bucket per source chain and referrer: what you earned on Base is a different bucket from what you earned on mainnet. The hub is its own pot; it is funded by plain USDC transfers from the protocol and never draws on a vault.

There are three claim calls on the hub.

* **`claim(chainId, referrer)`:** pays one bucket in full and reverts with `PotDry` when the pot holds less than the bucket.
* **`claimUpTo(chainId, referrer, amount)`:** pays up to the given amount and up to what the pot holds, and leaves the rest claimable.
* **`claimAll(referrer, chainIds)`:** pays every listed bucket that can pay, each up to the cover left after the buckets before it, and reverts with `NothingClaimable` only when it paid nothing at all.

A claim can be sent by you or by the bucket's payout address, and the USDC always goes to the payout address.

### Your Payout Address per Chain:

The hub chain bucket pays your own address by default, and you can set another payout address on the hub with `setPayoutAddress`. A spoke chain bucket (Base, Arbitrum, Robinhood) pays nothing until a designation from that chain has landed at the hub. Set the designation on that chain's registry with `setPayoutAddress`; the next flush of your book on that chain carries it to the hub, or push it at once with `pushPayoutAddress`, paying the CCIP fee. The newest designation wins. The reader view `claimablesOf` lists your buckets with the address each would pay, and a zero address there means the bucket is not claimable yet.

> A designation of the zero address is valid and pays the same address as your own on mainnet. If you are a contract wallet on a spoke chain, designate a nonzero mainnet address you control, because the same address on mainnet may be nobody's, or someone else's.

## What Should a Referrer Expect?

### What if the Pot Is Short?

The pot is funded by the protocol. When it is short, `claim` reverts and `claimUpTo` or `claimAll` pay what is covered, in the order you list the buckets. **Nothing is lost**; the remainder stays claimable until the pot is topped up.

### Can a Priced Week Change?

A closed week keeps its verdict. Its rate can rise when more records for it arrive, never fall, and no commission already credited is ever clawed back, not even after a correction of the referrer.

### What if a Week Is Flushed Late?

Later delivery costs nothing except time. A week flushed late is priced at the rate it had when it closed, from its own record. The vaults keep up to 104 weeks of history per book for the first flush, so flush each book at least once every two years.

### Who Controls What Is Shipped?

Your own flush is the one that advances the vault's shipping cursors. A courier can only ship weeks above your cursors, so if you want to control what is shipped first, flush your own book first.

### Does the Queue Cost Me Commission?

Yes, from the join. The queued shares leave your book at the join, newest credit first, earn you nothing while queued, and do not come back when the referee leaves the queue unfilled; a new deposit is the only way credit returns.

### Does Stake on Different Chains Add Up?

Everything is a sum across chains. Referred stake in one vault and own stake in another add up on the same ladder in the same week, and relocating stake between vaults does not change the age of its credit.

### Conclusion

You earn a nominal yearly rate on the principal your referees keep in the vaults, counted in whole weeks at the rate of each week, with your own stake raising the tier and the cap at 10 percent. Closed weeks never lose their verdict, the courier share is paid on top, and your commission waits in a bucket per chain at the hub until you claim it in USDC.
