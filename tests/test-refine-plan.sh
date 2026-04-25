#!/usr/bin/env bash
#
# Test script for refine-plan command structure, validator behavior, QA template coverage,
# and AC-7 installation wiring coverage
#
# Validates:
# - commands/refine-plan.md frontmatter and workflow requirements
# - validate-refine-plan-io.sh exit codes 0-7 and mode handling
# - Comment extraction/classification requirements documented by the command
# - Language variant and atomic write requirements
# - AC-7 installation/documentation wiring for humanize-refine-plan
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMANDS_DIR="$PROJECT_ROOT/commands"
PROMPT_TEMPLATE_DIR="$PROJECT_ROOT/prompt-template/plan"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"
SKILLS_DIR="$PROJECT_ROOT/skills"
DOCS_DIR="$PROJECT_ROOT/docs"
CLAUDE_PLUGIN_DIR="$PROJECT_ROOT/.claude-plugin"

REFINE_PLAN_CMD="$COMMANDS_DIR/refine-plan.md"
REFINE_PLAN_QA_TEMPLATE="$PROMPT_TEMPLATE_DIR/refine-plan-qa-template.md"
VALIDATE_SCRIPT="$SCRIPTS_DIR/validate-refine-plan-io.sh"
REFINE_PLAN_SKILL="$SKILLS_DIR/humanize-refine-plan/SKILL.md"
INSTALL_SKILL_SCRIPT="$SCRIPTS_DIR/install-skill.sh"
CLAUDE_INSTALL_DOC="$DOCS_DIR/install-for-claude.md"
CODEX_INSTALL_DOC="$DOCS_DIR/install-for-codex.md"
KIMI_INSTALL_DOC="$DOCS_DIR/install-for-kimi.md"
PLUGIN_JSON="$CLAUDE_PLUGIN_DIR/plugin.json"
MARKETPLACE_JSON="$CLAUDE_PLUGIN_DIR/marketplace.json"
README_FILE="$PROJECT_ROOT/README.md"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

# Test helper functions
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

assert_file_contains() {
    local file="$1"
    local needle="$2"
    local description="$3"

    if grep -qF -- "$needle" "$file"; then
        pass "$description"
    else
        fail "$description" "$needle" "missing"
    fi
}

assert_file_contains_regex() {
    local file="$1"
    local pattern="$2"
    local description="$3"

    if grep -Eq -- "$pattern" "$file"; then
        pass "$description"
    else
        fail "$description" "$pattern" "missing"
    fi
}

assert_line_order() {
    local file="$1"
    local first="$2"
    local second="$3"
    local description="$4"
    local first_line=""
    local second_line=""

    first_line=$(grep -nF -- "$first" "$file" | head -1 | cut -d: -f1 || true)
    second_line=$(grep -nF -- "$second" "$file" | head -1 | cut -d: -f1 || true)

    if [[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]]; then
        pass "$description"
    else
        fail "$description" "line('$first') < line('$second')" "first=$first_line second=$second_line"
    fi
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local description="$3"

    if [[ "$actual" == "$expected" ]]; then
        pass "$description"
    else
        fail "$description" "$expected" "$actual"
    fi
}

frontmatter_value() {
    local file="$1"
    local key="$2"
    sed -n "/^---$/,/^---$/{ /^${key}:[[:space:]]*/{ s/^${key}:[[:space:]]*//p; q; } }" "$file"
}

json_first_string_value() {
    local file="$1"
    local key="$2"
    sed -n "s/^[[:space:]]*\"${key}\":[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$file" | head -1
}

readme_current_version() {
    local file="$1"
    sed -n 's/^\*\*Current Version:[[:space:]]*\([^*][^*]*\)\*\*$/\1/p' "$file" | head -1
}

trim_string() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

