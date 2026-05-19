#!/usr/bin/env bash
#
# Tests for ask-codex.sh - one-shot consultation with mock Codex
#
# All tests use a mock codex binary (no real Codex calls).
# Mock behavior is controlled via exported environment variables:
#   MOCK_CODEX_EXIT_CODE - exit code the mock returns (default: 0)
#   MOCK_CODEX_STDOUT    - text the mock writes to stdout
#   MOCK_CODEX_STDERR    - text the mock writes to stderr
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

ASK_CODEX_SCRIPT="$SCRIPT_DIR/../scripts/ask-codex.sh"
ASK_CODEX_SKILL="$SCRIPT_DIR/../skills/ask-codex/SKILL.md"

echo "=========================================="
echo "Ask Codex Tests (mock)"
echo "=========================================="
echo ""

# ========================================
# Setup: mock codex binary and test project
# ========================================

setup_test_dir

# Create a mock git repo as PROJECT_ROOT
MOCK_PROJECT="$TEST_DIR/project"
init_test_git_repo "$MOCK_PROJECT"

# Create mock codex binary directory
MOCK_BIN_DIR="$TEST_DIR/mock-bin"
mkdir -p "$MOCK_BIN_DIR"

cat > "$MOCK_BIN_DIR/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
# Mock codex binary for testing ask-codex.sh
# Controlled via environment variables.
if [[ -n "${MOCK_CODEX_STDERR:-}" ]]; then
    echo "$MOCK_CODEX_STDERR" >&2
fi
if [[ -n "${MOCK_CODEX_STDOUT:-}" ]]; then
    echo "$MOCK_CODEX_STDOUT"
fi
# Consume stdin so the pipe doesn't break
cat > /dev/null
exit "${MOCK_CODEX_EXIT_CODE:-0}"
MOCK_EOF
chmod +x "$MOCK_BIN_DIR/codex"

# Export mock variables so child processes (the mock codex) can see them
export MOCK_CODEX_EXIT_CODE=""
export MOCK_CODEX_STDOUT=""
export MOCK_CODEX_STDERR=""

# Reset mock state between tests; also clears the skill dir so that
# find...sort|tail -1 always picks the single dir from the next invocation.
reset_mock() {
    export MOCK_CODEX_EXIT_CODE="0"
    export MOCK_CODEX_STDOUT=""
    export MOCK_CODEX_STDERR=""
    rm -rf "$MOCK_PROJECT/.humanize/skill" 2>/dev/null || true
}

# Override XDG_CACHE_HOME for run_ask_codex_capturing_dir; set to a non-writable path
# to exercise the fallback cache branch (CACHE_DIR=$SKILL_DIR/cache).
RUN_XDG_CACHE_HOME="$TEST_DIR/cache"

# Helper: run ask-codex with a controllable XDG_CACHE_HOME, capture stderr, and
# derive the exact project-local skill dir for that invocation.
# Sets RUN_EXIT_CODE (int) and RUN_SKILL_DIR (path, empty on resolution failure).
#
# Primary: "ask-codex: response saved to .../output.md" (emitted on success, always
#   project-local regardless of which cache layout was used).
# Fallback A: "ask-codex: cache=.../skill-<id>"  -> normal layout
# Fallback B: "ask-codex: cache=.../.humanize/skill/<id>/cache" -> fallback layout
# If none of the above match, RUN_SKILL_DIR is set to "" (explicit failure).
run_ask_codex_capturing_dir() {
    local run_stderr output_path cache_path skill_basename
    RUN_EXIT_CODE=0
    run_stderr=$(
        cd "$MOCK_PROJECT"
        export CLAUDE_PROJECT_DIR="$MOCK_PROJECT"
        export XDG_CACHE_HOME="$RUN_XDG_CACHE_HOME"
        PATH="$MOCK_BIN_DIR:$PATH" bash "$ASK_CODEX_SCRIPT" "$@" 2>&1 >/dev/null
    ) || RUN_EXIT_CODE=$?
    output_path=$(printf '%s\n' "$run_stderr" | grep "^ask-codex: response saved to " | sed 's/^ask-codex: response saved to //')
    if [[ -n "$output_path" ]]; then
        RUN_SKILL_DIR=$(dirname "$output_path")
        return
    fi
    cache_path=$(printf '%s\n' "$run_stderr" | grep "^ask-codex: cache=" | sed 's/^ask-codex: cache=//')
    skill_basename=$(basename "$cache_path")
    case "$skill_basename" in
        skill-*)
            RUN_SKILL_DIR="$MOCK_PROJECT/.humanize/skill/${skill_basename#skill-}"
            ;;
        cache)
            RUN_SKILL_DIR=$(dirname "$cache_path")
            ;;
        *)
            RUN_SKILL_DIR=""
            ;;
    esac
}

