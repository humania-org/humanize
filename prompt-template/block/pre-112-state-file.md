# RLCR Loop Terminated - Upgrade Required

This loop was started with an older version of Humanize (pre-1.1.2) that did not track the starting commit. The new plan file protection features cannot work reliably without this information.

**What happened:**
- Your state file has been renamed to `state.md.bak` to stop the loop
- Your work and summaries in `.humanize-loop.local/` are preserved

**To continue your work:**
1. Update Humanize to version 1.1.2 or later
2. Start a new RLCR loop with your plan file:
   `/humanize:start-rlcr-loop <your-plan.md>`

**Why this change:**
Version 1.1.2 introduced the `--commit-plan-file` option which requires tracking the starting commit to detect accidental plan file commits. Old state files cannot support this feature safely.

Your previous round summaries and review results are still available in the loop directory for reference.
