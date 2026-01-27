#!/bin/bash
#
# Test script for check-todos-from-transcript.py
#
# Tests the Python task checker for proper error handling
# and correct interpretation of task states.
# Supports both legacy TodoWrite and new Task system (TaskCreate/TaskUpdate).
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TODO_CHECKER="$PROJECT_ROOT/hooks/check-todos-from-transcript.py"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0

# Test helper functions
pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "${RED}FAIL${NC}: $1"
    echo "  Expected: $2"
    echo "  Got: $3"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Setup test environment
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

echo "========================================"
echo "Testing check-todos-from-transcript.py"
echo "========================================"
echo ""

# ========================================
# Test Group 1: Input Handling
# ========================================
echo "Test Group 1: Input Handling"
echo ""

# Test 1: Invalid JSON input should exit 2 (parse error)
echo "Test 1: Invalid JSON input"
set +e
RESULT=$(echo "not json at all" | python3 "$TODO_CHECKER" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Invalid JSON returns exit code 2"
else
    fail "Invalid JSON handling" "exit 2" "exit $EXIT_CODE"
fi

# Test 2: Empty input should exit 0 (allow proceeding - no transcript available)
echo "Test 2: Empty input"
set +e
RESULT=$(echo "" | python3 "$TODO_CHECKER" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Empty input allows proceeding (exit 0)"
else
    fail "Empty input handling" "exit 0" "exit $EXIT_CODE"
fi

# Test 3: Valid JSON without transcript_path should exit 0
echo "Test 3: JSON without transcript_path"
set +e
RESULT=$(echo '{"other": "data"}' | python3 "$TODO_CHECKER" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "JSON without transcript_path exits 0"
else
    fail "Missing transcript_path" "exit 0" "exit $EXIT_CODE"
fi

# Test 4: Non-existent transcript file should exit 0
echo "Test 4: Non-existent transcript file"
set +e
RESULT=$(echo '{"transcript_path": "/nonexistent/path/transcript.jsonl"}' | python3 "$TODO_CHECKER" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Non-existent file exits 0"
else
    fail "Non-existent file handling" "exit 0" "exit $EXIT_CODE"
fi

# ========================================
# Test Group 2: Todo Detection
# ========================================
echo ""
echo "Test Group 2: Todo Detection"
echo ""

# Test 5: Transcript with all completed todos
echo "Test 5: All todos completed"
cat > "$TEST_DIR/transcript-all-complete.jsonl" << 'EOF'
{"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "TodoWrite", "input": {"todos": [{"content": "Task 1", "status": "completed"}, {"content": "Task 2", "status": "completed"}]}}]}}
EOF
set +e
RESULT=$(echo "{\"transcript_path\": \"$TEST_DIR/transcript-all-complete.jsonl\"}" | python3 "$TODO_CHECKER" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "All todos completed exits 0"
else
    fail "All todos completed" "exit 0" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 6: Transcript with incomplete todos
echo "Test 6: Incomplete todos"
cat > "$TEST_DIR/transcript-incomplete.jsonl" << 'EOF'
{"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "TodoWrite", "input": {"todos": [{"content": "Task 1", "status": "completed"}, {"content": "Task 2", "status": "pending"}]}}]}}
EOF
set +e
RESULT=$(echo "{\"transcript_path\": \"$TEST_DIR/transcript-incomplete.jsonl\"}" | python3 "$TODO_CHECKER" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 1 ]]; then
    pass "Incomplete todos exits 1"
else
    fail "Incomplete todos" "exit 1" "exit $EXIT_CODE"
fi

# Test 7: Output includes incomplete todo details
echo "Test 7: Output includes todo details"
if echo "$RESULT" | grep -q "Task 2"; then
    pass "Output includes incomplete task name"
else
    fail "Output includes task name" "Task 2 in output" "$RESULT"
fi

# Test 8: In-progress status counts as incomplete
echo "Test 8: In-progress status"
cat > "$TEST_DIR/transcript-in-progress.jsonl" << 'EOF'
{"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "TodoWrite", "input": {"todos": [{"content": "Task 1", "status": "in_progress"}]}}]}}
EOF
set +e
RESULT=$(echo "{\"transcript_path\": \"$TEST_DIR/transcript-in-progress.jsonl\"}" | python3 "$TODO_CHECKER" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 1 ]]; then
    pass "In-progress status exits 1"
else
    fail "In-progress status" "exit 1" "exit $EXIT_CODE"
fi

# ========================================
# Test Group 3: Transcript Format Variations
# ========================================
echo ""
echo "Test Group 3: Transcript Format Variations"
echo ""

# Test 9: Empty transcript file
echo "Test 9: Empty transcript file"
touch "$TEST_DIR/transcript-empty.jsonl"
set +e
RESULT=$(echo "{\"transcript_path\": \"$TEST_DIR/transcript-empty.jsonl\"}" | python3 "$TODO_CHECKER" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Empty transcript exits 0"
else
    fail "Empty transcript" "exit 0" "exit $EXIT_CODE"
fi

# Test 10: Transcript with invalid JSONL lines
echo "Test 10: Invalid JSONL lines ignored"
cat > "$TEST_DIR/transcript-invalid-lines.jsonl" << 'EOF'
not json
{"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "TodoWrite", "input": {"todos": [{"content": "Task", "status": "completed"}]}}]}}
also not json
EOF
set +e
RESULT=$(echo "{\"transcript_path\": \"$TEST_DIR/transcript-invalid-lines.jsonl\"}" | python3 "$TODO_CHECKER" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Invalid JSONL lines ignored, valid todo found"
else
    fail "Invalid JSONL handling" "exit 0 (valid todo found)" "exit $EXIT_CODE"
fi

# Test 11: Multiple TodoWrite calls - uses latest
echo "Test 11: Multiple TodoWrite calls uses latest"
cat > "$TEST_DIR/transcript-multiple.jsonl" << 'EOF'
{"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "TodoWrite", "input": {"todos": [{"content": "Old Task", "status": "pending"}]}}]}}
{"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "TodoWrite", "input": {"todos": [{"content": "New Task", "status": "completed"}]}}]}}
EOF
set +e
RESULT=$(echo "{\"transcript_path\": \"$TEST_DIR/transcript-multiple.jsonl\"}" | python3 "$TODO_CHECKER" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Uses latest TodoWrite (all completed)"
else
    fail "Multiple TodoWrite handling" "exit 0 (latest is completed)" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 12: Direct tool_use entry format
echo "Test 12: Direct tool_use entry format"
cat > "$TEST_DIR/transcript-direct.jsonl" << 'EOF'
{"type": "tool_use", "name": "TodoWrite", "input": {"todos": [{"content": "Task", "status": "completed"}]}}
EOF
set +e
RESULT=$(echo "{\"transcript_path\": \"$TEST_DIR/transcript-direct.jsonl\"}" | python3 "$TODO_CHECKER" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Direct tool_use format handled"
else
    fail "Direct tool_use format" "exit 0" "exit $EXIT_CODE"
fi

# Test 13: type: message format
echo "Test 13: Alternative message format"
cat > "$TEST_DIR/transcript-message.jsonl" << 'EOF'
{"type": "message", "content": [{"type": "tool_use", "name": "TodoWrite", "input": {"todos": [{"content": "Task", "status": "completed"}]}}]}
EOF
set +e
RESULT=$(echo "{\"transcript_path\": \"$TEST_DIR/transcript-message.jsonl\"}" | python3 "$TODO_CHECKER" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Alternative message format handled"
else
    fail "Alternative message format" "exit 0" "exit $EXIT_CODE"
fi

# ========================================
# Test Group 4: Edge Cases
# ========================================
echo ""
echo "Test Group 4: Edge Cases"
echo ""

# Test 14: Todo with missing status field
echo "Test 14: Todo with missing status"
cat > "$TEST_DIR/transcript-no-status.jsonl" << 'EOF'
{"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "TodoWrite", "input": {"todos": [{"content": "Task without status"}]}}]}}
EOF
set +e
RESULT=$(echo "{\"transcript_path\": \"$TEST_DIR/transcript-no-status.jsonl\"}" | python3 "$TODO_CHECKER" 2>&1)
EXIT_CODE=$?
set -e
# Missing status should be treated as incomplete (not "completed")
if [[ $EXIT_CODE -eq 1 ]]; then
    pass "Missing status treated as incomplete"
else
    fail "Missing status handling" "exit 1 (incomplete)" "exit $EXIT_CODE"
fi

# Test 15: Todo with empty content
echo "Test 15: Todo with empty content"
cat > "$TEST_DIR/transcript-empty-content.jsonl" << 'EOF'
{"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "TodoWrite", "input": {"todos": [{"content": "", "status": "pending"}]}}]}}
EOF
set +e
RESULT=$(echo "{\"transcript_path\": \"$TEST_DIR/transcript-empty-content.jsonl\"}" | python3 "$TODO_CHECKER" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 1 ]]; then
    pass "Empty content todo handled (still incomplete)"
else
    fail "Empty content handling" "exit 1" "exit $EXIT_CODE"
fi

# Test 16: Unicode in todo content
echo "Test 16: Unicode in todo content"
cat > "$TEST_DIR/transcript-unicode.jsonl" << 'EOF'
{"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "TodoWrite", "input": {"todos": [{"content": "Task with unicode", "status": "completed"}]}}]}}
EOF
set +e
RESULT=$(echo "{\"transcript_path\": \"$TEST_DIR/transcript-unicode.jsonl\"}" | python3 "$TODO_CHECKER" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Unicode content handled"
else
    fail "Unicode content" "exit 0" "exit $EXIT_CODE"
fi

# ========================================
# Test Group 5: New Task System (File-based)
# ========================================
# The new Task system reads task state from ~/.claude/tasks/<session_id>/ directory
# (the authoritative source), NOT from transcript parsing (which causes ghost tasks).
echo ""
echo "Test Group 5: New Task System (File-based)"
echo ""

# Create mock tasks base directory
MOCK_TASKS_BASE="$TEST_DIR/mock-tasks"
mkdir -p "$MOCK_TASKS_BASE"

# Test 17: Single pending task (no status field defaults to pending)
echo "Test 17: Single pending task"
MOCK_SESSION_17="session-17"
mkdir -p "$MOCK_TASKS_BASE/$MOCK_SESSION_17"
cat > "$MOCK_TASKS_BASE/$MOCK_SESSION_17/task-1.json" << 'EOF'
{"subject": "Implement feature X", "description": "Full description here"}
EOF
set +e
RESULT=$(echo "{\"session_id\": \"$MOCK_SESSION_17\", \"tasks_base_dir\": \"$MOCK_TASKS_BASE\"}" | python3 "$TODO_CHECKER" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 1 ]]; then
    pass "Single pending task exits 1"
else
    fail "Single pending task" "exit 1" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 18: Single completed task
echo "Test 18: Single completed task"
MOCK_SESSION_18="session-18"
mkdir -p "$MOCK_TASKS_BASE/$MOCK_SESSION_18"
cat > "$MOCK_TASKS_BASE/$MOCK_SESSION_18/task-1.json" << 'EOF'
{"subject": "Implement feature X", "description": "Full description here", "status": "completed"}
EOF
set +e
RESULT=$(echo "{\"session_id\": \"$MOCK_SESSION_18\", \"tasks_base_dir\": \"$MOCK_TASKS_BASE\"}" | python3 "$TODO_CHECKER" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Single completed task exits 0"
else
    fail "Single completed task" "exit 0" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 19: Task with in_progress status (still incomplete)
echo "Test 19: Task with in_progress status"
MOCK_SESSION_19="session-19"
mkdir -p "$MOCK_TASKS_BASE/$MOCK_SESSION_19"
cat > "$MOCK_TASKS_BASE/$MOCK_SESSION_19/task-1.json" << 'EOF'
{"subject": "Implement feature X", "status": "in_progress"}
EOF
set +e
RESULT=$(echo "{\"session_id\": \"$MOCK_SESSION_19\", \"tasks_base_dir\": \"$MOCK_TASKS_BASE\"}" | python3 "$TODO_CHECKER" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 1 ]]; then
    pass "Task with in_progress status exits 1"
else
    fail "Task with in_progress status" "exit 1" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 20: Multiple tasks, one incomplete
echo "Test 20: Multiple tasks, one incomplete"
MOCK_SESSION_20="session-20"
mkdir -p "$MOCK_TASKS_BASE/$MOCK_SESSION_20"
cat > "$MOCK_TASKS_BASE/$MOCK_SESSION_20/task-1.json" << 'EOF'
{"subject": "Task A", "status": "completed"}
EOF
cat > "$MOCK_TASKS_BASE/$MOCK_SESSION_20/task-2.json" << 'EOF'
{"subject": "Task B", "status": "pending"}
EOF
set +e
RESULT=$(echo "{\"session_id\": \"$MOCK_SESSION_20\", \"tasks_base_dir\": \"$MOCK_TASKS_BASE\"}" | python3 "$TODO_CHECKER" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 1 ]]; then
    pass "Multiple tasks with one incomplete exits 1"
else
    fail "Multiple tasks with one incomplete" "exit 1" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 21: Multiple tasks, all completed
echo "Test 21: Multiple tasks, all completed"
MOCK_SESSION_21="session-21"
mkdir -p "$MOCK_TASKS_BASE/$MOCK_SESSION_21"
cat > "$MOCK_TASKS_BASE/$MOCK_SESSION_21/task-1.json" << 'EOF'
{"subject": "Task A", "status": "completed"}
EOF
cat > "$MOCK_TASKS_BASE/$MOCK_SESSION_21/task-2.json" << 'EOF'
{"subject": "Task B", "status": "completed"}
EOF
set +e
RESULT=$(echo "{\"session_id\": \"$MOCK_SESSION_21\", \"tasks_base_dir\": \"$MOCK_TASKS_BASE\"}" | python3 "$TODO_CHECKER" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Multiple tasks all completed exits 0"
else
    fail "Multiple tasks all completed" "exit 0" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 22: Deleted task is ignored (not incomplete)
echo "Test 22: Deleted task is ignored"
MOCK_SESSION_22="session-22"
mkdir -p "$MOCK_TASKS_BASE/$MOCK_SESSION_22"
cat > "$MOCK_TASKS_BASE/$MOCK_SESSION_22/task-1.json" << 'EOF'
{"subject": "Deleted task", "status": "deleted"}
EOF
set +e
RESULT=$(echo "{\"session_id\": \"$MOCK_SESSION_22\", \"tasks_base_dir\": \"$MOCK_TASKS_BASE\"}" | python3 "$TODO_CHECKER" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Deleted task is ignored (exits 0)"
else
    fail "Deleted task is ignored" "exit 0" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 23: Mix of legacy TodoWrite and new Task system
echo "Test 23: Mix of TodoWrite (transcript) and Task (file)"
MOCK_SESSION_23="session-23"
mkdir -p "$MOCK_TASKS_BASE/$MOCK_SESSION_23"
cat > "$MOCK_TASKS_BASE/$MOCK_SESSION_23/task-1.json" << 'EOF'
{"subject": "New task", "status": "pending"}
EOF
cat > "$TEST_DIR/transcript-mixed.jsonl" << 'EOF'
{"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "TodoWrite", "input": {"todos": [{"content": "Legacy task", "status": "completed"}]}}]}}
EOF
set +e
RESULT=$(echo "{\"session_id\": \"$MOCK_SESSION_23\", \"tasks_base_dir\": \"$MOCK_TASKS_BASE\", \"transcript_path\": \"$TEST_DIR/transcript-mixed.jsonl\"}" | python3 "$TODO_CHECKER" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 1 ]]; then
    pass "Mixed TodoWrite and Task - incomplete Task detected"
else
    fail "Mixed TodoWrite and Task" "exit 1 (Task incomplete)" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 24: Output includes Task ID for new Task system
echo "Test 24: Output includes Task ID"
if echo "$RESULT" | grep -q "Task #"; then
    pass "Output includes Task ID marker"
else
    fail "Output includes Task ID" "Task # in output" "$RESULT"
fi

# Test 25: Non-existent session directory (no tasks)
echo "Test 25: Non-existent session directory"
set +e
RESULT=$(echo "{\"session_id\": \"nonexistent-session\", \"tasks_base_dir\": \"$MOCK_TASKS_BASE\"}" | python3 "$TODO_CHECKER" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Non-existent session directory exits 0"
else
    fail "Non-existent session directory" "exit 0" "exit $EXIT_CODE"
fi

# ========================================
# Summary
# ========================================
echo ""
echo "========================================"
echo "Test Summary"
echo "========================================"
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo ""
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo ""
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
