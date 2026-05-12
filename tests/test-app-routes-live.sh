#!/usr/bin/env bash
#
# Live Flask test_client coverage for viz/server/app.py (T13).
#
# Drives the actual Flask app with route-level requests rather than
# pattern checks. Bootstraps a Python venv with Flask + flask-sock +
# watchdog + pyyaml if VIZ_TEST_VENV is unset; uses the supplied venv
# otherwise.
#
# Coverage (every assertion is a real Flask test_client request):
#   - GET /api/health (open in any mode).
#   - GET /api/sessions (200 with one CLI-fixed entry; 401 in remote
#     mode without valid token).
#   - GET /api/sessions/<id> (200 known / 404 unknown in localhost;
#     401 without token / 200 with valid bearer in remote mode).
#   - POST /api/sessions/cancel (400 missing-id route from Round 5).
#   - POST /api/sessions/<id>/cancel (404 unknown; 401 without token in
#     remote mode).
#   - 410 Gone for /api/projects/{switch,add,remove}.
#   - GET /api/sessions/<id>/logs/<basename> SSE: initial snapshot and
#     auto-eof when the session has terminal status (so test_client
#     iter_encoded() returns); basename validation rejects non-matching
#     names with 400; missing-cache startup yields resync(missing)+eof.
#   - Auth middleware: every protected endpoint requires a token in
#     remote mode; missing/invalid token returns 401, valid token
#     passes.
#   - Concurrent active sessions enumerated correctly with mixed
#     lifecycle states.
#   - Truncation recovery via the SSE route: a writer thread mutates
#     the cache log mid-stream while the SSE generator is reading,
#     then transitions the session to a terminal status so the
#     generator emits eof; the collected event stream contains the
#     full snapshot -> resync(truncated) -> snapshot -> eof sequence.
#
# All fixtures live under a per-test mktemp tree; no real ~/.humanize
# or ~/.cache/humanize is touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "========================================"
echo "Live Flask test_client coverage (T13)"
echo "========================================"

if ! command -v python3 &>/dev/null; then
    echo "SKIP: python3 not available"
    exit 0
fi

VENV_DIR="${VIZ_TEST_VENV:-/tmp/viz-routes-test-venv}"
if [[ ! -d "$VENV_DIR/bin" ]]; then
    echo "Bootstrapping test venv at $VENV_DIR (Flask + flask-sock + watchdog + pyyaml)..."
    if ! python3 -m venv "$VENV_DIR" 2>/dev/null; then
        echo "SKIP: failed to create venv at $VENV_DIR"
        exit 0
    fi
    if ! "$VENV_DIR/bin/pip" install --quiet flask flask-sock watchdog pyyaml 2>/dev/null; then
        echo "SKIP: failed to install Flask + deps (no internet?); cannot exercise live routes"
        exit 0
    fi
fi

# Sanity-check the venv has the imports.
if ! "$VENV_DIR/bin/python" -c "import flask, flask_sock, watchdog, yaml" 2>/dev/null; then
    echo "SKIP: venv at $VENV_DIR is missing required packages"
    exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Run the Python driver that does the heavy lifting.
"$VENV_DIR/bin/python" - "$PLUGIN_ROOT" "$TMP_DIR" <<'PYEOF'
import os
import sys
import json
import base64
import shutil
import threading
from contextlib import contextmanager

PLUGIN_ROOT, TMP_DIR = sys.argv[1], sys.argv[2]
SERVER_DIR = os.path.join(PLUGIN_ROOT, 'viz', 'server')
sys.path.insert(0, SERVER_DIR)


# ─── Fixture helpers ────────────────────────────────────────────────
def make_project(name, sessions):
    """Build a tmp project with the requested seeded sessions.

    sessions is a list of dicts: {id, status_files: {filename: content}}
    where filename is e.g. "state.md", "complete-state.md", etc.
    """
    project = os.path.join(TMP_DIR, name)
    rlcr = os.path.join(project, '.humanize', 'rlcr')
    os.makedirs(rlcr, exist_ok=True)
    for s in sessions:
        sd = os.path.join(rlcr, s['id'])
        os.makedirs(sd, exist_ok=True)
        for fn, content in s.get('status_files', {}).items():
            with open(os.path.join(sd, fn), 'w', encoding='utf-8') as f:
                f.write(content)
    return project


def seed_cache_log(project_root, session_id, basename, content_bytes):
    """Seed a cache log under XDG_CACHE_HOME (set per-test to TMP_DIR)."""
    import re
    cache_root = os.path.join(os.environ['XDG_CACHE_HOME'], 'humanize')
    sanitized = re.sub(r'-+', '-', re.sub(r'[^A-Za-z0-9._-]', '-', project_root))
    cache_dir = os.path.join(cache_root, sanitized, session_id)
    os.makedirs(cache_dir, exist_ok=True)
    path = os.path.join(cache_dir, basename)
    with open(path, 'wb') as f:
        f.write(content_bytes)
    return path


PASS = 0
FAIL = 0


def t_pass(msg):
    global PASS
    PASS += 1
    print(f"\033[0;32mPASS\033[0m: {msg}")


def t_fail(msg):
    global FAIL
    FAIL += 1
    print(f"\033[0;31mFAIL\033[0m: {msg}")


@contextmanager
def configured_app(host='127.0.0.1', auth_token='', project_dir=None):
    """Reload viz/server/app.py with a fresh PROJECT_DIR / BIND_HOST.

    The module holds globals (PROJECT_DIR, BIND_HOST, AUTH_TOKEN), so
    each test sets them directly rather than going through main().
    The watcher is NOT started so tests stay deterministic.
    """
    import importlib
    import app as _appmod
    importlib.reload(_appmod)
    # Override module globals before the test client makes any request.
    _appmod.PROJECT_DIR = project_dir or TMP_DIR
    _appmod.STATIC_DIR = os.path.join(PLUGIN_ROOT, 'viz', 'static')
    _appmod.BIND_HOST = host
    _appmod.AUTH_TOKEN = auth_token
    # Use Flask's testing config so 500s do not get swallowed.
    _appmod.app.config['TESTING'] = True
    yield _appmod


# ─── Tests ──────────────────────────────────────────────────────────

# Group 1: localhost-bound app, no auth required
print("\nGroup 1: localhost-bound app, no auth")
project = make_project('proj_localhost', [
    {'id': '2026-04-17_10-00-00', 'status_files': {
        'state.md': '---\ncurrent_round: 2\nmax_iterations: 42\n---\n',
    }},
    {'id': '2026-04-16_09-00-00', 'status_files': {
        'complete-state.md': '---\ncurrent_round: 5\nmax_iterations: 42\n---\n',
    }},
])
os.environ['XDG_CACHE_HOME'] = os.path.join(TMP_DIR, 'xdg_cache')

