---
description: "Cancel active RLCR loop"
allowed-tools: ["Bash(ls .humanize-loop.local/*/state.md:*)", "Bash(rm .humanize-loop.local/*/state.md)", "Bash(cat .humanize-loop.local/*/state.md)", "Read"]
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
   - Remove the state file(s) using: `rm .humanize-loop.local/*/state.md`
   - Report: "Cancelled RLCR loop (was at round N of M)"

The loop directory with summaries and review results will be preserved for reference.
