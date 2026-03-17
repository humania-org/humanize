#!/usr/bin/env bash
#
# PR Loop API fetch/state tests (parallel split 1/2)
#
# Runs Tests 1-11: PR Loop State Handling + fetch-pr-comments +
# Bot Response Parsing + JSON Edge Cases
#
# Sources the shared test library from test-pr-loop-api-robustness.sh
# and invokes the run_fetch_tests group function.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-pr-loop-api-robustness.sh"

run_fetch_tests
print_test_summary "PR Loop API Fetch Tests"
exit $?
