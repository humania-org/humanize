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
- **Manager-Driven Scenario Matrix** -- Humanize keeps a machine-readable task graph in `.humanize/rlcr/<timestamp>/scenario-matrix.json`, lets the top-level manager reconcile task state, projects that state back into the Goal Tracker and checkpoint contract, and can nudge a stuck agent toward a narrower recovery path without replacing the single-mainline rule.
- **Begin with the End in Mind** -- Before the loop starts, Humanize verifies that *you* understand the plan you are about to execute. The human must remain the architect. ([Details](docs/usage.md#begin-with-the-end-in-mind))

## How It Works

<p align="center">
  <img src="docs/images/rlcr-workflow.svg" alt="RLCR Workflow" width="680"/>
</p>

The loop has two phases: **Implementation** (Claude works, Codex reviews summaries) and **Code Review** (Codex checks code quality with severity markers). Issues feed back into implementation until resolved.

New-format loops also maintain a compatibility-first manager orchestration runtime:

- `scenario-matrix.json` is the machine-native control plane. It stores authoritative task state, dependency edges, task packets, repair-wave clustering, checkpoint/convergence metadata, and oversight signals.
- The top-level manager is the only authoritative scheduler and matrix reconciler. Execution agents implement code, while the manager assigns bounded task packets, ingests feedback, and keeps exactly one current primary objective.
- Review findings first enter a raw backlog, are deduplicated and normalized into grouped issue backlogs, and only become executable tasks when the manager explicitly promotes them.
- `goal-tracker.md` and `round-N-contract.md` remain human-facing compatibility views, but their mutable task sections are now projected from the matrix.
- Oversight interventions such as `nudge`, `reframe`, `split`, or `resequence` only steer the active agent back onto the current task. They do not create multiple mainlines or take over implementation authority.

## Install

```bash
# Add humania marketplace
/plugin marketplace add humania-org/humanize
# If you want to use development branch for experimental features
/plugin marketplace add humania-org/humanize#dev
# Then install humanize plugin
/plugin install humanize@humania
```

Requires [codex CLI](https://github.com/openai/codex) for review. See the full [Installation Guide](docs/install-for-claude.md) for prerequisites and alternative setup options.

## Quick Start

1. **Generate a plan** from your draft:
   ```bash
   /humanize:gen-plan --input draft.md --output docs/plan.md
   ```

2. **Refine an annotated plan** before implementation when reviewers add `CMT:` ... `ENDCMT` comments:
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

5. **Monitor progress**:
   ```bash
   source <path/to/humanize>/scripts/humanize.sh
   humanize monitor rlcr       # RLCR loop
   humanize monitor skill      # All skill invocations (codex + gemini)
   humanize monitor codex      # Codex invocations only
   humanize monitor gemini     # Gemini invocations only
   ```

   The RLCR monitor now shows scenario-matrix readiness, the current mainline projection, the current manager checkpoint, convergence state, repair-wave context, and any active oversight action alongside the existing loop status.

6. **Render the current scenario matrix as an HTML dashboard**:
   ```bash
   source <path/to/humanize>/scripts/humanize.sh
   humanize matrix                    # latest local RLCR session
   humanize matrix --input tmp.json   # explicit matrix/session/state file
   humanize matrix --serve            # local browser client with refresh
   ```

   `humanize matrix` generates a local HTML snapshot with the current primary objective, supporting window, dependency graph, feedback queues, recent events, and convergence/oversight status.

   `humanize matrix --serve` starts a local HTML client on `http://127.0.0.1:<port>/`. Leave that page open and use the in-page `Refresh Snapshot` button instead of reopening freshly generated files.

## Monitor Dashboard

<p align="center">
  <img src="docs/images/monitor.png" alt="Humanize Monitor" width="680"/>
</p>

## Documentation

- [Usage Guide](docs/usage.md) -- Commands, options, environment variables
- [Scenario Matrix Guide](scenario-matrix.md) -- Manager role, task packets, repair waves, and convergence flow
- [Install for Claude Code](docs/install-for-claude.md) -- Full installation instructions
- [Install for Codex](docs/install-for-codex.md) -- Codex skill runtime setup
- [Install for Kimi](docs/install-for-kimi.md) -- Kimi CLI skill setup
- [Configuration](docs/usage.md#configuration) -- Shared config hierarchy and override rules
- [Bitter Lesson Workflow](docs/bitlesson.md) -- Project memory, selector routing, and delta validation

## License

MIT