collapse_whitespace() {
    printf '%s' "$1" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

VALIDATOR_OUTPUT=""
VALIDATOR_EXIT_CODE=0

run_validator_capture() {
    local output_file="$TEST_FIXTURES_DIR/validator-output.txt"
    VALIDATOR_EXIT_CODE=0
    if "$VALIDATE_SCRIPT" "$@" >"$output_file" 2>&1; then
        VALIDATOR_EXIT_CODE=0
    else
        VALIDATOR_EXIT_CODE=$?
    fi
    VALIDATOR_OUTPUT="$(<"$output_file")"
}

make_valid_annotated_plan() {
    local output_file="$1"
    cat > "$output_file" <<'EOF'
# Refine Plan Fixture

## Goal Description
Refine the generated plan while keeping plan-only scope. CMT: clarify the scope boundary ENDCMT

## Acceptance Criteria
- AC-1: A refined plan is produced.

## Path Boundaries
Keep refinement inside plan artifacts only.

## Feasibility Hints and Suggestions
Reuse config-loader semantics and keep writes atomic.

## Dependencies and Sequence
1. Validate
2. Extract comments
3. Write outputs

## Task Breakdown
| Task ID | AC | Tag | Depends |
|---------|----|-----|---------|
| task1 | AC-1 | coding | - |

## Claude-Codex Deliberation
### Convergence Status
partially_converged

## Pending User Decisions
None.

## Implementation Notes
Remove all reviewer comments from the refined plan.
EOF
}

make_plan_without_comments() {
    local output_file="$1"
    cat > "$output_file" <<'EOF'
# Refine Plan Fixture

## Goal Description
Refine the generated plan while keeping plan-only scope.

## Acceptance Criteria
- AC-1: A refined plan is produced.

## Path Boundaries
Keep refinement inside plan artifacts only.

## Feasibility Hints and Suggestions
Reuse config-loader semantics and keep writes atomic.

## Dependencies and Sequence
1. Validate
2. Extract comments
3. Write outputs

## Task Breakdown
| Task ID | AC | Tag | Depends |
|---------|----|-----|---------|
| task1 | AC-1 | coding | - |

## Claude-Codex Deliberation
### Convergence Status
partially_converged

## Pending User Decisions
None.

## Implementation Notes
Remove all reviewer comments from the refined plan.
EOF
}

make_plan_with_goal_body() {
    local output_file="$1"
    local goal_body="$2"
    cat > "$output_file" <<EOF
# Refine Plan Fixture

## Goal Description
$goal_body

## Acceptance Criteria
- AC-1: A refined plan is produced.

## Path Boundaries
Keep refinement inside plan artifacts only.

## Feasibility Hints and Suggestions
Reuse config-loader semantics and keep writes atomic.

## Dependencies and Sequence
1. Validate
2. Extract comments
3. Write outputs

## Task Breakdown
| Task ID | AC | Tag | Depends |
|---------|----|-----|---------|
| task1 | AC-1 | coding | - |

## Claude-Codex Deliberation
### Convergence Status
partially_converged

## Pending User Decisions
None.

## Implementation Notes
Remove all reviewer comments from the refined plan.
EOF
}

make_plan_missing_sections() {
    local output_file="$1"
    cat > "$output_file" <<'EOF'
# Refine Plan Fixture

## Goal Description
Refine the generated plan. CMT: clarify the scope boundary ENDCMT

## Acceptance Criteria
- AC-1: A refined plan is produced.

## Implementation Notes
This file intentionally omits required sections.
EOF
}

make_plan_with_sections_only_in_fence() {
    local output_file="$1"
    cat > "$output_file" <<'EOF'
# Refine Plan Fixture

CMT: keep the validator path reachable ENDCMT

```markdown
## Goal Description
Hidden inside a code fence.

## Acceptance Criteria
- AC-1: Hidden inside a code fence.

## Path Boundaries
Hidden inside a code fence.

## Feasibility Hints and Suggestions
Hidden inside a code fence.

## Dependencies and Sequence
1. Hidden inside a code fence.

## Task Breakdown
| Task ID | AC | Tag | Depends |
|---------|----|-----|---------|
| hidden | AC-1 | coding | - |

## Claude-Codex Deliberation
### Convergence Status
partially_converged

## Pending User Decisions
Hidden inside a code fence.

## Implementation Notes
Hidden inside a code fence.
```
EOF
}

make_plan_with_sections_only_in_html_comment() {
    local output_file="$1"
    cat > "$output_file" <<'EOF'
# Refine Plan Fixture

CMT: keep the validator path reachable ENDCMT

<!--
## Goal Description
Hidden inside an HTML comment.

## Acceptance Criteria
- AC-1: Hidden inside an HTML comment.

## Path Boundaries
Hidden inside an HTML comment.

## Feasibility Hints and Suggestions
Hidden inside an HTML comment.

## Dependencies and Sequence
1. Hidden inside an HTML comment.

## Task Breakdown
| Task ID | AC | Tag | Depends |
|---------|----|-----|---------|
| hidden | AC-1 | coding | - |

## Claude-Codex Deliberation
### Convergence Status
partially_converged

## Pending User Decisions
Hidden inside an HTML comment.

## Implementation Notes
Hidden inside an HTML comment.
-->
EOF
}

make_plan_with_real_and_ignored_sections() {
    local output_file="$1"
    cat > "$output_file" <<'EOF'
# Refine Plan Fixture

<!--
## Goal Description
Ignored duplicate heading inside HTML comment.
-->

```markdown
## Acceptance Criteria
- AC-1: Ignored duplicate heading inside code fence.
```

## Goal Description
Refine the generated plan while keeping plan-only scope. CMT: clarify the scope boundary ENDCMT

## Acceptance Criteria
- AC-1: A refined plan is produced.

## Path Boundaries
Keep refinement inside plan artifacts only.

## Feasibility Hints and Suggestions
Reuse config-loader semantics and keep writes atomic.

## Dependencies and Sequence
1. Validate
2. Extract comments
3. Write outputs

## Task Breakdown
| Task ID | AC | Tag | Depends |
|---------|----|-----|---------|
| task1 | AC-1 | coding | - |

## Claude-Codex Deliberation
### Convergence Status
partially_converged

## Pending User Decisions
None.

## Implementation Notes
Remove all reviewer comments from the refined plan.
EOF
}

REFERENCE_COMMENT_COUNT=0
REFERENCE_CLEANED_PLAN=""

scan_reference_comments() {
    local input_file="$1"
    local line=""
    local working=""
    local before=""
    local after=""
    local comment=""
    local in_fence=""
    local in_html=0
    local in_cmt=0

    REFERENCE_COMMENT_COUNT=0
    REFERENCE_CLEANED_PLAN=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -n "$in_fence" ]]; then
            REFERENCE_CLEANED_PLAN+="$line"$'\n'
            if [[ "$in_fence" == '```' && "$line" =~ ^[[:space:]]*\`\`\` ]] || [[ "$in_fence" == '~~~' && "$line" =~ ^[[:space:]]*~~~ ]]; then
                in_fence=""
            fi
            continue
        fi

        working="$line"

        while :; do
            if [[ $in_html -eq 1 ]]; then
                if [[ "$working" == *"-->"* ]]; then
                    working="${working#*-->}"
                    in_html=0
                    continue
                fi
                working=""
                break
            fi

            if [[ $in_cmt -eq 1 ]]; then
                if [[ "$working" == *"ENDCMT"* ]]; then
                    before="${working%%ENDCMT*}"
                    comment+="$before"
                    if [[ -n "$(trim_string "$comment")" ]]; then
                        REFERENCE_COMMENT_COUNT=$((REFERENCE_COMMENT_COUNT + 1))
                    fi
                    working="${working#*ENDCMT}"
                    comment=""
                    in_cmt=0
                    continue
                fi
                comment+="$working"$'\n'
                working=""
                break
            fi

            if [[ "$working" =~ ^[[:space:]]*\`\`\` ]]; then
                REFERENCE_CLEANED_PLAN+="$working"$'\n'
                in_fence='```'
                working=""
                break
            fi

            if [[ "$working" =~ ^[[:space:]]*~~~ ]]; then
                REFERENCE_CLEANED_PLAN+="$working"$'\n'
                in_fence='~~~'
                working=""
                break
            fi

            if [[ "$working" == *"<!--"* ]]; then
                before="${working%%<!--*}"
                after="${working#*<!--}"
                if [[ "$after" == *"-->"* ]]; then
                    working="${before}${after#*-->}"
                    continue
                fi
                working="$before"
                in_html=1
            fi

            if [[ "$working" == *"CMT:"* ]]; then
                before="${working%%CMT:*}"
                after="${working#*CMT:}"
                REFERENCE_CLEANED_PLAN+="$before"
                if [[ "$after" == *"ENDCMT"* ]]; then
                    comment="${after%%ENDCMT*}"
                    if [[ -n "$(trim_string "$comment")" ]]; then
                        REFERENCE_COMMENT_COUNT=$((REFERENCE_COMMENT_COUNT + 1))
                    fi
                    working="${after#*ENDCMT}"
                    comment=""
                    continue
                fi
                comment="$after"$'\n'
                in_cmt=1
                working=""
                break
            fi

            REFERENCE_CLEANED_PLAN+="$working"
            break
        done

        REFERENCE_CLEANED_PLAN+=$'\n'
    done < "$input_file"
}

comment_matches_question() {
    local text="${1,,}"
    [[ "$text" == *"why"* || "$text" == *"how"* || "$text" == *"what"* || "$text" == *"explain"* || "$text" == *"clarify"* || "$text" == *"unclear"* ]]
}

comment_matches_change_request() {
    local text="${1,,}"
    [[ "$text" == *"add"* || "$text" == *"remove"* || "$text" == *"delete"* || "$text" == *"rewrite"* || "$text" == *"restore"* || "$text" == *"rename"* || "$text" == *"split"* || "$text" == *"merge"* || "$text" == *"modify"* ]]
}

comment_matches_research_request() {
    local text="${1,,}"
    [[ "$text" == *"investigate"* || "$text" == *"compare"* || "$text" == *"confirm"* || "$text" == *"current behavior"* || "$text" == *"gather evidence"* || "$text" == *"before deciding"* ]]
}

dominant_classification() {
    local text="$1"
    if comment_matches_research_request "$text"; then
        echo "research_request"
    elif comment_matches_change_request "$text"; then
        echo "change_request"
    elif comment_matches_question "$text"; then
        echo "question"
    else
        echo "ambiguous"
    fi
}

normalize_alt_language() {
    local raw
    local lower
    raw="$(trim_string "$1")"
    lower="${raw,,}"

    case "$lower" in
        chinese|zh) echo "Chinese|zh|variant" ;;
        korean|ko) echo "Korean|ko|variant" ;;
        japanese|ja) echo "Japanese|ja|variant" ;;
        spanish|es) echo "Spanish|es|variant" ;;
        french|fr) echo "French|fr|variant" ;;
        german|de) echo "German|de|variant" ;;
        portuguese|pt) echo "Portuguese|pt|variant" ;;
        russian|ru) echo "Russian|ru|variant" ;;
        arabic|ar) echo "Arabic|ar|variant" ;;
        english|en) echo "English|en|noop" ;;
        "") echo "||none" ;;
        *) echo "unsupported||unsupported" ;;
    esac
}

variant_path_for() {
    local path="$1"
    local code="$2"
    local dir=""
    local base=""
    local stem=""
    local ext=""

    dir="$(dirname "$path")"
    base="$(basename "$path")"

    if [[ "$base" == *.* ]]; then
        stem="${base%.*}"
        ext="${base##*.}"
        base="${stem}_${code}.${ext}"
    else
        base="${base}_${code}"
    fi

    if [[ "$dir" == "." ]]; then
        printf '%s\n' "$base"
    else
        printf '%s/%s\n' "$dir" "$base"
    fi
}

qa_path_for_input() {
    local input_path="$1"
    local qa_dir="$2"
    local base=""
    local stem=""

    base="$(basename "$input_path")"
    if [[ "$base" == *.* ]]; then
        stem="${base%.*}"
    else
        stem="$base"
    fi

    printf '%s/%s-qa.md\n' "$qa_dir" "$stem"
}

TEST_FIXTURES_DIR="$(mktemp -d)"
trap 'chmod -R u+w "$TEST_FIXTURES_DIR" 2>/dev/null || true; rm -rf "$TEST_FIXTURES_DIR"' EXIT

echo "========================================"
echo "Testing refine-plan Command Structure"
echo "========================================"
echo ""

# ========================================
# Positive Tests - Command/Template Coverage
# ========================================
echo "========================================"
echo "Positive Tests - Must Pass"
echo "========================================"

echo ""
echo "PT-1: Core files exist"
if [[ -f "$REFINE_PLAN_CMD" ]]; then
    pass "refine-plan.md command file exists"
