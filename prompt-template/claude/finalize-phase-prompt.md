# Finalize Phase

Codex review has passed. The implementation is complete and all acceptance criteria have been met.

You are now in the **Finalize Phase**. This is your opportunity to simplify and refactor the code before final completion.

## Your Task

Use the `code-simplifier:code-simplifier` agent via the Task tool to review and simplify the recent code changes.

Example invocation:
```
Task tool with subagent_type="code-simplifier:code-simplifier"
```

## Constraints

These constraints are **non-negotiable**:

1. **Must NOT change existing functionality** - All features must work exactly as before
2. **Must NOT fail existing tests** - Run tests to verify nothing is broken
3. **Must NOT introduce new bugs** - Be careful with refactoring
4. **Only perform functionality-equivalent changes** - Simplification and cleanup only

## Focus Areas

The code-simplifier agent should focus on:
- Code that was recently added or modified
- Focus more on changes between branch from `{{BASE_BRANCH}}` to `{{START_BRANCH}}`
- Removing unnecessary complexity
- Improving readability and maintainability
- Consolidating duplicate code
- Simplifying control flow where possible
- Removing dead code or unused variables

## Reference Files

- Original plan: @{{PLAN_FILE}}
- Goal tracker: @{{GOAL_TRACKER_FILE}}

## Before Exiting

1. Complete all tasks (mark them as completed using TaskUpdate with status "completed")
2. Commit your changes with a descriptive message
3. Write your finalize summary to: **{{FINALIZE_SUMMARY_FILE}}**

Your summary should include:
- What simplifications were made
- Files modified during the Finalize Phase
- Confirmation that tests still pass
- Any notes about the refactoring decisions
