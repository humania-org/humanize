---
description: "Cancel active PR loop"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/cancel-pr-loop.sh)", "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/cancel-pr-loop.sh --force)"]
hide-from-slash-command-tool: "true"
---

# Cancel PR Loop

To cancel the active PR loop:

1. Run the cancel script:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/cancel-pr-loop.sh"
```

2. Check the first line of output:
   - **NO_LOOP** or **NO_ACTIVE_LOOP**: Say "No active PR loop found."
   - **CANCELLED**: Report the cancellation message from the output

**Key principle**: The script handles all cancellation logic. A PR loop is active if `state.md` exists in the newest PR loop directory (.humanize/pr-loop/).

The loop directory with comments, resolution summaries, and state information will be preserved for reference.

**Note**: This command only affects PR loops. RLCR loops (.humanize/rlcr/) are not affected. Use `/humanize:cancel-rlcr-loop` to cancel RLCR loops.
