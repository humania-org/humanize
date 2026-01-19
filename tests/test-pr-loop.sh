#!/bin/bash
#
# Tests for PR loop feature
#
# This is the main test runner that sources and executes all test modules:
# - test-pr-loop-scripts.sh: Script argument validation tests
# - test-pr-loop-hooks.sh: Hook functionality tests
# - test-pr-loop-stophook.sh: Stop hook tests
#
# Usage: ./test-pr-loop.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source test helpers and common library
source "$SCRIPT_DIR/test-helpers.sh"
source "$SCRIPT_DIR/test-pr-loop-lib.sh"

# ========================================
# Test Environment Setup
# ========================================

init_pr_loop_test_env

# ========================================
# Source Test Modules
# ========================================

source "$SCRIPT_DIR/test-pr-loop-scripts.sh"
source "$SCRIPT_DIR/test-pr-loop-hooks.sh"
source "$SCRIPT_DIR/test-pr-loop-stophook.sh"

# ========================================
# Run All Tests
# ========================================

# Script tests (setup, cancel, fetch, poll)
run_script_tests

# Hook functionality tests
run_hook_tests

# Stop hook tests
run_stophook_tests

# ========================================
# Print Summary
# ========================================

print_test_summary
