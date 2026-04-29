# `/humanize:explore-idea` Hardened Prototype MVP

## Goal Description

Add the `/humanize:explore-idea` command and update `/humanize:gen-idea` to emit a lossless `directions.json` companion artifact alongside each idea draft. Bump the plugin version from 1.16.0 to 1.17.0.

The work is staged as two layers: PR-A adds the `directions.json` contract and its validator to `gen-idea`; PR-B adds the full `explore-idea` command that launches bounded parallel prototype workers in isolated worktrees, collects their JSON results, and synthesizes a two-tier report. After RLCR completes, a manual functional spike on a real task validates the behavioral assumptions documented in the `## Functional Spike Checklist`; any divergences are handled as out-of-scope follow-up.

## Acceptance Criteria

Following TDD philosophy, each criterion includes positive and negative tests for deterministic verification.

- AC-1: `validate-gen-idea-io.sh` enforces `.md` output suffix, rejects existing companion JSON, and emits `DIRECTIONS_JSON_FILE:` on success
  - Positive Tests (expected to PASS):
    - Given `--output foo.md` with no existing `foo.md` or `foo.directions.json`: exits 0, stdout includes `DIRECTIONS_JSON_FILE: /abs/path/foo.directions.json` and `VALIDATION_SUCCESS`
    - Given `--output subdir/bar.md` in a writable directory: derives companion path correctly as `subdir/bar.directions.json`
  - Negative Tests (expected to FAIL):
    - Given `--output foo` (no `.md` suffix): exits non-zero with a clear error about required `.md` suffix
    - Given `--output foo.txt`: exits non-zero with required `.md` suffix error
    - Given `--output foo.md` with `foo.directions.json` already existing: exits non-zero with companion collision error
    - Given `--output foo.md` with `foo.md` already existing: exits non-zero (existing output file, already in current behavior)

- AC-2: A successful `gen-idea` run writes both the draft markdown and a schema-valid companion `directions.json`; neither file is written when validation fails; the dual-write behavior and hint output are covered by `tests/test-gen-idea-dual-write.sh` (added in task5)
  - Positive Tests (expected to PASS):
    - After a successful run: both `<output>.md` and `<output>.directions.json` exist on disk
    - The companion JSON passes `validate-directions-json.sh` with exit code 0
    - The final `gen-idea` output reports both file paths and includes a hint for `/humanize:explore-idea <companion-json>`
  - Negative Tests (expected to FAIL):
    - When validation fails before generation (e.g., output already exists): neither `<output>.md` nor `<output>.directions.json` is created or modified
    - When gen-idea aborts after draft write but before companion write: companion is absent; next run will not silently overwrite the draft (existing collision rejection applies)

- AC-3: `scripts/validate-directions-json.sh` passes valid fixtures and rejects all known malformed cases
  - Positive Tests (expected to PASS):
    - A fixture with all required top-level keys, exactly one `is_primary: true`, unique `direction_id` values, unique `dir_slug` values, unique `source_index` values, integer `display_order` values, valid `confidence` enum, `metadata.n_returned == directions.length`, and 1–10 directions: exits 0
  - Negative Tests (expected to FAIL):
    - Missing `schema_version` field: exits non-zero
    - `directions` array with 11 elements: exits non-zero
    - Two entries with `is_primary: true`: exits non-zero
    - Zero entries with `is_primary: true`: exits non-zero
    - Duplicate `direction_id` across two entries: exits non-zero
    - Duplicate `dir_slug` across two entries: exits non-zero
    - Duplicate `source_index` across two entries: exits non-zero
    - A `display_order` value that is not an integer (e.g., a string): exits non-zero
    - A `dir_slug` value containing uppercase letters or spaces (not branch/path safe): exits non-zero
    - A direction entry missing a required per-direction field (`name`, `rationale`, `raw_phase3_response`, `approach_summary`, `objective_evidence`, or `known_risks`): exits non-zero
    - `objective_evidence` or `known_risks` that is not a JSON array: exits non-zero
    - `confidence` value not in `{high, medium, low}`: exits non-zero
    - `metadata.n_returned` does not equal `directions.length`: exits non-zero
    - Missing required top-level key (`title`, `original_idea`, `synthesis_notes`, `metadata`, or `directions`): exits non-zero

