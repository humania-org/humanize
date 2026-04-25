"""RLCR-only session and cache-log discovery for the dashboard.

This module is the single Python source of truth for mapping an RLCR
session directory under ``.humanize/rlcr/<session>/`` to the per-session
cache directory under ``${XDG_CACHE_HOME:-$HOME/.cache}/humanize/<sanitized-project>/<session>/``
and to the live round log files inside that cache directory.

Design constraints:
- RLCR-specific. Skill-invocation cache rules (handled by
  ``scripts/lib/monitor-skill.sh``) are intentionally NOT merged here.
- Pure-Python and side-effect-free at import time.
- Functions return empty containers (never raise) when the underlying
  directories are missing, so callers can poll safely during startup
  races where ``.humanize/rlcr/<session>/`` exists but the cache logs
  have not been written yet.
- Sanitization of the project path matches the rule in
  ``scripts/humanize.sh`` (replace any char outside ``[A-Za-z0-9._-]``
  with ``-``, then collapse runs of ``-``). The accompanying parity
  test exercises this against real project paths.
"""

from __future__ import annotations

import os
import re
from typing import Iterable, List, Tuple

ACTIVE_STATE_FILE = "state.md"
TERMINAL_STATE_SUFFIX = "-state.md"

ACTIVE_STATE_FILES = frozenset({
    ACTIVE_STATE_FILE,
    "methodology-analysis-state.md",
    "finalize-state.md",
})
"""Files whose presence means the RLCR loop is still progressing.

Mirrors the precedence rule in ``scripts/lib/monitor-common.sh`` (the
``monitor_find_state_file`` function preferring methodology-analysis-state.md
before state.md) and the status mapping in ``viz/server/parser.py``
(`detect_session_status` mapping methodology-analysis-state.md to
``analyzing`` and finalize-state.md to ``finalizing``).

Any other ``*-state.md`` file (complete-state.md, cancel-state.md,
stop-state.md, maxiter-state.md, unexpected-state.md, error-state.md,
timeout-state.md, approve-state.md, ...) marks a terminal stop reason
and pushes the session into Historical.
"""

_LOG_FILENAME_RE = re.compile(
    r"^round-(\d+)-(codex|gemini)-(run|review)\.log$"
)

_SANITIZE_NON_SAFE_RE = re.compile(r"[^A-Za-z0-9._-]")
_SANITIZE_COLLAPSE_RE = re.compile(r"-+")


def sanitize_project_path(project_root: str) -> str:
    """Sanitize an absolute project path into a single directory name.

    Mirrors the rule in ``scripts/humanize.sh`` (around the
    ``sanitized_project=...`` assignment in ``_find_latest_codex_log``):

        echo "$project_root" | sed 's/[^a-zA-Z0-9._-]/-/g' | sed 's/--*/-/g'

    The parity test in ``tests/test-rlcr-sources.sh`` cross-checks this
    against the live shell pipeline for several representative paths.
    """
    replaced = _SANITIZE_NON_SAFE_RE.sub("-", project_root)
    return _SANITIZE_COLLAPSE_RE.sub("-", replaced)


def cache_root() -> str:
    """Return the cache root used for RLCR per-session log directories.

    Resolves to ``${XDG_CACHE_HOME:-$HOME/.cache}/humanize`` exactly as
    ``scripts/humanize.sh`` does. The function does NOT verify that the
    directory exists; callers should treat a missing root as an empty
    discovery result, not as an error.
    """
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(
        os.path.expanduser("~"), ".cache"
    )
    return os.path.join(base, "humanize")


def cache_dir_for_session(project_root: str, session_id: str) -> str:
    """Return the absolute per-session cache directory path.

    The path is built from the sanitized project root and the session
    id (which is the basename of the session directory under
    ``.humanize/rlcr/``). The directory is not required to exist; the
    function only constructs the path.
    """
    sanitized = sanitize_project_path(project_root or "")
    return os.path.join(cache_root(), sanitized, session_id or "")


