/**
 * referral-sandbox.ts: the referral system on a local chain for front end work.
 *
 * Starts anvil as a fork of Ethereum mainnet, so the vaults, the registry and the hub sit at
 * their real addresses, hands their master role to anvil's first account, runs the production
 * upgrade scripts against the fork with every three day timelock skipped by moving the chain's
 * clock, and seeds a small world of referrers and depositors with weeks already closed and
 * shipped to the hub. The result is a chain on http://127.0.0.1:8545 (chain id 1) where a front
 * end can read referrers, claimable commission and payout addresses, and send deposits, flushes
 * and claims, without waiting for anything.
 *
 *   npm --prefix tools run sandbox -- up        start anvil and take over the master role
 *   npm --prefix tools run sandbox -- install   install the referral rounds on the three vaults
 *   npm --prefix tools run sandbox -- seed      the seeded world (see SEED below)
 *   npm --prefix tools run sandbox -- status    what a front end would read
 *   npm --prefix tools run sandbox -- all       up, install, seed, status
 *   npm --prefix tools run sandbox -- down      stop anvil
 *
 * Needs foundry (anvil, forge) on the PATH and MAINNET_RPC_URL in the environment or in .env
 * at the repository root. Steps already live on mainnet are detected and skipped, so the same
 * commands work at every stage of the rollout. Everything the sandbox writes goes under
 * .sandbox/ (anvil log, pid, the broadcast records of the forge runs), which git ignores.
 *
 * The accounts are anvil's default accounts, derived from its public test mnemonic; anvil prints
 * their keys at startup. Account 0 is the sandbox operator and master, the others are the seeded
 * referrers and depositors listed in SEED.
 */

import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, openSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import {
  createTestClient, http, publicActions, walletActions, parseAbi, toFunctionSelector, toHex,
  type Address, type Hex,
} from "viem";
import { mainnet } from "viem/chains";
import { mnemonicToAccount } from "viem/accounts";

// ---- Settings ----

const PORT = Number(process.env.SANDBOX_PORT ?? 8545);
const RPC = `http://127.0.0.1:${PORT}`;
const PRODUCTS = ["usdc", "usdt", "usdg"] as const;
const SEED_PRODUCT = "usdc";
const THREE_DAYS = 3 * 24 * 60 * 60 + 1;
const WEEK = 7 * 24 * 60 * 60;
const USD = (amount: number) => BigInt(amount) * 1_000_000n;
const ANVIL_MNEMONIC = "test test test test test test test test test test test junk";

const ROOT = findRoot();
const SANDBOX_DIR = join(ROOT, ".sandbox");
const ZERO: Address = "0x0000000000000000000000000000000000000000";

const REGISTRY_SCRIPT = "script/diamond/UpgradeReferralRegistry.s.sol:UpgradeReferralRegistry";
const FLUSH_SCRIPT = "script/diamond/UpgradeCohortFlush.s.sol:UpgradeCohortFlush";
const HUB_SCRIPT = "script/hub/DeployReferralHub.s.sol:DeployReferralHub";

const DEPOSIT_WITH_REFERRAL = toFunctionSelector("depositWithReferral(uint256,address)");
const FLUSH_REFERRALS = toFunctionSelector("flushReferrals(address[])");

// ---- SEED: the world the seed step builds on the usdc vault ----
//
//   account 1  alice   referrer with three referees (accounts 2, 3, 4: 100,000, 50,000 and
//                      30,000 USDC) and 40,000 USDC of own stake; the high tier
//   account 5  bob     referrer with one referee (account 6: 5,000 USDC), no own stake, the
//                      lowest tier; pays out to account 9
//   account 7  carol   referrer with one referee (account 8: 20,000 USDC) who moves half of its
//                      shares away after the first flush, so carol's book shrinks
//
//   Two weeks pass, every referrer flushes, two more weeks pass, every referrer flushes again,
//   and the hub holds 20,000 USDC to pay claims from.

const account = (index: number) => mnemonicToAccount(ANVIL_MNEMONIC, { addressIndex: index });
const OPERATOR = account(0);
const SEED = {
  alice: account(1), aliceReferees: [account(2), account(3), account(4)],
  bob: account(5), bobReferee: account(6), bobPayout: account(9),
  carol: account(7), carolReferee: account(8), sharesSink: account(9),
};

