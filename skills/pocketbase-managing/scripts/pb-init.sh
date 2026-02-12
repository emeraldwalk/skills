#!/bin/bash
# pb-init.sh: Full PocketBase project initialization
# Usage: bash .github/skills/pocketbase-managing/scripts/pb-init.sh <module-name> <port> <admin-email> <admin-password>
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/../../../.."
PB_DIR="$ROOT_DIR/pb"
GITIGNORE="$ROOT_DIR/.gitignore"
ENV_FILE="$PB_DIR/.env"

MODULE_NAME="${1:-}"
PB_PORT="${2:-}"
PB_ADMIN_EMAIL="${3:-}"
PB_ADMIN_PASSWORD="${4:-}"

# Create directory structure
mkdir -p "$PB_DIR/pb_hooks"
[ -f "$PB_DIR/pb_hooks/.gitkeep" ] || touch "$PB_DIR/pb_hooks/.gitkeep"
echo "Directory structure ready."

# Create main.go if it doesn't exist
if [ ! -f "$PB_DIR/main.go" ]; then
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
    echo "Usage: bash .github/skills/pocketbase-managing/scripts/pb-init.sh <module-name> <port> <admin-email> <admin-password>"
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
    echo "Usage: bash .github/skills/pocketbase-managing/scripts/pb-init.sh <module-name> <port> <admin-email> <admin-password>"
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
