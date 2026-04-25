"""Humanize Viz — Flask application.

Serves the SPA frontend, REST API for session data, and WebSocket
for real-time file change notifications.
"""

import os
import re
import sys
import json
import time
import argparse
import subprocess
import threading
from flask import Flask, Response, jsonify, request, send_from_directory, abort
from flask_sock import Sock
from werkzeug.utils import safe_join

# Add server directory to path
sys.path.insert(0, os.path.dirname(__file__))
from parser import list_sessions, parse_session, read_plan_file, is_valid_session
from analyzer import compute_analytics
from exporter import export_session_markdown
from watcher import SessionWatcher, CacheLogWatcher
import rlcr_sources
import log_streamer

app = Flask(__name__, static_folder=None)
sock = Sock(app)

# Global state
PROJECT_DIR = '.'
STATIC_DIR = '.'
BIND_HOST = '127.0.0.1'
AUTH_TOKEN = ''
# Set by main() when `--trust-proxy` (or HUMANIZE_VIZ_TRUST_PROXY=1)
# is supplied. Acknowledges that a TLS-terminating reverse proxy is
# in front of the server, which lets the CSRF host/port matcher
# honor `X-Forwarded-Proto` for scheme-based port resolution.
# Localhost-bound dev mode always leaves this False so attacker-
# supplied `X-Forwarded-Proto` headers cannot trick a direct-
# connect dashboard into thinking it's HTTPS.
TRUST_PROXY = False
_session_cache = {}
_cache_lock = threading.Lock()
_ws_clients = set()
_ws_lock = threading.Lock()
_watcher = None


def _is_localhost_bind():
    """Return True when the server is bound to a loopback interface."""
    return BIND_HOST in ('127.0.0.1', '::1', 'localhost')


def _request_token():
    """Extract the bearer token from an incoming Flask request.

    Honors both the standard ``Authorization: Bearer <tok>`` header (used
    by the SPA's ``fetch`` calls) and the ``?token=<tok>`` query parameter
    (used by the SSE ``EventSource`` client because browsers cannot set
    arbitrary headers on EventSource).
    """
    auth_header = request.headers.get('Authorization', '')
    if auth_header.startswith('Bearer '):
        token = auth_header[len('Bearer '):].strip()
        if token:
            return token
    return request.args.get('token', '').strip()


def _request_authorized():
    """True iff the current request may access protected endpoints.

    Fail-closed defense-in-depth: ``main()`` refuses to start a
    non-loopback bind without a token, but any code path that skips
    ``main()`` (module import plus a bespoke ``app.run`` wrapper, a
    future test harness, an alternate entry point) would otherwise
    pass every request through. Treat an empty AUTH_TOKEN on a
    non-loopback bind as "no credential was configured, deny" rather
    than "no credential was configured, allow".
    """
    if _is_localhost_bind():
        return True
    if not AUTH_TOKEN:
        return False
    return _request_token() == AUTH_TOKEN


def _get_rlcr_dir():
    return os.path.join(PROJECT_DIR, '.humanize', 'rlcr')


# Session ids flow into the frontend's inline onclick template
# literals:
#   onclick="navigate('#/session/${s.id}')"
#   onclick="opsPreviewIssue('${s.id}')"
# so any id containing a JS-string metacharacter (quote, backtick,
# backslash, angle bracket, newline, etc.) would let hostile disk
# state break out of the surrounding string and inject script.
# setup-rlcr-loop.sh generates ids that match
# `YYYY-MM-DD_HH-MM-SS`, but some test fixtures and legacy
# recoveries use simpler slugs like `2026-04-17_CL`. Accept the
# full superset of safe characters (ASCII letters, digits,
# underscore, dash, period — with extra rules rejecting `..`,
# leading-dot, and path separators) so those still work while
# every character outside that set is refused up-front.
_SESSION_ID_RE = re.compile(r'^[A-Za-z0-9_.\-]+$')


def _is_safe_session_id(session_id):
    """Return True iff ``session_id`` only uses the safe alphabet.

    Rejects anything with path separators, parent-traversal
    markers, leading dots, or characters that could escape a JS
    string literal in the frontend's inline onclick handlers.
    """
    if not session_id or len(session_id) > 128:
        return False
    if session_id in ('.', '..') or session_id.startswith('.'):
        return False
    if '/' in session_id or '\\' in session_id:
        return False
    return bool(_SESSION_ID_RE.match(session_id))


def _get_session_dir(session_id):
    """Resolve a session_id to its on-disk directory, or None.

    Defense-in-depth path validation: every session-scoped route
    (detail, plan, report, generate-report, cancel, SSE log stream)
    passes a user-controlled session_id through here. Without these
    checks a request like `/api/sessions/..` would resolve to
    `.humanize/..` = the project's `.humanize/` parent, and any
    stray directory under `.humanize/rlcr` (e.g. a `cache/` dir)
    would bypass the 404 contract and let downstream parsers read
    arbitrary files.

    Reject:
      - session_id that does not match the canonical
        ``YYYY-MM-DD_HH-MM-SS`` shape (covers path separators, `..`,
        dotfiles, and anything that could escape from a JS string
        literal in the frontend's inline onclick handlers)
      - candidates that resolve outside the RLCR dir after
        realpath normalisation (defense against symlink escapes)
      - directories that exist but are not actually RLCR sessions
        (parser.is_valid_session requires state.md or a terminal
        *-state.md file)
    """
    if not _is_safe_session_id(session_id):
        return None
    rlcr_dir = _get_rlcr_dir()
    candidate = os.path.join(rlcr_dir, session_id)
    if not os.path.isdir(candidate):
        return None
    # Resolve both sides to compare against symlinks. The candidate
    # must still live under the rlcr dir after normalisation.
    try:
        rlcr_real = os.path.realpath(rlcr_dir)
        cand_real = os.path.realpath(candidate)
    except (OSError, ValueError):
        return None
    rlcr_prefix = rlcr_real.rstrip(os.sep) + os.sep
    if not cand_real.startswith(rlcr_prefix):
        return None
    if not is_valid_session(candidate):
        return None
    return candidate


def _get_session(session_id, force_refresh=False):
    """Get session data with caching."""
    with _cache_lock:
        if not force_refresh and session_id in _session_cache:
            return _session_cache[session_id]

    session_dir = _get_session_dir(session_id)
    if not session_dir:
        return None

    session = parse_session(session_dir)
    with _cache_lock:
        _session_cache[session_id] = session
    return session


def _invalidate_cache(session_id=None):
    """Invalidate cache for a session or all sessions."""
    with _cache_lock:
        if session_id:
            _session_cache.pop(session_id, None)
        else:
            _session_cache.clear()


def broadcast_message(message):
    """Send a message to all connected WebSocket clients."""
    dead = set()
    with _ws_lock:
        clients = set(_ws_clients)

    for ws in clients:
        try:
            ws.send(message)
        except Exception:
            dead.add(ws)

    if dead:
        with _ws_lock:
            # Mutate in-place via difference_update instead of `-=`.
            # `_ws_clients -= dead` would rebind the name, which makes
            # Python treat `_ws_clients` as a function-local variable
            # throughout broadcast_message and raise UnboundLocalError
            # at the earlier `set(_ws_clients)` read.
            _ws_clients.difference_update(dead)

    # Invalidate cache for the affected session
    try:
        data = json.loads(message)
        _invalidate_cache(data.get('session_id'))
    except (json.JSONDecodeError, AttributeError):
        pass


# --- Auth middleware (T11) ---

# Endpoints that remain reachable without a token even in remote mode.
# The static SPA shell and the health probe must stay open so the
# browser can fetch index.html and report liveness; everything else
# (session data, SSE streams, mutators) is gated.
_AUTH_OPEN_PREFIXES = ('/api/health',)


def _is_open_path(path):
    if path == '/' or not path.startswith('/api/'):
        # Static asset path served by the SPA fallback.
        return True
    for prefix in _AUTH_OPEN_PREFIXES:
        if path.startswith(prefix):
            return True
    return False


_MUTATING_METHODS = frozenset({'POST', 'PUT', 'PATCH', 'DELETE'})

_LOOPBACK_HOSTS = frozenset({'localhost', '127.0.0.1', '::1'})


