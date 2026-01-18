# Humanize

**Current Version: 1.3.3**

> Derived from the [GAAC (GitHub-as-a-Context)](https://github.com/SihaoLiu/gaac) project.

## What is RLCR?

**RLCR** stands for **Ralph-Loop with Codex Review**. It was inspired by the official [ralph-loop](https://github.com/anthropics/claude-code/tree/main/.plugins/ralph-loop) plugin, enhanced with a series of optimizations and independent Codex review capabilities.

The name can also be interpreted as **Reinforcement Learning with Code Review** - reflecting the iterative improvement cycle where AI-generated code is continuously refined through external review feedback.

A Claude Code plugin that provides iterative development with Codex review. Humanize creates a feedback loop where Claude implements your plan while Codex independently reviews the work, ensuring quality through continuous refinement.

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

### Prerequisites

- `codex` - OpenAI Codex CLI (for review). Check with `codex --version`.

## Usage

### How It Works

```mermaid
flowchart LR
    Plan["Your Plan<br/>(plan.md)"] --> Claude["Claude Implements<br/>& Summarizes"]
    Claude --> Codex["Codex Reviews<br/>& Critiques"]
    Codex -->|Feedback Loop| Claude
    Codex -->|COMPLETE or max iterations| Done((Done))
```

### Quick Start

1. **Create a plan file** with clear description, acceptance criteria, and technical approach
2. **Run the loop**:
   ```bash
   /humanize:start-rlcr-loop docs/my-feature-plan.md
   ```
3. **Monitor progress** in `.humanize/rlcr/<timestamp>/`
4. **Cancel if needed**: `/humanize:cancel-rlcr-loop`

### Commands

| Command | Purpose |
|---------|---------|
| `/start-rlcr-loop <plan.md>` | Start iterative development with Codex review |
| `/cancel-rlcr-loop` | Cancel active loop |
| `/gen-plan --input <draft.md> --output <plan.md>` | Generate structured plan from draft |

### Command Options

#### start-rlcr-loop

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

#### gen-plan

```
/humanize:gen-plan --input <path/to/draft.md> --output <path/to/plan.md>

OPTIONS:
  --input   Path to the input draft file (required)
  --output  Path to the output plan file (required)

The gen-plan command transforms rough draft documents into structured implementation plans.

Workflow:
1. Validates input/output paths
2. Checks if draft is relevant to the repository
3. Analyzes draft for clarity, consistency, completeness, and functionality
4. Engages user to resolve any issues found
5. Generates a structured plan.md with AC-X acceptance criteria
```

## License

MIT

## Credits

- Claude Code: [Anthropic](https://github.com/anthropics/claude-code)
