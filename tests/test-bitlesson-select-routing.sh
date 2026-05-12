#!/usr/bin/env bash
# Tests for bitlesson-select.sh provider routing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"
BITLESSON_SELECT="$PROJECT_ROOT/scripts/bitlesson-select.sh"
# Keep PATH isolation strict in missing-binary tests to avoid picking up
# real codex/claude from user-local directories (e.g. ~/.nvm, ~/.local/bin).
# On NixOS, the shell toolchain itself lives under /run/current-system/sw/bin.
SAFE_BASE_PATH="/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin"

echo "=========================================="
echo "Bitlesson Select Routing Tests"
echo "=========================================="
echo ""

# Helper: create a mock .humanize/bitlesson.md with required content
create_mock_bitlesson() {
    local dir="$1"
    mkdir -p "$dir/.humanize"
    cat > "$dir/.humanize/bitlesson.md" <<'EOF'
# BitLesson Knowledge Base
## Entries
<!-- placeholder -->
EOF
}

create_real_bitlesson() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/bitlesson.md" <<'EOF'
# BitLesson Knowledge Base
## Entries

## Lesson: Avoid tracker drift
Lesson ID: BL-20260315-tracker-drift
Scope: goal-tracker.md
Problem Description: Tracker diverges from actual task status.
Root Cause: Status rows are not updated after verification.
Solution: Update tracker rows immediately after each verification step.
Constraints: Keep tracker edits minimal.
Validation Evidence: Verified in test fixture.
Source Rounds: 0
EOF
}

create_real_humanize_bitlesson() {
    local dir="$1"
    mkdir -p "$dir/.humanize"
    cat > "$dir/.humanize/bitlesson.md" <<'EOF'
# BitLesson Knowledge Base
## Entries

## Lesson: Avoid tracker drift
Lesson ID: BL-20260315-tracker-drift
Scope: goal-tracker.md
Problem Description: Tracker diverges from actual task status.
Root Cause: Status rows are not updated after verification.
Solution: Update tracker rows immediately after each verification step.
Constraints: Keep tracker edits minimal.
Validation Evidence: Verified in test fixture.
Source Rounds: 0
EOF
}

# Helper: create a mock codex binary that outputs valid bitlesson-selector format
create_mock_codex() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/codex" <<'EOF'
#!/usr/bin/env bash
# Mock codex that only reads prompt content from stdin when invoked with trailing '-'
if [[ "${*: -1}" != "-" ]]; then
    echo "mock codex expected trailing '-' to read prompt from stdin" >&2
    exit 9
fi

stdin_content=$(cat)
if [[ -z "$stdin_content" ]]; then
    echo "mock codex expected non-empty stdin prompt" >&2
    exit 10
fi

cat <<'OUT'
LESSON_IDS: NONE
RATIONALE: No matching lessons found (mock codex).
OUT
EOF
    chmod +x "$bin_dir/codex"
}

# Helper: create a mock codex binary that records stdin for assertions
create_recording_mock_codex() {
    local bin_dir="$1"
    local stdin_file="$2"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/codex" <<EOF
#!/usr/bin/env bash
if [[ "\${*: -1}" != "-" ]]; then
    echo "mock codex expected trailing '-' to read prompt from stdin" >&2
    exit 9
fi

cat > "$stdin_file"
if [[ ! -s "$stdin_file" ]]; then
    echo "mock codex expected non-empty stdin prompt" >&2
    exit 10
fi

cat <<'OUT'
LESSON_IDS: NONE
RATIONALE: No matching lessons found (mock codex).
OUT
EOF
    chmod +x "$bin_dir/codex"
}

# Helper: create a mock claude binary that outputs valid bitlesson-selector format
create_mock_claude() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/claude" <<'EOF'
#!/usr/bin/env bash
# Mock claude that outputs valid bitlesson-selector format
# Consume stdin so the pipe does not break
cat > /dev/null
cat <<'OUT'
LESSON_IDS: NONE
RATIONALE: No matching lessons found (mock claude).
OUT
EOF
    chmod +x "$bin_dir/claude"
}

# ========================================
# Test 1: Codex branch chosen for gpt-* model
# ========================================
echo "--- Test 1: gpt-* model routes to codex ---"
echo ""

