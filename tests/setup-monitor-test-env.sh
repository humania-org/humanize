#!/bin/bash
#
# Helper script to set up monitor test environment
# This script creates the necessary directory structure and state files
# for testing the monitor pr command.
#
# Usage: ./setup-monitor-test-env.sh <test_dir> <test_name>
#

set -euo pipefail

TEST_DIR="${1:-}"
TEST_NAME="${2:-default}"

if [[ -z "$TEST_DIR" ]]; then
    echo "Usage: $0 <test_dir> <test_name>" >&2
    exit 1
fi

case "$TEST_NAME" in
    yaml_list)
        # Test: active_bots with YAML list format
        TIMESTAMP="2026-01-18_16-00-00"
        mkdir -p "$TEST_DIR/.humanize/pr-loop/$TIMESTAMP"
        cat > "$TEST_DIR/.humanize/pr-loop/$TIMESTAMP/state.md" << 'STATEEOF'
---
current_round: 1
max_iterations: 42
pr_number: 456
start_branch: feature-branch
configured_bots:
  - claude
  - codex
active_bots:
  - claude
  - codex
codex_model: gpt-5.2-codex
codex_effort: medium
started_at: 2026-01-18T16:00:00Z
---
STATEEOF
        ;;
    configured)
        # Test: configured_bots vs active_bots (partial approval)
        TIMESTAMP="2026-01-18_16-01-00"
        mkdir -p "$TEST_DIR/.humanize/pr-loop/$TIMESTAMP"
        cat > "$TEST_DIR/.humanize/pr-loop/$TIMESTAMP/state.md" << 'STATEEOF'
---
current_round: 2
max_iterations: 42
pr_number: 789
start_branch: test-branch
configured_bots:
  - claude
  - codex
active_bots:
  - codex
codex_model: gpt-5.2-codex
codex_effort: medium
started_at: 2026-01-18T16:00:00Z
---
STATEEOF
        ;;
    empty)
        # Test: empty active_bots (all approved)
        TIMESTAMP="2026-01-18_16-02-00"
        mkdir -p "$TEST_DIR/.humanize/pr-loop/$TIMESTAMP"
        cat > "$TEST_DIR/.humanize/pr-loop/$TIMESTAMP/state.md" << 'STATEEOF'
---
current_round: 3
max_iterations: 42
pr_number: 999
start_branch: approved-branch
configured_bots:
  - claude
  - codex
active_bots:
codex_model: gpt-5.2-codex
codex_effort: medium
started_at: 2026-01-18T16:00:00Z
---
STATEEOF
        ;;
    *)
        echo "Unknown test name: $TEST_NAME" >&2
        echo "Available: yaml_list, configured, empty" >&2
        exit 1
        ;;
esac

echo "$TEST_DIR"
