#!/usr/bin/env bash
#
# Tests for gen-idea skill wiring across skills, installers, and install docs.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

SKILL_FILE="$PROJECT_ROOT/skills/humanize-gen-idea/SKILL.md"
INSTALL_SCRIPT="$PROJECT_ROOT/scripts/install-skill.sh"
README_FILE="$PROJECT_ROOT/README.md"
CLAUDE_INSTALL_DOC="$PROJECT_ROOT/docs/install-for-claude.md"
CODEX_INSTALL_DOC="$PROJECT_ROOT/docs/install-for-codex.md"
KIMI_INSTALL_DOC="$PROJECT_ROOT/docs/install-for-kimi.md"

frontmatter_value() {
    local file="$1"
    local key="$2"
    sed -n "/^---$/,/^---$/{ /^${key}:[[:space:]]*/{ s/^${key}:[[:space:]]*//p; q; } }" "$file"
}

assert_file_contains() {
    local file="$1"
    local needle="$2"
    local description="$3"

    if grep -qF -- "$needle" "$file"; then
        pass "$description"
    else
        fail "$description" "$needle" "missing"
    fi
}

echo "========================================"
echo "Gen-Idea Wiring Tests"
echo "========================================"
echo ""

if [[ -f "$SKILL_FILE" ]]; then
    pass "humanize-gen-idea skill file exists"

    if [[ "$(frontmatter_value "$SKILL_FILE" "name")" == "humanize-gen-idea" ]]; then
        pass "humanize-gen-idea skill frontmatter sets the correct name"
    else
        fail "humanize-gen-idea skill frontmatter sets the correct name" \
            "humanize-gen-idea" "$(frontmatter_value "$SKILL_FILE" "name")"
    fi

    if [[ "$(frontmatter_value "$SKILL_FILE" "user-invocable")" == "false" ]]; then
        pass "humanize-gen-idea skill frontmatter sets user-invocable: false"
    else
        fail "humanize-gen-idea skill frontmatter sets user-invocable: false" \
            "false" "$(frontmatter_value "$SKILL_FILE" "user-invocable")"
    fi
else
    fail "humanize-gen-idea skill file exists" "$SKILL_FILE" "missing"
fi

if sed -n '/^SKILL_NAMES=(/,/^)/p' "$INSTALL_SCRIPT" | grep -qF '"humanize-gen-idea"'; then
    pass "install-skill.sh includes humanize-gen-idea in SKILL_NAMES"
else
    fail "install-skill.sh includes humanize-gen-idea in SKILL_NAMES" \
        '"humanize-gen-idea"' "missing from SKILL_NAMES"
fi

assert_file_contains "$README_FILE" "/humanize:gen-idea" "README.md mentions gen-idea quick start"
assert_file_contains "$CLAUDE_INSTALL_DOC" "/humanize:gen-idea" "install-for-claude.md mentions gen-idea command"
assert_file_contains "$CODEX_INSTALL_DOC" "humanize-gen-idea" "install-for-codex.md mentions humanize-gen-idea skill"
assert_file_contains "$KIMI_INSTALL_DOC" "humanize-gen-idea" "install-for-kimi.md mentions humanize-gen-idea skill"

print_test_summary "Gen-Idea Wiring Tests"
