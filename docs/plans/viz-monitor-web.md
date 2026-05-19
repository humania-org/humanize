# Optimize viz-dashboard: Merge into `humanize monitor` as a Web View

## Goal Description

Optimize the `feat/viz-dashboard` branch so that the RLCR visualization becomes a web view layered on top of the existing `humanize monitor` data sources, supports multiple concurrent live RLCR loops with real-time streamed log output, moves the entry point out of Claude (no more `/humanize:viz` slash command) into a new `humanize monitor web` CLI subcommand, exposes the dashboard for online (browser) viewing with explicit network-binding and authentication controls, and preserves cross-conversation history browsing.

The dashboard MUST consume the same files and events that `humanize monitor rlcr|skill|codex|gemini` already read; it MUST NOT introduce a parallel capture pipeline (no new hooks just for the dashboard). The single-server-per-project model replaces the existing server-global project switcher to eliminate the cross-client mutation bug. Remote access defaults to safe (localhost-only) and requires an explicit token to expose data or actions to the network.

## Acceptance Criteria

Following TDD philosophy, each criterion includes positive and negative tests for deterministic verification.

- AC-1: CLI entry-point migration from Claude command to `humanize monitor web`.
  - Positive Tests (expected to PASS):
    - `humanize monitor web --project <p>` starts the dashboard server and prints the bound URL.
    - `humanize monitor rlcr`, `humanize monitor skill`, `humanize monitor codex`, `humanize monitor gemini` continue to behave exactly as before this change (verified by snapshot tests of usage text and exit behavior).
    - `humanize monitor` (no subcommand) prints usage that includes `web` alongside `rlcr|skill|codex|gemini`.
  - Negative Tests (expected to FAIL/be rejected):
    - The Claude slash command `/humanize:viz` is no longer registered (`commands/viz.md` removed); attempting to invoke it through Claude does not resolve.
    - `humanize monitor unknownsub` exits non-zero with usage; it does NOT silently fall through to a default.

- AC-2: Data-source reuse — no parallel capture pipeline.
  - Positive Tests:
    - With an active RLCR loop, `viz/server/parser.py` reads session metadata from `.humanize/rlcr/<session>/{state.md,goal-tracker.md,round-*-summary.md,round-*-review-result.md}` AND streamed bytes from `~/.cache/humanize/<sanitized-project>/<session>/round-*-codex-{run,review}.log`.
    - A test that intercepts file opens shows the dashboard reading from the same paths the RLCR monitor uses (parity test against `scripts/humanize.sh` cache lookup logic at lines around 284-368).
  - Negative Tests:
    - Grep over `hooks/` shows no new `*-viz-*.sh` or dashboard-only hook script added.
    - Grep over `viz/` shows no path writing to `.humanize/rlcr/` (the dashboard is a reader, not a writer of session state).

- AC-3: Multi-loop concurrent view enumerates all sessions, not only the newest.
  - Positive Tests:
    - With two concurrent active RLCR loops in the same project, the home page renders both session cards simultaneously, each showing session id, status, current round/max, current phase, and an independently updating live log pane.
    - Session enumeration covers ALL directories under `.humanize/rlcr/`, partitioned into "active" (state.md present) vs "historical" (terminal `*-state.md` present).
  - Negative Tests:
    - The dashboard does NOT auto-switch to the newest session (the single-session behavior of `monitor_find_latest_session` in `scripts/lib/monitor-common.sh` MUST NOT leak into the web view).
    - Adding a new active session while another is running does NOT remove or hide the existing one in the UI.

- AC-4: Live-log latency budget — append visible in browser within 2 seconds (HARD requirement).
  - Positive Tests:
    - An automated test appends N bytes to an active `round-*-codex-run.log`; the browser-side stream client receives those bytes within 2 seconds (measured end-to-end on the test harness).
    - The streaming protocol delivers an initial snapshot followed by byte-offset append events (snapshot + offset tail).
    - Truncation/rotation of the underlying log triggers a documented resync path (e.g. detect size shrink, restart from snapshot at offset 0).
  - Negative Tests:
    - The active-log path does NOT use a polling loop that re-fetches the full file body on every update.
    - Median measured append-to-render latency under nominal load does NOT exceed 2.0s; failure of this assertion fails CI.

