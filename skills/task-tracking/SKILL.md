---
name: task-tracking
description: Task management and tracking for agents. Use this skill whenever you need to create, update, claim, or retrieve tasks for agent workflows. This skill is triggered for any request involving task lists, task assignment, or status updates.
---

# Task Tracking Skill

This skill enables agents to manage tasks using the bundled Python script `scripts/task_tracking.py`.

> **Discovery:** Agents should use `python scripts/task_tracking.py --help` to discover all available commands and options. Do not read the script source directly; rely on the CLI help output for authoritative usage and argument details.

## Quick Start

- **Create a task list:**
  ```bash
  python scripts/task_tracking.py create-list <list-name>
  ```
- **Add a task:**
  ```bash
  python scripts/task_tracking.py add-task <list-name> "<description>" --context "<context>"
  ```
- **Claim or get next task:**
  ```bash
  python scripts/task_tracking.py next <list-name> [--skip-failed] [--claim <AGENT_ID>]
  ```
- **Update task status:**
  ```bash
  python scripts/task_tracking.py update-task <list-name> <task-id> <status> --note "<note>"
  ```

## Script Reference

See `scripts/task_tracking.py` for full CLI and API details. The script manages task lists and individual tasks in the `.tasks` directory of the current working directory. All operations are performed via the CLI interface.

- Task statuses: `todo`, `completed`, `failed`, etc.
- Each task requires a `context` string for creation.
- Status updates (except `completed`) require a note.

## Best Practices

- Always provide meaningful context for each task.
- Use agent IDs to claim tasks for specific agents.
- Log progress and errors using the `update-task` command with notes.

## Advanced Usage

For advanced workflows, refer to the script source or extend the script as needed. If you need to patch or debug, read `scripts/task_tracking.py` directly.