// ---- ABI ----

const abi = parseAbi([
  "function master() view returns (address)",
  "function proposeOwner(address)",
  "function claimOwnership()",
  "function selectorToFacet(bytes4) view returns (address)",
  "function proposedSelectorFacet(bytes4) view returns (address)",
  "function transferHookChangeQueuedAt() view returns (uint256)",
  "function getReferralRegistry() view returns (address)",
  "function getProposedReferralRegistry() view returns (address)",
  "function getCohortSyncEnabled() view returns (bool)",
  "function setBridgeGasLimit(uint256)",
  "function setCohortSyncEnabled(bool)",
  "function getFlushHub() view returns (address, uint64)",
  "function getProposedFlushHub() view returns (address, uint64)",
  "function allowedReporter(address) view returns (bool)",
  "function masterMinter() view returns (address)",
  "function configureMinter(address, uint256) returns (bool)",
  "function mint(address, uint256) returns (bool)",
  "function approve(address, uint256) returns (bool)",
  "function transfer(address, uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
  "function deposit(uint256)",
  "function depositWithReferral(uint256, address)",
  "function flushReferrals(address[]) payable",
  "function effectiveReferrerOf(address, address) view returns (address)",
  "function claimable(uint256, address) view returns (uint256)",
  "function setPayoutAddress(address)",
  "function payoutAddressOf(uint256, address) view returns (address)",
]);

// ---- Chain access ----

const client = createTestClient({ mode: "anvil", chain: mainnet, transport: http(RPC, { timeout: 600_000 }) })
  .extend(publicActions)
  .extend(walletActions);

type Read = Parameters<typeof client.readContract>[0]["functionName"];

async function read<F extends Read>(address: Address, functionName: F, args: unknown[] = []) {
  return client.readContract({ address, abi, functionName, args } as never) as Promise<unknown>;
}

async function send(from: Address, address: Address, functionName: string, args: unknown[] = [], value = 0n) {
  await client.impersonateAccount({ address: from });
  for (let attempt = 1; ; attempt++) {
    const hash = await client.writeContract({ account: from, address, abi, functionName, args, value, chain: mainnet } as never);
    const receipt = await client.waitForTransactionReceipt({ hash, timeout: 600_000, pollingInterval: 1_000 });
    if (receipt.status === "success") return;
    if (attempt === 2) throw new Error(`${functionName} on ${address} from ${from} reverted (${hash})`);
    console.log(`  ${functionName} from ${from} failed once (a fork state fetch can time out under load), trying again`);
    await new Promise((r) => setTimeout(r, 5000));
  }
}

async function warp(seconds: number) {
  await client.increaseTime({ seconds });
  await client.mine({ blocks: 1 });
}

async function chainAnswers() {
  try { await client.getChainId(); return true; } catch { return false; }
}

// ---- Config and files ----

function findRoot(): string {
  let dir = resolve(process.cwd());
  while (!existsSync(join(dir, "foundry.toml"))) {
    const parent = dirname(dir);
    if (parent === dir) throw new Error("run this from inside the repository");
    dir = parent;
  }
  return dir;
}

function config(file: string, key: string): Address {
  const json = JSON.parse(readFileSync(join(ROOT, "config", file), "utf8"));
  return json[key] as Address;
}

const vault = (product: string) => config(`vault.${product}.mainnet.json`, "diamond");
const usdOf = (product: string) => config(`vault.${product}.mainnet.json`, "usd");
const registry = () => config("registry.mainnet.json", "registry");
const hub = () => config("hub.mainnet.json", "hub");

const PUBLIC_MAINNET_RPCS = [
  "https://ethereum-rpc.publicnode.com",
  "https://eth.drpc.org",
  "https://1rpc.io/eth",
  "https://cloudflare-eth.com",
];

