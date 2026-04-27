# Humanize Usage Guide

Detailed usage documentation for the Humanize plugin. For installation, see [Install for Claude Code](install-for-claude.md).

## How It Works

Humanize creates an iterative feedback loop with two phases:

1. **Implementation Phase**: Claude works on your plan, Codex reviews summaries until COMPLETE
2. **Review Phase**: `codex review --base <branch>` checks code quality with `[P0-9]` severity markers

The loop continues until all acceptance criteria are met or no issues remain.

## Begin with the End in Mind

Before the RLCR loop starts any work, Humanize runs a **Plan Understanding Quiz** -- a brief pre-flight check that verifies you genuinely understand the plan you are about to execute.

### Why This Exists

The most expensive failure in AI-assisted development is not a bug. It is running a 40-round RLCR loop on a plan you never actually read. We call this **wishful coding**: treating a generated plan like a wish -- toss it in, hope for the best, check back later.

The problem is structural. An RLCR loop is an amplifier: it will faithfully execute whatever plan you give it. If the plan is wrong, the loop makes it wrong faster and at scale. If the plan is right but you do not understand it, you cannot course-correct when Codex raises questions, and the loop drifts.

Understanding your plan before execution is not optional overhead. It is the single highest-leverage thing you can do to ensure the loop succeeds.

### How the Quiz Works

When you run `start-rlcr-loop`, an independent agent analyzes the plan and generates two multiple-choice questions about the plan's technical implementation details:

1. **What components are changing and how?** -- Tests whether you know the core mechanism.
2. **How do the pieces connect?** -- Tests whether you understand the architecture being modified.

If you answer both correctly, the loop proceeds immediately. If you miss one or both, Humanize explains what the plan actually does and offers a choice: proceed anyway, or stop and review.

The quiz is advisory, not a gate. You always have the option to proceed. But that moment of friction -- the two seconds it takes to read the question and realize you do not know the answer -- is the entire point.

### Skipping the Quiz

- `--skip-quiz` -- Skip the quiz only. The rest of the RLCR loop behaves normally.
- `--yolo` -- Skip the quiz AND let Claude answer Codex's open questions directly (`--claude-answer-codex`). This is full automation mode for users who have already reviewed the plan and want to hand over complete control.
- Plans started via `gen-plan --auto-start-rlcr-if-converged` skip the quiz automatically, because the gen-plan convergence discussion already verified the user's understanding.

## Typical Planning Flow

1. Generate the initial implementation plan:
   ```bash
   /humanize:gen-plan --input draft.md --output docs/plan.md
   ```
2. If the plan is reviewed with comment annotations, refine it and generate a QA ledger:
   ```bash
   /humanize:refine-plan --input docs/plan.md
   ```
3. Start the RLCR loop on the refined plan:
   ```bash
   /humanize:start-rlcr-loop docs/plan.md
   ```

## Commands

| Command | Purpose |
|---------|---------|
| `/start-rlcr-loop <plan.md>` | Start iterative development with Codex review |
| `/cancel-rlcr-loop` | Cancel active loop |
| `/gen-plan --input <draft.md> --output <plan.md>` | Generate structured plan from draft |
| `/refine-plan --input <annotated-plan.md>` | Refine an annotated plan and generate a QA ledger |
| `/plan-check --plan <plan.md>` | Check a plan for contradictions, ambiguities, and schema compliance |
| `/ask-codex [question]` | One-shot consultation with Codex |

## Command Reference

### start-rlcr-loop

```
/humanize:start-rlcr-loop [path/to/plan.md | --plan-file path/to/plan.md] [OPTIONS]

OPTIONS:
  --plan-file <path>     Explicit plan file path (alternative to positional arg)
  --max <N>              Maximum iterations before auto-stop (default: 42)
  --codex-model <MODEL:EFFORT>
                         Codex model and reasoning effort (default from config, fallback gpt-5.5:high)
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
  --yolo                 Skip Plan Understanding Quiz and let Claude answer Codex Open
                         Questions directly. Alias for --skip-quiz --claude-answer-codex.
  --skip-quiz            Skip the Plan Understanding Quiz only (without other changes).
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
  --check       Enable integrated draft-check and plan-check mode for this invocation
  --no-check    Disable integrated check mode for this invocation (overrides --check and config)
  -h, --help             Show help message
```

The gen-plan command transforms rough draft documents into structured implementation plans.

Workflow:
1. Validates input/output paths
2. Checks if draft is relevant to the repository
3. When check mode is enabled, runs `check-draft` to detect contradictions and ambiguities that would affect plan generation
4. Analyzes draft for clarity, consistency, completeness, and functionality
5. Engages user to resolve any issues found
6. Generates a structured plan.md with acceptance criteria
7. When check mode is enabled, runs `check-plan` against the generated plan and repairs discrepancies using the original draft as the source of truth
8. Optionally starts `/humanize:start-rlcr-loop` if `--auto-start-rlcr-if-converged` conditions are met