else
    fail "refine-plan.md command file exists" "File exists" "File not found"
fi

if [[ -f "$REFINE_PLAN_QA_TEMPLATE" ]]; then
    pass "refine-plan QA template exists"
else
    fail "refine-plan QA template exists" "File exists" "File not found"
fi

if [[ -x "$VALIDATE_SCRIPT" ]]; then
    pass "validate-refine-plan-io.sh exists and is executable"
else
    fail "validate-refine-plan-io.sh exists and is executable" "Executable file" "Missing or not executable"
fi

echo ""
echo "PT-2: Frontmatter and command metadata"
if [[ -f "$REFINE_PLAN_CMD" ]]; then
    DESCRIPTION=$(frontmatter_value "$REFINE_PLAN_CMD" "description")
    if [[ -n "$DESCRIPTION" ]]; then
        pass "refine-plan.md has a non-empty description"
    else
        fail "refine-plan.md has a non-empty description" "Non-empty description" "(empty)"
    fi

    assert_file_contains "$REFINE_PLAN_CMD" 'argument-hint: "--input <path/to/annotated-plan.md> [--output <path/to/refined-plan.md>] [--qa-dir <path/to/qa-dir>] [--alt-language <language-or-code>] [--discussion|--direct]"' "refine-plan.md exposes expected argument hint"
    assert_file_contains "$REFINE_PLAN_CMD" '"Bash(${CLAUDE_PLUGIN_ROOT}/scripts/validate-refine-plan-io.sh:*)"' "refine-plan.md allowlist includes validate-refine-plan-io.sh"
    assert_file_contains "$REFINE_PLAN_CMD" '"AskUserQuestion"' "refine-plan.md allows AskUserQuestion for discussion mode"
    assert_file_contains "$REFINE_PLAN_CMD" 'hide-from-slash-command-tool: "true"' "refine-plan.md is hidden from slash command tool"
    assert_file_contains "$REFINE_PLAN_CMD" "Read and execute below with ultrathink." "refine-plan.md requires ultrathink execution mode"
fi

echo ""
echo "PT-3: Planning-only and workflow constraints"
assert_file_contains "$REFINE_PLAN_CMD" "## Hard Constraint: Planning-Only Refinement" "refine-plan.md declares planning-only hard constraint"
assert_file_contains "$REFINE_PLAN_CMD" "This command MUST ONLY refine plan artifacts." "refine-plan.md forbids repository implementation work"
assert_file_contains "$REFINE_PLAN_CMD" "**Sequential Execution Constraint**" "refine-plan.md documents sequential execution constraint"
assert_file_contains "$REFINE_PLAN_CMD" "Do NOT parallelize work across phases." "refine-plan.md forbids phase parallelism"

PHASES=(
    "## Phase 0: Execution Mode Setup"
    "## Phase 0.5: Load Project Config"
    "## Phase 1: IO Validation"
    "## Phase 2: Comment Extraction"
    "## Phase 3: Comment Classification"
    "## Phase 4: Comment Processing"
    "## Phase 5: Generate Refined Plan"
    "## Phase 6: Generate QA Document"
    "## Phase 7: Atomic Write Transaction"
)

for phase in "${PHASES[@]}"; do
    assert_file_contains "$REFINE_PLAN_CMD" "$phase" "refine-plan.md includes phase heading: $phase"
done

assert_line_order "$REFINE_PLAN_CMD" "## Phase 2: Comment Extraction" "## Phase 3: Comment Classification" "comment extraction phase appears before classification phase"
assert_line_order "$REFINE_PLAN_CMD" "## Phase 3: Comment Classification" "## Phase 4: Comment Processing" "classification phase appears before processing phase"
assert_line_order "$REFINE_PLAN_CMD" "## Phase 6: Generate QA Document" "## Phase 7: Atomic Write Transaction" "QA generation appears before atomic write phase"

echo ""
echo "PT-4: IO validation flow and exit handling"
assert_file_contains "$REFINE_PLAN_CMD" 'Keep `--alt-language` out of the validator invocation' "refine-plan.md excludes --alt-language from validator invocation"
assert_file_contains "$REFINE_PLAN_CMD" "- Exit code 0: Continue to Phase 2" "refine-plan.md documents validator exit code 0"
assert_file_contains "$REFINE_PLAN_CMD" '- Exit code 1: Report `Input file not found` and stop' "refine-plan.md documents validator exit code 1"
assert_file_contains "$REFINE_PLAN_CMD" '- Exit code 2: Report `Input file is empty` and stop' "refine-plan.md documents validator exit code 2"
assert_file_contains "$REFINE_PLAN_CMD" '- Exit code 3: Report `Input file has no comment blocks` and stop' "refine-plan.md documents validator exit code 3"
assert_file_contains "$REFINE_PLAN_CMD" '- Exit code 4: Report `Input file is missing required gen-plan sections` and stop' "refine-plan.md documents validator exit code 4"
assert_file_contains "$REFINE_PLAN_CMD" '- Exit code 5: Report `Output directory does not exist or is not writable - please fix it` and stop' "refine-plan.md documents validator exit code 5"
assert_file_contains "$REFINE_PLAN_CMD" '- Exit code 6: Report `QA directory is not writable` and stop' "refine-plan.md documents validator exit code 6"
assert_file_contains "$REFINE_PLAN_CMD" '- Exit code 7: Report `Invalid arguments` and show the validator usage, then stop' "refine-plan.md documents validator exit code 7"

echo ""
echo "PT-5: Comment extraction requirements"
assert_file_contains "$REFINE_PLAN_CMD" "Support both inline and multi-line blocks for all formats:" "refine-plan.md supports inline and multiline comment extraction"
assert_file_contains "$REFINE_PLAN_CMD" 'Inline: `Text before CMT: comment text ENDCMT text after`' "refine-plan.md documents single-line comment extraction"
assert_file_contains "$REFINE_PLAN_CMD" "CMT:" "refine-plan.md includes multiline comment marker example"
assert_file_contains "$REFINE_PLAN_CMD" 'Ignore comment markers inside fenced code blocks.' "refine-plan.md documents code fence exclusion"
assert_file_contains "$REFINE_PLAN_CMD" 'Ignore comment markers inside HTML comments.' "refine-plan.md documents HTML comment exclusion"
assert_file_contains "$REFINE_PLAN_CMD" "Preserve surrounding non-comment text when removing inline comment blocks from the working plan text." "refine-plan.md preserves inline surrounding text"
assert_file_contains "$REFINE_PLAN_CMD" '- `nearest_heading` or `Preamble` when no heading exists yet' "refine-plan.md records nearest heading or Preamble"
assert_file_contains "$REFINE_PLAN_CMD" '- `location_label` for QA output' "refine-plan.md records location labels"
assert_file_contains "$REFINE_PLAN_CMD" '- `form` = `inline` or `multiline`' "refine-plan.md records comment form"
assert_file_contains "$REFINE_PLAN_CMD" '- `context_excerpt` from the nearest non-comment source text' "refine-plan.md records context excerpts"
assert_file_contains "$REFINE_PLAN_CMD" 'Nested comment start marker while already inside a comment block' "refine-plan.md documents nested CMT parse errors"
assert_file_contains "$REFINE_PLAN_CMD" 'Comment end marker encountered while not inside a comment block or wrong end marker for the format' "refine-plan.md documents stray ENDCMT parse errors"
assert_file_contains "$REFINE_PLAN_CMD" "End of file reached while still inside a comment block" "refine-plan.md documents missing ENDCMT parse errors"
assert_file_contains "$REFINE_PLAN_CMD" "No non-empty CMT blocks remain after parsing" "refine-plan.md rejects empty-only comment sets"

