#!/bin/bash
# pbcli.sh: Unified PocketBase CLI for project management and migrations
# Usage (from project root): bash <SKILL_PATH>/scripts/pbcli.sh <command> [options]

set -e

ROOT_DIR="$(pwd)"
PB_DIR="$ROOT_DIR/pb"
ENV_FILE="$PB_DIR/.env"
GITIGNORE="$ROOT_DIR/.gitignore"
MIGRATIONS_DIR="$PB_DIR/pb_migrations"
PID_FILE="$PB_DIR/.pid"
LOG_FILE="$PB_DIR/server.log"

# Help message
show_help() {
  cat << EOF
PocketBase CLI - Unified tool for PocketBase project management

USAGE:
  pbcli.sh <command> [subcommand] [options]

COMMANDS:
  init <module> <port> <email> <password>
      Initialize a new PocketBase project
      Creates pb/ directory, main.go, .env file, updates .gitignore,
      initializes Go module, and runs go mod tidy

  start [--reset] [--background]
      Start the PocketBase dev server
      Stops existing instance if running, then starts server
      --reset: Remove pb_data before starting (fresh database)
      --background: Run server in background, log to pb/server.log

  stop
      Stop the running PocketBase server

  migration create <description> [type]
      Generate a timestamped migration boilerplate file
      description: snake_case name (e.g. create_posts)
      type: create (default), modify, or seed

  schema inspect [collection-name]
      Dump the current PocketBase schema as JSON
      Requires the server to be running
      Optional: specify collection name to inspect only that collection

  schema validate
      Dry-run all migrations to check for errors
      Wipes pb_data and runs migrations without starting server

  help
      Show this help message

EXAMPLES:
  # Initialize new project
  pbcli.sh init myapp/pb 8090 admin@example.com mypassword

  # Start server
  pbcli.sh start

  # Start with fresh database
  pbcli.sh start --reset

  # Start in background
  pbcli.sh start --background

  # Start with fresh database in background
  pbcli.sh start --reset --background

  # Stop server
  pbcli.sh stop

  # Create a new migration
  pbcli.sh migration create add_posts_collection
  pbcli.sh migration create seed_initial_data seed

  # Inspect schema
  pbcli.sh schema inspect
  pbcli.sh schema inspect posts

  # Validate migrations
  pbcli.sh schema validate

NOTES:
  - All commands must be run from the project root directory
  - Configuration is stored in pb/.env (PB_PORT, PB_ADMIN_EMAIL, PB_ADMIN_PASSWORD)
  - Script path: Use full absolute path (e.g., ~/.claude/skills/pocketbase-developing/scripts/pbcli.sh)
EOF
}

# Stop command
cmd_stop() {
  if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
  fi

  if [ -z "$PB_PORT" ]; then
    echo "Error: PB_PORT is not set. Create pb/.env with PB_PORT or export it."
    exit 1
  fi
  PORT="$PB_PORT"

  # Try to stop by PID file first
  if [ -f "$PID_FILE" ]; then
    SAVED_PID=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$SAVED_PID" ] && kill -0 "$SAVED_PID" 2>/dev/null; then
      echo "Stopping PocketBase (PID: $SAVED_PID from pid file)"
      kill "$SAVED_PID" 2>/dev/null || true
      sleep 1
      rm -f "$PID_FILE"
      echo "Server stopped."
      return
    else
      # PID file exists but process is dead, clean up
      rm -f "$PID_FILE"
    fi
  fi

  # Fallback to port-based lookup
  PID=$(lsof -ti :"$PORT" 2>/dev/null || true)
  if [ -n "$PID" ]; then
    echo "Stopping PocketBase on port $PORT (PID: $PID)"
    kill "$PID" 2>/dev/null || true
    sleep 1
    echo "Server stopped."
  else
    echo "No PocketBase instance running on port $PORT."
  fi
}