- AC-5: Cross-conversation / historical browsing preserved.
  - Positive Tests:
    - Completed sessions stored under `.humanize/rlcr/` from prior Claude conversations are listed in the "Historical" section and individually browsable.
    - Ending an active loop transitions that session card from "Active" to "Historical" without removing it from view.
  - Negative Tests:
    - A finished session does NOT disappear from the dashboard after its terminal `*-state.md` appears.
    - Switching between active and historical views does NOT clear the other list.

- AC-6: Remote-reachable + access controlled across ALL data surfaces.
  - Positive Tests:
    - With default flags, the server binds to `127.0.0.1` only.
    - With `--host 0.0.0.0` (or any non-localhost host), startup REQUIRES a non-empty `--auth-token` (or the equivalent env var); otherwise the process exits non-zero with a clear error.
    - In remote mode, every endpoint (session list, session detail, per-session log SSE stream, control endpoints) requires a valid token; missing/invalid token returns 401.
  - Negative Tests:
    - Starting the server with `--host 0.0.0.0` without a token does NOT start; it errors out.
    - An unauthenticated remote request to `/api/sessions/<id>` or the per-session SSE stream is rejected with 401, not served.
    - The server does NOT bind to `0.0.0.0` by default under any path of `humanize monitor web`.

- AC-7: Session-targeted cancel built and tested (per DEC-2 = build session-scoped cancel).
  - Positive Tests:
    - A new session-scoped cancel shell helper (next to `scripts/cancel-rlcr-loop.sh`) accepts a session id and cancels only that session.
    - The dashboard cancel UI hits a per-session API; cancelling session A does not affect session B.
  - Negative Tests:
    - Calling the per-session cancel endpoint without specifying a session id returns 400, not a project-wide cancel.
    - The dashboard does NOT directly call the existing project-global `scripts/cancel-rlcr-loop.sh` without a session id.

- AC-8: Multi-instance / project-isolation cleanups (per DEC-3 = CLI-fixed single project).
  - Positive Tests:
    - `viz/scripts/viz-start.sh` (or its replacement) uses a per-project tmux session name so starting a second project's dashboard does NOT kill the first.
    - The per-project port file `.humanize/viz.port` is also per-project and does not collide.
    - The server binds to one project chosen at startup via `--project`; there is no runtime project switch endpoint.
  - Negative Tests:
    - `viz/server/app.py` no longer exposes `/api/projects/switch` (or it returns 410/501 with a deprecation message).
    - `viz/static/js/app.js` and `viz/static/js/actions.js` no longer render or wire a project switcher / "+ Add" UI; tests grep for these handlers and assert their removal.
    - Starting `humanize monitor web --project A` while a `--project B` instance is already running does NOT terminate the project-B server.

- AC-9: Test coverage matrix.
  - Positive Tests (the suite must include and pass):
    - Two concurrent active RLCR sessions render and stream independently.
    - Session with `.humanize/rlcr/<session>` metadata but no cache logs yet (startup race) renders without crashing and recovers when logs appear.
    - Cache-log truncation/rotation triggers a documented resync rather than silent stall.
    - Remote-mode auth enforcement: missing/invalid token => 401 on every data and control endpoint.
    - Project-isolation: starting a second `humanize monitor web --project <other>` does NOT affect the first.
    - Backward-compat: `humanize monitor rlcr|skill|codex|gemini` outputs unchanged (snapshot tests).
    - Cache-path / session-mapping parity tests against `scripts/humanize.sh` (the source of truth at lines around 284-368).
  - Negative Tests:
    - Tests do NOT write into the user's real `~/.humanize` or `~/.cache/humanize`; all fixtures live under a tmp dir or repo `tests/` fixture tree.
    - No test depends on network access to the public internet.

- AC-10: Code style compliance.
  - Positive Tests:
    - Grep over `viz/`, `scripts/`, and changed `commands/`/`hooks/` files for the literal substrings `AC-`, `Milestone`, `Step `, `Phase ` (with trailing space) returns zero matches in implementation code or comments (matches in plan/doc files do not count).
  - Negative Tests:
    - Adding new code with any of those workflow markers fails the style check.

## Path Boundaries

Path boundaries define the acceptable range of implementation quality and choices.

### Upper Bound (Maximum Acceptable Scope)

