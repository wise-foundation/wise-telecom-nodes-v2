# WiseTelecomNodes multichain runbook: canonical addresses, dormant chains, adding chains

How to deploy the **vault-share bridge mesh** ([`BridgeFacet`](../../src/diamond/vault/facets/BridgeFacet.sol)) so the diamond lives at the **same canonical address on every chain**, how to bring up chains **dormant** (deposits off, bridge fully wired), and how to add the Nth chain later. The bridge is CCIP *arbitrary messaging*: the source diamond **burns** shares and sends `abi.encode(user, dstAmount, referralData)`; the destination peer diamond **mints** them. No token crosses CCIP.

> The `script/ccip/` + `src/bridgetest/` CCT token-pool bridge is a separate throwaway POC and is **not** covered here.

## How the deterministic deploy works

- The 12 facets stay plain `CREATE` (their addresses may differ per chain; only the diamond must be canonical).
- The one-shot [`WiseTelecomNodesBootstrap`](../diamond/WiseTelecomNodesBootstrap.sol) shim goes through **CreateX CREATE3** (`0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed`): its address depends only on `(deployer EOA, salt)`, never on bytecode or constructor args.
- The shim's constructor plain-CREATEs the diamond as its **nonce-1** creation → the diamond lands at `keccak256(rlp([shim, 1]))`, identical on every chain, while per-chain constructor args (underlying, name, caps) differ freely. The shim then wires all 93 selectors, sets the CCIP router, sets WISE when configured, closes the deposit gate on dormant chains, and proposes the deployer as owner; the deployer claims ownership in the next tx.
- The **salt** is msg.sender-guarded (bytes 0-19 = deployer EOA): nobody but the holder of that key can EVER claim the canonical address on any chain. Byte 20 = `0x00` keeps the address chain-invariant; bytes 21-31 are the product tag (mainnet tags are vanity-mined via `MineSaltTag.s.sol` so every canonical starts with the `0x7e1E` "TELE" prefix; testnet tags are plain ASCII `WTN-<PRODUCT>-T1`). The tag is permanent once the first chain is live. A reverted deploy does **not** burn the salt; retry safely.
- Every deploy **preflights** before broadcasting: CreateX + Permit2 must have code on the chain, the locally computed address must match both CreateX's own `computeCreate3Address` and the manifest `canonical`, and the canonical slot must still be empty.

Three products (`usdc`, `usdt`, `usdg`), fully parallel configs (`VAULT_PRODUCT` env, default `usdc`):

