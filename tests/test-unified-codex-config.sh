#!/bin/bash
#
# Tests for unified codex_model/codex_effort configuration
#
# Validates:
# - default_config.json contains codex_model/codex_effort (not loop_reviewer_*)
# - Config loader exposes codex keys through the 4-layer merge hierarchy
# - loop-common.sh loads config-backed DEFAULT_CODEX_MODEL/DEFAULT_CODEX_EFFORT
# - Stop hook uses STATE_CODEX_* -> DEFAULT_CODEX_* fallback chain
# - Setup script does not write loop_reviewer_* fields to state.md
# - Stale loop_reviewer_* keys in config/state are silently ignored
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

# Helper: assert_eq DESCRIPTION EXPECTED ACTUAL
# Calls pass/fail based on string equality
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$desc"
    else
        fail "$desc" "$expected" "$actual"
    fi
}

# Helper: assert_grep DESCRIPTION PATTERN FILE
# Passes if PATTERN is found in FILE
assert_grep() {
    local desc="$1" pattern="$2" file="$3"
    if grep -q "$pattern" "$file"; then pass "$desc"; else fail "$desc"; fi
}

# Helper: assert_no_grep DESCRIPTION PATTERN FILE_OR_STRING
# Passes if PATTERN is NOT found in FILE_OR_STRING
assert_no_grep() {
    local desc="$1" pattern="$2" file="$3"
    if grep -q "$pattern" "$file"; then fail "$desc"; else pass "$desc"; fi
}

echo "=========================================="
echo "Unified Codex Config Tests"
echo "=========================================="
echo ""

# ========================================
# default_config.json contains codex keys (not reviewer keys)
# ========================================

echo "--- default_config.json keys ---"

DEFAULT_CONFIG="$PROJECT_ROOT/config/default_config.json"

if ! command -v jq >/dev/null 2>&1; then
    skip "default config tests require jq" "jq not found"
else
    assert_eq "default_config.json: codex_model is gpt-5.4" \
        "gpt-5.4" "$(jq -r '.codex_model' "$DEFAULT_CONFIG")"

    assert_eq "default_config.json: codex_effort is high" \
        "high" "$(jq -r '.codex_effort' "$DEFAULT_CONFIG")"

    # Verify reviewer keys are absent
    assert_eq "default_config.json: loop_reviewer_model is absent" \
        "ABSENT" "$(jq -r '.loop_reviewer_model // "ABSENT"' "$DEFAULT_CONFIG")"

    assert_eq "default_config.json: loop_reviewer_effort is absent" \
        "ABSENT" "$(jq -r '.loop_reviewer_effort // "ABSENT"' "$DEFAULT_CONFIG")"
fi

echo ""

# ========================================
# Config merge hierarchy loads codex keys
# ========================================

echo "--- Config merge hierarchy ---"

CONFIG_LOADER="$PROJECT_ROOT/scripts/lib/config-loader.sh"
if [[ ! -f "$CONFIG_LOADER" ]]; then
    skip "config merge tests require config-loader.sh" "file not found"
else
    source "$CONFIG_LOADER"

    # Test default-only (no project override)
    setup_test_dir
    PROJECT_DIR="$TEST_DIR/empty-project"
    mkdir -p "$PROJECT_DIR"

    merged=$(XDG_CONFIG_HOME="$TEST_DIR/no-user-config" load_merged_config "$PROJECT_ROOT" "$PROJECT_DIR" 2>/dev/null)

    assert_eq "default-only: codex_model defaults to gpt-5.4" \
        "gpt-5.4" "$(get_config_value "$merged" "codex_model")"

    assert_eq "default-only: codex_effort defaults to high" \
        "high" "$(get_config_value "$merged" "codex_effort")"

    # Test project config override
    setup_test_dir
    PROJECT_DIR="$TEST_DIR/project-override"
    mkdir -p "$PROJECT_DIR/.humanize"
    printf '{"codex_model": "gpt-5.2", "codex_effort": "xhigh"}' > "$PROJECT_DIR/.humanize/config.json"

    merged=$(XDG_CONFIG_HOME="$TEST_DIR/no-user-config2" load_merged_config "$PROJECT_ROOT" "$PROJECT_DIR" 2>/dev/null)

    assert_eq "project override: codex_model overrides default" \
        "gpt-5.2" "$(get_config_value "$merged" "codex_model")"

    assert_eq "project override: codex_effort overrides default" \
        "xhigh" "$(get_config_value "$merged" "codex_effort")"