- AC-4: `explore-idea` resolves the input file to a valid `directions.json` before creating any side effects
  - Positive Tests (expected to PASS):
    - Given a `.directions.json` path directly: loads and schema-validates it, then proceeds
    - Given a `.md` draft path with an existing companion `.directions.json`: resolves and loads the companion, then proceeds
  - Negative Tests (expected to FAIL):
    - Given a `.md` path with no companion `.directions.json`: exits non-zero with a message instructing the user to regenerate the idea draft
    - Given a `.directions.json` that fails schema validation: exits non-zero before any worktrees are created
    - Given a non-existent path: exits non-zero

- AC-5: Direction selection defaults, `--directions` override, and all hard caps are enforced
  - Positive Tests (expected to PASS):
    - With no `--directions` flag and 8 available directions: first 6 by `display_order` are selected
    - `--directions dir-00,dir-02` (stable `direction_id` values): exactly those two are selected
    - `--directions 0,2` (numeric `source_index` values): resolves correctly to corresponding directions
    - `--concurrency 3` with 5 selected directions: effective concurrency is 3
    - `--concurrency 8` with 5 selected directions: effective concurrency is 5 (capped to selected count)
  - Negative Tests (expected to FAIL):
    - `--directions` selecting 11 directions: exits non-zero
    - `--concurrency 11`: exits non-zero
    - `--max-worker-iterations 4`: exits non-zero
    - `--worker-timeout-min 61`: exits non-zero
    - `--codex-timeout-min 21`: exits non-zero
    - `--directions` referencing an unknown `direction_id` or `source_index`: exits non-zero
    - `--directions` with duplicate selector values: exits non-zero
  - AC-5.1: `explore-idea` hard-fails before any dispatch side effects if the main checkout has uncommitted tracked changes
    - Positive Tests (expected to PASS):
      - With a clean main checkout (no uncommitted tracked changes): validation passes and dispatch proceeds to confirmation
    - Negative Tests (expected to FAIL):
      - With one or more modified tracked files in the main checkout: exits non-zero before confirmation dialog, before manifest creation, and before any worktree is created; error message names the dirty-checkout condition explicitly

- AC-6: Explicit user confirmation is required before any dispatch side effects occur
  - Positive Tests (expected to PASS):
    - Before dispatch: the command shows selected direction IDs and names, selected count, effective concurrency, iteration cap, worker timeout, Codex timeout, base branch, base commit, run directory, and a warning that workers will create local worktrees, branches, commits, run tests, and call Codex
    - After explicit confirmation: worker dispatch proceeds
  - Negative Tests (expected to FAIL):
    - User denies confirmation: no worktrees are created, no manifest is written, command exits cleanly

- AC-7: `manifest.json` is written to the run directory before any worker starts, and per-worker records are updated as workers complete
  - Positive Tests (expected to PASS):
    - `manifest.json` exists in `.humanize/explore/<RUN_ID>/` before the first worker is launched
    - Contains: `run_id`, `created_at`, `directions_json_file`, `draft_path`, `selected_direction_ids`, `base_branch`, `base_commit`, `concurrency`, `max_worker_iterations`, `worker_timeout_min`, `codex_timeout_min`, `expected_worker_count`
    - Each per-worker record contains: `direction_id`, `dir_slug`, prompt path, prompt hash, branch name, final status
    - `RUN_ID` is generated as `YYYY-MM-DD_HH-MM-SS`; if a run directory for the generated ID already exists, validation fails with a collision error before any writes occur
  - Negative Tests (expected to FAIL):
    - If `manifest.json` cannot be written before dispatch: dispatch fails and `.failed` is written; no workers are launched
    - If the run directory already exists at the time of validation: exits non-zero before manifest creation and before any worktrees are created

