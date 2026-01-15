# RLCR Loop Blocked: Plan File Changed

The plan file has been {{STATUS_TEXT}} since the loop started.

**Plan file**: `{{PLAN_FILE}}`
**Backup**: `{{PLAN_BACKUP_FILE}}`

The RLCR loop cannot continue because the plan has changed.

**Options:**
1. **Restart the loop** with the new plan:
   `/humanize:start-rlcr-loop {{PLAN_FILE}}`

2. **Restore the original plan** from backup:
   `cp '{{PLAN_BACKUP_FILE}}' '{{PLAN_FILE}}'`
   Then submit your prompt again.

3. **Cancel the loop** and work without RLCR:
   `/humanize:cancel-rlcr-loop`
