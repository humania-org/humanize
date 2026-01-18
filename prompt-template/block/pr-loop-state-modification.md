# PR Loop State File Modification Blocked

You cannot modify `state.md` in `.humanize/pr-loop/`. This file is managed by the PR loop system.

The state file contains:
- Current round number
- PR number and branch
- Active bots configuration
- Codex configuration
- Polling settings

Modifying it would corrupt the PR loop state.
