#!/usr/bin/env bash
# run_task_loop.sh — Orchestrate sequential task execution from a task list.
#
# Usage:
#   run_task_loop.sh <list-id> <max-tasks> <cli>
#
# Arguments:
#   list-id    Task list name (e.g. "my-sprint")
#   max-tasks  Maximum number of tasks to execute (integer), or "all" to run until no tasks remain
#   cli        Agent CLI to use: "claude", "copilot", or "mock" (for testing)
#
# Environment:
#   TASKS_DIR  Override the .tasks directory location (optional)
#
# The agent CLI is responsible for calling task_tracking.sh update-status
# to mark tasks as "completed" or "failed". This script checks status after
# each agent run and stops if the task was not completed.
#
# Logs for each task agent run are written to:
#   <project-root>/.tasks/logs/<list-id>/<task-id>_agent.log
#
# On success, changed files are committed with a message derived from the task.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_TRACKING="${SCRIPT_DIR}/task_tracking.sh"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
  cat <<'USAGE'
Usage: run_task_loop.sh <list-id> <max-tasks> <cli>

Arguments:
  list-id    Task list name
  max-tasks  Max number of tasks to execute (integer >= 1), or "all" to run until no tasks remain
  cli        Agent CLI: "claude", "copilot", or "mock"

Environment:
  TASKS_DIR  Override the .tasks directory location (optional)
USAGE
}

if [[ $# -ne 3 ]]; then
  echo "Error: Expected 3 arguments, got $#."
  usage
  exit 1
fi

LIST_ID="$1"
MAX_TASKS="$2"
CLI="$3"

if [[ "$MAX_TASKS" == "all" ]]; then
  RUN_ALL=1
elif [[ "$MAX_TASKS" =~ ^[1-9][0-9]*$ ]]; then
  RUN_ALL=0
else
  echo "Error: max-tasks must be a positive integer or 'all', got: ${MAX_TASKS}"
  exit 1
fi

case "$CLI" in
  claude|copilot|mock) ;;
  *)
    echo "Error: cli must be 'claude' or 'copilot', got: ${CLI}"
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Resolve project root and paths
# ---------------------------------------------------------------------------
find_tasks_dir() {
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    if [[ -d "$dir/.tasks" ]]; then
      echo "$dir/.tasks"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  echo "${PWD}/.tasks"
}

TASKS_DIR="${TASKS_DIR:-$(find_tasks_dir)}"
PROJECT_ROOT="$(dirname "$TASKS_DIR")"
LOG_BASE="${TASKS_DIR}/logs/${LIST_ID}"
LOOP_LOG="${LOG_BASE}/loop.log"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[run_task_loop] $*"; }

claim_id="run_task_loop_$$"

get_task_status() {
  local task_file="${TASKS_DIR}/${LIST_ID}/$1.json"
  if [[ ! -f "$task_file" ]]; then
    echo "unknown"
    return
  fi
  jq -r '.status' "$task_file"
}

