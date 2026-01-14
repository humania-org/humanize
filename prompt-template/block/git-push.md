# Git Push Blocked

Current commits should stay local - no need to push to remote.
The loop will handle commits locally until completion.

If you need to push, use `--push-every-round` when starting the loop:
```
/humanize:start-rlcr-loop plan.md --push-every-round
```
