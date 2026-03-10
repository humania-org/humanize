#!/bin/bash
#
# Tests for setup-rlcr-loop state.md reviewer config wiring
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

SETUP_SCRIPT="$PROJECT_ROOT/scripts/setup-rlcr-loop.sh"

echo "=========================================="
echo "Setup Loop State Reviewer Config Tests"
echo "=========================================="
echo ""

setup_mock_codex() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/codex" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$bin_dir/codex"
}

run_setup_skip_impl() {
    local repo_dir="$1"
    local output_file="$2"

    (
        cd "$repo_dir"
        CLAUDE_PROJECT_DIR="$repo_dir" PATH="$MOCK_BIN:$PATH" bash "$SETUP_SCRIPT" --skip-impl "${@:3}"
    ) >"$output_file" 2>&1
}

find_state_file() {
    local repo_dir="$1"
    find "$repo_dir/.humanize/rlcr" -name "state.md" -type f 2>/dev/null | head -1
}

setup_test_dir
MOCK_BIN="$TEST_DIR/bin"
setup_mock_codex "$MOCK_BIN"

# ========================================
# Test 1: Configured loop_reviewer_effort is written to state.md
# ========================================

REPO1="$TEST_DIR/repo-config-medium"
init_test_git_repo "$REPO1"
mkdir -p "$REPO1/.humanize"
cat > "$REPO1/.humanize/config.json" << 'EOF'
{"loop_reviewer_effort":"medium"}
EOF

if run_setup_skip_impl "$REPO1" "$TEST_DIR/repo1.out"; then
    pass "setup-rlcr-loop succeeds with .humanize/config.json loop_reviewer_effort"
else
    OUTPUT=$(cat "$TEST_DIR/repo1.out" 2>/dev/null || true)
    fail "setup-rlcr-loop succeeds with .humanize/config.json loop_reviewer_effort" "exit 0" "output: $OUTPUT"
fi

STATE1="$(find_state_file "$REPO1")"
if [[ -n "$STATE1" ]] && grep -q "^loop_reviewer_effort: medium$" "$STATE1"; then
    pass "state.md records loop_reviewer_effort: medium from project config"
else
    GOT="$(grep "^loop_reviewer_effort:" "$STATE1" 2>/dev/null || echo "missing")"
    fail "state.md records loop_reviewer_effort: medium from project config" "loop_reviewer_effort: medium" "$GOT"
fi

if [[ -n "$STATE1" ]] && grep -q "^codex_effort: medium$" "$STATE1"; then
    pass "state.md records codex_effort: medium from project loop_reviewer_effort"
else
    GOT="$(grep "^codex_effort:" "$STATE1" 2>/dev/null || echo "missing")"
    fail "state.md records codex_effort: medium from project loop_reviewer_effort" "codex_effort: medium" "$GOT"
fi

# ========================================
# Test 2: Missing config defaults loop_reviewer_effort to high
# ========================================

REPO2="$TEST_DIR/repo-default-high"
init_test_git_repo "$REPO2"

if run_setup_skip_impl "$REPO2" "$TEST_DIR/repo2.out"; then
    pass "setup-rlcr-loop succeeds without project config"
else
    OUTPUT=$(cat "$TEST_DIR/repo2.out" 2>/dev/null || true)
    fail "setup-rlcr-loop succeeds without project config" "exit 0" "output: $OUTPUT"
fi

STATE2="$(find_state_file "$REPO2")"
if [[ -n "$STATE2" ]] && grep -q "^loop_reviewer_effort: high$" "$STATE2"; then
    pass "state.md defaults loop_reviewer_effort: high when config is missing"
else
    GOT="$(grep "^loop_reviewer_effort:" "$STATE2" 2>/dev/null || echo "missing")"
    fail "state.md defaults loop_reviewer_effort: high when config is missing" "loop_reviewer_effort: high" "$GOT"
fi

if [[ -n "$STATE2" ]] && grep -q "^codex_effort: high$" "$STATE2"; then
    pass "state.md defaults codex_effort: high from reviewer defaults when config is missing"
else
    GOT="$(grep "^codex_effort:" "$STATE2" 2>/dev/null || echo "missing")"
    fail "state.md defaults codex_effort: high from reviewer defaults when config is missing" "codex_effort: high" "$GOT"
fi

# ========================================
# Test 3: Configured loop_reviewer_model is written to state.md
# ========================================

