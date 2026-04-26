---
name: humanize-gen-idea
description: Generate a repo-grounded idea draft from a loose prompt or notes file using directed exploration.
type: flow
user-invocable: false
disable-model-invocation: true
---

# Humanize Generate Idea

Use this flow as the Codex/Kimi entrypoint for turning a loose idea into a draft document that can feed `humanize-gen-plan`.

## Runtime Root

The installer hydrates this skill with an absolute runtime root path:

```bash
{{HUMANIZE_RUNTIME_ROOT}}
```

All commands below assume `{{HUMANIZE_RUNTIME_ROOT}}`.

## Required Sequence

### 1. Validate and Parse Input

Run the validator first:

```bash
"{{HUMANIZE_RUNTIME_ROOT}}/scripts/validate-gen-idea-io.sh" ...
```

Reconstruct argv safely:
- Keep `--n` and `--output` as separate shell arguments.
- Pass inline idea text as one quoted argument.
- Never rely on unsafe shell word-splitting for the free-form idea text.

On success, parse these keys from stdout:
- `INPUT_MODE`
- `OUTPUT_FILE`
- `SLUG`
- `TEMPLATE_FILE`
- `N`
- `IDEA_BODY_FILE` when `INPUT_MODE=file`

Preserve the idea body exactly:
- `inline`: extract the text between `=== IDEA_BODY_BEGIN ===` and `=== IDEA_BODY_END ===`
- `file`: read the entire contents of `IDEA_BODY_FILE`

If validation exits non-zero, stop and report the corresponding error.

### 2. Gather Repo Context

Ground the draft in the current repository before ideating:
- Read the repo `README.md`
- Read `CLAUDE.md` if present
- Read `.claude/CLAUDE.md` if present
- Inspect the top-level directory listing

### 3. Generate Orthogonal Directions

Generate exactly `N` distinct directions for exploring the idea.

Each direction must include:
- `name`: 2-5 words
- `rationale`: one sentence explaining why this angle is meaningfully different

If two directions are near-duplicates, replace one with a genuinely different angle.

### 4. Explore Each Direction

For each direction, gather objective evidence from the repo. Prefer parallel read-only exploration when your runtime supports it; otherwise do the same work sequentially.

Each proposal must contain exactly these fields:
- `APPROACH_SUMMARY`
- `OBJECTIVE_EVIDENCE`
- `KNOWN_RISKS`
- `CONFIDENCE` (`high`, `medium`, or `low`)

`OBJECTIVE_EVIDENCE` must use concrete repo paths or precedents. If no concrete evidence exists, record the literal sentinel:

```text
exploratory, no concrete precedent
```

### 5. Synthesize and Write the Draft

Choose the primary direction by:
1. Evidence density
2. Fit with existing repo patterns
3. Smaller implementation surface when quality is otherwise similar
4. `CONFIDENCE` as a tiebreaker

Write exactly one draft file to `OUTPUT_FILE`, using `TEMPLATE_FILE` as the structural contract. The draft should include:
- Title
- Original idea
- One primary direction
- Alternative directions considered
- Synthesis notes

Do not modify source code or write any file other than the draft output.

## Validation Exit Codes

| Exit Code | Meaning |
|-----------|---------|
| 0 | Success - continue |
| 1 | Missing idea input or empty input file |
| 2 | Input looks like a file path but is missing, unreadable, or not `.md` |
| 3 | Output directory does not exist |
| 4 | Output file already exists |
| 5 | No write permission to output directory |
| 6 | Invalid arguments |
| 7 | Idea template file not found |

## Usage

```bash
# Start the flow with inline text
/flow:humanize-gen-idea "add undo/redo to the editor"

# Or expand an existing notes file
/flow:humanize-gen-idea docs/idea.md --n 6

# Load as a standard skill only
/skill:humanize-gen-idea
```
