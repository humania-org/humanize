# Force Push Detected

A **force push** has been detected on this PR. The commit SHA changed from `{{OLD_COMMIT}}` to `{{NEW_COMMIT}}` in a non-fast-forward manner.

Force pushes reset the review state because the commit history has been rewritten.

**Required Actions**:
1. The PR loop has updated its tracking to the new commit SHA
2. You must post a new trigger comment to restart the review cycle
3. Post a comment mentioning {{BOT_MENTION_STRING}} to trigger a new review

**Example trigger comment**:
```
{{BOT_MENTION_STRING}} Please review these changes.
```

After posting a trigger comment, you may attempt to continue.
