#!/usr/bin/env bash
# Storage-collision guard for the WiseTelecomNodes diamond.
#
# Proves that the diamond entry contract and every concrete facet compile
# to one byte-identical storage layout (label/slot/offset/type per entry,
# compiler AST ids normalized away), and that the committed snapshot in
# test/diamond/storage_snapshot/ still matches the compiled diamond.
#
# Every facet is entered via DELEGATECALL into the diamond's storage, so
# a single facet disagreeing about any slot silently corrupts state —
# this check turns that class of bug into a loud CI failure with a
# unified diff. Run from anywhere; requires forge + python3.
set -euo pipefail
cd "$(dirname "$0")/.."

DIAMOND="src/diamond/vault/WiseTelecomNodesDiamond.sol:WiseTelecomNodesDiamond"
SNAPSHOT="test/diamond/storage_snapshot/vault_diamond_layout.json"
FACETS=(
    AdminFacet
    BridgeFacet
    BurnWiseFacet
    CashedInterestFacet
    CohortHookFacet
    CohortRecorderFacet
    GraceAccumHookFacet
    GraceFreezeHookFacet
    MigrationSeedFacet
    MoveFacet
    MulticallFacet
    Permit2ReferralFacet
    Permit2UserFacet
    ProxyFacet
    QueueAdminFacet
    QueueFulfillFacet
    QueueJoinLeaveFacet
    QueueViewFacet
    ReferralFacet
    SweepFacet
    UserFacet
)

# Project each storage entry to {label, slot, offset, type} and strip the
# AST-id suffixes solc embeds in struct/contract type names (they churn
# across unrelated recompiles and would cause false drift).
normalize() {
    python3 -c '
import json, re, sys
data = json.load(sys.stdin)
for e in data["storage"]:
    print(json.dumps({
        "label": e["label"],
        "slot": e["slot"],
        "offset": e["offset"],
        "type": re.sub(r"\)\d+", ")", e["type"]),
    }, sort_keys=True))
'
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Facets live in facets/ when routed on the live diamonds and in
# facets/pending/ until their upgrade has actually been broadcast
# (see src/diamond/DEPLOYED.md); resolve whichever exists.
facet_path() {
    if [ -f "src/diamond/vault/facets/$1.sol" ]; then
        echo "src/diamond/vault/facets/$1.sol:$1"
    else
        echo "src/diamond/vault/facets/pending/$1.sol:$1"
    fi
}

forge inspect "$DIAMOND" storage-layout --json | normalize > "$tmp/diamond.txt"

fail=0
for name in "${FACETS[@]}"; do
    forge inspect "$(facet_path "$name")" storage-layout --json \
        | normalize > "$tmp/$name.txt"
    if ! diff -u "$tmp/diamond.txt" "$tmp/$name.txt" > "$tmp/$name.diff"; then
        echo "STORAGE LAYOUT DRIFT: $name != WiseTelecomNodesDiamond"
        cat "$tmp/$name.diff"
        fail=1
    fi
done

normalize < "$SNAPSHOT" > "$tmp/snapshot.txt"
if ! diff -u "$tmp/snapshot.txt" "$tmp/diamond.txt" > "$tmp/snapshot.diff"; then
    echo "SNAPSHOT DRIFT: $SNAPSHOT no longer matches the compiled diamond."
    echo "If the layout change is intentional, regenerate with:"
    echo "  forge inspect $DIAMOND storage-layout --json > $SNAPSHOT"
    cat "$tmp/snapshot.diff"
    fail=1
fi

# Deploy-slim facets mirror only the slots they touch, padded into place
# with __gap*/__pad* fillers. Every pinned (non-filler) entry must sit at
# exactly the slot/offset/type the diamond assigns to the same label, or
# the facet reads garbage through the delegatecall.
PINNED_FACETS=(
    InterestAdminFacet
    QueueForecastFacet
)

for name in "${PINNED_FACETS[@]}"; do
    forge inspect "$(facet_path "$name")" storage-layout --json \
        | normalize > "$tmp/$name.pinned.txt"
    if ! python3 -c '
import json, sys
diamond = {}
for line in open(sys.argv[1]):
    e = json.loads(line)
    diamond[e["label"]] = (e["slot"], e["offset"], e["type"])
bad = 0
pinned = 0
for line in open(sys.argv[2]):
    e = json.loads(line)
    if e["label"].startswith("__gap") or e["label"].startswith("__pad"):
        continue
    pinned += 1
    want = diamond.get(e["label"])
    got = (e["slot"], e["offset"], e["type"])
    if want is None:
        print(f"  {e['\''label'\'']}: not present in the diamond layout")
        bad = 1
    elif want != got:
        print(f"  {e['\''label'\'']}: facet has slot={got[0]} offset={got[1]} type={got[2]}, diamond has slot={want[0]} offset={want[1]} type={want[2]}")
        bad = 1
if pinned == 0:
    print("  no pinned entries found (unexpected)")
    bad = 1
sys.exit(bad)
' "$tmp/diamond.txt" "$tmp/$name.pinned.txt"; then
        echo "PINNED SLOT MISMATCH: $name does not line up with the diamond layout."
        fail=1
    fi
done

if [ "$fail" -eq 0 ]; then
    echo "storage layout OK: diamond + ${#FACETS[@]} facets identical, ${#PINNED_FACETS[@]} slim facets pinned correctly, snapshot matches ($(wc -l < "$tmp/diamond.txt") entries)"
fi
exit "$fail"
