# Error: Plan File Has Uncommitted Changes

The plan file has uncommitted changes, but --commit-plan-file requires it to be clean.

**Plan file**: `{{PLAN_FILE}}`
**Status**: `{{PLAN_FILE_STATUS}}`

**Options:**
1. **Commit the plan file changes**: `git add '{{PLAN_FILE}}' && git commit -m 'Update plan'`
2. **Discard the changes**: `git checkout -- '{{PLAN_FILE}}'`
3. **Start a new loop** without --commit-plan-file if you want the plan to remain uncommitted
