#!/usr/bin/env bash
#
# Round 5 frontend pass tests:
#   - T10-frontend: project switcher and `+ Add` chrome are removed
#     from viz/static/js/app.js and viz/static/js/actions.js
#   - T11-frontend: token propagation is wired in api(), authedFetch,
#     and the EventSource mounting helper
#   - T6: home page mounts inline live-log panes via EventSource for
#     each active session
#
# These tests are pattern-based (no headless browser required).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_JS="$PLUGIN_ROOT/viz/static/js/app.js"
ACTIONS_JS="$PLUGIN_ROOT/viz/static/js/actions.js"

echo "========================================"
echo "Round 5 frontend pass (T6 + T10-frontend + T11-frontend)"
echo "========================================"

PASS_COUNT=0
FAIL_COUNT=0

_pass() { printf '\033[0;32mPASS\033[0m: %s\n' "$1"; PASS_COUNT=$((PASS_COUNT+1)); }
_fail() { printf '\033[0;31mFAIL\033[0m: %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT+1)); }

# ─── T10-frontend: project switcher chrome removed ───
echo
echo "Group 1: project switcher chrome removed (T10-frontend)"

if grep -q 'function switchProject' "$ACTIONS_JS"; then
    _fail "actions.js still defines switchProject"
else
    _pass "actions.js no longer defines switchProject"
fi

if grep -q 'function addProjectPrompt' "$ACTIONS_JS" || grep -q 'function addProject' "$ACTIONS_JS"; then
    _fail "actions.js still defines addProjectPrompt/addProject"
else
    _pass "actions.js no longer defines addProjectPrompt/addProject"
fi

if grep -qE "fetch\(\s*'/api/projects/(switch|add|remove)'" "$ACTIONS_JS"; then
    _fail "actions.js still calls /api/projects/{switch,add,remove}"
else
    _pass "actions.js no longer calls /api/projects/{switch,add,remove}"
fi

if grep -q 'switchProject(' "$APP_JS"; then
    _fail "app.js still references switchProject()"
else
    _pass "app.js no longer references switchProject()"
fi

if grep -q 'addProjectPrompt(' "$APP_JS"; then
    _fail "app.js still references addProjectPrompt()"
else
    _pass "app.js no longer references addProjectPrompt()"
fi

if grep -qE 'class="dropdown-menu"' "$APP_JS" && grep -q 'projectSwitcher' "$APP_JS"; then
    _fail "app.js still renders projectSwitcher block"
else
    _pass "app.js no longer renders projectSwitcher block"
fi

# ─── T11-frontend: token propagation ───
echo
echo "Group 2: token propagation (T11-frontend)"

if grep -q '_resolveAuthToken' "$APP_JS" && grep -q 'sessionStorage.*humanize-viz-token' "$APP_JS"; then
    _pass "app.js resolves auth token from URL/sessionStorage/meta"
else
    _fail "auth token resolver missing"
fi

if grep -qE "headers.*Authorization.*Bearer" "$APP_JS"; then
    _pass "api() helper attaches Authorization: Bearer header when token present"
else
    _fail "api() does not attach Authorization header"
fi

if grep -q 'window.authedFetch' "$APP_JS"; then
    _pass "app.js exports authedFetch wrapper for actions.js"
else
    _fail "authedFetch wrapper missing"
fi

if grep -q 'await window.authedFetch' "$ACTIONS_JS"; then
    _pass "actions.js uses authedFetch for token propagation"
else
    _fail "actions.js still uses raw fetch (token not propagated)"
fi

if grep -q '_withToken' "$APP_JS" && grep -q "token=\${encodeURIComponent" "$APP_JS"; then
    _pass "_withToken appends ?token= for SSE/EventSource per DEC-4"
else
    _fail "_withToken helper or ?token= query injection missing"
fi

# ─── T6: inline live-log panes on the home page ───
echo
echo "Group 3: home-page inline live-log panes (T6)"

if grep -q 'new EventSource' "$APP_JS"; then
    _pass "app.js creates EventSource for live log streaming"
else
    _fail "app.js has no EventSource client"
fi

if grep -qE "/api/sessions/.*\\\$\\{.*\\}/logs/" "$APP_JS"; then
    _pass "EventSource URL targets the per-session log endpoint"
else
    _fail "EventSource URL does not match the streaming protocol contract"
fi

for evt in snapshot append resync eof; do
    if grep -qE "addEventListener\('$evt'" "$APP_JS"; then
        _pass "app.js handles SSE event: $evt"
    else
        _fail "app.js does not handle SSE event: $evt"
    fi
done

if grep -q '_mountLiveLogPane' "$APP_JS" && grep -q '_teardownAllLivePanes' "$APP_JS"; then
    _pass "app.js mounts and tears down per-session live panes"
else
    _fail "live-pane mount/teardown helpers missing"
fi

# Home split into Active vs Completed sections uses the Claude-
# design kit's .session-grid container (auto-fit grid) tagged with
# data-home-section for the WS-driven diff updater. The old
# .active-sessions-list / .active-session-block + inline live-log
# scheme was removed when the log moved to the session-detail page.
if grep -q 'session-grid' "$APP_JS" && grep -q 'data-home-section="active"' "$APP_JS"; then
    _pass "renderHome uses the new session-grid layout"
else
    _fail "renderHome does not use the new session-grid layout"
fi

if grep -q 'live-log-pane' "$PLUGIN_ROOT/viz/static/css/layout.css" && \
   grep -q 'session-grid' "$PLUGIN_ROOT/viz/static/css/layout.css"; then
    _pass "layout.css includes styles for live log panes and session grid"
else
    _fail "layout.css missing live-log-pane / session-grid styles"
fi

# ─── T6 lifecycle fixes (Round 6) ───
echo
echo "Group 4: T6 lifecycle hardening (Round 6)"

# Teardown happens before EVERY non-home render, not just renderHome().
if grep -qE "_teardownAllLivePanes\(\)" "$APP_JS" && \
   grep -qE "if \(route\.page !== 'home'\)" "$APP_JS"; then
    _pass "non-home route changes call _teardownAllLivePanes()"
else
    _fail "non-home renders do not tear down live panes"
fi

# WebSocket is skipped in remote mode.
if grep -qE "_isRemoteMode" "$APP_JS" && \
   grep -qE "if \(_isRemoteMode\)" "$APP_JS"; then
    _pass "WebSocket connect is skipped in remote mode (DEC-4 + remote WS rejection)"
else
    _fail "WebSocket still connects unconditionally in remote mode"
fi

# Home refresh is WS-driven and debounced: _scheduleHomeRefresh()
# coalesces bursts into one _refreshHomeCards() call that diff-
# updates the sessions list without a full page rebuild. Polling
# was removed in favor of this targeted path — a setInterval in the
# home route would re-introduce the "frantic refresh" bug.
if grep -q '_scheduleHomeRefresh' "$APP_JS" && grep -q '_refreshHomeCards' "$APP_JS"; then
    _pass "home-route WS-driven targeted refresh is wired (covers WAITING -> live and EOF transitions)"
else
    _fail "home targeted refresh helpers missing"
fi

# eof closes the SSE cleanly without forcing a page rebuild; the
# session-detail Active -> Historical transition lands via the next
# WS round_added / session_finished event (server-side cache-dir
# watcher broadcasts when the state file is renamed).
if grep -qE "addEventListener\('eof'" "$APP_JS" && \
   grep -qE "_liveLogPanes\.delete" "$APP_JS"; then
    _pass "eof handler closes the pane cleanly without forcing a page rebuild"
else
    _fail "eof handler missing or does not deregister the live pane"
fi

# ─── Round 11 frontend fixes ───
echo
echo "Group 5: Round 11 P2 frontend fixes"

# Cancel button visibility now matches backend _CANCELLABLE_STATUSES.
if grep -qE "CANCELLABLE_STATUSES.*=.*\['active'.*'analyzing'.*'finalizing'\]" "$APP_JS" && \
   grep -qE "CANCELLABLE_STATUSES\.includes\(session\.status\)" "$APP_JS"; then
    _pass "cancel button visibility checks {active, analyzing, finalizing} (matches backend P2 fix)"
else
    _fail "cancel button still hidden in analyzing/finalizing phases"
fi

# Live log pane decodes UTF-8 properly (no mojibake on CJK/emoji).
if grep -qE "TextDecoder\(['\"]utf-8['\"]" "$APP_JS"; then
    _pass "live log pane decodes byte stream as UTF-8 (no mojibake on non-ASCII output)"
else
    _fail "live log pane still feeds atob() output directly into textContent (UTF-8 broken)"
fi

if grep -qE "Uint8Array\(.*\.length\)" "$APP_JS" && grep -q 'charCodeAt' "$APP_JS"; then
    _pass "live log pane converts Latin-1 binstring to Uint8Array before decoding"
else
    _fail "live log pane missing the binstring -> Uint8Array conversion"
fi

# ─── Group 6: Round 16 P2 fix — pipeline drag listener singleton ───
echo
echo "Group 6: pipeline.js window-level drag listeners installed once (P2 Round 16)"

PIPELINE_JS="$PLUGIN_ROOT/viz/static/js/pipeline.js"

# The window-level mousemove/mouseup pair must be guarded so re-
# rendering the pipeline on every SSE update does not accumulate
# duplicate handlers. A singleton guard flag + helper is the
# idiomatic form.
if grep -qE '_dragListenersInstalled\s*=\s*false' "$PIPELINE_JS" && \
   grep -qE 'function _ensureDragListeners' "$PIPELINE_JS"; then
    _pass "pipeline.js defines _dragListenersInstalled guard + _ensureDragListeners helper"
else
    _fail "pipeline.js missing singleton guard for window-level drag listeners"
fi

# renderPipeline must NOT call window.addEventListener directly
# (that was the duplication vector). It must route through the
# singleton helper.
render_body=$(awk '/^function renderPipeline/,/^}$/' "$PIPELINE_JS")
if grep -q 'window.addEventListener' <<<"$render_body"; then
    _fail "renderPipeline still calls window.addEventListener directly (duplication vector)"
else
    _pass "renderPipeline no longer calls window.addEventListener directly"
fi

if grep -q '_ensureDragListeners()' <<<"$render_body"; then
    _pass "renderPipeline routes window listeners through _ensureDragListeners()"
else
    _fail "renderPipeline does not call _ensureDragListeners()"
fi

# The guard must flip to true after the one-time install so the
# next call short-circuits.
if grep -qE '_dragListenersInstalled\s*=\s*true' "$PIPELINE_JS"; then
    _pass "_ensureDragListeners sets the guard to true after install (one-shot)"
else
    _fail "_ensureDragListeners never flips the guard (would re-install every call)"
fi

# ─── Group 7: WS-driven targeted session refresh ───
echo
echo "Group 7: session-detail targeted refresh + race guard"

# Session-scoped WS events schedule a debounced refresh that
# re-populates only the pipeline / sidebar / goal-bar subtrees.
# Polling was removed in favor of this path; a setInterval would
# reset the user's zoom / pan and restart the EventSource.
if grep -qE '_scheduleSessionPartialRefresh' "$APP_JS" && \
   grep -qE 'async function _refreshSessionPartial' "$APP_JS"; then
    _pass "app.js defines _scheduleSessionPartialRefresh + _refreshSessionPartial helpers"
else
    _fail "session-route targeted refresh helpers missing"
fi

# Race guard: after the /api/sessions/<id> fetch resolves we must
# re-check the active route and the layout skeleton's data-session-id
# before mutating DOM. Otherwise a user who navigated away between
# the request and the response would see stale data flash into the
# new page.
if grep -qE "route\.page !== 'session'" "$APP_JS" && \
   grep -qE 'data-session-id="\$\{CSS\.escape\(sessionId\)\}"' "$APP_JS"; then
    _pass "_refreshSessionPartial guards against route-change race after await"
else
    _fail "_refreshSessionPartial does not re-check route + skeleton after await"
fi

# Remote mode cannot reach the localhost-only WS, so a slow
# (~10s) polling fallback re-uses the same targeted-refresh path.
# It must gate on _isRemoteMode so localhost deployments stay WS-
# only.
if grep -qE 'function _startRemotePolling' "$APP_JS" && \
   grep -qE '_isRemoteMode' "$APP_JS"; then
    _pass "remote-mode slow polling fallback is wired via _startRemotePolling"
else
    _fail "remote-mode polling fallback missing"
fi

# Detail-page live-log pane mounts only on the session-detail
# route and is driven by the per-session SSE stream. The helper
# must be idempotent so WS-driven refreshes do not tear down the
# pane on every event.
if grep -qE 'function _ensureSessionLogPane' "$APP_JS" && \
   grep -qE 'session-log-container' "$APP_JS"; then
    _pass "_ensureSessionLogPane preserves the live-log SSE across WS refreshes"
else
    _fail "session-detail live-log helper _ensureSessionLogPane missing"
fi

echo
echo "========================================"
printf 'Passed: \033[0;32m%d\033[0m\n' "$PASS_COUNT"
printf 'Failed: \033[0;31m%d\033[0m\n' "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi

printf '\033[0;32mAll frontend migration tests passed!\033[0m\n'
