#!/usr/bin/env bash
#
# Integration tests for gen-plan --check mode
#
# Covers: draft-check pass/blocker, plan-check pass/blocker, repair,
# recheck, auto-start gating, tmp cleanup, and path-leak detection.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

CONFIG_LOADER="$PROJECT_ROOT/scripts/lib/config-loader.sh"
CHECK_MODE_LIB="$PROJECT_ROOT/scripts/lib/gen-plan-check-mode.sh"
PLAN_CHECK_COMMON="$PROJECT_ROOT/scripts/lib/plan-check-common.sh"
VALIDATE_SCRIPT="$PROJECT_ROOT/scripts/validate-gen-plan-io.sh"

GEN_PLAN_CMD="$PROJECT_ROOT/commands/gen-plan.md"

TESTS_PASSED=0
TESTS_FAILED=0

echo "========================================"
echo "gen-plan Check Mode Integration Tests"
echo "========================================"
echo ""

# ========================================
# Test: Resolver priority table
# ========================================

echo "--- Resolver priority table ---"

source "$CHECK_MODE_LIB"

# Default: false
_gen_plan_resolve_check_mode "false" "false" ""
if [[ "$EFFECTIVE_CHECK_MODE" == "false" ]]; then
    pass "resolver: default is false"
else
    fail "resolver: default is false" "false" "$EFFECTIVE_CHECK_MODE"
fi

# --check alone: true
_gen_plan_resolve_check_mode "true" "false" ""
if [[ "$EFFECTIVE_CHECK_MODE" == "true" ]]; then
    pass "resolver: --check alone enables"
else
    fail "resolver: --check alone enables" "true" "$EFFECTIVE_CHECK_MODE"
fi

# Config true: true
_gen_plan_resolve_check_mode "false" "false" "true"
if [[ "$EFFECTIVE_CHECK_MODE" == "true" ]]; then
    pass "resolver: config true enables"
else
    fail "resolver: config true enables" "true" "$EFFECTIVE_CHECK_MODE"
fi

# --check + config true: true (idempotent)
_gen_plan_resolve_check_mode "true" "false" "true"
if [[ "$EFFECTIVE_CHECK_MODE" == "true" ]]; then
    pass "resolver: --check + config true is true"
else
    fail "resolver: --check + config true is true" "true" "$EFFECTIVE_CHECK_MODE"
fi

# --no-check overrides --check: false
_gen_plan_resolve_check_mode "true" "true" "true"
if [[ "$EFFECTIVE_CHECK_MODE" == "false" ]]; then
    pass "resolver: --no-check overrides --check"
else
    fail "resolver: --no-check overrides --check" "false" "$EFFECTIVE_CHECK_MODE"
fi

# --no-check overrides config: false
_gen_plan_resolve_check_mode "false" "true" "true"
if [[ "$EFFECTIVE_CHECK_MODE" == "false" ]]; then
    pass "resolver: --no-check overrides config"
else
    fail "resolver: --no-check overrides config" "false" "$EFFECTIVE_CHECK_MODE"
fi

# Invalid config value warns and falls back to false
WARN_OUTPUT=$("$CHECK_MODE_LIB" </dev/null 2>&1 || true)
_gen_plan_resolve_check_mode "false" "false" "yes" 2>/tmp/gen-plan-check-warn.log
if [[ "$EFFECTIVE_CHECK_MODE" == "false" ]]; then
    pass "resolver: invalid config falls back to false"
else
    fail "resolver: invalid config falls back to false" "false" "$EFFECTIVE_CHECK_MODE"
fi
if grep -q "Warning: unsupported gen_plan_check" /tmp/gen-plan-check-warn.log; then
    pass "resolver: invalid config emits warning"
else
    fail "resolver: invalid config emits warning" "warning emitted" "no warning"
fi
rm -f /tmp/gen-plan-check-warn.log

# --check wins over invalid config (no warning should affect outcome)
_gen_plan_resolve_check_mode "true" "false" "yes" 2>/dev/null
if [[ "$EFFECTIVE_CHECK_MODE" == "true" ]]; then
    pass "resolver: --check wins over invalid config"
else
    fail "resolver: --check wins over invalid config" "true" "$EFFECTIVE_CHECK_MODE"
fi

# Null config value is treated as absent (default false)
_gen_plan_resolve_check_mode "false" "false" ""
if [[ "$EFFECTIVE_CHECK_MODE" == "false" ]]; then
    pass "resolver: empty config is default false"
else
    fail "resolver: empty config is default false" "false" "$EFFECTIVE_CHECK_MODE"
fi

# ========================================
# Test: Default config contains gen_plan_check
# ========================================

echo ""
echo "--- Default config ---"

DEFAULT_CONFIG="$PROJECT_ROOT/config/default_config.json"
if [[ -f "$DEFAULT_CONFIG" ]]; then
    val=$(jq -r '.gen_plan_check' "$DEFAULT_CONFIG")
    if [[ "$val" == "false" ]]; then
        pass "default config: gen_plan_check is false"
    else
        fail "default config: gen_plan_check is false" "false" "$val"
    fi
else
    fail "default config: file exists" "exists" "missing"
fi

# ========================================
# Test: gen-plan.md mentions check-mode phases
# ========================================

echo ""
echo "--- gen-plan.md check-mode phases ---"

if grep -q "Phase 2.5: Check-Draft" "$GEN_PLAN_CMD"; then
    pass "gen-plan.md: Check-Draft phase exists"
else
    fail "gen-plan.md: Check-Draft phase exists" "present" "missing"
fi

if grep -q "Step 1.5: Check-Plan and Repair" "$GEN_PLAN_CMD"; then
    pass "gen-plan.md: Check-Plan and Repair step exists"
else
    fail "gen-plan.md: Check-Plan and Repair step exists" "present" "missing"
fi

if grep -q "EFFECTIVE_CHECK_MODE" "$GEN_PLAN_CMD"; then
    pass "gen-plan.md: references EFFECTIVE_CHECK_MODE"
else
    fail "gen-plan.md: references EFFECTIVE_CHECK_MODE" "present" "missing"
fi

if grep -q "draft-consistency-checker" "$GEN_PLAN_CMD"; then
    pass "gen-plan.md: references draft-consistency-checker"
else
    fail "gen-plan.md: references draft-consistency-checker" "present" "missing"
fi

if grep -q "draft-ambiguity-checker" "$GEN_PLAN_CMD"; then
    pass "gen-plan.md: references draft-ambiguity-checker"
else
    fail "gen-plan.md: references draft-ambiguity-checker" "present" "missing"
fi

if grep -q "draft-plan-drift-checker" "$GEN_PLAN_CMD"; then
    pass "gen-plan.md: references draft-plan-drift-checker"
else
    fail "gen-plan.md: references draft-plan-drift-checker" "present" "missing"
fi

if grep -q "Run plan-consistency-checker on the plan body" "$GEN_PLAN_CMD" && \
   grep -q "Run plan-ambiguity-checker on the plan body" "$GEN_PLAN_CMD"; then
    pass "gen-plan.md: runs primary semantic checkers before drift lookup"
else
    fail "gen-plan.md: runs primary semantic checkers before drift lookup" "present" "missing"
fi

if grep -q "Run \`draft-plan-drift-checker\` only if \`PRIMARY_PLAN_FINDINGS\` is non-empty" "$GEN_PLAN_CMD"; then
    pass "gen-plan.md: drift checker is conditional on primary findings"
else
    fail "gen-plan.md: drift checker is conditional on primary findings" "present" "missing"
fi

if grep -q "\`PRIMARY_PLAN_FINDINGS\` as the existing plan findings to inspect" "$GEN_PLAN_CMD"; then
    pass "gen-plan.md: passes existing plan findings to drift checker"
else
    fail "gen-plan.md: passes existing plan findings to drift checker" "present" "missing"
fi

if grep -q "secondary source-recovery pass" "$GEN_PLAN_CMD" && \
   grep -q "must not run as an independent whole-plan draft completeness audit" "$GEN_PLAN_CMD"; then
    pass "gen-plan.md: documents drift as secondary source recovery"
else
    fail "gen-plan.md: documents drift as secondary source recovery" "present" "missing"
fi

if grep -q "Active Source Fidelity" "$GEN_PLAN_CMD" && \
   grep -q "the clarification takes precedence for that topic" "$GEN_PLAN_CMD"; then
    pass "gen-plan.md: documents active source fidelity and clarification precedence"
else
    fail "gen-plan.md: documents active source fidelity and clarification precedence" "present" "missing"
fi

if grep -q "MUST incorporate ALL information" "$GEN_PLAN_CMD"; then
    fail "gen-plan.md: does not require all draft information verbatim" "absent" "MUST incorporate ALL information"
else
    pass "gen-plan.md: does not require all draft information verbatim"
fi

if grep -q "superset of the draft" "$GEN_PLAN_CMD"; then
    fail "gen-plan.md: does not require plan to be a draft superset" "absent" "superset of the draft"
else
    pass "gen-plan.md: does not require plan to be a draft superset"
fi

if grep -q "NEVER discard or override any original draft content" "$GEN_PLAN_CMD"; then
    fail "gen-plan.md: does not forbid clarification supersession" "absent" "NEVER discard or override any original draft content"
else
    pass "gen-plan.md: does not forbid clarification supersession"
fi

if grep -q "plan_check_backup_plan" "$GEN_PLAN_CMD"; then
    pass "gen-plan.md: references plan_check_backup_plan"
else
    fail "gen-plan.md: references plan_check_backup_plan" "present" "missing"
fi

if grep -q "plan_check_atomic_write" "$GEN_PLAN_CMD"; then
    pass "gen-plan.md: references plan_check_atomic_write"
else
    fail "gen-plan.md: references plan_check_atomic_write" "present" "missing"
fi

if grep -q "unresolved-draft-blocker" "$GEN_PLAN_CMD"; then
    pass "gen-plan.md: auto-start skip message uses unresolved-draft-blocker"
else
    fail "gen-plan.md: auto-start skip message uses unresolved-draft-blocker" "present" "missing"
fi

if grep -q "unresolved-plan-check-blocker" "$GEN_PLAN_CMD"; then
    pass "gen-plan.md: auto-start skip message uses unresolved-plan-check-blocker"
else
    fail "gen-plan.md: auto-start skip message uses unresolved-plan-check-blocker" "present" "missing"
fi

if grep -q "recheck-failure" "$GEN_PLAN_CMD"; then
    pass "gen-plan.md: auto-start skip message uses recheck-failure"
else
    fail "gen-plan.md: auto-start skip message uses recheck-failure" "present" "missing"
fi

if grep -q ".humanize/gen-plan-check" "$GEN_PLAN_CMD"; then
    pass "gen-plan.md: references artifact directory"
else
    fail "gen-plan.md: references artifact directory" "present" "missing"
fi

if grep -q "tmp/" "$GEN_PLAN_CMD"; then
    pass "gen-plan.md: references tmp/ cleanup"
else
    fail "gen-plan.md: references tmp/ cleanup" "present" "missing"
fi

# ========================================
# Test: Agent files exist and have correct metadata
# ========================================

echo ""
echo "--- Agent files ---"

DRAFT_CONSISTENCY="$PROJECT_ROOT/agents/draft-consistency-checker.md"
DRAFT_AMBIGUITY="$PROJECT_ROOT/agents/draft-ambiguity-checker.md"
DRAFT_DRIFT="$PROJECT_ROOT/agents/draft-plan-drift-checker.md"

for agent_file in "$DRAFT_CONSISTENCY" "$DRAFT_AMBIGUITY" "$DRAFT_DRIFT"; do
    basename_file=$(basename "$agent_file")
    if [[ -f "$agent_file" ]]; then
        pass "agent: $basename_file exists"
    else
        fail "agent: $basename_file exists" "exists" "missing"
        continue
    fi

    if grep -q '^---$' "$agent_file"; then
        pass "agent: $basename_file has YAML frontmatter"
    else
        fail "agent: $basename_file has YAML frontmatter" "present" "missing"
    fi

    if grep -q "model:" "$agent_file"; then
        pass "agent: $basename_file has model field"
    else
        fail "agent: $basename_file has model field" "present" "missing"
    fi
done

# Check ID prefixes
if grep -q '"id": "DC-' "$DRAFT_CONSISTENCY"; then
    pass "draft-consistency-checker: uses DC- prefix"
else
    fail "draft-consistency-checker: uses DC- prefix" "present" "missing"
fi

if grep -q '"id": "DA-' "$DRAFT_AMBIGUITY"; then
    pass "draft-ambiguity-checker: uses DA- prefix"
else
    fail "draft-ambiguity-checker: uses DA- prefix" "present" "missing"
fi

if grep -q '"id": "DD-' "$DRAFT_DRIFT"; then
    pass "draft-plan-drift-checker: uses DD- prefix"
else
    fail "draft-plan-drift-checker: uses DD- prefix" "present" "missing"
fi

if grep -q '"category": "draft-plan-drift"' "$DRAFT_DRIFT"; then
    pass "draft-plan-drift-checker: category is draft-plan-drift"
else
    fail "draft-plan-drift-checker: category is draft-plan-drift" "present" "missing"
fi

if grep -q "Inspect only the specific supplied contradiction or ambiguity findings" "$DRAFT_DRIFT"; then
    pass "draft-plan-drift-checker: only inspects supplied findings"
else
    fail "draft-plan-drift-checker: only inspects supplied findings" "present" "missing"
fi

if grep -q "Do not scan the whole plan for omitted draft requirements" "$DRAFT_DRIFT"; then
    pass "draft-plan-drift-checker: prohibits whole-plan completeness review"
else
    fail "draft-plan-drift-checker: prohibits whole-plan completeness review" "present" "missing"
fi

if grep -q "Plan-vs-draft differences that are not attached to a supplied contradiction or ambiguity finding" "$DRAFT_DRIFT"; then
    pass "draft-plan-drift-checker: unrelated draft differences are out of scope"
else
    fail "draft-plan-drift-checker: unrelated draft differences are out of scope" "present" "missing"
fi

if grep -q '"related_finding_id": "C-001"' "$DRAFT_DRIFT"; then
    pass "draft-plan-drift-checker: includes related_finding_id field"
else
    fail "draft-plan-drift-checker: includes related_finding_id field" "present" "missing"
fi

# ========================================
# Test: plan-check.sh whitelist extensions
# ========================================

echo ""
echo "--- plan-check.sh whitelist ---"

PLAN_CHECK_SCRIPT="$PROJECT_ROOT/scripts/plan-check.sh"

if grep -q '"draft-plan-drift"' "$PLAN_CHECK_SCRIPT"; then
    pass "plan-check.sh: valid_categories includes draft-plan-drift"
else
    fail "plan-check.sh: valid_categories includes draft-plan-drift" "present" "missing"
fi

if grep -q '"draft-consistency-checker"' "$PLAN_CHECK_SCRIPT"; then
    pass "plan-check.sh: valid_checkers includes draft-consistency-checker"
