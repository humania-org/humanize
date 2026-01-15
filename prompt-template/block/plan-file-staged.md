# Git Commit Blocked: Plan File is Staged

The plan file is staged and would be included in this commit, but `--commit-plan-file` was not set when starting the RLCR loop.

**Plan file**: `{{PLAN_FILE}}`

## Why This Is Blocked

When `--commit-plan-file` is not set, the plan file should not be committed to version control. This prevents polluting the commit history with working document changes.

## How to Fix

### Option 1: Unstage the plan file (Recommended)

Run this command to unstage the plan file, then retry your commit:

```bash
git reset HEAD {{PLAN_FILE}}
```

### Option 2: Use --commit-plan-file

If you want the plan file to be tracked in version control:

1. Cancel this RLCR loop: `/humanize:cancel-rlcr-loop`
2. Restart with the --commit-plan-file flag:
   `/humanize:start-rlcr-loop {{PLAN_FILE}} --commit-plan-file`

**Note**: The plan file backup is always saved in `.humanize-loop.local/<timestamp>/plan-backup.md` regardless of this setting.
