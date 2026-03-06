---
description: "Generate implementation plan from draft document"
argument-hint: "--input <path/to/draft.md> --output <path/to/plan.md> [--auto-start-rlcr-if-converged] [--discussion|--direct]"
allowed-tools:
  - "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/validate-gen-plan-io.sh:*)"
  - "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/ask-codex.sh:*)"
  - "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-rlcr-loop.sh:*)"
  - "Read"
  - "Glob"
  - "Grep"
  - "Task"
  - "Write"
  - "AskUserQuestion"
hide-from-slash-command-tool: "true"
---

# Generate Plan from Draft

Read and execute below with ultrathink.

## Hard Constraint: No Coding During Plan Generation

This command MUST ONLY generate a plan document during the planning phases. It MUST NOT implement tasks, modify repository source code, or make commits/PRs while producing the plan.

Permitted writes (before any optional auto-start) are limited to:
- The plan output file (`--output`)
- Optional `_zh` translated plan (only when `CHINESE_PLAN_ENABLED=true`)

If `--auto-start-rlcr-if-converged` is enabled, the command MAY immediately start the RLCR loop by running `/humanize:start-rlcr-loop <output-plan-path>`, but only in `discussion` mode when `PLAN_CONVERGENCE_STATUS=converged` and there are no pending user decisions. All coding happens in that subsequent command/loop, not during plan generation.

This command transforms a user's draft document into a well-structured implementation plan with clear goals, acceptance criteria (AC-X format), path boundaries, and feasibility suggestions.

## Workflow Overview

1. **Execution Mode Setup**: Parse optional behaviors from command arguments
2. **Load Project Config**: Read `.humanize/config.json` and extract `chinese_plan` flag
3. **IO Validation**: Validate input and output paths
4. **Relevance Check**: Verify draft is relevant to the repository
5. **Codex First-Pass Analysis**: Use one planning Codex before Claude synthesizes plan details
6. **Claude Candidate Plan (v1)**: Claude builds an initial plan from draft + Codex findings
7. **Iterative Convergence Loop**: Claude and a second Codex iteratively challenge/refine plan reasonability
8. **Issue and Disagreement Resolution**: Resolve unresolved opposite opinions (or skip manual review if converged, auto-start mode is enabled, and `GEN_PLAN_MODE=discussion`)
9. **Final Plan Generation**: Generate the converged structured plan.md with task routing tags
10. **Write and Complete**: Write output file, optionally write `_zh` Chinese variant, optionally auto-start implementation, and report results

---

## Phase 0: Execution Mode Setup

Parse `$ARGUMENTS` and set:
- `AUTO_START_RLCR_IF_CONVERGED=true` if `--auto-start-rlcr-if-converged` is present
- `AUTO_START_RLCR_IF_CONVERGED=false` otherwise
- `GEN_PLAN_MODE_DISCUSSION=true` if `--discussion` is present
- `GEN_PLAN_MODE_DIRECT=true` if `--direct` is present
- If both `--discussion` and `--direct` are present simultaneously, report error "Cannot use --discussion and --direct together" and stop

`AUTO_START_RLCR_IF_CONVERGED=true` allows skipping manual plan review and starting implementation immediately (by invoking `/humanize:start-rlcr-loop <output-plan-path>`), but only when `GEN_PLAN_MODE=discussion`, plan convergence is achieved, and no pending user decisions remain. In `direct` mode this condition is never satisfied.

---

## Phase 0.5: Load Project Config

After setting execution mode flags, load the project-level configuration:

1. Attempt to read `.humanize/config.json` from the project root (the repository root where the command was invoked).
2. If the file does not exist, treat all config fields as absent. This is NOT an error; continue normally.
3. If the file exists, parse it as JSON and extract the `chinese_plan` field:
   - If `chinese_plan` is `true` (boolean), set `CHINESE_PLAN_ENABLED=true`.
   - Otherwise (field absent, `false`, or any non-true value), set `CHINESE_PLAN_ENABLED=false`.
4. Also extract the `gen_plan_mode` field from the same config:
   - Valid values: `"discussion"` or `"direct"` (case-insensitive).
   - Invalid or absent values: treat as absent (fall back to default) and log a warning if the value is present but invalid.
5. Resolve `GEN_PLAN_MODE` using the following priority (highest to lowest), with CLI flags taking priority over project config:
   - CLI flag: if `GEN_PLAN_MODE_DISCUSSION=true`, set `GEN_PLAN_MODE=discussion`; if `GEN_PLAN_MODE_DIRECT=true`, set `GEN_PLAN_MODE=direct`
   - Config file `gen_plan_mode` field (if valid)
   - Default: `discussion`
