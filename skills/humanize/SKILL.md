---
name: humanize
description: Iterative development with AI review. Provides RLCR (Ralph-Loop with Codex Review) for implementation planning and code review loops, plus PR review automation with bot monitoring.
user-invocable: false
---

# Humanize - Iterative Development with AI Review

Humanize creates a feedback loop where AI implements your plan while another AI independently reviews the work, ensuring quality through continuous refinement.

## Runtime Root

The installer hydrates this skill with an absolute runtime root path:

```bash
{{HUMANIZE_RUNTIME_ROOT}}
```

All command examples below use `{{HUMANIZE_RUNTIME_ROOT}}`.

## Core Philosophy

**Iteration over Perfection**: Instead of expecting perfect output in one shot, Humanize leverages an iterative feedback loop where:
- AI implements your plan
- Another AI independently reviews progress
- Issues are caught and addressed early
- Work continues until all acceptance criteria are met

## Available Workflows

### 1. RLCR Loop - Iterative Development with Review

The RLCR (Ralph-Loop with Codex Review) loop has two phases:

**Phase 1: Implementation**
- AI works on the implementation plan
- AI writes a summary of work completed
- Codex reviews the summary for completeness and correctness
- If issues found → feedback loop continues
- If Codex outputs "COMPLETE" → enters Review Phase

**Phase 2: Code Review**
- `codex review --base <branch>` checks code quality
- Issues marked with `[P0-9]` severity markers
- If issues found → AI fixes them and continues
- If no issues → loop completes with Finalize Phase
- In skill mode, always run `{{HUMANIZE_RUNTIME_ROOT}}/scripts/rlcr-stop-gate.sh` to enforce hook-equivalent transitions and blocking

### 2. PR Loop - Automated PR Review Handling

Automates handling of GitHub PR reviews from remote bots:

1. Detects the PR associated with the current branch
2. Fetches review comments from specified bot(s) (`--claude` and/or `--codex`)
3. AI analyzes and fixes issues identified by the bot(s)
4. Pushes changes and triggers re-review by commenting @bot
5. Stop Hook polls for new bot reviews (every 30s, 15min timeout per bot)
6. Local Codex validates if remote concerns are resolved
7. Loop continues until all bots approve or max iterations reached

### 3. Generate Plan - Structured Plan from Draft

Transforms a rough draft document into a structured implementation plan with:
- Clear goal description
- Acceptance criteria in AC-X format with TDD-style positive/negative tests
- Path boundaries (upper/lower bounds, allowed choices)
- Feasibility hints and conceptual approach
- Dependencies and milestone sequencing

## Commands Reference

### Start RLCR Loop

```bash
# With a plan file
"{{HUMANIZE_RUNTIME_ROOT}}/scripts/setup-rlcr-loop.sh" path/to/plan.md

# Or without plan (review-only mode)
"{{HUMANIZE_RUNTIME_ROOT}}/scripts/setup-rlcr-loop.sh" --skip-impl
```

```bash
# For each round, run the RLCR gate (required)
"{{HUMANIZE_RUNTIME_ROOT}}/scripts/rlcr-stop-gate.sh"
```

**Common Options:**
- `--max N` - Maximum iterations before auto-stop (default: 42)
- `--codex-model MODEL:EFFORT` - Codex model and reasoning effort for `codex exec` (default: gpt-5.4:high)
- Review phase `codex review` uses `gpt-5.4:high`
- `--codex-timeout SECONDS` - Timeout for each Codex review (default: 5400)
- `--base-branch BRANCH` - Base branch for code review (auto-detects if not specified)
- `--full-review-round N` - Interval for full alignment checks (default: 5)
- `--skip-impl` - Skip implementation phase, go directly to code review
- `--track-plan-file` - Enforce plan-file immutability when tracked in git
- `--push-every-round` - Require git push after each round
- `--claude-answer-codex` - Let Claude answer Codex Open Questions directly (default is AskUserQuestion)
- `--agent-teams` - Enable Agent Teams mode
- `--yolo` - Skip Plan Understanding Quiz and enable --claude-answer-codex
- `--skip-quiz` - Skip the Plan Understanding Quiz only
- `--privacy` - Disable methodology analysis at loop exit (default: analysis enabled)

### Cancel RLCR Loop

```bash
"{{HUMANIZE_RUNTIME_ROOT}}/scripts/cancel-rlcr-loop.sh"
# or force cancel during finalize phase
"{{HUMANIZE_RUNTIME_ROOT}}/scripts/cancel-rlcr-loop.sh" --force
```

### Start PR Loop

