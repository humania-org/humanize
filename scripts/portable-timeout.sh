#!/usr/bin/env bash
#
# Portable timeout wrapper for macOS/Linux compatibility
# Usage: source portable-timeout.sh; run_with_timeout <seconds> <command> [args...]
#
# Priority: gtimeout (Homebrew) > timeout (GNU) > python3 > no timeout
#

# Detect available timeout implementation
detect_timeout_impl() {
    if command -v gtimeout &>/dev/null; then
        echo "gtimeout"
        return
    fi
    if command -v timeout &>/dev/null; then
        # Require recognizable GNU coreutils output to avoid matching shims
        # (shims typically output nothing for --version and lack "timeout" in output)
        if timeout --version 2>&1 | grep -qiE 'GNU|coreutils|timeout [0-9]'; then
            echo "timeout"
            return
        fi
    fi
    if command -v python3 &>/dev/null; then
        echo "python3"
        return
    fi
    if command -v python &>/dev/null; then
        echo "python"
        return
    fi
    echo "none"
}

TIMEOUT_IMPL=$(detect_timeout_impl)

# Run command with timeout
# Args: timeout_seconds command [args...]
run_with_timeout() {
    local timeout_secs="$1"
    shift
    local cmd=("$@")

    case "$TIMEOUT_IMPL" in
        gtimeout)
            gtimeout "$timeout_secs" "${cmd[@]}"
            return $?
            ;;
        timeout)
            timeout "$timeout_secs" "${cmd[@]}"
            return $?
            ;;
        python3|python)
            # Use Python's subprocess with timeout
            "$TIMEOUT_IMPL" -c "
import subprocess
import sys

try:
    result = subprocess.run(sys.argv[1:], timeout=$timeout_secs)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)  # Match GNU timeout exit code
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
" "${cmd[@]}"
            return $?
            ;;
        none)
            # No timeout available - run without timeout
            echo "Warning: No timeout implementation available. Running without timeout." >&2
            "${cmd[@]}"
            return $?
            ;;
    esac
}

# Make TIMEOUT_IMPL available to sourcing scripts
# Note: export -f is bash-specific, but not needed since the function
# is used directly in the sourcing script, not in child processes
export TIMEOUT_IMPL
