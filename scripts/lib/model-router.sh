#!/usr/bin/env bash
#
# model-router.sh - Shared model routing helpers
#

# Source guard: prevent double-sourcing
[[ -n "${_MODEL_ROUTER_LOADED:-}" ]] && return 0 2>/dev/null || true
_MODEL_ROUTER_LOADED=1

detect_provider() {
    local model_name="${1:-}"

    if [[ -z "$model_name" ]]; then
        echo "Error: Model name must be non-empty." >&2
        return 1
    fi

    if [[ "$model_name" == gpt-* ]] || [[ "$model_name" == o[0-9]* ]]; then
        echo "codex"
        return 0
    fi

    if printf '%s\n' "$model_name" | grep -qiE '(^claude-)|(haiku|sonnet|opus)'; then
        echo "claude"
        return 0
    fi

    echo "Error: Unknown model name '$model_name'. Expected gpt-*/o[N]-* (Codex) or claude-*/haiku/sonnet/opus (Claude)." >&2
    return 1
}

check_provider_dependency() {
    local provider="${1:-}"
    local binary=""

    case "$provider" in
        codex)
            binary="codex"
            ;;
        claude)
            binary="claude"
            ;;
        *)
            echo "Error: Unknown provider '$provider'. Expected 'codex' or 'claude'." >&2
            return 1
            ;;
    esac

    if command -v "$binary" >/dev/null 2>&1; then
        return 0
    fi

    echo "Error: Required binary '$binary' was not found in PATH for provider '$provider'." >&2
    if [[ "$provider" == "codex" ]]; then
        echo "Install: https://github.com/openai/codex" >&2
    else
        echo "Install Claude Code CLI" >&2
    fi
    return 1
}

map_effort() {
    local effort="${1:-}"
    local target_provider="${2:-}"

    case "$target_provider" in
        codex|claude)
            ;;
        *)
            echo "Error: Unknown target provider '$target_provider'. Expected 'codex' or 'claude'." >&2
            return 1
            ;;
    esac

    case "$effort" in
        xhigh|high|medium|low)
            ;;
        *)
            echo "Error: Unknown effort '$effort'. Expected one of: xhigh, high, medium, low." >&2
            return 1
            ;;
    esac

    if [[ "$target_provider" == "claude" ]] && [[ "$effort" == "xhigh" ]]; then
        echo "Info: Mapping effort 'xhigh' to 'high' for provider 'claude'." >&2
        echo "high"
        return 0
    fi

    echo "$effort"
}
