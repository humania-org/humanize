---
name: ask-codex
description: One-shot consultation with Codex as an independent expert. Sends a question or task to codex exec and returns the response.
argument-hint: "[--codex-model MODEL:EFFORT] [--codex-timeout SECONDS] [question or task]"
disable-model-invocation: true
allowed-tools: "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/ask-codex.sh:*)"
---

# Ask Codex

Send a one-shot question or task to Codex and return the response.

## How to Use

Execute the ask-codex script with the user's arguments:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/ask-codex.sh" $ARGUMENTS
```

## Interpreting Output

- The script outputs Codex's response to **stdout** and status info to **stderr**
- Read the stdout output carefully and incorporate Codex's response into your answer
- If the script exits with a non-zero code, report the error to the user

## Error Handling

| Exit Code | Meaning |
|-----------|---------|
| 0 | Success - Codex response is in stdout |
| 1 | Validation error (missing codex, empty question, invalid flags) |
| 124 | Timeout - suggest using `--codex-timeout` with a larger value |
| Other | Codex process error - report the exit code and any stderr output |

## Notes

- This is a one-shot consultation, not an iterative loop
- The response is saved to `.humanize/skill/<timestamp>/output.md` for reference
- Default model is `gpt-5.3-codex:xhigh` with a 600-second timeout