setup_test_dir
create_real_humanize_bitlesson "$TEST_DIR"
BIN_DIR="$TEST_DIR/bin"
create_mock_codex "$BIN_DIR"
mkdir -p "$TEST_DIR/.humanize"
printf '{"bitlesson_model": "gpt-4o"}' > "$TEST_DIR/.humanize/config.json"

result=""
exit_code=0
result=$(CLAUDE_PROJECT_DIR="$TEST_DIR" XDG_CONFIG_HOME="$TEST_DIR/no-user" \
    PATH="$BIN_DIR:$PATH" \
    bash "$BITLESSON_SELECT" \
    --task "Fix a bug" \
    --paths "scripts/bitlesson-select.sh" \
    --bitlesson-file "$TEST_DIR/.humanize/bitlesson.md" 2>/dev/null) || exit_code=$?

if [[ $exit_code -eq 0 ]] && echo "$result" | grep -q "LESSON_IDS:"; then
    pass "Codex branch: gpt-* model routes to codex (produces LESSON_IDS output)"
else
    fail "Codex branch: gpt-* model routes to codex" "LESSON_IDS: in output (exit 0)" "exit=$exit_code, output=$result"
fi

# ========================================
# Test 1b: Codex branch passes '-' and consumes stdin prompt
# ========================================
echo ""
echo "--- Test 1b: gpt-* codex path passes stdin prompt via trailing '-' ---"
echo ""

setup_test_dir
create_real_humanize_bitlesson "$TEST_DIR"
BIN_DIR="$TEST_DIR/bin"
STDIN_FILE="$TEST_DIR/codex-stdin.txt"
create_recording_mock_codex "$BIN_DIR" "$STDIN_FILE"
mkdir -p "$TEST_DIR/.humanize"
printf '{"bitlesson_model": "gpt-4o"}' > "$TEST_DIR/.humanize/config.json"

result=""
exit_code=0
result=$(CLAUDE_PROJECT_DIR="$TEST_DIR" XDG_CONFIG_HOME="$TEST_DIR/no-user" \
    PATH="$BIN_DIR:$PATH" \
    bash "$BITLESSON_SELECT" \
    --task "Fix a bug" \
    --paths "scripts/bitlesson-select.sh" \
    --bitlesson-file "$TEST_DIR/.humanize/bitlesson.md" 2>/dev/null) || exit_code=$?

if [[ $exit_code -eq 0 ]] \
    && [[ -s "$STDIN_FILE" ]] \
    && grep -q "Sub-task description:" "$STDIN_FILE" \
    && grep -q "Fix a bug" "$STDIN_FILE"; then
    pass "Codex branch: selector passes trailing '-' and prompt content through stdin"
else
    fail "Codex branch: selector passes trailing '-' and prompt content through stdin" \
        "exit=0 with recorded stdin prompt" \
        "exit=$exit_code, output=$result, stdin=$(cat "$STDIN_FILE" 2>/dev/null || true)"
fi

# ========================================
# Test 2: Claude branch chosen for haiku model
# ========================================
echo ""
echo "--- Test 2: haiku model routes to claude ---"
echo ""

setup_test_dir
create_real_humanize_bitlesson "$TEST_DIR"
BIN_DIR="$TEST_DIR/bin"
create_mock_claude "$BIN_DIR"
mkdir -p "$TEST_DIR/.humanize"
printf '{"bitlesson_model": "haiku"}' > "$TEST_DIR/.humanize/config.json"

result=""
exit_code=0
result=$(CLAUDE_PROJECT_DIR="$TEST_DIR" XDG_CONFIG_HOME="$TEST_DIR/no-user" \
    PATH="$BIN_DIR:$PATH" \
    bash "$BITLESSON_SELECT" \
    --task "Fix a bug" \
    --paths "scripts/bitlesson-select.sh" \
    --bitlesson-file "$TEST_DIR/.humanize/bitlesson.md" 2>/dev/null) || exit_code=$?

if [[ $exit_code -eq 0 ]] && echo "$result" | grep -q "LESSON_IDS:"; then
    pass "Claude branch: haiku model routes to claude (produces LESSON_IDS output)"
else
    fail "Claude branch: haiku model routes to claude" "LESSON_IDS: in output (exit 0)" "exit=$exit_code, output=$result"
fi

# ========================================
# Test 3: Claude branch chosen for sonnet model
# ========================================
echo ""
echo "--- Test 3: sonnet model routes to claude ---"
echo ""

