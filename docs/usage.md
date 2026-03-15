# Humanize Usage Guide

Detailed usage documentation for the Humanize plugin. For installation, see [Install for Claude Code](install-for-claude.md).

## How It Works

Humanize creates an iterative feedback loop with two phases:

1. **Implementation Phase**: Claude works on your plan, Codex reviews summaries until COMPLETE
2. **Review Phase**: `codex review --base <branch>` checks code quality with `[P0-9]` severity markers

The loop continues until all acceptance criteria are met or no issues remain.

## Commands

| Command | Purpose |
|---------|---------|
| `/start-rlcr-loop <plan.md>` | Start iterative development with Codex review |
| `/cancel-rlcr-loop` | Cancel active loop |
| `/gen-plan --input <draft.md> --output <plan.md>` | Generate structured plan from draft |
| `/refine-plan --input <annotated-plan.md>` | Refine an annotated plan and generate a QA ledger |
| `/start-pr-loop --claude\|--codex` | Start PR review loop with bot monitoring |
| `/cancel-pr-loop` | Cancel active PR loop |
| `/ask-codex [question]` | One-shot consultation with Codex |

## Command Reference

### start-rlcr-loop

```
/humanize:start-rlcr-loop [path/to/plan.md | --plan-file path/to/plan.md] [OPTIONS]

OPTIONS:
  --plan-file <path>     Explicit plan file path (alternative to positional arg)
  --max <N>              Maximum iterations before auto-stop (default: 42)
  --codex-model <MODEL:EFFORT>
                         Codex model and reasoning effort (default from config, fallback gpt-5.4:high)
  --codex-timeout <SECONDS>
                         Timeout for each Codex review in seconds (default: 5400)
  --track-plan-file      Indicate plan file should be tracked in git (must be clean)
  --push-every-round     Require git push after each round (default: commits stay local)
  --base-branch <BRANCH> Base branch for code review phase (default: auto-detect)
                         Priority: user input > remote default > main > master
  --full-review-round <N>
                         Interval for Full Alignment Check rounds (default: 5, min: 2)
                         Full Alignment Checks occur at rounds N-1, 2N-1, 3N-1, etc.
  --skip-impl            Skip implementation phase, go directly to code review
                         Plan file is optional when using this flag
  --claude-answer-codex  When Codex finds Open Questions, let Claude answer them
                         directly instead of asking user via AskUserQuestion
  --agent-teams          Enable Claude Code Agent Teams mode for parallel development.
                         Requires CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 environment variable.
                         Claude acts as team leader, splitting tasks among team members.
  -h, --help             Show help message
```

### gen-plan

```
/humanize:gen-plan --input <path/to/draft.md> --output <path/to/plan.md> [OPTIONS]

OPTIONS:
  --input   Path to the input draft file (required)
  --output  Path to the output plan file (required)
  --auto-start-rlcr-if-converged
             Start the RLCR loop automatically when the plan is converged
             (discussion mode only; ignored in --direct)
  --discussion  Use discussion mode (iterative Claude/Codex convergence rounds)
  --direct      Use direct mode (skip convergence rounds, proceed immediately to plan)
  -h, --help             Show help message

The gen-plan command transforms rough draft documents into structured implementation plans.

Workflow:
1. Validates input/output paths
2. Checks if draft is relevant to the repository
3. Analyzes draft for clarity, consistency, completeness, and functionality
4. Engages user to resolve any issues found
5. Generates a structured plan.md with acceptance criteria
6. Optionally starts `/humanize:start-rlcr-loop` if `--auto-start-rlcr-if-converged` conditions are met
```

### refine-plan

```
/humanize:refine-plan --input <path/to/annotated-plan.md> [OPTIONS]

OPTIONS:
  --input <path>        Path to the annotated plan file (required)
  --output <path>       Path to the refined plan output file
                        Defaults to refining --input in place
  --qa-dir <path>       Directory for QA document output
                        Default: .humanize/plan_qa
  --alt-language <LANG>
                        Generate translated plan and QA variants
                        Supported: zh, ko, ja, es, fr, de, pt, ru, ar
                        Full language names are also accepted; en/English is a no-op
  --discussion          Interactive mode for ambiguous comment classification
  --direct              Non-interactive mode; makes minimal safe assumptions
  -h, --help            Show help message
```

