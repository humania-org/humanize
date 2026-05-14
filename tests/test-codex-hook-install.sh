#!/usr/bin/env bash
#
# Tests for Codex-native hook installation and merge behavior.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

INSTALL_SCRIPT="$PROJECT_ROOT/scripts/install-skill.sh"

echo "=========================================="
echo "Codex Hook Install Tests"
echo "=========================================="
echo ""

if [[ ! -x "$INSTALL_SCRIPT" ]]; then
    echo "FATAL: install-skill.sh not found at $INSTALL_SCRIPT" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "FATAL: python3 is required for this test" >&2
    exit 1
fi

setup_test_dir

FAKE_BIN="$TEST_DIR/bin"
CODEX_HOME_DIR="$TEST_DIR/codex-home"
HOOKS_FILE="$CODEX_HOME_DIR/hooks.json"
FEATURE_LOG="$TEST_DIR/codex-features.log"
XDG_CONFIG_HOME_DIR="$TEST_DIR/xdg-config"
HUMANIZE_USER_CONFIG="$XDG_CONFIG_HOME_DIR/humanize/config.json"
COMMAND_BIN_DIR="$TEST_DIR/command-bin"
mkdir -p "$FAKE_BIN" "$CODEX_HOME_DIR" "$COMMAND_BIN_DIR"

cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
    cat <<'HELP'
Usage: codex [OPTIONS] [PROMPT]
  --disable <feature>    Disable a named feature for this invocation
HELP
    for i in $(seq 1 5000); do
        printf '  --noise-%s\n' "$i"
    done
    exit 0
fi

if [[ "${1:-}" == "features" && "${2:-}" == "list" ]]; then
    cat <<'LIST'
hooks                            stable             false
LIST
    exit 0
fi

if [[ "${1:-}" == "features" && "${2:-}" == "enable" && "${3:-}" == "hooks" ]]; then
    printf 'CODEX_HOME=%s\n' "${CODEX_HOME:-}" >> "${TEST_CODEX_FEATURE_LOG:?}"
    mkdir -p "${CODEX_HOME:?}"
    : > "${CODEX_HOME}/.hooks-enabled"
    exit 0
fi

if [[ "${1:-}" == "exec" ]]; then
    cat <<'OUT'
LESSON_IDS: NONE
RATIONALE: No matching lessons found (fake codex exec).
OUT
    exit 0
fi

echo "unexpected fake codex invocation: $*" >&2
exit 1
EOF
chmod +x "$FAKE_BIN/codex"