# Build a compact, human-readable prompt from task JSON.
# The agent receives this as stdin so it has all context without any
# pre-processing required.
build_prompt() {
  local task_json="$1"

  # Extract fields
  local task_id description status ac_list files docs skills verify_type verify_val note
  task_id=$(echo "$task_json" | jq -r '.id')
  description=$(echo "$task_json" | jq -r '.description')
  status=$(echo "$task_json" | jq -r '.status')
  note=$(echo "$task_json" | jq -r '.note // ""')

  # Build prompt text
  cat <<PROMPT
You are a coding agent executing a task from a task list. Complete the task described below, then mark it as completed (or failed) using the task tracking script.

## Task
- List: ${LIST_ID}
- Task ID: ${task_id}
- Status: ${status}
- Description: ${description}
PROMPT

  # Acceptance criteria
  local ac_count
  ac_count=$(echo "$task_json" | jq '.acceptance_criteria | length')
  if [[ "$ac_count" -gt 0 ]]; then
    echo ""
    echo "## Acceptance Criteria"
    echo "$task_json" | jq -r '.acceptance_criteria[]' | while IFS= read -r item; do
      echo "- ${item}"
    done
  fi

  # Context: files
  local file_count
  file_count=$(echo "$task_json" | jq '.context.files | length')
  if [[ "$file_count" -gt 0 ]]; then
    echo ""
    echo "## Relevant Files"
    echo "$task_json" | jq -r '.context.files[]' | while IFS= read -r f; do
      echo "- ${f}"
    done
  fi

  # Context: docs
  local doc_count
  doc_count=$(echo "$task_json" | jq '.context.docs | length')
  if [[ "$doc_count" -gt 0 ]]; then
    echo ""
    echo "## Reference Docs"
    echo "$task_json" | jq -r '.context.docs[]' | while IFS= read -r d; do
      echo "- ${d}"
    done
  fi

  # Context: skills
  local skill_count
  skill_count=$(echo "$task_json" | jq '.context.skills | length')
  if [[ "$skill_count" -gt 0 ]]; then
    echo ""
    echo "## Skills to Load"
    echo "$task_json" | jq -r '.context.skills[]' | while IFS= read -r s; do
      echo "- ${s}"
    done
  fi

  # Verification
  local verify_type verify_val
  verify_type=$(echo "$task_json" | jq -r '.verification.type // ""')
  verify_val=$(echo "$task_json" | jq -r '.verification.value // ""')
  if [[ -n "$verify_type" ]]; then
    echo ""
    echo "## Verification"
    if [[ "$verify_type" == "command" ]]; then
      echo "Run this command to verify your work:"
      echo '```'
      echo "$verify_val"
      echo '```'
    else
      echo "$verify_val"
    fi
  fi

  # Note from previous attempt
  if [[ -n "$note" ]]; then
    echo ""
    echo "## Previous Note"
    echo "$note"
  fi

  # Instructions for agent
  cat <<INSTRUCTIONS

## Your Responsibilities
1. Complete the task described above.
2. When done, update the task status using the task tracking script:

   **On success:**
   \`\`\`bash
   bash "${TASK_TRACKING}" update-status "${LIST_ID}" "${task_id}" completed "<brief summary of what you did>"
   \`\`\`

   **On failure:**
   \`\`\`bash
   bash "${TASK_TRACKING}" update-status "${LIST_ID}" "${task_id}" failed "<reason for failure>"
   \`\`\`

3. Do NOT commit your changes — the orchestrator will commit them for you after confirming success.
INSTRUCTIONS
}

# ---------------------------------------------------------------------------
# Run agent CLI
# ---------------------------------------------------------------------------
run_agent() {
  local prompt="$1" log_file="$2"

  case "$CLI" in
    claude)
      # Use --verbose with stream-json for detailed real-time output
      echo "$prompt" | claude --print --verbose --output-format=stream-json --dangerously-skip-permissions \
        > "$log_file" 2>&1
      ;;
    copilot)
      echo "$prompt" | gh copilot suggest -t shell \
        > "$log_file" 2>&1
      ;;
    mock)
      echo "$prompt" | bash "${SCRIPT_DIR}/mock_agent.sh" \
        > "$log_file" 2>&1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
mkdir -p "$LOG_BASE"
# Tee stdout and stderr independently to loop.log so both streams are captured
# without merging them — callers (including agents) can still distinguish the two.
# The _LOGGING sentinel prevents infinite re-exec.
if [[ -z "${_LOGGING:-}" ]]; then
  export _LOGGING=1
  exec > >(tee -a "$LOOP_LOG") 2> >(tee -a "$LOOP_LOG" >&2)
fi
if [[ "$RUN_ALL" -eq 1 ]]; then
  pending_count=$(bash "$TASK_TRACKING" count "$LIST_ID" --exclude-status completed --exclude-status skipped 2>/dev/null || echo "?")
  TOTAL_TASKS="$pending_count"
else
  TOTAL_TASKS="$MAX_TASKS"
fi
log "Starting task run: list=${LIST_ID}, max=${TOTAL_TASKS}, cli=${CLI}"
log "Project root: ${PROJECT_ROOT}"
log "Tasks dir: ${TASKS_DIR}"

completed_count=0

while [[ "$RUN_ALL" -eq 1 || "$completed_count" -lt "$MAX_TASKS" ]]; do
  log "---"
  log "Iteration $((completed_count + 1)) of ${TOTAL_TASKS}"

  # Claim next available task
  task_json=$(bash "$TASK_TRACKING" next "$LIST_ID" --claim "$claim_id" 2>&1) || {
    log "Error claiming next task: ${task_json}"
    exit 1
  }

  # Check if no tasks available
  if echo "$task_json" | grep -q "^No pending tasks found"; then
    log "No more pending tasks available. Stopping."
    exit 0
  fi

  task_id=$(echo "$task_json" | jq -r '.id')
  task_desc=$(echo "$task_json" | jq -r '.description')
  log "Claimed task: ${task_id} — ${task_desc}"

  # Set up log file: .tasks/logs/<list-id>/<task-id>_agent.log
  mkdir -p "$LOG_BASE"
  log_file="${LOG_BASE}/${task_id}_agent.log"
  log "Agent log: ${log_file}"

  # Build prompt and run agent
  prompt=$(build_prompt "$task_json")
  log "Running ${CLI} agent..."

  run_agent "$prompt" "$log_file" || agent_exit=$?
  agent_exit="${agent_exit:-0}"

  if [[ "$agent_exit" -ne 0 ]]; then
    log "Agent process exited with code ${agent_exit}. See ${log_file}"
    log "Stopping."
    exit 1
  fi

  # Check task status after agent run
  task_status=$(get_task_status "$task_id")
  log "Task ${task_id} status after agent: ${task_status}"

  if [[ "$task_status" != "completed" ]]; then
    log "Task ${task_id} is '${task_status}' (not completed). Stopping."
    exit 1
  fi

  # Generate commit message and commit
  commit_msg=$(bash "$TASK_TRACKING" commit-message "$LIST_ID" "$task_id")

  if [[ "$CLI" == "mock" ]]; then
    log "[dry-run] cd \"${PROJECT_ROOT}\""
    log "[dry-run] git add -A"
    log "[dry-run] git commit -m \"${commit_msg}\""
  else
    log "Committing changes for ${task_id}..."
    (
      cd "$PROJECT_ROOT"
      git add -A
      if git diff --cached --quiet; then
        log "No changes to commit for ${task_id}."
      else
        git commit -m "$commit_msg"
        log "Committed: ${commit_msg%%$'\n'*}"
      fi
    )
  fi

  completed_count=$((completed_count + 1))
  log "Task ${task_id} complete. (${completed_count}/${TOTAL_TASKS})"
done

log "Reached max task limit (${TOTAL_TASKS}). Done. (${completed_count} tasks completed)"
