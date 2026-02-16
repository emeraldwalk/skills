# Helper: Parse add-task flags (no logic change)
parse_add_task_flags() {
  # expects all args as "$@"; sets ac_items, ctx_docs, ctx_files, ctx_skills, verify_command, verify_instruction
  ac_items=() ctx_docs=() ctx_files=() ctx_skills=()
  verify_command="" verify_instruction=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ac) ac_items+=("$2"); shift 2 ;;
      --doc) ctx_docs+=("$2"); shift 2 ;;
      --file) ctx_files+=("$2"); shift 2 ;;
      --skill) ctx_skills+=("$2"); shift 2 ;;
      --verify-command) verify_command="$2"; shift 2 ;;
      --verify-instruction) verify_instruction="$2"; shift 2 ;;
      *) echo "Unknown option: $1"; return 1 ;;
    esac
  done
}
#!/usr/bin/env bash
set -euo pipefail

TASKS_DIR="${TASKS_DIR:-${PWD}/.tasks}"

# Ensure .tasks directory exists
ensure_dir() {
  mkdir -p "$TASKS_DIR"
}

get_list_dir() { echo "${TASKS_DIR}/$1"; }
get_list_path() { echo "${TASKS_DIR}/$1/_task-list.json"; }
get_log_path() { echo "${TASKS_DIR}/$1/status-log.jsonl"; }

write_log() {
  local list_name="$1" task_id="$2" status="$3" note="${4:-null}"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S")
  if [[ "$note" == "null" ]]; then
    printf '{"id":"%s","status":"%s","timestamp":"%s","note":null}\n' \
      "$task_id" "$status" "$timestamp" >> "$(get_log_path "$list_name")"
  else
    jq -cn --arg id "$task_id" --arg s "$status" --arg t "$timestamp" --arg n "$note" \
      '{id:$id,status:$s,timestamp:$t,note:$n}' >> "$(get_log_path "$list_name")"
  fi
}

cmd_create_list() {
  local name="$1"
  local list_dir
  list_dir=$(get_list_dir "$name")
  local path
  path=$(get_list_path "$name")

  if [[ -d "$list_dir" ]]; then
    echo "Error: List '${name}' already exists."
    return 1
  fi

  mkdir -p "$list_dir"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S")
  jq -n --arg name "$name" --arg ts "$timestamp" \
    '{name:$name,created_at:$ts,tasks:[]}' > "$path"
  echo "List '${name}' created successfully."
}

