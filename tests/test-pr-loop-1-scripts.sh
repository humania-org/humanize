#!/usr/bin/env bash
#
# PR Loop Script Tests Runner (parallel split 1/3)
#
# Runs only script argument validation tests from the PR loop test suite.
# See test-pr-loop.sh for the combined runner.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test-helpers.sh"
source "$SCRIPT_DIR/test-pr-loop-lib.sh"

init_pr_loop_test_env

source "$SCRIPT_DIR/test-pr-loop-scripts.sh"

run_script_tests

print_test_summary "PR Loop Script Tests"
exit $?