If reviewers later annotate the generated plan with comment blocks, run
`/humanize:refine-plan --input <plan.md>` before starting or resuming implementation.

#### Check Mode

Check mode adds pre-generation draft checking and post-generation plan checking with targeted repair. It is **disabled by default**.

Enable check mode via CLI flag:
```bash
/humanize:gen-plan --input draft.md --output plan.md --check
```

Disable check mode for one invocation even if config enables it:
```bash
/humanize:gen-plan --input draft.md --output plan.md --no-check
```

Enable check mode by default via config (`gen_plan_check`):
```json
{
  "gen_plan_check": true
}
```

**Resolution priority** (highest to lowest):
1. `--no-check` flag forces disabled
2. `--check` flag forces enabled
3. Merged config `gen_plan_check` value (`true` or `false`)
4. Default: disabled

If the merged config contains an invalid value (anything other than `true` or `false`), a warning is printed and check mode falls back to disabled unless `--check` is passed.

**Check mode behavior**:
- `check-draft`: Runs after the relevance check and before plan generation. Detects contradictions and ambiguities in the draft that would affect plan generation. Blocker findings are presented to the user for clarification before the plan is generated.
- `check-plan`: Runs after the plan body is written. Validates schema compliance, internal consistency, and draft-vs-plan drift. Findings are repaired using source-of-truth precedence: explicit user answers > original draft text > repository facts > safe leader-agent judgment.
- `repair`: High-priority-source rewrites (clarifications, draft text, repo facts) are applied silently. Leader-agent-judgment rewrites require a diff preview and user confirmation.
- `recheck`: Controlled by the existing `plan_check_recheck` config. When enabled and at least one repair changed plan bytes, `check-plan` runs once more in check-only mode (no further repair).

**Artifacts**: When check mode is enabled, diagnostic artifacts are written to `.humanize/gen-plan-check/<timestamp>/`:
- `draft-findings.json` -- findings from the draft-check phase
- `plan-findings.json` -- findings from the plan-check phase
- `report.md` -- combined human-readable report
- `resolution.json` -- resolution records for repaired findings
- `backup/` -- backup of the plan before each accepted rewrite
- `tmp/` -- ephemeral temp files (deleted before the command exits)

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

`refine-plan` supports three comment formats for reviewer annotations. Both inline
and multi-line comment blocks are supported in all formats:

**Classic format (CMT:/ENDCMT):**
```markdown
Text before CMT: clarify why AC-3 is split here ENDCMT text after
```

```markdown
CMT:
Please investigate whether this task should depend on task4 or task5.
If the dependency is unclear, add a pending decision instead of guessing.
ENDCMT
```

**Short tag format (<cmt></cmt>):**
```markdown
Text before <cmt>clarify why AC-3 is split here</cmt> text after
```

```markdown
<cmt>
Please investigate whether this task should depend on task4 or task5.
If the dependency is unclear, add a pending decision instead of guessing.
</cmt>
```

**Long tag format (<comment></comment>):**
```markdown
Text before <comment>clarify why AC-3 is split here</comment> text after
```

```markdown
<comment>
Please investigate whether this task should depend on task4 or task5.
If the dependency is unclear, add a pending decision instead of guessing.
</comment>
```

Rules:
- At least one non-empty comment block must exist in the input file.
- Comment markers inside fenced code blocks or HTML comments are ignored.
- Empty comment blocks are removed but do not create QA ledger entries.
- The input plan must still follow the `gen-plan` section schema.
- All three formats can be mixed within the same file.

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

### ask-codex

```
/humanize:ask-codex [OPTIONS] <question or task>

OPTIONS:
  --codex-model <MODEL:EFFORT>
                         Codex model and reasoning effort (default from config, fallback gpt-5.5:high)
  --codex-timeout <SECONDS>
                         Timeout for the Codex query in seconds (default: 3600)
  -h, --help             Show help message
```

The ask-codex skill sends a one-shot question or task to Codex and returns the response
inline. Unlike the RLCR loop, this is a single consultation without iteration -- useful
for getting a second opinion, reviewing a design, or asking domain-specific questions.

Responses are saved to `.humanize/skill/<timestamp>/` with `input.md`, `output.md`,
and `metadata.md` for reference.

### plan-check

```
/humanize:plan-check --plan <path/to/plan.md> [OPTIONS]

OPTIONS:
  --plan <path>         Path to the plan file to check (required)
  --recheck             Re-run plan-check after an accepted rewrite (default: disabled)
  --alt-language <lang> Generate an additional report in the specified language
  -h, --help            Show help message
```

