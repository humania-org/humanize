"""File system watcher for RLCR session directories.

Uses watchdog to monitor .humanize/rlcr/ and pushes WebSocket events
when session files change. Events are debounced (500ms) to avoid
spamming during rapid consecutive writes.
"""

import os
import re
import json
import time
import threading
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

import rlcr_sources


def _noop_session_created(session_id):
    """Default handler for RLCREventHandler.on_session_created.

    Tests and alternate harnesses can drop the watchdog hook in
    without wiring up cache-dir observers. SessionWatcher.start
    replaces this with the real callback.
    """
    del session_id  # unused


class RLCREventHandler(FileSystemEventHandler):
    """Maps file changes to WebSocket event types."""

    def __init__(self, rlcr_dir, broadcast_fn):
        super().__init__()
        self.rlcr_dir = rlcr_dir
        self.broadcast = broadcast_fn
        self._pending = {}
        self._lock = threading.Lock()
        self._timer = None
        self.debounce_ms = 500
        # Set by SessionWatcher so a fresh session's cache dir is
        # watched as soon as its state dir appears, and so the
        # corresponding observer is torn down when a terminal state
        # marker lands. Defaults to no-op callables so alternate
        # harnesses / tests can invoke RLCREventHandler directly
        # without wiring these up.
        self.on_session_created = _noop_session_created
        self.on_session_finished = _noop_session_created

    def on_any_event(self, event):
        src = str(event.src_path)

        if event.is_directory and event.event_type == 'created':
            rel = os.path.relpath(src, self.rlcr_dir)
            if '/' not in rel and '\\' not in rel:
                self._schedule_event('session_created', rel)
                try:
                    self.on_session_created(rel)
                except Exception:
                    # Don't crash the observer thread on callback
                    # failures.
                    pass
            return

        if event.is_directory:
            return

        rel = os.path.relpath(src, self.rlcr_dir)
        parts = rel.replace('\\', '/').split('/')

        if len(parts) < 2:
            return

        session_id = parts[0]
        filename = parts[1]

        if filename == 'state.md':
            self._schedule_event('session_updated', session_id)
        elif filename == 'goal-tracker.md':
            self._schedule_event('session_updated', session_id)
        elif re.match(r'round-\d+-summary\.md$', filename):
            self._schedule_event('round_added', session_id)
        elif re.match(r'round-\d+-review-result\.md$', filename):
            self._schedule_event('session_updated', session_id)
        elif filename.endswith('-state.md') and filename != 'state.md':
            self._schedule_event('session_finished', session_id)
            # Tell SessionWatcher to tear down the per-session
            # cache-dir observer so we don't keep holding inotify
            # slots after the RLCR loop has stopped writing logs.
            try:
                self.on_session_finished(session_id)
            except Exception:
                pass

    def _schedule_event(self, event_type, session_id):
        """Debounce events: accumulate for 500ms before broadcasting."""
        # Ensure a cache-dir observer exists for this session. The
        # start-up path already tries this once; repeating it here
        # handles the race where the state directory appears before
        # the RLCR cache directory, and future events after the cache
        # dir materialises eventually succeed. Idempotent when the
        # observer is already running.
        try:
            self.on_session_created(session_id)
        except Exception:
            pass
        key = f"{event_type}:{session_id}"
        with self._lock:
            self._pending[key] = {
                'type': event_type,
                'session_id': session_id,
                'time': time.time(),
            }
        self._reset_timer()

    def _reset_timer(self):
        if self._timer:
            self._timer.cancel()
        self._timer = threading.Timer(self.debounce_ms / 1000.0, self._flush)
        self._timer.daemon = True
        self._timer.start()

    def _flush(self):
        with self._lock:
            events = list(self._pending.values())
            self._pending.clear()

        for event in events:
            self.broadcast(json.dumps({
                'type': event['type'],
                'session_id': event['session_id'],
            }))