6. A malformed JSON file should be reported as a warning but must NOT stop execution; fall back to `CHINESE_PLAN_ENABLED=false` and `GEN_PLAN_MODE=discussion`.

`CHINESE_PLAN_ENABLED` controls whether a `_zh` Chinese variant of the output file is written in Phase 8.

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
- Exit code 7: Report "Plan template file not found - plugin configuration error" and stop

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

## Phase 3: Codex First-Pass Analysis

After relevance check, invoke Codex BEFORE Claude plan synthesis.

This Codex pass is the first planning analysis before Claude synthesizes plan details.

1. Run:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/ask-codex.sh" "<structured prompt>"
   ```
2. The structured prompt MUST include:
   - Repository context (project purpose, relevant files)
   - Raw draft content
   - Explicit request to critique assumptions, identify missing requirements, and propose stronger plan directions
3. Require Codex output to follow this format:
   - `CORE_RISKS:` highest-risk assumptions and potential failure modes
   - `MISSING_REQUIREMENTS:` likely omitted requirements or edge cases
   - `TECHNICAL_GAPS:` feasibility or architecture gaps
   - `ALTERNATIVE_DIRECTIONS:` viable alternatives with tradeoffs
   - `QUESTIONS_FOR_USER:` questions that need explicit human decisions
   - `CANDIDATE_CRITERIA:` candidate acceptance criteria suggestions
4. Preserve this output as **Codex Analysis v1** and feed it into Claude planning.
5. Record a concise planning summary from this analysis.

### Codex Availability Handling

If `ask-codex.sh` fails (missing Codex CLI, timeout, or runtime error), use AskUserQuestion and let the user choose:
- Retry with updated Codex settings/environment
- Continue with Claude-only planning (explicitly note reduced cross-review confidence in plan output)

---

## Phase 4: Claude Candidate Plan (v1)

Use draft content + Codex Analysis v1 to produce an initial candidate plan and issue map.

Deeply analyze the draft for potential issues. Use Explore agents to investigate the codebase.

Alongside candidate plan v1, prepare a concise implementation summary covering scope, boundaries, dependencies, and known risks.

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

## Phase 5: Iterative Convergence Loop (Claude <-> Second Codex)

If `GEN_PLAN_MODE=direct`, skip this entire phase. The plan proceeds directly from candidate plan v1 (Phase 4) to Phase 6 without convergence rounds. Since no convergence rounds or second-pass review occurred, set `PLAN_CONVERGENCE_STATUS=partially_converged` and `HUMAN_REVIEW_REQUIRED=true` (direct mode must NOT satisfy `--auto-start-rlcr-if-converged` conditions).

After Claude candidate plan v1 is ready, run iterative challenge/refine rounds with a SECOND Codex pass.

### Convergence Round Steps

1. **Second Codex Reasonability Review**
   - Run:
     ```bash
     "${CLAUDE_PLUGIN_ROOT}/scripts/ask-codex.sh" "<review current candidate plan>"
     ```
   - Prompt MUST include current candidate plan, prior disagreements, and unresolved items
   - Require output format:
     - `AGREE:` points accepted as reasonable
     - `DISAGREE:` points considered unreasonable and why
     - `REQUIRED_CHANGES:` must-fix items before convergence
     - `OPTIONAL_IMPROVEMENTS:` non-blocking improvements
     - `UNRESOLVED:` opposite opinions needing user decisions
2. **Claude Revision**
   - Claude updates the candidate plan to address `REQUIRED_CHANGES`
   - Claude documents accepted/rejected suggestions with rationale
3. **Convergence Assessment**
   - Update a per-round convergence matrix:
     - Topic
     - Claude position
     - Second Codex position
     - Resolution status (`resolved`, `needs_user_decision`, `deferred`)
     - Round-to-round delta

### Loop Termination Rules

Repeat convergence rounds until one of the following is true:
- No `REQUIRED_CHANGES` remain and no high-impact `DISAGREE` remains
- Two consecutive rounds produce no material plan changes
- Maximum 3 rounds reached

If max rounds are reached with unresolved opposite opinions, carry them to user decision phase explicitly.

Set convergence state explicitly:
- `PLAN_CONVERGENCE_STATUS=converged` when convergence conditions are met
- `PLAN_CONVERGENCE_STATUS=partially_converged` otherwise

---

## Phase 6: Issue and Disagreement Resolution

> **Critical**: The draft document contains the most valuable human input. During issue resolution, NEVER discard or override any original draft content. All clarifications should be treated as incremental additions that supplement the draft, not replacements. Keep track of both the original draft statements and the clarified information.

### Step 1: Manual Review Gate

Decide if manual review can be skipped:
- If `GEN_PLAN_MODE=direct`, set `HUMAN_REVIEW_REQUIRED=true`
- Else if `AUTO_START_RLCR_IF_CONVERGED=true` **and** `PLAN_CONVERGENCE_STATUS=converged`, set `HUMAN_REVIEW_REQUIRED=false`
- Otherwise set `HUMAN_REVIEW_REQUIRED=true`

If `HUMAN_REVIEW_REQUIRED=false`, skip Step 2-4 and continue directly to Phase 7.

### Step 2: Resolve Analysis Issues (when manual review is required)

If any issues are found during Codex-first analysis, Claude analysis, or convergence loop, use AskUserQuestion to clarify with the user.

For each issue category that has problems, present:
- What the issue is
- Why it matters
- Options for resolution (if applicable)

Continue this dialogue until all significant issues are resolved or acknowledged by the user.

### Step 3: Confirm Quantitative Metrics (when manual review is required)

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

### Step 4: Resolve Unresolved Claude/Codex Disagreements (when manual review is required)

For every item marked `needs_user_decision`, explicitly ask the user to decide.

For each unresolved disagreement, present:
- The decision topic
- Claude's position
- Codex's position
- Tradeoffs and risks of each option
- A clear recommendation (if one option is materially safer)

If the user does not decide immediately, keep the item in the plan as `PENDING` under a dedicated user-decision section.

---

## Phase 7: Final Plan Generation

Deeply think and generate the plan.md following these rules:

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

## Task Breakdown

Each task must include exactly one routing tag:
- `coding`: implemented by Claude
- `analyze`: executed via Codex (`/humanize:ask-codex`)

| Task ID | Description | Target AC | Tag (`coding`/`analyze`) | Depends On |
|---------|-------------|-----------|----------------------------|------------|
| task1 | <...> | AC-1 | coding | - |
| task2 | <...> | AC-2 | analyze | task1 |

## Claude-Codex Deliberation

### Agreements
- <Point both sides agree on>

### Resolved Disagreements
- <Topic>: Claude vs Codex summary, chosen resolution, and rationale

### Convergence Status
- Final Status: `converged` or `partially_converged`

## Pending User Decisions

- DEC-1: <Decision topic>
  - Claude Position: <...>
  - Codex Position: <...>
  - Tradeoff Summary: <...>
  - Decision Status: `PENDING` or `<User's final decision>`

