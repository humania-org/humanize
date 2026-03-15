---
name: humanize-refine-plan
description: Refine an annotated implementation plan into a comment-free plan and a QA ledger while preserving the gen-plan schema.
type: flow
user-invocable: false
---

# Humanize Refine Plan

Refines an annotated plan that contains `CMT:` / `ENDCMT` blocks into a comment-free plan plus a QA ledger, while preserving the `gen-plan` structure and convergence state.

The installer hydrates this skill with an absolute runtime root path:

```bash
{{HUMANIZE_RUNTIME_ROOT}}
```

```mermaid
flowchart TD
    BEGIN([BEGIN]) --> SETUP[Parse arguments and derive paths<br/>Resolve mode, output path, QA path, alt-language]
    SETUP --> LOAD_CFG[Load merged config<br/>Reuse humanize config precedence and defaults]
    LOAD_CFG --> VALIDATE[Validate IO<br/>Run: {{HUMANIZE_RUNTIME_ROOT}}/scripts/validate-refine-plan-io.sh --input &lt;annotated-plan&gt; [--output ...] [--qa-dir ...] [--discussion|--direct]]
    VALIDATE --> VALID_OK{Validation passed?}
    VALID_OK -->|No| REPORT_VALIDATION[Report validation error<br/>Stop]
    REPORT_VALIDATION --> END_FAIL([END])
    VALID_OK --> EXTRACT[Read input plan and extract valid<br/>CMT:/ENDCMT blocks with a stateful scanner]
    EXTRACT --> PARSE_OK{Parse succeeded?}
    PARSE_OK -->|No| REPORT_PARSE[Report parse error with<br/>line, column, heading, context<br/>Stop]
    REPORT_PARSE --> END_FAIL
    PARSE_OK --> CLASSIFY[Classify comments:<br/>question, change_request, research_request]
    CLASSIFY --> AMBIG{Ambiguous comments?}
    AMBIG -->|Yes, discussion mode| ASK_USER[Ask the minimum user question<br/>needed to continue]
    ASK_USER --> PROCESS
    AMBIG -->|No| PROCESS[Process comments in order:<br/>answer, refine plan, or do targeted repo research]
    PROCESS --> REFINE[Generate refined plan text<br/>Keep required gen-plan sections intact]
    REFINE --> PLAN_CHECK{Plan still valid?<br/>No CMT markers, references consistent,<br/>routing tags valid}
    PLAN_CHECK -->|No, fixable| FIX[Repair internal inconsistencies]
    FIX --> PLAN_CHECK
    PLAN_CHECK -->|No, blocking| REPORT_BLOCK[Report blocking inconsistency<br/>Stop]
    REPORT_BLOCK --> END_FAIL
    PLAN_CHECK -->|Yes| QA[Populate QA document from<br/>{{HUMANIZE_RUNTIME_ROOT}}/prompt-template/plan/refine-plan-qa-template.md]
    QA --> ALT_LANG{Generate translated variants?}
    ALT_LANG -->|Yes| VARIANTS[Translate refined plan and QA<br/>Keep identifiers unchanged]
    ALT_LANG -->|No| ATOMIC
    VARIANTS --> ATOMIC[Write refined plan, QA, and variants<br/>atomically via temp files]
    ATOMIC --> REPORT_SUCCESS[Report success:<br/>paths, counts, mode, convergence status]
    REPORT_SUCCESS --> END_SUCCESS([END])
```

## Input Requirements

**Required Arguments:**
- `--input <path/to/annotated-plan.md>` - Input plan that already follows the `gen-plan` schema and contains at least one `CMT:` / `ENDCMT` block

**Optional Arguments:**
- `--output <path/to/refined-plan.md>` - Output path for the refined plan; defaults to in-place mode (`--input`)
- `--qa-dir <path/to/qa-dir>` - Directory for the generated QA ledger; defaults to `.humanize/plan_qa`
- `--alt-language <language-or-code>` - Optional translated output language for plan and QA variants
- `--discussion` - Ask the user to resolve ambiguous classifications or language decisions
- `--direct` - Resolve ambiguity with the smallest safe assumption and record it in QA

**Argument Rules:**
- `--discussion` and `--direct` are mutually exclusive
- The validator does not accept `--alt-language`, so do not pass that flag to `validate-refine-plan-io.sh`
- If `--output` is omitted, refine the plan in place and still write the QA document separately

## Workflow Guarantees

The refinement flow must:

- Preserve the `gen-plan` schema instead of inventing new top-level sections
- Remove all resolved `CMT:` / `ENDCMT` blocks from the final plan
- Keep required sections intact:
  - `## Goal Description`
  - `## Acceptance Criteria`
  - `## Path Boundaries`
  - `## Feasibility Hints and Suggestions`
  - `## Dependencies and Sequence`
  - `## Task Breakdown`
  - `## Claude-Codex Deliberation`
  - `## Pending User Decisions`
  - `## Implementation Notes`
- Preserve optional sections when present, including the original design draft appendix
- Keep task routing tags restricted to `coding` or `analyze`
- Generate a QA ledger from the shipped QA template
- Write the refined plan, QA file, and any language variants atomically

## Classification And Output

Each extracted raw comment block receives one dominant classification:

- `question`
- `change_request`
- `research_request`

The flow produces:

- A refined plan with comment blocks removed and approved refinements applied
- A QA ledger that records:
  - one row per raw `CMT-N`
  - classification and disposition
  - answers to questions
  - research findings
  - applied plan changes
  - remaining decisions
  - refinement metadata and convergence status

## Supported Alternate Languages

`--alt-language` supports these normalized values:

| Language | Code | Variant Suffix |
|----------|------|----------------|
| Chinese | `zh` | `_zh` |
| Korean | `ko` | `_ko` |
| Japanese | `ja` | `_ja` |
| Spanish | `es` | `_es` |
| French | `fr` | `_fr` |
| German | `de` | `_de` |
| Portuguese | `pt` | `_pt` |
| Russian | `ru` | `_ru` |
| Arabic | `ar` | `_ar` |

Rules:

- Accept either the language name or ISO code
- Treat `English` / `en` as a no-op
- Keep identifiers unchanged in translated variants
- If the alternate language matches the main plan language, skip variant generation

## Validation Exit Codes

| Exit Code | Meaning |
|-----------|---------|
| 0 | Success - continue |
| 1 | Input file not found |
| 2 | Input file is empty |
| 3 | Input file has no `CMT:` blocks |
| 4 | Input file is missing required `gen-plan` sections |
| 5 | Output directory does not exist or is not writable |
| 6 | QA directory is not writable |
| 7 | Invalid arguments |

## Usage

```bash
# Start the flow
/flow:humanize-refine-plan

# The flow will ask for:
# - Input annotated plan path
# - Optional output refined plan path
# - Optional QA directory
# - Optional execution mode and alternate language
```

Or with the skill only (no auto-execution):

```bash
/skill:humanize-refine-plan
```
