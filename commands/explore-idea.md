---
description: "Launch bounded parallel prototype workers for idea directions and synthesize a two-tier report"
argument-hint: "<draft-or-directions-json> [--directions ids] [--concurrency N] [--max-worker-iterations N] [--worker-timeout-min N] [--codex-timeout-min N]"
allowed-tools:
  - "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/validate-explore-idea-io.sh:*)"
  - "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/validate-directions-json.sh:*)"
  - "Agent"
  - "Read"
  - "Write"
  - "Bash(git *)"
  - "Bash(mkdir *)"
  - "Bash(shasum *)"
  - "Bash(sha256sum *)"
  - "Bash(date *)"
  - "Bash(jq *)"
  - "AskUserQuestion"
---

# Explore Idea — Bounded Parallel Prototype Workers

Read and execute below with ultrathink.

## Hard Constraints

- MUST NOT run workers until the user explicitly confirms the dispatch.
- MUST NOT push any branch to any remote at any point.
- MUST write `manifest.json` to the run directory BEFORE dispatching any worker.
- MUST NOT invoke nested Skills or slash commands inside worker prompts.
- MUST NOT use `--effort max` (not supported by `ask-codex.sh`).
- Worker branches follow the format `explore/<RUN_ID>/<dir_slug>` exactly.
- Worker Codex calls must be scoped to the worker worktree root via `CLAUDE_PROJECT_DIR="$PWD"`.
- All worker results must be recorded in `worker-results.jsonl`; no result may be silently dropped.

## Worker Constraint Sync

The per-direction worker constraints are defined in `WORKER_PROMPT_TEMPLATE` (from validation stdout) and must be kept in sync with this command's design. Do not weaken worker constraints in dispatch prompts.

## Workflow

1. IO Validation
2. Confirmation
3. Run State Initialization
4. Worker Dispatch (parallel)
5. Result Collection
6. Report Synthesis

---

## Phase 1: IO Validation

Run:
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/validate-explore-idea-io.sh" $ARGUMENTS
```

Handle exit codes:
- `0`: Parse stdout to extract all `KEY: value` pairs:
  `DIRECTIONS_JSON_FILE`, `DRAFT_PATH`, `RUN_ID`, `RUN_DIR`, `BASE_BRANCH`, `BASE_COMMIT`,
  `SELECTED_DIRECTION_IDS`, `EFFECTIVE_CONCURRENCY`, `MAX_WORKER_ITERATIONS`,
  `WORKER_TIMEOUT_MIN`, `CODEX_TIMEOUT_MIN`, `WORKER_PROMPT_TEMPLATE`, `REPORT_TEMPLATE`.
  Continue to Phase 2.
- `1`: Report "No input path provided" and stop.
- `2`: Report "Input file not found" and stop.
- `3`: Report "Companion .directions.json missing — regenerate the idea draft with `/humanize:gen-idea`" and stop.
- `4`: Report "Input must be a .directions.json or .md file" and stop.
- `5`: Report "Directions JSON failed schema validation" and stop.
- `6`: Report the specific cap or argument error from stderr and stop.
- `7`: Report "Main checkout has uncommitted tracked changes — commit or stash before exploring" and stop.
- `8`: Report "Run directory collision — wait one second and retry" and stop.
- `9`: Report "Template file missing — plugin configuration error" and stop.

Load the directions JSON:
- Read `DIRECTIONS_JSON_FILE` to get the full directions data for later use.
- `SELECTED_DIRECTION_IDS` is a space-separated list of `direction_id` values that were selected.

---

## Phase 2: Confirmation

Display a pre-dispatch summary to the user and require explicit confirmation before proceeding.

**Show the following information:**
```
=== explore-idea Dispatch Plan ===

Input:           <DIRECTIONS_JSON_FILE>
Draft:           <DRAFT_PATH or "(direct .directions.json input)">
Run directory:   <RUN_DIR>
Base branch:     <BASE_BRANCH>
Base commit:     <BASE_COMMIT>

Selected directions (<N> of <total>):
  [1] <direction_id>: <name>
  [2] <direction_id>: <name>
  ...

Effective concurrency:   <EFFECTIVE_CONCURRENCY>
Worker iteration cap:    <MAX_WORKER_ITERATIONS>
Worker timeout:          <WORKER_TIMEOUT_MIN> min
Codex timeout:           <CODEX_TIMEOUT_MIN> min

WARNING: Workers will create local git worktrees, branches, and commits.
         Workers will run targeted tests and invoke Codex.
         No branches will be pushed to any remote.

