---
name: task-tracking
description: Task management and tracking for agents. Use this skill whenever you need to create, update, claim, or retrieve tasks for agent workflows. This skill is triggered for any request involving task lists, task assignment, or status updates.
---

# Task Tracking Skill

This skill enables agents to manage tasks using the bundled bash script `task_tracking.sh`, located in the skill's `scripts` folder. Requires `jq` to be installed.

> **Note:** The script is bundled with the skill. All references in this documentation use the script name only; agents should resolve the path to the script within the skill's `scripts` directory as appropriate for their environment.

> **Discovery:** Agents should use `bash scripts/task_tracking.sh --help` to discover all available commands and options. Do not read the script source directly; rely on the CLI help output for authoritative usage and argument details.

## Quick Start

- **Create a task list:**
  ```bash
  bash scripts/task_tracking.sh create-list <list-name>
  ```
- **List available task lists:**
  ```bash
  bash scripts/task_tracking.sh list-lists
  ```
- **Add a task:**
  ```bash
  bash scripts/task_tracking.sh add-task <list-name> "<description>" [--file <path>]... [--doc <path>]... [--skill <name>]... [--ac "<criterion>"]... [--verify-command "<cmd>"] [--verify-instruction "<text>"] [--depends-on <task-id>]...
  ```
- **Claim or get next task:**
  ```bash
  bash scripts/task_tracking.sh next <list-name> [--skip-failed] [--claim <AGENT_ID>]
  ```
- **Update task status:**
  ```bash
  bash scripts/task_tracking.sh update-status <list-name> <task-id> <status> "<note>"
  ```
- **Update task metadata:**
  ```bash
  bash scripts/task_tracking.sh update-task <list-name> <task-id> [--description "<text>"] [--file <path>]... [--doc <path>]... [--skill <name>]... [--ac "<criterion>"]... [--verify-command "<cmd>"] [--verify-instruction "<text>"] [--depends-on <task-id>]...
  ```
- **Add a dependency:**
  ```bash
  bash scripts/task_tracking.sh add-dependency <list-name> <task-id> <depends-on-task-id>
  ```
- **Remove a dependency:**
  ```bash
  bash scripts/task_tracking.sh remove-dependency <list-name> <task-id> <depends-on-task-id>
  ```
- **List all tasks in a list:**
  ```bash
  bash scripts/task_tracking.sh list-tasks <list-name> [--format summary|full|json]
  ```
- **Query/filter tasks:**
  ```bash
  bash scripts/task_tracking.sh query <list-name> [--status <status>] [--search <term>] [--depends-on <task-id>] [--blocked] [--claimed-by <agent-id>] [--limit <n>]
  ```

## Script Reference

See `task_tracking.sh` for full CLI and API details. The script manages task lists and individual tasks in the `.tasks` directory of the current working directory. All operations are performed via the CLI interface.

- Task statuses: `todo`, `in_progress`, `completed`, `failed`, etc.
- **`update-status`** changes status and writes a log entry. Both `<status>` and `<note>` are positional and always required.
- **`update-task`** edits metadata only — description, context, acceptance criteria, verification, dependencies. It never changes status or writes a log entry. Use it to fix typos, add context, or clarify scope at any time.
- Each task has a `context` object with `files`, `docs`, and `skills` arrays (via repeatable `--file`, `--doc`, `--skill` flags). All are optional and default to empty arrays.
- Tasks may include `acceptance_criteria` (list of strings, via repeatable `--ac`) and a `verification` object (via `--verify-command` or `--verify-instruction`). All are optional.
- `--verify-command` stores `{"type":"command","value":"..."}` — a shell command the agent can execute.
- `--verify-instruction` stores `{"type":"instruction","value":"..."}` — a free-text instruction for manual verification.
- Only one of `--verify-command` or `--verify-instruction` may be specified per task.
- Metadata arrays (`--file`, `--doc`, `--skill`, `--ac`) are **replaced**, not appended, when passed to `update-task`.

### Listing and Querying Tasks

- **`list-tasks <list> [--format summary|full|json]`** — Lists all tasks in a list.
  - `summary` (default): returns `[{id, description, status}]` from the index — fast, no file reads
  - `full`: returns full task objects in order, reading each per-task file
  - `json`: returns the raw `_task-list.json` index

- **`query <list> [options]`** — Filters tasks matching ALL provided criteria. Returns `[{id, description, status, claimed_by, depends_on}]`.
  - `--status <status>` — match exact status (`todo`, `in_progress`, `completed`, `failed`)
  - `--search <term>` — case-insensitive substring match in description, acceptance criteria, or notes
  - `--depends-on <task-id>` — tasks that list the given ID in their `depends_on`
  - `--blocked` — non-completed tasks with at least one non-completed dependency
  - `--claimed-by <agent-id>` — tasks claimed by the specified agent
  - `--limit <n>` — cap results at N (default: 0 = unlimited)

  Examples:
  ```bash
  # All todo tasks
  bash scripts/task_tracking.sh query my-list --status todo

  # Search for auth-related tasks
  bash scripts/task_tracking.sh query my-list --search "auth"

  # Tasks blocked by task-01 being incomplete
  bash scripts/task_tracking.sh query my-list --depends-on task-01

  # All blocked tasks
  bash scripts/task_tracking.sh query my-list --blocked

  # Tasks claimed by a specific agent
  bash scripts/task_tracking.sh query my-list --claimed-by agent-123

  # Combine filters: in-progress tasks claimed by agent-123
  bash scripts/task_tracking.sh query my-list --status in_progress --claimed-by agent-123
  ```

## Dependency Tracking

Tasks can declare dependencies on other tasks via `depends_on` (a list of task IDs).

- **`next --claim`** rejects a task if any of its `depends_on` tasks are not `completed`. Complete blocking tasks first.
- **`update-status ... completed`** prints a warning listing any pending tasks that depend on the one being completed, so you know what is now unblocked.
- Use `--depends-on <task-id>` (repeatable) with `add-task` or `update-task` to set/replace the full dependency list.
- Use `add-dependency` / `remove-dependency` for surgical edits to an existing task's dependencies.
- Circular dependencies are not auto-detected; avoid them when designing task lists.

## Error Handling

**CRITICAL:** If the task tracking script returns an error or fails to execute:
1. **IMMEDIATELY notify the user** about the error and include the full error message
2. **DO NOT attempt to modify task files manually** (e.g., editing `.tasks/` directory JSON files directly)
3. **DO NOT work around the script** by using jq, cat, or other tools to manipulate task data
4. **WAIT for explicit user instruction** before taking any alternative action

The task tracking system is designed to maintain data integrity through the script interface only. Manual modifications can corrupt the task list, status logs, or task metadata.

## Best Practices

- Always provide meaningful context for each task.
- Use agent IDs to claim tasks for specific agents.
- Log progress and errors using the `update-task` command with notes.
- If the script fails, stop and notify the user - do not attempt manual workarounds.

## Writing Self-Sufficient Tasks

When creating a task, populate enough context for a zero-context agent to succeed without follow-up questions:

**Description**: State the current state and desired outcome, not just the task name.
- Poor: `"Fix free book button"`
- Good: `"Free products show 'Add to Cart' — change button label to 'Get Free' for products with price = 0"`

**Before running `add-task`**, search the codebase to identify relevant files, then include them via `--file`.

**Acceptance criteria** (`--ac`) should describe observable outcomes, not restate the description.

**Verification**: Use `--verify-command` for automated checks, `--verify-instruction` when human judgment is needed.
