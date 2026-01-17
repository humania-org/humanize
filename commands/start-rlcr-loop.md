---
description: "Start iterative loop with Codex review"
argument-hint: "<path/to/plan.md> [--max N] [--codex-model MODEL:EFFORT] [--codex-timeout SECONDS] [--push-every-round]"
allowed-tools: ["Skill(humanize:start-rlcr-loop:*)"]
hide-from-slash-command-tool: "true"
---

# Start RLCR Loop

This command delegates to the `humanize:start-rlcr-loop` skill.

Use the Skill tool to invoke the skill with the provided arguments:

```
Skill: humanize:start-rlcr-loop
Arguments: $ARGUMENTS
```

The skill contains the full instructions for initializing and running the RLCR workflow.
