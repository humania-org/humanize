#!/usr/bin/env bash
#
# PR Loop API poll/stop-hook tests (parallel split 2/2)
#
# Runs Tests 12-19: PR Loop Stop Hook + poll-pr-reviews
#
# Sources the shared test library from test-pr-loop-api-robustness.sh
# and invokes the run_poll_tests group function.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-pr-loop-api-robustness.sh"

run_poll_tests
print_test_summary "PR Loop API Poll Tests"
exit $?