## Implementation Notes

### Code Style Requirements
- Implementation code and comments must NOT contain plan-specific terminology such as "AC-", "Milestone", "Step", "Phase", or similar workflow markers
- These terms are for plan documentation only, not for the resulting codebase
- Use descriptive, domain-appropriate naming in code instead

## Output File Convention

This template is used to produce the main output file (e.g., `plan.md`).

### Chinese Variant (`_zh` file)

When `chinese_plan=true` is set in `.humanize/config.json`, a `_zh` variant of the output file is also written after the main file. The `_zh` filename is constructed by inserting `_zh` immediately before the file extension:

- `plan.md` becomes `plan_zh.md`
- `docs/my-plan.md` becomes `docs/my-plan_zh.md`
- `output` (no extension) becomes `output_zh`

The `_zh` file contains a full Chinese translation of the English plan. All identifiers (`AC-*`, task IDs, file paths, API names, command flags) remain unchanged, as they are language-neutral.

When `chinese_plan=false` (the default), or when `.humanize/config.json` does not exist, or when the `chinese_plan` field is absent, the `_zh` file is NOT written. A missing config file is not an error.
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

10. **Code Style Constraint**: The generated plan MUST include a section or note instructing that implementation code and comments should NOT contain plan-specific progress terminology such as "AC-", "Milestone", "Step", "Phase", or similar workflow markers. These terms belong in the plan document, not in the resulting codebase.

11. **Draft Completeness Requirement**: The generated plan MUST incorporate ALL information from the input draft document without omission. The draft represents the most valuable human input and must be fully preserved. Any clarifications obtained through Phase 6 should be added incrementally to the draft's original content, never replacing or losing any original requirements. The final plan must be a superset of the draft information plus all clarified details.

