---
description: "Refine an annotated implementation plan and generate a QA ledger"
argument-hint: "--input <path/to/annotated-plan.md> [--output <path/to/refined-plan.md>] [--qa-dir <path/to/qa-dir>] [--alt-language <language-or-code>] [--discussion|--direct]"
allowed-tools:
  - "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/validate-refine-plan-io.sh:*)"
  - "Read"
  - "Glob"
  - "Grep"
  - "Write"
  - "Edit"
  - "AskUserQuestion"
hide-from-slash-command-tool: "true"
---

# Refine Annotated Plan

Read and execute below with ultrathink.

## Hard Constraint: Planning-Only Refinement

This command MUST ONLY refine plan artifacts. It MUST NOT implement repository code, modify source files unrelated to the plan outputs, start RLCR automatically, or create a new plan schema.

Permitted writes are limited to:
- The refined plan output file (`--output`, or `--input` in in-place mode)
- The QA document under `--qa-dir`
- Optional translated language variants for the refined plan and QA document

The refined plan MUST reuse the existing `gen-plan` schema. Do not invent new top-level sections. Keep required sections intact, preserve optional sections when present, and preserve any `--- Original Design Draft Start ---` appendix or other non-comment content unless a comment explicitly requires a plan-level change there.

## Workflow Overview

> **Sequential Execution Constraint**: Execute the phases strictly in order. Do NOT parallelize work across phases. Finish each phase before moving to the next one.

1. **Execution Mode Setup**: Parse CLI arguments and derive output paths
2. **Load Project Config**: Resolve `alternative_plan_language` and mode defaults using `config-loader.sh` semantics
3. **IO Validation**: Run `validate-refine-plan-io.sh`
4. **Comment Extraction**: Scan the annotated plan and extract valid comment blocks (`CMT:`/`ENDCMT`, `<cmt>`/`</cmt>`, `<comment>`/`</comment>`)
5. **Comment Classification**: Classify each extracted comment for downstream handling
6. **Comment Processing**: Answer questions, apply requested plan edits, and perform targeted research
7. **Plan Refinement**: Produce the comment-free refined plan while preserving the `gen-plan` structure
8. **QA Generation**: Populate the QA template with the comment ledger and outcomes
9. **Atomic Write**: Commit the refined plan, QA document, and optional variants as one transaction

---

## Phase 0: Execution Mode Setup

Parse `$ARGUMENTS` and set the following variables:

- `INPUT_FILE` from `--input` (required)
- `OUTPUT_FILE` from `--output`
- `QA_DIR` from `--qa-dir`
- `CLI_ALT_LANGUAGE_RAW` from `--alt-language`
- `REFINE_PLAN_MODE_DISCUSSION=true` if `--discussion` is present
- `REFINE_PLAN_MODE_DIRECT=true` if `--direct` is present

Argument rules:

1. `--input <path>` is required.
2. `--output <path>` is optional. If omitted, set `OUTPUT_FILE=INPUT_FILE` for in-place mode.
3. `--qa-dir <path>` is optional. If omitted, set `QA_DIR=.humanize/plan_qa`.
4. `--alt-language <language-or-code>` is optional. If present without a value, report `Invalid arguments: --alt-language requires a value` and stop.
5. `--discussion` and `--direct` are mutually exclusive. If both are present, report `Cannot use --discussion and --direct together` and stop.

Derived paths:

1. Compute `IN_PLACE_MODE=true` when `OUTPUT_FILE` equals `INPUT_FILE`; otherwise `false`.
2. Compute `QA_FILE` from the input basename, not the output basename:
   - `plan.md` becomes `<QA_DIR>/plan-qa.md`
   - `docs/my-plan.md` becomes `<QA_DIR>/my-plan-qa.md`
   - `plan` becomes `<QA_DIR>/plan-qa.md`
3. Keep `--alt-language` out of the validator invocation because `validate-refine-plan-io.sh` does not accept it. Pass only:
   - `--input`
   - `--output` when provided
   - `--qa-dir` when provided
   - `--discussion` or `--direct` when provided

Scope rules for v1:

- Do not introduce `--language` or `--qa-output`
- Do not add new config keys
- Do not auto-start RLCR after refinement

---

## Phase 0.5: Load Project Config

Resolve configuration by following the same precedence and merge semantics defined in `${CLAUDE_PLUGIN_ROOT}/scripts/lib/config-loader.sh`. Reuse that behavior; do not invent a separate refine-plan config model.

### Config Merge Semantics