def _default_port_for_scheme(scheme):
    return 443 if scheme == 'https' else 80


def _effective_request_scheme():
    """Return the wire-level scheme the browser actually used.

    Behind a TLS-terminating reverse proxy (the `--trust-proxy`
    deployment mode), Flask sees the back-channel request as plain
    HTTP — `request.scheme` is `http`, so the default-port lookup
    below would collapse to 80 even though the browser spoke to the
    proxy on 443. That mismatch turns every browser Origin of
    `https://host` into a 403 at `_origin_matches_request()` because
    the computed request port (80) differs from the origin port
    (443), which in turn blocks cancel / generate-report / GitHub-
    issue submissions in the standard HTTPS-behind-proxy deployment.

    When `TRUST_PROXY` is True, honor `X-Forwarded-Proto`
    (populated by every reasonable reverse proxy) for scheme
    resolution so the default-port calculation lines up with the
    browser's view. Anything other than explicit `https` falls back
    to Flask's own `request.scheme` so HTTP proxy deployments keep
    working. When `TRUST_PROXY` is False we ignore the header
    entirely — otherwise an attacker on a direct-connect localhost
    dashboard could flip our scheme view with a crafted header.
    """
    if TRUST_PROXY:
        forwarded = (request.headers.get('X-Forwarded-Proto') or '').strip().lower()
        # Some proxies comma-separate when multiple hops exist; the
        # first entry is the one the client hit.
        if forwarded:
            forwarded = forwarded.split(',', 1)[0].strip()
        if forwarded == 'https':
            return 'https'
        if forwarded == 'http':
            return 'http'
    return request.scheme


def _parse_request_host_port():
    """Return ``(host, port)`` for the current request's Host header.

    ``request.host`` is the value the browser actually used to reach
    the dashboard (e.g. ``server.example.com:18000``), which may
    differ from the configured ``BIND_HOST`` in wildcard deployments
    such as ``--host 0.0.0.0``. Same-origin checks must compare
    against this value, not against the bind, so remote browsers can
    actually issue cross-host writes.

    IPv6 hosts in HTTP Host headers are bracketed per RFC 7230
    (``[::1]:18000`` for the loopback bind), but ``urlparse(Origin)
    .hostname`` returns the unbracketed form (``::1``). Strip the
    brackets after the host/port split so the comparison matches.
    """
    scheme = _effective_request_scheme()
    raw = (request.host or '').lower()
    if not raw:
        return ('', _default_port_for_scheme(scheme))
    if ':' in raw and not raw.endswith(']'):
        host, port_str = raw.rsplit(':', 1)
        try:
            port = int(port_str)
        except ValueError:
            port = _default_port_for_scheme(scheme)
    else:
        host = raw
        port = _default_port_for_scheme(scheme)
    if host.startswith('[') and host.endswith(']'):
        host = host[1:-1]
    return (host, port)


def _origin_matches_request(origin_value):
    """True when ``origin_value`` points at the same host:port the
    browser actually used for this request.

    Comparing to the request's own ``Host`` header (rather than the
    configured ``BIND_HOST``) is what lets ``--host 0.0.0.0`` remote
    deployments work: the bind is a wildcard but the browser sends
    the machine's real hostname, so a literal-bind comparison would
    reject every cross-host POST as cross-origin. Loopback aliases
    (localhost/127.0.0.1/::1) are treated as equivalent so the user
    is not pinned to whichever alias they happened to type.
    """
    if not origin_value:
        return False
    try:
        from urllib.parse import urlparse
        parsed = urlparse(origin_value)
    except Exception:
        return False
    if parsed.scheme not in ('http', 'https'):
        return False
    origin_host = (parsed.hostname or '').lower()
    if not origin_host:
        return False
    # ``urlparse`` succeeds for malformed Origin values like
    # ``http://host:bad`` or ``http://host:999999``; the port is only
    # validated when ``.port`` is accessed, which raises ValueError.
    # Treat such values as non-matching so ``_enforce_csrf_protection``
    # returns a controlled 403 instead of letting the exception bubble
    # up as a 500.
    try:
        origin_port = parsed.port or _default_port_for_scheme(parsed.scheme)
    except ValueError:
        return False

    request_host, request_port = _parse_request_host_port()
    if origin_port != request_port:
        return False
    if origin_host in _LOOPBACK_HOSTS and request_host in _LOOPBACK_HOSTS:
        return True
    return origin_host == request_host


def _enforce_csrf_protection():
    """Reject cross-origin writes regardless of bind / auth posture.

    Remote-mode deployments are still further gated by the auth
    middleware (token check); CSRF is layered on top so a stolen
    token cannot be exploited from an arbitrary origin either.
    Localhost binds were the original gap Codex flagged: without this
    layer, any webpage open in the same browser could POST to
    127.0.0.1:<port> mutating endpoints.
    """
    if request.method not in _MUTATING_METHODS:
        return None
    if _is_open_path(request.path):
        return None
    origin = request.headers.get('Origin', '').strip()
    referer = request.headers.get('Referer', '').strip()
    if origin:
        if _origin_matches_request(origin):
            return None
        return jsonify({'error': 'cross-origin write rejected'}), 403
    if referer:
        if _origin_matches_request(referer):
            return None
        return jsonify({'error': 'cross-origin write rejected'}), 403
    # No Origin AND no Referer header: browsers always set at least
    # one of them on cross-site form/fetch POSTs, so the absence
    # almost certainly means the request came from a same-origin
    # script that suppressed both, a server-to-server tool such as
    # curl, or our own Flask test_client. Allow it; the auth layer
    # still gates remote requests via token.
    return None


@app.before_request
def _enforce_auth_and_csrf():
    """Combined auth + CSRF gate.

    Order matters: the CSRF layer runs first so cross-origin writes
    are rejected even if the request happens to carry a valid token
    (defense in depth). The auth layer then enforces the bearer
    token in remote mode for every protected endpoint.
    """
    csrf_response = _enforce_csrf_protection()
    if csrf_response is not None:
        return csrf_response
    if _is_localhost_bind():
        return None
    if _is_open_path(request.path):
        return None
    if _request_authorized():
        return None
    return jsonify({'error': 'unauthorized'}), 401


# --- Static file serving ---

@app.route('/')
def index():
    return send_from_directory(STATIC_DIR, 'index.html')


@app.route('/<path:path>')
def static_files(path):
    if path.startswith('api/'):
        abort(404)
    # Reject traversal / absolute paths BEFORE probing the filesystem.
    # The earlier implementation did ``os.path.isfile(os.path.join(
    # STATIC_DIR, path))`` for any client-supplied ``path``, which
    # turned an intentionally-open endpoint into an unauthenticated
    # filesystem-existence oracle: a request containing ``..``
    # segments took the ``send_from_directory`` branch (404) when the
    # target existed, but fell through to the SPA fallback (200) when
    # it did not. Werkzeug's ``safe_join`` returns ``None`` for any
    # path that would escape STATIC_DIR, so we skip the probe entirely
    # in that case and go straight to the SPA fallback — the response
    # is identical whether the traversal target existed or not.
    safe_path = safe_join(STATIC_DIR, path)
    if safe_path is not None and os.path.isfile(safe_path):
        return send_from_directory(STATIC_DIR, path)
    # SPA fallback
    return send_from_directory(STATIC_DIR, 'index.html')


# --- Health check ---

@app.route('/api/health')
def health():
    return jsonify({'status': 'ok'})


# --- Project Listing (read-only; CLI-fixed single-project model per DEC-3) ---
#
# T10 backend cleanup: the legacy server-global project switcher (which
# allowed any client to mutate PROJECT_DIR for ALL connected clients
# and persisted to ~/.humanize/viz-projects.json) has been removed in
# favor of one server per project. Project selection is now CLI-fixed
# at startup via `humanize monitor web --project <path>`. The
# read-only /api/projects endpoint stays for frontend compatibility
# during the Round 5 UI refactor; it returns ONLY the project the
# server was started with and never mutates the projects file.


