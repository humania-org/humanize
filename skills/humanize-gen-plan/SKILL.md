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
    BEGIN([BEGIN]) --> VALIDATE[Validate input/output paths<br/>Run: {{HUMANIZE_RUNTIME_ROOT}}/scripts/validate-gen-plan-io.sh --input &lt;draft&gt; --output &lt;plan&gt;]
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
- `--coach` - Insert plan-time coaching checks so the user stays aligned with each planning stage before the agent expands the next layer

## Coach Mode

When `--coach` is enabled, pause after each completed planning stage for mandatory Coach Mode stage quizzes:
- Explain the current stage and the planning decision being made
- Keep normal plan decision questions separate from coach quizzes
- Ask short-answer or free-form quiz questions instead of multiple-choice checks
- Classify coaching questions as Memory, Self-check, or Education, in that order when multiple checks apply
- Interpret mismatches as design intent drift, AI design correction, or background gap instead of a generic wrong answer
- Ask one quiz question at a time, walking the plan's decision tree in dependency order
- Grade the user's answer against the agent's current plan state before continuing
- Re-explain or revise direction when the user is unsure or identifies a problem
- Reference earlier confirmed decisions only when later plan content depends on them
- Perform overall human acceptance before writing the final plan

The flow should not wait until the finished plan for review. It should test alignment after first-pass analysis, candidate-plan synthesis, convergence-round deltas, and final plan direction. Quiz questions should stay tied to the plan's goal, risks, approach, scope, acceptance criteria, dependencies, and task sequence. Coach mode includes real stage quizzes, not rapid Q&A or confirmation-only prompts.

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
/flow:humanize-gen-plan

# The flow will ask for:
# - Input draft file path
# - Output plan file path
```

Or with the skill only (no auto-execution):

```bash
/skill:humanize-gen-plan
```
