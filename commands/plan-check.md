---
description: "Check a plan file for contradictions, ambiguities, and schema compliance"
argument-hint: "--plan path/to/plan.md [--recheck] [--alt-language lang]"
allowed-tools:
  - "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/lib/config-loader.sh:*)"
  - "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/validate-plan-check-io.sh:*)"
  - "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-check.sh:*)"
  - "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/lib/plan-check-common.sh:*)"
  - "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/ask-codex.sh:*)"
  - "Bash(source ${CLAUDE_PLUGIN_ROOT}/scripts/lib/config-loader.sh:*)"
  - "Bash(source ${CLAUDE_PLUGIN_ROOT}/scripts/lib/plan-check-common.sh:*)"
  - "Bash(mktemp:*)"
  - "Bash(diff:*)"
  - "Read"
  - "Write"
  - "Edit"
  - "Task"
  - "AskUserQuestion"
---

# Plan Check

Analyze a plan file for internal contradictions, ambiguities, and structural schema compliance.

## Workflow Overview

1. **Argument Parsing**: Parse `--plan`, `--recheck`, `--alt-language`, and `-h/--help`
2. **Load Project Config**: Resolve merged Humanize config defaults for `plan_check_recheck`
3. **IO Validation**: Validate input plan file and output directory
4. **Load Plan**: Read the plan file content
5. **Check Pipeline**: Spawn a dedicated sub-agent to execute the full check pipeline
6. **Report Generation**: Assemble and write `report.md` and `findings.json`
7. **Contradiction Resolution**: Present contradictions to the user and collect resolutions
8. **Ambiguity Clarification**: Present ambiguities atomically and collect clarifications
9. **Rewrite**: Ask whether to apply resolutions to the plan file in-place
10. **Display Results**: Output the final report to the terminal

---

## Phase 1: Argument Parsing

Parse `$ARGUMENTS` and set:
- `PLAN_FILE`: value following `--plan` (required)
- `RECHECK_REQUESTED=true` if `--recheck` is present; `RECHECK_REQUESTED=false` otherwise
- `ALT_LANGUAGE`: value following `--alt-language` if present

If `-h` or `--help` is present, print:
```
Usage: /humanize:plan-check --plan <path/to/plan.md> [--recheck] [--alt-language <lang>]

Options:
  --plan <path>         Path to the plan file to check (required)
  --recheck             Re-run plan-check after an accepted rewrite (default: disabled)
  --alt-language <lang> Generate an additional report in the specified language
  -h, --help            Show this help message
```

If `--plan` is missing, report error "--plan is required" and stop.

---

## Phase 2: Load Project Config

Resolve configuration using `${CLAUDE_PLUGIN_ROOT}/scripts/lib/config-loader.sh`. Reuse that behavior; do not read `.humanize/config.json` directly.

### Config Merge Semantics

1. Source `${CLAUDE_PLUGIN_ROOT}/scripts/lib/config-loader.sh`.
2. Determine `PROJECT_ROOT` from the directory where the command was invoked.
3. Call `load_merged_config "${CLAUDE_PLUGIN_ROOT}" "${PROJECT_ROOT}"` to obtain `MERGED_CONFIG_JSON`.
4. `load_merged_config` merges these layers in order:
   - Required default config: `${CLAUDE_PLUGIN_ROOT}/config/default_config.json`
   - Optional user config: `${XDG_CONFIG_HOME:-$HOME/.config}/humanize/config.json`
   - Optional project config: `${HUMANIZE_CONFIG:-$PROJECT_ROOT/.humanize/config.json}`
5. Later layers override earlier layers. Malformed optional JSON objects are warnings and ignored. A malformed required default config, missing `jq`, or any other fatal `load_merged_config` failure is a configuration error and must stop the command.

### Recheck Resolution

Use `get_config_value` against `MERGED_CONFIG_JSON` to read:

- `CONFIG_PLAN_CHECK_RECHECK_RAW` from `plan_check_recheck`

Resolve `EFFECTIVE_RECHECK` using this priority:
1. CLI flag: if `RECHECK_REQUESTED=true`, set `EFFECTIVE_RECHECK=true`.
2. Merged config `plan_check_recheck`, when it is exactly `true` or `false` (case-insensitive).
3. Default: `false`.

If `CONFIG_PLAN_CHECK_RECHECK_RAW` is present but is not `true` or `false`, log:
`Warning: unsupported plan_check_recheck "<value>". Expected true or false. Recheck after rewrite is disabled unless --recheck is passed.`

`--recheck` is a positive override only. If config sets `plan_check_recheck=true`, the command rechecks after accepted rewrites without requiring a flag.

---

## Phase 3: IO Validation

Run `${CLAUDE_PLUGIN_ROOT}/scripts/validate-plan-check-io.sh` with:
- `--plan "$PLAN_FILE"`
- `--recheck` when `EFFECTIVE_RECHECK=true`
- `--alt-language "$ALT_LANGUAGE"` when `ALT_LANGUAGE` is non-empty