class _CacheLogBroadcastHandler(FileSystemEventHandler):
    """Emit ``round_added`` broadcasts when a new round-*.log file appears.

    The RLCREventHandler above only sees writes inside
    ``.humanize/rlcr/`` — i.e. state.md, goal-tracker.md, and the
    round summary/review markdown files. It never notices when a
    brand-new ``round-N-codex-run.log`` materialises in the
    per-session cache directory (``~/.cache/humanize/<project>/<session>/``),
    which is the actual file the dashboard's live-log pane streams.
    Without this handler the frontend would stay pinned to the
    previous round's log until the next state.md write, which can
    lag many minutes into the new round.
    """

    _LOG_NAME_RE = re.compile(
        r"^round-\d+-(?:codex|gemini)-(?:run|review)\.log$"
    )

    def __init__(self, session_id, broadcast_fn):
        super().__init__()
        self.session_id = session_id
        self.broadcast = broadcast_fn
        self._seen = set()
        self._lock = threading.Lock()

    def on_created(self, event):
        if event.is_directory:
            return
        name = os.path.basename(str(event.src_path))
        if not self._LOG_NAME_RE.match(name):
            return
        with self._lock:
            if name in self._seen:
                return
            self._seen.add(name)
        try:
            self.broadcast(json.dumps({
                'type': 'round_added',
                'session_id': self.session_id,
            }))
        except Exception:
            # Never crash the watchdog observer thread on a broadcast
            # failure — the frontend will catch up on the next
            # state.md / summary.md write anyway.
            pass


class SessionWatcher:
    """Manages the watchdog observer for RLCR directories.

    Two observers are maintained in parallel:
      - An observer on ``.humanize/rlcr/`` for session-level state
        files (state.md, goal-tracker.md, round summaries and
        review results, terminal state files).
      - One observer per active session's cache directory
        (``~/.cache/humanize/<project>/<session>/``). Those observers
        broadcast ``round_added`` when a new round-*.log file is
        created so the dashboard can switch the live-log pane to the
        new round without waiting for the next state.md write.
    """

    def __init__(self, project_dir, broadcast_fn):
        self.project_dir = project_dir
        self.rlcr_dir = os.path.join(project_dir, '.humanize', 'rlcr')
        self.broadcast = broadcast_fn
        self.observer = None
        self._cache_observers = {}
        self._cache_lock = threading.Lock()

    # A session is "active" (and therefore worth watching for new
    # cache-log files) only while state.md is present without any
    # terminal *-state.md marker alongside it. Any other permutation
    # (state.md missing, or one of cancel-state.md / complete-state.md
    # / stop-state.md / maxiter-state.md / unexpected-state.md /
    # finalize-state.md / methodology-analysis-state.md present) means
    # the RLCR loop is no longer writing cache logs for that session.
    _TERMINAL_STATE_SUFFIXES = (
        'cancel-state.md',
        'complete-state.md',
        'stop-state.md',
        'maxiter-state.md',
        'unexpected-state.md',
        'finalize-state.md',
        'methodology-analysis-state.md',
    )

    def _session_is_active(self, session_id):
        session_dir = os.path.join(self.rlcr_dir, session_id)
        if not os.path.isdir(session_dir):
            return False
        if not os.path.isfile(os.path.join(session_dir, 'state.md')):
            return False
        # `finalize-state.md` and `methodology-analysis-state.md`
        # represent transient end-of-session phases where cache logs
        # can technically still land, but the RLCR loop finishes
        # writing them within seconds; treat them as terminal for the
        # purposes of watcher allocation — the lazy retry in
        # `_schedule_event()` will bring the observer back if a cache
        # log file actually appears after the transition.
        for suffix in self._TERMINAL_STATE_SUFFIXES:
            if os.path.isfile(os.path.join(session_dir, suffix)):
                return False
        return True

    def start(self):
        if not os.path.isdir(self.rlcr_dir):
            os.makedirs(self.rlcr_dir, exist_ok=True)

        handler = RLCREventHandler(self.rlcr_dir, self.broadcast)
        # Hook session-created events so we can start a cache-log
        # observer the moment a new session directory appears; also
        # hook session-finished events so the observer is torn down
        # when a terminal state marker lands.
        handler.on_session_created = self._start_cache_observer
        handler.on_session_finished = self._stop_cache_observer
        self.observer = Observer()
        self.observer.schedule(handler, self.rlcr_dir, recursive=True)
        self.observer.daemon = True
        self.observer.start()

        # Prime cache observers ONLY for sessions that are currently
        # active on disk. A project that has accumulated dozens of
        # completed sessions used to start one observer per session at
        # boot, which quickly exhausts inotify / watchdog slots on
        # busy hosts and defeats the broadcast path. Completed
        # sessions don't write new round-*.log files, so they don't
        # need a watcher at all.
        try:
            for entry in os.listdir(self.rlcr_dir):
                if not os.path.isdir(os.path.join(self.rlcr_dir, entry)):
                    continue
                if self._session_is_active(entry):
                    self._start_cache_observer(entry)
        except OSError:
            pass

    def _start_cache_observer(self, session_id):
        """Best-effort: attach a cache-dir observer for ``session_id``.

        Skips silently when the cache directory doesn't exist yet
        (startup race — the RLCR loop creates it only after the first
        round fires). A new observer is started on the first
        ``round_added`` event for the session, so the absent-at-
        start-up case is naturally covered on the subsequent retry
        from ``_schedule_event``.
        """
        with self._cache_lock:
            if session_id in self._cache_observers:
                return
        # Defence against re-starting an observer for a session that
        # has already transitioned to a terminal state while this
        # callback was in flight (common when broadcast events
        # straddle a loop-end boundary).
        if not self._session_is_active(session_id):
            return
        cache_dir = rlcr_sources.cache_dir_for_session(self.project_dir, session_id)
        if not cache_dir or not os.path.isdir(cache_dir):
            return
        handler = _CacheLogBroadcastHandler(session_id, self.broadcast)
        obs = Observer()
        try:
            obs.schedule(handler, cache_dir, recursive=False)
            obs.daemon = True
            obs.start()
        except Exception:
            return
        with self._cache_lock:
            # Re-check under lock: another thread may have raced us.
            if session_id in self._cache_observers:
                try:
                    obs.stop()
                except Exception:
                    pass
                return
            self._cache_observers[session_id] = obs

    def _stop_cache_observer(self, session_id):
        """Tear down the cache-dir observer for a finished session.

        Called from ``RLCREventHandler`` the moment a terminal state
        marker appears. Safe to call for sessions that never had an
        observer — the lock-guarded map lookup is a no-op in that
        case.
        """
        with self._cache_lock:
            obs = self._cache_observers.pop(session_id, None)
        if obs is None:
            return
        try:
            obs.stop()
            obs.join(timeout=2)
        except Exception:
            pass

    def stop(self):
        if self.observer:
            self.observer.stop()
            self.observer.join(timeout=5)
        with self._cache_lock:
            observers = list(self._cache_observers.values())
            self._cache_observers.clear()
        for obs in observers:
            try:
                obs.stop()
                obs.join(timeout=2)
            except Exception:
                pass


