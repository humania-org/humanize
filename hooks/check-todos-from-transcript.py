#!/usr/bin/env python3
"""
Helper script to check for incomplete tasks from Claude Code.

Supports both:
- Legacy TodoWrite tool (parsed from transcript)
- New Task system (read directly from ~/.claude/tasks/<session_id>/)

Exit codes:
  0 - All tasks are completed (or no tasks exist)
  1 - There are incomplete tasks (details on stdout)
  2 - Parse error reading hook input JSON

Usage:
    echo '{"session_id": "...", "transcript_path": "/path/to/transcript.jsonl"}' | python3 check-todos-from-transcript.py
"""
import json
import sys
from pathlib import Path
from typing import List, Tuple


def extract_tool_calls_from_entry(entry: dict) -> List[Tuple[str, dict]]:
    """
    Extract tool calls from a transcript entry.
    Returns list of (tool_name, tool_input) tuples.
    """
    tool_calls = []
    entry_type = entry.get("type", "")

    # Pattern 1 & 2: Extract content list from assistant or message entries
    if entry_type == "assistant":
        content = entry.get("message", {}).get("content", [])
    elif entry_type == "message":
        content = entry.get("content", [])
    else:
        content = []

    # Extract tool calls from content list
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                tool_name = block.get("name", "")
                tool_input = block.get("input", {})
                if tool_name:
                    tool_calls.append((tool_name, tool_input))

    # Pattern 3: Direct tool_use entry
    if entry_type == "tool_use":
        tool_name = entry.get("name", "") or entry.get("tool_name", "")
        tool_input = entry.get("input", {}) or entry.get("tool_input", {})
        if tool_name:
            tool_calls.append((tool_name, tool_input))

    return tool_calls


def find_incomplete_todos_from_transcript(transcript_path: Path) -> List[dict]:
    """
    Parse transcript JSONL and find incomplete legacy todos (TodoWrite only).

    Returns list of incomplete items with 'status' and 'content' keys.
    """
    if not transcript_path.exists():
        return []

    # Legacy: track the most recent TodoWrite todos
    latest_todos = []

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

    # Build list of incomplete items from legacy todos
    incomplete = []
    for todo in latest_todos:
        status = todo.get("status", "")
        content = todo.get("content", "")
        if status != "completed":
            incomplete.append({
                "status": status,
                "content": content,
                "source": "todo",
            })

    return incomplete


def find_incomplete_tasks_from_directory(session_id: str, tasks_base_dir: str = "") -> List[dict]:
    """
    Read task files directly from ~/.claude/tasks/<session_id>/ directory.

    This is the authoritative source for task state, as it reflects
    the actual in-memory task list that Claude Code maintains.

    Args:
        session_id: The Claude Code session ID
        tasks_base_dir: Optional override for tasks base directory (for testing)

    Returns list of incomplete items with 'status' and 'content' keys.
    """
    if tasks_base_dir:
        tasks_dir = Path(tasks_base_dir) / session_id
    else:
        tasks_dir = Path.home() / ".claude" / "tasks" / session_id
    if not tasks_dir.exists() or not tasks_dir.is_dir():
        return []

    incomplete = []
    for task_file in tasks_dir.glob("*.json"):
        try:
            with open(task_file, 'r', encoding='utf-8') as f:
                task = json.load(f)

            status = task.get("status", "pending")
            if status not in ("completed", "deleted"):
                # Task is incomplete
                subject = task.get("subject", "")
                description = task.get("description", "")
                task_id = task_file.stem  # Filename without .json
                content = subject or description or f"Task {task_id}"
                incomplete.append({
                    "status": status,
                    "content": content,
                    "source": "task",
                    "task_id": task_id,
                })
        except (json.JSONDecodeError, OSError):
            # Skip malformed or unreadable task files
            continue

    return incomplete


def main():
    # Read hook input from stdin
    try:
        stdin_content = sys.stdin.read().strip()
        if not stdin_content:
            # Empty input - no data available, allow proceeding
            sys.exit(0)
        hook_input = json.loads(stdin_content)
    except json.JSONDecodeError as e:
        # Parse error - exit with code 2
        print(f"PARSE_ERROR: {e}", file=sys.stderr)
        sys.exit(2)

    incomplete_items = []

    # Check new Task system using external task directory (authoritative source)
    session_id = hook_input.get("session_id", "")
    tasks_base_dir = hook_input.get("tasks_base_dir", "")  # For testing
    if session_id:
        incomplete_items.extend(find_incomplete_tasks_from_directory(session_id, tasks_base_dir))

    # Check legacy TodoWrite from transcript
    transcript_path = hook_input.get("transcript_path", "")
    if transcript_path:
        transcript_path = Path(transcript_path).expanduser()
        incomplete_items.extend(find_incomplete_todos_from_transcript(transcript_path))

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
    print("INCOMPLETE_TODOS")
    print("\n".join(output_lines))
    sys.exit(1)


if __name__ == "__main__":
    main()