async function mainnetRpcUrl(): Promise<string> {
  if (process.env.MAINNET_RPC_URL) return process.env.MAINNET_RPC_URL;
  const envFile = join(ROOT, ".env");
  if (existsSync(envFile)) {
    for (const line of readFileSync(envFile, "utf8").split("\n")) {
      const match = line.match(/^\s*(?:export\s+)?MAINNET_RPC_URL\s*=\s*"?([^"\s]+)"?/);
      if (match) return match[1];
    }
  }
  for (const url of PUBLIC_MAINNET_RPCS) {
    if (await answersChainId(url, 1)) {
      console.log(`MAINNET_RPC_URL is not set, forking from the public endpoint ${url} (a free key from any provider is faster and not rate limited)`);
      return url;
    }
  }
  throw new Error("no public mainnet endpoint answered; set MAINNET_RPC_URL (any mainnet endpoint; an archive node is not needed)");
}

async function answersChainId(url: string, chainId: number): Promise<boolean> {
  try {
    const response = await fetch(url, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }),
      signal: AbortSignal.timeout(10_000),
    });
    const json = (await response.json()) as { result?: string };
    return Number(json.result) === chainId;
  } catch {
    return false;
  }
}

function runForge(target: string, sig: string, product?: string) {
  const log = join(SANDBOX_DIR, "last_run.log");
  const result = spawnSync("forge", ["script", target, "--sig", sig, "--rpc-url", RPC, "--broadcast"], {
    cwd: ROOT,
    encoding: "utf8",
    env: {
      ...process.env,
      PRIVATE_KEY: toHex(OPERATOR.getHdKey().privateKey!),
      VAULT_PRODUCT: product ?? "usdc",
      FOUNDRY_BROADCAST: ".sandbox/broadcast",
    },
  });
  writeFileSync(log, (result.stdout ?? "") + (result.stderr ?? ""));
  if (result.status !== 0) {
    const reasons = (result.stdout + result.stderr).split("\n").filter((l) => /revert|Error/.test(l)).slice(0, 5);
    throw new Error(`forge script ${target} ${sig} failed (see .sandbox/last_run.log)\n${reasons.join("\n")}`);
  }
}

const isZero = (a: unknown) => (a as string).toLowerCase() === ZERO;
const same = (a: Address, b: Address) => a.toLowerCase() === b.toLowerCase();
const usd = (amount: bigint) => `${(Number(amount) / 1e6).toLocaleString("en-US", { maximumFractionDigits: 2 })} USDC`;

// ---- Steps ----

async function up() {
  mkdirSync(SANDBOX_DIR, { recursive: true });
  if (await chainAnswers()) {
    console.log(`anvil already answers on ${RPC}`);
  } else {
    console.log(`starting anvil as a fork of mainnet on port ${PORT}`);
    const log = openSync(join(SANDBOX_DIR, "anvil.log"), "w");
    const child = spawn("anvil", [
      "--fork-url", await mainnetRpcUrl(), "--port", String(PORT), "--auto-impersonate", "--silent",
    ], {
      detached: true, stdio: ["ignore", log, log],
    });
    child.unref();
    writeFileSync(join(SANDBOX_DIR, "anvil.pid"), String(child.pid));
    for (let i = 0; i < 60 && !(await chainAnswers()); i++) await new Promise((r) => setTimeout(r, 1000));
    if (!(await chainAnswers())) throw new Error("anvil did not start (see .sandbox/anvil.log)");
  }
  console.log(`chain id ${await client.getChainId()}, block ${await client.getBlockNumber()}`);
  for (const product of PRODUCTS) await takeover(vault(product), `vault ${product}`);
  await takeover(registry(), "registry");
  await takeover(hub(), "hub");
}

async function takeover(contract: Address, label: string) {
  const master = (await read(contract, "master")) as Address;
  if (same(master, OPERATOR.address)) {
    console.log(`  ${label}: master is already the sandbox operator`);
    return;
  }
  await client.setBalance({ address: master, value: 10n ** 19n });
  await send(master, contract, "proposeOwner", [OPERATOR.address]);
  await send(OPERATOR.address, contract, "claimOwnership");
  console.log(`  ${label}: master handed from ${master} to the sandbox operator`);
}