The implementation provides:
- An RLCR-specific Python helper (e.g. `viz/server/rlcr_sources.py`) that owns session enumeration and cache-log path discovery, with parity tests against `scripts/humanize.sh` (lines around 284-368).
- A frozen one-page event-protocol contract document (output of T2 architecture review) that fixes snapshot+byte-offset semantics, truncation/rotation handling, and the per-session vs project channel scoping.
- Per-session SSE streams over HTTP(S), each carrying an initial snapshot followed by append events identified by file path + byte offset.
- Bearer-token auth via query parameter on SSE streams and via `Authorization` header on standard HTTP endpoints; flask_sock WebSocket retained ONLY for localhost-bound deployments.
- Session-targeted cancel: a new `scripts/cancel-rlcr-session.sh` (or named equivalent) helper plus a per-session API endpoint, fully tested.
- A multi-loop UI grid that always shows every active session at once, with an inline expand-to-detail per-session log pane (no full-page navigation required to see live logs).
- A single-project-per-server CLI model: `humanize monitor web --project <path>`. The `/api/projects/switch` endpoint and the `+ Add` / Switch UI elements in `viz/static/js/app.js` and `viz/static/js/actions.js` are fully removed.
- Per-project tmux session naming and per-project port file for the optional `--daemon` mode (per DEC-1).
- Documentation for two remote-deployment patterns (SSH tunnel example FIRST, LAN bind example SECOND) plus an upgrade note explaining the `/humanize:viz` removal.
- Full test matrix per AC-9.

### Lower Bound (Minimum Acceptable Scope)

The implementation provides:
- Extensions to the existing `viz/server/parser.py` and `viz/server/watcher.py` so they additionally ingest cache round logs (`codex-run.log`, `codex-review.log`, gemini variants when present) and emit append events with byte offsets.
- A new per-session SSE endpoint in `viz/server/app.py` that supports the snapshot+offset protocol agreed in the T2 contract document, including a documented resync path for truncation.
- A new `humanize monitor web` dispatch entry in `scripts/humanize.sh` (alongside `rlcr|skill|codex|gemini`) that runs the dashboard in the foreground by default; an optional `--daemon` flag launches the existing tmux-managed server with a per-project tmux name and port file.
- `--host`, `--port`, `--auth-token` flags in `viz/server/app.py` (and forwarded by `humanize monitor web`); the server binds to `127.0.0.1` by default; non-localhost binding requires a non-empty token; unauthenticated remote requests are rejected on EVERY data and control endpoint, not just mutators.
- Removal of the server-global project switch: `/api/projects/switch` and the `+ Add` / Switch UI flows in `viz/static/js/app.js` and `viz/static/js/actions.js` are removed. `viz-projects.json` is no longer mutated by the server in v1.
- Removal of `/humanize:viz`: `commands/viz.md` and `skills/humanize-viz/SKILL.md` are deleted; a brief upgrade note is added to `README.md` (or equivalent) pointing users at `humanize monitor web`.
- The session-targeted cancel helper and per-session cancel API (per DEC-2 = build session-scoped cancel).
- All tests in AC-9 are present and pass in CI.
- Documentation: at minimum, the SSH tunnel deployment pattern.

### Allowed Choices

- Can use:
  - The existing Flask + flask_sock stack (retained for localhost) plus a new SSE endpoint for per-session log streams.
  - Reusing or extracting helper logic from `scripts/humanize.sh` for RLCR-specific cache-path discovery (RLCR-only — do not merge skill-monitor cache rules).
  - Per-session byte offsets, file-path-keyed event streams.
  - Either `python -m venv` (current `viz-start.sh` model) or system python for the foreground CLI invocation.
  - Token sources: CLI flag `--auth-token <value>`, env var `HUMANIZE_VIZ_TOKEN`, or a token file at `${XDG_CONFIG_HOME:-$HOME/.config}/humanize/viz-token`.
- Cannot use:
  - New Claude hooks added solely to capture data for the dashboard.
  - Default network bind to `0.0.0.0` (must be opt-in).
  - OAuth / OIDC / external IAM providers in v1.
  - A cross-language shared "monitor-core" library that conflates the RLCR session model with the skill-invocation model.
  - WebSocket as the remote-mode transport for log streams (browser WS cannot set `Authorization` headers; remote streams must be SSE per DEC-4). flask_sock WS may remain for localhost-bound use.
  - Project-global cancel paths wired to per-session UI without explicit user warnings (per DEC-2 the dashboard MUST use a session-scoped cancel helper).

