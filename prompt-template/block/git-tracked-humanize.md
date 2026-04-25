# Tracked Humanize State Blocked

Detected tracked or staged files under `.humanize/`.

These files are local Humanize loop state and must remain outside version control.

## Required Fix

1. Remove Humanize state from the index:

       git rm --cached -r .humanize

2. Keep only real project files staged.
3. Retry the stop action after the local state is no longer tracked.

## Important

- Do NOT use `git add -f` on Humanize state files.
- Do NOT commit RLCR trackers, round summaries, contracts, or cancel/finalize markers.
