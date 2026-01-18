
===========================================
CRITICAL - Work Completion Requirements
===========================================

When you complete your work, you MUST:

1. COMMIT and PUSH your changes:
   - Create a commit with descriptive message
   - Push to the remote repository

2. Comment on the PR to trigger re-review:
   gh pr comment {{PR_NUMBER}} --body "{{BOT_MENTION_STRING}} please review"

3. Write your resolution summary to:
   {{RESOLVE_PATH}}

   The summary should include:
   - Issues addressed
   - Files modified
   - Tests added (if any)

The Stop Hook will then poll for bot reviews.
===========================================