def _classify_session(session_dir: str) -> str:
    """Return one of ``"active"``, ``"historical"``, ``"unknown"``.

    Active phases are detected by the presence of any file in
    ``ACTIVE_STATE_FILES`` (state.md, methodology-analysis-state.md,
    finalize-state.md). This matches the precedence in
    ``scripts/lib/monitor-common.sh:monitor_find_state_file`` and the
    status mapping in ``viz/server/parser.py:detect_session_status``,
    where methodology-analysis and finalize are running phases of the
    loop, not stop reasons.

    Historical sessions have at least one ``*-state.md`` file but none
    of the active ones (terminal stop reasons such as complete-state.md,
    cancel-state.md, etc.). Sessions with no state file at all (mid-
    write, partial scaffold) are reported as ``unknown``.
    """
    if not os.path.isdir(session_dir):
        return "unknown"
    try:
        names = os.listdir(session_dir)
    except OSError:
        return "unknown"

    has_terminal = False
    for name in names:
        if name in ACTIVE_STATE_FILES and os.path.isfile(
            os.path.join(session_dir, name)
        ):
            return "active"
        if name.endswith(TERMINAL_STATE_SUFFIX) and name not in ACTIVE_STATE_FILES:
            has_terminal = True
    return "historical" if has_terminal else "unknown"


SessionEntry = Tuple[str, str, str]
"""(session_id, session_dir, classification)."""


def enumerate_sessions(rlcr_dir: str) -> List[SessionEntry]:
    """List every session directory under ``rlcr_dir``.

    Returns a deterministic list sorted by session id (which uses the
    ISO-like timestamp naming convention, so lexical sort yields
    chronological order). Sessions with non-conforming names (anything
    that is not a directory) are skipped silently. The dashboard relies
    on this enumeration to reject the single-session auto-switch
    behavior that the terminal monitor uses.
    """
    if not rlcr_dir or not os.path.isdir(rlcr_dir):
        return []

    entries: List[SessionEntry] = []
    try:
        names = sorted(os.listdir(rlcr_dir))
    except OSError:
        return []

    for name in names:
        full = os.path.join(rlcr_dir, name)
        if not os.path.isdir(full):
            continue
        entries.append((name, full, _classify_session(full)))
    return entries


def partition_sessions(
    entries: Iterable[SessionEntry],
) -> Tuple[List[SessionEntry], List[SessionEntry], List[SessionEntry]]:
    """Split enumeration output into ``(active, historical, unknown)``.

    Each returned list preserves input order. The dashboard renders
    active and historical lists separately; unknown entries are kept
    so the UI can surface partial sessions without crashing.
    """
    active: List[SessionEntry] = []
    historical: List[SessionEntry] = []
    unknown: List[SessionEntry] = []
    for entry in entries:
        if entry[2] == "active":
            active.append(entry)
        elif entry[2] == "historical":
            historical.append(entry)
        else:
            unknown.append(entry)
    return active, historical, unknown


LogPath = Tuple[int, str, str, str]
"""(round, tool, role, absolute_path) where tool in {codex, gemini} and role in {run, review}."""


def live_log_paths(cache_dir: str) -> List[LogPath]:
    """Return all round log files in a per-session cache directory.

    Filenames are matched against the strict pattern
    ``round-N-{codex|gemini}-{run|review}.log``. The result is sorted
    by ``(round, tool, role)`` so consumers get a deterministic order.
    A missing or unreadable cache directory returns an empty list
    rather than raising, which lets callers poll during startup races.
    """
    if not cache_dir or not os.path.isdir(cache_dir):
        return []

    matches: List[LogPath] = []
    try:
        names = os.listdir(cache_dir)
    except OSError:
        return []

    for name in names:
        m = _LOG_FILENAME_RE.match(name)
        if not m:
            continue
        round_num = int(m.group(1))
        tool = m.group(2)
        role = m.group(3)
        matches.append((round_num, tool, role, os.path.join(cache_dir, name)))

    matches.sort(key=lambda t: (t[0], t[1], t[2]))
    return matches


__all__ = [
    "ACTIVE_STATE_FILE",
    "ACTIVE_STATE_FILES",
    "TERMINAL_STATE_SUFFIX",
    "SessionEntry",
    "LogPath",
    "sanitize_project_path",
    "cache_root",
    "cache_dir_for_session",
    "enumerate_sessions",
    "partition_sessions",
    "live_log_paths",
]
