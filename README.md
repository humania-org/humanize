# Humanize

**Current Version: 2.0.0**

> Derived from the [GAAC (GitHub-as-a-Context)](https://github.com/SihaoLiu/gaac) project.

## Overview

Humanize is a Claude Code plugin that provides two complementary iterative loops:

| Loop | Direction | Purpose |
|------|-----------|---------|
| **RLCR** | Documentation -> Implementation | Claude implements plans, Codex reviews code |
| **DCCB** | Implementation -> Documentation | Claude distills code, Codex reviews docs |

Together, these loops form a bidirectional "auto-encoder" for software systems, where documentation serves as the compressed "latent space" representation of code.

## What is RLCR?

**RLCR** stands for **Ralph-Loop with Codex Review**. It was inspired by the official [ralph-loop](https://github.com/anthropics/claude-code/tree/main/.plugins/ralph-loop) plugin, enhanced with a series of optimizations and independent Codex review capabilities.

The name can also be interpreted as **Reinforcement Learning with Code Review** - reflecting the iterative improvement cycle where AI-generated code is continuously refined through external review feedback.

A Claude Code plugin that provides iterative development with Codex review. Humanize creates a feedback loop where Claude implements your plan while Codex independently reviews the work, ensuring quality through continuous refinement.

## What is DCCB?

**DCCB** stands for **Distill Code to Conceptual Blueprint**. It is the reverse of RLCR - instead of going from documentation to implementation, DCCB goes from implementation to documentation.

The goal is to create a **Conceptual Blueprint** - a minimal, self-contained architecture document that:
- Does NOT depend on reading the actual source code
- Represents the "minimal necessary mental model" of the system
- Is sufficient to guide building a **functionally equivalent** system
- Serves as the "obligation boundary" for human understanding

### Functional Equivalence, NOT Exact Replication

**CRITICAL**: The documentation is a **general practice guide**, not a reference manual to the original code.

- A reader should be able to build a **functionally equivalent** system
- A reader does NOT need to create an exact 1:1 clone
- The documentation should NOT contain:
  - Line number references (e.g., "see line 42")
  - File path references to the original codebase
  - References that point to specific implementations
  - Anything that assumes access to the original code

This is inspired by the concept of **Reconstructive Programming** - treating documentation as a compressed representation that can be "decompressed" back into working code in ANY language or framework.

## Core Philosophy

**Iteration over Perfection**: Instead of expecting perfect output in one shot, Humanize leverages an iterative feedback loop where:
- Claude implements your plan
- Codex independently reviews progress
- Issues are caught and addressed early
- Work continues until all acceptance criteria are met

This approach provides:
- Independent review preventing blind spots
- Goal tracking to prevent drift
- Quality assurance through iteration
- Complete audit trail of development progress

## Quick Start: Iterative Development with Codex Review

### How It Works

```mermaid
flowchart LR
    Plan["Your Plan<br/>(plan.md)"] --> Claude["Claude Implements<br/>& Summarizes"]
    Claude --> Codex["Codex Reviews<br/>& Critiques"]
    Codex -->|Feedback Loop| Claude
    Codex -->|COMPLETE or max iterations| Done((Done))
```

### Step 1: Create Your Plan

Use Claude's plan mode to design your implementation. Save the plan to a markdown file:

```bash
# In Claude Code, enter plan mode and describe your task
# Claude will create a detailed plan
# Save the plan to a file, e.g., docs/my-feature-plan.md
```

Your plan file should contain:
- Clear description of what to implement
- Acceptance criteria
- Technical approach (optional but helpful)
- At least 5 lines of content

### Step 2: Run the Loop

```bash
# Basic usage - runs up to 42 iterations
/humanize:start-rlcr-loop docs/my-feature-plan.md

# Limit iterations
/humanize:start-rlcr-loop docs/my-feature-plan.md --max 10

# Custom Codex model
/humanize:start-rlcr-loop plan.md --codex-model gpt-5.2-codex:high

# Custom timeout (2 hours)
/humanize:start-rlcr-loop plan.md --codex-timeout 7200
```

### Step 3: Monitor Progress

All iteration artifacts are saved in `.humanize-loop.local/<timestamp>/`:

```bash
# View current round
cat .humanize-loop.local/*/state.md

# View Claude's latest summary
cat .humanize-loop.local/*/round-*-summary.md | tail -50

# View Codex's review feedback
cat .humanize-loop.local/*/round-*-review-result.md | tail -50
```

**Real-time Monitoring Dashboard** (Recommended):

First, source the Humanize shell utilities in your `.bashrc` or `.zshrc`:

```bash
# Auto-discover Humanize plugin location from humania marketplace
HUMANIZE_PLUGIN_ROOT=$(find ~/.claude/plugins/marketplaces -type d -name "humania" 2>/dev/null | head -1)
if [[ -n "$HUMANIZE_PLUGIN_ROOT" && -f "$HUMANIZE_PLUGIN_ROOT/scripts/humanize.sh" ]]; then
    source "$HUMANIZE_PLUGIN_ROOT/scripts/humanize.sh"
fi
```

Then run the monitor in your project directory:

```bash
humanize monitor rlcr-loop
```

This provides a real-time dashboard showing:
- Session info and round progress
- Progress summary (ACs, active/completed tasks, issues)
- Git status with file changes and line diffs
- Goal summary, plan file path, and live log output

### Step 4: Pause, Resume, or Cancel

**The loop is fully interruptible** - you can exit Claude Code at any time and resume later:

- **Loop state**: Controlled solely by the presence of `.humanize-loop.local/*/state.md`
- **Resume**: Simply restart Claude Code in the same directory - the loop continues automatically
- **Cancel**: Remove the state file to stop the loop permanently

```bash
# Cancel the active loop
/humanize:cancel-rlcr-loop

# Or manually remove state file
rm .humanize-loop.local/*/state.md
```

The loop directory with all summaries and review results is preserved for reference.

## Quick Start: Code Distillation with DCCB

### How It Works

```mermaid
flowchart LR
    Code["Your Codebase"] --> Claude["Claude Analyzes<br/>& Documents"]
    Claude --> Codex["Codex Reviews<br/>Reconstruction-Readiness"]
    Codex -->|Feedback Loop| Claude
    Codex -->|COMPLETE or max iterations| Blueprint["Conceptual<br/>Blueprint"]
```

### Step 1: Run the Loop

No plan file needed - DCCB analyzes your current codebase:

```bash
# Basic usage - runs up to 42 iterations
/humanize:start-dccb-loop

# Limit iterations
/humanize:start-dccb-loop --max 20

# Custom output directory
/humanize:start-dccb-loop --output-dir architecture-docs

# Custom Codex model
/humanize:start-dccb-loop --codex-model gpt-5.2-codex:high
```

### Step 2: Monitor Progress

All iteration artifacts are saved in `.humanize-dccb.local/<timestamp>/`:

```bash
# View current round
cat .humanize-dccb.local/*/state.md

# View Claude's latest summary
cat .humanize-dccb.local/*/round-*-summary.md | tail -50

# View Codex's review feedback
cat .humanize-dccb.local/*/round-*-review-result.md | tail -50
```

### Step 3: Review Output

Documentation is created in `dccb-doc/` (or your custom output directory). The structure is **dynamic** and adapts to the codebase:

**Small project (~1K lines):**
```
dccb-doc/
└── blueprint.md          # Everything in one file
```

**Medium project (~10K lines):**
```
dccb-doc/
├── index.md              # Overview and navigation
├── architecture.md       # System structure
├── data-models.md        # Core data concepts
├── workflows.md          # Key processes
└── interfaces.md         # External contracts
```

**Large project (~100K+ lines):**
```
dccb-doc/
├── index.md              # Top-level overview
├── core/
│   ├── index.md          # Module overview
│   ├── concepts.md       # Key abstractions
│   └── interfaces.md     # Module contracts
├── api/
│   └── ...
└── infrastructure/
    └── ...
```

### Step 4: Cancel or Complete

```bash
# Cancel the active loop
/humanize:cancel-dccb-loop

# Or manually remove state file
rm .humanize-dccb.local/*/state.md
```

The loop completes when Codex confirms the documentation is "reconstruction-ready" - meaning an AI or developer could rebuild a functionally equivalent system using only these documents.

## Blueprint Tracker System

DCCB uses a **Blueprint Tracker** to monitor documentation progress:

### Structure
- **Codebase Analysis**: Metrics and structure analysis from Round 0
- **Proposed Structure**: Documentation structure chosen based on codebase analysis
- **Reconstruction Criteria**: What makes documentation "reconstruction-ready"
- **Coverage Gaps**: Areas needing more attention
- **Review Feedback History**: Track Codex feedback across rounds

### Key Criteria for Completion

1. **Self-Contained**: Each document is understandable without reading source code
2. **Complete Coverage**: All significant modules, interfaces, and flows are documented
3. **De-Specialized**: Implementation-specific details are abstracted to concepts
4. **Consistent**: Terminology and cross-references are coherent across documents
5. **Minimal**: Only essential information for reconstruction is included
6. **Reconstructible**: An AI/developer could rebuild the system from these docs alone
7. **Appropriately Structured**: Documentation depth matches codebase complexity

## Goal Tracker System

Humanize uses a **Goal Tracker** to prevent goal drift across iterations:

### Structure
- **IMMUTABLE SECTION**: Ultimate Goal and Acceptance Criteria (set in Round 0, never changed)
- **MUTABLE SECTION**: Active Tasks, Completed Items, Deferred Items, Plan Evolution Log

### Key Features
1. **Acceptance Criteria**: Each task maps to a specific AC - nothing can be "forgotten"
2. **Plan Evolution Log**: If you discover the plan needs changes, document the change with justification
3. **Explicit Deferrals**: Deferred tasks require strong justification and impact analysis
4. **Full Alignment Checks**: At rounds 4, 9, 14, etc. (after every 4 rounds of work), Codex conducts a comprehensive goal alignment audit

### Circuit Breaker

During Full Alignment Checks, Codex can detect development stagnation and trigger a circuit breaker:
- Same issues appearing repeatedly across multiple rounds
- No meaningful progress on Acceptance Criteria
- Circular discussions without resolution

If stagnation is detected, Codex outputs "STOP" to terminate the loop and prevent wasted iterations.

## Installation

### Option 1: Install from Git Marketplace (Recommended)

Start Claude Code and run the following commands:

```bash
# Add the marketplace
/plugin marketplace add git@github.com:humania-org/humanize.git

# Install the plugin
/plugin install humanize@humania
```

### Option 2: Local Development / Testing

If you have the plugin cloned locally:

```bash
# Start Claude Code with the plugin directory
claude --plugin-dir /path/to/humanize
```

### Verify Installation

Run `/plugin` in Claude Code and check the **Installed** tab to confirm the plugin is active.

## Commands

| Command | Purpose |
|---------|---------|
| `/start-rlcr-loop <plan.md>` | Start iterative development with Codex review |
| `/cancel-rlcr-loop` | Cancel active RLCR loop |
| `/start-dccb-loop` | Start code-to-blueprint distillation with Codex review |
| `/cancel-dccb-loop` | Cancel active DCCB loop |

### RLCR Command Options

```
/humanize:start-rlcr-loop <path/to/plan.md> [OPTIONS]

OPTIONS:
  --max <N>              Maximum iterations before auto-stop (default: 42)
  --codex-model <MODEL:EFFORT>
                         Codex model and reasoning effort (default: gpt-5.2-codex:high)
  --codex-timeout <SECONDS>
                         Timeout for each Codex review in seconds (default: 5400)
  --push-every-round     Require git push after each round (default: commits stay local)
  -h, --help             Show help message
```

### DCCB Command Options

```
/humanize:start-dccb-loop [OPTIONS]

OPTIONS:
  --max <N>              Maximum iterations before auto-stop (default: 42)
  --codex-model <MODEL:EFFORT>
                         Codex model and reasoning effort (default: gpt-5.2-codex:high)
  --codex-timeout <SECONDS>
                         Timeout for each Codex review in seconds (default: 5400)
  --output-dir <DIR>     Output directory for documentation (default: dccb-doc)
  -h, --help             Show help message
```

## Prerequisites

Required tools:
- `codex` - OpenAI Codex CLI (for review)

Check if Codex is available:
```bash
codex --version
```

## Directory Structure

```
humanize/
├── .claude-plugin/
│   └── plugin.json          # Plugin manifest
├── .claude/
│   └── CLAUDE.md            # Project rules
├── commands/                 # Slash commands
│   ├── start-rlcr-loop.md   # RLCR loop start command
│   ├── cancel-rlcr-loop.md  # RLCR loop cancel command
│   ├── start-dccb-loop.md   # DCCB loop start command
│   └── cancel-dccb-loop.md  # DCCB loop cancel command
├── hooks/                    # Lifecycle hooks
│   ├── hooks.json
│   ├── loop-codex-stop-hook.sh   # RLCR stop hook
│   ├── loop-dccb-stop-hook.sh    # DCCB stop hook
│   ├── loop-write-validator.sh
│   ├── loop-edit-validator.sh
│   ├── loop-read-validator.sh
│   ├── loop-bash-validator.sh
│   ├── check-todos-from-transcript.py
│   └── lib/
│       └── loop-common.sh
├── scripts/                  # Setup scripts
│   ├── setup-rlcr-loop.sh   # RLCR initialization
│   ├── setup-dccb-loop.sh   # DCCB initialization
│   ├── portable-timeout.sh
│   └── humanize.sh           # Shell utilities (monitor command)
├── .gitignore
└── README.md
```

## State Directory Structure

### RLCR State

When RLCR loop is active, creates: `.humanize-loop.local/<TIMESTAMP>/`

**Files Created**:
- `state.md` - Current round, config (YAML frontmatter)
- `goal-tracker.md` - Immutable (goals/AC) + Mutable (active tasks, deferred, etc.)
- `round-N-prompt.md` - Instructions FROM Codex TO Claude
- `round-N-summary.md` - Work summary written BY Claude
- `round-N-review-prompt.md` - Prompt sent to Codex
- `round-N-review-result.md` - Codex's review output

**Cache Directory** (not in project):
- `$HOME/.cache/humanize/<sanitized-project-path>/<timestamp>/`
  - `round-N-codex-run.cmd` - Command invoked
  - `round-N-codex-run.out` - Codex stdout
  - `round-N-codex-run.log` - Codex stderr

### DCCB State

When DCCB loop is active, creates: `.humanize-dccb.local/<TIMESTAMP>/`

**Files Created**:
- `state.md` - Current round, config (YAML frontmatter)
- `blueprint-tracker.md` - Codebase analysis, proposed structure, progress tracking
- `round-N-prompt.md` - Instructions FROM Codex TO Claude
- `round-N-summary.md` - Work summary written BY Claude
- `round-N-review-prompt.md` - Prompt sent to Codex
- `round-N-review-result.md` - Codex's review output

**Output Directory** (in project):
- `dccb-doc/` (or custom via `--output-dir`)
  - Structure is **dynamic** based on codebase analysis
  - Small projects: single `blueprint.md`
  - Large projects: hierarchical with subdirectories mirroring codebase

**Cache Directory** (not in project):
- `$HOME/.cache/humanize-dccb/<sanitized-project-path>/<timestamp>/`
  - `round-N-codex-run.cmd` - Command invoked
  - `round-N-codex-run.out` - Codex stdout
  - `round-N-codex-run.log` - Codex stderr

## Design Principles

### Shared Principles
1. **Iteration over Perfection**: Use review loops to refine work
2. **Independent Review**: Codex provides unbiased feedback
3. **Circuit Breaker**: Detect and stop stagnating development

### RLCR Principles
4. **Goal Tracking**: Prevent drift with immutable acceptance criteria
5. **Explicit Deferrals**: Every deferred task requires justification

### DCCB Principles
6. **Self-Containment**: Documentation must be readable without code
7. **De-Specialization**: Abstract implementation to concepts
8. **Reconstruction-Readiness**: Documentation enables rebuilding the system

## License

MIT

## Credits

- Claude Code: [Anthropic](https://github.com/anthropics/claude-code)
