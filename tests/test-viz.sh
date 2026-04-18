#!/usr/bin/env bash
#
# Tests for the Humanize Viz dashboard functionality
#
# Tests cover:
# - viz-start.sh / viz-stop.sh / viz-status.sh script behavior
# - Python parser module (syntax + basic functionality)
# - Python analyzer module
# - Python exporter module
# - Sanitized issue generation
# - Setup script viz marker output
# - Cancel script viz stop integration
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VIZ_DIR="$PLUGIN_ROOT/viz"
SERVER_DIR="$VIZ_DIR/server"

echo "========================================"
echo "Humanize Viz Dashboard Tests"
echo "========================================"

# ─── Pre-check ───
if ! command -v python3 &>/dev/null; then
    echo "SKIP: python3 not available"
    exit 0
fi

setup_test_dir

# ========================================
# Test Group 1: Shell Script Validation
# ========================================
echo ""
echo "Test Group 1: Shell Script Syntax"

for script in viz-start.sh viz-stop.sh viz-status.sh; do
    if bash -n "$VIZ_DIR/scripts/$script" 2>/dev/null; then
        pass "Shell syntax valid: $script"
    else
        fail "Shell syntax invalid: $script"
    fi
done

# ========================================
# Test Group 2: Python Module Syntax
# ========================================
echo ""
echo "Test Group 2: Python Module Syntax"

for module in parser.py analyzer.py exporter.py app.py watcher.py; do
    if python3 -m py_compile "$SERVER_DIR/$module" 2>/dev/null; then
        pass "Python syntax valid: $module"
    else
        fail "Python syntax invalid: $module"
    fi
done

# ========================================
# Test Group 3: Parser Tests
# ========================================
echo ""
echo "Test Group 3: Parser Functionality"

# Create a mock RLCR session
MOCK_PROJECT="$TEST_DIR/project"
MOCK_SESSION="$MOCK_PROJECT/.humanize/rlcr/2026-01-01_12-00-00"
mkdir -p "$MOCK_SESSION"

# Create state.md
cat > "$MOCK_SESSION/state.md" << 'STATE'
---
current_round: 2
max_iterations: 42
plan_file: plan.md
start_branch: main
base_branch: main
codex_model: gpt-5.4
codex_effort: high
started_at: 2026-01-01T12:00:00Z
---
STATE

# Create goal-tracker.md
cat > "$MOCK_SESSION/goal-tracker.md" << 'GT'
## IMMUTABLE SECTION

### Ultimate Goal
Build a test feature.

### Acceptance Criteria

- AC-1: First criterion
- AC-2: Second criterion

---

## MUTABLE SECTION

### Plan Version: 1 (Updated: Round 0)

#### Active Tasks
| Task | Target AC | Status | Tag | Owner | Notes |
|------|-----------|--------|-----|-------|-------|
| task1 | AC-1 | completed | coding | claude | Done |
| task2 | AC-2 | in_progress | coding | claude | WIP |

### Completed and Verified
| AC | Task | Completed Round | Verified Round | Evidence |
|----|------|-----------------|----------------|----------|
| AC-1 | task1 | 1 | 1 | Tests pass |

### Explicitly Deferred
| Task | Original AC | Deferred Since | Justification | When to Reconsider |
|------|-------------|----------------|---------------|-------------------|
GT

# Create round summaries
cat > "$MOCK_SESSION/round-0-summary.md" << 'R0'
# Round 0 Summary
## What Was Implemented
Initial setup completed. 2/4 tasks done.
## BitLesson Delta
Action: none
R0

cat > "$MOCK_SESSION/round-1-summary.md" << 'R1'
# Round 1 Summary
## What Was Implemented
Implemented main feature.
## BitLesson Delta
Action: add
R1

# Create review result
cat > "$MOCK_SESSION/round-0-review-result.md" << 'RR0'
# Round 0 Review
Mainline Progress Verdict: ADVANCED
The implementation is progressing well.
RR0

