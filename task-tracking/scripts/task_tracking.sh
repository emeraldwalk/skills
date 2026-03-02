# Helper: Parse add-task flags (no logic change)
parse_add_task_flags() {
  # expects all args as "$@"; sets ac_items, ctx_docs, ctx_files, ctx_skills, verify_command, verify_instruction, depends_on_items
  ac_items=() ctx_docs=() ctx_files=() ctx_skills=() depends_on_items=()
  verify_command="" verify_instruction=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ac) ac_items+=("$2"); shift 2 ;;
      --doc) ctx_docs+=("$2"); shift 2 ;;
      --file) ctx_files+=("$2"); shift 2 ;;
      --skill) ctx_skills+=("$2"); shift 2 ;;
      --verify-command) verify_command="$2"; shift 2 ;;
      --verify-instruction) verify_instruction="$2"; shift 2 ;;
      --depends-on) depends_on_items+=("$2"); shift 2 ;;
      *) echo "Unknown option: $1"; return 1 ;;
    esac
  done
}
#!/usr/bin/env bash
set -euo pipefail

# Find existing .tasks directory by walking up, or fallback to PWD
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

  # Validate depends_on task IDs exist
  for dep_id in "${depends_on_items[@]+"${depends_on_items[@]}"}"; do
    if [[ ! -f "${list_dir}/${dep_id}.json" ]]; then
      echo "Error: Dependency task '${dep_id}' not found in list '${list_name}'."
      return 1
    fi
  done

  # Find next task number
  local max_num
  max_num=$(jq '[.tasks[].id | select(startswith("task-")) | split("-")[1] | tonumber] | max // 0' "$path")
  local next_num=$((max_num + 1))
  local task_id
  task_id=$(printf "task-%02d" "$next_num")
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S")

  # Build JSON arrays from repeatable flags
  local files_json="[]" docs_json="[]" skills_json="[]" ac_json="[]" depends_on_json="[]"
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
  if [[ ${#depends_on_items[@]} -gt 0 ]]; then
    depends_on_json=$(printf '%s\n' "${depends_on_items[@]}" | jq -R . | jq -s .)
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
    --argjson depends_on "$depends_on_json" \
    '{id:$id,description:$desc,status:"todo",created:$ts,updated:$ts,note:null,context:$ctx,acceptance_criteria:$ac,verification:$verify,depends_on:$depends_on,claimed_by:null}')

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
  local skip_failed=false claim="" force=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-failed) skip_failed=true; shift ;;
      --claim) claim="$2"; shift 2 ;;
      --force) force=true; shift ;;
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

  # Iterate through candidate tasks in order, skipping blocked ones
  local candidate_ids
  candidate_ids=$(jq -r '.tasks[] | select(.status != "completed" and .status != "skipped") | .id' "$path")

  local task_id="" task=""

  while IFS= read -r cid; do
    [[ -z "$cid" ]] && continue

    local cfile="${list_dir}/${cid}.json"
    [[ -f "$cfile" ]] || continue

    local cstatus
    cstatus=$(jq -r '.status' "$cfile")

    # Skip terminal statuses (guards against stale index)
    if [[ "$cstatus" == "completed" || "$cstatus" == "skipped" ]]; then
      continue
    fi

    # Apply --skip-failed
    if [[ "$skip_failed" == "true" && "$cstatus" == "failed" ]]; then
      continue
    fi

    # Check all dependencies are completed
    local deps
    deps=$(jq -r '.depends_on // [] | .[]' "$cfile")
    local blocked=false
    while IFS= read -r dep_id; do
      [[ -z "$dep_id" ]] && continue
      local dep_file="${list_dir}/${dep_id}.json"
      if [[ ! -f "$dep_file" ]]; then
        blocked=true
        break
      fi
      local dep_status
      dep_status=$(jq -r '.status' "$dep_file")
      if [[ "$dep_status" != "completed" && "$dep_status" != "skipped" ]]; then
        blocked=true
        break
      fi
    done <<< "$deps"

    if [[ "$blocked" == "true" ]]; then
      continue
    fi

    task_id="$cid"
    task=$(cat "$cfile")
    break
  done <<< "$candidate_ids"

  if [[ -z "$task_id" ]]; then
    echo "No pending tasks found."
    return 0
  fi

  local task_file="${list_dir}/${task_id}.json"

  if [[ -n "$claim" ]]; then
    local claimed_by
    claimed_by=$(echo "$task" | jq -r '.claimed_by // empty')

    if [[ -n "$claimed_by" && "$force" != "true" ]]; then
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

