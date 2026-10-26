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
share ever moves between the two systems. A separate guide covers the system for depositors,
referrers, integrators and front end developers, chapter by chapter.

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

## Running the vaults locally

For front end work you can run local copies of the live chains with anvil, which ships with Foundry.
Each copy is a fork: it starts from the real chain state, so the vaults, the registries and the hub
sit at their real addresses, and from there you get free test funds and a clock you control. Start
one per chain, each in its own terminal:

```bash
anvil --fork-url $MAINNET_RPC_URL  --port 8545 --auto-impersonate
anvil --fork-url $BASE_RPC_URL     --port 8546 --auto-impersonate
anvil --fork-url $ARBITRUM_RPC_URL --port 8547 --auto-impersonate
```

Any RPC endpoint of the chain works, an archive node is not needed. A fork keeps the chain id of the
chain it copies (1, 8453 and 42161), so add `http://127.0.0.1:8545` and the others to your wallet as
custom networks with those ids and import one of the test accounts anvil prints at startup. The forks
do not talk to each other, so a bridge or a cross chain message never arrives; everything that stays
on one chain behaves as it does live.

| Contract | Ethereum | Base | Arbitrum |
|---|---|---|---|
| wtnUSDC vault | `0x7e1EFF4301defc24936470B30bd1c686D2a295dc` | same | same |
| Referral registry | `0x294713C98E20F2120261201B7B74079bba2E3617` | `0x15576bCE5a72566EbaeEBaB0D7b560Ef973C5767` | `0x8d2C71eCF741B1A6ca1797Cf6E6B67aC9e234Ad3` |
| Referral hub | `0x68D207E22037d1B0764a509C16c08310C539ce94` | | |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |

The commands below use the mainnet fork. For Base or Arbitrum change `ETH_RPC_URL` and `USDC`.

```bash
export ETH_RPC_URL=http://127.0.0.1:8545
USDC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
VAULT=0x7e1EFF4301defc24936470B30bd1c686D2a295dc
REGISTRY=0x294713C98E20F2120261201B7B74079bba2E3617
HUB=0x68D207E22037d1B0764a509C16c08310C539ce94
ME=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266        # anvil test account 0
REFERRER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8  # anvil test account 1

# test USDC: the token's master minter makes itself a minter and mints
MINTER=$(cast call $USDC "masterMinter()(address)")
cast rpc anvil_setBalance $MINTER 0xDE0B6B3A7640000
cast send $USDC "configureMinter(address,uint256)" $MINTER 1000000000000 --from $MINTER --unlocked
cast send $USDC "mint(address,uint256)" $ME 100000000000 --from $MINTER --unlocked

# deposit 50,000 USDC naming a referrer, then read the referrer back from the registry
cast send $USDC "approve(address,uint256)" $VAULT 50000000000 --from $ME --unlocked
cast send $VAULT "depositWithReferral(uint256,address)" 50000000000 $REFERRER --from $ME --unlocked
cast call $REGISTRY "effectiveReferrerOf(address,address)(address)" $ME $VAULT

# let two weeks pass, ship the closed weeks to the hub and read what the referrer can claim
cast rpc evm_increaseTime 1209600 && cast rpc evm_mine
cast send $VAULT "flushReferrals(address[])" "[$REFERRER]" --from $REFERRER --unlocked
cast call $HUB "claimable(uint256,address)(uint256)" 1 $REFERRER

# the hub pays out of its own USDC balance, so fund it before claiming
cast send $USDC "mint(address,uint256)" $HUB 10000000000 --from $MINTER --unlocked
cast send $HUB "claim(uint256,address)" 1 $REFERRER --from $REFERRER --unlocked
```

USDC has 6 decimals, so `50000000000` is 50,000 USDC. A week is 604,800 seconds and only closed weeks
are shipped, so a flush in the same week as the deposit has nothing to send yet. With
`--auto-impersonate` you can send from any address with `--from <address> --unlocked`, which is how
the commands above act as the USDC minter. Restarting anvil throws the local state away and forks the
chain again at its latest block.

## License

Copyright © WiseSoft / Wise Foundation. License to be determined by Wise Foundation.