> **Note on Deterministic Designs**: DEC-1, DEC-2, DEC-3, and DEC-4 have already been fixed by user decision (recorded under `## Pending User Decisions`). The path boundaries above already reflect those choices and do not leave room for alternative interpretations of those four points.

## Feasibility Hints and Suggestions

> **Note**: This section is for reference and understanding only. These are conceptual suggestions, not prescriptive requirements.

### Conceptual Approach

One viable path:

1. Branch hygiene as a parallel preflight track. Rebase `feat/viz-dashboard` onto `upstream/dev` (currently 9 commits ahead). Conflicts are expected to be small because the branch already includes upstream commits 338b4dd (PR-loop removal) and 016caca (monitor split).
2. Add a small, RLCR-specific Python module (e.g. `viz/server/rlcr_sources.py`) that owns:
   - listing all session directories under `.humanize/rlcr/<project>/`,
   - mapping each session to its cache-log directory under `~/.cache/humanize/<sanitized-project>/<session>/`,
   - returning per-session live log file paths (`round-N-codex-run.log`, `round-N-codex-review.log`, gemini variants).
   Cover this module with parity tests that compare its outputs against the discovery logic in `scripts/humanize.sh` (around lines 284-368).
3. Run a focused architecture-review consultation (T2, `analyze` task via `/humanize:ask-codex`) to freeze the streaming protocol contract: snapshot+offset semantics, truncation/rotation behavior, per-session vs project channel scoping. Output a one-page contract document that subsequent code refers to.
4. Extend `viz/server/parser.py` to use the new helper and to read cache round logs (with graceful fallback when files are missing/partial). Extend `viz/server/watcher.py` to also watch the cache log directory and emit append events with `(path, offset, len)`.
5. Add a per-session SSE endpoint in `viz/server/app.py` keyed by session id; it serves a snapshot then appends; it survives truncation by detecting size shrink and restarting from offset 0 with a documented resync event.
6. Add `humanize monitor web` to the dispatch in `scripts/humanize.sh` next to `rlcr|skill|codex|gemini`. Foreground default; pass-through `--host`, `--port`, `--auth-token`, `--project`, `--daemon`. The `--daemon` path delegates to a refactored `viz/scripts/viz-start.sh` that uses a per-project tmux name and per-project port file.
7. Delete `commands/viz.md` and `skills/humanize-viz/SKILL.md`; add a one-line note in `README.md` directing users to `humanize monitor web`.
8. Replace the project switcher backend by a CLI-fixed model: remove `/api/projects/switch` from `viz/server/app.py`; remove the switch / + Add UI from `viz/static/js/app.js` and `viz/static/js/actions.js`. The frontend reads only the project the server was started against.
9. Add `--host`, `--port`, `--auth-token`. Default `--host=127.0.0.1`. If host is non-localhost, require a non-empty token. Apply auth middleware to ALL data and control endpoints (session list, session detail, SSE streams, cancel/report). Token propagation in the frontend: `Authorization: Bearer <t>` for fetch; `?token=<t>` query parameter for `EventSource`.
10. Build the session-targeted cancel helper (e.g. `scripts/cancel-rlcr-session.sh`) and wire a `POST /api/sessions/<id>/cancel` route to it. Mirror the existing project-global script's safety conventions.
11. Multi-loop UI: render all active sessions on the home page in a grid, each with an inline live-log pane that opens an SSE stream when expanded. Historical sessions are listed below.
12. Build the test matrix per AC-9. Use a tmp `.humanize/rlcr/` and tmp `~/.cache/humanize/` fixture tree per test.
13. Document the SSH tunnel deployment pattern first; add a LAN bind example second.

### Relevant References

