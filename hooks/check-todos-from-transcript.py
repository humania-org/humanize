#!/usr/bin/env python3
"""
Helper script to check for incomplete todos from Claude Code transcript.

Reads the transcript JSONL file and finds the most recent TodoWrite tool call.

Exit codes:
  0 - All todos are completed (or no todos exist)
  1 - There are incomplete todos (details on stdout)
  2 - Parse error reading hook input JSON

Usage:
    echo '{"transcript_path": "/path/to/transcript.jsonl"}' | python3 check-todos-from-transcript.py
"""
import json
import sys
from pathlib import Path


def find_latest_todos(transcript_path: Path) -> list:
    """
    Parse transcript JSONL and find the most recent TodoWrite tool result.
    Returns the list of todos from the most recent TodoWrite call.
    """
    if not transcript_path.exists():
        return []

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

            # The actual Claude Code transcript format:
            # {
            #   "type": "assistant",
            #   "message": {
            #     "content": [
            #       {"type": "tool_use", "name": "TodoWrite", "input": {"todos": [...]}}
            #     ]
            #   }
            # }

            # Pattern 1: Claude Code transcript format (type: assistant)
            if entry.get("type") == "assistant":
                message = entry.get("message", {})
                content = message.get("content", [])
                if isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "tool_use":
                            tool_name = block.get("name", "")
                            if tool_name == "TodoWrite":
                                tool_input = block.get("input", {})
                                todos = tool_input.get("todos", [])
                                if todos:
                                    latest_todos = todos

            # Pattern 2: Alternative format (type: message)
            if entry.get("type") == "message":
                content = entry.get("content", [])
                if isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "tool_use":
                            tool_name = block.get("name", "")
                            if tool_name == "TodoWrite":
                                tool_input = block.get("input", {})
                                todos = tool_input.get("todos", [])
                                if todos:
                                    latest_todos = todos

            # Pattern 3: Direct tool_use entry
            if entry.get("type") == "tool_use":
                tool_name = entry.get("name", "") or entry.get("tool_name", "")
                if tool_name == "TodoWrite":
                    tool_input = entry.get("input", {}) or entry.get("tool_input", {})
                    todos = tool_input.get("todos", [])
                    if todos:
                        latest_todos = todos

    return latest_todos


def main():
    # Read hook input from stdin
    try:
        hook_input = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        # Parse error - exit with code 2
        print(f"PARSE_ERROR: {e}", file=sys.stderr)
        sys.exit(2)

    transcript_path = hook_input.get("transcript_path", "")
    if not transcript_path:
        sys.exit(0)

    # Expand ~ to home directory
    transcript_path = Path(transcript_path).expanduser()

    # Find the latest todos
    todos = find_latest_todos(transcript_path)

    if not todos:
        # No todos found, allow proceeding
        sys.exit(0)

    # Check for incomplete todos
    incomplete = []
    for todo in todos:
        status = todo.get("status", "")
        content = todo.get("content", "")
        if status != "completed":
            incomplete.append(f"  - [{status}] {content}")

    if incomplete:
        # Output marker and incomplete todos both to stdout
        # (Using mixed stdout/stderr causes ordering issues due to buffering)
        print("INCOMPLETE_TODOS")
        print("\n".join(incomplete))
        sys.exit(1)

    # All todos completed
    sys.exit(0)


if __name__ == "__main__":
    main()
