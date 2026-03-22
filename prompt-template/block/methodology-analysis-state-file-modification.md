# Methodology Analysis State File Modification Blocked

You cannot modify `methodology-analysis-state.md`. This file is managed by the loop system during the Methodology Analysis Phase.

The Methodology Analysis Phase runs before the loop fully exits. Focus on:
1. Spawning an Opus agent to analyze development records
2. Reviewing the sanitized analysis report
3. Optionally helping the user file a GitHub issue with improvement suggestions
4. Writing your completion marker to `methodology-analysis-done.md`
