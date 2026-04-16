#!/usr/bin/env bash
#
# Background-task helpers for the RLCR stop hook.
#
# Owns all logic that inspects the Claude Code transcript to decide
# whether the hook should short-circuit (the main session is still
# waiting on an asynchronous Agent/Bash dispatch), plus the four guard
# blocks that the stop hook runs before its normal gate logic:
#
#   1. Ambiguous-caller marker guard
#   2. Cross-session parked-loop guard
#   3. Early exit: pending background tasks
#   4. Same-session stale-marker cleanup
#
# Depends on loop-common.sh (FIELD_SESSION_ID, resolve_active_state_file)
# being sourced first.
#

# Source guard.
[[ -n "${_LOOP_BG_TASKS_LOADED:-}" ]] && return 0 2>/dev/null || true
_LOOP_BG_TASKS_LOADED=1

# Expand a leading "~" or "~/" in a path to "$HOME" without using eval.
# Only the bare "~" and "~/..." forms are expanded; "~user/..." and every
# other input (absolute path, relative path, empty string) is returned verbatim.
#
# Usage: expand_leading_tilde "$path"
#   Prints the normalized path to stdout.
expand_leading_tilde() {
    local path="$1"
    case "$path" in
        '~')   printf '%s' "${HOME:-}" ;;
        '~/'*) printf '%s/%s' "${HOME:-}" "${path#'~/'}" ;;
        *)     printf '%s' "$path" ;;
    esac
}

# Extract transcript_path from hook JSON input and expand any leading tilde.
# Usage: extract_transcript_path "$json_input"
# Outputs the transcript_path to stdout, or empty string if not available.
extract_transcript_path() {
    local input="$1"
    local raw
    raw=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")
    expand_leading_tilde "$raw"
}