else
    fail "plan-check.sh: valid_checkers includes draft-consistency-checker" "present" "missing"
fi

if grep -q '"draft-ambiguity-checker"' "$PLAN_CHECK_SCRIPT"; then
    pass "plan-check.sh: valid_checkers includes draft-ambiguity-checker"
else
    fail "plan-check.sh: valid_checkers includes draft-ambiguity-checker" "present" "missing"
fi

if grep -q '"draft-plan-drift-checker"' "$PLAN_CHECK_SCRIPT"; then
    pass "plan-check.sh: valid_checkers includes draft-plan-drift-checker"
else
    fail "plan-check.sh: valid_checkers includes draft-plan-drift-checker" "present" "missing"
fi

# ========================================
# Test: plan-check-common.sh valid_resolutions extension
# ========================================

echo ""
echo "--- plan-check-common.sh extensions ---"

if grep -q '("draft-plan-drift", "drift_resolution")' "$PLAN_CHECK_COMMON"; then
    pass "plan-check-common.sh: valid_resolutions includes draft-plan-drift"
else
    fail "plan-check-common.sh: valid_resolutions includes draft-plan-drift" "present" "missing"
fi

# ========================================
# Test: _plan_check_extract_appendix helper
# ========================================

echo ""
echo "--- _plan_check_extract_appendix helper ---"

# Need to source with set +e because plan-check-common.sh has set -e
set +e
source "$PLAN_CHECK_COMMON"
set -e

# Create a plan with appendix
TMP_PLAN=$(mktemp)
cat > "$TMP_PLAN" <<'EOF'
# Plan Title

## Goal Description
Some goal.

--- Original Design Draft Start ---

Original draft line 1.
Original draft line 2.

--- Original Design Draft End ---
EOF

APPENDIX=$(_plan_check_extract_appendix "$TMP_PLAN")
if echo "$APPENDIX" | grep -q "Original draft line 1"; then
    pass "extract_appendix: returns inner appendix content"
else
    fail "extract_appendix: returns inner appendix content" "contains draft text" "$APPENDIX"
fi

# Create a plan without appendix
TMP_PLAN_NO_APPENDIX=$(mktemp)
cat > "$TMP_PLAN_NO_APPENDIX" <<'EOF'
# Plan Title

## Goal Description
No appendix.
EOF

APPENDIX_EMPTY=$(_plan_check_extract_appendix "$TMP_PLAN_NO_APPENDIX" 2>/dev/null)
if [[ -z "$APPENDIX_EMPTY" ]]; then
    pass "extract_appendix: returns empty for missing markers"
else
    fail "extract_appendix: returns empty for missing markers" "empty" "$APPENDIX_EMPTY"
fi

rm -f "$TMP_PLAN" "$TMP_PLAN_NO_APPENDIX"

# ========================================
# Test: draft-plan-drift final schema validation
# ========================================

echo ""
echo "--- draft-plan-drift final schema validation ---"

DRIFT_SCHEMA_DIR=$(mktemp -d)
DRIFT_PLAN="$DRIFT_SCHEMA_DIR/plan.md"
cat > "$DRIFT_PLAN" <<'EOF'
# Plan

## Goal Description
Validate drift findings.
EOF

cat > "$DRIFT_SCHEMA_DIR/valid-drift.json" <<'EOF'
[
  {"id":"C-001","severity":"warning","category":"contradiction","source_checker":"plan-consistency-checker","location":{"section":"Goal","fragment":"config key"},"evidence":"conflicting key names","explanation":"two key names appear","suggested_resolution":"use one key","affected_acs":[],"affected_tasks":[]},
  {"id":"DD-001","severity":"warning","category":"draft-plan-drift","source_checker":"draft-plan-drift-checker","location":{"section":"Goal","fragment":"config key"},"evidence":"clarification says use gen_plan_check","explanation":"source material resolves the primary contradiction","suggested_resolution":"use gen_plan_check","related_finding_id":"C-001","affected_acs":[],"affected_tasks":[]}
]
EOF

mkdir -p "$DRIFT_SCHEMA_DIR/report-valid"
bash "$PLAN_CHECK_SCRIPT" \
    --plan "$DRIFT_PLAN" \
    --report-dir "$DRIFT_SCHEMA_DIR/report-valid" \
    --findings-file "$DRIFT_SCHEMA_DIR/valid-drift.json" > /dev/null 2>&1

valid_drift_result=$(python3 -c '
import json, sys
d=json.load(open(sys.argv[1]))
cats=[f.get("category") for f in d["findings"]]
ids=[f.get("id") for f in d["findings"]]
print("ok" if "draft-plan-drift" in cats and "runtime-error" not in cats and "DD-001" in ids else "bad")
' "$DRIFT_SCHEMA_DIR/report-valid/findings.json")
if [[ "$valid_drift_result" == "ok" ]]; then
    pass "plan-check.sh: valid drift finding with related_finding_id is accepted"
else
    fail "plan-check.sh: valid drift finding with related_finding_id is accepted" "ok" "$valid_drift_result"
fi

if grep -q "Related Finding.*C-001" "$DRIFT_SCHEMA_DIR/report-valid/report.md"; then
    pass "plan-check.sh: report includes related finding for drift"
else
    fail "plan-check.sh: report includes related finding for drift" "Related Finding C-001" "missing"
fi

cat > "$DRIFT_SCHEMA_DIR/missing-related.json" <<'EOF'
[
  {"id":"C-001","severity":"warning","category":"contradiction","source_checker":"plan-consistency-checker","location":{"section":"Goal","fragment":"config key"},"evidence":"conflicting key names","explanation":"two key names appear","suggested_resolution":"use one key","affected_acs":[],"affected_tasks":[]},
  {"id":"DD-001","severity":"warning","category":"draft-plan-drift","source_checker":"draft-plan-drift-checker","location":{"section":"Goal","fragment":"config key"},"evidence":"clarification says use gen_plan_check","explanation":"source material resolves the primary contradiction","suggested_resolution":"use gen_plan_check","affected_acs":[],"affected_tasks":[]}
]
EOF

mkdir -p "$DRIFT_SCHEMA_DIR/report-missing"
bash "$PLAN_CHECK_SCRIPT" \
    --plan "$DRIFT_PLAN" \
    --report-dir "$DRIFT_SCHEMA_DIR/report-missing" \
    --findings-file "$DRIFT_SCHEMA_DIR/missing-related.json" > /dev/null 2>&1
missing_related_result=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); cats=[f.get("category") for f in d["findings"]]; ids=[f.get("id") for f in d["findings"]]; print("ok" if "runtime-error" in cats and "C-001" in ids else "bad")' "$DRIFT_SCHEMA_DIR/report-missing/findings.json")
if [[ "$missing_related_result" == "ok" ]]; then
    pass "plan-check.sh: missing drift related_finding_id becomes runtime-error"
else
    fail "plan-check.sh: missing drift related_finding_id becomes runtime-error" "runtime-error plus preserved C-001" "$missing_related_result"
fi

cat > "$DRIFT_SCHEMA_DIR/unknown-related.json" <<'EOF'
[
  {"id":"C-001","severity":"warning","category":"contradiction","source_checker":"plan-consistency-checker","location":{"section":"Goal","fragment":"config key"},"evidence":"conflicting key names","explanation":"two key names appear","suggested_resolution":"use one key","affected_acs":[],"affected_tasks":[]},
  {"id":"DD-001","severity":"warning","category":"draft-plan-drift","source_checker":"draft-plan-drift-checker","location":{"section":"Goal","fragment":"config key"},"evidence":"clarification says use gen_plan_check","explanation":"source material resolves the primary contradiction","suggested_resolution":"use gen_plan_check","related_finding_id":"C-999","affected_acs":[],"affected_tasks":[]}
]
EOF

mkdir -p "$DRIFT_SCHEMA_DIR/report-unknown"
bash "$PLAN_CHECK_SCRIPT" \
    --plan "$DRIFT_PLAN" \
    --report-dir "$DRIFT_SCHEMA_DIR/report-unknown" \
    --findings-file "$DRIFT_SCHEMA_DIR/unknown-related.json" > /dev/null 2>&1
unknown_related_result=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); cats=[f.get("category") for f in d["findings"]]; ids=[f.get("id") for f in d["findings"]]; print("ok" if "runtime-error" in cats and "C-001" in ids else "bad")' "$DRIFT_SCHEMA_DIR/report-unknown/findings.json")
if [[ "$unknown_related_result" == "ok" ]]; then
    pass "plan-check.sh: unknown drift related_finding_id becomes runtime-error"
else
    fail "plan-check.sh: unknown drift related_finding_id becomes runtime-error" "runtime-error plus preserved C-001" "$unknown_related_result"
fi

cat > "$DRIFT_SCHEMA_DIR/wrong-category-related.json" <<'EOF'
[
  {"id":"S-001","severity":"warning","category":"schema","source_checker":"plan-schema-validator","location":{"section":"Goal","fragment":"config key"},"evidence":"schema issue","explanation":"not a primary semantic finding","suggested_resolution":"fix schema","affected_acs":[],"affected_tasks":[]},
  {"id":"DD-001","severity":"warning","category":"draft-plan-drift","source_checker":"draft-plan-drift-checker","location":{"section":"Goal","fragment":"config key"},"evidence":"clarification says use gen_plan_check","explanation":"source material resolves the primary contradiction","suggested_resolution":"use gen_plan_check","related_finding_id":"S-001","affected_acs":[],"affected_tasks":[]}
]
EOF

mkdir -p "$DRIFT_SCHEMA_DIR/report-wrong-category"
bash "$PLAN_CHECK_SCRIPT" \
    --plan "$DRIFT_PLAN" \
    --report-dir "$DRIFT_SCHEMA_DIR/report-wrong-category" \
    --findings-file "$DRIFT_SCHEMA_DIR/wrong-category-related.json" > /dev/null 2>&1
wrong_category_result=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); cats=[f.get("category") for f in d["findings"]]; ids=[f.get("id") for f in d["findings"]]; print("ok" if "runtime-error" in cats and "S-001" in ids else "bad")' "$DRIFT_SCHEMA_DIR/report-wrong-category/findings.json")
if [[ "$wrong_category_result" == "ok" ]]; then
    pass "plan-check.sh: wrong-category drift related_finding_id becomes runtime-error"
else
    fail "plan-check.sh: wrong-category drift related_finding_id becomes runtime-error" "runtime-error plus preserved S-001" "$wrong_category_result"
fi

resolved_drift_findings='[{"id":"C-001","severity":"warning","category":"contradiction","source_checker":"plan-consistency-checker","location":{"section":"Goal","fragment":"config key"},"evidence":"conflicting key names","explanation":"two key names appear","suggested_resolution":"use one key","affected_acs":[],"affected_tasks":[]},{"id":"DD-001","severity":"blocker","category":"draft-plan-drift","source_checker":"draft-plan-drift-checker","location":{"section":"Goal","fragment":"config key"},"evidence":"clarification says use gen_plan_check","explanation":"source material resolves the primary contradiction","suggested_resolution":"use gen_plan_check","related_finding_id":"C-001","affected_acs":[],"affected_tasks":[]}]'
resolved_drift_resolutions='[{"finding_id":"DD-001","resolution_type":"drift_resolution","resolution":"Use gen_plan_check from clarification"}]'
resolved_drift_json="$(plan_check_build_resolved_json "$DRIFT_PLAN" "abc" "test-model" "{}" 0 "$resolved_drift_findings" "$resolved_drift_resolutions")"
resolved_drift_status="$(echo "$resolved_drift_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["summary"]["status"])')"
resolved_drift_unresolved="$(echo "$resolved_drift_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["summary"]["unresolved_blockers"])')"
resolved_drift_state="$(echo "$resolved_drift_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print([f for f in d["findings"] if f["id"]=="DD-001"][0]["resolution_state"])')"
if [[ "$resolved_drift_status" == "pass" && "$resolved_drift_unresolved" == "0" && "$resolved_drift_state" == "resolved" ]]; then
    pass "plan-check-common.sh: drift_resolution resolves draft-plan-drift blocker"
else
    fail "plan-check-common.sh: drift_resolution resolves draft-plan-drift blocker" "pass/0/resolved" "$resolved_drift_status/$resolved_drift_unresolved/$resolved_drift_state"
fi

rm -rf "$DRIFT_SCHEMA_DIR"

# ========================================
# Test: docs/usage.md mentions check mode
# ========================================

echo ""
echo "--- docs/usage.md check mode docs ---"

USAGE_MD="$PROJECT_ROOT/docs/usage.md"

if grep -q '\--check' "$USAGE_MD"; then
    pass "usage.md: mentions --check"
else
    fail "usage.md: mentions --check" "present" "missing"
fi

if grep -q '\--no-check' "$USAGE_MD"; then
    pass "usage.md: mentions --no-check"
else
    fail "usage.md: mentions --no-check" "present" "missing"
fi

if grep -q 'gen_plan_check' "$USAGE_MD"; then
    pass "usage.md: mentions gen_plan_check"
else
    fail "usage.md: mentions gen_plan_check" "present" "missing"
fi

if grep -q 'check-draft' "$USAGE_MD"; then
    pass "usage.md: mentions check-draft"
else
    fail "usage.md: mentions check-draft" "present" "missing"
fi

if grep -q 'check-plan' "$USAGE_MD"; then
    pass "usage.md: mentions check-plan"
else
    fail "usage.md: mentions check-plan" "present" "missing"
fi

if grep -q '.humanize/gen-plan-check' "$USAGE_MD"; then
    pass "usage.md: mentions artifact directory"
else
    fail "usage.md: mentions artifact directory" "present" "missing"
fi

# ========================================
# Test: Version bump
# ========================================

echo ""
echo "--- Version bump ---"

PLUGIN_JSON="$PROJECT_ROOT/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$PROJECT_ROOT/.claude-plugin/marketplace.json"
README_MD="$PROJECT_ROOT/README.md"

PLUGIN_VER=$(grep -o '"version":[[:space:]]*"[^"]*"' "$PLUGIN_JSON" | grep -o '"[^"]*"$' | tr -d '"')
MARKETPLACE_VER=$(grep -o '"version":[[:space:]]*"[^"]*"' "$MARKETPLACE_JSON" | grep -o '"[^"]*"$' | tr -d '"')
README_VER=$(grep -o 'Current Version:[[:space:]]*[0-9.]*' "$README_MD" | grep -o '[0-9.]*$')

if [[ "$PLUGIN_VER" == "1.17.0" ]]; then
    pass "version: plugin.json is 1.17.0"
else
    fail "version: plugin.json is 1.17.0" "1.17.0" "$PLUGIN_VER"
fi

if [[ "$MARKETPLACE_VER" == "1.17.0" ]]; then
    pass "version: marketplace.json is 1.17.0"
else
    fail "version: marketplace.json is 1.17.0" "1.17.0" "$MARKETPLACE_VER"
