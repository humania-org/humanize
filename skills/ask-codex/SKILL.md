---
name: ask-codex
description: Consult Codex as an independent expert. Sends a question or task to codex exec and returns the response.
argument-hint: "[--codex-model MODEL:EFFORT] [--codex-timeout SECONDS] [question or task]"
allowed-tools: "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/ask-codex.sh:*)"
---

# Ask Codex

Send a question or task to Codex and return the response.

## How to Use

Do not pass free-form user text to the shell unquoted. The question or task may contain spaces or shell metacharacters such as `(`, `)`, `;`, `#`, `*`, or `[`.

If the user only supplied a question or task, execute:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/ask-codex.sh" "$ARGUMENTS"
```

If the user supplied flags such as `--codex-model` or `--codex-timeout`, reconstruct the command so those flags remain separate shell arguments and the remaining free-form question is passed as one quoted final argument.

Example:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/ask-codex.sh" --codex-model gpt-5.4:high "Review the following round summary (M4)..."
```

Never run this unsafe form:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/ask-codex.sh" $ARGUMENTS
```

because the shell will re-parse the question text and can fail before `ask-codex.sh` starts.

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

- The response is saved to `.humanize/skill/<timestamp>/output.md` for reference
- Default model is `gpt-5.4:high` with a 3600-second timeout
