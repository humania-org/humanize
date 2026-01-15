# Humanize Introduction
This is a Claude Code plugin that provides iterative development with Codex review. Use `/start-rlcr-loop` to start an RLCR loop, and `/cancel-rlcr-loop` to cancel an active loop.

# Humanize Project Rules
- Everything about this project, including but not limited to implementations, comments, tests and documentations should be in English. No Emoji or CJK char is allowed.
- **Version Update Rules**:
  - **On feature branches** (not `main` or `master`): No need to bump version on every commit. However, ensure the branch has an incremental version update compared to the default main branch before merging.
  - **On default branch** (`main` or `master`): Every commit MUST include a version bump in `.claude-plugin/plugin.json` and `README.md` (the "Current Version" line). Increment the patch version (e.g., 1.0.0 -> 1.0.1, 1.0.9 -> 1.1.0, 3.4.7 -> 4.0.0) for each commit.
- Every `git push` or `git commit` MUST confirm with user first, MUST NOT commit or push to remote without check with user.
- Version number must be in format of `X.Y.Z` where X/Y/Z is numeric number. Version MUST NOT include anything other than `X.Y.Z`. For example, a good version is `9.732.42`; Bad version examples (MUST NOT USE): `3.22.7-alpha` (extra "-alpha" string), `9.77.2 (2026-01-07)` (useless date/timestamp).