cat > "$HOOKS_FILE" <<'EOF'
{
  "description": "Existing hooks",
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/custom/session-start.sh",
            "timeout": 15
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/tmp/old/skills/humanize/hooks/loop-codex-stop-hook.sh",
            "timeout": 30
          }
        ]
      },
      {
        "hooks": [
          {
            "type": "command",
            "command": "/custom/keep-me.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
EOF

PATH="$FAKE_BIN:$PATH" TEST_CODEX_FEATURE_LOG="$FEATURE_LOG" XDG_CONFIG_HOME="$XDG_CONFIG_HOME_DIR" \
    "$INSTALL_SCRIPT" \
    --target codex \
    --codex-config-dir "$CODEX_HOME_DIR" \
    --codex-skills-dir "$CODEX_HOME_DIR/skills" \
    --command-bin-dir "$COMMAND_BIN_DIR" \
    > "$TEST_DIR/install.log" 2>&1

if [[ -f "$CODEX_HOME_DIR/skills/humanize/SKILL.md" ]]; then
    pass "Codex install syncs Humanize skill bundle"
else
    fail "Codex install syncs Humanize skill bundle" "skills/humanize/SKILL.md exists" "missing"
fi

if [[ -f "$CODEX_HOME_DIR/skills/humanize-rlcr/SKILL.md" ]]; then
    pass "Codex install keeps humanize-rlcr entrypoint skill"
else
    fail "Codex install keeps humanize-rlcr entrypoint skill" "skills/humanize-rlcr/SKILL.md exists" "missing"
fi

if [[ -f "$HOOKS_FILE" ]]; then
    pass "Codex install writes hooks.json"
else
    fail "Codex install writes hooks.json" "$HOOKS_FILE exists" "missing"
fi

if [[ -f "$CODEX_HOME_DIR/.hooks-enabled" ]]; then
    pass "Codex install enables hooks feature"
else
    fail "Codex install enables hooks feature" ".hooks-enabled marker exists" "missing"
fi

if [[ -f "$HUMANIZE_USER_CONFIG" ]]; then
    pass "Codex install writes Humanize user config"
else
    fail "Codex install writes Humanize user config" "$HUMANIZE_USER_CONFIG exists" "missing"
fi

if [[ -x "$COMMAND_BIN_DIR/bitlesson-selector" ]]; then
    pass "Codex install writes a PATH-ready bitlesson-selector shim"
else
    fail "Codex install writes a PATH-ready bitlesson-selector shim" "$COMMAND_BIN_DIR/bitlesson-selector exists" "missing"
fi

if [[ "$(jq -r '.bitlesson_model // empty' "$HUMANIZE_USER_CONFIG")" == "gpt-5.5" ]]; then
    pass "Codex install seeds bitlesson_model with a Codex/OpenAI model"
else
    fail "Codex install seeds bitlesson_model with a Codex/OpenAI model" \
        "gpt-5.5" "$(jq -c '.' "$HUMANIZE_USER_CONFIG" 2>/dev/null || echo MISSING)"
fi

if [[ "$(jq -r '.provider_mode // empty' "$HUMANIZE_USER_CONFIG")" == "codex-only" ]]; then
    pass "Codex install marks Humanize user config as codex-only"
else
    fail "Codex install marks Humanize user config as codex-only" \
        "codex-only" "$(jq -c '.' "$HUMANIZE_USER_CONFIG" 2>/dev/null || echo MISSING)"
fi

runtime_root="$CODEX_HOME_DIR/skills/humanize"
PY_OUTPUT="$(
    python3 - "$HOOKS_FILE" "$runtime_root" <<'PY'
import json
import pathlib
import sys

hooks_file = pathlib.Path(sys.argv[1])
runtime_root = sys.argv[2]
data = json.loads(hooks_file.read_text(encoding="utf-8"))

commands = []
for group in data["hooks"]["Stop"]:
    for hook in group.get("hooks", []):
        command = hook.get("command")
        if isinstance(command, str):
            commands.append(command)

expected = {
    f"{runtime_root}/hooks/loop-codex-stop-hook.sh",
}

print("FOUND=" + ("1" if expected.issubset(set(commands)) else "0"))
print("KEEP=" + ("1" if "/custom/keep-me.sh" in commands else "0"))
print("OLD=" + ("1" if any("/tmp/old/skills/humanize/hooks/" in cmd for cmd in commands) else "0"))
print("SESSION=" + ("1" if data["hooks"]["SessionStart"][0]["hooks"][0]["command"] == "/custom/session-start.sh" else "0"))
print("COUNT=" + str(sum(1 for cmd in commands if "/humanize/hooks/" in cmd)))
PY
)"

if grep -q '^FOUND=1$' <<<"$PY_OUTPUT"; then
    pass "Codex install adds managed Humanize Stop hook commands"
else
    fail "Codex install adds managed Humanize Stop hook commands" "FOUND=1" "$PY_OUTPUT"
fi

if grep -q '^KEEP=1$' <<<"$PY_OUTPUT"; then
    pass "Codex install preserves unrelated Stop hooks"
else
    fail "Codex install preserves unrelated Stop hooks" "KEEP=1" "$PY_OUTPUT"
fi

if grep -q '^OLD=0$' <<<"$PY_OUTPUT"; then
    pass "Codex install removes stale Humanize hook commands"
else
    fail "Codex install removes stale Humanize hook commands" "OLD=0" "$PY_OUTPUT"
fi

if grep -q '^SESSION=1$' <<<"$PY_OUTPUT"; then
    pass "Codex install preserves SessionStart hooks"
else
    fail "Codex install preserves SessionStart hooks" "SESSION=1" "$PY_OUTPUT"
fi

if grep -q '^COUNT=1$' <<<"$PY_OUTPUT"; then
    pass "Codex install writes exactly one managed Humanize Stop hook"
else
    fail "Codex install writes exactly one managed Humanize Stop hook" "COUNT=1" "$PY_OUTPUT"
fi

mkdir -p "$TEST_DIR/project"
cat > "$TEST_DIR/project/bitlesson.md" <<'EOF'
# BitLesson Knowledge Base
## Entries
<!-- placeholder -->
EOF

shim_output="$(
    CLAUDE_PROJECT_DIR="$TEST_DIR/project" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME_DIR" \
    PATH="$COMMAND_BIN_DIR:$FAKE_BIN:$PATH" \
    "$COMMAND_BIN_DIR/bitlesson-selector" \
    --task "Verify the shim dispatches into the installed runtime" \
    --paths "README.md" \
    --bitlesson-file "$TEST_DIR/project/bitlesson.md"
)"

if grep -q '^LESSON_IDS: NONE$' <<<"$shim_output"; then
    pass "bitlesson-selector shim dispatches into installed runtime"
else
    fail "bitlesson-selector shim dispatches into installed runtime" "LESSON_IDS: NONE" "$shim_output"
fi

PATH="$FAKE_BIN:$PATH" TEST_CODEX_FEATURE_LOG="$FEATURE_LOG" XDG_CONFIG_HOME="$XDG_CONFIG_HOME_DIR" \
    "$INSTALL_SCRIPT" \
    --target codex \
    --codex-config-dir "$CODEX_HOME_DIR" \
    --codex-skills-dir "$CODEX_HOME_DIR/skills" \
    --command-bin-dir "$COMMAND_BIN_DIR" \
    > "$TEST_DIR/install-2.log" 2>&1

PY_OUTPUT_2="$(
    python3 - "$HOOKS_FILE" <<'PY'
import json
import pathlib
import sys

hooks_file = pathlib.Path(sys.argv[1])
data = json.loads(hooks_file.read_text(encoding="utf-8"))

commands = []
for group in data["hooks"]["Stop"]:
    for hook in group.get("hooks", []):
        command = hook.get("command")
        if isinstance(command, str):
            commands.append(command)

print(sum(1 for cmd in commands if "/humanize/hooks/" in cmd))
PY
)"