- AC-8: Valid worker sentinel JSON is parsed into `worker-results.jsonl`; timeout, invalid-JSON, and no-summary cases produce coordinator-generated failure rows with stable enum values; coordinator failures after dispatch begin are recorded and do not silently lose worker results
  - Positive Tests (expected to PASS):
    - A worker that emits valid JSON between `=== EXPLORE_RESULT_JSON_BEGIN ===` and `=== EXPLORE_RESULT_JSON_END ===`: row appended to `worker-results.jsonl` with correct fields
    - A worker that times out: coordinator appends `{"task_status": "timeout", "direction_id": "...", "error": "worker exceeded timeout"}`
    - A worker that emits malformed JSON inside the sentinel markers: coordinator appends a `no_summary` row
    - All `task_status` enum values (`success`, `partial`, `failed`, `timeout`, `no_summary`) are representable in `worker-results.jsonl`
    - If a coordinator-side error occurs after dispatch begins (e.g., result collection fails for one worker): remaining workers continue; the failing worker's result row is written with the error noted; `.failed` is NOT written unless all workers failed
  - Negative Tests (expected to FAIL):
    - A worker result with no sentinel markers: treated as `no_summary`, not silently dropped
    - If all workers fail or error: `.failed` is written and `manifest.json` is updated with failure reason; no success `report.md` is written

- AC-9: Worker Codex calls are scoped to the worker worktree root; a root mismatch is recorded as a worker failure
  - Positive Tests (expected to PASS):
    - Worker sets `export CLAUDE_PROJECT_DIR="$PWD"` before calling `ask-codex.sh`; Codex resolves project root to the worker worktree path
    - Worker result includes `worktree_path` matching the directory where Codex ran
  - Negative Tests (expected to FAIL):
    - If `CLAUDE_PROJECT_DIR` points to the coordinator checkout (mismatch detected by assertion): worker emits a failure result with `task_status: "failed"` and does not proceed with Codex

- AC-10: `report.md` contains two-tier rankings and adoption paths with concrete worktree/branch/commit data
  - Positive Tests (expected to PASS):
    - `report.md` contains a "Best product direction" ranking section covering user value, strategic fit, original direction quality, objective evidence, and known risks
    - `report.md` contains a "Most implementation-ready prototype" ranking section covering `task_status`, `codex_final_verdict`, tests passed/failed, commit status, dirty state, and iteration count
    - Each worker result entry has an adoption path with worktree path, branch name, commit SHA, and a suggested next command (e.g., `/humanize:start-rlcr-loop`)
    - Cleanup guidance for non-adopted worktrees and branches is included
  - Negative Tests (expected to FAIL):
    - If all workers failed: `report.md` is still generated with a failure table and cleanup/status guidance (no crash)

- AC-11: After RLCR completes, a manual functional spike runs explore-idea on a real task and records a pass/partial/fail outcome for every item in the Functional Spike Checklist
  - Positive Tests (expected to PASS):
    - A real `gen-idea` run produces a valid `directions.json`; `explore-idea` is invoked on it with 2–3 directions and 1–2 worker iterations
    - Every item in `## Functional Spike Checklist` has a recorded outcome (pass, partial, or fail) with observation notes
    - Results are documented in `docs/runtime-spike-results.md`
  - Negative Tests (expected to FAIL):
    - A divergence discovered during the spike is patched inline without a new plan: this is a scope violation; all divergences must be filed as follow-up via `/humanize:gen-plan`

- AC-12: All 7 new shell CI test suites are registered in `tests/run-all-tests.sh` and pass without invoking live runtime
  - Positive Tests (expected to PASS):
    - `tests/run-all-tests.sh` `TEST_SUITES` array includes: `test-validate-gen-idea-io.sh`, `test-directions-json-schema.sh`, `test-gen-idea-dual-write.sh`, `test-validate-explore-idea-io.sh`, `test-worker-result-contract.sh`, `test-explore-manifest.sh`, `test-explore-command-structure.sh`
    - Each suite exits 0 against its valid fixtures
    - Full `run-all-tests.sh` exits 0
  - Negative Tests (expected to FAIL):
    - Any new test file invokes a live slash command, real Agent/Task worker, or live Codex call: this is a disqualifying violation

