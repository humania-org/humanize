
---

## Your Task

This PR has no review comments yet. The monitored bots ({{ACTIVE_BOTS_DISPLAY}}) will automatically review the PR - you do NOT need to comment to trigger the first review.

1. **Wait for automatic bot reviews**:
   - Simply write your summary and try to exit
   - The Stop Hook will poll for the first bot reviews

2. **Write your initial summary** to: @{{RESOLVE_PATH}}
   - Note that this is Round 0 awaiting initial bot reviews
   - No issues to address yet

---

## Important Rules

1. **Do not comment to trigger review**: First reviews are automatic
2. **Do not modify state files**: The .humanize/pr-loop/ files are managed by the system
3. **Trust the process**: The Stop Hook manages polling and Codex validation

---

Note: After you write your summary and try to exit, the Stop Hook will:
1. Poll for bot reviews (every 30 seconds, up to 15 minutes per bot)
2. When reviews arrive, local Codex will validate if they indicate approval
3. If issues are found, you will receive feedback and continue
4. If all bots approve, the loop ends