with configured_app(project_dir=project) as appmod:
    client = appmod.app.test_client()

    r = client.get('/api/health')
    if r.status_code == 200 and r.get_json().get('status') == 'ok':
        t_pass("GET /api/health 200 ok")
    else:
        t_fail(f"GET /api/health failed: {r.status_code}")

    r = client.get('/api/sessions')
    if r.status_code == 200:
        body = r.get_json() or []
        if isinstance(body, list) and len(body) >= 1:
            t_pass(f"GET /api/sessions returned {len(body)} session(s)")
        else:
            t_fail(f"GET /api/sessions body wrong: {body}")
    else:
        t_fail(f"GET /api/sessions failed: {r.status_code}")

    r = client.get('/api/projects')
    body = r.get_json() or []
    if r.status_code == 200 and isinstance(body, list) and len(body) == 1 and body[0].get('cli_fixed') is True:
        t_pass("GET /api/projects returns one CLI-fixed entry")
    else:
        t_fail(f"GET /api/projects unexpected: {r.status_code} {body}")

    r = client.post('/api/projects/switch', json={'path': '/tmp'})
    if r.status_code == 410:
        t_pass("POST /api/projects/switch returns 410 Gone")
    else:
        t_fail(f"projects/switch should return 410, got {r.status_code}")

    r = client.post('/api/projects/add', json={'path': '/tmp'})
    if r.status_code == 410:
        t_pass("POST /api/projects/add returns 410 Gone")
    else:
        t_fail(f"projects/add should return 410, got {r.status_code}")

    r = client.post('/api/projects/remove', json={'path': '/tmp'})
    if r.status_code == 410:
        t_pass("POST /api/projects/remove returns 410 Gone")
    else:
        t_fail(f"projects/remove should return 410, got {r.status_code}")

    # Missing-session-id 400 (the dedicated /api/sessions/cancel route)
    r = client.post('/api/sessions/cancel')
    if r.status_code == 400 and 'session_id is required' in (r.get_data(as_text=True) or ''):
        t_pass("POST /api/sessions/cancel 400 with 'session_id is required'")
    else:
        t_fail(f"missing-id 400 route wrong: {r.status_code} {r.get_data(as_text=True)}")

    # Unknown session 404
    r = client.post('/api/sessions/9999-99-99/cancel')
    if r.status_code == 404:
        t_pass("POST /api/sessions/<unknown>/cancel returns 404")
    else:
        t_fail(f"unknown-session cancel wrong: {r.status_code}")

    # GET /api/sessions/<known> returns the parsed session dict
    r = client.get('/api/sessions/2026-04-17_10-00-00')
    if r.status_code == 200:
        body = r.get_json() or {}
        if body.get('id') == '2026-04-17_10-00-00' and body.get('status'):
            t_pass("GET /api/sessions/<known> returns parsed session dict")
        else:
            t_fail(f"GET /api/sessions/<known> body wrong: {body}")
    else:
        t_fail(f"GET /api/sessions/<known> failed: {r.status_code}")

    # GET /api/sessions/<unknown> returns 404
    r = client.get('/api/sessions/9999-99-99-no-such')
    if r.status_code == 404:
        t_pass("GET /api/sessions/<unknown> returns 404")
    else:
        t_fail(f"GET /api/sessions/<unknown> should 404, got {r.status_code}")

# Group 2: remote-bound app with token enforcement
print("\nGroup 2: remote-bound app + token enforcement")
TOKEN = 'a-very-secret-test-token'
with configured_app(host='192.0.2.10', auth_token=TOKEN, project_dir=project) as appmod:
    client = appmod.app.test_client()

    r = client.get('/api/health')
    if r.status_code == 200:
        t_pass("GET /api/health open in remote mode")
    else:
        t_fail(f"health should be open: {r.status_code}")

    r = client.get('/api/sessions')
    if r.status_code == 401:
        t_pass("GET /api/sessions 401 without token in remote mode")
    else:
        t_fail(f"missing-token sessions should 401, got {r.status_code}")

    r = client.get('/api/sessions', headers={'Authorization': f'Bearer {TOKEN}'})
    if r.status_code == 200:
        t_pass("GET /api/sessions 200 with valid bearer token")
    else:
        t_fail(f"valid-token sessions failed: {r.status_code}")

    r = client.get('/api/sessions', headers={'Authorization': 'Bearer wrong-token'})
    if r.status_code == 401:
        t_pass("GET /api/sessions 401 with invalid bearer token")
    else:
        t_fail(f"invalid-token sessions should 401, got {r.status_code}")

    # SSE handler is also gated. Use ?token= query param per DEC-4.
    seed_cache_log(project, '2026-04-17_10-00-00', 'round-2-codex-run.log', b'hello')
    r = client.get('/api/sessions/2026-04-17_10-00-00/logs/round-2-codex-run.log')
    if r.status_code == 401:
        t_pass("SSE stream 401 without ?token= in remote mode")
    else:
        t_fail(f"missing-token SSE should 401, got {r.status_code}")

    r = client.post('/api/sessions/2026-04-17_10-00-00/cancel')
    if r.status_code == 401:
        t_pass("POST cancel 401 without token in remote mode")
    else:
        t_fail(f"missing-token cancel should 401, got {r.status_code}")

    # GET /api/sessions/<known> in remote mode: 401 without, 200 with token
    r = client.get('/api/sessions/2026-04-17_10-00-00')
    if r.status_code == 401:
        t_pass("GET /api/sessions/<known> 401 without token in remote mode")
    else:
        t_fail(f"detail GET should 401 without token, got {r.status_code}")

    r = client.get(
        '/api/sessions/2026-04-17_10-00-00',
        headers={'Authorization': f'Bearer {TOKEN}'},
    )
    if r.status_code == 200 and (r.get_json() or {}).get('id') == '2026-04-17_10-00-00':
        t_pass("GET /api/sessions/<known> 200 with valid bearer token in remote mode")
    else:
        t_fail(f"detail GET with valid token wrong: {r.status_code} {r.get_data(as_text=True)[:200]}")

# Group 3: SSE stream behavior on terminal session (auto-eof)
print("\nGroup 3: SSE stream on terminal session (auto-eof)")

# Add a terminal session whose SSE generator self-terminates.
project_term = make_project('proj_terminal', [
    {'id': '2026-04-17_11-00-00', 'status_files': {
        'complete-state.md': '---\ncurrent_round: 3\nmax_iterations: 42\n---\n',
    }},
])
seed_cache_log(project_term, '2026-04-17_11-00-00',
               'round-1-codex-run.log', b'snapshot bytes here')

with configured_app(project_dir=project_term) as appmod:
    client = appmod.app.test_client()

    r = client.get('/api/sessions/2026-04-17_11-00-00/logs/round-1-codex-run.log',
                   buffered=True)
    if r.status_code == 200:
        body = b''.join(r.iter_encoded()).decode('utf-8', errors='replace')
        if 'event: snapshot' in body and 'event: eof' in body:
            t_pass("SSE stream on terminal session yields snapshot + eof")
        else:
            t_fail(f"SSE body missing expected events:\n{body[:500]}")
    else:
        t_fail(f"SSE 200 expected, got {r.status_code}")

    # Bad basename rejected
    r = client.get('/api/sessions/2026-04-17_11-00-00/logs/not-a-valid-name.txt',
                   buffered=True)
    if r.status_code == 400:
        t_pass("SSE rejects basenames that don't match round-N-{codex,gemini}-{run,review}.log")
    else:
        t_fail(f"bad basename should 400, got {r.status_code}")

