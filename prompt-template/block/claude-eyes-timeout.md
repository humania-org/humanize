# Claude Bot Not Responding

The Claude bot did not respond with an 'eyes' reaction after **{{RETRY_COUNT}} retries** ({{TOTAL_WAIT_SECONDS}} seconds total).

**Possible causes**:
1. The remote repository does not have the Claude bot configured
2. The Claude bot is experiencing issues or downtime
3. The bot does not have permissions on this repository

**Required Actions**:
1. Verify the Claude bot is installed on the remote repository
2. Check that the bot has appropriate permissions
3. Ensure the PR is in a state where the bot can respond

**To configure Claude bot**:
Visit the repository settings and ensure the Claude GitHub App is installed and has access to this repository.

Once the bot is properly configured, post a new trigger comment to restart the review.
