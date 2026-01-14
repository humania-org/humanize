# Wrong File Location

You are trying to read `{{FILE_PATH}}`, but loop files are in `{{ACTIVE_LOOP_DIR}}/`.

**Current round files**:
- Prompt: `{{ACTIVE_LOOP_DIR}}/round-{{CURRENT_ROUND}}-prompt.md`
- Summary: `{{ACTIVE_LOOP_DIR}}/round-{{CURRENT_ROUND}}-summary.md`

If you need this file, use: `cat {{FILE_PATH}}`