# Test parser
PARSER_OUTPUT=$(python3 -c "
import sys
sys.path.insert(0, '$SERVER_DIR')
from parser import parse_session, list_sessions, is_valid_session

# Test is_valid_session
assert is_valid_session('$MOCK_SESSION'), 'should be valid session'

# Test parse_session
s = parse_session('$MOCK_SESSION')
assert s['id'] == '2026-01-01_12-00-00', f'id mismatch: {s[\"id\"]}'
assert s['status'] == 'active', f'status: {s[\"status\"]}'
assert s['current_round'] == 2, f'round: {s[\"current_round\"]}'
assert s['max_iterations'] == 42
assert s['plan_file'] == 'plan.md'
assert s['start_branch'] == 'main'
assert s['codex_model'] == 'gpt-5.4'

# Rounds: should have 3 (0, 1, 2) even though round 2 has no summary
assert len(s['rounds']) == 3, f'expected 3 rounds, got {len(s[\"rounds\"])}'
assert s['rounds'][0]['number'] == 0
assert s['rounds'][2]['number'] == 2

# Round 0 should have summary content
r0_summary = s['rounds'][0]['summary']
assert r0_summary is not None and (isinstance(r0_summary, dict) or isinstance(r0_summary, str)), 'round 0 should have summary'

# Round 2 should have null summary (no file)
r2_summary = s['rounds'][2]['summary']
if isinstance(r2_summary, dict):
    assert r2_summary.get('en') is None and r2_summary.get('zh') is None, 'round 2 summary should be null'

# Verdict from review
assert s['rounds'][0]['verdict'] == 'advanced', f'verdict: {s[\"rounds\"][0][\"verdict\"]}'

# Goal tracker
gt = s['goal_tracker']
assert gt is not None
assert len(gt['acceptance_criteria']) == 2
assert gt['acceptance_criteria'][0]['id'] == 'AC-1'

# Completed and Verified parsing
assert len(gt['completed_verified']) == 1
assert gt['completed_verified'][0]['ac'] == 'AC-1'

# AC status from completed table
assert any(ac['status'] == 'completed' for ac in gt['acceptance_criteria']), 'AC-1 should be completed'

# Task counts
assert s['tasks_total'] == 3, f'tasks_total: {s[\"tasks_total\"]}'  # 2 active + 1 completed
assert s['tasks_done'] == 1, f'tasks_done: {s[\"tasks_done\"]}'

# Test list_sessions
sessions = list_sessions('$MOCK_PROJECT')
assert len(sessions) == 1
assert sessions[0]['id'] == '2026-01-01_12-00-00'

print('ALL_PARSER_TESTS_PASSED')
" 2>&1)

if echo "$PARSER_OUTPUT" | grep -q "ALL_PARSER_TESTS_PASSED"; then
    pass "Parser: parse_session with full mock data"
    pass "Parser: canonical round indices (0..current_round)"
    pass "Parser: goal tracker with Completed and Verified"
    pass "Parser: list_sessions"
    pass "Parser: is_valid_session"
else
    fail "Parser tests" "" "$PARSER_OUTPUT"
fi

# Test malformed session skip
MALFORMED_SESSION="$MOCK_PROJECT/.humanize/rlcr/2026-01-01_13-00-00"
mkdir -p "$MALFORMED_SESSION"
echo "garbage" > "$MALFORMED_SESSION/readme.txt"

SKIP_OUTPUT=$(python3 -c "
import sys
sys.path.insert(0, '$SERVER_DIR')
from parser import is_valid_session
assert not is_valid_session('$MALFORMED_SESSION'), 'should not be valid'
print('SKIP_OK')
" 2>&1)

if echo "$SKIP_OUTPUT" | grep -q "SKIP_OK"; then
    pass "Parser: skips malformed session (no state.md)"
else
    fail "Parser: malformed session skip" "" "$SKIP_OUTPUT"
fi

# ========================================
# Test Group 4: Analyzer Tests
# ========================================
echo ""
echo "Test Group 4: Analyzer"

cd "$PLUGIN_ROOT"
ANALYZER_OUTPUT=$(python3 -c "
import sys
sys.path.insert(0, '$SERVER_DIR')
from analyzer import compute_analytics

# Empty
result = compute_analytics([])
assert result['overview']['total_sessions'] == 0
assert result['overview']['completion_rate'] == 0

# With mock session
mock = {
    'id': '2026-01-01_12-00-00',
    'current_round': 3,
    'status': 'complete',
    'ac_done': 2, 'ac_total': 4,
    'rounds': [
        {'number': 0, 'verdict': 'advanced', 'review_result': 'some review', 'bitlesson_delta': 'add', 'phase': 'implementation', 'p_issues': {}, 'duration_minutes': 10},
        {'number': 1, 'verdict': 'advanced', 'review_result': 'review 2', 'bitlesson_delta': 'none', 'phase': 'implementation', 'p_issues': {'P1': 1}, 'duration_minutes': 15},
        {'number': 2, 'verdict': 'complete', 'review_result': 'final', 'bitlesson_delta': 'none', 'phase': 'code_review', 'p_issues': {}, 'duration_minutes': 5},
    ]
}
result = compute_analytics([mock])
assert result['overview']['total_sessions'] == 1
assert result['overview']['completed_sessions'] == 1
assert result['overview']['completion_rate'] == 100.0

# Verdict distribution should not include rounds without review_result
vd = result['verdict_distribution']
assert 'advanced' in vd
assert vd['advanced'] == 2
assert vd.get('unknown', 0) == 0, 'unknown should not appear for reviewed rounds'

print('ANALYZER_OK')
" 2>&1)

if echo "$ANALYZER_OUTPUT" | grep -q "ANALYZER_OK"; then
    pass "Analyzer: empty sessions"
    pass "Analyzer: basic statistics"
    pass "Analyzer: verdict distribution excludes non-reviewed rounds"
else
    fail "Analyzer tests" "" "$ANALYZER_OUTPUT"
fi

# ========================================
# Test Group 5: Exporter Tests
# ========================================
echo ""
echo "Test Group 5: Exporter"

EXPORTER_OUTPUT=$(python3 -c "
import sys
sys.path.insert(0, '$SERVER_DIR')
from exporter import export_session_markdown

mock = {
    'id': '2026-01-01_12-00-00',
    'status': 'complete',
    'current_round': 2,
    'plan_file': 'plan.md',
    'start_branch': 'main',
    'started_at': '2026-01-01T12:00:00Z',
    'codex_model': 'gpt-5.4',
    'last_verdict': 'advanced',
    'ac_total': 2, 'ac_done': 2,
    'rounds': [
        {'number': 0, 'phase': 'implementation', 'verdict': 'unknown', 'duration_minutes': None,
         'bitlesson_delta': 'none', 'summary': {'en': '# Round 0', 'zh': None}, 'review_result': {'en': None, 'zh': None}},
        {'number': 1, 'phase': 'implementation', 'verdict': 'advanced', 'duration_minutes': 15.0,
         'bitlesson_delta': 'add', 'summary': {'en': '# Round 1 done', 'zh': None}, 'review_result': {'en': 'ADVANCED', 'zh': None}},
    ],
    'goal_tracker': {
        'ultimate_goal': 'Test goal',
        'acceptance_criteria': [
            {'id': 'AC-1', 'description': 'First', 'status': 'completed'},
            {'id': 'AC-2', 'description': 'Second', 'status': 'completed'},
        ]
    },
    'methodology_report': {'en': '# Report', 'zh': None},
}

md = export_session_markdown(mock)
assert 'RLCR Session Report' in md
assert '2026-01-01_12-00-00' in md
assert 'Round 0' in md
assert 'Round 1 done' in md
assert 'AC-1' in md
assert '# Report' in md
assert isinstance(md, str), 'output must be string, not dict'

print('EXPORTER_OK')
" 2>&1)

if echo "$EXPORTER_OUTPUT" | grep -q "EXPORTER_OK"; then
    pass "Exporter: generates valid Markdown from bilingual session"
    pass "Exporter: handles {zh,en} dicts without TypeError"
else
    fail "Exporter tests" "" "$EXPORTER_OUTPUT"
fi

# ========================================
# Test Group 6: Integration Markers
# ========================================
# The early viz plan auto-started a tmux-backed viz daemon whenever
# an RLCR loop ran, threaded through VIZ_AVAILABLE / VIZ_PROJECT
# env markers and viz-stop.sh cleanup hooks in setup-rlcr-loop.sh /
# cancel-rlcr-loop.sh / commands/start-rlcr-loop.md. That auto-
# start path was deprecated in favor of the explicit CLI entry
# point `humanize monitor web --project <path>` (Round 7), which
# runs the Flask server in the foreground. The RLCR setup/cancel
# scripts no longer need to know about the dashboard — it is now a
# separate terminal the user launches when they want it.
#
# Integration assertions therefore only check that the viz-start
# and viz-stop helpers still exist as importable scripts for the
# opt-in `--daemon` path; they no longer require the setup /
# cancel scripts to reference them.
echo ""
echo "Test Group 6: Integration Markers (opt-in --daemon path)"

for helper in viz-start.sh viz-stop.sh viz-status.sh; do
    if [[ -x "$PLUGIN_ROOT/viz/scripts/$helper" ]]; then
        pass "viz helper is present and executable: $helper"
    else
        fail "viz helper missing: $helper"
    fi
done

# ========================================
# Test Group 7: humanize monitor web migration
# ========================================
# The legacy /humanize:viz Claude command and skill have been removed.
# The web dashboard is now reached via the `humanize monitor web`
# subcommand in scripts/humanize.sh. Tests assert both states.
echo ""
echo "Test Group 7: humanize monitor web (replaces /humanize:viz)"

if [[ ! -f "$PLUGIN_ROOT/commands/viz.md" ]]; then
    pass "Legacy /humanize:viz command file is removed"
else
    fail "commands/viz.md still exists (should be deleted)"
fi

if [[ ! -d "$PLUGIN_ROOT/skills/humanize-viz" ]]; then
    pass "Legacy humanize-viz skill directory is removed"
else
    fail "skills/humanize-viz/ still exists (should be deleted)"
fi

if grep -q '_humanize_monitor_web' "$PLUGIN_ROOT/scripts/humanize.sh"; then
    pass "scripts/humanize.sh defines _humanize_monitor_web function"
else
    fail "scripts/humanize.sh missing _humanize_monitor_web function"
fi

if grep -q 'web)' "$PLUGIN_ROOT/scripts/humanize.sh" && \
   grep -q 'monitor web' "$PLUGIN_ROOT/scripts/humanize.sh"; then
    pass "humanize monitor dispatch includes 'web' subcommand"
else
    fail "humanize monitor dispatch missing 'web' subcommand"
fi

if ! grep -q '/humanize:viz' "$PLUGIN_ROOT/commands/start-rlcr-loop.md"; then
    pass "commands/start-rlcr-loop.md no longer references /humanize:viz"
else
    fail "commands/start-rlcr-loop.md still references /humanize:viz"
fi

if grep -q 'humanize monitor web' "$PLUGIN_ROOT/README.md"; then
    pass "README.md documents humanize monitor web"
else
    fail "README.md missing humanize monitor web reference"
fi

# Round 18 P2: foreground port probe must branch on --host (same
# shape as viz-start.sh find_port) so --host <specific-ip> doesn't
# pick a port that is in use on the external interface.
humanize_sh="$PLUGIN_ROOT/scripts/humanize.sh"
if grep -qE 'probe_host=.*"localhost"' "$humanize_sh" && \
   grep -qE 'probe_host="\$host"' "$humanize_sh"; then
    pass "humanize.sh foreground monitor-web path branches probe_host on --host (P2 Round 18)"
else
    fail "humanize.sh foreground monitor-web path still probes localhost only"
fi

if grep -qE '/dev/tcp/\$probe_host/\$candidate' "$humanize_sh"; then
    pass "humanize.sh foreground port loop uses \$probe_host (no literal localhost)"
else
    fail "humanize.sh foreground port loop still uses /dev/tcp/localhost/\$candidate literal"
fi

# ========================================
# Test Group 8: Static Assets
# ========================================
echo ""
echo "Test Group 8: Static Assets"

for file in index.html css/theme.css css/layout.css js/app.js js/pipeline.js js/charts.js js/actions.js js/i18n.js; do
    if [[ -f "$VIZ_DIR/static/$file" ]]; then
        pass "Static file exists: $file"
    else
        fail "Static file missing: $file"
    fi
done

# Verify no hard-coded Chinese in i18n.js (UI should be English-only)
if ! grep -P '[\x{4e00}-\x{9fff}]' "$VIZ_DIR/static/js/i18n.js" >/dev/null 2>&1; then
    pass "i18n.js contains no Chinese characters (English-only UI)"
else
    fail "i18n.js should not contain Chinese characters"
fi

# Requirements file
if [[ -f "$VIZ_DIR/server/requirements.txt" ]]; then
    pass "Python requirements.txt exists"
    if grep -q "flask" "$VIZ_DIR/server/requirements.txt"; then
        pass "requirements.txt includes flask"
    else
        fail "requirements.txt missing flask"
    fi
else
    fail "Python requirements.txt missing"
fi

# ========================================
# Summary
# ========================================

print_test_summary "Humanize Viz Tests"