- AC-13: `ask-codex.sh` auto-probes Codex CLI support and disables nested hooks when supported; existing hook tests pass unchanged
  - Positive Tests (expected to PASS):
    - When the installed Codex CLI supports `--disable codex_hooks`: `ask-codex.sh` includes that flag in all invocations automatically, without any caller-side flag
    - `tests/test-ask-codex.sh` includes a case verifying the auto-probe and flag injection behavior
  - Negative Tests (expected to FAIL):
    - `tests/test-disable-nested-codex-hooks.sh` fails after the `ask-codex.sh` change: this is a regression that must be fixed before merging

- AC-14: Version 1.17.0 is present in all three plugin metadata files
  - Positive Tests (expected to PASS):
    - `.claude-plugin/plugin.json` contains `"version": "1.17.0"`
    - `.claude-plugin/marketplace.json` contains `"version": "1.17.0"`
    - `README.md` "Current Version" line reads `1.17.0`
  - Negative Tests (expected to FAIL):
    - Any of the three files still contains `1.16.0` after the bump: this is a version inconsistency

- AC-15: A manual smoke run with 2 directions and 1 worker iteration produces all expected artifacts with no push
  - Positive Tests (expected to PASS):
    - After the smoke run: `.humanize/explore/<RUN_ID>/manifest.json` exists and is complete, `worker-results.jsonl` contains exactly 2 entries, `report.md` exists with both ranking sections, 2 local branches named `explore/<RUN_ID>/<dir_slug>` exist, each branch has at least 1 commit
  - Negative Tests (expected to FAIL):
    - Any worker branch is visible in the upstream fork remote after the smoke run: this means a push occurred and is a critical violation

## Path Boundaries

Path boundaries define the acceptable range of implementation quality and choices.

### Upper Bound (Maximum Acceptable Scope)

The implementation includes PR-A and PR-B as described in the design, with parallel worker dispatch, durable run state, two-tier LLM report, adoption paths, all 7 CI test suites registered and passing, `ask-codex.sh` auto-probe behavior, documentation updates (README, `docs/usage.md`, CLAUDE.md sync rules, `.gitignore` if needed), and the 1.17.0 version bump across all three files. The manual smoke test passes. Optional companion commands (`explore-status`, `explore-cleanup`) may be described in documentation as deferred.

### Lower Bound (Minimum Acceptable Scope)

The implementation includes PR-A and PR-B with all 18 tasks complete: `validate-gen-idea-io.sh` updated, `validate-directions-json.sh` added, `commands/gen-idea.md` updated, the full `explore-idea` command with supporting scripts and templates, `ask-codex.sh` auto-probe behavior, all 7 CI test suites registered and passing, documentation updates, the 1.17.0 version bump, manual smoke verification (task17), and functional spike results documented in `docs/runtime-spike-results.md` (task18). Spike divergences are out of scope for this plan.

### Allowed Choices

- Can use: `jq` for all JSON validation in shell scripts; `bash` for all new scripts and tests; `portable-timeout.sh` for worker timeouts; existing `ask-codex.sh` invocation pattern; existing test file structure from `tests/test-validate-gen-plan-io.sh` or similar as reference
- Cannot use: Python, Node.js, or other non-shell runtimes for validators (must match existing repo conventions); nested Skills, slash commands, or Agent/Task workers inside worker prompts; `git push` from any worker; `--effort max` flag (not supported by current `ask-codex.sh`)

> **Note on Deterministic Designs**: The draft specifies fixed values for all numeric caps, branch naming format (`explore/<RUN_ID>/<dir_slug>`), run state directory layout (`.humanize/explore/<RUN_ID>/`), sentinel markers, schema version (1), and output file naming (`${OUTPUT_FILE%.md}.directions.json`). These are fixed constraints, not choices.

