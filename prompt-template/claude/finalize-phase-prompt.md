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

1. Complete all `[mainline]` and `[blocking]` tasks (mark them as completed using TaskUpdate with status "completed")
2. `[queued]` tasks may remain only if they are documented as non-blocking follow-up work
3. Commit your changes with a descriptive message
4. Write your finalize summary to: **{{FINALIZE_SUMMARY_FILE}}**

Your summary should include:
- What simplifications were made
- Files modified during the Finalize Phase
- Confirmation that tests still pass
- Any notes about the refactoring decisions

## Required: Outcome Classification

The **first content line** of your finalize summary MUST be one of these three classifications, formatted exactly as shown:

```
Outcome: no-op (already-minimal)
```
```
Outcome: cosmetic (formatting only)
```
```
Outcome: substantive (logic edits)
```

Pick the one that matches what actually happened:

- **`no-op (already-minimal)`** — the code was already at minimal complexity for its constraints; refactor agent (or you) made no edits. This is a positive signal — it means the prior rounds did not ship over-complex artifacts. Common in re-acceptance sessions where the substantive work landed in a prior session.
- **`cosmetic (formatting only)`** — only formatting / whitespace / comment-only changes. No logic touched.
- **`substantive (logic edits)`** — actual logic changes were made (extracted helpers, consolidated branches, removed dead code, etc.). For sessions whose Codex review approved COMPLETE before Finalize, a `substantive` outcome warrants a one-sentence justification of why the prior rounds shipped non-minimal artifacts.

Why this classification matters: it lets future audits and methodology analyses tell at a glance whether the Finalize Phase added real value, was a no-op (the expected outcome in well-shaped rounds), or surfaced complexity the implementation rounds left behind. A `no-op` outcome is **not failure** — it is positive evidence that the prior rounds' exit point was already at local minimum complexity.