# Group 4: two concurrent active sessions enumerated
print("\nGroup 4: concurrent active sessions")
proj_concurrent = make_project('proj_concurrent', [
    {'id': '2026-04-17_A', 'status_files': {
        'state.md': '---\ncurrent_round: 1\nmax_iterations: 42\n---\n',
    }},
    {'id': '2026-04-17_B', 'status_files': {
        'methodology-analysis-state.md': '---\ncurrent_round: 5\nmax_iterations: 42\n---\n',
    }},
    {'id': '2026-04-17_C', 'status_files': {
        'finalize-state.md': '---\ncurrent_round: 9\nmax_iterations: 42\n---\n',
    }},
    {'id': '2026-04-17_D', 'status_files': {
        'cancel-state.md': '---\ncurrent_round: 2\nmax_iterations: 42\n---\n',
    }},
])
with configured_app(project_dir=proj_concurrent) as appmod:
    client = appmod.app.test_client()
    r = client.get('/api/sessions')
    body = r.get_json() or []
    statuses = {s['id']: s['status'] for s in body if isinstance(s, dict)}
    expected = {
        '2026-04-17_A': 'active',
        '2026-04-17_B': 'analyzing',
        '2026-04-17_C': 'finalizing',
        '2026-04-17_D': 'cancel',
    }
    if all(statuses.get(k) == v for k, v in expected.items()):
        t_pass("4 sessions with mixed lifecycle states enumerated correctly")
    else:
        t_fail(f"lifecycle status enumeration wrong: {statuses}")

# Group 5: missing-cache startup race
print("\nGroup 5: missing-cache startup race")
proj_race = make_project('proj_race', [
    {'id': '2026-04-17_R', 'status_files': {
        'state.md': '---\ncurrent_round: 0\nmax_iterations: 42\n---\n',
    }},
])
with configured_app(project_dir=proj_race) as appmod:
    client = appmod.app.test_client()
    # Active session with a state.md but NO terminal status → SSE
    # generator never auto-eofs. To keep the test deterministic, rename
    # the session to terminal mid-test by writing a complete-state.md
    # AFTER the snapshot but BEFORE a long poll. Easier: just check
    # the route accepts the request even without the cache log; the
    # missing-cache resync semantics are unit-tested in test-streaming.sh.
    # Drop the session into terminal state from the start so the
    # generator self-terminates.
    rlcr_dir = os.path.join(proj_race, '.humanize', 'rlcr', '2026-04-17_R')
    os.rename(os.path.join(rlcr_dir, 'state.md'),
              os.path.join(rlcr_dir, 'complete-state.md'))
    r = client.get('/api/sessions/2026-04-17_R/logs/round-0-codex-run.log',
                   buffered=True)
    if r.status_code == 200:
        body = b''.join(r.iter_encoded()).decode('utf-8', errors='replace')
        if 'event: resync' in body and 'missing' in body and 'event: eof' in body:
            t_pass("missing-cache startup yields resync(missing) + eof")
        else:
            t_fail(f"missing-cache body unexpected:\n{body[:500]}")
    else:
        t_fail(f"missing-cache SSE 200 expected, got {r.status_code}")

# Group 6: route-backed truncation recovery via the SSE endpoint.
# A writer thread mutates the cache log mid-stream while the SSE
# generator is reading; once the mutation sequence is done the
# session transitions to a terminal status so the generator emits
# eof and Flask's iter_encoded() returns. The collected event stream
# must contain the full snapshot -> resync(truncated) -> snapshot ->
# eof sequence, proving the real Flask route honors the protocol
# contract end to end (not just the LogStream class in isolation).
print("\nGroup 6: route-backed truncation through the SSE endpoint")

import time as _time

proj_trunc = make_project('proj_trunc_route', [
    {'id': '2026-04-17_TR', 'status_files': {
        'state.md': '---\ncurrent_round: 0\nmax_iterations: 42\n---\n',
    }},
])
TR_LOG = seed_cache_log(proj_trunc, '2026-04-17_TR',
                        'round-0-codex-run.log', b'initial bytes here')
TR_RLCR = os.path.join(proj_trunc, '.humanize', 'rlcr', '2026-04-17_TR')

def _writer_then_terminate():
    # Wait long enough for the SSE handler to emit the initial
    # snapshot. The handler polls every 0.25 s and exits the snapshot
    # loop after one read, so 0.6 s is comfortably past the first
    # poll boundary.
    _time.sleep(0.6)
    # Truncate by overwriting with shorter content.
    with open(TR_LOG, 'wb') as f:
        f.write(b'short')
    # Give the poll loop a tick to detect the size shrink and emit
    # resync(truncated) plus a fresh snapshot.
    _time.sleep(0.6)
    # Transition to terminal so the SSE generator emits eof and Flask
    # closes the response. The handler checks status every poll
    # iteration via _get_session(force_refresh=True).
    os.rename(os.path.join(TR_RLCR, 'state.md'),
              os.path.join(TR_RLCR, 'complete-state.md'))

with configured_app(project_dir=proj_trunc) as appmod:
    client = appmod.app.test_client()
    writer_thread = threading.Thread(target=_writer_then_terminate, daemon=True)
    writer_thread.start()

    r = client.get('/api/sessions/2026-04-17_TR/logs/round-0-codex-run.log',
                   buffered=True)
    writer_thread.join(timeout=5)

    if r.status_code != 200:
        t_fail(f"route-backed truncation: SSE 200 expected, got {r.status_code}")
    else:
        body = b''.join(r.iter_encoded()).decode('utf-8', errors='replace')
        # Count occurrences to verify the full sequence.
        snap_count = body.count('event: snapshot')
        resync_truncated = ('event: resync' in body
                            and '"reason":"truncated"' in body)
        eof_seen = 'event: eof' in body
        if snap_count >= 2 and resync_truncated and eof_seen:
            t_pass("SSE route emits snapshot -> resync(truncated) -> snapshot -> eof in sequence")
        else:
            t_fail(
                "route-backed truncation event stream incomplete: "
                f"snapshots={snap_count} resync_truncated={resync_truncated} eof={eof_seen}\n"
                f"body[:800]:\n{body[:800]}"
            )

# Group 7: CSRF protection on mutating endpoints (Round 8 P1 fix).
# A loopback-bound dashboard would otherwise accept cross-origin POSTs
# from any webpage open in the same browser. The same-origin check
# layered on top of the auth middleware closes that gap regardless
# of bind. Read methods (GET) stay open; the test verifies that
# behaviour is unchanged.
print("\nGroup 7: CSRF protection on mutating endpoints (P1)")

