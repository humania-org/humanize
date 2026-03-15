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

# Helper: assert_contains DESCRIPTION PATTERN STRING
# Passes if PATTERN is found in STRING
assert_contains() {
    local desc="$1" pattern="$2" text="$3"
    if grep -q -- "$pattern" <<< "$text"; then pass "$desc"; else fail "$desc"; fi
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

    # Caller-provided defaults must continue to override config values
    result=$(bash -c "
        export DEFAULT_CODEX_MODEL='preset-model'
        export DEFAULT_CODEX_EFFORT='medium'
        export CLAUDE_PROJECT_DIR='$OVERRIDE_PROJECT'
        export XDG_CONFIG_HOME='$TEST_DIR/no-user-config'
        source '$LOOP_COMMON' 2>/dev/null
        echo \"\$DEFAULT_CODEX_MODEL|\$DEFAULT_CODEX_EFFORT\"
    " 2>/dev/null || echo "ERROR")

    assert_eq "caller preset: DEFAULT_CODEX_MODEL wins over config" \
        "preset-model" "$(echo "$result" | cut -d'|' -f1)"

    assert_eq "caller preset: DEFAULT_CODEX_EFFORT wins over config" \
        "medium" "$(echo "$result" | cut -d'|' -f2)"

    # Invalid config values should warn and fall back to hardcoded defaults
    setup_test_dir
    INVALID_PROJECT="$TEST_DIR/invalid-project"
    mkdir -p "$INVALID_PROJECT/.humanize"
    printf '{"codex_model": "haiku!", "codex_effort": "superhigh"}' > "$INVALID_PROJECT/.humanize/config.json"

    result=$(bash -c "
        export CLAUDE_PROJECT_DIR='$INVALID_PROJECT'
        export XDG_CONFIG_HOME='$TEST_DIR/no-user-config-invalid'
        source '$LOOP_COMMON'
        printf 'RESULT:%s|%s\n' \"\$DEFAULT_CODEX_MODEL\" \"\$DEFAULT_CODEX_EFFORT\"
    " 2>&1 || echo "ERROR")

    result_line="$(printf '%s\n' "$result" | grep '^RESULT:' | tail -n 1)"

    assert_eq "invalid config: codex_model falls back to gpt-5.4" \
        "gpt-5.4" "$(echo "$result_line" | cut -d':' -f2 | cut -d'|' -f1)"

    assert_eq "invalid config: codex_effort falls back to high" \
        "high" "$(echo "$result_line" | cut -d'|' -f2)"

    assert_contains "invalid config: warns on invalid codex_model" \
        "Warning: Invalid codex_model in merged config: haiku!" "$result"

    assert_contains "invalid config: warns on invalid codex_effort" \
        "Warning: Invalid codex_effort in merged config: superhigh" "$result"

    # Shell-safe but non-Codex models should also warn and fall back
    for invalid_model in haiku false claude-3; do
        setup_test_dir
        INVALID_PROJECT="$TEST_DIR/invalid-model-project"
        mkdir -p "$INVALID_PROJECT/.humanize"
        printf '{"codex_model": "%s"}' "$invalid_model" > "$INVALID_PROJECT/.humanize/config.json"

        result=$(bash -c "
            export CLAUDE_PROJECT_DIR='$INVALID_PROJECT'
            export XDG_CONFIG_HOME='$TEST_DIR/no-user-config-invalid-model'
            source '$LOOP_COMMON'
            printf 'RESULT:%s|%s\n' \"\$DEFAULT_CODEX_MODEL\" \"\$DEFAULT_CODEX_EFFORT\"
        " 2>&1 || echo "ERROR")

        result_line="$(printf '%s\n' "$result" | grep '^RESULT:' | tail -n 1)"

        assert_eq "non-Codex config ($invalid_model): codex_model falls back to gpt-5.4" \
            "gpt-5.4" "$(echo "$result_line" | cut -d':' -f2 | cut -d'|' -f1)"

        assert_eq "non-Codex config ($invalid_model): codex_effort stays at high fallback" \
            "high" "$(echo "$result_line" | cut -d'|' -f2)"

        assert_contains "non-Codex config ($invalid_model): warns on unsupported codex_model" \
            "Warning: Unsupported codex_model in merged config: $invalid_model" "$result"
    done
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
    # Ensure a 'master' branch exists so --base-branch master is valid
    # (init_test_git_repo may create 'main' depending on git config)
    (cd "$EXEC_PROJECT" && git branch master 2>/dev/null || true)

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

        SUMMARY_FILE="$(dirname "$STATE_FILE")/round-0-summary.md"
        if [[ -f "$SUMMARY_FILE" ]]; then
            if grep -q '^## BitLesson Delta$' "$SUMMARY_FILE" && \
               grep -q '^Action: none$' "$SUMMARY_FILE"; then
                pass "setup execution: round-0 summary scaffold includes BitLesson Delta defaults"
            else
                fail "setup execution: round-0 summary scaffold includes BitLesson Delta defaults" \
                    "BitLesson Delta scaffold" \
                    "$(cat "$SUMMARY_FILE")"
            fi
        else
            fail "setup execution: round-0 summary scaffold was created" \
                "round-0-summary.md exists" \
                "not found"
        fi

        # Verify codex_model from --codex-model flag
        assert_eq "setup execution: --codex-model set codex_model (gpt-5.3)" \
            "gpt-5.3" "$(grep '^codex_model:' "$STATE_FILE" | sed 's/codex_model: *//')"

        assert_eq "setup execution: --codex-model set codex_effort (xhigh)" \
            "xhigh" "$(grep '^codex_effort:' "$STATE_FILE" | sed 's/codex_effort: *//')"

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
# PR loop respects config-backed codex_model (AC-5)
# ========================================

echo "--- PR loop config-backed defaults ---"

SETUP_PR_LOOP="$PROJECT_ROOT/scripts/setup-pr-loop.sh"
PR_STOP_HOOK="$PROJECT_ROOT/hooks/pr-loop-stop-hook.sh"

if [[ ! -f "$LOOP_COMMON" ]]; then
    skip "PR loop config tests require loop-common.sh" "file not found"
elif [[ ! -f "$SETUP_PR_LOOP" ]]; then
    skip "PR loop config tests require setup-pr-loop.sh" "file not found"
else
    # PR loop setup does NOT pre-set DEFAULT_CODEX_MODEL (should come from config)
    assert_no_grep "setup-pr-loop.sh: does not pre-set DEFAULT_CODEX_MODEL" \
        'DEFAULT_CODEX_MODEL=' "$SETUP_PR_LOOP"

    # PR loop setup DOES pre-set DEFAULT_CODEX_EFFORT to medium
    assert_grep "setup-pr-loop.sh: pre-sets DEFAULT_CODEX_EFFORT to medium" \
        'DEFAULT_CODEX_EFFORT="medium"' "$SETUP_PR_LOOP"

    # PR stop hook also does NOT pre-set DEFAULT_CODEX_MODEL
    if [[ ! -f "$PR_STOP_HOOK" ]]; then
        skip "pr-loop-stop-hook.sh tests require pr-loop-stop-hook.sh" "file not found"
    else
        assert_no_grep "pr-loop-stop-hook.sh: does not pre-set DEFAULT_CODEX_MODEL" \
            'DEFAULT_CODEX_MODEL=' "$PR_STOP_HOOK"

        assert_grep "pr-loop-stop-hook.sh: pre-sets DEFAULT_CODEX_EFFORT to medium" \
            'DEFAULT_CODEX_EFFORT="medium"' "$PR_STOP_HOOK"
    fi

    # Behavioral: sourcing loop-common.sh with PR loop effort pre-set picks up config model
    setup_test_dir
    PR_CFG_PROJECT="$TEST_DIR/pr-cfg-project"
    mkdir -p "$PR_CFG_PROJECT/.humanize"
    printf '{"codex_model": "o3-mini", "codex_effort": "low"}' > "$PR_CFG_PROJECT/.humanize/config.json"

    result=$(bash -c "
        export DEFAULT_CODEX_EFFORT='medium'
        export CLAUDE_PROJECT_DIR='$PR_CFG_PROJECT'
        export XDG_CONFIG_HOME='$TEST_DIR/no-user-config'
        source '$LOOP_COMMON' 2>/dev/null
        echo \"\$DEFAULT_CODEX_MODEL|\$DEFAULT_CODEX_EFFORT\"
    " 2>/dev/null || echo "ERROR")

    assert_eq "PR loop behavioral: config codex_model respected (o3-mini)" \
        "o3-mini" "$(echo "$result" | cut -d'|' -f1)"

    assert_eq "PR loop behavioral: pre-set effort kept over config (medium)" \
        "medium" "$(echo "$result" | cut -d'|' -f2)"

    # Without config, falls back to hardcoded default model but keeps medium effort
    result=$(bash -c "
        export DEFAULT_CODEX_EFFORT='medium'
        export XDG_CONFIG_HOME='$TEST_DIR/no-user-config'
        source '$LOOP_COMMON' 2>/dev/null
        echo \"\$DEFAULT_CODEX_MODEL|\$DEFAULT_CODEX_EFFORT\"
    " 2>/dev/null || echo "ERROR")

    assert_eq "PR loop behavioral: no config falls back to gpt-5.4" \
        "gpt-5.4" "$(echo "$result" | cut -d'|' -f1)"

    assert_eq "PR loop behavioral: no config keeps medium effort" \
        "medium" "$(echo "$result" | cut -d'|' -f2)"
fi

echo ""

# ========================================
# ask-codex respects config-backed defaults (AC-5)
# ========================================

echo "--- ask-codex config-backed defaults ---"

ASK_CODEX="$PROJECT_ROOT/scripts/ask-codex.sh"

if [[ ! -f "$ASK_CODEX" ]]; then
    skip "ask-codex config tests require ask-codex.sh" "file not found"
else
    # ask-codex does NOT pre-set DEFAULT_CODEX_MODEL or DEFAULT_CODEX_EFFORT
    assert_no_grep "ask-codex.sh: does not pre-set DEFAULT_CODEX_MODEL" \
        'DEFAULT_CODEX_MODEL=' "$ASK_CODEX"

    assert_no_grep "ask-codex.sh: does not pre-set DEFAULT_CODEX_EFFORT" \
        'DEFAULT_CODEX_EFFORT=' "$ASK_CODEX"

    # ask-codex uses DEFAULT_CODEX_MODEL from loop-common.sh (config-backed)
    assert_grep "ask-codex.sh: assigns CODEX_MODEL from DEFAULT_CODEX_MODEL" \
        'CODEX_MODEL="\$DEFAULT_CODEX_MODEL"' "$ASK_CODEX"

    assert_grep "ask-codex.sh: assigns CODEX_EFFORT from DEFAULT_CODEX_EFFORT" \
        'CODEX_EFFORT="\$DEFAULT_CODEX_EFFORT"' "$ASK_CODEX"

    # Help text mentions config-backed defaults
    assert_grep "ask-codex.sh: help text mentions config-backed default" \
        'default from config' "$ASK_CODEX"
fi

echo ""

# ========================================
# PR loop --codex-model override (runtime behavioral)
# ========================================

echo "--- PR loop --codex-model override (runtime) ---"

if [[ ! -f "$SETUP_PR_LOOP" ]]; then
    skip "PR loop override test requires setup-pr-loop.sh" "file not found"
else
    # Run setup-pr-loop.sh --help with project config to verify help text shows config-backed default
    # --help exits before requiring gh/PR prerequisites, so no external deps needed
    setup_test_dir
    PR_OVERRIDE_PROJECT="$TEST_DIR/pr-override-project"
    mkdir -p "$PR_OVERRIDE_PROJECT/.humanize"
    printf '{"codex_model": "o3-mini", "codex_effort": "low"}' > "$PR_OVERRIDE_PROJECT/.humanize/config.json"

    help_output=$(cd "$PR_OVERRIDE_PROJECT" && \
        CLAUDE_PROJECT_DIR="$PR_OVERRIDE_PROJECT" \
        XDG_CONFIG_HOME="$TEST_DIR/no-user-config" \
        timeout 10 bash "$SETUP_PR_LOOP" --help 2>&1) || true

    # Help text must mention config-backed default (not a hardcoded model name)
    if echo "$help_output" | grep -q 'default from config'; then
        pass "PR loop runtime: --help shows config-backed default"
    else
        fail "PR loop runtime: --help shows config-backed default" "contains 'default from config'" "$(echo "$help_output" | grep codex-model)"
    fi

    # End-to-end: run setup-pr-loop.sh with mock gh/codex and --codex-model override
    if ! command -v jq >/dev/null 2>&1; then
        skip "PR loop e2e test requires jq" "jq not found"
    else
        setup_test_dir
        PR_E2E_PROJECT="$TEST_DIR/pr-e2e-project"
        init_test_git_repo "$PR_E2E_PROJECT"
        mkdir -p "$PR_E2E_PROJECT/.humanize"
        printf '{"codex_model": "o3-mini", "codex_effort": "low"}' > "$PR_E2E_PROJECT/.humanize/config.json"

        # Create a local bare remote (setup-pr-loop.sh needs a git remote)
        PR_BARE_REMOTE="$TEST_DIR/pr-remote.git"
        git clone --bare "$PR_E2E_PROJECT" "$PR_BARE_REMOTE" -q 2>/dev/null
        (cd "$PR_E2E_PROJECT" && git remote remove origin 2>/dev/null; git remote add origin "$PR_BARE_REMOTE") 2>/dev/null || true

        # Create mock gh that handles all setup-pr-loop.sh calls
        PR_MOCK_BIN="$TEST_DIR/pr-mock-bin"
        mkdir -p "$PR_MOCK_BIN"
        cat > "$PR_MOCK_BIN/gh" << 'GH_MOCK_EOF'
#!/bin/bash
# Mock gh for setup-pr-loop.sh end-to-end test
ALL_ARGS="$*"
case "$1" in
    auth) exit 0 ;;
    repo)
        if [[ "$ALL_ARGS" == *"owner,name"* ]]; then
            echo "testowner/testrepo"; exit 0
        elif [[ "$ALL_ARGS" == *"parent"* ]]; then
            echo "null/"; exit 0
        fi ;;
    pr)
        if [[ "$2" == "view" ]]; then
            if [[ "$ALL_ARGS" == *"number,url"* ]]; then
                printf '123\nhttps://github.com/testowner/testrepo/pull/123'; exit 0
            elif [[ "$ALL_ARGS" == *"state"* ]]; then
                echo "OPEN"; exit 0
            elif [[ "$ALL_ARGS" == *"number"* ]]; then
                echo "123"; exit 0
            elif [[ "$ALL_ARGS" == *"headRefOid"* ]]; then
                echo '{"sha":"abc123","date":"2026-01-01T00:00:00Z"}'; exit 0
            fi
        elif [[ "$2" == "comment" ]]; then
            echo "https://github.com/testowner/testrepo/pull/123#comment-1"; exit 0
        fi ;;
    api)
        if [[ "$2" == "user" ]]; then
            echo '{"login":"testuser"}'; exit 0
        elif [[ "$2" == *"/comments"* ]] || [[ "$2" == *"/reviews"* ]]; then
            echo "[]"; exit 0
        fi
        echo "[]"; exit 0 ;;
esac
echo "Mock gh: unhandled: $ALL_ARGS" >&2; exit 1
GH_MOCK_EOF
        chmod +x "$PR_MOCK_BIN/gh"

        # Create mock codex (not called during setup, but required by command -v check)
        cat > "$PR_MOCK_BIN/codex" << 'CODEX_MOCK_EOF'
#!/bin/bash
exit 0
CODEX_MOCK_EOF
        chmod +x "$PR_MOCK_BIN/codex"

        # Run setup-pr-loop.sh with --codex-model override
        pr_setup_exit=0
        pr_output=$(cd "$PR_E2E_PROJECT" && \
            CLAUDE_PROJECT_DIR="$PR_E2E_PROJECT" \
            XDG_CONFIG_HOME="$TEST_DIR/no-user-config" \
            PATH="$PR_MOCK_BIN:$PATH" \
            timeout 30 bash "$SETUP_PR_LOOP" --claude --codex-model override-model:xhigh 2>&1) || pr_setup_exit=$?

        assert_eq "PR loop e2e: setup-pr-loop.sh exited successfully" \
            "0" "$pr_setup_exit"

        # Find the generated PR loop state.md
        PR_STATE_FILE=$(find "$PR_E2E_PROJECT/.humanize/pr-loop" -name "state.md" 2>/dev/null | head -1 || true)
        if [[ -z "$PR_STATE_FILE" ]]; then
            fail "PR loop e2e: state.md was created" "non-empty path" "empty"
        else
            pass "PR loop e2e: state.md was created"

            # Assert --codex-model override is stored in state, not config values
            assert_eq "PR loop e2e: --codex-model set codex_model (override-model)" \
                "override-model" "$(grep '^codex_model:' "$PR_STATE_FILE" | sed 's/codex_model: *//')"

            assert_eq "PR loop e2e: --codex-model set codex_effort (xhigh)" \
                "xhigh" "$(grep '^codex_effort:' "$PR_STATE_FILE" | sed 's/codex_effort: *//')"
        fi
    fi
fi

echo ""

# ========================================
# ask-codex runtime behavioral test
# ========================================

echo "--- ask-codex runtime behavioral ---"

if [[ ! -f "$ASK_CODEX" ]]; then
    skip "ask-codex runtime test requires ask-codex.sh" "file not found"
else
    setup_test_dir
    ASK_CFG_PROJECT="$TEST_DIR/ask-cfg-project"
    init_test_git_repo "$ASK_CFG_PROJECT"
    mkdir -p "$ASK_CFG_PROJECT/.humanize"
    printf '{"codex_model": "o3-mini", "codex_effort": "low"}' > "$ASK_CFG_PROJECT/.humanize/config.json"

    # Create a mock codex that outputs a fixed response
    MOCK_BIN="$TEST_DIR/mock-bin"
    mkdir -p "$MOCK_BIN"
    cat > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/bin/bash
echo "mock codex response"
exit 0
MOCK_EOF
    chmod +x "$MOCK_BIN/codex"

    # Run ask-codex with config-backed defaults (no --codex-model flag)
    ask_stderr=$(cd "$ASK_CFG_PROJECT" && \
        CLAUDE_PROJECT_DIR="$ASK_CFG_PROJECT" \
        XDG_CONFIG_HOME="$TEST_DIR/no-user-config" \
        PATH="$MOCK_BIN:$PATH" \
        timeout 30 bash "$ASK_CODEX" "test question" 2>&1 >/dev/null) || true

    # Stderr should report config-backed model and effort
    if echo "$ask_stderr" | grep -q 'model=o3-mini'; then
        pass "ask-codex runtime: config-backed model reported in stderr (o3-mini)"
    else
        fail "ask-codex runtime: config-backed model reported in stderr (o3-mini)" "contains 'model=o3-mini'" "$ask_stderr"
    fi

    if echo "$ask_stderr" | grep -q 'effort=low'; then
        pass "ask-codex runtime: config-backed effort reported in stderr (low)"
    else
        fail "ask-codex runtime: config-backed effort reported in stderr (low)" "contains 'effort=low'" "$ask_stderr"
    fi

    # Run ask-codex with --codex-model override
    override_stderr=$(cd "$ASK_CFG_PROJECT" && \
        CLAUDE_PROJECT_DIR="$ASK_CFG_PROJECT" \
        XDG_CONFIG_HOME="$TEST_DIR/no-user-config" \
        PATH="$MOCK_BIN:$PATH" \
        timeout 30 bash "$ASK_CODEX" --codex-model override-model:xhigh "test question" 2>&1 >/dev/null) || true

    if echo "$override_stderr" | grep -q 'model=override-model'; then
        pass "ask-codex runtime: --codex-model override reported in stderr (override-model)"
    else
        fail "ask-codex runtime: --codex-model override reported in stderr (override-model)" "contains 'model=override-model'" "$override_stderr"
    fi

    if echo "$override_stderr" | grep -q 'effort=xhigh'; then
        pass "ask-codex runtime: --codex-model override effort in stderr (xhigh)"
    else
        fail "ask-codex runtime: --codex-model override effort in stderr (xhigh)" "contains 'effort=xhigh'" "$override_stderr"
    fi
fi

echo ""

# ========================================
# Summary
# ========================================

print_test_summary "Unified Codex Config Test Summary"
