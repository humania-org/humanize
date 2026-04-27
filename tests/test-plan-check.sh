#!/usr/bin/env bash
#
# Fixture-style tests for the plan-check command pipeline.
#
# Tests deterministic validation, report assembly, and edge cases.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

pass() { echo -e "${GREEN}PASS${NC}: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}FAIL${NC}: $1"; if [[ $# -ge 2 ]]; then echo "  Expected: $2"; fi; if [[ $# -ge 3 ]]; then echo "  Got: $3"; fi; TESTS_FAILED=$((TESTS_FAILED + 1)); }
skip() { echo -e "${YELLOW}SKIP${NC}: $1 - $2"; TESTS_SKIPPED=$((TESTS_SKIPPED + 1)); }

print_test_summary() {
    local title="${1:-Test Summary}"
    echo ""
    echo "========================================"
    echo "$title"
    echo "========================================"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
    if [[ $TESTS_SKIPPED -gt 0 ]]; then
        echo -e "Skipped: ${YELLOW}$TESTS_SKIPPED${NC}"
    fi
    echo ""
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}Some tests failed!${NC}"
        return 1
    fi
}

# Setup
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

source "$PROJECT_ROOT/scripts/lib/plan-check-common.sh"
# plan-check-common.sh sets 'set -e'; restore test-script behavior
set +e
source "$SCRIPT_DIR/test-helpers.sh"

REPORT_DIR="$TEST_DIR/reports"
mkdir -p "$REPORT_DIR"

# Helper: run schema validation and return findings JSON array
collect_schema_findings() {
    local plan_file="$1"
    local template_file="${2:-$PROJECT_ROOT/prompt-template/plan/gen-plan-template.md}"
    local findings
    findings="$(plan_check_validate_schema "$plan_file" "$template_file")"
    if [[ -z "$findings" ]]; then
        echo "[]"
    else
        echo "[$findings]"
    fi
}

# Helper: run schema validation in a fresh strict-mode shell. This catches
# regressions where optional greps abort only under set -euo pipefail.
collect_schema_findings_strict() {
    local plan_file="$1"
    local output_file="$2"
    local template_file="${3:-$PROJECT_ROOT/prompt-template/plan/gen-plan-template.md}"

    bash -euo pipefail -c '
        project_root="$1"
        plan_file="$2"
        template_file="$3"
        output_file="$4"
        source "$project_root/scripts/lib/plan-check-common.sh"
        findings="$(plan_check_validate_schema "$plan_file" "$template_file")"
        if [[ -z "$findings" ]]; then
            printf "[]" > "$output_file"
        else
            printf "[%s]" "$findings" > "$output_file"
        fi
    ' _ "$PROJECT_ROOT" "$plan_file" "$template_file" "$output_file"
}

assert_strict_template_runtime_error() {
    local plan_file="$1"
    local template_file="$2"
    local output_file="$3"
    local pass_label="$4"
    local fail_label="$5"

    local strict_exit=0
    collect_schema_findings_strict "$plan_file" "$output_file" "$template_file" || strict_exit=$?

    local strict_findings
    strict_findings="$(cat "$output_file" 2>/dev/null || echo "[]")"
    local strict_runtime
    strict_runtime="$(count_category "$strict_findings" runtime-error)"
    local strict_schema
    strict_schema="$(count_category "$strict_findings" schema)"

    if [[ "$strict_exit" -eq 0 && "$strict_runtime" -ge 1 && "$strict_schema" -eq 0 ]]; then
        pass "$pass_label"
    else
        fail "$fail_label" "exit 0, 1 runtime-error, 0 schema" "exit=$strict_exit, $strict_runtime runtime-error, $strict_schema schema"
    fi
}

# Helper: count findings by category
count_category() {
    local findings="$1"
    local category="$2"
    printf '%s' "$findings" | python3 -c "import json,sys; d=json.load(sys.stdin); print(sum(1 for f in d if f.get('category')=='$category'))"
}

# Helper: count findings by severity
count_severity() {
    local findings="$1"
    local severity="$2"
    printf '%s' "$findings" | python3 -c "import json,sys; d=json.load(sys.stdin); print(sum(1 for f in d if f.get('severity')=='$severity'))"
}

echo "=== Test: Plan Check Schema Validation ==="
echo ""

# Test 0a: plan_check_resolve_recheck defaults to false
recheck_default="$(plan_check_resolve_recheck '{}')"
if [[ "$recheck_default" == "false" ]]; then
    pass "plan_check_resolve_recheck defaults to false"
else
    fail "plan_check_resolve_recheck default" "false" "$recheck_default"
fi

# Test 0b: plan_check_resolve_recheck accepts true config
recheck_enabled="$(plan_check_resolve_recheck '{"plan_check_recheck": true}')"
if [[ "$recheck_enabled" == "true" ]]; then
    pass "plan_check_resolve_recheck accepts true config"
else
    fail "plan_check_resolve_recheck true config" "true" "$recheck_enabled"
fi

# Test 0c: plan_check_resolve_recheck treats invalid config as false
recheck_invalid="$(plan_check_resolve_recheck '{"plan_check_recheck": "sometimes"}')"
if [[ "$recheck_invalid" == "false" ]]; then
    pass "plan_check_resolve_recheck treats invalid config as false"
else
    fail "plan_check_resolve_recheck invalid config" "false" "$recheck_invalid"
fi

# Test 1: Valid plan produces no blockers
cat > "$TEST_DIR/valid-plan.md" << 'EOF'
# Valid Plan

## Goal Description
A valid test plan.

## Acceptance Criteria

- **AC-1**: First criterion
  - Positive Tests:
    - Test passes
  - Negative Tests:
    - Test fails

## Path Boundaries

### Upper Bound
Complete implementation.

### Lower Bound
Minimum viable implementation.

## Task Breakdown

| Task ID | Description | Target AC | Tag | Depends On |
|---------|-------------|-----------|-----|------------|
| task1 | Do something | AC-1 | coding | - |

## Claude-Codex Deliberation
EOF

echo "Test 1: Valid plan produces no blockers"
findings="$(collect_schema_findings "$TEST_DIR/valid-plan.md")"
blockers="$(count_severity "$findings" blocker)"
if [[ "$blockers" -eq 0 ]]; then
    pass "Valid plan has no blockers"
else
    fail "Valid plan should have no blockers" "0 blockers" "$blockers blockers"
fi

# Test 1b: Task Breakdown is optional for Codex-generated plans
cat > "$TEST_DIR/valid-plan-no-tasks.md" << 'EOF'
# Valid Plan Without Tasks

## Goal Description
A valid test plan without an explicit task list.

## Acceptance Criteria

- **AC-1**: First criterion
  - Positive Tests:
    - Test passes
  - Negative Tests:
    - Test fails

## Path Boundaries

### Upper Bound
Complete implementation.

### Lower Bound
Minimum viable implementation.
EOF

echo "Test 1b: Valid plan without Task Breakdown produces no blockers"
findings="$(collect_schema_findings "$TEST_DIR/valid-plan-no-tasks.md")"
blockers="$(count_severity "$findings" blocker)"
if [[ "$blockers" -eq 0 ]]; then
    pass "Task Breakdown is optional for schema validation"
else
    fail "Plan without Task Breakdown should have no blockers" "0 blockers" "$blockers blockers"
fi

# Test 2: Missing required section produces schema finding
cat > "$TEST_DIR/missing-section.md" << 'EOF'
# Missing Section Plan

## Goal Description
A plan missing Path Boundaries.

## Acceptance Criteria

- **AC-1**: First criterion

## Task Breakdown

| Task ID | Description | Target AC | Tag | Depends On |
|---------|-------------|-----------|-----|------------|
| task1 | Do something | AC-1 | coding | - |
EOF

echo "Test 2: Missing required section produces schema finding"
findings="$(collect_schema_findings "$TEST_DIR/missing-section.md")"
schema_count="$(count_category "$findings" schema)"
if [[ "$schema_count" -ge 1 ]]; then
    pass "Missing section detected"
else
    fail "Missing section should be detected" "at least 1 schema finding" "$schema_count schema findings"
fi

# Test 3: Duplicate canonical AC IDs
cat > "$TEST_DIR/duplicate-ac.md" << 'EOF'
# Duplicate AC Plan

## Goal Description
A plan with duplicate ACs.

## Acceptance Criteria

- **AC-1**: First criterion
- **AC-1**: Duplicate criterion

## Path Boundaries

### Upper Bound
Complete.

### Lower Bound
Minimum.

## Task Breakdown

| Task ID | Description | Target AC | Tag | Depends On |
|---------|-------------|-----------|-----|------------|
| task1 | Do something | AC-1 | coding | - |
EOF

echo "Test 3: Duplicate canonical AC IDs detected"
findings="$(collect_schema_findings "$TEST_DIR/duplicate-ac.md")"
schema_count="$(count_category "$findings" schema)"
if [[ "$schema_count" -ge 1 ]]; then
    pass "Duplicate AC detected"
else
    fail "Duplicate AC should be detected" "at least 1 schema finding" "$schema_count schema findings"
fi

# Test 4: Nonexistent Target AC produces dependency finding
cat > "$TEST_DIR/bad-target-ac.md" << 'EOF'
# Bad Target AC Plan

## Goal Description
A plan with a bad target.

## Acceptance Criteria

- **AC-1**: First criterion

## Path Boundaries

### Upper Bound
Complete.

### Lower Bound
Minimum.

## Task Breakdown

| Task ID | Description | Target AC | Tag | Depends On |
|---------|-------------|-----------|-----|------------|
| task1 | Do something | AC-99 | coding | - |
EOF

echo "Test 4: Nonexistent Target AC detected"
findings="$(collect_schema_findings "$TEST_DIR/bad-target-ac.md")"
dep_count="$(count_category "$findings" dependency)"
if [[ "$dep_count" -ge 1 ]]; then
    pass "Nonexistent Target AC detected"
else
    fail "Nonexistent Target AC should be detected" "at least 1 dependency finding" "$dep_count dependency findings"
fi

# Test 5: Target AC range "AC-1 through AC-7" passes validation
cat > "$TEST_DIR/range-target-ac.md" << 'EOF'
# Range Target AC Plan

## Goal Description
A plan with range target.

## Acceptance Criteria

- **AC-1**: First criterion
- **AC-2**: Second criterion
- **AC-3**: Third criterion
- **AC-4**: Fourth criterion
- **AC-5**: Fifth criterion
- **AC-6**: Sixth criterion
- **AC-7**: Seventh criterion

## Path Boundaries

### Upper Bound
Complete.

### Lower Bound
Minimum.

## Task Breakdown

| Task ID | Description | Target AC | Tag | Depends On |
|---------|-------------|-----------|-----|------------|
| task1 | Do everything | AC-1 through AC-7 | coding | - |
EOF

echo "Test 5: Target AC range 'AC-1 through AC-7' passes"
findings="$(collect_schema_findings "$TEST_DIR/range-target-ac.md")"
dep_count="$(count_category "$findings" dependency)"
if [[ "$dep_count" -eq 0 ]]; then
    pass "Target AC range accepted"
else
    fail "Target AC range should be accepted" "0 dependency findings" "$dep_count dependency findings"
fi

# Test 5b: Existing AC-X.Y sub-criterion target passes validation
cat > "$TEST_DIR/sub-ac-target.md" << 'EOF'
# Sub-AC Target Plan

## Goal Description
A plan with a sub-criterion target.

## Acceptance Criteria

- **AC-1**: First criterion
  - AC-1.1: Sub-criterion

## Path Boundaries

### Upper Bound
Complete.

### Lower Bound
Minimum.

## Task Breakdown

| Task ID | Description | Target AC | Tag | Depends On |
|---------|-------------|-----------|-----|------------|
| task1 | Do the sub-criterion work | AC-1.1 | coding | - |
EOF

echo "Test 5b: Existing AC-X.Y sub-criterion target passes"
findings="$(collect_schema_findings "$TEST_DIR/sub-ac-target.md")"
dep_count="$(count_category "$findings" dependency)"
if [[ "$dep_count" -eq 0 ]]; then
    pass "Existing AC-X.Y sub-criterion target accepted"
else
    fail "Existing AC-X.Y sub-criterion target should be accepted" "0 dependency findings" "$dep_count dependency findings"
fi

# Test 5c: Nonexistent AC-X.Y sub-criterion target is detected
cat > "$TEST_DIR/bad-sub-ac-target.md" << 'EOF'
# Bad Sub-AC Target Plan

## Goal Description
A plan with a missing sub-criterion target.

## Acceptance Criteria

- **AC-1**: First criterion
  - AC-1.1: Sub-criterion

## Path Boundaries

### Upper Bound
Complete.

### Lower Bound
Minimum.

## Task Breakdown

| Task ID | Description | Target AC | Tag | Depends On |
|---------|-------------|-----------|-----|------------|
| task1 | Do the missing sub-criterion work | AC-1.9 | coding | - |
EOF

echo "Test 5c: Nonexistent AC-X.Y sub-criterion target detected"
findings="$(collect_schema_findings "$TEST_DIR/bad-sub-ac-target.md")"
dep_count="$(count_category "$findings" dependency)"
if [[ "$dep_count" -ge 1 ]]; then
    pass "Nonexistent AC-X.Y sub-criterion target detected"
else
    fail "Nonexistent AC-X.Y sub-criterion target should be detected" "at least 1 dependency finding" "$dep_count dependency findings"
fi

# Test 5d: Bold AC mention outside Acceptance Criteria does not define a target
cat > "$TEST_DIR/bold-mention-target-ac.md" << 'EOF'
# Bold Mention Target Plan

## Goal Description
A plan whose task text mentions **AC-99** without defining it.

## Acceptance Criteria

- **AC-1**: First criterion

## Path Boundaries

### Upper Bound
Complete.

### Lower Bound
Minimum.

## Task Breakdown

| Task ID | Description | Target AC | Tag | Depends On |
|---------|-------------|-----------|-----|------------|
| task1 | Preserve the literal **AC-99** note in docs | AC-99 | coding | - |
EOF

echo "Test 5d: Bold non-definition AC mention does not satisfy target validation"
findings="$(collect_schema_findings "$TEST_DIR/bold-mention-target-ac.md")"
dep_count="$(count_category "$findings" dependency)"
if [[ "$dep_count" -ge 1 ]]; then
    pass "Bold non-definition AC mention ignored"
else
    fail "Bold non-definition AC mention should not define Target AC" "at least 1 dependency finding" "$dep_count dependency findings"
fi

# Test 5e: Empty or malformed Target AC is detected
cat > "$TEST_DIR/unparsable-target-ac.md" << 'EOF'
# Unparsable Target AC Plan

## Goal Description
A plan whose task has no valid Target AC token.

## Acceptance Criteria

- **AC-1**: First criterion

## Path Boundaries

### Upper Bound
Complete.

### Lower Bound
Minimum.

## Task Breakdown

| Task ID | Description | Target AC | Tag | Depends On |
|---------|-------------|-----------|-----|------------|
| task1 | Do something | - | coding | - |
EOF

echo "Test 5e: Unparsable Target AC detected"
findings="$(collect_schema_findings "$TEST_DIR/unparsable-target-ac.md")"
dep_count="$(count_category "$findings" dependency)"
if [[ "$dep_count" -ge 1 ]]; then
    pass "Unparsable Target AC detected"
else
    fail "Unparsable Target AC should be detected" "at least 1 dependency finding" "$dep_count dependency findings"
fi

# Test 6: Invalid routing tag produces schema finding
cat > "$TEST_DIR/bad-tag.md" << 'EOF'
# Bad Tag Plan

## Goal Description
A plan with a bad tag.

## Acceptance Criteria

- **AC-1**: First criterion

## Path Boundaries

### Upper Bound
Complete.

### Lower Bound
Minimum.

## Task Breakdown

| Task ID | Description | Target AC | Tag | Depends On |
|---------|-------------|-----------|-----|------------|
| task1 | Do something | AC-1 | review | - |
EOF

echo "Test 6: Invalid routing tag detected"
findings="$(collect_schema_findings "$TEST_DIR/bad-tag.md")"
schema_count="$(count_category "$findings" schema)"
if [[ "$schema_count" -ge 1 ]]; then
    pass "Invalid routing tag detected"
else
    fail "Invalid routing tag should be detected" "at least 1 schema finding" "$schema_count schema findings"
fi

# Test 6b: Spaced/aligned Markdown separators still enable task validation
cat > "$TEST_DIR/spaced-separator-task-table.md" << 'EOF'
# Spaced Separator Task Table Plan

## Goal Description
A plan with a common spaced and aligned Markdown table separator.

## Acceptance Criteria

- **AC-1**: First criterion

## Path Boundaries

### Upper Bound
Complete.

### Lower Bound
Minimum.

## Task Breakdown

| Task ID | Description | Target AC | Tag | Depends On |
| :--- | :--- | :---: | ---: | --- |
| task1 | Do something | AC-99 | review | missing-task |
EOF

echo "Test 6b: Spaced Markdown table separator preserves task validation"
findings="$(collect_schema_findings "$TEST_DIR/spaced-separator-task-table.md")"
schema_count="$(count_category "$findings" schema)"
dep_count="$(count_category "$findings" dependency)"
if [[ "$schema_count" -ge 1 && "$dep_count" -ge 1 ]]; then
    pass "Spaced Markdown table separator preserves task validation"
else
    fail "Spaced Markdown table separator should preserve task validation" "schema>=1 and dependency>=1" "schema=$schema_count, dependency=$dep_count"
fi

# Test 7: Circular dependency detected
cat > "$TEST_DIR/circular-deps.md" << 'EOF'
# Circular Dependency Plan

## Goal Description
A plan with circular deps.

## Acceptance Criteria

- **AC-1**: First criterion

## Path Boundaries

### Upper Bound
Complete.

### Lower Bound
Minimum.

## Task Breakdown

| Task ID | Description | Target AC | Tag | Depends On |
|---------|-------------|-----------|-----|------------|
| task1 | Do something | AC-1 | coding | task2 |
| task2 | Do another thing | AC-1 | coding | task1 |
EOF

echo "Test 7: Circular dependency detected"
findings="$(collect_schema_findings "$TEST_DIR/circular-deps.md")"
dep_count="$(count_category "$findings" dependency)"
if [[ "$dep_count" -ge 1 ]]; then
    pass "Circular dependency detected"
else
    fail "Circular dependency should be detected" "at least 1 dependency finding" "$dep_count dependency findings"
fi

# Test 8: Malformed template produces runtime-error info finding and skips schema checks
cat > "$TEST_DIR/malformed-template.md" << 'EOF'
not a plan schema
EOF

cat > "$TEST_DIR/malformed-template-plan.md" << 'EOF'
# Plan

## Goal Description
A plan.

## Acceptance Criteria

- **AC-1**: First criterion

## Path Boundaries

### Upper Bound
Complete.

### Lower Bound
Minimum.

## Task Breakdown

| Task ID | Description | Target AC | Tag | Depends On |
|---------|-------------|-----------|-----|------------|
| task1 | Do something | AC-1 | coding | - |
EOF

echo "Test 8: Malformed template produces runtime-error info finding"
findings="$(collect_schema_findings "$TEST_DIR/malformed-template-plan.md" "$TEST_DIR/malformed-template.md")"
runtime_count="$(count_category "$findings" runtime-error)"
schema_count="$(count_category "$findings" schema)"
if [[ "$runtime_count" -ge 1 && "$schema_count" -eq 0 ]]; then
    pass "Malformed template produces runtime-error and skips schema checks"
else
    fail "Malformed template handling" "1 runtime-error, 0 schema" "$runtime_count runtime-error, $schema_count schema"
fi

assert_strict_template_runtime_error \
    "$TEST_DIR/malformed-template-plan.md" \
    "$TEST_DIR/malformed-template.md" \
    "$TEST_DIR/malformed-template-strict.json" \
    "Malformed template returns runtime-error under strict shell" \
    "Malformed template strict handling"

# Test 9: plan-check.sh rejects malformed findings input
echo "Test 9: plan-check.sh rejects malformed JSON input"
mkdir -p "$TEST_DIR/report9"
echo '{not-json' > "$TEST_DIR/bad-findings.json"
bash "$PROJECT_ROOT/scripts/plan-check.sh" \
    --plan "$TEST_DIR/valid-plan.md" \
    --report-dir "$TEST_DIR/report9" \
    --findings-file "$TEST_DIR/bad-findings.json" > /dev/null 2>&1
exit_code=$?
category="$(python3 -c "import json; d=json.load(open('$TEST_DIR/report9/findings.json')); print(d['findings'][0]['category'])" 2>/dev/null || echo 'ERROR')"
if [[ "$exit_code" -eq 0 && "$category" == "runtime-error" ]]; then
    pass "Malformed findings produce runtime-error finding"
else
    fail "Malformed findings handling" "exit 0 with runtime-error category" "exit $exit_code, category=$category"
fi

# Test 10: plan-check.sh rejects non-array findings input
echo "Test 10: plan-check.sh rejects non-array JSON input"
mkdir -p "$TEST_DIR/report10"
echo '{}' > "$TEST_DIR/object-findings.json"
bash "$PROJECT_ROOT/scripts/plan-check.sh" \
    --plan "$TEST_DIR/valid-plan.md" \
    --report-dir "$TEST_DIR/report10" \
    --findings-file "$TEST_DIR/object-findings.json" > /dev/null 2>&1
exit_code=$?
category="$(python3 -c "import json; d=json.load(open('$TEST_DIR/report10/findings.json')); print(d['findings'][0]['category'])" 2>/dev/null || echo 'ERROR')"
if [[ "$exit_code" -eq 0 && "$category" == "runtime-error" ]]; then
    pass "Non-array findings produce runtime-error finding"
else
    fail "Non-array findings handling" "exit 0 with runtime-error category" "exit $exit_code, category=$category"
fi

# Test 11: Appendix drift produces info finding
cat > "$TEST_DIR/appendix-drift.md" << 'EOF'
# Appendix Drift Plan

## Goal Description
A plan with appendix.

## Acceptance Criteria

- **AC-1**: First criterion

## Path Boundaries

### Upper Bound
Complete.

### Lower Bound
Minimum.

## Task Breakdown

| Task ID | Description | Target AC | Tag | Depends On |
|---------|-------------|-----------|-----|------------|
| task1 | Do something | AC-1 | coding | - |

--- Original Design Draft Start ---

Some original draft content.

--- Original Design Draft End ---
EOF

echo "Test 11: Appendix drift produces info finding"
findings="$(collect_schema_findings "$TEST_DIR/appendix-drift.md")"
drift_count="$(count_category "$findings" appendix-drift)"
if [[ "$drift_count" -ge 1 ]]; then
    pass "Appendix drift detected"
else
    fail "Appendix drift should be detected" "at least 1 appendix-drift finding" "$drift_count appendix-drift findings"
fi

# Test 12: Ambiguity ID post-processing produces stable hash IDs
echo "Test 12: Ambiguity ID post-processing"
cat > "$TEST_DIR/ambiguity-findings.json" << 'EOF'
[
  {
    "id": "A-001",
    "severity": "blocker",
    "category": "ambiguity",
    "source_checker": "plan-ambiguity-checker",
    "location": {"section": "Task Breakdown", "fragment": "use caching where appropriate"},
    "evidence": "ambiguous caching instruction",
    "explanation": "no invalidation strategy defined",
    "suggested_resolution": "define cache invalidation",
    "affected_acs": [],
    "affected_tasks": []
  }
]
EOF
processed="$(python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)))" < <(cat "$TEST_DIR/ambiguity-findings.json" | plan_check_postprocess_ambiguity_ids))"
id="$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'])" <<< "$processed")"
if [[ "$id" == A-* && "$id" != "A-001" ]]; then
    pass "Ambiguity ID is stable hash"