echo ""
echo "PT-6: Comment classification requirements"
assert_file_contains "$REFINE_PLAN_CMD" '- `question`' "refine-plan.md includes question classification"
assert_file_contains "$REFINE_PLAN_CMD" '- `change_request`' "refine-plan.md includes change_request classification"
assert_file_contains "$REFINE_PLAN_CMD" '- `research_request`' "refine-plan.md includes research_request classification"
assert_file_contains "$REFINE_PLAN_CMD" '- `question`: asks why, how, what, explain, clarify, or says the plan is unclear' "refine-plan.md documents question heuristics"
assert_file_contains "$REFINE_PLAN_CMD" '- `change_request`: asks to add, remove, delete, rewrite, restore, rename, split, merge, or otherwise modify the plan' "refine-plan.md documents change_request heuristics"
assert_file_contains "$REFINE_PLAN_CMD" '- `research_request`: asks to investigate the repository, compare existing patterns, confirm current behavior, or gather evidence before deciding' "refine-plan.md documents research_request heuristics"
assert_file_contains "$REFINE_PLAN_CMD" 'Create deterministic processing sub-items in textual order: `CMT-N.1`, `CMT-N.2`, ...' "refine-plan.md splits multi-intent comments into sub-items"
assert_file_contains "$REFINE_PLAN_CMD" '- `research_request`' "refine-plan.md includes dominant classification precedence values"
assert_file_contains "$REFINE_PLAN_CMD" 'In `discussion` mode: use `AskUserQuestion` to confirm the classification before continuing' "refine-plan.md asks the user to resolve ambiguity in discussion mode"
assert_file_contains "$REFINE_PLAN_CMD" 'In `direct` mode: choose the most action-driving interpretation and record the assumption in the QA document' "refine-plan.md resolves ambiguity heuristically in direct mode"
assert_file_contains "$REFINE_PLAN_CMD" '- `answered`' "refine-plan.md defines answered disposition"
assert_file_contains "$REFINE_PLAN_CMD" '- `applied`' "refine-plan.md defines applied disposition"
assert_file_contains "$REFINE_PLAN_CMD" '- `researched`' "refine-plan.md defines researched disposition"
assert_file_contains "$REFINE_PLAN_CMD" '- `deferred`' "refine-plan.md defines deferred disposition"
assert_file_contains "$REFINE_PLAN_CMD" '- `resolved`' "refine-plan.md defines resolved disposition"

echo ""
echo "PT-7: Refined plan structure and mode rules"
assert_file_contains "$REFINE_PLAN_CMD" 'If omitted, set `OUTPUT_FILE=INPUT_FILE` for in-place mode.' "refine-plan.md defaults output to in-place mode"
assert_file_contains "$REFINE_PLAN_CMD" 'Compute `IN_PLACE_MODE=true` when `OUTPUT_FILE` equals `INPUT_FILE`' "refine-plan.md derives IN_PLACE_MODE"
assert_file_contains "$REFINE_PLAN_CMD" 'Compute `QA_FILE` from the input basename, not the output basename:' "refine-plan.md derives QA file from input basename"
assert_file_contains "$REFINE_PLAN_CMD" 'Do not introduce `--language` or `--qa-output`' "refine-plan.md constrains v1 CLI surface"
assert_file_contains "$REFINE_PLAN_CMD" "- `## Goal Description`" "refine-plan.md preserves Goal Description section"
assert_file_contains "$REFINE_PLAN_CMD" "- `## Acceptance Criteria`" "refine-plan.md preserves Acceptance Criteria section"
assert_file_contains "$REFINE_PLAN_CMD" "- `## Path Boundaries`" "refine-plan.md preserves Path Boundaries section"
assert_file_contains "$REFINE_PLAN_CMD" "- `## Feasibility Hints and Suggestions`" "refine-plan.md preserves Feasibility Hints and Suggestions section"
assert_file_contains "$REFINE_PLAN_CMD" "- `## Dependencies and Sequence`" "refine-plan.md preserves Dependencies and Sequence section"
assert_file_contains "$REFINE_PLAN_CMD" "- `## Task Breakdown`" "refine-plan.md preserves Task Breakdown section"
assert_file_contains "$REFINE_PLAN_CMD" "- `## Claude-Codex Deliberation`" "refine-plan.md preserves Claude-Codex Deliberation section"
assert_file_contains "$REFINE_PLAN_CMD" "- `## Pending User Decisions`" "refine-plan.md preserves Pending User Decisions section"
assert_file_contains "$REFINE_PLAN_CMD" "- `## Implementation Notes`" "refine-plan.md preserves Implementation Notes section"

echo ""
echo "PT-8: Alternative language and filename rules"
assert_file_contains "$REFINE_PLAN_CMD" 'Resolve configuration by following the same precedence and merge semantics defined in `${CLAUDE_PLUGIN_ROOT}/scripts/lib/config-loader.sh`.' "refine-plan.md reuses config-loader merge semantics"
assert_file_contains "$REFINE_PLAN_CMD" '`CONFIG_ALT_LANGUAGE_RAW` from `alternative_plan_language`' "refine-plan.md reads alternative_plan_language from config"
assert_file_contains "$REFINE_PLAN_CMD" 'Do not depend on deprecated `chinese_plan`. `refine-plan` only uses `alternative_plan_language`.' "refine-plan.md ignores deprecated chinese_plan"
assert_file_contains "$REFINE_PLAN_CMD" '1. CLI `--alt-language`' "refine-plan.md prioritizes CLI alt-language"
assert_file_contains "$REFINE_PLAN_CMD" '2. Config `alternative_plan_language`' "refine-plan.md falls back to config alt-language"
assert_file_contains "$REFINE_PLAN_CMD" '3. Treat `English` / `en` as a no-op: no translated variant is generated.' "refine-plan.md treats English as no-op for variants"
assert_file_contains "$REFINE_PLAN_CMD" '4. If the CLI value is unsupported, report `Unsupported --alt-language "<value>"` and stop.' "refine-plan.md rejects unsupported CLI alt-language"
assert_file_contains "$REFINE_PLAN_CMD" "5. If the config value is unsupported, log a warning and disable variant generation." "refine-plan.md warns on unsupported config alt-language"
assert_file_contains_regex "$REFINE_PLAN_CMD" '^\\| Chinese[[:space:]]+\\| zh[[:space:]]+\\| `_zh`[[:space:]]+\\|$' "refine-plan.md includes Chinese language mapping"
assert_file_contains_regex "$REFINE_PLAN_CMD" '^\\| Korean[[:space:]]+\\| ko[[:space:]]+\\| `_ko`[[:space:]]+\\|$' "refine-plan.md includes Korean language mapping"
assert_file_contains_regex "$REFINE_PLAN_CMD" '^\\| Japanese[[:space:]]+\\| ja[[:space:]]+\\| `_ja`[[:space:]]+\\|$' "refine-plan.md includes Japanese language mapping"
assert_file_contains_regex "$REFINE_PLAN_CMD" '^\\| Spanish[[:space:]]+\\| es[[:space:]]+\\| `_es`[[:space:]]+\\|$' "refine-plan.md includes Spanish language mapping"
assert_file_contains_regex "$REFINE_PLAN_CMD" '^\\| French[[:space:]]+\\| fr[[:space:]]+\\| `_fr`[[:space:]]+\\|$' "refine-plan.md includes French language mapping"
assert_file_contains_regex "$REFINE_PLAN_CMD" '^\\| German[[:space:]]+\\| de[[:space:]]+\\| `_de`[[:space:]]+\\|$' "refine-plan.md includes German language mapping"
assert_file_contains_regex "$REFINE_PLAN_CMD" '^\\| Portuguese[[:space:]]+\\| pt[[:space:]]+\\| `_pt`[[:space:]]+\\|$' "refine-plan.md includes Portuguese language mapping"
assert_file_contains_regex "$REFINE_PLAN_CMD" '^\\| Russian[[:space:]]+\\| ru[[:space:]]+\\| `_ru`[[:space:]]+\\|$' "refine-plan.md includes Russian language mapping"
assert_file_contains_regex "$REFINE_PLAN_CMD" '^\\| Arabic[[:space:]]+\\| ar[[:space:]]+\\| `_ar`[[:space:]]+\\|$' "refine-plan.md includes Arabic language mapping"
assert_file_contains "$REFINE_PLAN_CMD" '- `plan.md` -> `plan_zh.md`' "refine-plan.md documents plan variant naming"
assert_file_contains "$REFINE_PLAN_CMD" '- `feature-a-qa.md` -> `feature-a-qa_zh.md`' "refine-plan.md documents QA variant naming"
assert_file_contains "$REFINE_PLAN_CMD" '- `output` -> `output_zh`' "refine-plan.md documents extensionless variant naming"
assert_file_contains "$REFINE_PLAN_CMD" 'If `ALT_PLAN_LANGUAGE` is empty or equals the main language, do not create variant files.' "refine-plan.md skips unnecessary variants"