# Start command
cmd_start() {
  local RESET_FLAG=false
  local BACKGROUND_FLAG=false

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case $1 in
      --reset)
        RESET_FLAG=true
        shift
        ;;
      --background)
        BACKGROUND_FLAG=true
        shift
        ;;
      *)
        echo "Error: Unknown option '$1'"
        echo "Usage: pbcli.sh start [--reset] [--background]"
        exit 1
        ;;
    esac
  done

  if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
  fi

  if [ -z "$PB_PORT" ]; then
    echo "Error: PB_PORT is not set. Create pb/.env with PB_PORT or export it."
    exit 1
  fi
  PORT="$PB_PORT"

  # Stop existing instance if running
  PID=$(lsof -ti :"$PORT" 2>/dev/null || true)
  if [ -n "$PID" ]; then
    echo "Stopping existing PocketBase on port $PORT (PID: $PID)"
    kill "$PID" 2>/dev/null || true
    sleep 1
  fi

  # Clean up old PID file if exists
  rm -f "$PID_FILE"

  # Reset database if --reset flag is set
  if [ "$RESET_FLAG" = true ]; then
    if [ -d "$PB_DIR/pb_data" ]; then
      echo "Removing pb_data..."
      rm -rf "$PB_DIR/pb_data"
    fi

    # Create superuser after reset
    if [ -n "$PB_ADMIN_EMAIL" ] && [ -n "$PB_ADMIN_PASSWORD" ]; then
      echo "Creating superuser..."
      cd "$PB_DIR"
      go run . superuser upsert "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD"
    fi
  fi

  # Create superuser on first run (no pb_data yet)
  if [ ! -d "$PB_DIR/pb_data" ] && [ -n "$PB_ADMIN_EMAIL" ] && [ -n "$PB_ADMIN_PASSWORD" ]; then
    echo "First run detected — creating superuser..."
    cd "$PB_DIR"
    go run . superuser upsert "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD"
  fi

  # Start server
  cd "$PB_DIR"

  if [ "$BACKGROUND_FLAG" = true ]; then
    echo "Starting PocketBase on port $PORT in background..."
    echo "Logs: $LOG_FILE"
    nohup go run . serve --http="127.0.0.1:$PORT" > "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    echo "Server started (PID: $(cat "$PID_FILE"))"
    echo "Run 'pbcli.sh stop' to stop the server"
  else
    echo "Starting PocketBase on port $PORT..."
    exec go run . serve --http="127.0.0.1:$PORT"
  fi
}

# Init command
cmd_init() {
  MODULE_NAME="${1:-}"
  PB_PORT="${2:-}"
  PB_ADMIN_EMAIL="${3:-}"
  PB_ADMIN_PASSWORD="${4:-}"

  # Create main.go if it doesn't exist
  if [ ! -f "$PB_DIR/main.go" ]; then
    mkdir -p "$PB_DIR"
    cat > "$PB_DIR/main.go" << 'GOEOF'
package main

import (
	"log"
	"os"
	"strings"

	"github.com/pocketbase/pocketbase"
	"github.com/pocketbase/pocketbase/plugins/jsvm"
	"github.com/pocketbase/pocketbase/plugins/migratecmd"
)

func main() {
	app := pocketbase.New()

	// Enable automigrate only during development (go run)
	isGoRun := strings.HasPrefix(os.Args[0], os.TempDir())

	jsvm.MustRegister(app, jsvm.Config{
		MigrationsDir: "pb_migrations",
	})

	migratecmd.MustRegister(app, app.RootCmd, migratecmd.Config{
		TemplateLang: migratecmd.TemplateLangJS,
		Automigrate:  isGoRun,
	})

	if err := app.Start(); err != nil {
		log.Fatal(err)
	}
}
GOEOF
    echo "Created pb/main.go."
  else
    echo "pb/main.go already exists, skipping."
  fi

  # Create pb/.env if it doesn't exist
  if [ ! -f "$ENV_FILE" ]; then
    if [ -z "$PB_PORT" ] || [ -z "$PB_ADMIN_EMAIL" ] || [ -z "$PB_ADMIN_PASSWORD" ]; then
      echo "Error: pb/.env does not exist and missing required args."
      echo "Usage: pbdev.sh init <module-name> <port> <admin-email> <admin-password>"
      exit 1
    fi
    cat > "$ENV_FILE" << EOF
PB_PORT=$PB_PORT
PB_ADMIN_EMAIL=$PB_ADMIN_EMAIL
PB_ADMIN_PASSWORD=$PB_ADMIN_PASSWORD
EOF
    echo "Created pb/.env."
  else
    echo "pb/.env already exists, skipping."
  fi

  # Update .gitignore
  PB_IGNORE_ENTRIES=("pb/pb_data/" "pb/pocketbase" "pb/.env" "pb/.pid" "pb/server.log")
  if [ ! -f "$GITIGNORE" ]; then
    printf "# PocketBase\n" > "$GITIGNORE"
    for entry in "${PB_IGNORE_ENTRIES[@]}"; do
      printf "%s\n" "$entry" >> "$GITIGNORE"
    done
    echo "Created .gitignore with PocketBase entries."
  else
    for entry in "${PB_IGNORE_ENTRIES[@]}"; do
      if ! grep -qxF "$entry" "$GITIGNORE"; then
        printf "\n%s" "$entry" >> "$GITIGNORE"
        echo "Added $entry to .gitignore."
      fi
    done
  fi

  # Initialize Go module if needed
  cd "$PB_DIR"

  if [ ! -f "go.mod" ]; then
    if [ -z "$MODULE_NAME" ]; then
      echo "Error: go.mod does not exist and no module name provided."
      echo "Usage: pbdev.sh init <module-name> <port> <admin-email> <admin-password>"
      exit 1
    fi
    echo "Initializing Go module: $MODULE_NAME"
    go mod init "$MODULE_NAME"
  else
    echo "go.mod already exists, skipping init."
  fi

  echo "Running go mod tidy..."
  go mod tidy
  echo "Done."
}

