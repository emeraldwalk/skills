#!/usr/bin/env bash
# Usage: bash scripts/tests/test_task_tracking.sh [--local]
# Runs all tests for task_tracking.sh.
#   --local  Run in current directory (results left in .tasks/ for inspection)
#   default  Run in isolated temp directories (cleaned up after each test)
# Requires: jq
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="${SCRIPT_DIR}/task_tracking.sh"
PASS=0
FAIL=0
LOCAL=false
ORIG_DIR="$PWD"
TEST_NUM=0

if [[ "${1:-}" == "--local" ]]; then
  LOCAL=true
  export TASKS_DIR="${ORIG_DIR}/.tasks/.tests"
  rm -rf "$TASKS_DIR"
fi

# Each test gets a unique list name to avoid collisions in --local mode
setup() {
  TEST_NUM=$((TEST_NUM + 1))
  if [[ "$LOCAL" == "true" ]]; then
    cd "$ORIG_DIR"
  else
    TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR"
  fi
}

teardown() {
  if [[ "$LOCAL" != "true" ]]; then
    rm -rf "$TEST_DIR"
  fi
}

# Unique list name per test
L() { echo "test-${TEST_NUM}"; }

# Resolve .tasks dir for assertions (respects TASKS_DIR override)
T() { echo "${TASKS_DIR:-${PWD}/.tasks}"; }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == *"$expected"* ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected to contain: $expected"
    echo "    actual: $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_exists() {
  local label="$1" file="$2"
  if [[ -f "$file" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (file not found: $file)"
    FAIL=$((FAIL + 1))
  fi
}

assert_json_eq() {
  local label="$1" file="$2" query="$3" expected="$4"
  local actual
  actual=$(jq -r "$query" "$file")
  assert_eq "$label" "$expected" "$actual"
}

# ─── Tests ───

echo "=== create-list ==="

echo "-- creates a new list"
setup; l=$(L)
out=$(bash "$S" create-list "$l")
assert_contains "success message" "created successfully" "$out"
assert_file_exists "_task-list.json exists" "$(T)/$l/_task-list.json"
assert_json_eq "list name" "$(T)/$l/_task-list.json" ".name" "$l"
assert_json_eq "empty tasks array" "$(T)/$l/_task-list.json" ".tasks | length" "0"
teardown

echo "-- rejects duplicate list"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
out=$(bash "$S" create-list "$l" 2>&1 || true)
assert_contains "error message" "already exists" "$out"
teardown

echo ""
echo "=== add-task ==="

echo "-- minimal task (no optional flags)"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
out=$(bash "$S" add-task "$l" "Simple task")
assert_contains "success message" "Created task task-01" "$out"
assert_file_exists "per-task file" "$(T)/$l/task-01.json"
assert_json_eq "index has id" "$(T)/$l/_task-list.json" ".tasks[0].id" "task-01"
assert_json_eq "index has description" "$(T)/$l/_task-list.json" ".tasks[0].description" "Simple task"
assert_json_eq "index has status" "$(T)/$l/_task-list.json" ".tasks[0].status" "todo"
assert_json_eq "index has no context" "$(T)/$l/_task-list.json" ".tasks[0] | keys | length" "3"
assert_json_eq "task has context object" "$(T)/$l/task-01.json" ".context | type" "object"
assert_json_eq "empty files" "$(T)/$l/task-01.json" ".context.files | length" "0"
assert_json_eq "empty docs" "$(T)/$l/task-01.json" ".context.docs | length" "0"
assert_json_eq "empty skills" "$(T)/$l/task-01.json" ".context.skills | length" "0"
assert_json_eq "null verification" "$(T)/$l/task-01.json" ".verification" "null"
assert_json_eq "empty ac" "$(T)/$l/task-01.json" ".acceptance_criteria | length" "0"
teardown

echo "-- task with all flags"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
bash "$S" add-task "$l" "Full task" \
  --file "src/app.ts" --file "tsconfig.json" \
  --doc "docs/PLAN.md" \
  --skill "pocketbase-managing" \
  --ac "Passes tests" --ac "No regressions" \
  --verify-command "npm test" >/dev/null
assert_json_eq "2 files" "$(T)/$l/task-01.json" ".context.files | length" "2"
assert_json_eq "first file" "$(T)/$l/task-01.json" ".context.files[0]" "src/app.ts"
assert_json_eq "second file" "$(T)/$l/task-01.json" ".context.files[1]" "tsconfig.json"
assert_json_eq "1 doc" "$(T)/$l/task-01.json" ".context.docs | length" "1"
assert_json_eq "doc value" "$(T)/$l/task-01.json" ".context.docs[0]" "docs/PLAN.md"
assert_json_eq "1 skill" "$(T)/$l/task-01.json" ".context.skills | length" "1"
assert_json_eq "skill value" "$(T)/$l/task-01.json" ".context.skills[0]" "pocketbase-managing"
assert_json_eq "2 ac" "$(T)/$l/task-01.json" ".acceptance_criteria | length" "2"
assert_json_eq "verify type" "$(T)/$l/task-01.json" ".verification.type" "command"
assert_json_eq "verify value" "$(T)/$l/task-01.json" ".verification.value" "npm test"
teardown

echo "-- verify-instruction"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
bash "$S" add-task "$l" "Manual check" \
  --verify-instruction "Confirm modal closes on click" >/dev/null
assert_json_eq "verify type" "$(T)/$l/task-01.json" ".verification.type" "instruction"
assert_json_eq "verify value" "$(T)/$l/task-01.json" ".verification.value" "Confirm modal closes on click"
teardown

echo "-- rejects both verify flags"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
out=$(bash "$S" add-task "$l" "Bad" --verify-command "a" --verify-instruction "b" 2>&1 || true)
assert_contains "error message" "Cannot specify both" "$out"
teardown

echo "-- verify-command with special characters"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
bash "$S" add-task "$l" "Pipe test" \
  --verify-command 'curl -s localhost:3000 | jq ".status"' >/dev/null
assert_json_eq "pipes preserved" "$(T)/$l/task-01.json" ".verification.value" 'curl -s localhost:3000 | jq ".status"'
teardown

echo "-- incremental task IDs"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
bash "$S" add-task "$l" "First" >/dev/null
bash "$S" add-task "$l" "Second" >/dev/null
bash "$S" add-task "$l" "Third" >/dev/null
assert_json_eq "3 tasks in index" "$(T)/$l/_task-list.json" ".tasks | length" "3"
assert_json_eq "task-01" "$(T)/$l/_task-list.json" ".tasks[0].id" "task-01"
assert_json_eq "task-02" "$(T)/$l/_task-list.json" ".tasks[1].id" "task-02"
assert_json_eq "task-03" "$(T)/$l/_task-list.json" ".tasks[2].id" "task-03"
assert_file_exists "task-01.json" "$(T)/$l/task-01.json"
assert_file_exists "task-02.json" "$(T)/$l/task-02.json"
assert_file_exists "task-03.json" "$(T)/$l/task-03.json"
teardown

echo "-- add-task to nonexistent list"
setup; l=$(L)
out=$(bash "$S" add-task "nonexistent-$l" "Task" 2>&1 || true)
assert_contains "error message" "not found" "$out"
teardown

echo ""
echo "=== next ==="

echo "-- returns first todo task (full detail)"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
bash "$S" add-task "$l" "First" --file "a.ts" >/dev/null
bash "$S" add-task "$l" "Second" >/dev/null
out=$(bash "$S" next "$l")
assert_contains "returns task-01" '"id": "task-01"' "$out"
assert_contains "has context" '"context"' "$out"
assert_contains "has file detail" '"a.ts"' "$out"
teardown

echo "-- skips completed tasks"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
bash "$S" add-task "$l" "First" >/dev/null
bash "$S" add-task "$l" "Second" >/dev/null
bash "$S" update-task "$l" task-01 completed >/dev/null
out=$(bash "$S" next "$l")
assert_contains "returns task-02" '"id": "task-02"' "$out"
teardown

echo "-- skip-failed flag"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
bash "$S" add-task "$l" "First" >/dev/null
bash "$S" add-task "$l" "Second" >/dev/null
bash "$S" update-task "$l" task-01 failed --note "broken" >/dev/null
out=$(bash "$S" next "$l" --skip-failed)
assert_contains "skips failed, returns task-02" '"id": "task-02"' "$out"
teardown

echo "-- no pending tasks"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
bash "$S" add-task "$l" "Only" >/dev/null
bash "$S" update-task "$l" task-01 completed >/dev/null
out=$(bash "$S" next "$l")
assert_contains "no pending message" "No pending tasks found" "$out"
teardown

echo "-- claim a task"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
bash "$S" add-task "$l" "Claimable" >/dev/null
out=$(bash "$S" next "$l" --claim agent-42)
assert_contains "returns task" '"id": "task-01"' "$out"
assert_contains "claimed_by set" '"claimed_by": "agent-42"' "$out"
assert_json_eq "claim persisted" "$(T)/$l/task-01.json" ".claimed_by" "agent-42"
teardown

echo "-- reject double claim"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
bash "$S" add-task "$l" "Claimable" >/dev/null
bash "$S" next "$l" --claim agent-1 >/dev/null
out=$(bash "$S" next "$l" --claim agent-2 2>&1 || true)
assert_contains "already claimed error" "already claimed" "$out"
teardown

echo "-- next on nonexistent list"
setup; l=$(L)
out=$(bash "$S" next "nonexistent-$l" 2>&1 || true)
assert_contains "error message" "List not found" "$out"
teardown

echo ""
echo "=== update-task ==="

echo "-- update to completed (no note required)"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
bash "$S" add-task "$l" "Task" >/dev/null
out=$(bash "$S" update-task "$l" task-01 completed)
assert_contains "success message" "updated to 'completed'" "$out"
assert_json_eq "index status" "$(T)/$l/_task-list.json" ".tasks[0].status" "completed"
assert_json_eq "task status" "$(T)/$l/task-01.json" ".status" "completed"
teardown

echo "-- update to failed (requires note)"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
bash "$S" add-task "$l" "Task" >/dev/null
out=$(bash "$S" update-task "$l" task-01 failed --note "segfault in module X")
assert_contains "success message" "updated to 'failed'" "$out"
assert_json_eq "index status" "$(T)/$l/_task-list.json" ".tasks[0].status" "failed"
assert_json_eq "task status" "$(T)/$l/task-01.json" ".status" "failed"
assert_json_eq "note saved" "$(T)/$l/task-01.json" ".note" "segfault in module X"
teardown

echo "-- rejects non-completed without note"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
bash "$S" add-task "$l" "Task" >/dev/null
out=$(bash "$S" update-task "$l" task-01 failed 2>&1 || true)
assert_contains "error message" "note is required" "$out"
teardown

echo "-- update nonexistent task"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
out=$(bash "$S" update-task "$l" task-99 completed 2>&1 || true)
assert_contains "error message" "not found" "$out"
teardown

echo "-- status log written"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
bash "$S" add-task "$l" "Task" >/dev/null
bash "$S" update-task "$l" task-01 failed --note "oops" >/dev/null
bash "$S" update-task "$l" task-01 completed >/dev/null
assert_file_exists "log file" "$(T)/$l/status-log.jsonl"
lines=$(wc -l < "$(T)/$l/status-log.jsonl" | tr -d ' ')
assert_eq "2 log entries" "2" "$lines"
teardown

echo "-- update with context files"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
bash "$S" add-task "$l" "Task" >/dev/null
bash "$S" update-task "$l" task-01 in_progress --note "Adding files" \
  --file "src/new.ts" --file "src/test.ts" >/dev/null
assert_json_eq "2 files added" "$(T)/$l/task-01.json" ".context.files | length" "2"
assert_json_eq "first file" "$(T)/$l/task-01.json" ".context.files[0]" "src/new.ts"
assert_json_eq "second file" "$(T)/$l/task-01.json" ".context.files[1]" "src/test.ts"
teardown

echo "-- update with docs and skills"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
bash "$S" add-task "$l" "Task" >/dev/null
bash "$S" update-task "$l" task-01 in_progress --note "Adding context" \
  --doc "README.md" --doc "API.md" \
  --skill "pocketbase-managing" >/dev/null
assert_json_eq "2 docs" "$(T)/$l/task-01.json" ".context.docs | length" "2"
assert_json_eq "1 skill" "$(T)/$l/task-01.json" ".context.skills | length" "1"
assert_json_eq "skill value" "$(T)/$l/task-01.json" ".context.skills[0]" "pocketbase-managing"
teardown

echo "-- update with acceptance criteria"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
bash "$S" add-task "$l" "Task" >/dev/null
bash "$S" update-task "$l" task-01 in_progress --note "Adding AC" \
  --ac "Tests pass" --ac "Coverage >80%" --ac "No lint errors" >/dev/null
assert_json_eq "3 ac items" "$(T)/$l/task-01.json" ".acceptance_criteria | length" "3"
assert_json_eq "first ac" "$(T)/$l/task-01.json" ".acceptance_criteria[0]" "Tests pass"
assert_json_eq "second ac" "$(T)/$l/task-01.json" ".acceptance_criteria[1]" "Coverage >80%"
teardown

echo "-- update with verify-command"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
bash "$S" add-task "$l" "Task" >/dev/null
bash "$S" update-task "$l" task-01 in_progress --note "Adding verification" \
  --verify-command "npm test" >/dev/null
assert_json_eq "verify type" "$(T)/$l/task-01.json" ".verification.type" "command"
assert_json_eq "verify value" "$(T)/$l/task-01.json" ".verification.value" "npm test"
teardown

echo "-- update with verify-instruction"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
bash "$S" add-task "$l" "Task" >/dev/null
bash "$S" update-task "$l" task-01 in_progress --note "Manual verification" \
  --verify-instruction "Check UI is responsive" >/dev/null
assert_json_eq "verify type" "$(T)/$l/task-01.json" ".verification.type" "instruction"
assert_json_eq "verify value" "$(T)/$l/task-01.json" ".verification.value" "Check UI is responsive"
teardown

echo "-- update rejects both verify flags"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
bash "$S" add-task "$l" "Task" >/dev/null
out=$(bash "$S" update-task "$l" task-01 in_progress --note "test" \
  --verify-command "a" --verify-instruction "b" 2>&1 || true)
assert_contains "error message" "Cannot specify both" "$out"
teardown

echo "-- update with all flags combined"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
bash "$S" add-task "$l" "Task" >/dev/null
bash "$S" update-task "$l" task-01 in_progress --note "Full update" \
  --file "a.ts" --file "b.ts" \
  --doc "PLAN.md" \
  --skill "task-tracking" \
  --ac "Works" --ac "Fast" \
  --verify-command "bash test.sh" >/dev/null
assert_json_eq "2 files" "$(T)/$l/task-01.json" ".context.files | length" "2"
assert_json_eq "1 doc" "$(T)/$l/task-01.json" ".context.docs | length" "1"
assert_json_eq "1 skill" "$(T)/$l/task-01.json" ".context.skills | length" "1"
assert_json_eq "2 ac" "$(T)/$l/task-01.json" ".acceptance_criteria | length" "2"
assert_json_eq "verify set" "$(T)/$l/task-01.json" ".verification.type" "command"
assert_json_eq "status updated" "$(T)/$l/task-01.json" ".status" "in_progress"
assert_json_eq "note set" "$(T)/$l/task-01.json" ".note" "Full update"
teardown

echo "-- update preserves existing fields when adding new ones"
setup; l=$(L)
bash "$S" create-list "$l" >/dev/null
bash "$S" add-task "$l" "Task" --file "original.ts" --ac "Original AC" >/dev/null
bash "$S" update-task "$l" task-01 in_progress --note "Adding more" \
  --file "new.ts" --ac "New AC" >/dev/null
# Note: update-task REPLACES arrays, doesn't append
assert_json_eq "files replaced" "$(T)/$l/task-01.json" ".context.files | length" "1"
assert_json_eq "new file" "$(T)/$l/task-01.json" ".context.files[0]" "new.ts"
assert_json_eq "ac replaced" "$(T)/$l/task-01.json" ".acceptance_criteria | length" "1"
assert_json_eq "new ac" "$(T)/$l/task-01.json" ".acceptance_criteria[0]" "New AC"
teardown

echo ""
echo "=== help ==="

echo "-- help flag"
setup
out=$(bash "$S" --help)
assert_contains "shows commands" "Commands:" "$out"
assert_contains "shows create-list" "create-list" "$out"
assert_contains "shows add-task" "add-task" "$out"
assert_contains "shows next" "next" "$out"
assert_contains "shows update-task" "update-task" "$out"
teardown

echo "-- no args shows help"
setup
out=$(bash "$S")
assert_contains "shows commands" "Commands:" "$out"
teardown

echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