REPO3="$TEST_DIR/repo-config-reviewer-model"
init_test_git_repo "$REPO3"
mkdir -p "$REPO3/.humanize"
cat > "$REPO3/.humanize/config.json" << 'EOF'
{"loop_reviewer_model":"sonnet"}
EOF

if run_setup_skip_impl "$REPO3" "$TEST_DIR/repo3.out"; then
    pass "setup-rlcr-loop succeeds with .humanize/config.json loop_reviewer_model"
else
    OUTPUT=$(cat "$TEST_DIR/repo3.out" 2>/dev/null || true)
    fail "setup-rlcr-loop succeeds with .humanize/config.json loop_reviewer_model" "exit 0" "output: $OUTPUT"
fi

STATE3="$(find_state_file "$REPO3")"
if [[ -n "$STATE3" ]] && grep -q "^codex_model: sonnet$" "$STATE3"; then
    pass "state.md records codex_model: sonnet from project loop_reviewer_model"
else
    GOT="$(grep "^codex_model:" "$STATE3" 2>/dev/null || echo "missing")"
    fail "state.md records codex_model: sonnet from project loop_reviewer_model" "codex_model: sonnet" "$GOT"
fi

# ========================================
# Test 4: Legacy codex_review_effort migrates to loop_reviewer_effort
# ========================================

REPO4="$TEST_DIR/repo-legacy-low"
init_test_git_repo "$REPO4"
mkdir -p "$REPO4/.humanize"
cat > "$REPO4/.humanize/config.json" << 'EOF'
{"codex_review_effort":"low"}
EOF

if run_setup_skip_impl "$REPO4" "$TEST_DIR/repo4.out"; then
    pass "setup-rlcr-loop succeeds with legacy codex_review_effort config"
else
    OUTPUT=$(cat "$TEST_DIR/repo4.out" 2>/dev/null || true)
    fail "setup-rlcr-loop succeeds with legacy codex_review_effort config" "exit 0" "output: $OUTPUT"
fi

STATE4="$(find_state_file "$REPO4")"
if [[ -n "$STATE4" ]] && grep -q "^loop_reviewer_effort: low$" "$STATE4"; then
    pass "state.md writes loop_reviewer_effort: low from legacy codex_review_effort"
else
    GOT="$(grep "^loop_reviewer_effort:" "$STATE4" 2>/dev/null || echo "missing")"
    fail "state.md writes loop_reviewer_effort: low from legacy codex_review_effort" "loop_reviewer_effort: low" "$GOT"
fi

# ========================================
# Test 5: --codex-model MODEL inherits reviewer effort default
# ========================================

REPO5="$TEST_DIR/repo-cli-model-reviewer-effort"
init_test_git_repo "$REPO5"
mkdir -p "$REPO5/.humanize"
cat > "$REPO5/.humanize/config.json" << 'EOF'
{"loop_reviewer_effort":"medium"}
EOF

if run_setup_skip_impl "$REPO5" "$TEST_DIR/repo5.out" --codex-model sonnet; then
    pass "setup-rlcr-loop succeeds with --codex-model MODEL and project loop_reviewer_effort"
else
    OUTPUT=$(cat "$TEST_DIR/repo5.out" 2>/dev/null || true)
    fail "setup-rlcr-loop succeeds with --codex-model MODEL and project loop_reviewer_effort" "exit 0" "output: $OUTPUT"
fi

STATE5="$(find_state_file "$REPO5")"
if [[ -n "$STATE5" ]] && grep -q "^codex_model: sonnet$" "$STATE5"; then
    pass "state.md records codex_model: sonnet from --codex-model MODEL"
else
    GOT="$(grep "^codex_model:" "$STATE5" 2>/dev/null || echo "missing")"
    fail "state.md records codex_model: sonnet from --codex-model MODEL" "codex_model: sonnet" "$GOT"
fi

if [[ -n "$STATE5" ]] && grep -q "^codex_effort: medium$" "$STATE5"; then
    pass "state.md uses reviewer effort default for --codex-model MODEL without :EFFORT"
else
    GOT="$(grep "^codex_effort:" "$STATE5" 2>/dev/null || echo "missing")"
    fail "state.md uses reviewer effort default for --codex-model MODEL without :EFFORT" "codex_effort: medium" "$GOT"
fi

print_test_summary "Setup Loop State Reviewer Config Test Summary"
exit $?