## Feasibility Hints and Suggestions

> **Note**: This section is for reference and understanding only. These are conceptual suggestions, not prescriptive requirements.

### Conceptual Approach

**PR-A: Companion JSON emission**

In `validate-gen-idea-io.sh`, after confirming the output path ends in `.md`:
```bash
# Enforce .md suffix
if [[ "${OUTPUT_FILE##*.}" != "md" ]]; then
  echo "ERROR: --output must have .md suffix for companion derivation" >&2
  exit 6
fi
DIRECTIONS_JSON_FILE="${OUTPUT_FILE%.md}.directions.json"
# Reject existing companion
if [[ -f "$DIRECTIONS_JSON_FILE" ]]; then
  echo "ERROR: companion already exists: $DIRECTIONS_JSON_FILE" >&2
  exit 4
fi
echo "DIRECTIONS_JSON_FILE: $DIRECTIONS_JSON_FILE"
```

In `commands/gen-idea.md`, after the draft markdown is written, parse the structured Phase 2/3 direction data and write a `directions.json` that conforms to schema version 1. Report both paths in the final output block. Add a hint line:
```
Next step (optional): /humanize:explore-idea $DIRECTIONS_JSON_FILE
```

**PR-A: Schema validator**

`scripts/validate-directions-json.sh` wraps a single `jq -e` expression:
```bash
jq -e '
  .schema_version == 1
  and (.directions | length) >= 1
  and (.directions | length) <= 10
  and (.directions | map(select(.is_primary == true)) | length) == 1
  and (.directions | map(.direction_id) | unique | length) == (.directions | length)
  and (.directions | map(.dir_slug) | unique | length) == (.directions | length)
  and (.directions | map(.dir_slug) | all(test("^[a-z0-9-]+$")))
  and (.directions | map(.source_index) | unique | length) == (.directions | length)
  and (.directions | map(.display_order) | all(. != null and (type == "number") and (. == floor)))
  and (.metadata.n_returned == (.directions | length))
  and (.directions | map(.confidence) | all(. == "high" or . == "medium" or . == "low"))
  and (.directions | map(
        has("name") and has("rationale") and has("raw_phase3_response")
        and has("approach_summary")
        and ((.objective_evidence | type) == "array")
        and ((.known_risks | type) == "array")
      ) | all)
' "$INPUT_FILE"
```

**PR-B: `ask-codex.sh` auto-probe**

Check if the installed Codex CLI supports `--disable codex_hooks` by probing with `codex --help 2>&1 | grep -q 'disable'` (or equivalent). Store the result and unconditionally include the flag when supported. Follow the same pattern already used in `hooks/lib/loop-codex-stop-hook.sh` and `scripts/bitlesson-select.sh`.

**PR-B: Run state before dispatch**

Before launching any workers:
1. Generate `RUN_ID` as `$(date -u +%Y-%m-%d_%H-%M-%S)`
2. Check that `.humanize/explore/$RUN_ID/` does not already exist; if it does, exit with a collision error (same-second collision: hard-fail, no retry)
3. `mkdir -p ".humanize/explore/$RUN_ID/dispatch-prompts"`
4. Write `manifest.json` with all coordinator-side fields
5. Write each `dispatch-prompts/<direction_id>.md` with the full worker prompt
6. Compute prompt hash with a portable command (`shasum -a 256` on macOS/Linux; `sha256sum` on Linux-only environments) and store in the manifest per-worker record

### Relevant References

- `scripts/validate-gen-idea-io.sh` — existing IO validation pattern; extend for companion derivation
- `scripts/validate-gen-plan-io.sh` — second IO validator to use as style reference
- `scripts/ask-codex.sh` — existing Codex invocation; add auto-probe behavior here
- `hooks/loop-codex-stop-hook.sh` — existing nested hook disable probe pattern to replicate (probe at line ~1169)
- `scripts/bitlesson-select.sh` — another instance of the probe pattern
- `scripts/portable-timeout.sh` — timeout wrapper for worker enforcement
- `tests/test-validate-gen-plan-io.sh` — example test file structure to follow for new test suites
- `tests/test-disable-nested-codex-hooks.sh` — existing test that must keep passing after ask-codex.sh change
- `tests/run-all-tests.sh` — hardcoded `TEST_SUITES` array; new tests must be added here explicitly

