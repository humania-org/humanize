#!/usr/bin/env bash
#
# Tests for 4-layer config merge behavior in scripts/lib/config-loader.sh
#
# Validates:
# - Default-only: values come from config/default_config.json
# - Project config overrides defaults
# - User config is overridden by project config (project wins)
# - User keys not in project config are preserved (additive merge)
# - Null values in a higher layer do not override lower-layer values (strip_nulls)
# - HUMANIZE_CONFIG env var overrides the default project config path
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

CONFIG_LOADER="$PROJECT_ROOT/scripts/lib/config-loader.sh"

echo "=========================================="
echo "Config Merge Tests"
echo "=========================================="
echo ""

if [[ ! -f "$CONFIG_LOADER" ]]; then
    echo "FATAL: config-loader.sh not found at $CONFIG_LOADER" >&2
    exit 1
fi

# shellcheck source=../scripts/lib/config-loader.sh
source "$CONFIG_LOADER"

# ========================================
# Test 1: Default-only (no user/project config)
# ========================================

setup_test_dir
PROJECT_DIR="$TEST_DIR/empty-project"
mkdir -p "$PROJECT_DIR"

merged=$(XDG_CONFIG_HOME="$TEST_DIR/no-user-config" load_merged_config "$PROJECT_ROOT" "$PROJECT_DIR" 2>/dev/null)

val=$(get_config_value "$merged" "bitlesson_model")
if [[ "$val" == "haiku" ]]; then
    pass "default-only: bitlesson_model defaults to haiku"
else
    fail "default-only: bitlesson_model defaults to haiku" "haiku" "$val"
fi

val=$(get_config_value "$merged" "agent_teams")
if [[ "$val" == "false" ]]; then
    pass "default-only: agent_teams defaults to false"
else
    fail "default-only: agent_teams defaults to false" "false" "$val"
fi

val=$(get_config_value "$merged" "gen_plan_mode")
if [[ -n "$val" ]]; then
    pass "default-only: gen_plan_mode is set from defaults"
else
    fail "default-only: gen_plan_mode is set from defaults" "non-empty value" "empty"
fi

# ========================================
# Test 2: Project config overrides a default key
# ========================================

setup_test_dir
PROJECT_DIR="$TEST_DIR/project-override"
mkdir -p "$PROJECT_DIR/.humanize"
printf '{"bitlesson_model": "opus"}' > "$PROJECT_DIR/.humanize/config.json"

merged=$(XDG_CONFIG_HOME="$TEST_DIR/no-user-config2" load_merged_config "$PROJECT_ROOT" "$PROJECT_DIR" 2>/dev/null)

val=$(get_config_value "$merged" "bitlesson_model")
if [[ "$val" == "opus" ]]; then
    pass "project override: bitlesson_model overrides default"
else
    fail "project override: bitlesson_model overrides default" "opus" "$val"
fi

val=$(get_config_value "$merged" "agent_teams")
if [[ "$val" == "false" ]]; then
    pass "project override: non-overridden keys still use defaults"
else
    fail "project override: non-overridden keys still use defaults" "false" "$val"
fi

# ========================================
# Test 3: Project config wins over user config (priority order)
# ========================================

setup_test_dir
PROJECT_DIR="$TEST_DIR/layer-priority"
mkdir -p "$PROJECT_DIR/.humanize"
mkdir -p "$TEST_DIR/user-cfg/humanize"
printf '{"bitlesson_model": "user-model"}' > "$TEST_DIR/user-cfg/humanize/config.json"
printf '{"bitlesson_model": "project-model"}' > "$PROJECT_DIR/.humanize/config.json"

merged=$(XDG_CONFIG_HOME="$TEST_DIR/user-cfg" load_merged_config "$PROJECT_ROOT" "$PROJECT_DIR" 2>/dev/null)

val=$(get_config_value "$merged" "bitlesson_model")
if [[ "$val" == "project-model" ]]; then
    pass "layer priority: project config wins over user config"
else
    fail "layer priority: project config wins over user config" "project-model" "$val"
fi

# ========================================
# Test 4: User config key not present in project config is preserved
# ========================================

