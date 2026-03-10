#!/bin/bash
# Tests for model-router.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"
source "$PROJECT_ROOT/scripts/lib/model-router.sh"

SAFE_BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

echo "=========================================="
echo "Model Router Tests"
echo "=========================================="
echo ""

create_mock_binary() {
    local bin_dir="$1"
    local binary_name="$2"

    mkdir -p "$bin_dir"
    cat > "$bin_dir/$binary_name" <<EOF
#!/bin/bash
exit 0
EOF
    chmod +x "$bin_dir/$binary_name"
}

# ========================================
# Test 1: gpt-5.3-codex routes to codex
# ========================================
echo "--- Test 1: gpt-5.3-codex routes to codex ---"
echo ""

result=""
exit_code=0
result=$(detect_provider "gpt-5.3-codex" 2>/dev/null) || exit_code=$?

if [[ $exit_code -eq 0 ]] && [[ "$result" == "codex" ]]; then
    pass "detect_provider: gpt-5.3-codex returns codex"
else
    fail "detect_provider: gpt-5.3-codex returns codex" "exit 0 + codex" "exit=$exit_code, output=$result"
fi

# ========================================
# Test 2: gpt-4o routes to codex
# ========================================
echo ""
echo "--- Test 2: gpt-4o routes to codex ---"
echo ""

result=""
exit_code=0
result=$(detect_provider "gpt-4o" 2>/dev/null) || exit_code=$?

if [[ $exit_code -eq 0 ]] && [[ "$result" == "codex" ]]; then
    pass "detect_provider: gpt-4o returns codex"
else
    fail "detect_provider: gpt-4o returns codex" "exit 0 + codex" "exit=$exit_code, output=$result"
fi

# ========================================
# Test 2a: o3-mini routes to codex
# ========================================
echo ""
echo "--- Test 2a: o3-mini routes to codex ---"
echo ""

result=""
exit_code=0
result=$(detect_provider "o3-mini" 2>/dev/null) || exit_code=$?

if [[ $exit_code -eq 0 ]] && [[ "$result" == "codex" ]]; then
    pass "detect_provider: o3-mini returns codex"
else
    fail "detect_provider: o3-mini returns codex" "exit 0 + codex" "exit=$exit_code, output=$result"
fi

# ========================================
# Test 2b: o1-pro routes to codex
# ========================================
echo ""
echo "--- Test 2b: o1-pro routes to codex ---"
echo ""

result=""
exit_code=0
result=$(detect_provider "o1-pro" 2>/dev/null) || exit_code=$?

if [[ $exit_code -eq 0 ]] && [[ "$result" == "codex" ]]; then
    pass "detect_provider: o1-pro returns codex"
else
    fail "detect_provider: o1-pro returns codex" "exit 0 + codex" "exit=$exit_code, output=$result"
fi

# ========================================
# Test 3: haiku routes to claude
# ========================================
echo ""
echo "--- Test 3: haiku routes to claude ---"
echo ""

result=""
exit_code=0
result=$(detect_provider "haiku" 2>/dev/null) || exit_code=$?

if [[ $exit_code -eq 0 ]] && [[ "$result" == "claude" ]]; then
    pass "detect_provider: haiku returns claude"
else
    fail "detect_provider: haiku returns claude" "exit 0 + claude" "exit=$exit_code, output=$result"
fi

# ========================================
# Test 4: sonnet routes to claude
# ========================================
echo ""
echo "--- Test 4: sonnet routes to claude ---"
echo ""

result=""
exit_code=0
result=$(detect_provider "sonnet" 2>/dev/null) || exit_code=$?

if [[ $exit_code -eq 0 ]] && [[ "$result" == "claude" ]]; then
    pass "detect_provider: sonnet returns claude"
else
    fail "detect_provider: sonnet returns claude" "exit 0 + claude" "exit=$exit_code, output=$result"
fi

# ========================================
# Test 5: opus routes to claude
# ========================================
echo ""
echo "--- Test 5: opus routes to claude ---"
echo ""

result=""
exit_code=0
result=$(detect_provider "opus" 2>/dev/null) || exit_code=$?

if [[ $exit_code -eq 0 ]] && [[ "$result" == "claude" ]]; then
    pass "detect_provider: opus returns claude"
else
    fail "detect_provider: opus returns claude" "exit 0 + claude" "exit=$exit_code, output=$result"
fi

# ========================================
# Test 6: claude-sonnet-4-6 routes to claude
# ========================================
echo ""
echo "--- Test 6: claude-sonnet-4-6 routes to claude ---"
echo ""

result=""
exit_code=0
result=$(detect_provider "claude-sonnet-4-6" 2>/dev/null) || exit_code=$?