cmd_add_task() {

  local list_name="$1" description="$2"
  shift 2
  parse_add_task_flags "$@"

  if [[ -n "$verify_command" && -n "$verify_instruction" ]]; then
    echo "Error: Cannot specify both --verify-command and --verify-instruction."
    return 1
  fi

  local path
  path=$(get_list_path "$list_name")
  local list_dir
  list_dir=$(get_list_dir "$list_name")

  if [[ ! -f "$path" ]]; then
    echo "Error: List '${list_name}' not found."
    return 1
  fi

  # Find next task number
  local max_num
  max_num=$(jq '[.tasks[].id | select(startswith("task-")) | split("-")[1] | tonumber] | max // 0' "$path")
  local next_num=$((max_num + 1))
  local task_id
  task_id=$(printf "task-%02d" "$next_num")
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S")

  # Build JSON arrays from repeatable flags
  local files_json="[]" docs_json="[]" skills_json="[]" ac_json="[]"
  if [[ ${#ctx_files[@]} -gt 0 ]]; then
    files_json=$(printf '%s\n' "${ctx_files[@]}" | jq -R . | jq -s .)
  fi
  if [[ ${#ctx_docs[@]} -gt 0 ]]; then
    docs_json=$(printf '%s\n' "${ctx_docs[@]}" | jq -R . | jq -s .)
  fi
  if [[ ${#ctx_skills[@]} -gt 0 ]]; then
    skills_json=$(printf '%s\n' "${ctx_skills[@]}" | jq -R . | jq -s .)
  fi
  if [[ ${#ac_items[@]} -gt 0 ]]; then
    ac_json=$(printf '%s\n' "${ac_items[@]}" | jq -R . | jq -s .)
  fi

  # Build context object
  local ctx_json
  ctx_json=$(jq -n \
    --argjson files "$files_json" \
    --argjson docs "$docs_json" \
    --argjson skills "$skills_json" \
    '{files:$files,docs:$docs,skills:$skills}')

  # Build verification JSON object
  local verify_json="null"
  if [[ -n "$verify_command" ]]; then
    verify_json=$(jq -n --arg v "$verify_command" '{type:"command",value:$v}')
  elif [[ -n "$verify_instruction" ]]; then
    verify_json=$(jq -n --arg v "$verify_instruction" '{type:"instruction",value:$v}')
  fi

  # Build the new task object
  local new_task
  new_task=$(jq -n \
    --arg id "$task_id" \
    --arg desc "$description" \
    --arg ts "$timestamp" \
    --argjson ctx "$ctx_json" \
    --argjson ac "$ac_json" \
    --argjson verify "$verify_json" \
    '{id:$id,description:$desc,status:"todo",created:$ts,updated:$ts,note:null,context:$ctx,acceptance_criteria:$ac,verification:$verify,claimed_by:null}')

  # Update _task-list.json (summary only)
  local summary
  summary=$(jq -n --arg id "$task_id" --arg desc "$description" \
    '{id:$id,description:$desc,status:"todo"}')
  local tmp="${path}.tmp"
  jq --argjson task "$summary" '.tasks += [$task]' "$path" > "$tmp" && mv "$tmp" "$path"

  # Write per-task JSON file (full detail)
  echo "$new_task" | jq '.' > "${list_dir}/${task_id}.json"

  echo "Created task ${task_id} in list '${list_name}'."
}

cmd_next() {
  local list_name="$1"
  shift
  local skip_failed=false claim=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-failed) skip_failed=true; shift ;;
      --claim) claim="$2"; shift 2 ;;
      *) echo "Unknown option: $1"; return 1 ;;
    esac
  done

  local path
  path=$(get_list_path "$list_name")
  local list_dir
  list_dir=$(get_list_dir "$list_name")

  if [[ ! -f "$path" ]]; then
    echo "Error: List not found."
    return 1
  fi

  # Find first matching task from index
  local filter='.tasks[] | select(.status != "completed")'
  if [[ "$skip_failed" == "true" ]]; then
    filter="$filter"' | select(.status != "failed")'
  fi
  filter="[${filter}] | first"

  local summary
  summary=$(jq "$filter" "$path")

  if [[ "$summary" == "null" || -z "$summary" ]]; then
    echo "No pending tasks found."
    return 0
  fi

  local task_id
  task_id=$(echo "$summary" | jq -r '.id')

  # Read full task from per-task file
  local task_file="${list_dir}/${task_id}.json"
  local task
  task=$(cat "$task_file")

  if [[ -n "$claim" ]]; then
    local claimed_by
    claimed_by=$(echo "$task" | jq -r '.claimed_by // empty')

    if [[ -n "$claimed_by" ]]; then
      echo "Error: Task ${task_id} is already claimed by ${claimed_by}."
      return 1
    fi

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S")

    # Update per-task JSON
    task=$(jq --arg agent "$claim" --arg ts "$timestamp" \
      '.claimed_by = $agent | .updated = $ts' <<< "$task")
    echo "$task" | jq '.' > "$task_file"
  fi

  echo "$task" | jq '.'
}

cmd_list_lists() {
  if [[ ! -d "$TASKS_DIR" ]]; then
    echo "[]"
    return 0
  fi

  local lists=()
  for dir in "$TASKS_DIR"/*; do
    if [[ -d "$dir" && -f "$dir/_task-list.json" ]]; then
      lists+=("$(basename "$dir")")
    fi
  done

  if [[ ${#lists[@]} -eq 0 ]]; then
    echo "[]"
    return 0
  fi

  printf '%s\n' "${lists[@]}" | jq -R . | jq -s .
}

cmd_update_task() {
  local list_name="$1" task_id="$2" status="$3"
  shift 3
  local note=""

  # Parse all flags (including add-task flags and --note)
  ac_items=() ctx_docs=() ctx_files=() ctx_skills=()
  verify_command="" verify_instruction=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --note) note="$2"; shift 2 ;;
      --ac) ac_items+=("$2"); shift 2 ;;
      --doc) ctx_docs+=("$2"); shift 2 ;;
      --file) ctx_files+=("$2"); shift 2 ;;
      --skill) ctx_skills+=("$2"); shift 2 ;;
      --verify-command) verify_command="$2"; shift 2 ;;
      --verify-instruction) verify_instruction="$2"; shift 2 ;;
      *) echo "Unknown option: $1"; return 1 ;;
    esac
  done

  if [[ -n "$verify_command" && -n "$verify_instruction" ]]; then
    echo "Error: Cannot specify both --verify-command and --verify-instruction."
    return 1
  fi

  if [[ "$status" != "completed" && -z "$note" ]]; then
    echo "Error: A note is required for non-completed status changes (e.g., error logs or progress updates)."
    return 1
  fi

  local path
  path=$(get_list_path "$list_name")

  if [[ ! -f "$path" ]]; then
    echo "Error: List not found."
    return 1
  fi

  local list_dir
  list_dir=$(get_list_dir "$list_name")
  local task_file="${list_dir}/${task_id}.json"

  # Check task exists
  if [[ ! -f "$task_file" ]]; then
    echo "Error: Task ${task_id} not found."
    return 1
  fi

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S")

  # Update index (status only)
  local tmp="${path}.tmp"
  jq --arg id "$task_id" --arg s "$status" \
    '(.tasks[] | select(.id == $id)).status = $s' \
    "$path" > "$tmp" && mv "$tmp" "$path"

  # Build update expression for per-task JSON
  local task_update='.status = $s | .updated = $ts'

  if [[ -n "$note" ]]; then
    task_update="$task_update"' | .note = $n'
  else
    task_update="$task_update"' | .note = null'
  fi

  # Build JSON arrays if flags provided
  if [[ ${#ctx_files[@]} -gt 0 ]]; then
    local files_json
    files_json=$(printf '%s\n' "${ctx_files[@]}" | jq -R . | jq -s .)
    task_update="$task_update"' | .context.files = $files'
  fi

  if [[ ${#ctx_docs[@]} -gt 0 ]]; then
    local docs_json
    docs_json=$(printf '%s\n' "${ctx_docs[@]}" | jq -R . | jq -s .)
    task_update="$task_update"' | .context.docs = $docs'
  fi

  if [[ ${#ctx_skills[@]} -gt 0 ]]; then
    local skills_json
    skills_json=$(printf '%s\n' "${ctx_skills[@]}" | jq -R . | jq -s .)
    task_update="$task_update"' | .context.skills = $skills'
  fi

  if [[ ${#ac_items[@]} -gt 0 ]]; then
    local ac_json
    ac_json=$(printf '%s\n' "${ac_items[@]}" | jq -R . | jq -s .)
    task_update="$task_update"' | .acceptance_criteria = $ac'
  fi

  if [[ -n "$verify_command" ]]; then
    task_update="$task_update"' | .verification = {type:"command",value:$verify}'
  elif [[ -n "$verify_instruction" ]]; then
    task_update="$task_update"' | .verification = {type:"instruction",value:$verify}'
  fi

  # Build jq command with all args
  local jq_args=(--arg s "$status" --arg ts "$timestamp")

  if [[ -n "$note" ]]; then
    jq_args+=(--arg n "$note")
  fi
  if [[ ${#ctx_files[@]} -gt 0 ]]; then
    jq_args+=(--argjson files "$files_json")
  fi
  if [[ ${#ctx_docs[@]} -gt 0 ]]; then
    jq_args+=(--argjson docs "$docs_json")
  fi
  if [[ ${#ctx_skills[@]} -gt 0 ]]; then
    jq_args+=(--argjson skills "$skills_json")
  fi
  if [[ ${#ac_items[@]} -gt 0 ]]; then
    jq_args+=(--argjson ac "$ac_json")
  fi
  if [[ -n "$verify_command" ]]; then
    jq_args+=(--arg verify "$verify_command")
  elif [[ -n "$verify_instruction" ]]; then
    jq_args+=(--arg verify "$verify_instruction")
  fi

  # Update per-task JSON (full detail)
  local task_tmp="${task_file}.tmp"
  jq "${jq_args[@]}" "$task_update" "$task_file" > "$task_tmp" && mv "$task_tmp" "$task_file"

  if [[ -n "$note" ]]; then
    write_log "$list_name" "$task_id" "$status" "$note"
  else
    write_log "$list_name" "$task_id" "$status"
  fi

  echo "Task ${task_id} updated to '${status}'."
}

usage() {
  cat <<'USAGE'
Agent Task CLI (bash)

Commands:
  create-list <name>
  list-lists
  add-task <list> <desc> [--file <path>]... [--doc <path>]... [--skill <name>]... [--ac <criterion>]... [--verify-command <cmd>] [--verify-instruction <text>]
  next <list> [--skip-failed] [--claim <AGENT_ID>]
  update-task <list> <task-id> <status> [--note <note>] [--file <path>]... [--doc <path>]... [--skill <name>]... [--ac <criterion>]... [--verify-command <cmd>] [--verify-instruction <text>]
USAGE
}

# --- Main ---
ensure_dir

command="${1:-}"
shift 2>/dev/null || true

case "$command" in
  create-list)  cmd_create_list "$@" ;;
  list-lists)   cmd_list_lists "$@" ;;
  add-task)     cmd_add_task "$@" ;;
  next)         cmd_next "$@" ;;
  update-task)  cmd_update_task "$@" ;;
  --help|-h|"") usage ;;
  *)            echo "Unknown command: $command"; usage; exit 1 ;;
esac
