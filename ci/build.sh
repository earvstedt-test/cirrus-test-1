#!/usr/bin/env bash

# This script can also be run locally for testing:
#   scenario=default ./build.sh
#
# It leaves no persistent traces on the host system (when variable CIRRUS_CI is unset).

set -euo pipefail
set -x

scenario=${scenario:-}
CACHIX_SIGNING_KEY=${CACHIX_SIGNING_KEY:-}

cd "${BASH_SOURCE[0]%/*}"

if [[ -v CIRRUS_CI ]]; then
    TMPDIR=/tmp
    if [[ $scenario ]]; then
        if [[ ! -e /dev/kvm ]]; then
            >&2 echo "No KVM available on VM host."
            exit 1
        fi
        if [[ $(stat -c %a /dev/kvm) != *6 ]]; then
            chmod o+rw /dev/kvm
        fi
    fi
else
    TMPDIR=$(mktemp -d -p /tmp)
    trap "rm -rf $TMPDIR" EXIT
    # Prevent cachix from writing to HOME
    export HOME=$TMPDIR
fi

cachix use nix-bitcoin-ci-ea
echo "$NIX_PATH ($(nix eval --raw nixpkgs.lib.version))"

## Build

if [[ $scenario ]]; then
    buildExpr=$(../test/run-tests.sh --scenario $scenario exprForCI)
else
    buildExpr="import ./build.nix"
fi

time nix-instantiate -E "$buildExpr" --add-root $TMPDIR/drv --indirect

outPath=$(nix-store --query $TMPDIR/drv)
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

nix-build $TMPDIR/drv

if [[ $CACHIX_SIGNING_KEY ]]; then
    # Wait until cachix has finished uploading
    nix run -f '<nixpkgs>' ruby -c ../helper/wait-for-network-idle.rb $cachixPid
fi
