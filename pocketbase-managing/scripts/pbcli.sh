#!/bin/bash
# pbdev.sh: Unified PocketBase CLI for project management
# Usage (from project root): bash <SKILL_PATH>/scripts/pbdev.sh <command> [options]

set -e

ROOT_DIR="$(pwd)"
PB_DIR="$ROOT_DIR/pb"
ENV_FILE="$PB_DIR/.env"
GITIGNORE="$ROOT_DIR/.gitignore"

# Help message
show_help() {
  cat << EOF
PocketBase CLI - Unified tool for PocketBase project management

USAGE:
  pbdev.sh <command> [options]

COMMANDS:
  init <module> <port> <email> <password>
      Initialize a new PocketBase project
      Creates pb/ directory, main.go, .env file, updates .gitignore,
      initializes Go module, and runs go mod tidy

  start [--reset]
      Start the PocketBase dev server
      Stops existing instance if running, then starts server
      --reset: Remove pb_data before starting (fresh database)

  stop
      Stop the running PocketBase server

  help
      Show this help message

EXAMPLES:
  # Initialize new project
  pbdev.sh init myapp/pb 8090 admin@example.com mypassword

  # Start server
  pbdev.sh start

  # Start with fresh database
  pbdev.sh start --reset

  # Stop server
  pbdev.sh stop

NOTES:
  - All commands must be run from the project root directory
  - Configuration is stored in pb/.env (PB_PORT, PB_ADMIN_EMAIL, PB_ADMIN_PASSWORD)
  - Script path: Use full absolute path (e.g., ~/.claude/skills/pocketbase-managing/scripts/pbdev.sh)
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

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case $1 in
      --reset)
        RESET_FLAG=true
        shift
        ;;
      *)
        echo "Error: Unknown option '$1'"
        echo "Usage: pbdev.sh start [--reset]"
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
  echo "Starting PocketBase on port $PORT..."
  cd "$PB_DIR"
  exec go run . serve --http="127.0.0.1:$PORT"
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
  PB_IGNORE_ENTRIES=("pb/pb_data/" "pb/pocketbase" "pb/.env")
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

# Main command router
COMMAND="${1:-}"

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
  help|--help|-h)
    show_help
    ;;
  "")
    echo "Error: No command specified."
    echo "Run 'pbdev.sh help' for usage information."
    exit 1
    ;;
  *)
    echo "Error: Unknown command '$COMMAND'"
    echo "Run 'pbdev.sh help' for usage information."
    exit 1
    ;;
esac
