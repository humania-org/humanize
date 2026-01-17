#!/bin/bash
#
# Manual Test Script for AC-1.1 and AC-1.3
#
# This script helps verify that:
# - AC-1.1: Deleting .humanize/ results in clean exit with user-friendly message
# - AC-1.3: Terminal state is properly restored after graceful stop
#
# Usage:
# 1. In terminal 1: cd to project root, run ./tests/manual-monitor-test.sh setup
# 2. In terminal 2: cd to project root, run: source scripts/humanize.sh && humanize monitor rlcr-loop
# 3. In terminal 1: run ./tests/manual-monitor-test.sh delete
# 4. Observe terminal 2: should see clean exit message, terminal should be restored
# 5. Clean up: run ./tests/manual-monitor-test.sh cleanup
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

case "${1:-}" in
    setup)
        echo "Setting up test directories..."
        mkdir -p .humanize/rlcr/2026-01-16_99-99-99
        echo "current_round: 1
max_iterations: 5
codex_model: test
codex_effort: high
started_at: 2026-01-16T00:00:00Z
plan_file: test-plan.md" > .humanize/rlcr/2026-01-16_99-99-99/state.md
        echo "# Goal Tracker
## IMMUTABLE SECTION
### Ultimate Goal
Test
### Acceptance Criteria
- AC-1: Test" > .humanize/rlcr/2026-01-16_99-99-99/goal-tracker.md
        echo ""
        echo "Setup complete. Test directories created:"
        echo "  .humanize/rlcr/2026-01-16_99-99-99/"
        echo ""
        echo "Next steps:"
        echo "1. In another terminal, run: source scripts/humanize.sh && humanize monitor rlcr-loop"
        echo "2. Then come back here and run: ./tests/manual-monitor-test.sh delete"
        ;;
    delete)
        echo "Deleting .humanize directory..."
        rm -rf .humanize
        echo ""
        echo "Done. Check the monitor terminal for:"
        echo "  - Clean exit message: 'Monitoring stopped: .humanize/rlcr directory no longer exists'"
        echo "  - Terminal should be restored (scroll region reset, cursor at bottom)"
        echo "  - No zsh/bash 'no matches found' errors"
        echo ""
        echo "If everything looks good, AC-1.1 and AC-1.3 are verified!"
        ;;
    cleanup)
        echo "Cleaning up..."
        rm -rf .humanize
        echo "Done."
        ;;
    *)
        echo "Usage: $0 {setup|delete|cleanup}"
        echo ""
        echo "Commands:"
        echo "  setup   - Create test .humanize directory with session"
        echo "  delete  - Delete .humanize directory (triggers graceful stop)"
        echo "  cleanup - Remove any leftover test directories"
        exit 1
        ;;
esac
