#!/usr/bin/env bash
#
# Parity and behavior tests for viz/server/rlcr_sources.py.
#
# Covers:
#   - sanitize_project_path() matches the sed pipeline used in
#     scripts/humanize.sh for a selection of representative paths
#     (spaces, slashes, tildes, unicode, repeated special chars).
#   - enumerate_sessions() returns every seeded session directory
#     and partition_sessions() classifies active / historical / unknown
#     correctly.
#   - live_log_paths() finds only round-N-{codex|gemini}-{run|review}.log
#     in the per-session cache directory and returns them in
#     deterministic order.
#
# No network access. All fixtures live under a per-test mktemp tree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VIZ_SERVER_DIR="$PLUGIN_ROOT/viz/server"

echo "========================================"
echo "rlcr_sources.py parity and behavior"
echo "========================================"

if ! command -v python3 &>/dev/null; then
    echo "SKIP: python3 not available"
    exit 0
fi

PASS_COUNT=0
FAIL_COUNT=0

_pass() { printf '\033[0;32mPASS\033[0m: %s\n' "$1"; PASS_COUNT=$((PASS_COUNT+1)); }
_fail() { printf '\033[0;31mFAIL\033[0m: %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT+1)); }

_shell_sanitize() {
    # Exact rule from scripts/humanize.sh:
    #   sanitized_project=$(echo "$project_root" | sed 's/[^a-zA-Z0-9._-]/-/g' | sed 's/--*/-/g')
    printf '%s\n' "$1" | sed 's/[^a-zA-Z0-9._-]/-/g' | sed 's/--*/-/g'
}

_py_sanitize() {
    python3 - "$1" <<'PYEOF'
import sys
sys.path.insert(0, "__VIZ_SERVER_DIR__")
from rlcr_sources import sanitize_project_path
print(sanitize_project_path(sys.argv[1]))
PYEOF
}

# Rewrite the __VIZ_SERVER_DIR__ placeholder so we can safely single-quote the heredoc
_py_sanitize() {
    python3 -c "
import sys
sys.path.insert(0, '$VIZ_SERVER_DIR')
from rlcr_sources import sanitize_project_path
print(sanitize_project_path(sys.argv[1]))
" "$1"
}

# ─── Test Group 1: sanitize_project_path parity ───
echo
echo "Group 1: sanitize_project_path parity with scripts/humanize.sh"

declare -a PROJECT_PATHS=(
    "/home/user/project"
    "/home/user/my project/with spaces"
    "/tmp/a_b.c-d"
    "/home/user/proj//double/slash"
    "/home/user/proj@@@weird!!chars"
    "/home/user/日本語/foo"
    "~/relative-ish"
)

for p in "${PROJECT_PATHS[@]}"; do
    expected="$(_shell_sanitize "$p")"
    actual="$(_py_sanitize "$p")"
    if [[ "$expected" == "$actual" ]]; then
        _pass "sanitize matches shell for: $p"
    else
        _fail "sanitize mismatch for: $p (shell='$expected' python='$actual')"
    fi
done

# Empty path should not explode
empty_shell="$(_shell_sanitize "")"
empty_py="$(_py_sanitize "")"
if [[ "$empty_shell" == "$empty_py" ]]; then
    _pass "sanitize matches shell for empty string"
else
    _fail "sanitize mismatch for empty string (shell='$empty_shell' python='$empty_py')"
fi

# ─── Test Group 2: enumerate_sessions + partition_sessions ───
echo
echo "Group 2: enumeration and partitioning"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

RLCR_DIR="$TMP_DIR/.humanize/rlcr"
mkdir -p "$RLCR_DIR"

# Active session: has state.md
mkdir -p "$RLCR_DIR/2026-04-17_10-00-00"
: > "$RLCR_DIR/2026-04-17_10-00-00/state.md"

# Historical session: has complete-state.md, no state.md
mkdir -p "$RLCR_DIR/2026-04-16_09-00-00"
: > "$RLCR_DIR/2026-04-16_09-00-00/complete-state.md"

# Unknown session: empty dir
mkdir -p "$RLCR_DIR/2026-04-15_08-00-00"

# Non-session file (should be skipped silently)
: > "$RLCR_DIR/not-a-session.txt"

ENUM_OUTPUT="$(python3 -c "
import sys
sys.path.insert(0, '$VIZ_SERVER_DIR')
from rlcr_sources import enumerate_sessions, partition_sessions
entries = enumerate_sessions('$RLCR_DIR')
active, historical, unknown = partition_sessions(entries)
print('ALL:', '|'.join(e[0] for e in entries))
print('ACTIVE:', '|'.join(e[0] for e in active))
print('HISTORICAL:', '|'.join(e[0] for e in historical))
print('UNKNOWN:', '|'.join(e[0] for e in unknown))
")"

# Expected: chronological sort, 3 sessions total
if grep -q '^ALL: 2026-04-15_08-00-00|2026-04-16_09-00-00|2026-04-17_10-00-00$' <<<"$ENUM_OUTPUT"; then
    _pass "enumerate lists all 3 seeded sessions in chronological order"
else
    _fail "enumerate output unexpected: $(grep '^ALL:' <<<"$ENUM_OUTPUT")"
fi

if grep -q '^ACTIVE: 2026-04-17_10-00-00$' <<<"$ENUM_OUTPUT"; then
    _pass "partition identifies active session"
else
    _fail "active partition wrong: $(grep '^ACTIVE:' <<<"$ENUM_OUTPUT")"
fi

if grep -q '^HISTORICAL: 2026-04-16_09-00-00$' <<<"$ENUM_OUTPUT"; then
    _pass "partition identifies historical session"
else
    _fail "historical partition wrong: $(grep '^HISTORICAL:' <<<"$ENUM_OUTPUT")"
fi

if grep -q '^UNKNOWN: 2026-04-15_08-00-00$' <<<"$ENUM_OUTPUT"; then
    _pass "partition identifies unknown session (no state files yet)"
else
    _fail "unknown partition wrong: $(grep '^UNKNOWN:' <<<"$ENUM_OUTPUT")"
fi

# RLCR lifecycle: methodology-analysis and finalize phases must classify as active.
# Plain *-state.md files (complete, cancel, etc.) must classify as historical.
mkdir -p "$RLCR_DIR/2026-04-14_07-00-00"
: > "$RLCR_DIR/2026-04-14_07-00-00/methodology-analysis-state.md"
mkdir -p "$RLCR_DIR/2026-04-13_06-00-00"
: > "$RLCR_DIR/2026-04-13_06-00-00/finalize-state.md"
mkdir -p "$RLCR_DIR/2026-04-12_05-00-00"
: > "$RLCR_DIR/2026-04-12_05-00-00/cancel-state.md"
mkdir -p "$RLCR_DIR/2026-04-11_04-00-00"
: > "$RLCR_DIR/2026-04-11_04-00-00/maxiter-state.md"

LIFECYCLE_OUTPUT="$(python3 -c "
import sys
sys.path.insert(0, '$VIZ_SERVER_DIR')
from rlcr_sources import enumerate_sessions, partition_sessions
entries = enumerate_sessions('$RLCR_DIR')
active, historical, unknown = partition_sessions(entries)
print('ACTIVE:', '|'.join(e[0] for e in active))
print('HISTORICAL:', '|'.join(e[0] for e in historical))
")"

# Active set should now include: 2026-04-13, 2026-04-14, 2026-04-17 (sorted lexically)
if grep -q '^ACTIVE: 2026-04-13_06-00-00|2026-04-14_07-00-00|2026-04-17_10-00-00$' <<<"$LIFECYCLE_OUTPUT"; then
    _pass "methodology-analysis and finalize phases classified as active"
else
    _fail "lifecycle active partition wrong: $(grep '^ACTIVE:' <<<"$LIFECYCLE_OUTPUT")"
fi

# Historical set should include: 2026-04-11 (maxiter), 2026-04-12 (cancel), 2026-04-16 (complete)
if grep -q '^HISTORICAL: 2026-04-11_04-00-00|2026-04-12_05-00-00|2026-04-16_09-00-00$' <<<"$LIFECYCLE_OUTPUT"; then
    _pass "complete/cancel/maxiter terminal states classified as historical"
else
    _fail "lifecycle historical partition wrong: $(grep '^HISTORICAL:' <<<"$LIFECYCLE_OUTPUT")"
fi

# Cleanup the lifecycle fixtures so subsequent tests still see the original 3-session shape
rm -rf "$RLCR_DIR/2026-04-11_04-00-00" "$RLCR_DIR/2026-04-12_05-00-00" "$RLCR_DIR/2026-04-13_06-00-00" "$RLCR_DIR/2026-04-14_07-00-00"

# Missing rlcr dir returns empty list without raising
MISSING_OUTPUT="$(python3 -c "
import sys
sys.path.insert(0, '$VIZ_SERVER_DIR')
from rlcr_sources import enumerate_sessions
print(enumerate_sessions('/tmp/does-not-exist-$$'))
")"
if [[ "$MISSING_OUTPUT" == "[]" ]]; then
    _pass "enumerate returns [] for missing rlcr dir"
else
    _fail "enumerate should return [] for missing dir, got: $MISSING_OUTPUT"
fi

# ─── Test Group 3: live_log_paths ───
echo
echo "Group 3: live_log_paths discovery and ordering"

# Seed a fake cache dir with a mix of valid and invalid filenames
CACHE_DIR="$TMP_DIR/fakecache/humanize/-home-someproject/2026-04-17_10-00-00"
mkdir -p "$CACHE_DIR"
: > "$CACHE_DIR/round-0-codex-run.log"
: > "$CACHE_DIR/round-0-codex-review.log"
: > "$CACHE_DIR/round-1-codex-run.log"
: > "$CACHE_DIR/round-1-gemini-run.log"
: > "$CACHE_DIR/round-10-codex-run.log"
: > "$CACHE_DIR/random-file.txt"        # should be ignored
: > "$CACHE_DIR/round-abc-codex-run.log" # should be ignored (non-numeric round)

LOGS_OUTPUT="$(python3 -c "
import sys
sys.path.insert(0, '$VIZ_SERVER_DIR')
from rlcr_sources import live_log_paths
for rnd, tool, role, path in live_log_paths('$CACHE_DIR'):
    print(f'{rnd}|{tool}|{role}')
")"

EXPECTED_LOGS="0|codex|review
0|codex|run
1|codex|run
1|gemini|run
10|codex|run"

if [[ "$LOGS_OUTPUT" == "$EXPECTED_LOGS" ]]; then
    _pass "live_log_paths returns 5 matches in (round,tool,role) order; ignores non-matching files"
else
    _fail "live_log_paths output unexpected:
---- expected ----
$EXPECTED_LOGS
---- actual ----
$LOGS_OUTPUT"
fi

# Missing cache dir returns empty list (startup race safety)
MISSING_LOGS="$(python3 -c "
import sys
sys.path.insert(0, '$VIZ_SERVER_DIR')
from rlcr_sources import live_log_paths
print(live_log_paths('/tmp/cache-does-not-exist-$$'))
")"
if [[ "$MISSING_LOGS" == "[]" ]]; then
    _pass "live_log_paths returns [] for missing cache dir (startup-race safety)"
else
    _fail "live_log_paths should return [] for missing dir, got: $MISSING_LOGS"
fi

# ─── Test Group 4: cache_dir_for_session path shape ───
echo
echo "Group 4: cache_dir_for_session path construction"

PATH_OUTPUT="$(
  XDG_CACHE_HOME="$TMP_DIR/cache_override" python3 -c "
import sys
sys.path.insert(0, '$VIZ_SERVER_DIR')
from rlcr_sources import cache_dir_for_session
print(cache_dir_for_session('/home/user/weird project', '2026-04-17_10-00-00'))
")"

EXPECTED_PATH="$TMP_DIR/cache_override/humanize/-home-user-weird-project/2026-04-17_10-00-00"
if [[ "$PATH_OUTPUT" == "$EXPECTED_PATH" ]]; then
    _pass "cache_dir_for_session respects XDG_CACHE_HOME and sanitization"
else
    _fail "cache_dir mismatch:
    expected: $EXPECTED_PATH
    actual:   $PATH_OUTPUT"
fi

# ─── Summary ───
echo
echo "========================================"
printf 'Passed: \033[0;32m%d\033[0m\n' "$PASS_COUNT"
printf 'Failed: \033[0;31m%d\033[0m\n' "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi

printf '\033[0;32mAll rlcr_sources tests passed!\033[0m\n'
