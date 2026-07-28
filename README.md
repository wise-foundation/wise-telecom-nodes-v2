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
git clone --recursive https://github.com/vonMangoldt/wise-telecom-nodes.git
cd wise-telecom-nodes
npm ci
npm ci --prefix tools
bash script/install_solc_0836.sh   # forge 1.7.1 predates solc 0.8.36, see script header
forge build                        # solc 0.8.36 diamond / 0.8.29 legacy, cancun, 600k runs
bash script/check_storage_layout.sh
```

The suite splits into an offline part and a mainnet-fork part:

```bash
# offline: 1008 tests, no network or configuration needed
forge test --no-match-path "test/{MoneyForward.t.sol,MoneyForwardViewParity.t.sol,diamond/WiseTelecomNodesBurnWiseFacet.t.sol,diamond/fork/DiamondLiveUsageFork.t.sol,diamond/fork/UniswapV4FlashLoanFork.t.sol,diamond/fork/WiseBurnFork.t.sol,diamond/fork/WiseTelecomNodesPermitFork.t.sol,migration/DiamondMigrationForkE2E.t.sol,migration/PostDeployMigrationFork.t.sol}"

# full: additionally replays the live Ethereum + Arbitrum vaults and re-verifies the
# v2 to v3 migration against real chain state at a pinned pre-migration block
cp .env.example .env               # set MAINNET_RPC_URL and ARBITRUM_RPC_URL (archive access)
forge test
```

CI runs the build, the storage-layout check and the offline suite on every push.

Beyond fuzz and invariant testing (`test/diamond/invariant/`, catalogued with IDs in
`test/diamond/INVARIANTS.md`), the interest accounting, queue cursor and bridge atomicity
laws are formally verified with [Kontrol](https://github.com/runtimeverification/kontrol)
under `test/diamond/kontrol/`.

## License

Copyright © WiseSoft / Wise Foundation. License to be determined by Wise Foundation.