else
    fail "Ambiguity ID post-processing" "stable hash ID starting with A-" "$id"
fi

# Test 12b: Malformed ambiguity findings are passed through unchanged
echo "Test 12b: Ambiguity post-processing preserves malformed input"
malformed_findings='[{"category":"ambiguity",'
processed_malformed="$(printf '%s' "$malformed_findings" | plan_check_postprocess_ambiguity_ids)"
if [[ "$processed_malformed" == "$malformed_findings" ]]; then
    pass "Ambiguity post-processing preserves malformed input"
else
    fail "Ambiguity post-processing malformed input fallback" "$malformed_findings" "$processed_malformed"
fi

# Test 13: plan-check.sh produces valid findings.json with valid input
echo "Test 13: plan-check.sh produces valid findings.json"
mkdir -p "$TEST_DIR/report13"
bash "$PROJECT_ROOT/scripts/plan-check.sh" \
    --plan "$TEST_DIR/valid-plan.md" \
    --report-dir "$TEST_DIR/report13" \
    --findings-file "$TEST_DIR/ambiguity-findings.json" > /dev/null 2>&1
if python3 -c "import json; json.load(open('$TEST_DIR/report13/findings.json'))" 2>/dev/null; then
    pass "Valid findings produce parseable findings.json"
else
    fail "Valid findings should produce parseable findings.json"