@app.route('/api/projects')
def api_projects():
    rlcr_dir = os.path.join(PROJECT_DIR, '.humanize', 'rlcr')
    session_count = 0
    if os.path.isdir(rlcr_dir):
        session_count = len([
            d for d in os.listdir(rlcr_dir)
            if os.path.isdir(os.path.join(rlcr_dir, d))
        ])
    return jsonify([
        {
            'path': PROJECT_DIR,
            'name': os.path.basename(PROJECT_DIR),
            'sessions': session_count,
            'active': True,
            'cli_fixed': True,
        }
    ])


_CANCELLABLE_STATUSES = frozenset({'active', 'analyzing', 'finalizing'})


_REMOVED_PROJECT_ENDPOINT_BODY = {
    'error': 'project switching is no longer supported; run `humanize monitor web --project <path>` per project',
    'replacement': 'humanize monitor web --project <path>',
}


@app.route('/api/projects/switch', methods=['POST'])
@app.route('/api/projects/add', methods=['POST'])
@app.route('/api/projects/remove', methods=['POST'])
def api_projects_removed():
    return jsonify(_REMOVED_PROJECT_ENDPOINT_BODY), 410


# --- REST API ---

@app.route('/api/sessions')
def api_sessions():
    sessions = list_sessions(PROJECT_DIR)
    # Return summary-level data (no full round content). cache_logs is
    # included because the home-page multi-session live-pane feature
    # needs it to pick a log filename and open the SSE stream; without
    # it every active card degrades to the WAITING state regardless of
    # whether cache logs actually exist.
    #
    # Filter out any on-disk directory whose name does not match the
    # canonical session-id shape before emitting. This is the second
    # line of defence for the inline-onclick XSS vector Codex flagged
    # — a session directory created by hand with a name like
    # `2026-04-18_00-34-17'); alert(1); //` should never reach the
    # frontend where `onclick="navigate('#/session/${s.id}')"` would
    # break out of the JS string.
    summaries = []
    for s in sessions:
        if not _is_safe_session_id(s.get('id', '')):
            continue
        summaries.append({
            'id': s['id'],
            'status': s['status'],
            'current_round': s['current_round'],
            'max_iterations': s['max_iterations'],
            'full_review_round': s.get('full_review_round'),
            'plan_file': s['plan_file'],
            'start_branch': s['start_branch'],
            'started_at': s['started_at'],
            'last_verdict': s['last_verdict'],
            'drift_status': s['drift_status'],
            # Extra state fields so the home-page active card can
            # match the `humanize monitor rlcr` status bar line-for-line
            # without forcing clients to hit /api/sessions/<id>.
            'codex_model': s.get('codex_model', ''),
            'codex_effort': s.get('codex_effort', ''),
            'ask_codex_question': s.get('ask_codex_question', False),
            'review_started': s.get('review_started', False),
            'agent_teams': s.get('agent_teams', False),
            'push_every_round': s.get('push_every_round', False),
            'mainline_stall_count': s.get('mainline_stall_count', 0),
            'last_mainline_verdict': s.get('last_mainline_verdict', 'unknown'),
            'build_finish_round': s.get('build_finish_round'),
            'skip_impl': s.get('skip_impl', False),
            'tasks_done': s['tasks_done'],
            'tasks_total': s['tasks_total'],
            'tasks_active': s.get('tasks_active', 0),
            'tasks_deferred': s.get('tasks_deferred', 0),
            'ac_done': s['ac_done'],
            'ac_total': s['ac_total'],
            'ultimate_goal': s.get('ultimate_goal', ''),
            'duration_minutes': s.get('duration_minutes'),
            'cache_logs': s.get('cache_logs') or [],
            'active_log_path': s.get('active_log_path', ''),
            'git_status': s.get('git_status'),
        })
    return jsonify(summaries)


@app.route('/api/sessions/<session_id>')
def api_session_detail(session_id):
    session = _get_session(session_id)
    if not session:
        abort(404)
    return jsonify(session)


@app.route('/api/sessions/<session_id>/plan')
def api_session_plan(session_id):
    session_dir = _get_session_dir(session_id)
    if not session_dir:
        abort(404)
    plan = read_plan_file(session_dir, PROJECT_DIR)
    if plan is None:
        abort(404)
    return jsonify({'content': plan})


@app.route('/api/sessions/<session_id>/report')
def api_session_report(session_id):
    session = _get_session(session_id)
    if not session:
        abort(404)
    report = session.get('methodology_report')
    # parse_session always populates methodology_report via
    # _to_bilingual, which returns {'zh': None, 'en': None} when no
    # report file exists. The previous `if not report:` never fired
    # because that dict is truthy, so the route returned 200 with an
    # empty payload and clients couldn't distinguish "report missing"
    # from "report loaded successfully but empty". Require at least
    # one of zh / en to carry content before returning 200.
    if not isinstance(report, dict) or not (report.get('zh') or report.get('en')):
        abort(404)
    return jsonify({'content': report})


@app.route('/api/analytics')
def api_analytics():
    # Drop any on-disk session whose directory name does not match
    # the canonical shape before feeding it into the analyzer. The
    # Analytics page's comparison table renders ``session_id`` into
    # an inline ``onclick="navigate('#/session/${id}')"`` template
    # and cell HTML; without this filter a crafted directory name
    # containing quote/JS metacharacters would reach the browser
    # and could break out of the attribute or inject script, which
    # is the exact vector ``/api/sessions`` already guards against.
    # Matching the same filter here keeps both surfaces consistent.
    sessions = [
        s for s in list_sessions(PROJECT_DIR)
        if _is_safe_session_id(s.get('id', ''))
    ]
    analytics = compute_analytics(sessions)
    return jsonify(analytics)


def _report_is_stale(session_dir, report_path):
    """True when the on-disk methodology report predates any round
    summary / review-result under ``session_dir``.

    The cached report was generated against an earlier snapshot of
    the session; any new summary or review file that lands after
    its mtime invalidates it. Activities after the report:
      - a new round's summary was written (loop kept going)
      - an existing round's review-result changed (verdict flipped)
    Either way, returning the stale cached text on /generate-report
    would feed Codex/users an analysis of a session that has since
    moved on.

    Returns False when the report is missing or empty (caller will
    generate from scratch), or when it's present and at least as
    new as every source file.
    """
    try:
        report_mtime = os.path.getmtime(report_path)
    except OSError:
        return False
    import glob as _glob
    sources = _glob.glob(os.path.join(session_dir, 'round-*-summary.md'))
    sources += _glob.glob(os.path.join(session_dir, 'round-*-review-result.md'))
    for src in sources:
        try:
            if os.path.getmtime(src) > report_mtime:
                return True
        except OSError:
            continue
    return False


