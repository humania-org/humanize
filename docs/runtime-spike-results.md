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

Spike run: 2026-04-29, idea "explore-idea-progress-display", 2 directions (ansi-live-rewrite, coordinator-activity-log), max-worker-iterations 1. Executed manually following `commands/explore-idea.md` because `humanize:explore-idea` skill is not registered in the cached 1.16.0 plugin (it is a 1.17.0 feature). The skill would be invoked automatically post-merge.

### Phase 1: IO Validation
- [x] `validate-explore-idea-io.sh` runs and emits all required keys — ran manually; emitted RUN_DIR, DIRECTIONS_JSON_FILE, SELECTED_IDS, etc.
- [x] `DIRECTIONS_JSON_FILE` points to a schema-valid file — `validate-directions-json.sh` returned VALIDATION_SUCCESS; 6 directions, schema_version 1
- [x] `RUN_DIR` path is under `.humanize/explore/<RUN_ID>/` — `.humanize/explore/2026-04-29_16-33-06/`

### Phase 2: Confirmation
- [~] Dispatch plan displayed to user before any side effects — manually verified parameters before dispatch; AskUserQuestion not exercised (skill not registered)
- [~] User confirmation required (`[y/N]` prompt shown) — `AskUserQuestion` confirmed present in `commands/explore-idea.md` allowed-tools (AC-6); not auto-invoked in manual run
- [~] Confirmation dialog shows all expected parameters (direction IDs, concurrency, timeouts, base branch, base commit, run directory, mutation warning) — all parameters verified manually; dialog UI not tested end-to-end

### Phase 3: Run State Initialization
- [x] Run directory created: `.humanize/explore/<RUN_ID>/` — `.humanize/explore/2026-04-29_16-33-06/` created before any worker dispatch
- [x] `dispatch-prompts/` subdirectory created — both `dir-01-ansi-live-rewrite.md` and `dir-06-coordinator-activity-log.md` present
- [x] `manifest.json` written before any workers start — verified with timestamp; both workers had `status: pending` in manifest at dispatch time (AC-7)
- [x] Each direction has a per-worker entry with `status: pending` in manifest — confirmed via `jq '.workers[] | .status'` before dispatch

### Phase 4: Worker Dispatch
- [x] Workers dispatched in parallel (single Agent-tool message) — both Task invocations sent in a single message with `isolation: "worktree"` and `run_in_background: true`
- [x] Workers run in isolated git worktrees (`isolation: "worktree"`) — worktrees at `.claude/worktrees/agent-a7a6059b` and `.claude/worktrees/agent-afee2c9b`
- [x] No branches pushed to remote — `git branch -r | grep explore/2026-04-29_16-33-06` returned empty

### Phase 5: Result Collection
- [x] `worker-results.jsonl` created with one entry per worker — 2 lines, one per direction
- [x] Each entry has valid JSON with all required fields — `jq` parsed both entries successfully; all schema_version, direction_id, task_status, codex_final_verdict, tests_passed/failed, commit_sha present
- [ ] Workers that failed emit coordinator-generated failure rows — not tested; both workers succeeded

### Phase 6: Report Synthesis
- [x] `report.md` created with two-tier ranking tables — `.humanize/explore/2026-04-29_16-33-06/report.md` written with Tier 1 (product) and Tier 2 (implementation) ranking tables
- [x] Tier 1 ranks by product direction quality — ANSI Live Rewrite ranked first (primary direction, more direct user value)
- [x] Tier 2 ranks by implementation readiness — Coordinator Activity Log ranked first (46 tests vs 23; broader coverage)
- [x] Adoption paths include correct worktree/branch/commit data — all paths, SHAs, and branch names match actual run artifacts

### Worker Isolation
- [x] Each worker modifies only files within its assigned worktree; no files outside the worktree are created or changed — both workers created new files only under their respective worktrees; main checkout unchanged
- [x] Workers do not invoke nested Skills or slash commands during execution — worker-prompt.md explicitly prohibits this; verified in worker summary
- [x] Workers do not spawn nested Agent/Task workers — single RLCR-equivalent loop; no nested dispatch observed
- [x] Workers do not push any branch to any remote — verified via `git branch -r`
- [x] Workers do not access or read sibling worktrees — no cross-worktree file access; isolation enforced by `worktree` mode

### Concurrency and Coordination
- [x] Multiple workers dispatch in parallel (not serially), bounded by the configured `--concurrency` value — both workers dispatched simultaneously in single Task tool message; concurrency=2
- [x] Coordinator waits for all workers to complete within a single session without manual intervention — both completed and results collected in same session
- [ ] Worker timeouts are enforced; a timed-out worker produces a coordinator-generated `task_status: "timeout"` row rather than hanging indefinitely — not tested; both workers completed within time limit