```bash
# Monitor claude[bot] reviews
"{{HUMANIZE_RUNTIME_ROOT}}/scripts/setup-pr-loop.sh" --claude

# Monitor chatgpt-codex-connector[bot] reviews
"{{HUMANIZE_RUNTIME_ROOT}}/scripts/setup-pr-loop.sh" --codex

# Monitor both
"{{HUMANIZE_RUNTIME_ROOT}}/scripts/setup-pr-loop.sh" --claude --codex
```

**Common Options:**
- `--max N` - Maximum iterations (default: 42)
- `--codex-model MODEL:EFFORT` - Codex model for validation (default: gpt-5.4:medium)
- `--codex-timeout SECONDS` - Timeout for Codex validation (default: 900)

### Cancel PR Loop

```bash
"{{HUMANIZE_RUNTIME_ROOT}}/scripts/cancel-pr-loop.sh"
```

### Generate Plan from Draft

```bash
"{{HUMANIZE_RUNTIME_ROOT}}/scripts/validate-gen-plan-io.sh" --input path/to/draft.md --output path/to/plan.md
```

Then follow the workflow in this skill to generate the structured plan content.

### Ask Codex (One-shot Consultation)

```bash
"{{HUMANIZE_RUNTIME_ROOT}}/scripts/ask-codex.sh" [--codex-model MODEL:EFFORT] [--codex-timeout SECONDS] "your question"
```

## Plan File Structure

A good plan file should include:

```markdown
# Plan Title

## Goal Description
Clear description of what needs to be accomplished

## Acceptance Criteria

- AC-1: First criterion
  - Positive Tests (expected to PASS):
    - Test case that should succeed
  - Negative Tests (expected to FAIL):
    - Test case that should fail

## Path Boundaries

### Upper Bound (Maximum Scope)
Most comprehensive acceptable implementation

### Lower Bound (Minimum Scope)
Minimum viable implementation

### Allowed Choices
- Can use: technologies, approaches allowed
- Cannot use: prohibited technologies

## Dependencies and Sequence

### Milestones
1. Milestone 1: Description
   - Phase A: ...
   - Phase B: ...

## Implementation Notes
- Code should NOT contain plan terminology like "AC-", "Milestone", "Step"
```

## Goal Tracker System

The RLCR loop uses a Goal Tracker to prevent goal drift:

- **IMMUTABLE SECTION**: Ultimate Goal and Acceptance Criteria (set in Round 0, never changed)
- **MUTABLE SECTION**: Active Tasks, Completed Items, Deferred Items, Plan Evolution Log

### Key Principles

1. **Acceptance Criteria**: Each task maps to a specific AC
2. **Plan Evolution Log**: Document any plan changes with justification
3. **Explicit Deferrals**: Deferred tasks require strong justification
4. **Full Alignment Checks**: Every N rounds (default: 5), comprehensive goal alignment audit

## Important Rules

1. **Write summaries**: Always write work summary to the specified file before exiting
2. **Maintain Goal Tracker**: Keep goal-tracker.md up-to-date with progress
3. **Be thorough**: Include details about implementation, files changed, tests added
4. **No cheating**: Don't try to exit by editing state files or running cancel commands
5. **Run stop gate each round**: Use `scripts/rlcr-stop-gate.sh` instead of manual phase control
6. **Trust the process**: External review helps improve implementation quality

## Prerequisites

- `codex` - OpenAI Codex CLI (for review)
- `gh` - GitHub CLI (for PR loop)

## Directory Structure

Humanize stores all data in `.humanize/`:

```
.humanize/
├── rlcr/           # RLCR loop data
│   └── <timestamp>/
│       ├── state.md
│       ├── goal-tracker.md
│       ├── round-N-summary.md
│       ├── round-N-review-result.md
│       ├── finalize-state.md
│       ├── finalize-summary.md
│       ├── methodology-analysis-state.md
│       ├── methodology-analysis-report.md
│       ├── methodology-analysis-done.md
│       └── complete-state.md
├── pr-loop/        # PR loop data
│   └── <timestamp>/
│       ├── state.md
│       └── resolution-N.md
└── skill/          # One-shot skill results
    └── <timestamp>/
        ├── input.md
        ├── output.md
        └── metadata.md
```

## Monitoring

Use the monitor script to track loop progress:

```bash
source "{{HUMANIZE_RUNTIME_ROOT}}/scripts/humanize.sh"
humanize monitor rlcr   # Monitor RLCR loop
humanize monitor pr     # Monitor PR loop
```

## Exit Codes

### ask-codex.sh
- `0` - Success
- `1` - Validation error
- `124` - Timeout

### validate-gen-plan-io.sh
- `0` - Success
- `1` - Input file not found
- `2` - Input file is empty
- `3` - Output directory does not exist
- `4` - Output file already exists
- `5` - No write permission
- `6` - Invalid arguments
- `7` - Plan template file not found
