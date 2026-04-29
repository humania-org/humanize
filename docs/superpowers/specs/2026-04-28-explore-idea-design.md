# Design: `/humanize:explore-idea` — Parallel Per-Direction RLCR Exploration

> Status: Approved (brainstorming gate). Awaiting writing-plans handoff.
> Date: 2026-04-28
> Authors: Claude Opus 4.7 (1M context) with reviewer input from Claude Opus 4.7 (general-purpose) and Codex GPT-5.4 xhigh.
> Target branches: `dev` (PR-A first, then PR-B).

---

## 1. Motivation

The existing `/humanize:gen-idea` command produces a draft enumerating N orthogonal directions for an idea, with one direction synthesized as the primary and the rest as compressed alternatives. The user must then manually pick one direction, run `/humanize:gen-plan`, and run `/humanize:start-rlcr-loop` — exploring a single direction at a time.

This design adds parallel exploration: take the N directions and run a full RLCR-equivalent loop on each one independently, in isolated git worktrees, then synthesize a comparison report. Rooted in the W2S Automated Researcher principle (parallel autonomous researchers in sandboxed environments) and the user's `gen-idea-parallel-exploration-methodology-v2.md` doctrine (parallel at the worktree-session boundary, sequential within each worker, never invoke Skills inside subagents).

## 2. Goals and non-goals

### Goals

- Enable single-command "explore each direction in parallel" workflow after `gen-idea`.
- Stay strictly within the v2 doctrine's `2N` peak concurrency bound — no recursive Skill fanout.
- Reuse Claude Code primitives (`Task` tool with `isolation: "worktree"`, `run_in_background: true`) and existing humanize primitives (`scripts/ask-codex.sh`, `.humanize/` layout, sentinel-block stdout contract) rather than inventing parallel mechanisms.
- Match `gen-idea` and `gen-plan` structural conventions so the new command feels native to the plugin.
- Produce both a deterministic ranking and an LLM-synthesized comparison report; keep the two layers separable.

### Non-goals

- Running multiple independent samples of the same direction (W2S sample-fanout). Only direction-fanout is in scope.
- Auto-pushing branches or auto-opening PRs (intentionally local-only commits).
- Cross-worker information sharing during the run.
- Replacing or wrapping `/humanize:start-rlcr-loop` for solo single-direction use.
- A `gen-idea --explore` chainer flag (deferred indefinitely; Skill-from-Skill chaining at the orchestrator level is not yet proven safe).
- Modifying `setup-rlcr-loop.sh` to be worktree-aware (deferred; workers run an inline RLCR-equivalent loop instead).

## 3. Contribution structure

This contribution lands as **two coordinated PRs**, both targeting `dev`:

- **PR-A**: amend `gen-idea` (commands/gen-idea.md and validate-gen-idea-io.sh) to additionally emit a `directions.json` companion artifact carrying the lossless per-direction proposals. Bumps version triplet to `1.16.1`.
- **PR-B**: add the `/humanize:explore-idea` command and its supporting templates and scripts. Depends on PR-A merged. Bumps version triplet to `1.17.0`.

The split is forced by a finding from the design review: the existing `gen-idea` template (`prompt-template/idea/gen-idea-template.md` lines 7–30) compresses non-primary directions to `Gist / Objective Evidence / Why not primary`, discarding each alternative's full `APPROACH_SUMMARY` from Phase 3. Without an upstream lossless artifact, `explore-idea` would either operate on degraded inputs for non-primary directions or be forced to re-run the explorer subagents to recover them.

## 4. PR-A: gen-idea amendment

### 4.1 Phase 4 add-on (Step 4.6)

After `gen-idea` Phase 4 finishes writing the draft `.md` file, add a new step:

> **Step 4.6: Write the directions companion artifact.**
> Write a `directions.json` file alongside the draft, capturing every Phase-3 surviving proposal verbatim. The path is `<OUTPUT_FILE>` with `.md` replaced by `.directions.json`. Single write, no progressive edits, no tempfile.