- `scripts/humanize.sh:1196` — `humanize` dispatcher; this is where `monitor web` is added.
- `scripts/humanize.sh` (around lines 284-368) — current RLCR cache-log discovery logic; source of truth for parity tests.
- `scripts/lib/monitor-common.sh` — shared shell helpers (single-session by design); reused for terminal monitor only.
- `scripts/lib/monitor-skill.sh` — skill cache discovery (separate model from RLCR); deliberately NOT merged into the RLCR helper.
- `scripts/cancel-rlcr-loop.sh` — existing project-global cancel; the new session-scoped helper sits next to it.
- `viz/server/parser.py` — RLCR session parser; extended to read cache logs.
- `viz/server/watcher.py` — watchdog observer; extended to watch cache log dirs and emit append events.
- `viz/server/app.py` — Flask routes; gains `--host/--port/--auth-token`, per-session SSE, session-scoped cancel; loses `/api/projects/switch`.
- `viz/scripts/viz-start.sh` — tmux launcher; refactored for per-project naming and `--daemon` mode.
- `viz/static/js/app.js` and `viz/static/js/actions.js` — UI; loses project switcher; gains multi-session grid + per-session SSE client with token propagation.
- `commands/viz.md`, `skills/humanize-viz/SKILL.md` — deleted.
- `tests/test-viz.sh` — extended with the AC-9 matrix.
- `README.md`, `docs/usage.md` — gain monitor `web` entry and the remote-deploy guide.

## Dependencies and Sequence

### Milestones

1. M0 Branch hygiene (preflight, parallel track):
   - Sub-step A: Fetch `upstream/dev`, list the 9 commits ahead, rebase `feat/viz-dashboard`, resolve conflicts.
   - Sub-step B: Re-run existing tests (`tests/test-viz.sh` and any monitor smoke test).
   - This milestone is NOT a hard gate for design tasks; T1+ may proceed once conflicts are mechanically resolved.
2. M1 Discovery and ingestion:
   - Sub-step A: RLCR-specific session+cache-log discovery helper (T1).
   - Sub-step B: Parser and watcher extensions to ingest cache round logs (T3, T4).
3. M2 Streaming protocol freeze (architecture gate):
   - Sub-step A: Architecture review (T2, analyze) producing a one-page contract document for snapshot+offset semantics, truncation handling, channel scoping.
   - This milestone gates T3/T4/T5 implementation details that depend on the contract.
4. M3 Live multi-loop streaming:
   - Sub-step A: Per-session SSE endpoint (T5).
   - Sub-step B: Multi-loop UI with independent live log panes (T6).
5. M4 CLI consolidation:
   - Sub-step A: Add `humanize monitor web` to dispatch (T8).
   - Sub-step B: Per-project tmux + port file refactor (T9).
   - Sub-step C: Remove `/humanize:viz` (T12).
6. M5 Remote access + safety:
   - Sub-step A: `--host/--port/--auth-token` + auth middleware on all surfaces (T11).
   - Sub-step B: Remove server-global project switch and frontend switcher (T10).
   - Sub-step C: Session-targeted cancel helper + endpoint (T7).
7. M6 Tests + docs:
   - Sub-step A: Test matrix per AC-9 (T13).
   - Sub-step B: Documentation: README monitor section + remote-deploy guide (T14).

Relative dependencies: M2 must precede the streaming-shape decisions in M1's parser/watcher work and all of M3. M5 access-control work (T11) depends on the basic streaming endpoints (M3) being available so it can layer auth on top. M6 tests depend on M3 + M4 + M5 being feature-complete. M0 is independent and can run alongside M1 until conflicts are mechanically resolved.

## Task Breakdown

Each task includes exactly one routing tag:
- `coding`: implemented by Claude
- `analyze`: executed via Codex (`/humanize:ask-codex`)

