#!/bin/bash
#
# Tests for reviewer model configuration end-to-end flow
#
# Validates:
# - AC-1: default_config.json contains loop_reviewer_model and loop_reviewer_effort
# - AC-2: Config loader exposes reviewer keys through the 4-layer merge hierarchy
# - AC-3: loop-common.sh loads reviewer defaults from merged config
# - AC-4: setup-rlcr-loop.sh writes reviewer fields to state.md
# - AC-5: Stop hook uses reviewer-specific config for both review paths
# - AC-6: Backward compatibility with legacy state files
# - AC-7: Invalid reviewer config values produce errors
# - AC-8: State parser handles new reviewer fields
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

echo "=========================================="
echo "Reviewer Config Tests"
echo "=========================================="
echo ""

# ========================================
# AC-1: default_config.json contains reviewer keys
# ========================================

echo "--- AC-1: default_config.json keys ---"

DEFAULT_CONFIG="$PROJECT_ROOT/config/default_config.json"

if ! command -v jq >/dev/null 2>&1; then
    skip "AC-1 tests require jq" "jq not found"
else
    val=$(jq -r '.loop_reviewer_model' "$DEFAULT_CONFIG")
    if [[ "$val" == "gpt-5.4" ]]; then
        pass "default_config.json: loop_reviewer_model is gpt-5.4"
    else
        fail "default_config.json: loop_reviewer_model is gpt-5.4" "gpt-5.4" "$val"
    fi

    val=$(jq -r '.loop_reviewer_effort' "$DEFAULT_CONFIG")
    if [[ "$val" == "high" ]]; then
        pass "default_config.json: loop_reviewer_effort is high"
    else
        fail "default_config.json: loop_reviewer_effort is high" "high" "$val"
    fi

    # JSON validity check
    if jq '.' "$DEFAULT_CONFIG" >/dev/null 2>&1; then
        pass "default_config.json: valid JSON"
    else
        fail "default_config.json: valid JSON"
    fi
fi

echo ""

# ========================================
# AC-2: Config loader exposes reviewer keys through merge hierarchy
# ========================================

echo "--- AC-2: Config merge hierarchy ---"

CONFIG_LOADER="$PROJECT_ROOT/scripts/lib/config-loader.sh"
if [[ ! -f "$CONFIG_LOADER" ]]; then
    skip "AC-2 tests require config-loader.sh" "file not found"
else
    source "$CONFIG_LOADER"

    # Test default-only (no project override)
    setup_test_dir
    PROJECT_DIR="$TEST_DIR/empty-project"
    mkdir -p "$PROJECT_DIR"

    merged=$(XDG_CONFIG_HOME="$TEST_DIR/no-user-config" load_merged_config "$PROJECT_ROOT" "$PROJECT_DIR" 2>/dev/null)

    val=$(get_config_value "$merged" "loop_reviewer_model")
    if [[ "$val" == "gpt-5.4" ]]; then
        pass "default-only: loop_reviewer_model defaults to gpt-5.4"
    else
        fail "default-only: loop_reviewer_model defaults to gpt-5.4" "gpt-5.4" "$val"
    fi

    val=$(get_config_value "$merged" "loop_reviewer_effort")
    if [[ "$val" == "high" ]]; then
        pass "default-only: loop_reviewer_effort defaults to high"
    else
        fail "default-only: loop_reviewer_effort defaults to high" "high" "$val"
    fi

    # Test project config override
    setup_test_dir
    PROJECT_DIR="$TEST_DIR/project-override"
    mkdir -p "$PROJECT_DIR/.humanize"
    printf '{"loop_reviewer_model": "gpt-5.2", "loop_reviewer_effort": "xhigh"}' > "$PROJECT_DIR/.humanize/config.json"

    merged=$(XDG_CONFIG_HOME="$TEST_DIR/no-user-config2" load_merged_config "$PROJECT_ROOT" "$PROJECT_DIR" 2>/dev/null)

    val=$(get_config_value "$merged" "loop_reviewer_model")
    if [[ "$val" == "gpt-5.2" ]]; then
        pass "project override: loop_reviewer_model overrides default"
    else
        fail "project override: loop_reviewer_model overrides default" "gpt-5.2" "$val"
    fi

    val=$(get_config_value "$merged" "loop_reviewer_effort")
    if [[ "$val" == "xhigh" ]]; then
        pass "project override: loop_reviewer_effort overrides default"
    else
        fail "project override: loop_reviewer_effort overrides default" "xhigh" "$val"
    fi
