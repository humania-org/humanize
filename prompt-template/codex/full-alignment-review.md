# FULL GOAL ALIGNMENT CHECK - Round {{CURRENT_ROUND}}

This is a **mandatory checkpoint** (at configurable intervals). You must conduct a comprehensive goal alignment audit.

## Original Implementation Plan

**IMPORTANT**: The original plan that Claude is implementing is located at:
@{{PLAN_FILE}}

You MUST read this plan file first to understand the full scope of work before conducting your review.

---
## Claude's Work Summary
<!-- CLAUDE's WORK SUMMARY START -->
{{SUMMARY_CONTENT}}
<!-- CLAUDE's WORK SUMMARY  END  -->
---

## Part 1: Goal Tracker Audit (MANDATORY)

Read @{{GOAL_TRACKER_FILE}} and verify:

### 1.1 Acceptance Criteria Status
For EACH Acceptance Criterion in the IMMUTABLE SECTION:
| AC | Status | Evidence (if MET) | Blocker (if NOT MET) | Justification (if DEFERRED) |
|----|--------|-------------------|---------------------|----------------------------|
| AC-1 | MET / PARTIAL / NOT MET / DEFERRED | ... | ... | ... |
| ... | ... | ... | ... | ... |

### 1.2 Forgotten Items Detection
Compare the original plan (@{{PLAN_FILE}}) with the current goal-tracker:
- Are there tasks that are neither in "Active", "Completed", nor "Deferred"?
- Are there tasks marked "complete" in summaries but not verified?
- List any forgotten items found.

### 1.3 Deferred Items Audit
For each item in "Explicitly Deferred":
- Is the deferral justification still valid?
- Should it be un-deferred based on current progress?
- Does it contradict the Ultimate Goal?

### 1.4 Goal Completion Summary
```
Acceptance Criteria: X/Y met (Z deferred)
Active Tasks: N remaining
Estimated remaining rounds: ?
Critical blockers: [list if any]
```

## Part 2: Mainline Drift Audit (MANDATORY)

Determine whether the recent rounds are still serving the original plan:
- Is the current round's mainline objective clear and singular?
- Has Claude been advancing mainline ACs, or mostly clearing side issues?
- Which findings are true **blocking side issues** versus merely **queued side issues**?

Include a short drift summary:
```
Mainline Progress Verdict: ADVANCED / STALLED / REGRESSED
Blocking Side Issues: N
Queued Side Issues: N
```

The `Mainline Progress Verdict` line is mandatory. If you omit it, the Humanize stop hook will block the round and require the review to be rerun.

## Part 3: Implementation Review

- Conduct a deep critical review of the implementation
- Verify Claude's claims match reality
- Identify any gaps, bugs, or incomplete work
- Reference @{{DOCS_PATH}} for design documents

## Part 4: Failure-Surface Coverage Pass (MANDATORY)

Before you write the final lane findings, you MUST expand review coverage across the touched failure surfaces:

0. **Historical Tail-Repair Scan**
   - Inspect recent git history before you settle on a narrow diff-only review.
   - Start with `git log --oneline --stat -n 20` to understand the recent repair pattern.
   - If the current round or recent rounds keep touching the same hotspot file or module, also inspect file-scoped history such as `git log --stat -- <path>`.
   - Treat these as a long-tail repair-chain signal:
     - repeated small `fix` commits
     - repeated blocker cleanup in the same file or module
     - several follow-up patches that keep revisiting one hotspot
   - If that signal appears, widen the audit:
     - inspect neighboring call sites in the hotspot
     - inspect sibling lifecycle and rollback paths
     - search for system-level consistency failures beyond the newest local patch
   - Reflect that broader scan in `Touched Failure Surfaces`, `Likely Sibling Risks`, and `Coverage Ledger`.

1. **Touched Failure Surfaces**
   - Map the high-risk failure surfaces touched by the recent diff, summaries, and changed tests.
   - Prefer system-oriented surfaces such as lifecycle symmetry, rollback correctness, resource cleanup, state consistency, snapshot/projection consistency, dependency propagation, and cross-subsystem synchronization.
   - If the git history shows a long-tail repair chain, prefer the broader failure surface over a single-file symptom label.
   - Use this exact bullet format so the runtime can retain the analysis:
     - `- <surface> | why: <reason> | confidence: high|medium|low`