echo ""
echo "PT-9: Atomic write transaction requirements"
assert_file_contains "$REFINE_PLAN_CMD" "Prepare all final content in memory first:" "refine-plan.md prepares outputs in memory before writing"
assert_file_contains "$REFINE_PLAN_CMD" "Write each output to a temporary file in the same directory as its final destination." "refine-plan.md writes temp files in destination directories"
assert_file_contains "$REFINE_PLAN_CMD" '- `.refine-plan-XXXXXX`' "refine-plan.md defines refine-plan temp filename"
assert_file_contains "$REFINE_PLAN_CMD" '- `.refine-qa-XXXXXX`' "refine-plan.md defines refine-qa temp filename"
assert_file_contains "$REFINE_PLAN_CMD" '- `.refine-plan-variant-XXXXXX`' "refine-plan.md defines refine-plan variant temp filename"
assert_file_contains "$REFINE_PLAN_CMD" '- `.refine-qa-variant-XXXXXX`' "refine-plan.md defines refine-qa variant temp filename"
assert_file_contains "$REFINE_PLAN_CMD" "Delete all temp files" "refine-plan.md deletes temp files on failure"
assert_file_contains "$REFINE_PLAN_CMD" "Leave existing final outputs untouched" "refine-plan.md preserves final outputs on temp write failure"
assert_file_contains "$REFINE_PLAN_CMD" "Replace auxiliary outputs before replacing the main in-place plan file, so the primary plan is updated last." "refine-plan.md updates the main plan last"
assert_file_contains "$REFINE_PLAN_CMD" "No stale temp files remain" "refine-plan.md requires temp cleanup after success"

echo ""
echo "PT-10: QA template coverage"
assert_file_contains "$REFINE_PLAN_QA_TEMPLATE" "# Refine Plan QA" "refine-plan QA template has title"
assert_file_contains "$REFINE_PLAN_QA_TEMPLATE" "## Summary" "refine-plan QA template includes Summary section"
assert_file_contains "$REFINE_PLAN_QA_TEMPLATE" "## Comment Ledger" "refine-plan QA template includes Comment Ledger section"
assert_file_contains "$REFINE_PLAN_QA_TEMPLATE" "## Answers" "refine-plan QA template includes Answers section"
assert_file_contains "$REFINE_PLAN_QA_TEMPLATE" "## Research Findings" "refine-plan QA template includes Research Findings section"
assert_file_contains "$REFINE_PLAN_QA_TEMPLATE" "## Plan Changes Applied" "refine-plan QA template includes Plan Changes Applied section"
assert_file_contains "$REFINE_PLAN_QA_TEMPLATE" "## Remaining Decisions" "refine-plan QA template includes Remaining Decisions section"
assert_file_contains "$REFINE_PLAN_QA_TEMPLATE" "## Refinement Metadata" "refine-plan QA template includes Refinement Metadata section"
assert_file_contains "$REFINE_PLAN_QA_TEMPLATE" "| CMT-ID | Classification | Location | Original Text (excerpt) | Disposition |" "refine-plan QA template includes ledger columns"
assert_file_contains "$REFINE_PLAN_QA_TEMPLATE" "- **Input Plan:** <path/to/input-plan.md>" "refine-plan QA template records input plan path"
assert_file_contains "$REFINE_PLAN_QA_TEMPLATE" "- **Output Plan:** <path/to/refined-plan.md>" "refine-plan QA template records output plan path"
assert_file_contains "$REFINE_PLAN_QA_TEMPLATE" "- **QA Document:** <path/to/qa-document.md>" "refine-plan QA template records QA document path"
assert_file_contains "$REFINE_PLAN_QA_TEMPLATE" "- **Convergence Status:** <converged | partially_converged>" "refine-plan QA template records convergence status"

echo ""
echo "PT-11: AC-7 wiring coverage"
if [[ -f "$REFINE_PLAN_SKILL" ]]; then
    USER_INVOCABLE="$(frontmatter_value "$REFINE_PLAN_SKILL" "user-invocable")"
    assert_equals "false" "$USER_INVOCABLE" "humanize-refine-plan skill frontmatter sets user-invocable: false"
else
    fail "humanize-refine-plan skill frontmatter sets user-invocable: false" "File exists with user-invocable: false" "File not found"
fi

if sed -n '/^SKILL_NAMES=(/,/^)/p' "$INSTALL_SKILL_SCRIPT" | grep -qF '"humanize-refine-plan"'; then
    pass "install-skill.sh includes humanize-refine-plan in SKILL_NAMES"
else
    fail "install-skill.sh includes humanize-refine-plan in SKILL_NAMES" '"humanize-refine-plan"' "missing from SKILL_NAMES"
fi

assert_file_contains "$CLAUDE_INSTALL_DOC" "/humanize:refine-plan" "install-for-claude.md mentions refine-plan command"
assert_file_contains "$CODEX_INSTALL_DOC" "humanize-refine-plan" "install-for-codex.md mentions humanize-refine-plan skill"
assert_file_contains "$KIMI_INSTALL_DOC" "humanize-refine-plan" "install-for-kimi.md mentions humanize-refine-plan skill"

# Kimi manual-install runtime bundle copy assertions (6 directories)
for bundle_dir in scripts hooks prompt-template templates config agents; do
    assert_file_contains "$KIMI_INSTALL_DOC" "cp -r $bundle_dir ~/.config/agents/skills/humanize/" \
        "install-for-kimi.md manual install copies $bundle_dir/ to skills/humanize/"
done

# Kimi manual-install user-invocable stripping section
assert_file_contains "$KIMI_INSTALL_DOC" \
    "# Strip user-invocable flag from SKILL.md files for runtime visibility" \
    "install-for-kimi.md has user-invocable stripping section comment"
assert_file_contains "$KIMI_INSTALL_DOC" \
    'in_fm && $0 ~ /^user-invocable:' \
    "install-for-kimi.md stripping section contains awk user-invocable filter"

# Kimi uninstall section includes humanize-refine-plan
assert_file_contains "$KIMI_INSTALL_DOC" \
    "rm -rf ~/.config/agents/skills/humanize-refine-plan" \
    "install-for-kimi.md uninstall removes humanize-refine-plan"

PLUGIN_VERSION="$(json_first_string_value "$PLUGIN_JSON" "version")"
MARKETPLACE_VERSION="$(json_first_string_value "$MARKETPLACE_JSON" "version")"
README_VERSION="$(readme_current_version "$README_FILE")"

if [[ -n "$PLUGIN_VERSION" ]]; then
    pass "plugin.json exposes a non-empty version"
else
    fail "plugin.json exposes a non-empty version" "Non-empty version" "(empty)"
fi

if [[ -n "$MARKETPLACE_VERSION" ]]; then
    pass "marketplace.json exposes a non-empty version"
else
    fail "marketplace.json exposes a non-empty version" "Non-empty version" "(empty)"
fi

if [[ -n "$README_VERSION" ]]; then
    pass "README.md exposes a non-empty current version"
else
    fail "README.md exposes a non-empty current version" "Non-empty current version" "(empty)"
fi

assert_equals "$PLUGIN_VERSION" "$MARKETPLACE_VERSION" "plugin.json and marketplace.json versions match"
assert_equals "$PLUGIN_VERSION" "$README_VERSION" "plugin.json and README.md current versions match"

# ========================================
# Reference Behavior Tests - Extraction/Classification/Language
# ========================================
echo ""
echo "========================================"
echo "Reference Behavior Tests"
echo "========================================"

echo ""
echo "RT-1: Comment extraction reference cases"
INLINE_FIXTURE="$TEST_FIXTURES_DIR/inline-comments.md"
cat > "$INLINE_FIXTURE" <<'EOF'
Before CMT: inline question ENDCMT after
EOF
scan_reference_comments "$INLINE_FIXTURE"
if [[ "$REFERENCE_COMMENT_COUNT" -eq 1 ]]; then
    pass "reference extractor counts a single-line comment block"
else
    fail "reference extractor counts a single-line comment block" "1" "$REFERENCE_COMMENT_COUNT"
fi

if [[ "$(collapse_whitespace "$REFERENCE_CLEANED_PLAN")" == "Before after" ]]; then
    pass "reference extractor preserves surrounding text for single-line comments"
else
    fail "reference extractor preserves surrounding text for single-line comments" "Before after" "$(collapse_whitespace "$REFERENCE_CLEANED_PLAN")"
fi

