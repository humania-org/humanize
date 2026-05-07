Your work is not finished. Read and execute the below with ultrathink.

## Original Implementation Plan

**IMPORTANT**: Before proceeding, review the original plan you are implementing:
@{{PLAN_FILE}}

This plan contains the full scope of work and requirements. Ensure your work aligns with this plan.

---

## Round Re-anchor (REQUIRED FIRST STEP)

Before writing code:
- Re-read @{{PLAN_FILE}}
- Re-read @{{GOAL_TRACKER_FILE}}
- Re-read the most recent round summaries/reviews that led to this round
- Write the current round contract to @{{ROUND_CONTRACT_FILE}}

Your round contract must contain:
- Exactly one **mainline objective**
- The 1-2 target ACs for this round
- Which issues are truly **blocking** that mainline objective
- Which issues are **queued** and explicitly out of scope
- Concrete success criteria for this round

Do not start implementation until the round contract exists.

## Task Lane Rules

Use the Task system (TaskCreate, TaskUpdate, TaskList) with one required tag per task:
- `[mainline]` for plan-derived work that directly advances this round's objective
- `[blocking]` for issues that prevent the mainline objective from succeeding safely
- `[queued]` for non-blocking bugs, cleanup, or follow-up work

Rules:
- `[mainline]` work is the round's primary success condition
- `[blocking]` work is allowed only when it truly blocks the mainline objective
- `[queued]` work must be documented but must NOT replace the round objective
- If a new bug does not block the current objective, tag it `[queued]` and keep moving on mainline work

Before executing each task in this round:
1. Read @{{BITLESSON_FILE}}
2. Run `bitlesson-selector` for each task/sub-task
3. Follow selected lesson IDs (or `NONE`) during implementation

---
Below is Codex's review result:
<!-- CODEX's REVIEW RESULT START -->
{{REVIEW_CONTENT}}
<!-- CODEX's REVIEW RESULT  END  -->
---

## Goal Tracker Reference

Before starting work, **read** @{{GOAL_TRACKER_FILE}} to understand:
- The Ultimate Goal and Acceptance Criteria you're working toward
- Which tasks are Active, Completed, or Deferred
- Which side issues are blocking vs queued
- Any Plan Evolution that has occurred
- The latest side-issue state that needs attention

**IMPORTANT**: Keep the mutable section of `goal-tracker.md` up to date during the round.
Do NOT change the immutable section after Round 0.
If you cannot safely reconcile the tracker yourself, include an optional "Goal Tracker Update Request" section in your summary (see below).

## Mainline Guardrails

- Keep the mainline objective from @{{ROUND_CONTRACT_FILE}} stable for this round
- Do not let queued issues take over the round
- If Codex reported several findings, classify them into:
  - mainline gaps
  - blocking side issues
  - queued side issues
- Only mainline gaps and blocking side issues should drive the next code changes

## Optional: Blocked By Methodology Invariant Block

If a Codex finding's only fix would mutate a session-byte-locked artifact (e.g., a plan file under `--track-plan-file`, a sealed witness lattice, a frozen wire-protocol), you cannot address it from inside the loop. Re-running the round shape over and over will not unstick it; the methodology will eventually trigger the stagnation circuit breaker.

When you recognise this class of impasse, include the following block in your round summary so the reviewer treats it as a high-confidence signal rather than re-issuing the same critique:

```markdown
## Blocked By Methodology Invariant

- Invariant: <invariant-name> (e.g., "plan-file-byte-lock", "witness-lattice-seven-impl-seal", "bus-v1-byte-freeze")
- Findings blocked:
  - <one-line description of finding 1>
  - <one-line description of finding 2>
- Canonical resolution: <e.g., "cancel/amend/restart with the locked artifact amended off-loop">
- Why I cannot act in-loop: <one-sentence explanation citing the relevant byte-lock or seal>
```

When this block is present, the reviewer is asked to:
1. Acknowledge the block instead of re-issuing the listed findings as `must-fix`.
2. Tag the listed findings as `out-of-loop` rather than `must-fix`.
3. Recommend the canonical resolution path.

Use this block conservatively. It is the implementer's escape hatch when the methodology's invariants prevent in-round action — it is NOT a way to defer ordinary follow-up work. Each finding in the block must be one that cannot be addressed without amending a byte-locked artifact.
