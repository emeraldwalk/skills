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
- **Add a task:**
  ```bash
  bash scripts/task_tracking.sh add-task <list-name> "<description>" [--file <path>]... [--doc <path>]... [--skill <name>]... [--ac "<criterion>"]... [--verify-command "<cmd>"] [--verify-instruction "<text>"]
  ```
- **Claim or get next task:**
  ```bash
  bash scripts/task_tracking.sh next <list-name> [--skip-failed] [--claim <AGENT_ID>]
  ```
- **Update task status:**
  ```bash
  bash scripts/task_tracking.sh update-task <list-name> <task-id> <status> [--note "<note>"] [--file <path>]... [--doc <path>]... [--skill <name>]... [--ac "<criterion>"]... [--verify-command "<cmd>"] [--verify-instruction "<text>"]
  ```

## Script Reference

See `task_tracking.sh` for full CLI and API details. The script manages task lists and individual tasks in the `.tasks` directory of the current working directory. All operations are performed via the CLI interface.

- Task statuses: `todo`, `completed`, `failed`, etc.
- Each task has a `context` object with `files`, `docs`, and `skills` arrays (via repeatable `--file`, `--doc`, `--skill` flags). All are optional and default to empty arrays.
- Tasks may include `acceptance_criteria` (list of strings, via repeatable `--ac`) and a `verification` object (via `--verify-command` or `--verify-instruction`). All are optional.
- `--verify-command` stores `{"type":"command","value":"..."}` — a shell command the agent can execute.
- `--verify-instruction` stores `{"type":"instruction","value":"..."}` — a free-text instruction for manual verification.
- Only one of `--verify-command` or `--verify-instruction` may be specified per task.
- Status updates (except `completed`) require a `--note`.
- The `update-task` command supports all the same metadata flags as `add-task` (`--file`, `--doc`, `--skill`, `--ac`, `--verify-command`, `--verify-instruction`), allowing you to modify task metadata when updating status.

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