@app.route('/api/sessions/<session_id>/generate-report', methods=['POST'])
def api_generate_report(session_id):
    """Generate a methodology analysis report by invoking local Claude CLI.

    The ``?force=1`` query parameter bypasses the "report already
    exists" shortcut and always re-runs Claude. Without it the
    route still re-runs when the cached report predates any round
    summary or review-result file — the old "exists => done" path
    let users see stale analyses on sessions that had advanced
    since the last preview.
    """
    session_dir = _get_session_dir(session_id)
    if not session_dir:
        abort(404)

    report_path = os.path.join(session_dir, 'methodology-analysis-report.md')
    force_regen = request.args.get('force', '').strip() in ('1', 'true', 'yes')

    # Serve the cached report only when it's present, non-empty,
    # and still newer than every source file that contributes to
    # the analysis. A stale cache would otherwise survive indefinitely
    # across new rounds on an active session.
    if (not force_regen
            and os.path.exists(report_path)
            and os.path.getsize(report_path) > 0
            and not _report_is_stale(session_dir, report_path)):
        with open(report_path, 'r', encoding='utf-8') as f:
            return jsonify({'status': 'exists', 'content': f.read()})

    # Collect round summaries and review results (sorted numerically by round number)
    import glob as _glob
    import re as _re_local

    def _sort_round_files(files):
        def _round_num(path):
            m = _re_local.search(r'round-(\d+)-', os.path.basename(path))
            return int(m.group(1)) if m else 0
        return sorted(files, key=_round_num)

    summaries = []
    for sf in _sort_round_files(_glob.glob(os.path.join(session_dir, 'round-*-summary.md'))):
        try:
            with open(sf, 'r', encoding='utf-8') as f:
                summaries.append(f'--- {os.path.basename(sf)} ---\n{f.read()}')
        except (PermissionError, OSError):
            pass

    reviews = []
    for rf in _sort_round_files(_glob.glob(os.path.join(session_dir, 'round-*-review-result.md'))):
        try:
            with open(rf, 'r', encoding='utf-8') as f:
                reviews.append(f'--- {os.path.basename(rf)} ---\n{f.read()}')
        except (PermissionError, OSError):
            pass

    if not summaries and not reviews:
        return jsonify({'error': 'No round data to analyze'}), 400

    # Build the analysis prompt
    prompt = f"""Analyze the following RLCR development records from a PURE METHODOLOGY perspective.

CRITICAL SANITIZATION RULES — your output MUST NOT contain:
- File paths, directory paths, or module paths
- Function names, variable names, class names, or method names
- Branch names, commit hashes, or git identifiers
- Business domain terms, product names, or feature names
- Code snippets or code fragments of any kind
- Raw error messages or stack traces
- Project-specific URLs or endpoints
- Any information that could identify the specific project

Focus areas:
- Iteration efficiency: Were rounds productive or repetitive?
- Feedback loop quality: Did reviewer feedback lead to improvements?
- Stagnation patterns: Were there signs of going in circles?
- Review effectiveness: Did reviews catch real issues or create false positives?
- Plan-to-execution alignment: Did execution follow the plan or drift?
- Round count vs. progress ratio: Was the number of rounds proportional to progress?
- Communication clarity: Were summaries and reviews clear and actionable?

Output format: Write a structured markdown report following this exact structure:

## Context
<Brief session stats: round count, exit reason, AC completion — no project names>

## Observations
<Numbered list of methodology observations — generic language only>

## Suggested Improvements
| # | Suggestion | Mechanism |
|---|-----------|-----------|
<Table rows with concrete improvement suggestions>

## Quantitative Summary
| Metric | Value |
|--------|-------|
<Key metrics table>

--- ROUND SUMMARIES ---
{chr(10).join(summaries[-10:])}

--- REVIEW RESULTS ---
{chr(10).join(reviews[-10:])}
"""
    # `_sort_round_files` returns entries in ascending round order
    # (round 0, round 1, ...), so [-10:] picks the LATEST 10 rounds.
    # Methodology signals — stagnation, drift, finalization — surface
    # in the late phase of long sessions; taking [:10] would drop
    # exactly the rounds that matter most for a session longer than
    # ten rounds. Sessions with <=10 rounds are unaffected.

    # Invoke Claude CLI in pipe mode
    try:
        result = subprocess.run(
            ['claude', '-p', '--model', 'sonnet', '--output-format', 'text'],
            input=prompt,
            capture_output=True,
            text=True,
            timeout=120,
            cwd=PROJECT_DIR,
        )

        if result.returncode != 0:
            return jsonify({
                'error': f'Claude CLI failed (exit {result.returncode})',
                'stderr': result.stderr[-500:] if result.stderr else '',
            }), 500

        report_content = result.stdout.strip()
        if not report_content:
            return jsonify({'error': 'Claude returned empty response'}), 500

        # Save the report
        with open(report_path, 'w', encoding='utf-8') as f:
            f.write(report_content)

        # Invalidate session cache so the report is picked up
        _invalidate_cache(session_id)

        return jsonify({'status': 'generated', 'content': report_content})

    except FileNotFoundError:
        return jsonify({'error': 'Claude CLI not found. Install Claude Code to generate reports.'}), 500
    except subprocess.TimeoutExpired:
        return jsonify({'error': 'Claude CLI timed out (120s). Try again or reduce session size.'}), 500
    except Exception as e:
        return jsonify({'error': str(e)}), 500


def _find_cancel_script():
    """Resolve cancel-rlcr-loop.sh from plugin layout or env."""
    # Check env override first
    env_script = os.environ.get('HUMANIZE_CANCEL_SCRIPT', '')
    if env_script and os.path.isfile(env_script):
        return env_script

    # Sibling path within the same humanize plugin repo (viz/server/../../scripts/)
    server_dir = os.path.dirname(os.path.abspath(__file__))
    sibling = os.path.normpath(os.path.join(server_dir, '..', '..', 'scripts', 'cancel-rlcr-loop.sh'))
    if os.path.isfile(sibling):
        return sibling

    # Search standard plugin cache locations
    search_paths = [
        os.path.expanduser('~/.claude/plugins/cache/PolyArch/humanize'),
        os.path.expanduser('~/.claude/plugins/marketplaces/humania'),
    ]
    for base in search_paths:
        if not os.path.isdir(base):
            continue
        for entry in sorted(os.listdir(base), reverse=True):
            candidate = os.path.join(base, entry, 'scripts', 'cancel-rlcr-loop.sh')
            if os.path.isfile(candidate):
                return candidate
        candidate = os.path.join(base, 'scripts', 'cancel-rlcr-loop.sh')
        if os.path.isfile(candidate):
            return candidate

    return None


def _find_session_cancel_script():
    """Locate the session-scoped cancel helper from the plugin install.

    Mirrors the same lookup semantics as ``_find_cancel_script``: env
    override first, then the sibling repo path (this file's grandparent
    plus ``scripts/``), then the standard plugin cache locations. Without
    the sibling and broader cache-path checks the route would 500 in any
    deployment where ``CLAUDE_PLUGIN_ROOT`` is not set, which is the
    common case when the dashboard is launched via
    ``humanize monitor web`` from another terminal.
    """
    env_script = os.environ.get('HUMANIZE_CANCEL_SESSION_SCRIPT', '')
    if env_script and os.path.isfile(env_script):
        return env_script

    server_dir = os.path.dirname(os.path.abspath(__file__))
    sibling = os.path.normpath(
        os.path.join(server_dir, '..', '..', 'scripts', 'cancel-rlcr-session.sh')
    )
    if os.path.isfile(sibling):
        return sibling

    search_paths = [
        os.environ.get('CLAUDE_PLUGIN_ROOT', ''),
        os.path.expanduser('~/.claude/plugins/cache/PolyArch/humanize'),
        os.path.expanduser('~/.claude/plugins/marketplaces/humania'),
    ]
    for base in search_paths:
        if not base or not os.path.isdir(base):
            continue
        for entry in sorted(os.listdir(base), reverse=True):
            candidate = os.path.join(base, entry, 'scripts', 'cancel-rlcr-session.sh')
            if os.path.isfile(candidate):
                return candidate
        candidate = os.path.join(base, 'scripts', 'cancel-rlcr-session.sh')
        if os.path.isfile(candidate):
            return candidate
    return None


@app.route('/api/sessions/cancel', methods=['POST'])
def api_cancel_session_missing_id():
    """Reachable 400 for the missing-session-id contract from criterion C-7.

    Flask routing requires the ``<session_id>`` segment in the main
    cancel route to match at all, so a request without it would
    otherwise 404 before any handler ran. This explicit no-id route
    surfaces the documented 400 contract and lets clients (and tests)
    distinguish "you forgot the id" from "the id does not exist".
    """
    return jsonify({
        'error': 'session_id is required',
        'usage': 'POST /api/sessions/<session_id>/cancel',
    }), 400


@app.route('/api/sessions/<session_id>/cancel', methods=['POST'])
def api_cancel_session(session_id):
    session = _get_session(session_id)
    if not session:
        abort(404)
    status = session.get('status')
    if status not in _CANCELLABLE_STATUSES:
        return jsonify({
            'error': 'Session is not in a cancellable state',
            'status': status,
        }), 400

    cancel_script = _find_session_cancel_script()
    if not cancel_script:
        return jsonify({
            'error': 'Session-scoped cancel helper not found. Ensure humanize plugin is installed.',
            'expected_script': 'scripts/cancel-rlcr-session.sh',
        }), 500

    # The helper requires --force when the session is in the
    # finalizing phase to avoid silent cancellation; without --force it
    # exits with code 2. Forward it so dashboard cancel works for every
    # phase the helper supports (active / analyzing / finalizing).
    #
    # `--project` MUST be passed explicitly so the helper does not
    # fall back to ``CLAUDE_PROJECT_DIR`` (which the dashboard
    # process may inherit from the shell that launched it, pointing
    # at an entirely different workspace).
    helper_args = [cancel_script, '--project', PROJECT_DIR, '--session-id', session_id]
    if status == 'finalizing':
        helper_args.append('--force')

    try:
        subprocess.run(helper_args, cwd=PROJECT_DIR, timeout=30, check=True)
        _invalidate_cache(session_id)
        return jsonify({'status': 'cancelled', 'session_id': session_id})
    except subprocess.SubprocessError as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/sessions/<session_id>/export', methods=['POST'])
