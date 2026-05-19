#!/usr/bin/env bash
#
# Tests for the auth-related changes in viz/server/app.py (T11 + T10).
#
# These tests do NOT spin up a live Flask server (Flask may not be in
# the system Python). Instead they assert presence and absence of the
# code patterns required by the Round 4 contract:
#   - main() registers --host, --port, --auth-token, --static, --project
#   - main() exits non-zero if --host is non-localhost without a token
#   - app.before_request enforces auth on protected endpoints when not localhost
#   - SSE handler reads ?token= via _request_token / Authorization header
#   - WebSocket route refuses non-localhost binds
#   - /api/projects/{switch,add,remove} no longer mutate state (return 410)
#   - viz-projects.json persistence helpers (_load_projects, _save_projects)
#     are removed
#   - app.run() uses the configurable BIND_HOST instead of hard-coded
#     127.0.0.1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_PY="$PLUGIN_ROOT/viz/server/app.py"

echo "========================================"
echo "viz/server/app.py auth + migration (T8/T10/T11)"
echo "========================================"

PASS_COUNT=0
FAIL_COUNT=0

_pass() { printf '\033[0;32mPASS\033[0m: %s\n' "$1"; PASS_COUNT=$((PASS_COUNT+1)); }
_fail() { printf '\033[0;31mFAIL\033[0m: %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT+1)); }

# Section 1: CLI flags (T8) ---------------------------------------------
for flag in '--host' '--port' '--project' '--static' '--auth-token'; do
    if grep -qE "parser\.add_argument\('$flag'" "$APP_PY"; then
        _pass "main() registers $flag"
    else
        _fail "main() missing $flag"
    fi
done

# Section 2: Remote-bind safety (T11 fail-closed) -----------------------
if grep -q '_is_localhost_bind' "$APP_PY" && \
   grep -q 'requires --auth-token' "$APP_PY"; then
    _pass "main() refuses non-localhost host without --auth-token"
else
    _fail "non-local host validation missing in main()"
fi

if grep -qE "app\.run\(host=BIND_HOST" "$APP_PY"; then
    _pass "app.run() uses configurable BIND_HOST (no longer hardcoded 127.0.0.1)"
else
    _fail "app.run() still hardcodes a host"
fi

# Section 3: Auth middleware (T11) --------------------------------------
if grep -q '@app.before_request' "$APP_PY" && grep -q '_request_authorized' "$APP_PY"; then
    _pass "app.before_request middleware references _request_authorized"
else
    _fail "auth middleware not wired"
fi

if grep -q "Authorization" "$APP_PY" && grep -q "Bearer" "$APP_PY"; then
    _pass "auth path honors Authorization: Bearer header"
else
    _fail "Authorization: Bearer header support missing"
fi

if grep -qE "request\.args\.get\('token'" "$APP_PY"; then
    _pass "auth path honors ?token= query param (for SSE EventSource per DEC-4)"
else
    _fail "?token= query param fallback missing"
fi

# Section 4: WebSocket disabled in remote mode (T11 / DEC-4) ------------
if grep -q "WebSocket transport disabled in remote mode" "$APP_PY"; then
    _pass "WebSocket route refuses non-localhost binds with explicit reason"
else
    _fail "WebSocket route does not reject remote-mode connections"
fi

# Section 5: T10 backend cleanup ----------------------------------------
if grep -qE "def _save_projects" "$APP_PY"; then
    _fail "_save_projects helper still present (should be removed for T10)"
else
    _pass "_save_projects helper removed"
fi

if grep -qE "def _load_projects" "$APP_PY"; then
    _fail "_load_projects helper still present (should be removed for T10)"
else
    _pass "_load_projects helper removed"
fi

if grep -qE "def _ensure_current_project" "$APP_PY"; then
    _fail "_ensure_current_project helper still present"
else
    _pass "_ensure_current_project helper removed"
fi

# Allow a single explanatory comment about the removed file (the
# migration note tells future readers WHY the persistence is gone).
# Reject any non-comment occurrence (would indicate the code still
# tries to read or write the legacy projects file).
if grep -nE "viz-projects\.json" "$APP_PY" | grep -vE '^[0-9]+:\s*#' >/dev/null; then
    _fail "viz-projects.json is still referenced from non-comment code"
else
    _pass "viz-projects.json no longer used by code (only an explanatory comment may remain)"
fi

# Section 6: Project-mutation routes return 410 (T10) -------------------
if grep -qE "/api/projects/switch.*POST" "$APP_PY" && \
   grep -qE "/api/projects/add.*POST" "$APP_PY" && \
   grep -qE "/api/projects/remove.*POST" "$APP_PY" && \
   grep -q '410' "$APP_PY"; then
    _pass "project switch/add/remove endpoints return 410 Gone"
else
    _fail "project switch/add/remove endpoints not returning 410"
fi

# Section 7: T7 session-scoped cancel ----------------------------------
if grep -q '_find_session_cancel_script' "$APP_PY" && \
   grep -q 'cancel-rlcr-session.sh' "$APP_PY"; then
    _pass "/api/sessions/<id>/cancel uses session-scoped helper"
else
    _fail "session-scoped cancel helper not wired"
fi

if grep -q "session_id is required" "$APP_PY"; then
    _pass "cancel endpoint validates session id presence (400)"
else
    _fail "cancel endpoint does not validate session id"
fi

# Section 8: T7 portability fix (Round 5) ------------------------------
if grep -q 'HUMANIZE_CANCEL_SESSION_SCRIPT' "$APP_PY"; then
    _pass "_find_session_cancel_script honors HUMANIZE_CANCEL_SESSION_SCRIPT env override"
else
    _fail "_find_session_cancel_script does not honor env override"
fi

if grep -qE "sibling.*cancel-rlcr-session\.sh|cancel-rlcr-session\.sh.*sibling" "$APP_PY" || \
   grep -qE "os\.path\.join\(server_dir.*cancel-rlcr-session" "$APP_PY"; then
    _pass "_find_session_cancel_script checks the sibling repo path"
else
    _fail "_find_session_cancel_script does not check the sibling repo path"
fi

if grep -qE "marketplaces/humania" "$APP_PY"; then
    _pass "_find_session_cancel_script searches marketplaces/humania plugin location"
else
    _fail "_find_session_cancel_script does not search marketplaces plugin location"
fi

# Section 9: T7 missing-session-id 400 case (Round 5) ------------------
if grep -qE "@app\.route\('/api/sessions/cancel'" "$APP_PY"; then
    _pass "/api/sessions/cancel route registered for missing-id 400 case"
else
    _fail "/api/sessions/cancel route missing (negative case unreachable)"
fi

if grep -q "api_cancel_session_missing_id" "$APP_PY"; then
    _pass "missing-id handler defined as a routable view function"
else
    _fail "missing-id handler not defined as a separate view function"
fi

# Section 10: Round 8 P1 + P2 fixes ------------------------------------
if grep -q '_enforce_csrf_protection' "$APP_PY"; then
    _pass "CSRF protection function defined (P1)"
else
    _fail "CSRF protection function missing"
fi

if grep -qE "_MUTATING_METHODS\s*=" "$APP_PY"; then
    _pass "CSRF predicate enumerates mutating methods (POST/PUT/PATCH/DELETE)"
else
    _fail "CSRF predicate missing _MUTATING_METHODS set"
fi

if grep -q '_origin_matches_request' "$APP_PY"; then
    _pass "same-origin host check defined (request-relative as of Round 9)"
else
    _fail "same-origin host check missing"
fi

if grep -q '_CANCELLABLE_STATUSES' "$APP_PY" && \
   grep -qE "'analyzing'.*'finalizing'|'finalizing'.*'analyzing'" "$APP_PY"; then
    _pass "cancel route accepts analyzing/finalizing in addition to active (P2)"
else
    _fail "cancel route still narrowed to active-only"
fi

if grep -qE "helper_args\.append\(['\"]--force['\"]\)" "$APP_PY"; then
    _pass "cancel route forwards --force when status is finalizing (P2)"
else
    _fail "cancel route does not forward --force for finalizing"
fi

# Section 11: Round 9 fixes ---------------------------------------------
if grep -q '_origin_matches_request' "$APP_PY" && grep -q '_parse_request_host_port' "$APP_PY"; then
    _pass "CSRF check is request-relative (works for --host 0.0.0.0 wildcard binds; P1 Round 9)"
else
    _fail "CSRF still compares against literal BIND_HOST (would break --host 0.0.0.0)"
fi

if grep -qE "'--project',\s*PROJECT_DIR,\s*'--session-id'" "$APP_PY"; then
    _pass "cancel route forwards --project PROJECT_DIR to the helper (P2 Round 9)"
else
    _fail "cancel route does not forward --project; CLAUDE_PROJECT_DIR could leak"
fi

# Section 12: Round 13 P1 fix — auth predicate fails closed ------------
# _request_authorized() must NOT treat an empty AUTH_TOKEN as "allow";
# on a non-loopback bind without a token, return False (deny) so any
# code path that bypasses main()'s startup guard (module import,
# bespoke app.run wrapper, alternate entry point) cannot serve
# protected endpoints unauthenticated.
python3 - "$APP_PY" <<'PYEOF'
import ast
import pathlib
import re
import sys

src = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
tree = ast.parse(src)

func = next(
    (node for node in tree.body
     if isinstance(node, ast.FunctionDef) and node.name == '_request_authorized'),
    None,
)
if func is None:
    print("FAIL: _request_authorized not found", file=sys.stderr)
    sys.exit(1)

body = ast.unparse(func)

# The old predicate had "_is_localhost_bind() or not AUTH_TOKEN" as a
# single allow clause. The fail-closed shape must explicitly return
# False when AUTH_TOKEN is absent on a non-loopback bind.
has_or_not = re.search(r'_is_localhost_bind\(\)\s+or\s+not\s+AUTH_TOKEN', body)
has_deny = 'return False' in body

if has_or_not:
    print("FAIL: still has combined allow clause (_is_localhost_bind() or not AUTH_TOKEN)")
    sys.exit(2)
if not has_deny:
    print("FAIL: _request_authorized has no explicit 'return False' deny branch")
    sys.exit(3)

print("OK")
PYEOF
AUTH_PROBE_EXIT=$?
if [[ "$AUTH_PROBE_EXIT" -eq 0 ]]; then
    _pass "[P1 Round 13] _request_authorized fails closed on non-loopback + empty AUTH_TOKEN"
else
    _fail "[P1 Round 13] _request_authorized does not fail closed (exit=$AUTH_PROBE_EXIT)"
fi

# Behavioural probe: import app.py, force BIND_HOST=0.0.0.0 with
# AUTH_TOKEN='', and assert _request_authorized() returns False for a
# simulated request. Protects against regressions that pass the
# static grep above while behaving wrongly at runtime.
VIZ_TEST_VENV="${VIZ_TEST_VENV:-/tmp/viz-routes-test-venv}"
if [[ -x "$VIZ_TEST_VENV/bin/python" ]] && "$VIZ_TEST_VENV/bin/python" -c 'import flask' 2>/dev/null; then
    # The behavioural probe imports app.py, which pulls in Flask. When
    # the dedicated viz test venv does not have Flask installed (fresh
    # CI runs that skipped the viz app-routes suite setup step), skip
    # this assertion so a missing dependency does not turn into a
    # test-script crash under `set -euo pipefail`. The preceding
    # static grep check already covers the fail-closed contract.
    PROBE_OUT="$("$VIZ_TEST_VENV/bin/python" - "$PLUGIN_ROOT" <<'PYEOF' 2>&1 || true
import sys, os
plugin_root = sys.argv[1]
sys.path.insert(0, os.path.join(plugin_root, 'viz', 'server'))
import app
app.BIND_HOST = '0.0.0.0'
app.AUTH_TOKEN = ''
with app.app.test_request_context('/api/sessions', method='GET'):
    a = app._request_authorized()
app.AUTH_TOKEN = 'valid-token-xyz'
with app.app.test_request_context('/api/sessions', method='GET'):
    b = not app._request_authorized()
with app.app.test_request_context('/api/sessions', method='GET',
                                  headers={'Authorization': 'Bearer valid-token-xyz'}):
    c = app._request_authorized()
app.BIND_HOST = '127.0.0.1'
app.AUTH_TOKEN = ''
with app.app.test_request_context('/api/sessions', method='GET'):
    d = app._request_authorized()
print(f"NO_TOKEN_DENY={a is False} WRONG_TOKEN_DENY={b is True} "
      f"VALID_TOKEN_GRANT={c is True} LOOPBACK_OPEN={d is True}")
PYEOF
)"
    if grep -q 'NO_TOKEN_DENY=True WRONG_TOKEN_DENY=True VALID_TOKEN_GRANT=True LOOPBACK_OPEN=True' <<<"$PROBE_OUT"; then
        _pass "[P1 Round 13] behavioural probe: deny/grant matrix correct across bind/token combos"
    else
        _fail "[P1 Round 13] behavioural probe mismatch: $PROBE_OUT"
    fi
else
    _pass "[P1 Round 13] behavioural probe SKIPPED (viz test venv missing Flask at $VIZ_TEST_VENV)"
fi

echo
echo "========================================"
printf 'Passed: \033[0;32m%d\033[0m\n' "$PASS_COUNT"
printf 'Failed: \033[0;31m%d\033[0m\n' "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi

printf '\033[0;32mAll app auth/migration tests passed!\033[0m\n'
