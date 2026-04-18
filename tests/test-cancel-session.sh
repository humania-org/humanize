#!/usr/bin/env bash
#
# Tests for scripts/cancel-rlcr-session.sh.
#
# Verifies the session-scoped cancel helper added in Round 4 (T7):
#   - missing --session-id is rejected with exit code 3
#   - non-existent session id is rejected with exit code 1
#   - cancelling session A leaves a sibling active session B untouched
#   - state.md is renamed to cancel-state.md and .cancel-requested is created
#   - session in finalize phase requires --force (exit code 2 otherwise)
#
# All fixtures live under a per-test mktemp tree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$PLUGIN_ROOT/scripts/cancel-rlcr-session.sh"

echo "========================================"
echo "cancel-rlcr-session.sh (T7)"
echo "========================================"

if [[ ! -x "$HELPER" ]]; then
    echo "FAIL: $HELPER not found or not executable" >&2
    exit 1
fi

PASS_COUNT=0
FAIL_COUNT=0

_pass() { printf '\033[0;32mPASS\033[0m: %s\n' "$1"; PASS_COUNT=$((PASS_COUNT+1)); }
_fail() { printf '\033[0;31mFAIL\033[0m: %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT+1)); }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT_ROOT="$TMP_DIR/proj"
RLCR_DIR="$PROJECT_ROOT/.humanize/rlcr"
mkdir -p "$RLCR_DIR"

SESSION_A="2026-04-17_10-00-00"
SESSION_B="2026-04-17_11-00-00"
SESSION_FINALIZE="2026-04-17_12-00-00"

mkdir -p "$RLCR_DIR/$SESSION_A" "$RLCR_DIR/$SESSION_B" "$RLCR_DIR/$SESSION_FINALIZE"
: > "$RLCR_DIR/$SESSION_A/state.md"
: > "$RLCR_DIR/$SESSION_B/state.md"
: > "$RLCR_DIR/$SESSION_FINALIZE/finalize-state.md"

# ─── Test 1: missing --session-id ───
if "$HELPER" --project "$PROJECT_ROOT" >/dev/null 2>&1; then
    _fail "missing --session-id should exit non-zero"
else
    rc=$?
    if [[ "$rc" -eq 3 ]]; then
        _pass "missing --session-id exits with code 3"
    else
        _fail "missing --session-id should exit 3, got $rc"
    fi
fi

# ─── Test 2: non-existent session id ───
if "$HELPER" --project "$PROJECT_ROOT" --session-id 9999-99-99 >/dev/null 2>&1; then
    _fail "non-existent session should exit non-zero"
else
    rc=$?
    if [[ "$rc" -eq 1 ]]; then
        _pass "non-existent session exits with code 1"
    else
        _fail "non-existent session should exit 1, got $rc"
    fi
fi

# ─── Test 3: successful cancel of session A ───
out=$("$HELPER" --project "$PROJECT_ROOT" --session-id "$SESSION_A" 2>&1)
rc=$?
if [[ "$rc" -eq 0 ]] && grep -q "^CANCELLED $SESSION_A$" <<<"$out"; then
    _pass "cancel of active session A succeeds (exit 0, CANCELLED line present)"
else
    _fail "cancel of session A failed: rc=$rc out=$out"
fi

# ─── Test 4: state.md renamed to cancel-state.md ───
if [[ -f "$RLCR_DIR/$SESSION_A/cancel-state.md" && ! -f "$RLCR_DIR/$SESSION_A/state.md" ]]; then
    _pass "session A: state.md renamed to cancel-state.md"
else
    _fail "session A: rename did not happen"
fi

# ─── Test 5: .cancel-requested signal file created ───
if [[ -f "$RLCR_DIR/$SESSION_A/.cancel-requested" ]]; then
    _pass "session A: .cancel-requested signal file present"
else
    _fail "session A: .cancel-requested missing"
fi

# ─── Test 6: session B untouched ───
if [[ -f "$RLCR_DIR/$SESSION_B/state.md" && ! -f "$RLCR_DIR/$SESSION_B/cancel-state.md" && ! -f "$RLCR_DIR/$SESSION_B/.cancel-requested" ]]; then
    _pass "session B: untouched while session A was cancelled"
else
    _fail "session B: should be untouched but was modified"
fi

# ─── Test 7: finalize phase requires --force ───
if "$HELPER" --project "$PROJECT_ROOT" --session-id "$SESSION_FINALIZE" >/dev/null 2>&1; then
    _fail "finalize-phase session should require --force"
else
    rc=$?
    if [[ "$rc" -eq 2 ]]; then
        _pass "finalize-phase session without --force exits with code 2"
    else
        _fail "finalize-phase should exit 2, got $rc"
    fi
fi

# ─── Test 8: finalize phase with --force succeeds ───
out=$("$HELPER" --project "$PROJECT_ROOT" --session-id "$SESSION_FINALIZE" --force 2>&1)
rc=$?
if [[ "$rc" -eq 0 ]] && [[ -f "$RLCR_DIR/$SESSION_FINALIZE/cancel-state.md" ]]; then
    _pass "finalize-phase session with --force is cancelled"
else
    _fail "finalize-phase --force failed: rc=$rc out=$out"
fi

# ─── Test 9: legacy positional argument form still works ───
SESSION_LEGACY="2026-04-17_13-00-00"
mkdir -p "$RLCR_DIR/$SESSION_LEGACY"
: > "$RLCR_DIR/$SESSION_LEGACY/state.md"
out=$("$HELPER" --project "$PROJECT_ROOT" "$SESSION_LEGACY" 2>&1)
rc=$?
if [[ "$rc" -eq 0 ]] && [[ -f "$RLCR_DIR/$SESSION_LEGACY/cancel-state.md" ]]; then
    _pass "legacy positional session-id form still works"
else
    _fail "legacy positional form failed: rc=$rc out=$out"
fi

echo
echo "========================================"
printf 'Passed: \033[0;32m%d\033[0m\n' "$PASS_COUNT"
printf 'Failed: \033[0;31m%d\033[0m\n' "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi

printf '\033[0;32mAll cancel-session tests passed!\033[0m\n'