### 4.2 Schema for `directions.json`

```json
{
  "schema_version": 1,
  "title": "<inferred title from Step 4.2>",
  "original_idea": "<IDEA_BODY verbatim>",
  "synthesis_notes": "<lead's synthesis paragraph>",
  "metadata": {
    "n_requested": 6,
    "n_returned": 6,
    "timestamp": "2026-04-28_17-30-12",
    "draft_path": ".humanize/ideas/undo-redo-2026-04-28-17-30-12.md"
  },
  "directions": [
    {
      "index": 0,
      "is_primary": true,
      "name": "<short label>",
      "rationale": "<single-sentence rationale from Phase 2>",
      "approach_summary": "<full APPROACH_SUMMARY from Phase 3>",
      "objective_evidence": ["<bullet>", "<bullet>"],
      "known_risks": ["<bullet>", "<bullet>"],
      "confidence": "high|medium|low"
    },
    {
      "index": 1,
      "is_primary": false,
      "name": "...",
      "rationale": "...",
      "approach_summary": "...",
      "objective_evidence": ["..."],
      "known_risks": ["..."],
      "confidence": "..."
    }
  ]
}
```

- `directions` is ordered: primary first (index 0), then alternatives in the order they appear in the draft (Alt-1, Alt-2, ...).
- `objective_evidence` may contain the literal sentinel `exploratory, no concrete precedent` as a single-element list, mirroring `gen-idea`'s sentinel handling.
- All free-form text fields are English-only and contain no emoji or CJK characters (project rule).

### 4.3 Validation script change

`scripts/validate-gen-idea-io.sh` emits one additional KEY: VALUE line in its success stdout:

```
DIRECTIONS_JSON_FILE: <output-file with .md replaced by .directions.json>
```

Derivation is purely path-arithmetic; no separate validation pass needed.

### 4.4 Sync rule (CLAUDE.md addition)

Add to `.claude/CLAUDE.md`:

> The `directions.json` schema documented in `commands/gen-idea.md` Step 4.6 and consumed in `commands/explore-idea.md` Phase 1 must stay in sync. Schema changes require updating both files in the same commit.

### 4.5 Version bump (PR-A)

`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `README.md` "Current Version" line: `1.16.0` → `1.16.1`. Patch bump justified because the change is purely additive (new artifact, no behavior change to existing draft contract).

## 5. PR-B: `/humanize:explore-idea` command

### 5.1 Frontmatter

```yaml
---
description: "Explore N directions from a gen-idea draft in parallel via per-direction RLCR"
argument-hint: "<directions-json-path> [--max-rounds R]"
allowed-tools:
  - "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/validate-explore-idea-io.sh:*)"
  - "Read"
  - "Write"
  - "Task"
