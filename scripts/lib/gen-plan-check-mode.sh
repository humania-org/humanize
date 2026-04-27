#!/usr/bin/env bash
# gen-plan-check-mode.sh
# Resolves the effective check-mode flag for gen-plan from CLI flags and merged config.
#
# Usage (sourced):
#   source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/gen-plan-check-mode.sh"
#   _gen_plan_resolve_check_mode "$CHECK_FLAG" "$NO_CHECK_FLAG" "$CONFIG_GEN_PLAN_CHECK_RAW"
#   echo "Effective check mode: $EFFECTIVE_CHECK_MODE"
#
# Resolution priority (highest to lowest):
#   1. --no-check flag  -> EFFECTIVE_CHECK_MODE=false
#   2. --check flag     -> EFFECTIVE_CHECK_MODE=true
#   3. Merged config gen_plan_check value (true/false)
#   4. Default          -> EFFECTIVE_CHECK_MODE=false
#
# Invalid config values warn and fall back to disabled unless --check is passed.

# Source guard
[[ -n "${_GEN_PLAN_CHECK_MODE_LOADED:-}" ]] && return 0 2>/dev/null || true
_GEN_PLAN_CHECK_MODE_LOADED=1

set -euo pipefail

# Resolve effective check mode from CLI flags and merged config.
# Inputs:
#   $1 - CHECK_FLAG     ("true" or "false")
#   $2 - NO_CHECK_FLAG  ("true" or "false")
#   $3 - CONFIG_GEN_PLAN_CHECK_RAW (raw config value string, may be empty)
# Outputs:
#   Sets global EFFECTIVE_CHECK_MODE to "true" or "false"
#   Prints warnings to stderr when appropriate
_gen_plan_resolve_check_mode() {
    local check_flag="${1:-false}"
    local no_check_flag="${2:-false}"
    local config_raw="${3:-}"

    # Priority 1: --no-check always wins
    if [[ "$no_check_flag" == "true" ]]; then
        EFFECTIVE_CHECK_MODE="false"
        return 0
    fi

    # Priority 2: --check flag
    if [[ "$check_flag" == "true" ]]; then
        EFFECTIVE_CHECK_MODE="true"
        return 0
    fi

    # Priority 3: merged config value
    local config_normalized=""
    if [[ -n "$config_raw" ]]; then
        config_normalized="$(printf '%s' "$config_raw" | tr '[:upper:]' '[:lower:]')"
    fi

    if [[ "$config_normalized" == "true" ]]; then
        EFFECTIVE_CHECK_MODE="true"
        return 0
    fi

    if [[ "$config_normalized" == "false" || -z "$config_raw" ]]; then
        EFFECTIVE_CHECK_MODE="false"
        return 0
    fi

    # Invalid config value: warn and fall back to disabled
    # (config_raw is non-empty and not true/false)
    echo "Warning: unsupported gen_plan_check \"${config_raw}\". Expected true or false. Check mode is disabled unless --check is passed." >&2
    EFFECTIVE_CHECK_MODE="false"
    return 0
}