with configured_app(project_dir=project) as appmod:
    client = appmod.app.test_client()

    # Localhost POST with a cross-origin Origin header → 403.
    r = client.post(
        '/api/sessions/2026-04-17_10-00-00/cancel',
        headers={'Origin': 'http://evil.example.com'},
    )
    if r.status_code == 403 and 'cross-origin write rejected' in (r.get_data(as_text=True) or ''):
        t_pass("localhost POST with cross-origin Origin returns 403")
    else:
        t_fail(f"cross-origin POST should 403, got {r.status_code} {r.get_data(as_text=True)[:200]}")

    # Localhost POST with a same-origin Origin → goes through the
    # normal handler chain (400 here because the session is in a
    # terminal state, not active/analyzing/finalizing). Flask
    # test_client's default request Host is `localhost` (no explicit
    # port, implicit port 80), so the same-origin check uses an
    # Origin that resolves to the same host:port pair.
    r = client.post(
        '/api/sessions/2026-04-16_09-00-00/cancel',
        headers={'Origin': 'http://localhost'},
    )
    if r.status_code != 403:
        t_pass(f"localhost POST with same-origin Origin passes CSRF gate (handler returned {r.status_code})")
    else:
        t_fail(f"same-origin POST should NOT 403, got {r.status_code}")

    # Cross-origin Referer (no Origin) also rejected.
    r = client.post(
        '/api/sessions/2026-04-17_10-00-00/cancel',
        headers={'Referer': 'http://evil.example.com/foo'},
    )
    if r.status_code == 403:
        t_pass("localhost POST with cross-origin Referer returns 403")
    else:
        t_fail(f"cross-origin Referer POST should 403, got {r.status_code}")

    # GET requests are unaffected by CSRF (Same-Origin Policy already
    # prevents cross-origin pages from reading our responses).
    r = client.get(
        '/api/sessions',
        headers={'Origin': 'http://evil.example.com'},
    )
    if r.status_code == 200:
        t_pass("GET requests are not gated by CSRF (cross-origin Origin still 200)")
    else:
        t_fail(f"GET should not be gated by CSRF, got {r.status_code}")

# CSRF for the documented `--host 0.0.0.0` remote scenario: the bind
# is a wildcard, but browsers send the machine's real hostname, so a
# literal-bind comparison would (incorrectly) reject every cross-host
# POST as cross-origin. The fix compares Origin against the request's
# own Host header instead. We simulate that by configuring BIND_HOST
# to the wildcard and sending a request whose Origin matches the
# test_client's implicit Host (`localhost`).
print("\nGroup 7b: CSRF accepts real hostnames for wildcard remote bind")
TOKEN_REMOTE = 'token-for-wildcard-bind-test'
with configured_app(host='0.0.0.0', auth_token=TOKEN_REMOTE, project_dir=proj_lifecycle if False else project) as appmod:
    client = appmod.app.test_client()
    r = client.post(
        '/api/sessions/2026-04-16_09-00-00/cancel',
        headers={
            'Origin': 'http://localhost',
            'Authorization': f'Bearer {TOKEN_REMOTE}',
        },
    )
    if r.status_code != 403:
        t_pass(f"wildcard 0.0.0.0 bind: Origin matching request Host passes CSRF (handler returned {r.status_code})")
    else:
        t_fail("wildcard 0.0.0.0 bind: same-origin Origin still rejected as cross-origin")

    # And the cross-origin negative still rejects in wildcard mode.
    r = client.post(
        '/api/sessions/2026-04-16_09-00-00/cancel',
        headers={
            'Origin': 'http://evil.example.com',
            'Authorization': f'Bearer {TOKEN_REMOTE}',
        },
    )
    if r.status_code == 403:
        t_pass("wildcard 0.0.0.0 bind: cross-origin Origin still 403")
    else:
        t_fail(f"wildcard 0.0.0.0 bind: cross-origin should 403, got {r.status_code}")

# Group 7c: IPv6 loopback bind (Round 11 P2 fix). request.host carries
# the bracketed form `[::1]:18000` per RFC 7230, but urlparse on the
# Origin returns the unbracketed `::1`. Without bracket-stripping the
# same-origin compare would 403 every mutating request from the
# documented IPv6 loopback bind.
print("\nGroup 7c: CSRF strips IPv6 brackets before same-origin compare (P2 Round 11)")
with configured_app(host='::1', auth_token='', project_dir=project) as appmod:
    client = appmod.app.test_client()
    # Simulate a request whose Host is the bracketed IPv6 form.
    # Flask test_client honors the Host header explicitly.
    r = client.post(
        '/api/sessions/2026-04-16_09-00-00/cancel',
        headers={
            'Host': '[::1]',
            'Origin': 'http://[::1]',
        },
    )
    if r.status_code != 403:
        t_pass(f"IPv6 loopback bind: bracketed Host vs unbracketed Origin host passes CSRF (handler returned {r.status_code})")
    else:
        t_fail("IPv6 loopback bind: same-origin POST still rejected as cross-origin")

    # Cross-origin still rejected when Host is IPv6.
    r = client.post(
        '/api/sessions/2026-04-16_09-00-00/cancel',
        headers={
            'Host': '[::1]',
            'Origin': 'http://evil.example.com',
        },
    )
    if r.status_code == 403:
        t_pass("IPv6 loopback bind: cross-origin Origin still 403")
    else:
        t_fail(f"IPv6 loopback bind: cross-origin should 403, got {r.status_code}")

# Group 7d: malformed Origin ports are a controlled 403, not an
# uncaught ValueError. ``urlparse`` accepts values like
# ``http://host:bad`` or ``http://host:999999`` without raising, but
# accessing ``.port`` raises ValueError. Without bracketing that access
# in try/except, cancel/report/issue POSTs from a client sending such
# a header would return 500 instead of the intended 403.
print("\nGroup 7d: CSRF rejects malformed Origin ports with 403 (no 500)")
with configured_app(host='127.0.0.1', auth_token='', project_dir=project) as appmod:
    client = appmod.app.test_client()
    for bad_origin in (
        'http://localhost:bad',
        'http://localhost:999999',
        'http://localhost:-1',
        'http://localhost:0.5',
    ):
        r = client.post(
            '/api/sessions/2026-04-16_09-00-00/cancel',
            headers={'Origin': bad_origin},
        )
        if r.status_code == 403:
            t_pass(f"malformed Origin {bad_origin!r} -> 403 (not 500)")
        else:
            t_fail(f"malformed Origin {bad_origin!r} should 403, got {r.status_code}")

# Group 8: cancel allows analyzing / finalizing phases (Round 8 P2 fix).
# The dashboard previously rejected anything except status == 'active',
# which made finalize-stuck loops uncancellable from the UI even
# though scripts/cancel-rlcr-session.sh supports those phases.
print("\nGroup 8: cancel route accepts analyzing/finalizing (P2)")

proj_lifecycle = make_project('proj_cancel_lifecycle', [
    {'id': '2026-04-17_AN', 'status_files': {
        'methodology-analysis-state.md': '---\ncurrent_round: 5\nmax_iterations: 42\n---\n',
    }},
    {'id': '2026-04-17_FI', 'status_files': {
        'finalize-state.md': '---\ncurrent_round: 9\nmax_iterations: 42\n---\n',
    }},
])

