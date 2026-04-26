# Install Humanize Skills for Codex

This guide explains how to install Humanize for Codex CLI, including the skill runtime (`$CODEX_HOME/skills`) and the native Codex `Stop` hook (`$CODEX_HOME/hooks.json`).

## Quick Install (Recommended)

One-line install from anywhere:

```bash
tmp_dir="$(mktemp -d)" && git clone --depth 1 https://github.com/PolyArch/humanize.git "$tmp_dir/humanize" && "$tmp_dir/humanize/scripts/install-skills-codex.sh"
```

From the Humanize repo root:

```bash
./scripts/install-skills-codex.sh
```

Or use the unified installer directly:

```bash
./scripts/install-skill.sh --target codex
```

This will:
- Sync `humanize`, `humanize-gen-idea`, `humanize-gen-plan`, `humanize-refine-plan`, and `humanize-rlcr` into `${CODEX_HOME:-~/.codex}/skills`
- Copy runtime dependencies into `${CODEX_HOME:-~/.codex}/skills/humanize`
- Install/update native Humanize Stop hooks in `${CODEX_HOME:-~/.codex}/hooks.json`
- Enable the experimental `codex_hooks` feature in `${CODEX_HOME:-~/.codex}/config.toml` when `codex` is available
- Seed `~/.config/humanize/config.json` with a Codex/OpenAI `bitlesson_model` when that key is not already set
- Mark the install as `provider_mode: "codex-only"` when using `--target codex`
- Use RLCR defaults: `codex exec` with `gpt-5.5:high`, `codex review` with `gpt-5.5:high`

Requires Codex CLI `0.114.0` or newer for native hooks. Older Codex builds are not supported by the Codex install path.

## Verify

```bash
ls -la "${CODEX_HOME:-$HOME/.codex}/skills"
```

Expected directories:
- `humanize`
- `humanize-gen-idea`
- `humanize-gen-plan`
- `humanize-refine-plan`
- `humanize-rlcr`

Runtime dependencies in `humanize/`:
- `scripts/`
- `hooks/`
- `prompt-template/`
- `templates/`
- `config/`
- `agents/`

Installed files/directories:
- `${CODEX_HOME:-~/.codex}/skills/humanize/SKILL.md`
- `${CODEX_HOME:-~/.codex}/skills/humanize-gen-idea/SKILL.md`
- `${CODEX_HOME:-~/.codex}/skills/humanize-gen-plan/SKILL.md`
- `${CODEX_HOME:-~/.codex}/skills/humanize-refine-plan/SKILL.md`
- `${CODEX_HOME:-~/.codex}/skills/humanize-rlcr/SKILL.md`
- `${CODEX_HOME:-~/.codex}/skills/humanize/scripts/`
- `${CODEX_HOME:-~/.codex}/skills/humanize/hooks/`
- `${CODEX_HOME:-~/.codex}/skills/humanize/prompt-template/`
- `${CODEX_HOME:-~/.codex}/skills/humanize/templates/`
- `${CODEX_HOME:-~/.codex}/skills/humanize/config/`
- `${CODEX_HOME:-~/.codex}/skills/humanize/agents/`
- `${CODEX_HOME:-~/.codex}/hooks.json`
- `${XDG_CONFIG_HOME:-~/.config}/humanize/config.json` (created or updated only when Humanize config keys are unset)

Verify native hooks:

```bash
codex features list | rg codex_hooks
sed -n '1,220p' "${CODEX_HOME:-$HOME/.codex}/hooks.json"
```

Expected:
- `codex_hooks` is `true`
- `hooks.json` contains `loop-codex-stop-hook.sh`
- `${XDG_CONFIG_HOME:-~/.config}/humanize/config.json` contains `bitlesson_model` set to a Codex/OpenAI model such as `gpt-5.5`
- for `--target codex`, `${XDG_CONFIG_HOME:-~/.config}/humanize/config.json` also contains `provider_mode: "codex-only"`

## Optional: Install for Both Codex and Kimi

```bash
./scripts/install-skill.sh --target both
```

## Useful Options

```bash
# Preview without writing
./scripts/install-skills-codex.sh --dry-run

# Custom Codex skills dir
./scripts/install-skills-codex.sh --codex-skills-dir /custom/codex/skills

# Reinstall only the native hooks/config
./scripts/install-codex-hooks.sh
```

## Troubleshooting

If scripts are not found from installed skills:

```bash
ls -la "${CODEX_HOME:-$HOME/.codex}/skills/humanize/scripts"
```

If native exit gating does not trigger:

```bash
codex features enable codex_hooks
sed -n '1,220p' "${CODEX_HOME:-$HOME/.codex}/hooks.json"
```