setup_test_dir
create_real_humanize_bitlesson "$TEST_DIR"
BIN_DIR="$TEST_DIR/bin"
create_mock_claude "$BIN_DIR"
mkdir -p "$TEST_DIR/.humanize"
printf '{"bitlesson_model": "claude-3-5-sonnet-20241022"}' > "$TEST_DIR/.humanize/config.json"

result=""
exit_code=0
result=$(CLAUDE_PROJECT_DIR="$TEST_DIR" XDG_CONFIG_HOME="$TEST_DIR/no-user" \
    PATH="$BIN_DIR:$PATH" \
    bash "$BITLESSON_SELECT" \
    --task "Refactor logic" \
    --paths "scripts/bitlesson-select.sh" \
    --bitlesson-file "$TEST_DIR/.humanize/bitlesson.md" 2>/dev/null) || exit_code=$?

if [[ $exit_code -eq 0 ]] && echo "$result" | grep -q "LESSON_IDS:"; then
    pass "Claude branch: sonnet model routes to claude (produces LESSON_IDS output)"
else
    fail "Claude branch: sonnet model routes to claude" "LESSON_IDS: in output (exit 0)" "exit=$exit_code, output=$result"
fi

# ========================================
# Test 4: Claude branch chosen for opus model (case-insensitive)
# ========================================
echo ""
echo "--- Test 4: OPUS (uppercase) model routes to claude ---"
echo ""

setup_test_dir
create_real_humanize_bitlesson "$TEST_DIR"
BIN_DIR="$TEST_DIR/bin"
create_mock_claude "$BIN_DIR"
mkdir -p "$TEST_DIR/.humanize"
printf '{"bitlesson_model": "claude-3-OPUS-20240229"}' > "$TEST_DIR/.humanize/config.json"

result=""
exit_code=0
result=$(CLAUDE_PROJECT_DIR="$TEST_DIR" XDG_CONFIG_HOME="$TEST_DIR/no-user" \
    PATH="$BIN_DIR:$PATH" \
    bash "$BITLESSON_SELECT" \
    --task "Write docs" \
    --paths "scripts/bitlesson-select.sh" \
    --bitlesson-file "$TEST_DIR/.humanize/bitlesson.md" 2>/dev/null) || exit_code=$?

if [[ $exit_code -eq 0 ]] && echo "$result" | grep -q "LESSON_IDS:"; then
    pass "Claude branch: OPUS (uppercase) model routes to claude (case-insensitive match)"
else
    fail "Claude branch: OPUS (uppercase) model routes to claude" "LESSON_IDS: in output (exit 0)" "exit=$exit_code, output=$result"
fi

# ========================================
# Test 5: Unknown model exits non-zero with clear error message
# ========================================
echo ""
echo "--- Test 5: Unknown model exits non-zero with error ---"
echo ""

setup_test_dir
create_real_humanize_bitlesson "$TEST_DIR"
mkdir -p "$TEST_DIR/.humanize"
printf '{"bitlesson_model": "unknown-xyz-model"}' > "$TEST_DIR/.humanize/config.json"

exit_code=0
stderr_out=""
stderr_out=$(CLAUDE_PROJECT_DIR="$TEST_DIR" XDG_CONFIG_HOME="$TEST_DIR/no-user" \
    bash "$BITLESSON_SELECT" \
    --task "Fix a bug" \
    --paths "scripts/bitlesson-select.sh" \
    --bitlesson-file "$TEST_DIR/.humanize/bitlesson.md" 2>&1 >/dev/null) || exit_code=$?

if [[ $exit_code -ne 0 ]] && echo "$stderr_out" | grep -qiE "unknown|error"; then
    pass "Unknown model: exits non-zero with clear error message"
else
    fail "Unknown model: exits non-zero with clear error message" "non-zero exit + error message" "exit=$exit_code, stderr=$stderr_out"
fi

# ========================================
# Test 6: Codex branch missing codex binary exits non-zero
# ========================================
echo ""
echo "--- Test 6: gpt-* model with missing codex binary exits non-zero ---"
echo ""

