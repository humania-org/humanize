# Draft: Optimize viz-dashboard — Merge into `humanize monitor` as a Web View

## Background

The `feat/viz-dashboard` branch currently introduces a `/humanize:viz` Claude
slash command and a local visualization dashboard for Humanize. While the
dashboard does show some data, the visualization of a *live, dynamically
running RLCR loop* is not clear enough today: status, progress per round, and
streamed log output are hard to follow as a loop progresses.

Separately, Humanize already ships a CLI-side monitoring capability that the
user runs in another terminal (NOT inside Claude Code):

```bash
source <path/to/humanize>/scripts/humanize.sh   # or add to .bashrc / .zshrc

humanize monitor rlcr        # RLCR loop
humanize monitor skill       # All skill invocations (codex + gemini)
humanize monitor codex       # Codex invocations only
humanize monitor gemini      # Gemini invocations only
```

This monitor capability already captures live state (RLCR rounds, skill / Codex
/ Gemini invocations, log output). The web dashboard does not need to invent
its own capture pipeline — it should consume what `humanize monitor` already
provides.

## Goal

Optimize the viz-dashboard branch so that:

1. The dashboard becomes a **web view** layered on top of the existing
   `humanize monitor` data sources, rather than an independent capture layer.
2. The dashboard can show **multiple live RLCR loops simultaneously**, with
   per-loop status and streamed log output.
3. The entry point moves out of Claude (no more `/humanize:viz` slash command)
   and into the `humanize monitor` CLI command, as a new web-online viewing
   subcommand.
4. The new capability targets **online / remote viewing in a browser**, not a
   local-only viewer that requires the user to be on the same machine running
   Claude.
5. Useful features from the existing viz-dashboard branch — notably **cross-
   conversation querying** (browsing past sessions / loops across different
   Claude conversations) — are preserved.

## Non-goals

- Reimplementing the monitor capture pipeline (`humanize monitor rlcr/skill/
  codex/gemini`). The dashboard consumes it; it does not replace it.
- Continuing to ship `/humanize:viz` as a Claude slash command.
- Adding chart panels or features explicitly removed in commit 1b575fe
  ("multi-project switcher + restart + remove chart panels").

## Required behaviors

1. **CLI entry point unification**
   - Remove `commands/viz.md` and any `/humanize:viz` Claude command surface.
   - Add a new `humanize monitor` subcommand (name to be agreed during
     planning, e.g. `humanize monitor web` or `humanize monitor dashboard`)
     that starts the web dashboard server.
   - The other `humanize monitor rlcr|skill|codex|gemini` subcommands must
     keep working unchanged (terminal-attached live tail).

2. **Live multi-loop view**
   - The web dashboard MUST be able to display 2+ concurrently running RLCR
     loops at the same time, each with:
     - current status (running, paused, converged, stopped, …)
     - current round / phase
     - live streamed log output, updated in near real time

3. **Reuse existing monitor data**
   - The dashboard MUST source its data from the same files / events that
     `humanize monitor rlcr/skill/codex/gemini` already read. It MUST NOT add
     a parallel capture mechanism (no new hooks just for the dashboard).

4. **Online / remote-viewable**
   - The dashboard MUST be reachable from a browser over the network, not
     only via `localhost` on the machine running Claude. Concrete binding /
     auth design to be agreed during planning.

5. **Cross-conversation history**
   - Cross-conversation querying (browsing past loops from different Claude
     conversations / sessions) from the existing viz-dashboard branch MUST be
     preserved.

## Branch hygiene

Before implementation begins, the branch `feat/viz-dashboard` MUST be rebased
onto the latest `upstream/dev` (humania-org/humanize). Several relevant changes
have landed on `upstream/dev` after the branch diverged, including:

- `Add ask-gemini skill and tool-filtered monitor subcommands` (introduces the
  `humanize monitor skill|codex|gemini` subcommands the dashboard must reuse)
- `Remove PR loop feature entirely` (the viz-dashboard branch still references
  PR-loop concepts via `commands/cancel-pr-loop.md`, `commands/start-pr-loop.md`,
  `hooks/pr-loop-stop-hook.sh`)
- Multiple monitor / hook fixes

The rebase is therefore both a precondition for correctness (the dashboard
consumes the new monitor subcommands) and a cleanup step (PR-loop references
must be dropped).

## Out of scope (for this plan)

- Changes to RLCR semantics, hooks, or skill behavior.
- Authentication providers, identity systems, or multi-user account models —
  basic remote-access protection is in scope, but full IAM is not.
