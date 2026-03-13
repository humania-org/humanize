#!/bin/bash
#
# Tests for scripts/statusline.sh
#
# Covers RLCR repo-root resolution, fast-mode precedence, and mixed
# legacy/session-aware loop selection for the statusline display.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

strip_ansi() {
    local esc=$'\033'
    sed "s/${esc}\\[[0-9;]*m//g"
}

run_statusline_plain() {
    local cwd="$1"
    local session_id="${2:-}"
    local input_json

    if [[ -n "$session_id" ]]; then
        input_json=$(jq -nc --arg cwd "$cwd" --arg session_id "$session_id" \
            '{model: {display_name: "Claude"}, cwd: $cwd, session_id: $session_id, context_window: {used_percentage: 42}}')
    else
        input_json=$(jq -nc --arg cwd "$cwd" \
            '{model: {display_name: "Claude"}, cwd: $cwd, context_window: {used_percentage: 42}}')
    fi

    printf '%s\n' "$input_json" | HOME="$TEST_DIR/home" bash "$PROJECT_ROOT/scripts/statusline.sh" 2>/dev/null | strip_ansi
}

assert_statusline_rlcr() {
    local test_name="$1"
    local expected_status="$2"
    local plain_output="$3"

    if echo "$plain_output" | grep -q "RLCR: $expected_status"; then
        pass "$test_name"
    else
        fail "$test_name" "output containing RLCR: $expected_status" "$plain_output"
    fi
}

assert_statusline_fast() {
    local test_name="$1"
    local expected_status="$2"
    local plain_output="$3"

    if echo "$plain_output" | grep -q "Fast: $expected_status"; then
        pass "$test_name"
    else
        fail "$test_name" "output containing Fast: $expected_status" "$plain_output"
    fi
}

echo "=========================================="
echo "Statusline Tests"
echo "=========================================="
echo ""

setup_test_dir
mkdir -p "$TEST_DIR/home"

# ========================================
# Test: RLCR status resolves from repo root
# ========================================

init_test_git_repo "$TEST_DIR/repo"
mkdir -p "$TEST_DIR/repo/subdir/nested"
mkdir -p "$TEST_DIR/repo/.humanize/rlcr/2026-01-19_00-00-00"

cat > "$TEST_DIR/repo/.humanize/rlcr/2026-01-19_00-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 10
---
EOF

PLAIN_OUTPUT=$(run_statusline_plain "$TEST_DIR/repo/subdir/nested")
assert_statusline_rlcr \
    "statusline resolves RLCR state from git repo root when cwd is nested" \
    "Active" \
    "$PLAIN_OUTPUT"

# ========================================
# Test: project-local fast mode overrides global fast mode
# ========================================

init_test_git_repo "$TEST_DIR/repo-fast-mode"
mkdir -p "$TEST_DIR/repo-fast-mode/subdir"
mkdir -p "$TEST_DIR/repo-fast-mode/.claude"
mkdir -p "$TEST_DIR/home/.claude"

cat > "$TEST_DIR/repo-fast-mode/.claude/settings.json" << 'EOF'
{
  "fastMode": false
}
EOF

cat > "$TEST_DIR/home/.claude/settings.json" << 'EOF'
{
  "fastMode": true
}
EOF

PLAIN_OUTPUT=$(run_statusline_plain "$TEST_DIR/repo-fast-mode/subdir")
assert_statusline_fast \
    "statusline prefers project-local fast mode over global settings" \
    "Off" \
    "$PLAIN_OUTPUT"

# ========================================
# Test: newer session-unaware loop is not hidden by older session-aware loop
# ========================================

init_test_git_repo "$TEST_DIR/repo-mixed"
mkdir -p "$TEST_DIR/repo-mixed/.humanize/rlcr/2026-01-19_00-00-00"
mkdir -p "$TEST_DIR/repo-mixed/.humanize/rlcr/2026-01-20_00-00-00"

cat > "$TEST_DIR/repo-mixed/.humanize/rlcr/2026-01-19_00-00-00/complete-state.md" << 'EOF'
---
session_id: older-session
current_round: 3
max_iterations: 10
---
EOF

cat > "$TEST_DIR/repo-mixed/.humanize/rlcr/2026-01-20_00-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 10
---
EOF

PLAIN_OUTPUT=$(run_statusline_plain "$TEST_DIR/repo-mixed")
assert_statusline_rlcr \
    "statusline prefers newest session-unaware loop when no session filter is provided" \
    "Active" \
    "$PLAIN_OUTPUT"

# ========================================
# Test: session-filtered status still surfaces legacy loop without session_id
# ========================================

init_test_git_repo "$TEST_DIR/repo-legacy-session"
mkdir -p "$TEST_DIR/repo-legacy-session/.humanize/rlcr/2026-01-19_00-00-00"
mkdir -p "$TEST_DIR/repo-legacy-session/.humanize/rlcr/2026-01-20_00-00-00"

cat > "$TEST_DIR/repo-legacy-session/.humanize/rlcr/2026-01-19_00-00-00/complete-state.md" << 'EOF'
---
session_id: other-session
current_round: 4
max_iterations: 10
---
EOF

cat > "$TEST_DIR/repo-legacy-session/.humanize/rlcr/2026-01-20_00-00-00/state.md" << 'EOF'
---
current_round: 1
max_iterations: 10
---
EOF

PLAIN_OUTPUT=$(run_statusline_plain "$TEST_DIR/repo-legacy-session" "current-session")
assert_statusline_rlcr \
    "statusline session filter treats legacy session-unaware loops as matching" \
    "Active" \
    "$PLAIN_OUTPUT"

# ========================================
# Test: newest loop without state is skipped for the next newest stateful loop
# ========================================

init_test_git_repo "$TEST_DIR/repo-skip-empty"
mkdir -p "$TEST_DIR/repo-skip-empty/.humanize/rlcr/2026-01-20_00-00-00"
mkdir -p "$TEST_DIR/repo-skip-empty/.humanize/rlcr/2026-01-19_00-00-00"

cat > "$TEST_DIR/repo-skip-empty/.humanize/rlcr/2026-01-19_00-00-00/pause-state.md" << 'EOF'
---
current_round: 2
max_iterations: 10
---
EOF

PLAIN_OUTPUT=$(run_statusline_plain "$TEST_DIR/repo-skip-empty")
assert_statusline_rlcr \
    "statusline skips newer loop directories that have no state files" \
    "Pause" \
    "$PLAIN_OUTPUT"

print_test_summary "Statusline Test Summary"
