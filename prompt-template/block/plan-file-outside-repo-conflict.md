# Configuration Conflict: Plan File Outside Repository

**Error**: --commit-plan-file is set but the plan file is outside the git repository.

**Plan file**: `{{PLAN_FILE}}`
**Relative path**: `{{PLAN_FILE_REL}}`

This is a configuration error that should have been caught at setup.
The loop cannot continue with this configuration.

**To fix**: Start a new loop with either:
1. Move the plan file inside the repository and use --commit-plan-file
2. Use the loop without --commit-plan-file for external plan files