fi

if [[ "$README_VER" == "1.17.0" ]]; then
    pass "version: README.md is 1.17.0"
else
    fail "version: README.md is 1.17.0" "1.17.0" "$README_VER"
fi

if [[ "$PLUGIN_VER" == "$MARKETPLACE_VER" && "$PLUGIN_VER" == "$README_VER" ]]; then
    pass "version: all three files are in sync"
else
    fail "version: all three files are in sync" "sync" "plugin=$PLUGIN_VER marketplace=$MARKETPLACE_VER readme=$README_VER"
fi

# ========================================
# Mocked Harness Setup
# ========================================

echo ""
echo "--- Mocked flow tests ---"

set +e
source "$PLAN_CHECK_COMMON" 2>/dev/null
set -e

# State directory for the current scenario
FLOW_STATE_DIR=""

# Reset state for a new scenario
_flow_reset_state() {
    FLOW_STATE_DIR="$1"
    mkdir -p "$FLOW_STATE_DIR"
    export FLOW_STATE_DIR
    cat > "$FLOW_STATE_DIR/state.json" <<'EOF'
{"checker_calls":[],"auq_calls":[],"backup_paths":[],"atomic_writes":[],"resolution_records":[],"skip_message":"","cleanup_done":false,"artifacts":[],"repair_sources":[],"recheck_ran":false}
EOF
    cat > "$FLOW_STATE_DIR/write-log.json" <<'EOF'
[]
EOF
}

# Setup PATH wrappers for cp, mv, mktemp to observe all writes
_flow_setup_path_wrappers() {
    local wrap_dir="$FLOW_STATE_DIR/wrappers"
    mkdir -p "$wrap_dir"
    local real_cp real_mv real_mktemp
    real_cp=$(command -v cp)
    real_mv=$(command -v mv)
    real_mktemp=$(command -v mktemp)

    # cp wrapper: log destination then delegate
    cat > "$wrap_dir/cp" <<EOF
#!/bin/bash
export FLOW_STATE_DIR="$FLOW_STATE_DIR"
dest="\${!#}"
python3 -c '
import json,sys
path=sys.argv[1]
with open(path) as f: data=json.load(f)
data.append({"op":"copy","path":sys.argv[2]})
with open(path,"w") as f: json.dump(data,f)
' "\$FLOW_STATE_DIR/write-log.json" "\$dest"
"$real_cp" "\$@"
EOF
    chmod +x "$wrap_dir/cp"

    # mv wrapper: log destination then delegate
    cat > "$wrap_dir/mv" <<EOF
#!/bin/bash
export FLOW_STATE_DIR="$FLOW_STATE_DIR"
dest="\${!#}"
python3 -c '
import json,sys
path=sys.argv[1]
with open(path) as f: data=json.load(f)
data.append({"op":"move","path":sys.argv[2]})
with open(path,"w") as f: json.dump(data,f)
' "\$FLOW_STATE_DIR/write-log.json" "\$dest"
"$real_mv" "\$@"
EOF
    chmod +x "$wrap_dir/mv"

    # mktemp wrapper: log created path then print it
    cat > "$wrap_dir/mktemp" <<EOF
#!/bin/bash
export FLOW_STATE_DIR="$FLOW_STATE_DIR"
result=\$("$real_mktemp" "\$@")
python3 -c '
import json,sys
path=sys.argv[1]
with open(path) as f: data=json.load(f)
data.append({"op":"temp","path":sys.argv[2]})
with open(path,"w") as f: json.dump(data,f)
' "\$FLOW_STATE_DIR/write-log.json" "\$result"
printf '%s\n' "\$result"
EOF
    chmod +x "$wrap_dir/mktemp"

    export PATH="$wrap_dir:$PATH"
}

# Log a write operation
_flow_log_write() {
    local op="$1" path="$2"
    python3 -c '
import json,sys
path=sys.argv[1]
op=sys.argv[2]
with open(path) as f: data=json.load(f)
data.append({"op":op,"path":sys.argv[3]})
with open(path,"w") as f: json.dump(data,f)
' "$FLOW_STATE_DIR/write-log.json" "$op" "$path"
}

# Write file through flow instrumentation
_flow_write_file() {
    local path="$1"
    local content="$2"
    _flow_log_write "write" "$path"
    printf '%s' "$content" > "$path"
}

# Append file through flow instrumentation
_flow_append_file() {
    local path="$1"
    local content="$2"
    _flow_log_write "append" "$path"
    printf '%s' "$content" >> "$path"
}

# Copy file through flow instrumentation
_flow_copy_file() {
    local src="$1" dst="$2"
    _flow_log_write "copy" "$dst"
    cp "$src" "$dst"
}

# Mock ask-codex.sh that logs invocations and returns predefined findings
mock_ask_codex() {
    local checker_name="$1"
    local pass_num="${2:-1}"
    echo "invoked: $checker_name pass=$pass_num" >> "$FLOW_STATE_DIR/codex.log"
    python3 -c '
import json,sys
path=sys.argv[1]
checker=sys.argv[2]
pass_num=sys.argv[3]
with open(path) as f: state=json.load(f)
state["checker_calls"].append({"checker":checker,"pass":int(pass_num)})
with open(path,"w") as f: json.dump(state,f)
' "$FLOW_STATE_DIR/state.json" "$checker_name" "$pass_num"
    if [[ "$checker_name" == "draft-consistency-checker" ]]; then
        printf '%s' "$MOCK_DRAFT_CONSISTENCY_FINDINGS"
    elif [[ "$checker_name" == "draft-ambiguity-checker" ]]; then
        printf '%s' "$MOCK_DRAFT_AMBIGUITY_FINDINGS"
    elif [[ "$checker_name" == "plan-consistency-checker" ]]; then
        printf '%s' "$MOCK_PLAN_CONSISTENCY_FINDINGS"
    elif [[ "$checker_name" == "plan-ambiguity-checker" ]]; then
        printf '%s' "$MOCK_PLAN_AMBIGUITY_FINDINGS"
    elif [[ "$checker_name" == "draft-plan-drift-checker" ]]; then
        printf '%s' "$MOCK_PLAN_DRIFT_FINDINGS"
    else
        printf '[]'
    fi
}

# Mock AskUserQuestion that logs questions, options, and returns predefined response
mock_ask_user_question() {
    local question="$1"
    shift
    local options=("$@")
    local options_json
    options_json=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${options[@]}")
    python3 -c '
import json,sys
path=sys.argv[1]
question=sys.argv[2]
options=json.loads(sys.argv[3])
with open(path) as f: state=json.load(f)
state["auq_calls"].append({"question":question,"options":options})
with open(path,"w") as f: json.dump(state,f)
' "$FLOW_STATE_DIR/state.json" "$question" "$options_json"
    printf '%s' "$MOCK_AUQ_RESPONSE"
}

# Helper: merge two JSON finding arrays
_merge_findings() {
    python3 -c 'import json,sys; a=json.loads(sys.argv[1]); b=json.loads(sys.argv[2]); print(json.dumps(a+b))' "$1" "$2"
}

# Helper: count blockers in a findings array
_count_blockers() {
    python3 -c 'import json,sys; print(sum(1 for f in json.loads(sys.argv[1]) if f.get("severity")=="blocker"))' "$1"
}

# Helper: map a finding category to the resolution_type accepted by final schema
_resolution_type_for_finding() {
    python3 -c '
import json,sys
category=json.loads(sys.argv[1]).get("category","")
mapping={
    "contradiction": "contradiction_resolution",
    "ambiguity": "ambiguity_answer",
    "draft-plan-drift": "drift_resolution",
}
print(mapping.get(category, ""))
' "$1"
}

# Resolve source-of-truth for a finding
_resolve_source_of_truth() {
    local finding="$1"
    local clarifications="$2"
    local draft_text="$3"
    local fid
    fid=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("id",""))' "$finding")
    local has_clarification
    has_clarification=$(python3 -c '
import json,sys
clarifications=json.loads(sys.argv[1])
fid=sys.argv[2]
print("true" if any(c.get("finding_id")==fid for c in clarifications) else "false")
' "$clarifications" "$fid")
    if [[ "$has_clarification" == "true" ]]; then
        printf 'clarification'
        return
    fi
    # Check finding's explicit resolution_source hint (for test harness)
    local explicit_source
    explicit_source=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("resolution_source",""))' "$finding")
    if [[ -n "$explicit_source" ]]; then
        printf '%s' "$explicit_source"
        return
    fi
    # Default to leader_judgment for unclarified findings in mock
    printf 'leader_judgment'
}

# Validate all writes in the log against AC-20 allow-list
_flow_validate_ac20() {
    local report_dir="$1"
    local output_file="$2"
    local variant_file="${3:-}"
    local violations=0
    local entry_count
    entry_count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$FLOW_STATE_DIR/write-log.json")
    local i=0
    while [[ $i -lt $entry_count ]]; do
        local wpath
        wpath=$(python3 -c '
import json,sys
path=sys.argv[1]
idx=int(sys.argv[2])
with open(path) as f: data=json.load(f)
print(data[idx]["path"])
' "$FLOW_STATE_DIR/write-log.json" "$i")
        local allowed="false"
        # Exact allowed paths per AC-20
        if [[ "$wpath" == "$output_file" ]]; then
            allowed="true"
        elif [[ -n "$variant_file" && "$wpath" == "$variant_file" ]]; then
            allowed="true"
        elif [[ "$wpath" == "$report_dir/draft-findings.json" ]]; then
            allowed="true"
        elif [[ "$wpath" == "$report_dir/plan-findings.json" ]]; then
            allowed="true"
        elif [[ "$wpath" == "$report_dir/report.md" ]]; then
            allowed="true"
        elif [[ "$wpath" == "$report_dir/resolution.json" ]]; then
            allowed="true"
        elif [[ "$wpath" == "$report_dir/backup/$(basename "$output_file").bak" ]]; then
            allowed="true"
        elif [[ "$wpath" == "$report_dir/tmp/"* ]]; then
            allowed="true"
        elif [[ "$wpath" == "$(dirname "$output_file")/.plan-check-write."* ]]; then
            allowed="true"
        fi
        if [[ "$allowed" == "false" ]]; then
            violations=$((violations + 1))
            echo "AC-20 violation: $wpath" >> "$FLOW_STATE_DIR/ac20-violations.log"
        fi
        i=$((i + 1))
    done
    printf '%d' "$violations"
}

# Helper: apply a mock repair by replacing PRE_REPAIR_BODY_SENTINEL with POST_REPAIR_BODY_SENTINEL
_apply_mock_repair() {
    local output_file="$1"
    local repaired_content
    repaired_content=$(python3 -c '
import sys
path = sys.argv[1]
with open(path, "r") as f:
    content = f.read()
content = content.replace("PRE_REPAIR_BODY_SENTINEL", "POST_REPAIR_BODY_SENTINEL")
print(content)
' "$output_file")
    plan_check_atomic_write "$output_file" "$repaired_content"
}

# Run the full mocked check-mode flow
_run_mock_check_mode_flow() {
    local report_dir="$1"
    local draft_file="$2"
    local output_file="$3"
    local plan_body_file="$4"
    local recheck_enabled="${5:-false}"
    local alt_lang="${6:-}"

    mkdir -p "$report_dir/tmp"
    local _flow_original_path="$PATH"
    _flow_setup_path_wrappers
    local clarifications="[]"
    local unresolved_draft=0
    local unresolved_plan=0
    local recheck_new=0
    local repairs_changed_bytes="false"
    local abort_occurred="false"

    # ========================================
    # Phase 1: Draft Check
    # ========================================
    local cf af
    cf=$(mock_ask_codex "draft-consistency-checker" 1)
    af=$(mock_ask_codex "draft-ambiguity-checker" 1)

    local draft_merged="[]"
    [[ "$cf" != "[]" ]] && draft_merged="$cf"
    [[ "$af" != "[]" ]] && draft_merged="$(_merge_findings "$draft_merged" "$af")"

    local draft_json
    draft_json=$(plan_check_assemble_findings_json "$draft_file" "abc123" "test-model" "{}" 0 "$draft_merged")
    _flow_write_file "$report_dir/draft-findings.json" "$draft_json"

    # Process draft blockers
    local draft_blockers
    draft_blockers=$(python3 -c 'import json,sys; print(json.dumps([f for f in json.loads(sys.stdin.read()) if f.get("severity")=="blocker"]))' <<< "$draft_merged")
    local draft_blocker_count
    draft_blocker_count=$(_count_blockers "$draft_blockers")

    local resolved_draft_count=0
    local i=0
    while [[ $i -lt $draft_blocker_count ]]; do
        local finding explanation response resolvable
        finding=$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])[int(sys.argv[2])]))' "$draft_blockers" "$i")
        explanation=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("explanation",""))' "$finding")
        resolvable=$(python3 -c 'import json,sys; print(str(json.loads(sys.argv[1]).get("resolvable",True)).lower())' "$finding")
        response=$(mock_ask_user_question "$explanation" "Provide an answer that resolves the blocker" "Abort the command")
        local fid
        fid=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("id",""))' "$finding")
        if [[ "$response" == "Abort the command" || "$response" == "abort" ]]; then
            abort_occurred="true"
            break
        elif [[ "$resolvable" == "false" ]]; then
            # Blocker remains unresolved
            true
        elif [[ -n "$response" && "$response" != "Abort the command" ]]; then
            resolved_draft_count=$((resolved_draft_count + 1))
            clarifications=$(python3 -c '
import json,sys
clarifications=json.loads(sys.argv[1])
fid=sys.argv[2]
answer=sys.argv[3]
clarifications.append({"finding_id":fid,"source":"user","answer":answer})
print(json.dumps(clarifications))
' "$clarifications" "$fid" "$response")
        else
            # No answer: leader-agent fallback with rationale
            resolved_draft_count=$((resolved_draft_count + 1))
            clarifications=$(python3 -c '
import json,sys
clarifications=json.loads(sys.argv[1])
fid=sys.argv[2]
clarifications.append({"finding_id":fid,"source":"agent","answer":"fallback-resolved","rationale":"Leader agent decided via source-of-truth precedence"})
print(json.dumps(clarifications))
' "$clarifications" "$fid")
        fi
        i=$((i + 1))
    done

    unresolved_draft=$((draft_blocker_count - resolved_draft_count))

    if [[ "$abort_occurred" == "true" ]]; then
        rm -rf "$report_dir/tmp"
        python3 -c '
import json,sys
path=sys.argv[1]
with open(path) as f: state=json.load(f)
state["cleanup_done"]=True
with open(path,"w") as f: json.dump(state,f)
' "$FLOW_STATE_DIR/state.json"
        export PATH="$_flow_original_path"
        return 1
    fi

    # Create output plan file
    {
      cat "$plan_body_file"
      printf '\n--- Original Design Draft Start ---\n'
      cat "$draft_file"
      printf '\n--- Original Design Draft End ---\n'
    } > "$output_file"
    _flow_log_write "write" "$output_file"

    # ========================================
    # Phase 2: Plan Check
    # ========================================
    local schema_out
    if [[ -n "${MOCK_SCHEMA_FINDINGS:-}" ]]; then
        schema_out="$MOCK_SCHEMA_FINDINGS"
    else
        schema_out=$(TMPDIR="$report_dir/tmp" plan_check_validate_schema "$output_file" "$PROJECT_ROOT/prompt-template/plan/gen-plan-template.md" 2>/dev/null)
    fi
    local sem_cons sem_amb sem_drift primary_plan_findings
    sem_cons=$(mock_ask_codex "plan-consistency-checker" 1)
    sem_amb=$(mock_ask_codex "plan-ambiguity-checker" 1)
    primary_plan_findings="[]"
    [[ "$sem_cons" != "[]" ]] && primary_plan_findings="$(_merge_findings "$primary_plan_findings" "$sem_cons")"
    [[ "$sem_amb" != "[]" ]] && primary_plan_findings="$(_merge_findings "$primary_plan_findings" "$sem_amb")"
    if [[ "$primary_plan_findings" != "[]" ]]; then
        sem_drift=$(mock_ask_codex "draft-plan-drift-checker" 1)
    else
        sem_drift="[]"
    fi

    local plan_merged="[]"
    if [[ -n "$schema_out" && "$schema_out" != "[]" ]]; then
        plan_merged="[$schema_out]"
    fi
    [[ "$sem_cons" != "[]" ]] && plan_merged="$(_merge_findings "$plan_merged" "$sem_cons")"
    [[ "$sem_amb" != "[]" ]] && plan_merged="$(_merge_findings "$plan_merged" "$sem_amb")"
    [[ "$sem_drift" != "[]" ]] && plan_merged="$(_merge_findings "$plan_merged" "$sem_drift")"

    local plan_json
    plan_json=$(plan_check_assemble_findings_json "$output_file" "hash123" "test-model" "{}" 0 "$plan_merged")
    _flow_write_file "$report_dir/plan-findings.json" "$plan_json"
    _flow_append_file "$report_dir/report.md" "# Plan Check Report\n\n"

    # Process plan blockers
    local plan_blockers
    plan_blockers=$(python3 -c 'import json,sys; print(json.dumps([f for f in json.loads(sys.stdin.read()) if f.get("severity")=="blocker"]))' <<< "$plan_merged")
    local plan_blocker_count
    plan_blocker_count=$(_count_blockers "$plan_blockers")

    local resolution_records="[]"
    i=0
    while [[ $i -lt $plan_blocker_count ]]; do
        local finding source_of_truth resolution_type
        finding=$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])[int(sys.argv[2])]))' "$plan_blockers" "$i")
        source_of_truth=$(_resolve_source_of_truth "$finding" "$clarifications" "draft content")
        resolution_type=$(_resolution_type_for_finding "$finding")
        local fid
        fid=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("id",""))' "$finding")

        python3 -c '
