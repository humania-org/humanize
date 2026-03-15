#!/bin/bash
#
# Install/upgrade Humanize skills for Kimi and/or Codex.
#
# What this does:
# 1) Sync skills/{humanize,humanize-gen-plan,humanize-rlcr} to target skills dir(s)
# 2) Copy runtime dependencies into <skills-dir>/humanize/{scripts,hooks,prompt-template}
# 3) Hydrate SKILL.md command paths with concrete runtime root paths
#
# Usage:
#   ./scripts/install-skill.sh [options]
#
# Options:
#   --repo-root PATH        Humanize repo root (default: auto-detect)
#   --target MODE           kimi|codex|both (default: kimi)
#   --skills-dir PATH       Legacy alias for target skills dir (kept for compatibility)
#   --kimi-skills-dir PATH  Kimi skills dir (default: ~/.config/agents/skills)
#   --codex-skills-dir PATH Codex skills dir (default: ${CODEX_HOME:-~/.codex}/skills)
#   --dry-run               Print actions without writing
#   -h, --help              Show help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="kimi"
KIMI_SKILLS_DIR="${HOME}/.config/agents/skills"
CODEX_SKILLS_DIR="${CODEX_HOME:-${HOME}/.codex}/skills"
LEGACY_SKILLS_DIR=""
DRY_RUN="false"

SKILL_NAMES=(
    "humanize"
    "humanize-gen-plan"
    "humanize-refine-plan"
    "humanize-rlcr"
)

usage() {
    cat <<'EOF'
Install Humanize skills for Kimi and/or Codex.

Usage:
  scripts/install-skill.sh [options]

Options:
  --target MODE           kimi|codex|both (default: kimi)
  --repo-root PATH        Humanize repo root (default: auto-detect)
  --skills-dir PATH       Legacy alias for target skills dir (compat)
  --kimi-skills-dir PATH  Kimi skills dir (default: ~/.config/agents/skills)
  --codex-skills-dir PATH Codex skills dir (default: ${CODEX_HOME:-~/.codex}/skills)
  --dry-run               Print actions without writing
  -h, --help              Show help
EOF
}

log() {
    printf '[install-skills] %s\n' "$*"
}

die() {
    printf '[install-skills] Error: %s\n' "$*" >&2
    exit 1
}

validate_repo() {
    [[ -d "$REPO_ROOT/skills" ]] || die "skills directory not found under repo root: $REPO_ROOT"
    [[ -d "$REPO_ROOT/scripts" ]] || die "scripts directory not found under repo root: $REPO_ROOT"
    [[ -d "$REPO_ROOT/hooks" ]] || die "hooks directory not found under repo root: $REPO_ROOT"
    [[ -d "$REPO_ROOT/prompt-template" ]] || die "prompt-template directory not found under repo root: $REPO_ROOT"
    [[ -d "$REPO_ROOT/templates" ]] || die "templates directory not found under repo root: $REPO_ROOT"
    [[ -d "$REPO_ROOT/config" ]] || die "config directory not found under repo root: $REPO_ROOT"
    [[ -d "$REPO_ROOT/agents" ]] || die "agents directory not found under repo root: $REPO_ROOT"
    for skill in "${SKILL_NAMES[@]}"; do
        [[ -f "$REPO_ROOT/skills/$skill/SKILL.md" ]] || die "missing $REPO_ROOT/skills/$skill/SKILL.md"
    done
}

sync_dir() {
    local src="$1"
    local dst="$2"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY-RUN sync $src -> $dst"
        return
    fi

    mkdir -p "$dst"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete "$src/" "$dst/"
    else
        # Copy to a temp sibling first so the destination is not destroyed
        # if cp fails partway through (disk full, permission error, etc.).
        local tmp_dst
        tmp_dst="$(mktemp -d "$(dirname "$dst")/.sync_tmp.XXXXXX")"
        if cp -a "$src/." "$tmp_dst/"; then
            rm -rf "$dst"
            mv "$tmp_dst" "$dst"
        else
            rm -rf "$tmp_dst"
            die "failed to copy $src to $dst"
        fi
    fi
}

sync_one_skill() {
    local skill="$1"
    local target_dir="$2"
    local src="$REPO_ROOT/skills/$skill"
    local dst="$target_dir/$skill"
    sync_dir "$src" "$dst"
}

install_runtime_bundle() {
    local target_dir="$1"
    local runtime_root="$target_dir/humanize"
    local component

    log "syncing runtime bundle into: $runtime_root"

    for component in scripts hooks prompt-template templates config agents; do
        sync_dir "$REPO_ROOT/$component" "$runtime_root/$component"
    done
}

