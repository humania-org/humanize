---
description: "Start PR review loop with bot monitoring"
argument-hint: "--claude|--chatgpt-codex-connector [--max N] [--codex-model MODEL:EFFORT] [--codex-timeout SECONDS]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-pr-loop.sh:*)"]
hide-from-slash-command-tool: "true"
---

# Start PR Loop

Execute the setup script to initialize the PR review loop:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-pr-loop.sh" $ARGUMENTS
```

This command starts a PR review loop that:

1. Detects the PR associated with the current branch
2. Fetches review comments from the specified bot(s)
3. You analyze and fix issues identified by the bot(s)
4. Push changes and trigger re-review by commenting @bot
5. Stop Hook polls for new bot reviews (every 30s, 15min timeout)
6. Local Codex validates if remote concerns are valid or approved

## Bot Flags (Required)

At least one bot flag is required:
- `--claude` - Monitor reviews from claude[bot]
- `--chatgpt-codex-connector` - Monitor reviews from chatgpt-codex-connector[bot]

## Comment Prioritization

Comments are processed in this order:
1. **Human comments first** - They always take precedence over bots
2. **Bot comments** - Newest comments analyzed first

## Workflow

1. Analyze PR comments and fix issues
2. Commit and push changes
3. Comment on PR to trigger re-review using the bot mentions shown in the prompt
4. Write resolution summary to the specified file
5. Try to exit - Stop Hook intercepts and polls for bot reviews
6. If issues remain, receive feedback and continue
7. If all bots approve, loop ends

**Note:** The setup script provides the exact mention string to use (e.g., `@claude @chatgpt-codex-connector`).
Use whatever bot mentions are shown in the initial prompt - they match the flags you provided.

## Important Rules

1. **Write summaries**: Always write your resolution summary to the specified file before exiting
2. **Push changes**: Your fixes must be pushed for bots to review them
3. **Tag bots**: Use the correct @mention format to trigger bot reviews
4. **No cheating**: Do not try to exit the loop by editing state files or running cancel commands
5. **Trust the process**: The Stop Hook manages polling and Codex validation

## Stopping the Loop

- Reach the maximum iteration count
- All monitored bots approve the changes
- User runs `/humanize:cancel-pr-loop`