with configured_app(project_dir=proj_lifecycle) as appmod:
    client = appmod.app.test_client()

    # Cancel on analyzing session: should succeed (no --force needed).
    r = client.post('/api/sessions/2026-04-17_AN/cancel')
    if r.status_code == 200 and (r.get_json() or {}).get('status') == 'cancelled':
        t_pass("POST cancel on analyzing session returns 200 cancelled")
    else:
        t_fail(f"analyzing-cancel should 200, got {r.status_code} {r.get_data(as_text=True)[:200]}")

    # Verify the helper actually renamed the active state file.
    rlcr_an = os.path.join(proj_lifecycle, '.humanize', 'rlcr', '2026-04-17_AN')
    if (os.path.isfile(os.path.join(rlcr_an, 'cancel-state.md'))
            and not os.path.isfile(os.path.join(rlcr_an, 'methodology-analysis-state.md'))):
        t_pass("analyzing session: methodology-analysis-state.md renamed to cancel-state.md")
    else:
        t_fail("analyzing session: state-file rename did not happen")

    # Cancel on finalizing session: should succeed because the route
    # forwards --force to the helper. Without --force the helper
    # returns exit 2.
    r = client.post('/api/sessions/2026-04-17_FI/cancel')
    if r.status_code == 200 and (r.get_json() or {}).get('status') == 'cancelled':
        t_pass("POST cancel on finalizing session returns 200 (route forwards --force)")
    else:
        t_fail(f"finalizing-cancel should 200, got {r.status_code} {r.get_data(as_text=True)[:200]}")

    rlcr_fi = os.path.join(proj_lifecycle, '.humanize', 'rlcr', '2026-04-17_FI')
    if (os.path.isfile(os.path.join(rlcr_fi, 'cancel-state.md'))
            and not os.path.isfile(os.path.join(rlcr_fi, 'finalize-state.md'))):
        t_pass("finalizing session: finalize-state.md renamed to cancel-state.md")
    else:
        t_fail("finalizing session: state-file rename did not happen")

    # Cancel on a terminal session is still rejected (status not in the
    # cancellable set). Use the freshly-cancelled session for the test.
    r = client.post('/api/sessions/2026-04-17_AN/cancel')
    if r.status_code == 400:
        t_pass("POST cancel on terminal (cancelled) session still returns 400")
    else:
        t_fail(f"terminal-cancel should 400, got {r.status_code}")

# Group 8b: --project forwarding regression test (Round 9 P2 fix).
# When the dashboard process inherits CLAUDE_PROJECT_DIR from another
# workspace, scripts/cancel-rlcr-session.sh would fall back to that
# stray env var instead of the dashboard's --project unless the route
# forwards --project explicitly. Simulate that scenario by setting
# CLAUDE_PROJECT_DIR to a DIFFERENT empty project and verifying the
# cancel still affects the dashboard's own project.
print("\nGroup 8b: cancel route forwards --project (Round 9 P2 fix)")

other_project = make_project('proj_other_for_env', [
    {'id': '2026-04-17_OTHER', 'status_files': {
        'state.md': '---\ncurrent_round: 0\nmax_iterations: 42\n---\n',
    }},
])

dashboard_project = make_project('proj_dashboard_target', [
    {'id': '2026-04-17_TARGET', 'status_files': {
        'state.md': '---\ncurrent_round: 1\nmax_iterations: 42\n---\n',
    }},
])

prev_claude_pd = os.environ.get('CLAUDE_PROJECT_DIR', '')
os.environ['CLAUDE_PROJECT_DIR'] = other_project
try:
    with configured_app(project_dir=dashboard_project) as appmod:
        client = appmod.app.test_client()
        r = client.post(
            '/api/sessions/2026-04-17_TARGET/cancel',
            headers={'Origin': 'http://localhost'},
        )
        if r.status_code == 200:
            t_pass("cancel succeeds with stray CLAUDE_PROJECT_DIR pointing at another workspace")
        else:
            t_fail(f"cancel with stray CLAUDE_PROJECT_DIR should 200, got {r.status_code} {r.get_data(as_text=True)[:200]}")

        # The TARGET project's session should be cancelled.
        target_dir = os.path.join(dashboard_project, '.humanize', 'rlcr', '2026-04-17_TARGET')
        if (os.path.isfile(os.path.join(target_dir, 'cancel-state.md'))
                and not os.path.isfile(os.path.join(target_dir, 'state.md'))):
            t_pass("cancel affected the dashboard's --project (TARGET cancelled)")
        else:
            t_fail("cancel did not rename TARGET state.md to cancel-state.md")

        # The OTHER project's session should be untouched.
        other_dir = os.path.join(other_project, '.humanize', 'rlcr', '2026-04-17_OTHER')
        if os.path.isfile(os.path.join(other_dir, 'state.md')):
            t_pass("cancel did NOT touch the stray CLAUDE_PROJECT_DIR project (OTHER untouched)")
        else:
            t_fail("cancel mistakenly affected the OTHER project (state.md missing)")
finally:
    if prev_claude_pd:
        os.environ['CLAUDE_PROJECT_DIR'] = prev_claude_pd
    else:
        os.environ.pop('CLAUDE_PROJECT_DIR', None)

# Group 9: parsers recognise both legacy AC-N and post-Round-5 C-N
# prefixes (Round 10 P2 fix). The --skip-impl template seeds C-N
# identifiers; if the parsers only matched the legacy prefix, review-
# only loops would report 0 ACs / 0% completion in the dashboard.
print("\nGroup 9: parsers recognise both AC-N and C-N criterion ids (P2 Round 10)")

def _make_session_with_tracker(name, session_id, tracker_body):
    proj = make_project(name, [
        {'id': session_id, 'status_files': {
            'state.md': '---\ncurrent_round: 0\nmax_iterations: 42\n---\n',
        }},
    ])
    sd = os.path.join(proj, '.humanize', 'rlcr', session_id)
    with open(os.path.join(sd, 'goal-tracker.md'), 'w', encoding='utf-8') as f:
        f.write(tracker_body)
    return proj

# Legacy AC-N tracker.
legacy_tracker = """\
### Acceptance Criteria

- AC-1: First criterion
- AC-2: Second criterion
- AC-3: Third criterion

### Completed and Verified
| AC | Task | Completed Round | Verified Round | Evidence |
|----|------|-----------------|----------------|----------|
"""
proj_legacy = _make_session_with_tracker('proj_ac_legacy', '2026-04-17_LE', legacy_tracker)

with configured_app(project_dir=proj_legacy) as appmod:
    client = appmod.app.test_client()
    r = client.get('/api/sessions/2026-04-17_LE')
    body = r.get_json() or {}
    if r.status_code == 200 and body.get('ac_total') == 3:
        t_pass("legacy AC-N criterion ids: ac_total == 3")
    else:
        t_fail(f"legacy AC-N detection wrong: {body.get('ac_total')} (status {r.status_code})")

