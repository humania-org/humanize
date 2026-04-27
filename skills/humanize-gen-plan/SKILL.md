---
name: humanize-gen-plan
description: Generate a structured implementation plan from a draft document. Validates input, checks relevance, analyzes for issues, and generates a complete plan.md with acceptance criteria.
type: flow
user-invocable: false
disable-model-invocation: true
---

# Humanize Generate Plan

Transforms a rough draft document into a well-structured implementation plan with clear goals, acceptance criteria (AC-X format), path boundaries, and feasibility suggestions.

The installer hydrates this skill with an absolute runtime root path:

```bash
{{HUMANIZE_RUNTIME_ROOT}}
```

```mermaid
flowchart TD
    BEGIN([BEGIN]) --> VALIDATE[Validate input/output paths and mode flags<br/>Run: {{HUMANIZE_RUNTIME_ROOT}}/scripts/validate-gen-plan-io.sh --input &lt;draft&gt; --output &lt;plan&gt; [--check|--no-check]]
    VALIDATE --> CHECK{Validation passed?}
    CHECK -->|No| REPORT_ERROR[Report validation error<br/>Stop]
    REPORT_ERROR --> END_FAIL([END])
    CHECK -->|Yes| READ_DRAFT[Read input draft file]
    READ_DRAFT --> CHECK_RELEVANCE{Is draft relevant to<br/>this repository?}
    CHECK_RELEVANCE -->|No| REPORT_IRRELEVANT[Report: Draft not related to repo<br/>Stop]
    REPORT_IRRELEVANT --> END_FAIL
    CHECK_RELEVANCE -->|Yes| ANALYZE[Analyze draft for:<br/>- Clarity<br/>- Consistency<br/>- Completeness<br/>- Functionality]
    ANALYZE --> HAS_ISSUES{Issues found?}
    HAS_ISSUES -->|Yes| RESOLVE[Engage user to resolve issues<br/>via AskUserQuestion]
    RESOLVE --> ANALYZE
    HAS_ISSUES -->|No| CHECK_METRICS{Has quantitative<br/>metrics?}
    CHECK_METRICS -->|Yes| CONFIRM_METRICS[Confirm metrics with user:<br/>Hard requirement or trend?]
    CONFIRM_METRICS --> GEN_PLAN
    CHECK_METRICS -->|No| GEN_PLAN[Generate structured plan:<br/>- Goal Description<br/>- Acceptance Criteria with TDD tests<br/>- Path Boundaries<br/>- Feasibility Hints<br/>- Dependencies & Milestones]
    GEN_PLAN --> WRITE[Write plan to output file<br/>using Edit tool to preserve draft]
    WRITE --> REVIEW[Review complete plan<br/>Check for inconsistencies]
    REVIEW --> INCONSISTENT{Inconsistencies?}
    INCONSISTENT -->|Yes| FIX[Fix inconsistencies]
    FIX --> REVIEW
    INCONSISTENT -->|No| CHECK_LANG{Multiple languages?}
    CHECK_LANG -->|Yes| UNIFY[Ask user to unify language]
    UNIFY --> REPORT_SUCCESS
    CHECK_LANG -->|No| REPORT_SUCCESS[Report success:<br/>- Plan path<br/>- AC count<br/>- Language unified?]
    REPORT_SUCCESS --> END_SUCCESS([END])
```

## Input Requirements

**Required Arguments:**
- `--input <path/to/draft.md>` - The draft document
- `--output <path/to/plan.md>` - Where to write the plan

**Optional Arguments:**
- `--check` - Enable integrated draft-check before plan generation and plan-check with targeted repair after plan generation.
- `--no-check` - Disable integrated check mode for this invocation, overriding `--check` and config.
- `--discussion` - Use iterative discussion mode.
- `--direct` - Use direct mode.
- `--auto-start-rlcr-if-converged` - Start RLCR automatically when discussion mode converges and check-mode gates pass.

Check mode can also be enabled by the merged `gen_plan_check` config key. Effective priority is `--no-check` > `--check` > `gen_plan_check` > default disabled.

## Plan Structure Output

The generated plan includes:

```markdown
# Plan Title

## Goal Description
Clear description of what needs to be accomplished

## Acceptance Criteria

- AC-1: First criterion
  - Positive Tests (expected to PASS):
    - Test case that should succeed
  - Negative Tests (expected to FAIL):
    - Test case that should fail

## Path Boundaries

### Upper Bound (Maximum Scope)
Most comprehensive acceptable implementation

### Lower Bound (Minimum Scope)  
Minimum viable implementation

### Allowed Choices
- Can use: allowed technologies
- Cannot use: prohibited technologies

## Dependencies and Sequence

### Milestones
1. Milestone 1: Description
   - Phase A: ...
   - Phase B: ...

## Implementation Notes
- Code should NOT contain plan terminology
```

## Validation Exit Codes

| Exit Code | Meaning |
|-----------|---------|
| 0 | Success - continue |
| 1 | Input file not found |
| 2 | Input file is empty |
| 3 | Output directory does not exist |
| 4 | Output file already exists |
| 5 | No write permission |
| 6 | Invalid arguments |
| 7 | Plan template file not found |

## Usage

```bash
# Start the flow
/flow:humanize-gen-plan --input .humanize/drafts/example.md --output .humanize/plans/example.md

# Start with integrated check mode
/flow:humanize-gen-plan --input .humanize/drafts/example.md --output .humanize/plans/example.md --check

# The flow will ask for:
# - Input draft file path
# - Output plan file path
```

Or with the skill only (no auto-execution):

```bash
/skill:humanize-gen-plan
```
