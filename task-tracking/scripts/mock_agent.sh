#!/usr/bin/env bash
# mock_agent.sh — Simulates a task agent for testing run_task_loop.sh.
#
# Reads the task prompt from stdin, extracts the list ID, task ID, and
# task_tracking.sh path from the embedded instructions, then marks the
# task as completed. Optionally simulates failure via MOCK_AGENT_FAIL.
#
# Environment:
#   MOCK_AGENT_FAIL   Set to "1" to mark the task as failed instead of completed
#   MOCK_AGENT_DELAY  Seconds to sleep before completing (default: 0)

set -euo pipefail

delay="${MOCK_AGENT_DELAY:-0}"
should_fail="${MOCK_AGENT_FAIL:-0}"

# Read full prompt from stdin
prompt="$(cat)"

echo "[mock_agent] Received prompt (${#prompt} chars)"

# Extract the task_tracking.sh path, list ID, and task ID from the
# update-status command embedded in the prompt by build_prompt().
# Expected line format:
#   bash "/path/to/task_tracking.sh" update-status "LIST_ID" "TASK_ID" completed "..."
update_line=$(echo "$prompt" | grep 'bash ".*task_tracking\.sh" update-status.*completed' | head -1)
tracking_script=$(echo "$update_line" | sed 's/.*bash "\([^"]*\)".*/\1/')
list_id=$(echo "$update_line" | sed 's/.*update-status "\([^"]*\)".*/\1/')
task_id=$(echo "$update_line" | sed 's/.*update-status "[^"]*" "\([^"]*\)".*/\1/')

if [[ -z "$tracking_script" || -z "$list_id" || -z "$task_id" ]]; then
  echo "[mock_agent] ERROR: Could not parse task_tracking path, list ID, or task ID from prompt."
  echo "[mock_agent] Prompt excerpt:"
  echo "$prompt" | grep -A2 'update-status' | head -10
  exit 1
fi

echo "[mock_agent] list=${list_id} task=${task_id}"
echo "[mock_agent] tracking script: ${tracking_script}"

if [[ "$delay" -gt 0 ]]; then
  echo "[mock_agent] Simulating work for ${delay}s..."
  sleep "$delay"
fi

if [[ "$should_fail" == "1" ]]; then
  echo "[mock_agent] Simulating failure."
  bash "$tracking_script" update-status "$list_id" "$task_id" failed "Mock agent simulated failure"
  echo "[mock_agent] Marked task as failed."
else
  echo "[mock_agent] Simulating successful completion."
  bash "$tracking_script" update-status "$list_id" "$task_id" completed "Mock agent completed task successfully"
  echo "[mock_agent] Marked task as completed."
fi

echo ""
echo "=== PROMPT RECEIVED ==="
echo "$prompt"
echo "=== END PROMPT ==="
