#!/bin/bash
# pb-schema-inspect.sh: Dump the current PocketBase schema as JSON
# Usage: bash .github/skills/pocketbase-migrating/scripts/pb-schema-inspect.sh [collection-name]
# Requires the PocketBase server to be running (via pb-dev or pb-reset).
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

BASE_URL="http://127.0.0.1:$PB_PORT"
COLLECTION_NAME="${1:-}"

# Check that the server is reachable
if ! curl -s --max-time 3 "$BASE_URL/api/health" > /dev/null 2>&1; then
  echo "Error: PocketBase server is not reachable at $BASE_URL"
  echo "Start the server first:"
  echo "  bash .github/skills/pocketbase-managing/scripts/pb-dev.sh"
  exit 1
fi

# Authenticate as superuser to access collection schema
if [ -z "$PB_ADMIN_EMAIL" ] || [ -z "$PB_ADMIN_PASSWORD" ]; then
  echo "Error: PB_ADMIN_EMAIL and PB_ADMIN_PASSWORD must be set in pb/.env"
  exit 1
fi

AUTH_RESPONSE=$(curl -s --max-time 5 \
  -H "Content-Type: application/json" \
  -d "{\"identity\":\"$PB_ADMIN_EMAIL\",\"password\":\"$PB_ADMIN_PASSWORD\"}" \
  "$BASE_URL/api/collections/_superusers/auth-with-password" 2>&1)

TOKEN=$(echo "$AUTH_RESPONSE" | grep -o '"token":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -z "$TOKEN" ]; then
  echo "Error: Failed to authenticate as superuser."
  echo "Response: $AUTH_RESPONSE"
  exit 1
fi

if [ -n "$COLLECTION_NAME" ]; then
  # Fetch a specific collection
  RESPONSE=$(curl -s --max-time 5 \
    -H "Authorization: Bearer $TOKEN" \
    "$BASE_URL/api/collections/$COLLECTION_NAME" 2>&1)

  # Check for error
  if echo "$RESPONSE" | grep -q '"code":404'; then
    echo "Error: Collection '$COLLECTION_NAME' not found."
    echo ""
    echo "Available collections:"
    curl -s --max-time 5 \
      -H "Authorization: Bearer $TOKEN" \
      "$BASE_URL/api/collections" | \
      grep -o '"name":"[^"]*"' | cut -d'"' -f4 | sort
    exit 1
  fi
else
  # Fetch all collections
  RESPONSE=$(curl -s --max-time 5 \
    -H "Authorization: Bearer $TOKEN" \
    "$BASE_URL/api/collections" 2>&1)
fi

# Pretty-print if python3 is available, otherwise raw output
if command -v python3 > /dev/null 2>&1; then
  echo "$RESPONSE" | python3 -m json.tool
else
  echo "$RESPONSE"
fi