if [[ "$PY_OUTPUT_2" == "1" ]]; then
    pass "Codex install is idempotent for managed hook commands"
else
    fail "Codex install is idempotent for managed hook commands" "1" "$PY_OUTPUT_2"
fi

if [[ "$(wc -l < "$FEATURE_LOG" | tr -d ' ')" == "2" ]]; then
    pass "Codex feature enable runs on each Codex install/update"
else
    fail "Codex feature enable runs on each Codex install/update" "2 log entries" "$(cat "$FEATURE_LOG")"
fi

LEGACY_CONFIG_HOME="$TEST_DIR/codex-home-legacy-config"
mkdir -p "$LEGACY_CONFIG_HOME"
cat > "$LEGACY_CONFIG_HOME/config.toml" <<'EOF'
[features]
codex_hooks = true
EOF

set +e
PATH="$FAKE_BIN:$PATH" TEST_CODEX_FEATURE_LOG="$FEATURE_LOG" \
    "$INSTALL_SCRIPT" \
    --target codex \
    --codex-config-dir "$LEGACY_CONFIG_HOME" \
    --codex-skills-dir "$LEGACY_CONFIG_HOME/skills" \
    > "$TEST_DIR/install-legacy-config.log" 2>&1
LEGACY_CONFIG_EXIT=$?
set -e