### Codex Root Scoping
- [~] `export CLAUDE_PROJECT_DIR="$PWD"` inside a worker worktree correctly scopes `ask-codex.sh` to that worktree's path, not the coordinator checkout — each worker ran ask-codex.sh in its worktree; no cross-checkout contamination observed; not explicitly traced
- [~] `ask-codex.sh` auto-probe behavior correctly disables nested Codex hooks during a live worker session — Codex ran within each worker's context; no hook conflicts observed in results; not explicitly instrumented
- [x] No worker Codex call accidentally reads or modifies the coordinator checkout — main checkout at `85cba42` unchanged throughout; both workers committed only to their worktree branches

### Worker Result Collection
- [~] Sentinel markers (`=== EXPLORE_RESULT_JSON_BEGIN ===` / `=== EXPLORE_RESULT_JSON_END ===`) are emitted by workers and parsed correctly by the coordinator — workers followed the sentinel protocol per worker-prompt.md; manual collection in this spike (skill not registered); production coordinator script would parse these
- [x] `worker-results.jsonl` contains exactly one row per dispatched worker after all workers complete — exactly 2 rows for 2 workers; `wc -l` = 2
- [ ] A worker that fails, times out, or emits malformed JSON produces a coordinator-generated row; no result is silently dropped — not tested; both workers succeeded

### Artifact Integrity
- [x] `manifest.json` exists and is complete with all required fields before the first worker starts work — written with all required fields (run_id, created_at, base_branch, base_commit, workers array, etc.) before dispatch
- [x] `dispatch-prompts/<direction_id>.md` contains the actual prompt text sent to each worker — both `dir-01-ansi-live-rewrite.md` and `dir-06-coordinator-activity-log.md` contain complete prompt text including worker-prompt.md template content
- [x] Branch names follow the exact `explore/<RUN_ID>/<dir_slug>` format — `explore/2026-04-29_16-33-06/ansi-live-rewrite` and `explore/2026-04-29_16-33-06/coordinator-activity-log` confirmed
- [x] Each successful worker branch has at least one commit with the prototype changes — 2 commits each (initial + Codex review fix round)

### Report Quality
- [x] `report.md` contains both ranking tiers with coherent synthesis derived from actual worker result data — both tables populated from actual worker-results.jsonl entries; rationale sections synthesize real observations
- [x] Adoption paths in the report contain the correct worktree path, branch name, and commit SHA for each worker — verified against manifest.json and worker-results.jsonl
- [x] Cleanup guidance accurately describes the real worktrees and branches created during the run — `git worktree list` confirms both worktrees; cleanup commands use exact paths

### UX Correctness
- [~] The confirmation dialog shows all expected parameters (direction IDs, concurrency, timeouts, base branch, base commit, run directory, mutation warning) before any worker is dispatched — confirmed via `AskUserQuestion` in allowed-tools (AC-6); not exercised end-to-end because skill not registered
- [~] The end-to-end `gen-idea` → `explore-idea <draft.md>` workflow resolves the companion JSON and proceeds without extra steps — `gen-idea` (1.16.0) does not emit `.directions.json`; companion JSON was written manually then validated; 1.17.0 would handle this automatically
- [x] Report adoption path commands are correct and immediately usable (e.g., `/humanize:start-rlcr-loop` with the right worktree path) — paths verified against `git worktree list` output

### Input Safety
- [ ] Invoking `explore-idea` with uncommitted tracked changes in the main checkout exits non-zero before the confirmation dialog, before any manifest is written, and before any worktree is created — not tested; main checkout was clean during run
- [ ] Invoking `explore-idea` when the run directory already exists exits non-zero with a collision error before any writes — not tested; `validate-explore-idea-io.sh` has collision detection but not exercised

### Coordinator Error Handling
- [ ] A coordinator-side failure after dispatch begins (e.g., result collection error for one worker) records the failure row in `worker-results.jsonl` and allows remaining workers to finish; `.failed` is not written unless all workers fail — not tested; both workers succeeded
- [ ] When all workers fail: `.failed` is written, `manifest.json` is updated with failure reason, and no success `report.md` is produced — not tested

### No-Push Safety
- [x] No `git push` occurred on any worker branch after the run completes — `git branch -r | grep explore/2026-04-29_16-33-06` returned empty
- [x] The main checkout is in the same state as before `explore-idea` was invoked (no uncommitted changes introduced by the coordinator) — `git status` on main checkout shows no changes; `git log --oneline -1` still at `85cba42`

## Spike Run Results

| Date | Idea Input | N Directions | Workers Run | Report Path | Notes |
|------|-----------|--------------|-------------|-------------|-------|
| 2026-04-29 | explore-idea-progress-display (Live ANSI Status Dashboard) | 6 generated, 2 selected (ansi-live-rewrite, coordinator-activity-log) | 2 | `.humanize/explore/2026-04-29_16-33-06/report.md` | Manual execution (skill not registered in cached 1.16.0). Both workers: success, codex partial, 0 test failures. 23 + 46 tests created. No push. Confirmation UX and failure-path not tested. gen-idea .directions.json companion written manually (1.16.0 does not emit it). |
