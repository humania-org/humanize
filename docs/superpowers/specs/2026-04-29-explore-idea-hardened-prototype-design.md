# Design: `/humanize:explore-idea` Hardened Prototype MVP

> Status: Approved brainstorming revision. Awaiting user review before implementation planning.
> Date: 2026-04-29
> Supersedes: `docs/superpowers/specs/2026-04-28-explore-idea-design.md`
> Target flow: implement on a Horacehxw fork branch, verify there, then open one combined upstream PR.

---

## 1. Motivation

The first `/humanize:explore-idea` design proposed parallel per-direction implementation attempts, but review found several blocking issues: unbounded fanout, prompt-only safety guarantees, fragile line-oriented contracts, missing manifest state, invalid `ask-codex.sh` flags, unclear worktree isolation, and ambiguous adoption/cleanup.

This revision keeps the central value proposition: compare real local prototype branches, not just plans. Workers may implement, test, consult Codex, and commit locally by default. That behavior is now gated by explicit user confirmation and backed by bounded concurrency, durable run state, JSON contracts, deterministic branch naming, worktree-root assertions, and cleanup/adoption instructions.

## 2. Goals and Non-Goals

### Goals

- Generate a lossless `directions.json` companion artifact from `/humanize:gen-idea`.
- Explore selected directions as bounded parallel prototype attempts.
- Create local worker worktrees, branches, and commits by default after a blocking user confirmation.
- Keep active work bounded: selected directions `<= 10`, active workers `<= --concurrency`, active Codex calls `<= active workers`.
- Persist enough state to understand, inspect, adopt, or clean up every worker result.
- Use JSON contracts for direction schema and worker results.
- Produce a human report with separate product-direction and implementation-readiness rankings.
- Verify all deterministic behavior in shell CI before any upstream PR.

### Non-Goals

- No auto-push from workers.
- No auto-merge or upstream PR creation from `/humanize:explore-idea`.
- No nested Skill, Agent, or Task fanout inside workers.
- No claim that the worker loop is full RLCR. It is a bounded prototype review loop.
- No CI test that runs real Claude slash commands, Agent/Task workers, or live Codex calls.
- No direct upstream PR until the fork branch has passed deterministic tests and a manual runtime smoke.

## 3. Contribution Flow

Build the change as one feature branch in the Horacehxw fork, but keep the work internally staged as two layers:

1. **PR-A layer:** amend `gen-idea` to emit and validate `directions.json`.
2. **PR-B layer:** add `explore-idea` and its validators, templates, worker result handling, report synthesis, and documentation.

After local implementation:

1. Push the branch to the Horacehxw fork.
2. Run deterministic shell tests.
3. Run the blocking runtime spike for Agent/Task worktree behavior.
4. Run one tiny manual smoke with two directions and one worker iteration.
5. Open one combined upstream PR after verification.

