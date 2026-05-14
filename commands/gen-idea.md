---
description: "Generate a repo-grounded idea draft via directed-swarm exploration"
argument-hint: "<idea-text-or-path> [--n <int>] [--output <path>]"
allowed-tools:
  - "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/validate-gen-idea-io.sh:*)"
  - "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/validate-directions-json.sh:*)"
  - "Bash(rm:*)"
  - "Read"
  - "Glob"
  - "Grep"
  - "Task"
  - "Write"
---

# Generate Idea Draft from Loose Input

Read and execute below with ultrathink.

## Hard Constraint: Draft-Only Output

This command MUST NOT implement features, modify source code, or create commits while producing the draft. Permitted writes are limited to the output draft file and its companion `directions.json` artifact produced in Phase 4; prerequisite directory creation for the default `.humanize/ideas/` path by the validation script is permitted. `rm` is permitted solely to delete those two just-written files when companion JSON validation fails (no-partial-output cleanup). All exploration subagents run read-only.

This command transforms a loose idea into a repo-grounded draft suitable as input to `/humanize:gen-plan`. It applies directed-diversity exploration: a lead picks N orthogonal directions, N parallel `Explore` subagents develop each, the lead synthesizes a draft with one primary direction plus N-1 alternatives. Each direction carries objective evidence from the repo.

## Workflow Overview

> **Sequential Execution Constraint**: All phases MUST execute strictly in order. Each phase fully completes before the next.

1. Parse Input
2. IO Validation
3. Direction Generation
4. Parallel Exploration
5. Synthesis, Write Draft, and Write Companion JSON

---

## Phase 0: Parse Input

Extract from `$ARGUMENTS`:
- First positional: inline idea text or path to a `.md` file (required).
- `--n <int>`: number of directions. Default 6.
- `--output <path>`: target draft path. Default resolved by the validation script.

Do not interpret or rewrite the idea text here. Pass `$ARGUMENTS` through to Phase 1 unchanged.

---

## Phase 1: IO Validation

