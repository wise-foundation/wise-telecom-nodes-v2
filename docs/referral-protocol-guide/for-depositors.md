# For Depositors

Name your referrer once, on any chain, and nothing else changes for you.

When you deposit into a Wise Telecom Nodes vault you can name a **referrer**: the person or integrator who brought you. Your referrer then earns a commission on your principal for as long as it stays in the vaults. The commission is paid by the protocol, not by you: your deposit, your interest and your exits work exactly as they would without a referrer.

This chapter covers what you do and what it means for you. What your referrer earns, and how, is in [For Referrers](for-referrers.md).

## How it Works:

### Naming a Referrer:

You name a referrer by depositing through one of the referral deposit entrypoints of a vault: `depositWithReferral`, `depositAndClaimInterestWithReferral`, `depositAndCompoundInterestWithReferral`, or their Permit2 twins. Connect your wallet, open the deposit screen, enter the referrer address (or follow a referral link that fills it in) and confirm. The assignment runs first and the deposit follows as a plain deposit.

**The assignment is written once.** The first referrer you name is recorded in the chain's referral registry and shared by every vault on that chain. A later deposit that names a different referrer is accepted as a deposit and the referrer argument is ignored. A zero referrer or your own address reverts. A vault, the registry or the hub can never be a referrer, and a referrer whose own referral chain leads back to you is refused, so two accounts cannot refer each other.

### The Referral Link:

A referral link carries the referrer's address. The front end keeps that address and writes it into the referrer field of the deposit call it sends; that exact address is what the registry records for you. If you already have a referrer, a good front end shows your recorded referrer instead of the link's address, because the link can no longer change it.

### One Referrer Across All Chains:

Your referrer is one fact across the whole mesh, not one per chain. Each registry stamps an assignment with a key made of the time of the assignment and the rank of the chain it was made on, and the registries exchange these keys over CCIP. When two registries disagree about you, **the lower key wins, which means the earlier assignment wins**; the chain ranks only break a tie between two assignments made in the same second, in a fixed order.

Suppose you name referrer A on Base on Monday and, before the two registries have talked, name referrer B on Arbitrum on Tuesday. Each chain records what it saw. As soon as the Base pair reaches Arbitrum, Arbitrum's registry sees the earlier key, switches you to A and marks the stake you already hold there for relocation from B's book to A's book. The Arbitrum pair can never win on Base, because its key is later. From then on every chain answers A, and A earns on your stake everywhere. Weeks that were already priced under B stay with B, because a closed week keeps its verdict.

The exchange is permissionless: anyone may pay the small cross chain fee to broadcast your pair to the other chains with `broadcastSync`, our courier does so for every new assignment, and a bridge of your own shares carries the pair along as well. Once you have been assigned and synced, a later deposit that names another referrer on any chain is accepted as a deposit and the referrer argument is ignored, exactly as on a single chain.

### Can My Referrer Be Changed?

Only with your consent. We (the protocol operator, called master in the code) may propose a different referrer for you with `proposeCorrectReferrer`. The proposal opens a **three day window**. During that window you can cancel it unilaterally with `cancelCorrectReferrer`, and so can we. Only after the three days may we execute it with `executeCorrectReferrer`. A proposal for a user who already has a referrer must be made on the chain where your current key was minted, which is the chain of your earliest referral deposit or of the last correction, so you veto on a chain where you have already acted.

A correction takes effect for the future only. Everything already priced at the hub stays with the old referrer. Your recorded stake moves to the new referrer's book through the same relocation path a cross chain sync flip uses, and the corrected pair carries a key that beats every copy of the old pair, so one broadcast carries it to every chain.

The same lane lets us attach a referrer to a user who never named one. We propose on any chain of the mesh, you have the same three days to cancel, and the execute records the pair with the same winning key. No book moves, because there was no referrer before. A referral deposit you make during the window kills the proposal, because the proposal is bound to the exact key you held when it was made.

> A front end that watches `ReferralCorrectionProposed` on your chain's registry can show you a cancel button for the whole three days.

## What Changes for You?

### Does a Referral Cost Me Anything?

No. Your deposit, your interest rate, your claims and your exits are the plain vault flows; the referral assignment runs first and then the deposit continues as if you had used the plain entrypoint. The commission your referrer earns is paid by the protocol from its own pot on mainnet. Nothing is deducted from your principal or your interest, and a referrer can never touch your funds.

### Does My Own Stake Matter?

Only if you refer others. Your own stake never earns commission for anyone, but if you become a referrer yourself, your own stake raises your rate on the ladder described in [What a Referrer Earns](for-referrers.md#what-a-referrer-earns).

### What Do Moves and Bridges Do?

A move between two vaults of the same product on the same chain and a bridge to your own address on another chain keep your referrer's credit, with exactly the age it had. A transfer to another address, a withdrawal through the queue and a burn end the credit for the amount that left; a new deposit builds it again. None of this changes your own balance or interest.

### What if I Join the Exit Queue?

Joining the queue is a withdrawal for commission purposes. A vault has no direct withdrawal; you exit by joining the queue with `joinQue`, which moves the queued shares from you into the vault's escrow by an internal transfer. That transfer runs the same hook as any transfer, so at the moment of the join your referrer's book is reduced by the queued amount exactly as a sale would reduce it, newest credit first, and the presence counted for your referrer stops for that amount from that instant.

Leaving the queue unfilled with `leaveQue` or `reduceQueAmount` returns the shares to you as plain balance and restores nothing for your referrer. The buyer who takes your queued shares is credited to no referrer. Your own position is unaffected: the shares come back in full if you leave, and you are paid in full if the order fills.

### Conclusion

You name a referrer once, on any chain, and the earliest assignment wins everywhere. Nothing is taken from you, your referrer earns from the protocol on the principal you keep in the vaults, and a change of referrer needs your consent. The only thing to remember is that joining the exit queue ends your referrer's credit for the queued amount, which is exactly what a withdrawal would do.
