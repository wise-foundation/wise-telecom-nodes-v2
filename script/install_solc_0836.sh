#!/usr/bin/env bash
# Installs solc 0.8.36 into foundry's svm cache.
#
# The solc release list compiled into forge 1.7.1 (the current stable)
# predates solc 0.8.36, so auto-detect cannot resolve the diamond's
# `pragma solidity =0.8.36` on a machine that has never installed it and
# `forge build` aborts before attempting a download. Seeding the official
# binary into ~/.svm makes it resolve as an already-installed version.
# Run once before the first `forge build`. Remove once a foundry stable
# ships that knows 0.8.36.
set -euo pipefail

version=0.8.36

case "$(uname -s)" in
    Linux)
        url="https://binaries.soliditylang.org/linux-amd64/solc-linux-amd64-v0.8.36+commit.8a079791"
        sha="c8d35afdddc3cd2743ee88b8f25e0fecd16e2bdd5f2120f37e52cd9cc45ae0e6"
        ;;
    Darwin)
        url="https://binaries.soliditylang.org/macosx-amd64/solc-macosx-amd64-v0.8.36+commit.8a079791"
        sha="d4abcf0b3e24b7948ddfd64c374d26c3214648717777790ecb936979054a129d"
        ;;
    *)
        echo "unsupported platform $(uname -s): install solc $version into \$HOME/.svm/$version/solc-$version manually" >&2
        exit 1
        ;;
esac

dest="$HOME/.svm/$version/solc-$version"

if [ -x "$dest" ]; then
    echo "solc $version already installed at $dest"
    exit 0
fi

mkdir -p "$(dirname "$dest")"
curl -sSfL "$url" -o "$dest"

if command -v sha256sum > /dev/null; then
    echo "$sha  $dest" | sha256sum --check --strict
else
    echo "$sha  $dest" | shasum -a 256 --check
fi

chmod +x "$dest"
echo "installed solc $version at $dest"