fi

# Test 13b: plan-check.sh escapes JSON metacharacters in plan path metadata
echo "Test 13b: plan-check.sh escapes JSON metacharacters in plan path metadata"
QUOTED_PLAN="$TEST_DIR/quoted \"plan.md"
cp "$TEST_DIR/valid-plan.md" "$QUOTED_PLAN"
mkdir -p "$TEST_DIR/report13b"
bash "$PROJECT_ROOT/scripts/plan-check.sh" \
    --plan "$QUOTED_PLAN" \
    --report-dir "$TEST_DIR/report13b" \
    --findings-file "$TEST_DIR/ambiguity-findings.json" > /dev/null 2>&1
quoted_exit=$?
quoted_path="$(FINDINGS_JSON="$TEST_DIR/report13b/findings.json" python3 -c 'import json, os; d=json.load(open(os.environ["FINDINGS_JSON"])); print(d["check_run"]["plan_path"])' 2>/dev/null)"
if [[ "$quoted_exit" -eq 0 && "$quoted_path" == "$QUOTED_PLAN" && -f "$TEST_DIR/report13b/report.md" ]]; then
    pass "Plan path with JSON metacharacters produces parseable findings.json and report.md"
else
    fail "Plan path with JSON metacharacters should remain valid JSON" "exit 0, matching plan_path, report.md exists" "exit=$quoted_exit, plan_path=$quoted_path, report_exists=$([[ -f "$TEST_DIR/report13b/report.md" ]] && echo yes || echo no)"
fi