import json,sys
path=sys.argv[1]
source=sys.argv[2]
with open(path) as f: state=json.load(f)
state["repair_sources"].append(source)
with open(path,"w") as f: json.dump(state,f)
' "$FLOW_STATE_DIR/state.json" "$source_of_truth"

        if [[ "$source_of_truth" == "clarification" || "$source_of_truth" == "draft_text" ]]; then
            # High-priority source: silent repair
            local backup_path
            backup_path=$(plan_check_backup_plan "$output_file" "$report_dir")
            python3 -c '
import json,sys
path=sys.argv[1]
bp=sys.argv[2]
with open(path) as f: state=json.load(f)
state["backup_paths"].append(bp)
with open(path,"w") as f: json.dump(state,f)
' "$FLOW_STATE_DIR/state.json" "$backup_path"
            _apply_mock_repair "$output_file"
            _flow_log_write "write" "$output_file"
            python3 -c '
import json,sys
path=sys.argv[1]
aw=sys.argv[2]
with open(path) as f: state=json.load(f)
state["atomic_writes"].append(aw)
with open(path,"w") as f: json.dump(state,f)
' "$FLOW_STATE_DIR/state.json" "$output_file"
            repairs_changed_bytes="true"
            resolution_records=$(python3 -c '
import json,sys
records=json.loads(sys.argv[1])
fid=sys.argv[2]
source=sys.argv[3]
rtype=sys.argv[4]
records.append({"finding_id":fid,"resolution_type":rtype,"source":source,"applied":True})
print(json.dumps(records))
' "$resolution_records" "$fid" "$source_of_truth" "$resolution_type")
        elif [[ "$source_of_truth" == "leader_judgment" ]]; then
            # Leader judgment: diff preview + AskUserQuestion
            local confirm_response
            confirm_response=$(mock_ask_user_question "Apply this repair?" "yes" "no")
            if [[ "$confirm_response" == "yes" ]]; then
                local backup_path
                backup_path=$(plan_check_backup_plan "$output_file" "$report_dir")
                python3 -c '
import json,sys
path=sys.argv[1]
bp=sys.argv[2]
with open(path) as f: state=json.load(f)
state["backup_paths"].append(bp)
with open(path,"w") as f: json.dump(state,f)
' "$FLOW_STATE_DIR/state.json" "$backup_path"
                _apply_mock_repair "$output_file"
                _flow_log_write "write" "$output_file"
                python3 -c '
import json,sys
path=sys.argv[1]
aw=sys.argv[2]
with open(path) as f: state=json.load(f)
state["atomic_writes"].append(aw)
with open(path,"w") as f: json.dump(state,f)
' "$FLOW_STATE_DIR/state.json" "$output_file"
                repairs_changed_bytes="true"
                resolution_records=$(python3 -c '
import json,sys
records=json.loads(sys.argv[1])
fid=sys.argv[2]
rtype=sys.argv[3]
records.append({"finding_id":fid,"resolution_type":rtype,"source":"leader_judgment","applied":True})
print(json.dumps(records))
' "$resolution_records" "$fid" "$resolution_type")
            else
                resolution_records=$(python3 -c '
import json,sys
records=json.loads(sys.argv[1])
fid=sys.argv[2]
rtype=sys.argv[3]
records.append({"finding_id":fid,"resolution_type":rtype,"source":"leader_judgment","applied":False})
print(json.dumps(records))
' "$resolution_records" "$fid" "$resolution_type")
            fi
        fi
        i=$((i + 1))
    done

    _flow_write_file "$report_dir/resolution.json" "$resolution_records"
    python3 -c '
import json,sys
path=sys.argv[1]
records=json.loads(sys.argv[2])
with open(path) as f: state=json.load(f)
state["resolution_records"]=records
with open(path,"w") as f: json.dump(state,f)
' "$FLOW_STATE_DIR/state.json" "$resolution_records"

    # Compute unresolved plan blockers
    unresolved_plan=$(python3 -c '
import json,sys
records=json.loads(sys.argv[1])
unresolved=sum(1 for r in records if not r.get("applied",False))
print(unresolved)
' "$resolution_records")

    # ========================================
    # Phase 3: Optional Recheck
    # ========================================
    if [[ "$recheck_enabled" == "true" && "$repairs_changed_bytes" == "true" ]]; then
        # Recheck runs exactly once, check-only
        local recheck_schema
        recheck_schema=$(TMPDIR="$report_dir/tmp" plan_check_validate_schema "$output_file" "$PROJECT_ROOT/prompt-template/plan/gen-plan-template.md" 2>/dev/null)
        local recheck_cons recheck_amb recheck_primary
        recheck_cons=$(mock_ask_codex "plan-consistency-checker" 2)
        recheck_amb=$(mock_ask_codex "plan-ambiguity-checker" 2)
        recheck_primary="[]"
        [[ "$recheck_cons" != "[]" ]] && recheck_primary="$(_merge_findings "$recheck_primary" "$recheck_cons")"
        [[ "$recheck_amb" != "[]" ]] && recheck_primary="$(_merge_findings "$recheck_primary" "$recheck_amb")"
        if [[ "$recheck_primary" != "[]" ]]; then
            mock_ask_codex "draft-plan-drift-checker" 2 >/dev/null
        fi
        # Simulate recheck new blockers if MOCK_RECHECK_NEW_BLOCKERS is set
        if [[ "${MOCK_RECHECK_NEW_BLOCKERS:-0}" -gt 0 ]]; then
            recheck_new="$MOCK_RECHECK_NEW_BLOCKERS"
        fi
        python3 -c '
import json,sys
path=sys.argv[1]
with open(path) as f: state=json.load(f)
state["recheck_ran"]=True
with open(path,"w") as f: json.dump(state,f)
' "$FLOW_STATE_DIR/state.json"
    fi

    # ========================================
    # Phase 4: Translation (after repair)
    # ========================================
    local variant_path=""
    if [[ -n "$alt_lang" ]]; then
        variant_path="${output_file%.md}_${alt_lang}.md"
        cp "$output_file" "$variant_path"
        _flow_log_write "write" "$variant_path"
    fi

    # ========================================
    # Phase 5: Auto-start gating
    # ========================================
    local skip_msg=""
    if [[ "$unresolved_draft" -gt 0 ]]; then
        skip_msg="Auto-start skipped: unresolved-draft-blocker"
    elif [[ "$unresolved_plan" -gt 0 ]]; then
        skip_msg="Auto-start skipped: unresolved-plan-check-blocker"
    elif [[ "$recheck_new" -gt 0 ]]; then
        skip_msg="Auto-start skipped: recheck-failure"
    fi
    python3 -c '
import json,sys
path=sys.argv[1]
msg=sys.argv[2]
with open(path) as f: state=json.load(f)
state["skip_message"]=msg
with open(path,"w") as f: json.dump(state,f)
' "$FLOW_STATE_DIR/state.json" "$skip_msg"

    # ========================================
    # Phase 6: Cleanup
    # ========================================
    rm -rf "$report_dir/tmp"
    python3 -c '
import json,sys
path=sys.argv[1]
with open(path) as f: state=json.load(f)
state["cleanup_done"]=True
with open(path,"w") as f: json.dump(state,f)
' "$FLOW_STATE_DIR/state.json"

    export PATH="$_flow_original_path"
    return 0
}

# ========================================
# Mocked Flow Scenario Tests
# ========================================

# Scenario 1: Draft-check pass
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
MOCK_DRAFT_CONSISTENCY_FINDINGS="[]"
MOCK_DRAFT_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_CONSISTENCY_FINDINGS="[]"
MOCK_PLAN_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_DRIFT_FINDINGS="[]"
MOCK_SCHEMA_FINDINGS="[]"
MOCK_AUQ_RESPONSE=""

printf "Draft line 1.\nDraft line 2.\n" > "$SCENARIO_DIR/draft.md"
printf "# Plan\n\n## Goal\nGoal text.\n" > "$SCENARIO_DIR/body.md"

_run_mock_check_mode_flow "$REPORT_DIR" "$SCENARIO_DIR/draft.md" "$SCENARIO_DIR/output.md" "$SCENARIO_DIR/body.md" "false" ""

if [[ -f "$SCENARIO_DIR/output.md" ]]; then
    pass "flow: draft-check pass creates output"
else
    fail "flow: draft-check pass creates output" "created" "missing"
fi

auq_count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["auq_calls"]))' "$FLOW_STATE_DIR/state.json")
if [[ "$auq_count" -eq 0 ]]; then
    pass "flow: draft-check pass does not call AskUserQuestion"
else
    fail "flow: draft-check pass does not call AskUserQuestion" "0" "$auq_count"
fi

rm -rf "$SCENARIO_DIR"

# Scenario 2: Draft-check blocker + user clarification
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
MOCK_DRAFT_CONSISTENCY_FINDINGS='[{"id":"DC-001","severity":"blocker","category":"contradiction","source_checker":"draft-consistency-checker","location":{"section":"Goal","fragment":"X"},"evidence":"X contradicts Y","explanation":"Draft says both X and Y","suggested_resolution":"Clarify","affected_acs":[],"affected_tasks":[]}]'
MOCK_DRAFT_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_CONSISTENCY_FINDINGS="[]"
MOCK_PLAN_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_DRIFT_FINDINGS="[]"
MOCK_SCHEMA_FINDINGS="[]"
MOCK_AUQ_RESPONSE="Use X, not Y"

printf "Draft line 1.\nDraft line 2.\n" > "$SCENARIO_DIR/draft.md"
printf "# Plan\n\n## Goal\nGoal text.\n" > "$SCENARIO_DIR/body.md"

_run_mock_check_mode_flow "$REPORT_DIR" "$SCENARIO_DIR/draft.md" "$SCENARIO_DIR/output.md" "$SCENARIO_DIR/body.md" "false" ""

if [[ -f "$SCENARIO_DIR/output.md" ]]; then
    pass "flow: draft-check blocker + clarification continues"
else
    fail "flow: draft-check blocker + clarification continues" "created" "missing"
fi

auq_count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["auq_calls"]))' "$FLOW_STATE_DIR/state.json")
if [[ "$auq_count" -eq 1 ]]; then
    pass "flow: draft-check blocker calls AskUserQuestion exactly once"
else
    fail "flow: draft-check blocker calls AskUserQuestion exactly once" "1" "$auq_count"
fi

# Verify clarification was recorded
clar_count=$(python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); calls=data.get("auq_calls",[]); print(len(calls))' "$FLOW_STATE_DIR/state.json")
if [[ "$clar_count" -eq 1 ]]; then
    pass "flow: clarification AskUserQuestion recorded"
else
    fail "flow: clarification AskUserQuestion recorded" "1" "$clar_count"
fi

# Verify AskUserQuestion options are exactly answer and abort, no skip
auq_options=$(python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); opts=data["auq_calls"][0]["options"]; print(json.dumps(opts))' "$FLOW_STATE_DIR/state.json")
if echo "$auq_options" | grep -q "Provide an answer that resolves the blocker" && echo "$auq_options" | grep -q "Abort the command"; then
    pass "flow: draft-check AskUserQuestion offers answer and abort options"
else
    fail "flow: draft-check AskUserQuestion offers answer and abort options" "[answer, abort]" "$auq_options"
fi
if echo "$auq_options" | grep -qi "skip"; then
    fail "flow: draft-check AskUserQuestion does not offer skip option"
else
    pass "flow: draft-check AskUserQuestion does not offer skip option"
fi

rm -rf "$SCENARIO_DIR"

# Scenario 3: Draft-check blocker + no answer + leader fallback
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
MOCK_DRAFT_CONSISTENCY_FINDINGS='[{"id":"DC-001","severity":"blocker","category":"contradiction","source_checker":"draft-consistency-checker","location":{"section":"Goal","fragment":"X"},"evidence":"X contradicts Y","explanation":"Draft says both X and Y","suggested_resolution":"Clarify","affected_acs":[],"affected_tasks":[]}]'
MOCK_DRAFT_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_CONSISTENCY_FINDINGS="[]"
MOCK_PLAN_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_DRIFT_FINDINGS="[]"
MOCK_SCHEMA_FINDINGS="[]"
MOCK_AUQ_RESPONSE=""

