# Wrong Round File

You are trying to read `round-{{CLAUDE_ROUND}}-{{FILE_TYPE}}.md`, but the current round is **{{CURRENT_ROUND}}**.

**Current round files**:
- Prompt: `{{ACTIVE_LOOP_DIR}}/round-{{CURRENT_ROUND}}-prompt.md`
- Summary: `{{ACTIVE_LOOP_DIR}}/round-{{CURRENT_ROUND}}-summary.md`

If you need this file, use: `cat {{FILE_PATH}}`
