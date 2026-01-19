# Code Review Request

Review the code changes between the base branch and current HEAD.

## Base Branch
`{{BASE_BRANCH}}`

## Review Scope
Focus on code quality, potential bugs, and implementation issues in the changes made during this RLCR session.

## Review Guidelines

1. **Severity Markers**: Use `[P0]` through `[P9]` to indicate issue priority:
   - `[P0]` - Critical: Security vulnerability, data loss, or crash
   - `[P1]` - High: Significant bug or broken functionality
   - `[P2]` - Medium: Logic error or incorrect behavior
   - `[P3]` - Low: Minor bug or edge case issue
   - `[P4-P9]` - Minimal: Code quality, style, or optimization suggestions

2. **Issue Format**:
   ```
   [P<N>] <file>:<line> - <brief description>
   <detailed explanation>
   ```

3. **Review Focus**:
   - Logic errors and bugs
   - Missing error handling
   - Security vulnerabilities
   - Performance issues
   - Edge cases not handled
   - Incorrect assumptions

## Output

If issues are found, list each with its severity marker and location.

If no issues are found, output a brief summary confirming the code is ready for finalization.

Write your review to: `{{REVIEW_RESULT_FILE}}`