Capture its exit code:
- `0`: success, continue
- `1`: input missing -- report error and stop
- `2`: input empty -- report error and stop
- `3`: output dir missing and cannot be created -- report error and stop
- `4`: output exists -- report error and stop
- `5`: no write permission -- report error and stop
- `6`: invalid args -- report error and stop
- Any other code: report unexpected validation failure and stop

---

## Phase 4: Load Plan

Use the Read tool to read the plan file at `PLAN_FILE`.

If the file cannot be read, report error and stop.

---

## Phase 5: Check Pipeline (Sub-Agent)

Spawn a dedicated sub-agent via the Task tool to execute the check pipeline.

### Sub-Agent Payload Boundary

The command layer (Claude) must:
1. Create a temporary path with `tmp_plan="$(mktemp)"`, then write `PLAN_CONTENT` to that path using the `Write` tool.
2. Pass ONLY these two pieces of information to the sub-agent:
   - The temporary plan file path (`$tmp_plan`)
   - The plan content as text (for semantic checks that do not need file access)
3. The sub-agent does NOT receive the original plan file path, project history, prior conversation context, or background information.

### Sub-Agent Parameters

```
- model: "sonnet"
- prompt: |
    You are the plan-check pipeline executor.

    Your task is to analyze the provided plan file for:
    1. Structural schema compliance (deterministic)
    2. Internal contradictions (semantic)
    3. Execution-affecting ambiguities (semantic)

    ## Input

    You receive exactly two inputs:
    - `PLAN_TEMP_PATH`: path to a temporary file containing the plan content
    - `PLAN_CONTENT`: the plan content as plain text

    You do NOT receive project history, prior conversation context, or background information.

    ## Deterministic Checks

    Source `${CLAUDE_PLUGIN_ROOT}/scripts/lib/plan-check-common.sh` and run:
    - `plan_check_validate_schema "$PLAN_TEMP_PATH" "${CLAUDE_PLUGIN_ROOT}/prompt-template/plan/gen-plan-template.md"`
      - If the template is unavailable, skip schema validation and produce a single info-level finding explaining the skip
      - `## Task Breakdown` is optional; validate task tags, Target ACs, and dependencies only when the section is present
    - Write findings from deterministic checks to a temporary JSON file

    ## Semantic Checks

    Run the following semantic checks via Codex using `${CLAUDE_PLUGIN_ROOT}/scripts/ask-codex.sh`:

    1. Contradiction check: Invoke the plan-consistency-checker agent logic.
       Pass `PLAN_CONTENT` (the plan text, not the file path). Expect a JSON array of contradiction findings.
       Each finding must have: id, severity=blocker, category=contradiction, location, evidence, explanation, suggested_resolution, affected_acs, affected_tasks.

    2. Ambiguity check: Invoke the plan-ambiguity-checker agent logic.
       Pass `PLAN_CONTENT` (the plan text, not the file path). Expect a JSON array of ambiguity findings.
       Each finding must have: id, severity, category=ambiguity, location, evidence, explanation, suggested_resolution, affected_acs, affected_tasks, ambiguity_details.

    If ask-codex.sh fails or returns malformed JSON, retry once. If still failing after retry, produce a single `runtime-error` info-level finding for that checker and continue. The runtime-error finding must have category `runtime-error`, severity `info`, and explain that the semantic check was skipped due to malformed agent output.

    ## Merge and Deduplicate

    Merge all findings (deterministic + semantic) into a single JSON array.
    Sort by severity: blocker first, then warning, then info.
    Assign sequential F-IDs if any finding lacks a stable ID.

    ## Output

    Return ONLY a JSON object with this exact structure:
    {
      "findings": [...],
      "summary": {
        "total": N,
        "blockers": N,
        "warnings": N,
        "infos": N,
        "status": "pass" | "fail"
      }
    }

    The `findings` array must contain all findings from deterministic and semantic checks.
    `status` is "fail" if any blocker exists, otherwise "pass".
```

### Parse Sub-Agent Output

1. Extract the JSON object from the sub-agent output. The sub-agent may wrap the JSON in markdown code fences; strip them if present.
2. Validate that the output contains a `findings` array and a `summary` object.
3. Post-process ambiguity findings to ensure stable content-addressable IDs:
   - Pipe the `findings` array through `plan_check_postprocess_ambiguity_ids()` from `plan-check-common.sh`.
   - This replaces any ambiguity IDs with a deterministic SHA-256 hash of `section + "\n" + fragment`, regardless of what the sub-agent returned.
4. If parsing fails or the output is malformed, report "Sub-agent returned malformed findings. Falling back to deterministic-only report." and use only the deterministic findings if available.

---

## Phase 6: Report Generation

Create a timestamped report directory under `.humanize/plan-check/<timestamp>/`.

Use `${CLAUDE_PLUGIN_ROOT}/scripts/plan-check.sh` to assemble the report:
```bash
${CLAUDE_PLUGIN_ROOT}/scripts/plan-check.sh \
  --plan "$PLAN_FILE" \
  --report-dir "$REPORT_DIR" \
  --findings-file "$FINDINGS_FILE"