if [[ "$LEGACY_CONFIG_EXIT" -ne 0 ]]; then
    pass "Codex install rejects legacy codex_hooks config"
else
    fail "Codex install rejects legacy codex_hooks config" "non-zero exit" "exit 0"
fi

if grep -q "legacy feature key 'codex_hooks'" "$TEST_DIR/install-legacy-config.log" \
    && grep -q "hooks = true" "$TEST_DIR/install-legacy-config.log"; then
    pass "Legacy codex_hooks config failure explains hooks rename"
else
    fail "Legacy codex_hooks config failure explains hooks rename" \
        "error mentioning legacy codex_hooks and hooks = true" \
        "$(cat "$TEST_DIR/install-legacy-config.log")"
fi

LEGACY_ONLY_BIN="$TEST_DIR/bin-legacy-only"
LEGACY_ONLY_HOME="$TEST_DIR/codex-home-legacy-only"
mkdir -p "$LEGACY_ONLY_BIN" "$LEGACY_ONLY_HOME"

cat > "$LEGACY_ONLY_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "features" && "${2:-}" == "list" ]]; then
    cat <<'LIST'
codex_hooks                      under development  false
LIST
    exit 0
fi

echo "unexpected fake codex invocation: $*" >&2
exit 1
EOF
chmod +x "$LEGACY_ONLY_BIN/codex"

set +e
PATH="$LEGACY_ONLY_BIN:$PATH" \
    "$INSTALL_SCRIPT" \
    --target codex \
    --codex-config-dir "$LEGACY_ONLY_HOME" \
    --codex-skills-dir "$LEGACY_ONLY_HOME/skills" \
    > "$TEST_DIR/install-legacy-only.log" 2>&1
LEGACY_ONLY_EXIT=$?
set -e

if [[ "$LEGACY_ONLY_EXIT" -ne 0 ]]; then
    pass "Codex install rejects Codex builds exposing only legacy codex_hooks"
else
    fail "Codex install rejects Codex builds exposing only legacy codex_hooks" "non-zero exit" "exit 0"
fi

if grep -q "legacy 'codex_hooks' feature" "$TEST_DIR/install-legacy-only.log" \
    && grep -q "Upgrade Codex" "$TEST_DIR/install-legacy-only.log"; then
    pass "Legacy-only feature failure asks user to upgrade Codex"
else
    fail "Legacy-only feature failure asks user to upgrade Codex" \
        "error mentioning legacy codex_hooks and Upgrade Codex" \
        "$(cat "$TEST_DIR/install-legacy-only.log")"
fi

UNSUPPORTED_BIN="$TEST_DIR/bin-unsupported"
UNSUPPORTED_HOME="$TEST_DIR/codex-home-unsupported"
UNSUPPORTED_COMMAND_BIN_DIR="$TEST_DIR/command-bin-unsupported"
UNSUPPORTED_XDG_CONFIG_HOME_DIR="$TEST_DIR/xdg-config-unsupported"
mkdir -p "$UNSUPPORTED_BIN" "$UNSUPPORTED_HOME" "$UNSUPPORTED_COMMAND_BIN_DIR" "$UNSUPPORTED_XDG_CONFIG_HOME_DIR"

cat > "$UNSUPPORTED_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "features" && "${2:-}" == "list" ]]; then
    cat <<'LIST'
apply_patch_freeform             under development  false
LIST
    exit 0
fi

echo "unexpected fake codex invocation: $*" >&2
exit 1
EOF
chmod +x "$UNSUPPORTED_BIN/codex"

