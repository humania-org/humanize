#!/usr/bin/env bash
set -euo pipefail

_config_loader_warn() {
    echo "Warning: $*" >&2
}

_config_loader_fatal() {
    echo "Error: $*" >&2
    return 1
}

_config_loader_require_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        _config_loader_fatal "jq is required. Install it (for example: 'brew install jq' or 'sudo apt-get install jq')."
        return 1
    fi
}

_config_loader_prepare_layer() {
    local config_path="${1:-}"
    local config_label="${2:-config}"
    local output_file="${3:-}"
    local required="${4:-false}"

    if [[ -z "$output_file" ]]; then
        _config_loader_fatal "_config_loader_prepare_layer requires an output file path."
        exit 1
    fi

    if [[ -z "$config_path" ]]; then
        printf '{}' > "$output_file"
        return 0
    fi

    if [[ ! -f "$config_path" ]]; then
        if [[ "$required" == "true" ]]; then
            _config_loader_fatal "Missing required ${config_label}: $config_path"
            # exit instead of return: this function is only called inside the (...)
            # subshell in load_merged_config; set -e does not reliably propagate
            # through nested if-body function calls in bash.
            exit 1
        fi
        printf '{}' > "$output_file"
        return 0
    fi

    if ! jq -e 'if type == "object" then . else error("not a JSON object") end' "$config_path" > "$output_file" 2>/dev/null; then
        if [[ "$required" == "true" ]]; then
            _config_loader_fatal "Malformed required ${config_label} (must be a JSON object): $config_path"
            exit 1
        fi
        _config_loader_warn "Ignoring malformed ${config_label} (must be a JSON object): $config_path"
        printf '{}' > "$output_file"
        return 0
    fi
}

_config_loader_extract_string() {
    local config_json="${1:-}"
    local key="${2:-}"
    local shell_escaped=""
    local decoded=""

    if [[ -z "$key" ]]; then
        return 1
    fi

    shell_escaped="$(
        printf '%s' "$config_json" | jq -r --arg key "$key" '
            if has($key) and .[$key] != null then
                (.[$key] | tostring | @sh)
            else
                ""
            end
        '
    )"

    if [[ -z "$shell_escaped" ]]; then
        return 0
    fi

    # shellcheck disable=SC2086
    eval "decoded=$shell_escaped"
    printf '%s' "$decoded"
}

# _config_loader_apply_legacy_keys <merged_json> [user_project_overlay]
#
# Migrate deprecated config keys to their new names.
# Checks the user_project_overlay (user+project layers without defaults) to determine
# whether the user explicitly set the NEW key. Only when the user did NOT set the new
# key (but DID set the old deprecated one) is the value migrated into merged_json.
# This prevents a deprecated key in user config from being silently ignored when the
# default_config.json already provides a value for the new key.
_config_loader_apply_legacy_keys() {
    local merged_json="${1:-}"
    # Two-step default: "${2:-{}}" is parsed by bash as "${2:-{}" + "}", which
    # appends a literal "}" to the value of $2 when $2 is non-empty (e.g. "{}").
    local user_project_overlay="${2:-}"
    [[ -z "$user_project_overlay" ]] && user_project_overlay="{}"
    local coding_worker=""
    local legacy_coding_worker=""
    local analyzing_worker=""
    local legacy_analyzing_worker=""
    local reviewer=""
    local legacy_reviewer=""
    local loop_reviewer_effort=""
    local legacy_codex_review_effort=""
    local bitlesson_model=""
    local bitlesson_agent_model=""
    local bitlesson_codex_model=""
    local selected_bitlesson_legacy=""

    # Check the user+project overlay (not merged, which includes defaults) so that
    # a default value for the new key does not suppress legacy key migration.
    coding_worker="$(_config_loader_extract_string "$user_project_overlay" "coding_worker")"
    legacy_coding_worker="$(_config_loader_extract_string "$user_project_overlay" "gen_plan_coding_worker")"
    if [[ -z "$coding_worker" && -n "$legacy_coding_worker" ]]; then
        _config_loader_warn "Config key 'gen_plan_coding_worker' is deprecated. Use 'coding_worker'."
        merged_json="$(printf '%s' "$merged_json" | jq --arg value "$legacy_coding_worker" '.coding_worker = $value')"
    fi

    analyzing_worker="$(_config_loader_extract_string "$user_project_overlay" "analyzing_worker")"
    legacy_analyzing_worker="$(_config_loader_extract_string "$user_project_overlay" "gen_plan_analyzing_worker")"
    if [[ -z "$analyzing_worker" && -n "$legacy_analyzing_worker" ]]; then
        _config_loader_warn "Config key 'gen_plan_analyzing_worker' is deprecated. Use 'analyzing_worker'."
        merged_json="$(printf '%s' "$merged_json" | jq --arg value "$legacy_analyzing_worker" '.analyzing_worker = $value')"
    fi

    reviewer="$(_config_loader_extract_string "$user_project_overlay" "reviewer")"
    legacy_reviewer="$(_config_loader_extract_string "$user_project_overlay" "gen_plan_reviewer")"
    if [[ -z "$reviewer" && -n "$legacy_reviewer" ]]; then
        _config_loader_warn "Config key 'gen_plan_reviewer' is deprecated. Use 'reviewer'."
        merged_json="$(printf '%s' "$merged_json" | jq --arg value "$legacy_reviewer" '.reviewer = $value')"
    fi

    loop_reviewer_effort="$(_config_loader_extract_string "$user_project_overlay" "loop_reviewer_effort")"
    legacy_codex_review_effort="$(_config_loader_extract_string "$user_project_overlay" "codex_review_effort")"
    if [[ -z "$loop_reviewer_effort" && -n "$legacy_codex_review_effort" ]]; then
        _config_loader_warn "Config key 'codex_review_effort' is deprecated. Use 'loop_reviewer_effort'."
        merged_json="$(printf '%s' "$merged_json" | jq --arg value "$legacy_codex_review_effort" '.loop_reviewer_effort = $value')"
    fi

    bitlesson_model="$(_config_loader_extract_string "$user_project_overlay" "bitlesson_model")"
    bitlesson_agent_model="$(_config_loader_extract_string "$user_project_overlay" "bitlesson_agent_model")"
    bitlesson_codex_model="$(_config_loader_extract_string "$user_project_overlay" "bitlesson_codex_model")"

    if [[ -z "$bitlesson_model" ]]; then
        if [[ -n "$bitlesson_agent_model" ]]; then
            selected_bitlesson_legacy="$bitlesson_agent_model"
            _config_loader_warn "Config key 'bitlesson_agent_model' is deprecated. Use 'bitlesson_model'."
        elif [[ -n "$bitlesson_codex_model" ]]; then
            selected_bitlesson_legacy="$bitlesson_codex_model"
            _config_loader_warn "Config key 'bitlesson_codex_model' is deprecated. Use 'bitlesson_model'."
        fi

        if [[ -n "$selected_bitlesson_legacy" ]]; then
            merged_json="$(printf '%s' "$merged_json" | jq --arg value "$selected_bitlesson_legacy" '.bitlesson_model = $value')"
        fi
    fi

    printf '%s\n' "$merged_json"
}

