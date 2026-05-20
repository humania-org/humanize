---
description: "Generate implementation plan from draft document"
argument-hint: "--input <path/to/draft.md> --output <path/to/plan.md> [--auto-start-rlcr-if-converged] [--discussion|--direct] [--coach]"
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
---

# Generate Plan from Draft

Read and execute below with ultrathink.

## Hard Constraint: No Coding During Plan Generation

This command MUST ONLY generate a plan document during the planning phases. It MUST NOT implement tasks, modify repository source code, or make commits/PRs while producing the plan.

Permitted writes (before any optional auto-start) are limited to:
- The plan output file (`--output`)
- Optional translated language variant (only when `ALT_PLAN_LANGUAGE` is configured)

If `--auto-start-rlcr-if-converged` is enabled, the command MAY immediately start the RLCR loop by running `/humanize:start-rlcr-loop <output-plan-path>`, but only in `discussion` mode when `PLAN_CONVERGENCE_STATUS=converged` and there are no pending user decisions. All coding happens in that subsequent command/loop, not during plan generation.

This command transforms a user's draft document into a well-structured implementation plan with clear goals, acceptance criteria (AC-X format), path boundaries, and feasibility suggestions.

## Workflow Overview

> **Sequential Execution Constraint**: All phases below MUST execute strictly in order. Do NOT parallelize tool calls across different phases. Each phase must fully complete before the next one begins.

1. **Execution Mode Setup**: Parse optional behaviors from command arguments, including coach mode
2. **Load Project Config**: Resolve merged Humanize config defaults for `alternative_plan_language` and `gen_plan_mode`
3. **IO Validation**: Validate input and output paths
4. **Relevance Check**: Verify draft is relevant to the repository
5. **Codex First-Pass Analysis**: Use one planning Codex before Claude synthesizes plan details
6. **Claude Candidate Plan (v1)**: Claude builds an initial plan from draft + Codex findings
7. **Iterative Convergence Loop**: Claude and a second Codex iteratively challenge/refine plan reasonability
8. **Issue and Disagreement Resolution**: Resolve unresolved opposite opinions (or skip manual review if converged, auto-start mode is enabled, and `GEN_PLAN_MODE=discussion`)
9. **Final Plan Generation**: Generate the converged structured plan.md with task routing tags
10. **Write and Complete**: Write output file, optionally write translated language variant, optionally auto-start implementation, and report results

When `--coach` is enabled, run mandatory stage quizzes after each completed planning stage. Normal human decision questions still happen when the plan needs a user choice, but those decision questions do not count as coach quizzes. Coach quizzes are inserted during plan generation, not deferred to a final review, and test whether the human's understanding is aligned with the agent's current plan.

---

## Phase 0: Execution Mode Setup

Parse `$ARGUMENTS` and set:
- `AUTO_START_RLCR_IF_CONVERGED=true` if `--auto-start-rlcr-if-converged` is present
- `AUTO_START_RLCR_IF_CONVERGED=false` otherwise
- `GEN_PLAN_MODE_DISCUSSION=true` if `--discussion` is present
- `GEN_PLAN_MODE_DIRECT=true` if `--direct` is present
- `COACH_MODE=true` if `--coach` is present
- `COACH_MODE=false` otherwise
- If both `--discussion` and `--direct` are present simultaneously, report error "Cannot use --discussion and --direct together" and stop

`AUTO_START_RLCR_IF_CONVERGED=true` allows skipping manual plan review and starting implementation immediately (by invoking `/humanize:start-rlcr-loop <output-plan-path>`), but only when `GEN_PLAN_MODE=discussion`, plan convergence is achieved, and no pending user decisions remain. In `direct` mode this condition is never satisfied.

Initialize coach-mode state:
- `COACH_CHECK_STATUS=not_enabled` when `COACH_MODE=false`
- `COACH_CHECK_STATUS=pending` when `COACH_MODE=true`
- `COACH_CHECK_COUNT=0`
- `COACH_CHECK_SUMMARY=""`
- `COACH_MAINLINE_LEDGER=[]`

### Coach Mode Protocol