# Helper: run ask-codex with mock codex in PATH, inside mock project
run_ask_codex() {
    (
        cd "$MOCK_PROJECT"
        export CLAUDE_PROJECT_DIR="$MOCK_PROJECT"
        export XDG_CACHE_HOME="$TEST_DIR/cache"
        PATH="$MOCK_BIN_DIR:$PATH" bash "$ASK_CODEX_SCRIPT" "$@"
    )
}

# ========================================
# Validation Tests
# ========================================

echo "--- Validation Tests ---"
echo ""

# Test: empty question
EXIT_CODE=0
OUTPUT=$(run_ask_codex 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]] && echo "$OUTPUT" | grep -q "No question or task provided"; then
    pass "empty question exits 1 with error message"
else
    fail "empty question exits 1 with error message" "exit 1 + error" "exit=$EXIT_CODE"
fi

# Test: --help exits 0
EXIT_CODE=0
OUTPUT=$(run_ask_codex --help 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]] && echo "$OUTPUT" | grep -q "USAGE"; then
    pass "--help exits 0 with usage info"
else
    fail "--help exits 0 with usage info" "exit 0 + USAGE" "exit=$EXIT_CODE"
fi

# Test: unknown option exits 1
EXIT_CODE=0
OUTPUT=$(run_ask_codex --bad-flag test 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]] && echo "$OUTPUT" | grep -q "Unknown option"; then
    pass "unknown option exits 1"
else
    fail "unknown option exits 1" "exit 1 + Unknown option" "exit=$EXIT_CODE"
fi

# Test: --codex-model without argument
EXIT_CODE=0
OUTPUT=$(run_ask_codex --codex-model 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]] && echo "$OUTPUT" | grep -q "requires a MODEL:EFFORT"; then
    pass "--codex-model without argument exits 1"
else
    fail "--codex-model without argument exits 1" "exit 1" "exit=$EXIT_CODE"
fi

# Test: --codex-timeout without argument
EXIT_CODE=0
OUTPUT=$(run_ask_codex --codex-timeout 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]] && echo "$OUTPUT" | grep -q "requires a number"; then
    pass "--codex-timeout without argument exits 1"
else
    fail "--codex-timeout without argument exits 1" "exit 1" "exit=$EXIT_CODE"
fi

# Test: --codex-timeout non-numeric
EXIT_CODE=0
OUTPUT=$(run_ask_codex --codex-timeout abc test 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]] && echo "$OUTPUT" | grep -q "must be a positive integer"; then
    pass "--codex-timeout non-numeric exits 1"
else
    fail "--codex-timeout non-numeric exits 1" "exit 1" "exit=$EXIT_CODE"
fi

# Test: invalid model characters
EXIT_CODE=0
OUTPUT=$(run_ask_codex --codex-model 'bad;model' test 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]] && echo "$OUTPUT" | grep -q "invalid characters"; then
    pass "invalid model characters exits 1"
else
    fail "invalid model characters exits 1" "exit 1" "exit=$EXIT_CODE"
fi

# Test: invalid effort characters
EXIT_CODE=0
OUTPUT=$(run_ask_codex --codex-model 'model:bad;effort' test 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]] && echo "$OUTPUT" | grep -q "invalid characters"; then
    pass "invalid effort characters exits 1"