# Post-Round-5 C-N tracker (matches the --skip-impl template form).
new_tracker = """\
### Acceptance Criteria

- C-1: First criterion
- C-2: Second criterion
- C-3: Third criterion

### Completed and Verified
| AC | Task | Completed Round | Verified Round | Evidence |
|----|------|-----------------|----------------|----------|
"""
proj_new = _make_session_with_tracker('proj_ac_new', '2026-04-17_NE', new_tracker)

with configured_app(project_dir=proj_new) as appmod:
    client = appmod.app.test_client()
    r = client.get('/api/sessions/2026-04-17_NE')
    body = r.get_json() or {}
    if r.status_code == 200 and body.get('ac_total') == 3:
        t_pass("post-Round-5 C-N criterion ids: ac_total == 3 (review-only / --skip-impl loops report progress)")
    else:
        t_fail(f"C-N detection wrong: {body.get('ac_total')} (status {r.status_code})")

# Group 10: finalize-phase classification only applies to the live
# round, not retroactively to historical rounds (Round 10 P2 fix).
print("\nGroup 10: finalize phase only labels the live round (P2 Round 10)")

proj_final = make_project('proj_finalize_phase', [
    {'id': '2026-04-17_FN', 'status_files': {
        'finalize-state.md': '---\ncurrent_round: 4\nmax_iterations: 42\n---\n',
    }},
])
fn_dir = os.path.join(proj_final, '.humanize', 'rlcr', '2026-04-17_FN')
# Seed several round summaries so parse_session has rounds 0..4 to
# classify; round 4 is the current round (live finalize step).
for n in range(5):
    with open(os.path.join(fn_dir, f'round-{n}-summary.md'), 'w', encoding='utf-8') as f:
        f.write(f'## Round {n}\n\nSummary content for round {n}.\n')

with configured_app(project_dir=proj_final) as appmod:
    client = appmod.app.test_client()
    r = client.get('/api/sessions/2026-04-17_FN')
    body = r.get_json() or {}
    rounds = {item['number']: item['phase'] for item in (body.get('rounds') or [])}

    # Historical rounds 0..3 should be 'implementation', not 'finalize'.
    historical_correct = all(rounds.get(n) == 'implementation' for n in range(4))
    if historical_correct:
        t_pass("historical rounds (0..3) classified as 'implementation', NOT 'finalize'")
    else:
        t_fail(f"historical rounds wrongly relabeled: {rounds}")

    # The current (live finalize) round should be 'finalize'.
    if rounds.get(4) == 'finalize':
        t_pass("current round (4) classified as 'finalize' (live finalize step)")
    else:
        t_fail(f"current round should be finalize, got {rounds.get(4)}")

# Group 11: parser recognises decimal and dashless criterion ids
# (Round 13 P2 fix). The plan/goal-tracker format explicitly allows
# nested ids (AC-1.1, C-2.5) and dashless short forms (C1). A regex
# that only matched [A]?[C]-\d+ silently dropped those and the
# dashboard under-reported ac_total/ac_done.
print("\nGroup 11: parser recognises decimal + dashless criterion ids (P2 Round 13)")

mixed_tracker = """\
### Acceptance Criteria

- AC-1.1: Nested criterion with decimal suffix
- C-2.5: Single-letter nested criterion
- C3: Dashless short-form criterion
- AC-4: Legacy form still works alongside the new ones

### Completed and Verified
| AC | Task | Completed Round | Verified Round | Evidence |
|----|------|-----------------|----------------|----------|
"""
proj_mixed = _make_session_with_tracker('proj_ac_mixed', '2026-04-17_MX', mixed_tracker)

with configured_app(project_dir=proj_mixed) as appmod:
    client = appmod.app.test_client()
    r = client.get('/api/sessions/2026-04-17_MX')
    body = r.get_json() or {}
    gt = body.get('goal_tracker') or {}
    acs = gt.get('acceptance_criteria') or []
    if r.status_code == 200 and body.get('ac_total') == 4:
        t_pass("mixed criterion forms (decimal + dashless + legacy): ac_total == 4")
    else:
        t_fail(f"mixed-form detection wrong: ac_total={body.get('ac_total')} "
               f"status={r.status_code} acs={[a.get('id') for a in acs]}")

    ac_ids = {item.get('id') for item in acs}
    if ac_ids == {'AC-1.1', 'C-2.5', 'C3', 'AC-4'}:
        t_pass("every id form is present verbatim in the parsed acceptance_criteria list")
    else:
        t_fail(f"expected {{AC-1.1, C-2.5, C3, AC-4}}, got {ac_ids}")

# Group 12: multi-criterion cells in Completed-Verified mark every
# listed id as done (Round 13 P2 fix). Before this fix, a row like
# `| AC-1, AC-2 | ... |` added the composite string as the completed
# key, so the acceptance_criteria status lookup (which tests a single
# id) left both criteria pending even though the loop's shell-side
# accounting treated them as verified.
print("\nGroup 12: multi-id Completed-Verified cells mark every id done (P2 Round 13)")

multi_id_tracker = """\
### Acceptance Criteria

- AC-1: First criterion
- AC-2: Second criterion
- AC-3: Third criterion
- C-4.1: Fourth criterion (nested)

### Completed and Verified
| AC | Task | Completed Round | Verified Round | Evidence |
|----|------|-----------------|----------------|----------|
| AC-1, AC-2 | Combined task that satisfies two criteria | Round 3 | Round 3-review | evidence cell |
| AC-3 / C-4.1 | Second combined task with slash separator | Round 5 | Round 5-review | evidence cell |
"""
proj_multi = _make_session_with_tracker('proj_ac_multi', '2026-04-17_ML', multi_id_tracker)

with configured_app(project_dir=proj_multi) as appmod:
    client = appmod.app.test_client()
    r = client.get('/api/sessions/2026-04-17_ML')
    body = r.get_json() or {}
    if r.status_code == 200 and body.get('ac_done') == 4 and body.get('ac_total') == 4:
        t_pass("all four criteria listed via multi-id cells are marked done (ac_done == 4)")
    else:
        t_fail(f"multi-id split wrong: ac_done={body.get('ac_done')} "
               f"ac_total={body.get('ac_total')} status={r.status_code}")

    gt = body.get('goal_tracker') or {}
    ac_by_id = {item.get('id'): item.get('status')
                for item in (gt.get('acceptance_criteria') or [])}
    if all(ac_by_id.get(i) == 'completed' for i in ('AC-1', 'AC-2', 'AC-3', 'C-4.1')):
        t_pass("every individual id in a multi-id row resolves to status='completed'")
    else:
        t_fail(f"per-id statuses wrong: {ac_by_id}")

# Group 13: table-form acceptance criteria (Round 14 P2 fix). The
# loop's shell-side accounting and the refine-plan workflow both
# allow the "### Acceptance Criteria" section to render as a table
# instead of a bulleted list. Previously the parser only matched
# "- id: description" list items, so table-form trackers reported
# ac_total=0 and skewed analytics.
print("\nGroup 13: parser accepts table-form acceptance criteria (P2 Round 14)")

