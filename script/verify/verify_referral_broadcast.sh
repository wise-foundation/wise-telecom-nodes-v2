#!/usr/bin/env bash
# Explorer verification backfill for every contract the referral rollout broadcasts created.
#
#   ./script/verify/verify_referral_broadcast.sh <script file> <network>
#   e.g. ./script/verify/verify_referral_broadcast.sh UpgradeReferralRegistry.s.sol arbitrum
#
# Reads every broadcast file under broadcast/<script file>/<chain id>/ (forge writes a
# `run-<timestamp>.json` per finished broadcast, whatever the `--sig`, and keeps the newest run of
# each function in `<function>-latest.json`, which also holds the CREATEs of a broadcast that
# stopped part way) and submits every CREATE once to the chain's explorer; a CREATE whose
# address holds no code (never mined) is reported and skipped. It is the fallback
# for an in-run `--verify` that missed: a lagging explorer, a verifier that refused, a chain
# where forge skipped the submission. Robinhood and its testnet verify on Blockscout, every
# other network on Etherscan V2 through the `[etherscan]` table of foundry.toml. The source of
# each contract is found by its declaration under src/, so the script keeps working after the
# pending folders graduate. Idempotent: an already verified contract reports so and the loop
# continues. A CREATE whose contract it cannot place counts as a failure. Constructor
# arguments are reconstructed from the creation code (`--guess-constructor-args`), which
# covers the three referral contracts that take any (the registry, the hub and the reader).
# Run inside WSL with foundry on PATH and the explorer key loaded through env_run.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."

SCRIPT_FILE="${1:?usage: verify_referral_broadcast.sh <script file> <network>}"
NET="${2:?network required}"

VERIFIER_ARGS=""
case "$NET" in
  robinhood)         VERIFIER_ARGS="--verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api" ;;
  robinhood_testnet) VERIFIER_ARGS="--verifier blockscout --verifier-url https://explorer.testnet.chain.robinhood.com/api" ;;
esac

CHAINID=$(cast chain-id --rpc-url "$NET")
DIR="broadcast/${SCRIPT_FILE}/${CHAINID}"

if [ ! -d "$DIR" ]; then
  echo "!! no broadcast folder at $DIR"
  exit 1
fi

PAIRS=$(python3 - "$DIR" <<'PY'
import glob, json, os, re, sys

sources = {}
for root, _, files in os.walk("src"):
    for name in files:
        if not name.endswith(".sol"):
            continue
        path = os.path.join(root, name)
        for match in re.finditer(r"^(?:abstract\s+)?contract\s+(\w+)", open(path, encoding="utf-8").read(), re.M):
            sources.setdefault(match.group(1), []).append(path)

seen = set()
runs = sorted(glob.glob(os.path.join(sys.argv[1], "*.json")))
for run in runs:
    for t in json.load(open(run)).get("transactions", []):
        if t.get("transactionType") != "CREATE" or not t.get("contractAddress"):
            continue
        address = t["contractAddress"].lower()
        if address in seen:
            continue
        seen.add(address)
        name = t.get("contractName") or ""
        paths = sources.get(name, [])
        if len(paths) != 1:
            print("UNPLACED " + (name or "unnamed") + "@" + address)
            continue
        print(paths[0] + ":" + name + " " + address)
PY
)

FAILED=0
COUNT=0
while read -r CONTRACT ADDR; do
  [ -z "${CONTRACT:-}" ] && continue
  if [[ "$CONTRACT" == UNPLACED* ]]; then
    echo "!! cannot place a source for $ADDR"
    FAILED=$((FAILED+1))
    continue
  fi
  if [ "$(cast code "$ADDR" --rpc-url "$NET")" = "0x" ]; then
    echo "!! no code at $ADDR ($CONTRACT), never mined: skipped"
    continue
  fi
  COUNT=$((COUNT+1))
  echo "--- $CONTRACT @ $ADDR"
  forge verify-contract "$ADDR" "$CONTRACT" \
    --rpc-url "$NET" --compiler-version 0.8.36 --guess-constructor-args --watch $VERIFIER_ARGS \
    || { echo "!! verification failed for $CONTRACT @ $ADDR"; FAILED=$((FAILED+1)); }
done <<< "$PAIRS"

if [ "$COUNT" -eq 0 ]; then
  echo "!! no contract found to verify in $DIR"
  exit 1
fi

if [ "$FAILED" -ne 0 ]; then
  echo "!! $FAILED contract(s) not verified on $NET"
  exit 1
fi

echo "=== $COUNT contract(s) of $DIR submitted on $NET"
