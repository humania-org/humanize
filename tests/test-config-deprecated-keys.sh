#!/bin/bash
#
# Tests for deprecated config key compatibility in scripts/lib/config-loader.sh
#
# Validates:
# - gen_plan_coding_worker → warns and maps to coding_worker
# - gen_plan_analyzing_worker → warns and maps to analyzing_worker
# - bitlesson_agent_model → warns and maps to bitlesson_model
# - bitlesson_codex_model → warns and maps to bitlesson_model
# - bitlesson_agent_model takes priority over bitlesson_codex_model
# - New key present in user/project config → deprecated key is not applied
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

CONFIG_LOADER="$PROJECT_ROOT/scripts/lib/config-loader.sh"

echo "=========================================="
echo "Config Deprecated Keys Tests"
echo "=========================================="
echo ""

if [[ ! -f "$CONFIG_LOADER" ]]; then
    echo "FATAL: config-loader.sh not found at $CONFIG_LOADER" >&2
    exit 1
fi

# shellcheck source=../scripts/lib/config-loader.sh
source "$CONFIG_LOADER"

# Temp files for capturing stdout and stderr from load_merged_config.
# Avoids the subshell-variable-isolation pitfall of $(...) command substitution.
_STDOUT_FILE=""
_STDERR_FILE=""

# Helper: write project config and invoke load_merged_config.
# Writes stdout to $_STDOUT_FILE and stderr to $_STDERR_FILE.
# Callers must NOT use command substitution to call this function.
run_with_project_config() {
    local config_json="$1"
    local project_dir="$2"
    mkdir -p "$project_dir/.humanize"
    printf '%s' "$config_json" > "$project_dir/.humanize/config.json"
    _STDOUT_FILE="$(mktemp)"
    _STDERR_FILE="$(mktemp)"
    XDG_CONFIG_HOME="$project_dir/.no-user" \
        load_merged_config "$PROJECT_ROOT" "$project_dir" \
        >"$_STDOUT_FILE" 2>"$_STDERR_FILE" || true
}

cleanup_run_files() {
    rm -f "${_STDOUT_FILE:-}" "${_STDERR_FILE:-}"
}

# ========================================
# Test 1: gen_plan_coding_worker → deprecated, maps to coding_worker
# ========================================

setup_test_dir
run_with_project_config '{"gen_plan_coding_worker": "legacy-coder"}' "$TEST_DIR/dep1"

if grep -q "deprecated" "$_STDERR_FILE"; then
    pass "gen_plan_coding_worker: deprecation warning emitted"
else
    fail "gen_plan_coding_worker: deprecation warning emitted" "warning containing 'deprecated'" "no warning"
fi

mapped_val=$(jq -r '.coding_worker // empty' "$_STDOUT_FILE" 2>/dev/null || true)
if [[ "$mapped_val" == "legacy-coder" ]]; then
    pass "gen_plan_coding_worker: value mapped to coding_worker"
else
    fail "gen_plan_coding_worker: value mapped to coding_worker" "legacy-coder" "$mapped_val"
fi
cleanup_run_files

# ========================================
# Test 2: gen_plan_analyzing_worker → deprecated, maps to analyzing_worker
# ========================================

setup_test_dir
run_with_project_config '{"gen_plan_analyzing_worker": "legacy-analyzer"}' "$TEST_DIR/dep2"

if grep -q "deprecated" "$_STDERR_FILE"; then
    pass "gen_plan_analyzing_worker: deprecation warning emitted"
else
    fail "gen_plan_analyzing_worker: deprecation warning emitted" "warning containing 'deprecated'" "no warning"
fi

mapped_val=$(jq -r '.analyzing_worker // empty' "$_STDOUT_FILE" 2>/dev/null || true)
if [[ "$mapped_val" == "legacy-analyzer" ]]; then
    pass "gen_plan_analyzing_worker: value mapped to analyzing_worker"
else
    fail "gen_plan_analyzing_worker: value mapped to analyzing_worker" "legacy-analyzer" "$mapped_val"
fi
cleanup_run_files

# ========================================
# Test 3: bitlesson_agent_model → deprecated, maps to bitlesson_model
# ========================================

setup_test_dir
run_with_project_config '{"bitlesson_agent_model": "legacy-haiku"}' "$TEST_DIR/dep3"

if grep -q "deprecated" "$_STDERR_FILE"; then
    pass "bitlesson_agent_model: deprecation warning emitted"
else
    fail "bitlesson_agent_model: deprecation warning emitted" "warning containing 'deprecated'" "no warning"
fi

mapped_val=$(jq -r '.bitlesson_model // empty' "$_STDOUT_FILE" 2>/dev/null || true)
if [[ "$mapped_val" == "legacy-haiku" ]]; then
    pass "bitlesson_agent_model: value mapped to bitlesson_model"
else
    fail "bitlesson_agent_model: value mapped to bitlesson_model" "legacy-haiku" "$mapped_val"
fi
cleanup_run_files

# ========================================
# Test 4: bitlesson_codex_model → deprecated, maps to bitlesson_model
# ========================================

setup_test_dir
run_with_project_config '{"bitlesson_codex_model": "legacy-codex-model"}' "$TEST_DIR/dep4"

if grep -q "deprecated" "$_STDERR_FILE"; then
    pass "bitlesson_codex_model: deprecation warning emitted"
else
    fail "bitlesson_codex_model: deprecation warning emitted" "warning containing 'deprecated'" "no warning"
fi

mapped_val=$(jq -r '.bitlesson_model // empty' "$_STDOUT_FILE" 2>/dev/null || true)
if [[ "$mapped_val" == "legacy-codex-model" ]]; then
    pass "bitlesson_codex_model: value mapped to bitlesson_model"
else
    fail "bitlesson_codex_model: value mapped to bitlesson_model" "legacy-codex-model" "$mapped_val"
fi
cleanup_run_files

# ========================================
# Test 5: bitlesson_agent_model takes priority over bitlesson_codex_model
# ========================================

setup_test_dir
run_with_project_config \
    '{"bitlesson_agent_model": "agent-wins", "bitlesson_codex_model": "codex-loses"}' \
    "$TEST_DIR/dep5"

mapped_val=$(jq -r '.bitlesson_model // empty' "$_STDOUT_FILE" 2>/dev/null || true)
if [[ "$mapped_val" == "agent-wins" ]]; then
    pass "bitlesson legacy priority: bitlesson_agent_model takes priority over bitlesson_codex_model"
else
    fail "bitlesson legacy priority: bitlesson_agent_model takes priority over bitlesson_codex_model" \
        "agent-wins" "$mapped_val"
fi
cleanup_run_files

# ========================================
# Test 6: New key explicitly set in project config → deprecated key not applied
# ========================================

setup_test_dir
run_with_project_config \
    '{"coding_worker": "new-key-value", "gen_plan_coding_worker": "old-key-value"}' \
    "$TEST_DIR/dep6"

mapped_val=$(jq -r '.coding_worker // empty' "$_STDOUT_FILE" 2>/dev/null || true)
if [[ "$mapped_val" == "new-key-value" ]]; then
    pass "new key explicitly set: deprecated key does not override existing new key in user/project config"
else
    fail "new key explicitly set: deprecated key does not override existing new key in user/project config" \
        "new-key-value" "$mapped_val"
fi
cleanup_run_files

print_test_summary "Config Deprecated Keys Tests"
