---
description: "Start iterative loop with Codex review"
argument-hint: "[path/to/plan.md | --plan-file path/to/plan.md] [--max N] [--codex-model MODEL:EFFORT] [--codex-timeout SECONDS] [--track-plan-file] [--push-every-round] [--base-branch BRANCH] [--full-review-round N] [--skip-impl] [--claude-answer-codex] [--agent-teams] [--yolo] [--skip-quiz] [--privacy]"
allowed-tools:
  - "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-rlcr-loop.sh:*)"
  - "Read"
  - "Task"
  - "AskUserQuestion"
hide-from-slash-command-tool: "true"
---

# Start RLCR Loop

## Plan Compliance Pre-Check

Before running the setup script, validate the plan file for compliance. This is a fool-proofing mechanism that catches obviously wrong plan files early.

**Skip this entire pre-check if** any of these conditions are true:
- `$ARGUMENTS` contains `--skip-impl` (no plan file to validate)
- `$ARGUMENTS` contains `-h` or `--help` (just showing help)

### Extract the plan file path from arguments

Parse `$ARGUMENTS` to find the plan file path:
- If `--plan-file <path>` is present, use `<path>`
- Otherwise, use the first positional argument (the first argument that does not start with `--` and is not a value following a known flag like `--max`, `--codex-model`, `--codex-timeout`, `--base-branch`, `--full-review-round`, `--plan-file`)
- If no plan file path can be determined, skip the pre-check and let the setup script handle the error

### Basic path safety gate

Only proceed with the pre-check if the extracted path meets ALL of these conditions:
- Is a relative path (does not start with forward slash)
- Does not contain parent directory traversal (double dot path components)
- Contains only safe path characters: letters, digits, hyphen, underscore, dot, and forward slash

If any condition fails, skip the pre-check and let the setup script handle path validation.

### Read and validate plan content

1. Use the Read tool to read the plan file. If the file does not exist or cannot be read, skip the pre-check and let the setup script handle the error.

2. Use the Task tool to invoke the `humanize:plan-compliance-checker` agent (sonnet model):
   ```
   Task tool parameters:
   - model: "sonnet"
   - prompt: Include the plan file content and ask the agent to:
     1. Explore the repository structure (README, CLAUDE.md, main files)
     2. Check if the plan content relates to this repository
     3. Check if the plan contains branch-switching instructions
     4. Return exactly one of: `PASS: <summary>`, `FAIL_RELEVANCE: <reason>`, or `FAIL_BRANCH_SWITCH: <details>`
   ```

3. **Parse the result** (fail-closed):
   - If output contains `PASS`: continue to setup script below
   - If output contains `FAIL_RELEVANCE`: report "Plan compliance check failed: the plan does not appear to be related to this repository." Show the reason. **Stop the command.**
   - If output contains `FAIL_BRANCH_SWITCH`: report "Plan compliance check failed: the plan contains branch-switching instructions, which are incompatible with RLCR. The RLCR loop requires the working branch to remain constant across all rounds." Show the details. **Stop the command.**
   - If output contains none of the above (malformed): report "Plan compliance check produced unexpected output. Cannot proceed." **Stop the command.**

---

## Plan Understanding Quiz

Before running the setup script, verify the user genuinely understands what the plan will do. This is an advisory check -- it never blocks the loop, but catches "wishful thinking" users who blindly accepted a generated plan without reading it.

**Skip this entire quiz if** any of these conditions are true:
- `$ARGUMENTS` contains `--skip-impl` (no plan to quiz about)
- `$ARGUMENTS` contains `--yolo` (user explicitly opted out of all pre-flight checks)
- `$ARGUMENTS` contains `--skip-quiz` (user explicitly opted out of the quiz)
- `$ARGUMENTS` contains `-h` or `--help` (just showing help)
- No plan content is available (the compliance pre-check was skipped because no plan file path could be determined)

### Run the quiz agent

1. Reuse the plan content that was already read during the compliance pre-check above (do not re-read the file).

2. Use the Task tool to invoke the `humanize:plan-understanding-quiz` agent (opus model):
   ```
   Task tool parameters:
   - model: "opus"
   - prompt: Include the plan file content and ask the agent to:
     1. Explore the repository structure for context
     2. Analyze the plan's technical implementation details
     3. Generate 2 multiple-choice questions (4 options each) and a plan summary
     4. Return in the structured format: QUESTION_1, OPTION_1A-D, ANSWER_1, QUESTION_2, OPTION_2A-D, ANSWER_2, PLAN_SUMMARY
   ```

3. **Parse the result**: Extract all 13 fields from the agent output (QUESTION_1, OPTION_1A through OPTION_1D, ANSWER_1, QUESTION_2, OPTION_2A through OPTION_2D, ANSWER_2, PLAN_SUMMARY). If the output is malformed (any field missing or ANSWER not A/B/C/D), warn: "Plan understanding quiz unavailable, continuing without it." and proceed to the Setup section below.

### Ask questions and evaluate

4. Use AskUserQuestion to present QUESTION_1 as a multiple-choice question with the 4 options (OPTION_1A through OPTION_1D). Compare the user's choice against ANSWER_1:
   - If the user selected the correct answer, mark QUESTION_1 as **PASS**
   - Otherwise, mark as **WRONG**