---
```

No `git`, no `mkdir`, no shell beyond the one whitelisted validation script. The Task tool's `isolation: "worktree"` handles all filesystem isolation; no pre-flight git operations are needed. Ranking is performed via inline LLM evaluation in Phase 7 (no script, no bash).

### 5.2 Command surface

```
/humanize:explore-idea <directions-json-path> [--max-rounds R]
```

- `<directions-json-path>` (required): path to a `directions.json` produced by gen-idea (PR-A).
- `--max-rounds R` (optional, default `5`): per-worker iteration cap on the inline RLCR loop. Renamed from `--max` to avoid colliding with `start-rlcr-loop --max N` (default 42).

There is no `--max M` (cap on directions explored). The command always explores every direction present in the JSON. Users who want fewer directions should regenerate the draft with a smaller `gen-idea --n` or hand-edit the JSON to drop entries.

### 5.3 Hard Constraint header

> **Hard Constraint: Coordinator-Side Read-Only.** This command MUST NOT modify any tracked file outside `.humanize/explore/<RUN_ID>/`. The coordinator session does not commit, push, branch, or edit code in the main checkout. All code changes happen inside isolated worker worktrees, which are fully managed by the Task tool's `isolation: "worktree"` mechanism. Each worker's prompt enforces an analogous internal constraint (no Skill invocation, no nested Task spawn, no cross-worktree access, no push). Workers may commit locally to their auto-created branch.

### 5.4 Sequential Execution Constraint header

> **Sequential Execution Constraint:** Phases 1–7 MUST execute strictly in order. Phase 4 (parallel worker dispatch) is the only intra-phase parallelism; workers themselves run independently within Phase 4 but Phase 5 (collection) does not begin until all workers have returned via background notification.

### 5.5 Phases (overview; full body in `commands/explore-idea.md`)

| Phase | Purpose | Notes |
|---|---|---|
| 1 | IO validation via `validate-explore-idea-io.sh` | Mirrors `validate-gen-idea-io.sh` exit-code table |
| 2 | Read `directions.json`; build in-memory direction list | Schema-validate; reject if 0 directions |
| 3 | Render N kickoff prompts in memory from `worker-prompt.md` template | Substitution only; no disk write |
| 4 | Single Task message dispatching N workers (`isolation: "worktree"`, `run_in_background: true`) | The only fanout step |
| 5 | Collect each worker's stdout sentinel block as background notifications arrive | No polling — event-driven |
| 6 | Build `workers.tsv` from collected sentinel blocks (status table only — no scoring) | Plain bookkeeping; no ranking yet |
| 7 | Render `synthesis-prompt.md` with all sentinel blocks + directions.json; coordinator's own LLM call performs the qualitative ranking and writes `report.md` | LLM-side judgment, not script. Run at maximum reasoning effort (Claude `/think` deep mode or codex `--effort xhigh` if delegated). No Skill, no Agent, no Task. |

### 5.6 Version bump (PR-B)

`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `README.md` "Current Version" line: `1.16.1` → `1.17.0`. Minor bump justified because a new command is added to the public surface.

## 6. Worker contract

Each worker is a `general-purpose` subagent dispatched by Task with `isolation: "worktree"` and `run_in_background: true`. It runs in an automatically-created worktree on a fresh branch. The kickoff prompt (rendered from `prompt-template/explore/worker-prompt.md`) contains the following hard constraints and workflow:

### 6.1 Hard constraints (worker prompt enforces verbatim)

- Do not invoke any Skill (no slash commands such as `/humanize:start-rlcr-loop`, `/humanize:gen-plan`, `/superpowers:brainstorming`, etc.).
- Do not spawn Task subagents (no nested fanout).
- For Codex consultation, use only `bash ${CLAUDE_PLUGIN_ROOT}/scripts/ask-codex.sh`.
- All work stays within the assigned worktree. No cross-worktree access.
- Do not push branches.
- Output ends with the sentinel block defined in 6.3.

### 6.2 Workflow

1. **Brainstorm**: read `README.md`, `CLAUDE.md`, and code files relevant to this direction. Inline reasoning only; do not spawn research subagents.
2. **Plan**: write `.humanize/explore/<DIR_SLUG>/plan.md` (inside worktree) capturing the actionable steps for this direction.
3. **RLCR loop**, up to `<MAX_ROUNDS>` iterations:
    1. Implement code changes (Edit/Write/Bash, scoped to this direction).
    2. Run targeted tests for the touched files only (do not run full suite).
    3. Invoke `bash ${CLAUDE_PLUGIN_ROOT}/scripts/ask-codex.sh "Review round <k>: <diff or summary>"`, blocking until completion.
    4. Apply the feedback. If Codex returns `LGTM` or the budget is exhausted, exit the loop.
