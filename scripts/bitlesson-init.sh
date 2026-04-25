#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'USAGE_EOF' >&2
Usage:
  bitlesson-init.sh --project-root <dir> --template <path> [--bitlesson-relpath <relpath>]

Behavior:
  - Default bitlesson-relpath: .humanize/bitlesson.md
  - Creates <project-root>/<bitlesson-relpath> from template if missing
  - Does not overwrite existing file
  - Prints the resolved bitlesson file path to stdout on success
USAGE_EOF
}

PROJECT_ROOT=""
TEMPLATE_PATH=""
BITLESSON_RELPATH=".humanize/bitlesson.md"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --project-root)
            PROJECT_ROOT="${2:-}"
            shift 2
            ;;
        --template)
            TEMPLATE_PATH="${2:-}"
            shift 2
            ;;
        --bitlesson-relpath)
            BITLESSON_RELPATH="${2:-}"
            shift 2
            ;;
        *)
            echo "Error: Unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$PROJECT_ROOT" ]]; then
    echo "Error: --project-root is required" >&2
    usage
    exit 1
fi

if [[ -z "$TEMPLATE_PATH" ]]; then
    echo "Error: --template is required" >&2
    usage
    exit 1
fi

if [[ ! -d "$PROJECT_ROOT" ]]; then
    echo "Error: --project-root must be an existing directory: $PROJECT_ROOT" >&2
    exit 1
fi

if [[ ! -f "$TEMPLATE_PATH" ]]; then
    echo "Error: --template must be an existing file: $TEMPLATE_PATH" >&2
    exit 1
fi

if [[ "$BITLESSON_RELPATH" = /* ]] || [[ "$BITLESSON_RELPATH" =~ (^|/)\.\.(/|$) ]]; then
    echo "Error: --bitlesson-relpath must be a relative path without '..': $BITLESSON_RELPATH" >&2
    exit 1
fi

PROJECT_ROOT_ABS="$(cd "$PROJECT_ROOT" && pwd -P)"
BITLESSON_FILE="$PROJECT_ROOT_ABS/$BITLESSON_RELPATH"

if [[ -e "$BITLESSON_FILE" && ! -f "$BITLESSON_FILE" ]]; then
    echo "Error: BitLesson path exists but is not a regular file: $BITLESSON_FILE" >&2
    exit 1
fi

if [[ ! -f "$BITLESSON_FILE" ]]; then
    mkdir -p "$(dirname "$BITLESSON_FILE")"
    cp "$TEMPLATE_PATH" "$BITLESSON_FILE"
fi

printf '%s\n' "$BITLESSON_FILE"
