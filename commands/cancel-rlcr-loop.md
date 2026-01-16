---
description: "Cancel active RLCR loop"
allowed-tools: ["Bash(ls -1d .humanize/rlcr/*/)", "Bash(touch .humanize/rlcr/*/.cancel-requested)", "Bash(mv .humanize/rlcr/*/state.md .humanize/rlcr/*/cancel-state.md)", "Bash(cat .humanize/rlcr/*/state.md)", "Read"]
hide-from-slash-command-tool: "true"
---

# Cancel RLCR Loop

To cancel the active loop:

1. Find the current loop directory (newest timestamp):

```bash
LOOP_DIR=$(ls -1d .humanize/rlcr/*/ 2>/dev/null | sort -r | head -1)
echo "Loop dir: ${LOOP_DIR:-NONE}"
```

2. **If NONE**: Say "No active RLCR loop found."

3. Check if the current loop is active (state.md exists):

```bash
ls "${LOOP_DIR}state.md" 2>/dev/null || echo "NO_ACTIVE_LOOP"
```

4. **If NO_ACTIVE_LOOP**: Say "No active RLCR loop found. The loop directory exists but state.md is missing, indicating the loop has already ended or was never properly started."

5. **If state.md found**:
   - Read the state file to get the current round number and max iterations
   - **Create the cancel signal file first**: `touch "${LOOP_DIR}.cancel-requested"`
   - Then rename state.md to cancel-state.md: `mv "${LOOP_DIR}state.md" "${LOOP_DIR}cancel-state.md"`
   - Report: "Cancelled RLCR loop (was at round N of M). State preserved as cancel-state.md"

**Key principle**: The current loop directory is always the one with the newest timestamp. A loop is active only if `state.md` exists in that directory.

The loop directory with summaries, review results, and state information will be preserved for reference.
