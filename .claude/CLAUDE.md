# Humanize Introduction
This is a Claude Code plugin that provides iterative development with Codex review. Use `/start-rlcr-loop` to start an RLCR loop, and `/cancel-rlcr-loop` to cancel an active loop.

# Humanize Project Rules
- Everything about this project, including but not limited to implementations, comments, tests and documentations should be in English. No Emoji or CJK char is allowed.
- If version bump is required, please bump them in three files: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` and `README.md` (the "Current Version" line).
- Version number must be in format of `X.Y.Z` where X/Y/Z is numeric number. Version MUST NOT include anything other than `X.Y.Z`. For example, a good version is `9.732.42`; Bad version examples (MUST NOT USE): `3.22.7-alpha` (extra "-alpha" string), `9.77.2 (2026-01-07)` (useless date/timestamp).
- The plan template in `commands/gen-plan.md` (Phase 5 Plan Structure section) and `prompt-template/plan/gen-plan-template.md` are intentionally kept in sync. When modifying either file, ensure both are updated to maintain consistency.
- Conversely, changes to `prompt-template/plan/gen-plan-template.md` must also be reflected in the Plan Structure section of `commands/gen-plan.md`.
- The directions.json schema v1 is defined in two places that must stay in sync: the jq validation expression in `scripts/validate-directions-json.sh` and the schema documentation in `commands/gen-idea.md` (Step 4.5). When adding, removing, or renaming a field in either place, update the other.
- Worker constraints (hard caps, isolation rules, no-push rule, sentinel format) are documented in four places that must stay in sync: `commands/explore-idea.md` (coordinator phases), `prompt-template/explore/worker-prompt.md` (worker instructions), `scripts/validate-explore-idea-io.sh` (cap enforcement), and `docs/usage.md` (user-facing option docs). Any change to a cap value or constraint must be reflected in all four.