load_merged_config() {
    local plugin_root="${1:-}"
    local project_root="${2:-}"
    local default_config_path=""
    local user_config_path=""
    local project_config_path=""

    if [[ -z "$plugin_root" || -z "$project_root" ]]; then
        _config_loader_fatal "Usage: load_merged_config <plugin_root> <project_root>"
        return 1
    fi

    _config_loader_require_jq

    default_config_path="$plugin_root/config/default_config.json"
    if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
        user_config_path="$XDG_CONFIG_HOME/humanize/config.json"
    else
        user_config_path="${HOME:-}/.config/humanize/config.json"
    fi

    if [[ -n "${HUMANIZE_CONFIG:-}" ]]; then
        project_config_path="$HUMANIZE_CONFIG"
    else
        project_config_path="$project_root/.humanize/config.json"
    fi

    (
        set -euo pipefail

        local tmp_dir=""
        local empty_layer_file=""
        local default_layer_file=""
        local user_layer_file=""
        local project_layer_file=""
        local merged_json=""

        tmp_dir="$(mktemp -d)"
        trap 'rm -rf "${tmp_dir:-}"' EXIT

        empty_layer_file="$tmp_dir/empty.json"
        default_layer_file="$tmp_dir/default.json"
        user_layer_file="$tmp_dir/user.json"
        project_layer_file="$tmp_dir/project.json"

        printf '{}' > "$empty_layer_file"
        _config_loader_prepare_layer "$default_config_path" "default config" "$default_layer_file" "true"
        _config_loader_prepare_layer "$user_config_path" "user config" "$user_layer_file" "false"
        _config_loader_prepare_layer "$project_config_path" "project config" "$project_layer_file" "false"

        merged_json="$(
            jq -n \
                --slurpfile layer0 "$empty_layer_file" \
                --slurpfile layer1 "$default_layer_file" \
                --slurpfile layer2 "$user_layer_file" \
                --slurpfile layer3 "$project_layer_file" '
                def strip_nulls:
                    if type == "object" then
                        with_entries(select(.value != null) | .value |= strip_nulls)
                    elif type == "array" then
                        map(select(. != null) | strip_nulls)
                    else
                        .
                    end;

                ($layer0[0] // {} | strip_nulls)
                * ($layer1[0] // {} | strip_nulls)
                * ($layer2[0] // {} | strip_nulls)
                * ($layer3[0] // {} | strip_nulls)
            '
        )"

        # Compute the user+project overlay (without defaults) so that legacy key
        # migration can distinguish "user explicitly set new key" from "new key came
        # from default_config.json".
        local user_project_overlay=""
        user_project_overlay="$(
            jq -n \
                --slurpfile layer2 "$user_layer_file" \
                --slurpfile layer3 "$project_layer_file" '
                def strip_nulls:
                    if type == "object" then
                        with_entries(select(.value != null) | .value |= strip_nulls)
                    elif type == "array" then
                        map(select(. != null) | strip_nulls)
                    else
                        .
                    end;

                ($layer2[0] // {} | strip_nulls)
                * ($layer3[0] // {} | strip_nulls)
            '
        )"

        _config_loader_apply_legacy_keys "$merged_json" "$user_project_overlay"
    )
}

get_config_value() {
    local merged_config_json="${1:-}"
    local key="${2:-}"

    if [[ -z "$key" ]]; then
        _config_loader_fatal "Usage: get_config_value <merged_config_json> <key>"
        return 1
    fi

    printf '%s' "$merged_config_json" | jq -r --arg key "$key" '
        if has($key) then
            .[$key]
            | if type == "string" then .
              elif . == null then empty
              else tostring
              end
        else
            empty
        end
    '
}
