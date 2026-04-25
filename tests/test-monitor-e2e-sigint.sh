#!/usr/bin/env bash
# Monitor e2e SIGINT tests (parallel split 2/3)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-monitor-e2e-real.sh"

echo "========================================"
echo "Monitor E2E SIGINT Tests"
echo "========================================"
echo ""

monitor_test_bash_sigint
monitor_test_zsh_sigint

echo ""
echo "========================================"
echo "Test Summary"
echo "========================================"
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