class CacheLogEventHandler(FileSystemEventHandler):
    """Maps cache-log file system events to a per-file callback.

    The callback signature is ``callback(filepath: str)``. The handler
    fires the callback for any modification, creation, or deletion of
    a regular file inside the watched cache directory; the consumer
    (typically a :class:`log_streamer.LogStream`) is then responsible
    for translating that signal into snapshot/append/resync/eof events
    per the streaming protocol contract.
    """

    def __init__(self, cache_dir, callback):
        super().__init__()
        self.cache_dir = cache_dir
        self.callback = callback

    def on_any_event(self, event):
        if event.is_directory:
            return
        try:
            self.callback(str(event.src_path))
        except Exception:
            # Callbacks must not crash the observer thread.
            pass


class CacheLogWatcher:
    """Watch a per-session cache directory for live log mutations.

    The dashboard uses this alongside :class:`SessionWatcher`:
    ``SessionWatcher`` carries coarse session metadata events for
    localhost-bound WebSocket clients, while ``CacheLogWatcher``
    backs the per-session SSE stream for live log bytes. The latter
    is the only path that emits the per-file append events required
    by the protocol contract.
    """

    def __init__(self, cache_dir, callback):
        self.cache_dir = cache_dir
        self.callback = callback
        self.observer = None

    def start(self):
        if not os.path.isdir(self.cache_dir):
            # Startup race: cache directory may not exist yet. The
            # SSE handler can still poll lazily and start a watcher
            # later when the directory appears.
            return False
        handler = CacheLogEventHandler(self.cache_dir, self.callback)
        self.observer = Observer()
        self.observer.schedule(handler, self.cache_dir, recursive=False)
        self.observer.daemon = True
        self.observer.start()
        return True

    def stop(self):
        if self.observer:
            self.observer.stop()
            self.observer.join(timeout=5)
            self.observer = None
