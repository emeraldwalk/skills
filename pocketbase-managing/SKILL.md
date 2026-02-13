---
name: pocketbase-managing
description: Sets up and manages PocketBase projects, including project initialization and dev server lifecycle. Use when bootstrapping a new PocketBase project, starting or stopping the dev server, or resetting the database.
---

# PocketBase

Covers initial project setup, dev server operations, schema iteration workflow, and JS migration API.

## Prerequisites

- Go 1.23+ installed and on PATH
- **Working directory**: Always run go commands from the workspace root using `go -C pb`. Never `cd` into `pb/` directly.

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

Run **PB Init** (see Operations below) with all four configuration values. This creates the `pb/` directory structure, writes `pb/main.go`, creates `pb/.env`, adds PocketBase entries to `.gitignore`, initializes the Go module, and installs dependencies:

```bash
bash .github/skills/pocketbase-managing/scripts/pb-init.sh <PB_MODULE_NAME> <PB_PORT> <PB_ADMIN_EMAIL> <PB_ADMIN_PASSWORD>
```

### Step 3: Verify Setup

Run a **PB Reset** (see Operations below) to confirm everything works.

Expected outcome:

- PocketBase compiles and starts
- Superuser is created
- Server is accessible at `http://127.0.0.1:<PB_PORT>`
- Admin dashboard at `http://127.0.0.1:<PB_PORT>/_/`

## Operations

All operations source `pb/.env` for `PB_PORT`, `PB_ADMIN_EMAIL`, and `PB_ADMIN_PASSWORD`.

| Operation    | Script                                                                                      | Description                                                                                   |
| ------------ | ------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| **PB Init**  | `bash .github/skills/pocketbase-managing/scripts/pb-init.sh <MODULE> <PORT> <EMAIL> <PASS>` | Full project setup: directories, `main.go`, `pb/.env`, `.gitignore`, Go module, `go mod tidy` |
| **PB Stop**  | `bash .github/skills/pocketbase-managing/scripts/pb-stop.sh`                                | Kill existing PocketBase instance on the configured port                                      |
| **PB Dev**   | `bash .github/skills/pocketbase-managing/scripts/pb-dev.sh`                                 | Stop existing instance, then start the dev server                                             |
| **PB Reset** | `bash .github/skills/pocketbase-managing/scripts/pb-reset.sh`                               | Stop instance, wipe data, create superuser, start fresh                                       |

## Iteration Workflow

| Action                       | Procedure                                              |
| ---------------------------- | ------------------------------------------------------ |
| Initialize or update Go deps | Run **PB Init** (pass module name on first run)        |
| Start server                 | Run **PB Dev**                                         |
| Wipe DB and restart          | Run **PB Reset**                                       |
| Stop server                  | Run **PB Stop** (or `Ctrl+C` if running in foreground) |

### Schema Change Loop

The recommended workflow for iterating on schema:

1. **Write or edit migration files** in `pb/pb_migrations/`
2. **Run PB Reset** — wipes DB, re-runs all migrations from scratch, creates superuser
3. **Verify** — check the admin dashboard at `/_/` or hit the API

Migrations run automatically on server start. PB Reset gives a clean slate every time, so you can freely edit migration files and re-test.

### Automigrate (Dashboard Mode)

When running via `go run` (which **PB Dev** uses), `Automigrate` is enabled. Changes made in the admin dashboard (`/_/`) automatically generate JS migration files in `pb_migrations/`. Commit these files to version control.

### Hooks

Add JS hooks in `pb/pb_hooks/` using the `*.pb.js` naming pattern. They hot-reload automatically during development.

## JS Migration Reference

For the full JS migration API — collection creation, auth collections, modification, relations, seeding, raw SQL, field types, and API rules — see [references/migrations.md](references/migrations.md).