| Task ID | Description | Target AC | Tag | Depends On |
|---------|-------------|-----------|-----|------------|
| T0 | Preflight (parallel track): rebase `feat/viz-dashboard` onto `upstream/dev` (9 commits), resolve conflicts, rerun existing tests. NOT a hard gate for T1+. | AC-9 | coding | - |
| T1 | RLCR-specific session + cache-log discovery helper (e.g. `viz/server/rlcr_sources.py`); RLCR-only (do NOT merge skill-monitor cache rules); enumerates ALL sessions under `.humanize/rlcr/`. | AC-2, AC-3 | coding | - |
| T2 | Architecture review: select event protocol shape (snapshot + byte-offset tail, truncation/rotation behavior, per-session vs project channels) and confirm transport (SSE for remote streams + retained flask_sock for localhost only). Output: one-page contract document committed under `docs/`. | AC-4 | analyze | T1 |
| T3 | Extend `viz/server/parser.py` to ingest cache round logs (`codex-run.log`, `codex-review.log`, gemini variants); fall back gracefully when missing or partially written. | AC-2, AC-4 | coding | T2 |
| T4 | Extend `viz/server/watcher.py` to also watch the cache log directory; emit per-file append events `(path, offset, length)` per the T2 contract. | AC-4 | coding | T2 |
| T5 | Per-session SSE endpoint in `viz/server/app.py` per the T2 contract; supports initial snapshot then append; handles rotation/truncation resync. | AC-4 | coding | T3, T4 |
| T6 | Multi-loop UI in `viz/static/js/app.js`: list ALL sessions, partition into Active vs Historical, render every active session simultaneously with an independent live log pane (no fallback to single-session detail view for active loops). | AC-3, AC-5 | coding | T5 |
| T7 | Session-scoped cancel: new `scripts/cancel-rlcr-session.sh` helper + `POST /api/sessions/<id>/cancel` route + UI wiring; do NOT delegate to the project-global `scripts/cancel-rlcr-loop.sh`. | AC-7 | coding | T5 |
| T8 | Add `humanize monitor web` to the dispatch in `scripts/humanize.sh` next to `rlcr|skill|codex|gemini`; foreground default; pass-through `--host/--port/--auth-token/--project/--daemon`; preserve existing subcommands and usage text. | AC-1 | coding | - |
| T9 | Refactor `viz/scripts/viz-start.sh`: per-project tmux session name (no more global `humanize-viz`); per-project port file; only invoked by the `--daemon` path of `humanize monitor web`. | AC-8 | coding | T8 |
| T10 | Remove server-global project mutation in `viz/server/app.py`: remove `/api/projects/switch` (or convert to read-only listing); remove project switcher / + Add flows in `viz/static/js/app.js` and `viz/static/js/actions.js`; do not mutate `viz-projects.json` from server. | AC-5, AC-8 | coding | T8 |
| T11 | Add `--host`, `--port`, `--auth-token` to `viz/server/app.py` + propagate through `viz/scripts/viz-start.sh` and `humanize monitor web`; default `--host=127.0.0.1`; reject non-local startup without token; gate ALL data/control endpoints (session list, session detail, SSE stream, cancel) behind token in remote mode; frontend token propagation: `Authorization: Bearer` for fetch + `?token=...` for SSE `EventSource`. | AC-6 | coding | T5, T10 |
| T12 | Remove `/humanize:viz`: delete `commands/viz.md` and `skills/humanize-viz/SKILL.md`; add a one-line upgrade note in `README.md` pointing users at `humanize monitor web`. | AC-1 | coding | T8 |
| T13 | Test matrix per AC-9: concurrent active loops, missing-cache-log startup, log rotation/truncation recovery, remote auth on every endpoint, project isolation, monitor backward-compat, per-project port-file collision avoidance, parity tests for cache-path/session mapping vs `scripts/humanize.sh`. | AC-9 | coding | T6, T7, T11 |
| T14 | Docs: README monitor section update; remote-deploy guide (SSH tunnel example FIRST, LAN bind example SECOND); upgrade note for `/humanize:viz` removal. | AC-1, AC-6 | coding | T13 |

## Claude-Codex Deliberation

### Agreements

- Reusing the existing `humanize monitor` data sources (the `.humanize/rlcr/<session>/*` files plus `~/.cache/humanize/<project>/<session>/round-*-codex-{run,review}.log`) is the correct architecture; the dashboard is a reader, not a parallel capture pipeline.
- Moving the entry point into the `humanize monitor` dispatch in `scripts/humanize.sh` and removing `/humanize:viz` is a natural extension of the existing CLI shape and avoids a stranded slash-command surface.
- Tightening network exposure with localhost default plus explicit `--host` + `--auth-token` for remote opt-in is the right baseline given the unauthenticated mutators in the current `viz/server/app.py`.
- The current global `humanize-viz` tmux session name in `viz/scripts/viz-start.sh` is a real collision bug; per-project naming is required.
- The feat/viz-dashboard branch already includes upstream commits 338b4dd (PR-loop removal) and 016caca (monitor split). The rebase is therefore drift cleanup (9 commits), not a missing prerequisite.
- The streaming protocol must support snapshot + byte-offset append + truncation/rotation resync; "no full-file refetch loop" was tightened from "append-only forever" to allow legitimate snapshot/resync paths.

