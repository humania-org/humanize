# Code Review Phase - Round {{REVIEW_ROUND}}

This file documents the code review invocation for audit purposes.
Note: `codex review` does not accept prompt input; it performs automated code review based on git diff.

## Review Configuration

- **Base Branch**: {{BASE_BRANCH}}
- **Review Round**: {{REVIEW_ROUND}}
- **Timestamp**: {{TIMESTAMP}}

## What This Phase Does

1. Runs `codex review --base {{BASE_BRANCH}}` to perform automated code review
2. Scans output for `[P0-9]` severity markers indicating issues
3. If issues found: Returns fix prompt to Claude for remediation
4. If no issues: Transitions to Finalize Phase

## Expected Output Format

Codex review outputs issues in this format:
```
- [P0] Critical issue description - /path/to/file.py:line-range
  Detailed explanation of the issue.

- [P1] High priority issue - /path/to/file.py:line-range
  Detailed explanation.
```

## Files Generated

- `round-{{REVIEW_ROUND}}-review-prompt.md` - This audit file
- `round-{{REVIEW_ROUND}}-review-result.md` - Review output (in loop directory)
- `round-{{REVIEW_ROUND}}-codex-review.cmd` - Command invocation (in cache)
- `round-{{REVIEW_ROUND}}-codex-review.out` - Stdout capture (in cache)
- `round-{{REVIEW_ROUND}}-codex-review.log` - Stderr capture (in cache)