else
    fail "invalid effort characters exits 1" "exit 1" "exit=$EXIT_CODE"
fi

# ========================================
# Successful Run Tests
# ========================================

echo ""
echo "--- Successful Run Tests ---"
echo ""

# Test: successful codex response appears on stdout
reset_mock
export MOCK_CODEX_STDOUT="This is the answer"
STDOUT=$(run_ask_codex "What is 1+1?" 2>/dev/null)
if echo "$STDOUT" | grep -q "This is the answer"; then
    pass "successful run outputs codex response to stdout"
else
    fail "successful run outputs codex response to stdout" "This is the answer" "$STDOUT"
fi

# Test: successful run creates output.md in skill dir
SKILL_DIRS_BEFORE=$(find "$MOCK_PROJECT/.humanize/skill" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
reset_mock
export MOCK_CODEX_STDOUT="Test output for file"
run_ask_codex "file test" > /dev/null 2>&1
SKILL_DIRS_AFTER=$(find "$MOCK_PROJECT/.humanize/skill" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
NEW_DIR=$(comm -13 <(echo "$SKILL_DIRS_BEFORE") <(echo "$SKILL_DIRS_AFTER") | head -1)
if [[ -n "$NEW_DIR" ]] && [[ -f "$NEW_DIR/output.md" ]] && grep -q "Test output for file" "$NEW_DIR/output.md"; then
    pass "successful run creates output.md with codex response"
else
    fail "successful run creates output.md with codex response" "output.md with content" "dir=$NEW_DIR"
fi

# Test: successful run creates metadata.md with status: success
if [[ -n "$NEW_DIR" ]] && [[ -f "$NEW_DIR/metadata.md" ]] && grep -q "status: success" "$NEW_DIR/metadata.md"; then
    pass "successful run creates metadata.md with status: success"
else
    fail "successful run creates metadata.md with status: success"
fi

# Test: successful run creates input.md with the question
if [[ -n "$NEW_DIR" ]] && [[ -f "$NEW_DIR/input.md" ]] && grep -q "file test" "$NEW_DIR/input.md"; then
    pass "successful run saves question to input.md"
else
    fail "successful run saves question to input.md"
fi

# Test: successful run exits 0
reset_mock
export MOCK_CODEX_STDOUT="ok"
EXIT_CODE=0
run_ask_codex "exit code test" > /dev/null 2>&1 || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "successful run exits 0"
else
    fail "successful run exits 0" "exit 0" "exit=$EXIT_CODE"
fi

# ========================================
# Error Handling Tests
# ========================================

echo ""
echo "--- Error Handling Tests ---"
echo ""

# Test: codex non-zero exit propagates
reset_mock
export MOCK_CODEX_EXIT_CODE="42"
export MOCK_CODEX_STDERR="something broke"
EXIT_CODE=0
run_ask_codex "error test" > /dev/null 2>&1 || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 42 ]]; then
    pass "codex non-zero exit code propagates"
else
    fail "codex non-zero exit code propagates" "exit 42" "exit=$EXIT_CODE"
fi

# Test: codex error creates metadata with status: error
LATEST_DIR=$(find "$MOCK_PROJECT/.humanize/skill" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1)
if [[ -n "$LATEST_DIR" ]] && [[ -f "$LATEST_DIR/metadata.md" ]] && grep -q "status: error" "$LATEST_DIR/metadata.md"; then
    pass "codex error creates metadata with status: error"
else
    fail "codex error creates metadata with status: error"
fi

# Test: codex empty response exits 1
reset_mock
export MOCK_CODEX_STDOUT=""
EXIT_CODE=0
run_ask_codex "empty test" > /dev/null 2>&1 || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]]; then
    pass "empty codex response exits 1"
else
    fail "empty codex response exits 1" "exit 1" "exit=$EXIT_CODE"
fi