cmd_update_status() {
  local list_name="$1" task_id="$2" status="$3" note="$4"

  local path
  path=$(get_list_path "$list_name")

  if [[ ! -f "$path" ]]; then
    echo "Error: List not found."
    return 1
  fi

  local list_dir
  list_dir=$(get_list_dir "$list_name")
  local task_file="${list_dir}/${task_id}.json"

  if [[ ! -f "$task_file" ]]; then
    echo "Error: Task ${task_id} not found."
    return 1
  fi

  # Warn if completing/skipping a task that other tasks depend on
  if [[ "$status" == "completed" || "$status" == "skipped" ]]; then
    local dependents=()
    for tf in "${list_dir}"/task-*.json; do
      [[ -f "$tf" ]] || continue
      local tid
      tid=$(jq -r '.id' "$tf")
      [[ "$tid" == "$task_id" ]] && continue
      local dep_status
      dep_status=$(jq -r '.status' "$tf")
      if [[ "$dep_status" != "completed" && "$dep_status" != "skipped" ]]; then
        local has_dep
        has_dep=$(jq --arg dep "$task_id" '.depends_on // [] | map(select(. == $dep)) | length' "$tf")
        if [[ "$has_dep" -gt 0 ]]; then
          dependents+=("$tid")
        fi
      fi
    done
    if [[ ${#dependents[@]} -gt 0 ]]; then
      echo "Note: Completing ${task_id} will unblock dependent tasks: ${dependents[*]}"
    fi
  fi

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S")

  # Update index (status only)
  local tmp="${path}.tmp"
  jq --arg id "$task_id" --arg s "$status" \
    '(.tasks[] | select(.id == $id)).status = $s' \
    "$path" > "$tmp" && mv "$tmp" "$path"

  # Update per-task JSON
  local task_tmp="${task_file}.tmp"
  jq --arg s "$status" --arg ts "$timestamp" --arg n "$note" \
    '.status = $s | .updated = $ts | .note = $n' \
    "$task_file" > "$task_tmp" && mv "$task_tmp" "$task_file"

  write_log "$list_name" "$task_id" "$status" "$note"

  echo "Task ${task_id} updated to '${status}'."
}

cmd_update_task() {
  local list_name="$1" task_id="$2"
  shift 2

  ac_items=() ctx_docs=() ctx_files=() ctx_skills=() depends_on_items=()
  verify_command="" verify_instruction=""
  local new_description=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --description) new_description="$2"; shift 2 ;;
      --ac) ac_items+=("$2"); shift 2 ;;
      --doc) ctx_docs+=("$2"); shift 2 ;;
      --file) ctx_files+=("$2"); shift 2 ;;
      --skill) ctx_skills+=("$2"); shift 2 ;;
      --verify-command) verify_command="$2"; shift 2 ;;
      --verify-instruction) verify_instruction="$2"; shift 2 ;;
      --depends-on) depends_on_items+=("$2"); shift 2 ;;
      *) echo "Unknown option: $1"; return 1 ;;
    esac
  done

  if [[ -n "$verify_command" && -n "$verify_instruction" ]]; then
    echo "Error: Cannot specify both --verify-command and --verify-instruction."
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

  if [[ ! -f "$task_file" ]]; then
    echo "Error: Task ${task_id} not found."
    return 1
  fi

  # Validate depends_on task IDs exist (if provided)
  for dep_id in "${depends_on_items[@]+"${depends_on_items[@]}"}"; do
    if [[ ! -f "${list_dir}/${dep_id}.json" ]]; then
      echo "Error: Dependency task '${dep_id}' not found in list '${list_name}'."
      return 1
    fi
  done

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S")

  # Build update expression for per-task JSON
  local task_update='.updated = $ts'

  if [[ -n "$new_description" ]]; then
    task_update="$task_update"' | .description = $desc'
  fi

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

  if [[ ${#depends_on_items[@]} -gt 0 ]]; then
    local depends_on_json
    depends_on_json=$(printf '%s\n' "${depends_on_items[@]}" | jq -R . | jq -s .)
    task_update="$task_update"' | .depends_on = $depends_on'
  fi

  if [[ -n "$verify_command" ]]; then
    task_update="$task_update"' | .verification = {type:"command",value:$verify}'
  elif [[ -n "$verify_instruction" ]]; then
    task_update="$task_update"' | .verification = {type:"instruction",value:$verify}'
  fi

  # Build jq args
  local jq_args=(--arg ts "$timestamp")

  if [[ -n "$new_description" ]]; then
    jq_args+=(--arg desc "$new_description")
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
  if [[ ${#depends_on_items[@]} -gt 0 ]]; then
    jq_args+=(--argjson depends_on "$depends_on_json")
  fi
  if [[ -n "$verify_command" ]]; then
    jq_args+=(--arg verify "$verify_command")
  elif [[ -n "$verify_instruction" ]]; then
    jq_args+=(--arg verify "$verify_instruction")
  fi

  # Update per-task JSON
  local task_tmp="${task_file}.tmp"
  jq "${jq_args[@]}" "$task_update" "$task_file" > "$task_tmp" && mv "$task_tmp" "$task_file"

  # Update description in index if changed
  if [[ -n "$new_description" ]]; then
    local tmp="${path}.tmp"
    jq --arg id "$task_id" --arg desc "$new_description" \
      '(.tasks[] | select(.id == $id)).description = $desc' \
      "$path" > "$tmp" && mv "$tmp" "$path"
  fi

  echo "Task ${task_id} updated."
}

cmd_list_tasks() {
  local list_name="$1"
  shift
  local format="summary"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --format) format="$2"; shift 2 ;;
      *) echo "Unknown option: $1"; return 1 ;;
    esac
  done

  local path
  path=$(get_list_path "$list_name")
  local list_dir
  list_dir=$(get_list_dir "$list_name")

  if [[ ! -f "$path" ]]; then
    echo "Error: List '${list_name}' not found."
    return 1
  fi

  # Helper: iterate per-task files in index order, emit each via jq filter
  _list_tasks_in_order() {
    local jq_filter="$1"
    local order
    order=$(jq -r '.tasks[].id' "$path")
    local task_files=("${list_dir}"/task-*.json)
    if [[ ! -f "${task_files[0]}" ]]; then
      echo "[]"
      return 0
    fi
    local result="[" first=true
    while IFS= read -r task_id; do
      local tf="${list_dir}/${task_id}.json"
      [[ -f "$tf" ]] || continue
      if [[ "$first" == "true" ]]; then first=false; else result+=","; fi
      result+=$(jq "$jq_filter" "$tf")
    done <<< "$order"
    result+="]"
    echo "$result" | jq '.'
  }

  case "$format" in
    full)
      _list_tasks_in_order '.'
      ;;
    json)
      # Index metadata + per-task summary array (includes depends_on, claimed_by)
      local tasks_json
      tasks_json=$(_list_tasks_in_order '{id,description,status,claimed_by,depends_on}')
      jq --argjson tasks "$tasks_json" '. + {tasks: $tasks}' "$path"
      ;;
    summary|*)
      # Per-task summary: id, description, status, claimed_by, depends_on
      _list_tasks_in_order '{id,description,status,claimed_by,depends_on}'
      ;;
  esac
}