### Resolved Disagreements

- Topic: Should the rebase be the dependency root for the entire plan (M0/T0 as a hard gate)?
  - Claude (v1): yes, M0 first, T0 blocks all other tasks.
  - Codex: no, branch hygiene already includes the critical upstream commits; making T0 a hard gate turns unrelated upstream drift into a blocker for design.
  - Resolution: M0/T0 is a parallel preflight track. T1+ may proceed once rebase conflicts are mechanically resolved. Recorded in M0 description and in T0's wording.

- Topic: Should there be a single shared "monitor-core" library consumed by both terminal and web monitors?
  - Claude (v1): yes, extract a shared module to keep terminal and web in lockstep.
  - Codex: no, the shell `monitor-common.sh` is single-session by design and the web side is Python; forcing a cross-language core conflates models.
  - Resolution: do NOT build a shared cross-language core. Keep terminal helpers in shell where they help; build a separate small RLCR-specific Python helper for the web side (`viz/server/rlcr_sources.py`) and validate it via parity tests against `scripts/humanize.sh` cache logic.

- Topic: Should T2 (extract shared cache-discovery helper) merge logic from `scripts/humanize.sh` (RLCR) with `scripts/lib/monitor-skill.sh` (skill invocations)?
  - Claude (v1): yes, factor the cache-discovery patterns into one helper.
  - Codex: no, RLCR session caches and skill invocation caches are adjacent but different models; merging conflates them.
  - Resolution: T1 helper is RLCR-specific only. Skill-monitor cache rules stay separate.

- Topic: When should the architecture review for the streaming protocol shape happen?
  - Claude (v1): T13 at the end, after watcher and endpoint code.
  - Codex: backwards; it has to gate watcher and endpoint design.
  - Resolution: T2 is now an `analyze` task that runs BEFORE T3/T4/T5 and outputs a one-page contract document.

- Topic: Should the streaming protocol forbid full-file refetch entirely?
  - Claude (v1): yes, append-only.
  - Codex: append-only forever breaks late-joining clients and rotation recovery.
  - Resolution: AC-4 reworded to "snapshot + byte-offset append + documented resync" and "no polling loop that re-fetches the full file body on every update." Both intents preserved.

- Topic: Is removing `/api/projects/switch` enough to fix the multi-project bug?
  - Claude (v1): yes.
  - Codex: no, the frontend switcher / + Add flows in `viz/static/js/app.js` and `viz/static/js/actions.js` would still be wired.
  - Resolution: T10 expanded to also remove the frontend switcher chrome; AC-8 expanded to test for the absence of these UI elements.

- Topic: Does remote auth need to cover read endpoints, or just mutators?
  - Claude (v2): just mutators.
  - Codex: no, read endpoints serve session data too; remote unauth must be blocked everywhere.
  - Resolution: AC-6 expanded; T11 expanded to cover ALL data and control surfaces, plus token propagation in the frontend (`Authorization` for fetch, `?token=...` for SSE).

- Topic: Cancel semantics in the multi-loop UI.
  - Claude (v1/v2): keep cancel + report.
  - Codex: the existing `scripts/cancel-rlcr-loop.sh` is project-global, not session-targeted; either build a session-scoped path or freeze v1 with cancel disabled.
  - Resolution: User chose DEC-2 = build session-scoped cancel. T7 builds a new `scripts/cancel-rlcr-session.sh` helper plus a per-session API and tests it.

- Topic: Auth transport for live log streams (browser WebSocket cannot set `Authorization` header).
  - Claude (v2): bearer token via `--auth-token`, transport unspecified.
  - Codex: WS in browsers cannot send arbitrary auth headers; either define a precise WS auth handshake or drop WS for remote.
  - Resolution: User chose DEC-4 = SSE over HTTPS with token query-param for remote streams; flask_sock WS retained for localhost only.

### Convergence Status

- Final Status: `converged`
- Convergence rounds executed: 3 (round 1 surfaced 7 required changes; round 2 surfaced 5 tighteners; round 3 returned no required changes and no high-impact disagreements).

## Pending User Decisions

All decisions raised during planning have been resolved by the user. None remain `PENDING`.