async function install() {
  for (const product of PRODUCTS) {
    const diamond = vault(product);
    console.log(`vault ${product} ${diamond}`);

    if (isZero(await read(diamond, "selectorToFacet", [DEPOSIT_WITH_REFERRAL]))) {
      if ((await read(diamond, "transferHookChangeQueuedAt")) === 0n) {
        console.log("  referral round: propose"); runForge(REGISTRY_SCRIPT, "propose()", product);
      } else console.log("  referral round: already proposed on mainnet");
      await warp(THREE_DAYS);
      console.log("  referral round: execute"); runForge(REGISTRY_SCRIPT, "execute()", product);
    } else console.log("  referral round: live");

    if (isZero(await read(diamond, "getReferralRegistry"))) {
      if (isZero(await read(diamond, "getProposedReferralRegistry"))) {
        console.log("  registry pointer: propose"); runForge(REGISTRY_SCRIPT, "proposePointer()", product);
      } else console.log("  registry pointer: already proposed on mainnet");
      await warp(THREE_DAYS);
      console.log("  registry pointer: execute"); runForge(REGISTRY_SCRIPT, "executePointer()", product);
    } else console.log("  registry pointer: live");

    if (!(await read(diamond, "getCohortSyncEnabled"))) {
      console.log("  arm: bridge gas limit and cohort sync (the cross chain peer checks of arm() do not apply to a fork)");
      await send(OPERATOR.address, diamond, "setBridgeGasLimit", [5_000_000n]);
      await send(OPERATOR.address, diamond, "setCohortSyncEnabled", [true]);
    } else console.log("  arm: live");

    if (isZero(await read(diamond, "selectorToFacet", [FLUSH_REFERRALS]))) {
      if (isZero(await read(diamond, "proposedSelectorFacet", [FLUSH_REFERRALS]))) {
        console.log("  flush round: propose"); runForge(FLUSH_SCRIPT, "propose()", product);
      } else console.log("  flush round: already proposed on mainnet");
      await warp(THREE_DAYS);
      console.log("  flush round: execute"); runForge(FLUSH_SCRIPT, "execute()", product);
    } else console.log("  flush round: live");

    const [flushHub] = (await read(diamond, "getFlushHub")) as [Address, bigint];
    if (isZero(flushHub)) {
      const [proposed] = (await read(diamond, "getProposedFlushHub")) as [Address, bigint];
      if (isZero(proposed)) {
        console.log("  flush hub pointer: propose"); runForge(FLUSH_SCRIPT, "proposeFlushHub()", product);
      } else console.log("  flush hub pointer: already proposed on mainnet");
      await warp(THREE_DAYS);
      console.log("  flush hub pointer: execute"); runForge(FLUSH_SCRIPT, "executeFlushHub()", product);
    } else console.log("  flush hub pointer: live");
  }

  let wired = true;
  for (const product of PRODUCTS) if (!(await read(hub(), "allowedReporter", [vault(product)]))) wired = false;
  if (!wired) {
    console.log("hub: flush wiring and reporter grants");
    runForge(HUB_SCRIPT, "proposeFlushWiring()");
    await warp(THREE_DAYS);
    runForge(HUB_SCRIPT, "wireFlush()");
  } else console.log("hub: wiring live");
  console.log("install done");
}