Use the same layer order as `load_merged_config`:

1. Required default config: `${CLAUDE_PLUGIN_ROOT}/config/default_config.json`
2. Optional user config: `${XDG_CONFIG_HOME:-$HOME/.config}/humanize/config.json`
3. Optional project config: `${HUMANIZE_CONFIG:-$PROJECT_ROOT/.humanize/config.json}`

Later layers override earlier layers. Malformed optional JSON objects are treated as warnings and ignored. A malformed required default config is a fatal configuration error.

### Values to Extract

Read the merged config and resolve:

- `CONFIG_ALT_LANGUAGE_RAW` from `alternative_plan_language`
- `CONFIG_GEN_PLAN_MODE_RAW` from `gen_plan_mode`

### Mode Resolution

Resolve `REFINE_PLAN_MODE` with this priority:

1. CLI `--discussion` => `discussion`
2. CLI `--direct` => `direct`
3. Valid config value `gen_plan_mode` (`discussion` or `direct`, case-insensitive)
4. Default => `discussion`

If `gen_plan_mode` is present but invalid, log a warning and fall back to the next rule.

### Alternative Language Resolution

Resolve the variant language with this priority:

1. CLI `--alt-language`
2. Config `alternative_plan_language`
3. No variant

Normalize the value case-insensitively using this mapping table:

| Language   | Code | Suffix |
|------------|------|--------|
| Chinese    | zh   | `_zh`  |
| Korean     | ko   | `_ko`  |
| Japanese   | ja   | `_ja`  |
| Spanish    | es   | `_es`  |
| French     | fr   | `_fr`  |
| German     | de   | `_de`  |
| Portuguese | pt   | `_pt`  |
| Russian    | ru   | `_ru`  |
| Arabic     | ar   | `_ar`  |

Normalization rules:

1. Trim leading and trailing whitespace before matching.
2. Accept either the full language name or the ISO code from the table.
3. Treat `English` / `en` as a no-op: no translated variant is generated.
4. If the CLI value is unsupported, report `Unsupported --alt-language "<value>"` and stop.
5. If the config value is unsupported, log a warning and disable variant generation.

Set:

- `ALT_PLAN_LANGUAGE` to the normalized language name or empty string
- `ALT_PLAN_LANG_CODE` to the normalized code or empty string

Do not depend on deprecated `chinese_plan`. `refine-plan` only uses `alternative_plan_language`.

---

## Phase 1: IO Validation

Run the validator with the parsed arguments, excluding `--alt-language`:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/validate-refine-plan-io.sh" <validated-arguments>
```

Handle exit codes exactly:

- Exit code 0: Continue to Phase 2
- Exit code 1: Report `Input file not found` and stop
- Exit code 2: Report `Input file is empty` and stop
- Exit code 3: Report `Input file has no comment blocks` and stop
- Exit code 4: Report `Input file is missing required gen-plan sections` and stop
- Exit code 5: Report `Output directory does not exist or is not writable - please fix it` and stop
- Exit code 6: Report `QA directory is not writable` and stop
- Exit code 7: Report `Invalid arguments` and show the validator usage, then stop

Validation notes:

1. `validate-refine-plan-io.sh` may create `QA_DIR` when it does not exist. Treat that as expected setup, not as a side effect to undo.
2. After validation succeeds, read the input file and preserve its exact contents as `ORIGINAL_PLAN_TEXT`.
3. Do not mutate the validated input yet. All writes happen in Phase 7 only.

---

## Phase 2: Comment Extraction

Extract comments using a **stateful scanner** equivalent to POSIX `awk` wrapped by `bash`, not a naive regular expression pass. The scanner behavior must match the Task 3 findings.

### Scanner Requirements

Track these states while scanning the validated input in document order:

- `IN_FENCE` with the active fence marker (` ``` ` or ` ~~~ `)
- `IN_HTML_COMMENT` for `<!-- ... -->`
- `IN_CMT_BLOCK`
- `NEAREST_HEADING`

Extraction rules:

1. Support three comment formats:
   - Classic: `CMT:` as start marker and `ENDCMT` as end marker
   - Short tag: `<cmt>` as start marker and `</cmt>` as end marker
   - Long tag: `<comment>` as start marker and `</comment>` as end marker
2. Support both inline and multi-line blocks for all formats:
   - Inline: `Text before CMT: comment text ENDCMT text after`
   - Inline: `Text before <cmt>comment text</cmt> text after`
   - Inline: `Text before <comment>comment text</comment> text after`
   - Multi-line:
     ```markdown
     CMT:
     comment text
     ENDCMT
     ```
     ```markdown
     <cmt>
     comment text
     </cmt>
     ```
     ```markdown
     <comment>
     comment text
     </comment>
     ```