2. **Likely Sibling Risks**
   - For each confirmed issue, extend the search into sibling paths:
     - symmetric paths
     - parallel resources
     - adjacent state transitions
     - neighboring call sites in the same hotspot module
   - If the git history shows repeated small fixes in one hotspot, increase skepticism and search wider before you stop.
   - Report high-confidence sibling risks even if they are not yet elevated into blocking findings.
   - Use this exact bullet format:
     - `- <risk summary> | derived_from: <finding or surface> | axis: <expansion axis> | why: <why likely> | check: <recommended check> | confidence: high|medium|low`

3. **Coverage Ledger**
   - End the review with a short ledger describing which touched surfaces are `covered`, `partial`, or `unclear`.
   - **Do NOT render the Coverage Ledger as `-` / `*` bullet findings.** Use a markdown table or short plain-text paragraphs instead.
   - This preserves compatibility with the current finding parser.
   - Preferred format:
     ```
     | Surface | Status | Notes |
     |---------|--------|-------|
     | rollback-symmetry | partial | cancel path checked; restore path still unclear |
     ```

## Part 5: {{GOAL_TRACKER_UPDATE_SECTION}}

## Part 6: Progress Stagnation Check (MANDATORY for Full Alignment Rounds)

To implement the original plan at @{{PLAN_FILE}}, we have completed **{{COMPLETED_ITERATIONS}} iterations** (Round 0 to Round {{CURRENT_ROUND}}).

The project's `.humanize/rlcr/{{LOOP_TIMESTAMP}}/` directory contains the history of each round's iteration:
- Round input prompts: `round-N-prompt.md`
- Round output summaries: `round-N-summary.md`
- Round review prompts: `round-N-review-prompt.md`
- Round review results: `round-N-review-result.md`

**How to Access Historical Files**: Read the historical review results and summaries using file paths like:
- `@.humanize/rlcr/{{LOOP_TIMESTAMP}}/round-{{PREV_ROUND}}-review-result.md` (previous round)
- `@.humanize/rlcr/{{LOOP_TIMESTAMP}}/round-{{PREV_PREV_ROUND}}-review-result.md` (2 rounds ago)
- `@.humanize/rlcr/{{LOOP_TIMESTAMP}}/round-{{PREV_ROUND}}-summary.md` (previous summary)

**Your Task**: Review the historical review results, especially the **recent rounds** of development progress and review outcomes, to determine if the development has stalled.

**Signs of Stagnation** (circuit breaker triggers):
- Same issues appearing repeatedly across multiple rounds
- No meaningful progress on Acceptance Criteria over several rounds
- Claude making the same mistakes repeatedly
- Circular discussions without resolution
- No new code changes despite continued iterations
- Codex giving similar feedback repeatedly without Claude addressing it

**If development is stagnating**, write **STOP** (as a single word on its own line) as the last line of your review output @{{REVIEW_RESULT_FILE}} instead of COMPLETE.

## Part 7: Output Requirements

- If issues found OR any AC is NOT MET (including deferred ACs), write your findings to @{{REVIEW_RESULT_FILE}}
- Structure the review in this order:
  1. `Touched Failure Surfaces`
  2. `Likely Sibling Risks`
  3. `Mainline Gaps`
  4. `Blocking Side Issues`
  5. `Queued Side Issues`
  6. `Mainline Progress Verdict`
  7. `Coverage Ledger`
- Include specific action items for Claude to address, classified into:
  - Mainline Gaps
  - Blocking Side Issues
  - Queued Side Issues
- Keep the lane headings exactly as written above so the runtime can continue to classify findings safely.
- Keep lane findings as explicit issue bullets, preferably with `[P0-9]` severity markers.
- **If development is stagnating** (see Part 6), write "STOP" as the last line
- **CRITICAL**: Only write "COMPLETE" as the last line if ALL ACs from the original plan are FULLY MET with no deferrals
  - DEFERRED items are considered INCOMPLETE - do NOT output COMPLETE if any AC is deferred
  - The ONLY condition for COMPLETE is: all original plan tasks are done, all ACs are met, no deferrals allowed
