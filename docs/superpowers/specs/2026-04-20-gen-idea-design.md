# gen-idea — Directed-Swarm Idea Drafting (Design)

## Context

Humanize today starts at `gen-plan`, which takes a user-authored draft `.md` and produces a structured plan via a single Codex first-pass + a Claude/Codex convergence loop. The draft itself — the "most valuable human input" that `gen-plan` preserves verbatim — still has to be hand-authored.

This spec introduces a new command `/humanize:gen-idea` that sits one step earlier in the flow. It takes a loose idea (inline text or a `.md` of notes) and produces a repo-grounded draft suitable as `gen-plan`'s `--input`.

The command borrows its core mechanic from the Anthropic alignment note *Automated W2S Researcher* (2026). That work showed that when nine agents received **different high-level directions** ("study data filtering", "study distillation", "study evolutionary search") they decisively outperformed nine agents given the same task description — directed diversity climbs faster than undirected replication. `gen-idea` applies the same insight to idea generation: instead of one LLM pass, a lead picks N orthogonal directions and delegates one direction per subagent, then synthesizes.

## Goal

One shipable command, `/humanize:gen-idea`, that:

- Accepts a loose idea (inline text or `.md` path) and a desired direction count.
- Spawns N parallel read-only exploration subagents, each assigned a distinct direction.
- Writes a single draft `.md` that chooses one primary direction, lists alternatives, and grounds each in objective repo evidence.
- Produces output that passes through `gen-plan --input <draft>` unchanged.

No Codex, no RLCR, no auto-chaining, no relevance check, no config-loader integration. Lightweight first pass — everything downstream already exists.

## Out of Scope (First Pass)

- Codex involvement in idea phase (delegated to downstream `gen-plan`).
- Relevance check against repo (delegated to `gen-plan` Phase 2).
- Config-loader integration (`.humanize/config.json` not read).
- Alternative-language translation variant.
- Auto-chain to `gen-plan`.
- Test harness, CI coverage, or telemetry.
- `--directions` override flag (directions are LLM-picked per topic).

Each of these may land in a follow-up once the primary flow is proven.

## Command Signature

```
/humanize:gen-idea <idea-text-or-path> [--n 6] [--output <path>]
```

**Input auto-detection**: if the positional arg resolves to an existing file AND ends in `.md`, it is read as file content; otherwise the arg is treated verbatim as inline idea text.

**Parameters**

- Positional (required): idea body as inline text or path to a `.md` file. Must be non-empty after parsing.
- `--n <int>` (optional, default `6`): direction count. Valid range `[2, 10]`. Out-of-range stops the command.
- `--output <path>` (optional): target draft path. Default `.humanize/ideas/<slug>-<YYYYMMDD-HHMMSS>.md` relative to project root.

**Slug construction**

- File input → filename stem (extension removed).
- Inline input → lowercase first ~40 chars of the idea, strip non-alphanumeric (keep `-`), collapse dash runs, trim leading/trailing dashes.
- Empty result → fallback `idea`.

**Path behavior**

- For the **default** `--output`, the command auto-creates `.humanize/ideas/` if missing. This matches the implicit contract that Humanize owns its own `.humanize/` subtree.
- For a **user-supplied** `--output`, the parent directory must already exist. This mirrors `gen-plan`'s stance and avoids silently creating arbitrary directories.
- Output file must not already exist. Refuse to overwrite.

## Architecture

Five phases inside a single command file `commands/gen-idea.md`, strictly sequential:

### Phase 0 — Parse Input

Parse `$ARGUMENTS`. Set `IDEA_INPUT`, `N` (default 6), `OUTPUT_FILE` (default path if unset).

### Phase 1 — IO Validation

Call `scripts/validate-gen-idea-io.sh` with the resolved flags. The script:

- Distinguishes inline vs file input.
- Writes inline text to a tempfile under `$TMPDIR` and prints its path (so downstream phases always consume a file, simplifying the command body).
- Verifies `--n` is an integer in `[2, 10]`.
- Creates the default output directory when the default path is used; rejects non-existent parent directory for user-supplied paths.
- Refuses to overwrite an existing output file.
- Locates `prompt-template/idea/gen-idea-template.md`.

Exit codes parallel `validate-gen-plan-io.sh` (distinct failures get distinct codes; `6` is "invalid arguments"; `7` is "template missing").

Script stdout contains `INPUT_MODE`, `IDEA_BODY_FILE`, `OUTPUT_FILE`, `SLUG`, `TEMPLATE_FILE`, `N` for the command to consume.

### Phase 2 — Direction Generation

One Claude pass. Inputs: the idea body, the repo README, the project `CLAUDE.md` (if any), and a top-level directory listing. Output: exactly `N` orthogonal directions, each with:

- A short **name** (2–5 words).
- A **one-sentence rationale** explaining *why this angle is distinct from the others*.

Orthogonality is the hard constraint — two near-duplicate directions defeat the W2S premise. The generation prompt names this explicitly and requires the model to flag and replace any near-duplicates before returning.

### Phase 3 — Parallel Exploration

Single Task-tool invocation block with N parallel `Explore` subagents. Each subagent receives:

- The verbatim idea body.
- Its single assigned direction (name + rationale).
- Instruction to produce a structured mini-proposal with **objective evidence** — references to specific repo paths, existing patterns worth extending, measurable considerations (rough complexity, LOC surface, perf implications) where discoverable. Read-only; no writes.
- Explicit instruction to report "exploratory, no concrete precedent" verbatim if no evidence is found. Fabrication is forbidden.

