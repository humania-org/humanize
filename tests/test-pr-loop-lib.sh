#!/bin/bash
#
# Common library for PR loop tests
#
# Provides shared setup, helpers, and mock functions used by all test modules.
#
# Usage: source test-pr-loop-lib.sh
#

# Determine script location
if [[ -z "${TEST_PR_LOOP_LIB_LOADED:-}" ]]; then
    TEST_PR_LOOP_LIB_LOADED=1

    # Get directories if not already set
    SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

    # Source test helpers if not already sourced
    if ! declare -f setup_test_dir &>/dev/null; then
        source "$SCRIPT_DIR/test-helpers.sh"
    fi

    # ========================================
    # Mock Creation Functions
    # ========================================

    # Create mock scripts for gh CLI
    create_mock_gh() {
        local mock_dir="$1"
        mkdir -p "$mock_dir"

        cat > "$mock_dir/gh" << 'MOCK_GH'
#!/bin/bash
# Mock gh CLI for testing

case "$1" in
    auth)
        if [[ "$2" == "status" ]]; then
            echo "Logged in to github.com"
            exit 0
        fi
        ;;
    repo)
        if [[ "$2" == "view" ]]; then
            if [[ "$3" == "--json" && "$4" == "owner" ]]; then
                echo '{"login": "testowner"}'
            elif [[ "$3" == "--json" && "$4" == "name" ]]; then
                echo '{"name": "testrepo"}'
            fi
            exit 0
        fi
        ;;
    pr)
        if [[ "$2" == "view" ]]; then
            if [[ "$*" == *"commits"* ]] && [[ "$*" == *"--jq"* ]]; then
                # Return just the timestamp when --jq is used
                echo "2026-01-18T12:00:00Z"
                exit 0
            elif [[ "$*" == *"commits"* ]]; then
                echo '{"commits":[{"committedDate":"2026-01-18T12:00:00Z"}]}'
                exit 0
            elif [[ "$3" == "--json" && "$4" == "number" ]]; then
                echo '{"number": 123}'
                exit 0
            elif [[ "$3" == "--json" && "$4" == "state" ]] || [[ "$*" == *"state"* ]]; then
                echo '{"state": "OPEN"}'
                exit 0
            fi
            exit 0
        fi
        ;;
    api)
        # Handle user endpoint
        if [[ "$2" == "user" ]]; then
            echo "testuser"
            exit 0
        fi
        # Return empty arrays for comment/review fetching
        echo "[]"
        exit 0
        ;;
esac

echo "Mock gh: unhandled command: $*" >&2
exit 1
MOCK_GH
        chmod +x "$mock_dir/gh"
    }

    # Create mock codex command
    create_mock_codex() {
        local mock_dir="$1"

        cat > "$mock_dir/codex" << 'MOCK_CODEX'
#!/bin/bash
# Mock codex CLI for testing
echo "Mock codex output"
exit 0
MOCK_CODEX
        chmod +x "$mock_dir/codex"
    }

    # ========================================
    # Test Environment Setup
    # ========================================

    # Initialize test environment (call once at start of test run)
    init_pr_loop_test_env() {
        setup_test_dir

        # Create mock scripts directory and wire it into PATH
        MOCK_BIN_DIR="$TEST_DIR/mock_bin"
        mkdir -p "$MOCK_BIN_DIR"
        export PATH="$MOCK_BIN_DIR:$PATH"

        # Initialize mock gh and codex in the PATH
        create_mock_gh "$MOCK_BIN_DIR"
        create_mock_codex "$MOCK_BIN_DIR"

        export MOCK_BIN_DIR
    }

    # ========================================
    # Test Result Summary
    # ========================================

    # Print test summary and exit with appropriate code
    print_test_summary() {
        echo ""
        echo "========================================"
        echo "PR Loop Tests"
        echo "========================================"
        echo -e "Passed: \033[0;32m$TESTS_PASSED\033[0m"
        echo -e "Failed: \033[0;31m$TESTS_FAILED\033[0m"
        echo ""

        if [[ $TESTS_FAILED -gt 0 ]]; then
            echo -e "\033[0;31mSome tests failed!\033[0m"
            return 1
        else
            echo -e "\033[0;32mAll tests passed!\033[0m"
            return 0
        fi
    }
fi
