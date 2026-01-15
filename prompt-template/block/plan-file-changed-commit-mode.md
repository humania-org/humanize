# Error: Plan File Changed (--commit-plan-file mode)

The plan file has changed since the loop started, but --commit-plan-file requires it to be tracked and clean.

**Plan file**: `{{PLAN_FILE}}`
**Issues**:
{{ISSUE_DETAILS}}

**Backup**: `{{PLAN_BACKUP_FILE}}`

The loop cannot continue because the plan file state has changed unexpectedly.

**Options:**
1. **Commit the plan file changes** and restart the loop
2. **Revert to the original plan**: `cp '{{PLAN_BACKUP_FILE}}' '{{PLAN_FILE}}'` then commit
3. **Start a new loop** without --commit-plan-file if you want the plan to remain uncommitted