Each subagent returns a proposal block with fields: `APPROACH_SUMMARY`, `OBJECTIVE_EVIDENCE` (bullet list), `KNOWN_RISKS`, `CONFIDENCE` (`high` / `medium` / `low`).

### Phase 4 — Synthesis & Write

The Lead (main command body, same model context) reviews all returned proposals and:

1. Picks the strongest direction as **primary**, factoring in: evidence density, fit with repo patterns, implementation surface area, and declared confidence.
2. Populates the template in this order: inferred title → `Original Idea` (verbatim copy of the idea body) → `Primary Direction` section (filled from the chosen proposal) → `Alternative Directions Considered` (each remaining direction in Alt-1..Alt-(N-1) order, with "Why not primary" line) → `Synthesis Notes` (which alt elements could fold into primary).
3. Writes the finalized draft to `OUTPUT_FILE` via `Write`.
4. Reports path + one-line summary to the user.

## Draft Output Format

Rendered from `prompt-template/idea/gen-idea-template.md`:

```markdown
# <Inferred Title>

## Original Idea
<Verbatim — never paraphrased>

## Primary Direction: <Name>

### Rationale
<Why strongest given repo context and evidence.>

### Approach Summary
<Concrete design: what to build, core mechanism, affected components.>

### Objective Evidence
- <Code reference: path/to/file — existing pattern we extend>
- <Prior art / precedent>
- <Measurable consideration where available>

### Known Risks
<Short honest list of what could go wrong.>

## Alternative Directions Considered

### Alt-1: <Name>
- Gist: <one-paragraph summary>
- Objective Evidence:
  - <bullet>
- Why not primary: <short reason>

### Alt-2 ... Alt-(N-1)
<Same shape.>

## Synthesis Notes
<Which elements from alternatives could fold into the primary if the user picks an alt.>
```

Two invariants:

1. `Original Idea` is byte-identical to the user's input. Mirrors `gen-plan`'s "draft is the most valuable human input" principle.
2. The draft is a complete, self-contained design — not a set of open questions. This is what lets it pass `gen-plan` Phase 2 and feed Phase 3 meaningfully.

## Agent Topology

```
user idea (inline | file)
        |
        v
[Phase 2: Lead — generate N orthogonal directions]
        |
        +--> [Explore #1, direction A]  --+
        +--> [Explore #2, direction B]  --|
        +--> [Explore #3, direction C]  --|--> [Phase 4: Lead — synthesize]
        +--> ...                        --|              |
        +--> [Explore #N, direction N]  --+              v
                                                      draft.md
```

All parallel subagents are `Explore` (read-only). No new subagent type is introduced.

## Error Handling

- **Direction generation returns fewer than N**: retry the Phase 2 call once, asking for exactly N orthogonal directions. After the retry, if at least 2 directions are returned, proceed with the reduced count and log a warning; with fewer than 2, stop.
- **One Explore subagent fails**: drop it and continue synthesis with the rest. With fewer than 2 successful proposals, stop with error `exploration phase degraded; retry`.
- **No objective evidence for a direction**: subagent reports `exploratory, no concrete precedent`; that text is preserved verbatim in the draft. Never fabricate references.
- **Inline idea shorter than 10 characters**: warn and proceed (user's call — some valid ideas are terse).
- **Input file unreadable / not `.md`**: IO validation exits with distinct error code, parallel to `validate-gen-plan-io.sh` semantics.

## Files to Add or Modify

1. `commands/gen-idea.md` — new command spec (estimated ~150–200 lines, structured like a lean subset of `gen-plan.md`).
2. `prompt-template/idea/gen-idea-template.md` — new template file matching the format above.
3. `scripts/validate-gen-idea-io.sh` — new IO validation + slug resolution script, modeled on `validate-gen-plan-io.sh`.
4. `README.md` — add a one-line Quick Start entry for `gen-idea` above the `gen-plan` step; bump `Current Version` to `1.16.1`.
5. `.claude-plugin/plugin.json` — bump `version` to `1.16.1`.
6. `.claude-plugin/marketplace.json` — bump `version` to `1.16.1` (three-file version sync is a project-level rule).

No test harness is added in this first pass.

## Acceptance (Smoke-Level)

- `/humanize:gen-idea "add undo/redo to the editor"` writes a `.md` under `.humanize/ideas/` with all required sections populated — one primary direction plus five alternatives (`N=6` total).
- `/humanize:gen-idea notes/rough.md --n 3 --output tmp/draft.md` reads the file, writes to `tmp/draft.md`, with exactly one primary and two alternatives.
- `/humanize:gen-idea ""` stops with a clear "missing idea" error.
- `/humanize:gen-idea "x" --n 1` stops with an out-of-range error.
- `/humanize:gen-idea "x" --output <existing-file>` refuses to overwrite.
- The resulting draft fed into `/humanize:gen-plan --input <draft> --output plan.md` passes Phase 2 relevance check and produces a structured plan without human edits.

## Future Extensions (Out of Scope Here)

- Codex pass over the synthesized draft for independent sanity check.
- Optional `--chain-to-gen-plan` flag that invokes `gen-plan` on the written draft.
- `--directions "..."` override for users who want to pin angles.
- Config-loader integration for alternative-language draft variants.
- Relevance check mirroring `gen-plan` Phase 2 to fail early when an idea is clearly unrelated to the repo.