```

Where:
- `REPORT_DIR` is the timestamped directory
- `FINDINGS_FILE` is a temporary file containing the merged findings JSON array

If `--alt-language` is specified, write an additional `report.<lang>.md` using the same structure but with section headers translated.

### Print Initial Findings Report

After `scripts/plan-check.sh` has written `report.md` and `findings.json`, print the initial findings report to the terminal as a contiguous block. Read the generated `report.md` and print its contents. This ensures the user sees the full findings before any resolution or clarification questions are asked, and that terminal output matches the file report (AC-5).

Format:
```
=== Initial Plan Check Findings ===
Plan: <plan_path>
Status: <pass|fail>
Blockers: <N>  Warnings: <N>  Infos: <N>

<report body from report.md>
```

---

## Phase 7: Contradiction Resolution

If any findings have `category=contradiction` and `severity=blocker`, present them to the user for resolution.

For each contradiction finding:
1. Display the contradiction details:
   - ID, section, fragment, evidence, explanation
   - The competing definitions or conflicting statements
2. Use `AskUserQuestion` with:
   - Question: "How do you want to resolve contradiction <id>?"
   - Options:
     - "Accept first definition" (if two definitions are present)
     - "Accept second definition"
     - "Provide custom resolution"
   - If "Provide custom resolution" is selected, prompt for free-text input.
3. Record the resolution:
   - Create a resolution record with the finding ID, the selected option, and any custom text.
   - Mark the finding as resolved.

If no contradictions exist, skip this phase.

---

## Phase 8: Ambiguity Clarification

If any findings have `category=ambiguity` and `severity=blocker`, present them to the user one by one for clarification.

For each ambiguity finding:
1. Display the ambiguity details:
   - ID, section, fragment, evidence, explanation
   - Competing interpretations
   - Execution drift risk
2. Use `AskUserQuestion` to ask the `ambiguity_details.clarification_question`.
   - Options:
     - Provide a specific answer (as free-text if the question is open-ended)
     - "Skip this ambiguity"
3. Record the clarification:
   - If answered: create a clarification record with the finding ID and the user's answer.
   - If skipped: the ambiguity remains a blocker.

The check does not pass until all ambiguity questions are answered. Skipped ambiguities remain as blockers.

If no blocker ambiguities exist, skip this phase.

---

## Phase 9: Resolution Report

After all contradictions are resolved and all ambiguities are clarified (or skipped):

1. Build the resolutions array from the collected resolutions and clarifications.
2. Use `plan_check_build_resolved_json()` to assemble a resolution report JSON including:
   - Original findings
   - Resolutions array
   - Updated summary with resolved status
3. Write the resolution report to `$REPORT_DIR/resolution.json`.
4. Append a resolution summary to `$REPORT_DIR/report.md`.

---

## Phase 10: In-Place Rewrite

If all blockers are resolved (no remaining unresolved contradictions or unskipped ambiguities):

1. Ask the user via `AskUserQuestion`:
   - Question: "Do you want to apply the resolutions and clarifications to the plan file?"
   - Options:
     - "Yes, rewrite the plan file"
     - "No, keep the plan file unchanged"
2. If the user agrees:
   - Generate a revised plan content that incorporates the resolutions and clarifications into the relevant sections.
   - Show a diff preview: `diff -u "$PLAN_FILE" <(echo "$revised_content")` or equivalent.
   - Ask for final confirmation: "Apply these changes?"
   - If confirmed:
     - Create a backup using `plan_check_backup_plan()`: `.humanize/plan-check/<timestamp>/backup/<plan>.bak`
     - Write atomically using `plan_check_atomic_write()` in the same directory as the plan file.
     - If `EFFECTIVE_RECHECK=true`, rerun the check pipeline from Phase 5 on the rewritten plan.
3. If the user declines, the plan file remains unchanged.

---

## Phase 11: Display Final Resolution Report

After the resolution report is written, print the final resolution report to the terminal as a contiguous block. This ensures terminal output and file report are consistent (AC-5).

Format:
```
=== Plan Check Resolution Report ===
Plan: <plan_path>
Final Status: <pass|fail>
Unresolved Blockers: <N>
Total Resolutions: <N>

<resolution details>
```

If unresolved blockers remain (unresolved contradictions or skipped ambiguities), state:
"The plan has unresolved blockers. Review the findings report and resolve all contradictions and ambiguities before implementation."

If all blockers are resolved, state:
"All blockers resolved. The plan is ready for implementation."

---

## Phase 12: Exit

Exit with code 0 if no unresolved blockers remain, or with code 1 if unresolved blockers exist.

---

## Deterministic-Only Fallback

If the sub-agent fails entirely (no usable output), fall back to deterministic-only validation:

1. Source `${CLAUDE_PLUGIN_ROOT}/scripts/lib/plan-check-common.sh`
2. Run `plan_check_validate_schema "$PLAN_FILE" "${CLAUDE_PLUGIN_ROOT}/prompt-template/plan/gen-plan-template.md"`
3. Collect findings, write report via `scripts/plan-check.sh`
4. Display results and exit with appropriate code

This ensures the command always produces a report even when semantic agents are unavailable.
