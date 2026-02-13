#!/bin/bash
# pb-reset.sh: Wipe PocketBase data, create superuser, and start fresh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/../../../.."
ENV_FILE="$ROOT_DIR/pb/.env"

if [ -f "$ENV_FILE" ]; then
  set -a; source "$ENV_FILE"; set +a
fi

if [ -z "$PB_PORT" ]; then
  echo "Error: PB_PORT is not set. Create pb/.env with PB_PORT or export it."
  exit 1
fi
PORT="$PB_PORT"

# Kill existing instance
PID=$(lsof -ti :"$PORT" 2>/dev/null || true)
if [ -n "$PID" ]; then
  echo "Stopping PocketBase on port $PORT (PID: $PID)"
  kill "$PID" 2>/dev/null || true
  sleep 1
fi

# Wipe data
if [ -d "$ROOT_DIR/pb/pb_data" ]; then
  echo "Removing pb_data..."
  rm -rf "$ROOT_DIR/pb/pb_data"
fi

# Create superuser (initializes fresh DB)
if [ -n "$PB_ADMIN_EMAIL" ] && [ -n "$PB_ADMIN_PASSWORD" ]; then
  echo "Creating superuser..."
  cd "$ROOT_DIR/pb"
  go run . superuser upsert "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD"
fi

# Start server
echo "Starting PocketBase on port $PORT..."
cd "$ROOT_DIR/pb"
exec go run . serve --http="127.0.0.1:$PORT"