def api_export_session(session_id):
    session = _get_session(session_id)
    if not session:
        abort(404)
    markdown = export_session_markdown(session)
    return jsonify({'content': markdown, 'filename': f'rlcr-report-{session_id}.md'})


import re as _re


_FORBIDDEN_CATEGORIES = [
    ('path_token', _re.compile(r'[/\\]\w+\.\w{1,4}\b')),
    ('path_token', _re.compile(r'\b\w+/\w+/\w+')),
    ('qualified_name', _re.compile(r'\b\w+::\w+')),
    ('qualified_name', _re.compile(r'\b\w+\.\w+\.\w+\(')),
    ('git_hash', _re.compile(r'\b[a-f0-9]{7,40}\b')),
    ('branch_name', _re.compile(r'\b(?:feat|fix|hotfix|release|bugfix)/\w+')),
    ('branch_name', _re.compile(r'\bmain|master|develop\b')),
    ('code_definition', _re.compile(r'\bdef \w+|function \w+|class \w+')),
    # Code-shaped imports only. The previous `\b(?:import|require|from)
    # \s+\w+` pattern matched ordinary English prose like
    # "drifted from the original plan structure", which flagged the
    # built-in `plan_execution` methodology observation and caused
    # /api/sessions/<id>/github-issue to reject already-sanitized
    # payloads with a false-positive warning. Anchor each variant to
    # a context that only appears in code:
    #   - Python `import x` / `import x.y` at line start
    #   - Python `from x.y import z` at line start
    #   - JS/Node `require("…")` call syntax
    ('import_statement', _re.compile(r'^\s*import\s+[\w.]+', _re.MULTILINE)),
    ('import_statement', _re.compile(r'^\s*from\s+[\w.]+\s+import\b', _re.MULTILINE)),
    ('import_statement', _re.compile(r'\brequire\s*\(')),
    ('code_fence', _re.compile(r'```')),
    ('identifier', _re.compile(r'\b\w+_\w+_\w+\b')),
    ('identifier', _re.compile(r'\b[a-z]+[A-Z]\w+\b')),
    ('stack_trace', _re.compile(r'\bTraceback \(most recent')),
    ('stack_trace', _re.compile(r'\bFile ".+", line \d+')),
    ('error_pattern', _re.compile(r'\b(?:Error|Exception|Panic|SIGSEGV|SIGABRT)\b')),
    ('stack_trace', _re.compile(r'at \w+\.\w+\(.*:\d+:\d+\)')),
    ('external_url', _re.compile(r'https?://(?!github\.com/humania)')),
    ('local_endpoint', _re.compile(r'\b(?:localhost|127\.0\.0\.1):\d+')),
]


def _scan_for_forbidden_tokens(text):
    """Return dict of {category: count} for forbidden patterns found in text.
    Never returns the matched strings themselves to prevent leakage."""
    violations = {}
    for category, pattern in _FORBIDDEN_CATEGORIES:
        matches = pattern.findall(text)
        if matches:
            violations[category] = violations.get(category, 0) + len(matches)
    return violations


def _is_english_only(text):
    """Check that text is predominantly ASCII/English (>95% ASCII chars)."""
    if not text:
        return True
    ascii_count = sum(1 for c in text if ord(c) < 128)
    return (ascii_count / len(text)) > 0.95


# Constrained methodology taxonomy — observations are classified into
# these generic categories. Only the category label and a generic phrasing
# are emitted into the issue; no report prose passes through.
_METHODOLOGY_CATEGORIES = {
    'iteration_efficiency': 'Iteration efficiency pattern observed: rounds showed uneven productivity distribution.',
    'feedback_loop': 'Feedback loop quality issue: reviewer-implementer communication could be improved.',
    'stagnation': 'Stagnation pattern detected: consecutive rounds showed limited forward progress.',
    'review_effectiveness': 'Review effectiveness concern: review feedback did not consistently drive improvements.',
    'plan_execution': 'Plan-execution alignment gap: implementation drifted from the original plan structure.',
    'verification_gap': 'Verification scope issue: implementer verification did not match reviewer expectations.',
    'phase_transition': 'phase-boundary transition pattern: the boundary between implementation and review work was unclear.',
    'scope_management': 'Scope management observation: work expanded or contracted relative to plan boundaries.',
    'general': 'General methodology observation noted.',
}

_CATEGORY_KEYWORDS = {
    'iteration_efficiency': ['efficiency', 'productive', 'unproductive', 'round count', 'per-round output', 'diminish'],
    'feedback_loop': ['feedback', 'communication', 'reviewer', 'implementer', 'round-trip'],
    'stagnation': ['stagnation', 'stall', 'circle', 'repeat', 'no progress', 'same issue'],
    'review_effectiveness': ['false positive', 'review quality', 'missed issue', 'review catch'],
    'plan_execution': ['plan drift', 'alignment', 'deviat', 'scope change', 'off-plan'],
    'verification_gap': ['verification', 'insufficient test', 'too narrow', 'missed check', 'universal quantifier'],
    'phase_transition': ['phase transition', 'review phase', 'implementation phase', 'polishing', 'two-phase'],
    'scope_management': ['scope', 'over-engineer', 'under-deliver', 'bloat', 'defer'],
}


def _classify_observation(text):
    """Classify a report observation into a methodology category."""
    lower = text.lower()
    best_cat = 'general'
    best_score = 0
    for cat, keywords in _CATEGORY_KEYWORDS.items():
        score = sum(1 for kw in keywords if kw in lower)
        if score > best_score:
            best_score = score
            best_cat = cat
    return best_cat