async function seed() {
  const diamond = vault(SEED_PRODUCT);
  const token = usdOf(SEED_PRODUCT);
  const minter = (await read(token, "masterMinter")) as Address;
  await client.setBalance({ address: minter, value: 10n ** 19n });
  await send(minter, token, "configureMinter", [OPERATOR.address, USD(100_000_000)]);

  const mint = (to: Address, amount: bigint) => send(OPERATOR.address, token, "mint", [to, amount]);
  const depositFor = async (who: Address, amount: bigint, referrer: Address) => {
    await mint(who, amount);
    await send(who, token, "approve", [diamond, amount]);
    await send(who, diamond, "depositWithReferral", [amount, referrer]);
  };
  const ownStake = async (who: Address, amount: bigint) => {
    await mint(who, amount);
    await send(who, token, "approve", [diamond, amount]);
    await send(who, diamond, "deposit", [amount]);
  };
  const flushAll = async () => {
    for (const referrer of [SEED.alice, SEED.bob, SEED.carol]) {
      await send(referrer.address, diamond, "flushReferrals", [[referrer.address]]);
    }
  };

  const [a1, a2, a3] = SEED.aliceReferees;
  await depositFor(a1.address, USD(100_000), SEED.alice.address);
  await depositFor(a2.address, USD(50_000), SEED.alice.address);
  await depositFor(a3.address, USD(30_000), SEED.alice.address);
  await ownStake(SEED.alice.address, USD(40_000));
  await depositFor(SEED.bobReferee.address, USD(5_000), SEED.bob.address);
  await send(SEED.bob.address, hub(), "setPayoutAddress", [SEED.bobPayout.address]);
  await depositFor(SEED.carolReferee.address, USD(20_000), SEED.carol.address);
  await mint(hub(), USD(20_000));
  console.log("deposits placed: alice (three referees, own stake), bob (one referee, payout to account 9), carol (one referee); hub pot 20,000 USDC");

  await warp(2 * WEEK);
  await flushAll();
  console.log("two weeks passed, every referrer flushed its book");

  const shares = (await read(diamond, "balanceOf", [SEED.carolReferee.address])) as bigint;
  await send(SEED.carolReferee.address, diamond, "transfer", [SEED.sharesSink.address, shares / 2n]);
  console.log("carol's referee moved half of its shares to account 9, which ends the credit on them");

  await warp(2 * WEEK);
  await flushAll();
  console.log("two more weeks passed, every referrer flushed again");
  await status();
}

async function status() {
  for (const product of PRODUCTS) {
    const diamond = vault(product);
    const [flushHub] = (await read(diamond, "getFlushHub")) as [Address, bigint];
    console.log(`vault ${product}: referral round ${isZero(await read(diamond, "selectorToFacet", [DEPOSIT_WITH_REFERRAL])) ? "not routed" : "routed"}, ` +
      `registry ${isZero(await read(diamond, "getReferralRegistry")) ? "not set" : "set"}, ` +
      `armed ${await read(diamond, "getCohortSyncEnabled")}, ` +
      `flush round ${isZero(await read(diamond, "selectorToFacet", [FLUSH_REFERRALS])) ? "not routed" : "routed"}, ` +
      `flush hub ${isZero(flushHub) ? "not set" : "set"}, ` +
      `hub reporter ${await read(hub(), "allowedReporter", [diamond])}`);
  }
  const diamond = vault(SEED_PRODUCT);
  for (const [name, who] of [["alice", SEED.alice], ["bob", SEED.bob], ["carol", SEED.carol]] as const) {
    const claimable = (await read(hub(), "claimable", [1n, who.address])) as bigint;
    const payout = (await read(hub(), "payoutAddressOf", [1n, who.address])) as Address;
    console.log(`${name} ${who.address}: claimable ${usd(claimable)}, payout address ${isZero(payout) ? "own" : payout}`);
  }
  const referrer = (await read(registry(), "effectiveReferrerOf", [SEED.aliceReferees[0].address, diamond])) as Address;
  console.log(`registry: account 2's referrer on the usdc vault is ${referrer} (alice)`);
  console.log(`hub pot: ${usd((await read(usdOf(SEED_PRODUCT), "balanceOf", [hub()])) as bigint)}`);
}

function down() {
  const pidFile = join(SANDBOX_DIR, "anvil.pid");
  if (!existsSync(pidFile)) { console.log("no anvil of this sandbox is running"); return; }
  try { process.kill(Number(readFileSync(pidFile, "utf8"))); console.log("anvil stopped"); } catch { console.log("anvil was not running"); }
  rmSync(pidFile);
}

// ---- Entry ----

const steps: Record<string, () => Promise<void> | void> = {
  up, install, seed, status, down,
  all: async () => { await up(); await install(); await seed(); },
};
const step = steps[process.argv[2] ?? ""];
if (!step) {
  console.log("usage: npm --prefix tools run sandbox -- <up|install|seed|status|all|down>");
  process.exit(2);
}
Promise.resolve(step()).catch((error) => { console.error(error.message ?? error); process.exit(1); });