MULTILINE_FIXTURE="$TEST_FIXTURES_DIR/multiline-comments.md"
cat > "$MULTILINE_FIXTURE" <<'EOF'
Before
CMT:
please clarify this section
and keep the rest
ENDCMT
After
EOF
scan_reference_comments "$MULTILINE_FIXTURE"
if [[ "$REFERENCE_COMMENT_COUNT" -eq 1 ]]; then
    pass "reference extractor counts a multi-line comment block"
else
    fail "reference extractor counts a multi-line comment block" "1" "$REFERENCE_COMMENT_COUNT"
fi

if [[ "$(collapse_whitespace "$REFERENCE_CLEANED_PLAN")" == "Before After" ]]; then
    pass "reference extractor removes multi-line comments from the working plan"
else
    fail "reference extractor removes multi-line comments from the working plan" "Before After" "$(collapse_whitespace "$REFERENCE_CLEANED_PLAN")"
fi

FENCE_FIXTURE="$TEST_FIXTURES_DIR/fence-comments.md"
cat > "$FENCE_FIXTURE" <<'EOF'
```markdown
CMT: ignored inside code fence ENDCMT
```
EOF
scan_reference_comments "$FENCE_FIXTURE"
if [[ "$REFERENCE_COMMENT_COUNT" -eq 0 ]]; then
    pass "reference extractor ignores comment markers inside code fences"
else
    fail "reference extractor ignores comment markers inside code fences" "0" "$REFERENCE_COMMENT_COUNT"
fi

HTML_FIXTURE="$TEST_FIXTURES_DIR/html-comments.md"
cat > "$HTML_FIXTURE" <<'EOF'
<!-- CMT: ignored inside HTML comment ENDCMT -->
EOF
scan_reference_comments "$HTML_FIXTURE"
if [[ "$REFERENCE_COMMENT_COUNT" -eq 0 ]]; then
    pass "reference extractor ignores comment markers inside HTML comments"
else
    fail "reference extractor ignores comment markers inside HTML comments" "0" "$REFERENCE_COMMENT_COUNT"
fi

echo ""
echo "RT-2: Comment classification reference cases"
if [[ "$(dominant_classification "Why do we need two config layers here?")" == "question" ]]; then
    pass "reference classifier maps question comments to question"
else
    fail "reference classifier maps question comments to question" "question" "$(dominant_classification "Why do we need two config layers here?")"
fi

if [[ "$(dominant_classification "Delete task5 and fold its work into task4.")" == "change_request" ]]; then
    pass "reference classifier maps change requests to change_request"
else
    fail "reference classifier maps change requests to change_request" "change_request" "$(dominant_classification "Delete task5 and fold its work into task4.")"
fi

if [[ "$(dominant_classification "Investigate how config loading works in this repo before deciding whether AC-3 should change.")" == "research_request" ]]; then
    pass "reference classifier maps research requests to research_request"
else
    fail "reference classifier maps research requests to research_request" "research_request" "$(dominant_classification "Investigate how config loading works in this repo before deciding whether AC-3 should change.")"
fi

if [[ "$(dominant_classification "Investigate the repo and delete task5 if the evidence shows it is redundant.")" == "research_request" ]]; then
    pass "reference classifier gives research_request dominant precedence over change_request"
else
    fail "reference classifier gives research_request dominant precedence over change_request" "research_request" "$(dominant_classification "Investigate the repo and delete task5 if the evidence shows it is redundant.")"
fi

if [[ "$(dominant_classification "Delete task5 because it is unclear why it exists.")" == "change_request" ]]; then
    pass "reference classifier gives change_request precedence over question"
else
    fail "reference classifier gives change_request precedence over question" "change_request" "$(dominant_classification "Delete task5 because it is unclear why it exists.")"
fi

echo ""
echo "RT-3: Language and path reference cases"
if [[ "$(normalize_alt_language " zh ")" == "Chinese|zh|variant" ]]; then
    pass "reference language normalizer trims and resolves zh"
else
    fail "reference language normalizer trims and resolves zh" "Chinese|zh|variant" "$(normalize_alt_language " zh ")"
fi

if [[ "$(normalize_alt_language "Spanish")" == "Spanish|es|variant" ]]; then
    pass "reference language normalizer resolves full language names"
else
    fail "reference language normalizer resolves full language names" "Spanish|es|variant" "$(normalize_alt_language "Spanish")"
fi

if [[ "$(normalize_alt_language "English")" == "English|en|noop" ]]; then
    pass "reference language normalizer treats English as no-op"
else
    fail "reference language normalizer treats English as no-op" "English|en|noop" "$(normalize_alt_language "English")"
fi

if [[ "$(normalize_alt_language "Klingon")" == "unsupported||unsupported" ]]; then
    pass "reference language normalizer rejects unsupported languages"
else
    fail "reference language normalizer rejects unsupported languages" "unsupported||unsupported" "$(normalize_alt_language "Klingon")"
fi

if [[ "$(variant_path_for "plan.md" "zh")" == "plan_zh.md" ]]; then
    pass "reference variant path inserts suffix before extension"
else
    fail "reference variant path inserts suffix before extension" "plan_zh.md" "$(variant_path_for "plan.md" "zh")"
fi

if [[ "$(variant_path_for "docs/feature-a-qa.md" "zh")" == "docs/feature-a-qa_zh.md" ]]; then
    pass "reference variant path uses the last extension only"
else
    fail "reference variant path uses the last extension only" "docs/feature-a-qa_zh.md" "$(variant_path_for "docs/feature-a-qa.md" "zh")"
fi

if [[ "$(variant_path_for "output" "zh")" == "output_zh" ]]; then
    pass "reference variant path appends suffix for extensionless outputs"
else
    fail "reference variant path appends suffix for extensionless outputs" "output_zh" "$(variant_path_for "output" "zh")"
fi

if [[ "$(qa_path_for_input "docs/my-plan.md" ".humanize/plan_qa")" == ".humanize/plan_qa/my-plan-qa.md" ]]; then
    pass "reference QA path derives from input basename with extension"
else
    fail "reference QA path derives from input basename with extension" ".humanize/plan_qa/my-plan-qa.md" "$(qa_path_for_input "docs/my-plan.md" ".humanize/plan_qa")"
fi

if [[ "$(qa_path_for_input "plan" ".humanize/plan_qa")" == ".humanize/plan_qa/plan-qa.md" ]]; then
    pass "reference QA path derives from input basename without extension"
else
    fail "reference QA path derives from input basename without extension" ".humanize/plan_qa/plan-qa.md" "$(qa_path_for_input "plan" ".humanize/plan_qa")"
fi

# ========================================
# Script Tests - validate-refine-plan-io.sh
# ========================================
echo ""
echo "========================================"
echo "Script Tests - validate-refine-plan-io.sh"
echo "========================================"

echo ""
echo "ST-1: Invalid argument handling"
run_validator_capture --input
if [[ "$VALIDATOR_EXIT_CODE" -eq 7 ]]; then
    pass "validate-refine-plan-io: --input without value exits 7"
else
    fail "validate-refine-plan-io: --input without value exits 7" "7" "$VALIDATOR_EXIT_CODE"
fi

run_validator_capture --output
if [[ "$VALIDATOR_EXIT_CODE" -eq 7 ]]; then
    pass "validate-refine-plan-io: --output without value exits 7"
else
    fail "validate-refine-plan-io: --output without value exits 7" "7" "$VALIDATOR_EXIT_CODE"
fi

run_validator_capture --qa-dir
if [[ "$VALIDATOR_EXIT_CODE" -eq 7 ]]; then
    pass "validate-refine-plan-io: --qa-dir without value exits 7"
else
    fail "validate-refine-plan-io: --qa-dir without value exits 7" "7" "$VALIDATOR_EXIT_CODE"
fi

run_validator_capture --alt-language zh
if [[ "$VALIDATOR_EXIT_CODE" -eq 7 ]]; then
    pass "validate-refine-plan-io: unexpected --alt-language flag exits 7"
else
    fail "validate-refine-plan-io: unexpected --alt-language flag exits 7" "7" "$VALIDATOR_EXIT_CODE"
fi

run_validator_capture --discussion --direct --input /tmp/any.md
if [[ "$VALIDATOR_EXIT_CODE" -eq 7 ]]; then
    pass "validate-refine-plan-io: mutually exclusive discussion/direct exits 7"
