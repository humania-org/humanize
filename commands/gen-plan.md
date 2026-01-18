---
description: "Generate implementation plan from draft document"
argument-hint: "--input <path/to/draft.md> --output <path/to/plan.md>"
allowed-tools:
  - "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/validate-gen-plan-io.sh:*)"
  - "Read"
  - "Glob"
  - "Grep"
  - "Task"
  - "Write"
  - "AskUserQuestion"
hide-from-slash-command-tool: "true"
---

# Generate Plan from Draft

This command transforms a user's draft document into a well-structured implementation plan with clear goals, acceptance criteria (AC-X format), path boundaries, and feasibility suggestions.

## Workflow Overview

1. **IO Validation**: Validate input and output paths
2. **Relevance Check**: Verify draft is relevant to the repository
3. **Draft Analysis**: Analyze draft for clarity, consistency, completeness, and functionality
4. **Issue Resolution**: Engage user to clarify any issues found
5. **Plan Generation**: Generate the structured plan.md
6. **Write and Complete**: Write output file and report results

---

## Phase 1: IO Validation

Execute the validation script with the provided arguments:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/validate-gen-plan-io.sh" $ARGUMENTS
```

**Handle exit codes:**
- Exit code 0: Continue to Phase 2
- Exit code 1: Report "Input file not found" and stop
- Exit code 2: Report "Input file is empty" and stop
- Exit code 3: Report "Output directory does not exist - please create it" and stop
- Exit code 4: Report "Output file already exists - please choose another path" and stop
- Exit code 5: Report "No write permission to output directory" and stop
- Exit code 6: Report "Invalid arguments" and show usage, then stop

---

## Phase 2: Relevance Check

After IO validation passes, check if the draft is relevant to this repository.

> **Note**: Do not spend too much time on this check. As long as the draft is not completely unrelated to the current project - not like the difference between ship design and cake recipes - it passes.

1. Read the input draft file to get its content
2. Use the Task tool to invoke the `humanize:draft-relevance-checker` agent (haiku model):
   ```
   Task tool parameters:
   - model: "haiku"
   - prompt: Include the draft content and ask the agent to:
     1. Explore the repository structure (README, CLAUDE.md, main files)
     2. Analyze if the draft content relates to this repository
     3. Return either `RELEVANT: <reason>` or `NOT_RELEVANT: <reason>`
   ```

3. **If NOT_RELEVANT**:
   - Report: "The draft content does not appear to be related to this repository."
   - Show the reason from the relevance check
   - Stop the command

4. **If RELEVANT**: Continue to Phase 3

---

## Phase 3: Draft Analysis

Deeply analyze the draft for potential issues. Use Explore agents to investigate the codebase.

### Analysis Dimensions

1. **Clarity**: Is the draft's intent and goals clearly expressed?
   - Are objectives well-defined?
   - Is the scope clear?
   - Are terms and concepts unambiguous?

2. **Consistency**: Does the draft contradict itself?
   - Are requirements internally consistent?
   - Do different sections align with each other?

3. **Completeness**: Are there missing considerations?
   - Use Explore agents to investigate parts of the codebase the draft might affect
   - Identify dependencies, side effects, or related components not mentioned
   - Check if the draft overlooks important edge cases

4. **Functionality**: Does the design have fundamental flaws?
   - Would the proposed approach actually work?
   - Are there technical limitations not addressed?
   - Could the design negatively impact existing functionality?

### Exploration Strategy

Use the Task tool with `subagent_type: "Explore"` to investigate:
- Components mentioned in the draft
- Related files and directories
- Existing patterns and conventions
- Dependencies and integrations

---

## Phase 4: Issue Resolution

### Step 1: Resolve Analysis Issues

If any issues are found during analysis, use AskUserQuestion to clarify with the user.

For each issue category that has problems, present:
- What the issue is
- Why it matters
- Options for resolution (if applicable)

Continue this dialogue until all significant issues are resolved or acknowledged by the user.

### Step 2: Confirm Quantitative Metrics

After all analysis issues are resolved, check the draft for any quantitative metrics or numeric thresholds, such as:
- Performance targets: "less than 15GB/s", "under 100ms latency"
- Size constraints: "below 300KB", "maximum 1MB"
- Count limits: "more than 10 files", "at least 5 retries"
- Percentage goals: "95% coverage", "reduce by 50%"

For each quantitative metric found, use AskUserQuestion to explicitly confirm with the user:
- Is this a **hard requirement** that must be achieved for the implementation to be considered successful?
- Or is this describing an **optimization trend/direction** where improvement toward the target is acceptable even if the exact number is not reached?

Document the user's answer for each metric, as this distinction significantly affects how acceptance criteria should be written in the plan.

---

## Phase 5: Plan Generation

Generate the plan.md following these rules:

### Plan Structure

```markdown
# <Plan Title>

