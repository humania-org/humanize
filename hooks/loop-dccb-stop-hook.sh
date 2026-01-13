#!/bin/bash
#
# Stop Hook for DCCB loop (Distill Code to Conceptual Blueprint)
#
# Intercepts Claude's exit attempts and uses Codex to review documentation.
# If Codex doesn't confirm the documentation is reconstruction-ready, blocks exit
# and feeds review back.
#
# State directory: .humanize-dccb.local/<timestamp>/
# State file: state.md (current_round, max_iterations, codex config)
# Summary file: round-N-summary.md (Claude's work summary)
# Review prompt: round-N-review-prompt.md (prompt sent to Codex)
# Review result: round-N-review-result.md (Codex's review)
#

set -euo pipefail

# ========================================
# Default Configuration
# ========================================

DEFAULT_CODEX_MODEL="gpt-5.2-codex"
DEFAULT_CODEX_EFFORT="high"
DEFAULT_CODEX_TIMEOUT=5400

# ========================================
# Read Hook Input
# ========================================

HOOK_INPUT=$(cat)

# ========================================
# Find Active Loop
# ========================================

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
LOOP_BASE_DIR="$PROJECT_ROOT/.humanize-dccb.local"

# Source shared loop functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/loop-common.sh"

# Find active loop (newest directory with state.md)
LOOP_DIR=""
if [[ -d "$LOOP_BASE_DIR" ]]; then
    # Find newest directory containing state.md
    for dir in $(ls -1dt "$LOOP_BASE_DIR"/*/ 2>/dev/null); do
        if [[ -f "$dir/state.md" ]]; then
            LOOP_DIR="$dir"
            break
        fi
    done
fi

# If no active loop, allow exit
if [[ -z "$LOOP_DIR" ]]; then
    exit 0
fi

STATE_FILE="$LOOP_DIR/state.md"

# ========================================
# Quick Check: Are All Todos Completed?
# ========================================

TODO_CHECKER="$SCRIPT_DIR/check-todos-from-transcript.py"

if [[ -f "$TODO_CHECKER" ]]; then
    TODO_RESULT=$(echo "$HOOK_INPUT" | python3 "$TODO_CHECKER" 2>&1) || TODO_EXIT=$?
    TODO_EXIT=${TODO_EXIT:-0}

    if [[ "$TODO_EXIT" -eq 1 ]]; then
        INCOMPLETE_LIST=$(echo "$TODO_RESULT" | tail -n +2)

        REASON="# Incomplete Todos Detected

You are trying to stop, but you still have **incomplete todos**:

$INCOMPLETE_LIST

**Required Action**:
1. Complete all remaining todos before attempting to stop
2. Mark each todo as completed using the TodoWrite tool
3. Only after ALL todos are completed, you may proceed to write your summary and stop

Do NOT proceed to Codex review until all todos are finished."

        jq -n \
            --arg reason "$REASON" \
            --arg msg "DCCB Loop: Blocked - incomplete todos detected" \
            '{
                "decision": "block",
                "reason": $reason,
                "systemMessage": $msg
            }'
        exit 0
    fi
fi

# ========================================
# Quick Check: Large File Detection
# ========================================

MAX_LINES=1800

# Check documentation files specifically
if [[ -f "$STATE_FILE" ]]; then
    OUTPUT_DIR=$(grep -E "^output_dir:" "$STATE_FILE" 2>/dev/null | sed 's/output_dir: *//' || echo "dccb-doc")
    DOC_DIR="$PROJECT_ROOT/$OUTPUT_DIR"

    if [[ -d "$DOC_DIR" ]]; then
        LARGE_FILES=""

        while IFS= read -r file; do
            if [[ -f "$file" ]]; then
                line_count=$(wc -l < "$file" 2>/dev/null | tr -d ' ') || continue
                if [[ "$line_count" -gt "$MAX_LINES" ]]; then
                    filename="${file#$PROJECT_ROOT/}"
                    LARGE_FILES="${LARGE_FILES}
- \`${filename}\`: ${line_count} lines"
                fi
            fi
        done < <(find "$DOC_DIR" -name "*.md" -type f 2>/dev/null)

        if [[ -n "$LARGE_FILES" ]]; then
            REASON="# Large Documentation Files Detected

You are trying to stop, but some documentation files exceed the **${MAX_LINES}-line limit**:
$LARGE_FILES

**Why This Matters**:
- Large documents are harder to read and understand
- They make the blueprint less accessible
- Each document should be focused and digestible

**Required Actions**:
1. Split large documents into logical parts
2. Ensure smooth cross-references between split files
3. Maintain coherence and consistency across files
4. Update blueprint-tracker.md to reflect the new structure

After splitting the files, attempt to exit again."

            jq -n \
                --arg reason "$REASON" \
                --arg msg "DCCB Loop: Blocked - large docs detected (>${MAX_LINES} lines)" \
                '{
                    "decision": "block",
                    "reason": $reason,
                    "systemMessage": $msg
                }'
            exit 0
        fi
    fi
fi

# ========================================
# Parse State File
# ========================================

if [[ ! -f "$STATE_FILE" ]]; then
    exit 0
fi

# Extract frontmatter values
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE" 2>/dev/null || echo "")

CURRENT_ROUND=$(echo "$FRONTMATTER" | grep '^current_round:' | sed 's/current_round: *//' | tr -d ' ')
MAX_ITERATIONS=$(echo "$FRONTMATTER" | grep '^max_iterations:' | sed 's/max_iterations: *//' | tr -d ' ')
CODEX_MODEL=$(echo "$FRONTMATTER" | grep '^codex_model:' | sed 's/codex_model: *//' | tr -d ' ')
CODEX_EFFORT=$(echo "$FRONTMATTER" | grep '^codex_effort:' | sed 's/codex_effort: *//' | tr -d ' ')
STATE_CODEX_TIMEOUT=$(echo "$FRONTMATTER" | grep '^codex_timeout:' | sed 's/codex_timeout: *//' | tr -d ' ')
OUTPUT_DIR=$(echo "$FRONTMATTER" | grep '^output_dir:' | sed 's/output_dir: *//')

# Defaults
CURRENT_ROUND="${CURRENT_ROUND:-0}"
MAX_ITERATIONS="${MAX_ITERATIONS:-42}"
CODEX_MODEL="${CODEX_MODEL:-$DEFAULT_CODEX_MODEL}"
CODEX_EFFORT="${CODEX_EFFORT:-$DEFAULT_CODEX_EFFORT}"
CODEX_TIMEOUT="${STATE_CODEX_TIMEOUT:-${CODEX_TIMEOUT:-$DEFAULT_CODEX_TIMEOUT}}"
OUTPUT_DIR="${OUTPUT_DIR:-dccb-doc}"

# Validate numeric fields
if [[ ! "$CURRENT_ROUND" =~ ^[0-9]+$ ]]; then
    echo "Warning: State file corrupted (current_round), stopping loop" >&2
    rm -f "$STATE_FILE"
    exit 0
fi

if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
    MAX_ITERATIONS=42
fi

# ========================================
# Check Summary File Exists
# ========================================

SUMMARY_FILE="$LOOP_DIR/round-${CURRENT_ROUND}-summary.md"

if [[ ! -f "$SUMMARY_FILE" ]]; then
    REASON="# Work Summary Missing

You attempted to exit without writing your work summary.

**Required Action**: Write your work summary to:
\`\`\`
$SUMMARY_FILE
\`\`\`

The summary should include:
- Codebase analysis highlights (Round 0) or improvements made (subsequent rounds)
- Documentation structure proposed/updated
- Documents created/modified
- Confidence level in reconstruction-readiness

After writing the summary, you may attempt to exit again."

    jq -n \
        --arg reason "$REASON" \
        --arg msg "DCCB Loop: Summary file missing for round $CURRENT_ROUND" \
        '{
            "decision": "block",
            "reason": $reason,
            "systemMessage": $msg
        }'
    exit 0
fi

# ========================================
# Check Documentation Directory Has Content
# ========================================

DOC_DIR="$PROJECT_ROOT/$OUTPUT_DIR"

if [[ ! -d "$DOC_DIR" ]]; then
    REASON="# Documentation Directory Missing

You attempted to exit without creating the documentation directory.

**Required Action**: Create documentation in \`$OUTPUT_DIR/\`

The structure should be proportional to the codebase:
- Small project: single blueprint.md
- Medium project: 5-10 files
- Large project: hierarchical with subdirectories

After creating documentation, you may attempt to exit again."

    jq -n \
        --arg reason "$REASON" \
        --arg msg "DCCB Loop: Documentation directory missing" \
        '{
            "decision": "block",
            "reason": $reason,
            "systemMessage": $msg
        }'
    exit 0
fi

# Check if any markdown files exist in the output directory
DOC_COUNT=$(find "$DOC_DIR" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')

if [[ "$DOC_COUNT" -eq 0 ]]; then
    REASON="# No Documentation Files Found

You attempted to exit without creating any documentation files.

**Required Action**: Create at least one markdown file in \`$OUTPUT_DIR/\`

The structure should be proportional to the codebase:
- Small project: single blueprint.md or index.md
- Medium project: 5-10 files
- Large project: hierarchical with subdirectories

After creating documentation, you may attempt to exit again."

    jq -n \
        --arg reason "$REASON" \
        --arg msg "DCCB Loop: No documentation files found in $OUTPUT_DIR" \
        '{
            "decision": "block",
            "reason": $reason,
            "systemMessage": $msg
        }'
    exit 0
fi

# ========================================
# Check Blueprint Tracker Initialization (Round 0 only)
# ========================================

BLUEPRINT_TRACKER_FILE="$LOOP_DIR/blueprint-tracker.md"

if [[ "$CURRENT_ROUND" -eq 0 ]] && [[ -f "$BLUEPRINT_TRACKER_FILE" ]]; then
    TRACKER_CONTENT=$(cat "$BLUEPRINT_TRACKER_FILE")

    # Check if key sections are still placeholders
    HAS_METRICS_PLACEHOLDER=false
    HAS_STRUCTURE_PLACEHOLDER=false

    if echo "$TRACKER_CONTENT" | grep -q '\[pending\]'; then
        if echo "$TRACKER_CONTENT" | grep -q 'Total Files.*\[pending\]'; then
            HAS_METRICS_PLACEHOLDER=true
        fi
        if echo "$TRACKER_CONTENT" | grep -q 'pending - Claude will propose structure'; then
            HAS_STRUCTURE_PLACEHOLDER=true
        fi
    fi

    MISSING_ITEMS=""
    if [[ "$HAS_METRICS_PLACEHOLDER" == "true" ]]; then
        MISSING_ITEMS="$MISSING_ITEMS
- **Codebase Metrics**: Still contains placeholder values"
    fi
    if [[ "$HAS_STRUCTURE_PLACEHOLDER" == "true" ]]; then
        MISSING_ITEMS="$MISSING_ITEMS
- **Documentation Structure**: Still contains placeholder text"
    fi

    if [[ -n "$MISSING_ITEMS" ]]; then
        REASON="# Blueprint Tracker Not Initialized

You are in **Round 0** and the Blueprint Tracker has not been properly initialized.

**Missing items in \`blueprint-tracker.md\`**:
$MISSING_ITEMS

**Required Actions**:
1. Complete your codebase analysis
2. Fill in the **Codebase Metrics** section
3. Propose and document your **Documentation Structure**
4. Provide **Structure Rationale**
5. Update the **Documentation Progress** table

After updating the Blueprint Tracker, you may attempt to exit again."

        jq -n \
            --arg reason "$REASON" \
            --arg msg "DCCB Loop: Blueprint Tracker not initialized in Round 0" \
            '{
                "decision": "block",
                "reason": $reason,
                "systemMessage": $msg
            }'
        exit 0
    fi
fi

# ========================================
# Check Max Iterations
# ========================================

NEXT_ROUND=$((CURRENT_ROUND + 1))

if [[ $NEXT_ROUND -gt $MAX_ITERATIONS ]]; then
    echo "DCCB loop did not complete, but reached max iterations ($MAX_ITERATIONS). Exiting." >&2
    rm -f "$STATE_FILE"
    exit 0
fi

# ========================================
# Build Codex Review Prompt
# ========================================

PROMPT_FILE="$LOOP_DIR/round-${CURRENT_ROUND}-prompt.md"
REVIEW_PROMPT_FILE="$LOOP_DIR/round-${CURRENT_ROUND}-review-prompt.md"
REVIEW_RESULT_FILE="$LOOP_DIR/round-${CURRENT_ROUND}-review-result.md"

SUMMARY_CONTENT=$(cat "$SUMMARY_FILE")

# Get documentation tree structure for Codex
DOC_TREE=$(find "$DOC_DIR" -name "*.md" -type f 2>/dev/null | sed "s|$PROJECT_ROOT/||" | sort)
DOC_TREE_FORMATTED=$(echo "$DOC_TREE" | while read -r f; do echo "- @$f"; done)

# Determine if this is a Full Review round (every 5 rounds)
FULL_REVIEW=false
if [[ $((CURRENT_ROUND % 5)) -eq 4 ]]; then
    FULL_REVIEW=true
fi

# Build the review prompt
if [[ "$FULL_REVIEW" == "true" ]]; then
    # Full Reconstruction-Readiness Review
    cat > "$REVIEW_PROMPT_FILE" << EOF
# FULL RECONSTRUCTION-READINESS REVIEW - Round $CURRENT_ROUND

This is a **mandatory checkpoint** (every 5 rounds). You must conduct a comprehensive review to determine if the documentation is sufficient for complete codebase reconstruction.

## Your Role

You are **Codex**, acting as a **Reconstruction Critic**. Your job is to evaluate whether the documentation in \`$OUTPUT_DIR/\` is sufficient for an AI or developer to rebuild a functionally equivalent codebase WITHOUT access to the original source code.

**NOTE**: You do NOT actually implement or rebuild the system. You conduct deep analysis, reasoning, and critical review. For verifying specific core claims (algorithms, math, critical logic), you may write small verification scripts, but delete them after verification.

## Documentation Location

All documentation files are in: @$OUTPUT_DIR/

**Documentation Files Found:**
$DOC_TREE_FORMATTED

Also read the progress tracker: @$BLUEPRINT_TRACKER_FILE

**IMPORTANT**: Read ALL documentation files listed above before making your assessment.

---
## Claude's Work Summary
<!-- CLAUDE's WORK SUMMARY START -->
$SUMMARY_CONTENT
<!-- CLAUDE's WORK SUMMARY  END  -->
---

## Part 1: Structure Appropriateness Assessment

### 1.1 Codebase vs Documentation Proportion
First, verify that the documentation structure is appropriate for the codebase:
- Is the documentation depth proportional to codebase complexity?
- Does the structure mirror the codebase organization?
- Is there over-documentation (too much for a small codebase)?
- Is there under-documentation (too little for a large codebase)?

| Aspect | Assessment |
|--------|------------|
| Codebase Size | [estimate] |
| Doc File Count | $DOC_COUNT |
| Structure Appropriate? | YES/NO |
| Issues | ... |

### 1.2 Documentation Structure Review
Evaluate the chosen structure:
- Does it make logical sense?
- Can a reader navigate it easily?
- Are related concepts grouped together?

## Part 2: Reconstruction-Readiness Assessment

### 2.1 Self-Containment Check
For EACH document, answer:
- Can this be understood WITHOUT reading the source code?
- Does it explain concepts rather than describe implementation?
- Are all terms defined before use?

| Document | Self-Contained? | Issues |
|----------|-----------------|--------|
EOF

    # Add each doc file to the table
    echo "$DOC_TREE" | while read -r f; do
        echo "| $f | YES/NO | ... |" >> "$REVIEW_PROMPT_FILE"
    done

    cat >> "$REVIEW_PROMPT_FILE" << EOF

### 2.2 Completeness Check
Verify the documentation covers:
- [ ] All significant modules and their purposes
- [ ] All external interfaces (APIs, CLIs, protocols)
- [ ] All key data structures and their relationships
- [ ] All important workflows and execution paths
- [ ] Critical invariants and constraints
- [ ] Design principles and trade-offs

List any **missing topics** that would be needed for reconstruction.

### 2.3 De-Specialization Check (CRITICAL)

**Remember**: The goal is **functional equivalence**, NOT exact replication. Someone should be able to build a functionally equivalent system in ANY language/framework.

Look for signs of inadequate abstraction:
- Code snippets that should be conceptual descriptions
- Implementation-specific names (variables, functions, classes)
- **Line number references** (e.g., "see line 42", "at line 100")
- **File path references** to the original codebase (e.g., "in src/foo/bar.py")
- **References pointing to specific implementations** in the existing code
- Framework-specific details that should be generalized
- Incidental details that don't contribute to reconstruction
- Anything that assumes the reader has access to the original code

List any **specialization issues** found. These are BLOCKING issues.

### 2.4 Consistency Check
Verify cross-document coherence:
- [ ] Terminology is used consistently across documents
- [ ] Cross-references are valid and helpful
- [ ] No contradictions between documents

List any **consistency issues** found.

### 2.5 Reconstruction Test (Analysis Only)

**IMPORTANT**: You do NOT need to actually implement the system to verify reconstruction-readiness. Instead, conduct deep analysis and reasoning.

Analyze the documentation as if you were tasked with rebuilding this system:
- What questions would you need answered that aren't in the docs?
- What would be ambiguous or unclear?
- Where might you make wrong assumptions?

**Optional Verification**: For core claims involving mathematical formulas, algorithms, or critical logic, you MAY write small verification scripts to test correctness. If you do:
1. Create a minimal script to verify the specific claim
2. Run the verification
3. **Delete the script afterward** (it is NOT part of the documentation)
4. Include the verification result in your review

List your **reconstruction concerns**.

## Part 3: Gap List (CRITICAL)

Based on your assessment, create a prioritized **Gap List**:

\`\`\`markdown
## Gap List

### Critical Gaps (Block completion)
1. [Gap description and which document needs update]
2. ...

### Major Gaps (Should be addressed)
1. [Gap description and which document needs update]
2. ...

### Minor Gaps (Nice to have)
1. [Gap description and which document needs update]
2. ...
\`\`\`

## Part 4: Progress Stagnation Check

Review the historical round files in \`.humanize-dccb.local/$(basename "$LOOP_DIR")/\`:
- Round summaries: \`round-N-summary.md\`
- Review results: \`round-N-review-result.md\`

**Signs of Stagnation**:
- Same gaps appearing repeatedly across rounds
- No meaningful documentation improvement
- Claude repeating the same content
- Circular feedback without resolution

If stagnation is detected, output \`STOP\` instead of continuing.

## Part 5: Output Requirements

Write your findings to @$REVIEW_RESULT_FILE

**If Critical or Major Gaps exist**:
- Document all gaps clearly
- Provide specific guidance on what Claude should add/fix
- Do NOT output COMPLETE

**If development is stagnating**:
- Output \`STOP\` as the last line

**CRITICAL - Only output \`COMPLETE\` as the last line if**:
- Documentation structure is appropriate for the codebase
- ALL documents are self-contained (no references to original code)
- NO line numbers, file paths, or implementation-specific references exist
- NO critical or major gaps remain
- Documentation enables building a **functionally equivalent** system
- An AI could rebuild the system from these docs alone (in any language/framework)
EOF

else
    # Regular review prompt
    cat > "$REVIEW_PROMPT_FILE" << EOF
# Documentation Review - Round $CURRENT_ROUND

## Your Role

You are **Codex**, acting as a **Reconstruction Critic**. Your job is to evaluate whether Claude's documentation is progressing toward being sufficient for complete codebase reconstruction.

**NOTE**: You do NOT actually implement or rebuild the system. You conduct deep analysis, reasoning, and critical review. For verifying specific core claims (algorithms, math, critical logic), you may write small verification scripts, but delete them after verification.

## Documentation Location

All documentation files are in: @$OUTPUT_DIR/

**Documentation Files Found:**
$DOC_TREE_FORMATTED

Also read the progress tracker: @$BLUEPRINT_TRACKER_FILE

**IMPORTANT**: Read ALL documentation files listed above before making your assessment.

---
## Claude's Work Summary
<!-- CLAUDE's WORK SUMMARY START -->
$SUMMARY_CONTENT
<!-- CLAUDE's WORK SUMMARY  END  -->
---

## Part 1: Documentation Quality Review

### Structure Assessment
- Is the documentation structure proportional to the codebase?
- Does it mirror the codebase organization appropriately?

### Self-Containment
- Can each document be understood without reading source code?
- Are concepts explained rather than implementation described?

### Completeness
- Are all significant aspects of the system documented?
- Are there obvious gaps in coverage?

### De-Specialization (Goal: Functional Equivalence)
The goal is to enable building a **functionally equivalent** system, NOT exact replication.
- Has Claude abstracted implementation details to concepts?
- Are there code snippets that should be conceptual descriptions?
- Are there **line number references** (e.g., "see line 42")?
- Are there **file path references** to the original codebase?
- Are there references that assume access to the original code?

### Consistency
- Is terminology consistent across documents?
- Do cross-references work correctly?

## Part 2: Gap Analysis

Identify specific gaps that prevent reconstruction-readiness:

### What's Missing?
- Topics not covered
- Concepts not explained
- Interfaces not documented
- Workflows not traced

### What Needs Improvement?
- Sections that are too vague
- Areas that still reference code
- Parts that lack context

## Part 3: Feedback for Claude

Based on your analysis:
1. List the TOP 3-5 most important improvements needed
2. For each improvement, specify:
   - Which document needs updating (or new document needed)
   - What information should be added/changed
   - Why this matters for reconstruction

## Part 4: Output Requirements

Write your findings to @$REVIEW_RESULT_FILE

**If improvements are needed**:
- Document specific gaps and required changes
- Provide clear guidance for Claude
- Do NOT output COMPLETE

**CRITICAL - Only output \`COMPLETE\` as the last line if**:
- Documentation structure is appropriate
- ALL documents are self-contained (no references to original code)
- NO line numbers, file paths, or implementation-specific references exist
- NO significant gaps remain
- Documentation enables building a **functionally equivalent** system
- An AI could rebuild the system from these docs alone (in any language/framework)

If Claude is making good progress but not yet complete, provide constructive feedback to guide the next iteration.
EOF
fi

# ========================================
# Run Codex Review
# ========================================

echo "Running Codex review for DCCB round $CURRENT_ROUND..." >&2

PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Debug log files go to cache directory
LOOP_TIMESTAMP=$(basename "$LOOP_DIR")
SANITIZED_PROJECT_PATH=$(echo "$PROJECT_ROOT" | sed 's/[^a-zA-Z0-9._-]/-/g' | sed 's/--*/-/g')
CACHE_DIR="$HOME/.cache/humanize-dccb/$SANITIZED_PROJECT_PATH/$LOOP_TIMESTAMP"
mkdir -p "$CACHE_DIR"

CODEX_CMD_FILE="$CACHE_DIR/round-${CURRENT_ROUND}-codex-run.cmd"
CODEX_STDOUT_FILE="$CACHE_DIR/round-${CURRENT_ROUND}-codex-run.out"
CODEX_STDERR_FILE="$CACHE_DIR/round-${CURRENT_ROUND}-codex-run.log"

# Source portable timeout if available
TIMEOUT_SCRIPT="$PLUGIN_ROOT/scripts/portable-timeout.sh"
if [[ -f "$TIMEOUT_SCRIPT" ]]; then
    source "$TIMEOUT_SCRIPT"
else
    run_with_timeout() {
        local timeout_secs="$1"
        shift
        if command -v timeout &>/dev/null; then
            timeout "$timeout_secs" "$@"
        elif command -v gtimeout &>/dev/null; then
            gtimeout "$timeout_secs" "$@"
        else
            "$@"
        fi
    }
fi

# Build Codex command arguments
CODEX_ARGS=("-m" "$CODEX_MODEL")
if [[ -n "$CODEX_EFFORT" ]]; then
    CODEX_ARGS+=("-c" "model_reasoning_effort=${CODEX_EFFORT}")
fi
CODEX_ARGS+=("--full-auto" "-C" "$PROJECT_ROOT")

# Save the command for debugging
CODEX_PROMPT_CONTENT=$(cat "$REVIEW_PROMPT_FILE")
{
    echo "# Codex DCCB invocation debug info"
    echo "# Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Working directory: $PROJECT_ROOT"
    echo "# Timeout: $CODEX_TIMEOUT seconds"
    echo ""
    echo "codex exec ${CODEX_ARGS[*]} \"<prompt>\""
    echo ""
    echo "# Prompt content:"
    echo "$CODEX_PROMPT_CONTENT"
} > "$CODEX_CMD_FILE"

echo "Codex command saved to: $CODEX_CMD_FILE" >&2
echo "Running codex exec with timeout ${CODEX_TIMEOUT}s..." >&2

CODEX_EXIT_CODE=0
run_with_timeout "$CODEX_TIMEOUT" codex exec "${CODEX_ARGS[@]}" "$CODEX_PROMPT_CONTENT" \
    > "$CODEX_STDOUT_FILE" 2> "$CODEX_STDERR_FILE" || CODEX_EXIT_CODE=$?

echo "Codex exit code: $CODEX_EXIT_CODE" >&2
echo "Codex stdout saved to: $CODEX_STDOUT_FILE" >&2
echo "Codex stderr saved to: $CODEX_STDERR_FILE" >&2

# Check if Codex created the review result file
if [[ ! -f "$REVIEW_RESULT_FILE" ]]; then
    if [[ -s "$CODEX_STDOUT_FILE" ]]; then
        echo "Codex output found in stdout, copying to review result file..." >&2
        cp "$CODEX_STDOUT_FILE" "$REVIEW_RESULT_FILE"
    fi
fi

# ========================================
# Check Codex Output
# ========================================

if [[ ! -f "$REVIEW_RESULT_FILE" ]]; then
    echo "Error: Codex did not create review result file" >&2

    STDERR_CONTENT=""
    if [[ -f "$CODEX_STDERR_FILE" ]]; then
        STDERR_CONTENT=$(tail -50 "$CODEX_STDERR_FILE" 2>/dev/null || echo "(unable to read stderr)")
    fi

    REASON="# Codex Review Failed

The Codex review process failed to produce output.

**Exit Code**: $CODEX_EXIT_CODE
**Review Result File**: $REVIEW_RESULT_FILE (not created)

**Debug Files**:
- Command: $CODEX_CMD_FILE
- Stdout: $CODEX_STDOUT_FILE
- Stderr: $CODEX_STDERR_FILE

**Stderr (last 50 lines)**:
\`\`\`
$STDERR_CONTENT
\`\`\`

Please check the debug files for more details. The system will attempt another review when you exit."

    jq -n \
        --arg reason "$REASON" \
        --arg msg "DCCB Loop: Codex review failed for round $CURRENT_ROUND (exit code: $CODEX_EXIT_CODE)" \
        '{
            "decision": "block",
            "reason": $reason,
            "systemMessage": $msg
        }'
    exit 0
fi

# Read the review result
REVIEW_CONTENT=$(cat "$REVIEW_RESULT_FILE")

# Check if the last non-empty line is exactly "COMPLETE" or "STOP"
LAST_LINE=$(echo "$REVIEW_CONTENT" | grep -v '^[[:space:]]*$' | tail -1)
LAST_LINE_TRIMMED=$(echo "$LAST_LINE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

# Handle COMPLETE - loop finished successfully
if [[ "$LAST_LINE_TRIMMED" == "COMPLETE" ]]; then
    if [[ "$FULL_REVIEW" == "true" ]]; then
        echo "Codex confirms documentation is reconstruction-ready. DCCB loop complete!" >&2
    else
        echo "Codex review passed. Documentation is reconstruction-ready. DCCB loop complete!" >&2
    fi
    rm -f "$STATE_FILE"
    exit 0
fi

# Handle STOP - circuit breaker triggered
if [[ "$LAST_LINE_TRIMMED" == "STOP" ]]; then
    echo "" >&2
    echo "========================================" >&2
    if [[ "$FULL_REVIEW" == "true" ]]; then
        echo "CIRCUIT BREAKER TRIGGERED" >&2
        echo "========================================" >&2
        echo "Codex detected documentation stagnation during Full Review (Round $CURRENT_ROUND)." >&2
        echo "The loop has been stopped to prevent further unproductive iterations." >&2
    else
        echo "UNEXPECTED CIRCUIT BREAKER" >&2
        echo "========================================" >&2
        echo "Codex output STOP during a non-review round (Round $CURRENT_ROUND)." >&2
    fi
    echo "" >&2
    echo "Review the documentation and consider:" >&2
    echo "  - Manual refinement of the blueprint" >&2
    echo "  - Breaking down the codebase into smaller parts" >&2
    echo "  - Consulting with domain experts" >&2
    echo "========================================" >&2
    rm -f "$STATE_FILE"
    exit 0
fi

# ========================================
# Review Found Issues - Continue Loop
# ========================================

# Update state file for next round
TEMP_FILE="${STATE_FILE}.tmp.$$"
sed "s/^current_round: .*/current_round: $NEXT_ROUND/" "$STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$STATE_FILE"

# Create next round prompt
NEXT_PROMPT_FILE="$LOOP_DIR/round-${NEXT_ROUND}-prompt.md"
NEXT_SUMMARY_FILE="$LOOP_DIR/round-${NEXT_ROUND}-summary.md"

# Check if this is after a Full Review
IS_POST_FULL_REVIEW=$([[ $((CURRENT_ROUND % 5)) -eq 4 ]] && echo "true" || echo "false")

cat > "$NEXT_PROMPT_FILE" << EOF
Your documentation is not yet reconstruction-ready. Read and execute the below with ultrathink.

---
## Codex's Review Feedback
<!-- CODEX's REVIEW RESULT START -->
$REVIEW_CONTENT
<!-- CODEX's REVIEW RESULT  END  -->
---

## Your Task

Based on Codex's feedback above, improve the documentation in \`$OUTPUT_DIR/\`.

### Key Focus Areas

1. **Address Gap List**: If Codex identified specific gaps, fill them
2. **Improve Self-Containment**: Make sure each doc is understandable without code
3. **De-Specialize**: Replace code-specific details with concepts
4. **Ensure Consistency**: Align terminology and cross-references
5. **Structure Appropriateness**: Adjust if documentation depth doesn't match codebase

### Documentation Location

Update files in: @$OUTPUT_DIR/

Current documentation files:
$DOC_TREE_FORMATTED

You may:
- Update existing files
- Add new files if needed for better coverage
- Split large files into smaller ones
- Create subdirectories to mirror codebase structure (for large projects)

### Progress Tracking

Update @$BLUEPRINT_TRACKER_FILE with:
- What gaps you addressed
- What improvements you made
- Any new files created
- Updated documentation progress table

EOF

# Add special instructions for post-Full Review rounds
if [[ "$IS_POST_FULL_REVIEW" == "true" ]]; then
    cat >> "$NEXT_PROMPT_FILE" << EOF

### Post-Full-Review Focus

This round follows a comprehensive reconstruction-readiness review. Pay special attention to:
- **Critical Gaps**: These MUST be addressed before completion
- **Self-Containment Issues**: Documents flagged as not self-contained need rewriting
- **Missing Coverage**: Topics that Codex identified as missing for reconstruction
- **Structure Issues**: If documentation structure was flagged as inappropriate, adjust it
EOF
fi

cat >> "$NEXT_PROMPT_FILE" << EOF

---

Note: You MUST NOT try to exit the DCCB loop by lying or editing loop state files or trying to execute \`cancel-dccb-loop\`

After completing your improvements:
1. Update @$BLUEPRINT_TRACKER_FILE with progress
2. Write your work summary to @$NEXT_SUMMARY_FILE

Your summary should include:
- What gaps you addressed from Codex's feedback
- What documents you updated/created and how
- Remaining concerns about reconstruction-readiness
- Your assessment: is the documentation now sufficient?
EOF

# Build system message
SYSTEM_MSG="DCCB Loop: Round $NEXT_ROUND/$MAX_ITERATIONS - Codex found documentation gaps to address"

# Block exit and send review feedback
jq -n \
    --arg reason "$(cat "$NEXT_PROMPT_FILE")" \
    --arg msg "$SYSTEM_MSG" \
    '{
        "decision": "block",
        "reason": $reason,
        "systemMessage": $msg
    }'

exit 0
