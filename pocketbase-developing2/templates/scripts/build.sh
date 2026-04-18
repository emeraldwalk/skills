#!/usr/bin/env bash
set -e

GOOS=$(go env GOOS)
GOARCH=$(go env GOARCH)
OUTPUT="pb_server_${GOOS}_${GOARCH}"

echo "Building for $GOOS/$GOARCH -> $OUTPUT"
GOOS=$GOOS GOARCH=$GOARCH go -C pb build -o "$OUTPUT" .
echo "Done: $OUTPUT"