The refine-plan command reads an annotated `gen-plan` document, processes embedded review
comments, removes those comment blocks from the final plan, and writes a QA ledger that records
how each comment was handled.

**Usage examples:**

```bash
# Refine a plan in place and write QA output to the default directory
/humanize:refine-plan --input docs/plan.md

# Write the refined plan to a new file and store QA output in a custom directory
/humanize:refine-plan --input docs/plan.annotated.md --output docs/plan.refined.md --qa-dir docs/plan-qa

# Run in direct mode and generate translated variants
/humanize:refine-plan --input docs/plan.md --direct --alt-language zh
```

**Annotated comment block format:**

`refine-plan` looks for reviewer comments wrapped in `CMT:` and `ENDCMT` markers. Both inline
and multi-line comment blocks are supported:

```markdown
Text before CMT: clarify why AC-3 is split here ENDCMT text after
```

```markdown
CMT:
Please investigate whether this task should depend on task4 or task5.
If the dependency is unclear, add a pending decision instead of guessing.
ENDCMT
```

Rules:
- At least one non-empty `CMT:` block must exist in the input file.
- `CMT:` and `ENDCMT` markers inside fenced code blocks or HTML comments are ignored.
- Empty comment blocks are removed but do not create QA ledger entries.
- The input plan must still follow the `gen-plan` section schema.

**QA output structure:**

For an input plan named `plan.md`, the default QA output path is `.humanize/plan_qa/plan-qa.md`.
The generated QA document includes:

- `## Summary`: overall refinement outcome and comment counts
- `## Comment Ledger`: one row per raw `CMT-N` block with classification, location, excerpt, and disposition
- `## Answers`: responses to question comments and any clarifying edits
- `## Research Findings`: repository research performed for `research_request` comments
- `## Plan Changes Applied`: changes made for `change_request` comments and cross-reference updates
- `## Remaining Decisions`: unresolved items or assumption-heavy decisions that still need user input
- `## Refinement Metadata`: input/output paths, QA path, classification counts, modified sections, convergence status, and date

Disposition values in the ledger are `answered`, `applied`, `researched`, `deferred`, or
`resolved`.

If `--alt-language` is set to a supported non-English language, the command also generates
translated plan and QA variants by inserting `_<code>` before the file extension, such as
`plan_zh.md` and `plan-qa_zh.md`.

### start-pr-loop

```
/humanize:start-pr-loop --claude|--codex [OPTIONS]

BOT FLAGS (at least one required):
  --claude   Monitor reviews from claude[bot] (trigger with @claude)
  --codex    Monitor reviews from chatgpt-codex-connector[bot] (trigger with @codex)

OPTIONS:
  --max <N>              Maximum iterations before auto-stop (default: 42)
  --codex-model <MODEL:EFFORT>
                         Codex model and reasoning effort (default from config, effort: medium)
  --codex-timeout <SECONDS>
                         Timeout for each Codex review in seconds (default: 900)
  -h, --help             Show help message
```

The PR loop automates the process of handling GitHub PR reviews from remote bots:

1. Detects the PR associated with the current branch
2. Fetches review comments from the specified bot(s)
3. Claude analyzes and fixes issues identified by the bot(s)
4. Pushes changes and triggers re-review by commenting @bot
5. Stop Hook polls for new bot reviews (every 30s, 15min timeout per bot)
6. Local Codex validates if remote concerns are approved or have issues
7. Loop continues until all bots approve or max iterations reached

**Prerequisites:**
- GitHub CLI (`gh`) must be installed and authenticated
- Codex CLI must be installed
- Current branch must have an associated open PR

### ask-codex

```
/humanize:ask-codex [OPTIONS] <question or task>

OPTIONS:
  --codex-model <MODEL:EFFORT>
                         Codex model and reasoning effort (default from config, fallback gpt-5.4:high)
  --codex-timeout <SECONDS>
                         Timeout for the Codex query in seconds (default: 3600)
  -h, --help             Show help message
```

The ask-codex skill sends a one-shot question or task to Codex and returns the response
inline. Unlike the RLCR loop, this is a single consultation without iteration -- useful
for getting a second opinion, reviewing a design, or asking domain-specific questions.