# Test 14: Resolved contradiction produces status=pass
echo "Test 14: Resolved contradiction produces status=pass"
findings14='[{"id":"F-001","severity":"blocker","category":"contradiction","source_checker":"plan-consistency-checker","location":{"section":"Task Breakdown","fragment":""},"evidence":"conflict","explanation":"two defs","suggested_resolution":"pick one","affected_acs":[],"affected_tasks":[]}]'
resolutions14='[{"finding_id":"F-001","resolution_type":"contradiction_resolution","resolution":"accepted first definition"}]'
result14="$(plan_check_build_resolved_json "$TEST_DIR/valid-plan.md" "abc" "test" "{}" 0 "$findings14" "$resolutions14")"
status14="$(echo "$result14" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["summary"]["status"])')"
unresolved14="$(echo "$result14" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["summary"]["unresolved_blockers"])')"
if [[ \"$status14\" == \"pass\" && \"$unresolved14\" == \"0\" ]]; then
    pass "Resolved contradiction produces pass"
else
    fail "Resolved contradiction should produce pass" "status=pass, unresolved_blockers=0" "status=$status14, unresolved_blockers=$unresolved14"
fi

# Test 15: Answered ambiguity produces status=pass
echo "Test 15: Answered ambiguity produces status=pass"
findings15='[{"id":"A-abc123","severity":"blocker","category":"ambiguity","source_checker":"plan-ambiguity-checker","location":{"section":"Task Breakdown","fragment":"use caching"},"evidence":"vague","explanation":"no strategy","suggested_resolution":"define strategy","affected_acs":[],"affected_tasks":[],"ambiguity_details":{"competing_interpretations":["A","B"],"execution_drift_risk":"high","clarification_question":"what cache?"}}]'
resolutions15='[{"finding_id":"A-abc123","resolution_type":"ambiguity_answer","answer":"use LRU cache with 5-minute TTL"}]'
result15="$(plan_check_build_resolved_json "$TEST_DIR/valid-plan.md" "abc" "test" "{}" 0 "$findings15" "$resolutions15")"
status15="$(echo "$result15" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["summary"]["status"])')"
unresolved15="$(echo "$result15" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["summary"]["unresolved_blockers"])')"
if [[ \"$status15\" == \"pass\" && \"$unresolved15\" == \"0\" ]]; then
    pass "Answered ambiguity produces pass"
else
    fail "Answered ambiguity should produce pass" "status=pass, unresolved_blockers=0" "status=$status15, unresolved_blockers=$unresolved15"
fi

# Test 16: Skipped ambiguity produces status=fail
echo "Test 16: Skipped ambiguity produces status=fail"
resolutions16='[{"finding_id":"A-abc123","resolution_type":"ambiguity_skipped"}]'
result16="$(plan_check_build_resolved_json "$TEST_DIR/valid-plan.md" "abc" "test" "{}" 0 "$findings15" "$resolutions16")"
status16="$(echo "$result16" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["summary"]["status"])')"
unresolved16="$(echo "$result16" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["summary"]["unresolved_blockers"])')"
if [[ \"$status16\" == \"fail\" && \"$unresolved16\" == \"1\" ]]; then
    pass "Skipped ambiguity produces fail"
else
    fail "Skipped ambiguity should produce fail" "status=fail, unresolved_blockers=1" "status=$status16, unresolved_blockers=$unresolved16"
fi

# Test 17: Rewrite backup and atomic write
echo "Test 17: Rewrite backup and atomic write"
mkdir -p "$TEST_DIR/rewrite-report/backup"
cp "$TEST_DIR/valid-plan.md" "$TEST_DIR/original-plan.md"
backup_path="$(plan_check_backup_plan "$TEST_DIR/original-plan.md" "$TEST_DIR/rewrite-report")"
if [[ -f "$backup_path" ]]; then
    pass "Backup created at $backup_path"
else
    fail "Backup should be created" "backup file exists" "missing"
fi
new_content="# Modified Plan\n\n## Goal Description\nModified."
plan_check_atomic_write "$TEST_DIR/original-plan.md" "$new_content"
if grep -q "Modified" "$TEST_DIR/original-plan.md"; then
    pass "Atomic write succeeded"
else
    fail "Atomic write should modify the file" "file contains Modified" "missing"
fi
mode17="$(stat -c '%a' "$TEST_DIR/original-plan.md" 2>/dev/null || stat -f '%Lp' "$TEST_DIR/original-plan.md" 2>/dev/null || true)"
if [[ "$mode17" == "644" ]]; then
    pass "Atomic write preserves file mode"
else
    fail "Atomic write should preserve file mode" "644" "$mode17"
fi

# Test 18: plan-check.sh respects valid ambiguity with full schema
echo "Test 18: plan-check.sh accepts valid ambiguity with full schema"
mkdir -p "$TEST_DIR/report18"
cat > "$TEST_DIR/full-ambiguity.json" << 'EOF'
[
  {
    "id": "A-abc123",
    "severity": "blocker",
    "category": "ambiguity",
    "source_checker": "plan-ambiguity-checker",
    "location": {"section": "Task Breakdown", "fragment": "use caching"},
    "evidence": "vague",
    "explanation": "no strategy",
    "suggested_resolution": "define strategy",
    "affected_acs": [],
    "affected_tasks": [],
    "ambiguity_details": {
      "competing_interpretations": ["A", "B"],
      "execution_drift_risk": "high",
      "clarification_question": "what cache?"
    }
  }
]
EOF
bash "$PROJECT_ROOT/scripts/plan-check.sh" \
    --plan "$TEST_DIR/valid-plan.md" \
    --report-dir "$TEST_DIR/report18" \
    --findings-file "$TEST_DIR/full-ambiguity.json" > /dev/null 2>&1
if python3 -c "import json; d=json.load(open('$TEST_DIR/report18/findings.json')); print(d['findings'][0]['category'])" 2>/dev/null | grep -q "ambiguity"; then
    pass "Valid ambiguity with full schema accepted"
else
    fail "Valid ambiguity with full schema should be accepted"
fi

# Test 19: Partial template may omit optional Task Breakdown heading
echo "Test 19: Partial template missing optional Task Breakdown validates"
cat > "$TEST_DIR/partial-template.md" << 'EOF'
# Partial Template

## Goal Description
Test.

## Acceptance Criteria
- AC-1: test

## Path Boundaries

### Upper Bound
Complete.
EOF
findings19="$(collect_schema_findings "$TEST_DIR/valid-plan.md" "$TEST_DIR/partial-template.md")"
runtime19="$(count_category "$findings19" runtime-error)"
schema19="$(count_category "$findings19" schema)"
blockers19="$(count_severity "$findings19" blocker)"
if [[ "$runtime19" -eq 0 && "$schema19" -eq 0 && "$blockers19" -eq 0 ]]; then
    pass "Partial template without optional Task Breakdown validates"
else
    fail "Partial template without optional Task Breakdown" "0 runtime-error, 0 schema, 0 blockers" "$runtime19 runtime-error, $schema19 schema, $blockers19 blockers"
fi

# Test 19b: Partial template missing a required core heading triggers runtime-error
echo "Test 19b: Partial template missing core heading triggers runtime-error"
cat > "$TEST_DIR/partial-template-missing-core.md" << 'EOF'
# Partial Template

## Goal Description
Test.

## Acceptance Criteria
- AC-1: test
EOF

findings19b="$(collect_schema_findings "$TEST_DIR/valid-plan.md" "$TEST_DIR/partial-template-missing-core.md")"
runtime19b="$(count_category "$findings19b" runtime-error)"
schema19b="$(count_category "$findings19b" schema)"
if [[ "$runtime19b" -ge 1 && "$schema19b" -eq 0 ]]; then
    pass "Partial template missing core heading triggers runtime-error and skips schema checks"
else
    fail "Partial template missing core heading" "1 runtime-error, 0 schema" "$runtime19b runtime-error, $schema19b schema"
fi

assert_strict_template_runtime_error \
    "$TEST_DIR/valid-plan.md" \
    "$TEST_DIR/partial-template-missing-core.md" \
    "$TEST_DIR/partial-template-missing-core-strict.json" \
    "Partial template missing core heading returns runtime-error under strict shell" \
    "Partial template missing core heading strict handling"

# Test 20: plan-check.sh rejects missing affected_acs
echo "Test 20: plan-check.sh rejects missing affected_acs"
mkdir -p "$TEST_DIR/report20"
cat > "$TEST_DIR/missing-affected.json" << 'EOF'
[{"id":"F-001","severity":"blocker","category":"schema","source_checker":"plan-schema-validator","location":{"section":"Test","fragment":""},"evidence":"test","explanation":"test","suggested_resolution":"fix"}]
EOF
bash "$PROJECT_ROOT/scripts/plan-check.sh" \
    --plan "$TEST_DIR/valid-plan.md" \
    --report-dir "$TEST_DIR/report20" \
    --findings-file "$TEST_DIR/missing-affected.json" > /dev/null 2>&1
cat20="$(python3 -c "import json; d=json.load(open('$TEST_DIR/report20/findings.json')); print(d['findings'][0]['category'])" 2>/dev/null || echo 'ERROR')"
if [[ "$cat20" == "runtime-error" ]]; then
    pass "Missing affected_acs produces runtime-error"
else
    fail "Missing affected_acs should produce runtime-error" "runtime-error" "$cat20"
fi

# Test 21: plan-check.sh rejects missing ambiguity_details
echo "Test 21: plan-check.sh rejects missing ambiguity_details"
mkdir -p "$TEST_DIR/report21"
cat > "$TEST_DIR/missing-details.json" << 'EOF'
[{"id":"A-abc123","severity":"blocker","category":"ambiguity","source_checker":"plan-ambiguity-checker","location":{"section":"Test","fragment":""},"evidence":"test","explanation":"test","suggested_resolution":"fix","affected_acs":[],"affected_tasks":[]}]
EOF
bash "$PROJECT_ROOT/scripts/plan-check.sh" \
    --plan "$TEST_DIR/valid-plan.md" \
    --report-dir "$TEST_DIR/report21" \
    --findings-file "$TEST_DIR/missing-details.json" > /dev/null 2>&1
cat21="$(python3 -c "import json; d=json.load(open('$TEST_DIR/report21/findings.json')); print(d['findings'][0]['category'])" 2>/dev/null || echo 'ERROR')"
if [[ "$cat21" == "runtime-error" ]]; then
    pass "Missing ambiguity_details produces runtime-error"
else
    fail "Missing ambiguity_details should produce runtime-error" "runtime-error" "$cat21"
fi

# Test 22: Schema blocker + contradiction_resolution still fails (category-aware)
echo "Test 22: Schema blocker cannot be cleared by contradiction resolution"
findings22='[{"id":"F-001","severity":"blocker","category":"schema","source_checker":"plan-schema-validator","location":{"section":"Task Breakdown","fragment":""},"evidence":"missing section","explanation":"required","suggested_resolution":"add it","affected_acs":[],"affected_tasks":[]}]'
resolutions22='[{"finding_id":"F-001","resolution_type":"contradiction_resolution","resolution":"fixed"}]'
result22="$(plan_check_build_resolved_json "$TEST_DIR/valid-plan.md" "abc" "test" "{}" 0 "$findings22" "$resolutions22")"
status22="$(echo "$result22" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["summary"]["status"])')"
unresolved22="$(echo "$result22" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["summary"]["unresolved_blockers"])')"
if [[ "$status22" == "fail" && "$unresolved22" == "1" ]]; then
    pass "Schema blocker remains unresolved with contradiction resolution"
else
    fail "Schema blocker should remain unresolved" "status=fail, unresolved=1" "status=$status22, unresolved=$unresolved22"
fi

# Test 23: plan-check.sh rejects invalid scalar type for id
echo "Test 23: plan-check.sh rejects invalid scalar type for id"
mkdir -p "$TEST_DIR/report23"
cat > "$TEST_DIR/invalid-id.json" << 'EOF'
[{"id":[],"severity":"blocker","category":"schema","source_checker":"plan-schema-validator","location":{"section":"Test","fragment":""},"evidence":"test","explanation":"test","suggested_resolution":"fix","affected_acs":[],"affected_tasks":[]}]
EOF
bash "$PROJECT_ROOT/scripts/plan-check.sh" \
    --plan "$TEST_DIR/valid-plan.md" \
    --report-dir "$TEST_DIR/report23" \
    --findings-file "$TEST_DIR/invalid-id.json" > /dev/null 2>&1
cat23="$(python3 -c "import json; d=json.load(open('$TEST_DIR/report23/findings.json')); print(d['findings'][0]['category'])" 2>/dev/null || echo 'ERROR')"
if [[ "$cat23" == "runtime-error" ]]; then
    pass "Invalid scalar type for id produces runtime-error"
else
    fail "Invalid scalar type for id should produce runtime-error" "runtime-error" "$cat23"
fi

# Test 24: plan-check.sh rejects unknown source_checker
echo "Test 24: plan-check.sh rejects unknown source_checker"
mkdir -p "$TEST_DIR/report24"
cat > "$TEST_DIR/invalid-checker.json" << 'EOF'
[{"id":"F-001","severity":"blocker","category":"schema","source_checker":"unknown-checker","location":{"section":"Test","fragment":""},"evidence":"test","explanation":"test","suggested_resolution":"fix","affected_acs":[],"affected_tasks":[]}]
EOF
bash "$PROJECT_ROOT/scripts/plan-check.sh" \
    --plan "$TEST_DIR/valid-plan.md" \
    --report-dir "$TEST_DIR/report24" \
    --findings-file "$TEST_DIR/invalid-checker.json" > /dev/null 2>&1
cat24="$(python3 -c "import json; d=json.load(open('$TEST_DIR/report24/findings.json')); print(d['findings'][0]['category'])" 2>/dev/null || echo 'ERROR')"
if [[ "$cat24" == "runtime-error" ]]; then
    pass "Unknown source_checker produces runtime-error"
else
    fail "Unknown source_checker should produce runtime-error" "runtime-error" "$cat24"
fi

# Test 25: plan-check.sh rejects ambiguity with only 1 competing interpretation
echo "Test 25: plan-check.sh rejects ambiguity with only 1 interpretation"
mkdir -p "$TEST_DIR/report25"
cat > "$TEST_DIR/invalid-interpretations.json" << 'EOF'
[{"id":"A-abc123","severity":"blocker","category":"ambiguity","source_checker":"plan-ambiguity-checker","location":{"section":"Test","fragment":""},"evidence":"test","explanation":"test","suggested_resolution":"fix","affected_acs":[],"affected_tasks":[],"ambiguity_details":{"competing_interpretations":["A"],"execution_drift_risk":"high","clarification_question":"what?"}}]
EOF
bash "$PROJECT_ROOT/scripts/plan-check.sh" \
    --plan "$TEST_DIR/valid-plan.md" \
    --report-dir "$TEST_DIR/report25" \
    --findings-file "$TEST_DIR/invalid-interpretations.json" > /dev/null 2>&1
cat25="$(python3 -c "import json; d=json.load(open('$TEST_DIR/report25/findings.json')); print(d['findings'][0]['category'])" 2>/dev/null || echo 'ERROR')"
if [[ "$cat25" == "runtime-error" ]]; then
    pass "Only 1 interpretation produces runtime-error"
else
    fail "Only 1 interpretation should produce runtime-error" "runtime-error" "$cat25"
fi

# Test 26: plan-check.sh rejects empty ambiguity clarification question
echo "Test 26: plan-check.sh rejects empty ambiguity clarification question"
mkdir -p "$TEST_DIR/report26"
cat > "$TEST_DIR/invalid-question.json" << 'EOF'
[{"id":"A-abc123","severity":"blocker","category":"ambiguity","source_checker":"plan-ambiguity-checker","location":{"section":"Test","fragment":""},"evidence":"test","explanation":"test","suggested_resolution":"fix","affected_acs":[],"affected_tasks":[],"ambiguity_details":{"competing_interpretations":["A","B"],"execution_drift_risk":"high","clarification_question":""}}]
EOF
bash "$PROJECT_ROOT/scripts/plan-check.sh" \
    --plan "$TEST_DIR/valid-plan.md" \
    --report-dir "$TEST_DIR/report26" \
    --findings-file "$TEST_DIR/invalid-question.json" > /dev/null 2>&1
cat26="$(python3 -c "import json; d=json.load(open('$TEST_DIR/report26/findings.json')); print(d['findings'][0]['category'])" 2>/dev/null || echo 'ERROR')"
if [[ "$cat26" == "runtime-error" ]]; then
    pass "Empty clarification question produces runtime-error"
else
    fail "Empty clarification question should produce runtime-error" "runtime-error" "$cat26"
fi

# Test 27: Diff preview can be generated before rewrite
echo "Test 27: Diff preview can be generated before rewrite"
cp "$TEST_DIR/valid-plan.md" "$TEST_DIR/diff-plan.md"
new_content="# Modified Plan\n\n## Goal Description\nModified.\n\n## Acceptance Criteria\n\n- **AC-1**: First criterion\n\n## Path Boundaries\n\n### Upper Bound\nComplete.\n\n### Lower Bound\nMinimum.\n\n## Task Breakdown\n\n| Task ID | Description | Target AC | Tag | Depends On |\n|---------|-------------|-----------|-----|------------|\n| task1 | Do something | AC-1 | coding | - |"
diff_output="$(diff -u "$TEST_DIR/diff-plan.md" <(echo -e "$new_content") 2>/dev/null || true)"
if echo "$diff_output" | grep -q "Modified"; then
    pass "Diff preview shows changes"
else
    fail "Diff preview should show changes" "diff contains Modified" "missing"
fi

# Test 28: plan-check.sh accepts valid contradiction with full schema
echo "Test 28: plan-check.sh accepts valid contradiction with full schema"
mkdir -p "$TEST_DIR/report28"
cat > "$TEST_DIR/full-contradiction.json" << 'EOF'
[{"id":"F-001","severity":"blocker","category":"contradiction","source_checker":"plan-consistency-checker","location":{"section":"Task Breakdown","fragment":""},"evidence":"conflict","explanation":"two defs","suggested_resolution":"pick one","affected_acs":[],"affected_tasks":[]}]
EOF
bash "$PROJECT_ROOT/scripts/plan-check.sh" \
    --plan "$TEST_DIR/valid-plan.md" \
    --report-dir "$TEST_DIR/report28" \
    --findings-file "$TEST_DIR/full-contradiction.json" > /dev/null 2>&1
if python3 -c "import json; d=json.load(open('$TEST_DIR/report28/findings.json')); print(d['findings'][0]['category'])" 2>/dev/null | grep -q "contradiction"; then
    pass "Valid contradiction with full schema accepted"
else
    fail "Valid contradiction with full schema should be accepted"
fi

# Test 29: Dependency blocker + contradiction_resolution still fails
echo "Test 29: Dependency blocker cannot be cleared by contradiction resolution"
findings29='[{"id":"F-001","severity":"blocker","category":"dependency","source_checker":"plan-schema-validator","location":{"section":"Task Breakdown","fragment":"task1"},"evidence":"circular","explanation":"cycle","suggested_resolution":"break it","affected_acs":[],"affected_tasks":["task1"]}]'
resolutions29='[{"finding_id":"F-001","resolution_type":"contradiction_resolution","resolution":"fixed"}]'
result29="$(plan_check_build_resolved_json "$TEST_DIR/valid-plan.md" "abc" "test" "{}" 0 "$findings29" "$resolutions29")"
status29="$(echo "$result29" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["summary"]["status"])')"
unresolved29="$(echo "$result29" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["summary"]["unresolved_blockers"])')"
if [[ "$status29" == "fail" && "$unresolved29" == "1" ]]; then
    pass "Dependency blocker remains unresolved with contradiction resolution"
else
    fail "Dependency blocker should remain unresolved" "status=fail, unresolved=1" "status=$status29, unresolved=$unresolved29"
fi

# Test 30: Ambiguity + wrong resolution type remains unresolved
echo "Test 30: Ambiguity + wrong resolution type remains unresolved"
findings30='[{"id":"A-abc123","severity":"blocker","category":"ambiguity","source_checker":"plan-ambiguity-checker","location":{"section":"Task Breakdown","fragment":"use caching"},"evidence":"vague","explanation":"no strategy","suggested_resolution":"define strategy","affected_acs":[],"affected_tasks":[],"ambiguity_details":{"competing_interpretations":["A","B"],"execution_drift_risk":"high","clarification_question":"what cache?"}}]'
resolutions30='[{"finding_id":"A-abc123","resolution_type":"contradiction_resolution","resolution":"wrong type"}]'
result30="$(plan_check_build_resolved_json "$TEST_DIR/valid-plan.md" "abc" "test" "{}" 0 "$findings30" "$resolutions30")"
status30="$(echo "$result30" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["summary"]["status"])')"
unresolved30="$(echo "$result30" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["summary"]["unresolved_blockers"])')"
if [[ "$status30" == "fail" && "$unresolved30" == "1" ]]; then
    pass "Ambiguity with wrong resolution type remains unresolved"
else
    fail "Ambiguity with wrong resolution type should remain unresolved" "status=fail, unresolved=1" "status=$status30, unresolved=$unresolved30"
fi

# Test 31: plan-check.sh rejects array severity
mkdir -p "$TEST_DIR/report31"
cat > "$TEST_DIR/array-severity.json" << 'EOF'
[{"id":"F-001","severity":[],"category":"schema","source_checker":"plan-schema-validator","location":{"section":"Test","fragment":""},"evidence":"test","explanation":"test","suggested_resolution":"fix","affected_acs":[],"affected_tasks":[]}]
EOF
bash "$PROJECT_ROOT/scripts/plan-check.sh" \
    --plan "$TEST_DIR/valid-plan.md" \
    --report-dir "$TEST_DIR/report31" \
    --findings-file "$TEST_DIR/array-severity.json" > /dev/null 2>&1
cat31="$(python3 -c "import json; d=json.load(open('$TEST_DIR/report31/findings.json')); print(d['findings'][0]['category'])" 2>/dev/null || echo 'ERROR')"
if [[ "$cat31" == "runtime-error" ]]; then
    pass "Array severity produces runtime-error"
else
    fail "Array severity should produce runtime-error" "runtime-error" "$cat31"
fi

# Test 32: plan-check.sh rejects object category
echo "Test 32: plan-check.sh rejects object category"
mkdir -p "$TEST_DIR/report32"
cat > "$TEST_DIR/object-category.json" << 'EOF'
[{"id":"F-001","severity":"blocker","category":{},"source_checker":"plan-schema-validator","location":{"section":"Test","fragment":""},"evidence":"test","explanation":"test","suggested_resolution":"fix","affected_acs":[],"affected_tasks":[]}]
EOF
bash "$PROJECT_ROOT/scripts/plan-check.sh" \
    --plan "$TEST_DIR/valid-plan.md" \
    --report-dir "$TEST_DIR/report32" \
    --findings-file "$TEST_DIR/object-category.json" > /dev/null 2>&1
cat32="$(python3 -c "import json; d=json.load(open('$TEST_DIR/report32/findings.json')); print(d['findings'][0]['category'])" 2>/dev/null || echo 'ERROR')"
if [[ "$cat32" == "runtime-error" ]]; then
    pass "Object category produces runtime-error"
else
    fail "Object category should produce runtime-error" "runtime-error" "$cat32"
fi

# Test 33: plan-check.sh rejects number severity
echo "Test 33: plan-check.sh rejects number severity"
mkdir -p "$TEST_DIR/report33"
cat > "$TEST_DIR/number-severity.json" << 'EOF'
[{"id":"F-001","severity":123,"category":"schema","source_checker":"plan-schema-validator","location":{"section":"Test","fragment":""},"evidence":"test","explanation":"test","suggested_resolution":"fix","affected_acs":[],"affected_tasks":[]}]
EOF
bash "$PROJECT_ROOT/scripts/plan-check.sh" \
    --plan "$TEST_DIR/valid-plan.md" \
    --report-dir "$TEST_DIR/report33" \
    --findings-file "$TEST_DIR/number-severity.json" > /dev/null 2>&1
cat33="$(python3 -c "import json; d=json.load(open('$TEST_DIR/report33/findings.json')); print(d['findings'][0]['category'])" 2>/dev/null || echo 'ERROR')"
if [[ "$cat33" == "runtime-error" ]]; then
    pass "Number severity produces runtime-error"
else
    fail "Number severity should produce runtime-error" "runtime-error" "$cat33"
fi

# Helper: simulate the full rewrite flow with actual helpers and filesystem assertions
simulate_rewrite_flow() {
    local plan_file="$1"
    local report_dir="$2"
    local revised_content="$3"
    local user_choice="$4"
    local final_confirm="$5"
    local recheck_enabled="$6"

    local diff_generated=0
    local backup_path=""
    local atomic_write_performed=0
    local recheck_count=0
    local recheck_blockers=""
    local pre_hash=""
    local post_hash=""

    pre_hash="$(sha256sum "$plan_file" | awk '{print $1}')"

    if [[ "$user_choice" == "accept" ]]; then
        diff -u "$plan_file" <(printf '%s\n' "$revised_content") > "$report_dir/diff.txt" 2>/dev/null || true
        diff_generated=1

        if [[ "$final_confirm" == "yes" ]]; then
            backup_path="$(plan_check_backup_plan "$plan_file" "$report_dir")"

            plan_check_atomic_write "$plan_file" "$revised_content"
            atomic_write_performed=1

            if [[ "$recheck_enabled" == "true" ]]; then
                recheck_count=1
                # Run actual schema validation on rewritten plan
                local recheck_findings
                recheck_findings="$(collect_schema_findings "$plan_file")"
                recheck_blockers="$(count_severity "$recheck_findings" blocker)"
            fi
        fi
    fi

    post_hash="$(sha256sum "$plan_file" | awk '{print $1}')"

    python3 -c 'import json,sys; d=json.loads(sys.stdin.read().strip()); d["pre_hash"]=d.pop("_pre"); d["post_hash"]=d.pop("_post"); print(json.dumps(d))' <<< "$(printf '{"diff_generated":%d,"backup_path":"%s","atomic_write_performed":%d,"recheck_count":%d,"recheck_blockers":"%s","_pre":"%s","_post":"%s"}\n' "$diff_generated" "$backup_path" "$atomic_write_performed" "$recheck_count" "$recheck_blockers" "$pre_hash" "$post_hash")"
}

# Helper: simulate semantic retry-once behavior and validate findings through plan-check.sh
simulate_semantic_retry() {
    local first_output="$1"
    local second_output="$2"
    local report_dir="$3"
    local valid_plan="$4"

    local retry_count=0
    local accepted_findings="[]"

    retry_count=1
    if [[ "$first_output" == "valid" ]]; then
        accepted_findings='[{"id":"F-001","severity":"blocker","category":"contradiction","source_checker":"plan-consistency-checker","location":{"section":"Test","fragment":""},"evidence":"test","explanation":"test","suggested_resolution":"fix","affected_acs":[],"affected_tasks":[]}]'
    else
        retry_count=2
        if [[ "$second_output" == "valid" ]]; then
            accepted_findings='[{"id":"F-001","severity":"blocker","category":"contradiction","source_checker":"plan-consistency-checker","location":{"section":"Test","fragment":""},"evidence":"test","explanation":"test","suggested_resolution":"fix","affected_acs":[],"affected_tasks":[]}]'
        else
            accepted_findings='[{"id":"F-RUNTIME-001","severity":"info","category":"runtime-error","source_checker":"plan-schema-validator","location":{"section":"","fragment":""},"evidence":"Semantic check failed after retry","explanation":"The semantic checker produced malformed output after one retry","suggested_resolution":"Review the sub-agent output and retry the check","affected_acs":[],"affected_tasks":[]}]'
        fi
    fi

    # Validate accepted findings through plan-check.sh
    local findings_file="$report_dir/findings.json"
    mkdir -p "$report_dir"
    printf '%s\n' "$accepted_findings" > "$findings_file"
    bash "$PROJECT_ROOT/scripts/plan-check.sh" \
        --plan "$valid_plan" \
        --report-dir "$report_dir" \
        --findings-file "$findings_file" > /dev/null 2>&1 || true

    printf '{"retry_count":%d,"findings":%s}\n' "$retry_count" "$accepted_findings"
}

# Test 34: Accept rewrite + confirm final defaults to no recheck
echo "Test 34: Accept+confirm defaults to no recheck"
mkdir -p "$TEST_DIR/report34"
# Start with an invalid plan; default behavior should still skip the recheck.
cat > "$TEST_DIR/flow-plan-34.md" << 'EOF'
# Invalid Plan

## Goal Description
A plan.

## Acceptance Criteria

- **AC-1**: First criterion

## Task Breakdown

| Task ID | Description | Target AC | Tag | Depends On |
|---------|-------------|-----------|-----|------------|
| task1 | Do something | AC-1 | coding | - |
EOF
# Fixed content adds missing Path Boundaries
fixed34="# Fixed Plan\n\n## Goal Description\nA plan.\n\n## Acceptance Criteria\n\n- **AC-1**: First criterion\n\n## Path Boundaries\n\n### Upper Bound\nComplete.\n\n### Lower Bound\nMinimum.\n\n## Task Breakdown\n\n| Task ID | Description | Target AC | Tag | Depends On |\n|---------|-------------|-----------|-----|------------|\n| task1 | Do something | AC-1 | coding | - |"
result34="$(simulate_rewrite_flow "$TEST_DIR/flow-plan-34.md" "$TEST_DIR/report34" "$fixed34" "accept" "yes" "false")"
diff34="$(echo "$result34" | python3 -c 'import json,sys; print(json.load(sys.stdin)["diff_generated"])')"
backup_path34="$(echo "$result34" | python3 -c 'import json,sys; print(json.load(sys.stdin)["backup_path"])')"
atomic34="$(echo "$result34" | python3 -c 'import json,sys; print(json.load(sys.stdin)["atomic_write_performed"])')"
recheck34="$(echo "$result34" | python3 -c 'import json,sys; print(json.load(sys.stdin)["recheck_count"])')"
recheck_blockers34="$(echo "$result34" | python3 -c 'import json,sys; print(json.load(sys.stdin)["recheck_blockers"])')"
pre34="$(echo "$result34" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pre_hash"])')"
post34="$(echo "$result34" | python3 -c 'import json,sys; print(json.load(sys.stdin)["post_hash"])')"
if [[ "$diff34" == "1" && -f "$backup_path34" && "$atomic34" == "1" && "$recheck34" == "0" && "$recheck_blockers34" == "" && "$pre34" != "$post34" ]]; then
    pass "Accept+confirm default: diff, backup exists, atomic write, recheck=0, plan changed"
else
    fail "Accept+confirm default flow" "diff=1, backup exists, atomic=1, recheck=0, recheck_blockers empty, hash changed" "diff=$diff34, backup=$backup_path34, atomic=$atomic34, recheck=$recheck34, recheck_blockers=$recheck_blockers34, pre=$pre34, post=$post34"
fi

# Test 35: Accept rewrite + confirm final + --recheck runs recheck
echo "Test 35: Accept+confirm with --recheck produces recheck=1"
mkdir -p "$TEST_DIR/report35"
cat > "$TEST_DIR/flow-plan-35.md" << 'EOF'
# Invalid Plan

## Goal Description
A plan.

## Acceptance Criteria

- **AC-1**: First criterion

## Task Breakdown

| Task ID | Description | Target AC | Tag | Depends On |
|---------|-------------|-----------|-----|------------|
| task1 | Do something | AC-1 | coding | - |
EOF
fixed35="# Fixed Plan\n\n## Goal Description\nA plan.\n\n## Acceptance Criteria\n\n- **AC-1**: First criterion\n\n## Path Boundaries\n\n### Upper Bound\nComplete.\n\n### Lower Bound\nMinimum.\n\n## Task Breakdown\n\n| Task ID | Description | Target AC | Tag | Depends On |\n|---------|-------------|-----------|-----|------------|\n| task1 | Do something | AC-1 | coding | - |"
result35="$(simulate_rewrite_flow "$TEST_DIR/flow-plan-35.md" "$TEST_DIR/report35" "$fixed35" "accept" "yes" "true")"
atomic35="$(echo "$result35" | python3 -c 'import json,sys; print(json.load(sys.stdin)["atomic_write_performed"])')"
recheck35="$(echo "$result35" | python3 -c 'import json,sys; print(json.load(sys.stdin)["recheck_count"])')"
recheck_blockers35="$(echo "$result35" | python3 -c 'import json,sys; print(json.load(sys.stdin)["recheck_blockers"])')"
if [[ "$atomic35" == "1" && "$recheck35" == "1" && "$recheck_blockers35" == "0" ]]; then
    pass "Accept+confirm with --recheck: atomic=1, recheck=1, recheck_blockers=0"
else
    fail "Accept+confirm --recheck flow" "atomic=1, recheck=1, recheck_blockers=0" "atomic=$atomic35, recheck=$recheck35, recheck_blockers=$recheck_blockers35"
fi

# Test 36: Decline rewrite leaves plan unchanged and creates no backup
echo "Test 36: Decline leaves plan unchanged, no backup, no atomic write, no recheck"
mkdir -p "$TEST_DIR/report36"
cp "$TEST_DIR/valid-plan.md" "$TEST_DIR/flow-plan-36.md"
fixed36="# Modified Plan\n\n## Goal Description\nModified.\n\n## Acceptance Criteria\n\n- **AC-1**: First criterion\n\n## Path Boundaries\n\n### Upper Bound\nComplete.\n\n### Lower Bound\nMinimum.\n\n## Task Breakdown\n\n| Task ID | Description | Target AC | Tag | Depends On |\n|---------|-------------|-----------|-----|------------|\n| task1 | Do something | AC-1 | coding | - |"
result36="$(simulate_rewrite_flow "$TEST_DIR/flow-plan-36.md" "$TEST_DIR/report36" "$fixed36" "decline" "no" "false")"
backup_path36="$(echo "$result36" | python3 -c 'import json,sys; print(json.load(sys.stdin)["backup_path"])')"
atomic36="$(echo "$result36" | python3 -c 'import json,sys; print(json.load(sys.stdin)["atomic_write_performed"])')"
recheck36="$(echo "$result36" | python3 -c 'import json,sys; print(json.load(sys.stdin)["recheck_count"])')"
pre36="$(echo "$result36" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pre_hash"])')"
post36="$(echo "$result36" | python3 -c 'import json,sys; print(json.load(sys.stdin)["post_hash"])')"
if [[ -z "$backup_path36" && "$atomic36" == "0" && "$recheck36" == "0" && "$pre36" == "$post36" ]]; then
    pass "Decline: no backup, no atomic write, no recheck, plan hash unchanged"
else
    fail "Decline flow" "backup empty, atomic=0, recheck=0, hash unchanged" "backup=$backup_path36, atomic=$atomic36, recheck=$recheck36, pre=$pre36, post=$post36"
fi

# Test 37: Accept then reject final confirmation leaves plan unchanged
echo "Test 37: Accept+reject-final leaves plan unchanged, no backup, no atomic write, no recheck"
mkdir -p "$TEST_DIR/report37"
cp "$TEST_DIR/valid-plan.md" "$TEST_DIR/flow-plan-37.md"
fixed37="# Modified Plan\n\n## Goal Description\nModified.\n\n## Acceptance Criteria\n\n- **AC-1**: First criterion\n\n## Path Boundaries\n\n### Upper Bound\nComplete.\n\n### Lower Bound\nMinimum.\n\n## Task Breakdown\n\n| Task ID | Description | Target AC | Tag | Depends On |\n|---------|-------------|-----------|-----|------------|\n| task1 | Do something | AC-1 | coding | - |"
result37="$(simulate_rewrite_flow "$TEST_DIR/flow-plan-37.md" "$TEST_DIR/report37" "$fixed37" "accept" "no" "false")"
backup_path37="$(echo "$result37" | python3 -c 'import json,sys; print(json.load(sys.stdin)["backup_path"])')"
atomic37="$(echo "$result37" | python3 -c 'import json,sys; print(json.load(sys.stdin)["atomic_write_performed"])')"
recheck37="$(echo "$result37" | python3 -c 'import json,sys; print(json.load(sys.stdin)["recheck_count"])')"
pre37="$(echo "$result37" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pre_hash"])')"
post37="$(echo "$result37" | python3 -c 'import json,sys; print(json.load(sys.stdin)["post_hash"])')"
if [[ -z "$backup_path37" && "$atomic37" == "0" && "$recheck37" == "0" && "$pre37" == "$post37" ]]; then
    pass "Accept+reject-final: no backup, no atomic write, no recheck, plan hash unchanged"
