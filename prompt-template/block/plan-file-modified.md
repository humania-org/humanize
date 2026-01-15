# Plan File Modified

The plan file `{{PLAN_FILE}}` has been modified since the RLCR loop started.

**Modifying plan files is forbidden during an active RLCR loop.**

If you need to change the plan:
1. Cancel the current loop: `/humanize:cancel-rlcr-loop`
2. Update the plan file
3. Start a new loop: `/humanize:start-rlcr-loop {{PLAN_FILE}}`

Backup available at: `{{BACKUP_PATH}}`