set +e
PATH="$UNSUPPORTED_BIN:$PATH" XDG_CONFIG_HOME="$UNSUPPORTED_XDG_CONFIG_HOME_DIR" \
    "$INSTALL_SCRIPT" \
    --target codex \
    --codex-config-dir "$UNSUPPORTED_HOME" \
    --codex-skills-dir "$UNSUPPORTED_HOME/skills" \
    --command-bin-dir "$UNSUPPORTED_COMMAND_BIN_DIR" \
    > "$TEST_DIR/install-unsupported.log" 2>&1
UNSUPPORTED_EXIT=$?
set -e

if [[ "$UNSUPPORTED_EXIT" -ne 0 ]]; then
    pass "Codex install rejects builds without native hooks support"
else
    fail "Codex install rejects builds without native hooks support" "non-zero exit" "exit 0"
fi

if grep -q "native 'hooks' feature" "$TEST_DIR/install-unsupported.log" \
    && grep -q "Upgrade Codex" "$TEST_DIR/install-unsupported.log"; then
    pass "Unsupported Codex failure explains missing hooks feature"
else
    fail "Unsupported Codex failure explains missing hooks feature" \
        "error mentioning native hooks feature and Upgrade Codex" \
        "$(cat "$TEST_DIR/install-unsupported.log")"
fi

# --- Codex with hooks but without --disable must be rejected ---
# Regression: a Codex build that exposes hooks but lacks --disable cannot
# be safely installed because the stop hook's recursive-invocation guard relies on
# `--disable hooks`. The installer must catch this configuration before
# writing any files.

NO_DISABLE_BIN="$TEST_DIR/bin-no-disable"
NO_DISABLE_HOME="$TEST_DIR/codex-home-no-disable"
NO_DISABLE_XDG="$TEST_DIR/xdg-no-disable"
mkdir -p "$NO_DISABLE_BIN" "$NO_DISABLE_HOME"

cat > "$NO_DISABLE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
    echo "Usage: codex [OPTIONS] [PROMPT]"
    exit 0
fi

if [[ "${1:-}" == "features" && "${2:-}" == "list" ]]; then
    cat <<'LIST'
hooks                            stable             false
LIST
    exit 0
fi

echo "unexpected fake codex invocation: $*" >&2
exit 1
EOF
chmod +x "$NO_DISABLE_BIN/codex"

set +e
PATH="$NO_DISABLE_BIN:$PATH" XDG_CONFIG_HOME="$NO_DISABLE_XDG" \
    "$INSTALL_SCRIPT" \
    --target codex \
    --codex-config-dir "$NO_DISABLE_HOME" \
    --codex-skills-dir "$NO_DISABLE_HOME/skills" \
    --command-bin-dir "$COMMAND_BIN_DIR" \
    > "$TEST_DIR/install-no-disable.log" 2>&1
NO_DISABLE_EXIT=$?
set -e

if [[ "$NO_DISABLE_EXIT" -ne 0 ]]; then
    pass "Codex install rejects builds with hooks but without --disable"
else
    fail "Codex install rejects builds with hooks but without --disable" "non-zero exit" "exit 0"
fi

if grep -q "\-\-disable" "$TEST_DIR/install-no-disable.log"; then
    pass "No-disable Codex failure mentions --disable flag requirement"
else
    fail "No-disable Codex failure mentions --disable flag requirement" \
        "error mentioning --disable" \
        "$(cat "$TEST_DIR/install-no-disable.log")"
fi

# --- Kimi RLCR skill gate test ---
# Regression: after the native-hook SKILL.md was introduced, Kimi installs
# received the same "stop or exit normally / native hook" instructions.
# overwrite_kimi_rlcr_skill() must replace that with the gate-based SKILL.md.

KIMI_HOME_DIR="$TEST_DIR/kimi-home"
KIMI_SKILLS_DIR="$KIMI_HOME_DIR/skills"
mkdir -p "$KIMI_HOME_DIR"

