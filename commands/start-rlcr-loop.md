---
description: "Start iterative loop with Codex review"
argument-hint: "[path/to/plan.md | --plan-file path/to/plan.md] [--max N] [--codex-model MODEL:EFFORT] [--codex-timeout SECONDS] [--track-plan-file] [--push-every-round] [--base-branch BRANCH] [--full-review-round N] [--skip-impl] [--claude-answer-codex] [--agent-teams]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-rlcr-loop.sh:*)"]
hide-from-slash-command-tool: "true"
---

# Start RLCR Loop

Execute the setup script to initialize the loop:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-rlcr-loop.sh" $ARGUMENTS
```

This command starts an iterative development loop where:

1. You work on the implementation plan provided
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
2. **Plan Evolution Log**: If you discover the plan needs changes, document the change with justification
3. **Explicit Deferrals**: Deferred tasks require strong justification and impact analysis
4. **Full Alignment Checks**: At configurable intervals (default every 5 rounds: rounds 4, 9, 14, etc.), Codex conducts a comprehensive goal alignment audit. Use `--full-review-round N` to customize (min: 2)

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

## Stopping the Loop

- Reach the maximum iteration count
- Codex confirms completion with "COMPLETE", followed by successful code review (no `[P0-9]` issues)
- User runs `/humanize:cancel-rlcr-loop`

## Two-Phase System

The RLCR loop has two phases within the active loop:

1. **Implementation Phase**: Work on the plan, Codex reviews your summary
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