setup_test_dir
PROJECT_DIR="$TEST_DIR/user-preserved"
mkdir -p "$PROJECT_DIR/.humanize"
mkdir -p "$TEST_DIR/user-cfg2/humanize"
printf '{"bitlesson_model": "user-bitlesson"}' > "$TEST_DIR/user-cfg2/humanize/config.json"
printf '{"gen_plan_mode": "project-plan-mode"}' > "$PROJECT_DIR/.humanize/config.json"

merged=$(XDG_CONFIG_HOME="$TEST_DIR/user-cfg2" load_merged_config "$PROJECT_ROOT" "$PROJECT_DIR" 2>/dev/null)

val_b=$(get_config_value "$merged" "bitlesson_model")
val_g=$(get_config_value "$merged" "gen_plan_mode")
if [[ "$val_b" == "user-bitlesson" && "$val_g" == "project-plan-mode" ]]; then
    pass "layer merge: user-set key preserved when not overridden by project config"
else
    fail "layer merge: user-set key preserved when not overridden by project config" \
        "bitlesson_model=user-bitlesson, gen_plan_mode=project-plan-mode" \
        "bitlesson_model=$val_b, gen_plan_mode=$val_g"
fi

# ========================================
# Test 5: Null in project config does not override default (strip_nulls)
# ========================================

setup_test_dir
PROJECT_DIR="$TEST_DIR/null-strip"
mkdir -p "$PROJECT_DIR/.humanize"
printf '{"bitlesson_model": null}' > "$PROJECT_DIR/.humanize/config.json"

merged=$(XDG_CONFIG_HOME="$TEST_DIR/no-user-cfg3" load_merged_config "$PROJECT_ROOT" "$PROJECT_DIR" 2>/dev/null)

val=$(get_config_value "$merged" "bitlesson_model")
if [[ "$val" == "haiku" ]]; then
    pass "null strip: null in project config does not override default value"
else
    fail "null strip: null in project config does not override default value" "haiku" "$val"
fi

# ========================================
# Test 6: HUMANIZE_CONFIG env var overrides default project config path
# ========================================

setup_test_dir
PROJECT_DIR="$TEST_DIR/custom-config-path"
mkdir -p "$PROJECT_DIR/.humanize"
printf '{"bitlesson_model": "ignored-default-project"}' > "$PROJECT_DIR/.humanize/config.json"

custom_cfg="$TEST_DIR/my-custom.json"
printf '{"bitlesson_model": "from-custom-path"}' > "$custom_cfg"

merged=$(XDG_CONFIG_HOME="$TEST_DIR/no-user-cfg4" HUMANIZE_CONFIG="$custom_cfg" \
    load_merged_config "$PROJECT_ROOT" "$PROJECT_DIR" 2>/dev/null)

val=$(get_config_value "$merged" "bitlesson_model")
if [[ "$val" == "from-custom-path" ]]; then
    pass "HUMANIZE_CONFIG: custom config path via env var overrides project default"
else
    fail "HUMANIZE_CONFIG: custom config path via env var overrides project default" \
        "from-custom-path" "$val"
fi

# ========================================
# Test 7: All layers merge additively
# ========================================

setup_test_dir
PROJECT_DIR="$TEST_DIR/all-layers"
mkdir -p "$PROJECT_DIR/.humanize"
mkdir -p "$TEST_DIR/user-cfg-all/humanize"
printf '{"gen_plan_mode": "user-plan-mode"}' > "$TEST_DIR/user-cfg-all/humanize/config.json"
printf '{"agent_teams": true}' > "$PROJECT_DIR/.humanize/config.json"

merged=$(XDG_CONFIG_HOME="$TEST_DIR/user-cfg-all" load_merged_config "$PROJECT_ROOT" "$PROJECT_DIR" 2>/dev/null)

val_g=$(get_config_value "$merged" "gen_plan_mode")
val_a=$(get_config_value "$merged" "agent_teams")
val_b=$(get_config_value "$merged" "bitlesson_model")

if [[ "$val_g" == "user-plan-mode" && "$val_a" == "true" && "$val_b" == "haiku" ]]; then
    pass "all-layers: gen_plan_mode from user, agent_teams from project, bitlesson_model from default"
else
    fail "all-layers: all three layers contribute distinct keys" \
        "user-plan-mode + true + haiku" \
        "$val_g + $val_a + $val_b"
fi

print_test_summary "Config Merge Tests"
