---
description: "Cancel active RLCR loop"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/cancel-rlcr-loop.sh)", "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/cancel-rlcr-loop.sh --force)", "AskUserQuestion"]
hide-from-slash-command-tool: "true"
---

# Cancel RLCR Loop

To cancel the active loop:

1. Run the cancel script:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/cancel-rlcr-loop.sh"
```

2. Check the first line of output:
   - **NO_LOOP** or **NO_ACTIVE_LOOP**: Say "No active RLCR loop found."
   - **CANCELLED**: Report the cancellation message from the output
   - **CANCELLED_FINALIZE**: Report the cancellation message from the output
   - **FINALIZE_NEEDS_CONFIRM**: The loop is in Finalize Phase. Continue to step 3

3. **If FINALIZE_NEEDS_CONFIRM**:
   - Use AskUserQuestion to confirm cancellation with these options:
     - Question: "The loop is currently in Finalize Phase. After this phase completes, the loop will end without returning to Codex review. Are you sure you want to cancel now?"
     - Header: "Cancel?"
     - Options:
       1. Label: "Yes, cancel now", Description: "Cancel the loop immediately, finalize-state.md will be renamed to cancel-state.md"
       2. Label: "No, let it finish", Description: "Continue with the Finalize Phase, the loop will complete normally"
   - **If user chooses "Yes, cancel now"**:
     - Run: `"${CLAUDE_PLUGIN_ROOT}/scripts/cancel-rlcr-loop.sh" --force`
     - Report the cancellation message from the output
   - **If user chooses "No, let it finish"**:
     - Report: "Understood. The Finalize Phase will continue. Once complete, the loop will end normally."

**Key principle**: The script handles all cancellation logic. A loop is active if `state.md` (normal loop) or `finalize-state.md` (Finalize Phase) exists in the newest loop directory.

The loop directory with summaries, review results, and state information will be preserved for reference.
