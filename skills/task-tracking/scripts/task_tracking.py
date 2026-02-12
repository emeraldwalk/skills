#!/usr/bin/env python3
import os
import json
import uuid
import sys
import argparse
from datetime import datetime


# Always use .tasks in the current working directory, not the script's directory
TASKS_DIR = os.path.join(os.getcwd(), ".tasks")


class TaskManager:
    def __init__(self):
        # Ensure .tasks is always created in the current working directory
        if not os.path.exists(TASKS_DIR):
            os.makedirs(TASKS_DIR)


    def _get_list_dir(self, list_name):
        return os.path.join(TASKS_DIR, list_name)

    def _get_list_path(self, list_name):
        return os.path.join(self._get_list_dir(list_name), "task-list.json")

    def _get_log_path(self, list_name):
        return os.path.join(self._get_list_dir(list_name), "status-log.jsonl")

    def _write_log(self, list_name, task_id, status, note=None):
        log_entry = {
            "id": task_id,
            "status": status,
            "timestamp": datetime.now().isoformat(),
            "note": note
        }
        with open(self._get_log_path(list_name), "a") as f:
            f.write(json.dumps(log_entry) + "\n")

    def create_list(self, name):
        list_dir = self._get_list_dir(name)
        path = self._get_list_path(name)
        if os.path.exists(list_dir):
            return f"Error: List '{name}' already exists."
        os.makedirs(list_dir, exist_ok=True)
        data = {"name": name, "created_at": datetime.now().isoformat(), "tasks": []}
        with open(path, "w") as f:
            json.dump(data, f, indent=2)
        return f"List '{name}' created successfully."

    def create_task(self, list_name, description, context):
        path = self._get_list_path(list_name)
        list_dir = self._get_list_dir(list_name)
        if not os.path.exists(path):
            return f"Error: List '{list_name}' not found."
        with open(path, "r") as f:
            data = json.load(f)
        # Generate incremental task id in the form task-##
        existing_ids = [task["id"] for task in data["tasks"] if task["id"].startswith("task-")]
        max_num = 0
        for tid in existing_ids:
            try:
                num = int(tid.split("-")[-1])
                if num > max_num:
                    max_num = num
            except Exception:
                continue
        task_id = f"task-{max_num+1:02d}"
        timestamp = datetime.now().isoformat()
        if not context:
            return "Error: Context is required for task creation."
        new_task = {
            "id": task_id,
            "description": description,
            "status": "todo",
            "created": timestamp,
            "updated": timestamp,
            "note": None,
            "context": context,
            "claimed_by": None
        }
        data["tasks"].append(new_task)
        # 1. Update JSON Index
        with open(path, "w") as f:
            json.dump(data, f, indent=2)
        # 2. Create per-task JSON file in list subdirectory
        json_path = os.path.join(list_dir, f"{task_id}.json")
        with open(json_path, "w") as f:
            json.dump(new_task, f, indent=2)
        # 3. Do not log initial status
        return f"Created task {task_id} in list '{list_name}'."


    def get_next(self, list_name, skip_failed=False, claim_agent=None):
        path = self._get_list_path(list_name)
        list_dir = self._get_list_dir(list_name)
        if not os.path.exists(path):
            return "Error: List not found."
        with open(path, "r") as f:
            data = json.load(f)
        for task in data["tasks"]:
            if task["status"] == "completed":
                continue
            if skip_failed and task["status"] == "failed":
                continue
            if claim_agent:
                if task.get("claimed_by"):
                    return f"Error: Task {task['id']} is already claimed by {task['claimed_by']}."
                task["claimed_by"] = claim_agent
                task["updated"] = datetime.now().isoformat()
                # Update both list and per-task JSON
                with open(path, "w") as wf:
                    json.dump(data, wf, indent=2)
                json_path = os.path.join(list_dir, f"{task['id']}.json")
                with open(json_path, "w") as jf:
                    json.dump(task, jf, indent=2)
            return json.dumps(task, indent=2)
        return "No pending tasks found."

    def update_status(self, list_name, task_id, status, note=None):
        if status != "completed" and not note:
            return "Error: A note is required for non-completed status changes (e.g., error logs or progress updates)."
        path = self._get_list_path(list_name)
        if not os.path.exists(path):
            return "Error: List not found."
        with open(path, "r") as f:
            data = json.load(f)
        found = False
        for task in data["tasks"]:
            if task["id"] == task_id:
                task["status"] = status
                task["note"] = note
                task["updated"] = datetime.now().isoformat()
                found = True
                break
        if not found:
            return f"Error: Task {task_id} not found."
        with open(path, "w") as f:
            json.dump(data, f, indent=2)
        self._write_log(list_name, task_id, status, note)
        return f"Task {task_id} updated to '{status}'."



def main():
    parser = argparse.ArgumentParser(description="Agent Task CLI")
    subparsers = parser.add_subparsers(dest="command")

    # Create List
    p_cl = subparsers.add_parser("create-list")
    p_cl.add_argument("name")

    # Create Task
    p_ct = subparsers.add_parser("add-task")
    p_ct.add_argument("list")
    p_ct.add_argument("desc")
    p_ct.add_argument("--context", required=True, help="Context for the task (required)")


    # Update Task
    p_ut = subparsers.add_parser("update-task")
    p_ut.add_argument("list")
    p_ut.add_argument("id")
    p_ut.add_argument("status")
    p_ut.add_argument("--note", help="Required for non-completed status")

    # Get Next
    p_gn = subparsers.add_parser("next")
    p_gn.add_argument("list")
    p_gn.add_argument("--skip-failed", action="store_true")
    p_gn.add_argument("--claim", metavar="AGENT_ID", help="Claim the next unclaimed task as AGENT_ID")

    args = parser.parse_args()
    tm = TaskManager()

    if args.command == "create-list":
        print(tm.create_list(args.name))
    elif args.command == "add-task":
        print(tm.create_task(args.list, args.desc, args.context))
    elif args.command == "update-task":
        print(tm.update_status(args.list, args.id, args.status, args.note))
    elif args.command == "next":
        print(tm.get_next(args.list, args.skip_failed, claim_agent=args.claim))
    else:
        parser.print_help()

if __name__ == "__main__":
    main()
