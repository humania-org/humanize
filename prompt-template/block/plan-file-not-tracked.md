# Error: Plan File Not Tracked

The plan file is not tracked by git, but --commit-plan-file requires it to be tracked.

**Plan file**: `{{PLAN_FILE}}`

**Options:**
1. **Track the plan file**: `git add '{{PLAN_FILE}}' && git commit -m 'Add plan file'`
2. **Cancel and restart** without --commit-plan-file if you want the plan to remain untracked

`/humanize:cancel-rlcr-loop`