printf "Draft line 1.\nDraft line 2.\n" > "$SCENARIO_DIR/draft.md"
printf "# Plan\n\n## Goal\nGoal text.\n" > "$SCENARIO_DIR/body.md"

_run_mock_check_mode_flow "$REPORT_DIR" "$SCENARIO_DIR/draft.md" "$SCENARIO_DIR/output.md" "$SCENARIO_DIR/body.md" "false" ""

if [[ -f "$SCENARIO_DIR/output.md" ]]; then
    pass "flow: draft-check no-answer fallback continues"
else
    fail "flow: draft-check no-answer fallback continues" "created" "missing"
fi

auq_count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["auq_calls"]))' "$FLOW_STATE_DIR/state.json")
if [[ "$auq_count" -eq 1 ]]; then
    pass "flow: draft-check no-answer still calls AskUserQuestion once"
else
    fail "flow: draft-check no-answer still calls AskUserQuestion once" "1" "$auq_count"
fi

rm -rf "$SCENARIO_DIR"

# Scenario 4: Draft-check abort flow
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
mkdir -p "$REPORT_DIR/tmp"
touch "$REPORT_DIR/tmp/work.tmp"
MOCK_DRAFT_CONSISTENCY_FINDINGS='[{"id":"DC-001","severity":"blocker","category":"contradiction","source_checker":"draft-consistency-checker","location":{"section":"Goal","fragment":"X"},"evidence":"X contradicts Y","explanation":"Draft says both X and Y","suggested_resolution":"Clarify","affected_acs":[],"affected_tasks":[]}]'
MOCK_DRAFT_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_CONSISTENCY_FINDINGS="[]"
MOCK_PLAN_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_DRIFT_FINDINGS="[]"
MOCK_SCHEMA_FINDINGS="[]"
MOCK_AUQ_RESPONSE="abort"

printf "Draft line 1.\nDraft line 2.\n" > "$SCENARIO_DIR/draft.md"
printf "# Plan\n\n## Goal\nGoal text.\n" > "$SCENARIO_DIR/body.md"

_run_mock_check_mode_flow "$REPORT_DIR" "$SCENARIO_DIR/draft.md" "$SCENARIO_DIR/output.md" "$SCENARIO_DIR/body.md" "false" "" || true

if [[ ! -f "$SCENARIO_DIR/output.md" ]]; then
    pass "flow: draft-check abort does not create output"
else
    fail "flow: draft-check abort does not create output" "not created" "created"
fi

if [[ ! -d "$REPORT_DIR/tmp" ]]; then
    pass "flow: draft-check abort cleans tmp"
else
    fail "flow: draft-check abort cleans tmp" "removed" "still present"
fi

if [[ -f "$REPORT_DIR/draft-findings.json" ]]; then
    pass "flow: draft-check abort retains diagnostics"
else
    fail "flow: draft-check abort retains diagnostics" "retained" "missing"
fi

cleanup_done=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cleanup_done"])' "$FLOW_STATE_DIR/state.json")
if [[ "$cleanup_done" == "True" ]]; then
    pass "flow: draft-check abort sets cleanup flag"
else
    fail "flow: draft-check abort sets cleanup flag" "True" "$cleanup_done"
fi

rm -rf "$SCENARIO_DIR"

# Scenario 5: Plan-check pass
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
MOCK_DRAFT_CONSISTENCY_FINDINGS="[]"
MOCK_DRAFT_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_CONSISTENCY_FINDINGS="[]"
MOCK_PLAN_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_DRIFT_FINDINGS='[{"id":"DD-001","severity":"blocker","category":"draft-plan-drift","source_checker":"draft-plan-drift-checker","location":{"section":"Goal","fragment":"missing draft detail"},"evidence":"Draft-only detail","explanation":"This should not be used when primary plan findings are empty","suggested_resolution":"Do not call drift checker","related_finding_id":"C-001","affected_acs":[],"affected_tasks":[]}]'
MOCK_SCHEMA_FINDINGS="[]"
MOCK_AUQ_RESPONSE=""

printf "Draft line 1.\nDraft line 2.\n" > "$SCENARIO_DIR/draft.md"
{
  printf "# Test Plan\n\n## Goal Description\nTest goal.\n\n## Acceptance Criteria\n\n- AC-1: Test criterion\n  - Positive Tests:\n    - test passes\n  - Negative Tests:\n    - test fails\n\n## Path Boundaries\n\n### Upper Bound\nMaximum scope.\n\n### Lower Bound\nMinimum scope.\n\n### Allowed Choices\n- Can use: bash\n- Cannot use: python\n\n## Dependencies and Sequence\n\n### Milestones\n1. M1: Do thing\n\n## Task Breakdown\n\n| Task ID | Description | Target AC | Tag | Depends On |\n|---------|-------------|-----------|-----|------------|\n| task1 | Do thing | AC-1 | coding | - |\n\n## Claude-Codex Deliberation\n\n### Agreements\n- Both agree.\n\n### Resolved Disagreements\n- None.\n\n### Convergence Status\n- Final Status: converged\n\n## Pending User Decisions\n\n## Implementation Notes\n\n### Code Style Requirements\n- No AC- references in code.\n"
} > "$SCENARIO_DIR/body.md"

_run_mock_check_mode_flow "$REPORT_DIR" "$SCENARIO_DIR/draft.md" "$SCENARIO_DIR/output.md" "$SCENARIO_DIR/body.md" "false" ""

plan_blockers=$(python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); print(len(data.get("repair_sources",[])))' "$FLOW_STATE_DIR/state.json")
if [[ "$plan_blockers" -eq 0 ]]; then
    pass "flow: plan-check pass has zero blockers"
else
    fail "flow: plan-check pass has zero blockers" "0" "$plan_blockers"
fi

drift_calls=$(python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); print(sum(1 for c in data["checker_calls"] if c["checker"]=="draft-plan-drift-checker"))' "$FLOW_STATE_DIR/state.json")
if [[ "$drift_calls" -eq 0 ]]; then
    pass "flow: no primary plan findings skips draft-plan-drift-checker"
else
    fail "flow: no primary plan findings skips draft-plan-drift-checker" "0" "$drift_calls"
fi

if grep -q "DD-001" "$REPORT_DIR/plan-findings.json"; then
    fail "flow: no primary plan findings excludes drift findings"
else
    pass "flow: no primary plan findings excludes drift findings"
fi

rm -rf "$SCENARIO_DIR"

# Scenario 5b: Primary ambiguity enables drift source-recovery pass
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
MOCK_DRAFT_CONSISTENCY_FINDINGS="[]"
MOCK_DRAFT_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_CONSISTENCY_FINDINGS="[]"
MOCK_PLAN_AMBIGUITY_FINDINGS='[{"id":"A-001","severity":"warning","category":"ambiguity","source_checker":"plan-ambiguity-checker","location":{"section":"Goal","fragment":"check mode"},"evidence":"Plan does not say whether check mode is opt-in","explanation":"The plan can be read as default-on or opt-in","suggested_resolution":"Use the draft default-off behavior","affected_acs":[],"affected_tasks":[],"ambiguity_details":{"competing_interpretations":["check mode is default-on","check mode is opt-in"],"execution_drift_risk":"medium","clarification_question":"Is check mode opt-in?"}}]'
MOCK_PLAN_DRIFT_FINDINGS='[{"id":"DD-001","severity":"warning","category":"draft-plan-drift","source_checker":"draft-plan-drift-checker","location":{"section":"Goal","fragment":"check mode"},"evidence":"Draft says check mode is disabled by default and enabled by --check.","explanation":"The draft resolves the supplied ambiguity.","suggested_resolution":"State that check mode is opt-in.","related_finding_id":"A-001","affected_acs":[],"affected_tasks":[]}]'
MOCK_SCHEMA_FINDINGS="[]"
MOCK_AUQ_RESPONSE=""

printf "Check mode is disabled by default and enabled by --check.\n" > "$SCENARIO_DIR/draft.md"
printf "# Plan\n\n## Goal\nDocument check mode.\n" > "$SCENARIO_DIR/body.md"

_run_mock_check_mode_flow "$REPORT_DIR" "$SCENARIO_DIR/draft.md" "$SCENARIO_DIR/output.md" "$SCENARIO_DIR/body.md" "false" ""

drift_calls=$(python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); print(sum(1 for c in data["checker_calls"] if c["checker"]=="draft-plan-drift-checker"))' "$FLOW_STATE_DIR/state.json")
if [[ "$drift_calls" -eq 1 ]]; then
    pass "flow: primary ambiguity enables draft-plan-drift-checker"
else
    fail "flow: primary ambiguity enables draft-plan-drift-checker" "1" "$drift_calls"
fi

if grep -q "DD-001" "$REPORT_DIR/plan-findings.json"; then
    pass "flow: primary ambiguity merges drift source-recovery finding"
else
    fail "flow: primary ambiguity merges drift source-recovery finding" "DD-001 present" "missing"
fi

rm -rf "$SCENARIO_DIR"

# Scenario 5c: Primary contradiction can produce clarification-backed drift
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
MOCK_DRAFT_CONSISTENCY_FINDINGS='[{"id":"DC-001","severity":"blocker","category":"contradiction","source_checker":"draft-consistency-checker","location":{"section":"Goal","fragment":"old key vs new key"},"evidence":"Draft says use old_key but clarification is needed","explanation":"Config key source is unclear","suggested_resolution":"Clarify key name","affected_acs":[],"affected_tasks":[]}]'
MOCK_DRAFT_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_CONSISTENCY_FINDINGS='[{"id":"C-001","severity":"warning","category":"contradiction","source_checker":"plan-consistency-checker","location":{"section":"Goal","fragment":"config key"},"evidence":"Plan still names both old_key and new_key","explanation":"The generated plan conflicts on the key name","suggested_resolution":"Use the clarified key name","affected_acs":[],"affected_tasks":[]}]'
MOCK_PLAN_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_DRIFT_FINDINGS='[{"id":"DD-001","severity":"warning","category":"draft-plan-drift","source_checker":"draft-plan-drift-checker","location":{"section":"Goal","fragment":"config key"},"evidence":"Clarification DC-001 answer: Use new_key only.","explanation":"The newer clarification resolves the supplied contradiction and supersedes the older draft key.","suggested_resolution":"Use new_key only.","related_finding_id":"C-001","affected_acs":[],"affected_tasks":[]}]'
MOCK_SCHEMA_FINDINGS="[]"
MOCK_AUQ_RESPONSE="Use new_key only."

printf "Original draft says use old_key until clarified.\n" > "$SCENARIO_DIR/draft.md"
printf "# Plan\n\n## Goal\nUse old_key and new_key.\n" > "$SCENARIO_DIR/body.md"

_run_mock_check_mode_flow "$REPORT_DIR" "$SCENARIO_DIR/draft.md" "$SCENARIO_DIR/output.md" "$SCENARIO_DIR/body.md" "false" ""

drift_calls=$(python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); print(sum(1 for c in data["checker_calls"] if c["checker"]=="draft-plan-drift-checker"))' "$FLOW_STATE_DIR/state.json")
if [[ "$drift_calls" -eq 1 ]]; then
    pass "flow: primary contradiction enables clarification-backed drift lookup"
else
    fail "flow: primary contradiction enables clarification-backed drift lookup" "1" "$drift_calls"
fi

if grep -q "Clarification DC-001 answer: Use new_key only." "$REPORT_DIR/plan-findings.json" && \
   grep -q '"related_finding_id": "C-001"' "$REPORT_DIR/plan-findings.json"; then
    pass "flow: clarification-backed drift is tied to primary contradiction"
else
    fail "flow: clarification-backed drift is tied to primary contradiction" "clarification evidence and related_finding_id" "missing"
fi

rm -rf "$SCENARIO_DIR"

# Scenario 5d: Plan aligned with newer clarification does not drift only because older draft differs
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
MOCK_DRAFT_CONSISTENCY_FINDINGS='[{"id":"DC-001","severity":"blocker","category":"contradiction","source_checker":"draft-consistency-checker","location":{"section":"Goal","fragment":"old key vs new key"},"evidence":"Draft says use old_key but clarification is needed","explanation":"Config key source is unclear","suggested_resolution":"Clarify key name","affected_acs":[],"affected_tasks":[]}]'
MOCK_DRAFT_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_CONSISTENCY_FINDINGS="[]"
MOCK_PLAN_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_DRIFT_FINDINGS='[{"id":"DD-001","severity":"warning","category":"draft-plan-drift","source_checker":"draft-plan-drift-checker","location":{"section":"Goal","fragment":"new_key"},"evidence":"Older draft says old_key.","explanation":"This would be invalid because the newer clarification supersedes the old draft text.","suggested_resolution":"Use old_key.","related_finding_id":"C-001","affected_acs":[],"affected_tasks":[]}]'
MOCK_SCHEMA_FINDINGS="[]"
MOCK_AUQ_RESPONSE="Use new_key only."

printf "Original draft says use old_key until clarified.\n" > "$SCENARIO_DIR/draft.md"
printf "# Plan\n\n## Goal\nUse new_key only.\n" > "$SCENARIO_DIR/body.md"

_run_mock_check_mode_flow "$REPORT_DIR" "$SCENARIO_DIR/draft.md" "$SCENARIO_DIR/output.md" "$SCENARIO_DIR/body.md" "false" ""

drift_calls=$(python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); print(sum(1 for c in data["checker_calls"] if c["checker"]=="draft-plan-drift-checker"))' "$FLOW_STATE_DIR/state.json")
if [[ "$drift_calls" -eq 0 ]]; then
    pass "flow: plan aligned with newer clarification skips older-draft drift"
else
    fail "flow: plan aligned with newer clarification skips older-draft drift" "0" "$drift_calls"
fi

if grep -q "DD-001" "$REPORT_DIR/plan-findings.json"; then
    fail "flow: older draft text alone does not produce drift after clarification" "no DD-001" "DD-001 present"
else
    pass "flow: older draft text alone does not produce drift after clarification"
fi

rm -rf "$SCENARIO_DIR"

# Scenario 6: Plan-check blocker + high-priority silent repair
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
MOCK_DRAFT_CONSISTENCY_FINDINGS="[]"
MOCK_DRAFT_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_CONSISTENCY_FINDINGS='[{"id":"C-001","severity":"blocker","category":"contradiction","source_checker":"plan-consistency-checker","location":{"section":"Goal","fragment":"default off vs on"},"evidence":"Plan says default-on but draft says default-off","explanation":"Plan contradicts draft","suggested_resolution":"Use draft default-off","resolution_source":"draft_text","affected_acs":[],"affected_tasks":[]}]'
MOCK_PLAN_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_DRIFT_FINDINGS="[]"
MOCK_SCHEMA_FINDINGS="[]"
MOCK_AUQ_RESPONSE=""