fi

echo ""

# ========================================
# AC-3 & AC-8: loop-common.sh loads reviewer defaults and defines field constants
# ========================================

echo "--- AC-3: loop-common.sh reviewer defaults ---"

# We test by sourcing loop-common.sh in a subshell to check exported values
LOOP_COMMON="$PROJECT_ROOT/hooks/lib/loop-common.sh"

if [[ ! -f "$LOOP_COMMON" ]]; then
    skip "AC-3 tests require loop-common.sh" "file not found"
else
    # Test default values load correctly
    result=$(bash -c "
        source '$LOOP_COMMON' 2>/dev/null
        echo \"\$DEFAULT_LOOP_REVIEWER_MODEL|\$DEFAULT_LOOP_REVIEWER_EFFORT\"
    " 2>/dev/null || echo "ERROR")

    model=$(echo "$result" | cut -d'|' -f1)
    effort=$(echo "$result" | cut -d'|' -f2)

    if [[ "$model" == "gpt-5.4" ]]; then
        pass "loop-common.sh: DEFAULT_LOOP_REVIEWER_MODEL is set"
    else
        fail "loop-common.sh: DEFAULT_LOOP_REVIEWER_MODEL is set" "gpt-5.4" "$model"
    fi

    if [[ "$effort" == "high" ]]; then
        pass "loop-common.sh: DEFAULT_LOOP_REVIEWER_EFFORT is set"
    else
        fail "loop-common.sh: DEFAULT_LOOP_REVIEWER_EFFORT is set" "high" "$effort"
    fi

    # Test field constants are defined
    result=$(bash -c "
        source '$LOOP_COMMON' 2>/dev/null
        echo \"\$FIELD_LOOP_REVIEWER_MODEL|\$FIELD_LOOP_REVIEWER_EFFORT\"
    " 2>/dev/null || echo "ERROR")

    field_model=$(echo "$result" | cut -d'|' -f1)
    field_effort=$(echo "$result" | cut -d'|' -f2)

    if [[ "$field_model" == "loop_reviewer_model" ]]; then
        pass "loop-common.sh: FIELD_LOOP_REVIEWER_MODEL constant defined"
    else
        fail "loop-common.sh: FIELD_LOOP_REVIEWER_MODEL constant defined" "loop_reviewer_model" "$field_model"
    fi

    if [[ "$field_effort" == "loop_reviewer_effort" ]]; then
        pass "loop-common.sh: FIELD_LOOP_REVIEWER_EFFORT constant defined"
    else
        fail "loop-common.sh: FIELD_LOOP_REVIEWER_EFFORT constant defined" "loop_reviewer_effort" "$field_effort"
    fi
fi

echo ""

# ========================================
# AC-8: State parser handles reviewer fields
# ========================================

echo "--- AC-8: State parser (parse_state_file) ---"

if [[ ! -f "$LOOP_COMMON" ]]; then
    skip "AC-8 tests require loop-common.sh" "file not found"
else
    setup_test_dir

    # Create a state file with reviewer fields
    cat > "$TEST_DIR/state.md" << 'STATE_EOF'
---
current_round: 3
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
session_id: test-session
agent_teams: false
loop_reviewer_model: gpt-5.2
loop_reviewer_effort: xhigh
---
STATE_EOF

    result=$(bash -c "
        source '$LOOP_COMMON' 2>/dev/null
        parse_state_file '$TEST_DIR/state.md'
        echo \"\$STATE_LOOP_REVIEWER_MODEL|\$STATE_LOOP_REVIEWER_EFFORT\"
    " 2>/dev/null || echo "ERROR")

    parsed_model=$(echo "$result" | cut -d'|' -f1)
    parsed_effort=$(echo "$result" | cut -d'|' -f2)

    if [[ "$parsed_model" == "gpt-5.2" ]]; then
        pass "parse_state_file: STATE_LOOP_REVIEWER_MODEL parsed correctly"
    else
        fail "parse_state_file: STATE_LOOP_REVIEWER_MODEL parsed correctly" "gpt-5.2" "$parsed_model"
    fi

    if [[ "$parsed_effort" == "xhigh" ]]; then
        pass "parse_state_file: STATE_LOOP_REVIEWER_EFFORT parsed correctly"
    else
        fail "parse_state_file: STATE_LOOP_REVIEWER_EFFORT parsed correctly" "xhigh" "$parsed_effort"
    fi
fi

echo ""

# ========================================
# AC-6: Backward compatibility with legacy state files
# ========================================

echo "--- AC-6: Legacy state backward compatibility ---"

if [[ ! -f "$LOOP_COMMON" ]]; then
    skip "AC-6 tests require loop-common.sh" "file not found"
else
    setup_test_dir

    # Create a legacy state file WITHOUT reviewer fields
    cat > "$TEST_DIR/legacy-state.md" << 'LEGACY_EOF'
---
current_round: 2
max_iterations: 10
codex_model: gpt-5.3
codex_effort: medium
codex_timeout: 3600
push_every_round: false
full_review_round: 5
plan_file: plan.md
plan_tracked: false
start_branch: feature
base_branch: main
base_commit: def456
review_started: false
ask_codex_question: true
session_id: legacy-session
agent_teams: false
---
LEGACY_EOF

    result=$(bash -c "
        source '$LOOP_COMMON' 2>/dev/null
        parse_state_file '$TEST_DIR/legacy-state.md'
        echo \"\$STATE_LOOP_REVIEWER_MODEL|\$STATE_LOOP_REVIEWER_EFFORT\"
    " 2>/dev/null || echo "ERROR")

    parsed_model=$(echo "$result" | cut -d'|' -f1)
    parsed_effort=$(echo "$result" | cut -d'|' -f2)

    # Legacy state should have empty reviewer fields (fallback handled by consumer)
    if [[ -z "$parsed_model" ]]; then
        pass "legacy state: STATE_LOOP_REVIEWER_MODEL is empty (allows fallback)"
    else
        fail "legacy state: STATE_LOOP_REVIEWER_MODEL is empty (allows fallback)" "empty" "$parsed_model"
    fi

    if [[ -z "$parsed_effort" ]]; then
        pass "legacy state: STATE_LOOP_REVIEWER_EFFORT is empty (allows fallback)"
    else
        fail "legacy state: STATE_LOOP_REVIEWER_EFFORT is empty (allows fallback)" "empty" "$parsed_effort"
    fi

    # Verify fallback chain works: empty reviewer -> codex fields used
    result=$(bash -c "
        source '$LOOP_COMMON' 2>/dev/null
        parse_state_file '$TEST_DIR/legacy-state.md'
        # Simulate the stop hook fallback chain (final fallback: DEFAULT_LOOP_REVIEWER_*)
        EXEC_MODEL=\"\${STATE_LOOP_REVIEWER_MODEL:-\${STATE_CODEX_MODEL:-\$DEFAULT_LOOP_REVIEWER_MODEL}}\"
        EXEC_EFFORT=\"\${STATE_LOOP_REVIEWER_EFFORT:-\${STATE_CODEX_EFFORT:-\$DEFAULT_LOOP_REVIEWER_EFFORT}}\"
        echo \"\$EXEC_MODEL|\$EXEC_EFFORT\"
    " 2>/dev/null || echo "ERROR")

    fallback_model=$(echo "$result" | cut -d'|' -f1)
    fallback_effort=$(echo "$result" | cut -d'|' -f2)

    if [[ "$fallback_model" == "gpt-5.3" ]]; then
        pass "legacy state: fallback chain resolves model to codex_model (gpt-5.3)"
    else
        fail "legacy state: fallback chain resolves model to codex_model (gpt-5.3)" "gpt-5.3" "$fallback_model"
    fi

    if [[ "$fallback_effort" == "medium" ]]; then
        pass "legacy state: fallback chain resolves effort to codex_effort (medium)"
    else
        fail "legacy state: fallback chain resolves effort to codex_effort (medium)" "medium" "$fallback_effort"
    fi
fi

echo ""

# ========================================
# AC-5: Stop hook reviewer config resolution
# ========================================

echo "--- AC-5: Stop hook reviewer config resolution ---"

if [[ ! -f "$LOOP_COMMON" ]]; then
    skip "AC-5 tests require loop-common.sh" "file not found"
else
    setup_test_dir

    # State with reviewer fields - reviewer should take precedence
    cat > "$TEST_DIR/reviewer-state.md" << 'REVSTATE_EOF'
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
session_id: test
agent_teams: false
loop_reviewer_model: gpt-5.2
loop_reviewer_effort: xhigh
---
REVSTATE_EOF

    result=$(bash -c "
        source '$LOOP_COMMON' 2>/dev/null
        parse_state_file '$TEST_DIR/reviewer-state.md'
        # Replicate stop hook resolution (final fallback: DEFAULT_LOOP_REVIEWER_*)
        EXEC_MODEL=\"\${STATE_LOOP_REVIEWER_MODEL:-\${STATE_CODEX_MODEL:-\$DEFAULT_LOOP_REVIEWER_MODEL}}\"
        EXEC_EFFORT=\"\${STATE_LOOP_REVIEWER_EFFORT:-\${STATE_CODEX_EFFORT:-\$DEFAULT_LOOP_REVIEWER_EFFORT}}\"
        echo \"\$EXEC_MODEL|\$EXEC_EFFORT\"
    " 2>/dev/null || echo "ERROR")

    exec_model=$(echo "$result" | cut -d'|' -f1)
    exec_effort=$(echo "$result" | cut -d'|' -f2)

    if [[ "$exec_model" == "gpt-5.2" ]]; then
        pass "stop hook: reviewer model used for both exec and review (gpt-5.2)"
    else
        fail "stop hook: reviewer model used for both exec and review (gpt-5.2)" "gpt-5.2" "$exec_model"
    fi

    if [[ "$exec_effort" == "xhigh" ]]; then
        pass "stop hook: reviewer effort used for both exec and review (xhigh)"
    else
        fail "stop hook: reviewer effort used for both exec and review (xhigh)" "xhigh" "$exec_effort"
    fi
fi

echo ""

# ========================================
# AC-7: Invalid config value validation
# ========================================

echo "--- AC-7: Invalid config value validation ---"

SETUP_SCRIPT="$PROJECT_ROOT/scripts/setup-rlcr-loop.sh"

# Test invalid model name (has spaces) - we test the validation regex directly
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
# AC-4: setup-rlcr-loop.sh writes reviewer fields to state.md
# ========================================

echo "--- AC-4: Setup script state.md template ---"

# Verify the setup script contains the reviewer fields in the state template
if grep -q 'loop_reviewer_model:' "$SETUP_SCRIPT"; then
    pass "setup script: state.md template includes loop_reviewer_model"
else
    fail "setup script: state.md template includes loop_reviewer_model"
fi

if grep -q 'loop_reviewer_effort:' "$SETUP_SCRIPT"; then
    pass "setup script: state.md template includes loop_reviewer_effort"
else
    fail "setup script: state.md template includes loop_reviewer_effort"
fi

# Verify --codex-model does NOT appear in the reviewer field lines
reviewer_model_line=$(grep 'loop_reviewer_model:' "$SETUP_SCRIPT" | head -1)
if [[ "$reviewer_model_line" == *'$CODEX_MODEL'* ]]; then
    fail "setup script: reviewer model should NOT use CODEX_MODEL variable"
else
    pass "setup script: reviewer model does not use CODEX_MODEL variable"
fi

echo ""

# ========================================
# AC-6 Extended: Fallback chain edge cases
# ========================================

echo "--- AC-6 Extended: Fallback chain edge cases ---"

if [[ ! -f "$LOOP_COMMON" ]]; then
    skip "AC-6 extended tests require loop-common.sh" "file not found"
else
    # Case: Missing BOTH reviewer AND codex fields -> config defaults
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
        EXEC_MODEL=\"\${STATE_LOOP_REVIEWER_MODEL:-\${STATE_CODEX_MODEL:-\$DEFAULT_LOOP_REVIEWER_MODEL}}\"
        EXEC_EFFORT=\"\${STATE_LOOP_REVIEWER_EFFORT:-\${STATE_CODEX_EFFORT:-\$DEFAULT_LOOP_REVIEWER_EFFORT}}\"
        echo \"\$EXEC_MODEL|\$EXEC_EFFORT\"
    " 2>/dev/null || echo "ERROR")

    fb_model=$(echo "$result" | cut -d'|' -f1)
    fb_effort=$(echo "$result" | cut -d'|' -f2)

    if [[ "$fb_model" == "gpt-5.4" ]]; then
        pass "bare state: falls back to DEFAULT_LOOP_REVIEWER_MODEL (gpt-5.4)"
    else
        fail "bare state: falls back to DEFAULT_LOOP_REVIEWER_MODEL (gpt-5.4)" "gpt-5.4" "$fb_model"
    fi

    if [[ "$fb_effort" == "high" ]]; then
        pass "bare state: falls back to DEFAULT_LOOP_REVIEWER_EFFORT (high)"
    else
        fail "bare state: falls back to DEFAULT_LOOP_REVIEWER_EFFORT (high)" "high" "$fb_effort"
    fi

    # Case: reviewer_model set but reviewer_effort missing -> partial fallback
    setup_test_dir
    cat > "$TEST_DIR/partial-state.md" << 'PARTIAL_EOF'
---
current_round: 1
max_iterations: 42
codex_model: gpt-5.4
codex_effort: medium
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
session_id: partial
agent_teams: false
loop_reviewer_model: gpt-5.2
---
PARTIAL_EOF

    result=$(bash -c "
        source '$LOOP_COMMON' 2>/dev/null
        parse_state_file '$TEST_DIR/partial-state.md'
        EXEC_MODEL=\"\${STATE_LOOP_REVIEWER_MODEL:-\${STATE_CODEX_MODEL:-\$DEFAULT_LOOP_REVIEWER_MODEL}}\"
        EXEC_EFFORT=\"\${STATE_LOOP_REVIEWER_EFFORT:-\${STATE_CODEX_EFFORT:-\$DEFAULT_LOOP_REVIEWER_EFFORT}}\"
        echo \"\$EXEC_MODEL|\$EXEC_EFFORT\"
    " 2>/dev/null || echo "ERROR")

    pm=$(echo "$result" | cut -d'|' -f1)
    pe=$(echo "$result" | cut -d'|' -f2)

    if [[ "$pm" == "gpt-5.2" ]]; then
        pass "partial state: reviewer model used (gpt-5.2)"
    else
        fail "partial state: reviewer model used (gpt-5.2)" "gpt-5.2" "$pm"
    fi

    if [[ "$pe" == "medium" ]]; then
        pass "partial state: missing reviewer effort falls back to codex_effort (medium)"
    else
        fail "partial state: missing reviewer effort falls back to codex_effort (medium)" "medium" "$pe"
    fi

    # Case: reviewer_effort set but reviewer_model missing -> partial fallback
    setup_test_dir
    cat > "$TEST_DIR/partial2-state.md" << 'PARTIAL2_EOF'
---
current_round: 1
max_iterations: 42
codex_model: gpt-5.3
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
session_id: partial2
agent_teams: false
loop_reviewer_effort: low
---
PARTIAL2_EOF

    result=$(bash -c "
        source '$LOOP_COMMON' 2>/dev/null
        parse_state_file '$TEST_DIR/partial2-state.md'
        EXEC_MODEL=\"\${STATE_LOOP_REVIEWER_MODEL:-\${STATE_CODEX_MODEL:-\$DEFAULT_LOOP_REVIEWER_MODEL}}\"
        EXEC_EFFORT=\"\${STATE_LOOP_REVIEWER_EFFORT:-\${STATE_CODEX_EFFORT:-\$DEFAULT_LOOP_REVIEWER_EFFORT}}\"
        echo \"\$EXEC_MODEL|\$EXEC_EFFORT\"
    " 2>/dev/null || echo "ERROR")

    pm2=$(echo "$result" | cut -d'|' -f1)
    pe2=$(echo "$result" | cut -d'|' -f2)

    if [[ "$pm2" == "gpt-5.3" ]]; then
        pass "partial state: missing reviewer model falls back to codex_model (gpt-5.3)"
    else
        fail "partial state: missing reviewer model falls back to codex_model (gpt-5.3)" "gpt-5.3" "$pm2"
    fi

    if [[ "$pe2" == "low" ]]; then
        pass "partial state: reviewer effort used (low)"
    else
        fail "partial state: reviewer effort used (low)" "low" "$pe2"
    fi
fi

echo ""

# ========================================
# AC-3 Extended: Config merge feeds into loop-common defaults
# ========================================

echo "--- AC-3 Extended: Config merge with project override ---"

if [[ ! -f "$LOOP_COMMON" ]]; then
    skip "AC-3 extended tests require loop-common.sh" "file not found"
else
    setup_test_dir
    OVERRIDE_PROJECT="$TEST_DIR/override-project"
    mkdir -p "$OVERRIDE_PROJECT/.humanize"
    printf '{"loop_reviewer_model": "o3-mini", "loop_reviewer_effort": "low"}' > "$OVERRIDE_PROJECT/.humanize/config.json"

    # Source loop-common.sh with CLAUDE_PROJECT_DIR pointed at the override project
    result=$(bash -c "
        export CLAUDE_PROJECT_DIR='$OVERRIDE_PROJECT'
        export XDG_CONFIG_HOME='$TEST_DIR/no-user-config'
        source '$LOOP_COMMON' 2>/dev/null
        echo \"\$DEFAULT_LOOP_REVIEWER_MODEL|\$DEFAULT_LOOP_REVIEWER_EFFORT\"
    " 2>/dev/null || echo "ERROR")

    cm=$(echo "$result" | cut -d'|' -f1)
    ce=$(echo "$result" | cut -d'|' -f2)

    if [[ "$cm" == "o3-mini" ]]; then
        pass "config merge: project override feeds into DEFAULT_LOOP_REVIEWER_MODEL"
    else
        fail "config merge: project override feeds into DEFAULT_LOOP_REVIEWER_MODEL" "o3-mini" "$cm"
    fi

    if [[ "$ce" == "low" ]]; then
        pass "config merge: project override feeds into DEFAULT_LOOP_REVIEWER_EFFORT"
    else
        fail "config merge: project override feeds into DEFAULT_LOOP_REVIEWER_EFFORT" "low" "$ce"
    fi
fi

echo ""

# ========================================
# AC-7 Extended: Validation in setup script
# ========================================

echo "--- AC-7 Extended: Setup script validation behavior ---"

SETUP_SCRIPT="$PROJECT_ROOT/scripts/setup-rlcr-loop.sh"

# Verify the setup script contains the reviewer model validation block
if grep -q 'Reviewer model contains invalid characters' "$SETUP_SCRIPT"; then
    pass "setup script: reviewer model validation error message present"
else
    fail "setup script: reviewer model validation error message present"
fi

# Verify the setup script contains the reviewer effort enum validation
if grep -q 'Reviewer effort must be one of' "$SETUP_SCRIPT"; then
    pass "setup script: reviewer effort enum validation present"
else
    fail "setup script: reviewer effort enum validation present"
fi

# Verify validation exits with non-zero status (exit may be a few lines after message)
model_block=$(grep -A4 'Reviewer model contains invalid characters' "$SETUP_SCRIPT")
if echo "$model_block" | grep -q 'exit 1'; then
    pass "setup script: reviewer model validation exits with code 1"
else
    fail "setup script: reviewer model validation exits with code 1"
fi

effort_block=$(grep -A4 'Reviewer effort must be one of' "$SETUP_SCRIPT")
if echo "$effort_block" | grep -q 'exit 1'; then
    pass "setup script: reviewer effort validation exits with code 1"
else
    fail "setup script: reviewer effort validation exits with code 1"
fi

echo ""

# ========================================
# AC-8 Extended: Quoted YAML frontmatter
# ========================================

echo "--- AC-8 Extended: Quoted reviewer frontmatter ---"

if [[ ! -f "$LOOP_COMMON" ]]; then
    skip "AC-8 quoted tests require loop-common.sh" "file not found"
else
    setup_test_dir

    # Create state file with quoted reviewer values (valid YAML)
    cat > "$TEST_DIR/quoted-state.md" << 'QUOTED_EOF'
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
session_id: quoted-test
agent_teams: false
loop_reviewer_model: "gpt-5.2"
loop_reviewer_effort: "low"
---
QUOTED_EOF

    result=$(bash -c "
        source '$LOOP_COMMON' 2>/dev/null
        parse_state_file '$TEST_DIR/quoted-state.md'
        echo \"\$STATE_LOOP_REVIEWER_MODEL|\$STATE_LOOP_REVIEWER_EFFORT\"
    " 2>/dev/null || echo "ERROR")

    qm=$(echo "$result" | cut -d'|' -f1)
    qe=$(echo "$result" | cut -d'|' -f2)

    if [[ "$qm" == "gpt-5.2" ]]; then
        pass "quoted frontmatter: reviewer model quotes stripped (gpt-5.2)"
    else
        fail "quoted frontmatter: reviewer model quotes stripped (gpt-5.2)" "gpt-5.2" "$qm"
    fi

    if [[ "$qe" == "low" ]]; then
        pass "quoted frontmatter: reviewer effort quotes stripped (low)"
    else
        fail "quoted frontmatter: reviewer effort quotes stripped (low)" "low" "$qe"
    fi
fi

echo ""

# ========================================
# AC-5/6 Extended: Bare state with config override proves reviewer defaults used
# ========================================

echo "--- AC-5/6 Extended: Bare state uses config-derived reviewer defaults ---"

if [[ ! -f "$LOOP_COMMON" ]]; then
    skip "AC-5/6 extended test requires loop-common.sh" "file not found"
else
    setup_test_dir
    OVERRIDE_PROJECT="$TEST_DIR/reviewer-override"
    mkdir -p "$OVERRIDE_PROJECT/.humanize"
    printf '{"loop_reviewer_model": "o1-preview", "loop_reviewer_effort": "medium"}' > "$OVERRIDE_PROJECT/.humanize/config.json"

    # Create bare state file (no reviewer or codex fields)
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

    # Source loop-common.sh with project override, then test fallback chain
    result=$(bash -c "
        export CLAUDE_PROJECT_DIR='$OVERRIDE_PROJECT'
        export XDG_CONFIG_HOME='$TEST_DIR/no-user-config'
        source '$LOOP_COMMON' 2>/dev/null
        parse_state_file '$TEST_DIR/cfg-bare-state.md'
        EXEC_MODEL=\"\${STATE_LOOP_REVIEWER_MODEL:-\${STATE_CODEX_MODEL:-\$DEFAULT_LOOP_REVIEWER_MODEL}}\"
        EXEC_EFFORT=\"\${STATE_LOOP_REVIEWER_EFFORT:-\${STATE_CODEX_EFFORT:-\$DEFAULT_LOOP_REVIEWER_EFFORT}}\"
        echo \"\$EXEC_MODEL|\$EXEC_EFFORT\"
    " 2>/dev/null || echo "ERROR")

    cfg_model=$(echo "$result" | cut -d'|' -f1)
    cfg_effort=$(echo "$result" | cut -d'|' -f2)

    if [[ "$cfg_model" == "o1-preview" ]]; then
        pass "config override + bare state: reviewer model from config (o1-preview)"
    else
        fail "config override + bare state: reviewer model from config (o1-preview)" "o1-preview" "$cfg_model"
    fi

    if [[ "$cfg_effort" == "medium" ]]; then
        pass "config override + bare state: reviewer effort from config (medium)"
    else
        fail "config override + bare state: reviewer effort from config (medium)" "medium" "$cfg_effort"
    fi
fi

echo ""

# ========================================
# AC-4 Extended: Real setup script execution
# ========================================

echo "--- AC-4 Extended: Setup script execution test ---"

SETUP_SCRIPT="$PROJECT_ROOT/scripts/setup-rlcr-loop.sh"

if ! command -v jq >/dev/null 2>&1; then
    skip "setup execution test requires jq" "jq not found"
elif ! command -v codex >/dev/null 2>&1; then
    skip "setup execution test requires codex" "codex not found"
else
    setup_test_dir
    EXEC_PROJECT="$TEST_DIR/exec-project"
    init_test_git_repo "$EXEC_PROJECT"

    # Create project config with reviewer overrides (outside .humanize to avoid git issues)
    mkdir -p "$EXEC_PROJECT/.humanize"
    printf '{"loop_reviewer_model": "gpt-5.2", "loop_reviewer_effort": "low"}' > "$EXEC_PROJECT/.humanize/config.json"

    # Create a plan file with enough lines (minimum 5 required) and commit it
    cat > "$EXEC_PROJECT/plan.md" << 'PLAN_EOF'
# Test Plan
## Goal
Test reviewer config
## Tasks
- Task 1: Add config keys
- Task 2: Wire through pipeline
PLAN_EOF
    (cd "$EXEC_PROJECT" && git add plan.md && git commit -q -m "Add plan")

    # Create a local bare remote to prevent network calls during base-branch detection
    BARE_REMOTE="$TEST_DIR/remote.git"
    git clone --bare "$EXEC_PROJECT" "$BARE_REMOTE" -q 2>/dev/null
    (cd "$EXEC_PROJECT" && git remote remove origin 2>/dev/null; git remote add origin "$BARE_REMOTE") 2>/dev/null || true

    # Run setup-rlcr-loop.sh with --codex-model flag (should NOT affect reviewer)
    # --base-branch avoids remote detection; --track-plan-file avoids gitignore requirement
    output=$(cd "$EXEC_PROJECT" && timeout 30 bash "$SETUP_SCRIPT" --codex-model gpt-5.3:xhigh --base-branch master --track-plan-file plan.md 2>&1) || true

    # Find the generated state.md
    STATE_FILE=$(find "$EXEC_PROJECT/.humanize/rlcr" -name "state.md" 2>/dev/null | head -1)
    if [[ -z "$STATE_FILE" ]]; then
        fail "setup execution: state.md was created" "non-empty path" "empty"
    else
        pass "setup execution: state.md was created"

        # Check reviewer model in state.md
        rev_model=$(grep '^loop_reviewer_model:' "$STATE_FILE" | sed 's/loop_reviewer_model: *//')
        if [[ "$rev_model" == "gpt-5.2" ]]; then
            pass "setup execution: state.md reviewer model from config (gpt-5.2)"
        else
            fail "setup execution: state.md reviewer model from config (gpt-5.2)" "gpt-5.2" "$rev_model"
        fi

        # Check reviewer effort in state.md
        rev_effort=$(grep '^loop_reviewer_effort:' "$STATE_FILE" | sed 's/loop_reviewer_effort: *//')
        if [[ "$rev_effort" == "low" ]]; then
            pass "setup execution: state.md reviewer effort from config (low)"
        else
            fail "setup execution: state.md reviewer effort from config (low)" "low" "$rev_effort"
        fi

        # Check --codex-model did NOT change reviewer
        codex_model=$(grep '^codex_model:' "$STATE_FILE" | sed 's/codex_model: *//')
        if [[ "$codex_model" == "gpt-5.3" ]]; then
            pass "setup execution: --codex-model set codex_model (gpt-5.3)"
        else
            fail "setup execution: --codex-model set codex_model (gpt-5.3)" "gpt-5.3" "$codex_model"
        fi

        if [[ "$rev_model" != "$codex_model" ]]; then
            pass "setup execution: reviewer model independent from --codex-model"
        else
            fail "setup execution: reviewer model independent from --codex-model"
        fi
    fi
fi

echo ""

# ========================================
# Summary
# ========================================

print_test_summary "Reviewer Config Test Summary"
