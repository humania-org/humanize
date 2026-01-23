# Finalize Phase (Review Skipped)

**Warning**: Code review was skipped due to: {{REVIEW_SKIP_REASON}}

The implementation could not be fully validated. You are now in the **Finalize Phase**.

## Important Notice

Since the code review was skipped, please manually verify your changes before finalizing:

1. Review your code changes for any obvious issues
2. Run any available tests to verify correctness
3. Check for common code quality issues

## Simplification (Optional)

If time permits, use the `code-simplifier:code-simplifier` agent via the Task tool to simplify and refactor your code.

Focus more on changes between branch from `{{BASE_BRANCH}}` to `{{START_BRANCH}}`.

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

## Reference Files

- Original plan: @{{PLAN_FILE}}
- Goal tracker: @{{GOAL_TRACKER_FILE}}

## Before Exiting

1. Complete all tasks (mark them as completed using TaskUpdate with status "completed")
2. Commit your changes with a descriptive message
3. Write your finalize summary to: **{{FINALIZE_SUMMARY_FILE}}**

Your summary should include:
- What work was done
- Files modified
- Confirmation that tests still pass (if possible)
- Any notes about manual verification performed