4. **BitLesson**: read `.humanize/bitlesson.md` if present in the worktree. Note: because `.humanize/` is git-ignored in the humanize repo, a freshly created worktree starts with an empty `.humanize/` directory; the file is NOT inherited from the parent checkout. The worker prompt instructs: "If `.humanize/bitlesson.md` is missing in this worktree, emit `bitlesson_action: none` and proceed without lesson lookup." A future upgrade can have the coordinator copy `.humanize/bitlesson.md` into each worktree before dispatch (out of scope for MVP). Emit `bitlesson_action: none|add|update` in the summary.
5. **Commit**: `git add` explicit paths; `git commit` with a conventional commit message; do not push.
6. **Summary file**: write `.humanize/explore/<DIR_SLUG>/summary.md` (inside worktree) with the structured fields below.
7. **Sentinel block**: print the sentinel block (6.3) to stdout as the final action.

### 6.3 Stdout sentinel block

```
=== EXPLORE_SUMMARY_BEGIN ===
dir_slug: <slug>
rounds_used: <int>
tests_passed: <int>
tests_failed: <int>
codex_final_verdict: lgtm|partial|failed
commit_count: <int>
worktree_path: <absolute path returned by Task isolation>
branch_name: <branch>
approach_recap: <one paragraph; no embedded newlines, escape with \n>
what_worked: <bullets joined by '; '>
what_didnt: <bullets joined by '; '>
bitlesson_action: none|add|update
=== EXPLORE_SUMMARY_END ===
```

The coordinator parses this block from each worker's stdout in Phase 5. KEY: VALUE format is line-oriented; values containing newlines must be escaped as `\n`.

### 6.4 Failure handling inside a worker

- If `ask-codex.sh` fails three consecutive rounds, set `codex_final_verdict: failed` and exit gracefully (still print sentinel block).
- If targeted tests are unavailable for the direction (no tests written), set `tests_passed: 0`, `tests_failed: 0`, and note in `what_didnt`.
- If implementation cannot be completed within `<MAX_ROUNDS>`, exit with whatever state exists, set `codex_final_verdict: partial`, and document in `what_didnt`.

## 7. Aggregation

### 7.1 Qualitative LLM ranking (no script)

Aggregation is performed by a single inline LLM call in the coordinator's own context — there is no separate ranking script and no numeric formula. The synthesis prompt embeds an ordered list of qualitative criteria; the LLM evaluates each worker's sentinel block against those criteria in lexicographic order (first criterion fully decides; ties broken by the next; etc.), exactly mirroring the gen-idea Phase 4 lead-direction selection convention.

**Lexicographic priority (highest to lowest):**

1. **Outcome quality** — `codex_final_verdict: lgtm` ranks above `partial`, which ranks above `failed`. Workers with `task_status: timeout` or `no_summary` rank below all of these.
2. **Test signal** — among directions tied on outcome: `tests_passed > 0` and `tests_failed == 0` ranks above any worker with `tests_failed > 0`, which ranks above `tests_passed == 0`. The LLM may also weigh test coverage qualitatively from the summary text.
3. **Implementation surface fit** — qualitative judgement: how cleanly the worker's `approach_recap` extends existing repo patterns vs. introducing new abstractions. Mirrors gen-idea Phase 4.1 step 2.
4. **Effort economy** — fewer `rounds_used` (faster convergence) is preferred among ties.
5. **Original confidence** — if all above tie, prefer the direction whose `confidence` field in `directions.json` was higher (`high > medium > low`).

Workers with `task_status: failed`, `timeout`, or `no_summary` are reported but ranked at the bottom; they are flagged in `workers.tsv` for operator follow-up but do not block the synthesis report.

**No composite score.** No script. No formula. The synthesis call carries the full directions.json plus the per-worker sentinel blocks, applies the priority list above qualitatively, and emits the ranked comparison directly into `report.md`. The output of the call is the authoritative ranking; there is no separate `rankings.tsv` file.

The synthesis call is performed at maximum reasoning effort: when invoked via `bash scripts/ask-codex.sh` (the canonical Codex path used elsewhere in humanize), pass `--effort max` (or `xhigh` if codex labels it that way) so the qualitative judgment runs at full deliberation budget. This matches the user instruction to use `/effort max` for this aggregation step.