else
    fail "Accept+reject-final flow" "backup empty, atomic=0, recheck=0, hash unchanged" "backup=$backup_path37, atomic=$atomic37, recheck=$recheck37, pre=$pre37, post=$post37"
fi

# Test 38: Semantic retry-once: malformed then valid yields retry=2 and accepted findings
echo "Test 38: Semantic retry malformed-then-valid yields retry=2 and accepted findings"
mkdir -p "$TEST_DIR/report38"
result38="$(simulate_semantic_retry "malformed" "valid" "$TEST_DIR/report38" "$TEST_DIR/valid-plan.md")"
retry38="$(echo "$result38" | python3 -c 'import json,sys; print(json.load(sys.stdin)["retry_count"])')"
count38="$(echo "$result38" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["findings"]))')"
severity38="$(echo "$result38" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["findings"][0]["severity"])')"
# Validate findings passed through plan-check.sh
valid38="$(python3 -c "import json; d=json.load(open('$TEST_DIR/report38/findings.json')); print(d['findings'][0]['category'])" 2>/dev/null || echo 'ERROR')"
if [[ "$retry38" == "2" && "$count38" == "1" && "$severity38" == "blocker" && "$valid38" == "contradiction" ]]; then
    pass "Semantic retry malformed-then-valid: retry=2, accepted blocker findings, validated by plan-check.sh"