def _build_sanitized_issue(session):
    """Build a sanitized GitHub issue payload following issue #62 format.

    Uses constrained methodology taxonomy — no report prose passes through.
    Returns dict with 'title', 'body', and 'warnings' keys, or None if no report.
    Warnings contain only category names and counts, never matched strings.
    """
    report_obj = session.get('methodology_report', {})
    # Prefer English report; fall back to Chinese
    report = (report_obj or {}).get('en') or (report_obj or {}).get('zh') or ''
    if not report:
        return None

    # Source diagnostics (informational only — do NOT gate outbound)
    source_diagnostics = {}
    if not _is_english_only(report):
        source_diagnostics['non_english'] = 1

    # Extract raw observations and suggestions from report structure
    raw_observations = []
    raw_suggestions = []
    current_section = None

    for line in report.split('\n'):
        stripped = line.strip()
        if stripped.lower().startswith('## observation') or stripped.lower().startswith('## finding'):
            current_section = 'observations'
            continue
        elif stripped.lower().startswith('## suggest'):
            current_section = 'suggestions'
            continue
        elif stripped.startswith('## '):
            current_section = stripped[3:].strip().lower()
            continue

        if current_section == 'observations' and stripped.startswith(('- ', '* ', '1.', '2.', '3.', '4.', '5.', '6.', '7.', '8.', '9.')):
            raw_observations.append(stripped.lstrip('-* 0123456789.').strip())
        elif current_section == 'suggestions' and stripped.startswith('|') and not stripped.startswith('|---') and not stripped.startswith('| #'):
            cols = [c.strip() for c in stripped.split('|')[1:-1]]
            if len(cols) >= 2:
                raw_suggestions.append(cols)

    if not raw_observations:
        for line in report.split('\n'):
            stripped = line.strip()
            if stripped and not stripped.startswith('#') and not stripped.startswith('|') and not stripped.startswith('---'):
                raw_observations.append(stripped)

    # Log source-level findings as diagnostics (not blocking)
    for obs in raw_observations:
        violations = _scan_for_forbidden_tokens(obs)
        for cat, count in violations.items():
            source_diagnostics[cat] = source_diagnostics.get(cat, 0) + count

    # Classify observations into methodology categories (no prose passes through)
    category_counts = {}
    for obs in raw_observations:
        category = _classify_observation(obs)
        category_counts[category] = category_counts.get(category, 0) + 1

    # Classify suggestions into methodology categories (no raw text passes through)
    suggestion_categories = {}
    for cols in raw_suggestions:
        combined = ' '.join(cols)
        cat = _classify_observation(combined)
        suggestion_categories[cat] = suggestion_categories.get(cat, 0) + 1

    # Build title from dominant category (no report text)
    dominant_cat = max(category_counts, key=category_counts.get) if category_counts else 'general'
    title = f"RLCR: {dominant_cat.replace('_', ' ').capitalize()} pattern identified"

    # Build issue #62 body using ONLY taxonomy-derived phrasing
    s = session
    # ``current_round`` is a 0-based index, not a round *count*. Using
    # it verbatim printed ``0-round`` for sessions that only finished
    # round 0 and under-reported every other session by one. The
    # parser-built ``rounds`` list is the authoritative count — its
    # length matches ``max_disk_round + 1``.
    round_total = len(s.get('rounds') or [])
    body_lines = [
        '## Context\n',
        f'A {round_total}-round RLCR session ended with status: {s["status"]}.',
    ]
    if s.get('ac_total', 0) > 0:
        body_lines.append(f'Acceptance criteria: {s["ac_done"]}/{s["ac_total"]} verified.')
    body_lines.append('')

    body_lines.append('## Observations\n')
    for i, (cat, count) in enumerate(sorted(category_counts.items(), key=lambda x: -x[1]), 1):
        generic_text = _METHODOLOGY_CATEGORIES.get(cat, _METHODOLOGY_CATEGORIES['general'])
        body_lines.append(f'{i}. **{cat.replace("_", " ").capitalize()}** ({count}x): {generic_text}')

    body_lines.append('')
    body_lines.append('## Suggested Improvements\n')
    body_lines.append('| # | Suggestion | Mechanism |')
    body_lines.append('|---|-----------|-----------|')
    if suggestion_categories:
        for i, (cat, count) in enumerate(sorted(suggestion_categories.items(), key=lambda x: -x[1]), 1):
            generic_suggestion = f'Improve {cat.replace("_", " ")} practices'
            mechanism = f'Apply targeted {cat.replace("_", " ")} methodology adjustments ({count} suggestion(s) in this area)'
            body_lines.append(f'| {i} | {generic_suggestion} | {mechanism} |')
    else:
        body_lines.append('| - | No specific suggestions identified | - |')

    body_lines.append('')
    body_lines.append('## Quantitative Summary\n')
    body_lines.append('| Metric | Value |')
    body_lines.append('|--------|-------|')
    # Reuse the ``round_total`` count computed for the Context section
    # above — ``s["current_round"]`` is a 0-based index, so a raw read
    # here would under-report every session (0 for a single-round
    # session, N-1 for an N-round session) in the Quantitative
    # Summary table that downstream issue readers rely on.
    body_lines.append(f'| Total rounds | {round_total} |')
    body_lines.append(f'| Exit reason | {s["status"].capitalize()} |')
    if s.get('ac_total', 0) > 0:
        rate = round(s['ac_done'] / s['ac_total'] * 100) if s['ac_total'] > 0 else 0
        body_lines.append(f'| AC count | {s["ac_total"]} |')
        body_lines.append(f'| Completion rate | {rate}% |')
    body_lines.append(f'| Observation categories | {len(category_counts)} |')
    body_lines.append(f'| Total observations | {sum(category_counts.values())} |')

    body = '\n'.join(body_lines)

    # OUTBOUND VALIDATION: only the final generated title/body determine
    # whether the payload is safe to send. Source-report findings are
    # informational and do NOT gate the outbound path.
    outbound_warnings = {}

    final_violations = _scan_for_forbidden_tokens(body)
    for cat, count in final_violations.items():
        outbound_warnings[cat] = outbound_warnings.get(cat, 0) + count

    title_violations = _scan_for_forbidden_tokens(title)
    for cat, count in title_violations.items():
        outbound_warnings[cat] = outbound_warnings.get(cat, 0) + count

    if not _is_english_only(body):
        outbound_warnings['non_english'] = 1

    return {
        'title': title,
        'body': body,
        'warnings': outbound_warnings,
        'source_diagnostics': source_diagnostics,
    }


@app.route('/api/sessions/<session_id>/sanitized-issue')
def api_sanitized_issue(session_id):
    session = _get_session(session_id)
    if not session:
        abort(404)
    payload = _build_sanitized_issue(session)
    if not payload:
        abort(404)

    # Outbound gate: only block if the FINAL generated payload has warnings
    if payload.get('warnings'):
        return jsonify({
            'title': payload['title'],
            'body': '[REDACTED — outbound payload failed validation.]',
            'warnings': payload['warnings'],
            'source_diagnostics': payload.get('source_diagnostics', {}),
            'requires_review': True,
        })

    # Clean payload — include source diagnostics as informational
    result = {
        'title': payload['title'],
        'body': payload['body'],
        'warnings': {},
        'source_diagnostics': payload.get('source_diagnostics', {}),
    }
    return jsonify(result)


@app.route('/api/sessions/<session_id>/github-issue', methods=['POST'])
def api_github_issue(session_id):
    session = _get_session(session_id)
    if not session:
        abort(404)

    payload = _build_sanitized_issue(session)
    if not payload:
        return jsonify({'error': 'No methodology report available'}), 400

    # Block submission and redact body when sanitization warnings exist
    if payload.get('warnings'):
        return jsonify({
            'error': 'Sanitization check failed. Review the methodology report manually and remove project-specific content before sending.',
            'warnings': payload['warnings'],
            'manual': False,
        }), 400

    title = payload['title']
    body = payload['body']

    # Check if gh is available
    try:
        subprocess.run(['gh', '--version'], capture_output=True, timeout=5, check=True)
    except (subprocess.SubprocessError, FileNotFoundError):
        return jsonify({
            'error': 'gh CLI not available',
            'title': title,
            'body': body,
            'manual': True,
        }), 400

    try:
        result = subprocess.run(
            ['gh', 'issue', 'create', '--repo', 'PolyArch/humanize',
             '--title', title, '--body', body],
            capture_output=True, text=True, timeout=30, check=True, cwd=PROJECT_DIR,
        )
        url = result.stdout.strip()
        return jsonify({'status': 'created', 'url': url})
    except subprocess.SubprocessError as e:
        return jsonify({
            'error': str(e),
            'title': title,
            'body': body,
            'manual': True,
        }), 500


# --- Per-session SSE log streaming (per docs/streaming-protocol.md) ---

_LOG_BASENAME_RE = re.compile(
    r"^round-\d+-(?:codex|gemini)-(?:run|review)\.log$"
)

# Polling cadence inside the SSE generator. Combined with the 64 KiB
# snapshot chunk size, this gives the contract's median-latency
# budget plenty of head-room (median << 2.0s under nominal load).
_SSE_POLL_INTERVAL_SECONDS = 0.25
_SSE_HEARTBEAT_INTERVAL_SECONDS = 15.0

# Process-lifetime registry of LogStream instances. The registry
# implementation lives in log_streamer.py so it can be tested without
# needing the Flask import path; see docstring there for the
# correctness rationale (Codex Round 2 review caught a reconnect bug
# where per-request LogStream construction lost retained history).
_log_stream_registry = log_streamer.LogStreamRegistry()
# Ref-counted registry of per-cache-directory log watchers. Each live
# SSE generator calls _acquire_cache_watcher on entry and the matching
# _release_cache_watcher in its finally block, so the observer (and
# its inotify handle) is torn down on the last client disconnect. The
# pre-fix implementation only started watchers and never stopped them,
# so long-running dashboard processes leaked one watcher thread per
# unique cache directory the user ever browsed.
_cache_watchers = {}
_cache_watcher_refcounts = {}
_cache_watchers_lock = threading.Lock()


def _sse_frame(event):
    """Render one event dict as the SSE wire format from the contract."""
    payload = {k: v for k, v in event.items() if k != 'id'}
    return (
        f"event: {event['type']}\n"
        f"id: {event['id']}\n"
        f"data: {json.dumps(payload, separators=(',', ':'))}\n\n"
    )


