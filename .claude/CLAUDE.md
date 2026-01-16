# Humanize Introduction
This is a Claude Code plugin that provides iterative development with Codex review. Use `/start-rlcr-loop` to start an RLCR loop, and `/cancel-rlcr-loop` to cancel an active loop.

# Humanize Project Rules
- Everything about this project, including but not limited to implementations, comments, tests and documentations should be in English. No Emoji or CJK char is allowed.
- If under `main` branch, every commit MUST include a version bump in `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` and `README.md` (the "Current Version" line). If not under `main` branch, please make sure that the current branch's `version` in those three files has a incremental update compared to that of `main` branch. The `version` must be identical in those three files.
- Version number must be in format of `X.Y.Z` where X/Y/Z is numeric number. Version MUST NOT include anything other than `X.Y.Z`. For example, a good version is `9.732.42`; Bad version examples (MUST NOT USE): `3.22.7-alpha` (extra "-alpha" string), `9.77.2 (2026-01-07)` (useless date/timestamp).
