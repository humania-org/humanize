# Bitter Lesson Workflow

BitLesson is the repository's Bitter Lesson-style knowledge capture system for RLCR rounds.

## Configuration

The selector reads `bitlesson_model` from the merged config hierarchy:

1. `config/default_config.json`
2. `~/.config/humanize/config.json`
3. `.humanize/config.json`
4. CLI flags where applicable

Provider routing is automatic:

- `gpt-*`, `o1-*`, `o3-*` route to Codex
- `claude-*`, `haiku`, `sonnet`, `opus` route to Claude

If the configured provider binary is missing, the selector falls back to the default Codex model so the loop can still proceed.

## Workflow

Each project keeps its BitLesson knowledge base at `.humanize/bitlesson.md`.

When `start-rlcr-loop` begins:

1. The file is initialized from `templates/bitlesson.md` if it does not already exist
2. Each task or sub-task runs through `scripts/bitlesson-select.sh`
3. The selected lesson IDs are applied during implementation, or `NONE` is recorded when nothing matches
4. The stop gate validates a required `## BitLesson Delta` section in every round summary

## Summary Contract

Required summary shape:

```markdown
## BitLesson Delta
- Action: none|add|update
- Lesson ID(s): <IDs or NONE>
- Notes: <what changed and why>
```

Validation rules are strict:

- `Action: none` must use `Lesson ID(s): NONE` or leave the field empty
- `Action: add` and `Action: update` must reference concrete `BL-YYYYMMDD-short-name` IDs that exist in `.humanize/bitlesson.md`
- `--require-bitlesson-entry-for-none` can be used to block empty knowledge bases from repeatedly reporting `none`
