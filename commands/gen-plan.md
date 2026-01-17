---
description: "Generate implementation plan from draft document"
argument-hint: "--input <path/to/draft.md> --output <path/to/plan.md>"
allowed-tools: ["Skill(humanize:gen-plan:*)"]
hide-from-slash-command-tool: "true"
---

# Generate Plan

This command delegates to the `humanize:gen-plan` skill.

Use the Skill tool to invoke the skill with the provided arguments:

```
Skill: humanize:gen-plan
Arguments: $ARGUMENTS
```

The skill contains the full instructions for transforming a draft into a structured implementation plan.
