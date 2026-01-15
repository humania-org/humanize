# Warning: Plan File Modified

The plan file has been modified since the loop started.

**Plan file**: `{{PLAN_FILE}}` ({{TRACKING_STATUS}})
**Backup**: `{{PLAN_BACKUP_FILE}}`

The current plan differs from the backup taken when the loop started. Your work may no longer align with the updated plan.

**Options:**
1. **Restart the loop** with the new plan:
   `/humanize:start-rlcr-loop {{PLAN_FILE}}`

2. **Continue with the new plan** by overwriting the backup:
   `cp '{{PLAN_FILE}}' '{{PLAN_BACKUP_FILE}}'`
   Then start a new loop with `/humanize:start-rlcr-loop {{PLAN_FILE}}`

3. **Revert to the original plan**:
   `cp '{{PLAN_BACKUP_FILE}}' '{{PLAN_FILE}}'`
   Then start a new loop with `/humanize:start-rlcr-loop {{PLAN_FILE}}`
