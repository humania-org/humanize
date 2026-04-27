# Install Humanize for Kimi CLI

This guide explains how to install the Humanize skills for [Kimi Code CLI](https://github.com/MoonshotAI/kimi-cli).

## Overview

Humanize provides four Agent Skills for kimi:

| Skill | Type | Purpose |
|-------|------|---------|
| `humanize` | Standard | General guidance for all workflows |
| `humanize-gen-plan` | Flow | Generate structured plan from draft |
| `humanize-refine-plan` | Flow | Refine annotated plan with CMT blocks |
| `humanize-rlcr` | Flow | Iterative development with Codex review |

## Installation

### Quick Install (Recommended)

From the Humanize repo root, run:

```bash
./scripts/install-skills-kimi.sh
```

This command will:
- Sync `humanize`, `humanize-gen-plan`, `humanize-plan-check`, `humanize-refine-plan`, and `humanize-rlcr` into `~/.config/agents/skills`
- Copy runtime dependencies into `~/.config/agents/skills/humanize`

Common installer script (all targets):

```bash
./scripts/install-skill.sh --target kimi
```

### Manual Install

### 1. Clone or navigate to the humanize repository

```bash
cd /path/to/humanize
```

### 2. Copy skills and runtime bundle to kimi's skills directory

```bash
# Create the skills directory if it doesn't exist
mkdir -p ~/.config/agents/skills

# Copy all Humanize skills
cp -r skills/humanize ~/.config/agents/skills/
cp -r skills/humanize-gen-plan ~/.config/agents/skills/
cp -r skills/humanize-plan-check ~/.config/agents/skills/
cp -r skills/humanize-refine-plan ~/.config/agents/skills/
cp -r skills/humanize-rlcr ~/.config/agents/skills/

# Copy runtime dependencies used by the skills
# (must match install-skill.sh's install_runtime_bundle)
cp -r scripts ~/.config/agents/skills/humanize/
cp -r hooks ~/.config/agents/skills/humanize/
cp -r prompt-template ~/.config/agents/skills/humanize/
cp -r templates ~/.config/agents/skills/humanize/
cp -r config ~/.config/agents/skills/humanize/
cp -r agents ~/.config/agents/skills/humanize/

# Hydrate runtime root placeholders inside SKILL.md files
for skill in humanize humanize-gen-plan humanize-plan-check humanize-refine-plan humanize-rlcr; do
  sed -i.bak "s|{{HUMANIZE_RUNTIME_ROOT}}|$HOME/.config/agents/skills/humanize|g" \
    "$HOME/.config/agents/skills/$skill/SKILL.md"
done

# Strip user-invocable flag from SKILL.md files for runtime visibility
# (This matches the behavior of scripts/install-skill.sh)
for skill in humanize humanize-gen-plan humanize-plan-check humanize-refine-plan humanize-rlcr; do
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
  ' "$HOME/.config/agents/skills/$skill/SKILL.md" > "$HOME/.config/agents/skills/$skill/SKILL.md.tmp"
  mv "$HOME/.config/agents/skills/$skill/SKILL.md.tmp" "$HOME/.config/agents/skills/$skill/SKILL.md"
done
```

### 3. Verify installation

```bash
# List installed skills
ls -la ~/.config/agents/skills/

# Should show:
# humanize/
# humanize-gen-plan/
# humanize-plan-check/
# humanize-refine-plan/
# humanize-rlcr/
```

### 4. Restart kimi (if already running)

Skills are loaded at startup. Restart kimi to pick up the new skills:

```bash
# Exit current kimi session
/exit

# Or press Ctrl-D

# Start kimi again
kimi
```

## Usage

### List available skills

```bash
/help
```

Look for the "Skills" section in the help output.

### Use the skills

#### 1. Generate plan from draft

```bash
# Start the flow (will ask for input/output paths)
/flow:humanize-gen-plan

# Or load as standard skill
/skill:humanize-gen-plan
```

#### 2. Start RLCR development loop

```bash
# Start with plan file
/flow:humanize-rlcr path/to/plan.md

# With options
/flow:humanize-rlcr path/to/plan.md --max 20 --push-every-round

# Skip implementation, go directly to code review
/flow:humanize-rlcr --skip-impl

# Load as standard skill (no auto-execution)
/skill:humanize-rlcr
```

#### 3. Get general guidance

```bash
/skill:humanize
```

## Command Options

### RLCR Loop Options

| Option | Description | Default |
|--------|-------------|---------|
| `path/to/plan.md` | Plan file path | Required (unless --skip-impl) |
| `--max N` | Maximum iterations | 42 |
| `--codex-model MODEL:EFFORT` | Codex model | gpt-5.5:high |
| `--codex-timeout SECONDS` | Review timeout | 5400 |
| `--base-branch BRANCH` | Base for code review | auto-detect |
| `--full-review-round N` | Full alignment check interval | 5 |
| `--skip-impl` | Skip to code review | false |
| `--push-every-round` | Push after each round | false |

### Generate Plan Options

| Option | Description | Required |
|--------|-------------|----------|
| `--input <path>` | Draft file path | Yes |
| `--output <path>` | Plan output path | Yes |

## Prerequisites

Ensure you have `codex` CLI installed:

```bash
codex --version
```

The skills will use `gpt-5.5` with `high` effort level by default.

## Uninstall

To remove the skills:

```bash
rm -rf ~/.config/agents/skills/humanize
rm -rf ~/.config/agents/skills/humanize-gen-plan
rm -rf ~/.config/agents/skills/humanize-refine-plan
rm -rf ~/.config/agents/skills/humanize-rlcr
```

## Troubleshooting

### Skills not showing up

1. Check the skills directory exists:
   ```bash
   ls ~/.config/agents/skills/
   ```

2. Ensure SKILL.md files are present:
   ```bash
   cat ~/.config/agents/skills/humanize/SKILL.md | head -5
   ```

3. Restart kimi completely

### Codex not found

The skills expect `codex` to be in your PATH. If using a proxy, ensure `~/.zprofile` is configured:

```bash
# Add to ~/.zprofile if needed
export OPENAI_API_KEY="your-api-key"
# or other proxy settings
```

### Scripts not found

If skills report missing scripts like `setup-rlcr-loop.sh`, verify:

```bash
ls -la ~/.config/agents/skills/humanize/scripts
```

### Installer options

The installer supports:

```bash
./scripts/install-skill.sh --help
```

Common examples:

```bash
# Preview only
./scripts/install-skills-kimi.sh --dry-run

# Custom skills directory
./scripts/install-skills-kimi.sh --skills-dir /custom/skills/dir
```

### Output files not found

The skills save output to:
- Cache: `~/.cache/humanize/<project>/<timestamp>/`
- Loop data: `.humanize/rlcr/<timestamp>/`

Ensure these directories are writable.

## See Also

- [Kimi CLI Documentation](https://moonshotai.github.io/kimi-cli/)
- [Agent Skills Format](https://agentskills.io/)
- [Install for Codex](./install-for-codex.md)
- [Humanize README](../README.md)