### 7.2 Synthesis output (Phase 7)

The synthesis prompt template substitutes:

- `<DIRECTIONS_JSON>` — full directions.json content (so the model sees lossless per-direction context, including `known_risks` and `confidence`)
- `<SENTINEL_BLOCKS>` — concatenation of all worker sentinel blocks from Phase 5
- `<WORKER_SUMMARIES>` — concatenation of each worker's `summary.md` text (read from each worker's worktree path)
- `<RANKING_CRITERIA>` — the lexicographic list from §7.1 verbatim
- `<ORIGINAL_IDEA>` — copied from `directions.json.original_idea`

The rendered prompt is consumed by an inline LLM call in the coordinator's own context (no Skill, no Agent, no Task). The synthesis call runs with maximum reasoning effort. The output written to `<RUN_DIR>/report.md` must contain:

- Executive summary (one paragraph)
- **Ranking** — ordered list from best to worst, each direction annotated with which criterion was decisive (e.g., "Rank 1: <slug> — won on criterion 1 (only `lgtm` outcome)")
- Per-direction breakdown (one section per direction, citing concrete signals from its sentinel block + summary)
- Tradeoffs surfaced
- Recommended next steps (e.g., "run /humanize:gen-plan against the winner's plan.md and `git switch <branch>` to its branch")

## 8. State layout

### 8.1 Coordinator-side (main repo working dir)

```
.humanize/explore/<RUN_ID>/
  workers.tsv        # one row per worker: dir_slug, worktree_path, branch_name, task_status, codex_final_verdict, rounds_used, tests_passed, tests_failed, commit_count
  report.md          # LLM-synthesized comparison + qualitative ranking (the authoritative ranking)
  .failed            # only present if Phase 4 dispatch failed entirely
```

`<RUN_ID>` uses RLCR's timestamp format `%Y-%m-%d_%H-%M-%S` for consistency with `.humanize/rlcr/<ts>/`.

### 8.2 Worker-side (each auto-created worktree)

```
<worktree-path>/
  .humanize/explore/<DIR_SLUG>/
    plan.md
    summary.md
  <code changes>            # whatever the worker modified, committed locally on the worker's branch
```

The worktree path is returned by the Task tool's isolation result and recorded in the coordinator's `workers.tsv`. The user can inspect any worker after the run by `cd <worktree-path> && git log`.

## 9. Concurrency model and fork-bomb avoidance

### 9.1 Why this is safe

The user's `gen-idea-parallel-exploration-methodology-v2.md` documents a real fork-bomb incident in which sub-agent prompts contained instructions to invoke Skills (`/superpowers:brainstorming`, `/humanize:start-rlcr-loop`); each Skill internally spawned its own sub-agents, producing 2-layer recursive fanout (6 workers × 7 spawned each = 42+ concurrent agents → OOM, locked worktrees).

This design avoids that pattern by enforcing two rules:

1. **No Skill invocation inside a worker.** Worker prompts explicitly forbid calling slash commands. The only sub-process a worker invokes is `bash scripts/ask-codex.sh`, which is a shell script, not a Skill.
2. **No nested Task spawn inside a worker.** Workers may not call the `Task` tool. The only allowed parallelism is the coordinator's single Phase-4 dispatch.

Peak concurrency is therefore bounded by `2N`: N worker subagents plus up to N concurrent `ask-codex.sh` shell processes. The `2N` bound matches the user's v2 doctrine.

### 9.2 Why we don't directly invoke `start-rlcr-loop` per worker

Calling `/humanize:start-rlcr-loop` from inside a worker would re-introduce Skill-in-subagent nesting. The Skill internally uses `Task` for plan compliance checks, plan-understanding quizzes, and Codex review — each spawning further sub-agents. The fork-bomb concern resurfaces.

The inline RLCR-equivalent loop is the pragmatic fix: workers replicate the *behavior* (implement → review → apply) without invoking the Skill *abstraction*.

