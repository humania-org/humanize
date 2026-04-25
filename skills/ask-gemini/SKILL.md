---
name: ask-gemini
description: Consult Gemini as an independent expert with deep web research. Sends a question or task to Gemini CLI and returns a research-backed response.
argument-hint: "[--gemini-model MODEL] [--gemini-timeout SECONDS] [question or task]"
allowed-tools: "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/ask-gemini.sh:*)"
---

# Ask Gemini

Send a question or task to Gemini and return a research-backed response.
Gemini is always instructed to perform web research via Google Search,
making this ideal for deep-research tasks that benefit from up-to-date
internet information.

## How to Use

Do not pass free-form user text to the shell unquoted. The question or task may contain spaces or shell metacharacters such as `(`, `)`, `;`, `#`, `*`, or `[`.

If the user only supplied a question or task, execute:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/ask-gemini.sh" "$ARGUMENTS"
```

If the user supplied flags such as `--gemini-model` or `--gemini-timeout`, reconstruct the command so those flags remain separate shell arguments and the remaining free-form question is passed as one quoted final argument.

Example:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/ask-gemini.sh" --gemini-model gemini-2.5-pro "What are the latest Rust async runtime benchmarks?"
```

Never run this unsafe form:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/ask-gemini.sh" $ARGUMENTS
```

because the shell will re-parse the question text and can fail before `ask-gemini.sh` starts.

## Interpreting Output

- The script outputs Gemini's response to **stdout** and status info to **stderr**
- Read the stdout output carefully and incorporate Gemini's response into your answer
- Gemini's responses are research-backed with web sources; relay source citations when available
- If the script exits with a non-zero code, report the error to the user

## Error Handling

| Exit Code | Meaning |
|-----------|---------|
| 0 | Success - Gemini response is in stdout |
| 1 | Validation error (missing gemini, empty question, invalid flags) |
| 124 | Timeout - suggest using `--gemini-timeout` with a larger value |
| Other | Gemini process error - report the exit code and any stderr output |

## Notes

- The response is saved to `.humanize/skill/<timestamp>/output.md` for reference
- Default model is `gemini-3.1-pro-preview` with a 3600-second timeout
- Gemini is always instructed to perform Google Search for up-to-date information