3. Ignore comment markers inside fenced code blocks.
4. Ignore comment markers inside HTML comments.
5. Update `NEAREST_HEADING` whenever a Markdown heading is encountered outside fenced code and HTML comments.
6. Preserve surrounding non-comment text when removing inline comment blocks from the working plan text.
7. Assign raw comment IDs in document order as `CMT-1`, `CMT-2`, ... only for non-empty blocks.
8. If a block is empty after trimming whitespace, remove it from the working plan text but do not create a ledger item and do not consume an ID.

### Extracted Metadata

For each non-empty comment block, capture:

- `id` (`CMT-N`)
- `original_text` exactly as written between the comment markers
- `normalized_text` with surrounding whitespace trimmed
- `start_line`, `start_column`
- `end_line`, `end_column`
- `nearest_heading` or `Preamble` when no heading exists yet
- `location_label` for QA output
- `form` = `inline` or `multiline`
- `context_excerpt` from the nearest non-comment source text

### Parse Errors

These are fatal extraction errors:

1. Nested comment start marker while already inside a comment block
2. Comment end marker encountered while not inside a comment block or wrong end marker for the format
3. End of file reached while still inside a comment block

Every fatal parse error MUST report:

- The error kind
- The exact line and column
- The nearest heading
- A short context excerpt

Examples of acceptable messages:

- `Comment parse error: nested comment block at line 48, column 3 near "## Acceptance Criteria" (context: "<cmt>split AC-2...")`
- `Comment parse error: stray comment end marker at line 109, column 1 near "## Task Breakdown" (context: "</comment>")`
- `Comment parse error: missing end marker for block opened at line 72, column 5 near "## Dependencies and Sequence"`

### Outputs from Phase 2

Produce:

- `EXTRACTED_COMMENTS`: ordered list of comment records
- `PLAN_WITH_COMMENTS_REMOVED`: the original plan text with every valid comment block removed and surrounding inline text preserved

If `EXTRACTED_COMMENTS` is empty after removing no-op blocks, report `No non-empty CMT blocks remain after parsing` and stop.

---

## Phase 3: Comment Classification

Classify every extracted comment for downstream handling.

### Primary Classification Set

Each raw comment block must receive exactly one primary classification:

- `question`
- `change_request`
- `research_request`

### Heuristic Rules

Use these heuristics first:

- `question`: asks why, how, what, explain, clarify, or says the plan is unclear
- `change_request`: asks to add, remove, delete, rewrite, restore, rename, split, merge, or otherwise modify the plan
- `research_request`: asks to investigate the repository, compare existing patterns, confirm current behavior, or gather evidence before deciding

When more than one intent appears in the same raw block:

1. Keep the raw ledger ID unchanged (`CMT-N`)
2. Create deterministic processing sub-items in textual order: `CMT-N.1`, `CMT-N.2`, ...
3. Assign each sub-item one of the three classifications above
4. Assign the raw block a dominant classification for the QA ledger using this precedence:
   - `research_request`
   - `change_request`
   - `question`

### Ambiguity Handling

If classification is still ambiguous after applying the heuristics:

- In `discussion` mode: use `AskUserQuestion` to confirm the classification before continuing
- In `direct` mode: choose the most action-driving interpretation and record the assumption in the QA document

Examples:

- `Why do we need two config layers here?` => `question`
- `Delete task5 and fold its work into task4.` => `change_request`
- `Investigate how config loading works in this repo before deciding whether AC-3 should change.` => `research_request`, or split into research plus follow-up change sub-items if the block clearly contains both intents

### Classification Record

For each raw comment block and any sub-items, record:

- `id`
- `parent_id` when applicable
- `classification`
- `classification_rationale`
- `needs_user_confirmation` (`true` or `false`)
- `resolved_via_discussion` (`true` or `false`)

---

## Phase 4: Comment Processing

Process comments in document order. When a raw block has sub-items, process the sub-items in order before moving to the next raw block.

### `question`

Default behavior:

1. Answer the question in the QA document.
2. Apply only minimal clarifying plan edits when the current plan text is genuinely ambiguous or misleading.
3. Do not use a question as an excuse to expand scope, add implementation detail, or rewrite unrelated sections.

Preferred destinations for light clarification:

- `## Goal Description`
- `## Feasibility Hints and Suggestions`
- `## Dependencies and Sequence`
- `## Implementation Notes`

### `change_request`

Default behavior:

1. Apply the requested plan edits directly to the refined plan draft.
2. Keep the `gen-plan` structure intact.
3. Propagate changes across all affected sections so the plan stays internally consistent.

Consistency obligations:

- Acceptance criteria still match referenced tasks
- Task Breakdown still points to existing ACs
- Task dependencies still reference existing task IDs or `-`
- Milestones and sequencing remain aligned with the changed scope
- `Claude-Codex Deliberation` and `Pending User Decisions` reflect the new state
- Task routing tags remain exactly `coding` or `analyze`

### `research_request`

Default behavior:

1. Perform targeted repository research using only `Read`, `Glob`, and `Grep`.
2. Keep the research tightly scoped to the comment. Do not drift into implementation work.
3. Summarize the files and patterns examined in the QA document.
4. Integrate the conclusion into the refined plan if the evidence supports a clear plan update.
5. If the research narrows the issue but still requires a human choice, add or update a `DEC-N` item in `## Pending User Decisions` and record the same decision in the QA document.

### Resolution Rules

1. Every raw `CMT-N` must end with one disposition:
   - `answered`
   - `applied`
   - `researched`
   - `deferred`
   - `resolved`
2. Preserve the original comment text in the QA document exactly as captured in Phase 2.
3. If a comment cannot be fully resolved without user input:
   - In `discussion` mode, ask only the minimum necessary question
   - In `direct` mode, make the smallest safe assumption, mark it explicitly in QA, and add a pending decision when the assumption materially affects the plan
4. If unresolved user decisions remain after processing, the plan convergence status must be `partially_converged`
5. If all comments are fully resolved and no pending decisions remain, preserve or set convergence status to `converged`

---

## Phase 5: Generate Refined Plan

Starting from `PLAN_WITH_COMMENTS_REMOVED`, apply the accepted refinements from Phase 4 and produce `REFINED_PLAN_TEXT`.

### Structural Preservation Rules

The refined plan MUST retain these required sections:

- `## Goal Description`
- `## Acceptance Criteria`
- `## Path Boundaries`
- `## Feasibility Hints and Suggestions`
- `## Dependencies and Sequence`
- `## Task Breakdown`
- `## Claude-Codex Deliberation`
- `## Pending User Decisions`
- `## Implementation Notes`

Optional sections that MUST be preserved when present in the input:

- `## Codex Team Workflow`
- `## Convergence Log`
- `--- Original Design Draft Start ---` appendix and its matching end marker

### Refinement Rules

1. Remove every resolved comment marker and all enclosed comment text from the refined plan.
2. Do not add any new top-level schema section.
3. Preserve `AC-X` / `AC-X.Y` formatting.
4. Preserve task IDs unless a comment explicitly requests a structural change.
5. If task IDs or AC IDs change, update all references consistently across the plan.
6. Keep task routing tags restricted to `coding` or `analyze`.
7. Keep the refined plan in the same main language as the input plan. Only normalize mixed-language content when the input is ambiguous and discussion-mode user input explicitly requests normalization.

### Main Language Detection

Determine the primary language of the input plan after comment removal.

Rules:

1. Use the dominant language of headings and prose as the default main language.
2. If the plan is clearly mixed-language and the dominant language is ambiguous:
   - In `discussion` mode, ask the user whether to keep the current mix or normalize to the dominant language
   - In `direct` mode, keep the dominant language inferred from headings and body text; if still tied, default to English
3. The QA document MUST use the same main language as the refined plan.
4. If `ALT_PLAN_LANGUAGE` resolves to the same language as the main language, skip variant generation.

### Required Validation Before Phase 6

Before generating the QA document, verify:

1. All required sections are still present
2. No comment markers remain
3. Every referenced `AC-*` exists
4. Every task dependency references an existing task ID or `-`
5. Every task row has exactly one valid routing tag: `coding` or `analyze`
6. `## Pending User Decisions` and `### Convergence Status` agree with the actual unresolved state

If a validation issue can be fixed by reconciling the plan, fix it before continuing. If it cannot be fixed without inventing requirements, stop and report the blocking inconsistency.

---

## Phase 6: Generate QA Document

Read `${CLAUDE_PLUGIN_ROOT}/prompt-template/plan/refine-plan-qa-template.md` and populate it completely. The QA document is not optional.

### QA Content Requirements

Populate all template sections:

