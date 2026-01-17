#!/bin/bash
#
# Run all test suites for the Humanize plugin
#
# Usage: ./tests/run-all-tests.sh
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

echo "========================================"
echo "Running All Humanize Plugin Tests"
echo "========================================"
echo ""

TOTAL_PASSED=0
TOTAL_FAILED=0
FAILED_SUITES=()

# Test suites to run (in order)
TEST_SUITES=(
    "test-template-loader.sh"
    "test-bash-validator-patterns.sh"
    "test-todo-checker.sh"
    "test-plan-file-validation.sh"
    "test-template-references.sh"
    "test-state-exit-naming.sh"
    "test-templates-comprehensive.sh"
    "test-plan-file-hooks.sh"
    "test-error-scenarios.sh"
    "test-ansi-parsing.sh"
    "test-allowlist-validators.sh"
    "test-finalize-phase.sh"
    "test-cancel-signal-file.sh"
    "test-humanize-escape.sh"
    "test-zsh-monitor-safety.sh"
    "test-monitor-runtime.sh"
    "test-monitor-e2e-real.sh"
)

# Tests that must be run with zsh (not bash)
ZSH_TESTS=(
    "test-zsh-monitor-safety.sh"
)

for suite in "${TEST_SUITES[@]}"; do
    suite_path="$SCRIPT_DIR/$suite"

    if [[ ! -f "$suite_path" ]]; then
        echo -e "${YELLOW}SKIP${NC}: $suite (not found)"
        continue
    fi

    # Check if this test needs to run under zsh
    needs_zsh=false
    for zsh_test in "${ZSH_TESTS[@]}"; do
        if [[ "$suite" == "$zsh_test" ]]; then
            needs_zsh=true
            break
        fi
    done

    if [[ "$needs_zsh" == "true" ]]; then
        echo -e "${BOLD}Running: $suite (zsh)${NC}"
    else
        echo -e "${BOLD}Running: $suite${NC}"
    fi
    echo "----------------------------------------"

    # Run the test suite and capture output
    set +e
    if [[ "$needs_zsh" == "true" ]]; then
        # Run zsh tests with zsh interpreter
        if command -v zsh &>/dev/null; then
            output=$(zsh "$suite_path" 2>&1)
            exit_code=$?
        else
            echo -e "${YELLOW}SKIP${NC}: $suite (zsh not available)"
            continue
        fi
    else
        output=$("$suite_path" 2>&1)
        exit_code=$?
    fi
    set -e

    # Strip ANSI escape codes and extract pass/fail counts
    esc=$'\033'
    output_stripped=$(echo "$output" | sed "s/${esc}\\[[0-9;]*m//g")
    passed=$(echo "$output_stripped" | grep -oE 'Passed:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' | tail -1 || echo "0")
    failed=$(echo "$output_stripped" | grep -oE 'Failed:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' | tail -1 || echo "0")

    TOTAL_PASSED=$((TOTAL_PASSED + passed))
    TOTAL_FAILED=$((TOTAL_FAILED + failed))

    if [[ $exit_code -ne 0 ]] || [[ "$failed" -gt 0 ]]; then
        echo -e "${RED}FAILED${NC}: $suite (exit code: $exit_code, failed: $failed)"
        FAILED_SUITES+=("$suite")
        # Show the output for failed suites
        echo "$output" | tail -30
    else
        echo -e "${GREEN}PASSED${NC}: $suite ($passed tests)"
    fi
    echo ""
done

echo "========================================"
echo "Test Summary"
echo "========================================"
echo -e "Total Passed: ${GREEN}$TOTAL_PASSED${NC}"
echo -e "Total Failed: ${RED}$TOTAL_FAILED${NC}"
echo ""

if [[ ${#FAILED_SUITES[@]} -gt 0 ]]; then
    echo -e "${RED}Failed Test Suites:${NC}"
    for suite in "${FAILED_SUITES[@]}"; do
        echo "  - $suite"
    done
    echo ""
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
