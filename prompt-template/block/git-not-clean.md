# Git Not Clean

You are trying to stop, but you have **{{GIT_ISSUES}}**.
{{SPECIAL_NOTES}}
**Required Actions**:
0. If the `code-simplifier` plugin is installed, use it to review and simplify your code before committing. Invoke via: `/code-simplifier`, `@agent-code-simplifier`, or `@code-simplifier:code-simplifier (agent)`
1. Review untracked files - add build artifacts to `.gitignore`
2. Stage real changes: `git add <files>` (or `git add -A` if all files should be tracked)
3. Commit with a descriptive message following project conventions

**Important Rules**:
- Commit message must follow project conventions
- AI tools (Claude, Codex, etc.) must NOT have authorship in commits
- Do NOT include `Co-Authored-By: Claude` or similar AI attribution

After committing all changes, you may attempt to exit again.
