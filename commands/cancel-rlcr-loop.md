---
description: "Cancel active RLCR loop"
allowed-tools: ["Bash(ls .humanize-loop.local/*/state.md:*)", "Bash(mv .humanize-loop.local/*/state.md .humanize-loop.local/*/cancel-state.md)", "Bash(cat .humanize-loop.local/*/state.md)", "Read"]
hide-from-slash-command-tool: "true"
---

# Cancel RLCR Loop

To cancel the active loop:

1. Check if any loop is active by looking for state files:

```bash
ls .humanize-loop.local/*/state.md 2>/dev/null || echo "NO_LOOP"
```

2. **If NO_LOOP**: Say "No active RLCR loop found."

3. **If state file(s) found**:
   - Read the state file to get the current round number
   - Rename the state file to cancel-state.md using: `mv .humanize-loop.local/*/state.md .humanize-loop.local/*/cancel-state.md`
   - Report: "Cancelled RLCR loop (was at round N of M). State preserved as cancel-state.md"

The loop directory with summaries, review results, and state information will be preserved for reference.