# Test: empty response creates metadata with status: empty_response
LATEST_DIR=$(find "$MOCK_PROJECT/.humanize/skill" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1)
if [[ -n "$LATEST_DIR" ]] && [[ -f "$LATEST_DIR/metadata.md" ]] && grep -q "status: empty_response" "$LATEST_DIR/metadata.md"; then
    pass "empty response creates metadata with status: empty_response"
else
    fail "empty response creates metadata with status: empty_response"
fi

# Test: codex timeout (exit 124) is handled
reset_mock
export MOCK_CODEX_EXIT_CODE="124"
EXIT_CODE=0
STDERR=$(run_ask_codex --codex-timeout 999 "timeout test" 2>&1 >/dev/null) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 124 ]] && echo "$STDERR" | grep -q "timed out"; then
    pass "timeout exit 124 is handled with error message"
else
    fail "timeout exit 124 is handled with error message" "exit 124 + timed out" "exit=$EXIT_CODE"
fi

# Test: timeout creates metadata with status: timeout
LATEST_DIR=$(find "$MOCK_PROJECT/.humanize/skill" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1)
if [[ -n "$LATEST_DIR" ]] && [[ -f "$LATEST_DIR/metadata.md" ]] && grep -q "status: timeout" "$LATEST_DIR/metadata.md"; then
    pass "timeout creates metadata with status: timeout"
else
    fail "timeout creates metadata with status: timeout"
fi

# ========================================
# Directory Uniqueness Tests
# ========================================

echo ""
echo "--- Directory Uniqueness Tests ---"
echo ""

# Test: two rapid calls produce different skill directories
DIRS_BEFORE=$(find "$MOCK_PROJECT/.humanize/skill" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)

reset_mock
export MOCK_CODEX_STDOUT="call-concurrent"
run_ask_codex "uniqueness test 1" > /dev/null 2>&1 &
PID1=$!
run_ask_codex "uniqueness test 2" > /dev/null 2>&1 &
PID2=$!
wait "$PID1" 2>/dev/null || true
wait "$PID2" 2>/dev/null || true

