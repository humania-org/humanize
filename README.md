# Humanize

**Current Version: 1.16.0**

> Derived from the [GAAC (GitHub-as-a-Context)](https://github.com/SihaoLiu/gaac) project.

A Claude Code plugin that provides iterative development with independent AI review. Build with confidence through continuous feedback loops.

## What is RLCR?

**RLCR** stands for **Ralph-Loop with Codex Review**, inspired by the official ralph-loop plugin and enhanced with independent Codex review. The name also reads as **Reinforcement Learning with Code Review** -- reflecting the iterative cycle where AI-generated code is continuously refined through external review feedback.

## Core Concepts

- **Iteration over Perfection** -- Instead of expecting perfect output in one shot, Humanize leverages continuous feedback loops where issues are caught early and refined incrementally.
- **One Build + One Review** -- Claude implements, Codex independently reviews. No blind spots.
- **Ralph Loop with Swarm Mode** -- Iterative refinement continues until all acceptance criteria are met. Optionally parallelize with Agent Teams.
- **Begin with the End in Mind** -- Before the loop starts, Humanize verifies that *you* understand the plan you are about to execute. The human must remain the architect. ([Details](docs/usage.md#begin-with-the-end-in-mind))

## How It Works

<p align="center">
  <img src="docs/images/rlcr-workflow.svg" alt="RLCR Workflow" width="680"/>
</p>

The loop has two phases: **Implementation** (Claude works, Codex reviews summaries) and **Code Review** (Codex checks code quality with severity markers). Issues feed back into implementation until resolved.


## Install

```bash
# Add PolyArch marketplace
/plugin marketplace add PolyArch/humanize
# If you want to use development branch for experimental features
/plugin marketplace add PolyArch/humanize#dev
# Then install humanize plugin
/plugin install humanize@PolyArch
```

Requires [codex CLI](https://github.com/openai/codex) for review. See the full [Installation Guide](docs/install-for-claude.md) for prerequisites and alternative setup options.

## Quick Start

1. **Generate a plan** from your draft:
   ```bash
   /humanize:gen-plan --input draft.md --output docs/plan.md
   ```

2. **Refine an annotated plan** before implementation when reviewers add comments (`CMT:` ... `ENDCMT`, `<cmt>` ... `</cmt>`, or `<comment>` ... `</comment>`):
   ```bash
   /humanize:refine-plan --input docs/plan.md
   ```

3. **Run the loop**:
   ```bash
   /humanize:start-rlcr-loop docs/plan.md
   ```

4. **Consult Gemini** for deep web research (requires Gemini CLI):
   ```bash
   /humanize:ask-gemini What are the latest best practices for X?
   ```

5. **Monitor progress (in another terminal, not inside Claude Code)**:
   ```bash
   source <path/to/humanize>/scripts/humanize.sh # Or just add it into your .bashec or .zshrc
   humanize monitor rlcr       # RLCR loop
   humanize monitor skill      # All skill invocations (codex + gemini)
   humanize monitor codex      # Codex invocations only
   humanize monitor gemini     # Gemini invocations only
   humanize monitor web        # Browser dashboard for the current project
   ```

   The `humanize monitor web` subcommand launches a per-project browser dashboard
   that layers on top of the same data sources the terminal monitors read. It runs
   in the foreground by default; pass `--daemon` for the background tmux launcher
   and `--host` / `--port` / `--auth-token` to configure remote access. See the
   upgrade note: `/humanize:viz` has been removed in favour of `humanize monitor web`.

## Monitor Dashboard

<p align="center">
  <img src="docs/images/monitor.png" alt="Humanize Monitor" width="680"/>
</p>

## Documentation

- [Usage Guide](docs/usage.md) -- Commands, options, environment variables
- [Install for Claude Code](docs/install-for-claude.md) -- Full installation instructions
- [Install for Codex](docs/install-for-codex.md) -- Codex skill runtime setup
- [Install for Kimi](docs/install-for-kimi.md) -- Kimi CLI skill setup
- [Configuration](docs/usage.md#configuration) -- Shared config hierarchy and override rules
- [Bitter Lesson Workflow](docs/bitlesson.md) -- Project memory, selector routing, and delta validation

## License

MIT
