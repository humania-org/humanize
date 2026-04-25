#!/usr/bin/env bash
#
# Methodology Analysis Phase library
#
# Provides functions for the methodology improvement analysis phase that runs
# before the RLCR loop truly exits. An independent Opus agent analyzes the
# development records from a pure methodology perspective and optionally helps
# the user file a GitHub issue with improvement suggestions.
#
# This library is sourced by loop-codex-stop-hook.sh.
#

# Source guard: prevent double-sourcing
[[ -n "${_METHODOLOGY_ANALYSIS_LOADED:-}" ]] && return 0 2>/dev/null || true
_METHODOLOGY_ANALYSIS_LOADED=1

# Enter the methodology analysis phase
#
# Renames the current state file to methodology-analysis-state.md, records the
# exit reason, renders the analysis prompt, and outputs a block JSON response.
#
# Arguments:
#   $1 - exit_reason: "complete", "stop", or "maxiter"
#   $2 - exit_reason_description: human-readable explanation of why the loop is exiting
#
# Globals read:
#   PRIVACY_MODE - "true" to skip analysis, "false" to proceed
#   STATE_FILE   - path to the current active state file
#   LOOP_DIR     - path to the loop directory
#   CURRENT_ROUND - current round number
#   MAX_ITERATIONS - max iterations setting
#   TEMPLATE_DIR - template directory for prompt rendering
#
# Returns:
#   0 - analysis phase entered, block JSON has been output, caller should exit 0
#   1 - analysis should be skipped (privacy on, already done, or re-entry)
#
enter_methodology_analysis_phase() {
    local exit_reason="$1"
    local exit_reason_description="$2"

    # Skip if privacy mode is on
    if [[ "$PRIVACY_MODE" == "true" ]]; then
        echo "Methodology analysis skipped (privacy mode enabled)" >&2
        return 1
    fi

    # Prevent re-entry: if methodology-analysis-state.md already exists, skip
    if [[ -f "$LOOP_DIR/methodology-analysis-state.md" ]]; then
        echo "Methodology analysis phase already active, skipping re-entry" >&2
        return 1
    fi

    # Skip if already completed in a previous attempt
    if [[ -f "$LOOP_DIR/methodology-analysis-done.md" ]]; then
        local done_content
        done_content=$(cat "$LOOP_DIR/methodology-analysis-done.md" 2>/dev/null || echo "")
        if [[ -n "$done_content" ]]; then
            echo "Methodology analysis already completed, skipping" >&2
            return 1
        fi
    fi

    # Rename current state file to methodology-analysis-state.md
    mv "$STATE_FILE" "$LOOP_DIR/methodology-analysis-state.md"
    echo "State file renamed to: $LOOP_DIR/methodology-analysis-state.md" >&2

    # Record the original exit reason so the completion handler can finalize
    echo "$exit_reason" > "$LOOP_DIR/.methodology-exit-reason"

    # Create empty placeholder for the completion artifact
    touch "$LOOP_DIR/methodology-analysis-done.md"

    # Render prompt template
    local fallback="# Methodology Analysis Phase

Please analyze the development records in $LOOP_DIR and provide methodology improvement suggestions.
Write your analysis to $LOOP_DIR/methodology-analysis-report.md.
When done, write a completion note to $LOOP_DIR/methodology-analysis-done.md."

    local analysis_prompt
    analysis_prompt=$(load_and_render_safe "$TEMPLATE_DIR" "claude/methodology-analysis-prompt.md" "$fallback" \
        "LOOP_DIR=$LOOP_DIR" \
        "EXIT_REASON=$exit_reason" \
        "EXIT_REASON_DESCRIPTION=$exit_reason_description" \
        "CURRENT_ROUND=$CURRENT_ROUND" \
        "MAX_ITERATIONS=$MAX_ITERATIONS")

    # Output block JSON with the rendered prompt
    jq -n \
        --arg reason "$analysis_prompt" \
        --arg msg "Loop: Methodology Analysis Phase - analyzing development methodology" \
        '{
            "decision": "block",
            "reason": $reason,
            "systemMessage": $msg
        }'

    return 0
}