else
    fail "validate-refine-plan-io: mutually exclusive discussion/direct exits 7" "7" "$VALIDATOR_EXIT_CODE"
fi

run_validator_capture --help
if [[ "$VALIDATOR_EXIT_CODE" -eq 7 ]]; then
    pass "validate-refine-plan-io: --help exits 7"
else
    fail "validate-refine-plan-io: --help exits 7" "7" "$VALIDATOR_EXIT_CODE"
fi

if echo "$VALIDATOR_OUTPUT" | grep -q -- "--discussion"; then
    pass "validate-refine-plan-io: usage output includes --discussion"
else
    fail "validate-refine-plan-io: usage output includes --discussion" "--discussion" "missing"
fi

echo ""
echo "ST-2: Exit codes 1-6"
run_validator_capture --input "$TEST_FIXTURES_DIR/missing-input.md"
if [[ "$VALIDATOR_EXIT_CODE" -eq 1 ]]; then
    pass "validate-refine-plan-io: missing input exits 1"
else
    fail "validate-refine-plan-io: missing input exits 1" "1" "$VALIDATOR_EXIT_CODE"
fi

EMPTY_INPUT="$TEST_FIXTURES_DIR/empty.md"
touch "$EMPTY_INPUT"
run_validator_capture --input "$EMPTY_INPUT"
if [[ "$VALIDATOR_EXIT_CODE" -eq 2 ]]; then
    pass "validate-refine-plan-io: empty input exits 2"
else
    fail "validate-refine-plan-io: empty input exits 2" "2" "$VALIDATOR_EXIT_CODE"
fi

NO_COMMENT_PLAN="$TEST_FIXTURES_DIR/no-comment-plan.md"
make_plan_without_comments "$NO_COMMENT_PLAN"
run_validator_capture --input "$NO_COMMENT_PLAN"
if [[ "$VALIDATOR_EXIT_CODE" -eq 3 ]]; then
    pass "validate-refine-plan-io: input without CMT blocks exits 3"
else
    fail "validate-refine-plan-io: input without CMT blocks exits 3" "3" "$VALIDATOR_EXIT_CODE"
fi

HTML_ONLY_COMMENT_PLAN="$TEST_FIXTURES_DIR/html-only-comment-plan.md"
make_plan_with_goal_body "$HTML_ONLY_COMMENT_PLAN" "<!-- CMT: ignored inside HTML comment ENDCMT -->"
run_validator_capture --input "$HTML_ONLY_COMMENT_PLAN"
if [[ "$VALIDATOR_EXIT_CODE" -eq 3 ]]; then
    pass "validate-refine-plan-io: HTML-comment markers do not count as CMT blocks"
else
    fail "validate-refine-plan-io: HTML-comment markers do not count as CMT blocks" "3" "$VALIDATOR_EXIT_CODE"
fi

FENCE_ONLY_COMMENT_PLAN="$TEST_FIXTURES_DIR/fence-only-comment-plan.md"
make_plan_with_goal_body "$FENCE_ONLY_COMMENT_PLAN" $'```markdown\nCMT: ignored inside code fence ENDCMT\n```'
run_validator_capture --input "$FENCE_ONLY_COMMENT_PLAN"
if [[ "$VALIDATOR_EXIT_CODE" -eq 3 ]]; then
    pass "validate-refine-plan-io: code-fence markers do not count as CMT blocks"
else
    fail "validate-refine-plan-io: code-fence markers do not count as CMT blocks" "3" "$VALIDATOR_EXIT_CODE"
fi

EMPTY_COMMENT_PLAN="$TEST_FIXTURES_DIR/empty-comment-plan.md"
make_plan_with_goal_body "$EMPTY_COMMENT_PLAN" "CMT:      ENDCMT"
run_validator_capture --input "$EMPTY_COMMENT_PLAN"
if [[ "$VALIDATOR_EXIT_CODE" -eq 3 ]]; then
    pass "validate-refine-plan-io: empty CMT blocks do not count as valid input"
else
    fail "validate-refine-plan-io: empty CMT blocks do not count as valid input" "3" "$VALIDATOR_EXIT_CODE"
fi

UNTERMINATED_COMMENT_PLAN="$TEST_FIXTURES_DIR/unterminated-comment-plan.md"
make_plan_with_goal_body "$UNTERMINATED_COMMENT_PLAN" "CMT: this block never closes"
run_validator_capture --input "$UNTERMINATED_COMMENT_PLAN"
if [[ "$VALIDATOR_EXIT_CODE" -eq 3 ]]; then
    pass "validate-refine-plan-io: unterminated CMT blocks exit 3"
else
    fail "validate-refine-plan-io: unterminated CMT blocks exit 3" "3" "$VALIDATOR_EXIT_CODE"
fi

if echo "$VALIDATOR_OUTPUT" | grep -q "missing end marker"; then
    pass "validate-refine-plan-io: unterminated CMT blocks report missing ENDCMT"
else
    fail "validate-refine-plan-io: unterminated CMT blocks report missing ENDCMT" "missing end marker" "$VALIDATOR_OUTPUT"
fi

if echo "$VALIDATOR_OUTPUT" | grep -q 'context: "CMT: this block never closes"'; then
    pass "validate-refine-plan-io: unterminated CMT blocks include the opening-line context excerpt"
else
    fail "validate-refine-plan-io: unterminated CMT blocks include the opening-line context excerpt" 'context: "CMT: this block never closes"' "$VALIDATOR_OUTPUT"
fi

NESTED_COMMENT_PLAN="$TEST_FIXTURES_DIR/nested-comment-plan.md"
make_plan_with_goal_body "$NESTED_COMMENT_PLAN" "CMT: outer CMT: inner ENDCMT"
run_validator_capture --input "$NESTED_COMMENT_PLAN"
if [[ "$VALIDATOR_EXIT_CODE" -eq 3 ]]; then
    pass "validate-refine-plan-io: nested CMT blocks exit 3"
else
    fail "validate-refine-plan-io: nested CMT blocks exit 3" "3" "$VALIDATOR_EXIT_CODE"
fi

if echo "$VALIDATOR_OUTPUT" | grep -q "nested comment block"; then
    pass "validate-refine-plan-io: nested CMT blocks report a parse error"
else
    fail "validate-refine-plan-io: nested CMT blocks report a parse error" "nested comment block" "$VALIDATOR_OUTPUT"
fi

MISSING_SECTION_PLAN="$TEST_FIXTURES_DIR/missing-sections-plan.md"
make_plan_missing_sections "$MISSING_SECTION_PLAN"
run_validator_capture --input "$MISSING_SECTION_PLAN"
if [[ "$VALIDATOR_EXIT_CODE" -eq 4 ]]; then
    pass "validate-refine-plan-io: input missing required sections exits 4"
else
    fail "validate-refine-plan-io: input missing required sections exits 4" "4" "$VALIDATOR_EXIT_CODE"
fi

FENCE_SECTION_PLAN="$TEST_FIXTURES_DIR/fence-sections-plan.md"
make_plan_with_sections_only_in_fence "$FENCE_SECTION_PLAN"
run_validator_capture --input "$FENCE_SECTION_PLAN"
if [[ "$VALIDATOR_EXIT_CODE" -eq 4 ]]; then
    pass "validate-refine-plan-io: required sections inside code fences do not satisfy section checks"
else
    fail "validate-refine-plan-io: required sections inside code fences do not satisfy section checks" "4" "$VALIDATOR_EXIT_CODE"
fi

HTML_SECTION_PLAN="$TEST_FIXTURES_DIR/html-sections-plan.md"
make_plan_with_sections_only_in_html_comment "$HTML_SECTION_PLAN"
run_validator_capture --input "$HTML_SECTION_PLAN"
if [[ "$VALIDATOR_EXIT_CODE" -eq 4 ]]; then
    pass "validate-refine-plan-io: required sections inside HTML comments do not satisfy section checks"
else
    fail "validate-refine-plan-io: required sections inside HTML comments do not satisfy section checks" "4" "$VALIDATOR_EXIT_CODE"
fi

VALID_PLAN="$TEST_FIXTURES_DIR/valid-plan.md"
make_valid_annotated_plan "$VALID_PLAN"
run_validator_capture --input "$VALID_PLAN" --output "$TEST_FIXTURES_DIR/missing-dir/refined.md"
if [[ "$VALIDATOR_EXIT_CODE" -eq 5 ]]; then
    pass "validate-refine-plan-io: missing output directory exits 5"