## Dependencies and Sequence

### Milestones

1. **PR-A: gen-idea directions.json companion**
   - Phase A: Update `scripts/validate-gen-idea-io.sh` — add `.md` enforcement, companion collision rejection, `DIRECTIONS_JSON_FILE:` stdout emission
   - Phase B: Add `scripts/validate-directions-json.sh` — jq-based schema validator for directions.json schema v1
   - Phase C: Update `commands/gen-idea.md` — emit companion JSON after draft write, report both paths, add explore-idea hint
   - Phase D: Add test fixtures under `tests/fixtures/` for valid and invalid directions.json cases, plus gen-idea IO edge cases; add `tests/test-validate-gen-idea-io.sh`, `tests/test-directions-json-schema.sh`, and `tests/test-gen-idea-dual-write.sh` (covers AC-2 dual-write and hint output); register all three in `tests/run-all-tests.sh`

2. **PR-B: explore-idea input and validation layer**
   - Phase A: Add `scripts/validate-explore-idea-io.sh` — resolves input to directions.json, validates direction selectors, enforces all caps, checks run dir collision, emits validation output
   - Phase B: Add `commands/explore-idea.md` — frontmatter with allowed tools, command documentation, confirmation UX, coordinator loop, worker dispatch instructions, result collection, report synthesis instructions
   - Phase C: Add `prompt-template/explore/worker-prompt.md` — worker constraints, loop structure, Codex call contract, result JSON sentinel emission
   - Phase D: Add `prompt-template/explore/report-template.md` — two-tier ranking structure and adoption path format

3. **PR-B: ask-codex.sh auto-probe**
   - Phase A: Add nested hook disable auto-probe inside `scripts/ask-codex.sh` following the existing pattern from `hooks/loop-codex-stop-hook.sh`
   - Phase B: Update `tests/test-ask-codex.sh` with auto-probe coverage; verify `tests/test-disable-nested-codex-hooks.sh` still passes

4. **PR-B: CI test suites**
   - Phase A: Add `tests/test-validate-explore-idea-io.sh`, `tests/test-worker-result-contract.sh`, `tests/test-explore-manifest.sh`, `tests/test-explore-command-structure.sh` with fixtures
   - Phase B: Register all 4 in `tests/run-all-tests.sh` `TEST_SUITES` array