Versioning is a single public bump from `1.16.0` to `1.17.0` across `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and the `README.md` Current Version line.

## 4. PR-A Layer: Lossless `directions.json`

### 4.1 `gen-idea` Output Contract

After the draft markdown is written, `gen-idea` writes a companion file:

```text
<draft>.directions.json
```

For ordinary `.md` output, the path is derived with:

```bash
${OUTPUT_FILE%.md}.directions.json
```

MVP behavior: reject non-`.md` output for `gen-idea`, because companion derivation and draft ergonomics rely on the markdown suffix.

`commands/gen-idea.md` must update its hard constraint from "single output draft file" to "draft file plus validated directions companion artifact." It must report both paths in its final output and mention the optional next step:

```text
/humanize:explore-idea <directions-json-path>
```

### 4.2 Validation Changes

`scripts/validate-gen-idea-io.sh` must:

- Require a `.md` output path.
- Derive `DIRECTIONS_JSON_FILE`.
- Reject an existing draft file.
- Reject an existing companion JSON file.
- Ensure the output directory is writable for both files.
- Emit `DIRECTIONS_JSON_FILE: <absolute-path>` on success.

If any validation fails, neither output file is written.

### 4.3 Schema

`directions.json` uses schema version 1:

```json
{
  "schema_version": 1,
  "title": "Command Pattern Undo Stack",
  "original_idea": "verbatim user input",
  "synthesis_notes": "lead synthesis paragraph",
  "metadata": {
    "n_requested": 6,
    "n_returned": 6,
    "timestamp": "20260429-153012",
    "draft_path": ".humanize/ideas/undo-redo-20260429-153012.md"
  },
  "directions": [
    {
      "direction_id": "dir-00-command-history",
      "dir_slug": "command-history",
      "source_index": 0,
      "display_order": 0,
      "is_primary": true,
      "name": "Command History",
      "rationale": "Single-sentence rationale from Phase 2.",
      "raw_phase3_response": "Exact raw proposal text from the explorer.",
      "approach_summary": "Normalized approach summary.",
      "objective_evidence": ["path/or/evidence"],
      "known_risks": ["risk"],
      "confidence": "high"
    }
  ]
}
```

Rules:

- `direction_id` is immutable and unique.
- `dir_slug` is unique and branch/path safe: lowercase ASCII letters, digits, and hyphens.
- `source_index` preserves the original Phase-2 direction index.
- `display_order` is primary first, then alternatives.
- `raw_phase3_response` preserves the exact subagent response.
- Normalized fields are derived for easier downstream consumption.
- `original_idea` is exempt from generated-text English-only rules because it must preserve user input verbatim.
- Generated fields remain English-only and contain no emoji or CJK characters.

### 4.4 Shared Schema Validator

Add a deterministic schema validator, preferably `scripts/validate-directions-json.sh` using `jq`. It validates:

- `schema_version == 1`
- required top-level keys
- `directions` length is `1..10`
- exactly one `is_primary: true`
- unique `direction_id`
- unique `dir_slug`
- unique `source_index`
- contiguous or unique `display_order` values
- `confidence` is `high`, `medium`, or `low`
- `metadata.n_returned == directions.length`
- required string/list fields have the expected types

Both `gen-idea` and `explore-idea` rely on this validator as the canonical contract.

## 5. PR-B Layer: Command UX

### 5.1 Command Surface

```text
/humanize:explore-idea <draft-or-directions-json>
  [--directions ids]
  [--concurrency P]
  [--max-worker-iterations R]
  [--worker-timeout-min M]
  [--codex-timeout-min M]
```

Input:

- Accept a `.directions.json` path directly.
- Accept a generated draft `.md` path and resolve the companion JSON with `.md -> .directions.json`.
- If the companion JSON is missing, fail clearly and tell the user to regenerate the idea draft.

Direction selection:

- Default: first `min(6, directions.length)` directions by `display_order`.
- `--directions` selects stable `direction_id` values or numeric `source_index` values.
- Validation rejects selecting more than 10 directions.
- Validation rejects duplicate or unknown direction selectors.

Defaults and caps:

- Default selected directions: up to 6.
- Hard max directions: 10.
- Default concurrency: 6.
- Hard max concurrency: 10.
- Effective concurrency: `min(requested_concurrency, selected_direction_count)`.
- Default worker iterations: 2.
- Hard max worker iterations: 3.
- Default worker timeout: 60 minutes.
- Hard max worker timeout: 60 minutes.
- Default Codex timeout: 20 minutes.
- Hard max Codex timeout: 20 minutes.

### 5.2 Blocking Confirmation

Commits are default behavior, but dispatch is blocked until explicit user confirmation.

Before launching workers, the command shows:

- selected direction IDs and names
- selected direction count
- effective concurrency
- worker iteration cap
- worker timeout
- Codex timeout
- base branch
- base commit
- run directory
- warning that workers will create local worktrees, branches, commits, run targeted tests, and invoke Codex

The command proceeds only if the user explicitly confirms.

### 5.3 Frontmatter and Runtime Capability

The implementation must use the current Claude Code subagent tool naming and schema. If the current runtime uses `Agent`, command docs and frontmatter should use `Agent`. If `Task` remains the installed command-tool name, the spec may document `Task` as a compatibility alias.

Before PR-B implementation proceeds, run a blocking spike that proves:

- worktree isolation is supported
- background execution or equivalent parallel execution is supported
- the command can wait for all workers in one session
- worker results are available to the coordinator
- worktree path and branch name are discoverable
- worker permissions allow required edits, tests, git, and Codex calls

If the spike fails, revise PR-B before implementation continues.

## 6. Explore Run State

The coordinator writes durable state before dispatch:

```text
.humanize/explore/<RUN_ID>/
  manifest.json
  dispatch-prompts/
    <direction_id>.md
  worker-results.jsonl
  report.md
  .failed