When `COACH_MODE=true`, insert a mandatory stage quiz after each completed planning stage and before expanding from one planning layer to the next. Each quiz gate MUST use AskUserQuestion and MUST include:

1. **Stage explanation**: 3-5 concise bullets explaining what was completed, what plan state now exists, and why it matters.
2. **Decision separation**: ask normal plan decision questions separately from coach quizzes. Decision questions resolve product/design choices and may use options; they do not satisfy the stage quiz requirement.
3. **Stage quiz**: ask at least one short-answer or free-form quiz question that the human must answer in their own words. Do not use multiple-choice, yes/no, or "continue" confirmation as the quiz, unless the interface has no free-form input path; if forced to use choices, ask the human to type the reasoning before continuing.
4. **Coach question ladder**: choose quiz questions only from these categories, in this order when more than one category applies:
   - **Memory**: ask the user to restate or identify a design decision from their own draft or prior clarification. This checks whether the user remembers what they already designed; do not challenge correctness in this category.
   - **Self-check**: ask the user to inspect the candidate plan/design and confirm whether it matches their intent, constraints, risks, and acceptance criteria. This checks whether the design direction is correct or needs revision.
   - **Education**: explain background knowledge, repository context, or technical tradeoffs that may be obvious to the agent but not to the user, then ask whether the explanation is understood before relying on it.
5. **Grading and remediation**: grade the answer against the stage's current plan state, explain any mismatch, and remediate according to the category-specific standards below.
6. **Confirmation**: continue only after the quiz answer is aligned, or after remediation/revision resolves the mismatch.

Do NOT continue to the next planning layer until the stage quiz has been answered and graded. If the user asks a follow-up question, answer it directly, inspect the repository when codebase facts matter, update the explanation if needed, and then ask a new stage quiz on the same mainline point. If the user challenges the direction, update the candidate plan state, rerun the relevant analysis, and repeat the quiz gate for the revised stage.

If confirmation cannot be obtained, set `COACH_CHECK_STATUS=blocked`, write the unresolved decision or comprehension blocker into `## Pending User Decisions`, report the blocker, and stop instead of producing a deeper plan.

### Coach Answer Interpretation Standards

Incorrect, surprising, or non-confirming answers are first-class gen-plan quality signals. Interpret them by category:

- **Memory mismatch**: treat this as possible design intent drift, not as a simple recall failure. Pause expansion, ask whether the original draft decision has changed or should remain authoritative, update the candidate plan source of truth or `## Pending User Decisions`, and rerun the affected analysis before proceeding.
- **Self-check rejection**: treat this as evidence that the AI candidate plan/design is wrong, incomplete, or misaligned with the user's intent. Revise the candidate plan, record the correction, and rerun the relevant analysis or convergence step before asking for confirmation again.
- **Education gap**: treat this as a prerequisite background/context gap. Provide a concise explanation tied to the repository or technical tradeoff, ask for explicit confirmation, and do not rely on that concept in deeper plan content until it is understood. If the gap remains unresolved, set `COACH_CHECK_STATUS=blocked`, record it as a blocker, and do not auto-start implementation.

The plan is not coach-confirmed until each triggered category has been handled according to its standard. Do not collapse these signals into a generic wrong answer.

### Coach Questioning Style

- Ask one quiz question at a time.
- Use the Memory -> Self-check -> Education order when a checkpoint needs multiple quiz questions. Skip categories that do not apply; never invent busywork to fill all three.
- Walk the plan's decision tree in dependency order. Resolve prerequisite understanding before downstream implementation details.
- Provide the expected answer and concise rationale only after the user answers or asks for help, so the exchange remains a real quiz rather than a disguised explanation.
- If a question can be answered by inspecting the repository, inspect the repository instead of asking the user. Ask the human only about comprehension, judgment, priority, or unresolved tradeoffs.
- Do not use rapid Q&A. Do not substitute multiple-choice, yes/no, or "continue" prompts for the mandatory stage quiz. Avoid trivia; every quiz must test alignment with the current plan's goal, risks, approach, scope, acceptance criteria, dependencies, or task sequence.

### Coach Ledger

