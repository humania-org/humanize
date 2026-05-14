# explore-idea Explore Report

**Run ID:** <RUN_ID>
**Base Branch:** <BASE_BRANCH>
**Base Commit:** <BASE_COMMIT>
**Created At:** <CREATED_AT>
**Explore Report:** <REPORT_PATH>
**Final Idea:** <FINAL_IDEA_PATH>

---

## Summary

<SUMMARY_PARAGRAPH>

---

## Tier 1: Best Product Direction

*Ranked by user value, strategic fit, original direction quality, evidence, and known risks. This ranking reflects the quality of the original idea directions, not prototype implementation success.*

| Rank | Direction | Confidence | Key Evidence | Known Risks |
|------|-----------|------------|--------------|-------------|
<PRODUCT_DIRECTION_RANKING_ROWS>

### Rationale

<PRODUCT_DIRECTION_RATIONALE>

---

## Tier 2: Most Implementation-Ready Prototype

*Ranked by prototype outcome: task status, Codex verdict, test results, commit status, and iteration count.*

| Rank | Direction | Status | Codex | Tests | Commits | Iterations |
|------|-----------|--------|-------|-------|---------|------------|
<IMPLEMENTATION_RANKING_ROWS>

### Rationale

<IMPLEMENTATION_RANKING_RATIONALE>

---

## Worker Results

<WORKER_RESULT_ENTRIES>

---

## Adoption Paths

### Recommended: Generate Plan From Final Idea

Use the plan-ready final idea synthesis as the default productization path. This treats the explore run as research, starts implementation from a clean plan, and keeps worker prototype state optional.

```bash
/humanize:gen-plan --input <FINAL_IDEA_PATH> --output <plan-path>
/humanize:start-rlcr-loop <plan-path>
```

### Prototype Fast Path: Continue Winner Branch

Use this only when the top-ranked prototype is already clearly worth preserving and you want RLCR to review or finalize the mutated worker worktree state:

```bash
# Navigate to the winner's worktree
cd <WINNER_WORKTREE_PATH>

# Branch: <WINNER_BRANCH_NAME>
# Commit: <WINNER_COMMIT_SHA>

# Start RLCR loop from the prototype state
/humanize:start-rlcr-loop --skip-impl
```

### Cherry-Pick Prototype

To cherry-pick specific commits from a prototype branch:

```bash
git cherry-pick <COMMIT_SHA>
# Verify the base branch matches before cherry-picking.
```

### Discard Non-Adopted Prototypes

Remove worktrees and branches for directions you are not adopting:

```bash
<CLEANUP_COMMANDS>
```

---

## All Worker Details

<ALL_WORKER_DETAILS>

---

## Cleanup Reference

All explore run artifacts are stored in:

```
.humanize/explore/<RUN_ID>/
  manifest.json           — coordinator state and per-worker metadata
  dispatch-prompts/       — exact prompts sent to each worker
  worker-results.jsonl    — machine-readable result rows
  explore-report.md       — audit, ranking, adoption, and cleanup report
  final-idea.md           — plan-ready synthesis artifact for gen-plan
```

To remove all local explore artifacts for this run:
```bash
# Remove worktrees
<ALL_WORKTREE_REMOVE_COMMANDS>

# Remove branches
<ALL_BRANCH_DELETE_COMMANDS>

# Remove run directory (optional, for cleanup)
# rm -rf ".humanize/explore/<RUN_ID>"
```