Responses are saved to `.humanize/skill/<timestamp>/` with `input.md`, `output.md`,
and `metadata.md` for reference.

## Configuration

Humanize uses a 4-layer config hierarchy (lowest to highest priority):
1. **Plugin defaults**: `config/default_config.json`
2. **User config**: `~/.config/humanize/config.json`
3. **Project config**: `.humanize/config.json`
4. **CLI flags**: Command-line arguments (where available)

Current built-in keys:

| Key | Default | Description |
|-----|---------|-------------|
| `codex_model` | `gpt-5.4` | Shared default model for Codex-backed review and analysis |
| `codex_effort` | `high` | Shared default reasoning effort (`xhigh`, `high`, `medium`, `low`) |
| `bitlesson_model` | `haiku` | Model used by the BitLesson selector agent |
| `agent_teams` | `false` | Project-level default for agent teams workflow |
| `alternative_plan_language` | `""` | Optional translated plan variant language; supported values include `Chinese`, `Korean`, `Japanese`, `Spanish`, `French`, `German`, `Portuguese`, `Russian`, `Arabic`, or ISO codes like `zh` |
| `gen_plan_mode` | `discussion` | Default plan-generation mode |

### Codex Model Configuration

All Codex-using features (RLCR loop, PR loop, ask-codex) share the same model configuration:

| Key | Default | Description |
|-----|---------|-------------|
| `codex_model` | `gpt-5.4` | Model used for Codex operations (reviews, analysis, queries) |
| `codex_effort` | `high` | Reasoning effort (`xhigh`, `high`, `medium`, `low`) |

To override, add to `.humanize/config.json`:

```json
{
  "codex_model": "gpt-5.2",
  "codex_effort": "xhigh",
  "bitlesson_model": "sonnet"
}
```

Codex model is resolved with this precedence:
1. CLI `--codex-model` flag (highest priority)
2. Feature-specific defaults (e.g., PR loop defaults to `medium` effort)
3. Config-backed defaults from the 4-layer hierarchy above
4. Hardcoded fallback (`gpt-5.4:high`)

**Migration note**: If your `.humanize/config.json` contains the legacy keys
`loop_reviewer_model` or `loop_reviewer_effort`, they are silently ignored.
Use `codex_model` and `codex_effort` instead.


## Monitoring

Set up the monitoring helper for real-time progress tracking:

```bash
# Add to your .bashrc or .zshrc
source ~/.claude/plugins/cache/humania/humanize/<LATEST.VERSION>/scripts/humanize.sh

# Monitor RLCR loop progress
humanize monitor rlcr

# Monitor PR loop progress
humanize monitor pr
```

Progress data is stored in `.humanize/rlcr/<timestamp>/` for each loop session.

## Cancellation

- **RLCR loop**: `/humanize:cancel-rlcr-loop`
- **PR loop**: `/humanize:cancel-pr-loop`

## Environment Variables

### HUMANIZE_CODEX_BYPASS_SANDBOX

**WARNING: This is a dangerous option that disables security protections. Use only if you understand the implications.**

- **Purpose**: Controls whether Codex runs with sandbox protection
- **Default**: Not set (uses `--full-auto` with sandbox protection)
- **Values**:
  - `true` or `1`: Bypasses Codex sandbox and approvals (uses `--dangerously-bypass-approvals-and-sandbox`)
  - Any other value or unset: Uses safe mode with sandbox

**When to use this**:
- Linux servers without landlock kernel support (where Codex sandbox fails)
- Automated CI/CD pipelines in trusted environments
- Development environments where you have full control

**When NOT to use this**:
- Public or shared development servers
- When reviewing untrusted code or pull requests
- Production systems
- Any environment where unauthorized system access could cause damage

**Security implications**:
- Codex will have unrestricted access to your filesystem
- Codex can execute arbitrary commands without approval prompts
- Review all code changes carefully when using this mode

**Usage example**:
```bash
# Export before starting Claude Code
export HUMANIZE_CODEX_BYPASS_SANDBOX=true

# Or set for a single session
HUMANIZE_CODEX_BYPASS_SANDBOX=true claude --plugin-dir /path/to/humanize
```
