#!/usr/bin/env bash
#
# Install/update Humanize native Codex hooks in CODEX_HOME/hooks.json.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CODEX_CONFIG_DIR="${CODEX_HOME:-${HOME}/.codex}"
RUNTIME_ROOT="$CODEX_CONFIG_DIR/skills/humanize"
DRY_RUN="false"
ENABLE_FEATURE="true"
HOOKS_TEMPLATE="$REPO_ROOT/config/codex-hooks.json"
HOOK_FEATURE_ENABLED=""

usage() {
    cat <<'EOF'
Install/update Humanize native Codex hooks.

Usage:
  scripts/install-codex-hooks.sh [options]

Options:
  --codex-config-dir PATH  Codex config dir (default: ${CODEX_HOME:-~/.codex})
  --runtime-root PATH      Installed Humanize runtime root (default: <codex-config-dir>/skills/humanize)
  --skip-enable-feature    Do not run `codex features enable hooks`
  --dry-run                Print actions without writing
  -h, --help               Show help
EOF
}

log() {
    printf '[install-codex-hooks] %s\n' "$*"
}

die() {
    printf '[install-codex-hooks] Error: %s\n' "$*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --codex-config-dir)
            [[ -n "${2:-}" ]] || die "--codex-config-dir requires a value"
            CODEX_CONFIG_DIR="$2"
            shift 2
            ;;
        --runtime-root)
            [[ -n "${2:-}" ]] || die "--runtime-root requires a value"
            RUNTIME_ROOT="$2"
            shift 2
            ;;
        --skip-enable-feature)
            ENABLE_FEATURE="false"
            shift
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

[[ -f "$HOOKS_TEMPLATE" ]] || die "hook template not found: $HOOKS_TEMPLATE"

HOOKS_FILE="$CODEX_CONFIG_DIR/hooks.json"

config_uses_legacy_codex_hooks() {
    local config_file="$CODEX_CONFIG_DIR/config.toml"

    [[ -f "$config_file" ]] || return 1

    grep -Eq '^[[:space:]]*(features\.)?codex_hooks[[:space:]]*=' "$config_file"
}

require_native_hooks_support() {
    if ! command -v codex >/dev/null 2>&1; then
        die "Codex CLI with native hooks support is required. Install Codex 0.114.0+ first."
    fi

    if config_uses_legacy_codex_hooks; then
        die "Codex config uses the legacy feature key 'codex_hooks'. Current Codex uses 'hooks'. Update $CODEX_CONFIG_DIR/config.toml to use 'hooks = true' under [features], or upgrade Codex if 'codex features list' does not show 'hooks'."
    fi

    local features
    local line
    features="$(CODEX_HOME="$CODEX_CONFIG_DIR" codex features list 2>/dev/null)" || {
        die "failed to inspect Codex features. Humanize Codex install requires the native 'hooks' feature."
    }

    line="$(printf '%s\n' "$features" | awk '$1 == "hooks" { print; exit }')"
    if [[ -n "$line" ]]; then
        HOOK_FEATURE_ENABLED="$(awk '{ print $NF }' <<<"$line")"
        return 0
    fi

    if printf '%s\n' "$features" | awk '$1 == "codex_hooks" { found = 1 } END { exit found ? 0 : 1 }'; then
        die "Installed Codex exposes only the legacy 'codex_hooks' feature. Humanize now requires the renamed 'hooks' feature. Upgrade Codex, then rerun the installer."
    fi

    die "Installed Codex CLI does not expose the native 'hooks' feature. Upgrade Codex, then rerun the installer."
}