else
    fail "Semantic retry malformed-then-valid" "retry=2, count=1, severity=blocker, valid category" "retry=$retry38, count=$count38, severity=$severity38, valid=$valid38"
fi

# Test 39: Semantic retry-once: malformed then malformed yields retry=2 and runtime-error
echo "Test 39: Semantic retry malformed-then-malformed yields retry=2 and runtime-error"
mkdir -p "$TEST_DIR/report39"
result39="$(simulate_semantic_retry "malformed" "malformed" "$TEST_DIR/report39" "$TEST_DIR/valid-plan.md")"
retry39="$(echo "$result39" | python3 -c 'import json,sys; print(json.load(sys.stdin)["retry_count"])')"
count39="$(echo "$result39" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["findings"]))')"
severity39="$(echo "$result39" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["findings"][0]["severity"])')"
category39="$(echo "$result39" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["findings"][0]["category"])')"
# Validate runtime-error finding has all required schema fields via plan-check.sh
valid39_cat="$(python3 -c "import json; d=json.load(open('$TEST_DIR/report39/findings.json')); print(d['findings'][0]['category'])" 2>/dev/null || echo 'ERROR')"
valid39_id="$(python3 -c "import json; d=json.load(open('$TEST_DIR/report39/findings.json')); print(d['findings'][0]['id'])" 2>/dev/null || echo 'ERROR')"
if [[ "$retry39" == "2" && "$count39" == "1" && "$severity39" == "info" && "$category39" == "runtime-error" && "$valid39_cat" == "runtime-error" && "$valid39_id" == "F-RUNTIME-001" ]]; then
    pass "Semantic retry malformed-then-malformed: retry=2, runtime-error info, all schema fields valid"