# Complete the methodology analysis phase
#
# Checks the completion artifact, reads the original exit reason, renames the
# state file to the appropriate terminal state, and cleans up marker files.
#
# Globals read:
#   LOOP_DIR - path to the loop directory
#
# Returns:
#   0 - completion successful, caller should exit 0 (allow exit)
#   1 - incomplete (done marker missing/empty, report missing, or exit reason invalid)
#
complete_methodology_analysis() {
    local done_file="$LOOP_DIR/methodology-analysis-done.md"
    local report_file="$LOOP_DIR/methodology-analysis-report.md"

    # Check completion artifact has actual content (not just empty placeholder)
    if [[ ! -f "$done_file" ]]; then
        return 1
    fi

    local done_content
    done_content=$(cat "$done_file" 2>/dev/null || echo "")
    # Trim whitespace to reject whitespace-only markers
    done_content="${done_content#"${done_content%%[![:space:]]*}"}"
    if [[ -z "$done_content" ]]; then
        return 1
    fi

    # Require the analysis report to exist with content (ensures the Opus agent
    # actually produced an analysis, not just an empty/truncated file)
    if [[ ! -f "$report_file" ]]; then
        echo "Warning: methodology-analysis-report.md missing, blocking completion" >&2
        return 1
    fi
    local report_content
    report_content=$(cat "$report_file" 2>/dev/null || echo "")
    report_content="${report_content#"${report_content%%[![:space:]]*}"}"
    if [[ -z "$report_content" ]]; then
        echo "Warning: methodology-analysis-report.md is empty, blocking completion" >&2
        return 1
    fi

    # Read exit reason (fail closed: missing marker blocks completion)
    if [[ ! -f "$LOOP_DIR/.methodology-exit-reason" ]]; then
        echo "Error: .methodology-exit-reason marker missing, cannot determine terminal state" >&2
        return 1
    fi

    local exit_reason
    exit_reason=$(cat "$LOOP_DIR/.methodology-exit-reason" 2>/dev/null || echo "")
    exit_reason=$(echo "$exit_reason" | tr -d '[:space:]')

    # Validate exit reason (fail closed on invalid values)
    case "$exit_reason" in
        complete|stop|maxiter)
            ;;
        *)
            echo "Error: Invalid methodology exit reason '$exit_reason', blocking completion" >&2
            return 1
            ;;
    esac

    # Rename methodology-analysis-state.md to the terminal state
    local target_name="${exit_reason}-state.md"
    mv "$LOOP_DIR/methodology-analysis-state.md" "$LOOP_DIR/$target_name"
    echo "Methodology analysis complete. State preserved as: $LOOP_DIR/$target_name" >&2

    # Clean up marker file
    rm -f "$LOOP_DIR/.methodology-exit-reason"

    return 0
}

# Block exit because methodology analysis is incomplete
#
# Outputs a block JSON instructing Claude to complete the analysis before exiting.
#
# Globals read:
#   LOOP_DIR - path to the loop directory
#
block_methodology_analysis_incomplete() {
    local done_file="$LOOP_DIR/methodology-analysis-done.md"

    local reason="# Methodology Analysis Incomplete

Please complete the methodology analysis before exiting.

You need to:
1. Spawn an Opus agent to analyze the development records
2. Review the analysis report
3. Optionally help the user file a GitHub issue
4. Write a completion note to: $done_file

The completion marker file must contain actual content (not be empty) to signal that the analysis is done."

    jq -n \
        --arg reason "$reason" \
        --arg msg "Loop: Methodology Analysis Phase - please complete the analysis" \
        '{
            "decision": "block",
            "reason": $reason,
            "systemMessage": $msg
        }'
}
