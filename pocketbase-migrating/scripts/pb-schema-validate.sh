#!/bin/bash
# pb-schema-validate.sh: Dry-run all PocketBase migrations to check for errors
# Usage: bash .github/skills/pocketbase-migrating/scripts/pb-schema-validate.sh
# Wipes pb_data and runs migrations without starting the server.
# Run pb-reset or pb-dev afterward to get a running server.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/../../../.."
ENV_FILE="$ROOT_DIR/pb/.env"
PB_DIR="$ROOT_DIR/pb"

if [ -f "$ENV_FILE" ]; then
  set -a; source "$ENV_FILE"; set +a
fi

if [ -z "$PB_PORT" ]; then
  echo "Error: PB_PORT is not set. Create pb/.env with PB_PORT or export it."
  exit 1
fi

# Stop any running instance
PID=$(lsof -ti :"$PB_PORT" 2>/dev/null || true)
if [ -n "$PID" ]; then
  echo "Stopping PocketBase on port $PB_PORT (PID: $PID)"
  kill "$PID" 2>/dev/null || true
  sleep 1
fi

# Wipe data for a clean slate
if [ -d "$PB_DIR/pb_data" ]; then
  echo "Removing pb_data..."
  rm -rf "$PB_DIR/pb_data"
fi

# Count migration files
MIGRATION_COUNT=$(ls "$PB_DIR/pb_migrations"/*.js 2>/dev/null | wc -l | tr -d ' ')
echo "Found $MIGRATION_COUNT migration file(s)."
echo ""

if [ "$MIGRATION_COUNT" -eq 0 ]; then
  echo "No migrations to validate."
  exit 0
fi

# List migrations in order
echo "Migrations (execution order):"
ls -1 "$PB_DIR/pb_migrations"/*.js 2>/dev/null | while read -r f; do
  echo "  $(basename "$f")"
done
echo ""

# Run migrations
echo "Running migrations..."
echo "---"
cd "$PB_DIR"
if go run . migrate 2>&1; then
  echo "---"
  echo ""
  echo "All migrations applied successfully."
  echo ""
  echo "Next steps:"
  echo "  bash .github/skills/pocketbase-managing/scripts/pb-reset.sh   # start server with fresh data"
  echo "  bash .github/skills/pocketbase-managing/scripts/pb-dev.sh      # start server (keeps current data)"
else
  EXIT_CODE=$?
  echo "---"
  echo ""
  echo "Migration FAILED. Fix the errors above and re-run validation."
  exit $EXIT_CODE
fi
