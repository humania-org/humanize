---
name: humanize-gen-idea
description: Generate a repo-grounded idea draft from loose input using directed exploration.
type: flow
user-invocable: false
disable-model-invocation: true
---

# Humanize Generate Idea

Transforms loose idea text, or a `.md` file containing an idea, into a repo-grounded draft suitable for `humanize-gen-plan`.

The installer hydrates this skill with an absolute runtime root path:

```bash
{{HUMANIZE_RUNTIME_ROOT}}
```

## Hard Constraint

This flow must only produce an idea draft. Do not implement features, modify source code, create commits, or write any file other than the final draft output selected by the validator.

## Input Requirements

Required:
- One positional idea input: inline text or path to a `.md` file

Optional:
- `--n <int>` - number of directions to explore; default is 6
- `--output <path>` - output draft path; default is resolved by the validator under `.humanize/ideas/`

## Required Sequence

### 1. Parse Arguments Safely

Extract `$ARGUMENTS` into:
- `IDEA_INPUT`
- optional `N`
- optional `OUTPUT_FILE`

Do not pass free-form idea text to the shell unquoted. Inline idea text may contain spaces or shell metacharacters and must be passed as one shell argument.

### 2. Validate IO

Run the validator from the installed runtime root:

```bash
"{{HUMANIZE_RUNTIME_ROOT}}/scripts/validate-gen-idea-io.sh" [--n N] [--output OUTPUT_FILE] "IDEA_INPUT"
```

Handle exit codes:

| Exit Code | Meaning |
|-----------|---------|
| 0 | Success; parse validator stdout and continue |
| 1 | Missing or empty idea input |
| 2 | Input looks like a file path but is missing, unreadable, or not `.md` |
| 3 | Output directory does not exist |
| 4 | Output file already exists |
| 5 | No write permission to output directory |
| 6 | Invalid arguments |
| 7 | Template file missing |

On success, parse these stdout fields:
- `INPUT_MODE`
- `OUTPUT_FILE`
- `SLUG`
- `TEMPLATE_FILE`
- `N`
- `IDEA_BODY_FILE` when `INPUT_MODE` is `file`

For inline input, extract `IDEA_BODY` from the validator's sentinel block between `=== IDEA_BODY_BEGIN ===` and `=== IDEA_BODY_END ===`. For file input, read `IDEA_BODY_FILE`. Preserve the idea body byte-identically for the final draft.

### 3. Generate Orthogonal Directions

Read repository context before proposing directions:
- `README.md`
- `CLAUDE.md`, if present
- `.claude/CLAUDE.md`, if present
- one-level top-level directory listing

Generate exactly `N` direction entries. Each entry must have:
- `name`: 2-5 words
- `rationale`: one sentence explaining why this angle is distinct

Directions must be genuinely orthogonal. If two are near-duplicates, replace one. If the first pass yields fewer than `N` directions, regenerate once. If the second pass still yields fewer than `N` but at least 2, proceed with the reduced count and report a warning. If fewer than 2 directions remain, stop with `direction generation degraded; retry.`

### 4. Explore Each Direction

For each direction, gather objective evidence from the repository. Prefer child-agent or parallel exploration only when available and permitted by the current runtime policy; otherwise perform the explorations sequentially in the current session.

Every exploration must be read-only and must return these fields:

```text
APPROACH_SUMMARY:
OBJECTIVE_EVIDENCE:
KNOWN_RISKS:
CONFIDENCE:
```

Rules for exploration:
- `OBJECTIVE_EVIDENCE` must cite concrete repository paths, prior art, or measurable considerations.
- If no concrete evidence exists, use the literal sentinel `exploratory, no concrete precedent` once.
- Do not fabricate repository references.
- `CONFIDENCE` must be one of `high`, `medium`, or `low`.
- Drop any exploration result missing one of the required fields.
- If fewer than 2 proposals survive, stop with `exploration phase degraded; retry.`

### 5. Synthesize The Draft

Choose the primary proposal using this priority:
1. Evidence density
2. Fit with existing repository patterns
3. Smaller implementation surface for otherwise comparable proposals
4. Higher declared confidence

Generate a 4-10 word Title Case title that captures the primary direction.

Read `TEMPLATE_FILE` and replace:
- `<TITLE>`
- `<ORIGINAL_IDEA>`
- `<PRIMARY_NAME>`
- `<PRIMARY_RATIONALE>`
- `<PRIMARY_APPROACH_SUMMARY>`
- `<PRIMARY_OBJECTIVE_EVIDENCE>`
- `<PRIMARY_KNOWN_RISKS>`
- `<ALTERNATIVES>`
- `<SYNTHESIS_NOTES>`

Alternative sections must use this format:

```markdown
### Alt-<i>: <name>
- Gist: <one-paragraph summary derived from APPROACH_SUMMARY>
- Objective Evidence:
  - <bullet from OBJECTIVE_EVIDENCE>
- Why not primary: <one sentence stating the tradeoff vs PRIMARY>
```

### 6. Write And Report

Write the finalized draft to `OUTPUT_FILE` in one operation. Do not write partial output if any prior phase failed.

Report:
- Path written
- Primary direction name
- Requested `N` and actual direction count
- Any warnings
- Next step: run `humanize-gen-plan` with the draft as `--input`