cmd_query() {
  local list_name="$1"
  shift

  local filter_status="" search_term="" depends_on_id="" claimed_by=""
  local show_blocked=false limit=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status)      filter_status="$2"; shift 2 ;;
      --search)      search_term="$2"; shift 2 ;;
      --depends-on)  depends_on_id="$2"; shift 2 ;;
      --blocked)     show_blocked=true; shift ;;
      --claimed-by)  claimed_by="$2"; shift 2 ;;
      --limit)       limit="$2"; shift 2 ;;
      *) echo "Unknown option: $1"; return 1 ;;
    esac
  done

  local path
  path=$(get_list_path "$list_name")
  local list_dir
  list_dir=$(get_list_dir "$list_name")

  if [[ ! -f "$path" ]]; then
    echo "Error: List '${list_name}' not found."
    return 1
  fi

  # Get ordered task IDs from index
  local task_ids
  task_ids=$(jq -r '.tasks[].id' "$path")

  local results=()

  while IFS= read -r task_id; do
    local tf="${list_dir}/${task_id}.json"
    [[ -f "$tf" ]] || continue

    local task
    task=$(cat "$tf")

    # --status filter
    if [[ -n "$filter_status" ]]; then
      local ts
      ts=$(echo "$task" | jq -r '.status')
      [[ "$ts" == "$filter_status" ]] || continue
    fi

    # --claimed-by filter
    if [[ -n "$claimed_by" ]]; then
      local cb
      cb=$(echo "$task" | jq -r '.claimed_by // ""')
      [[ "$cb" == "$claimed_by" ]] || continue
    fi

    # --depends-on filter: tasks that list the given ID in their depends_on
    if [[ -n "$depends_on_id" ]]; then
      local has_dep
      has_dep=$(echo "$task" | jq --arg dep "$depends_on_id" \
        '.depends_on // [] | map(select(. == $dep)) | length')
      [[ "$has_dep" -gt 0 ]] || continue
    fi

    # --blocked filter: tasks with at least one non-terminal dependency
    if [[ "$show_blocked" == "true" ]]; then
      local task_status
      task_status=$(echo "$task" | jq -r '.status')
      # Only non-terminal tasks can be meaningfully "blocked"
      [[ "$task_status" != "completed" && "$task_status" != "skipped" ]] || continue

      local deps
      deps=$(echo "$task" | jq -r '.depends_on // [] | .[]')
      local is_blocked=false
      while IFS= read -r dep_id; do
        [[ -z "$dep_id" ]] && continue
        local dep_file="${list_dir}/${dep_id}.json"
        if [[ ! -f "$dep_file" ]]; then
          is_blocked=true
          break
        fi
        local dep_status
        dep_status=$(jq -r '.status' "$dep_file")
        if [[ "$dep_status" != "completed" && "$dep_status" != "skipped" ]]; then
          is_blocked=true
          break
        fi
      done <<< "$deps"
      [[ "$is_blocked" == "true" ]] || continue
    fi

    # --search filter: case-insensitive match in description, AC, or notes
    if [[ -n "$search_term" ]]; then
      local matched
      matched=$(echo "$task" | jq --arg term "$search_term" '
        (.description | ascii_downcase | contains($term | ascii_downcase)) or
        (.acceptance_criteria // [] | map(ascii_downcase | contains($term | ascii_downcase)) | any) or
        (.note // "" | ascii_downcase | contains($term | ascii_downcase))
      ')
      [[ "$matched" == "true" ]] || continue
    fi

    results+=("$task")

    # --limit check (0 = unlimited)
    if [[ "$limit" -gt 0 && "${#results[@]}" -ge "$limit" ]]; then
      break
    fi
  done <<< "$task_ids"

  if [[ ${#results[@]} -eq 0 ]]; then
    echo "[]"
    return 0
  fi

  # Output as JSON array of summary objects (id, description, status, claimed_by)
  local json="["
  local first=true
  for task in "${results[@]}"; do
    if [[ "$first" == "true" ]]; then
      first=false
    else
      json+=","
    fi
    json+=$(echo "$task" | jq '{id,description,status,claimed_by,depends_on}')
  done
  json+="]"
  echo "$json" | jq '.'
}

cmd_count() {
  local list_name="$1"
  shift

  local filter_status="" exclude_statuses=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status)         filter_status="$2"; shift 2 ;;
      --exclude-status) exclude_statuses+=("$2"); shift 2 ;;
      *) echo "Unknown option: $1"; return 1 ;;
    esac
  done

  local path
  path=$(get_list_path "$list_name")

  if [[ ! -f "$path" ]]; then
    echo "Error: List '${list_name}' not found."
    return 1
  fi

  local exclude_json
  exclude_json=$(printf '%s\n' "${exclude_statuses[@]+"${exclude_statuses[@]}"}" | jq -Rsc 'split("\n") | map(select(. != ""))')

  jq \
    --arg fs "$filter_status" \
    --argjson xs "$exclude_json" \
    '[.tasks[]
      | select($fs == "" or .status == $fs)
      | select(.status as $s | $xs | map(. == $s) | any | not)
    ] | length' "$path"
}

cmd_add_dependency() {
  local list_name="$1" task_id="$2" dep_id="$3"

  local list_dir
  list_dir=$(get_list_dir "$list_name")
  local task_file="${list_dir}/${task_id}.json"
  local dep_file="${list_dir}/${dep_id}.json"

  if [[ ! -f "$(get_list_path "$list_name")" ]]; then
    echo "Error: List '${list_name}' not found."
    return 1
  fi
  if [[ ! -f "$task_file" ]]; then
    echo "Error: Task '${task_id}' not found."
    return 1
  fi
  if [[ ! -f "$dep_file" ]]; then
    echo "Error: Dependency task '${dep_id}' not found."
    return 1
  fi
  if [[ "$task_id" == "$dep_id" ]]; then
    echo "Error: A task cannot depend on itself."
    return 1
  fi

  # Check for duplicate
  local already
  already=$(jq --arg dep "$dep_id" '.depends_on // [] | map(select(. == $dep)) | length' "$task_file")
  if [[ "$already" -gt 0 ]]; then
    echo "Dependency '${dep_id}' already exists on task '${task_id}'."
    return 0
  fi

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S")
  local task_tmp="${task_file}.tmp"
  jq --arg dep "$dep_id" --arg ts "$timestamp" \
    '.depends_on = ((.depends_on // []) + [$dep]) | .updated = $ts' \
    "$task_file" > "$task_tmp" && mv "$task_tmp" "$task_file"

  echo "Added dependency: ${task_id} depends on ${dep_id}."
}

cmd_commit_message() {
  local list_name="$1" task_id="$2"

  local list_dir
  list_dir=$(get_list_dir "$list_name")
  local task_file="${list_dir}/${task_id}.json"

  if [[ ! -f "$(get_list_path "$list_name")" ]]; then
    echo "Error: List '${list_name}' not found."
    return 1
  fi
  if [[ ! -f "$task_file" ]]; then
    echo "Error: Task '${task_id}' not found."
    return 1
  fi

  local description note
  description=$(jq -r '.description' "$task_file")
  note=$(jq -r '.note // ""' "$task_file")

  local subject="${list_name}/${task_id}: ${description}"
  if [[ -n "$note" ]]; then
    printf '%s\n\n%s\n' "$subject" "$note"
  else
    printf '%s\n' "$subject"
  fi
}

cmd_remove_dependency() {
  local list_name="$1" task_id="$2" dep_id="$3"

  local list_dir
  list_dir=$(get_list_dir "$list_name")
  local task_file="${list_dir}/${task_id}.json"

  if [[ ! -f "$(get_list_path "$list_name")" ]]; then
    echo "Error: List '${list_name}' not found."
    return 1
  fi
  if [[ ! -f "$task_file" ]]; then
    echo "Error: Task '${task_id}' not found."
    return 1
  fi

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S")
  local task_tmp="${task_file}.tmp"
  jq --arg dep "$dep_id" --arg ts "$timestamp" \
    '.depends_on = ((.depends_on // []) | map(select(. != $dep))) | .updated = $ts' \
    "$task_file" > "$task_tmp" && mv "$task_tmp" "$task_file"

  echo "Removed dependency: ${task_id} no longer depends on ${dep_id}."
}

usage() {
  cat <<'USAGE'
Agent Task CLI (bash)

Commands:
  create-list <name>
  list-lists
  list-tasks <list> [--format {summary|full|json}]
  add-task <list> <desc> [--file <path>]... [--doc <path>]... [--skill <name>]... [--ac <criterion>]... [--verify-command <cmd>] [--verify-instruction <text>] [--depends-on <task-id>]...
  next <list> [--skip-failed] [--claim <AGENT_ID>] [--force]
  update-status <list> <task-id> <status> <note>
  update-task <list> <task-id> [--description <text>] [--file <path>]... [--doc <path>]... [--skill <name>]... [--ac <criterion>]... [--verify-command <cmd>] [--verify-instruction <text>] [--depends-on <task-id>]...
  add-dependency <list> <task-id> <depends-on-task-id>
  remove-dependency <list> <task-id> <depends-on-task-id>
  commit-message <list> <task-id>
  query <list> [--status <status>] [--search <term>] [--depends-on <task-id>] [--blocked] [--claimed-by <agent-id>] [--limit <n>]
  count <list> [--status <status>] [--exclude-status <status>]

Dependency notes:
  - 'next --claim' rejects tasks with unmet (non-completed) dependencies
  - 'update-status ... completed' notes if other pending tasks depend on this task

Query notes:
  - Filters are AND-combined (all must match)
  - --blocked shows non-completed tasks with at least one non-completed dependency
  - --search matches against description, acceptance criteria, and notes (case-insensitive)
  - --limit 0 means unlimited (default)
USAGE
}

# --- Main ---
ensure_dir

command="${1:-}"
shift 2>/dev/null || true

case "$command" in
  create-list)        cmd_create_list "$@" ;;
  list-lists)         cmd_list_lists "$@" ;;
  list-tasks)         cmd_list_tasks "$@" ;;
  add-task)           cmd_add_task "$@" ;;
  next)               cmd_next "$@" ;;
  update-status)      cmd_update_status "$@" ;;
  update-task)        cmd_update_task "$@" ;;
  add-dependency)     cmd_add_dependency "$@" ;;
  remove-dependency)  cmd_remove_dependency "$@" ;;
  commit-message)     cmd_commit_message "$@" ;;
  query)              cmd_query "$@" ;;
  count)              cmd_count "$@" ;;
  --help|-h|"")       usage ;;
  *)                  echo "Unknown command: $command"; usage; exit 1 ;;
esac