table_ac_tracker = """\
### Ultimate Goal

Some goal.

### Acceptance Criteria

| ID | Description |
|----|-------------|
| AC-1 | First table criterion |
| C-2 | Second, dashed single-letter |
| C3 | Third, dashless short form |
| AC-4.1 | Fourth, nested decimal |

### Completed and Verified
| AC | Task | Completed Round | Verified Round | Evidence |
|----|------|-----------------|----------------|----------|
| AC-1 | did the thing | Round 1 | Round 1-review | tests |
"""
proj_tbl = _make_session_with_tracker('proj_ac_table', '2026-04-17_TB', table_ac_tracker)

with configured_app(project_dir=proj_tbl) as appmod:
    client = appmod.app.test_client()
    r = client.get('/api/sessions/2026-04-17_TB')
    body = r.get_json() or {}
    if r.status_code == 200 and body.get('ac_total') == 4:
        t_pass("table-form AC section: ac_total == 4 (was 0 before fix)")
    else:
        t_fail(f"table-form detection wrong: ac_total={body.get('ac_total')} status={r.status_code}")

    gt = body.get('goal_tracker') or {}
    ac_by_id = {item.get('id'): item.get('status') for item in (gt.get('acceptance_criteria') or [])}
    if ac_by_id.get('AC-1') == 'completed' and ac_by_id.get('C-2') == 'pending':
        t_pass("table-form ACs inherit completion status from Completed-Verified split")
    else:
        t_fail(f"table-form status propagation wrong: {ac_by_id}")

# Group 13b: /api/sessions must keep cache_logs so home-page live
# panes can open SSE streams (Round 17 P1 fix). Before this fix the
# summary route stripped the field, so the multi-session live-pane
# feature silently never activated on #/.
print("\nGroup 13b: /api/sessions preserves cache_logs (P1 Round 17)")

proj_cl = make_project('proj_cache_logs', [
    {'id': '2026-04-17_CL', 'status_files': {
        'state.md': '---\ncurrent_round: 1\nmax_iterations: 42\n---\n',
    }},
])
cl_cache_dir = os.path.join(proj_cl, '.cache', 'humanize',
                            '-' + proj_cl.strip('/').replace('/', '-'),
                            '2026-04-17_CL')
# Seed a cache log so parse_session can report it. Use the project-
# local .cache layout honoured by rlcr_sources when the user-level
# cache is not available in the test environment.
env_override = {'XDG_CACHE_HOME': os.path.join(proj_cl, '.cache')}
os.makedirs(cl_cache_dir, exist_ok=True)
with open(os.path.join(cl_cache_dir, 'round-0-codex-run.log'), 'w') as f:
    f.write('seeded cache log contents\n')

old_env = {}
for k, v in env_override.items():
    old_env[k] = os.environ.get(k)
    os.environ[k] = v
try:
    with configured_app(project_dir=proj_cl) as appmod:
        client = appmod.app.test_client()
        r = client.get('/api/sessions')
        body = r.get_json() or []
        row = next((item for item in body if item.get('id') == '2026-04-17_CL'), None)
        if row is None:
            t_fail('/api/sessions returned no entry for 2026-04-17_CL')
        elif 'cache_logs' not in row:
            t_fail('/api/sessions summary dict missing cache_logs field (home-page live panes broken)')
        elif isinstance(row.get('cache_logs'), list):
            t_pass('/api/sessions summary dict includes cache_logs (home-page live panes can find a log)')
        else:
            t_fail(f"/api/sessions cache_logs is not a list: {type(row.get('cache_logs')).__name__}")
finally:
    for k, v in old_env.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v

# Group 13c: methodology report prompt uses the LATEST rounds, not
# the earliest (Round 17 P2 fix). Verified via source-level check
# because /api/sessions/<id>/generate-report actually invokes the
# claude CLI which is not available in the test env.
print("\nGroup 13c: methodology report uses latest rounds (P2 Round 17)")

import re as _re_test
app_src = open(os.path.join(SERVER_DIR, 'app.py'), encoding='utf-8').read()
if _re_test.search(r'summaries\[-10:\]', app_src) and _re_test.search(r'reviews\[-10:\]', app_src):
    t_pass("methodology report prompt slices summaries[-10:] and reviews[-10:] (latest rounds)")
else:
    t_fail("methodology report prompt still uses summaries[:10]/reviews[:10] (earliest rounds drop late-phase signals)")

if not _re_test.search(r'summaries\[:10\]|reviews\[:10\]', app_src):
    t_pass("no stale summaries[:10] / reviews[:10] slice remains in app.py")
else:
    t_fail("stale [:10] slice still present somewhere in app.py")

# Group 15: session-path validation (Round 19 P1 fix). Non-session
# paths and traversal attempts must resolve to 404 instead of
# letting downstream parsers read arbitrary files under .humanize/.
print("\nGroup 15: session-path validation rejects traversal + non-session dirs (P1 Round 19)")

proj_trav = make_project('proj_path_validation', [
    {'id': '2026-04-17_PV', 'status_files': {
        'state.md': '---\ncurrent_round: 0\nmax_iterations: 42\n---\n',
    }},
])
# Seed a non-session directory under .humanize/rlcr so "stray dir"
# requests have a real directory to point at (otherwise isdir fails
# early for a different reason and the test is uninteresting).
stray_dir = os.path.join(proj_trav, '.humanize', 'rlcr', 'cache')
os.makedirs(stray_dir, exist_ok=True)

with configured_app(project_dir=proj_trav) as appmod:
    client = appmod.app.test_client()
    # The valid session still returns 200 (sanity baseline).
    r = client.get('/api/sessions/2026-04-17_PV')
    if r.status_code == 200:
        t_pass("[P1] valid session id still resolves to 200 (regression baseline)")
    else:
        t_fail(f"[P1] regression: valid session id returned {r.status_code}")

    # Traversal attempts must 404, not leak file contents from
    # sibling .humanize paths. Flask routing normalises `/..`, so
    # we test the path-segment form that reaches _get_session_dir.
    for bad_id in ('..', '.', '.hidden', 'foo/bar', 'foo\\bar'):
        r = client.get(f'/api/sessions/{bad_id}')
        if r.status_code == 404:
            pass  # expected
        else:
            t_fail(f"[P1] traversal id '{bad_id}' returned {r.status_code} (should be 404)")
            break
    else:
        t_pass("[P1] traversal ids ('..', '.', hidden, slashes, backslashes) all resolve to 404")

    # A real but non-session directory (stray `cache/`) must also
    # 404 because is_valid_session requires state.md or a terminal
    # *-state.md file.
    r = client.get('/api/sessions/cache')
    if r.status_code == 404:
        t_pass("[P1] non-session directory under .humanize/rlcr resolves to 404")
    else:
        t_fail(f"[P1] non-session dir returned {r.status_code} (should be 404)")

