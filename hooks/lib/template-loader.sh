#!/bin/bash
#
# Template loading functions for RLCR loop hooks
#
# This library provides functions to load and render prompt templates.
#
# Template Variable Syntax
# ========================
# Templates use {{VARIABLE_NAME}} syntax for placeholders.
# - Variable names: uppercase letters, numbers, underscores only
# - Example: {{PLAN_FILE}}, {{CURRENT_ROUND}}, {{GOAL_TRACKER_FILE}}
# - Single-pass substitution: {{VAR}} in a value will NOT be expanded
# - Missing variables: placeholder is kept as-is (e.g., {{UNDEFINED}})
#
# Available functions:
# - get_template_dir: Get path to template directory
# - load_template: Load a template file by name
# - render_template: Replace {{VAR}} placeholders with values
# - load_and_render: Load and render in one call
# - load_and_render_safe: Same as above but with fallback for missing templates
# - validate_template_dir: Check if template directory is valid
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

# Render a template with multiple variable substitutions (single-pass)
# Usage: render_template "$template_content" "VAR1=value1" "VAR2=value2" ...
# Variables should be passed as VAR=value pairs
#
# IMPORTANT: This uses a single-pass approach to prevent placeholder injection.
# If a variable value contains {{OTHER_VAR}}, it will NOT be replaced.
# This prevents content like REVIEW_CONTENT from having its {{...}} patterns
# accidentally substituted, which could corrupt prompts.
render_template() {
    local content="$1"
    shift

    # Build environment variables for all substitutions
    # Using TMPL_VAR_ prefix to avoid conflicts
    local -a env_vars=()
    for var_assignment in "$@"; do
        local var_name="${var_assignment%%=*}"
        local var_value="${var_assignment#*=}"
        env_vars+=("TMPL_VAR_${var_name}=${var_value}")
    done

    # Single-pass replacement using awk
    # Scans for {{VAR}} patterns and replaces them with values from environment
    # Replaced content goes directly to output without re-scanning
    content=$(env "${env_vars[@]}" awk '
    BEGIN {
        # Build lookup table from environment variables with TMPL_VAR_ prefix
        for (name in ENVIRON) {
            if (substr(name, 1, 9) == "TMPL_VAR_") {
                var_name = substr(name, 10)  # Remove prefix
                vars[var_name] = ENVIRON[name]
            }
        }
    }
    {
        line = $0
        result = ""

        # Process line character by character, looking for {{ patterns
        while (length(line) > 0) {
            # Find next {{
            open_idx = index(line, "{{")
            if (open_idx == 0) {
                # No more placeholders, append rest of line
                result = result line
                break
            }

            # Append everything before {{
            result = result substr(line, 1, open_idx - 1)
            line = substr(line, open_idx)  # line now starts with {{

            # Find closing }}
            close_idx = index(substr(line, 3), "}}")
            if (close_idx == 0) {
                # No closing }}, treat {{ as literal
                result = result substr(line, 1, 2)
                line = substr(line, 3)
                continue
            }

            # Extract variable name (between {{ and }})
            var_name = substr(line, 3, close_idx - 1)
            placeholder = "{{" var_name "}}"

            # Look up in our variables table
            if (var_name in vars) {
                # Replace with value (value goes to output, not re-scanned)
                result = result vars[var_name]
            } else {
                # Keep original placeholder if not found
                result = result placeholder
            }

            # Move past the placeholder
            line = substr(line, length(placeholder) + 1)
        }

        print result
    }' <<< "$content")

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
