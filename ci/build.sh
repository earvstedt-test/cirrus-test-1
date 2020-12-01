#!/usr/bin/env bash

set -euo pipefail
set -x

if [[ $scenario && ! -e /dev/kvm ]]; then
    >&2 echo "No KVM available on VM host."
    exit 1
fi

cachix use nix-bitcoin
echo "$NIX_PATH ($(nix eval --raw nixpkgs.lib.version))"

## Build

if [[ $scenario ]]; then
    buildExpr=$(test/run-tests.sh --scenario $scenario exprForCI)
else
    buildExpr="import ./build.nix"
fi

time nix-instantiate -E "$buildExpr" --add-root ./drv --indirect

outPath=$(nix-store --query ./drv)
if nix path-info --store https://nix-bitcoin.cachix.org $outPath &>/dev/null; then
    echo "$outPath" has already been built successfully.
    exit 0
fi

# Cirrus doesn't expose secrets to pull-request builds,
# so skip cache uploading in this case
if [[ $CACHIX_SIGNING_KEY ]]; then
    cachix push nix-bitcoin --watch-store &
    cachixPid=$!
fi

nix-build ./drv

if [[ $CACHIX_SIGNING_KEY ]]; then
    # Wait until cachix has finished uploading
    scriptDir=${BASH_SOURCE[0]%/*}
    nix run -f '<nixpkgs>' ruby -c "$scriptDir"/../helper/wait-for-network-idle.rb $cachixPid
fi