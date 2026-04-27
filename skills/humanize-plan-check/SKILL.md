---
name: humanize-plan-check
description: Check a Humanize plan file for contradictions, ambiguities, and schema compliance, then write a structured report under .humanize/plan-check.
type: flow
argument-hint: "--plan <path/to/plan.md> [--recheck] [--alt-language lang]"
user-invocable: false
---

# Humanize Plan Check

Use this flow as the Codex entrypoint for checking an existing Humanize plan.
It mirrors the `/humanize:plan-check` Claude command, but it does not depend on
Claude slash-command directories, `Task`, or `AskUserQuestion`.

## Runtime Root

The installer hydrates this skill with an absolute runtime root path:

```bash
{{HUMANIZE_RUNTIME_ROOT}}
```

All commands below assume `{{HUMANIZE_RUNTIME_ROOT}}`.

## Usage

```bash
$humanize-plan-check --plan .humanize/plans/example.md
$humanize-plan-check --plan .humanize/plans/example.md --recheck
```

Options:
- `--plan <path>`: plan file to check. Required.
- `--recheck`: re-run plan-check after an accepted rewrite.
- `--alt-language <lang>`: accepted for parity with the Claude command.
- `-h`, `--help`: show usage and stop.

## Workflow

1. Parse `$ARGUMENTS`.
   - Require `--plan <path>`.
   - Treat `--recheck` as a positive override.
   - Preserve `--alt-language <lang>` when present.
2. Load config and shared helpers:
   ```bash
   source "{{HUMANIZE_RUNTIME_ROOT}}/scripts/lib/config-loader.sh"
   source "{{HUMANIZE_RUNTIME_ROOT}}/scripts/lib/plan-check-common.sh"
   PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
   MERGED_CONFIG_JSON="$(load_merged_config "{{HUMANIZE_RUNTIME_ROOT}}" "$PROJECT_ROOT")"
   ```
3. Resolve effective recheck:
   - If `--recheck` was supplied, set `EFFECTIVE_RECHECK=true`.
   - Otherwise set `EFFECTIVE_RECHECK="$(plan_check_resolve_recheck "$MERGED_CONFIG_JSON")"`.
4. Validate IO by running:
   ```bash
   VALIDATE_ARGS=(--plan "$PLAN_FILE")
   [[ "$EFFECTIVE_RECHECK" == "true" ]] && VALIDATE_ARGS+=(--recheck)
   [[ -n "$ALT_LANGUAGE" ]] && VALIDATE_ARGS+=(--alt-language "$ALT_LANGUAGE")
   "{{HUMANIZE_RUNTIME_ROOT}}/scripts/validate-plan-check-io.sh" \
     "${VALIDATE_ARGS[@]}"
   ```
   Stop on validation failure and report the script output.
5. Read the plan file. Keep the exact path for report metadata.
6. Create the timestamped report directory:
   - Parse `Report directory: ...` from validation output as `REPORT_BASE`.
   - Run `REPORT_DIR="$(plan_check_init_report_dir "$REPORT_BASE")"`.
7. Run deterministic schema checks:
   ```bash
   SCHEMA_TEMPLATE="$(plan_check_resolve_schema_template "{{HUMANIZE_RUNTIME_ROOT}}" || true)"
   SCHEMA_FINDINGS="$(plan_check_validate_schema "$PLAN_FILE" "$SCHEMA_TEMPLATE")"
   ```
   `## Task Breakdown` is optional; when present, task tags, Target ACs, and dependencies are still validated. Wrap non-empty `SCHEMA_FINDINGS` as a JSON array; otherwise use `[]`.
8. Run semantic checks directly in this Codex session.
   - Do not call the Claude `Task` tool.
   - Do not call nested `codex exec` unless the user explicitly asks.
   - Produce JSON-array findings matching the `findings.json` schema used by `plan-check.sh`.
   - Run two semantic passes:
     - contradiction pass using the intent of `{{HUMANIZE_RUNTIME_ROOT}}/agents/plan-consistency-checker.md`
     - ambiguity pass using the intent of `{{HUMANIZE_RUNTIME_ROOT}}/agents/plan-ambiguity-checker.md`
   - If a semantic pass cannot be completed, add one `runtime-error` info finding for that checker and continue.
9. Merge deterministic and semantic findings into one JSON array.
   - Sort blockers first, then warnings, then infos.
   - Pipe the merged array through `plan_check_postprocess_ambiguity_ids`.
   - Write it to `${REPORT_DIR}/findings_array.json`.
10. Generate the report:
    ```bash
    "{{HUMANIZE_RUNTIME_ROOT}}/scripts/plan-check.sh" \
      --plan "$PLAN_FILE" \
      --report-dir "$REPORT_DIR" \
      --findings-file "$REPORT_DIR/findings_array.json"
    ```
11. Print `${REPORT_DIR}/report.md` to the user and summarize:
    - report path
    - blockers, warnings, infos
    - whether unresolved blockers remain
12. If blocker findings exist, ask the user whether to resolve them now.
    - For contradictions, collect the chosen resolution.
    - For ambiguities, collect a concrete clarification.
    - Write `${REPORT_DIR}/resolution.json` using `plan_check_build_resolved_json`.
13. If the user wants an in-place rewrite:
    - Preview the intended diff first.
    - Ask for explicit confirmation before writing.
    - Run `plan_check_backup_plan "$PLAN_FILE" "$REPORT_DIR"`.
    - Run `plan_check_atomic_write "$PLAN_FILE" "$REWRITTEN_PLAN"`.
    - If `EFFECTIVE_RECHECK=true`, repeat the check workflow on the rewritten plan.

## Output Contract

Successful runs create:
- `.humanize/plan-check/<timestamp>/report.md`
- `.humanize/plan-check/<timestamp>/findings.json`
- `.humanize/plan-check/<timestamp>/findings_array.json`
- `.humanize/plan-check/<timestamp>/resolution.json` when user resolutions are collected
- `.humanize/plan-check/<timestamp>/backup/<plan>.bak` when an in-place rewrite is accepted

Exit-facing status:
- Pass when there are no unresolved blocker findings.
- Fail when blocker findings remain unresolved.