# Migration create command
cmd_migration_create() {
  DESCRIPTION="${1:-}"
  TYPE="${2:-create}"

  if [ -z "$DESCRIPTION" ]; then
    echo "Error: description is required."
    echo "Usage: pbcli.sh migration create <description> [type]"
    echo "  type: create (default), modify, or seed"
    exit 1
  fi

  # Ensure migrations directory exists
  mkdir -p "$MIGRATIONS_DIR"

  # Generate timestamp
  TIMESTAMP=$(date +%s)
  FILENAME="${TIMESTAMP}_${DESCRIPTION}.js"
  FILEPATH="$MIGRATIONS_DIR/$FILENAME"

  case "$TYPE" in
    create)
      cat > "$FILEPATH" << 'MIGEOF'
/// <reference path="../pb_data/types.d.ts" />

migrate((app) => {
  const collection = new Collection({
    type: "base",          // "base", "auth", or "view"
    name: "COLLECTION_NAME",
    listRule: null,        // null = superuser only, "" = public, "@request.auth.id != ''" = any auth
    viewRule: null,
    createRule: null,
    updateRule: null,
    deleteRule: null,
    fields: [
      // new TextField({ name: "title", required: true, min: 1, max: 200 }),
      // new NumberField({ name: "count", required: false, min: 0, onlyInt: true }),
      // new BoolField({ name: "active" }),
      // new EmailField({ name: "contactEmail" }),
      // new URLField({ name: "website" }),
      // new EditorField({ name: "body", required: true }),
      // new DateField({ name: "publishedAt" }),
      // new AutodateField({ name: "created", onCreate: true, onUpdate: false }),
      // new AutodateField({ name: "updated", onCreate: true, onUpdate: true }),
      // new SelectField({ name: "status", values: ["draft", "published"], maxSelect: 1, required: true }),
      // new FileField({ name: "avatar", maxSelect: 1, maxSize: 5242880, mimeTypes: ["image/jpeg", "image/png"] }),
      // new JSONField({ name: "metadata" }),
      // new GeoPointField({ name: "location" }),

      // Relations — ALWAYS look up the target collection ID at runtime:
      // const targetCol = app.findCollectionByNameOrId("target_collection_name")
      // new RelationField({ name: "author", collectionId: targetCol.id, maxSelect: 1, cascadeDelete: false }),
    ],
    indexes: [
      // "CREATE INDEX idx_COLLECTION_NAME_field ON COLLECTION_NAME (field)",
      // "CREATE UNIQUE INDEX idx_COLLECTION_NAME_field ON COLLECTION_NAME (field)",
    ],
  })
  app.save(collection)
}, (app) => {
  const collection = app.findCollectionByNameOrId("COLLECTION_NAME")
  app.delete(collection)
})
MIGEOF
      ;;

    modify)
      cat > "$FILEPATH" << 'MIGEOF'
/// <reference path="../pb_data/types.d.ts" />

migrate((app) => {
  const collection = app.findCollectionByNameOrId("COLLECTION_NAME")

  // Add a field:
  // collection.fields.add(new TextField({ name: "subtitle", max: 200 }))

  // Remove a field:
  // collection.fields.removeByName("old_field")

  // Modify an existing field (returns a reference):
  // const titleField = collection.fields.getByName("title")
  // titleField.max = 500

  // Update API rules:
  // collection.listRule = "@request.auth.id != ''"

  // Add an index:
  // collection.addIndex("idx_name", false, "field_name", "")

  app.save(collection)
}, (app) => {
  const collection = app.findCollectionByNameOrId("COLLECTION_NAME")

  // Reverse changes here

  app.save(collection)
})
MIGEOF
      ;;

    seed)
      cat > "$FILEPATH" << 'MIGEOF'
