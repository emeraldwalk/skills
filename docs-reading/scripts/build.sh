#!/usr/bin/env bash
# Build the agent-docs-search binary for the current platform (default) or all targets.
# Usage:
#   ./scripts/build.sh                  # build for current platform → bin/agent-docs-search
#   ./scripts/build.sh --all-platforms  # build linux/amd64, linux/arm64, darwin/arm64, darwin/amd64

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
SRC="$ROOT/cmd/docs"
BIN="$ROOT/bin"

mkdir -p "$BIN"

build_one() {
    local goos="$1" goarch="$2" suffix="${3:-}"
    local out="$BIN/agent-docs-search${suffix}"
    echo "  → GOOS=$goos GOARCH=$goarch  $out"
    (cd "$SRC" && GOOS="$goos" GOARCH="$goarch" go build -o "$out" .)
}

if [[ "${1:-}" == "--all-platforms" ]]; then
    echo "Building for all platforms..."
    build_one linux  amd64 "-linux-amd64"
    build_one linux  arm64 "-linux-arm64"
    build_one darwin arm64 "-darwin-arm64"
    build_one darwin amd64 "-darwin-amd64"
    echo "Done. Binaries in bin/"
else
    echo "Building for current platform..."
    (cd "$SRC" && go build -o "$BIN/agent-docs-search" .)
    echo "Done → bin/agent-docs-search"
fi