5. **Documentation and version bump**
   - Phase A: Update `README.md` quick start section with optional explore-idea step; update `docs/usage.md` command reference
   - Phase B: Update `.claude/CLAUDE.md` sync rules for directions.json schema and worker constraint synchronization; check `.gitignore` for worktree paths
   - Phase C: Bump version in `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `README.md` from `1.16.0` to `1.17.0`

Milestone 1 (PR-A) must complete before Milestones 2–5 begin. Milestones 2, 3, and 4 can proceed in parallel once PR-A is complete. Milestone 5 depends on Milestones 2–4. The manual functional spike (AC-11) runs after all milestones complete; any divergences are handled as out-of-scope follow-up.

## Task Breakdown

Each task must include exactly one routing tag:
- `coding`: implemented by Claude
- `analyze`: executed via Codex (`/humanize:ask-codex`)

| Task ID | Description | Target AC | Tag (`coding`/`analyze`) | Depends On |
|---------|-------------|-----------|----------------------------|------------|
| task1 | Update `scripts/validate-gen-idea-io.sh`: enforce `.md` suffix, reject existing companion JSON, emit `DIRECTIONS_JSON_FILE:` | AC-1 | coding | - |
| task2 | Add `scripts/validate-directions-json.sh`: jq schema validator for directions.json v1 | AC-3 | coding | - |
| task3 | Update `commands/gen-idea.md`: emit companion JSON after draft write, report both paths, add explore-idea hint | AC-2 | coding | task1, task2 |
| task4 | Add test fixtures for PR-A (valid/invalid directions.json, gen-idea IO edge cases) | AC-1, AC-2, AC-3 | coding | task1, task2 |
| task5 | Add `tests/test-validate-gen-idea-io.sh`, `tests/test-directions-json-schema.sh`, and `tests/test-gen-idea-dual-write.sh` (covers AC-2 dual-write and hint output) | AC-2, AC-12 | coding | task4 |
| task6 | Register PR-A test suites in `tests/run-all-tests.sh` `TEST_SUITES` array | AC-12 | coding | task5 |
| task7 | Add `scripts/validate-explore-idea-io.sh`: input resolution, dirty-checkout hard-fail, direction selection, all hard caps, run dir collision | AC-4, AC-5, AC-5.1 | coding | task6 |
| task8 | Add `commands/explore-idea.md`: frontmatter, args doc, confirmation UX, coordinator loop, worker dispatch and collection, post-dispatch fail-and-record | AC-6, AC-7, AC-8, AC-9, AC-10 | coding | task7 |
| task9 | Add `prompt-template/explore/worker-prompt.md`: worker loop, constraints, result JSON sentinel | AC-9 | coding | task7 |
| task10 | Add `prompt-template/explore/report-template.md`: two-tier ranking structure and adoption path format | AC-10 | coding | task7 |
| task11 | Add nested hook auto-probe to `scripts/ask-codex.sh`; update `tests/test-ask-codex.sh` | AC-13 | coding | task6 |
| task12 | Add `tests/test-validate-explore-idea-io.sh`, `test-worker-result-contract.sh`, `test-explore-manifest.sh`, `test-explore-command-structure.sh` with fixtures | AC-12 | coding | task7, task8, task9 |
| task13 | Register all PR-B test suites in `tests/run-all-tests.sh` `TEST_SUITES` array | AC-12 | coding | task12 |
| task14 | Update `README.md` quick start and `docs/usage.md` command reference | - | coding | task13 |
| task15 | Update `.claude/CLAUDE.md` sync rules; check `.gitignore` for worktree paths | - | coding | task13 |
| task16 | Bump version `1.16.0` → `1.17.0` in `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `README.md` | AC-14 | coding | task14, task15 |
| task17 | Manual smoke run: invoke explore-idea with 2 directions and 1 worker iteration; verify all artifacts exist and no push occurred | AC-15 | coding | task16, task11 |
| task18 | Functional spike: run gen-idea → explore-idea on a real task; record every Functional Spike Checklist item; write `docs/runtime-spike-results.md` | AC-11 | coding | task17 |

## Functional Spike Checklist

These items are derived from spec assumptions that deterministic shell tests cannot verify. After RLCR completes, run `explore-idea` on a real task (using `gen-idea` output as input, 2–3 directions, 1–2 worker iterations) and record each item as **pass**, **partial**, or **fail** with brief observation notes. File divergences as follow-up via `/humanize:gen-plan` — do not patch them inline.

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

## Claude-Codex Deliberation

### Agreements

- PR-A (gen-idea companion) must complete before PR-B (explore-idea) begins: the `directions.json` schema is the foundational contract that both layers depend on.
- Runtime behavioral assumptions (worker isolation, parallel execution, Codex root scoping, result collection) are best validated by a real functional spike after implementation, not by a pre-implementation capability checklist; the `## Functional Spike Checklist` captures these assumptions so divergences are trackable.
- Hard numeric caps (10 directions, 10 concurrency, 3 iterations, 60/20 min timeouts) are correct and sufficient to prevent unbounded fanout.
- Durable run state (`manifest.json` before dispatch, `worker-results.jsonl` per result) is the right design for inspectability and postmortem debugging.
- `tests/run-all-tests.sh` registration via the hardcoded `TEST_SUITES` array is mandatory; forgetting registration silently drops coverage.
- `CLAUDE_PROJECT_DIR=$PWD` is the correct seam for scoping `ask-codex.sh` to the worker worktree root; `resolve_project_root()` in the script already prefers this env var.

