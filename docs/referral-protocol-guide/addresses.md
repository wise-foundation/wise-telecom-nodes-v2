# Contract Addresses

The contracts of the vault mesh and the referral system, per chain.

Every address here is copied from a configuration record in the repository, never typed by hand, and the record is the source of truth. The vault diamonds are deployed with CREATE3, so a product has the same address on every chain it runs on, and every USD token in the mesh has six decimals. The referral contracts are not deployed at the time of writing; their rows carry `(filled at deployment)` and name the file the deploy scripts write, so they are filled from those files after the rollout.

> Before you use an address, read it from its configuration file and check it onchain with `cast code <address> --rpc-url <rpc>`, which must return bytecode.

## Ethereum Mainnet (Chain Id 1)

| Contract | Address | Source of truth |
|---|---|---|
| Vault diamond, product `usdc` | `0x7e1EFF4301defc24936470B30bd1c686D2a295dc` | `config/vault.usdc.mainnet.json` |
| USD token of `usdc` (USDC, 6 decimals) | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | `config/vault.usdc.mainnet.json` |
| Vault diamond, product `usdt` | `0x7e1EBE1D25367C6D3bC0aA72A1f00fC5320a05d7` | `config/vault.usdt.mainnet.json` |
| USD token of `usdt` (USDT, 6 decimals) | `0xdAC17F958D2ee523a2206206994597C13D831ec7` | `config/vault.usdt.mainnet.json` |
| Vault diamond, product `usdg` | `0x7E1e77EDE1d3b67ee46d031FC7De9e1379856064` | `config/vault.usdg.mainnet.json` |
| USD token of `usdg` (USDG, 6 decimals) | `0xe343167631d89B6Ffc58B88d6b7fB0228795491D` | `config/vault.usdg.mainnet.json` |
| CCIP router | `0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D` | `config/ccip.mainnet.json` |
| Referral registry (mainnet, rank 0) | (filled at deployment) | `config/registry.mainnet.json` |
| Referral hub diamond | (filled at deployment) | `config/hub.mainnet.json` |
| Hub facet `ReferralHubCheckpointsFacet` | (filled at deployment) | `config/hub.mainnet.json` |
| Hub facet `ReferralHubRatesFacet` | (filled at deployment) | `config/hub.mainnet.json` |
| Hub facet `ReferralHubIntakeFacet` | (filled at deployment) | `config/hub.mainnet.json` |
| Hub facet `ReferralHubMailboxFacet` | (filled at deployment) | `config/hub.mainnet.json` |
| Hub facet `ReferralHubPayoutFacet` | (filled at deployment) | `config/hub.mainnet.json` |
| `ReferralHubReader` | (filled at deployment) | `config/hub-reader.mainnet.json` |
| Vault facets of the registry round (`ReferralFacet`, `Permit2ReferralFacet`, `CohortRecorderFacet`, `CohortHookFacet`, `CohortMoveHookFacet`, `CohortBridgeHookFacet`, the grown `AdminFacet`) | (filled at deployment) | `src/diamond/DEPLOYED.md` |
| Vault facets of the flush round (`CohortFlushFacet`, `CohortFlushPolicyFacet`) | (filled at deployment) | `src/diamond/DEPLOYED.md` |
| Sovren vault diamond, product `wsnusdc` (system 1, not yet part of the referral system) | `0x50bae2675A6D7D9CADf9e2Ec96c7e45897Be8603` | `config/vault.wsnusdc.mainnet.json` |
| USD token of `wsnusdc` (USDC, 6 decimals) | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | `config/vault.wsnusdc.mainnet.json` |

## Base (Chain Id 8453)

| Contract | Address | Source of truth |
|---|---|---|
| Vault diamond, product `usdc` | `0x7e1EFF4301defc24936470B30bd1c686D2a295dc` | `config/vault.usdc.base.json` |
| USD token of `usdc` (USDC, 6 decimals) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | `config/vault.usdc.base.json` |
| Vault diamond, product `usdt` | `0x7e1EBE1D25367C6D3bC0aA72A1f00fC5320a05d7` | `config/vault.usdt.base.json` |
| USD token of `usdt` (USDT, 6 decimals) | `0x102d758f688a4C1C5a80b116bD945d4455460282` | `config/vault.usdt.base.json` |
| CCIP router | `0x881e3A65B4d4a04dD529061dd0071cf975F58bCD` | `config/ccip.base.json` |
| Referral registry (Base, rank 1) | (filled at deployment) | `config/registry.base.json` |
| Vault facets of the registry round and the flush round | (filled at deployment) | `src/diamond/DEPLOYED.md` |

## Arbitrum One (Chain Id 42161)

| Contract | Address | Source of truth |
|---|---|---|
| Vault diamond, product `usdc` | `0x7e1EFF4301defc24936470B30bd1c686D2a295dc` | `config/vault.usdc.arbitrum.json` |
| USD token of `usdc` (USDC, 6 decimals) | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` | `config/vault.usdc.arbitrum.json` |
| Vault diamond, product `usdt` | `0x7e1EBE1D25367C6D3bC0aA72A1f00fC5320a05d7` | `config/vault.usdt.arbitrum.json` |
| USD token of `usdt` (USDT, 6 decimals) | `0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9` | `config/vault.usdt.arbitrum.json` |
| Vault diamond, product `usdg` | `0x7E1e77EDE1d3b67ee46d031FC7De9e1379856064` | `config/vault.usdg.arbitrum.json` |
| USD token of `usdg` (USDG, 6 decimals) | `0x004B506865409877C9fA29bfb1ebA929984B9bbC` | `config/vault.usdg.arbitrum.json` |
| CCIP router | `0x141fa059441E0ca23ce184B6A78bafD2A517DdE8` | `config/ccip.arbitrum.json` |
| Referral registry (Arbitrum, rank 2) | (filled at deployment) | `config/registry.arbitrum.json` |
| Vault facets of the registry round and the flush round | (filled at deployment) | `src/diamond/DEPLOYED.md` |

## Robinhood Chain (Chain Id 4663)

| Contract | Address | Source of truth |
|---|---|---|
| Vault diamond, product `usdg` | `0x7E1e77EDE1d3b67ee46d031FC7De9e1379856064` | `config/vault.usdg.robinhood.json` |
| USD token of `usdg` (USDG, 6 decimals) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | `config/vault.usdg.robinhood.json` |
| CCIP router | `0x06fC836cf9839B1cd891C440A0a45242DA6Ae1c9` | `config/ccip.robinhood.json` |
| Referral registry (Robinhood, rank 3) | (filled at deployment) | `config/registry.robinhood.json` |
| Vault facets of the registry round and the flush round | (filled at deployment) | `src/diamond/DEPLOYED.md` |

## Where Each Contract Lives

* **The hub and the reader:** exist only on Ethereum mainnet.
* **The registries:** one per chain, four in all.
* **The vault facets:** deployed once per chain and routed on every vault of that chain through the selector timelock; `src/diamond/DEPLOYED.md` records per chain which facet address is live, pending or pending redeploy.

### Conclusion

Read every address from its configuration record and check it with `cast code` before you use it. The vaults and routers above are live today; the registry, hub, facet and reader rows are filled from the files the deploy scripts write, so nothing in this chapter is ever typed by hand.