setup_test_dir
create_real_humanize_bitlesson "$TEST_DIR"
mkdir -p "$TEST_DIR/.humanize"
printf '{"bitlesson_model": "gpt-4o"}' > "$TEST_DIR/.humanize/config.json"
# Use a bin dir that contains a stub claude but NOT codex.
NO_CODEX_BIN="$TEST_DIR/no-codex-bin"
mkdir -p "$NO_CODEX_BIN"
# Provide a stub claude so it does not interfere with the codex check
cat > "$NO_CODEX_BIN/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$NO_CODEX_BIN/claude"

exit_code=0
stderr_out=""
stderr_out=$(CLAUDE_PROJECT_DIR="$TEST_DIR" XDG_CONFIG_HOME="$TEST_DIR/no-user" \
    PATH="$NO_CODEX_BIN:$SAFE_BASE_PATH" \
    bash "$BITLESSON_SELECT" \
    --task "Fix a bug" \
    --paths "scripts/bitlesson-select.sh" \
    --bitlesson-file "$TEST_DIR/.humanize/bitlesson.md" 2>&1 >/dev/null) || exit_code=$?

if [[ $exit_code -ne 0 ]] && echo "$stderr_out" | grep -qi "codex"; then
    pass "Codex branch: missing codex binary exits non-zero with informative error"
else
    fail "Codex branch: missing codex binary exits non-zero with informative error" "non-zero exit + 'codex' in stderr" "exit=$exit_code, stderr=$stderr_out"
fi

# ========================================
# Test 7: Claude model falls back to codex when claude binary is missing
# ========================================
echo ""
echo "--- Test 7: haiku model falls back to codex when claude binary is missing ---"
echo ""

setup_test_dir
create_real_humanize_bitlesson "$TEST_DIR"
mkdir -p "$TEST_DIR/.humanize"
printf '{"bitlesson_model": "haiku"}' > "$TEST_DIR/.humanize/config.json"
# Use a bin dir that contains a stub codex but NOT claude.
NO_CLAUDE_BIN="$TEST_DIR/no-claude-bin"
mkdir -p "$NO_CLAUDE_BIN"
# Provide a stub codex that produces valid bitlesson output (proves fallback worked)
cat > "$NO_CLAUDE_BIN/codex" <<'MOCK_EOF'
#!/usr/bin/env bash
echo "LESSON_IDS: NONE"
echo "RATIONALE: No relevant lessons for this task."
MOCK_EOF
chmod +x "$NO_CLAUDE_BIN/codex"

exit_code=0
stdout_out=""
stdout_out=$(CLAUDE_PROJECT_DIR="$TEST_DIR" XDG_CONFIG_HOME="$TEST_DIR/no-user" \
    PATH="$NO_CLAUDE_BIN:$SAFE_BASE_PATH" \
    bash "$BITLESSON_SELECT" \
    --task "Fix a bug" \
    --paths "scripts/bitlesson-select.sh" \
    --bitlesson-file "$TEST_DIR/.humanize/bitlesson.md" 2>/dev/null) || exit_code=$?

if [[ $exit_code -eq 0 ]] && echo "$stdout_out" | grep -q "LESSON_IDS: NONE"; then
    pass "Claude model falls back to codex when claude binary is missing"
else
    fail "Claude model falls back to codex when claude binary is missing" "exit=0 + LESSON_IDS in stdout" "exit=$exit_code, stdout=$stdout_out"
fi

# ========================================
# Summary
# ========================================

echo ""
echo "--- Test 8: codex-only provider mode forces codex routing ---"
echo ""

setup_test_dir
create_real_bitlesson "$TEST_DIR"
mkdir -p "$TEST_DIR/.humanize"
printf '{"bitlesson_model": "haiku", "codex_model": "gpt-5.5", "provider_mode": "codex-only"}' > "$TEST_DIR/.humanize/config.json"
FALLBACK_BIN="$TEST_DIR/fallback-bin"
create_mock_codex "$FALLBACK_BIN"

exit_code=0
stdout_out=""
stdout_out=$(CLAUDE_PROJECT_DIR="$TEST_DIR" XDG_CONFIG_HOME="$TEST_DIR/no-user" \
    PATH="$FALLBACK_BIN:$PATH" \
    bash "$BITLESSON_SELECT" \
    --task "Initialize tracker" \
    --paths "plans/plan.md" \
    --bitlesson-file "$TEST_DIR/bitlesson.md" 2>/dev/null) || exit_code=$?

