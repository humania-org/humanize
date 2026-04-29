# Runtime Spike Results — explore-idea

This document records the results of the post-RLCR functional spike for `/humanize:explore-idea`.

## How to Run

After the RLCR loop completes and the PR is merged, execute the following sequence in a real session:

```bash
# Step 1: Generate an idea draft with directions.json companion
/humanize:gen-idea "add undo/redo to the editor"

# Step 2: Run explore-idea with the emitted directions.json
/humanize:explore-idea .humanize/ideas/<slug>-<timestamp>.directions.json \
    --max-worker-iterations 1
```

## Functional Spike Checklist

Record each item as `[x]` (passed), `[~]` (partial), or `[ ]` (failed/skipped) after the spike run. Include brief observation notes.

### Phase 1: IO Validation
- [ ] `validate-explore-idea-io.sh` runs and emits all required keys
- [ ] `DIRECTIONS_JSON_FILE` points to a schema-valid file
- [ ] `RUN_DIR` path is under `.humanize/explore/<RUN_ID>/`

### Phase 2: Confirmation
- [ ] Dispatch plan displayed to user before any side effects
- [ ] User confirmation required (`[y/N]` prompt shown)
- [ ] Confirmation dialog shows all expected parameters (direction IDs, concurrency, timeouts, base branch, base commit, run directory, mutation warning)

### Phase 3: Run State Initialization
- [ ] Run directory created: `.humanize/explore/<RUN_ID>/`
- [ ] `dispatch-prompts/` subdirectory created
- [ ] `manifest.json` written before any workers start
- [ ] Each direction has a per-worker entry with `status: pending` in manifest

### Phase 4: Worker Dispatch
- [ ] Workers dispatched in parallel (single Agent-tool message)
- [ ] Workers run in isolated git worktrees (`isolation: "worktree"`)
- [ ] No branches pushed to remote

### Phase 5: Result Collection
- [ ] `worker-results.jsonl` created with one entry per worker
- [ ] Each entry has valid JSON with all required fields
- [ ] Workers that failed emit coordinator-generated failure rows

### Phase 6: Report Synthesis
- [ ] `report.md` created with two-tier ranking tables
- [ ] Tier 1 ranks by product direction quality
- [ ] Tier 2 ranks by implementation readiness
- [ ] Adoption paths include correct worktree/branch/commit data

### Worker Isolation
- [ ] Each worker modifies only files within its assigned worktree; no files outside the worktree are created or changed
- [ ] Workers do not invoke nested Skills or slash commands during execution
- [ ] Workers do not spawn nested Agent/Task workers
- [ ] Workers do not push any branch to any remote
- [ ] Workers do not access or read sibling worktrees

### Concurrency and Coordination
- [ ] Multiple workers dispatch in parallel (not serially), bounded by the configured `--concurrency` value
- [ ] Coordinator waits for all workers to complete within a single session without manual intervention
- [ ] Worker timeouts are enforced; a timed-out worker produces a coordinator-generated `task_status: "timeout"` row rather than hanging indefinitely

### Codex Root Scoping
- [ ] `export CLAUDE_PROJECT_DIR="$PWD"` inside a worker worktree correctly scopes `ask-codex.sh` to that worktree's path, not the coordinator checkout
- [ ] `ask-codex.sh` auto-probe behavior correctly disables nested Codex hooks during a live worker session
- [ ] No worker Codex call accidentally reads or modifies the coordinator checkout

### Worker Result Collection
- [ ] Sentinel markers (`=== EXPLORE_RESULT_JSON_BEGIN ===` / `=== EXPLORE_RESULT_JSON_END ===`) are emitted by workers and parsed correctly by the coordinator
- [ ] `worker-results.jsonl` contains exactly one row per dispatched worker after all workers complete
- [ ] A worker that fails, times out, or emits malformed JSON produces a coordinator-generated row; no result is silently dropped

### Artifact Integrity
- [ ] `manifest.json` exists and is complete with all required fields before the first worker starts work
- [ ] `dispatch-prompts/<direction_id>.md` contains the actual prompt text sent to each worker
- [ ] Branch names follow the exact `explore/<RUN_ID>/<dir_slug>` format
- [ ] Each successful worker branch has at least one commit with the prototype changes

### Report Quality
- [ ] `report.md` contains both ranking tiers with coherent synthesis derived from actual worker result data
- [ ] Adoption paths in the report contain the correct worktree path, branch name, and commit SHA for each worker
- [ ] Cleanup guidance accurately describes the real worktrees and branches created during the run

### UX Correctness
- [ ] The confirmation dialog shows all expected parameters (direction IDs, concurrency, timeouts, base branch, base commit, run directory, mutation warning) before any worker is dispatched
- [ ] The end-to-end `gen-idea` → `explore-idea <draft.md>` workflow resolves the companion JSON and proceeds without extra steps
- [ ] Report adoption path commands are correct and immediately usable (e.g., `/humanize:start-rlcr-loop` with the right worktree path)

### Input Safety
- [ ] Invoking `explore-idea` with uncommitted tracked changes in the main checkout exits non-zero before the confirmation dialog, before any manifest is written, and before any worktree is created
- [ ] Invoking `explore-idea` when the run directory already exists exits non-zero with a collision error before any writes

### Coordinator Error Handling
- [ ] A coordinator-side failure after dispatch begins (e.g., result collection error for one worker) records the failure row in `worker-results.jsonl` and allows remaining workers to finish; `.failed` is not written unless all workers fail
- [ ] When all workers fail: `.failed` is written, `manifest.json` is updated with failure reason, and no success `report.md` is produced

### No-Push Safety
- [ ] No `git push` occurred on any worker branch after the run completes
- [ ] The main checkout is in the same state as before `explore-idea` was invoked (no uncommitted changes introduced by the coordinator)

## Spike Run Results

| Date | Idea Input | N Directions | Workers Run | Report Path | Notes |
|------|-----------|--------------|-------------|-------------|-------|
| (pending) | | | | | Run post-RLCR loop completion |