else
    fail "Semantic retry malformed-then-malformed" "retry=2, count=1, severity=info, category=runtime-error, valid id/cat" "retry=$retry39, count=$count39, severity=$severity39, category=$category39, valid_cat=$valid39_cat, valid_id=$valid39_id"
fi

# Test 40: Null severity produces runtime-error
echo "Test 40: plan-check.sh rejects null severity"
mkdir -p "$TEST_DIR/report40"
cat > "$TEST_DIR/null-severity.json" << 'EOF'
[{"id":"F-001","severity":null,"category":"schema","source_checker":"plan-schema-validator","location":{"section":"Test","fragment":""},"evidence":"test","explanation":"test","suggested_resolution":"fix","affected_acs":[],"affected_tasks":[]}]
EOF
bash "$PROJECT_ROOT/scripts/plan-check.sh" \
    --plan "$TEST_DIR/valid-plan.md" \
    --report-dir "$TEST_DIR/report40" \
    --findings-file "$TEST_DIR/null-severity.json" > /dev/null 2>&1
cat40="$(python3 -c "import json; d=json.load(open('$TEST_DIR/report40/findings.json')); print(d['findings'][0]['category'])" 2>/dev/null || echo 'ERROR')"
if [[ "$cat40" == "runtime-error" ]]; then
    pass "Null severity produces runtime-error"
else
    fail "Null severity should produce runtime-error" "runtime-error" "$cat40"
fi

# Test 41: Mixed valid and malformed findings preserve valid blockers
echo "Test 41: Mixed valid and malformed findings preserve valid blockers"
mkdir -p "$TEST_DIR/report41"
cat > "$TEST_DIR/mixed-valid-invalid.json" << 'EOF'
[
  {"id":"F-SCHEMA-001","severity":"blocker","category":"schema","source_checker":"plan-schema-validator","location":{"section":"Task Breakdown","fragment":"task1"},"evidence":"schema blocker","explanation":"schema blocker remains valid","suggested_resolution":"fix schema","affected_acs":[],"affected_tasks":["task1"]},
  {"id":"F-BAD-001","severity":null,"category":"schema","source_checker":"plan-schema-validator","location":{"section":"Task Breakdown","fragment":"task2"},"evidence":"bad semantic finding","explanation":"bad item","suggested_resolution":"fix bad item","affected_acs":[],"affected_tasks":["task2"]}
]
EOF
bash "$PROJECT_ROOT/scripts/plan-check.sh" \
    --plan "$TEST_DIR/valid-plan.md" \
    --report-dir "$TEST_DIR/report41" \
    --findings-file "$TEST_DIR/mixed-valid-invalid.json" > /dev/null 2>&1
mixed41="$(python3 -c "import json; d=json.load(open('$TEST_DIR/report41/findings.json')); cats=[f['category'] for f in d['findings']]; ids=[f['id'] for f in d['findings']]; print('ok' if 'F-SCHEMA-001' in ids and 'runtime-error' in cats and d['summary']['blockers'] == 1 and d['summary']['status'] == 'fail' else f'bad ids={ids} cats={cats} summary={d[\"summary\"]}')" 2>/dev/null || echo 'ERROR')"
if [[ "$mixed41" == "ok" ]]; then
    pass "Mixed valid/invalid findings keep valid blocker and append runtime-error"
else
    fail "Mixed valid/invalid findings should keep valid blocker" "ok" "$mixed41"
fi

# Test 42: Command spec line order: rewrite prompt precedes diff preview precedes final confirmation precedes backup/atomic write precedes recheck gate
echo "Test 42: Command spec rewrite line order"
CMD_SPEC="$PROJECT_ROOT/commands/plan-check.md"
rewrite_line="$(grep -n -i 'rewrite the plan file' "$CMD_SPEC" | head -1 | cut -d: -f1)"
diff_line="$(grep -n -i 'diff preview' "$CMD_SPEC" | head -1 | cut -d: -f1)"
confirm_line="$(grep -n -i 'apply these changes' "$CMD_SPEC" | head -1 | cut -d: -f1)"
backup_line="$(grep -n 'plan_check_backup_plan' "$CMD_SPEC" | head -1 | cut -d: -f1)"
atomic_line="$(grep -n 'plan_check_atomic_write' "$CMD_SPEC" | head -1 | cut -d: -f1)"
recheck_line="$(grep -n 'EFFECTIVE_RECHECK=true' "$CMD_SPEC" | tail -1 | cut -d: -f1)"
if [[ -n "$rewrite_line" && -n "$diff_line" && -n "$confirm_line" && -n "$backup_line" && -n "$atomic_line" && -n "$recheck_line" ]]; then
    if [[ "$rewrite_line" -lt "$diff_line" && "$diff_line" -lt "$confirm_line" && "$confirm_line" -lt "$backup_line" && "$backup_line" -lt "$atomic_line" && "$atomic_line" -lt "$recheck_line" ]]; then
        pass "Command spec rewrite line order is correct"
    else
        fail "Command spec rewrite line order" "rewrite < diff < confirm < backup < atomic < recheck" "rewrite=$rewrite_line, diff=$diff_line, confirm=$confirm_line, backup=$backup_line, atomic=$atomic_line, recheck=$recheck_line"
    fi
else
    fail "Command spec rewrite line order: missing keywords" "all keywords present" "rewrite=$rewrite_line, diff=$diff_line, confirm=$confirm_line, backup=$backup_line, atomic=$atomic_line, recheck=$recheck_line"
fi

# Test 43: Command spec restricts shell tools while allowing repair flow writes
echo "Test 43: Command spec restricts shell tools while allowing repair flow writes"
if ! grep -q '^  - "Bash"$' "$CMD_SPEC" && \
   grep -q '^  - "Bash(mktemp:\*)"$' "$CMD_SPEC" && \
   grep -q '^  - "Bash(diff:\*)"$' "$CMD_SPEC" && \
   grep -q '^  - "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-check.sh:\*)"$' "$CMD_SPEC" && \
   grep -q '^  - "Write"$' "$CMD_SPEC" && \
   grep -q '^  - "Edit"$' "$CMD_SPEC"; then
    pass "Command spec restricts Bash and keeps required write/diff tools"
else
    fail "Command spec shell tool restrictions" "no bare Bash; mktemp, diff, plan-check.sh, Write, Edit allowed" "missing or unrestricted"
fi

# Test 44: Regression: info finding with severity strings in non-severity fields must not distort counts
echo "Test 44: Info finding with severity strings in non-severity fields reports correct counts"
mkdir -p "$TEST_DIR/report42"
cat > "$TEST_DIR/mixed-section.json" << 'EOF'
[{"id":"F-INFO-001","severity":"info","category":"appendix-drift","source_checker":"plan-schema-validator","location":{"section":"blocker warning info","fragment":""},"evidence":"appendix present","explanation":"review appendix","suggested_resolution":"check drift","affected_acs":[],"affected_tasks":[]}]
EOF
bash "$PROJECT_ROOT/scripts/plan-check.sh" \
    --plan "$TEST_DIR/valid-plan.md" \
    --report-dir "$TEST_DIR/report42" \
    --findings-file "$TEST_DIR/mixed-section.json" > /dev/null 2>&1
blockers42="$(python3 -c "import json; d=json.load(open('$TEST_DIR/report42/findings.json')); print(d['summary']['blockers'])" 2>/dev/null || echo 'ERROR')"
warnings42="$(python3 -c "import json; d=json.load(open('$TEST_DIR/report42/findings.json')); print(d['summary']['warnings'])" 2>/dev/null || echo 'ERROR')"
infos42="$(python3 -c "import json; d=json.load(open('$TEST_DIR/report42/findings.json')); print(d['summary']['infos'])" 2>/dev/null || echo 'ERROR')"
status42="$(python3 -c "import json; d=json.load(open('$TEST_DIR/report42/findings.json')); print(d['summary']['status'])" 2>/dev/null || echo 'ERROR')"
# Assert report.md markdown summary
md_blockers42="$(grep -oE 'Blockers: [0-9]+' "$TEST_DIR/report42/report.md" | awk '{print $2}')"
md_warnings42="$(grep -oE 'Warnings: [0-9]+' "$TEST_DIR/report42/report.md" | awk '{print $2}')"
md_infos42="$(grep -oE 'Infos: [0-9]+' "$TEST_DIR/report42/report.md" | awk '{print $2}')"
if [[ "$blockers42" == "0" && "$warnings42" == "0" && "$infos42" == "1" && "$status42" == "pass" && "$md_blockers42" == "0" && "$md_warnings42" == "0" && "$md_infos42" == "1" ]]; then
    pass "Info finding with severity strings in non-severity fields: blockers=0, warnings=0, infos=1, status=pass, report.md correct"
else
    fail "Info finding regression" "blockers=0, warnings=0, infos=1, status=pass, md matches" "blockers=$blockers42, warnings=$warnings42, infos=$infos42, status=$status42, md_blockers=$md_blockers42, md_warnings=$md_warnings42, md_infos=$md_infos42"
fi

# Test 45: Command spec sub-agent contract asserts retry-once and runtime-error fallback
echo "Test 45: Command spec semantic retry-once contract"
CMD_SPEC="$PROJECT_ROOT/commands/plan-check.md"
retry_line="$(grep -n -i 'retry once' "$CMD_SPEC" | head -1 | cut -d: -f1)"
continue_line="$(grep -n -i 'runtime-error.*finding' "$CMD_SPEC" | grep -i 'continue' | head -1 | cut -d: -f1)"
if [[ -n "$retry_line" && -n "$continue_line" ]]; then
    pass "Command spec contains retry-once and continue-with-runtime-error contract"
