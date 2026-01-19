## Goal Tracker Update Instructions

After completing your analysis, update the goal tracker file at `{{GOAL_TRACKER_FILE}}`:

### Required Updates

1. **Update Current Status section:**
   - Change the Round heading to match current round: `### Round {{NEXT_ROUND}}`
   - Update `Phase:` to reflect current state (e.g., "Analyzing feedback", "Issues found", "All approved")
   - Update `Active Bots:` to list only bots that still have ISSUES status
   - Update `Approved Bots:` to list bots that have APPROVE status

2. **Update Open Issues table:**
   - Add new issues from this round (one row per issue)
   - Mark resolved issues by moving them to Addressed Issues

3. **Update Addressed Issues table:**
   - Move issues that were fixed in this round from Open Issues
   - Add resolution description

4. **Update Log table:**
   - Add entry for this round: `| {{NEXT_ROUND}} | <timestamp> | <summary of what happened> |`

### Example Goal Tracker Update

If bot "claude" reported 2 issues and "codex" approved:

```markdown
### Round {{NEXT_ROUND}}: Review Analysis

- **Phase:** Issues found - awaiting fixes
- **Active Bots:** claude
- **Approved Bots:** codex

### Open Issues

| Round | Bot | Issue | Status |
|-------|-----|-------|--------|
| {{NEXT_ROUND}} | claude | Missing error handling in auth.ts | pending |
| {{NEXT_ROUND}} | claude | Test coverage below 80% | pending |

### Log

| Round | Timestamp | Event |
|-------|-----------|-------|
| {{NEXT_ROUND}} | (now) | codex approved; claude reported 2 issues |
```

### Important

- Keep the file structure intact
- Use proper markdown table formatting
- Only update sections mentioned above
- Do not modify the header sections (PR Information, Ultimate Goal, Acceptance Criteria)