hydrate_skill_runtime_root() {
    local target_dir="$1"
    local runtime_root="$target_dir/humanize"
    local skill
    local skill_file
    local tmp

    for skill in "${SKILL_NAMES[@]}"; do
        skill_file="$target_dir/$skill/SKILL.md"
        [[ -f "$skill_file" ]] || continue

        if [[ "$DRY_RUN" == "true" ]]; then
            log "DRY-RUN hydrate runtime root in $skill_file"
            continue
        fi

        tmp="$(mktemp)"
        # Use ENVIRON to pass the runtime root to awk instead of -v, which
        # interprets backslash escape sequences (e.g. \n -> newline).
        # ENVIRON passes the value verbatim.
        _HYDRATE_RUNTIME_ROOT="$runtime_root" \
            awk '{gsub(/\{\{HUMANIZE_RUNTIME_ROOT\}\}/, ENVIRON["_HYDRATE_RUNTIME_ROOT"]); print}' "$skill_file" > "$tmp" \
            || { rm -f "$tmp"; die "failed to hydrate $skill_file"; }
        mv "$tmp" "$skill_file"
    done
}

strip_user_invocable_for_runtime() {
    local target_dir="$1"
    local skill
    local skill_file
    local tmp

    for skill in "${SKILL_NAMES[@]}"; do
        skill_file="$target_dir/$skill/SKILL.md"
        [[ -f "$skill_file" ]] || continue

        if [[ "$DRY_RUN" == "true" ]]; then
            log "DRY-RUN strip user-invocable in $skill_file"
            continue
        fi

        tmp="$(mktemp)"
        awk '
            BEGIN { in_fm = 0; fm_done = 0 }
            /^---[[:space:]]*$/ {
                if (fm_done == 0) {
                    in_fm = !in_fm
                    if (in_fm == 0) {
                        fm_done = 1
                    }
                }
                print
                next
            }
            in_fm && $0 ~ /^user-invocable:[[:space:]]*/ { next }
            { print }
        ' "$skill_file" > "$tmp" \
            || { rm -f "$tmp"; die "failed to update $skill_file"; }
        mv "$tmp" "$skill_file"
    done
}

sync_target() {
    local label="$1"
    local target_dir="$2"

    log "target: $label"
    log "skills dir: $target_dir"

    if [[ "$DRY_RUN" != "true" ]]; then
        mkdir -p "$target_dir"
    fi

    for skill in "${SKILL_NAMES[@]}"; do
        log "syncing [$label] skill: $skill"
        sync_one_skill "$skill" "$target_dir"
    done
    install_runtime_bundle "$target_dir"
    hydrate_skill_runtime_root "$target_dir"
    strip_user_invocable_for_runtime "$target_dir"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            [[ -n "${2:-}" ]] || die "--target requires a value"
            case "$2" in
                kimi|codex|both) TARGET="$2" ;;
                *) die "--target must be one of: kimi, codex, both" ;;
            esac
            shift 2
            ;;
        --repo-root)
            [[ -n "${2:-}" ]] || die "--repo-root requires a value"
            REPO_ROOT="$2"
            shift 2
            ;;
        --skills-dir)
            [[ -n "${2:-}" ]] || die "--skills-dir requires a value"
            LEGACY_SKILLS_DIR="$2"
            shift 2
            ;;
        --kimi-skills-dir)
            [[ -n "${2:-}" ]] || die "--kimi-skills-dir requires a value"
            KIMI_SKILLS_DIR="$2"
            shift 2
            ;;
        --codex-skills-dir)
            [[ -n "${2:-}" ]] || die "--codex-skills-dir requires a value"
            CODEX_SKILLS_DIR="$2"
            shift 2
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

validate_repo

if [[ -n "$LEGACY_SKILLS_DIR" ]]; then
    case "$TARGET" in
        kimi) KIMI_SKILLS_DIR="$LEGACY_SKILLS_DIR" ;;
        codex) CODEX_SKILLS_DIR="$LEGACY_SKILLS_DIR" ;;
        both)
            KIMI_SKILLS_DIR="$LEGACY_SKILLS_DIR"
            CODEX_SKILLS_DIR="$LEGACY_SKILLS_DIR"
            ;;
    esac
fi

log "repo root: $REPO_ROOT"
log "target: $TARGET"
if [[ "$TARGET" == "kimi" || "$TARGET" == "both" ]]; then
    log "kimi skills dir: $KIMI_SKILLS_DIR"
fi
if [[ "$TARGET" == "codex" || "$TARGET" == "both" ]]; then
    log "codex skills dir: $CODEX_SKILLS_DIR"
fi

case "$TARGET" in
    kimi)
        sync_target "kimi" "$KIMI_SKILLS_DIR"
        ;;
    codex)
        sync_target "codex" "$CODEX_SKILLS_DIR"
        ;;
    both)
        sync_target "kimi" "$KIMI_SKILLS_DIR"
        sync_target "codex" "$CODEX_SKILLS_DIR"
        ;;
esac

cat <<EOF

Done.

Skills synced:
EOF

if [[ "$TARGET" == "kimi" || "$TARGET" == "both" ]]; then
    cat <<EOF
  - kimi:  $KIMI_SKILLS_DIR
EOF
fi

if [[ "$TARGET" == "codex" || "$TARGET" == "both" ]]; then
    cat <<EOF
  - codex: $CODEX_SKILLS_DIR
EOF
fi

cat <<EOF

Runtime root per target:
  <skills-dir>/humanize

No shell profile changes were made.
EOF