PATH="$FAKE_BIN:$PATH" XDG_CONFIG_HOME="$XDG_CONFIG_HOME_DIR" \
    "$INSTALL_SCRIPT" \
    --target kimi \
    --kimi-skills-dir "$KIMI_SKILLS_DIR" \
    --command-bin-dir "$COMMAND_BIN_DIR" \
    > "$TEST_DIR/install-kimi.log" 2>&1

KIMI_RLCR_SKILL="$KIMI_SKILLS_DIR/humanize-rlcr/SKILL.md"

if [[ -f "$KIMI_RLCR_SKILL" ]]; then
    pass "Kimi install produces humanize-rlcr/SKILL.md"
else
    fail "Kimi install produces humanize-rlcr/SKILL.md" "SKILL.md exists" "missing"
fi

if grep -q "rlcr-stop-gate.sh" "$KIMI_RLCR_SKILL" 2>/dev/null; then
    pass "Kimi humanize-rlcr/SKILL.md uses explicit rlcr-stop-gate.sh gate"
else
    fail "Kimi humanize-rlcr/SKILL.md uses explicit rlcr-stop-gate.sh gate" \
        "rlcr-stop-gate.sh present" \
        "$(head -10 "$KIMI_RLCR_SKILL" 2>/dev/null || echo MISSING)"
fi

if ! grep -q "native.*Stop hook\|Stop hook run automatically\|exit normally" "$KIMI_RLCR_SKILL" 2>/dev/null; then
    pass "Kimi humanize-rlcr/SKILL.md does not reference native Stop hook"
else
    fail "Kimi humanize-rlcr/SKILL.md does not reference native Stop hook" \
        "native hook text absent" "native hook text present"
fi

if grep -q "gpt-5.5:high" "$KIMI_RLCR_SKILL" 2>/dev/null \
        && ! grep -q "gpt-5.4:high" "$KIMI_RLCR_SKILL" 2>/dev/null; then
    pass "Kimi humanize-rlcr/SKILL.md documents current Codex default model"
else
    fail "Kimi humanize-rlcr/SKILL.md documents current Codex default model" \
        "gpt-5.5:high present and gpt-5.4:high absent" \
        "$(grep -n "gpt-5\\.[45]:high" "$KIMI_RLCR_SKILL" 2>/dev/null || echo MISSING)"
fi

# --- --target both provider_mode test ---
# Regression: install_codex_target() was passing $TARGET ("both") to
# install_codex_user_config(), so provider_mode: "codex-only" was never written
# for mixed Codex+Kimi installs.

BOTH_CODEX_HOME="$TEST_DIR/both-codex-home"
BOTH_KIMI_SKILLS="$TEST_DIR/both-kimi-skills"
BOTH_XDG_CONFIG="$TEST_DIR/both-xdg-config"
BOTH_USER_CONFIG="$BOTH_XDG_CONFIG/humanize/config.json"
mkdir -p "$BOTH_CODEX_HOME" "$BOTH_KIMI_SKILLS"

PATH="$FAKE_BIN:$PATH" TEST_CODEX_FEATURE_LOG="$TEST_DIR/feature-log-both.log" \
    XDG_CONFIG_HOME="$BOTH_XDG_CONFIG" \
    HUMANIZE_USER_CONFIG_DIR="$BOTH_XDG_CONFIG/humanize" \
    "$INSTALL_SCRIPT" \
    --target both \
    --codex-config-dir "$BOTH_CODEX_HOME" \
    --codex-skills-dir "$BOTH_CODEX_HOME/skills" \
    --kimi-skills-dir "$BOTH_KIMI_SKILLS" \
    --command-bin-dir "$COMMAND_BIN_DIR" \
    > "$TEST_DIR/install-both.log" 2>&1

if [[ "$(jq -r '.provider_mode // empty' "$BOTH_USER_CONFIG" 2>/dev/null)" == "codex-only" ]]; then
    pass "--target both install writes provider_mode: codex-only"