### 9.3 Future work: direct Skill invocation

When Claude Code supports nested top-level Skill invocation safely (for example, if Task workers can be elevated to true top-level sessions, or if `/batch`-style dispatch gains a Skill-safe flag, or if workers can spawn external `claude --print` subprocesses cleanly), the inline RLCR-equivalent loop in worker prompts can be replaced with a real `/humanize:start-rlcr-loop` invocation. The exact mechanism depends on what Claude Code primitives are available at that point; this is recorded as a forward-looking option, not a concrete plan.

## 10. Error handling

| Failure | Where | Coordinator response |
|---|---|---|
| `directions.json` missing or unreadable | Phase 1 | exit 2; clear message; no `RUN_DIR` created |
| Schema invalid | Phase 1 | exit 3; cite first invalid key |
| `RUN_DIR` already exists | Phase 1 | exit 4; suggest waiting or `--force-cleanup` (future) |
| Template files missing | Phase 1 | exit 7; "plugin install corrupt" |
| `directions.json` has zero directions | Phase 2 | hard-fail; nothing to explore |
| `directions.json` has one direction | Phase 2 | proceed; single-worker run is valid |
| Task tool rejects `isolation: "worktree"` or `run_in_background: true` | Phase 4 | hard-fail with explicit message: "explore-idea requires Claude Code Task tool with `isolation` and `run_in_background` support. Verify your runtime version." |
| Worker times out | Phase 5 | record `task_status: timeout`; continue collecting other workers |
| Worker stdout has no `EXPLORE_SUMMARY` block | Phase 5 | record `task_status: no_summary`; ranker treats numeric fields as worst-case |
| Worker reports `codex_final_verdict: failed` | Phase 5 | accepted; ranked low |
| `ask-codex.sh` unavailable inside worker | Worker | Worker emits `codex_final_verdict: failed` after 3 consecutive failures, exits gracefully |
| `.humanize/bitlesson.md` missing in worktree | Worker | Worker emits `bitlesson_action: none`; notes absence in summary |
| All workers fail | Phase 7 | skip synthesis; write minimal `report.md` citing failure mode |

**Atomicity invariant.** If Phase 1 validation fails, no `RUN_DIR` is created. If Phase 4 dispatch fails entirely, an empty `RUN_DIR/.failed` marker is written so the user knows what timestamp to clean up.

## 11. Testing

Tests live in `tests/`, mirroring the gen-idea test structure. CI runs them on Linux with bash 4+.

- `tests/test-validate-explore-idea-io.sh` — exit-code matrix. Cases: happy path, missing input, input not found, input not `.json`, schema invalid (missing `directions`, missing `is_primary`, wrong types), output dir collision, permission denied, missing template.
- (No `tests/test-explore-rank.sh` — there is no deterministic ranker script in this design. Ranking is an LLM judgement step; correctness is exercised via the smoke recipe.)
- `tests/test-worker-prompt-render.sh` — placeholder coverage. Render template with sample direction values; assert no `<PLACEHOLDER>` literals remain; assert hard-constraint block is present verbatim.
- `tests/test-synthesis-prompt-render.sh` — same shape as worker prompt test.
- `tests/test-gen-idea-directions-json.sh` (PR-A) — runs gen-idea on a fixture; asserts `.directions.json` exists with correct schema; validates `schema_version`.

**No live end-to-end test in CI** (would spin up N real Task subagents and Codex calls). A manual smoke recipe is documented in `commands/explore-idea.md`:

1. Tiny test repo plus tiny idea.
2. `/humanize:gen-idea "..." --n 2` — verify `.directions.json` exists.
3. `/humanize:explore-idea <json> --max-rounds 2` — verify `report.md`, two worker branches exist locally, no push attempted.

## 12. Runtime requirements