if [[ $exit_code -eq 0 ]] && [[ "$result" == "claude" ]]; then
    pass "detect_provider: claude-sonnet-4-6 returns claude"
else
    fail "detect_provider: claude-sonnet-4-6 returns claude" "exit 0 + claude" "exit=$exit_code, output=$result"
fi

# ========================================
# Test 7: claude-3-OPUS-20240229 routes to claude
# ========================================
echo ""
echo "--- Test 7: claude-3-OPUS-20240229 routes to claude ---"
echo ""

result=""
exit_code=0
result=$(detect_provider "claude-3-OPUS-20240229" 2>/dev/null) || exit_code=$?

if [[ $exit_code -eq 0 ]] && [[ "$result" == "claude" ]]; then
    pass "detect_provider: claude-3-OPUS-20240229 returns claude"
else
    fail "detect_provider: claude-3-OPUS-20240229 returns claude" "exit 0 + claude" "exit=$exit_code, output=$result"
fi

# ========================================
# Test 8: unknown model exits non-zero
# ========================================
echo ""
echo "--- Test 8: unknown model exits non-zero ---"
echo ""

exit_code=0
stderr_out=""
stderr_out=$(detect_provider "unknown-xyz" 2>&1 >/dev/null) || exit_code=$?

if [[ $exit_code -ne 0 ]] && echo "$stderr_out" | grep -qiE "unknown|error"; then
    pass "detect_provider: unknown model exits non-zero with error"
else
    fail "detect_provider: unknown model exits non-zero with error" "non-zero exit + error message" "exit=$exit_code, stderr=$stderr_out"
fi

# ========================================
# Test 9: empty model exits non-zero
# ========================================
echo ""
echo "--- Test 9: empty model exits non-zero ---"
echo ""

exit_code=0
stderr_out=""
stderr_out=$(detect_provider "" 2>&1 >/dev/null) || exit_code=$?

if [[ $exit_code -ne 0 ]] && echo "$stderr_out" | grep -qiE "non-empty|error"; then
    pass "detect_provider: empty model exits non-zero with error"
else
    fail "detect_provider: empty model exits non-zero with error" "non-zero exit + error message" "exit=$exit_code, stderr=$stderr_out"
fi

# ========================================
# Test 10: codex dependency succeeds when codex is in PATH
# ========================================
echo ""
echo "--- Test 10: codex dependency succeeds with mock binary ---"
echo ""

setup_test_dir
BIN_DIR="$TEST_DIR/bin"
create_mock_binary "$BIN_DIR" "codex"

if PATH="$BIN_DIR:$SAFE_BASE_PATH" check_provider_dependency "codex" >/dev/null 2>&1; then
    pass "check_provider_dependency: codex succeeds when mock codex is in PATH"
else
    fail "check_provider_dependency: codex succeeds when mock codex is in PATH" "exit 0" "non-zero exit"
fi

# ========================================
# Test 11: codex dependency fails when codex is not in PATH
# ========================================
echo ""
echo "--- Test 11: codex dependency fails without codex ---"
echo ""

exit_code=0
stderr_out=""
stderr_out=$(PATH="$SAFE_BASE_PATH" check_provider_dependency "codex" 2>&1 >/dev/null) || exit_code=$?

if [[ $exit_code -ne 0 ]] && echo "$stderr_out" | grep -qi "codex"; then
    pass "check_provider_dependency: codex fails when codex is missing"
else
    fail "check_provider_dependency: codex fails when codex is missing" "non-zero exit + codex in stderr" "exit=$exit_code, stderr=$stderr_out"
fi

# ========================================
# Test 12: claude dependency succeeds when claude is in PATH
# ========================================
echo ""
echo "--- Test 12: claude dependency succeeds with mock binary ---"
echo ""

setup_test_dir
BIN_DIR="$TEST_DIR/bin"
create_mock_binary "$BIN_DIR" "claude"

if PATH="$BIN_DIR:$SAFE_BASE_PATH" check_provider_dependency "claude" >/dev/null 2>&1; then
    pass "check_provider_dependency: claude succeeds when mock claude is in PATH"
else
    fail "check_provider_dependency: claude succeeds when mock claude is in PATH" "exit 0" "non-zero exit"
fi

# ========================================
# Test 13: claude dependency fails when claude is not in PATH
# ========================================
echo ""
echo "--- Test 13: claude dependency fails without claude ---"
echo ""

exit_code=0
stderr_out=""
stderr_out=$(PATH="$SAFE_BASE_PATH" check_provider_dependency "claude" 2>&1 >/dev/null) || exit_code=$?