5. Use AskUserQuestion to present QUESTION_2 as a multiple-choice question with the 4 options (OPTION_2A through OPTION_2D). Compare the user's choice against ANSWER_2 using the same criteria.

### Decide whether to proceed

6. **If both questions PASS**: Briefly acknowledge ("Your understanding of the plan looks solid. Proceeding with setup.") and continue to the Setup section below.

7. **If one or both questions are WRONG**: Show the PLAN_SUMMARY to the user to help them understand what the plan does and the correct answers to the questions they missed. Then use AskUserQuestion with the question: "Would you like to proceed with the RLCR loop anyway, or stop and review the plan more carefully first?" with these choices:
   - "Proceed with RLCR loop"
   - "Stop and review the plan first"

   - If the user chooses **"Proceed with RLCR loop"**: Continue to the Setup section below.
   - If the user chooses **"Stop and review the plan first"**: Report "Stopping. Please review the plan file and re-run start-rlcr-loop when ready." and **stop the command**.

---

## Setup

If the pre-check passed (or was skipped), and the quiz passed (or was skipped or user chose to proceed), execute the setup script to initialize the loop:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-rlcr-loop.sh" $ARGUMENTS
```

This command starts an iterative development loop where:

1. You execute the implementation plan with task-tag routing
   - `coding` tasks: Claude executes directly
   - `analyze` tasks: execute via `/humanize:ask-codex`
2. Write a summary of your work to the specified summary file
3. When you try to exit, Codex reviews your summary
4. If Codex finds issues, you receive feedback and continue
5. If Codex outputs "COMPLETE", the loop enters **Review Phase**
6. In Review Phase, `codex review --base <branch>` performs code review
7. If code review finds issues (`[P0-9]` markers), you fix them and continue
8. When no issues are found, the loop ends with a Finalize Phase

## Goal Tracker System

This loop uses a **Goal Tracker** to prevent goal drift across iterations:

### Structure
- **IMMUTABLE SECTION**: Ultimate Goal and Acceptance Criteria (set in Round 0, never changed)
- **MUTABLE SECTION**: Active Tasks, Completed Items, Deferred Items, Plan Evolution Log

### Key Features
1. **Acceptance Criteria**: Each task maps to a specific AC - nothing can be "forgotten"
2. **Task Tag Routing**: Every task should carry `coding` or `analyze` tag from plan generation
   - `coding -> Claude`, `analyze -> Codex`
3. **Plan Evolution Log**: If you discover the plan needs changes, document the change with justification
4. **Explicit Deferrals**: Deferred tasks require strong justification and impact analysis
5. **Full Alignment Checks**: At configurable intervals (default every 5 rounds: rounds 4, 9, 14, etc.), Codex conducts a comprehensive goal alignment audit. Use `--full-review-round N` to customize (min: 2)

### How to Use
1. **Round 0**: Initialize the Goal Tracker with Ultimate Goal and Acceptance Criteria
2. **Each Round**: Update task status, log plan changes, note discovered issues
3. **Before Exit**: Ensure goal-tracker.md reflects current state accurately

## Important Rules

1. **Write summaries**: Always write your work summary to the specified file before exiting
2. **Maintain Goal Tracker**: Keep goal-tracker.md up-to-date with your progress
3. **Be thorough**: Include details about what was implemented, files changed, and tests added
4. **No cheating**: Do not try to exit the loop by editing state files or running cancel commands
5. **Trust the process**: Codex's feedback helps improve the implementation

## BitLesson Workflow (Project Level)

Each project must maintain its own `.humanize/bitlesson.md` file.
If missing, `start-rlcr-loop` initializes it automatically with a strict template.

Per round requirements:
1. Read `.humanize/bitlesson.md` before execution
2. Run `bitlesson-selector` for each task/sub-task
3. Apply selected lesson IDs (or `NONE`) during implementation
4. Include `## BitLesson Delta` in the round summary with `Action: none|add|update`

If a problem is solved only after multiple rounds, add or update a precise lesson entry in `.humanize/bitlesson.md` (specific problem + specific solution).
By default, empty `.humanize/bitlesson.md` does not block `Action: none`; use `--require-bitlesson-entry-for-none` to enforce strict blocking.

## Stopping the Loop

- Reach the maximum iteration count
- Codex confirms completion with "COMPLETE", followed by successful code review (no `[P0-9]` issues)
- User runs `/humanize:cancel-rlcr-loop`

## Two-Phase System

The RLCR loop has two phases within the active loop:

1. **Implementation Phase**: Work by task tags (`coding -> Claude`, `analyze -> /humanize:ask-codex`), then Codex reviews your summary
2. **Review Phase**: After COMPLETE, `codex review` checks code quality with `[P0-9]` severity markers

The `--base-branch` option specifies the base branch for code review comparison. If not provided, it auto-detects from: remote default > local main > local master.

## Skip Implementation Mode

Use `--skip-impl` to skip the implementation phase and go directly to code review:

```bash
/humanize:start-rlcr-loop --skip-impl
```

In this mode:
- Plan file is optional (not required)
- No goal tracker initialization needed
- Immediately starts code review when you try to exit
- Useful for reviewing existing changes without an implementation plan

This is helpful when you want to:
- Review code changes made outside of an RLCR loop
- Get code quality feedback on existing work
- Skip the implementation tracking overhead for simple tasks