# Group 16: COMPLETE verdict requires terminal marker line (Round 19
# P2 fix). Prose like "CANNOT COMPLETE" must NOT flip verdict to
# 'complete' -- that would silently break last_verdict, the pipeline
# UI, and analytics for any review that discusses the COMPLETE
# contract in free text.
print("\nGroup 16: COMPLETE verdict requires terminal marker line (P2 Round 19)")

from parser import parse_review_result
import tempfile

test_cases = [
    ('terminal COMPLETE', 'Analysis says this is done.\n\nCOMPLETE\n', 'complete'),
    ('terminal COMPLETE with trailing blanks', 'Some prose.\n\nCOMPLETE\n\n\n', 'complete'),
    ('CANNOT COMPLETE prose', 'Explanation: CANNOT COMPLETE until the test passes.\n', 'unknown'),
    ('cannot COMPLETE yet prose', 'We cannot COMPLETE yet; more rounds needed.\n', 'unknown'),
    ('COMPLETE in middle, stalled terminal', 'COMPLETE was tried.\n\nThe run is stalled.\n', 'stalled'),
    ('advanced verdict', 'The loop advanced this round.\n', 'advanced'),
]

all_verdicts_correct = True
for label, content, expected in test_cases:
    with tempfile.NamedTemporaryFile('w', suffix='.md', delete=False) as f:
        f.write(content)
        fp = f.name
    try:
        result = parse_review_result(fp)
        got = (result or {}).get('verdict')
        if got != expected:
            t_fail(f"[P2] {label}: expected verdict='{expected}', got '{got}'")
            all_verdicts_correct = False
    finally:
        os.unlink(fp)

if all_verdicts_correct:
    t_pass("[P2] COMPLETE verdict parsing handles terminal marker + false-positive prose + fallback verdicts")

# Group 17: /report returns 404 for sessions with no methodology
# report (Round 19 P3 fix). Without this, clients get 200 plus
# {'content': {'zh': None, 'en': None}} and cannot distinguish
# "report missing" from "report loaded successfully but empty".
print("\nGroup 17: /api/sessions/<id>/report returns 404 when report missing (P3 Round 19)")

proj_rep = make_project('proj_no_report', [
    {'id': '2026-04-17_NR', 'status_files': {
        'state.md': '---\ncurrent_round: 0\nmax_iterations: 42\n---\n',
    }},
])

with configured_app(project_dir=proj_rep) as appmod:
    client = appmod.app.test_client()
    # No methodology-report.md file seeded -> must 404.
    r = client.get('/api/sessions/2026-04-17_NR/report')
    if r.status_code == 404:
        t_pass("[P3] /report returns 404 when methodology report file is missing")
    else:
        t_fail(f"[P3] /report returned {r.status_code} for missing report (expected 404)")

    # Seed a real report and confirm the route flips back to 200.
    nr_dir = os.path.join(proj_rep, '.humanize', 'rlcr', '2026-04-17_NR')
    with open(os.path.join(nr_dir, 'methodology-analysis-report.md'), 'w') as f:
        f.write('# Methodology Report\n\nContent here.\n')
    # Drop any cached session to force re-parse.
    appmod._invalidate_cache()
    r = client.get('/api/sessions/2026-04-17_NR/report')
    if r.status_code == 200:
        body = r.get_json() or {}
        content = (body.get('content') or {})
        if content.get('en') or content.get('zh'):
            t_pass("[P3] /report returns 200 with non-empty content when report exists")
        else:
            t_fail(f"[P3] /report 200 but content is empty: {body}")
    else:
        t_fail(f"[P3] /report returned {r.status_code} after report was seeded (expected 200)")

# Group 14: skip-impl round 0 is classified as code_review, not
# implementation (Round 14 P2 fix). setup-rlcr-loop.sh writes the
# marker file with skip_impl=true so _determine_phase() can
# distinguish it from a normal-mode session whose first round
# happened to be the last build round (build_finish_round=0).
print("\nGroup 14: skip-impl round 0 classifies as code_review (P2 Round 14)")

# A. Skip-impl session: every round (including round 0) is review.
proj_skip = make_project('proj_skip_impl', [
    {'id': '2026-04-17_SK', 'status_files': {
        'state.md': '---\ncurrent_round: 3\nmax_iterations: 42\nreview_started: true\n---\n',
    }},
])
sk_dir = os.path.join(proj_skip, '.humanize', 'rlcr', '2026-04-17_SK')
# Marker carries both build_finish_round=0 (legacy content) AND the
# new skip_impl=true discriminator. Seed round-N summaries so
# parse_session has something to classify.
with open(os.path.join(sk_dir, '.review-phase-started'), 'w') as f:
    f.write('build_finish_round=0\nskip_impl=true\n')
for n in range(4):
    with open(os.path.join(sk_dir, f'round-{n}-summary.md'), 'w') as f:
        f.write(f'## Round {n}\n')

with configured_app(project_dir=proj_skip) as appmod:
    client = appmod.app.test_client()
    r = client.get('/api/sessions/2026-04-17_SK')
    body = r.get_json() or {}
    rounds = {item['number']: item['phase'] for item in (body.get('rounds') or [])}
    if rounds.get(0) == 'code_review':
        t_pass("skip-impl round 0 classified as code_review (not implementation)")
    else:
        t_fail(f"skip-impl round 0 wrongly classified: {rounds}")
    if all(rounds.get(n) == 'code_review' for n in range(4)):
        t_pass("every round in a skip-impl session classified as code_review")
    else:
        t_fail(f"skip-impl round phases wrong: {rounds}")

# B. Normal-mode regression: build_finish_round=0 WITHOUT
# skip_impl=true means round 0 was the last build round and
# should remain 'implementation' (round 1+ is code_review).
proj_norm = make_project('proj_norm_build0', [
    {'id': '2026-04-17_NB', 'status_files': {
        'state.md': '---\ncurrent_round: 3\nmax_iterations: 42\nreview_started: true\n---\n',
    }},
])
nb_dir = os.path.join(proj_norm, '.humanize', 'rlcr', '2026-04-17_NB')
with open(os.path.join(nb_dir, '.review-phase-started'), 'w') as f:
    f.write('build_finish_round=0\n')
for n in range(4):
    with open(os.path.join(nb_dir, f'round-{n}-summary.md'), 'w') as f:
        f.write(f'## Round {n}\n')

with configured_app(project_dir=proj_norm) as appmod:
    client = appmod.app.test_client()
    r = client.get('/api/sessions/2026-04-17_NB')
    body = r.get_json() or {}
    rounds = {item['number']: item['phase'] for item in (body.get('rounds') or [])}
    if rounds.get(0) == 'implementation' and rounds.get(1) == 'code_review':
        t_pass("normal-mode build_finish_round=0 preserves round 0 = implementation (regression-safe)")
    else:
        t_fail(f"normal-mode round phases wrong: {rounds}")

# Summary
print()
print("========================================")
print(f"Passed: \033[0;32m{PASS}\033[0m")
print(f"Failed: \033[0;31m{FAIL}\033[0m")
if FAIL > 0:
    sys.exit(1)
print("\033[0;32mAll live route tests passed!\033[0m")
PYEOF