def _is_terminal_status(status):
    return status not in (None, '', 'active', 'analyzing', 'finalizing', 'unknown')


# Terminal-state marker filenames produced by the RLCR loop. Only
# truly-terminal markers belong here: the SSE generator closes the
# stream as soon as any of these appear, and the dashboard still
# treats ``methodology-analysis-state.md`` / ``finalize-state.md``
# as running (``analyzing`` / ``finalizing`` status, still cancellable,
# still emitting live log bytes). Including those markers in this
# list used to cause the live log pane to EOF the moment a session
# entered finalize or analysis, so the finalize-phase / methodology-
# report output never reached the browser. The list must stay in
# lock-step with ``_is_terminal_status`` above.
_TERMINAL_STATE_FILES = (
    'complete-state.md',
    'cancel-state.md',
    'stop-state.md',
    'maxiter-state.md',
    'unexpected-state.md',
)


def _session_is_terminal_cheap(session_id):
    """Fast path for the SSE EOF check.

    The 250 ms SSE poll loop used to call ``_get_session(session_id,
    force_refresh=True)`` every tick, which re-runs the full
    parse_session pipeline (re-scans every round file, parses the
    goal tracker, re-reads the methodology report, and shells out to
    ``git`` once or twice for the git-status summary). On long
    sessions with many rounds and multiple live SSE clients, that
    quickly becomes the bottleneck.

    Terminal state is trivially detectable from on-disk markers:
    whenever any *-state.md file other than state.md is present the
    loop has stopped writing logs. Check that directly so the hot
    loop doesn't drag the full parser behind it. False negatives
    just defer the EOF by one poll cycle; they never corrupt the
    stream because the file-system watcher still drives every
    append.
    """
    session_dir = _get_session_dir(session_id)
    if not session_dir:
        # The directory vanished or was renamed — treat as terminal
        # so the SSE generator closes cleanly.
        return True
    for name in _TERMINAL_STATE_FILES:
        if os.path.isfile(os.path.join(session_dir, name)):
            return True
    return False


def _acquire_cache_watcher(cache_dir):
    """Reserve a cache watcher for one active SSE stream.

    Starts at most one CacheLogWatcher per cache directory and
    increments a per-directory refcount so concurrent SSE clients on
    the same session share the observer. Paired with
    :func:`_release_cache_watcher`, which stops the watcher when the
    last client releases it. The watcher's callback runs the matching
    LogStream's poll inline so file-system events drive the stream in
    addition to the SSE handler's own 250 ms poll loop. Best-effort
    on startup: if the cache directory does not exist yet the
    watcher does not start and the SSE handler continues to drive
    everything via its poll loop.
    """
    with _cache_watchers_lock:
        _cache_watcher_refcounts[cache_dir] = (
            _cache_watcher_refcounts.get(cache_dir, 0) + 1
        )
        if cache_dir in _cache_watchers:
            return

        def callback(filepath):
            basename = os.path.basename(filepath)
            for stream in _log_stream_registry.streams_in_cache_dir(cache_dir, basename):
                try:
                    stream.poll()
                except Exception:
                    # Watcher callbacks must not crash the observer thread.
                    pass

        watcher = CacheLogWatcher(cache_dir, callback)
        if watcher.start():
            _cache_watchers[cache_dir] = watcher


def _release_cache_watcher(cache_dir):
    """Release one reservation; stop the watcher on the final release.

    Called from the SSE generator's ``finally`` block so an observer
    is torn down when its last client disconnects (normal EOF,
    connection close, or server shutdown). Without this pairing the
    observer thread and inotify handle outlive every session a user
    ever browsed, which exhausts ``fs.inotify.max_user_watches`` on
    long-running dashboard processes.
    """
    with _cache_watchers_lock:
        remaining = _cache_watcher_refcounts.get(cache_dir, 0) - 1
        if remaining <= 0:
            _cache_watcher_refcounts.pop(cache_dir, None)
            watcher = _cache_watchers.pop(cache_dir, None)
        else:
            _cache_watcher_refcounts[cache_dir] = remaining
            watcher = None
    if watcher is not None:
        try:
            watcher.stop()
        except Exception:
            # Best-effort cleanup: a failed observer stop must not
            # take down the request that triggered the release.
            pass


def _acquire_log_stream(session_id, basename):
    """Acquire the shared LogStream for ``(session_id, basename)``.

    Increments the registry refcount so the caller owns one release.
    The caller (the SSE route) MUST pair this with
    :func:`_release_log_stream` and
    :func:`_acquire_cache_watcher` / :func:`_release_cache_watcher`
    around the generator body so stream + watcher lifetimes track
    active SSE consumers instead of process lifetime. Without the
    release, the registry retains the 256-event deque (often large
    base64 payloads) for every session the user ever browsed.
    """
    cache_dir = rlcr_sources.cache_dir_for_session(PROJECT_DIR, session_id)
    stream = _log_stream_registry.acquire(cache_dir, session_id, basename)
    return stream


def _release_log_stream(session_id, basename):
    """Release one :func:`_acquire_log_stream` reservation."""
    _log_stream_registry.release(session_id, basename)


@app.route('/api/sessions/<session_id>/logs/<basename>')
def stream_session_log(session_id, basename):
    """Per-session, per-file SSE stream per the streaming protocol.

    Implements the snapshot+append+resync+eof event sequence frozen in
    docs/streaming-protocol.md, including Last-Event-Id reconnect with
    the documented 256-event retention. Remote-mode authentication is
    enforced by the @app.before_request middleware: in remote mode the
    request must carry a valid bearer token (`Authorization: Bearer`
    header for fetch-style calls, `?token=` query parameter for SSE
    EventSource clients per DEC-4); missing or invalid token returns
    401. Localhost-bound deployments skip the auth check.
    """
    if not _LOG_BASENAME_RE.match(basename):
        abort(400)
    session_dir = _get_session_dir(session_id)
    if session_dir is None:
        abort(404)

    stream = _acquire_log_stream(session_id, basename)
    # Resolve the cache directory once up-front so the generator's
    # watcher acquire/release pair references the same key. The
    # registry helper derives it internally; re-derive here so the
    # cache-watcher refcount key matches the stream registry's.
    cache_dir = rlcr_sources.cache_dir_for_session(PROJECT_DIR, session_id)

    last_event_id = 0
    raw_id = request.headers.get('Last-Event-Id')
    if raw_id:
        try:
            last_event_id = int(raw_id)
        except ValueError:
            last_event_id = 0

    def generate():
        # Reserve the per-cache-dir watcher for the lifetime of this
        # stream. The paired release in the finally block below is
        # what lets long-running dashboard instances stop leaking
        # inotify handles (one per distinct session the user browses)
        # after clients disconnect. The log-stream refcount acquired
        # at route entry is released here too so its retention deque
        # can be freed once the last client has seen EOF.
        _acquire_cache_watcher(cache_dir)
        try:
            client_last_id = last_event_id

            # Initial event delivery: replay if the client has a Last-Event-Id,
            # else fresh snapshot. The route never falls through to a poll
            # that would emit the file body as `append` from offset 0.
            if client_last_id > 0:
                replayed, in_window = stream.replay(client_last_id)
                for event in replayed:
                    yield _sse_frame(event)
                    client_last_id = event['id']
                if not in_window:
                    for event in stream.snapshot():
                        yield _sse_frame(event)
                        client_last_id = event['id']
            else:
                for event in stream.snapshot():
                    yield _sse_frame(event)
                    client_last_id = event['id']

            # Steady-state loop. Drive poll() (may be a no-op if the cache
            # watcher or another concurrent handler already polled), then
            # forward any retained events newer than what this client has
            # already sent. Using the deque as the source of truth means
            # multiple concurrent SSE clients on the same stream all
            # receive every event without racing on _offset.
            last_heartbeat = time.time()
            while True:
                stream.poll()
                catchup, in_window = stream.replay(client_last_id)
                for event in catchup:
                    yield _sse_frame(event)
                    client_last_id = event['id']
                if not in_window:
                    for event in stream.snapshot():
                        yield _sse_frame(event)
                        client_last_id = event['id']

                # Cheap disk probe instead of a full parse_session on
                # every SSE tick. Avoids re-scanning round files, goal
                # tracker, and the `git status` subprocesses just to
                # decide whether to emit EOF.
                if _session_is_terminal_cheap(session_id):
                    for event in stream.mark_eof():
                        yield _sse_frame(event)
                        client_last_id = event['id']
                    return

                now = time.time()
                if now - last_heartbeat >= _SSE_HEARTBEAT_INTERVAL_SECONDS and not catchup:
                    yield ": keepalive\n\n"
                    last_heartbeat = now
                time.sleep(_SSE_POLL_INTERVAL_SECONDS)
        finally:
            # Runs on normal EOF return, GeneratorExit (client
            # disconnect), or any propagated exception, so the
            # refcount always balances the earlier acquire. The
            # log-stream release evicts the stream's retention deque
            # once its final client disconnects AND EOF has already
            # been delivered; active sessions without a current
            # client stay resident so reconnects get the replay
            # window the streaming contract requires.
            _release_cache_watcher(cache_dir)
            _release_log_stream(session_id, basename)

    response = Response(generate(), mimetype='text/event-stream')
    response.headers['Cache-Control'] = 'no-cache'
    response.headers['X-Accel-Buffering'] = 'no'
    return response


