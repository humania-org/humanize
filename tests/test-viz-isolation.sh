#!/usr/bin/env bash
#
# Tests for per-project tmux/port isolation in the viz dashboard
# launcher (T9, AC-8).
#
# Verifies:
#   - viz_tmux_session_name() returns a per-project name (different
#     project paths produce different tmux session names).
#   - viz-stop.sh and viz-status.sh derive the same name as
#     viz-start.sh so they target the right project.
#   - The legacy global session name "humanize-viz" no longer appears
#     hard-coded in viz-start.sh / viz-stop.sh / viz-status.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NAME_HELPER="$PLUGIN_ROOT/viz/scripts/viz-session-name.sh"
START_SH="$PLUGIN_ROOT/viz/scripts/viz-start.sh"
STOP_SH="$PLUGIN_ROOT/viz/scripts/viz-stop.sh"
STATUS_SH="$PLUGIN_ROOT/viz/scripts/viz-status.sh"

echo "========================================"
echo "Per-project viz isolation (T9 / AC-8)"
echo "========================================"

PASS_COUNT=0
FAIL_COUNT=0

_pass() { printf '\033[0;32mPASS\033[0m: %s\n' "$1"; PASS_COUNT=$((PASS_COUNT+1)); }
_fail() { printf '\033[0;31mFAIL\033[0m: %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT+1)); }

if [[ ! -f "$NAME_HELPER" ]]; then
    _fail "viz-session-name.sh not found at $NAME_HELPER"
    exit 1
fi

# ─── Test 1: helper is sourceable and exposes viz_tmux_session_name ───
# shellcheck disable=SC1090
source "$NAME_HELPER"
if declare -F viz_tmux_session_name >/dev/null 2>&1; then
    _pass "viz_tmux_session_name function is defined after sourcing"
else
    _fail "viz_tmux_session_name function not defined"
    exit 1
fi

# ─── Test 2: different project paths produce different names ───
NAME_A="$(viz_tmux_session_name "/home/u/projectA")"
NAME_B="$(viz_tmux_session_name "/home/u/projectB")"

if [[ -n "$NAME_A" && -n "$NAME_B" && "$NAME_A" != "$NAME_B" ]]; then
    _pass "different project paths produce different tmux session names ($NAME_A vs $NAME_B)"
else
    _fail "expected distinct names, got A='$NAME_A' B='$NAME_B'"
fi

# ─── Test 3: same project path produces a stable name ───
NAME_A2="$(viz_tmux_session_name "/home/u/projectA")"
if [[ "$NAME_A" == "$NAME_A2" ]]; then
    _pass "same project path produces a stable tmux session name across calls"
else
    _fail "stable-name expectation broken: '$NAME_A' vs '$NAME_A2'"
fi

# ─── Test 4: name has the humanize-viz- prefix ───
if [[ "$NAME_A" == humanize-viz-* ]]; then
    _pass "session name uses the humanize-viz- prefix ($NAME_A)"
else
    _fail "session name missing humanize-viz- prefix: $NAME_A"
fi

# ─── Test 5: empty input falls back to legacy global name ───
NAME_EMPTY="$(viz_tmux_session_name "")"
if [[ "$NAME_EMPTY" == "humanize-viz" ]]; then
    _pass "empty project path falls back to legacy global name (defensive default)"
else
    _fail "empty input should yield 'humanize-viz', got '$NAME_EMPTY'"
fi

# ─── Test 6: viz-start.sh / viz-stop.sh / viz-status.sh source the helper ───
for f in "$START_SH" "$STOP_SH" "$STATUS_SH"; do
    if grep -q 'viz-session-name.sh' "$f"; then
        _pass "$(basename "$f") sources viz-session-name.sh"
    else
        _fail "$(basename "$f") does not source viz-session-name.sh"
    fi
done

# ─── Test 7: viz-stop.sh and viz-status.sh no longer hard-code TMUX_SESSION="humanize-viz" ───
for f in "$START_SH" "$STOP_SH" "$STATUS_SH"; do
    if grep -qE 'TMUX_SESSION="humanize-viz"' "$f"; then
        _fail "$(basename "$f") still hard-codes the legacy global tmux session name"
    else
        _pass "$(basename "$f") no longer hard-codes the legacy global tmux session name"
    fi
done

# ─── Test 8: scripts call viz_tmux_session_name with the project dir ───
for f in "$START_SH" "$STOP_SH" "$STATUS_SH"; do
    if grep -q 'viz_tmux_session_name "\$PROJECT_DIR"' "$f"; then
        _pass "$(basename "$f") derives TMUX_SESSION from project dir"
    else
        _fail "$(basename "$f") does not derive TMUX_SESSION from project dir"
    fi
done

# ─── Test 9: viz.url persistence so health checks target the configured bind (Round 11 P2 fix) ───
echo
echo "Group 9: viz.url persistence for non-loopback bind health checks (Round 11)"

if grep -q 'URL_FILE="\$HUMANIZE_DIR/viz.url"' "$START_SH" && grep -q "echo \"http://" "$START_SH"; then
    _pass "viz-start.sh writes viz.url alongside viz.port"
else
    _fail "viz-start.sh does not persist the visible URL"
fi

if grep -q 'URL_FILE="\$HUMANIZE_DIR/viz.url"' "$STATUS_SH" && grep -q '\$probe_url/api/health' "$STATUS_SH"; then
    _pass "viz-status.sh reads viz.url for the liveness probe (no longer hardcodes localhost)"
else
    _fail "viz-status.sh still probes localhost regardless of bind"
fi

if grep -q 'URL_FILE="\$HUMANIZE_DIR/viz.url"' "$STOP_SH" && grep -q 'rm -f "\$PORT_FILE" "\$URL_FILE"' "$STOP_SH"; then
    _pass "viz-stop.sh cleans up viz.url alongside viz.port"
else
    _fail "viz-stop.sh leaves stale viz.url behind"
fi

if grep -qE 'fall back to .*localhost|fallback.*localhost' "$STATUS_SH" || grep -q 'http://localhost:\$port' "$STATUS_SH"; then
    _pass "viz-status.sh keeps the localhost fallback for older deployments without viz.url"
else
    _fail "viz-status.sh missing back-compat fallback when viz.url is absent"
fi

# ─── Group 10: find_port probes the configured bind host (Round 14 P2 fix) ───
echo
echo "Group 10: find_port probes the configured host (Round 14 P2 fix)"

# Before this fix, find_port always probed localhost. A specific
# non-loopback bind (e.g. 192.168.1.10) does not listen on localhost,
# so the probe mis-reported ports as free when another service owned
# them on the external interface, and Flask died with EADDRINUSE.
if grep -qE 'probe_host=.*"localhost"' "$START_SH" && \
   grep -qE 'probe_host="\$HOST"' "$START_SH"; then
    _pass "viz-start.sh find_port branches probe_host on configured HOST"
else
    _fail "viz-start.sh find_port still hardcodes localhost for all binds"
fi

if grep -qE '/dev/tcp/\$probe_host/\$candidate' "$START_SH"; then
    _pass "viz-start.sh find_port uses \$probe_host in /dev/tcp check (not literal localhost)"
else
    _fail "viz-start.sh find_port still uses /dev/tcp/localhost/\$candidate literal"
fi

# Check that the probe_host case block covers every documented bind
# family: loopback aliases, IPv4/IPv6 wildcards, and the specific-IP
# default. Missing any branch would regress the remote-mode contract.
if grep -B1 'probe_host="localhost"' "$START_SH" | grep -qE '127\.0\.0\.1\|::1\|localhost\|0\.0\.0\.0\|::'; then
    _pass "find_port probe_host=localhost branch covers loopback + wildcard binds (127.0.0.1|::1|localhost|0.0.0.0|::)"
else
    _fail "find_port probe_host=localhost branch missing one of the loopback/wildcard aliases"
fi

# The specific-IP branch (default "*)") must set probe_host to $HOST
# so a non-loopback bind probes its own interface.
if awk '/^find_port\(\) \{/,/^\}$/' "$START_SH" | \
   grep -A1 '^\s*\*)' | grep -q 'probe_host="\$HOST"'; then
    _pass "find_port default branch sets probe_host=\$HOST for specific non-loopback IPs"
else
    _fail "find_port default branch does not set probe_host=\$HOST"
fi

# ─── Group 11: readiness probe fail-closed (Round 16 P2 fix) ───
echo
echo "Group 11: readiness probe fail-closed + cleanup (Round 16 P2 fix)"

# The readiness loop must probe the canonical URL (viz.url) rather
# than hardcoding localhost, and must track whether any probe
# succeeded. Previously it printed "ready" unconditionally, so
# --host <specific-ip> daemons and startup crashes both went
# unnoticed with stale viz.port / viz.url left on disk.
if grep -qE 'probe_url=\$\(cat "\$URL_FILE"\)' "$START_SH" && \
   grep -qE '"\$probe_url/api/health"' "$START_SH"; then
    _pass "viz-start.sh readiness loop probes the canonical URL (viz.url), not literal localhost"
else
    _fail "viz-start.sh readiness loop still probes localhost regardless of bind"
fi

if grep -qE 'ready="true"' "$START_SH" && grep -qE 'if \[\[ "\$ready" != "true" \]\]; then' "$START_SH"; then
    _pass "viz-start.sh readiness loop tracks success + fails closed when never reachable"
else
    _fail "viz-start.sh readiness loop does not track success (always reports ready)"
fi

fail_block=$(awk '/if \[\[ "\$ready" != "true" \]\]; then/,/^fi$/' "$START_SH")
if grep -q 'rm -f "\$PORT_FILE" "\$URL_FILE"' <<<"$fail_block"; then
    _pass "viz-start.sh readiness failure cleans up stale viz.port and viz.url"
else
    _fail "viz-start.sh readiness failure leaves stale port/url files behind"
fi

if grep -q 'exit 1' <<<"$fail_block"; then
    _pass "viz-start.sh readiness failure exits non-zero (launcher fails closed)"
else
    _fail "viz-start.sh readiness failure still exits 0"
fi

# ─── Group 12: Round 18 P2 fix — IPv6 bind addresses bracketed in viz.url ───
echo
echo "Group 12: viz.url brackets IPv6 bind addresses per RFC 3986 (P2 Round 18)"

# A specific IPv6 bind written as http://<ipv6>:<port> is an invalid
# URL -- the port separator collides with the trailing fragments of
# the address. Without RFC 3986 brackets, curl/browsers/viz-status.sh
# treat the URL as unreachable and the Round 16 readiness probe
# falsely reports the dashboard as down.
if grep -qE 'case "\$visible_host_for_url" in' "$START_SH" && \
   grep -qE 'visible_host_for_url="\[\$\{visible_host_for_url\}\]"' "$START_SH"; then
    _pass "viz-start.sh wraps IPv6 visible_host_for_url in RFC 3986 brackets"
else
    _fail "viz-start.sh writes unbracketed IPv6 host to viz.url (readiness probe will false-fail)"
fi

# Behavioural probe: source the URL-build block with different HOST
# values and verify the final URL shape is correct.
URL_PROBE_SCRIPT="$(mktemp)"
trap "rm -f '$URL_PROBE_SCRIPT'" EXIT
cat > "$URL_PROBE_SCRIPT" <<'PROBE_EOF'
#!/usr/bin/env bash
# Replay the viz.url case blocks for a range of HOST values and print
# the computed URL so the test can assert on shape.
set -u
for host_value in 127.0.0.1 ::1 localhost 0.0.0.0 :: 192.168.1.10 10.0.0.5 2001:db8::1 fe80::abcd:1234; do
    HOST="$host_value"
    PORT=18000
    visible_host_for_url="$HOST"
    case "$HOST" in
        127.0.0.1|::1|localhost|0.0.0.0|::)
            visible_host_for_url="localhost"
            ;;
    esac
    case "$visible_host_for_url" in
        *:*)
            visible_host_for_url="[${visible_host_for_url}]"
            ;;
    esac
    echo "HOST=$HOST URL=http://${visible_host_for_url}:${PORT}"
