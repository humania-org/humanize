# Humanize

**Current Version: 1.17.0**

> Derived from the [GAAC (GitHub-as-a-Context)](https://github.com/SihaoLiu/gaac) project.

A Claude Code plugin that provides iterative development with independent AI review. Build with confidence through continuous feedback loops.

> **Note**: The `h2-dev` branch is a transitional branch that ships Humanize 1.0 features (RLCR loop, Codex review, planning commands) **and** the Humanize 2.0 platform (MCP server hub with HTML workflow cartridges) side by side. See the [Humanize 2.0 Platform](#humanize-20-platform-mcp-server-hub) section below for the new generic workflow runtime.

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

1. **Generate an idea draft** from a loose thought (optional — skip if you already have a draft):
   ```bash
   /humanize:gen-idea "add undo/redo to the editor"
   ```
   Output goes to `.humanize/ideas/<slug>-<timestamp>.md` by default. Pass a `.md` path to expand existing rough notes. `--n` controls how many parallel directions explore the idea (default 6).

2. **Generate a plan** from your draft:
   ```bash
   /humanize:gen-plan --input draft.md --output docs/plan.md
   ```

3. **Refine an annotated plan** before implementation when reviewers add comments (`CMT:` ... `ENDCMT`, `<cmt>` ... `</cmt>`, or `<comment>` ... `</comment>`):
   ```bash
   /humanize:refine-plan --input docs/plan.md
   ```

4. **Run the loop**:
   ```bash
   /humanize:start-rlcr-loop docs/plan.md
   ```

5. **Consult Gemini** for deep web research (requires Gemini CLI):
   ```bash
   /humanize:ask-gemini What are the latest best practices for X?
   ```

6. **Monitor progress (in another terminal, not inside Claude Code)**:
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

## Humanize 2.0 Platform (MCP Server Hub)

Humanize 2.0 ships alongside the 1.0 plugin on this branch. It is a local MCP server hub and HTML workflow runtime that turns Humanize from a fixed RLCR plugin into a general-purpose flow execution platform. The same human programmer keeps using familiar agent CLIs (Codex, Claude Code, Gemini CLI, Zed, etc.); the hub provides the shared workflow layer underneath.

### Build

The MCP server is shipped as TypeScript source and must be built once before use:

```bash
cd <plugin-root>
npm install
npm run build
```

### Plugin MCP Registration

The plugin auto-registers a `humanize2` MCP server via `.mcp.json` at the plugin root. After building, the server starts automatically with the plugin under any MCP-capable Claude Code client.

### Start the Local Hub

```bash
HUMANIZE2_PORT=4772 npm run hub
# Open the dashboard
xdg-open http://127.0.0.1:4772
```

The dashboard lists Agent Sessions, shows the logical session graph and Gantt timeline, and lets you select a session to inspect input history, log, and output. The hub uses `~/.h2/config.yaml` and stores run history under `~/.h2/cache` by default. Set `HUMANIZE2_CACHE_DIR` or `HUMANIZE2_DEFAULT_TIMEOUT_MS` to override those values.

### MCP Tools

The `humanize2` server exposes these MCP tools:

- `agent_status` reports availability for configured agent backends.
- `agent_run` accepts an explicit `agent` field and dispatches to that backend.
- `agent_spawn_child` starts a hub-managed child run; the current run is used as the parent automatically when called from a Humanize2-managed agent.
- `codex_run` dispatches directly to Codex CLI.
- `claude_run` dispatches directly to Claude Code CLI.
- `agent_send_message` sends a message to a hub-managed run. If the run is still active, the hub interrupts it and starts a linked continuation run.
- `agent_wait` waits for a hub-managed run to finish.

The hub also exposes a workflow surface (`workflow_*`, `view_*`, `board_*`, `artifact_*`, `event_*`, `human_*`) for HTML workflow cartridges under `flow/`.

### Workflow Cartridges

First-party flow cartridges ship under `flow/`:

- `flow/rlcr` -- the legacy RLCR loop expressed as a workflow cartridge
- `flow/gen-idea`, `flow/gen-plan`, `flow/refine-plan` -- planning workflows
- `flow/experimental/team-intervention-smoke` -- intervention smoke test

See the source under `src/` and tests under `tests/` for the full workflow grammar, MCP/RPC surface, and runtime behavior.

### Development Checks

```bash
npm test
npm run typecheck
npm run build
```

## License

MIT