- DEC-1: How should `humanize monitor web` be launched (lifecycle)?
  - Claude Position: Foreground default + optional `--daemon` flag; matches CLI monitor UX and avoids hidden processes.
  - Codex Position: Either foreground or daemon is defensible, but the v1 plan must pick one to avoid mixed ownership of `viz/scripts/viz-start.sh`.
  - Tradeoff Summary: Foreground = matches `humanize monitor rlcr` UX, no orphan tmux sessions, simpler test harness. Daemon = "always on" convenience, but hidden processes and tmux name collisions to manage.
  - Decision Status: `Foreground default + --daemon opt-in` (user-confirmed).

- DEC-2: Cancel button policy in the multi-loop dashboard for v1?
  - Claude Position: Build a session-scoped cancel.
  - Codex Position: Either build a session-scoped path or freeze v1 with cancel disabled; the existing `scripts/cancel-rlcr-loop.sh` is project-global and unsafe in multi-loop mode.
  - Tradeoff Summary: Build = correct UX, more work (new shell helper + API + tests). Disable = smaller v1, defers the cancel feature. Keep-global = correctness bug.
  - Decision Status: `Build session-scoped cancel` (user-confirmed). T7 builds `scripts/cancel-rlcr-session.sh`.

- DEC-3: How should the dashboard handle multiple projects?
  - Claude Position: CLI-fixed single project per server (`humanize monitor web --project <path>`); multi-project means run multiple processes.
  - Codex Position: Either CLI-fixed, per-client state, or separate instances per project; ambiguity blocks AC-5/AC-8.
  - Tradeoff Summary: CLI-fixed = clean isolation, simple backend, removes the server-global mutation bug, costs the in-server switcher convenience. Per-client = complex backend. Server-global = current bug.
  - Decision Status: `CLI-fixed single project per server` (user-confirmed). `/api/projects/switch` is removed; frontend switcher chrome is removed.

- DEC-4: Remote auth transport for live log streaming?
  - Claude Position: Bearer token; transport open.
  - Codex Position: Browser WebSocket clients cannot set `Authorization` header; pick SSE for remote, or define a precise WS handshake.
  - Tradeoff Summary: SSE = clean browser auth via query-param token over HTTPS, append-shaped traffic matches SSE strength, drops bidirectional control. WS = bidirectional but auth requires custom subprotocol/handshake.
  - Decision Status: `SSE over HTTPS with token query-param for remote streams; flask_sock WS retained for localhost only` (user-confirmed).

- AC-4 latency budget: hard requirement vs directional target?
  - Claude Position: Hard requirement (<=2s) to give "live" a precise meaning.
  - Codex Position: Either is defensible; the plan must record the choice.
  - Tradeoff Summary: Hard = strict CI assertion, sharper failure mode. Directional = looser SLA, easier to pass under load.
  - Decision Status: `Hard requirement (<=2s end-to-end)` (user-confirmed). AC-4 negative tests fail CI when median latency exceeds 2.0s under nominal load.

## Implementation Notes

### Code Style Requirements

- Implementation code and comments must NOT contain plan-specific terminology such as "AC-", "Milestone", "Step", "Phase", or similar workflow markers. These belong only in plan documentation.
- Use descriptive, domain-appropriate naming in code instead. For example, prefer `RLCRSessionEnumerator` / `cache_log_discovery` / `live_log_stream` over names that reference plan task ids.
- All implementation, comments, tests, and documentation must be in English. No emoji or CJK characters in code or comments (per project rules in `.claude/CLAUDE.md`).
- Per project rules in `.claude/CLAUDE.md`: any commit on `main` must include a version bump in `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `README.md` (the "Current Version" line). For commits on `feat/viz-dashboard`, the branch's `version` in those three files must already be ahead of `main`'s version. Implementation work must respect that policy.

### Branch and Rebase Note

- Implementation begins on `feat/viz-dashboard` (NOT the current `feat/rlcr-integral-context` branch).
- T0 rebases `feat/viz-dashboard` onto `upstream/dev` (9 commits ahead). It is a parallel preflight, not a hard gate for design tasks.
- `gen-plan` itself does not perform any git operation. The rebase happens at the start of the implementation loop (`/humanize:start-rlcr-loop`).

--- Original Design Draft Start ---

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

--- Original Design Draft End ---