done
PROBE_EOF
chmod +x "$URL_PROBE_SCRIPT"

if probe_url_output=$(bash "$URL_PROBE_SCRIPT" 2>&1); then
    if grep -q 'HOST=::1 URL=http://localhost:18000' <<<"$probe_url_output" && \
       grep -q 'HOST=2001:db8::1 URL=http://\[2001:db8::1\]:18000' <<<"$probe_url_output" && \
       grep -q 'HOST=fe80::abcd:1234 URL=http://\[fe80::abcd:1234\]:18000' <<<"$probe_url_output" && \
       grep -q 'HOST=192.168.1.10 URL=http://192.168.1.10:18000' <<<"$probe_url_output" && \
       grep -q 'HOST=localhost URL=http://localhost:18000' <<<"$probe_url_output"; then
        _pass "IPv6 bracketing matrix correct: loopback/wildcard -> localhost (no brackets); specific IPv6 -> bracketed; IPv4 -> unbracketed"
    else
        _fail "IPv6 bracketing matrix wrong: $probe_url_output"
    fi
else
    _fail "IPv6 bracketing probe failed: $probe_url_output"
fi

echo
echo "========================================"
printf 'Passed: \033[0;32m%d\033[0m\n' "$PASS_COUNT"
printf 'Failed: \033[0;31m%d\033[0m\n' "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi

printf '\033[0;32mAll viz isolation tests passed!\033[0m\n'