printf "draft content line 1.\ndraft content line 2.\n" > "$SCENARIO_DIR/draft.md"
{
  printf "# Test Plan\n\n## Goal Description\nTest goal.\n\n## Acceptance Criteria\n\n- AC-1: Test criterion\n\n## Task Breakdown\n\n| Task ID | Description | Target AC | Tag | Depends On |\n|---------|-------------|-----------|-----|------------|\n| task1 | Do thing | AC-1 | coding | - |\n"
} > "$SCENARIO_DIR/body.md"

_run_mock_check_mode_flow "$REPORT_DIR" "$SCENARIO_DIR/draft.md" "$SCENARIO_DIR/output.md" "$SCENARIO_DIR/body.md" "false" ""

auq_count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["auq_calls"]))' "$FLOW_STATE_DIR/state.json")
if [[ "$auq_count" -eq 0 ]]; then
    pass "flow: high-priority repair is silent (no AskUserQuestion)"
else
    fail "flow: high-priority repair is silent (no AskUserQuestion)" "0" "$auq_count"
fi

backup_count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["backup_paths"]))' "$FLOW_STATE_DIR/state.json")
if [[ "$backup_count" -eq 1 ]]; then
    pass "flow: high-priority repair creates backup"
else
    fail "flow: high-priority repair creates backup" "1" "$backup_count"
fi

# Verify appendix preserved
_plan_check_extract_appendix "$SCENARIO_DIR/output.md" > "$SCENARIO_DIR/extracted.md"
if cmp -s "$SCENARIO_DIR/draft.md" "$SCENARIO_DIR/extracted.md"; then
    pass "flow: high-priority repair preserves appendix"
else
    fail "flow: high-priority repair preserves appendix" "identical" "differ"
fi

# Verify repair source recorded
first_source=$(python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); print(data["repair_sources"][0])' "$FLOW_STATE_DIR/state.json")
if [[ "$first_source" == "draft_text" ]]; then
    pass "flow: high-priority repair source is draft_text"
else
    fail "flow: high-priority repair source is draft_text" "draft_text" "$first_source"
fi

rm -rf "$SCENARIO_DIR"

# Scenario 6b: Draft-plan-drift blocker + high-priority silent repair preserves appendix
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
MOCK_DRAFT_CONSISTENCY_FINDINGS="[]"
MOCK_DRAFT_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_CONSISTENCY_FINDINGS='[{"id":"C-001","severity":"warning","category":"contradiction","source_checker":"plan-consistency-checker","location":{"section":"Goal","fragment":"default off vs on"},"evidence":"Plan says default-on but draft says default-off","explanation":"Primary finding gates draft drift analysis","suggested_resolution":"Use draft default-off","affected_acs":[],"affected_tasks":[]}]'
MOCK_PLAN_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_DRIFT_FINDINGS='[{"id":"DD-001","severity":"blocker","category":"draft-plan-drift","source_checker":"draft-plan-drift-checker","location":{"section":"Goal","fragment":"default off vs on"},"evidence":"Original draft says the feature is default-off.","explanation":"The draft resolves the supplied primary contradiction.","suggested_resolution":"Rewrite generated plan body to default-off.","resolution_source":"draft_text","related_finding_id":"C-001","affected_acs":[],"affected_tasks":[]}]'
MOCK_SCHEMA_FINDINGS="[]"
MOCK_AUQ_RESPONSE=""

printf "Original draft unique bytes line A.\nOriginal draft unique bytes line B.\n" > "$SCENARIO_DIR/draft.md"
{
  printf "# Test Plan\n\n## Goal Description\nPRE_REPAIR_BODY_SENTINEL\n\n## Acceptance Criteria\n\n- AC-1: Test criterion\n\n## Task Breakdown\n\n| Task ID | Description | Target AC | Tag | Depends On |\n|---------|-------------|-----------|-----|------------|\n| task1 | Do thing | AC-1 | coding | - |\n"
} > "$SCENARIO_DIR/body.md"

_run_mock_check_mode_flow "$REPORT_DIR" "$SCENARIO_DIR/draft.md" "$SCENARIO_DIR/output.md" "$SCENARIO_DIR/body.md" "false" ""

drift_calls=$(python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); print(sum(1 for c in data["checker_calls"] if c["checker"]=="draft-plan-drift-checker"))' "$FLOW_STATE_DIR/state.json")
if [[ "$drift_calls" -eq 1 ]]; then
    pass "flow: drift repair calls draft-plan-drift-checker"
else
    fail "flow: drift repair calls draft-plan-drift-checker" "1" "$drift_calls"
fi

auq_count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["auq_calls"]))' "$FLOW_STATE_DIR/state.json")
if [[ "$auq_count" -eq 0 ]]; then
    pass "flow: drift repair is silent (no AskUserQuestion)"
else
    fail "flow: drift repair is silent (no AskUserQuestion)" "0" "$auq_count"
fi

backup_count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["backup_paths"]))' "$FLOW_STATE_DIR/state.json")
if [[ "$backup_count" -eq 1 ]]; then
    pass "flow: drift repair creates exactly one backup"
else
    fail "flow: drift repair creates exactly one backup" "1" "$backup_count"
fi

atomic_count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["atomic_writes"]))' "$FLOW_STATE_DIR/state.json")
if [[ "$atomic_count" -eq 1 ]]; then
    pass "flow: drift repair records exactly one atomic write"
else
    fail "flow: drift repair records exactly one atomic write" "1" "$atomic_count"
fi

if grep -q "POST_REPAIR_BODY_SENTINEL" "$SCENARIO_DIR/output.md" && \
   ! grep -q "PRE_REPAIR_BODY_SENTINEL" "$SCENARIO_DIR/output.md"; then
    pass "flow: drift repair rewrites generated plan body"
else
    fail "flow: drift repair rewrites generated plan body" "POST without PRE" "missing post or stale pre"
fi

_plan_check_extract_appendix "$SCENARIO_DIR/output.md" > "$SCENARIO_DIR/extracted.md"
if cmp -s "$SCENARIO_DIR/draft.md" "$SCENARIO_DIR/extracted.md"; then
    pass "flow: drift repair preserves appendix byte-for-byte"
else
    fail "flow: drift repair preserves appendix byte-for-byte" "identical" "differ"
fi

drift_resolution_record=$(python3 -c '
import json,sys
records=json.load(open(sys.argv[1]))
match=[
    r for r in records
    if r.get("finding_id")=="DD-001"
    and r.get("resolution_type")=="drift_resolution"
    and r.get("source")=="draft_text"
    and r.get("applied") is True
]
print("ok" if len(match)==1 else "bad")
' "$REPORT_DIR/resolution.json")
if [[ "$drift_resolution_record" == "ok" ]]; then
    pass "flow: drift repair resolution.json records drift_resolution"
else
    fail "flow: drift repair resolution.json records drift_resolution" "ok" "$drift_resolution_record"
fi

drift_state_record=$(python3 -c '
import json,sys
state=json.load(open(sys.argv[1]))
records=state.get("resolution_records", [])
match=[
    r for r in records
    if r.get("finding_id")=="DD-001"
    and r.get("resolution_type")=="drift_resolution"
    and r.get("source")=="draft_text"
    and r.get("applied") is True
]
print("ok" if len(match)==1 else "bad")
' "$FLOW_STATE_DIR/state.json")
if [[ "$drift_state_record" == "ok" ]]; then
    pass "flow: drift repair state records drift_resolution"
else
    fail "flow: drift repair state records drift_resolution" "ok" "$drift_state_record"
fi

drift_related_id=$(python3 -c '
import json,sys
data=json.load(open(sys.argv[1]))
match=[
    f for f in data.get("findings", [])
    if f.get("id")=="DD-001"
    and f.get("category")=="draft-plan-drift"
    and f.get("related_finding_id")=="C-001"
]
print("ok" if len(match)==1 else "bad")
' "$REPORT_DIR/plan-findings.json")
if [[ "$drift_related_id" == "ok" ]]; then
    pass "flow: drift repair plan findings preserve related_finding_id"
else
    fail "flow: drift repair plan findings preserve related_finding_id" "ok" "$drift_related_id"
fi

rm -rf "$SCENARIO_DIR"

# Scenario 7: Plan-check blocker + leader judgment + diff + confirmation
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
MOCK_DRAFT_CONSISTENCY_FINDINGS="[]"
MOCK_DRAFT_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_CONSISTENCY_FINDINGS='[{"id":"C-001","severity":"blocker","category":"contradiction","source_checker":"plan-consistency-checker","location":{"section":"Goal","fragment":"wording"},"evidence":"Wording is ambiguous","explanation":"Leader judgment required for wording fix","suggested_resolution":"Rephrase","affected_acs":[],"affected_tasks":[]}]'
MOCK_PLAN_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_DRIFT_FINDINGS="[]"
MOCK_SCHEMA_FINDINGS="[]"
MOCK_AUQ_RESPONSE="yes"

printf "draft content line 1.\ndraft content line 2.\n" > "$SCENARIO_DIR/draft.md"
{
  printf "# Test Plan\n\n## Goal Description\nTest goal.\n\n## Acceptance Criteria\n\n- AC-1: Test criterion\n\n## Task Breakdown\n\n| Task ID | Description | Target AC | Tag | Depends On |\n|---------|-------------|-----------|-----|------------|\n| task1 | Do thing | AC-1 | coding | - |\n"
} > "$SCENARIO_DIR/body.md"

_run_mock_check_mode_flow "$REPORT_DIR" "$SCENARIO_DIR/draft.md" "$SCENARIO_DIR/output.md" "$SCENARIO_DIR/body.md" "false" ""

auq_count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["auq_calls"]))' "$FLOW_STATE_DIR/state.json")
if [[ "$auq_count" -eq 1 ]]; then
    pass "flow: leader-judgment calls AskUserQuestion for confirmation"
else
    fail "flow: leader-judgment calls AskUserQuestion for confirmation" "1" "$auq_count"
fi

backup_count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["backup_paths"]))' "$FLOW_STATE_DIR/state.json")
if [[ "$backup_count" -eq 1 ]]; then
    pass "flow: leader-judgment confirmed repair creates backup"
else
    fail "flow: leader-judgment confirmed repair creates backup" "1" "$backup_count"
fi

first_source=$(python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); print(data["repair_sources"][0])' "$FLOW_STATE_DIR/state.json")
if [[ "$first_source" == "leader_judgment" ]]; then
    pass "flow: leader-judgment repair source recorded"
else
    fail "flow: leader-judgment repair source recorded" "leader_judgment" "$first_source"
fi

rm -rf "$SCENARIO_DIR"

# Scenario 8: Recheck runs exactly once
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
MOCK_DRAFT_CONSISTENCY_FINDINGS="[]"
MOCK_DRAFT_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_CONSISTENCY_FINDINGS='[{"id":"C-001","severity":"blocker","category":"contradiction","source_checker":"plan-consistency-checker","location":{"section":"Goal","fragment":"wording"},"evidence":"Wording is ambiguous","explanation":"Leader judgment required for wording fix","suggested_resolution":"Rephrase","affected_acs":[],"affected_tasks":[]}]'
MOCK_PLAN_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_DRIFT_FINDINGS="[]"
MOCK_SCHEMA_FINDINGS="[]"
MOCK_AUQ_RESPONSE="yes"

printf "draft content line 1.\ndraft content line 2.\n" > "$SCENARIO_DIR/draft.md"
{
  printf "# Test Plan\n\n## Goal Description\nTest goal.\n\n## Acceptance Criteria\n\n- AC-1: Test criterion\n\n## Task Breakdown\n\n| Task ID | Description | Target AC | Tag | Depends On |\n|---------|-------------|-----------|-----|------------|\n| task1 | Do thing | AC-1 | coding | - |\n"
} > "$SCENARIO_DIR/body.md"

_run_mock_check_mode_flow "$REPORT_DIR" "$SCENARIO_DIR/draft.md" "$SCENARIO_DIR/output.md" "$SCENARIO_DIR/body.md" "true" ""

recheck_ran=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["recheck_ran"])' "$FLOW_STATE_DIR/state.json")
if [[ "$recheck_ran" == "True" ]]; then
    pass "flow: recheck runs when enabled and repairs changed bytes"
else
    fail "flow: recheck runs when enabled and repairs changed bytes" "True" "$recheck_ran"
fi

# Verify recheck added exactly 3 extra checker calls (schema + 3 semantic = 4 total post-repair, but schema is not mock_ask_codex)
# Actually schema validation is real, mock codex calls are: plan-consistency (pass1), plan-ambiguity (pass1), drift (pass1), plan-consistency (pass2), plan-ambiguity (pass2), drift (pass2)
# Total mock checker calls should be 6 (3 initial + 3 recheck)
checker_calls=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["checker_calls"]))' "$FLOW_STATE_DIR/state.json")
if [[ "$checker_calls" -eq 8 ]]; then
    pass "flow: recheck adds exactly 3 extra checker calls"
else
    fail "flow: recheck adds exactly 3 extra checker calls" "8" "$checker_calls"
fi

rm -rf "$SCENARIO_DIR"

# Scenario 9: Recheck skipped when repairs did not change bytes
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
MOCK_DRAFT_CONSISTENCY_FINDINGS="[]"
MOCK_DRAFT_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_CONSISTENCY_FINDINGS='[{"id":"C-001","severity":"blocker","category":"contradiction","source_checker":"plan-consistency-checker","location":{"section":"Goal","fragment":"wording"},"evidence":"Wording is ambiguous","explanation":"Leader judgment required for wording fix","suggested_resolution":"Rephrase","affected_acs":[],"affected_tasks":[]}]'
MOCK_PLAN_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_DRIFT_FINDINGS="[]"
MOCK_SCHEMA_FINDINGS="[]"
MOCK_AUQ_RESPONSE="no"

printf "draft content line 1.\ndraft content line 2.\n" > "$SCENARIO_DIR/draft.md"
{
  printf "# Test Plan\n\n## Goal Description\nTest goal.\n\n## Acceptance Criteria\n\n- AC-1: Test criterion\n\n## Task Breakdown\n\n| Task ID | Description | Target AC | Tag | Depends On |\n|---------|-------------|-----------|-----|------------|\n| task1 | Do thing | AC-1 | coding | - |\n"
} > "$SCENARIO_DIR/body.md"

_run_mock_check_mode_flow "$REPORT_DIR" "$SCENARIO_DIR/draft.md" "$SCENARIO_DIR/output.md" "$SCENARIO_DIR/body.md" "true" ""

recheck_ran=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["recheck_ran"])' "$FLOW_STATE_DIR/state.json")
if [[ "$recheck_ran" == "False" ]]; then
    pass "flow: recheck skipped when user declines repair"
else
    fail "flow: recheck skipped when user declines repair" "False" "$recheck_ran"
fi

rm -rf "$SCENARIO_DIR"