# Convert an RLCR loop dir basename to a lexically-comparable ISO-8601
# UTC timestamp suitable for filtering transcript events.
#
# `setup-rlcr-loop.sh` creates loop dirs named `YYYY-MM-DD_HH-MM-SS` in
# the system's LOCAL wall clock (it calls `date +%Y-%m-%d_%H-%M-%S`
# without `-u`). Claude transcript events carry actual UTC timestamps
# like `2026-04-16T13:19:26.819Z`. To compare them correctly, this
# helper converts the local wall-clock parse back to a real UTC moment
# via a two-step: parse local -> epoch seconds -> format in UTC.
#
# The `.000Z` suffix keeps sub-second transcript timestamps in the same
# second compared greater via lexical string ordering.
#
# Usage: derive_loop_start_iso_ts "$loop_dir"
#   Prints the ISO-8601 UTC timestamp, or empty string when the
#   basename does not match the expected format or the local `date`
#   binary cannot parse it.
derive_loop_start_iso_ts() {
    local loop_dir="$1"
    local base
    base=$(basename "$loop_dir" 2>/dev/null || echo "")
    if [[ ! "$base" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2})$ ]]; then
        return
    fi
    local local_datetime
    local_datetime="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}:${BASH_REMATCH[3]}:${BASH_REMATCH[4]}"

    # Local wall-clock -> epoch seconds. GNU `date -d` first,
    # BSD/macOS `date -j -f ...` second. Both honour the caller's TZ
    # for interpretation, matching setup-rlcr-loop.sh's behaviour at
    # loop-dir creation time.
    local epoch
    epoch=$(date -d "$local_datetime" +%s 2>/dev/null) || epoch=""
    if [[ -z "$epoch" ]]; then
        epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$local_datetime" +%s 2>/dev/null) || epoch=""
    fi
    if [[ -z "$epoch" ]]; then
        return
    fi

    # Epoch -> UTC ISO-8601. Try GNU then BSD.
    local utc_iso
    utc_iso=$(date -u -d "@$epoch" "+%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null) || utc_iso=""
    if [[ -z "$utc_iso" ]]; then
        utc_iso=$(date -u -r "$epoch" "+%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null) || utc_iso=""
    fi
    printf '%s' "$utc_iso"
}

# Enumerate background-task ids that have been launched but not yet marked
# completed in a Claude Code transcript.jsonl.
#
# Launch events (inspected in tool_result "user" messages):
#   - Background subagent: toolUseResult.isAsync == true
#     -> id is toolUseResult.agentId
#   - Background shell: toolUseResult.backgroundTaskId non-empty
#     -> id is toolUseResult.backgroundTaskId
#
# Completion events are recognised from two Claude Code transcript forms:
#
#   1. Structured SDK record
#      (see SDKTaskNotificationMessage in docs/typescript.md):
#      `type == "system"`, `subtype == "task_notification"`,
#      `task_id` is the completed id. Any `status` value
#      (completed, failed, stopped, ...) is treated as terminal.
#
#   2. Legacy queue-operation enqueue whose `content` embeds a
#      `<task-notification>` XML block with `<task-id>...</task-id>`;
#      kept for transcripts produced by older Claude Code versions.
#
# pending := launched \ completed
#
# Optional second argument `since_ts` (ISO-8601 string, e.g. the value
# returned by `derive_loop_start_iso_ts`): when provided, only launch
# events whose top-level `.timestamp` field is >= `since_ts` count as
# candidate launches. Events without a `.timestamp` are included (keeps
# fixture transcripts and older record formats working). This keeps
# pre-loop session-wide background work from pinning an RLCR loop that
# has no pending work of its own.
#
# Usage: list_pending_background_task_ids "$transcript_path" [since_ts]
#   - Outputs one id per line on stdout (possibly empty).
#   - Returns 0 when the transcript is readable (including when there are
#     no pending tasks). Returns 1 when the transcript path is empty, not
#     a regular file, or jq is unavailable, so callers must treat non-zero
#     as "unknown -> do not short-circuit".
list_pending_background_task_ids() {
    local transcript_path="$1"
    local since_ts="${2:-}"

    # Normalize a leading tilde so direct callers (tests, ad-hoc scripts)
    # work correctly even when transcript_path was not routed through
    # extract_transcript_path.
    transcript_path=$(expand_leading_tilde "$transcript_path")

    if [[ -z "$transcript_path" ]] || [[ ! -f "$transcript_path" ]]; then
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        return 1
    fi

    local launched completed
    launched=$(jq -r --arg since_ts "$since_ts" '
        select(.toolUseResult != null)
        | select(
            ($since_ts == ""
             or ((.timestamp // "") == "")
             or ((.timestamp // "") >= $since_ts))
          )
        | select(
            (.toolUseResult.isAsync == true and (.toolUseResult.agentId // "") != "")
            or ((.toolUseResult.backgroundTaskId // "") != "")
          )
        | (.toolUseResult.agentId // .toolUseResult.backgroundTaskId)
    ' "$transcript_path" 2>/dev/null | sort -u) || return 1

    # Union of both completion formats. Either source alone is enough to
    # mark a launched id terminal.
    #
    # The `grep -oE || true` guard on the legacy branch keeps `set -o
    # pipefail` from poisoning the combined pipeline when no legacy
    # queue-operation records exist in the transcript (grep with `-o`
    # exits 1 on no matches, which would otherwise wipe out any SDK
    # task_notification results collected above).
    completed=$(
        {
            jq -r '
                select(.type == "system" and .subtype == "task_notification")
                | (.task_id // empty)
            ' "$transcript_path" 2>/dev/null
            jq -r '
                select(.type == "queue-operation" and .operation == "enqueue")
                | (.content // "" | tostring)
                | select(contains("<task-notification>"))
            ' "$transcript_path" 2>/dev/null \
                | { grep -oE '<task-id>[^<]+</task-id>' || true; } \
                | sed -E 's|</?task-id>||g'
        } | sort -u | sed '/^$/d'
    ) || completed=""

    # Emit launched ids that have no matching completion notification.
    comm -23 \
        <(printf '%s\n' "$launched" | sed '/^$/d') \
        <(printf '%s\n' "$completed" | sed '/^$/d')
}

# Returns 0 when the transcript shows at least one pending background task.
# Returns 1 when no pending tasks are detected (including fail-closed cases
# like missing transcript, non-file path, or jq unavailable).
#
# Usage: has_pending_background_tasks "$transcript_path" [since_ts]
has_pending_background_tasks() {
    local transcript_path="$1"
    local since_ts="${2:-}"
    local pending
    pending=$(list_pending_background_task_ids "$transcript_path" "$since_ts" 2>/dev/null) || return 1
    [[ -n "$pending" ]]
}

# Prints the count of pending background tasks to stdout. Prints 0 for any
# error case so callers can still format messages safely.
#
# Usage: count_pending_background_tasks "$transcript_path" [since_ts]
count_pending_background_tasks() {
    local transcript_path="$1"
    local since_ts="${2:-}"
    local pending
    pending=$(list_pending_background_task_ids "$transcript_path" "$since_ts" 2>/dev/null) || {
        echo 0
        return 0
    }
    if [[ -z "$pending" ]]; then
        echo 0
    else
        printf '%s\n' "$pending" | sed '/^$/d' | wc -l | tr -d ' '
    fi
}

# Single entry point for the stop hook: runs the four guard blocks
# (ambiguous-caller, cross-session parked, pending-bg short-circuit,
# same-session stale-marker cleanup) in order. When a guard decides to
# short-circuit the stop hook, it emits the appropriate JSON on stdout
# and `exit 0`s directly; the caller (sourcing the hook script) never
# returns. When no guard fires, this function returns 0 and the stop
# hook continues into its normal gate logic.
#
# Depends on FIELD_SESSION_ID and resolve_active_state_file from
# loop-common.sh.
#
# Usage: handle_bg_task_short_circuit "$LOOP_DIR" "$HOOK_INPUT" "$HOOK_SESSION_ID"
handle_bg_task_short_circuit() {
    local loop_dir="$1" hook_input="$2" hook_session_id="$3"

    # Shared state used by the guard blocks below.
    # Loop-start boundary: derived from the loop dir basename
    # (`YYYY-MM-DD_HH-MM-SS`). Empty means derivation failed; helpers
    # treat empty since_ts as no boundary.
    local loop_start_ts transcript_path
    loop_start_ts=$(derive_loop_start_iso_ts "$loop_dir")
    transcript_path=$(extract_transcript_path "$hook_input")

    # ----------------------------------------
    # Ambiguous-Caller Marker Guard
    # ----------------------------------------
    # If a bg-pending.marker is present but we have no session_id on
    # this hook invocation (typical of scripts/rlcr-stop-gate.sh
    # invoked without --session-id, or any other caller that doesn't
    # forward session_id), we cannot tell whether this caller owns the
    # parked loop. Taking either branch (foreign-session guard below,
    # or same-session cleanup further down) would be wrong in one of
    # the two possible realities. Exit 0 silently: the real Claude
    # hook will arrive with session_id populated and drive parking /
    # cleanup from an authoritative context.
    if [[ -f "$loop_dir/bg-pending.marker" ]] && [[ -z "$hook_session_id" ]]; then
        exit 0
    fi

    # ----------------------------------------
    # Cross-Session Parked-Loop Guard
    # ----------------------------------------
    # If find_active_loop handed this dir over via the marker fallback,
    # the loop is parked by a different session waiting on a background
    # task. The current session has no authority to inspect or advance
    # that loop - its transcript sees none of the foreign bg activity -
    # so the only safe response is to exit 0 with a distinct
    # systemMessage and leave every on-disk artifact (state file,
    # stored session_id, marker) untouched.
    #
    # Both sides of the session-id comparison must be non-empty for
    # this branch to trigger: an empty hook_session_id has already
    # exited above via the ambiguous-caller guard, and an empty stored
    # session_id keeps the backward-compat "matches any" semantics
    # from find_active_loop.
    if [[ -f "$loop_dir/bg-pending.marker" ]]; then
        local guard_state_file guard_stored_sid
        guard_state_file=$(resolve_active_state_file "$loop_dir")
        if [[ -n "$guard_state_file" ]]; then
            guard_stored_sid=$(sed -n '/^---$/,/^---$/{ /^'"${FIELD_SESSION_ID}"':/{ s/^'"${FIELD_SESSION_ID}"': *//; p; } }' "$guard_state_file" 2>/dev/null | tr -d ' ')
            if [[ -n "$guard_stored_sid" ]] \
               && [[ -n "$hook_session_id" ]] \
               && [[ "$guard_stored_sid" != "$hook_session_id" ]]; then
                jq -n \
                    '{systemMessage: "RLCR loop in this repo is parked by another Claude session waiting for background work. Stop allowed; your session leaves the loop untouched. If that session ended, run /humanize:cancel-rlcr-loop to clean up."}'
                exit 0
            fi
        fi
    fi

    # ----------------------------------------
    # Early Exit: Pending Background Tasks
    # ----------------------------------------
    # When the main Claude Code session has dispatched background work
    # (Agent with run_in_background=true, or Bash with
    # run_in_background=true) whose completion notifications have not
    # yet arrived, the natural "stop" is simply "I am waiting for the
    # background task". Running git/summary/BitLesson/Codex gates in
    # that state wastes Codex tokens and produces low-signal reviews.
    #
    # Allow the stop (exit 0) and emit a user-visible systemMessage so
    # nobody mistakes the pause for loop completion. The on-disk loop
    # state is left untouched -- the next natural stop (after
    # background work finishes) will re-enter this hook with no
    # pending tasks and run the normal flow.
    #
    # loop_start_ts confines the transcript scan to launches that
    # actually happened during this loop; earlier session-wide bg
    # activity cannot pin the loop.
    #
    # This check MUST run before any other gate (phase detection,
    # state parsing, branch / plan / git-clean / summary / max-iter
    # checks, Codex review).
    local pending_bg_ids
    pending_bg_ids=$(list_pending_background_task_ids "$transcript_path" "$loop_start_ts" 2>/dev/null) || true
    if [[ -n "$pending_bg_ids" ]]; then
        local pending_bg_count
        pending_bg_count=$(printf '%s\n' "$pending_bg_ids" | sed '/^$/d' | wc -l | tr -d ' ')
        # Mark the loop as parked; allows the same session to resume
        # later and makes the cross-session guard above reachable if
        # the user opens a different Claude session in this repo
        # before the bg task completes.
        : > "$loop_dir/bg-pending.marker" 2>/dev/null || true
        jq -n --arg count "$pending_bg_count" \
            '{systemMessage: ("RLCR loop active. " + $count + " background task(s) still running - stop allowed naturally; loop has NOT terminated and will resume on completion.")}'
        exit 0
    fi

    # ----------------------------------------
    # Same-Session Stale-Marker Cleanup
    # ----------------------------------------
    # The cross-session guard above already exited for every foreign
    # session, so reaching here with the marker present means the
    # CURRENT session parked the loop and has now come back with a
    # transcript showing no pending bg events. Remove the stale marker
    # before the normal flow takes over.
    #
    # Two-part guard to make sure we never drop the parked-state
    # signal without evidence:
    #   (a) list_pending_background_task_ids returned exit 0 -- the
    #       transcript was present, readable, AND parsed successfully.
    #       The helper is fail-closed on missing files, empty paths,
    #       jq parse failure, and truncation, so a non-zero exit
    #       blocks cleanup here even when the transcript "file"
    #       exists.
    #   (b) its output is empty -- proves "no pending" was
    #       authoritatively verified, not inferred from a failure.
    # The check uses a single fresh call so we capture both the exit
    # code and the emptiness without double-running jq.
    if [[ -f "$loop_dir/bg-pending.marker" ]]; then
        local pending_bg_check
        if pending_bg_check=$(list_pending_background_task_ids "$transcript_path" "$loop_start_ts" 2>/dev/null) \
           && [[ -z "$pending_bg_check" ]]; then
            rm -f "$loop_dir/bg-pending.marker" 2>/dev/null || true
        fi
    fi
}
