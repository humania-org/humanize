#!/bin/bash
#
# PR Loop Stop Hook Tests Runner (parallel split 3/3)
#
# Runs only stop hook integration tests from the PR loop test suite.
# This is the slowest module due to timeout-based bot polling tests.
# See test-pr-loop.sh for the combined runner.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test-helpers.sh"
source "$SCRIPT_DIR/test-pr-loop-lib.sh"

if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    skip "PR Loop Stop Hook Tests" "Skipped in GitHub Actions"
    print_test_summary "PR Loop Stop Hook Tests"
    exit 0
fi

init_pr_loop_test_env

source "$SCRIPT_DIR/test-pr-loop-stophook.sh"

run_stophook_tests

print_test_summary "PR Loop Stop Hook Tests"
exit $?
