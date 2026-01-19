## Goal Tracker Update Instructions

After completing your analysis, update the goal tracker file at `{{GOAL_TRACKER_FILE}}`:

### Required Updates

1. **Add row to Issue Summary table:**
   - Add a new row for this round with your review results
   - Format: `| {{NEXT_ROUND}} | <reviewer_name> | <issues_found> | <issues_resolved> | <status> |`
   - Status should be: "Issues Found", "All Resolved", or "Approved"

2. **Update Total Statistics section:**
   - Increment `Total Issues Found` by number of new issues discovered
   - Increment `Total Issues Resolved` by number of issues you verified as fixed
   - Update `Remaining` to be (Total Found - Total Resolved)

3. **Add Issue Log entry for this round:**
   - Create heading: `### Round {{NEXT_ROUND}}`
   - List each issue or approval with details
   - Include reviewer name and brief description

### Example Goal Tracker Update

If bot "claude" reported 2 new issues and "codex" found 0 issues (approved):

```markdown
## Issue Summary

| Round | Reviewer | Issues Found | Issues Resolved | Status |
|-------|----------|--------------|-----------------|--------|
| 0     | -        | 0            | 0               | Initial |
| 1     | claude   | 2            | 0               | Issues Found |
| 1     | codex    | 0            | 0               | Approved |

## Total Statistics

- Total Issues Found: 2
- Total Issues Resolved: 0
- Remaining: 2

## Issue Log

### Round 0
*Awaiting initial reviews*

Started: 2026-01-18T10:00:00Z
Startup Case: 1

### Round 1
**claude** found 2 issues:
1. Missing error handling in auth.ts
2. Test coverage below 80%

**codex** approved - no issues found.
```

### Important Rules

- Keep the file structure intact
- Use proper markdown table formatting
- Only update the sections mentioned above (Issue Summary, Total Statistics, Issue Log)
- Do not modify the header sections (PR Information, Ultimate Goal)
- Add to existing tables, do not replace them
- Each reviewer gets a separate row in Issue Summary