Maintain `COACH_MAINLINE_LEDGER` as the plan develops. Each entry should capture a mainline topic, the checkpoint where it was introduced, its question category (`Memory`, `Self-check`, or `Education`), its outcome (`confirmed`, `design_intent_drift`, `ai_design_correction`, `background_gap`, or `blocked`), its dependencies, the user's decision or confirmation, and whether it is confirmed or blocked.

During later checkpoints, reference earlier ledger entries only when current plan content depends on them, and connect those prior decisions to the current mainline logic. Do not add unrelated historical checks just to increase difficulty.

### Overall Human Acceptance

Checkpoint D MUST perform overall human acceptance for the full plan logic before Phase 7 writes the final plan:

- Summarize the plan's mainline from goal to implementation sequence.
- Summarize what the user has already confirmed and any topics that required explanation or revision.
- Ask whether the user understands and accepts the overall plan direction, not merely whether the last checkpoint is complete.
- If the user asks follow-up questions during this acceptance, answer them and repeat the acceptance confirmation before proceeding.

Run these checkpoints:

- **Checkpoint A - First-pass analysis**: After Phase 3 and before Phase 4, explain Codex Analysis v1, then quiz the user on the highest-risk assumption and whether any `QUESTIONS_FOR_USER` item blocks candidate planning.
- **Checkpoint B - Candidate plan**: After Phase 4 and before Phase 5 (or before Phase 6 in direct mode), explain the proposed scope, path boundaries, dependencies, and risks, then quiz the user on the main implementation mechanism or affected components.
- **Checkpoint C - Convergence rounds**: After each Phase 5 convergence round and before running another round or declaring convergence, explain material changes, resolved disagreements, and remaining disagreements, then quiz the user on the delta and whether any item should be reopened.
- **Checkpoint D - Finalization gate**: After Phase 6 and before Phase 7, summarize the final plan direction, unresolved decisions, and acceptance-criteria shape. Perform a final stage quiz on the plan's mainline and ask for overall human acceptance before writing the plan.

After each passed checkpoint, increment `COACH_CHECK_COUNT`, update `COACH_MAINLINE_LEDGER`, and append concise checkpoint notes to `COACH_CHECK_SUMMARY` for Phase 8 reporting. When all required checkpoints have passed, set `COACH_CHECK_STATUS=passed`. When `COACH_MODE=false`, skip this protocol completely.

---

## Phase 0.5: Load Project Config

After setting execution mode flags, resolve configuration using `${CLAUDE_PLUGIN_ROOT}/scripts/lib/config-loader.sh`. Reuse that behavior; do not read `.humanize/config.json` directly.

### Config Merge Semantics

1. Source `${CLAUDE_PLUGIN_ROOT}/scripts/lib/config-loader.sh`.
2. Call `load_merged_config "${CLAUDE_PLUGIN_ROOT}" "${PROJECT_ROOT}"` to obtain `MERGED_CONFIG_JSON`, where `PROJECT_ROOT` is the repository root where the command was invoked.
3. `load_merged_config` merges these layers in order:
   - Required default config: `${CLAUDE_PLUGIN_ROOT}/config/default_config.json`
   - Optional user config: `${XDG_CONFIG_HOME:-$HOME/.config}/humanize/config.json`
   - Optional project config: `${HUMANIZE_CONFIG:-$PROJECT_ROOT/.humanize/config.json}`
4. Later layers override earlier layers. Malformed optional JSON objects are warnings and ignored. A malformed required default config, missing `jq`, or any other fatal `load_merged_config` failure is a configuration error and must stop the command.

### Values to Extract

Use `get_config_value` against `MERGED_CONFIG_JSON` to read:

- `CONFIG_ALT_LANGUAGE_RAW` from `alternative_plan_language`
- `CONFIG_GEN_PLAN_MODE_RAW` from `gen_plan_mode`
- `CONFIG_CHINESE_PLAN_RAW` from `chinese_plan` (legacy fallback only)

Also detect whether `alternative_plan_language` is explicitly present in `MERGED_CONFIG_JSON` so an empty string still counts as an explicit override:

- `HAS_ALT_LANGUAGE_KEY=true` when `MERGED_CONFIG_JSON` contains the `alternative_plan_language` key
- `HAS_ALT_LANGUAGE_KEY=false` otherwise

### Alternative Language Resolution

1. Resolve the effective `alternative_plan_language` value with this priority:
   - Merged config `alternative_plan_language`, when `HAS_ALT_LANGUAGE_KEY=true` (even if the value is an empty string)
   - Deprecated merged config `chinese_plan`, only when `HAS_ALT_LANGUAGE_KEY=false`
   - Default disabled state
2. Backward compatibility for deprecated `chinese_plan`:
   - If `HAS_ALT_LANGUAGE_KEY=true` and `CONFIG_CHINESE_PLAN_RAW` is `true`, log: `Warning: deprecated "chinese_plan" field ignored; "alternative_plan_language" takes precedence. Remove "chinese_plan" from your humanize config.`
   - If `HAS_ALT_LANGUAGE_KEY=false` and `CONFIG_CHINESE_PLAN_RAW` is `true`, treat the effective `alternative_plan_language` as `"Chinese"`. Log: `Warning: deprecated "chinese_plan" field detected. Replace it with "alternative_plan_language": "Chinese" in your humanize config.`
   - Otherwise treat the effective `alternative_plan_language` as disabled.
3. Resolve `ALT_PLAN_LANGUAGE` and `ALT_PLAN_LANG_CODE` from the effective `alternative_plan_language` value using the built-in mapping table below. Matching is **case-insensitive**.

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

   Matching accepts both the language name (e.g. `"Chinese"`) and the ISO 639-1 code (e.g. `"zh"`), both case-insensitive. Leading/trailing whitespace is trimmed before matching.

   - If the value is empty or absent: set `ALT_PLAN_LANGUAGE=""` and `ALT_PLAN_LANG_CODE=""` (disabled).
   - If the value is `"English"` or `"en"` (case-insensitive): set `ALT_PLAN_LANGUAGE=""` and `ALT_PLAN_LANG_CODE=""` (no-op; the plan is already in English).
   - If the value matches a language name or code in the table: set `ALT_PLAN_LANGUAGE` to the matched language name and `ALT_PLAN_LANG_CODE` to the corresponding code.
   - If the value does NOT match any language name or code in the table: set `ALT_PLAN_LANGUAGE=""` and `ALT_PLAN_LANG_CODE=""` (disabled). Log: `Warning: unsupported alternative_plan_language "<value>". Supported values: Chinese (zh), Korean (ko), Japanese (ja), Spanish (es), French (fr), German (de), Portuguese (pt), Russian (ru), Arabic (ar). Translation variant will not be generated.`
4. Resolve `CONFIG_GEN_PLAN_MODE_RAW` from the merged config:
   - Valid values: `"discussion"` or `"direct"` (case-insensitive).
   - Invalid or absent values: treat as absent (fall back to default) and log a warning if the value is present but invalid.
5. Resolve `GEN_PLAN_MODE` using the following priority (highest to lowest), with CLI flags taking priority over merged config:
   - CLI flag: if `GEN_PLAN_MODE_DISCUSSION=true`, set `GEN_PLAN_MODE=discussion`; if `GEN_PLAN_MODE_DIRECT=true`, set `GEN_PLAN_MODE=direct`
   - Merged config `gen_plan_mode` field (if valid)
   - Default: `discussion`
6. Malformed optional user or project config files should be reported as warnings by `load_merged_config` and must NOT stop execution. In those cases, continue with the remaining valid layers and the same effective defaults (`ALT_PLAN_LANGUAGE=""`, `ALT_PLAN_LANG_CODE=""`, and `GEN_PLAN_MODE=discussion`) when no higher-precedence value is available.

`ALT_PLAN_LANGUAGE` and `ALT_PLAN_LANG_CODE` control whether a translated language variant of the output file is written in Phase 8. When `ALT_PLAN_LANGUAGE` is non-empty, a variant file with the `_<ALT_PLAN_LANG_CODE>` suffix is generated.

---

