---
description: "Cancel active DCCB loop"
allowed-tools: ["Bash(ls .humanize-dccb.local/*/state.md:*)", "Bash(rm .humanize-dccb.local/*/state.md)", "Bash(cat .humanize-dccb.local/*/state.md)", "Read"]
hide-from-slash-command-tool: "true"
---

# Cancel DCCB Loop

To cancel the active loop:

1. Check if any loop is active by looking for state files:

```bash
ls .humanize-dccb.local/*/state.md 2>/dev/null || echo "NO_LOOP"
```

2. **If NO_LOOP**: Say "No active DCCB loop found."

3. **If state file(s) found**:
   - Read the state file to get the current round number
   - Remove the state file(s) using: `rm .humanize-dccb.local/*/state.md`
   - Report: "Cancelled DCCB loop (was at round N of M)"

The loop directory with documentation drafts and review results will be preserved for reference.
