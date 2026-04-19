#!/usr/bin/env bash
#
# Behavior tests for viz/server/log_streamer.py and the parser/watcher
# extensions added in the streaming block (T3+T4+T5).
#
# Covers the contract in docs/streaming-protocol.md:
#   - Snapshot of an existing file (chunked at 64 KiB)
#   - Append after new bytes are written
#   - Truncation: file size shrinks below known offset
#   - Rotation: same path, new inode
#   - Missing file at startup: no events, no crash
#   - Missing then reappear: resync(recreated) + fresh snapshot
#   - EOF: subsequent polls are no-ops
#   - Replay with Last-Event-Id: in-window returns newer events; out
#     of window returns resync(overflow)
#   - Parser cache_logs_for_session integrates rlcr_sources discovery
#
# No network access; all fixtures live under per-test mktemp tree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VIZ_SERVER_DIR="$PLUGIN_ROOT/viz/server"

echo "========================================"
echo "Streaming block (T3+T4+T5)"
echo "========================================"

if ! command -v python3 &>/dev/null; then
    echo "SKIP: python3 not available"
    exit 0
fi

PASS_COUNT=0
FAIL_COUNT=0

_pass() { printf '\033[0;32mPASS\033[0m: %s\n' "$1"; PASS_COUNT=$((PASS_COUNT+1)); }
_fail() { printf '\033[0;31mFAIL\033[0m: %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT+1)); }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CACHE_DIR="$TMP_DIR/cache"
mkdir -p "$CACHE_DIR"

# Helper: run a python driver and capture its output
_run_py() {
    python3 -c "
import sys
sys.path.insert(0, '$VIZ_SERVER_DIR')
$1
"
}

# ─── Test Group 1: Missing file at startup ───
echo
echo "Group 1: Missing file at startup"

OUTPUT="$(_run_py "
from log_streamer import LogStream
stream = LogStream('$CACHE_DIR', 'round-0-codex-run.log')
events = stream.snapshot()
print('SNAPSHOT_COUNT:', len(events))
events = stream.poll()
for e in events:
    print('POLL:', e['type'], e.get('reason', ''))
")"

if grep -q '^SNAPSHOT_COUNT: 0$' <<<"$OUTPUT"; then
    _pass "snapshot of missing file emits no events"
else
    _fail "expected 0 snapshot events, got: $(grep '^SNAPSHOT_COUNT' <<<"$OUTPUT")"
fi

if grep -q '^POLL: resync missing$' <<<"$OUTPUT"; then
    _pass "first poll of missing file emits resync(missing)"
else
    _fail "expected resync(missing) on first poll, got: $(grep '^POLL:' <<<"$OUTPUT")"
fi

# ─── Test Group 2: Snapshot existing file ───
echo
echo "Group 2: Snapshot of existing file"

LOG="$CACHE_DIR/round-1-codex-run.log"
printf 'hello world' > "$LOG"

OUTPUT="$(_run_py "
import base64
from log_streamer import LogStream
stream = LogStream('$CACHE_DIR', 'round-1-codex-run.log')
events = stream.snapshot()
print('COUNT:', len(events))
for e in events:
    print('TYPE:', e['type'])
    print('OFFSET:', e['offset'])
    print('BYTES:', base64.b64decode(e['bytes_b64']).decode('ascii'))
    print('EOF:', e['eof'])
")"

if grep -q '^COUNT: 1$' <<<"$OUTPUT"; then
    _pass "snapshot emits one event for small file"
else
    _fail "expected 1 snapshot event, got: $(grep '^COUNT' <<<"$OUTPUT")"
fi

if grep -q '^TYPE: snapshot$' <<<"$OUTPUT" && grep -q '^OFFSET: 0$' <<<"$OUTPUT" && grep -q '^BYTES: hello world$' <<<"$OUTPUT" && grep -q '^EOF: False$' <<<"$OUTPUT"; then
    _pass "snapshot payload contains 'hello world' at offset 0 with eof=False"
else
    _fail "snapshot payload wrong: $OUTPUT"
fi

# ─── Test Group 3: Append after writes ───
echo
echo "Group 3: Append after writes"

OUTPUT="$(_run_py "
import base64
from log_streamer import LogStream
stream = LogStream('$CACHE_DIR', 'round-1-codex-run.log')
stream.snapshot()
with open('$LOG', 'ab') as f:
    f.write(b' more')
events = stream.poll()
for e in events:
    print('TYPE:', e['type'])
    print('OFFSET:', e['offset'])
    print('BYTES:', base64.b64decode(e['bytes_b64']).decode('ascii'))
")"

if grep -q '^TYPE: append$' <<<"$OUTPUT" && grep -q '^OFFSET: 11$' <<<"$OUTPUT" && grep -q '^BYTES:  more$' <<<"$OUTPUT"; then
    _pass "poll after append emits append event with correct offset and bytes"
else
    _fail "append event wrong: $OUTPUT"
fi

# ─── Test Group 4: Truncation triggers resync + fresh snapshot ───
echo
echo "Group 4: Truncation"

OUTPUT="$(_run_py "
from log_streamer import LogStream
stream = LogStream('$CACHE_DIR', 'round-1-codex-run.log')
stream.snapshot()
# Truncate file to a smaller size in place
with open('$LOG', 'wb') as f:
    f.write(b'short')
events = stream.poll()
for e in events:
    print('TYPE:', e['type'], e.get('reason', ''), 'OFFSET:', e.get('offset', '-'))
")"

# Expect: resync(truncated), snapshot
if grep -q '^TYPE: resync truncated' <<<"$OUTPUT" && grep -q '^TYPE: snapshot' <<<"$OUTPUT"; then
    _pass "truncation triggers resync(truncated) followed by fresh snapshot"
else
    _fail "truncation behavior wrong: $OUTPUT"
fi

# ─── Test Group 5: Rotation (inode change) ───
echo
echo "Group 5: Rotation (file recreated with different inode)"

ROTLOG="$CACHE_DIR/round-2-codex-run.log"
printf 'first generation' > "$ROTLOG"

OUTPUT="$(_run_py "
import os
from log_streamer import LogStream
stream = LogStream('$CACHE_DIR', 'round-2-codex-run.log')
stream.snapshot()
# Rotate: rm + recreate produces a new inode
os.unlink('$ROTLOG')
with open('$ROTLOG', 'wb') as f:
    f.write(b'new generation')
events = stream.poll()
for e in events:
    print('TYPE:', e['type'], e.get('reason', ''))
")"

# We may see resync(missing) first if poll happens between unlink and recreate;
# in this test the recreate is synchronous so we expect resync(rotated) followed by snapshot.
# Allow either pattern as long as resync occurs and a snapshot follows.
if grep -q '^TYPE: resync' <<<"$OUTPUT" && grep -q '^TYPE: snapshot' <<<"$OUTPUT"; then
    _pass "rotation triggers resync followed by fresh snapshot"
else
    _fail "rotation behavior wrong: $OUTPUT"
fi

# ─── Test Group 6: Missing then reappear ───
echo
echo "Group 6: Missing file reappears"

REAP="$CACHE_DIR/round-3-codex-run.log"
OUTPUT="$(_run_py "
from log_streamer import LogStream
stream = LogStream('$CACHE_DIR', 'round-3-codex-run.log')
# Initial poll: file missing, expect resync(missing)
events = stream.poll()
for e in events:
    print('FIRST:', e['type'], e.get('reason', ''))
# Now create the file
with open('$REAP', 'wb') as f:
    f.write(b'hello')
events = stream.poll()
for e in events:
    print('SECOND:', e['type'], e.get('reason', ''))
")"

if grep -q '^FIRST: resync missing$' <<<"$OUTPUT" && \
   grep -q '^SECOND: resync recreated$' <<<"$OUTPUT" && \
   grep -q '^SECOND: snapshot ' <<<"$OUTPUT"; then
    _pass "missing -> reappear triggers resync(recreated) followed by snapshot"
else
    _fail "reappear behavior wrong: $OUTPUT"
fi

# ─── Test Group 7: EOF + subsequent polls ───
echo
echo "Group 7: EOF marking is sticky"

EOFLOG="$CACHE_DIR/round-4-codex-run.log"
printf 'done' > "$EOFLOG"
OUTPUT="$(_run_py "
from log_streamer import LogStream
stream = LogStream('$CACHE_DIR', 'round-4-codex-run.log')
stream.snapshot()
events = stream.mark_eof()
print('EOF:', events[0]['type'])
events = stream.mark_eof()
print('SECOND_EOF_COUNT:', len(events))
events = stream.poll()
print('POLL_AFTER_EOF_COUNT:', len(events))
")"

if grep -q '^EOF: eof$' <<<"$OUTPUT" && \
   grep -q '^SECOND_EOF_COUNT: 0$' <<<"$OUTPUT" && \
   grep -q '^POLL_AFTER_EOF_COUNT: 0$' <<<"$OUTPUT"; then
    _pass "eof event is one-shot; subsequent polls and eof are no-ops"
else
    _fail "eof stickiness wrong: $OUTPUT"
fi

# ─── Test Group 8: Replay with Last-Event-Id ───
echo
echo "Group 8: Replay with Last-Event-Id"

REPLOG="$CACHE_DIR/round-5-codex-run.log"
printf 'aaaaa' > "$REPLOG"

OUTPUT="$(_run_py "
from log_streamer import LogStream
stream = LogStream('$CACHE_DIR', 'round-5-codex-run.log')
snap = stream.snapshot()  # id 1
# Append twice
with open('$REPLOG', 'ab') as f:
    f.write(b'BBB')
ap1 = stream.poll()       # id 2
with open('$REPLOG', 'ab') as f:
    f.write(b'CCC')
ap2 = stream.poll()       # id 3
# Client only saw up through id 2; replay starting from id 2
replayed, in_window = stream.replay(2)
print('REPLAY_IN_WINDOW:', in_window)
print('REPLAY_COUNT:', len(replayed))
for e in replayed:
    print('REPLAY_ID:', e['id'], 'TYPE:', e['type'])
# Out-of-window: replay from a tiny id with retention exceeded
# Force overflow by manipulating retention; small fixture so replay an id below the window
# Retention is 256 so we cannot easily exceed it; just verify replay(0) returns ALL retained
all_replay, all_in_window = stream.replay(0)
print('REPLAY_ALL_COUNT:', len(all_replay))
print('REPLAY_ALL_IN_WINDOW:', all_in_window)
")"

if grep -q '^REPLAY_IN_WINDOW: True$' <<<"$OUTPUT" && \
   grep -q '^REPLAY_COUNT: 1$' <<<"$OUTPUT" && \
   grep -q '^REPLAY_ID: 3 TYPE: append$' <<<"$OUTPUT"; then
    _pass "in-window replay returns events newer than Last-Event-Id"
else
    _fail "in-window replay wrong: $OUTPUT"
fi

if grep -q '^REPLAY_ALL_COUNT: 3$' <<<"$OUTPUT" && grep -q '^REPLAY_ALL_IN_WINDOW: True$' <<<"$OUTPUT"; then
    _pass "replay(0) returns all retained events"
else
    _fail "replay(0) result wrong: $OUTPUT"
fi

# Also verify out-of-window: directly invoke replay with id much smaller than oldest after window slides
OUTPUT_OW="$(_run_py "
from log_streamer import LogStream, EVENT_RETENTION
import os
log = '$CACHE_DIR/round-6-codex-run.log'
with open(log, 'wb') as f:
    f.write(b'')
stream = LogStream('$CACHE_DIR', 'round-6-codex-run.log')
# Generate enough events to overflow the retention window
for i in range(EVENT_RETENTION + 5):
    with open(log, 'ab') as f:
        f.write(b'x')
    stream.poll()
# Replay from id 1 - should be out of window now (oldest id in window is 6)
replayed, in_window = stream.replay(1)
print('OW_IN_WINDOW:', in_window)
print('OW_TYPE:', replayed[0]['type'], replayed[0].get('reason', ''))
")"

if grep -q '^OW_IN_WINDOW: False$' <<<"$OUTPUT_OW" && grep -q '^OW_TYPE: resync overflow$' <<<"$OUTPUT_OW"; then
    _pass "out-of-window replay emits resync(overflow)"
else
    _fail "out-of-window replay wrong: $OUTPUT_OW"
fi

# ─── Test Group 9: Snapshot chunking at 64 KiB ───
echo
echo "Group 9: Snapshot chunking"

BIGLOG="$CACHE_DIR/round-7-codex-run.log"
# 130 KiB of bytes -> expect 3 snapshot chunks of (64,64,2) KiB
python3 -c "open('$BIGLOG','wb').write(b'x' * (130 * 1024))"

OUTPUT="$(_run_py "
from log_streamer import LogStream
stream = LogStream('$CACHE_DIR', 'round-7-codex-run.log')
events = stream.snapshot()
print('CHUNK_COUNT:', len(events))
total = sum(len(__import__('base64').b64decode(e['bytes_b64'])) for e in events)
print('TOTAL_BYTES:', total)
print('OFFSETS:', ','.join(str(e['offset']) for e in events))
")"

if grep -q '^CHUNK_COUNT: 3$' <<<"$OUTPUT" && \
   grep -q '^TOTAL_BYTES: 133120$' <<<"$OUTPUT" && \
   grep -q '^OFFSETS: 0,65536,131072$' <<<"$OUTPUT"; then
    _pass "130 KiB file is chunked into 3 snapshot events at 64 KiB boundaries"
else
    _fail "chunking wrong: $OUTPUT"
fi

# ─── Test Group 10: Parser integration (cache_logs_for_session) ───
echo
echo "Group 10: parser.cache_logs_for_session"

PROJECT_ROOT="$TMP_DIR/proj"
SID="2026-04-17_99-99-99"
mkdir -p "$PROJECT_ROOT/.humanize/rlcr/$SID"
: > "$PROJECT_ROOT/.humanize/rlcr/$SID/state.md"

# Need to seed cache logs at the rlcr_sources-derived path under XDG_CACHE_HOME
PROJECT_CACHE_DIR="$TMP_DIR/cache_xdg/humanize/$(printf '%s' "$PROJECT_ROOT" | sed 's/[^a-zA-Z0-9._-]/-/g' | sed 's/--*/-/g')/$SID"
mkdir -p "$PROJECT_CACHE_DIR"
: > "$PROJECT_CACHE_DIR/round-0-codex-run.log"
: > "$PROJECT_CACHE_DIR/round-1-codex-run.log"
: > "$PROJECT_CACHE_DIR/round-1-codex-review.log"

OUTPUT="$(XDG_CACHE_HOME="$TMP_DIR/cache_xdg" python3 -c "
import sys
sys.path.insert(0, '$VIZ_SERVER_DIR')
from parser import cache_logs_for_session
logs = cache_logs_for_session('$PROJECT_ROOT', '$SID')
print('LOG_COUNT:', len(logs))
for log in logs:
    print('LOG:', log['round'], log['tool'], log['role'], log['basename'])
")"

if grep -q '^LOG_COUNT: 3$' <<<"$OUTPUT"; then
    _pass "cache_logs_for_session returns 3 logs"
else
    _fail "cache_logs_for_session count wrong: $OUTPUT"
fi

if grep -q '^LOG: 0 codex run round-0-codex-run.log$' <<<"$OUTPUT" && \
   grep -q '^LOG: 1 codex review round-1-codex-review.log$' <<<"$OUTPUT" && \
   grep -q '^LOG: 1 codex run round-1-codex-run.log$' <<<"$OUTPUT"; then
    _pass "cache_logs_for_session returns deterministic ordering with full metadata"
else
    _fail "cache_logs_for_session ordering wrong: $OUTPUT"
fi

# ─── Test Group 11: Shared stream registry + reconnect semantics ───
echo
echo "Group 11: LogStreamRegistry + reconnect semantics"

REGLOG="$CACHE_DIR/round-8-codex-run.log"
printf 'initial' > "$REGLOG"

OUTPUT="$(_run_py "
from log_streamer import LogStreamRegistry, LogStream
reg = LogStreamRegistry()
s1 = reg.get_or_create('$CACHE_DIR', 'sid-A', 'round-8-codex-run.log')
s2 = reg.get_or_create('$CACHE_DIR', 'sid-A', 'round-8-codex-run.log')
print('SAME:', s1 is s2)
print('LEN_AFTER_DUP_KEY:', len(reg))
s3 = reg.get_or_create('$CACHE_DIR', 'sid-B', 'round-8-codex-run.log')
print('DIFFERENT:', s1 is not s3)
print('LEN_AFTER_NEW_KEY:', len(reg))
# streams_in_cache_dir returns both streams targeting the same basename
streams = reg.streams_in_cache_dir('$CACHE_DIR', 'round-8-codex-run.log')
print('STREAMS_FOR_BASENAME:', len(streams))
")"

if grep -q '^SAME: True$' <<<"$OUTPUT" && \
   grep -q '^LEN_AFTER_DUP_KEY: 1$' <<<"$OUTPUT" && \
   grep -q '^DIFFERENT: True$' <<<"$OUTPUT" && \
   grep -q '^LEN_AFTER_NEW_KEY: 2$' <<<"$OUTPUT" && \
   grep -q '^STREAMS_FOR_BASENAME: 2$' <<<"$OUTPUT"; then
    _pass "registry returns same instance for same key, distinct for different keys"
else
    _fail "registry sharing wrong: $OUTPUT"
fi

# Reconnect simulation: client saw events up through id=N; second
# connection to the SAME registered stream with Last-Event-Id=N must
# only receive events newer than N, never an `append` from offset 0.
OUTPUT="$(_run_py "
from log_streamer import LogStreamRegistry
reg = LogStreamRegistry()
stream = reg.get_or_create('$CACHE_DIR', 'sid-A', 'round-8-codex-run.log')
# Simulate first client: snapshot then one append
snap_events = stream.snapshot()
with open('$REGLOG', 'ab') as f:
    f.write(b' APPENDED')
append_events = stream.poll()
# Client last saw the snapshot id
client_last = snap_events[-1]['id']
# Second client reconnects via the registry with Last-Event-Id=client_last
same_stream = reg.get_or_create('$CACHE_DIR', 'sid-A', 'round-8-codex-run.log')
replayed, in_window = same_stream.replay(client_last)
print('IN_WINDOW:', in_window)
print('REPLAY_COUNT:', len(replayed))
print('REPLAY_TYPES:', ','.join(e['type'] for e in replayed))
print('REPLAY_OFFSETS:', ','.join(str(e.get('offset', -1)) for e in replayed))
print('APPEND_STARTS_AFTER_SNAP:', all(e['offset'] >= snap_events[-1].get('offset', 0) + len(b'initial') for e in replayed if e['type'] == 'append'))
")"

if grep -q '^IN_WINDOW: True$' <<<"$OUTPUT" && \
   grep -q '^REPLAY_TYPES: append$' <<<"$OUTPUT" && \
   grep -q '^APPEND_STARTS_AFTER_SNAP: True$' <<<"$OUTPUT"; then
    _pass "reconnect via shared registry replays events newer than Last-Event-Id, no append from offset 0"
else
    _fail "reconnect semantics wrong: $OUTPUT"
fi

# Reconnect with Last-Event-Id from a DIFFERENT stream (unknown to this one)
# must produce resync(overflow) + snapshot path, not append from offset 0.
OUTPUT="$(_run_py "
from log_streamer import LogStreamRegistry, EVENT_RETENTION
reg = LogStreamRegistry()
stream = reg.get_or_create('$CACHE_DIR', 'sid-reconnect-fresh', 'round-8-codex-run.log')
# Exhaust the retention window by producing a large number of events
# so a Last-Event-Id from before the window becomes out-of-window.
import os
for _ in range(EVENT_RETENTION + 2):
    with open('$REGLOG', 'ab') as f:
        f.write(b'X')
    stream.poll()
# Now reconnect with an ancient Last-Event-Id
replayed, in_window = stream.replay(1)
print('IN_WINDOW:', in_window)
print('FIRST_TYPE:', replayed[0]['type'], replayed[0].get('reason', ''))
print('NO_APPEND_OFFSET_ZERO_FIRST:', not (replayed[0]['type'] == 'append' and replayed[0].get('offset') == 0))
")"

if grep -q '^IN_WINDOW: False$' <<<"$OUTPUT" && \
   grep -q '^FIRST_TYPE: resync overflow$' <<<"$OUTPUT" && \
   grep -q '^NO_APPEND_OFFSET_ZERO_FIRST: True$' <<<"$OUTPUT"; then
    _pass "out-of-window reconnect emits resync(overflow), NOT append from offset 0"
else
    _fail "out-of-window reconnect wrong: $OUTPUT"
fi

# ─── Idle stream eviction without follow-up release ───
# Regression: a stream whose refcount drops to zero without EOF should
# not survive forever when no subsequent release() ever fires. Sweeps
# must also run on other registry interactions (acquire,
# streams_in_cache_dir) so idle retention deques are reclaimed under
# low-churn traffic.
SWEEPLOG="$CACHE_DIR/round-9-codex-run.log"
: > "$SWEEPLOG"

OUTPUT="$(_run_py "
import time
from log_streamer import LogStreamRegistry
# Use a non-zero TTL and rewind the recorded idle timestamp so the
# next sweep observes the TTL as elapsed without real waiting. Reaching
# into a private dict is acceptable in a white-box regression test:
# the point is to verify which call-sites sweep, not real-time timing.
reg = LogStreamRegistry(idle_ttl_seconds=60.0)
# Stream A: one-off disconnect, no EOF, no further release on the same key.
reg.acquire('$CACHE_DIR', 'sid-sweep-A', 'round-9-codex-run.log')
reg.release('sid-sweep-A', 'round-9-codex-run.log')
print('A_PRESENT_BEFORE_SWEEP:', ('sid-sweep-A', 'round-9-codex-run.log') in reg)
# Force A's idle_since far in the past so any subsequent sweep evicts it.
reg._idle_since[('sid-sweep-A', 'round-9-codex-run.log')] = time.monotonic() - 1e6
# New acquire on a different session must trigger the sweep.
reg.acquire('$CACHE_DIR', 'sid-sweep-B', 'round-9-codex-run.log')
print('A_EVICTED_BY_ACQUIRE:', ('sid-sweep-A', 'round-9-codex-run.log') not in reg)
print('B_PRESENT:', ('sid-sweep-B', 'round-9-codex-run.log') in reg)

# Independent registry: verify streams_in_cache_dir() (invoked by the
# cache watcher callback on every observed write) also evicts idle
# streams even when no release() follows.
reg2 = LogStreamRegistry(idle_ttl_seconds=60.0)
reg2.acquire('$CACHE_DIR', 'sid-sweep-C', 'round-9-codex-run.log')
reg2.release('sid-sweep-C', 'round-9-codex-run.log')
reg2._idle_since[('sid-sweep-C', 'round-9-codex-run.log')] = time.monotonic() - 1e6
_ = reg2.streams_in_cache_dir('$CACHE_DIR', 'round-9-codex-run.log')
print('C_EVICTED_BY_STREAMS_LOOKUP:', ('sid-sweep-C', 'round-9-codex-run.log') not in reg2)
")"

if grep -q '^A_PRESENT_BEFORE_SWEEP: True$' <<<"$OUTPUT" && \
   grep -q '^A_EVICTED_BY_ACQUIRE: True$' <<<"$OUTPUT" && \
   grep -q '^B_PRESENT: True$' <<<"$OUTPUT" && \
   grep -q '^C_EVICTED_BY_STREAMS_LOOKUP: True$' <<<"$OUTPUT"; then
    _pass "idle streams are evicted by acquire() and streams_in_cache_dir(), not only by a follow-up release()"
else
    _fail "idle-stream sweep regression: $OUTPUT"
fi

# ─── Summary ───
echo
echo "========================================"
printf 'Passed: \033[0;32m%d\033[0m\n' "$PASS_COUNT"
printf 'Failed: \033[0;31m%d\033[0m\n' "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi

printf '\033[0;32mAll streaming tests passed!\033[0m\n'
