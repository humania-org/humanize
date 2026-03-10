---
description: "Start iterative loop with Codex review"
argument-hint: "[path/to/plan.md | --plan-file path/to/plan.md] [--max N] [--codex-model MODEL:EFFORT] [--codex-timeout SECONDS] [--track-plan-file] [--push-every-round] [--base-branch BRANCH] [--full-review-round N] [--skip-impl] [--claude-answer-codex] [--agent-teams]"
allowed-tools:
  - "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-rlcr-loop.sh:*)"
  - "Read"
  - "Task"
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

## Setup

If the pre-check passed (or was skipped), execute the setup script to initialize the loop:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-rlcr-loop.sh" $ARGUMENTS
```

This command starts an iterative development loop where:

1. You execute the implementation plan with task-tag routing
   - `coding` tasks: execute via the configured coding worker (see `coding_worker_model` config key)
   - `analyze` tasks: execute via the configured analyzing worker (see `analyzing_worker_model` config key)
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
   - `coding -> worker`, `analyze -> analyzer`
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
6. **Delegated agent context is mandatory**: Every delegated agent call must explicitly mention the worker/reviewer relationship and that review is **independent** (cross-vendor style), even if all models are OpenAI today.

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

1. **Implementation Phase**: Work by task tags (`coding -> configured coding worker via coding_worker_model`, `analyze -> configured analyzing worker via analyzing_worker_model`), then Codex reviews your summary
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