### Resolved Disagreements

- **DEC-3 hook disabling approach**: Claude proposed an opt-in `--disable-nested-codex-hooks` flag for `ask-codex.sh` callers. Second Codex review rejected this, citing that the existing codebase pattern (used in `hooks/lib/loop-codex-stop-hook.sh` and `scripts/bitlesson-select.sh`) is script-level auto-probe, not caller-pushed flags. Resolution: `ask-codex.sh` probes internally and applies the flag automatically; no caller change needed, no new flag exposed.
- **AC-2 companion collision gap**: Claude's initial AC-2 did not explicitly require rejecting an already-existing `<output>.directions.json`. Second Codex review identified this as a missing first-class validation. Resolution: AC-1 now explicitly covers companion collision rejection in `validate-gen-idea-io.sh`, and its tests cover the collision case.
- **Spike position and nature**: Initial plan placed a pre-implementation capability spike as a blocking gate between PR-A and PR-B. Revised per user direction: the spike is a post-RLCR functional validation on a real task, with a predefined checklist derived from spec assumptions. Divergences are out-of-scope follow-up, not inline patches.

### Convergence Status

- Final Status: `converged`

## Pending User Decisions

- DEC-1: Dirty main checkout before explore-idea dispatch
  - Claude Position: Hard-fail — reject if main checkout has uncommitted tracked changes; no `--allow-dirty` in MVP
  - Codex Position: N/A - open question (Codex flagged as missing requirement, did not take opposing position)
  - Tradeoff Summary: Hard-fail prevents inconsistent prototype base states at the cost of forcing users to stash or commit before exploring; warn-and-proceed reduces friction but risks divergent branches
  - Decision Status: Hard-fail (user confirmed)

- DEC-2: Spike timing and divergence handling
  - Claude Position: Post-RLCR functional spike on a real task; divergences filed as follow-up via `/humanize:gen-plan`
  - Codex Position: N/A - the original question (serial fallback if pre-implementation spike failed) is superseded by the post-implementation spike model
  - Tradeoff Summary: Post-RLCR spike lets implementation proceed on spec assumptions and validates them empirically; pre-implementation gate would have required capabilities to be proven before any PR-B code was written
  - Decision Status: Post-RLCR functional spike; divergences are out-of-scope follow-up (user confirmed)

- DEC-3: Codex hook disabling approach
  - Claude Position: Opt-in `--disable-nested-codex-hooks` flag passed by callers
  - Codex Position: Script-level auto-probe in `ask-codex.sh` to match existing codebase pattern; no caller flag needed
  - Tradeoff Summary: Auto-probe is cleaner and safer — one place to maintain, no risk of callers forgetting the flag; opt-in flag distributes responsibility to callers
  - Decision Status: Auto-probe in `ask-codex.sh` (Codex REQUIRED_CHANGES; adopted)

- DEC-4: Crash recovery scope for MVP
  - Claude Position: Fail-and-record — write `.failed`, record failure reason in `manifest.json`, require manual cleanup; no resume
  - Codex Position: N/A - open question (Codex flagged as missing requirement, did not take opposing position)
  - Tradeoff Summary: Fail-and-record is simpler and ships faster; resume logic adds significant complexity for a feature not yet running in production
  - Decision Status: Fail-and-record for MVP (both Claude and Codex agreed; user confirmed via numeric caps confirmation)

## Implementation Notes

### Code Style Requirements

- Implementation code and comments must NOT contain plan-specific terminology such as "AC-", "Milestone", "Step", "Phase", or similar workflow markers
- These terms are for plan documentation only, not for the resulting codebase
- Use descriptive, domain-appropriate naming in code instead

--- Original Design Draft Start ---

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

`ask-codex.sh` must disable nested Codex hooks when supported, using the same `--disable codex_hooks` probing pattern already used by the RLCR stop hook and `bitlesson-select.sh`.

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

--- Original Design Draft End ---
