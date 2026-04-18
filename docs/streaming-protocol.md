# Streaming Protocol Contract

## Status
Frozen on April 17, 2026. Any change requires a new dated revision section appended below.

## Scope
This contract governs live streaming of RLCR round log files discovered for a single server project from `XDG_CACHE_HOME` or `HOME/.cache/humanize/SANITIZED/SID/round-N-{codex,gemini}-{run,review}.log`, where `SANITIZED` follows the rule implemented in `viz/server/rlcr_sources.py`. Session identity and liveness are derived from `.humanize/rlcr/SID/` metadata, but this contract does not define polling, parsing, or REST retrieval of frontmatter status files, goal-tracker files, round summaries, or review-result files.

## Channel Model
Streams are per-session, per-file. A stream is identified by `GET /api/sessions/SID/logs/FNAME`, where `SID` is the RLCR session id and `FNAME` is the exact cache-log basename such as `round-3-codex-run.log`. Each URL maps to one logical byte stream for one file generation within one session. Multiple sessions MAY be active concurrently, and clients MAY open multiple such channels in parallel.

## Event Shape
The live-log transport is Server-Sent Events. Every SSE frame MUST include `event: TYPE`, `id: N`, and one `data:` line containing exactly one JSON object. `TYPE` MUST equal the JSON `type` field. `id` MUST be a strictly increasing decimal string within the stream. `path` MUST be the canonical `FNAME` for the channel, not an absolute filesystem path. Raw file bytes MUST be base64 encoded into `bytes_b64` with standard RFC 4648 base64 and no line breaks. Payloads are: `snapshot` = `{ "type": "snapshot", "path": "...", "offset": 0, "bytes_b64": "...", "eof": false }`; `append` = `{ "type": "append", "path": "...", "offset": N, "bytes_b64": "..." }`; `resync` = `{ "type": "resync", "path": "...", "reason": "truncated|rotated|recreated|missing|overflow" }`; `eof` = `{ "type": "eof", "path": "..." }`. `offset` is the starting byte offset represented by `bytes_b64`.

## Truncation and Rotation Resync
The server MUST track the last emitted byte offset for each stream and, on POSIX, MUST also track `(st_dev, st_ino)` for the currently open file. If observed size shrinks below the last known offset, or `(st_dev, st_ino)` changes, or the file disappears, the server MUST emit `resync` and MUST restart the channel at offset `0` with a fresh `snapshot` as soon as the current file generation is readable again.

## Snapshot vs Append Semantics
A late-joining client MUST receive `snapshot` first. After that, only `append` events flow until a resync condition fires. Initial snapshots MUST be chunked at a maximum of `64 KiB` raw bytes per event; large files therefore produce multiple ordered `snapshot` events with increasing `offset` values until current EOF. `snapshot.eof=true` MAY be used only when the file is already terminal at snapshot time.

## Transport Mapping
When the server host is not `127.0.0.1`, live logs MUST be delivered only as SSE over HTTPS, and clients MUST authenticate with `?token=BEARER` on the stream URL. In that mode, WebSocket endpoints MUST be disabled or otherwise unreachable. When the server host equals `127.0.0.1`, SSE remains the live-log transport; `flask_sock` WebSocket MAY serve coarse session-level notifications such as `session-list-changed`, but MUST NOT carry per-file append data.

## Reconnect Behavior
On disconnect, the client SHOULD reconnect to the same stream URL and send `Last-Event-Id`. The server MUST retain the last `256` events per stream and MUST replay all events newer than that id when available. If the requested id is older than retained history or invalid for the current file generation, the server MUST recover by emitting `resync` and then a fresh `snapshot` from offset `0`.

## Latency Budget
Under nominal load of one project, up to `5` concurrent active sessions, and append rate not exceeding `100 KB/s` per stream, median append-to-render latency MUST be `<= 2.0s`. Tail `p95` latency MUST be `<= 5.0s`. Failure of the median assertion in CI MUST fail the build.

## Backpressure
If a client cannot keep up, the server MAY drop the oldest pending or retained `append` events for that stream, but it MUST emit a final `resync` with reason `overflow` and then provide a fresh `snapshot`. Silent data loss is forbidden.

## Out of Scope
This contract does not define the cancel control channel at `POST /api/sessions/SID/cancel`, project switching, daemon lifecycle, token issuance or validation, coarse session-list events, or any non-log REST payloads. Those surfaces require their own specifications.

## Example Event Stream
```text
event: snapshot
id: 101
data: {"type":"snapshot","path":"round-3-codex-run.log","offset":0,"bytes_b64":"U3RhcnQK","eof":false}

event: append
id: 102
data: {"type":"append","path":"round-3-codex-run.log","offset":6,"bytes_b64":"TW9yZQo="}

event: append
id: 103
data: {"type":"append","path":"round-3-codex-run.log","offset":11,"bytes_b64":"RGF0YQo="}

event: resync
id: 104
data: {"type":"resync","path":"round-3-codex-run.log","reason":"rotated"}

event: snapshot
id: 105
data: {"type":"snapshot","path":"round-3-codex-run.log","offset":0,"bytes_b64":"TmV3IGZpbGUK","eof":false}
```
