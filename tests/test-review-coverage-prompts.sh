#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "${RED}FAIL${NC}: $1"
    if [[ -n "${2:-}" ]]; then
        echo "  Expected: $2"
    fi
    if [[ -n "${3:-}" ]]; then
        echo "  Got: $3"
    fi
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

regular_template="$PROJECT_ROOT/prompt-template/codex/regular-review.md"
full_template="$PROJECT_ROOT/prompt-template/codex/full-alignment-review.md"

require_string() {
    local file="$1"
    local pattern="$2"
    local description="$3"

    if grep -Fq -- "$pattern" "$file"; then
        pass "$description"
    else
        fail "$description" "$pattern in $file" "$(sed -n '1,220p' "$file")"
    fi
}

require_string "$regular_template" "Touched Failure Surfaces" "regular review prompt requires touched failure surfaces"
require_string "$regular_template" "Likely Sibling Risks" "regular review prompt requires likely sibling risks"
require_string "$regular_template" "Coverage Ledger" "regular review prompt requires coverage ledger"
require_string "$regular_template" "Historical Tail-Repair Scan" "regular review prompt requires historical tail-repair scan"
require_string "$regular_template" "git log --oneline --stat -n 12" "regular review prompt inspects recent git history"
require_string "$regular_template" "long-tail repair-chain signal" "regular review prompt defines long-tail repair-chain signal"
require_string "$regular_template" "Do NOT render the Coverage Ledger as \`-\` / \`*\` bullet findings." "regular review prompt preserves parser-safe coverage ledger formatting"
require_string "$regular_template" "Keep the lane headings exactly as written above" "regular review prompt preserves machine-readable lane headings"
require_string "$regular_template" "1. \`Touched Failure Surfaces\`" "regular review prompt documents output order starting with touched failure surfaces"
require_string "$regular_template" "3. \`Mainline Gaps\`" "regular review prompt keeps lane output after analysis"
require_string "$regular_template" "7. \`Coverage Ledger\`" "regular review prompt ends output order with coverage ledger"
require_string "$regular_template" "- \`- <surface> | why: <reason> | confidence: high|medium|low\`" "regular review prompt specifies parser-friendly touched surface format"
require_string "$regular_template" "- \`- <risk summary> | derived_from: <finding or surface> | axis: <expansion axis> | why: <why likely> | check: <recommended check> | confidence: high|medium|low\`" "regular review prompt specifies parser-friendly sibling risk format"
require_string "$regular_template" "| Surface | Status | Notes |" "regular review prompt specifies parser-friendly coverage ledger table"

require_string "$full_template" "Touched Failure Surfaces" "full alignment prompt requires touched failure surfaces"
require_string "$full_template" "Likely Sibling Risks" "full alignment prompt requires likely sibling risks"
require_string "$full_template" "Coverage Ledger" "full alignment prompt requires coverage ledger"
require_string "$full_template" "Historical Tail-Repair Scan" "full alignment prompt requires historical tail-repair scan"
require_string "$full_template" "git log --oneline --stat -n 20" "full alignment prompt inspects recent git history"
require_string "$full_template" "long-tail repair-chain signal" "full alignment prompt defines long-tail repair-chain signal"
require_string "$full_template" "Do NOT render the Coverage Ledger as \`-\` / \`*\` bullet findings." "full alignment prompt preserves parser-safe coverage ledger formatting"
require_string "$full_template" "Keep the lane headings exactly as written above" "full alignment prompt preserves machine-readable lane headings"
require_string "$full_template" "1. \`Touched Failure Surfaces\`" "full alignment prompt documents output order starting with touched failure surfaces"
require_string "$full_template" "3. \`Mainline Gaps\`" "full alignment prompt keeps lane output after analysis"
require_string "$full_template" "7. \`Coverage Ledger\`" "full alignment prompt ends output order with coverage ledger"
require_string "$full_template" "- \`- <surface> | why: <reason> | confidence: high|medium|low\`" "full alignment prompt specifies parser-friendly touched surface format"
require_string "$full_template" "- \`- <risk summary> | derived_from: <finding or surface> | axis: <expansion axis> | why: <why likely> | check: <recommended check> | confidence: high|medium|low\`" "full alignment prompt specifies parser-friendly sibling risk format"
require_string "$full_template" "| Surface | Status | Notes |" "full alignment prompt specifies parser-friendly coverage ledger table"

echo ""
echo "========================================"
echo "Review Coverage Prompt Tests"
echo "========================================"
echo "Passed: ${TESTS_PASSED}"
echo "Failed: ${TESTS_FAILED}"

if [[ "$TESTS_FAILED" -ne 0 ]]; then
    exit 1
fi