if [[ $exit_code -eq 0 ]] && echo "$stdout_out" | grep -q "mock codex"; then
    pass "codex-only provider mode forces codex routing"
else
    fail "codex-only provider mode forces codex routing" "exit=0 + mock codex rationale" "exit=$exit_code, stdout=$stdout_out"
fi

echo ""
echo "--- Test 9: Placeholder BitLesson file short-circuits to NONE ---"
echo ""

setup_test_dir
create_mock_bitlesson "$TEST_DIR"
mkdir -p "$TEST_DIR/.humanize"
printf '{"bitlesson_model": "gpt-5.5"}' > "$TEST_DIR/.humanize/config.json"

exit_code=0
stdout_out=""
stdout_out=$(CLAUDE_PROJECT_DIR="$TEST_DIR" XDG_CONFIG_HOME="$TEST_DIR/no-user" \
    PATH="$SAFE_BASE_PATH" \
    bash "$BITLESSON_SELECT" \
    --task "Any task" \
    --paths "README.md" \
    --bitlesson-file "$TEST_DIR/.humanize/bitlesson.md" 2>/dev/null) || exit_code=$?

if [[ $exit_code -eq 0 ]] && echo "$stdout_out" | grep -q "LESSON_IDS: NONE" && echo "$stdout_out" | grep -q "no recorded lessons"; then
    pass "Placeholder BitLesson file returns NONE without invoking a model"
else
    fail "Placeholder BitLesson file returns NONE without invoking a model" "exit=0 + NONE rationale" "exit=$exit_code, stdout=$stdout_out"
fi

echo ""
echo "--- Test 10: Codex selector disables hooks and avoids full-auto ---"
echo ""

setup_test_dir
create_real_bitlesson "$TEST_DIR"
mkdir -p "$TEST_DIR/.humanize"
printf '{"bitlesson_model": "gpt-5.5"}' > "$TEST_DIR/.humanize/config.json"
CAPTURE_BIN="$TEST_DIR/capture-bin"
mkdir -p "$CAPTURE_BIN"
cat > "$CAPTURE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
# Respond to help probes with supported flags
for arg in "$@"; do
    if [[ "$arg" == "--help" ]]; then
        echo "  --disable <feature>   Disable a feature"
        echo "  --skip-git-repo-check Skip git repo check"
        echo "  --ephemeral           Ephemeral mode"
        exit 0
    fi
done
printf '%s\n' "$@" > "${TEST_CAPTURE_ARGS:?}"
cat > /dev/null
cat <<'OUT'
LESSON_IDS: BL-20260315-tracker-drift
RATIONALE: The tracker lesson directly matches the task.
OUT
EOF
chmod +x "$CAPTURE_BIN/codex"

CAPTURE_ARGS="$TEST_DIR/codex-args.txt"
exit_code=0
stdout_out=""
stdout_out=$(TEST_CAPTURE_ARGS="$CAPTURE_ARGS" CLAUDE_PROJECT_DIR="$TEST_DIR" XDG_CONFIG_HOME="$TEST_DIR/no-user" \
    PATH="$CAPTURE_BIN:$SAFE_BASE_PATH" \
    bash "$BITLESSON_SELECT" \
    --task "Update the goal tracker after verification" \
    --paths "goal-tracker.md" \
    --bitlesson-file "$TEST_DIR/bitlesson.md" 2>/dev/null) || exit_code=$?

captured_args="$(cat "$CAPTURE_ARGS")"

if [[ $exit_code -eq 0 ]] \
    && echo "$stdout_out" | grep -q "BL-20260315-tracker-drift" \
    && echo "$captured_args" | grep -q -- '--disable' \
    && echo "$captured_args" | grep -q -- 'hooks' \
    && echo "$captured_args" | grep -q -- '--skip-git-repo-check' \
    && echo "$captured_args" | grep -q -- '--ephemeral' \
    && echo "$captured_args" | grep -q -- 'read-only' \
    && ! echo "$captured_args" | grep -q -- '--full-auto'; then
    pass "Codex selector runs as a direct helper without hooks or full-auto"
else
    fail "Codex selector runs as a direct helper without hooks or full-auto" \
        "exit=0 + direct-helper args" \
        "exit=$exit_code, stdout=$stdout_out, args=$captured_args"
fi

print_test_summary "Bitlesson Select Routing Test Summary"
