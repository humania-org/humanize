# Code Review Findings

You are in the **Review Phase**. Codex has performed a code review and found issues that need to be addressed.

## Required Re-anchor

Before touching code:
- Re-read the original plan at @{{PLAN_FILE}}
- Re-read the goal tracker at @{{GOAL_TRACKER_FILE}}
{{SCENARIO_MATRIX_REANCHOR_STEPS}}
- Refresh the current round contract at @{{ROUND_CONTRACT_FILE}}

The round contract must preserve a single mainline objective. Code review findings do NOT automatically become the new round objective.

{{SCENARIO_MATRIX_MAINLINE_BLOCK}}

Treat the Current Task Packet and Manager Checkpoint as manager-issued fix scope.
Do not rewrite authoritative matrix state directly; report packet corrections or task-shape concerns through the summary feedback section.

## Review Results

{{REVIEW_CONTENT}}

## Issue Classification

Classify each review finding before acting on it:
- **blocking side issue**: prevents the current mainline objective from succeeding safely or prevents review acceptance
- **queued side issue**: valid follow-up, but does not block the current round objective

Queued issues may be documented, but they must NOT take over the round.

## Task Rules

Every task must use one lane tag:
- `[blocking]` for review findings that must be fixed now
- `[queued]` for non-blocking follow-up work

Do not create new `[mainline]` tasks in review phase unless the review proves the previous mainline objective was incomplete.

## Instructions

1. **Refresh the round contract** at `{{ROUND_CONTRACT_FILE}}`
2. **Address blocking issues first** and keep the mainline objective stable
3. **Focus on fixes only** - do not add new features or make unrelated changes
4. **Commit your changes** after fixing the issues
5. **Write your summary** to: `{{SUMMARY_FILE}}`

## Summary Template

Your summary should include:
- The mainline objective for this round
- Which blocking issues were fixed
- Which issues were reclassified as queued follow-up
- How each fixed issue was resolved
- Any issues that could not be resolved (with explanation)
- Confirmation that `goal-tracker.md` was updated if the blocking/queued issue lists changed
- A Goal Tracker Update Request only if tracker reconciliation still needs Codex help

## Important Notes

- The COMPLETE signal has no effect during the review phase
- You must address the code review findings to proceed
- After you commit and write your summary, Codex will perform another code review
- The loop continues until no `[P0-9]` issues are found
{{SCENARIO_MATRIX_TRACKER_NOTE}}
