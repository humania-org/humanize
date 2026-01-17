---
name: cancel-rlcr-loop
description: Cancel active RLCR loop. Use when stopping a running development loop, cancelling Codex review iteration, or when the user wants to exit the RLCR workflow early.
model: claude-opus-4-5-20250514
allowed-tools:
  - Bash(ls -1d .humanize/rlcr/*/)
  - Bash(touch .humanize/rlcr/*/.cancel-requested)
  - Bash(mv .humanize/rlcr/*/state.md .humanize/rlcr/*/cancel-state.md)
  - Bash(mv .humanize/rlcr/*/finalize-state.md .humanize/rlcr/*/cancel-state.md)
  - Bash(cat .humanize/rlcr/*/state.md)
  - Bash(cat .humanize/rlcr/*/finalize-state.md)
  - Read
  - AskUserQuestion
---

# Cancel RLCR Loop

To cancel the active loop:

1. Find the current loop directory (newest timestamp):

```bash
LOOP_DIR=$(ls -1d .humanize/rlcr/*/ 2>/dev/null | sort -r | head -1)
echo "Loop dir: ${LOOP_DIR:-NONE}"
```

2. **If NONE**: Say "No active RLCR loop found."

3. Check if the current loop is active (state.md or finalize-state.md exists):

```bash
ls "${LOOP_DIR}state.md" 2>/dev/null && echo "NORMAL_LOOP" || ls "${LOOP_DIR}finalize-state.md" 2>/dev/null && echo "FINALIZE_PHASE" || echo "NO_ACTIVE_LOOP"
```

4. **If NO_ACTIVE_LOOP**: Say "No active RLCR loop found. The loop directory exists but no active state file is present, indicating the loop has already ended or was never properly started."

5. **If NORMAL_LOOP (state.md found)**:
   - Read the state file to get the current round number and max iterations
   - **Create the cancel signal file first**: `touch "${LOOP_DIR}.cancel-requested"`
   - Then rename state.md to cancel-state.md: `mv "${LOOP_DIR}state.md" "${LOOP_DIR}cancel-state.md"`
   - Report: "Cancelled RLCR loop (was at round N of M). State preserved as cancel-state.md"

6. **If FINALIZE_PHASE (finalize-state.md found)**:
   - Read the finalize-state file to get the current round number and max iterations
   - Use AskUserQuestion to confirm cancellation with these options:
     - Question: "The loop is currently in Finalize Phase. After this phase completes, the loop will end without returning to Codex review. Are you sure you want to cancel now?"
     - Header: "Cancel?"
     - Options:
       1. Label: "Yes, cancel now", Description: "Cancel the loop immediately, finalize-state.md will be renamed to cancel-state.md"
       2. Label: "No, let it finish", Description: "Continue with the Finalize Phase, the loop will complete normally"
   - **If user chooses "Yes, cancel now"**:
     - Create the cancel signal file: `touch "${LOOP_DIR}.cancel-requested"`
     - Rename finalize-state.md to cancel-state.md: `mv "${LOOP_DIR}finalize-state.md" "${LOOP_DIR}cancel-state.md"`
     - Report: "Cancelled RLCR loop during Finalize Phase (was at round N of M). State preserved as cancel-state.md"
   - **If user chooses "No, let it finish"**:
     - Report: "Understood. The Finalize Phase will continue. Once complete, the loop will end normally."

**Key principle**: The current loop directory is always the one with the newest timestamp. A loop is active if `state.md` (normal loop) or `finalize-state.md` (Finalize Phase) exists in that directory.

The loop directory with summaries, review results, and state information will be preserved for reference.