Run:
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/validate-gen-idea-io.sh" $ARGUMENTS
```

Handle exit codes:
- `0`: Parse stdout to extract `INPUT_MODE`, `OUTPUT_FILE`, `DIRECTIONS_JSON_FILE`, `SLUG`, `TEMPLATE_FILE`, `N` (each appears on its own `KEY: value` line). When `INPUT_MODE` is `file`, stdout additionally contains an `IDEA_BODY_FILE: <path>` line; extract that too. Continue to Phase 2. (`SLUG` is informational — the script has already incorporated it into `OUTPUT_FILE`, so later phases do not need to use `SLUG` directly.)
- `1`: Report "Missing or empty idea input" and stop.
- `2`: Report "Input looks like a file path but is missing, not readable, or not `.md`" and stop.
- `3`: Report "Output directory does not exist — please create it or choose a different path" and stop.
- `4`: Report "Output file already exists — choose a different path" and stop.
- `5`: Report "No write permission to output directory" and stop.
- `6`: Report "Invalid arguments — output path must have `.md` suffix" with the stdout usage text and stop.
- `7`: Report "Template file missing — plugin configuration error" and stop.
- `8`: Report "Companion directions.json already exists — choose a different output path or remove the existing companion file" and stop.

Before `VALIDATION_SUCCESS`, stdout may contain one or more lines starting with `WARNING:` (for example, `WARNING: short idea (<N> chars); proceeding` when an inline idea is under 10 characters). Surface these warnings to the user in your final report but continue Phase 2 normally. `WARNING:` lines are informational, not errors.

Obtain the idea body into memory as `IDEA_BODY`, based on `INPUT_MODE`:
- `inline`: stdout contains a sentinel block at the end of the success output; extract all text between the `=== IDEA_BODY_BEGIN ===` and `=== IDEA_BODY_END ===` lines (exclusive). The script emits a trailing newline after the last body line.
- `file`: read the full contents of `IDEA_BODY_FILE` using the `Read` tool.

Preserve byte-identical content in memory for later phases. No on-disk tempfile is created in inline mode — the stdout sentinel block is the authoritative source.

---

## Phase 2: Direction Generation

Generate exactly `N` orthogonal directions for exploring the idea.

### Context to Gather

Before generating directions, read (paths relative to the project root, which is `$(git rev-parse --show-toplevel)`):
- `README.md` at the project root.
- `CLAUDE.md` at the project root (if it exists).
- `.claude/CLAUDE.md` (if it exists).
- Top-level directory listing via `Glob` with pattern `*` (one level, no recursion).

This context grounds the directions in the actual repo rather than generic brainstorming.

### Generation Rules

Produce exactly `N` direction entries. Each entry has:
- `name`: a 2-5 word short label.
- `rationale`: a single sentence explaining why this angle is distinct from the other directions.

Hard constraint: **orthogonality**. Two near-duplicate directions defeat the directed-diversity premise. Before returning:
- If two directions feel like dupes, replace one with a genuinely different angle.
- If a direction collapses to "just do X better" with no angle distinction, replace it.
- Do not emit directions that merely restate the idea in different words.

### Retry and Degradation

- If the first pass returns fewer than `N` entries, regenerate once with an explicit "you MUST produce `N` orthogonal directions" instruction.
- If the second pass still returns fewer than `N` but at least 2, proceed with the reduced count and emit a warning to the user: `Warning: direction generation returned <count> of <N> requested directions; proceeding with reduced count.`
- If fewer than 2 directions are produced, stop with error: `direction generation degraded; retry.`

Store the final direction list as `DIRECTIONS` (ordered; index 0..len-1).

---

## Phase 3: Parallel Exploration

Dispatch all directions in a **single Task-tool message** containing one Task invocation per direction. This is the W2S parallel-swarm step.

### Subagent Invocation

For each direction in `DIRECTIONS`, launch one `Explore` subagent. Each invocation prompt MUST include:

1. A verbatim copy of the idea body (`IDEA_BODY`) captured in Phase 1.
2. The assigned direction (name + rationale).
3. The following instruction block (reproduce verbatim in the subagent prompt):

> Explore this direction within the current repo. Gather OBJECTIVE EVIDENCE:
> - Specific repo paths with existing patterns worth extending.
> - Prior art or precedent in the codebase or adjacent tooling.
> - Measurable considerations (approximate complexity, LOC surface, performance implications) where discoverable from reading the code.
>
> Read-only. Do not write any files.
>
> If no concrete evidence exists for this direction, report the literal string `exploratory, no concrete precedent` once in OBJECTIVE_EVIDENCE and stop exploring further. Fabrication of references is forbidden.
>
> Return a structured proposal with exactly these fields:
> - `APPROACH_SUMMARY`: concrete design description (what to build, core mechanism, affected components).
> - `OBJECTIVE_EVIDENCE`: bullet list of repo paths, prior art, or the `exploratory, no concrete precedent` sentinel.
> - `KNOWN_RISKS`: short bullet list.
> - `CONFIDENCE`: one of `high`, `medium`, `low`.

### Collection and Degradation

Collect all subagent responses. For each response:
- Parse the four required fields. If a field is missing, mark that proposal as degraded and drop it.
- If fewer than 2 proposals survive, stop with error: `exploration phase degraded; retry.`
- Otherwise continue with the surviving proposals.

Associate each surviving proposal with its originating direction (so Phase 4 can label it with the original direction name). When numbering alternatives in Phase 4 after any drops, renumber survivors sequentially as Alt-1..Alt-K (where K is the count of surviving non-primary directions). Do not preserve gaps from dropped proposals.

---

## Phase 4: Synthesis and Write

### Step 4.1: Pick the Primary Direction

Review all surviving proposals. Choose the strongest as the primary based on:
1. Evidence density — more concrete repo references outranks fewer.
2. Fit with existing repo patterns — extending patterns outranks introducing unfamiliar paradigms.
3. Implementation surface area — prefer smaller surface where quality is otherwise comparable.
4. Declared `CONFIDENCE` — `high` > `medium` > `low` as tiebreaker.

Record the chosen direction as `PRIMARY`; the remaining surviving directions become the Alt-1..Alt-K list (where K is the number of non-primary survivors, K ≤ N-1), numbered sequentially in their original direction order with no gaps for any dropped proposals.

### Step 4.2: Infer Title

Generate a 4-10 word Title Case title that captures the primary direction, not the original input phrasing verbatim. Example: idea `add undo/redo` with primary direction `command-pattern history` yields title `Command-Pattern Undo Stack For The Editor`.

### Step 4.3: Populate the Template

Read the template file located at `TEMPLATE_FILE` (from Phase 1 stdout).

Produce the finalized draft content in memory by replacing placeholders:
- `<TITLE>` — the inferred title.
- `<ORIGINAL_IDEA>` — byte-identical value of `IDEA_BODY` captured in Phase 1. Preserve line breaks, trailing newline, and all formatting. Do NOT paraphrase or re-indent.
- `<PRIMARY_NAME>` — primary direction's short name.
- `<PRIMARY_RATIONALE>` — primary direction's rationale (from Phase 2).
- `<PRIMARY_APPROACH_SUMMARY>` — primary proposal's `APPROACH_SUMMARY`.
- `<PRIMARY_OBJECTIVE_EVIDENCE>` — primary proposal's `OBJECTIVE_EVIDENCE`, rendered as a bullet list. If the subagent returned only the literal sentinel `exploratory, no concrete precedent`, render it as a single bullet: `- exploratory, no concrete precedent`.
- `<PRIMARY_KNOWN_RISKS>` — primary proposal's `KNOWN_RISKS`, rendered as a bullet list.
- `<ALTERNATIVES>` — for each non-primary survivor at its Alt index `i` (1-based, sequential per Step 4.1), emit:

  ```markdown
  ### Alt-<i>: <name>
  - Gist: <one-paragraph summary derived from APPROACH_SUMMARY>
  - Objective Evidence:
    - <bullet from OBJECTIVE_EVIDENCE>
    - ...
  - Why not primary: <one sentence stating the tradeoff vs PRIMARY>
  ```

  Separate consecutive Alt entries with a single blank line.

- `<SYNTHESIS_NOTES>` — one paragraph describing which elements from the alternatives could fold into the primary if the user chose a different direction. This is the lead's own synthesis note, not a subagent output.

### Step 4.4: Write the Draft File

Write the finalized content to `OUTPUT_FILE` using the `Write` tool. Single write; no progressive edits.

### Step 4.5: Build and Write Companion JSON

Construct the companion `directions.json` in memory using all surviving direction proposals from Phase 3, then write it to `DIRECTIONS_JSON_FILE` (from Phase 1 stdout).

**JSON structure (schema version 1):**

```json
{
  "schema_version": 1,
  "title": "<TITLE from Step 4.2>",
  "original_idea": "<IDEA_BODY verbatim>",
  "synthesis_notes": "<SYNTHESIS_NOTES from Step 4.3>",
  "metadata": {
    "n_requested": <N>,
    "n_returned": <count of surviving directions>,
    "timestamp": "<YYYYMMDD-HHmmss>",
    "draft_path": "<OUTPUT_FILE>"
  },
  "directions": [
    {
      "direction_id": "dir-<NN>-<dir-slug>",
      "dir_slug": "<lowercase-alphanumeric-hyphen slug derived from direction name>",
      "source_index": <original 0-based index from DIRECTIONS list>,
      "display_order": <0 for primary, 1..K for alternatives in sequential order>,
      "is_primary": <true for PRIMARY, false otherwise>,
      "name": "<direction name>",
      "rationale": "<direction rationale from Phase 2>",
      "raw_phase3_response": "<exact raw subagent response text for this direction>",
      "approach_summary": "<APPROACH_SUMMARY from subagent>",
      "objective_evidence": ["<bullet item>", ...],
      "known_risks": ["<bullet item>", ...],
      "confidence": "<high|medium|low>"
    }
  ]
}
```

**Field derivation rules:**
- `direction_id`: `"dir-" + zero-padded source_index (2 digits) + "-" + dir_slug`. Example: `"dir-00-command-history"`.
- `dir_slug`: Derived from direction name — lowercase, replace non-alphanumeric with hyphens, collapse consecutive hyphens, strip leading/trailing hyphens. Must match `^[a-z0-9-]+$`.
- `dir_slug` collision handling: if two direction names slugify to the same value, append `-2`, `-3`, etc. by original `source_index` order until every `dir_slug` is unique.
- `source_index`: The 0-based index of this direction in the original `DIRECTIONS` list from Phase 2 (before any degradation drops).
- `display_order`: 0 for the primary direction, 1 through K for alternatives in their sequential order.
- `is_primary`: `true` for exactly one direction (PRIMARY), `false` for all others.
- `objective_evidence`: Each bullet item from the subagent's `OBJECTIVE_EVIDENCE` field as a string array element.
- `known_risks`: Each bullet item from the subagent's `KNOWN_RISKS` field as a string array element.
- `metadata.n_returned` must equal `directions.length`.

After writing `DIRECTIONS_JSON_FILE`, validate it:
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/validate-directions-json.sh" "$DIRECTIONS_JSON_FILE"
```

