# Wise Telecom Nodes

Fixed-rate RWA yield vaults with an on-chain exit queue, the v3 of
[ForwardVault](https://github.com/vonMangoldt/forward-vault). Deposits fund
[World Mobile AirNode](https://docs.wise.one/world-mobile) infrastructure; depositors hold
transferable ERC-20 share tokens (wtnUSDC, wtnUSDT, wtnUSDG) that accrue interest at a
master-set rate, hard-capped at 200% APR in the contract itself.

v3 collapses the separate v2 vault and queue contracts into a single diamond per product,
adds native cross-chain share bridging over Chainlink CCIP, Permit2 signature deposits,
and a deterministic deploy system that gives every product the same address on every chain.

> Built by [René Hochmuth](https://github.com/vonMangoldt) (`@author` in the on-chain verified
> source) for WiseSoft / Wise Foundation.

## Referral commission system

This repository continues [wise-telecom-nodes](https://github.com/wise-foundation/wise-telecom-nodes)
and adds the referral commission system to the running vaults, without redeploying anything that is
live. A depositor names a referrer once, with the deposit; the referrer earns a yearly commission on
that depositor's principal for as long as it stays, priced week by week against a published rate
table and paid in USDC on Ethereum mainnet. Three parts make it up:

* **A referral registry per chain** (`src/registry/`): records the referrer of every depositor once,
  shared by every vault on the chain; the four registries exchange their records over Chainlink CCIP
  and the earliest assignment wins everywhere. Deployed on Ethereum, Base, Arbitrum and Robinhood
  Chain on 2026-10-22.
* **Cohort facets on every vault** (`src/diamond/vault/facets/pending/`): record, week by week, the
  referred and the own stake each referrer had present, and ship the closed weeks to the hub. They
  reach the live diamonds through the vaults' three day selector timelocks, in two rounds per vault.
* **A hub on Ethereum mainnet** (`src/hub/`): receives the weekly records of every vault on every
  chain, prices each closed week and credits a claimable bucket per source chain and referrer; it is
  its own pot, funded by plain USDC transfers. Deployed on 2026-10-22 together with its reader.

The Sovren vault (`wsnUSDC`, built on the same vault code in its own repository) joins the same
referral umbrella as a second vault system: one rate table, one cap, one hub, one payout pot, and no
share ever moves between the two systems.

## Live deployments (v3)

One canonical address per product, identical on every chain it runs on (CREATE3, salt
mined in-repo). All contracts are verified on their explorers.

| Token | Address | Chains |
|---|---|---|
| wtnUSDC | `0x7e1EFF4301defc24936470B30bd1c686D2a295dc` | [Ethereum](https://etherscan.io/address/0x7e1EFF4301defc24936470B30bd1c686D2a295dc#code), [Base](https://basescan.org/address/0x7e1EFF4301defc24936470B30bd1c686D2a295dc#code), [Arbitrum](https://arbiscan.io/address/0x7e1EFF4301defc24936470B30bd1c686D2a295dc#code) |
| wtnUSDT | `0x7e1EBE1D25367C6D3bC0aA72A1f00fC5320a05d7` | [Ethereum](https://etherscan.io/address/0x7e1EBE1D25367C6D3bC0aA72A1f00fC5320a05d7#code), [Base](https://basescan.org/address/0x7e1EBE1D25367C6D3bC0aA72A1f00fC5320a05d7#code), [Arbitrum](https://arbiscan.io/address/0x7e1EBE1D25367C6D3bC0aA72A1f00fC5320a05d7#code) |
| wtnUSDG | `0x7E1e77EDE1d3b67ee46d031FC7De9e1379856064` | [Ethereum](https://etherscan.io/address/0x7E1e77EDE1d3b67ee46d031FC7De9e1379856064#code), [Arbitrum](https://arbiscan.io/address/0x7E1e77EDE1d3b67ee46d031FC7De9e1379856064#code), [Robinhood Chain](https://robinhoodchain.blockscout.com/address/0x7E1e77EDE1d3b67ee46d031FC7De9e1379856064) |

The [v2 contracts](https://github.com/vonMangoldt/forward-vault) were migrated live on
2026-07-23: every holder balance, every pending interest claim and every open queue order
was reproduced in v3 at its exact v2 queue position, verified on-chain against the v2 state
before activation. The v2 vaults are paused and hold no user funds.

## Architecture

Each product is one diamond: a single deployed contract whose external surface is served
partly by inherited ERC-20 vault code and partly by facets reached through a fixed
selector-to-facet router in the fallback. All facets share one storage layout, enforced
byte-for-byte by `script/check_storage_layout.sh` against a committed snapshot, so a facet
that disagrees about any slot fails CI instead of corrupting state.

```
src/
├── diamond/
│   ├── vault/          WiseTelecomNodesDiamond + 17 facets (admin, user, queue join/
│   │                   leave/fulfill/view, Permit2 deposits, CCIP bridge, same-chain
│   │                   move, sweep, WISE burn, cashed interest, grace hooks, multicall)
│   └── shared/         declarations, storage structs, helper bases
├── hub/                referral commission hub, live on Ethereum mainnet since 2026-10-22
├── registry/           per chain referral registry, live on all four chains since 2026-10-22
├── legacy/             v2 vault + queue source, kept verbatim as the parity oracle
├── migration/          migratable extensions of the v2 contracts
├── migration-v3/       flashloan-backed evacuation contract used for the v2 cash-out
└── bridgetest/         mocks and a standalone CCIP token-bridge harness
```

The mechanics in short:

- **Deposits** in USDC, USDT or USDG (6 decimals), directly or by Permit2 signature.
  Shares are plain transferable ERC-20 with interest accrual per holder.
- **Exits** go through the on-chain FIFO queue only; there is no direct withdraw in v3.
  Solvers fulfill orders fully or partially against an incentive schedule, and negative
  incentives are disabled on every live vault.
- **Cross-chain bridging** burns shares on the source chain and mints them on the
  destination through CCIP messaging between peer vaults at the same address. Pending
  interest is banked before the move so nothing is lost in transit. USDC and USDT bridge
  between Ethereum, Base and Arbitrum in all directions; USDG routes through Ethereum.
- **Same-chain moves** relocate shares between peer products (USDC to USDT and back)
  under the same interest-banking rules. Deposit caps travel with relocated shares, so
  per-chain deposit room is invariant under user flows and the cap sum stays conserved.
- **WISE burn**: the Ethereum USDC vault is the designated burn hub. A permissionless
  function burns a rotating slice of the vault's WISE balance, with a per-caller
  cooldown.
- **Hardening** on top of the v2 behaviour: interest rate capped at 200%, third-party
  address changes behind a 3-day timelock, cross-chain peer repoints staged and
  timelocked, CCIP replay protection by message id, and optional grace-period hooks
  (transfer freeze, deposit accumulator) that ship installed but dormant.

Deploys are deterministic and gated: `script/vault/DeployVaultDeterministic.s.sol` derives
the canonical address through CreateX and a bootstrap shim, and refuses to broadcast unless
the target chain's frozen signoff file in `config/` matches the compiled deploy byte-for-byte.

## Repository layout

| Path | Contents |
|---|---|
| `src/` | Contracts (see above) |
| `script/` | Deterministic deploy, mesh registration, migration and verification scripts |
| `test/` | Unit, invariant, fork and formal-verification suites |
| `config/` | Per-chain deploy manifests, CCIP lane configs, frozen deploy signoffs |
| `data/` | On-chain state snapshots consumed by the mainnet fork suites |
| `tools/` | TypeScript fetchers that regenerate and verify the `data/` snapshots |
| `abi/` | Combined ABI of the full diamond surface |

## Build and test

Requirements: [Foundry](https://getfoundry.sh) (forge 1.7.x), Node 20, Python 3, bash.

```bash
git clone --recursive https://github.com/wise-foundation/wise-telecom-nodes-v2.git
cd wise-telecom-nodes-v2
npm ci
npm ci --prefix tools
bash script/install_solc_0836.sh   # forge 1.7.1 predates solc 0.8.36, see script header
forge build                        # solc 0.8.36 diamond / 0.8.29 legacy, cancun, 600k runs
bash script/check_storage_layout.sh
```

The suite splits into an offline part and a mainnet-fork part:

```bash
# offline: no network or configuration needed
forge test --no-match-path "test/{MoneyForward.t.sol,MoneyForwardViewParity.t.sol,diamond/WiseTelecomNodesBurnWiseFacet.t.sol,diamond/fork/CcipBridgeFork.t.sol,diamond/fork/CcipCarryUpgradeRehearsalFork.t.sol,diamond/fork/CcipLaneDiscoveryFork.t.sol,diamond/fork/CcipRobinhoodBridgeFork.t.sol,diamond/fork/CcipUsdgPeeringRehearsalFork.t.sol,diamond/fork/CohortBridgeAttributionMatrixFork.t.sol,diamond/fork/CohortBridgeAttributionMatrixForkRollout.t.sol,diamond/fork/CohortBridgeAttributionMatrixForkStates.t.sol,diamond/fork/CohortFlushUpgradeFork.t.sol,diamond/fork/DiamondLiveUsageFork.t.sol,diamond/fork/ReferralBotOpsFork.t.sol,diamond/fork/ReferralHubClaimFork.t.sol,diamond/fork/ReferralPreflightFork.t.sol,diamond/fork/ReferralRegistryUpgradeFork.t.sol,diamond/fork/SovrenReferralFork.t.sol,diamond/fork/UniswapV4FlashLoanFork.t.sol,diamond/fork/WiseBurnFork.t.sol,diamond/fork/WiseTelecomNodesPermitFork.t.sol,migration/DiamondMigrationForkE2E.t.sol,migration/PostDeployMigrationFork.t.sol}"

# full: additionally replays the live Ethereum + Arbitrum vaults and re-verifies the
# v2 to v3 migration against real chain state at a pinned pre-migration block
cp .env.example .env               # set MAINNET_RPC_URL and ARBITRUM_RPC_URL (archive access)
forge test

# registry rehearsal: replays the full referral-registry rollout (ten selector
# batches + transfer-hook swap + standalone registry deploy + slot-77 pointer clock +
# arming + recorder lifecycle) on a fork of every live vault; run per chain as RPCs allow
forge test --match-path "test/diamond/fork/ReferralRegistryUpgradeFork.t.sol" --match-contract ReferralRegistryUpgradeUsdcBaseFork

# plus the mainnet cross-vault half: ONE registry serving the usdc + usdt diamonds
forge test --match-path "test/diamond/fork/ReferralRegistryUpgradeFork.t.sol" --match-contract ReferralRegistryCrossVaultMainnetFork

# claim rehearsal: the hub as its own payout pot (funded by a plain transfer, a real-USD
# claim paid out of the hub) on a mainnet fork, the retired vault rail never routed on both
# forks, the registry latch phase mirrored on both forks, the registry master handoff on
# both forks, and the payout route wiring of the registry deploy script on the base fork
forge test --match-path "test/diamond/fork/ReferralHubClaimFork.t.sol"

# flush-transport rehearsal: installs the full flush round on a live spoke fork and the
# hub (its own payout pot, funded by a plain transfer) on a mainnet fork, then proves the
# whole pipeline over the real CCIP lane (deposit, flush envelope, mailbox commit, lazy
# apply, the owed amount and a real-USD claim out of the pot) per spoke lane, plus a
# three-fork mesh proof that the CREATE3
# same-address vaults stay keyed apart per source chain
forge test --match-path "test/diamond/fork/CohortFlushUpgradeFork.t.sol" --match-contract CohortFlushUsdcBaseMainnetFork

# the robinhood lane runs OnRamp/OffRamp 2.0.0 (the CCV era); the off-ramp scrape shim
# speaks that generation too, so the same command covers it under the default engine
forge test --match-path "test/diamond/fork/CohortFlushUpgradeFork.t.sol" --match-contract CohortFlushUsdgRobinhoodMainnetFork

# the router engine remains available for any lane (hostile-message crafting, or a ramp
# generation the scrape shim does not speak yet)
WTN_CCIP_ROUTE_ENGINE=router forge test --match-path "test/diamond/fork/CohortFlushUpgradeFork.t.sol" --match-contract CohortFlushUsdgRobinhoodMainnetFork

# operator-bot ordering rehearsal: drives consecutive vault-built flush envelopes through
# the hub in REVERSED delivery order on the base usdc lane (the flush lane ships with
# allowOutOfOrderExecution) and proves claimables, courier shares, scores and score stamps
# converge exactly with the in-order run, plus the paid-cursor zeroing of a stale re-sent
# in-progress week
forge test --match-path "test/diamond/fork/ReferralBotOpsFork.t.sol"

# cross-chain attribution rehearsal: forks BOTH ends of a real CCIP lane, installs and arms
# the cohort round on each under the real master and the real timelocks, then pins the
# referred-bridge attribution matrix over the lane: the armed scenarios (plain, junk-bytes
# and forged carries, same-, earlier- and later-key registry merges, a pending flip), the
# state scenarios (untracked headroom, lazy deficit, unreferred, split rings, aged lanes,
# a round trip over the reverse lane) and the rollout states (genesis bytecode on either or
# both sides, a zeroed registry pointer, a three-lane delivery); one --match-contract
# prefix selects all three groups of a lane
forge test --match-path "test/diamond/fork/CohortBridgeAttributionMatrixFork*.t.sol" --match-contract CohortBridgeMatrixUsdcMainnetBaseFork

# the robinhood lane forks through ROBINHOOD_RPC_URL (foundry.toml); the public endpoint
# carries the full matrix, so override the variable inline when .env points elsewhere. The
# matrix self-skips under any routing engine other than the default off-ramp shim, so the
# router override above does not apply here
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path "test/diamond/fork/CohortBridgeAttributionMatrixFork*.t.sol" --match-contract CohortBridgeMatrixUsdgMainnetRobinhoodFork
```

CI runs the build, the storage-layout check and the offline suite on every push.

Beyond fuzz and invariant testing (`test/diamond/invariant/`, catalogued with IDs in
`test/diamond/INVARIANTS.md`), the interest accounting, queue cursor and bridge atomicity
laws are formally verified with [Kontrol](https://github.com/runtimeverification/kontrol)
under `test/diamond/kontrol/`.

## Running the referral system locally

For front end work you can have the whole referral system on your machine in a few minutes:
anvil, which ships with Foundry, runs a local copy of Ethereum mainnet forked from the live chain,
so the vaults, the registry and the hub sit at their real addresses, and a small tool installs the
referral rounds on that copy, skips every three day timelock by moving the chain's clock, and seeds
referrers and depositors with weeks of commission already closed and shipped to the hub. Chain id
stays 1, the clock is yours, and nothing you do touches the real chain.

### Setup

You need [Foundry](https://getfoundry.sh) (`anvil`, `forge`, `cast`) and Node 20 or newer. An RPC
endpoint for Ethereum mainnet is optional: without `MAINNET_RPC_URL` the sandbox forks from a public
endpoint, which works but is slower and rate limited, so a free key from any provider (Alchemy, Infura,
dRPC and the like; an archive node is not needed) makes the first run noticeably faster.

```bash
git clone --recursive https://github.com/wise-foundation/wise-telecom-nodes-v2.git
cd wise-telecom-nodes-v2
npm ci --prefix tools
export MAINNET_RPC_URL=https://...        # optional, see above
npm --prefix tools run sandbox -- all
```

`all` runs the four steps in order; the first run takes ten to twenty minutes, most of it compiling and
running the upgrade scripts and fetching mainnet state into the fork: `up` starts anvil as a fork and hands the master role of the three vaults, the
registry and the hub to the sandbox account, `install` puts the referral rounds on each vault and
wires the hub, `seed` builds the world below, `status` prints what a front end would read. Each
step can be run on its own, `down` stops anvil. Steps that are already live on mainnet are skipped,
so the same command keeps working as the real rollout progresses.

Point your wallet or app at `http://127.0.0.1:8545` with chain id 1. The accounts are anvil's ten
default accounts; anvil prints their keys when it starts (`.sandbox/anvil.log`), and account 0 is
the sandbox operator and master of everything.

| Account | Role in the seeded world |
|---|---|
| 1 | alice, a referrer at a high tier: three referees and 40,000 USDC of own stake |
| 2, 3, 4 | alice's referees, deposited 100,000, 50,000 and 30,000 USDC naming her |
| 5 | bob, a referrer at the lowest tier: one referee, no own stake, pays out to account 9 |
| 6 | bob's referee, 5,000 USDC |
| 7 | carol, a referrer whose book shrank: her referee moved half of its shares away |
| 8 | carol's referee, 20,000 USDC, then transferred half |
| 9 | bob's payout address, and the account carol's referee moved shares to |

Four weeks have passed on the chain, each referrer has flushed twice, and the hub holds
20,000 USDC to pay claims from.

| Contract | Address |
|---|---|
| wtnUSDC vault | `0x7e1EFF4301defc24936470B30bd1c686D2a295dc` |
| Referral registry | `0x294713C98E20F2120261201B7B74079bba2E3617` |
| Referral hub | `0x68D207E22037d1B0764a509C16c08310C539ce94` |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |

### Reading

The three reads a front end makes, as `cast` calls against the fork:

```bash
export ETH_RPC_URL=http://127.0.0.1:8545
VAULT=0x7e1EFF4301defc24936470B30bd1c686D2a295dc
REGISTRY=0x294713C98E20F2120261201B7B74079bba2E3617
HUB=0x68D207E22037d1B0764a509C16c08310C539ce94
ALICE=0x70997970C51812dc3A010C7d01b50e0d17dc79C8   # account 1
ACCOUNT2=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC

cast call $REGISTRY "effectiveReferrerOf(address,address)(address)" $ACCOUNT2 $VAULT   # who referred account 2
cast call $HUB "claimable(uint256,address)(uint256)" 1 $ALICE                          # alice's claimable USDC, 6 decimals
cast call $HUB "payoutAddressOf(uint256,address)(address)" 1 $ALICE                    # where a claim pays (her own address unless she set another)
```

The first argument of the hub reads is the chain id the commission was earned on; commission is
kept per source chain, and on the fork everything is chain 1.

### Making deposits

With `--auto-impersonate` on, you can send from any address with `--from <address> --unlocked`,
which is how the commands below mint USDC as the token's own minter. USDC has 6 decimals, so
`50000000000` is 50,000 USDC.

```bash
USDC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
ME=0x90F79bf6EB2c4f870365E785982E1f101E93b906          # account 3, or any address you like
MINTER=$(cast call $USDC "masterMinter()(address)")
cast send $USDC "configureMinter(address,uint256)" $MINTER 1000000000000 --from $MINTER --unlocked
cast send $USDC "mint(address,uint256)" $ME 100000000000 --from $MINTER --unlocked

# deposit 50,000 USDC naming alice as referrer
cast send $USDC "approve(address,uint256)" $VAULT 50000000000 --from $ME --unlocked
cast send $VAULT "depositWithReferral(uint256,address)" 50000000000 $ALICE --from $ME --unlocked
```

A depositor names a referrer once, with its first referred deposit; a later deposit naming someone
else keeps the first referrer. On a fresh fork a transaction can fail once while anvil is still
fetching the state it touches from mainnet; sending it again works.

### Moving time

Commission is counted in weeks of 604,800 seconds, aligned to the Unix epoch (a week closes when
`block.timestamp / 604800` ticks over), and only closed weeks are shipped to the hub, so a flush in
the same week as a deposit has nothing to send yet. Three ways to get there without waiting:

```bash
# jump by a fixed amount: two weeks, then mine a block so the new time is visible
cast rpc evm_increaseTime 1209600 && cast rpc evm_mine

# jump exactly to the next week boundary (the shortest skip that closes the current week)
cast rpc evm_setNextBlockTimestamp $(( ($(cast block latest -f timestamp) / 604800 + 1) * 604800 )) && cast rpc evm_mine

# let time run fast on its own: every mined block adds an hour, so a week passes in under three minutes
# (start anvil with --block-time 1 for this, so blocks are mined once a second)
cast rpc anvil_setBlockTimestampInterval 3600
cast rpc anvil_removeBlockTimestampInterval   # back to normal
```

The first two are for scripted checks, the third for watching a front end update live as weeks close.
Time only moves forward; to go back, restart the sandbox.

### Flushing and claiming

On the live chains nobody has to flush by hand: allowlisted bots ship every referrer's closed weeks to
the hub and earn a courier share for it, so a front end needs no flush button, only the reads above
and the claim. On the fork there are no bots, so after moving time a referrer flushes its own book,
which a referrer may always do, and the hub prices the closed weeks:

```bash
cast send $VAULT "flushReferrals(address[])" "[$ALICE]" --from $ALICE --unlocked
cast call $HUB "claimable(uint256,address)(uint256)" 1 $ALICE

# pay out one bucket in full; the USDC goes to the payout address (alice herself here)
cast send $HUB "claim(uint256,address)" 1 $ALICE --from $ALICE --unlocked
cast call $USDC "balanceOf(address)(uint256)" $ALICE
```

`claimUpTo(chainId, referrer, amount)` pays part of a bucket, `claimAll(referrer, chainIds)` pays
several buckets in one call, and the hub pays out of its own USDC balance, so top it up with a mint to
the hub address if a claim reports the pot dry.

### Resetting

`npm --prefix tools run sandbox -- down` stops anvil and throws the local state away; `all` starts
again from a fresh fork at the latest mainnet block. The sandbox writes its anvil log, pid and the
broadcast records of its forge runs under `.sandbox/`, which git ignores, and never touches
`broadcast/` or `config/`.

## License

Copyright © WiseSoft / Wise Foundation. License to be determined by Wise Foundation.