merge_hooks_json() {
    local hooks_file="$1"
    local template_file="$2"
    local runtime_root="$3"

    if ! command -v python3 >/dev/null 2>&1; then
        die "python3 is required to merge Codex hooks"
    fi

    python3 - "$hooks_file" "$template_file" "$runtime_root" <<'PY'
import json
import pathlib
import re
import shlex
import sys

hooks_file = pathlib.Path(sys.argv[1])
template_file = pathlib.Path(sys.argv[2])
runtime_root = sys.argv[3]

template_text = template_file.read_text(encoding="utf-8")
# JSON-escape the runtime root so metacharacters (quotes, backslashes) do not
# corrupt the template before json.loads parses it.
escaped_root = json.dumps(runtime_root)[1:-1]  # strip outer quotes from dumps output
template_text = template_text.replace("{{HUMANIZE_RUNTIME_ROOT}}", escaped_root)
template = json.loads(template_text)

# Shell-quote command paths so spaces in runtime_root do not split the command
for group_list in template.get("hooks", {}).values():
    for group in group_list:
        if isinstance(group, dict):
            for hook in group.get("hooks", []):
                if isinstance(hook, dict) and "command" in hook:
                    hook["command"] = shlex.quote(hook["command"])

existing = {}
if hooks_file.exists():
    with hooks_file.open("r", encoding="utf-8") as fh:
        existing = json.load(fh)

if not isinstance(existing, dict):
    raise SystemExit(f"existing hooks config must be a JSON object: {hooks_file}")

hooks = existing.setdefault("hooks", {})
if not isinstance(hooks, dict):
    raise SystemExit(f"existing hooks config has invalid 'hooks' object: {hooks_file}")

stop_groups = hooks.get("Stop", [])
if stop_groups is None:
    stop_groups = []
if not isinstance(stop_groups, list):
    raise SystemExit(f"existing hooks config has invalid Stop array: {hooks_file}")

managed_pattern = re.compile(r"(^|/)hooks/(loop-codex-stop-hook\.sh|pr-loop-stop-hook\.sh)(['\"\s]|$)")

filtered_groups = []
for group in stop_groups:
    if not isinstance(group, dict):
        filtered_groups.append(group)
        continue
    group_hooks = group.get("hooks")
    if not isinstance(group_hooks, list):
        filtered_groups.append(group)
        continue
    kept_hooks = []
    for hook in group_hooks:
        if not isinstance(hook, dict):
            kept_hooks.append(hook)
            continue
        command = hook.get("command")
        if isinstance(command, str) and managed_pattern.search(command):
            continue
        kept_hooks.append(hook)
    if kept_hooks:
        new_group = dict(group)
        new_group["hooks"] = kept_hooks
        filtered_groups.append(new_group)

managed_stop_groups = template.get("hooks", {}).get("Stop", [])
filtered_groups.extend(managed_stop_groups)
hooks["Stop"] = filtered_groups

if not existing.get("description"):
    existing["description"] = template.get("description", "Humanize Codex Hooks")

hooks_file.parent.mkdir(parents=True, exist_ok=True)
hooks_file.write_text(json.dumps(existing, indent=2) + "\n", encoding="utf-8")
PY
}

enable_feature() {
    local config_dir="$1"

    [[ "$ENABLE_FEATURE" == "true" ]] || return 0

    if [[ "$HOOK_FEATURE_ENABLED" == "true" ]]; then
        log "native hooks feature already enabled in $config_dir/config.toml"
        return 0
    fi

    if CODEX_HOME="$config_dir" codex features enable hooks >/dev/null 2>&1; then
        log "enabled hooks feature in $config_dir/config.toml"
    else
        die "failed to enable hooks feature automatically in $config_dir/config.toml"
    fi
}

log "codex config dir: $CODEX_CONFIG_DIR"
log "runtime root: $RUNTIME_ROOT"
log "hooks file: $HOOKS_FILE"

require_native_hooks_support

if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN merge $HOOKS_TEMPLATE -> $HOOKS_FILE"
    if [[ "$ENABLE_FEATURE" == "true" ]]; then
        log "DRY-RUN enable hooks feature in $CODEX_CONFIG_DIR/config.toml"
    fi
    exit 0
fi

merge_hooks_json "$HOOKS_FILE" "$HOOKS_TEMPLATE" "$RUNTIME_ROOT"
enable_feature "$CODEX_CONFIG_DIR"

cat <<EOF

Codex hooks installed.
  hooks.json:   $HOOKS_FILE
  runtime root: $RUNTIME_ROOT
EOF