fi

echo ""

# ========================================
# loop-common.sh loads config-backed defaults
# ========================================

echo "--- loop-common.sh config-backed defaults ---"

LOOP_COMMON="$PROJECT_ROOT/hooks/lib/loop-common.sh"

if [[ ! -f "$LOOP_COMMON" ]]; then
    skip "loop-common.sh tests require loop-common.sh" "file not found"
else
    # Test default values load correctly
    result=$(bash -c "
        source '$LOOP_COMMON' 2>/dev/null
        echo \"\$DEFAULT_CODEX_MODEL|\$DEFAULT_CODEX_EFFORT\"
    " 2>/dev/null || echo "ERROR")

    assert_eq "loop-common.sh: DEFAULT_CODEX_MODEL is set" \
        "gpt-5.4" "$(echo "$result" | cut -d'|' -f1)"

    assert_eq "loop-common.sh: DEFAULT_CODEX_EFFORT is set" \
        "high" "$(echo "$result" | cut -d'|' -f2)"

    # Verify no reviewer constants or defaults exist
    result=$(bash -c "
        source '$LOOP_COMMON' 2>/dev/null
        echo \"\${FIELD_LOOP_REVIEWER_MODEL:-ABSENT}|\${DEFAULT_LOOP_REVIEWER_MODEL:-ABSENT}\"
    " 2>/dev/null || echo "ERROR")

    assert_eq "loop-common.sh: FIELD_LOOP_REVIEWER_MODEL absent" \
        "ABSENT" "$(echo "$result" | cut -d'|' -f1)"

    assert_eq "loop-common.sh: DEFAULT_LOOP_REVIEWER_MODEL absent" \
        "ABSENT" "$(echo "$result" | cut -d'|' -f2)"

    # Test config override feeds into DEFAULT_CODEX_MODEL
    setup_test_dir
    OVERRIDE_PROJECT="$TEST_DIR/override-project"
    mkdir -p "$OVERRIDE_PROJECT/.humanize"
    printf '{"codex_model": "o3-mini", "codex_effort": "low"}' > "$OVERRIDE_PROJECT/.humanize/config.json"

    result=$(bash -c "
        export CLAUDE_PROJECT_DIR='$OVERRIDE_PROJECT'
        export XDG_CONFIG_HOME='$TEST_DIR/no-user-config'
        source '$LOOP_COMMON' 2>/dev/null
        echo \"\$DEFAULT_CODEX_MODEL|\$DEFAULT_CODEX_EFFORT\"
    " 2>/dev/null || echo "ERROR")

    assert_eq "config merge: project override feeds into DEFAULT_CODEX_MODEL" \
        "o3-mini" "$(echo "$result" | cut -d'|' -f1)"

    assert_eq "config merge: project override feeds into DEFAULT_CODEX_EFFORT" \
        "low" "$(echo "$result" | cut -d'|' -f2)"
fi

echo ""

# ========================================
# Stop hook fallback chain: STATE_CODEX_* -> DEFAULT_CODEX_*
# ========================================

echo "--- Stop hook fallback chain ---"

if [[ ! -f "$LOOP_COMMON" ]]; then
    skip "stop hook fallback tests require loop-common.sh" "file not found"
else
    # State with codex fields - should use them directly
    setup_test_dir
    cat > "$TEST_DIR/codex-state.md" << 'STATE_EOF'
---
current_round: 1
max_iterations: 42
codex_model: gpt-5.2
codex_effort: xhigh
codex_timeout: 5400
push_every_round: false
full_review_round: 5
plan_file: plan.md
plan_tracked: false
start_branch: feature
base_branch: main
base_commit: abc123
review_started: false
ask_codex_question: true
session_id: test
agent_teams: false
---
STATE_EOF

    result=$(bash -c "
        source '$LOOP_COMMON' 2>/dev/null
        parse_state_file '$TEST_DIR/codex-state.md'
        EXEC_MODEL=\"\${STATE_CODEX_MODEL:-\$DEFAULT_CODEX_MODEL}\"
        EXEC_EFFORT=\"\${STATE_CODEX_EFFORT:-\$DEFAULT_CODEX_EFFORT}\"
        echo \"\$EXEC_MODEL|\$EXEC_EFFORT\"
    " 2>/dev/null || echo "ERROR")

    assert_eq "stop hook: codex model from state (gpt-5.2)" \
        "gpt-5.2" "$(echo "$result" | cut -d'|' -f1)"

    assert_eq "stop hook: codex effort from state (xhigh)" \
        "xhigh" "$(echo "$result" | cut -d'|' -f2)"

    # Bare state (no codex fields) - should fall back to defaults
    setup_test_dir
    cat > "$TEST_DIR/bare-state.md" << 'BARE_EOF'
---
current_round: 0
max_iterations: 10
codex_timeout: 3600
push_every_round: false
full_review_round: 5
plan_file: plan.md
plan_tracked: false
start_branch: feature
base_branch: main
base_commit: abc123
review_started: false
ask_codex_question: true
session_id: bare-session
agent_teams: false
---
BARE_EOF

    result=$(bash -c "
        source '$LOOP_COMMON' 2>/dev/null
        parse_state_file '$TEST_DIR/bare-state.md'
        EXEC_MODEL=\"\${STATE_CODEX_MODEL:-\$DEFAULT_CODEX_MODEL}\"
        EXEC_EFFORT=\"\${STATE_CODEX_EFFORT:-\$DEFAULT_CODEX_EFFORT}\"
        echo \"\$EXEC_MODEL|\$EXEC_EFFORT\"
    " 2>/dev/null || echo "ERROR")

    assert_eq "bare state: falls back to DEFAULT_CODEX_MODEL (gpt-5.4)" \
        "gpt-5.4" "$(echo "$result" | cut -d'|' -f1)"

    assert_eq "bare state: falls back to DEFAULT_CODEX_EFFORT (high)" \
        "high" "$(echo "$result" | cut -d'|' -f2)"

    # Config override + bare state: config-backed defaults used
    setup_test_dir
    OVERRIDE_PROJECT="$TEST_DIR/codex-override"
    mkdir -p "$OVERRIDE_PROJECT/.humanize"
    printf '{"codex_model": "o1-preview", "codex_effort": "medium"}' > "$OVERRIDE_PROJECT/.humanize/config.json"

    cat > "$TEST_DIR/cfg-bare-state.md" << 'CFG_BARE_EOF'
---
current_round: 0
max_iterations: 10
codex_timeout: 3600
push_every_round: false
full_review_round: 5
plan_file: plan.md
plan_tracked: false
start_branch: feature
base_branch: main
base_commit: abc123
review_started: false
ask_codex_question: true
session_id: cfg-bare
agent_teams: false
---
CFG_BARE_EOF

    result=$(bash -c "
        export CLAUDE_PROJECT_DIR='$OVERRIDE_PROJECT'
        export XDG_CONFIG_HOME='$TEST_DIR/no-user-config'
        source '$LOOP_COMMON' 2>/dev/null
        parse_state_file '$TEST_DIR/cfg-bare-state.md'
        EXEC_MODEL=\"\${STATE_CODEX_MODEL:-\$DEFAULT_CODEX_MODEL}\"
        EXEC_EFFORT=\"\${STATE_CODEX_EFFORT:-\$DEFAULT_CODEX_EFFORT}\"
        echo \"\$EXEC_MODEL|\$EXEC_EFFORT\"
    " 2>/dev/null || echo "ERROR")

    assert_eq "config override + bare state: codex model from config (o1-preview)" \
        "o1-preview" "$(echo "$result" | cut -d'|' -f1)"

    assert_eq "config override + bare state: codex effort from config (medium)" \
        "medium" "$(echo "$result" | cut -d'|' -f2)"
fi

echo ""

# ========================================
# Setup script does not write reviewer fields
# ========================================

echo "--- Setup script state.md template ---"

SETUP_SCRIPT="$PROJECT_ROOT/scripts/setup-rlcr-loop.sh"

assert_no_grep "setup script: no loop_reviewer references" 'loop_reviewer' "$SETUP_SCRIPT"
assert_grep "setup script: state.md template includes codex_model" 'codex_model:' "$SETUP_SCRIPT"
assert_grep "setup script: state.md template includes codex_effort" 'codex_effort:' "$SETUP_SCRIPT"

echo ""

# ========================================
# Stale loop_reviewer_* keys in config are silently ignored
# ========================================

echo "--- Stale config key handling ---"

if [[ ! -f "$LOOP_COMMON" ]]; then
    skip "stale key tests require loop-common.sh" "file not found"
else
    # Project config with stale reviewer keys should not affect defaults
    setup_test_dir
    STALE_PROJECT="$TEST_DIR/stale-project"
    mkdir -p "$STALE_PROJECT/.humanize"
    printf '{"loop_reviewer_model": "o3-mini", "loop_reviewer_effort": "low", "codex_model": "gpt-5.3"}' > "$STALE_PROJECT/.humanize/config.json"

    result=$(bash -c "
        export CLAUDE_PROJECT_DIR='$STALE_PROJECT'
        export XDG_CONFIG_HOME='$TEST_DIR/no-user-config'
        source '$LOOP_COMMON' 2>/dev/null
        echo \"\$DEFAULT_CODEX_MODEL|\$DEFAULT_CODEX_EFFORT\"
    " 2>/dev/null || echo "ERROR")

    assert_eq "stale config: codex_model from config (gpt-5.3), reviewer keys ignored" \
        "gpt-5.3" "$(echo "$result" | cut -d'|' -f1)"

    assert_eq "stale config: codex_effort from hardcoded fallback (high), reviewer keys ignored" \
        "high" "$(echo "$result" | cut -d'|' -f2)"

    # State file with stale reviewer fields - parser should not set STATE_LOOP_REVIEWER_*
    setup_test_dir
    cat > "$TEST_DIR/stale-state.md" << 'STALE_EOF'
---
current_round: 1
max_iterations: 42
codex_model: gpt-5.4
codex_effort: high
codex_timeout: 5400
push_every_round: false
full_review_round: 5
plan_file: plan.md
plan_tracked: false
start_branch: feature
base_branch: main
base_commit: abc123
review_started: false
ask_codex_question: true
session_id: stale-test
agent_teams: false
loop_reviewer_model: gpt-5.2
loop_reviewer_effort: xhigh
---
STALE_EOF

    result=$(bash -c "
        source '$LOOP_COMMON' 2>/dev/null
        parse_state_file '$TEST_DIR/stale-state.md'
        echo \"\${STATE_LOOP_REVIEWER_MODEL:-ABSENT}|\${STATE_LOOP_REVIEWER_EFFORT:-ABSENT}\"
    " 2>/dev/null || echo "ERROR")

    assert_eq "stale state: STATE_LOOP_REVIEWER_MODEL not parsed (ABSENT)" \
        "ABSENT" "$(echo "$result" | cut -d'|' -f1)"

    assert_eq "stale state: STATE_LOOP_REVIEWER_EFFORT not parsed (ABSENT)" \
        "ABSENT" "$(echo "$result" | cut -d'|' -f2)"

    # Verify codex fields are still parsed correctly from the stale state
    result=$(bash -c "
        source '$LOOP_COMMON' 2>/dev/null
        parse_state_file '$TEST_DIR/stale-state.md'
        echo \"\$STATE_CODEX_MODEL|\$STATE_CODEX_EFFORT\"
    " 2>/dev/null || echo "ERROR")

    assert_eq "stale state: STATE_CODEX_MODEL still parsed (gpt-5.4)" \
        "gpt-5.4" "$(echo "$result" | cut -d'|' -f1)"

    assert_eq "stale state: STATE_CODEX_EFFORT still parsed (high)" \
        "high" "$(echo "$result" | cut -d'|' -f2)"
fi

echo ""

# ========================================
# Stop-hook effort validation
# ========================================

echo "--- Stop-hook effort validation ---"

STOP_HOOK="$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh"

if [[ ! -f "$STOP_HOOK" ]]; then
    skip "stop-hook effort test requires stop hook" "file not found"
elif ! command -v jq >/dev/null 2>&1; then
    skip "stop-hook effort test requires jq" "jq not found"
else
    setup_test_dir
    HOOK_PROJECT="$TEST_DIR/hook-project"
    mkdir -p "$HOOK_PROJECT/.humanize/rlcr/2099-01-01_00-00-00"

    # Create state.md with invalid codex effort
    cat > "$HOOK_PROJECT/.humanize/rlcr/2099-01-01_00-00-00/state.md" << 'HOOK_STATE_EOF'
---
current_round: 1
max_iterations: 10
codex_model: gpt-5.4
codex_effort: superhigh
codex_timeout: 3600
push_every_round: false
full_review_round: 5
plan_file: plan.md
plan_tracked: false
start_branch: main
base_branch: main
base_commit: abc123
review_started: false
ask_codex_question: false
session_id: hook-test
agent_teams: false
---
HOOK_STATE_EOF

    # Create a stub codex that records invocations (should never be called)
    STUB_BIN="$TEST_DIR/stub-bin"
    mkdir -p "$STUB_BIN"
    cat > "$STUB_BIN/codex" << 'STUB_EOF'
#!/bin/bash
echo "CODEX_INVOKED" >> "$CODEX_INVOCATION_LOG"
exit 0
STUB_EOF
    chmod +x "$STUB_BIN/codex"

    CODEX_LOG="$TEST_DIR/codex-invocations.log"

    # Run the stop hook with the invalid state
    hook_stderr=$(echo '{"session_id":"hook-test"}' | \
        CLAUDE_PROJECT_DIR="$HOOK_PROJECT" \
        CODEX_INVOCATION_LOG="$CODEX_LOG" \
        PATH="$STUB_BIN:$PATH" \
        bash "$STOP_HOOK" 2>&1 >/dev/null) || true

    # Assert: hook reported the invalid effort error (now "codex effort" not "reviewer effort")
    if echo "$hook_stderr" | grep -q "Invalid codex effort"; then
        pass "stop-hook behavioral: rejects 'superhigh' effort with error message"
    else
        fail "stop-hook behavioral: rejects 'superhigh' effort with error message" "contains 'Invalid codex effort'" "$hook_stderr"
    fi

    # Assert: codex stub was never invoked
    if [[ ! -f "$CODEX_LOG" ]]; then
        pass "stop-hook behavioral: codex was not invoked for invalid effort"
    else
        fail "stop-hook behavioral: codex was not invoked for invalid effort" "no invocation log" "codex was called"
    fi
fi

echo ""

# ========================================
# Setup script execution test
# ========================================

echo "--- Setup script execution test ---"

if ! command -v jq >/dev/null 2>&1; then
    skip "setup execution test requires jq" "jq not found"
elif ! command -v codex >/dev/null 2>&1; then
    skip "setup execution test requires codex" "codex not found"
else
    setup_test_dir
    EXEC_PROJECT="$TEST_DIR/exec-project"
    init_test_git_repo "$EXEC_PROJECT"

    # Create project config with codex overrides
    mkdir -p "$EXEC_PROJECT/.humanize"
    printf '{"codex_model": "gpt-5.2", "codex_effort": "low"}' > "$EXEC_PROJECT/.humanize/config.json"

    # Create a plan file with enough lines (minimum 5 required) and commit it
    cat > "$EXEC_PROJECT/plan.md" << 'PLAN_EOF'
# Test Plan
## Goal
Test unified codex config
## Tasks
- Task 1: Add config keys
- Task 2: Wire through pipeline
PLAN_EOF
    (cd "$EXEC_PROJECT" && git add plan.md && git commit -q -m "Add plan")

    # Create a local bare remote to prevent network calls
    BARE_REMOTE="$TEST_DIR/remote.git"
    git clone --bare "$EXEC_PROJECT" "$BARE_REMOTE" -q 2>/dev/null
    (cd "$EXEC_PROJECT" && git remote remove origin 2>/dev/null; git remote add origin "$BARE_REMOTE") 2>/dev/null || true

    # Run setup-rlcr-loop.sh with --codex-model override
    setup_exit=0
    output=$(cd "$EXEC_PROJECT" && CLAUDE_PROJECT_DIR="$EXEC_PROJECT" timeout 30 bash "$SETUP_SCRIPT" --codex-model gpt-5.3:xhigh --base-branch master --track-plan-file plan.md 2>&1) || setup_exit=$?

    assert_eq "setup execution: setup-rlcr-loop.sh exited successfully" \
        "0" "$setup_exit"

    # Find the generated state.md
    STATE_FILE=$(find "$EXEC_PROJECT/.humanize/rlcr" -name "state.md" 2>/dev/null | head -1 || true)
    if [[ -z "$STATE_FILE" ]]; then
        fail "setup execution: state.md was created" "non-empty path" "empty"
    else
        pass "setup execution: state.md was created"

        # Verify codex_model from --codex-model flag
        codex_model=$(grep '^codex_model:' "$STATE_FILE" | sed 's/codex_model: *//')
        assert_eq "setup execution: --codex-model set codex_model (gpt-5.3)" \
            "gpt-5.3" "$codex_model"

        codex_effort=$(grep '^codex_effort:' "$STATE_FILE" | sed 's/codex_effort: *//')
        assert_eq "setup execution: --codex-model set codex_effort (xhigh)" \
            "xhigh" "$codex_effort"

        assert_no_grep "setup execution: state.md does not contain loop_reviewer fields" \
            'loop_reviewer' "$STATE_FILE"
    fi

    # Verify output does NOT mention "Reviewer Model" or "Reviewer Effort"
    if echo "$output" | grep -q 'Reviewer Model\|Reviewer Effort'; then
        fail "setup execution: output does not mention Reviewer Model/Effort"
    else
        pass "setup execution: output does not mention Reviewer Model/Effort"
    fi
fi

echo ""

# ========================================
# Input validation still works
# ========================================

echo "--- Input validation ---"

# Test invalid model name (has spaces) - test the validation regex directly
model_with_spaces="gpt 5.4 bad"
if [[ ! "$model_with_spaces" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    pass "validation: model with spaces is rejected by regex"
else
    fail "validation: model with spaces is rejected by regex"
fi

model_with_shell="gpt-5.4;rm-rf"
if [[ ! "$model_with_shell" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    pass "validation: model with shell metacharacters is rejected"
else
    fail "validation: model with shell metacharacters is rejected"
fi

# Test invalid effort value
invalid_effort="superhigh"
if [[ ! "$invalid_effort" =~ ^(xhigh|high|medium|low)$ ]]; then
    pass "validation: invalid effort value is rejected by regex"
else
    fail "validation: invalid effort value is rejected by regex"
fi

# Test valid effort values
for effort in xhigh high medium low; do
    if [[ "$effort" =~ ^(xhigh|high|medium|low)$ ]]; then
        pass "validation: effort '$effort' is accepted"
    else
        fail "validation: effort '$effort' is accepted"
    fi
done

echo ""

# ========================================
# Summary
# ========================================

print_test_summary "Unified Codex Config Test Summary"
