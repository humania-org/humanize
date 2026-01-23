#!/usr/bin/env python3
"""
Helper script to check for incomplete tasks from Claude Code transcript.

Supports both the legacy TodoWrite tool and the new Task system (TaskCreate/TaskUpdate).

Exit codes:
  0 - All tasks are completed (or no tasks exist)
  1 - There are incomplete tasks (details on stdout)
  2 - Parse error reading hook input JSON

Usage:
    echo '{"transcript_path": "/path/to/transcript.jsonl"}' | python3 check-todos-from-transcript.py
"""
import json
import sys
from pathlib import Path
from typing import Dict, List, Tuple


def extract_tool_calls_from_entry(entry: dict) -> List[Tuple[str, dict]]:
    """
    Extract tool calls from a transcript entry.
    Returns list of (tool_name, tool_input) tuples.
    """
    tool_calls = []

    # Pattern 1: Claude Code transcript format (type: assistant)
    if entry.get("type") == "assistant":
        message = entry.get("message", {})
        content = message.get("content", [])
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    tool_name = block.get("name", "")
                    tool_input = block.get("input", {})
                    if tool_name:
                        tool_calls.append((tool_name, tool_input))

    # Pattern 2: Alternative format (type: message)
    if entry.get("type") == "message":
        content = entry.get("content", [])
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    tool_name = block.get("name", "")
                    tool_input = block.get("input", {})
                    if tool_name:
                        tool_calls.append((tool_name, tool_input))

    # Pattern 3: Direct tool_use entry
    if entry.get("type") == "tool_use":
        tool_name = entry.get("name", "") or entry.get("tool_name", "")
        tool_input = entry.get("input", {}) or entry.get("tool_input", {})
        if tool_name:
            tool_calls.append((tool_name, tool_input))

    return tool_calls


def find_incomplete_items(transcript_path: Path) -> List[dict]:
    """
    Parse transcript JSONL and find incomplete tasks/todos.

    Supports:
    - Legacy TodoWrite: Returns todos from the most recent TodoWrite call
    - New Task system: Tracks TaskCreate/TaskUpdate to build current task state

    Returns list of incomplete items with 'status' and 'content' keys.
    """
    if not transcript_path.exists():
        return []

    # Legacy: track the most recent TodoWrite todos
    latest_todos = []

    # New Task system: track tasks by ID
    # Key: taskId, Value: {subject, description, status}
    tasks: Dict[str, dict] = {}
    # Auto-increment ID for TaskCreate when no explicit ID
    next_task_id = 1

    with open(transcript_path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue

            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue

            # Extract all tool calls from this entry
            for tool_name, tool_input in extract_tool_calls_from_entry(entry):

                # Legacy: TodoWrite
                if tool_name == "TodoWrite":
                    todos = tool_input.get("todos", [])
                    if todos:
                        latest_todos = todos

                # New Task system: TaskCreate
                elif tool_name == "TaskCreate":
                    subject = tool_input.get("subject", "")
                    description = tool_input.get("description", "")
                    # TaskCreate always creates with pending status
                    # The taskId is assigned by the system, but we track by order
                    task_id = str(next_task_id)
                    next_task_id += 1
                    tasks[task_id] = {
                        "subject": subject,
                        "description": description,
                        "status": "pending",
                    }

                # New Task system: TaskUpdate
                elif tool_name == "TaskUpdate":
                    task_id = tool_input.get("taskId", "")
                    if task_id:
                        # Update existing task or create placeholder
                        if task_id not in tasks:
                            # Task was created before transcript started
                            tasks[task_id] = {
                                "subject": tool_input.get("subject", f"Task {task_id}"),
                                "description": tool_input.get("description", ""),
                                "status": "pending",
                            }
                        # Apply updates
                        if "status" in tool_input:
                            tasks[task_id]["status"] = tool_input["status"]
                        if "subject" in tool_input:
                            tasks[task_id]["subject"] = tool_input["subject"]
                        if "description" in tool_input:
                            tasks[task_id]["description"] = tool_input["description"]

    # Build list of incomplete items
    incomplete = []

    # Check legacy todos (from most recent TodoWrite)
    for todo in latest_todos:
        status = todo.get("status", "")
        content = todo.get("content", "")
        if status != "completed":
            incomplete.append({
                "status": status,
                "content": content,
                "source": "todo",
            })

    # Check new Task system
    for task_id, task in tasks.items():
        status = task.get("status", "pending")
        if status != "completed":
            # Use subject as content, fall back to description
            content = task.get("subject", "") or task.get("description", f"Task {task_id}")
            incomplete.append({
                "status": status,
                "content": content,
                "source": "task",
                "task_id": task_id,
            })

    return incomplete


def main():
    # Read hook input from stdin
    # First read the content, then parse - this handles empty input better
    try:
        stdin_content = sys.stdin.read().strip()
        if not stdin_content:
            # Empty input - no transcript path available, allow proceeding
            sys.exit(0)
        hook_input = json.loads(stdin_content)
    except json.JSONDecodeError as e:
        # Parse error - exit with code 2
        print(f"PARSE_ERROR: {e}", file=sys.stderr)
        sys.exit(2)

    transcript_path = hook_input.get("transcript_path", "")
    if not transcript_path:
        sys.exit(0)

    # Expand ~ to home directory
    transcript_path = Path(transcript_path).expanduser()

    # Find incomplete items (both legacy todos and new tasks)
    incomplete_items = find_incomplete_items(transcript_path)

    if not incomplete_items:
        # No incomplete items, allow proceeding
        sys.exit(0)

    # Format output
    output_lines = []
    for item in incomplete_items:
        status = item.get("status", "unknown")
        content = item.get("content", "")
        source = item.get("source", "unknown")
        if source == "task":
            task_id = item.get("task_id", "?")
            output_lines.append(f"  - [{status}] (Task #{task_id}) {content}")
        else:
            output_lines.append(f"  - [{status}] {content}")

    # Output marker and incomplete items both to stdout
    # (Using mixed stdout/stderr causes ordering issues due to buffering)
    print("INCOMPLETE_TODOS")
    print("\n".join(output_lines))
    sys.exit(1)


if __name__ == "__main__":
    main()
