#!/usr/bin/env bash
#
# Helper script to set up monitor test environment
# This script creates the necessary directory structure and state files
# for testing the monitor command.
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
    *)
        echo "Unknown test name: $TEST_NAME" >&2
        echo "Available: (none currently)" >&2
        exit 1
        ;;
esac

echo "$TEST_DIR"