12. **Debate Traceability**: The plan MUST include Codex-first findings, Claude/Codex agreements, resolved disagreements, and unresolved decisions. Unresolved opposite opinions MUST be recorded in `## Pending User Decisions` for explicit user decision.

13. **Convergence Requirement**: The plan MUST record Claude/Codex agreements, resolved disagreements, and final convergence status in `## Claude-Codex Deliberation`. Stop only when convergence conditions are met or max rounds reached with explicit carry-over decisions.

14. **Task Tag Requirement**: The plan MUST include `## Task Breakdown`, and every task MUST be tagged as either `coding` or `analyze` (no untagged tasks, no other tag values).

---

## Phase 8: Write and Complete

The output file already contains the plan template structure and the original draft content (combined during IO validation). Now complete the plan through the following steps:

### Step 1: Update Plan Content

Use the **Edit tool** (not Write) to update the plan file with the generated content:
- Replace template placeholders with actual plan content
- Keep the original draft section intact at the bottom of the file
- The final file should contain both the structured plan AND the original draft for reference

### Step 2: Comprehensive Review

After updating, **read the complete plan file** and verify:
- The plan is complete and comprehensive
- All sections are consistent with each other
- The structured plan aligns with the original draft content
- Claude/Codex disagreement handling is explicit and correctly reflected
- No contradictions exist between different parts of the document

If inconsistencies are found, fix them using the Edit tool.

### Step 3: Language Unification

Check if the updated plan file contains multiple languages (e.g., mixed English and Chinese content).

If multiple languages are detected:
1. Use **AskUserQuestion** to ask the user:
   - Whether they want to unify the language
   - Which language to use for unification
2. If the user chooses to unify:
   - Translate all content to the chosen language
   - Ensure the meaning and intent remain unchanged
   - Use the Edit tool to apply the translations
3. If the user declines, leave the document as-is

### Step 4: Write Chinese Variant (Conditional)

If `CHINESE_PLAN_ENABLED=true`, write a `_zh` variant of the output file containing a full Chinese translation of the English plan:

**Filename construction rule** - insert `_zh` immediately before the file extension:
- `plan.md` becomes `plan_zh.md`
- `docs/my-plan.md` becomes `docs/my-plan_zh.md`
- `output` (no extension) becomes `output_zh`

Algorithm:
1. Find the last `.` in the base filename.
2. If a `.` is found, insert `_zh` before it: `<stem>_zh.<extension>`.
3. If no `.` is found (no extension), append `_zh` to the filename: `<filename>_zh`.
4. The `_zh` file is placed in the same directory as the main output file.

**Content of the `_zh` file**:
- Translate the English plan content into Simplified Chinese.
- Section headings, AC labels, task IDs, file paths, API names, and command flags MUST remain unchanged (identifiers are language-neutral).
- The `_zh` file is a Chinese reading view of the same plan; it must not add new information not present in the main file.
- The original draft section at the bottom should be kept as-is (not re-translated).

If `CHINESE_PLAN_ENABLED=false` (the default), do NOT create the `_zh` file. The absence of `.humanize/config.json` or the absence of the `chinese_plan` field both imply `CHINESE_PLAN_ENABLED=false`; no error is raised.

### Step 5: Optional Direct Work Start

If all of the following are true:
- `AUTO_START_RLCR_IF_CONVERGED=true`
- `PLAN_CONVERGENCE_STATUS=converged`
- `GEN_PLAN_MODE=discussion`
- There are no pending decisions with status `PENDING`

Then start work immediately by running:

```bash
/humanize:start-rlcr-loop <output-plan-path>
```

If the command invocation is not available in this context, fall back to the setup script:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-rlcr-loop.sh" --plan-file <output-plan-path>
```

If the auto-start attempt fails, report the failure reason and provide the exact manual command for the user to run:

```bash
/humanize:start-rlcr-loop <output-plan-path>
```

### Step 6: Report Results

Report to the user:
- Path to the generated plan
- Summary of what was included
- Number of acceptance criteria defined
- Number of convergence rounds executed
- Number of unresolved user decisions (if any)
- Whether language was unified (if applicable)
- Whether direct work start was attempted, and its result

---

## Error Handling

If issues arise during plan generation that require user input:
- Use AskUserQuestion to clarify
- Document any user decisions in the plan's context

If auto-start mode is enabled but convergence conditions are not met:
- Explain why direct start was skipped
- Tell the user to either resolve pending decisions or run `/humanize:start-rlcr-loop <plan.md>` manually

If unable to generate a complete plan:
- Explain what information is missing
- Suggest how the user can improve their draft