The `plan-check` command analyzes a plan file for internal contradictions,
ambiguities, and structural schema compliance before implementation begins.

**What it checks:**
- **Contradictions**: Statements that assign two incompatible definitions to the same symbol or mechanism
- **Ambiguities**: Statements that admit multiple valid interpretations affecting execution
- **Schema compliance**: Required sections, duplicate AC IDs, invalid task tags, orphaned dependencies, circular dependencies, appendix drift

**How it works:**
1. Runs deterministic schema validation using the canonical `gen-plan-template.md`
2. Spawns a sub-agent to perform semantic contradiction and ambiguity detection
3. Generates a structured findings report under `.humanize/plan-check/<timestamp>/`
4. Presents contradictions to the user for interactive resolution
5. Presents ambiguities atomically for clarification
6. Optionally rewrites the plan file in-place after user confirmation

By default, `plan-check` does not re-run after an accepted rewrite. Use `--recheck`
for a single run, or set `"plan_check_recheck": true` in Humanize config to make
recheck the default for the project or user.

**Report artifacts:**
- `report.md` -- Human-readable findings report
- `findings.json` -- Machine-readable findings (schema v1.0)
- `resolution.json` -- Post-resolution report with user clarifications (if applicable)
- `backup/plan.md.bak` -- Backup of the original plan (if rewrite is performed)

**Exit codes:**
- `0` -- No unresolved blockers remain
- `1` -- Unresolved blockers exist

**Example:**
```bash
/humanize:plan-check --plan .humanize/plans/my-plan.md
```

In Codex, use the installed skill form:

```bash
$humanize-plan-check --plan .humanize/plans/my-plan.md
```

## Configuration

Humanize uses a 4-layer config hierarchy (lowest to highest priority):
1. **Plugin defaults**: `config/default_config.json`
2. **User config**: `~/.config/humanize/config.json`
3. **Project config**: `.humanize/config.json`
4. **CLI flags**: Command-line arguments (where available)

Current built-in keys:

| Key | Default | Description |
|-----|---------|-------------|
| `codex_model` | `gpt-5.5` | Shared default model for Codex-backed review and analysis |
| `codex_effort` | `high` | Shared default reasoning effort (`xhigh`, `high`, `medium`, `low`) |
| `bitlesson_model` | `haiku` | Model used by the BitLesson selector agent |
| `provider_mode` | unset | Optional runtime mode hint such as `codex-only` |
| `agent_teams` | `false` | Project-level default for agent teams workflow |
| `alternative_plan_language` | `""` | Optional translated plan variant language; supported values include `Chinese`, `Korean`, `Japanese`, `Spanish`, `French`, `German`, `Portuguese`, `Russian`, `Arabic`, or ISO codes like `zh` |
| `gen_plan_mode` | `discussion` | Default plan-generation mode |
| `plan_check_recheck` | `false` | Re-run `plan-check` after an accepted rewrite; CLI `--recheck` enables this for a single run |

### Codex Model Configuration

All Codex-using features (RLCR loop, ask-codex) share the same model configuration:

| Key | Default | Description |
|-----|---------|-------------|
| `codex_model` | `gpt-5.5` | Model used for Codex operations (reviews, analysis, queries) |
| `codex_effort` | `high` | Reasoning effort (`xhigh`, `high`, `medium`, `low`) |

To override, add to `.humanize/config.json`:

```json
{
  "codex_model": "gpt-5.2",
  "codex_effort": "xhigh",
  "bitlesson_model": "sonnet"
}
```

On Codex installs, Humanize also seeds `${XDG_CONFIG_HOME:-~/.config}/humanize/config.json`
with a Codex/OpenAI `bitlesson_model` and `provider_mode: "codex-only"` when those keys
are unset, so BitLesson selection stays on the Codex/OpenAI path without probing Claude.

Codex model is resolved with this precedence:
1. CLI `--codex-model` flag (highest priority)
2. Feature-specific defaults
3. Config-backed defaults from the 4-layer hierarchy above
4. Hardcoded fallback (`gpt-5.5:high`)

**Migration note**: If your `.humanize/config.json` contains the legacy keys
`loop_reviewer_model` or `loop_reviewer_effort`, they are silently ignored.
Use `codex_model` and `codex_effort` instead.


## Monitoring

Set up the monitoring helper for real-time progress tracking:

```bash
# Add to your .bashrc or .zshrc
source ~/.claude/plugins/cache/PolyArch/humanize/<LATEST.VERSION>/scripts/humanize.sh

# Monitor RLCR loop progress
humanize monitor rlcr

```

Progress data is stored in `.humanize/rlcr/<timestamp>/` for each loop session.

## Cancellation

- **RLCR loop**: `/humanize:cancel-rlcr-loop`

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
