#!/usr/bin/env bash
# Monitor e2e deletion tests (parallel split 1/3)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-monitor-e2e-real.sh"

echo "========================================"
echo "Monitor E2E Deletion Tests"
echo "========================================"
echo ""

monitor_test_bash_deletion
monitor_test_zsh_deletion

echo ""
echo "========================================"
echo "Test Summary"
echo "========================================"
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