## Phase 1: IO Validation

Execute the validation script with the provided arguments:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/validate-gen-plan-io.sh" $ARGUMENTS
```

**Handle exit codes:**
- Exit code 0: Continue to Phase 2. Parse the `TEMPLATE_FILE:` line from stdout to get the template path.
- Exit code 1: Report "Input file not found" and stop
- Exit code 2: Report "Input file is empty" and stop
- Exit code 3: Report "Output directory does not exist - please create it" and stop
- Exit code 4: Report "Output file already exists - please choose another path" and stop
- Exit code 5: Report "No write permission to output directory" and stop
- Exit code 6: Report "Invalid arguments" and show usage, then stop
- Exit code 7: Report "Plan template file not found - plugin configuration error" and stop

**Note:** The validation script is side-effect-free. It does NOT create the output file.

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

4. **If RELEVANT**: Create the output plan file by copying the template and appending the draft:
   ```bash
   cp "$TEMPLATE_FILE" "$OUTPUT_FILE" && echo "" >> "$OUTPUT_FILE" && echo "--- Original Design Draft Start ---" >> "$OUTPUT_FILE" && echo "" >> "$OUTPUT_FILE" && cat "$INPUT_FILE" >> "$OUTPUT_FILE" && echo "" >> "$OUTPUT_FILE" && echo "--- Original Design Draft End ---" >> "$OUTPUT_FILE"
   ```
   Then continue to Phase 3.

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

If `COACH_MODE=true`, run Checkpoint A before entering Phase 4.

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

If `COACH_MODE=true`, run Checkpoint B before entering Phase 5. In direct mode, run Checkpoint B before entering Phase 6.

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
   - If `COACH_MODE=true`, run Checkpoint C before starting another convergence round or declaring convergence

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

If `HUMAN_REVIEW_REQUIRED=false`, skip Step 2-4 after Step 1.5 runs. Then run Checkpoint D if `COACH_MODE=true`; otherwise continue directly to Phase 7.

### Step 1.5: Consolidate Pending User Decisions (runs unconditionally)

Before proceeding (regardless of `HUMAN_REVIEW_REQUIRED`), consolidate all user-facing questions from prior phases into the plan's `## Pending User Decisions` section:

1. Extract `QUESTIONS_FOR_USER` items from Codex Analysis v1 (Phase 3)
2. Extract items with status `needs_user_decision` from the final convergence matrix (Phase 5) — use the last round's state, not intermediate rounds
3. Deduplicate: if the same topic appears in both sources, merge into one entry
4. For each collected item, check if it was substantively resolved during Phase 4-5 plan refinement (i.e., Claude addressed it and second Codex agreed in a subsequent round). Remove only items with clear evidence of resolution.
5. Write all remaining unresolved items into the plan's `## Pending User Decisions` section. Use `DEC-N` identifiers. Set `Decision Status` to `PENDING`.
   - For Claude-vs-Codex disagreements: fill `Claude Position`, `Codex Position`, and `Tradeoff Summary`
   - For open questions (no opposing positions): set `Claude Position` to Claude's tentative answer (if any), `Codex Position` to `N/A - open question`, and `Tradeoff Summary` to the question's context

This ensures:
- When `HUMAN_REVIEW_REQUIRED=true`: items are visible for Steps 2-4 user resolution
- When `HUMAN_REVIEW_REQUIRED=false`: items block auto-start via Phase 8 Step 5's `PENDING` check

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

If `COACH_MODE=true`, run Checkpoint D after all required issue and disagreement handling is complete. Do not enter Phase 7 until `COACH_CHECK_STATUS=passed`.

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

### Translated Language Variant

When `alternative_plan_language` resolves to a supported language name through merged config loading, a translated variant of the output file is also written after the main file. Humanize loads config from merged layers in this order: default config, optional user config, then optional project config; `alternative_plan_language` may be set at any of those layers. The variant filename is constructed by inserting `_<code>` (the ISO 639-1 code from the built-in mapping table) immediately before the file extension:

- `plan.md` becomes `plan_<code>.md` (e.g. `plan_zh.md` for Chinese, `plan_ko.md` for Korean)
- `docs/my-plan.md` becomes `docs/my-plan_<code>.md`
- `output` (no extension) becomes `output_<code>`

The translated variant file contains a full translation of the main plan file's current content in the configured language. All identifiers (`AC-*`, task IDs, file paths, API names, command flags) remain unchanged, as they are language-neutral.

When `alternative_plan_language` is empty, absent, set to `"English"`, or set to an unsupported language, no translated variant is written. Humanize does not auto-create `.humanize/config.json` when no project config file is present.
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

The output file already contains the plan template structure and the original draft content (combined after the relevance check). Now complete the plan through the following steps:

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

### Step 4: Write Translated Language Variant (Conditional)

If `ALT_PLAN_LANGUAGE` is non-empty (translation enabled), write a translated variant of the output file.

**Language Unification guard**: If the main plan file was unified to `ALT_PLAN_LANGUAGE` in Step 3 (Language Unification), skip this step. Log: `Main plan file is already in <ALT_PLAN_LANGUAGE>; translated variant not needed.`

**Filename construction rule** - insert `_<ALT_PLAN_LANG_CODE>` immediately before the file extension:
- `plan.md` becomes `plan_<code>.md` (e.g. `plan_zh.md`, `plan_ko.md`)
- `docs/my-plan.md` becomes `docs/my-plan_<code>.md`
- `output` (no extension) becomes `output_<code>`

Algorithm:
1. Find the last `.` in the base filename.
2. If a `.` is found, insert `_<ALT_PLAN_LANG_CODE>` before it: `<stem>_<code>.<extension>`.
3. If no `.` is found (no extension), append `_<ALT_PLAN_LANG_CODE>` to the filename: `<filename>_<code>`.
4. The variant file is placed in the same directory as the main output file.

**Content of the variant file**:
- Translate the main plan file's current content (after any Language Unification from Step 3) into `ALT_PLAN_LANGUAGE`. For Chinese, default to Simplified Chinese.
- Section headings, AC labels, task IDs, file paths, API names, and command flags MUST remain unchanged (identifiers are language-neutral).
- The variant file is a translated reading view of the same plan; it must not add new information not present in the main file.
- The original draft section at the bottom should be kept as-is (not re-translated).

If `ALT_PLAN_LANGUAGE` is empty (the default), do NOT create a translated variant file.

### Step 5: Optional Direct Work Start

If all of the following are true:
- `AUTO_START_RLCR_IF_CONVERGED=true`
- `PLAN_CONVERGENCE_STATUS=converged`
- `GEN_PLAN_MODE=discussion`
- There are no pending decisions with status `PENDING`
- `COACH_MODE=false` or `COACH_CHECK_STATUS=passed`

Then start work immediately by running:

```bash
/humanize:start-rlcr-loop --skip-quiz <output-plan-path>
```

The `--skip-quiz` flag is passed because the user has already demonstrated understanding of the plan through the gen-plan convergence discussion and, when requested, coach checkpoints.

If the command invocation is not available in this context, fall back to the setup script:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-rlcr-loop.sh" --skip-quiz --plan-file <output-plan-path>
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
- Coach mode status, including checkpoint count, confirmed mainline decisions, and blocked items if applicable
- Number of unresolved user decisions (if any)
- Whether language was unified (if applicable)
- Whether direct work start was attempted, and its result

---

## Error Handling

If issues arise during plan generation that require user input:
- Use AskUserQuestion to clarify
- Document any user decisions in the plan's context

If coach confirmation fails or remains ambiguous:
- Stop before expanding the next planning layer
- Explain which checkpoint is blocked
- Summarize the explanation or revision that was attempted
- Record the blocker in `## Pending User Decisions`
- Tell the user they can rerun without `--coach` only if they intentionally want to skip plan-time coaching checks

If auto-start mode is enabled but convergence conditions are not met:
- Explain why direct start was skipped
- Tell the user to either resolve pending decisions or run `/humanize:start-rlcr-loop <plan.md>` manually

If unable to generate a complete plan:
- Explain what information is missing
- Suggest how the user can improve their draft