if [[ $exit_code -ne 0 ]] && echo "$stderr_out" | grep -qi "claude"; then
    pass "check_provider_dependency: claude fails when claude is missing"
else
    fail "check_provider_dependency: claude fails when claude is missing" "non-zero exit + claude in stderr" "exit=$exit_code, stderr=$stderr_out"
fi

# ========================================
# Test 14: xhigh maps to high for claude
# ========================================
echo ""
echo "--- Test 14: xhigh maps to high for claude ---"
echo ""

setup_test_dir
result=""
stderr_out=""
exit_code=0
result=$(map_effort "xhigh" "claude" 2> "$TEST_DIR/map-effort-stderr.txt") || exit_code=$?
stderr_out="$(cat "$TEST_DIR/map-effort-stderr.txt")"

if [[ $exit_code -eq 0 ]] && [[ "$result" == "high" ]] && echo "$stderr_out" | grep -qiE "mapping effort|xhigh|high"; then
    pass "map_effort: xhigh maps to high for claude with info log"
else
    fail "map_effort: xhigh maps to high for claude with info log" "exit 0 + high + info log" "exit=$exit_code, output=$result, stderr=$stderr_out"
fi

# ========================================
# Test 15: high passes through for codex
# ========================================
echo ""
echo "--- Test 15: high passes through for codex ---"
echo ""

result=""
exit_code=0
result=$(map_effort "high" "codex" 2>/dev/null) || exit_code=$?

if [[ $exit_code -eq 0 ]] && [[ "$result" == "high" ]]; then
    pass "map_effort: high passes through for codex"
else
    fail "map_effort: high passes through for codex" "exit 0 + high" "exit=$exit_code, output=$result"
fi

# ========================================
# Test 16: xhigh passes through for codex
# ========================================
echo ""
echo "--- Test 16: xhigh passes through for codex ---"
echo ""

result=""
exit_code=0
result=$(map_effort "xhigh" "codex" 2>/dev/null) || exit_code=$?

if [[ $exit_code -eq 0 ]] && [[ "$result" == "xhigh" ]]; then
    pass "map_effort: xhigh passes through for codex"
else
    fail "map_effort: xhigh passes through for codex" "exit 0 + xhigh" "exit=$exit_code, output=$result"
fi

# ========================================
# Test 17: medium passes through for claude
# ========================================
echo ""
echo "--- Test 17: medium passes through for claude ---"
echo ""

result=""
exit_code=0
result=$(map_effort "medium" "claude" 2>/dev/null) || exit_code=$?

if [[ $exit_code -eq 0 ]] && [[ "$result" == "medium" ]]; then
    pass "map_effort: medium passes through for claude"
else
    fail "map_effort: medium passes through for claude" "exit 0 + medium" "exit=$exit_code, output=$result"
fi

# ========================================
# Test 18: low passes through for claude
# ========================================
echo ""
echo "--- Test 18: low passes through for claude ---"
echo ""

result=""
exit_code=0
result=$(map_effort "low" "claude" 2>/dev/null) || exit_code=$?

if [[ $exit_code -eq 0 ]] && [[ "$result" == "low" ]]; then
    pass "map_effort: low passes through for claude"
else
    fail "map_effort: low passes through for claude" "exit 0 + low" "exit=$exit_code, output=$result"
fi

# ========================================
# Test 19: unknown claude effort exits non-zero
# ========================================
echo ""
echo "--- Test 19: unknown claude effort exits non-zero ---"
echo ""

exit_code=0
stderr_out=""
stderr_out=$(map_effort "ultra" "claude" 2>&1 >/dev/null) || exit_code=$?

if [[ $exit_code -ne 0 ]] && echo "$stderr_out" | grep -qiE "unknown effort|error"; then
    pass "map_effort: unknown claude effort exits non-zero with error"
else
    fail "map_effort: unknown claude effort exits non-zero with error" "non-zero exit + error message" "exit=$exit_code, stderr=$stderr_out"
fi

# ========================================
# Test 20: unknown codex effort exits non-zero
# ========================================
echo ""
echo "--- Test 20: unknown codex effort exits non-zero ---"
echo ""

exit_code=0
stderr_out=""
stderr_out=$(map_effort "ultra" "codex" 2>&1 >/dev/null) || exit_code=$?

if [[ $exit_code -ne 0 ]] && echo "$stderr_out" | grep -qiE "unknown effort|error"; then
    pass "map_effort: unknown codex effort exits non-zero with error"
else
    fail "map_effort: unknown codex effort exits non-zero with error" "non-zero exit + error message" "exit=$exit_code, stderr=$stderr_out"
fi

# ========================================
# Summary
# ========================================

print_test_summary "Model Router Test Summary"