# Scenario 10: Auto-start gating via driver
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
MOCK_DRAFT_CONSISTENCY_FINDINGS="[]"
MOCK_DRAFT_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_CONSISTENCY_FINDINGS="[]"
MOCK_PLAN_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_DRIFT_FINDINGS="[]"
MOCK_SCHEMA_FINDINGS="[]"
MOCK_AUQ_RESPONSE=""

printf "draft content\n" > "$SCENARIO_DIR/draft.md"
printf "# Plan\n\n## Goal\nGoal.\n" > "$SCENARIO_DIR/body.md"

_run_mock_check_mode_flow "$REPORT_DIR" "$SCENARIO_DIR/draft.md" "$SCENARIO_DIR/output.md" "$SCENARIO_DIR/body.md" "false" ""

skip_msg=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["skip_message"])' "$FLOW_STATE_DIR/state.json")
if [[ -z "$skip_msg" ]]; then
    pass "flow: auto-start allowed when all blockers clear"
else
    fail "flow: auto-start allowed when all blockers clear" "allowed" "blocked: $skip_msg"
fi

rm -rf "$SCENARIO_DIR"

# Scenario 11: Auto-start blocked by unresolved plan blocker
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
MOCK_DRAFT_CONSISTENCY_FINDINGS="[]"
MOCK_DRAFT_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_CONSISTENCY_FINDINGS='[{"id":"C-001","severity":"blocker","category":"contradiction","source_checker":"plan-consistency-checker","location":{"section":"Goal","fragment":"wording"},"evidence":"Wording is ambiguous","explanation":"Leader judgment required for wording fix","suggested_resolution":"Rephrase","affected_acs":[],"affected_tasks":[]}]'
MOCK_PLAN_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_DRIFT_FINDINGS="[]"
MOCK_SCHEMA_FINDINGS="[]"
MOCK_AUQ_RESPONSE="no"

printf "draft content\n" > "$SCENARIO_DIR/draft.md"
printf "# Plan\n\n## Goal\nGoal.\n" > "$SCENARIO_DIR/body.md"

_run_mock_check_mode_flow "$REPORT_DIR" "$SCENARIO_DIR/draft.md" "$SCENARIO_DIR/output.md" "$SCENARIO_DIR/body.md" "false" ""

skip_msg=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["skip_message"])' "$FLOW_STATE_DIR/state.json")
if [[ "$skip_msg" == "Auto-start skipped: unresolved-plan-check-blocker" ]]; then
    pass "flow: auto-start skip message for plan-check-blocker"
else
    fail "flow: auto-start skip message for plan-check-blocker" "unresolved-plan-check-blocker" "$skip_msg"
fi

if echo "$skip_msg" | grep -qi "AC-"; then
    fail "flow: auto-start skip message contains no AC- prefix"
else
    pass "flow: auto-start skip message contains no AC- prefix"
fi

rm -rf "$SCENARIO_DIR"

# Scenario 12: tmp cleanup on success
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
MOCK_DRAFT_CONSISTENCY_FINDINGS="[]"
MOCK_DRAFT_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_CONSISTENCY_FINDINGS="[]"
MOCK_PLAN_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_DRIFT_FINDINGS="[]"
MOCK_SCHEMA_FINDINGS="[]"
MOCK_AUQ_RESPONSE=""

printf "draft content\n" > "$SCENARIO_DIR/draft.md"
printf "# Plan\n\n## Goal\nGoal.\n" > "$SCENARIO_DIR/body.md"

_run_mock_check_mode_flow "$REPORT_DIR" "$SCENARIO_DIR/draft.md" "$SCENARIO_DIR/output.md" "$SCENARIO_DIR/body.md" "false" ""

if [[ ! -d "$REPORT_DIR/tmp" ]]; then
    pass "flow: tmp/ cleaned up on success path"
else
    fail "flow: tmp/ cleaned up on success path" "removed" "still present"
fi

cleanup_done=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cleanup_done"])' "$FLOW_STATE_DIR/state.json")
if [[ "$cleanup_done" == "True" ]]; then
    pass "flow: cleanup flag set on success"
else
    fail "flow: cleanup flag set on success" "True" "$cleanup_done"
fi

rm -rf "$SCENARIO_DIR"

# Scenario 13: Translation after repair via driver with alt_lang=zh
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
MOCK_DRAFT_CONSISTENCY_FINDINGS="[]"
MOCK_DRAFT_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_CONSISTENCY_FINDINGS='[{"id":"C-001","severity":"blocker","category":"contradiction","source_checker":"plan-consistency-checker","location":{"section":"Goal","fragment":"wording"},"evidence":"Wording is ambiguous","explanation":"Leader judgment required for wording fix","suggested_resolution":"Rephrase","resolution_source":"draft_text","affected_acs":[],"affected_tasks":[]}]'
MOCK_PLAN_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_DRIFT_FINDINGS="[]"
MOCK_SCHEMA_FINDINGS="[]"
MOCK_AUQ_RESPONSE=""

printf "draft content line 1.\ndraft content line 2.\n" > "$SCENARIO_DIR/draft.md"
{
  printf "# Test Plan\n\n## Goal Description\nPRE_REPAIR_BODY_SENTINEL\n\n## Acceptance Criteria\n\n- AC-1: Test criterion\n\n## Task Breakdown\n\n| Task ID | Description | Target AC | Tag | Depends On |\n|---------|-------------|-----------|-----|------------|\n| task1 | Do thing | AC-1 | coding | - |\n"
} > "$SCENARIO_DIR/body.md"

output_path="$SCENARIO_DIR/output.md"
_run_mock_check_mode_flow "$REPORT_DIR" "$SCENARIO_DIR/draft.md" "$output_path" "$SCENARIO_DIR/body.md" "false" "zh"

variant_path="${output_path%.md}_zh.md"

# Variant path uses documented suffix
if [[ "$variant_path" == "$SCENARIO_DIR/output_zh.md" ]]; then
    pass "flow: translation variant path uses documented suffix"
else
    fail "flow: translation variant path uses documented suffix" "$SCENARIO_DIR/output_zh.md" "$variant_path"
fi

# Variant exists after driver completes
if [[ -f "$variant_path" ]]; then
    pass "flow: translation variant created after repair"
else
    fail "flow: translation variant created after repair" "created" "missing"
fi

# Variant contains repaired bytes (sentinel replaced by _apply_mock_repair)
if grep -q "POST_REPAIR_BODY_SENTINEL" "$variant_path"; then
    pass "flow: translation variant contains repaired bytes"
else
    fail "flow: translation variant contains repaired bytes" "contains POST_REPAIR_BODY_SENTINEL" "missing"
fi

# Variant does not contain stale pre-repair bytes
if grep -q "PRE_REPAIR_BODY_SENTINEL" "$variant_path"; then
    fail "flow: translation variant does not contain stale pre-repair bytes"
else
    pass "flow: translation variant does not contain stale pre-repair bytes"
fi

# Appendix preserved in variant
_plan_check_extract_appendix "$variant_path" > "$SCENARIO_DIR/extracted.md"
if cmp -s "$SCENARIO_DIR/draft.md" "$SCENARIO_DIR/extracted.md"; then
    pass "flow: translation variant preserves appendix"
else
    fail "flow: translation variant preserves appendix" "identical" "differ"
fi

# Atomic write recorded in state
atomic_count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("atomic_writes",[])))' "$FLOW_STATE_DIR/state.json")
if [[ "$atomic_count" -eq 1 ]]; then
    pass "flow: translation repair records atomic write"
else
    fail "flow: translation repair records atomic write" "1" "$atomic_count"
fi

# AC-20 validation on repaired flow: zero violations including helper-produced paths
violations=$(_flow_validate_ac20 "$REPORT_DIR" "$output_path" "$variant_path")
if [[ "$violations" -eq 0 ]]; then
    pass "ac20: repaired translation flow produces zero write violations"
else
    fail "ac20: repaired translation flow produces zero write violations" "0" "$violations"
fi

