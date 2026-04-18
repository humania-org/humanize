"""Per-session, per-file log streaming logic for the dashboard.

Implements the snapshot+append+resync+eof event sequence frozen in
``docs/streaming-protocol.md``. The module is pure logic: it does not
own a poll loop or HTTP transport. Callers drive ``poll()`` and turn
the returned event dicts into SSE frames or any other transport.

Event shape (matches the contract):

    {"type": "snapshot", "path": <basename>, "offset": <int>, "bytes_b64": <str>, "eof": <bool>}
    {"type": "append",   "path": <basename>, "offset": <int>, "bytes_b64": <str>}
    {"type": "resync",   "path": <basename>, "reason": "truncated|rotated|recreated|missing|overflow"}
    {"type": "eof",      "path": <basename>}

The streamer assigns a strictly increasing ``id`` per stream and
retains the last 256 events for ``Last-Event-Id`` reconnects (per the
contract). Larger snapshots are chunked at 64 KiB.
"""

from __future__ import annotations

import base64
import os
import threading
from collections import deque
from typing import Deque, Dict, List, Optional, Tuple

SNAPSHOT_CHUNK_BYTES = 64 * 1024
EVENT_RETENTION = 256

EVENT_SNAPSHOT = "snapshot"
EVENT_APPEND = "append"
EVENT_RESYNC = "resync"
EVENT_EOF = "eof"

RESYNC_TRUNCATED = "truncated"
RESYNC_ROTATED = "rotated"
RESYNC_RECREATED = "recreated"
RESYNC_MISSING = "missing"
RESYNC_OVERFLOW = "overflow"


def _b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def _stat_id(path: str) -> Optional[Tuple[int, int]]:
    """Return ``(st_dev, st_ino)`` for ``path`` or ``None`` if absent."""
    try:
        st = os.stat(path)
    except (OSError, FileNotFoundError):
        return None
    return (st.st_dev, st.st_ino)


def _file_size(path: str) -> Optional[int]:
    try:
        return os.path.getsize(path)
    except (OSError, FileNotFoundError):
        return None


class LogStream:
    """One streaming channel for one (session, filename) pair.

    A stream is created with the basename of the cache log file (e.g.
    ``round-3-codex-run.log``) and the absolute path to the parent
    cache directory. The basename is what appears in the ``path``
    field of every emitted event so clients only see relative names.

    Lifecycle:

    - ``snapshot()`` — issue zero or more ``snapshot`` events covering
      the bytes already on disk. May be called multiple times during
      reconnect; the second call resets internal counters before
      replaying from offset 0.
    - ``poll()`` — observe the file once; emit ``append`` if new bytes
      appeared, ``resync`` followed by a fresh snapshot if the file
      shrank or its inode changed, ``resync`` with reason ``missing``
      if the file disappeared, or no events when nothing changed.
    - ``mark_eof()`` — caller signals that the writer has closed (the
      session reached a terminal state); a single ``eof`` event is
      emitted and subsequent ``poll()`` calls are no-ops.

    Events are returned with a monotonic per-stream id. ``replay``
    serves a ``Last-Event-Id`` reconnect by returning all retained
    events newer than the supplied id; if the id is out of the
    retention window it returns a ``resync(overflow)`` plus a fresh
    snapshot path that the caller should run through ``snapshot()``.
    """

    def __init__(self, cache_dir: str, basename: str):
        self.cache_dir = cache_dir
        self.basename = basename
        self.path = os.path.join(cache_dir, basename)
        self._next_id = 1
        self._offset = 0
        self._stat = _stat_id(self.path)
        self._eof_emitted = False
        self._retained: Deque[Dict] = deque(maxlen=EVENT_RETENTION)
        self._missing_emitted = False
        # All public mutators (snapshot, poll, mark_eof, replay) acquire
        # this lock so concurrent SSE handlers can share the same
        # instance without corrupting offset/retained state. RLock so
        # that internal helpers that call other public methods (e.g.
        # the replay overflow path that resets ``_offset``) do not
        # deadlock themselves.
        self.lock = threading.RLock()

    def latest_event_id(self) -> int:
        """Return the highest event id retained, or 0 if none."""
        with self.lock:
            return self._retained[-1]["id"] if self._retained else 0

    def _emit(self, event: Dict) -> Dict:
        event_with_id = {"id": self._next_id, **event}
        self._next_id += 1
        self._retained.append(event_with_id)
        return event_with_id

    def snapshot(self) -> List[Dict]:
        """Emit snapshot events for everything already on disk."""
        with self.lock:
            return self._snapshot_locked()

    def _snapshot_locked(self) -> List[Dict]:
        if self._eof_emitted:
            return []
        events: List[Dict] = []
        size = _file_size(self.path)
        if size is None:
            self._offset = 0
            self._stat = None
            return events

        self._stat = _stat_id(self.path)
        self._missing_emitted = False
        if size == 0:
            self._offset = 0
            return events

        try:
            f = open(self.path, "rb")
        except OSError:
            return events
        try:
            offset = 0
            while offset < size:
                chunk = f.read(SNAPSHOT_CHUNK_BYTES)
                if not chunk:
                    break
                events.append(self._emit({
                    "type": EVENT_SNAPSHOT,
                    "path": self.basename,
                    "offset": offset,
                    "bytes_b64": _b64(chunk),
                    "eof": False,
                }))
                offset += len(chunk)
            self._offset = offset
        finally:
            f.close()
        return events

    def poll(self) -> List[Dict]:
        """Observe the file once and emit any events that occurred."""
        with self.lock:
            return self._poll_locked()

    def _poll_locked(self) -> List[Dict]:
        if self._eof_emitted:
            return []
        events: List[Dict] = []
        size = _file_size(self.path)
        stat = _stat_id(self.path)

        if size is None:
            if not self._missing_emitted:
                events.append(self._emit({
                    "type": EVENT_RESYNC,
                    "path": self.basename,
                    "reason": RESYNC_MISSING,
                }))
                self._missing_emitted = True
            self._offset = 0
            self._stat = None
            return events

        if self._missing_emitted:
            # File came back; treat as a recreation.
            events.append(self._emit({
                "type": EVENT_RESYNC,
                "path": self.basename,
                "reason": RESYNC_RECREATED,
            }))
            self._missing_emitted = False
            self._offset = 0
            self._stat = stat
            events.extend(self._snapshot_locked())
            return events

        if stat is not None and self._stat is not None and stat != self._stat:
            events.append(self._emit({
                "type": EVENT_RESYNC,
                "path": self.basename,
                "reason": RESYNC_ROTATED,
            }))
            self._offset = 0
            self._stat = stat
            events.extend(self._snapshot_locked())
            return events

        if size < self._offset:
            events.append(self._emit({
                "type": EVENT_RESYNC,
                "path": self.basename,
                "reason": RESYNC_TRUNCATED,
            }))
            self._offset = 0
            self._stat = stat
            events.extend(self._snapshot_locked())
            return events

        if size > self._offset:
            new_bytes = size - self._offset
            try:
                f = open(self.path, "rb")
            except OSError:
                return events
            try:
                f.seek(self._offset)
                # Chunk appends so any individual event stays bounded.
                start = self._offset
                remaining = new_bytes
                while remaining > 0:
                    chunk = f.read(min(SNAPSHOT_CHUNK_BYTES, remaining))
                    if not chunk:
                        break
                    events.append(self._emit({
                        "type": EVENT_APPEND,
                        "path": self.basename,
                        "offset": start,
                        "bytes_b64": _b64(chunk),
                    }))
                    start += len(chunk)
                    remaining -= len(chunk)
                self._offset = start
            finally:
                f.close()
            self._stat = stat

        return events

    def mark_eof(self) -> List[Dict]:
        """Emit a single ``eof`` event; subsequent polls are no-ops."""
        with self.lock:
            if self._eof_emitted:
                return []
            self._eof_emitted = True
            return [self._emit({"type": EVENT_EOF, "path": self.basename})]

    def replay(self, last_event_id: int) -> Tuple[List[Dict], bool]:
        """Return retained events newer than ``last_event_id``.

        Returns ``(events, in_window)``. When ``in_window`` is False the
        caller MUST call ``snapshot()`` again after consuming any
        events; the helper has already emitted a ``resync(overflow)``.
        """
        with self.lock:
            if not self._retained:
                return [], True
            oldest = self._retained[0]["id"]
            if last_event_id < oldest - 1:
                overflow = self._emit({
                    "type": EVENT_RESYNC,
                    "path": self.basename,
                    "reason": RESYNC_OVERFLOW,
                })
                self._offset = 0
                return [overflow], False
            events = [e for e in self._retained if e["id"] > last_event_id]
            return events, True


