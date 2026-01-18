# Git Add Blocked: .humanize Protection

The `.humanize/` directory contains local loop state that should NOT be committed.
This directory is already listed in `.gitignore`.

Your command was blocked because it would add .humanize files to version control.

## Allowed Commands

Use specific file paths instead of broad patterns:

    git add <specific-file>
    git add src/
    git add -p  # patch mode

## Blocked Commands

These commands are blocked when .humanize exists:

    git add .humanize      # direct reference
    git add -A             # adds all including .humanize
    git add --all          # adds all including .humanize
    git add .              # may include .humanize if not gitignored
    git add -f .           # force bypasses gitignore

## Adding .humanize to .gitignore

If you need to add `.humanize*` to `.gitignore`, follow these steps:

1. Edit `.gitignore` to append `.humanize*`
2. Run: `git add .gitignore`
3. Run: `git commit -m "Add humanize local folder into gitignore"`

IMPORTANT: The commit message must NOT contain the literal string ".humanize" to avoid triggering this protection.