- Claude Code Task tool with `isolation: "worktree"` and `run_in_background: true` support. To be verified in the implementation plan's first task before any other work begins.
- `${CLAUDE_PLUGIN_ROOT}/scripts/ask-codex.sh` available (existing humanize dependency).
- `git` ≥ 2.5 (worktree support); already a humanize prerequisite.

## 13. Project-rule compliance

- **English-only, no emoji or CJK**: enforced in worker prompt template (constraint block) and synthesis prompt template; coordinator's `report.md` is generated by inline LLM call with explicit English-only instruction; `summary.md` field-formatting is structured, no free-form prose in the sentinel block.
- **Version-bump triplet**: PR-A bumps to `1.16.1` across `plugin.json`, `marketplace.json`, `README.md`. PR-B bumps to `1.17.0` across the same triplet. Authoring against `dev` (not main) — verified the dev triplet starting state before each PR.
- **Plan-template-sync analog**: two new sync rules added to `.claude/CLAUDE.md`. (1) `directions.json` schema in `commands/gen-idea.md` ↔ `commands/explore-idea.md` Phase 1. (2) Worker contract sections in `commands/explore-idea.md` ↔ `prompt-template/explore/worker-prompt.md`.

## 14. Future work (called out for posterity)

- `--force-cleanup` flag for stale `.humanize/explore/<ts>/` directories.
- `/humanize:explore-rerun <run-id> --direction <slug>` to re-run a single failed direction.
- `gen-idea --explore` chainer (deferred until Skill-from-Skill chaining at the orchestrator level is proven safe under humanize's Skill-recursion semantics).
- Direct `/humanize:start-rlcr-loop` invocation per worker (deferred until Claude Code supports nested top-level Skill invocation safely; would replace the inline RLCR-equivalent loop with a single Skill call).
- W2S-style sample-fanout (`--samples M` flag adding N×M total worker runs for the same direction at different temperatures). Out of scope for the direction-fanout MVP.
- Coordinator-side hook (`SessionEnd` or similar) that prints the latest `RUN_DIR/report.md` location whenever an explore run completes, even after coordinator session restart.
- `gen-idea` template change to embed a hash or signature in `directions.json` so `explore-idea` can detect mismatched draft/JSON pairs.

## 15. Open risks needing implementation-time verification

These items are deliberately not resolved in the design and must be verified as part of the implementation plan's first task:

1. **Task tool surface**. Confirm that `subagent_type: "general-purpose"` accepts both `isolation: "worktree"` and `run_in_background: true` simultaneously, and that the Task return payload includes the worktree path and branch name. Reviewer Codex flagged this as having no in-repo precedent.
2. **Worktree placement**. Verify where the Task tool places its auto-created worktrees. If they appear under `.worktrees/` in repo root, add `.worktrees/` to `.gitignore` in PR-B (or document why this is acceptable). If they appear under `.git/worktrees/` or a system temp area, no .gitignore change is needed.
3. **BitLesson inheritance**. Verified at design time: `.humanize/` is git-ignored, so a fresh worktree starts with an empty `.humanize/` directory and the bitlesson file is NOT visible. MVP behavior: worker emits `bitlesson_action: none` and proceeds. Implementation should consider whether to add a coordinator-side step that copies `.humanize/bitlesson.md` into each worktree path returned by the Task tool before workers begin substantive work. Whether this is feasible depends on whether the coordinator has access to the worktree paths at dispatch time or only at completion time (verify this in conjunction with risk #1).
4. **Background notification semantics**. Verify how Phase 5 receives notifications. Per the Task tool docs, "you will be automatically notified when it completes — do NOT sleep, poll, or proactively check on its progress." Phase 5 must handle the asynchronous arrival of all N notifications, not assume a synchronous wait.
5. **N concurrent `ask-codex.sh` calls**. Verify that running N `ask-codex.sh` invocations in parallel against the Codex CLI is supported (rate-limit or session-locking concerns). If not, the worker prompt may need to add jitter or a serialization mechanism.

If any of these checks fail, the affected portion of the design must be revised before implementation continues.
