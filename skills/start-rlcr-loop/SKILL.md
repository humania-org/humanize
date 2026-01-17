---
name: start-rlcr-loop
description: Start iterative development loop with Codex review. Use when starting a new development iteration, beginning RLCR workflow, or when the user wants to implement a plan with AI review feedback.
model: claude-opus-4-5-20250514
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-rlcr-loop.sh:*)
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
5. If Codex outputs "COMPLETE", the loop ends

## Goal Tracker System

This loop uses a **Goal Tracker** to prevent goal drift across iterations:

### Structure
- **IMMUTABLE SECTION**: Ultimate Goal and Acceptance Criteria (set in Round 0, never changed)
- **MUTABLE SECTION**: Active Tasks, Completed Items, Deferred Items, Plan Evolution Log

### Key Features
1. **Acceptance Criteria**: Each task maps to a specific AC - nothing can be "forgotten"
2. **Plan Evolution Log**: If you discover the plan needs changes, document the change with justification
3. **Explicit Deferrals**: Deferred tasks require strong justification and impact analysis
4. **Full Alignment Checks**: At rounds 4, 9, 14, etc. (after every 4 rounds of work), Codex conducts a comprehensive goal alignment audit

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
- Codex confirms completion with "COMPLETE" (all ACs met or validly deferred)
- User runs `/humanize:cancel-rlcr-loop`
