# Code Review - Round {{CURRENT_ROUND}}

## Original Implementation Plan

**IMPORTANT**: The original plan that Claude is implementing is located at:
@{{PLAN_FILE}}

You MUST read this plan file first to understand the full scope of work before conducting your review.
This plan contains the complete requirements and implementation details that Claude should be following.

Based on the original plan and @{{PROMPT_FILE}}, Claude claims to have completed the work. Please conduct a thorough critical review to verify this.

---
Below is Claude's summary of the work completed:
<!-- CLAUDE's WORK SUMMARY START -->
{{SUMMARY_CONTENT}}
<!-- CLAUDE's WORK SUMMARY  END  -->
---

## Part 1: Implementation Review

- Your task is to conduct a deep critical review, focusing on finding implementation issues and identifying gaps between "plan-design" and actual implementation.
- Relevant top-level guidance documents, phased implementation plans, and other important documentation and implementation references are located under @{{DOCS_PATH}}.
- If Claude planned to defer any tasks to future phases in its summary, DO NOT follow its lead. Instead, you should force Claude to complete ALL tasks as planned.
  - Such deferred tasks are considered incomplete work and should be flagged in your review comments, requiring Claude to address them.
  - If Claude planned to defer any tasks, please explore the codebase in-depth and draft a detailed implementation plan. This plan should be included in your review comments for Claude to follow.
  - Your review should be meticulous and skeptical. Look for any discrepancies, missing features, incomplete implementations.
- If Claude does not plan to defer any tasks, but honestly admits that some tasks are still pending (not yet completed), you should also include those pending tasks in your review.
  - Your review should elaborate on those unfinished tasks, explore the codebase, and draft an implementation plan.
  - A good engineering implementation plan should be **singular, directive, and definitive**, rather than discussing multiple possible implementation options.
  - The implementation plan should be **unambiguous**, internally consistent, and coherent from beginning to end, so that **Claude can execute the work accurately and without error**.

## Part 2: Goal Alignment Check (MANDATORY)

Read @{{GOAL_TRACKER_FILE}} and verify:

1. **Acceptance Criteria Progress**: For each AC, is progress being made? Are any ACs being ignored?
2. **Forgotten Items**: Are there tasks from the original plan that are not tracked in Active/Completed/Deferred?
3. **Deferred Items**: Are deferrals justified? Do they block any ACs?
4. **Plan Evolution**: If Claude modified the plan, is the justification valid?

Include a brief Goal Alignment Summary in your review:
```
ACs: X/Y addressed | Forgotten items: N | Unjustified deferrals: N
```

## Part 3: Failure-Surface Coverage Pass (MANDATORY)

Before you write those lane findings, you MUST first run a failure-surface coverage pass:

0. **Historical Tail-Repair Scan**
   - Before you settle on a narrow diff-only review, inspect recent git history.
   - Start with `git log --oneline --stat -n 12` to understand the recent repair pattern.
   - If the current round appears to touch a hotspot file or module, also inspect file-scoped history such as `git log --stat -- <path>`.
   - Treat these as a long-tail repair-chain signal:
     - repeated small `fix` commits
     - repeated review-blocker fixes in the same file or module
     - several follow-up patches that only nibble at one hotspot
   - If you detect that signal, widen your review strategy beyond the latest patch:
     - inspect neighboring call sites in the hotspot
     - inspect sibling state transitions and rollback paths
     - look for system-level consistency failures, not just the newest local diff defect
   - Reflect that broader scan in `Touched Failure Surfaces`, `Likely Sibling Risks`, and `Coverage Ledger`.

1. **Touched Failure Surfaces**
   - Map the high-risk failure surfaces touched by this round's diff, summary claims, and changed tests.
   - Prefer system-oriented surfaces such as lifecycle symmetry, rollback correctness, resource cleanup, state consistency, snapshot/projection consistency, dependency propagation, and cross-subsystem synchronization.
   - If the git history shows a long-tail repair chain around one hotspot, prefer naming the broader failure surface instead of reporting only a single-file symptom.
   - Keep this section concise, but do not skip it just because you already found one bug.
   - Use this exact bullet format so the runtime can retain the analysis:
     - `- <surface> | why: <reason> | confidence: high|medium|low`

2. **Likely Sibling Risks**
   - For each confirmed issue, expand at least one round further across sibling paths:
     - symmetric paths
     - parallel resources
     - adjacent state transitions
     - neighboring call sites in the same hotspot module
   - If the git history shows repeated small fixes in the same hotspot, increase skepticism and search wider before you stop.
   - Report high-confidence sibling risks even if they are not yet as strongly confirmed as the main finding.
   - Use this exact bullet format:
     - `- <risk summary> | derived_from: <finding or surface> | axis: <expansion axis> | why: <why likely> | check: <recommended check> | confidence: high|medium|low`

3. **Coverage Ledger**
   - Close the review with a short coverage ledger describing which touched failure surfaces are `covered`, `partial`, or `unclear`.
   - **Do NOT render the Coverage Ledger as `-` / `*` bullet findings.** Use a markdown table or short plain-text paragraphs instead.
   - This is required because Humanize currently parses lane bullets into machine-managed findings.
   - Preferred format:
     ```
     | Surface | Status | Notes |
     |---------|--------|-------|
     | rollback-symmetry | partial | cancel path checked; restore path still unclear |
     ```

Also include a one-line verdict:
```
Mainline Progress Verdict: ADVANCED / STALLED / REGRESSED
```

This verdict line is mandatory. If you omit it, the Humanize stop hook will block the round and require the review to be rerun.

If Claude mostly worked on queued side issues and failed to advance the mainline, say so explicitly.

## Part 4: Required Finding Classification

You MUST classify your findings into these lanes:
- **Mainline Gaps**: plan-derived work or AC progress that is missing, incomplete, or regressing
- **Blocking Side Issues**: bugs or implementation issues that block the current mainline objective from succeeding safely
- **Queued Side Issues**: valid non-blocking follow-up issues that should be documented but must NOT take over the next round

## Part 5: {{GOAL_TRACKER_UPDATE_SECTION}}

## Part 6: Output Requirements

- In short, your review comments can include: problems/findings/blockers; claims that don't match reality; implementation plans for deferred work (to be implemented now); implementation plans for unfinished work; goal alignment issues.
- Your output should be structured in this order:
  1. `Touched Failure Surfaces`
  2. `Likely Sibling Risks`
  3. `Mainline Gaps`
  4. `Blocking Side Issues`
  5. `Queued Side Issues`
  6. `Mainline Progress Verdict`
  7. `Coverage Ledger`
- Keep the lane headings exactly as written above so the runtime can continue to classify findings safely.
- Keep lane findings as explicit issue bullets, preferably with `[P0-9]` severity markers.
- If after your investigation the actual situation does not match what Claude claims to have completed, or there is pending work to be done, output your review comments to @{{REVIEW_RESULT_FILE}}.
- **CRITICAL**: Only output "COMPLETE" as the last line if ALL tasks from the original plan are FULLY completed with no deferrals
  - DEFERRED items are considered INCOMPLETE - do NOT output COMPLETE if any task is deferred
  - UNFINISHED items are considered INCOMPLETE - do NOT output COMPLETE if any task is pending
  - The ONLY condition for COMPLETE is: all original plan tasks are done, all ACs are met, no deferrals or pending work allowed
- The word COMPLETE on the last line will stop Claude.