else
    fail "--target both install writes provider_mode: codex-only" \
        "codex-only" "$(jq -c '.' "$BOTH_USER_CONFIG" 2>/dev/null || echo MISSING)"
fi

# --- --target both with shared skills dir must be rejected ---
# Regression: when KIMI_SKILLS_DIR == CODEX_SKILLS_DIR, install_codex_target
# overwrites the Kimi-specific humanize-rlcr/SKILL.md. The installer must
# reject this configuration before any install work happens.

SHARED_DIR="$TEST_DIR/shared-skills"
mkdir -p "$SHARED_DIR"

SHARED_CODEX_HOME="$TEST_DIR/shared-codex-home"
SHARED_XDG_CONFIG="$TEST_DIR/shared-xdg-config"
mkdir -p "$SHARED_CODEX_HOME"

set +e
PATH="$FAKE_BIN:$PATH" TEST_CODEX_FEATURE_LOG="$TEST_DIR/feature-log-shared.log" \
    XDG_CONFIG_HOME="$SHARED_XDG_CONFIG" \
    "$INSTALL_SCRIPT" \
    --target both \
    --codex-config-dir "$SHARED_CODEX_HOME" \
    --codex-skills-dir "$SHARED_DIR" \
    --kimi-skills-dir "$SHARED_DIR" \
    --command-bin-dir "$COMMAND_BIN_DIR" \
    > "$TEST_DIR/install-shared.log" 2>&1
SHARED_EXIT=$?
set -e

if [[ "$SHARED_EXIT" -ne 0 ]]; then
    pass "--target both with shared skills dir exits non-zero"
else
    fail "--target both with shared skills dir exits non-zero" "non-zero exit" "exit 0"
fi

if grep -qi "distinct\|same.*dir\|conflict\|identical" "$TEST_DIR/install-shared.log" 2>/dev/null; then
    pass "--target both shared-dir error explains conflict"
else
    fail "--target both shared-dir error explains conflict" \
        "conflict message" "$(cat "$TEST_DIR/install-shared.log")"
fi

# Equivalent non-existent paths must also be rejected. Regression: failed
# realpath calls used raw strings, so a/../shared and shared compared different.
mkdir -p "$TEST_DIR/path-normalization-missing" "$TEST_DIR/path-normalization-codex-home"
NORMALIZED_SHARED_A="$TEST_DIR/path-normalization-missing/a/../shared"
NORMALIZED_SHARED_B="$TEST_DIR/path-normalization-missing/shared"
set +e
PATH="$FAKE_BIN:$PATH" TEST_CODEX_FEATURE_LOG="$TEST_DIR/feature-log-shared-normalized.log" \
    XDG_CONFIG_HOME="$TEST_DIR/shared-normalized-xdg" \
    "$INSTALL_SCRIPT" \
    --target both \
    --codex-config-dir "$TEST_DIR/path-normalization-codex-home" \
    --codex-skills-dir "$NORMALIZED_SHARED_A" \
    --kimi-skills-dir "$NORMALIZED_SHARED_B" \
    --command-bin-dir "$COMMAND_BIN_DIR" \
    --dry-run \
    > "$TEST_DIR/install-shared-normalized.log" 2>&1
NORMALIZED_SHARED_EXIT=$?
set -e

if [[ "$NORMALIZED_SHARED_EXIT" -ne 0 ]] \
        && grep -qi "distinct\|same.*dir\|conflict\|identical" "$TEST_DIR/install-shared-normalized.log" 2>/dev/null; then
    pass "--target both rejects equivalent non-existent shared skills dirs"
else
    fail "--target both rejects equivalent non-existent shared skills dirs" \
        "non-zero conflict error" \
        "exit=$NORMALIZED_SHARED_EXIT log=$(cat "$TEST_DIR/install-shared-normalized.log")"
fi

print_test_summary "Codex Hook Install Tests"
