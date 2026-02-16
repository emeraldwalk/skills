---
name: pocketbase-developing
description: Complete PocketBase development toolkit for project initialization, dev server management, migration generation, schema inspection, and migration validation. Use when: (1) bootstrapping a new PocketBase project, (2) starting or stopping the dev server, (3) resetting the database, (4) creating migration files, (5) inspecting current schema, or (6) validating migrations.
---

# PocketBase

Covers project setup, dev server operations, migration creation, schema inspection, migration validation, and JS migration API.

## Prerequisites

- Go 1.23+ installed and on PATH

## Important: Script Execution Context

**Working Directory**: Execute all commands from the user's project root (where `pb/` is or will be located). The CLI uses `$(pwd)` to locate the project.

**Script Location**: This skill bundles `scripts/pbcli.sh`. Use the absolute path to the skill directory when invoking it.

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

Run `pbcli.sh init` with all four configuration values. This creates the `pb/` directory structure, writes `pb/main.go`, creates `pb/.env`, adds PocketBase entries to `.gitignore`, initializes the Go module, and installs dependencies.

### Step 3: Verify Setup

Run `pbcli.sh start --reset` to confirm everything works.

Expected outcome:

- PocketBase compiles and starts
- Superuser is created
- Server is accessible at `http://127.0.0.1:<PB_PORT>`
- Admin dashboard at `http://127.0.0.1:<PB_PORT>/_/`

## CLI Commands

All commands source `pb/.env` for `PB_PORT`, `PB_ADMIN_EMAIL`, and `PB_ADMIN_PASSWORD`.

**Note**: `<SKILL_PATH>` below represents the full path to this skill directory. All commands must be invoked from the project root directory.

**Usage**: `bash scripts/pbcli.sh <command> [subcommand] [options]`

> Note: `scripts/` refers to this skill's scripts directory. Use the absolute path to the skill when invoking.

### Project Management

| Command                               | Description                                                                                   |
| ------------------------------------- | --------------------------------------------------------------------------------------------- |
| `init <MODULE> <PORT> <EMAIL> <PASS>` | Full project setup: directories, `main.go`, `pb/.env`, `.gitignore`, Go module, `go mod tidy` |
| `start`                               | Stop existing instance (if running), then start the dev server in foreground                  |
| `start --reset`                       | Stop instance, wipe data, create superuser, start fresh                                       |
| `start --background`                  | Start server in background, log to `pb/server.log`, save PID to `pb/.pid`                     |
| `start --reset --background`          | Combine reset and background modes                                                            |
| `stop`                                | Kill existing PocketBase instance (checks PID file and port)                                  |

### Migration Management

| Command                                    | Description                                                             |
| ------------------------------------------ | ----------------------------------------------------------------------- |
| `migration create <description> [type]`    | Generate timestamped migration boilerplate (type: create/modify/seed)  |

### Schema Operations

| Command                          | Description                                                                      |
| -------------------------------- | -------------------------------------------------------------------------------- |
| `schema inspect [collection]`    | Dump current schema as JSON (requires running server, optional collection name) |
| `schema validate`                | Dry-run all migrations in clean environment to check for errors                 |

### Help

| Command | Description                                        |
| ------- | -------------------------------------------------- |
| `help`  | Show help message with all commands and examples   |

## Iteration Workflow

| Action                       | Procedure                                                         |
| ---------------------------- | ----------------------------------------------------------------- |
| Initialize or update Go deps | Run `pbcli.sh init` (pass module name on first run)               |
| Start server (foreground)    | Run `pbcli.sh start`                                              |
| Start server (background)    | Run `pbcli.sh start --background`                                 |
| Wipe DB and restart          | Run `pbcli.sh start --reset` (add `--background` if needed)       |
| Stop server                  | Run `pbcli.sh stop` (or `Ctrl+C` if running in foreground)        |
| View background server logs  | `tail -f pb/server.log` or `cat pb/server.log`                    |

### Schema Change Loop

The recommended workflow for iterating on schema:

1. **Create migration file** — Run `pbcli.sh migration create <description> [type]`
2. **Edit migration file** in `pb/pb_migrations/` with collection definitions
3. **Validate migrations** — Run `pbcli.sh schema validate` to test migrations in clean environment
4. **Start server** — Run `pbcli.sh start --reset` to wipe DB and apply all migrations
5. **Verify** — Check admin dashboard at `/_/` or inspect schema with `pbcli.sh schema inspect`

Migrations run automatically on server start. The `--reset` flag gives a clean slate every time, so you can freely edit migration files and re-test.

**Alternative: Quick validation** — Use `pbcli.sh schema validate` to test migrations without starting the server. This is faster for catching syntax errors and migration issues.

### Automigrate (Dashboard Mode)

When running via `go run` (which `pbdev.sh start` uses), `Automigrate` is enabled. Changes made in the admin dashboard (`/_/`) automatically generate JS migration files in `pb_migrations/`. Commit these files to version control.

### Hooks

Add JS hooks in `pb/pb_hooks/` using the `*.pb.js` naming pattern. They hot-reload automatically during development.

## JS Migration Reference

For the full JS migration API — collection creation, auth collections, modification, relations, seeding, raw SQL, field types, and API rules — see [references/migrations.md](references/migrations.md).