```

`manifest.json` includes:

- `run_id`
- `created_at`
- `directions_json_file`
- `draft_path`
- `selected_direction_ids`
- `base_branch`
- `base_commit`
- `concurrency`
- `max_worker_iterations`
- `worker_timeout_min`
- `codex_timeout_min`
- `expected_worker_count`
- `runtime_spike_status`
- per-worker records with `direction_id`, `dir_slug`, prompt path, prompt hash, branch name, worktree path if known, task/agent id if available, and final status

`dispatch-prompts/<direction_id>.md` stores the exact prompt sent to each worker. Prompts are not in-memory only.

`worker-results.jsonl` stores one JSON object per worker result or coordinator-generated failure row.

If dispatch fails entirely, write `.failed` and update `manifest.json` with the failure reason.

## 7. Worker Runtime and Isolation

### 7.1 Worker Constraints

Each worker must:

- stay inside its assigned worktree
- not invoke Skills or slash commands
- not spawn nested Agent/Task workers
- not push branches
- not access sibling worktrees
- not perform destructive cleanup outside its worktree
- use only the approved Codex consultation path
- emit the JSON result sentinel as its final action

These are still prompt-level constraints unless the runtime exposes tool-level restrictions. The spec must not claim a strict concurrency proof unless those restrictions are verified.

### 7.2 Worktree Root Safety

Before calling Humanize scripts, the worker must:

```bash
export CLAUDE_PROJECT_DIR="$PWD"
```

It must assert that `scripts/ask-codex.sh` resolves the same project root as the assigned worktree. If the assertion fails, the worker stops and emits a failure result.

This prevents `ask-codex.sh` from resolving the coordinator checkout through inherited `CLAUDE_PROJECT_DIR`.

### 7.3 Codex Calls

Worker Codex calls use:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/ask-codex.sh" \
  --codex-timeout 1200 \
  --codex-model "<model>:xhigh" \
  "<prompt>"
```

`ask-codex.sh` must disable nested Codex hooks when supported, using the same `--disable hooks` probing pattern already used by the RLCR stop hook and `bitlesson-select.sh`.

The spec does not use `--effort max`; that flag is not supported by the current script.

### 7.4 Worker Loop

The worker loop is a bounded prototype review loop:

1. Inspect relevant repo context.
2. Write a short plan sketch under the worker summary data.
3. Implement scoped prototype changes.
4. Run targeted tests for touched areas.
5. Ask Codex for review.
6. Apply useful feedback.
7. Repeat until `max_worker_iterations`, Codex `LGTM`, or failure.
8. Commit local changes when appropriate.
9. Emit JSON result.

This is not full RLCR. It does not replace `/humanize:start-rlcr-loop`.

### 7.5 Branch and Commit Rules

Branch names are deterministic:

```text
explore/<RUN_ID>/<dir_slug>
```

The worker result records:

- `branch_name`
- `worktree_path`
- `commit_sha`
- `commit_count`
- `dirty_state`
- `commit_status`

Allowed `commit_status` values:

- `committed`
- `none`
- `wip`
- `failed`

Successful and partial workers should commit if they produced changes. Failed workers may leave WIP changes only if the result marks that state clearly.

### 7.6 Timeouts

Coordinator enforces the worker timeout.

Codex calls use the Codex timeout.

If a worker times out, the coordinator writes a timeout result row to `worker-results.jsonl` with:

```json
{
  "task_status": "timeout",
  "direction_id": "...",
  "error": "worker exceeded timeout"
}
```

The report includes timeout cleanup guidance.

### 7.7 BitLesson

If worker worktree paths are known before substantive work begins, the coordinator copies or initializes `.humanize/bitlesson.md` in each worker worktree.

If paths are not known until completion, BitLesson is explicitly unavailable for MVP. Worker results set `bitlesson_action: "none"` and the report states that this run has reduced parity with standard RLCR.

## 8. Worker Result Contract

Workers print one JSON object between sentinel markers:

```text
=== EXPLORE_RESULT_JSON_BEGIN ===
{
  "schema_version": 1,
  "run_id": "2026-04-29_15-30-12",
  "direction_id": "dir-00-command-history",
  "dir_slug": "command-history",
  "task_status": "success",
  "codex_final_verdict": "lgtm",
  "rounds_used": 2,
  "tests_passed": 3,
  "tests_failed": 0,
  "worktree_path": "/abs/path",
  "branch_name": "explore/2026-04-29_15-30-12/command-history",
  "commit_sha": "abc123",
  "commit_count": 1,
  "dirty_state": "clean",
  "commit_status": "committed",
  "summary_markdown": "Full markdown summary.",
  "what_worked": ["item"],
  "what_didnt": ["item"],
  "bitlesson_action": "none",
  "error": null
}
=== EXPLORE_RESULT_JSON_END ===
```

Enums:

- `task_status`: `success`, `partial`, `failed`, `timeout`, `no_summary`
- `codex_final_verdict`: `lgtm`, `partial`, `failed`, `unavailable`
- `dirty_state`: `clean`, `dirty`, `unknown`
- `bitlesson_action`: `none`, `add`, `update`

The coordinator parses JSON, not ad hoc `KEY: VALUE` lines. Invalid JSON creates a `no_summary` row.

## 9. Ranking and Report

`worker-results.jsonl` is the machine-readable source of truth. `report.md` is the human synthesis.

The report has two rankings:

1. **Best product direction**
   - user value
   - strategic fit
   - original direction quality
   - objective evidence
   - known risks

2. **Most implementation-ready prototype**
   - `task_status`
   - `codex_final_verdict`
   - tests passed/failed
   - commit status
   - dirty state
   - implementation fit
   - worker iteration count

The design no longer claims deterministic ranking unless a future deterministic `ranking.json` artifact is added. For MVP, ranking is qualitative LLM synthesis over JSON inputs.

The synthesis is performed by the coordinator's current reasoning context unless `ask-codex.sh` is explicitly allowed and called with the valid `--codex-model <model>:xhigh` contract.

## 10. Adoption and Cleanup

The report includes exact adoption paths:

### Continue Winner Branch

Includes:

- worktree path
- branch name
- commit SHA
- suggested next command, for example `/humanize:start-rlcr-loop --skip-impl` when appropriate

### Restart From Plan

Use the winning worker's plan sketch and `summary_markdown` as input to normal `/humanize:gen-plan`, then run standard RLCR.

### Cherry-Pick Prototype

Includes exact commit SHA and warns that the user should verify the base branch first.

### Discard Prototypes

Includes cleanup guidance for losing worktrees and branches.

Future companion commands are designed but may be deferred:

```text
/humanize:explore-status <run-id>
/humanize:explore-cleanup <run-id> [--failed-only|--losers|--all]
```

If companion commands are deferred, the MVP report still prints shell cleanup commands and all ownership data remains in `manifest.json`.

## 11. Safety Model

The safety model is bounded concurrency, not an unqualified `2N` proof:

- selected directions are bounded by 10
- active workers are bounded by `--concurrency`
- active Codex calls are bounded by active workers
- nested Skill, Agent, and Task calls inside workers are forbidden
- worker project root is asserted before Codex calls
- `ask-codex.sh` disables nested Codex hooks when supported
- dispatch requires explicit user confirmation
- all worker branches/worktrees are recorded in the manifest