else
    fail "validate-refine-plan-io: missing output directory exits 5" "5" "$VALIDATOR_EXIT_CODE"
fi

READ_ONLY_OUTPUT_DIR="$TEST_FIXTURES_DIR/read-only-output"
mkdir -p "$READ_ONLY_OUTPUT_DIR"
chmod 0555 "$READ_ONLY_OUTPUT_DIR"
run_validator_capture --input "$VALID_PLAN" --output "$READ_ONLY_OUTPUT_DIR/refined.md"
if [[ "$VALIDATOR_EXIT_CODE" -eq 5 ]]; then
    pass "validate-refine-plan-io: non-writable output directory exits 5"
else
    fail "validate-refine-plan-io: non-writable output directory exits 5" "5" "$VALIDATOR_EXIT_CODE"
fi

if echo "$VALIDATOR_OUTPUT" | grep -q "VALIDATION_ERROR: OUTPUT_DIR_NOT_WRITABLE"; then
    pass "validate-refine-plan-io: non-writable output directory reports the specific validation error"
else
    fail "validate-refine-plan-io: non-writable output directory reports the specific validation error" "VALIDATION_ERROR: OUTPUT_DIR_NOT_WRITABLE" "$VALIDATOR_OUTPUT"
fi

chmod 0755 "$READ_ONLY_OUTPUT_DIR"

READ_ONLY_INPUT_DIR="$TEST_FIXTURES_DIR/read-only-input"
READ_ONLY_INPUT_PLAN="$READ_ONLY_INPUT_DIR/valid-plan.md"
READ_ONLY_INPUT_QA_DIR="$TEST_FIXTURES_DIR/read-only-input-qa"
mkdir -p "$READ_ONLY_INPUT_DIR"
make_valid_annotated_plan "$READ_ONLY_INPUT_PLAN"
chmod 0555 "$READ_ONLY_INPUT_DIR"
run_validator_capture --input "$READ_ONLY_INPUT_PLAN" --qa-dir "$READ_ONLY_INPUT_QA_DIR"
if [[ "$VALIDATOR_EXIT_CODE" -eq 5 ]]; then
    pass "validate-refine-plan-io: non-writable input directory in in-place mode exits 5"
else
    fail "validate-refine-plan-io: non-writable input directory in in-place mode exits 5" "5" "$VALIDATOR_EXIT_CODE"
fi

if echo "$VALIDATOR_OUTPUT" | grep -q "VALIDATION_ERROR: INPUT_DIR_NOT_WRITABLE"; then
    pass "validate-refine-plan-io: non-writable input directory reports the specific in-place validation error"
else
    fail "validate-refine-plan-io: non-writable input directory reports the specific in-place validation error" "VALIDATION_ERROR: INPUT_DIR_NOT_WRITABLE" "$VALIDATOR_OUTPUT"
fi

chmod 0755 "$READ_ONLY_INPUT_DIR"

REAL_AND_IGNORED_PLAN="$TEST_FIXTURES_DIR/real-and-ignored-sections-plan.md"
make_plan_with_real_and_ignored_sections "$REAL_AND_IGNORED_PLAN"
REAL_AND_IGNORED_QA_DIR="$TEST_FIXTURES_DIR/real-and-ignored-qa"
run_validator_capture --input "$REAL_AND_IGNORED_PLAN" --qa-dir "$REAL_AND_IGNORED_QA_DIR"
if [[ "$VALIDATOR_EXIT_CODE" -eq 0 ]]; then
    pass "validate-refine-plan-io: real sections outside ignored regions still pass validation"
else
    fail "validate-refine-plan-io: real sections outside ignored regions still pass validation" "0" "$VALIDATOR_EXIT_CODE"
fi

BROKEN_QA_PATH="$TEST_FIXTURES_DIR/not-a-dir"
printf 'not a directory\n' > "$BROKEN_QA_PATH"
run_validator_capture --input "$VALID_PLAN" --qa-dir "$BROKEN_QA_PATH"
if [[ "$VALIDATOR_EXIT_CODE" -eq 6 ]]; then
    pass "validate-refine-plan-io: non-directory QA path exits 6"
else
    fail "validate-refine-plan-io: non-directory QA path exits 6" "6" "$VALIDATOR_EXIT_CODE"
fi

echo ""
echo "ST-3: Exit code 0 and mode handling"
IN_PLACE_QA_DIR="$TEST_FIXTURES_DIR/in-place-qa"
run_validator_capture --input "$VALID_PLAN" --qa-dir "$IN_PLACE_QA_DIR" --discussion
if [[ "$VALIDATOR_EXIT_CODE" -eq 0 ]]; then
    pass "validate-refine-plan-io: valid in-place invocation exits 0"
else
    fail "validate-refine-plan-io: valid in-place invocation exits 0" "0" "$VALIDATOR_EXIT_CODE"
fi

if [[ -d "$IN_PLACE_QA_DIR" ]]; then
    pass "validate-refine-plan-io: auto-creates missing QA directory"
else
    fail "validate-refine-plan-io: auto-creates missing QA directory" "Directory created" "Directory missing"
fi

if echo "$VALIDATOR_OUTPUT" | grep -q "Mode: in-place (atomic write with temp file)"; then
    pass "validate-refine-plan-io: reports in-place mode"
else
    fail "validate-refine-plan-io: reports in-place mode" "Mode: in-place (atomic write with temp file)" "missing"
fi

MIXED_COMMENT_PLAN="$TEST_FIXTURES_DIR/mixed-comment-plan.md"
make_plan_with_goal_body "$MIXED_COMMENT_PLAN" 'Valid CMT: counted comment ENDCMT <!-- CMT: ignored inside HTML comment ENDCMT --> CMT:      ENDCMT'
MIXED_COMMENT_QA_DIR="$TEST_FIXTURES_DIR/mixed-comment-qa"
run_validator_capture --input "$MIXED_COMMENT_PLAN" --qa-dir "$MIXED_COMMENT_QA_DIR"
if [[ "$VALIDATOR_EXIT_CODE" -eq 0 ]]; then
    pass "validate-refine-plan-io: mixed valid, ignored, and empty markers still pass with a valid block"
else
    fail "validate-refine-plan-io: mixed valid, ignored, and empty markers still pass with a valid block" "0" "$VALIDATOR_EXIT_CODE"
fi

if echo "$VALIDATOR_OUTPUT" | grep -Eq 'Input file: .+ \([0-9]+ lines, 1 comment blocks\)'; then
    pass "validate-refine-plan-io: success output reports only valid non-empty CMT blocks"
else
    fail "validate-refine-plan-io: success output reports only valid non-empty CMT blocks" "1 comment blocks" "$VALIDATOR_OUTPUT"
fi

NEW_FILE_DIR="$TEST_FIXTURES_DIR/new-file-output"
mkdir -p "$NEW_FILE_DIR"
NEW_FILE_QA_DIR="$TEST_FIXTURES_DIR/new-file-qa"
run_validator_capture --input "$VALID_PLAN" --output "$NEW_FILE_DIR/refined-plan.md" --qa-dir "$NEW_FILE_QA_DIR" --direct
if [[ "$VALIDATOR_EXIT_CODE" -eq 0 ]]; then
    pass "validate-refine-plan-io: valid new-file invocation exits 0"
else
    fail "validate-refine-plan-io: valid new-file invocation exits 0" "0" "$VALIDATOR_EXIT_CODE"
fi

if echo "$VALIDATOR_OUTPUT" | grep -q "Mode: new file"; then
    pass "validate-refine-plan-io: reports new-file mode"
else
    fail "validate-refine-plan-io: reports new-file mode" "Mode: new file" "missing"
fi

if echo "$VALIDATOR_OUTPUT" | grep -q "Output target: $(realpath -m "$NEW_FILE_DIR/refined-plan.md")"; then
    pass "validate-refine-plan-io: reports the resolved output target"
else
    fail "validate-refine-plan-io: reports the resolved output target" "$(realpath -m "$NEW_FILE_DIR/refined-plan.md")" "$VALIDATOR_OUTPUT"
fi

# ========================================
# Summary
# ========================================
echo ""
echo "========================================"
echo "Test Summary"
echo "========================================"
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo ""
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo ""
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