1. `## Summary`
2. `## Comment Ledger`
3. `## Answers`
4. `## Research Findings`
5. `## Plan Changes Applied`
6. `## Remaining Decisions`
7. `## Refinement Metadata`

### Ledger Rules

The `Comment Ledger` MUST contain exactly one row per raw `CMT-N` extracted in Phase 2, in document order.

Each row must include:

- `CMT-ID`
- Dominant classification
- Location
- Original text excerpt
- Final disposition

If a raw block was split into processing sub-items, keep one ledger row for the raw ID and describe the sub-item handling in the detailed sections.

### Section-Specific Rules

- `Answers`: include all `question` items and any clarifying edits made to the plan
- `Research Findings`: include all `research_request` items, the files or patterns examined, and the impact on the plan
- `Plan Changes Applied`: include all `change_request` items and cross-reference updates
- `Remaining Decisions`: include every unresolved or assumption-heavy item that still needs user choice

Language rules:

1. Write the main QA document in the same main language as `REFINED_PLAN_TEXT`
2. Keep identifiers unchanged: `AC-*`, task IDs, file paths, API names, command flags, config keys
3. Preserve the original comment text verbatim inside fenced code blocks

Metadata rules:

1. Record the resolved input path, output path, QA path, date, and counts by classification
2. Record the final convergence status as `converged` or `partially_converged`
3. Record the set of plan sections modified during refinement

---

## Phase 7: Atomic Write Transaction

Do not write any final output until all content is fully prepared.

### Files in Scope

Always prepare:

- Main refined plan at `OUTPUT_FILE`
- Main QA document at `QA_FILE`

Conditionally prepare:

- Plan variant at `OUTPUT_FILE` with `_<ALT_PLAN_LANG_CODE>` inserted before the extension
- QA variant at `QA_FILE` with `_<ALT_PLAN_LANG_CODE>` inserted before the extension

Filename construction rule for variants:

1. If the filename has an extension, insert `_<code>` before the last `.`
2. If the filename has no extension, append `_<code>`

Examples:

- `plan.md` -> `plan_zh.md`
- `feature-a-qa.md` -> `feature-a-qa_zh.md`
- `output` -> `output_zh`

### Variant Content Rules

If `ALT_PLAN_LANGUAGE` is non-empty and different from the main language:

1. Translate the main refined plan into `ALT_PLAN_LANGUAGE`
2. Translate the main QA document into `ALT_PLAN_LANGUAGE`
3. Keep identifiers unchanged
4. For Chinese, default to Simplified Chinese

If `ALT_PLAN_LANGUAGE` is empty or equals the main language, do not create variant files.

### Transaction Rules

1. Prepare all final content in memory first:
   - `REFINED_PLAN_TEXT`
   - `QA_TEXT`
   - Optional `REFINED_PLAN_VARIANT_TEXT`
   - Optional `QA_VARIANT_TEXT`
2. Write each output to a temporary file in the same directory as its final destination.
3. Use temp naming patterns equivalent to:
   - `.refine-plan-XXXXXX`
   - `.refine-qa-XXXXXX`
   - `.refine-plan-variant-XXXXXX`
   - `.refine-qa-variant-XXXXXX`
4. If any temp write or translation step fails:
   - Delete all temp files
   - Leave existing final outputs untouched
   - Report the failure
5. Only after every temp file is written successfully may you replace final outputs.
6. Replace auxiliary outputs before replacing the main in-place plan file, so the primary plan is updated last.
7. If finalization fails after any destination was replaced, restore from backups if the environment allows it; otherwise report the partial-finalization risk explicitly.

Success condition:

- Main refined plan written successfully
- Main QA document written successfully
- Every requested variant written successfully
- No stale temp files remain

### Final Report

Report:

- Path to the refined plan
- Path to the QA document
- Paths to any generated variants
- Number of raw comments processed
- Counts by classification
- Whether pending decisions remain
- Final convergence status
- Whether refinement ran in `discussion` or `direct` mode

---

## Error Handling

If a blocking issue occurs:

- Report the exact phase where it failed
- Include the concrete reason
- Include any relevant line/column/context detail for parse errors
- Do not leave partially refined plan artifacts behind

If a user decision is needed in `discussion` mode:

- Ask only the narrowest question needed to proceed
- Record the decision in the QA document and, when still unresolved, in `## Pending User Decisions`

If a decision is deferred in `direct` mode:

- Make the smallest safe assumption
- Record the assumption explicitly in the QA document
- Mark the plan as `partially_converged` when the deferred item materially affects implementation direction
