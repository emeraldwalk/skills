---
name: pocketbase-managing
description: Sets up and manages PocketBase projects, including project initialization and dev server lifecycle. Use when bootstrapping a new PocketBase project, starting or stopping the dev server, or resetting the database.
---

# PocketBase

Covers initial project setup, dev server operations, schema iteration workflow, and JS migration API.

## Prerequisites

- Go 1.23+ installed and on PATH

## Important: Script Execution Context

**Working Directory**: The CLI script MUST be executed from the **user's project root directory** (where the `pb/` directory will be or is located), NOT from the skill directory. The script uses `$(pwd)` to determine the project root.

**Script Path**: The CLI is located at `<SKILL_PATH>/scripts/pbdev.sh`. When invoking it, use the full absolute path to the skill (e.g., `bash ~/.claude/skills/pocketbase-managing/scripts/pbdev.sh`).

**Example invocation pattern**:

```bash
# From the user's project directory:
cd /path/to/user/project
bash ~/.claude/skills/pocketbase-managing/scripts/pbdev.sh <command> [options]
```

**Go commands**: Always use `go -C pb` from workspace root. Never `cd` into `pb/` directly.

## Setup Steps

Follow these steps in order when setting up a new PocketBase project.

### Step 1: Prompt for Configuration

Ask the user for the following values:

| Variable            | Description                | Default            |
| ------------------- | -------------------------- | ------------------ |
| `PB_PORT`           | Port for PocketBase server | `8090`             |
| `PB_ADMIN_EMAIL`    | Superuser email            | _(required)_       |
| `PB_ADMIN_PASSWORD` | Superuser password         | _(required)_       |
| `PB_MODULE_NAME`    | Go module name             | Infer from project |

### Step 2: Initialize Project

Run `pbdev.sh init` with all four configuration values. This creates the `pb/` directory structure, writes `pb/main.go`, creates `pb/.env`, adds PocketBase entries to `.gitignore`, initializes the Go module, and installs dependencies.

### Step 3: Verify Setup

Run `pbdev.sh start --reset` to confirm everything works.

Expected outcome:

- PocketBase compiles and starts
- Superuser is created
- Server is accessible at `http://127.0.0.1:<PB_PORT>`
- Admin dashboard at `http://127.0.0.1:<PB_PORT>/_/`

## CLI Commands

All commands source `pb/.env` for `PB_PORT`, `PB_ADMIN_EMAIL`, and `PB_ADMIN_PASSWORD`.

**Note**: `<SKILL_PATH>` below represents the full path to this skill directory. All commands must be invoked from the project root directory.

**Usage**: `bash <SKILL_PATH>/scripts/pbdev.sh <command> [options]`

| Command                               | Description                                                                                   |
| ------------------------------------- | --------------------------------------------------------------------------------------------- |
| `init <MODULE> <PORT> <EMAIL> <PASS>` | Full project setup: directories, `main.go`, `pb/.env`, `.gitignore`, Go module, `go mod tidy` |
| `start`                               | Stop existing instance (if running), then start the dev server                                |
| `start --reset`                       | Stop instance, wipe data, create superuser, start fresh                                       |
| `stop`                                | Kill existing PocketBase instance on the configured port                                      |
| `help`                                | Show help message with all commands and usage examples                                        |

## Iteration Workflow

| Action                       | Procedure                                                  |
| ---------------------------- | ---------------------------------------------------------- |
| Initialize or update Go deps | Run `pbdev.sh init` (pass module name on first run)        |
| Start server                 | Run `pbdev.sh start`                                       |
| Wipe DB and restart          | Run `pbdev.sh start --reset`                               |
| Stop server                  | Run `pbdev.sh stop` (or `Ctrl+C` if running in foreground) |

### Schema Change Loop

The recommended workflow for iterating on schema:

1. **Write or edit migration files** in `pb/pb_migrations/`
2. **Run `pbdev.sh start --reset`** — wipes DB, re-runs all migrations from scratch, creates superuser
3. **Verify** — check the admin dashboard at `/_/` or hit the API

Migrations run automatically on server start. The `--reset` flag gives a clean slate every time, so you can freely edit migration files and re-test.

### Automigrate (Dashboard Mode)

When running via `go run` (which `pbdev.sh start` uses), `Automigrate` is enabled. Changes made in the admin dashboard (`/_/`) automatically generate JS migration files in `pb_migrations/`. Commit these files to version control.

### Hooks

Add JS hooks in `pb/pb_hooks/` using the `*.pb.js` naming pattern. They hot-reload automatically during development.

## JS Migration Reference

For the full JS migration API — collection creation, auth collections, modification, relations, seeding, raw SQL, field types, and API rules — see [references/migrations.md](references/migrations.md).