def stream_url_path(session_id: str, basename: str) -> str:
    """Canonical SSE URL path for one stream."""
    return f"/api/sessions/{session_id}/logs/{basename}"


class LogStreamRegistry:
    """Process-lifetime registry of LogStream instances.

    Keyed by ``(session_id, basename)``. Concurrent SSE handlers
    share the same instance so retained event history survives
    client reconnects and the contract's ``Last-Event-Id`` semantics
    are honored. Without this registry, each request would construct
    a fresh ``LogStream`` with empty retention and a reconnect would
    emit the file body as ``append`` from offset 0 instead of
    replaying or emitting ``resync(overflow)`` + ``snapshot``.
    """

    def __init__(self):
        self._streams: Dict[Tuple[str, str], LogStream] = {}
        self._lock = threading.Lock()

    def get_or_create(self, cache_dir: str, session_id: str, basename: str) -> LogStream:
        key = (session_id, basename)
        with self._lock:
            stream = self._streams.get(key)
            if stream is None:
                stream = LogStream(cache_dir, basename)
                self._streams[key] = stream
            return stream

    def get(self, session_id: str, basename: str) -> Optional[LogStream]:
        with self._lock:
            return self._streams.get((session_id, basename))

    def streams_in_cache_dir(self, cache_dir: str, basename: str) -> List[LogStream]:
        """Return all streams that observe a specific cache file."""
        with self._lock:
            return [
                s for s in self._streams.values()
                if s.cache_dir == cache_dir and s.basename == basename
            ]

    def __contains__(self, key) -> bool:
        with self._lock:
            return key in self._streams

    def __len__(self) -> int:
        with self._lock:
            return len(self._streams)


__all__ = [
    "EVENT_SNAPSHOT",
    "EVENT_APPEND",
    "EVENT_RESYNC",
    "EVENT_EOF",
    "RESYNC_TRUNCATED",
    "RESYNC_ROTATED",
    "RESYNC_RECREATED",
    "RESYNC_MISSING",
    "RESYNC_OVERFLOW",
    "SNAPSHOT_CHUNK_BYTES",
    "EVENT_RETENTION",
    "LogStream",
    "LogStreamRegistry",
    "stream_url_path",
]