If the runtime cannot enforce tool-level worker restrictions, the spec must describe nested fanout prevention as prompt-enforced plus verified by smoke testing, not mathematically guaranteed.

## 12. Error Handling

Validation failures occur before `RUN_DIR` creation.

If `RUN_DIR` already exists, validation fails unless a future cleanup flag is implemented.

If a selected direction is invalid, validation fails.

If dispatch fails entirely:

- write `.failed`
- update `manifest.json`
- do not write a success report

If a worker times out, fails, or emits invalid JSON:

- append a coordinator-generated JSON row to `worker-results.jsonl`
- continue collecting other workers
- include the failed worker in `report.md`

If all workers fail:

- write a minimal `report.md`
- include the failure table and cleanup/status guidance

## 13. Testing

CI tests are deterministic shell tests.

Add:

- `tests/test-validate-gen-idea-io.sh`
  - companion path derivation
  - `.md` requirement
  - companion collision rejection
  - `DIRECTIONS_JSON_FILE` stdout

- `tests/test-directions-json-schema.sh`
  - valid fixture
  - missing keys
  - more than 10 directions
  - duplicate `direction_id`
  - duplicate `dir_slug`
  - missing primary
  - multiple primary entries
  - bad confidence enum
  - `n_returned` mismatch

- `tests/test-validate-explore-idea-io.sh`
  - direct JSON input
  - draft-to-json resolution
  - missing companion JSON
  - direction cap
  - `--directions` parsing
  - concurrency range
  - worker iteration range
  - timeout range
  - run dir collision
  - template presence

- `tests/test-worker-result-contract.sh`
  - valid JSON sentinel
  - invalid JSON sentinel
  - timeout row
  - no-summary row
  - enum validation

- `tests/test-explore-manifest.sh`
  - required manifest fields
  - base branch and base commit fields
  - selected direction IDs
  - prompt path and prompt hash fields

- `tests/test-explore-command-structure.sh`
  - frontmatter tools
  - blocking confirmation text
  - worker hard constraints
  - schema/template sync references

Every new suite must be added to `tests/run-all-tests.sh`.

No CI test invokes live slash commands, real Agent/Task workers, or real Codex.

## 14. Manual Verification Before Upstream PR

Before opening the upstream PR:

1. Push the feature branch to the Horacehxw fork.
2. Run the full shell test suite.
3. Run the runtime spike:
   - prove worker worktree isolation
   - prove background/wait or equivalent parallel collection
   - prove worktree path and branch name discovery
   - prove worker permissions for edit/test/git/Codex
   - prove `CLAUDE_PROJECT_DIR="$PWD"` makes Codex run in the worker worktree
   - prove Codex hook disabling is active when supported
4. Run one tiny manual smoke:
   - two directions
   - one worker iteration
   - inspect `manifest.json`
   - inspect `worker-results.jsonl`
   - inspect `report.md`
   - verify local branches and commits
   - verify no push occurred

If any runtime spike check fails, revise PR-B before opening the upstream PR.

## 15. Documentation Updates

Update:

- `README.md` quick start with optional `explore-idea`.
- `docs/usage.md` command reference.
- `.claude/CLAUDE.md` sync rules:
  - `directions.json` schema is canonical in the schema validator and documented in both command docs.
  - worker constraints in `commands/explore-idea.md` and `prompt-template/explore/worker-prompt.md` must stay in sync.
- `.gitignore` if runtime spike confirms Claude-managed worktrees appear under an unignored path such as `.claude/worktrees/`.

## 16. Open Implementation Risks

These are blocking before PR-B is considered ready:

1. Confirm actual current Claude Code `Agent` or `Task` tool schema.
2. Confirm worktree isolation and branch naming behavior.
3. Confirm whether worktree paths are available before workers begin.
4. Confirm single command can wait and collect all worker results.
5. Confirm background workers can use required tools without hidden permission prompts.
6. Confirm `ask-codex.sh` hook disabling does not break existing tests.
7. Confirm concurrent Codex calls do not hit local locks or unacceptable rate limits.

If any item fails, update this design before implementation planning continues.