# --- WebSocket ---

@sock.route('/ws')
def websocket(ws):
    # T11 / DEC-4: WebSocket transport is restricted to localhost. In
    # remote mode (host != 127.0.0.1) the dashboard MUST use SSE for
    # log streams (over HTTPS with `?token=` auth), so the WebSocket
    # control channel is rejected entirely. Browsers cannot send
    # arbitrary auth headers on WebSocket upgrades, which is the root
    # reason behind DEC-4.
    if not _is_localhost_bind():
        try:
            ws.close(reason='WebSocket transport disabled in remote mode')
        except Exception:
            pass
        return

    # Cross-origin WebSocket rejection. The HTTP side of the app
    # gates mutating routes through `_enforce_csrf_protection`, but
    # browsers happily let arbitrary pages open a WebSocket to
    # ws://localhost:<port>/ws with no Origin check from the server.
    # A `cancel_session` message over that connection would kill an
    # active loop with zero auth prompt. Reuse the same request-host
    # matcher so the localhost dashboard's own Origin keeps working
    # while hostile origins (pages served by other projects in the
    # same browser) are closed before they can send anything.
    origin = request.headers.get('Origin', '').strip()
    if origin and not _origin_matches_request(origin):
        try:
            ws.close(reason='cross-origin WebSocket rejected')
        except Exception:
            pass
        return

    with _ws_lock:
        _ws_clients.add(ws)
    try:
        while True:
            data = ws.receive(timeout=60)
            if data is None:
                continue
            try:
                msg = json.loads(data)
                if msg.get('type') == 'cancel_session':
                    sid = msg.get('session_id', '')
                    if sid:
                        session = _get_session(sid)
                        if session and session.get('status') in _CANCELLABLE_STATUSES:
                            # Route through the session-scoped helper
                            # instead of the project-global cancel.
                            # Match the REST route's --force handling
                            # so finalizing sessions can be cancelled.
                            cancel_script = _find_session_cancel_script()
                            if cancel_script:
                                # Mirror the REST route: pass --project
                                # explicitly so the helper does not
                                # fall back to a stray
                                # CLAUDE_PROJECT_DIR inherited from
                                # the launching shell.
                                helper_args = [
                                    cancel_script,
                                    '--project', PROJECT_DIR,
                                    '--session-id', sid,
                                ]
                                if session.get('status') == 'finalizing':
                                    helper_args.append('--force')
                                subprocess.run(
                                    helper_args,
                                    cwd=PROJECT_DIR, timeout=30,
                                )
                                _invalidate_cache(sid)
            except (json.JSONDecodeError, KeyError):
                pass
    except Exception:
        pass
    finally:
        with _ws_lock:
            _ws_clients.discard(ws)


# --- Main ---

def _resolve_auth_token(cli_token):
    """Pick the effective bearer token from the CLI flag or env var."""
    if cli_token:
        return cli_token
    return os.environ.get('HUMANIZE_VIZ_TOKEN', '').strip()


def main():
    parser = argparse.ArgumentParser(description='Humanize Viz Dashboard Server')
    parser.add_argument('--host', type=str, default='127.0.0.1',
                        help='Bind address (default: 127.0.0.1)')
    parser.add_argument('--port', type=int, default=18000,
                        help='Bind port (default: 18000)')
    parser.add_argument('--project', type=str, default='.',
                        help='Project root for the dashboard (CLI-fixed per DEC-3)')
    parser.add_argument('--static', type=str, default='.',
                        help='Directory containing the SPA static assets')
    parser.add_argument('--auth-token', type=str, default='',
                        help='Bearer token required for remote-mode access. '
                             'May also be supplied via HUMANIZE_VIZ_TOKEN env var. '
                             'Required when --host is not a loopback address.')
    parser.add_argument('--trust-proxy', action='store_true', default=False,
                        help='Acknowledge that a TLS-terminating reverse proxy '
                             'is in front of this server. Required for '
                             'non-loopback binds because the SSE stream '
                             'transmits the bearer token as a ?token= query '
                             'parameter, which would leak in cleartext over '
                             'plain HTTP. May also be enabled via the '
                             'HUMANIZE_VIZ_TRUST_PROXY=1 env var.')
    args = parser.parse_args()

    global PROJECT_DIR, STATIC_DIR, BIND_HOST, AUTH_TOKEN, TRUST_PROXY, _watcher
    PROJECT_DIR = os.path.abspath(args.project)
    STATIC_DIR = os.path.abspath(args.static)
    BIND_HOST = args.host
    AUTH_TOKEN = _resolve_auth_token(args.auth_token)
    TRUST_PROXY = args.trust_proxy or os.environ.get(
        'HUMANIZE_VIZ_TRUST_PROXY', ''
    ).strip() in ('1', 'true', 'yes')

    if not _is_localhost_bind() and not AUTH_TOKEN:
        print(
            "Error: binding to a non-localhost host requires --auth-token "
            "(or HUMANIZE_VIZ_TOKEN env var). Refusing to start a remote "
            "server without authentication.",
            file=sys.stderr,
        )
        sys.exit(2)

    # Plain-HTTP Flask + ?token= bearer auth is safe on loopback
    # (nothing ever leaves the host), but leaks the token in
    # cleartext the moment the bind is externally reachable. Require
    # an explicit operator acknowledgement that a TLS-terminating
    # reverse proxy is in front of the server before accepting a
    # non-loopback bind. The flag / env var is a load-bearing
    # declaration: without it we'd rather refuse to start than hand
    # out an insecure dashboard URL. TRUST_PROXY is resolved above
    # and also drives the CSRF port-matcher's X-Forwarded-Proto
    # handling.
    if not _is_localhost_bind() and not TRUST_PROXY:
        print(
            "Error: binding to a non-localhost host requires a TLS-terminating\n"
            "reverse proxy so the ?token= query parameter is never transmitted\n"
            "in cleartext. Pass --trust-proxy (or HUMANIZE_VIZ_TRUST_PROXY=1)\n"
            "to acknowledge that an HTTPS reverse proxy (nginx / caddy / etc.)\n"
            "is in front of this server.",
            file=sys.stderr,
        )
        sys.exit(2)

    # Start file watcher
    _watcher = SessionWatcher(PROJECT_DIR, broadcast_message)
    _watcher.start()

    # Pre-populate cache
    list_sessions(PROJECT_DIR)

    visible_host = BIND_HOST if not _is_localhost_bind() else 'localhost'
    print(f"Humanize Viz server starting on http://{visible_host}:{args.port}")
    print(f"Project: {PROJECT_DIR}")
    print(f"Static:  {STATIC_DIR}")
    if AUTH_TOKEN:
        print("Remote mode: token authentication enabled.")
    elif _is_localhost_bind():
        print("Local mode: authentication disabled (loopback bind).")

    app.run(host=BIND_HOST, port=args.port, debug=False)


if __name__ == '__main__':
    main()
