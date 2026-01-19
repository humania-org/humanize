
---

## Your Task

1. **Analyze the comments above**, prioritizing:
   - Human comments first (they take precedence)
   - Bot comments (newest first)

2. **Fix any issues** identified by the reviewers:
   - Read the relevant code files
   - Make necessary changes
   - Create appropriate tests if needed

3. **After fixing issues**:
   - Commit your changes with a descriptive message
   - Push to the remote repository
   - Comment on the PR to trigger re-review:
     ```bash
     gh pr comment {{PR_NUMBER}} --body "{{BOT_MENTION_STRING}} please review the latest changes"
     ```

4. **Write your resolution summary** to: @{{RESOLVE_PATH}}
   - List what issues were addressed
   - Files modified
   - Tests added (if any)

---

## Important Rules

1. **Do not modify state files**: The .humanize/pr-loop/ files are managed by the system
2. **Always push changes**: Your fixes must be pushed for bots to review them
3. **Use the correct comment format**: Tag the bots to trigger their reviews
4. **Be thorough**: Address all valid concerns from the reviewers

---

Note: After you write your summary and try to exit, the Stop Hook will:
1. Poll for new bot reviews (every 30 seconds, up to 15 minutes per bot)
2. When reviews arrive, local Codex will validate if they indicate approval
3. If issues remain, you will receive feedback and continue
4. If all bots approve, the loop ends
