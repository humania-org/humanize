Your work is not finished. Read and execute the below with ultrathink.

## Drift Recovery Mode

Codex judged the recent implementation rounds as failing to advance the mainline.

- Consecutive stalled/regressed rounds: {{STALL_COUNT}}
- Last mainline verdict: {{LAST_MAINLINE_VERDICT}}

This round is a **drift recovery round**. Do not continue with normal issue-clearing behavior.

## Original Implementation Plan

**IMPORTANT**: Re-anchor on the original plan first:
@{{PLAN_FILE}}

## Required Recovery Re-anchor

Before changing code:
- Re-read @{{PLAN_FILE}}
- Re-read @{{GOAL_TRACKER_FILE}}
{{SCENARIO_MATRIX_REANCHOR_STEPS}}
- Re-read the recent round summaries and review results that led here
- Rewrite the round contract at @{{ROUND_CONTRACT_FILE}}

Your recovery contract must contain:
- Exactly one recovered **mainline objective**
- The 1-2 target ACs that prove mainline progress this round
- The root cause of recent drift or stagnation
- Which issues are truly **blocking** the recovered mainline objective
- Which issues remain **queued** and explicitly out of scope
- Concrete success criteria that would change the verdict back to `ADVANCED`

Do not start implementation until the recovery contract exists.

{{SCENARIO_MATRIX_MAINLINE_BLOCK}}

Treat the Current Task Packet and Manager Checkpoint as manager-issued recovery scope.
Do not rewrite authoritative matrix state directly; report packet corrections or task-shape concerns through the summary feedback section.

## Task Lane Rules

Use the Task system (TaskCreate, TaskUpdate, TaskList) with one required tag per task:
- `[mainline]` for plan-derived work that directly advances the recovered objective
- `[blocking]` for issues that prevent the recovered mainline objective from succeeding safely
- `[queued]` for non-blocking bugs, cleanup, or follow-up work

Rules:
- This round must prove mainline movement, not just reduce noise
- `[blocking]` work is allowed only when it directly unblocks the recovered mainline objective
- `[queued]` work must stay documented but must NOT replace the recovered objective
- If a new issue does not block the recovered objective, tag it `[queued]` and keep moving on mainline work

---
Below is Codex's review result:
<!-- CODEX's REVIEW RESULT START -->
{{REVIEW_CONTENT}}
<!-- CODEX's REVIEW RESULT  END  -->
---

## Goal Tracker Reference

Before starting work, **read and update** @{{GOAL_TRACKER_FILE}} as needed:
- Keep the immutable section unchanged
- Record the drift/stagnation cause in the mutable section if it changed planning
- Keep blocking vs queued issue classification accurate
- Ensure the tracker and contract now describe the same recovered mainline objective

{{SCENARIO_MATRIX_TRACKER_NOTE}}

## Recovery Guardrails

- Do not spend this round mostly on queued cleanup
- Do not broaden scope to compensate for previous stalls
- If the original approach was flawed, log the plan evolution explicitly instead of silently changing direction
- If you cannot produce a credible recovered mainline objective, say so in the summary with concrete blockers