| file | role |
|---|---|
| `config/vault_mesh.<product>[.testnet].json` | mesh manifest: `canonical`, `deployerEOA`, `saltTag`, `peerDecimals`, `chains[]` + `active[]` |
| `config/vault_deploy.<product>.<network>.json` | per-chain init params (underlying, wise, caps, name/symbol) |
| `config/ccip.<network>.json` | CCIP `chainSelector` + `router` (from the [CCIP Directory](https://docs.chain.link/ccip/directory)) |
| `config/vault.<product>.<network>.json` | written by the deploy script as the deploy record |

## Prerequisites

- **Dedicated deployer EOA**, used ONLY for these deploys, hardware-backed. Its key **is** the squat protection; losing it means no future chain can receive the canonical address. Funded with native gas on every chain (~20M gas total per chain per product).
- `.env`: `PRIVATE_KEY` (that EOA), RPCs for the chains in play (`foundry.toml [rpc_endpoints]`; Robinhood needs `ROBINHOOD_RPC_URL`, e.g. enable ROBINHOOD_MAINNET on your Alchemy app), `ETHERSCAN_KEY` (V2: one key, all Etherscan chains; Robinhood verifies via Blockscout flags).
- **CreateX presence** per chain: `cast code 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed --rpc-url <chain>` (verified live on Ethereum/Base/Arbitrum 2026-07-13; **check Robinhood before launch**: if absent, broadcast CreateX's pre-signed deployment tx or request deployment via the CreateX repo, and resolve BEFORE blessing salts).
- Canonical **Permit2** (`0x000000000022D473030F116dDEE9F6B43aC78BA3`) must have code (facet constructor reverts otherwise).
- A live CCIP lane per chain pair you intend to bridge (check the directory: peer registration is storage-only; a bridge on a dead lane reverts at `ccipSend`).
- Real `thirdParty` / `worker` (multisig) in the `vault_deploy` configs; zero means the deployer is used. For **usdg**, deposits forward to the worker (overhang-sweep) address: leave `thirdParty` zero (or equal to `worker`); the deploy script enforces it and forces `thirdParty = worker`.
- zk-stack chains (zkSync Era etc.) derive CREATE addresses differently, so they cannot join at the canonical address; treat them as out of scope.

## Step 0: bless the canonical address (once per product)

1. Fill `deployerEOA` in `config/vault_mesh.<product>.json` (and the `.testnet` manifest).
2. Mainnet manifest only: `VAULT_PRODUCT=<product> forge script script/vault/MineSaltTag.s.sol` grinds a salt tag whose canonical starts with `0x7e1E` (pure math; only bytes 21-31 are ground, the EOA guard stays intact), then paste the printed `tag` into the manifest.
3. `VAULT_PRODUCT=<product> forge script script/vault/PredictCanonicalAddress.s.sol`: pure math, no RPC (for the `.testnet` manifest run it with `--rpc-url sepolia` so the testnet file is selected).
4. Paste the printed `canonical` into the manifest. From now on every deploy hard-asserts against it, on every chain, before broadcasting anything.

## 1. Fresh-mesh bring-up

Nothing is finalized, so peer changes apply **instantly**. Deploy all → register all → finalize all. Peers are the canonical address itself, so no cross-chain config files are needed. The commands below are the default **usdc** mesh (mainnet/base/arbitrum; Robinhood is not in the usdc mesh, see §3 and the Robinhood caveat); prefix `VAULT_PRODUCT=usdt`/`usdg` and use each product's own chain set for the others.

```bash
# --- 0. dry-run each chain first (forks the chain, runs preflight + deploy, no broadcast) ---
forge script script/vault/DeployVaultDeterministic.s.sol --rpc-url mainnet

# --- 1. deploy on every chain (canonical address; writes config/vault.<product>.<net>.json) ---
forge script script/vault/DeployVaultDeterministic.s.sol --rpc-url mainnet   --broadcast --verify --slow
forge script script/vault/DeployVaultDeterministic.s.sol --rpc-url base      --broadcast --verify --slow
forge script script/vault/DeployVaultDeterministic.s.sol --rpc-url arbitrum  --broadcast --verify --slow

# --- 2. wire peers on every chain (instant, pre-finalize; peer = the canonical address) ---
forge script script/vault/RegisterCrossChainPeers.s.sol --rpc-url mainnet   --broadcast
forge script script/vault/RegisterCrossChainPeers.s.sol --rpc-url base      --broadcast
forge script script/vault/RegisterCrossChainPeers.s.sol --rpc-url arbitrum  --broadcast

# --- 3. verify (cast code <canonical> non-empty on every chain), then finalize (arms the 3-day timelocks) ---
forge script script/vault/FinalizeVault.s.sol --rpc-url mainnet   --broadcast
forge script script/vault/FinalizeVault.s.sol --rpc-url base      --broadcast
forge script script/vault/FinalizeVault.s.sol --rpc-url arbitrum  --broadcast

# --- 4. smoke test a live lane ---
forge script script/vault/BridgeVault.s.sol --sig "run(uint64,uint256)" \
  <destSelector> 1000000 --rpc-url mainnet --broadcast
```

Or use the loop driver: `script/vault/rollout.sh <product> <deploy|peers|finalize|dryrun>`, then `verify_all.sh` for explorer verification of the diamond + shim (internal creations don't auto-verify; the facets do).

For the **USDT product**, prefix every command with `VAULT_PRODUCT=usdt` (mesh = mainnet/base/arbitrum, with no USDT on Robinhood; it can join later at the same canonical address once an underlying exists there).

For the **USDG product**, prefix every command with `VAULT_PRODUCT=usdg` (mesh = mainnet/arbitrum/robinhood, the chains where Paxos natively issues USDG; no USDG on Base, it can join later at the reserved canonical). Launch posture: robinhood `active`, mainnet + arbitrum dormant (§2). robinhood⇄arbitrum stays deliberately un-peered; bridge via Ethereum (the CCIP routers carry a direct lane since August 2026, but the mesh routes through the hub). Robinhood deploys/registers/finalizes like the other chains but needs `--skip-simulation` + the Blockscout verifier + an archive RPC (see the Robinhood caveat below).

`--skip-simulation` on Robinhood/Arbitrum-Orbit chains: fast-block Orbit L2s break forge's fork simulation; they also need an **archive** RPC. `--slow` waits for each tx before sending the next, which is required because the deploy is a multi-tx sequence (facets → CreateX shim → claimOwnership).

**Testnet mesh** (usdc: sepolia, base_sepolia, arbitrum_sepolia, mirroring the mainnet usdc mesh, so robinhood_testnet is excluded and rehearsed as a §3 add; the usdg testnet mesh mirrors its mainnet chains: sepolia, arbitrum_sepolia, robinhood_testnet): identical commands with `DeployVaultTestnet` instead of `DeployVaultDeterministic`: same CREATE3 path, mintable `TestUSD` underlying, queue seed, bumpable salt tags (`WTN-USDC-T1` → `-T2` per mesh iteration, since CREATE3 cannot redeploy at a used address). Rehearse the full flow here first, including one `active:false` chain to exercise the deposit gate + `ActivateVault`.

## 2. Dormant chains: deploy now, activate later

Set a chain's flag to `false` in the manifest's `active[]` before deploying it. The deploy is identical except the shim closes the **deposit gate** (`setDepositsDisabled(true)`):

- blocked: the deposit entrypoints (plain, deposit-and-claim, deposit-and-compound, Permit2 and referral deposits)
- working: interest claims, compounds, `joinQue` and `leaveQue`, ERC20 transfers, **outbound bridging**, **inbound `ccipReceive` mints** (the chain is fully wired into the mesh from day one)

Activation later is **one instant master tx**:

```bash
forge script script/vault/ActivateVault.s.sol --rpc-url <net> --broadcast
```

(Deliberately NOT `pause()`: pausing blocks bridge-out, which would strand anyone who bridged shares into the chain. And NOT a minimal `totalDepositCap`: inbound `ccipReceive` mints and same-chain `mintFromPeer` moves land regardless of local room (both are relocation, raising this chain's cap by exactly the minted amount via `_raiseDepositCap`), but a zero-room chain rejects every *local* origination mint (deposits, all compound variants, `mintSupply`), so anyone who bridged in could never compound there. The deposit gate blocks exactly the intended surface and nothing else. Note the cap semantics: the cap is a plain per-chain supply ceiling (`totalSupply() ≤ totalDepositCap`) and **relocations move the cap with the shares** (bridge/move-out lowers the source cap by the burned amount, bridge/move-in raises the destination cap by the minted amount), so per-chain room (`totalDepositCap − totalSupply()`) is invariant under all user relocations and **mesh-wide origination IS bounded by the sum of the per-chain caps** (Σ caps is conserved by user flows; only master `setTotalDepositCap` calls change it). The per-chain caps therefore ARE the global budget split: size each chain's cap as its slice of the intended mesh total, including a small nonzero compound budget for dormant chains. `setTotalDepositCap` floors at the live `totalSupply()`; to halt deposits use the deposit gate, not a low cap. Two ops notes: master `burnSupply` frees deposit room on this chain without restoring any other chain's cap (cleaning up an erroneous relocation is two-step: burn here, then `setTotalDepositCap` where the budget belongs); and a CCIP message that is never delivered leaves the mesh cap sum deflated by the burned amount; recover with a master cap raise on the intended destination.)

**Split-deposit accumulator** (`GraceAccumHookFacet`) ships installed but dormant on every deploy: `depositAccumWindow` stays `0`, so grace-stamp detection is single-call only, exactly as before. Arming is one instant master tx per chain (`setDepositAccumWindow(<seconds>)`), after which sub-threshold deposits inside the window sum toward `graceThresholdAmount`. Keep the window a short burst window (≤ 7 days): compound-minted interest counts toward it, and principal above `10k · 365d / (APR · W)` would hit the threshold by routine compounding (at 20% APR: W=7d → ~2.6M, W=1d → ~18.25M). Disarm any time with `setDepositAccumWindow(0)`.

## 3. Add an Nth chain to a running mesh

The canonical address is already reserved on the new chain (guarded salt), so existing chains can even **pre-register the peer before the new chain is deployed**.

### 3a. one-time config for the new chain (zero Solidity edits)

- `config/ccip.<network>.json`: selector + router from the CCIP Directory (quote the selector as a **string**).
- `config/vault_deploy.<product>.<network>.json`: underlying (verify on-chain: symbol + 6 decimals), wise, `totalDepositCap` (the newcomer's slice of the mesh budget; it simply adds to the conserved mesh cap sum, no cap change is needed on any live vault), `wtnUSDC`/`wtnUSDT` naming.
- Mesh manifest: append to `chains[]` + `active[]` (usually `false` = dormant).
- `foundry.toml`: `[rpc_endpoints]` + `[etherscan]` rows. Named chains resolve via `_networkName()`; unknown chainids fall back to the chainid-as-string, so config files may also be named `config/ccip.<chainid>.json` etc.

### 3b. new chain (instant, un-finalized)

```bash
forge script script/vault/DeployVaultDeterministic.s.sol --rpc-url <newnet> --broadcast --verify --slow
forge script script/vault/RegisterCrossChainPeers.s.sol  --rpc-url <newnet> --broadcast
forge script script/vault/FinalizeVault.s.sol            --rpc-url <newnet> --broadcast
```

### 3c. existing chains → new chain (3-day timelock, so propose on day 0)

```bash
# on each existing chain, propose now (the canonical address is known in advance)
forge script script/vault/ProposeCrossChainPeer.s.sol --sig "run(uint64,address,uint8)" \
  <newSelector> <canonical> 6 --rpc-url <existingnet> --broadcast

# ...wait 3 days (CROSS_CHAIN_PEER_CHANGE_DELAY)...

forge script script/vault/ExecuteCrossChainPeer.s.sol --sig "run(uint64)" \
  <newSelector> --rpc-url <existingnet> --broadcast
```

`cast` equivalents (master calls the diamond directly):

```bash
cast send <canonical> "proposeCrossChainPeer(uint64,address,uint8)" <selector> <canonical> 6 \
  --rpc-url <net> --private-key $PRIVATE_KEY
cast send <canonical> "executeCrossChainPeerChange(uint64)" <selector> \
  --rpc-url <net> --private-key $PRIVATE_KEY
```

Before a lane executes toward a chain whose referral registry is not sync-peered with this chain's registry, read §3e: such a lane drops the carried referral book of every user who has no referrer on the destination until the referral pairs are relayed there.

### 3d. activate when ready

`ActivateVault` on the new chain (§2). If the 3-day proposals in §3c were executed early, the lane is live the moment the gate opens.

### 3e. referral registry: raise the sync rank bound before peering

Every per-chain `ReferralRegistry` refuses a sync key whose chain rank sits above its `maxSyncRank` (three at construction, the four-chain mesh). A new chain's registry is deployed with the next rank; before any existing registry is peered with it, master calls `raiseMaxSyncRank(<newRank>)` on EVERY existing registry (upward only, at most 15), or the new chain's keys are refused by the merge. `DeployReferralRegistry.status()` prints the bound per chain and reverts while it sits below the rank of any chain whose `config/registry.<network>.json` is recorded. The new network is appended to `_rankedNetworks()` in `script/registry/DeployReferralRegistry.s.sol` (grow its `new string[](n)` length by one), whose index is the rank `deploy()` gives its registry, and to the `_remoteNetworks` lists of `script/registry/RegisterRegistrySyncPeers.s.sol` for every chain it peers with. Once its registry is deployed and recorded, run `status()` on every existing chain, and run `RegisterRegistrySyncPeers.wire()` toward the new chain only on a chain where `status()` passes. On a registry whose master is already the chain's Safe (runbook 5.2), `raiseMaxSyncRank` and every `RegisterRegistrySyncPeers` phase are Safe transactions; a script phase broadcast with the deploy key reverts `NotMaster`.

A vault bridge lane between this chain and another chain (§3c) opens only when the registry on each end is sync-peered with the other end's registry or quarantines the other chain. The vault's bridge-in apply merges a carried origin key unless the receiving chain's registry quarantines the source chain, so for a chain that carries vault lanes to this one but has no registry peer here, master first runs `removeSyncPeer(<that chain's selector>)` on this registry and `removeSyncPeer(<this chain's selector>)` on that chain's registry: the call raises the `syncPeerQuarantined` flag even on a lane that was never peered, and only a later peer execute lifts it. For example, the arbitrum and robinhood registries stay deliberately unpeered, so each quarantines the other before any vault lane between those two chains opens. On such a quarantined lane the bridge-in skips the merge, so for a user with no referrer on the destination registry the destination drops the carried book (`CohortBridgeCarryBookDropped`) while the source has already lowered the referrer's book, and no later adoption or seed restores it. Before such a lane opens, relay the pair of every user who may bridge over it to the destination registry with `broadcastSync`: a received merge never re-broadcasts, so a relay through a chain peered with both ends takes two caller-paid calls, one per hop (the origin registry toward the middle chain, then the middle chain's registry toward the destination). No vault lane between unpeered registries is open today.

Allowlist on a registry (`setAllowedVault`, or the propose and execute lane once the sync setup is finalized) only a product diamond address read from `config/vault.<product>.<network>.json` and verified with `cast code`, never any other address: an allowlisted address counts as a vault for good, so an address that already earned commission as a referrer could never designate a payout address from then on, and the registry keeps no reverse index of referrers that could refuse it.

Before a vault on this chain proposes and again before it executes its registry pointer (`UpgradeReferralRegistry.proposePointer()` and `UpgradeReferralRegistry.executePointer()`), probe the chain's registry for every seam the vault calls, with the diamond as every address argument: `cast call <registry> "syncPeerQuarantined(uint64)(bool)" <selector> --rpc-url <newnet>` for every chain of the vault's mesh manifest, plus `referrerOf(address)(address)`, `effectiveReferrerOf(address,address)(address)`, `getReferrerPair(address)(address,uint256,uint256)`, `getPayoutDesignation(address)(address,uint256)` and `seedsLatched()(bool)`, each of which must answer cleanly, and `allowedVault(address)(bool)` must read true: it stands in for the four write seams (`assignReferrer`, `mergeReferrer`, `stageCarry`, `consumeCarry`) that a read-only call cannot probe. `proposePointer()` and `executePointer()` run the same probes, hold each answer to the vault's own decode bounds and revert on an unclean one. `executePointer()` and `arm()` also refuse until `RegisterRegistrySyncPeers.finalize()` has run on the chain's registry (`syncInitialized` true), and `arm()` refuses until every vault recorded for the chain has executed the registry round.

**Related master ops** (unchanged): **repoint** a peer = propose → 3 days → execute; **kill-switch** a lane = `removeCrossChainPeer(selector)` (instant); **abort** a pending proposal = `cancelCrossChainPeerChange(selector)`.

### 3f. referral hub: register the new chain's flush and designation sources

The mainnet `ReferralHub` accepts a flush only from a registered flush source and a payout designation only from a registered designation source. `DeployReferralHub.wireFlush()` registers them from three fixed lists in `script/hub/DeployReferralHub.s.sol`, never from every config file it finds, so the lists double as the allowlist against a stray config: the spoke list helper `_spokeNetworks()`, one entry per spoke chain, which `wireFlush()` wires and `status()` prints; `_flushChainIdOf`, the spoke's chain id that the hub files both sources under; and `_flushProductsOf`, the products whose vault configs are registered on a network (on mainnet the same list names the local reporters, and a network that matches no branch falls through to the three-product default). For a new spoke chain extend all three; for a new product on a chain already in the mesh extend `_flushProductsOf` and the product lists of `DeployReferralRegistry._products()`, `RegisterRegistrySyncPeers._products()` and `UpgradeReferralRegistry._assertChainRoundExecuted`, which skip a product they do not name. Record the new chain's registry config first: `wireFlush()` reverts for a spoke that has vault configs but no registry config. Then run `wireFlush()` and verify on the hub, for every new vault and for the new registry:

```bash
cast call <hub> "flushSourceChainId(uint64,address)(uint256)" <newSelector> <vault> --rpc-url mainnet
cast call <hub> "designationSourceChainId(uint64,address)(uint256)" <newSelector> <registry> --rpc-url mainnet
```

Both must return the new chain's id. `DeployReferralHub.status()` prints the registered flush and designation sources of every spoke `_spokeNetworks()` names, so the same check reads from one call. Once the hub master is the multisig, a `wireFlush()` broadcast with the deploy key reverts `NotMaster`, so the same `setFlushSource` and `setDesignationSource` calls go through as multisig transactions.

## 4. Ownership handoff

The deployer EOA is interim master on every chain. Hand off per chain with the existing two-step:

```bash
cast send <canonical> "proposeOwner(address)" <multisig> --rpc-url <net> --private-key $PRIVATE_KEY
# multisig executes: claimOwnership()
```

## 5. Same-chain peer vaults (`moveBetweenVaults`)

Different products on the same chain are wired for same-chain share moves via `MoveFacet`. The registry is a per-address mapping, so any number of vaults per chain works; each pair is enabled independently and per side: propose on **both** vaults, wait 3 days (`PEER_VAULT_CHANGE_DELAY`), execute on both. `removePeerVault` is the instant brake for a misbehaving peer.

Pair matrix once the USDG mesh is live: Ethereum & Arbitrum `usdc⇄usdt`, `usdc⇄usdg`, `usdt⇄usdg`; Base `usdc⇄usdt`. Robinhood runs a single vault (usdg mesh), so it has no same-chain pair.

```bash
# per pair, per chain, both directions (master calls the diamonds directly)
cast send <canonicalA> "proposePeerVault(address)" <canonicalB> --rpc-url <net> --private-key $PRIVATE_KEY
cast send <canonicalB> "proposePeerVault(address)" <canonicalA> --rpc-url <net> --private-key $PRIVATE_KEY

# ...wait 3 days (PEER_VAULT_CHANGE_DELAY)...

cast send <canonicalA> "executePeerVaultChange(address)" <canonicalB> --rpc-url <net> --private-key $PRIVATE_KEY
cast send <canonicalB> "executePeerVaultChange(address)" <canonicalA> --rpc-url <net> --private-key $PRIVATE_KEY
```

Moves into a **dormant** vault work: the deposit gate blocks only the deposit entrypoints (queue joins are not gated), mirroring inbound bridge mints. `mintFromPeer` is relocation: it raises the destination's `totalDepositCap` by the moved amount and mints it, so a zero-room destination never reverts a move. Note the moved cap budget crosses the product boundary with the shares (a wtnUSDC move-out funds wtnUSDT cap on the same chain); the mesh cap sum is still conserved. All three products share 6 share-decimals, so same-chain moves scale 1:1 with zero dust.

## Caveats

- **Peer decimals** come from the manifest (`peerDecimals`, 6 for both products: share decimals, identical on every chain). A future vault with different share decimals needs the real value or `_scaleAmountForCrossChainPeer` mis-computes `dstAmount`.
- **Router is set-once** (`setCcipRouter`, done inside the shim): a wrong router in `config/ccip.<net>.json` means burning the salt tag and redeploying under the next tag. Triple-check it in the dry-run output.
- **Explorer verification**: `--verify` covers the facets (top-level CREATEs). The shim and the diamond are internal creations; run `script/vault/verify_all.sh <product> <network>` (wraps `forge verify-contract` with the right constructor args) after each deploy.
- **Robinhood** (chainId 4663): runs only the **usdg**-mesh vault (underlying USDG). No Circle USDC on Robinhood, so it is intentionally excluded from the usdc mesh; add it later once Circle USDC launches (§3). Its live CCIP lanes reach **Ethereum + Base** (and, since August 2026, **Arbitrum**); within the usdg mesh only the Ethereum lane carries value (Base has no USDG; robinhood⇄arbitrum stays deliberately un-peered and routes via Ethereum); verification via Blockscout flags; `--skip-simulation` + archive RPC required.
- Dry-run cheatcodes write `config/vault.<product>.<net>.json` even without `--broadcast`; delete the file after a dry-run so it isn't mistaken for a real deploy (`cast code` the canonical to check reality).

## Referral channel (forward-prep, unchanged)

The wire format always carries `bytes referralData` (empty by default): `bridgeToVaultWithReferral(uint64,uint256,bytes)`, master switches `setReferralEnabled(bool)` + `setBridgeGasLimit(uint256)` (200k default; 200k-5M).
