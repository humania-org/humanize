# RLCR Loop Terminated - Branch Changed

The current HEAD (`{{CURRENT_HEAD}}`) is not a descendant of the loop's start commit (`{{START_COMMIT}}`).

**What happened:**
- You have checked out an older branch or reset to a previous commit
- The loop state is no longer valid for this commit history
- The state file has been renamed to `unexpected-state.md` to stop the loop

**Why this matters:**
The RLCR loop tracks progress against a specific commit history. When you switch to a branch that doesn't include the loop's starting point, the loop's state (round number, summaries, etc.) no longer makes sense.

**To continue working:**
1. If you want to continue the RLCR loop:
   - Checkout the original branch that contains the loop's commits
   - Rename `unexpected-state.md` back to `state.md` to resume
2. If you want to start fresh:
   - Start a new RLCR loop: `/humanize:start-rlcr-loop <your-plan.md>`
3. If you want to work without the loop:
   - Simply proceed with your work normally

Your previous round summaries and review results are still available in the loop directory for reference.
