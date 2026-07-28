#!/usr/bin/env bash
# Multichain rollout driver: loops one phase over every chain in the mesh manifest.
#
#   ./script/vault/rollout.sh <product> <dryrun|deploy|peers|finalize|codecheck> [--testnet]
#
#   product   usdc | usdt | usdg   (selects config/vault_mesh.<product>[.testnet].json)
#   dryrun    fork-simulate the deploy on every chain, no broadcast (preflight incl.
#             CreateX/Permit2 presence + canonical address match) — run this first;
#             delete the config/vault.<product>.<net>.json files it writes afterwards
#   deploy    broadcast the deterministic deploy on every chain (--slow, verified)
#   peers     RegisterCrossChainPeers on every chain (pre-finalize: instant)
#   finalize  FinalizeVault on every chain (arms the 3-day timelocks)
#   codecheck cast-code the canonical address on every chain (read-only sanity)
#
# Run inside WSL with foundry on PATH and .env populated (PRIVATE_KEY, RPCs, ETHERSCAN_KEY).
# Phases are separate on purpose: deploy everywhere, eyeball codecheck, then peers, then finalize.
set -euo pipefail
cd "$(dirname "$0")/../.."

PRODUCT="${1:?usage: rollout.sh <product> <dryrun|deploy|peers|finalize|codecheck> [--testnet]}"
PHASE="${2:?phase required: dryrun|deploy|peers|finalize|codecheck}"
SUFFIX=""
[[ "${3:-}" == "--testnet" ]] && SUFFIX=".testnet"

MESH="config/vault_mesh.${PRODUCT}${SUFFIX}.json"
CHAINS=$(python3 -c "import json; print('\n'.join(json.load(open('$MESH'))['chains']))")
CANON=$(python3 -c "import json; print(json.load(open('$MESH'))['canonical'])")

DEPLOY_SCRIPT="script/vault/DeployVaultDeterministic.s.sol"
[[ -n "$SUFFIX" ]] && DEPLOY_SCRIPT="script/vault/DeployVaultTestnet.s.sol"

extra_flags() {
  case "$1" in
    robinhood|robinhood_testnet|arbitrum_sepolia) echo "--skip-simulation" ;;
    *) echo "" ;;
  esac
}

verify_flags() {
  case "$1" in
    robinhood)          echo "--verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api" ;;
    robinhood_testnet)  echo "--verify --verifier blockscout --verifier-url https://explorer.testnet.chain.robinhood.com/api" ;;
    *)                  echo "--verify" ;;
  esac
}

for c in $CHAINS; do
  echo "=== [$PHASE] $c (product=$PRODUCT)"
  case "$PHASE" in
    dryrun)
      VAULT_PRODUCT="$PRODUCT" forge script "$DEPLOY_SCRIPT" --rpc-url "$c" $(extra_flags "$c")
      ;;
    deploy)
      VAULT_PRODUCT="$PRODUCT" forge script "$DEPLOY_SCRIPT" --rpc-url "$c" --broadcast --slow $(verify_flags "$c") $(extra_flags "$c")
      ;;
    peers)
      VAULT_PRODUCT="$PRODUCT" forge script script/vault/RegisterCrossChainPeers.s.sol --rpc-url "$c" --broadcast --slow $(extra_flags "$c")
      ;;
    finalize)
      VAULT_PRODUCT="$PRODUCT" forge script script/vault/FinalizeVault.s.sol --rpc-url "$c" --broadcast --slow $(extra_flags "$c")
      ;;
    codecheck)
      bytes=$(cast code "$CANON" --rpc-url "$c" | wc -c)
      echo "    canonical $CANON code hex chars: $bytes"
      ;;
    *)
      echo "unknown phase: $PHASE" >&2
      exit 1
      ;;
  esac
done
