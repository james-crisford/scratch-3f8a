#!/usr/bin/env bash
# Run the plab off-device harness in the official Swift Linux container.
#
#   harness/run.sh parity data/raw/by-build
#   harness/run.sh replay data/raw/by-build/0.2.2-16
#   harness/run.sh calfit data/raw/by-build
#   harness/run.sh sim --peak 0.15 --face -3 --cal 22.9 --cup 2.0
#
# Requires Docker Desktop running. First run pulls swift:6.1 (~1GB) and
# cold-builds (~20s); incremental rebuilds are a few seconds. Build
# artifacts land in .build/ (gitignored, Linux-only — harmless).
#
# NEVER `swift build` this package natively on macOS: the shim target is
# named `simd` and would shadow Apple's module. The shim source carries
# an #error guard enforcing this.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    HOSTREPO="$(cygpath -w "$REPO")"
else
    HOSTREPO="$REPO"
fi

MSYS_NO_PATHCONV=1 docker run --rm \
    -v "$HOSTREPO:/src" -w /src swift:6.1 \
    bash -c "swift build 2>&1 | tail -1 && .build/debug/plab $*"
