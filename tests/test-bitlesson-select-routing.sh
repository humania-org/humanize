#!/bin/bash
# Tests for bitlesson-select.sh provider routing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"
BITLESSON_SELECT="$PROJECT_ROOT/scripts/bitlesson-select.sh"
# Keep PATH isolation strict in missing-binary tests to avoid picking up
# real codex/claude from user-local directories (e.g. ~/.nvm, ~/.local/bin).
SAFE_BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

echo "=========================================="
echo "Bitlesson Select Routing Tests"
echo "=========================================="
echo ""

# Helper: create a mock bitlesson.md with required content
create_mock_bitlesson() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/bitlesson.md" <<'EOF'
# BitLesson Knowledge Base
## Entries
<!-- placeholder -->
EOF
}

# Helper: create a mock codex binary that outputs valid bitlesson-selector format
create_mock_codex() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/codex" <<'EOF'
#!/bin/bash
# Mock codex that outputs valid bitlesson-selector format
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
#!/bin/bash
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
create_mock_bitlesson "$TEST_DIR"
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
    --bitlesson-file "$TEST_DIR/bitlesson.md" 2>/dev/null) || exit_code=$?

if [[ $exit_code -eq 0 ]] && echo "$result" | grep -q "LESSON_IDS:"; then
    pass "Codex branch: gpt-* model routes to codex (produces LESSON_IDS output)"
else
    fail "Codex branch: gpt-* model routes to codex" "LESSON_IDS: in output (exit 0)" "exit=$exit_code, output=$result"
fi

# ========================================
# Test 2: Claude branch chosen for haiku model
# ========================================
echo ""
echo "--- Test 2: haiku model routes to claude ---"
echo ""

setup_test_dir
create_mock_bitlesson "$TEST_DIR"
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
    --bitlesson-file "$TEST_DIR/bitlesson.md" 2>/dev/null) || exit_code=$?

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
create_mock_bitlesson "$TEST_DIR"
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
    --bitlesson-file "$TEST_DIR/bitlesson.md" 2>/dev/null) || exit_code=$?

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
create_mock_bitlesson "$TEST_DIR"
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
    --bitlesson-file "$TEST_DIR/bitlesson.md" 2>/dev/null) || exit_code=$?

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
create_mock_bitlesson "$TEST_DIR"
mkdir -p "$TEST_DIR/.humanize"
printf '{"bitlesson_model": "unknown-xyz-model"}' > "$TEST_DIR/.humanize/config.json"

exit_code=0
stderr_out=""
stderr_out=$(CLAUDE_PROJECT_DIR="$TEST_DIR" XDG_CONFIG_HOME="$TEST_DIR/no-user" \
    bash "$BITLESSON_SELECT" \
    --task "Fix a bug" \
    --paths "scripts/bitlesson-select.sh" \
    --bitlesson-file "$TEST_DIR/bitlesson.md" 2>&1 >/dev/null) || exit_code=$?

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
create_mock_bitlesson "$TEST_DIR"
mkdir -p "$TEST_DIR/.humanize"
printf '{"bitlesson_model": "gpt-4o"}' > "$TEST_DIR/.humanize/config.json"
# Use a bin dir that contains a stub claude but NOT codex.
NO_CODEX_BIN="$TEST_DIR/no-codex-bin"
mkdir -p "$NO_CODEX_BIN"
# Provide a stub claude so it does not interfere with the codex check
cat > "$NO_CODEX_BIN/claude" <<'EOF'
#!/bin/bash
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
    --bitlesson-file "$TEST_DIR/bitlesson.md" 2>&1 >/dev/null) || exit_code=$?

if [[ $exit_code -ne 0 ]] && echo "$stderr_out" | grep -qi "codex"; then
    pass "Codex branch: missing codex binary exits non-zero with informative error"
else
    fail "Codex branch: missing codex binary exits non-zero with informative error" "non-zero exit + 'codex' in stderr" "exit=$exit_code, stderr=$stderr_out"
fi

# ========================================
# Test 7: Claude branch missing claude binary exits non-zero
# ========================================
echo ""
echo "--- Test 7: haiku model with missing claude binary exits non-zero ---"
echo ""

setup_test_dir
create_mock_bitlesson "$TEST_DIR"
mkdir -p "$TEST_DIR/.humanize"
printf '{"bitlesson_model": "haiku"}' > "$TEST_DIR/.humanize/config.json"
# Use a bin dir that contains a stub codex but NOT claude.
NO_CLAUDE_BIN="$TEST_DIR/no-claude-bin"
mkdir -p "$NO_CLAUDE_BIN"
# Provide a stub codex so it does not interfere with the claude check
cat > "$NO_CLAUDE_BIN/codex" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$NO_CLAUDE_BIN/codex"

exit_code=0
stderr_out=""
stderr_out=$(CLAUDE_PROJECT_DIR="$TEST_DIR" XDG_CONFIG_HOME="$TEST_DIR/no-user" \
    PATH="$NO_CLAUDE_BIN:$SAFE_BASE_PATH" \
    bash "$BITLESSON_SELECT" \
    --task "Fix a bug" \
    --paths "scripts/bitlesson-select.sh" \
    --bitlesson-file "$TEST_DIR/bitlesson.md" 2>&1 >/dev/null) || exit_code=$?

if [[ $exit_code -ne 0 ]] && echo "$stderr_out" | grep -qi "claude"; then
    pass "Claude branch: missing claude binary exits non-zero with informative error"
else
    fail "Claude branch: missing claude binary exits non-zero with informative error" "non-zero exit + 'claude' in stderr" "exit=$exit_code, stderr=$stderr_out"
fi

# ========================================
# Summary
# ========================================

print_test_summary "Bitlesson Select Routing Test Summary"
