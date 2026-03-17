#!/usr/bin/env bash
#
# PR Loop Hook Tests Runner (parallel split 2/3)
#
# Runs only hook functionality tests from the PR loop test suite.
# See test-pr-loop.sh for the combined runner.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test-helpers.sh"
source "$SCRIPT_DIR/test-pr-loop-lib.sh"

init_pr_loop_test_env

source "$SCRIPT_DIR/test-pr-loop-hooks.sh"

run_hook_tests

print_test_summary "PR Loop Hook Tests"
exit $?