Proceed? [y/N]
```

If the user does not confirm (enters anything other than `y` or `yes`, case-insensitive), stop with: "Dispatch cancelled. No worktrees or manifest created."

---

## Phase 3: Run State Initialization

Initialize durable run state BEFORE launching any workers.

### 3.1: Create Run Directory

```bash
mkdir -p "<RUN_DIR>/dispatch-prompts"
```

If `mkdir` fails, stop with an error message. Write `.failed` if the directory was partially created.

### 3.2: Build Dispatch Prompts

For each selected direction (in `SELECTED_DIRECTION_IDS`):
1. Read the direction's data from the loaded directions JSON (match by `direction_id`).
2. Read the worker prompt template from `WORKER_PROMPT_TEMPLATE`.
3. Build a per-worker prompt by substituting these placeholders in the template:
   - `<RUN_ID>` → the run ID
   - `<DIRECTION_ID>` → `direction_id`
   - `<DIR_SLUG>` → `dir_slug`
   - `<DIRECTION_NAME>` → `name`
   - `<DIRECTION_RATIONALE>` → `rationale`
   - `<APPROACH_SUMMARY>` → `approach_summary`
   - `<OBJECTIVE_EVIDENCE>` → `objective_evidence` items as a bullet list
   - `<KNOWN_RISKS>` → `known_risks` items as a bullet list
   - `<CONFIDENCE>` → `confidence`
   - `<MAX_WORKER_ITERATIONS>` → `MAX_WORKER_ITERATIONS`
   - `<CODEX_TIMEOUT_MIN>` → `CODEX_TIMEOUT_MIN`
   - `<BASE_BRANCH>` → `BASE_BRANCH`
   - `<ORIGINAL_IDEA>` → `original_idea` from the directions JSON
4. Write the prompt to `<RUN_DIR>/dispatch-prompts/<direction_id>.md`.
5. Compute a SHA-256 hash of the prompt file (using `shasum -a 256` on macOS, `sha256sum` on Linux; try both and use whichever succeeds).

### 3.3: Write manifest.json

Write `<RUN_DIR>/manifest.json` with all coordinator fields:

```json
{
  "run_id": "<RUN_ID>",
  "created_at": "<ISO8601 UTC timestamp>",
  "directions_json_file": "<DIRECTIONS_JSON_FILE>",
  "draft_path": "<DRAFT_PATH>",
  "selected_direction_ids": ["<id1>", "<id2>"],
  "base_branch": "<BASE_BRANCH>",
  "base_commit": "<BASE_COMMIT>",
  "concurrency": <EFFECTIVE_CONCURRENCY>,
  "max_worker_iterations": <MAX_WORKER_ITERATIONS>,
  "worker_timeout_min": <WORKER_TIMEOUT_MIN>,
  "codex_timeout_min": <CODEX_TIMEOUT_MIN>,
  "expected_worker_count": <selected count>,
  "runtime_spike_status": "not_validated",
  "workers": [
    {
      "direction_id": "<id>",
      "dir_slug": "<slug>",
      "prompt_path": "<RUN_DIR>/dispatch-prompts/<direction_id>.md",
      "prompt_hash": "<sha256>",
      "branch_name": "explore/<RUN_ID>/<dir_slug>",
      "status": "pending"
    }
  ]
}
```

If writing `manifest.json` fails, write `.failed` to `RUN_DIR`, and stop with error: "Failed to write manifest — dispatch aborted."

---

## Phase 4: Worker Dispatch (Parallel)

Dispatch all workers in a **single Agent-tool message** — one Agent invocation per selected direction. All workers run in parallel bounded by the effective concurrency.

### 4.1: Per-Worker Agent Invocation

For each direction in `SELECTED_DIRECTION_IDS`, launch one `Agent` subagent with:
- **isolation: "worktree"** — each worker runs in an isolated git worktree
- **model: "sonnet"** — use the current capable model
- **prompt**: the contents of `<RUN_DIR>/dispatch-prompts/<direction_id>.md`

The agent must create a branch named `explore/<RUN_ID>/<dir_slug>` in its worktree.

### 4.2: Dispatch Failure

If any agent fails to start, record a coordinator-generated failure row in `worker-results.jsonl`:
```json
{"schema_version": 1, "run_id": "<RUN_ID>", "direction_id": "<id>", "dir_slug": "<slug>", "task_status": "failed", "error": "worker failed to start", "codex_final_verdict": "unavailable", "rounds_used": 0, "tests_passed": 0, "tests_failed": 0, "worktree_path": "", "branch_name": "explore/<RUN_ID>/<slug>", "commit_sha": "", "commit_count": 0, "dirty_state": "unknown", "commit_status": "none", "summary_markdown": "", "what_worked": [], "what_didnt": [], "bitlesson_action": "none"}
```

---

## Phase 5: Result Collection

After all agents complete (or time out), collect results.

### 5.1: Parse Worker Output

For each worker agent result:
1. Search the agent's output for the sentinel block:
   ```
   === EXPLORE_RESULT_JSON_BEGIN ===
   <JSON object>
   === EXPLORE_RESULT_JSON_END ===
   ```
2. If found, extract the JSON between the sentinels and attempt to parse it with `jq`.
3. If parsing succeeds, append the JSON object as one line to `<RUN_DIR>/worker-results.jsonl`.
4. If JSON parsing fails or sentinels are absent, append a coordinator-generated `no_summary` row:
   ```json
   {"schema_version": 1, "run_id": "<RUN_ID>", "direction_id": "<id>", "dir_slug": "<slug>", "task_status": "no_summary", "error": "worker did not emit valid JSON result", "codex_final_verdict": "unavailable", "rounds_used": 0, "tests_passed": 0, "tests_failed": 0, "worktree_path": "", "branch_name": "explore/<RUN_ID>/<slug>", "commit_sha": "", "commit_count": 0, "dirty_state": "unknown", "commit_status": "none", "summary_markdown": "", "what_worked": [], "what_didnt": [], "bitlesson_action": "none"}
   ```

### 5.2: Coordinator Error Handling

If collecting one worker's result fails (e.g., exception in coordinator logic), record a failure row for that worker and continue collecting remaining workers. Do NOT write `.failed` unless ALL workers failed.

### 5.3: All Workers Failed

If every row in `worker-results.jsonl` has `task_status` in `{failed, timeout, no_summary}`:
1. Write `.failed` to `RUN_DIR`.
2. Patch `manifest.json` to add `"failure_reason": "all workers failed"`.
3. Skip to Phase 6 (generate a failure report, not a success report).

### 5.4: Update Manifest

After collecting all results, update the `workers` array in `manifest.json` to set each worker's final `status` field from its result row.

---

## Phase 6: Report Synthesis

Generate `<RUN_DIR>/report.md` by reading `REPORT_TEMPLATE` and synthesizing results.

### 6.1: Load Results

Read `<RUN_DIR>/worker-results.jsonl` (one JSON object per line).
Read the full directions JSON from `DIRECTIONS_JSON_FILE`.

### 6.2: Two-Tier Ranking

The report contains two ranking sections:

**Tier 1: Best Product Direction**
Rank all directions (even failed workers) on:
- User value derived from `approach_summary` and `objective_evidence`
- Strategic fit with the repo (from original direction data)
- Quality of original direction (evidence density, confidence level)
- Known risks

This ranking is based on the original direction quality, not prototype success.

**Tier 2: Most Implementation-Ready Prototype**
Rank only workers that produced a result on:
- `task_status` (success > partial > failed > timeout > no_summary)
- `codex_final_verdict` (lgtm > partial > failed > unavailable)
- `tests_passed` vs `tests_failed`
- `commit_status` (committed > wip > none > failed)
- `dirty_state` (clean > dirty > unknown)
- `rounds_used` (fewer is better, given same quality)

### 6.3: Adoption Paths

For each worker result, include an adoption path section with:
- Worktree path: `worktree_path`
- Branch name: `branch_name`
- Commit SHA: `commit_sha`
- Suggested next command (e.g., `cd <worktree_path> && /humanize:start-rlcr-loop`)

### 6.4: Cleanup Guidance

Include shell commands to remove non-adopted worktrees and branches:
```bash
# Remove a specific worktree and branch:
git worktree remove --force <worktree_path>
git branch -D <branch_name>
```

### 6.5: Failure Report

If all workers failed (`.failed` exists), still write `report.md` with:
- Failure summary table (direction_id, dir_slug, task_status, error)
- Cleanup guidance for any partially created worktrees
- No ranking sections

---

## Error Handling Summary

| Condition | Action |
|-----------|--------|
| Validation fails | Stop before any writes. Report error. |
| User denies confirmation | Stop. No manifest, no worktrees. |
| `manifest.json` write fails | Write `.failed`. Stop. |
| One worker fails | Record failure row. Continue remaining workers. |
| All workers fail | Write `.failed`. Update manifest. Write failure report. |
| Result collection error for one worker | Record error row. Continue. |