DIRS_AFTER=$(find "$MOCK_PROJECT/.humanize/skill" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
NEW_DIRS=$(comm -13 <(echo "$DIRS_BEFORE") <(echo "$DIRS_AFTER"))
NEW_DIR_COUNT=$(echo "$NEW_DIRS" | grep -c . || true)

if [[ "$NEW_DIR_COUNT" -ge 2 ]]; then
    pass "two concurrent calls create distinct skill directories"
else
    fail "two concurrent calls create distinct skill directories" ">=2 new dirs" "$NEW_DIR_COUNT new dirs"
fi

# Test: cache directories are also unique
CACHE_BASE="$TEST_DIR/cache/humanize"
if [[ -d "$CACHE_BASE" ]]; then
    CACHE_DIRS=$(find "$CACHE_BASE" -maxdepth 2 -mindepth 2 -type d -name "skill-*" 2>/dev/null | sort)
    CACHE_DIR_COUNT=$(echo "$CACHE_DIRS" | grep -c . || true)
    if [[ "$CACHE_DIR_COUNT" -ge 2 ]]; then
        pass "concurrent calls create distinct cache directories"
    else
        fail "concurrent calls create distinct cache directories" ">=2 cache dirs" "$CACHE_DIR_COUNT"
    fi
else
    fail "concurrent calls create distinct cache directories" "cache dir exists" "not found"
fi

# ========================================
# Argument Parsing Tests
# ========================================

echo ""
echo "--- Argument Parsing Tests ---"
echo ""

# Test: --codex-model MODEL:EFFORT sets both model and effort
reset_mock
export MOCK_CODEX_STDOUT="model-test"
run_ask_codex_capturing_dir --codex-model "custom-model:high" "model test"
if [[ "$RUN_EXIT_CODE" -eq 0 ]] && [[ -d "$RUN_SKILL_DIR" ]] \
        && grep -q "Model: custom-model" "$RUN_SKILL_DIR/input.md" \
        && grep -q "Effort: high" "$RUN_SKILL_DIR/input.md"; then
    pass "--codex-model MODEL:EFFORT parses model and effort"
else
    fail "--codex-model MODEL:EFFORT parses model and effort"
fi

# Test: --codex-model MODEL (no effort) uses default effort
reset_mock
export MOCK_CODEX_STDOUT="effort-default-test"
run_ask_codex_capturing_dir --codex-model "solo-model" "effort default test"
if [[ "$RUN_EXIT_CODE" -eq 0 ]] && [[ -d "$RUN_SKILL_DIR" ]] \
        && grep -q "Model: solo-model" "$RUN_SKILL_DIR/input.md" \
        && grep -q "Effort: high" "$RUN_SKILL_DIR/input.md"; then
    pass "--codex-model MODEL without effort uses default high"
else
    fail "--codex-model MODEL without effort uses default high"
fi

# Test: -- separator treats remaining args as question
reset_mock
export MOCK_CODEX_STDOUT="separator-test"
run_ask_codex_capturing_dir -- --not-a-flag "is question"
if [[ "$RUN_EXIT_CODE" -eq 0 ]] && [[ -d "$RUN_SKILL_DIR" ]] \
        && grep -qF -- "--not-a-flag" "$RUN_SKILL_DIR/input.md"; then
    pass "-- separator passes remaining args as question text"
else
    fail "-- separator passes remaining args as question text"
fi

# Test: --codex-timeout is recorded in input.md
reset_mock
export MOCK_CODEX_STDOUT="timeout-val"
run_ask_codex_capturing_dir --codex-timeout 123 "timeout value test"
if [[ "$RUN_EXIT_CODE" -eq 0 ]] && [[ -d "$RUN_SKILL_DIR" ]] \
        && grep -q "Timeout: 123s" "$RUN_SKILL_DIR/input.md"; then
    pass "--codex-timeout value is recorded in input.md"
else
    fail "--codex-timeout value is recorded in input.md"
fi

# Test: run_ask_codex_capturing_dir resolves correct skill dir when home cache is not writable
# (exercises the ask-codex.sh fallback branch: CACHE_DIR=$SKILL_DIR/cache)
READONLY_CACHE="$TEST_DIR/readonly-cache"
mkdir -p "$READONLY_CACHE"
chmod 444 "$READONLY_CACHE"
reset_mock
export MOCK_CODEX_STDOUT="fallback-cache-test"
RUN_XDG_CACHE_HOME="$READONLY_CACHE"
run_ask_codex_capturing_dir "fallback cache skill dir test"
RUN_XDG_CACHE_HOME="$TEST_DIR/cache"
chmod 755 "$READONLY_CACHE"
if [[ "$RUN_EXIT_CODE" -eq 0 ]] && [[ -d "$RUN_SKILL_DIR" ]] \
        && grep -q "fallback cache skill dir test" "$RUN_SKILL_DIR/input.md"; then
    pass "run_ask_codex_capturing_dir resolves skill dir when home cache is not writable"
else
    fail "run_ask_codex_capturing_dir resolves skill dir when home cache is not writable" \
        "exit 0 + valid skill dir with input.md" \
        "exit=$RUN_EXIT_CODE skill_dir=$RUN_SKILL_DIR"
fi

# ========================================
# Cache Directory Tests
# ========================================

echo ""
echo "--- Cache Directory Tests ---"
echo ""

# Test: cache directory contains expected files
reset_mock
export MOCK_CODEX_STDOUT="cache-file-test"
EXIT_CODE=0
STDERR=$(run_ask_codex "cache test" 2>&1 >/dev/null) || EXIT_CODE=$?
# Extract cache path from stderr
CACHE_PATH=$(echo "$STDERR" | grep "ask-codex: cache=" | sed 's/ask-codex: cache=//')
if [[ -n "$CACHE_PATH" ]] && [[ -f "$CACHE_PATH/codex-run.cmd" ]]; then
    pass "cache directory contains codex-run.cmd"
else
    fail "cache directory contains codex-run.cmd" "codex-run.cmd exists" "cache=$CACHE_PATH"
fi

if [[ -n "$CACHE_PATH" ]] && [[ -f "$CACHE_PATH/codex-run.out" ]]; then
    pass "cache directory contains codex-run.out"
else
    fail "cache directory contains codex-run.out"
fi

if [[ -n "$CACHE_PATH" ]] && grep -q "cache test" "$CACHE_PATH/codex-run.cmd"; then
    pass "codex-run.cmd records the question"
else
    fail "codex-run.cmd records the question"
fi

# ========================================
# Skill Guidance Tests
# ========================================

echo ""
echo "--- Skill Guidance Tests ---"
echo ""

# Test: skill explicitly warns against unsafe bare $ARGUMENTS shell expansion
if grep -Fq 'Never run this unsafe form' "$ASK_CODEX_SKILL" && grep -Fq '"${CLAUDE_PLUGIN_ROOT}/scripts/ask-codex.sh" $ARGUMENTS' "$ASK_CODEX_SKILL"; then
    pass "skill warns against bare \$ARGUMENTS shell expansion"
else
    fail "skill warns against bare \$ARGUMENTS shell expansion" "explicit unsafe-form warning" "missing"
fi

# Test: skill documents the safe quoted simple invocation
if grep -Fq '"${CLAUDE_PLUGIN_ROOT}/scripts/ask-codex.sh" "$ARGUMENTS"' "$ASK_CODEX_SKILL"; then
    pass "skill quotes the question when no flags are present"
else
    fail "skill quotes the question when no flags are present" "quoted simple invocation" "missing"
fi

# Test: skill explains that free-form text must be a quoted final argument
if grep -Fq 'one quoted final argument' "$ASK_CODEX_SKILL"; then
    pass "skill requires one quoted final argument for free-form text"
else
    fail "skill requires one quoted final argument for free-form text" "quoted final argument guidance" "missing"
fi

# ========================================
# Auto-Probe: Nested Hook Disable Tests
# ========================================

echo ""
echo "--- Auto-Probe: Nested Hook Disable Tests ---"
echo ""

# Setup: create a secondary mock codex binary directory for probe tests,
# so the probe result is not cached from earlier tests.
PROBE_BIN_DIR="$TEST_DIR/probe-bin"
PROBE_PROJECT="$TEST_DIR/probe-project"
init_test_git_repo "$PROBE_PROJECT"
mkdir -p "$PROBE_BIN_DIR"

run_ask_codex_probe() {
    (
        cd "$PROBE_PROJECT"
        export CLAUDE_PROJECT_DIR="$PROBE_PROJECT"
        export XDG_CACHE_HOME="$TEST_DIR/cache-probe"
        PATH="$PROBE_BIN_DIR:$PATH" bash "$ASK_CODEX_SCRIPT" "$@"
    )
}

# Test A: when codex supports --disable, ask-codex.sh injects --disable hooks
# Create a mock codex that echoes "--disable" in its --help output
cat > "$PROBE_BIN_DIR/codex" << 'PROBE_MOCK_SUPPORTS'
#!/usr/bin/env bash
if [[ "${1:-}" == "--help" ]] || echo "$*" | grep -q -- '--help'; then
    echo "--disable <feature>   Disable a named feature"
    for i in $(seq 1 5000); do
        printf -- "--noise-%s\n" "$i"
    done
    exit 0
fi
if [[ -n "${MOCK_CODEX_STDERR:-}" ]]; then echo "$MOCK_CODEX_STDERR" >&2; fi
if [[ -n "${MOCK_CODEX_STDOUT:-}" ]]; then echo "$MOCK_CODEX_STDOUT"; fi
cat > /dev/null
exit "${MOCK_CODEX_EXIT_CODE:-0}"
PROBE_MOCK_SUPPORTS
chmod +x "$PROBE_BIN_DIR/codex"

reset_mock
export MOCK_CODEX_STDOUT="probe-test-supports"
run_ask_codex_probe "probe disable test" > /dev/null 2>&1 || true

# Check that the cached probe result is "yes" in the skill dir
PROBE_SKILL_DIR=$(find "$PROBE_PROJECT/.humanize/skill" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1)
if [[ -n "$PROBE_SKILL_DIR" ]] && [[ -f "$PROBE_SKILL_DIR/.codex-disable-hooks-supported" ]]; then
    PROBE_RESULT=$(cat "$PROBE_SKILL_DIR/.codex-disable-hooks-supported")
    if [[ "$PROBE_RESULT" == "yes" ]]; then
        pass "auto-probe: cached 'yes' when codex supports --disable"
    else
        fail "auto-probe: cached 'yes' when codex supports --disable" "yes" "$PROBE_RESULT"
    fi
else
    fail "auto-probe: probe cache file created" "cache file exists" "not found"
fi

# Test B: when codex does NOT support --disable, probe result is "no"
PROBE_BIN_NO_DIR="$TEST_DIR/probe-bin-no"
PROBE_PROJECT_NO="$TEST_DIR/probe-project-no"
init_test_git_repo "$PROBE_PROJECT_NO"
mkdir -p "$PROBE_BIN_NO_DIR"

cat > "$PROBE_BIN_NO_DIR/codex" << 'PROBE_MOCK_NO_SUPPORT'
#!/usr/bin/env bash
if [[ "${1:-}" == "--help" ]] || echo "$*" | grep -q -- '--help'; then
    echo "Usage: codex exec [options]"
    echo "  --full-auto   Run without prompts"
    exit 0
fi
if [[ -n "${MOCK_CODEX_STDERR:-}" ]]; then echo "$MOCK_CODEX_STDERR" >&2; fi
if [[ -n "${MOCK_CODEX_STDOUT:-}" ]]; then echo "$MOCK_CODEX_STDOUT"; fi
cat > /dev/null
exit "${MOCK_CODEX_EXIT_CODE:-0}"
PROBE_MOCK_NO_SUPPORT
chmod +x "$PROBE_BIN_NO_DIR/codex"

run_ask_codex_probe_no() {
    (
        cd "$PROBE_PROJECT_NO"
        export CLAUDE_PROJECT_DIR="$PROBE_PROJECT_NO"
        export XDG_CACHE_HOME="$TEST_DIR/cache-probe-no"
        PATH="$PROBE_BIN_NO_DIR:$PATH" bash "$ASK_CODEX_SCRIPT" "$@"
    )
}

reset_mock
export MOCK_CODEX_STDOUT="probe-test-no-support"
run_ask_codex_probe_no "probe no-support test" > /dev/null 2>&1 || true

PROBE_NO_SKILL_DIR=$(find "$PROBE_PROJECT_NO/.humanize/skill" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1)
if [[ -n "$PROBE_NO_SKILL_DIR" ]] && [[ -f "$PROBE_NO_SKILL_DIR/.codex-disable-hooks-supported" ]]; then
    PROBE_NO_RESULT=$(cat "$PROBE_NO_SKILL_DIR/.codex-disable-hooks-supported")
    if [[ "$PROBE_NO_RESULT" == "no" ]]; then
        pass "auto-probe: cached 'no' when codex does not support --disable"
    else
        fail "auto-probe: cached 'no' when codex does not support --disable" "no" "$PROBE_NO_RESULT"
    fi
else
    fail "auto-probe: probe cache file created for no-support case" "cache file exists" "not found"
fi

# Test C: ask-codex.sh script contains the probe implementation
if grep -q "CODEX_DISABLE_HOOKS_ARGS=(--disable hooks)" "$ASK_CODEX_SCRIPT" \
    && grep -q "codex-disable-hooks-supported" "$ASK_CODEX_SCRIPT"; then
    pass "ask-codex.sh contains nested hook disable auto-probe implementation"
else
    fail "ask-codex.sh contains nested hook disable auto-probe implementation" "hooks disable args + probe cache" "not found"
fi

# ========================================
# Summary
# ========================================

print_test_summary "Ask Codex Test Summary"
