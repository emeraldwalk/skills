---
name: plan-orchestrating
description: Orchestrates implementation of "Ready to Implement" plans from .plans/PLAN.md. For a single plan, implements it directly without delegation. For multiple plans, delegates each to a foreground subagent in sequence with commit-on-success and stop-on-failure behavior. Use when a user asks to "run plans", "implement plans", "execute pending plans", or "orchestrate plan execution".
---

Read .plans/PLAN.md to understand available plans. The user's prompt will specify which plans to orchestrate.

Send notifications via ntfy.sh (topic: `emerald42create_`) when starting and completing each plan. Keep messages terse.

## Per-Plan Instructions

For each plan:

1. Implement the plan following its checklist and validation steps
2. If successful, commit the implementation to the repository
3. Report whether the implementation succeeded, and if not, what the error was

## Single Plan vs. Multiple Plans

**Single plan** — implement it directly yourself. Do not delegate to a subagent.

**Multiple plans** — delegate each plan to a new foreground subagent in sequence. Instruct each subagent to follow the Per-Plan Instructions above. Wait for each subagent to complete before starting the next. If any subagent fails, stop immediately and report the failure.