/// <reference path="../pb_data/types.d.ts" />

migrate((app) => {
  const collection = app.findCollectionByNameOrId("COLLECTION_NAME")

  const records = [
    // { field1: "value1", field2: "value2" },
  ]

  for (const data of records) {
    const record = new Record(collection)
    for (const [key, value] of Object.entries(data)) {
      record.set(key, value)
    }
    app.save(record)
  }
}, (app) => {
  // Optional: delete seeded records
  // const collection = app.findCollectionByNameOrId("COLLECTION_NAME")
  // const records = app.findRecordsByFilter(collection, "field1 = 'value1'", "", 0, 0)
  // for (const record of records) {
  //   app.delete(record)
  // }
})
MIGEOF
      ;;

    *)
      echo "Error: unknown type '$TYPE'. Use: create, modify, or seed"
      exit 1
      ;;
  esac

  echo "Created: pb/pb_migrations/$FILENAME"
  echo "Next: edit the file to fill in your collection name and fields, then validate with:"
  echo "  pbcli.sh schema validate"
}

# Schema inspect command
cmd_schema_inspect() {
  COLLECTION_NAME="${1:-}"

  if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
  fi

  if [ -z "$PB_PORT" ]; then
    echo "Error: PB_PORT is not set. Create pb/.env with PB_PORT or export it."
    exit 1
  fi

  BASE_URL="http://127.0.0.1:$PB_PORT"

  # Check that the server is reachable
  if ! curl -s --max-time 3 "$BASE_URL/api/health" > /dev/null 2>&1; then
    echo "Error: PocketBase server is not reachable at $BASE_URL"
    echo "Start the server first:"
    echo "  pbcli.sh start"
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
}

# Schema validate command
cmd_schema_validate() {
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
  MIGRATION_COUNT=$(ls "$MIGRATIONS_DIR"/*.js 2>/dev/null | wc -l | tr -d ' ')
  echo "Found $MIGRATION_COUNT migration file(s)."
  echo ""

  if [ "$MIGRATION_COUNT" -eq 0 ]; then
    echo "No migrations to validate."
    exit 0
  fi

  # List migrations in order
  echo "Migrations (execution order):"
  ls -1 "$MIGRATIONS_DIR"/*.js 2>/dev/null | while read -r f; do
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
    echo "  pbcli.sh start --reset   # start server with fresh data"
    echo "  pbcli.sh start           # start server (keeps current data)"
  else
    EXIT_CODE=$?
    echo "---"
    echo ""
    echo "Migration FAILED. Fix the errors above and re-run validation."
    exit $EXIT_CODE
  fi
}

# Main command router
COMMAND="${1:-}"
SUBCOMMAND="${2:-}"

case "$COMMAND" in
  init)
    shift
    cmd_init "$@"
    ;;
  start)
    shift
    cmd_start "$@"
    ;;
  stop)
    cmd_stop
    ;;
  migration)
    case "$SUBCOMMAND" in
      create)
        shift 2
        cmd_migration_create "$@"
        ;;
      *)
        echo "Error: Unknown migration subcommand '$SUBCOMMAND'"
        echo "Available: migration create"
        echo "Run 'pbcli.sh help' for usage information."
        exit 1
        ;;
    esac
    ;;
  schema)
    case "$SUBCOMMAND" in
      inspect)
        shift 2
        cmd_schema_inspect "$@"
        ;;
      validate)
        shift 2
        cmd_schema_validate "$@"
        ;;
      *)
        echo "Error: Unknown schema subcommand '$SUBCOMMAND'"
        echo "Available: schema inspect, schema validate"
        echo "Run 'pbcli.sh help' for usage information."
        exit 1
        ;;
    esac
    ;;
  help|--help|-h)
    show_help
    ;;
  "")
    echo "Error: No command specified."
    echo "Run 'pbcli.sh help' for usage information."
    exit 1
    ;;
  *)
    echo "Error: Unknown command '$COMMAND'"
    echo "Run 'pbcli.sh help' for usage information."
    exit 1
    ;;
esac