## Goal Description
<Clear, direct description of what needs to be accomplished>

## Acceptance Criteria

Following TDD philosophy, each criterion includes positive and negative tests for deterministic verification.

- AC-1: <First criterion>
  - Positive Tests (expected to PASS):
    - <Test case that should succeed when criterion is met>
    - <Another success case>
  - Negative Tests (expected to FAIL):
    - <Test case that should fail/be rejected when working correctly>
    - <Another failure/rejection case>
  - AC-1.1: <Sub-criterion if needed>
    - Positive: <...>
    - Negative: <...>
- AC-2: <Second criterion>
  - Positive Tests: <...>
  - Negative Tests: <...>
...

## Path Boundaries

Path boundaries define the acceptable range of implementation quality and choices.

### Upper Bound (Maximum Acceptable Scope)
<Affirmative description of the most comprehensive acceptable implementation>
<This represents completing the goal without over-engineering>
Example: "The implementation includes X, Y, and Z features with full test coverage"

### Lower Bound (Minimum Acceptable Scope)
<Affirmative description of the minimum viable implementation>
<This represents the least effort that still satisfies all acceptance criteria>
Example: "The implementation includes core feature X with basic validation"

### Allowed Choices
<Options that are acceptable for implementation decisions>
- Can use: <technologies, approaches, patterns that are allowed>
- Cannot use: <technologies, approaches, patterns that are prohibited>

> **Note on Deterministic Designs**: If the draft specifies a highly deterministic design with no choices (e.g., "must use JSON format", "must use algorithm X"), then the path boundaries should reflect this narrow constraint. In such cases, upper and lower bounds may converge to the same point, and "Allowed Choices" should explicitly state that the choice is fixed per the draft specification.

## Feasibility Hints and Suggestions

> **Note**: This section is for reference and understanding only. These are conceptual suggestions, not prescriptive requirements.

### Conceptual Approach
<Text description, pseudocode, or diagrams showing ONE possible implementation path>

### Relevant References
<Code paths and concepts that might be useful>
- <path/to/relevant/component> - <brief description>

## Dependencies and Sequence

### Milestones
1. <Milestone 1>: <Description>
   - Phase A: <...>
   - Phase B: <...>
2. <Milestone 2>: <Description>
   - Step 1: <...>
   - Step 2: <...>

<Describe relative dependencies between components, not time estimates>
```

### Generation Rules

1. **Terminology**: Use Milestone, Phase, Step, Section. Never use Day, Week, Month, Year, or time estimates.

2. **No Line Numbers**: Reference code by path only (e.g., `src/utils/helpers.ts`), never by line ranges.

3. **No Time Estimates**: Do not estimate duration, effort, or code line counts.

4. **Conceptual Not Prescriptive**: Path boundaries and suggestions guide without mandating.

5. **AC Format**: All acceptance criteria must use AC-X or AC-X.Y format.

6. **Clear Dependencies**: Show what depends on what, not when things happen.

7. **TDD-Style Tests**: Each acceptance criterion MUST include both positive tests (expected to pass) and negative tests (expected to fail). This follows Test-Driven Development philosophy and enables deterministic verification.

8. **Affirmative Path Boundaries**: Describe upper and lower bounds using affirmative language (what IS acceptable) rather than negative language (what is NOT acceptable).

9. **Respect Deterministic Designs**: If the draft specifies a fixed approach with no choices, reflect this in the plan by narrowing the path boundaries to match the user's specification.

---

## Phase 6: Write and Complete

Write the generated plan to the output file path, then report:
- Path to the generated plan
- Summary of what was included
- Number of acceptance criteria defined

---

## Error Handling

If issues arise during plan generation that require user input:
- Use AskUserQuestion to clarify
- Document any user decisions in the plan's context

If unable to generate a complete plan:
- Explain what information is missing
- Suggest how the user can improve their draft