else
    fail "Command spec retry contract" "retry-once and continue-with-runtime-error lines present" "retry=$retry_line, continue=$continue_line"
fi

# Test 46: validate-plan-check-io.sh returns exit 4 when output path exists as a file
echo "Test 46: validate-plan-check-io.sh exit 4 when output path exists as file"
mkdir -p "$TEST_DIR/io-test/.humanize"
touch "$TEST_DIR/io-test/.humanize/plan-check"
echo "# test plan" > "$TEST_DIR/io-test/plan.md"
bash "$PROJECT_ROOT/scripts/validate-plan-check-io.sh" \
    --plan "$TEST_DIR/io-test/plan.md" > /dev/null 2>&1
exit44=$?
if [[ "$exit44" == "4" ]]; then
    pass "validate-plan-check-io.sh returns exit 4 for existing output file"
else
    fail "validate-plan-check-io.sh exit 4" "exit 4" "exit $exit44"
fi

# Test 47: validate-plan-check-io.sh uses project-level report dir for nested plan paths
echo "Test 47: validate-plan-check-io.sh uses project-level report dir for nested plan paths"
mkdir -p "$TEST_DIR/report-root-repo/docs"
git -C "$TEST_DIR/report-root-repo" init -q
echo "# test plan" > "$TEST_DIR/report-root-repo/docs/plan.md"
OUTPUT45="$(bash "$PROJECT_ROOT/scripts/validate-plan-check-io.sh" \
    --plan "$TEST_DIR/report-root-repo/docs/plan.md" 2>&1)"
exit45=$?
expected_report45="$TEST_DIR/report-root-repo/.humanize/plan-check"
wrong_report45="$TEST_DIR/report-root-repo/docs/.humanize/plan-check"
if [[ "$exit45" == "0" && "$OUTPUT45" == *"Report directory: $expected_report45"* && "$OUTPUT45" != *"$wrong_report45"* ]]; then
    pass "validate-plan-check-io.sh uses project-level report dir for nested plan paths"
else
    fail "validate-plan-check-io.sh nested plan report dir" "$expected_report45" "exit $exit45; output: $OUTPUT45"
fi

# Test 48: validate-plan-check-io.sh accepts --recheck and reports enabled
echo "Test 48: validate-plan-check-io.sh accepts --recheck"
mkdir -p "$TEST_DIR/io-recheck"
echo "# test plan" > "$TEST_DIR/io-recheck/plan.md"
OUTPUT46="$(bash "$PROJECT_ROOT/scripts/validate-plan-check-io.sh" \
    --plan "$TEST_DIR/io-recheck/plan.md" \
    --recheck 2>&1)"
exit46=$?
if [[ "$exit46" == "0" && "$OUTPUT46" == *"Recheck: true"* ]]; then
    pass "validate-plan-check-io.sh accepts --recheck"
else
    fail "validate-plan-check-io.sh --recheck" "exit 0 and Recheck: true" "exit $exit46; output: $OUTPUT46"
fi

# Test 49: validate-plan-check-io.sh rejects removed --no-recheck flag
echo "Test 49: validate-plan-check-io.sh rejects --no-recheck"
OUTPUT47="$(bash "$PROJECT_ROOT/scripts/validate-plan-check-io.sh" \
    --plan "$TEST_DIR/io-recheck/plan.md" \
    --no-recheck 2>&1)"
exit47=$?
if [[ "$exit47" == "6" && "$OUTPUT47" == *"Unknown option: --no-recheck"* ]]; then
    pass "validate-plan-check-io.sh rejects --no-recheck"
else
    fail "validate-plan-check-io.sh rejects --no-recheck" "exit 6 and unknown option" "exit $exit47; output: $OUTPUT47"
fi

# Test 50: Regression: canonical-only AC syntax must not abort in strict mode
echo "Test 50: Canonical-only AC syntax validates under strict mode"
cat > "$TEST_DIR/canonical-only-ac.md" << 'EOF'
# Canonical AC Plan

## Goal Description
A plan that uses the canonical AC syntax from the gen-plan template.

## Acceptance Criteria

- AC-1: First criterion
  - Positive Tests:
    - Test passes
  - Negative Tests:
    - Test fails

## Path Boundaries

### Upper Bound
Complete.

### Lower Bound
Minimum.

## Task Breakdown

| Task ID | Description | Target AC | Tag | Depends On |
|---------|-------------|-----------|-----|------------|
| task1 | Do something | AC-1 | coding | - |
EOF
strict47="$TEST_DIR/canonical-only-ac-findings.json"
collect_schema_findings_strict "$TEST_DIR/canonical-only-ac.md" "$strict47" > /dev/null 2>&1
exit47=$?
findings47="$(cat "$strict47" 2>/dev/null || echo '[]')"
blockers47="$(count_severity "$findings47" blocker)"
if [[ "$exit47" == "0" && "$blockers47" == "0" ]]; then
    pass "Canonical-only AC syntax does not abort and has no blockers"
else
    fail "Canonical-only AC syntax strict validation" "exit 0 and 0 blockers" "exit $exit47, blockers=$blockers47, findings=$findings47"
fi

# Test 51: Regression: appendix task tables must not affect main plan schema validation
echo "Test 51: Appendix task tables are ignored by schema validators"
cat > "$TEST_DIR/appendix-task-table.md" << 'EOF'
# Appendix Task Table Plan

## Goal Description
A valid plan with a stale draft task table in the appendix.

## Acceptance Criteria

- AC-1: First criterion
  - Positive Tests:
    - Test passes
  - Negative Tests:
    - Test fails

## Path Boundaries

### Upper Bound
Complete.

### Lower Bound
Minimum.

## Task Breakdown

| Task ID | Description | Target AC | Tag | Depends On |
|---------|-------------|-----------|-----|------------|
| task1 | Do something | AC-1 | coding | - |

--- Original Design Draft Start ---

Draft notes.

## Task Breakdown

| Task ID | Description | Target AC | Tag | Depends On |
|---------|-------------|-----------|-----|------------|
| stale-task | Should be ignored | AC-99 | review | missing-task |

--- Original Design Draft End ---
EOF
strict48="$TEST_DIR/appendix-task-table-findings.json"
collect_schema_findings_strict "$TEST_DIR/appendix-task-table.md" "$strict48" > /dev/null 2>&1
exit48=$?
findings48="$(cat "$strict48" 2>/dev/null || echo '[]')"
blockers48="$(count_severity "$findings48" blocker)"
if [[ "$exit48" == "0" && "$blockers48" == "0" ]]; then
    pass "Appendix task table rows do not produce schema/dependency blockers"
else
    fail "Appendix task table strict validation" "exit 0 and 0 blockers" "exit $exit48, blockers=$blockers48, findings=$findings48"
fi

# Test 52: Schema findings escape plan-derived JSON metacharacters
echo "Test 52: Schema findings escape plan-derived JSON metacharacters"
cat > "$TEST_DIR/quoted-task-id.md" << 'EOF'
# Quoted Task ID Plan

## Goal Description
A malformed plan with JSON metacharacters in task fields.

## Acceptance Criteria

- AC-1: First criterion
  - Positive Tests:
    - Test passes
  - Negative Tests:
    - Test fails

## Path Boundaries

### Upper Bound
Complete.

### Lower Bound
Minimum.

## Task Breakdown

| Task ID | Description | Target AC | Tag | Depends On |
|---------|-------------|-----------|-----|------------|
| task"1 | Do something | AC-99 | review"tag | missing"dep |
EOF
strict49="$TEST_DIR/quoted-task-id-findings.json"
collect_schema_findings_strict "$TEST_DIR/quoted-task-id.md" "$strict49" > /dev/null 2>&1
exit49=$?
findings49="$(cat "$strict49" 2>/dev/null || echo '[]')"
quoted_task49="$(printf '%s' "$findings49" | python3 -c 'import json,sys; d=json.load(sys.stdin); matches=[f for f in d if f.get("location", {}).get("fragment") == "task\"1"]; print(matches[0]["affected_tasks"][0] if matches else "MISSING")' 2>/dev/null || echo 'ERROR')"
blockers49="$(count_severity "$findings49" blocker 2>/dev/null || echo ERROR)"
if [[ "$exit49" == "0" && "$quoted_task49" == 'task"1' && "$blockers49" != "ERROR" && "$blockers49" -ge 1 ]]; then
    pass "Schema findings preserve quoted task ID as valid JSON"
else
    fail "Schema findings should preserve quoted task ID as valid JSON" "exit 0, task\"1 in affected_tasks, parseable blockers" "exit $exit49, quoted_task=$quoted_task49, blockers=$blockers49, findings=$findings49"
fi

# Test 53: Codex independent plan-check skill is wired into installer and docs
echo "Test 53: Codex independent plan-check skill wiring"
PLAN_CHECK_SKILL="$PROJECT_ROOT/skills/humanize-plan-check/SKILL.md"
INSTALL_SKILL_SCRIPT="$PROJECT_ROOT/scripts/install-skill.sh"
CODEX_INSTALL_DOC="$PROJECT_ROOT/docs/install-for-codex.md"
KIMI_INSTALL_DOC="$PROJECT_ROOT/docs/install-for-kimi.md"
USAGE_DOC="$PROJECT_ROOT/docs/usage.md"

if [[ -f "$PLAN_CHECK_SKILL" ]]; then
    pass "humanize-plan-check skill exists"
else
    fail "humanize-plan-check skill exists" "$PLAN_CHECK_SKILL" "missing"
fi

if grep -q '{{HUMANIZE_RUNTIME_ROOT}}/scripts/validate-plan-check-io.sh' "$PLAN_CHECK_SKILL" \
    && grep -q '{{HUMANIZE_RUNTIME_ROOT}}/scripts/plan-check.sh' "$PLAN_CHECK_SKILL" \
    && grep -q '.humanize/plan-check/<timestamp>/report.md' "$PLAN_CHECK_SKILL"; then
    pass "humanize-plan-check skill documents runtime scripts and report output"
else
    fail "humanize-plan-check skill content" "runtime validation/report references" "missing"
fi

if sed -n '/^SKILL_NAMES=(/,/^)/p' "$INSTALL_SKILL_SCRIPT" | grep -qF '"humanize-plan-check"'; then
    pass "install-skill.sh includes humanize-plan-check in SKILL_NAMES"
else
    fail "install-skill.sh includes humanize-plan-check in SKILL_NAMES" '"humanize-plan-check"' "missing from SKILL_NAMES"
fi

if grep -q 'humanize-plan-check' "$CODEX_INSTALL_DOC" && grep -q 'humanize-plan-check' "$KIMI_INSTALL_DOC" && grep -q '\$humanize-plan-check --plan' "$USAGE_DOC"; then
    pass "docs mention humanize-plan-check install and Codex usage"
else
    fail "docs mention humanize-plan-check" "Codex/Kimi install docs and usage example" "missing"
fi

echo ""
print_test_summary "Plan Check Test Summary"
