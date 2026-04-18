#!/usr/bin/env bash
set -e

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${1:-}" == "--agents" ]]; then
  cat <<'EOF'
COMMAND: init.sh
DESCRIPTION: Initializes a new PocketBase project in the current directory.

USAGE: bash <this-script> <module-name> <port> <admin-email> <admin-password>

ARGUMENTS:
  module-name      Go module name (e.g. github.com/yourorg/yourapp)
  port             PocketBase port (e.g. 8090)
  admin-email      Superuser email address
  admin-password   Superuser password

EXAMPLE:
  bash <skill-dir>/scripts/init.sh github.com/acme/myapp 8090 admin@acme.com s3cr3t

WHAT IT DOES:
  - Creates pb/, pb/pb_migrations/, pb/pb_hooks/, scripts/ directories
  - Copies template files (main.go, migrations, devpb, build.sh)
  - Writes .env.local with provided values
  - Appends PocketBase rules to .gitignore
  - Runs: go mod init, go get pocketbase@latest, go mod tidy
EOF
  exit 0
fi

usage() {
  echo "Usage: bash $0 <module-name> <port> <admin-email> <admin-password>" >&2
  echo "Run with --agents for structured usage information." >&2
  exit 1
}

[[ $# -lt 4 ]] && usage

MODULE_NAME="$1"
PB_PORT="$2"
PB_ADMIN_EMAIL="$3"
PB_ADMIN_PASSWORD="$4"

# Create directories
mkdir -p pb/pb_migrations pb/pb_hooks scripts

# Copy pb/ templates
cp -r "$SKILL_DIR/templates/pb/." pb/

# Copy root-level scripts
cp "$SKILL_DIR/templates/devpb" devpb
chmod +x devpb
cp "$SKILL_DIR/templates/scripts/build.sh" scripts/build.sh
chmod +x scripts/build.sh

# Write .env.local
cat > .env.local <<EOF
PB_PORT=$PB_PORT
PB_ADMIN_EMAIL=$PB_ADMIN_EMAIL
PB_ADMIN_PASSWORD=$PB_ADMIN_PASSWORD

# Optional: custom TLS certificate paths
# PB_TLS_CERT=
# PB_TLS_KEY=
EOF

# Append .gitignore rules (create if absent)
cat "$SKILL_DIR/templates/gitignore-append" >> .gitignore

# Initialize Go module
go -C pb mod init "$MODULE_NAME"
go -C pb get github.com/pocketbase/pocketbase@latest
go -C pb mod tidy

echo ""
echo "PocketBase project initialized."
echo "  Start dev server: ./devpb"
echo "  Build:            bash scripts/build.sh"