# Assert write-log contains helper-observed cp (backup), mktemp (temp), and mv (output) paths
log_has_backup=$(python3 -c '
import json,sys
path=sys.argv[1]
with open(path) as f: data=json.load(f)
has_cp = any(e.get("op")=="copy" and ".bak" in e.get("path","") for e in data)
print("true" if has_cp else "false")
' "$FLOW_STATE_DIR/write-log.json")
if [[ "$log_has_backup" == "true" ]]; then
    pass "ac20: write-log observes backup copy from helper"
else
    fail "ac20: write-log observes backup copy from helper" "true" "false"
fi

log_has_temp=$(python3 -c '
import json,sys
path=sys.argv[1]
with open(path) as f: data=json.load(f)
has_temp = any(e.get("op")=="temp" and ".plan-check-write." in e.get("path","") for e in data)
print("true" if has_temp else "false")
' "$FLOW_STATE_DIR/write-log.json")
if [[ "$log_has_temp" == "true" ]]; then
    pass "ac20: write-log observes temp file from helper mktemp"
else
    fail "ac20: write-log observes temp file from helper mktemp" "true" "false"
fi

log_has_mv=$(python3 -c '
import json,sys
path=sys.argv[1]
with open(path) as f: data=json.load(f)
has_mv = any(e.get("op")=="move" for e in data)
print("true" if has_mv else "false")
' "$FLOW_STATE_DIR/write-log.json")
if [[ "$log_has_mv" == "true" ]]; then
    pass "ac20: write-log observes move from helper mv"
else
    fail "ac20: write-log observes move from helper mv" "true" "false"
fi

rm -rf "$SCENARIO_DIR"

# Scenario 14: Auto-start blocked by unresolved draft blocker
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
MOCK_DRAFT_CONSISTENCY_FINDINGS='[{"id":"DC-001","severity":"blocker","category":"contradiction","source_checker":"draft-consistency-checker","location":{"section":"Goal","fragment":"X"},"evidence":"X contradicts Y","explanation":"Draft says both X and Y","suggested_resolution":"Clarify","resolvable":false,"affected_acs":[],"affected_tasks":[]}]'
MOCK_DRAFT_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_CONSISTENCY_FINDINGS="[]"
MOCK_PLAN_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_DRIFT_FINDINGS="[]"
MOCK_SCHEMA_FINDINGS="[]"
MOCK_AUQ_RESPONSE=""

printf "draft content\n" > "$SCENARIO_DIR/draft.md"
printf "# Plan\n\n## Goal\nGoal.\n" > "$SCENARIO_DIR/body.md"

_run_mock_check_mode_flow "$REPORT_DIR" "$SCENARIO_DIR/draft.md" "$SCENARIO_DIR/output.md" "$SCENARIO_DIR/body.md" "false" ""

skip_msg=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["skip_message"])' "$FLOW_STATE_DIR/state.json")
if [[ "$skip_msg" == "Auto-start skipped: unresolved-draft-blocker" ]]; then
    pass "flow: auto-start skip message for draft-blocker"
else
    fail "flow: auto-start skip message for draft-blocker" "unresolved-draft-blocker" "$skip_msg"
fi

if echo "$skip_msg" | grep -qi "AC-"; then
    fail "flow: draft-blocker skip message contains no AC- prefix"
else
    pass "flow: draft-blocker skip message contains no AC- prefix"
fi

rm -rf "$SCENARIO_DIR"

# Scenario 15: Auto-start blocked by recheck-failure
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
MOCK_DRAFT_CONSISTENCY_FINDINGS="[]"
MOCK_DRAFT_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_CONSISTENCY_FINDINGS='[{"id":"C-001","severity":"blocker","category":"contradiction","source_checker":"plan-consistency-checker","location":{"section":"Goal","fragment":"wording"},"evidence":"Wording is ambiguous","explanation":"Leader judgment required for wording fix","suggested_resolution":"Rephrase","resolution_source":"draft_text","affected_acs":[],"affected_tasks":[]}]'
MOCK_PLAN_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_DRIFT_FINDINGS="[]"
MOCK_SCHEMA_FINDINGS="[]"
MOCK_AUQ_RESPONSE=""
MOCK_RECHECK_NEW_BLOCKERS=1

printf "draft content line 1.\ndraft content line 2.\n" > "$SCENARIO_DIR/draft.md"
{
  printf "# Test Plan\n\n## Goal Description\nTest goal.\n\n## Acceptance Criteria\n\n- AC-1: Test criterion\n\n## Task Breakdown\n\n| Task ID | Description | Target AC | Tag | Depends On |\n|---------|-------------|-----------|-----|------------|\n| task1 | Do thing | AC-1 | coding | - |\n"
} > "$SCENARIO_DIR/body.md"

_run_mock_check_mode_flow "$REPORT_DIR" "$SCENARIO_DIR/draft.md" "$SCENARIO_DIR/output.md" "$SCENARIO_DIR/body.md" "true" ""

skip_msg=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["skip_message"])' "$FLOW_STATE_DIR/state.json")
if [[ "$skip_msg" == "Auto-start skipped: recheck-failure" ]]; then
    pass "flow: auto-start skip message for recheck-failure"
else
    fail "flow: auto-start skip message for recheck-failure" "recheck-failure" "$skip_msg"
fi

if echo "$skip_msg" | grep -qi "AC-"; then
    fail "flow: recheck-failure skip message contains no AC- prefix"
else
    pass "flow: recheck-failure skip message contains no AC- prefix"
fi

rm -rf "$SCENARIO_DIR"

# ========================================
# AC-20 Write Validation Tests
# ========================================

echo ""
echo "--- AC-20 write validation ---"

# Positive: Normal flow writes only to allowed paths
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
MOCK_DRAFT_CONSISTENCY_FINDINGS="[]"
MOCK_DRAFT_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_CONSISTENCY_FINDINGS="[]"
MOCK_PLAN_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_DRIFT_FINDINGS="[]"
MOCK_SCHEMA_FINDINGS="[]"
MOCK_AUQ_RESPONSE=""

printf "draft content\n" > "$SCENARIO_DIR/draft.md"
printf "# Plan\n\n## Goal\nGoal.\n" > "$SCENARIO_DIR/body.md"

_run_mock_check_mode_flow "$REPORT_DIR" "$SCENARIO_DIR/draft.md" "$SCENARIO_DIR/output.md" "$SCENARIO_DIR/body.md" "false" ""

violations=$(_flow_validate_ac20 "$REPORT_DIR" "$SCENARIO_DIR/output.md" "")
if [[ "$violations" -eq 0 ]]; then
    pass "ac20: normal flow produces zero write violations"
else
    fail "ac20: normal flow produces zero write violations" "0" "$violations"
fi

rm -rf "$SCENARIO_DIR"

# Positive: Real schema validation temp files are routed through REPORT_DIR/tmp
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
MOCK_DRAFT_CONSISTENCY_FINDINGS="[]"
MOCK_DRAFT_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_CONSISTENCY_FINDINGS="[]"
MOCK_PLAN_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_DRIFT_FINDINGS="[]"
# Leave MOCK_SCHEMA_FINDINGS unset so real plan_check_validate_schema runs
unset MOCK_SCHEMA_FINDINGS
MOCK_AUQ_RESPONSE=""

printf "draft content\n" > "$SCENARIO_DIR/draft.md"
{
  printf "# Test Plan\n\n## Goal Description\nGoal.\n\n## Acceptance Criteria\n\n- AC-1: Test criterion\n\n## Path Boundaries\n\n## Task Breakdown\n\n| Task ID | Description | Target AC | Tag | Depends On |\n|---------|-------------|-----------|-----|------------|\n| task1 | Do thing | AC-1 | coding | - |\n"
} > "$SCENARIO_DIR/body.md"

_run_mock_check_mode_flow "$REPORT_DIR" "$SCENARIO_DIR/draft.md" "$SCENARIO_DIR/output.md" "$SCENARIO_DIR/body.md" "false" ""

# Assert at least one temp entry was recorded under REPORT_DIR/tmp
schema_temps_inside=$(python3 -c '
import json,sys
path=sys.argv[1]
report_dir=sys.argv[2]
with open(path) as f: data=json.load(f)
good = [e["path"] for e in data if e.get("op")=="temp" and e["path"].startswith(report_dir + "/tmp/")]
print(len(good))
' "$FLOW_STATE_DIR/write-log.json" "$REPORT_DIR")
if [[ "$schema_temps_inside" -ge 1 ]]; then
    pass "ac20: schema validation records at least one temp under REPORT_DIR/tmp"
else
    fail "ac20: schema validation records at least one temp under REPORT_DIR/tmp" ">=1" "$schema_temps_inside"
fi

# Assert no temp entries escaped REPORT_DIR/tmp
schema_temps_outside=$(python3 -c '
import json,sys
path=sys.argv[1]
report_dir=sys.argv[2]
with open(path) as f: data=json.load(f)
bad = [e["path"] for e in data if e.get("op")=="temp" and not e["path"].startswith(report_dir + "/tmp/")]
print(len(bad))
' "$FLOW_STATE_DIR/write-log.json" "$REPORT_DIR")
if [[ "$schema_temps_outside" -eq 0 ]]; then
    pass "ac20: schema validation temps are under REPORT_DIR/tmp"
else
    fail "ac20: schema validation temps are under REPORT_DIR/tmp" "0 outside" "$schema_temps_outside outside"
fi

violations=$(_flow_validate_ac20 "$REPORT_DIR" "$SCENARIO_DIR/output.md" "")
if [[ "$violations" -eq 0 ]]; then
    pass "ac20: real schema validation flow produces zero write violations"
else
    fail "ac20: real schema validation flow produces zero write violations" "0" "$violations"
fi

rm -rf "$SCENARIO_DIR"

# Positive: Translation flow writes to allowed paths (output + variant)
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
MOCK_DRAFT_CONSISTENCY_FINDINGS="[]"
MOCK_DRAFT_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_CONSISTENCY_FINDINGS="[]"
MOCK_PLAN_AMBIGUITY_FINDINGS="[]"
MOCK_PLAN_DRIFT_FINDINGS="[]"
MOCK_SCHEMA_FINDINGS="[]"
MOCK_AUQ_RESPONSE=""

printf "draft content\n" > "$SCENARIO_DIR/draft.md"
printf "# Plan\n\n## Goal\nGoal.\n" > "$SCENARIO_DIR/body.md"

output_path="$SCENARIO_DIR/output.md"
_run_mock_check_mode_flow "$REPORT_DIR" "$SCENARIO_DIR/draft.md" "$output_path" "$SCENARIO_DIR/body.md" "false" "zh"

variant_path="${output_path%.md}_zh.md"
violations=$(_flow_validate_ac20 "$REPORT_DIR" "$output_path" "$variant_path")
if [[ "$violations" -eq 0 ]]; then
    pass "ac20: translation flow produces zero write violations"
else
    fail "ac20: translation flow produces zero write violations" "0" "$violations"
fi

rm -rf "$SCENARIO_DIR"

# Negative: Detects forbidden path $REPORT_DIR/findings.json (wrong filename)
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
_flow_log_write "write" "$REPORT_DIR/findings.json"
violations=$(_flow_validate_ac20 "$REPORT_DIR" "$SCENARIO_DIR/output.md" "")
if [[ "$violations" -eq 1 ]]; then
    pass "ac20: flags $REPORT_DIR/findings.json as violation"
else
    fail "ac20: flags $REPORT_DIR/findings.json as violation" "1" "$violations"
fi
rm -rf "$SCENARIO_DIR"

# Negative: Detects forbidden path $REPORT_DIR/draft/foo.json (no draft/ subdir)
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
_flow_log_write "write" "$REPORT_DIR/draft/foo.json"
violations=$(_flow_validate_ac20 "$REPORT_DIR" "$SCENARIO_DIR/output.md" "")
if [[ "$violations" -eq 1 ]]; then
    pass "ac20: flags $REPORT_DIR/draft/ as violation"
else
    fail "ac20: flags $REPORT_DIR/draft/ as violation" "1" "$violations"
fi
rm -rf "$SCENARIO_DIR"

# Negative: Detects forbidden path $REPORT_DIR/plan/bar.json (no plan/ subdir)
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
_flow_log_write "write" "$REPORT_DIR/plan/bar.json"
violations=$(_flow_validate_ac20 "$REPORT_DIR" "$SCENARIO_DIR/output.md" "")
if [[ "$violations" -eq 1 ]]; then
    pass "ac20: flags $REPORT_DIR/plan/ as violation"
else
    fail "ac20: flags $REPORT_DIR/plan/ as violation" "1" "$violations"
fi
rm -rf "$SCENARIO_DIR"

# Negative: Detects write outside allow-list
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
_flow_log_write "write" "$SCENARIO_DIR/secret_leak.md"
violations=$(_flow_validate_ac20 "$REPORT_DIR" "$SCENARIO_DIR/output.md" "")
if [[ "$violations" -eq 1 ]]; then
    pass "ac20: flags write outside allow-list as violation"
else
    fail "ac20: flags write outside allow-list as violation" "1" "$violations"
fi
rm -rf "$SCENARIO_DIR"

# Negative: Detects forbidden backup path $REPORT_DIR/backup/other.bak
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
_flow_log_write "write" "$REPORT_DIR/backup/other.bak"
violations=$(_flow_validate_ac20 "$REPORT_DIR" "$SCENARIO_DIR/output.md" "")
if [[ "$violations" -eq 1 ]]; then
    pass "ac20: flags $REPORT_DIR/backup/other.bak as violation"
else
    fail "ac20: flags $REPORT_DIR/backup/other.bak as violation" "1" "$violations"
fi
rm -rf "$SCENARIO_DIR"

# Negative: Detects forbidden nested backup path $REPORT_DIR/backup/nested/file.bak
SCENARIO_DIR=$(mktemp -d)
REPORT_DIR=$(plan_check_init_report_dir "$SCENARIO_DIR")
_flow_reset_state "$SCENARIO_DIR/flow"
mkdir -p "$REPORT_DIR/backup/nested"
_flow_log_write "write" "$REPORT_DIR/backup/nested/file.bak"
violations=$(_flow_validate_ac20 "$REPORT_DIR" "$SCENARIO_DIR/output.md" "")
if [[ "$violations" -eq 1 ]]; then
    pass "ac20: flags $REPORT_DIR/backup/nested/file.bak as violation"
else
    fail "ac20: flags $REPORT_DIR/backup/nested/file.bak as violation" "1" "$violations"
fi
rm -rf "$SCENARIO_DIR"

# ========================================
# Regression Tests
# ========================================

echo ""
echo "--- Regression tests ---"

# Regression 1: Schema-template path in gen-plan.md
if grep -q 'plan_check_validate_schema.*prompt-template/plan/gen-plan-template.md' "$GEN_PLAN_CMD"; then
    pass "regression: schema validation uses canonical template path"
else
    fail "regression: schema validation uses canonical template path" "present" "missing"
fi

# Regression 2: Default-mode full output baseline using fixtures
FIXTURE_DIR="$SCRIPT_DIR/fixtures/gen-plan-check"
if [[ -d "$FIXTURE_DIR" ]]; then
    TEST_REG_DIR=$(mktemp -d)
    cp "$FIXTURE_DIR/default-draft.md" "$TEST_REG_DIR/draft.md"
    cp "$FIXTURE_DIR/default-template.md" "$TEST_REG_DIR/template.md"

    {
      cat "$TEST_REG_DIR/template.md"
      printf '\n--- Original Design Draft Start ---\n'
      cat "$TEST_REG_DIR/draft.md"
      printf '\n--- Original Design Draft End ---\n'
    } > "$TEST_REG_DIR/plan.md"

    if cmp -s "$TEST_REG_DIR/plan.md" "$FIXTURE_DIR/default-expected.md"; then
        pass "regression: default-mode full output matches fixture baseline"
    else
        fail "regression: default-mode full output matches fixture baseline" "identical" "differ"
    fi
    rm -rf "$TEST_REG_DIR"
else
    skip "regression: default-mode full output matches fixture baseline" "fixture dir not found"
fi

# Regression 3: Appendix preservation through accepted repair path
TEST_REG_DIR=$(mktemp -d)
printf "draft content line 1.\ndraft content line 2.\n" > "$TEST_REG_DIR/draft.md"
{
  printf "# Plan\n\n## Goal\nOriginal goal.\n\n## Task Breakdown\n\n| Task ID | Description | Target AC | Tag | Depends On |\n|---------|-------------|-----------|-----|------------|\n| task1 | Do thing | AC-1 | coding | - |\n"
  printf '\n--- Original Design Draft Start ---\n'
  cat "$TEST_REG_DIR/draft.md"
  printf '\n--- Original Design Draft End ---\n'
} > "$TEST_REG_DIR/plan.md"

REPORT_DIR=$(plan_check_init_report_dir "$TEST_REG_DIR")

# Accepted repair path: backup + atomic write
BACKUP_RESULT=$(plan_check_backup_plan "$TEST_REG_DIR/plan.md" "$REPORT_DIR")
{
  printf "# Plan\n\n## Goal\nRepaired goal.\n\n## Task Breakdown\n\n| Task ID | Description | Target AC | Tag | Depends On |\n|---------|-------------|-----------|-----|------------|\n| task1 | Do thing | AC-1 | coding | - |\n"
  printf '\n--- Original Design Draft Start ---\n'
  cat "$TEST_REG_DIR/draft.md"
  printf '\n--- Original Design Draft End ---\n'
} > "$TEST_REG_DIR/repaired.md"

plan_check_atomic_write "$TEST_REG_DIR/plan.md" "$(cat "$TEST_REG_DIR/repaired.md")"

_plan_check_extract_appendix "$TEST_REG_DIR/plan.md" > "$TEST_REG_DIR/extracted.md"
if cmp -s "$TEST_REG_DIR/draft.md" "$TEST_REG_DIR/extracted.md"; then
    pass "regression: appendix preserved through accepted repair path"
else
    fail "regression: appendix preserved through accepted repair path" "identical" "differ"
fi
if [[ -f "$BACKUP_RESULT" ]]; then
    pass "regression: accepted repair creates backup at flat path"
else
    fail "regression: accepted repair creates backup at flat path" "exists" "missing"
fi
rm -rf "$TEST_REG_DIR"

# Regression 5: Draft without trailing newline
TEST_REG_DIR=$(mktemp -d)
printf "no trailing newline" > "$TEST_REG_DIR/draft.md"
{
  printf "# Plan\n\n## Goal\nGoal text.\n"
  printf '\n--- Original Design Draft Start ---\n'
  cat "$TEST_REG_DIR/draft.md"
  printf '\n--- Original Design Draft End ---\n'
} > "$TEST_REG_DIR/plan.md"

_plan_check_extract_appendix "$TEST_REG_DIR/plan.md" > "$TEST_REG_DIR/extracted.md"
if cmp -s "$TEST_REG_DIR/draft.md" "$TEST_REG_DIR/extracted.md"; then
    pass "regression: draft without trailing newline preserved exactly"
else
    fail "regression: draft without trailing newline preserved exactly" "identical" "differ"
fi
rm -rf "$TEST_REG_DIR"

# Regression 6: plan_check_validate_schema runs deterministically with canonical template
if [[ -f "$PROJECT_ROOT/prompt-template/plan/gen-plan-template.md" ]]; then
    TEST_REG_DIR=$(mktemp -d)
    cat > "$TEST_REG_DIR/valid_plan.md" <<'EOF'
# Test Plan

## Goal Description
Test goal.

## Acceptance Criteria

- AC-1: Test criterion
  - Positive Tests:
    - test passes
  - Negative Tests:
    - test fails

## Path Boundaries

### Upper Bound
Maximum scope.

### Lower Bound
Minimum scope.

### Allowed Choices
- Can use: bash
- Cannot use: python

## Dependencies and Sequence

### Milestones
1. M1: Do thing

## Task Breakdown

| Task ID | Description | Target AC | Tag | Depends On |
|---------|-------------|-----------|-----|------------|
| task1 | Do thing | AC-1 | coding | - |

## Claude-Codex Deliberation

### Agreements
- Both agree.

### Resolved Disagreements
- None.

### Convergence Status
- Final Status: converged

## Pending User Decisions

## Implementation Notes

### Code Style Requirements
- No AC- references in code.

--- Original Design Draft Start ---

draft content

--- Original Design Draft End ---
EOF

    SCHEMA_OUT=$(plan_check_validate_schema "$TEST_REG_DIR/valid_plan.md" "$PROJECT_ROOT/prompt-template/plan/gen-plan-template.md" 2>/dev/null)
    if echo "$SCHEMA_OUT" | grep -q "runtime-error"; then
        fail "regression: schema validation with canonical template should not emit runtime-error" "no runtime-error" "has runtime-error"
    else
        pass "regression: schema validation runs deterministically with canonical template"
    fi
    rm -rf "$TEST_REG_DIR"
else
    skip "regression: schema validation with canonical template" "canonical template not found"
fi

# Regression 7: Backup path flat layout
TEST_BACKUP_DIR=$(mktemp -d)
printf "plan content\n" > "$TEST_BACKUP_DIR/plan.md"
BACKUP_RESULT=$(plan_check_backup_plan "$TEST_BACKUP_DIR/plan.md" "$TEST_BACKUP_DIR")
if [[ -f "$TEST_BACKUP_DIR/backup/plan.md.bak" ]]; then
    pass "regression: backup path is <report_dir>/backup/<plan>.bak"
else
    fail "regression: backup path is <report_dir>/backup/<plan>.bak" "exists" "missing"
fi
if [[ -d "$TEST_BACKUP_DIR/backup/backup" ]]; then
    fail "regression: backup path never nests backup/backup/" "absent" "present"
else
    pass "regression: backup path never nests backup/backup/"
fi
rm -rf "$TEST_BACKUP_DIR"

# ========================================
# Summary
# ========================================

print_test_summary "gen-plan Check Mode Integration Tests"
