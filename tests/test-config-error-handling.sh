#!/bin/bash
#
# Tests for error handling in scripts/lib/config-loader.sh
#
# Validates:
# - Missing default_config.json causes a fatal (non-zero) exit
# - Malformed JSON in project config emits a warning and falls back to defaults
# - Malformed JSON in user config emits a warning and falls back to defaults
# - Empty ({}) project config is valid and uses all defaults
# - Missing project config file is not fatal; defaults are used
# - Missing optional user config file is not fatal; defaults are used
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

CONFIG_LOADER="$PROJECT_ROOT/scripts/lib/config-loader.sh"

echo "=========================================="
echo "Config Error Handling Tests"
echo "=========================================="
echo ""

if [[ ! -f "$CONFIG_LOADER" ]]; then
    echo "FATAL: config-loader.sh not found at $CONFIG_LOADER" >&2
    exit 1
fi

# shellcheck source=../scripts/lib/config-loader.sh
source "$CONFIG_LOADER"

EXPECTED_CODING_MODEL="$(jq -r '.coding_worker_model' "$PROJECT_ROOT/config/default_config.json")"
EXPECTED_ANALYZING_MODEL="$(jq -r '.analyzing_worker_model' "$PROJECT_ROOT/config/default_config.json")"

# ========================================
# Test 1: Missing default_config.json is fatal
# ========================================

setup_test_dir
FAKE_PLUGIN_ROOT="$TEST_DIR/fake-plugin"
mkdir -p "$FAKE_PLUGIN_ROOT/config"
# Intentionally do NOT create default_config.json

PROJECT_DIR="$TEST_DIR/project-fatal"
mkdir -p "$PROJECT_DIR"

if ! load_merged_config "$FAKE_PLUGIN_ROOT" "$PROJECT_DIR" >/dev/null 2>&1; then
    pass "missing default_config.json: load_merged_config exits with non-zero status"
else
    fail "missing default_config.json: load_merged_config exits with non-zero status" \
        "non-zero exit" "zero exit (no error)"
fi

# ========================================
# Test 2: Malformed JSON in project config → warning + fall back to defaults
# ========================================

setup_test_dir
PROJECT_DIR="$TEST_DIR/malformed-project"
mkdir -p "$PROJECT_DIR/.humanize"
printf 'not valid json at all' > "$PROJECT_DIR/.humanize/config.json"

stderr_out=$(XDG_CONFIG_HOME="$TEST_DIR/no-user" \
    load_merged_config "$PROJECT_ROOT" "$PROJECT_DIR" 2>&1 >/dev/null || true)

if echo "$stderr_out" | grep -qi "malformed\|ignoring\|warning"; then
    pass "malformed project config: warning emitted to stderr"
else
    fail "malformed project config: warning emitted to stderr" \
        "warning/ignoring message on stderr" "no warning output"
fi

merged=$(XDG_CONFIG_HOME="$TEST_DIR/no-user" \
    load_merged_config "$PROJECT_ROOT" "$PROJECT_DIR" 2>/dev/null)
val=$(get_config_value "$merged" "coding_worker_model")
if [[ "$val" == "$EXPECTED_CODING_MODEL" ]]; then
    pass "malformed project config: falls back to defaults"
else
    fail "malformed project config: falls back to defaults" "$EXPECTED_CODING_MODEL" "$val"
fi

# ========================================
# Test 3: Malformed JSON in user config → warning + fall back to defaults
# ========================================

setup_test_dir
PROJECT_DIR="$TEST_DIR/malformed-user"
mkdir -p "$PROJECT_DIR"
mkdir -p "$TEST_DIR/bad-user-cfg/humanize"
printf '{bad json here}' > "$TEST_DIR/bad-user-cfg/humanize/config.json"

stderr_out=$(XDG_CONFIG_HOME="$TEST_DIR/bad-user-cfg" \
    load_merged_config "$PROJECT_ROOT" "$PROJECT_DIR" 2>&1 >/dev/null || true)

if echo "$stderr_out" | grep -qi "malformed\|ignoring\|warning"; then
    pass "malformed user config: warning emitted to stderr"
else
    fail "malformed user config: warning emitted to stderr" \
        "warning/ignoring message on stderr" "no warning output"
fi

merged=$(XDG_CONFIG_HOME="$TEST_DIR/bad-user-cfg" \
    load_merged_config "$PROJECT_ROOT" "$PROJECT_DIR" 2>/dev/null)
val=$(get_config_value "$merged" "bitlesson_model")
if [[ "$val" == "haiku" ]]; then
    pass "malformed user config: falls back to defaults"
else
    fail "malformed user config: falls back to defaults" "haiku" "$val"
fi

# ========================================
# Test 4: Empty project config ({}) is valid → use all defaults
# ========================================

setup_test_dir
PROJECT_DIR="$TEST_DIR/empty-proj-cfg"
mkdir -p "$PROJECT_DIR/.humanize"
printf '{}' > "$PROJECT_DIR/.humanize/config.json"

merged=$(XDG_CONFIG_HOME="$TEST_DIR/no-user2" \
    load_merged_config "$PROJECT_ROOT" "$PROJECT_DIR" 2>/dev/null)
val=$(get_config_value "$merged" "coding_worker_model")
if [[ "$val" == "$EXPECTED_CODING_MODEL" ]]; then
    pass "empty project config: uses all defaults"
else
    fail "empty project config: uses all defaults" "$EXPECTED_CODING_MODEL" "$val"
fi

# ========================================
# Test 5: Missing project config file is not fatal
# ========================================

setup_test_dir
PROJECT_DIR="$TEST_DIR/no-proj-cfg"
mkdir -p "$PROJECT_DIR"
# No .humanize/ directory at all

if merged=$(XDG_CONFIG_HOME="$TEST_DIR/no-user3" \
        load_merged_config "$PROJECT_ROOT" "$PROJECT_DIR" 2>/dev/null); then
    val=$(get_config_value "$merged" "coding_worker_model")
    if [[ "$val" == "$EXPECTED_CODING_MODEL" ]]; then
        pass "missing project config file: not fatal, uses defaults"
    else
        fail "missing project config file: not fatal, uses defaults" "$EXPECTED_CODING_MODEL" "$val"
    fi
else
    fail "missing project config file: not fatal, uses defaults" \
        "success with defaults" "fatal error"
fi

# ========================================
# Test 6: Missing user config directory is not fatal
# ========================================

setup_test_dir
PROJECT_DIR="$TEST_DIR/no-user-dir-project"
mkdir -p "$PROJECT_DIR"
# Point XDG_CONFIG_HOME to a non-existent directory

if merged=$(XDG_CONFIG_HOME="$TEST_DIR/does-not-exist" \
        load_merged_config "$PROJECT_ROOT" "$PROJECT_DIR" 2>/dev/null); then
    val=$(get_config_value "$merged" "bitlesson_model")
    if [[ "$val" == "haiku" ]]; then
        pass "missing user config directory: not fatal, uses defaults"
    else
        fail "missing user config directory: not fatal, uses defaults" "haiku" "$val"
    fi
else
    fail "missing user config directory: not fatal, uses defaults" \
        "success with defaults" "fatal error"
fi

print_test_summary "Config Error Handling Tests"