If validation fails, delete both `OUTPUT_FILE` and `DIRECTIONS_JSON_FILE` and stop with error: `companion JSON validation failed — this is a bug in the command; please report it`.

### Step 4.6: Report

Report to the user:
- Draft path written: `OUTPUT_FILE`
- Companion JSON path written: `DIRECTIONS_JSON_FILE`
- Primary direction name.
- Requested `N` and the actual direction count (note if reduced due to degradation).
- Next-step hints:
  ```
  To explore directions as parallel prototypes, run: /humanize:explore-idea <DIRECTIONS_JSON_FILE>
  To turn this draft into a plan, run: /humanize:gen-plan --input <OUTPUT_FILE> --output <plan-path>
  ```

---

## Error Handling

- Phase 1 validation errors stop the command with a clear message. No partial output.
- Phase 2 degradation follows the retry-once + ≥2 minimum rule stated above.
- Phase 3 degradation follows the drop-and-continue + ≥2 minimum rule stated above.
- Never fabricate repo references or prior art. The `exploratory, no concrete precedent` sentinel from subagents is preserved verbatim in the draft.
- If any phase stops with an error, do not write a partial `OUTPUT_FILE` or `DIRECTIONS_JSON_FILE`.
- If companion JSON validation fails after writing both files, delete both files and stop.
