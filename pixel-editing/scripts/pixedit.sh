#!/bin/sh
# OS/arch-agnostic launcher for pixedit.
# Detects the current platform and executes the appropriate binary from bin/.
#
# Binary naming convention in bin/:
#   pixedit-linux-amd64
#   pixedit-linux-arm64
#   pixedit-darwin-amd64
#   pixedit-darwin-arm64
#   pixedit-windows-amd64.exe
#   pixedit-windows-arm64.exe

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$ROOT_DIR/bin"

# Detect OS
case "$(uname -s 2>/dev/null)" in
  Linux*)  OS="linux" ;;
  Darwin*) OS="darwin" ;;
  MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
  *)
    echo "pixedit: unsupported OS: $(uname -s)" >&2
    exit 1
    ;;
esac

# Detect architecture
case "$(uname -m 2>/dev/null)" in
  x86_64|amd64) ARCH="amd64" ;;
  arm64|aarch64) ARCH="arm64" ;;
  armv7l|armv6l) ARCH="arm" ;;
  *)
    echo "pixedit: unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

# Build binary path
if [ "$OS" = "windows" ]; then
  BIN="$BIN_DIR/pixedit-${OS}-${ARCH}.exe"
else
  BIN="$BIN_DIR/pixedit-${OS}-${ARCH}"
fi

# Fall back to a bare 'pixedit' binary in the project root
if [ ! -f "$BIN" ]; then
  FALLBACK="$ROOT_DIR/pixedit"
  if [ -f "$FALLBACK" ]; then
    BIN="$FALLBACK"
  else
    echo "pixedit: binary not found: $BIN" >&2
    echo "pixedit: build it with: GOOS=$OS GOARCH=$ARCH go build -o $BIN ." >&2
    exit 1
  fi
fi

exec "$BIN" "$@"
