# State Schema Outdated

RLCR loop state file is missing required field: `{{FIELD_NAME}}`

This indicates the loop was started with an older version of humanize.

**Options:**
1. Cancel the loop: `/humanize:cancel-rlcr-loop`
2. Update humanize plugin to version 1.1.2+
3. Restart the RLCR loop with the updated plugin

The loop will be terminated as 'unexpected' to preserve state information.
