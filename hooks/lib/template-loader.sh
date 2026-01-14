#!/bin/bash
#
# Template loading functions for RLCR loop hooks
#
# This library provides functions to load and render prompt templates.
# Templates use {{VARIABLE_NAME}} syntax for placeholders.
#

# Get the template directory path
# This is relative to the hooks/lib directory (goes up 2 levels to plugin root)
get_template_dir() {
    local script_dir="$1"
    local plugin_root
    plugin_root="$(cd "$script_dir/../.." && pwd)"
    echo "$plugin_root/prompt-template"
}

# Load a template file and output its contents
# Usage: load_template "$TEMPLATE_DIR" "codex/full-alignment-review.md"
# Returns empty string if file not found
load_template() {
    local template_dir="$1"
    local template_name="$2"
    local template_path="$template_dir/$template_name"

    if [[ -f "$template_path" ]]; then
        cat "$template_path"
    else
        echo "" >&2
        echo "Warning: Template not found: $template_path" >&2
        echo ""
    fi
}

# Render a template with multiple variable substitutions
# Usage: render_template "$template_content" "VAR1=value1" "VAR2=value2" ...
# Variables should be passed as VAR=value pairs
render_template() {
    local content="$1"
    shift

    # Process each variable assignment
    for var_assignment in "$@"; do
        local var_name="${var_assignment%%=*}"
        local var_value="${var_assignment#*=}"

        # Use awk for safe substitution (handles special chars and multilines)
        # Use ENVIRON to avoid -v interpreting backslash escape sequences
        # Use index/substr instead of gsub to avoid replacement string special chars (& and \)
        content=$(TEMPLATE_VAR="{{$var_name}}" TEMPLATE_VAL="$var_value" \
            awk 'BEGIN {
                var = ENVIRON["TEMPLATE_VAR"]
                val = ENVIRON["TEMPLATE_VAL"]
                varlen = length(var)
            }
            {
                line = $0
                result = ""
                while ((idx = index(line, var)) > 0) {
                    result = result substr(line, 1, idx - 1) val
                    line = substr(line, idx + varlen)
                }
                print result line
            }' <<< "$content")
    done

    echo "$content"
}

# Load and render a template in one step
# Usage: load_and_render "$TEMPLATE_DIR" "block/git-not-clean.md" "GIT_ISSUES=uncommitted changes"
load_and_render() {
    local template_dir="$1"
    local template_name="$2"
    shift 2

    local content
    content=$(load_template "$template_dir" "$template_name")

    if [[ -n "$content" ]]; then
        render_template "$content" "$@"
    fi
}

# Append content from another template file
# Usage: append_template "$base_content" "$TEMPLATE_DIR" "claude/post-alignment.md"
append_template() {
    local base_content="$1"
    local template_dir="$2"
    local template_name="$3"

    local additional_content
    additional_content=$(load_template "$template_dir" "$template_name")

    echo "$base_content"
    echo "$additional_content"
}

# ========================================
# Safe versions with fallback messages
# ========================================

# Load and render with a fallback message if template fails
# Usage: load_and_render_safe "$TEMPLATE_DIR" "block/message.md" "fallback message" "VAR=value" ...
# Returns fallback message if template is missing or empty
load_and_render_safe() {
    local template_dir="$1"
    local template_name="$2"
    local fallback_msg="$3"
    shift 3

    local content
    content=$(load_template "$template_dir" "$template_name" 2>/dev/null)

    if [[ -z "$content" ]]; then
        # Template missing - use fallback with variable substitution
        if [[ $# -gt 0 ]]; then
            render_template "$fallback_msg" "$@"
        else
            echo "$fallback_msg"
        fi
        return
    fi

    local result
    result=$(render_template "$content" "$@")

    if [[ -z "$result" ]]; then
        # Rendering produced empty result - use fallback
        if [[ $# -gt 0 ]]; then
            render_template "$fallback_msg" "$@"
        else
            echo "$fallback_msg"
        fi
        return
    fi

    echo "$result"
}

# Validate that TEMPLATE_DIR exists and contains templates
# Usage: validate_template_dir "$TEMPLATE_DIR"
# Returns 0 if valid, 1 if not
validate_template_dir() {
    local template_dir="$1"

    if [[ ! -d "$template_dir" ]]; then
        echo "ERROR: Template directory not found: $template_dir" >&2
        return 1
    fi

    if [[ ! -d "$template_dir/block" ]] || [[ ! -d "$template_dir/codex" ]] || [[ ! -d "$template_dir/claude" ]]; then
        echo "ERROR: Template directory missing subdirectories: $template_dir" >&2
        return 1
    fi

    return 0
}
