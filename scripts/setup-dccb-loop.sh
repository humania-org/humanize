#!/bin/bash
#
# Setup script for start-dccb-loop
#
# Creates state files for the DCCB (Distill Code to Conceptual Blueprint) loop.
# This loop uses Claude to analyze code and produce architecture documentation,
# with Codex reviewing whether the documentation is reconstruction-ready.
#
# Usage:
#   setup-dccb-loop.sh [--max N] [--codex-model MODEL:EFFORT] [--output-dir DIR]
#

set -euo pipefail

# ========================================
# Default Configuration
# ========================================

# Default Codex model and reasoning effort
DEFAULT_CODEX_MODEL="gpt-5.2-codex"
DEFAULT_CODEX_EFFORT="high"
DEFAULT_CODEX_TIMEOUT=5400
DEFAULT_MAX_ITERATIONS=42
DEFAULT_OUTPUT_DIR="dccb-doc"

# ========================================
# Parse Arguments
# ========================================

MAX_ITERATIONS="$DEFAULT_MAX_ITERATIONS"
CODEX_MODEL="$DEFAULT_CODEX_MODEL"
CODEX_EFFORT="$DEFAULT_CODEX_EFFORT"
CODEX_TIMEOUT="$DEFAULT_CODEX_TIMEOUT"
OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"

show_help() {
    cat << 'HELP_EOF'
start-dccb-loop - Distill Code to Conceptual Blueprint

USAGE:
  /humanize:start-dccb-loop [OPTIONS]

DESCRIPTION:
  Starts an iterative loop to distill the current codebase into a conceptual
  blueprint - a minimal, self-contained architecture document collection that
  is sufficient to guide a complete reconstruction of the codebase.

  The documentation structure is DYNAMIC - it adapts to the codebase:
  - Small codebase (1K lines): might produce a single file
  - Large codebase (1M lines): produces hierarchical documentation with subdirectories

OPTIONS:
  --max <N>              Maximum iterations before auto-stop (default: 42)
  --codex-model <MODEL:EFFORT>
                         Codex model and reasoning effort (default: gpt-5.2-codex:high)
  --codex-timeout <SECONDS>
                         Timeout for each Codex review in seconds (default: 5400)
  --output-dir <DIR>     Output directory for documentation (default: dccb-doc)
  -h, --help             Show this help message

EXAMPLES:
  /humanize:start-dccb-loop
  /humanize:start-dccb-loop --max 20
  /humanize:start-dccb-loop --codex-model gpt-5.2-codex:high
  /humanize:start-dccb-loop --output-dir architecture-docs

OUTPUT:
  Creates a documentation collection in the output directory. The structure
  mirrors the codebase organization:

  Small project example:
    dccb-doc/
    └── blueprint.md          # Single file for small projects

  Large project example:
    dccb-doc/
    ├── index.md              # Top-level overview and navigation
    ├── core/
    │   ├── index.md          # Core module overview
    │   ├── data-models.md
    │   └── workflows.md
    ├── api/
    │   ├── index.md
    │   └── endpoints.md
    └── infrastructure/
        ├── index.md
        └── deployment.md

STOPPING:
  - /humanize:cancel-dccb-loop   Cancel the active loop
  - Reach --max iterations
  - Codex outputs "COMPLETE" as final line of review

MONITORING:
  # View current state:
  cat .humanize-dccb.local/*/state.md

  # View latest summary:
  cat .humanize-dccb.local/*/round-*-summary.md | tail -50

  # View Codex review:
  cat .humanize-dccb.local/*/round-*-review-result.md | tail -50
HELP_EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        --max)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --max requires a number argument" >&2
                exit 1
            fi
            if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --max must be a positive integer, got: $2" >&2
                exit 1
            fi
            MAX_ITERATIONS="$2"
            shift 2
            ;;
        --codex-model)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --codex-model requires a MODEL:EFFORT argument" >&2
                exit 1
            fi
            # Parse MODEL:EFFORT format (portable - works in bash and zsh)
            if [[ "$2" == *:* ]]; then
                CODEX_MODEL="${2%%:*}"
                CODEX_EFFORT="${2#*:}"
            else
                CODEX_MODEL="$2"
                CODEX_EFFORT="$DEFAULT_CODEX_EFFORT"
            fi
            shift 2
            ;;
        --codex-timeout)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --codex-timeout requires a number argument (seconds)" >&2
                exit 1
            fi
            if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --codex-timeout must be a positive integer (seconds), got: $2" >&2
                exit 1
            fi
            CODEX_TIMEOUT="$2"
            shift 2
            ;;
        --output-dir)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --output-dir requires a directory path" >&2
                exit 1
            fi
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
        *)
            echo "Error: Unexpected argument: $1" >&2
            echo "DCCB loop does not take positional arguments - it analyzes the current codebase" >&2
            exit 1
            ;;
    esac
done

# ========================================
# Validate Prerequisites
# ========================================

# Check codex is available
if ! command -v codex &>/dev/null; then
    echo "Error: start-dccb-loop requires codex to run" >&2
    echo "" >&2
    echo "Please install Codex CLI: https://openai.com/codex" >&2
    exit 1
fi

# ========================================
# Setup State Directory
# ========================================

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
LOOP_BASE_DIR="$PROJECT_ROOT/.humanize-dccb.local"

# Create timestamp for this loop session
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
LOOP_DIR="$LOOP_BASE_DIR/$TIMESTAMP"

mkdir -p "$LOOP_DIR"

# Create output directory for documentation
FULL_OUTPUT_DIR="$PROJECT_ROOT/$OUTPUT_DIR"
mkdir -p "$FULL_OUTPUT_DIR"

# ========================================
# Create State File
# ========================================

cat > "$LOOP_DIR/state.md" << EOF
---
current_round: 0
max_iterations: $MAX_ITERATIONS
codex_model: $CODEX_MODEL
codex_effort: $CODEX_EFFORT
codex_timeout: $CODEX_TIMEOUT
output_dir: $OUTPUT_DIR
started_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
---
EOF

# ========================================
# Create Blueprint Tracker File
# ========================================

BLUEPRINT_TRACKER_FILE="$LOOP_DIR/blueprint-tracker.md"

cat > "$BLUEPRINT_TRACKER_FILE" << 'BLUEPRINT_TRACKER_EOF'
# Blueprint Tracker

<!--
This file tracks the progress of documentation distillation.
The documentation structure is DYNAMIC - it adapts to the codebase size and organization.

RULES:
- Round 0: Analyze codebase and propose documentation structure
- Structure is locked after Round 0 (but can be refined in content)
- Each document must be self-contained and reconstruction-ready
- Files must be under 1800 lines (split if needed)
-->

## Codebase Analysis (Round 0)

### Metrics
<!-- To be filled by Claude in Round 0 -->
| Metric | Value |
|--------|-------|
| Total Files | [pending] |
| Total Lines | [pending] |
| Primary Language(s) | [pending] |
| Major Modules | [pending] |

### Proposed Documentation Structure
<!-- To be filled by Claude in Round 0 based on codebase analysis -->
```
[pending - Claude will propose structure here]
```

### Structure Rationale
<!-- Why this structure mirrors the codebase organization -->
[pending]

---

## IMMUTABLE SECTION (after Round 0)
<!-- Documentation structure is locked after initialization -->

### Reconstruction Criteria

The documentation is considered "reconstruction-ready" when:

1. **Self-Contained**: Each document is understandable without reading source code
2. **Complete Coverage**: All significant modules, interfaces, and flows are documented
3. **De-Specialized**: Implementation-specific details are abstracted to concepts
4. **Consistent**: Terminology and cross-references are coherent across documents
5. **Minimal**: Only essential information for reconstruction is included
6. **Reconstructible**: An AI/developer could rebuild a functionally equivalent system
7. **Appropriately Structured**: Documentation depth matches codebase complexity

---

## MUTABLE SECTION
<!-- Update each round with progress -->

### Documentation Progress

| Path | Status | Lines | Notes |
|------|--------|-------|-------|
| [pending] | pending | - | - |

### Coverage Gaps Identified
<!-- Items here need attention in subsequent rounds -->
| Gap | Discovered Round | Addressed Round | Resolution |
|-----|-----------------|-----------------|------------|

### Review Feedback History
<!-- Track Codex feedback to ensure continuous improvement -->
| Round | Key Feedback | Addressed |
|-------|-------------|-----------|
BLUEPRINT_TRACKER_EOF

# ========================================
# Create Initial Prompt
# ========================================

SUMMARY_PATH="$LOOP_DIR/round-0-summary.md"

cat > "$LOOP_DIR/round-0-prompt.md" << EOF
Read and execute below with ultrathink

# DCCB Loop: Distill Code to Conceptual Blueprint

## Your Mission

You are tasked with distilling the current codebase into a **Conceptual Blueprint** - a minimal, self-contained documentation collection that is sufficient to guide a complete reconstruction of the system.

This is NOT ordinary documentation. The goal is to create a **reconstruction guide** that:
- Does NOT depend on reading the actual source code
- Represents the "minimal necessary mental model" of the system
- Enables functional reconstruction without access to the original code
- Has a structure that MIRRORS the codebase organization

## CRITICAL: Dynamic Documentation Structure

The documentation structure must be **proportional and appropriate** to the codebase:

| Codebase Size | Expected Documentation |
|---------------|----------------------|
| ~1K lines | Single file or 2-3 files |
| ~10K lines | 5-10 files, possibly 1-2 subdirectories |
| ~100K lines | Hierarchical structure with multiple subdirectories |
| ~1M lines | Deep hierarchy mirroring major subsystems |

**DO NOT** create a fixed structure. Analyze the codebase first, then propose an appropriate structure.

---

## Phase 1: Deep Codebase Analysis (MANDATORY FIRST STEP)

Before writing ANY documentation, you MUST thoroughly explore the codebase:

### 1.1 Quantitative Analysis
- Count total files and lines of code
- Identify primary languages used
- Map the directory structure

### 1.2 Structural Analysis
- Identify major modules/packages/components
- Map dependencies between modules
- Find the architectural boundaries

### 1.3 Conceptual Analysis
- Understand the system's purpose
- Identify key abstractions and patterns
- Note critical invariants and constraints

### 1.4 Interface Analysis
- Find all external APIs, CLIs, protocols
- Identify data schemas and contracts
- Map integration points

Take your time. Read important files. Create a mental model of the entire system.

---

## Phase 2: Propose Documentation Structure

Based on your analysis, propose a documentation structure that:
1. **Mirrors the codebase organization** - Similar hierarchy depth
2. **Groups related concepts** - Not arbitrary divisions
3. **Scales appropriately** - More docs for larger/complex areas
4. **Enables navigation** - Clear index/overview files

### Structure Guidelines

**For small codebases (< 5K lines):**
\`\`\`
$OUTPUT_DIR/
└── blueprint.md    # Everything in one file
\`\`\`

**For medium codebases (5K-50K lines):**
\`\`\`
$OUTPUT_DIR/
├── index.md        # Overview and navigation
├── architecture.md # System structure
├── data-models.md  # Core data concepts
├── workflows.md    # Key processes
└── interfaces.md   # External contracts
\`\`\`

**For large codebases (50K+ lines):**
\`\`\`
$OUTPUT_DIR/
├── index.md                    # Top-level overview
├── <module-a>/
│   ├── index.md               # Module overview
│   ├── concepts.md            # Key abstractions
│   └── interfaces.md          # Module contracts
├── <module-b>/
│   └── ...
└── cross-cutting/
    ├── data-flow.md           # System-wide data flow
    └── error-handling.md      # Error strategies
\`\`\`

---

## Phase 3: Write Documentation

Write documentation to: \`$OUTPUT_DIR/\`

### Documentation Principles

Each document must be:
- **Self-Contained**: Understandable without reading source code
- **De-Specialized**: Abstract implementation details to concepts
- **Functionally-Oriented**: Enable building a functionally equivalent system, NOT an exact clone
- **Under 1800 lines**: Split larger documents logically

### CRITICAL: Functional Equivalence, NOT Exact Replication

The goal is to enable someone to build a **functionally equivalent** system - NOT to replicate the original codebase 1:1.

This means:
- A reader should understand WHAT the system does and WHY
- A reader should be able to implement the same CAPABILITIES
- A reader does NOT need to recreate the exact same code structure
- Implementation choices (language, framework, etc.) can vary

### Content Guidelines

**DO include:**
- System/module purpose and capabilities
- Key abstractions and why they exist
- Data models (conceptual, not code-specific)
- Workflows and state transitions
- External interfaces and contracts
- Design principles and constraints
- Trade-offs and rationale
- Decision criteria (why certain approaches work)

**DO NOT include:**
- Code snippets (describe concepts instead)
- Implementation-specific variable/function/class names
- Line number references (e.g., "see line 42")
- File path references to the original codebase (e.g., "in src/foo/bar.py")
- References that point to specific locations in the existing implementation
- Transient or incidental implementation details
- Anything that assumes the reader has access to the original code

---

## Phase 4: Update Blueprint Tracker

Update @$BLUEPRINT_TRACKER_FILE with:
1. **Codebase Metrics**: Fill in the analysis results
2. **Proposed Structure**: Document your chosen structure with rationale
3. **Documentation Progress**: Track each file's status

---

## Output Requirements

After completing analysis and documentation:

1. Update @$BLUEPRINT_TRACKER_FILE with:
   - Codebase metrics
   - Proposed documentation structure (with tree diagram)
   - Structure rationale
   - Initial progress table

2. Write ALL documentation files to \`$OUTPUT_DIR/\`
   - At minimum, create an index.md or blueprint.md
   - Structure should match your proposal

3. Write your work summary to @$SUMMARY_PATH
   - Codebase analysis highlights
   - Chosen documentation structure and why
   - Documents created
   - Confidence level in reconstruction-readiness

Note: You MUST NOT try to exit the DCCB loop by lying or editing loop state files or trying to execute \`cancel-dccb-loop\`
EOF

# ========================================
# Output Setup Message
# ========================================

cat << EOF
=== start-dccb-loop activated ===

Target: Current codebase at $PROJECT_ROOT
Output Directory: $OUTPUT_DIR/
Max Iterations: $MAX_ITERATIONS
Codex Model: $CODEX_MODEL
Codex Effort: $CODEX_EFFORT
Codex Timeout: ${CODEX_TIMEOUT}s
Loop Directory: $LOOP_DIR

The documentation structure will be DYNAMIC based on codebase analysis:
- Small codebase -> single file or few files
- Large codebase -> hierarchical structure mirroring the code

The loop is now active. When you try to exit:
1. Codex will review whether your documentation is reconstruction-ready
2. If gaps are found, you'll receive feedback and continue refining
3. If Codex outputs "COMPLETE", the loop ends

To cancel: /humanize:cancel-dccb-loop

---

EOF

# Output the initial prompt
cat "$LOOP_DIR/round-0-prompt.md"

echo ""
echo "==========================================="
echo "CRITICAL - Work Completion Requirements"
echo "==========================================="
echo ""
echo "When you complete your work, you MUST:"
echo ""
echo "1. ANALYZE the codebase to determine appropriate documentation structure"
echo ""
echo "2. CREATE documentation in:"
echo "   $FULL_OUTPUT_DIR/"
echo ""
echo "   Structure should be PROPORTIONAL to codebase complexity:"
echo "   - Small project: single blueprint.md"
echo "   - Medium project: 5-10 files"
echo "   - Large project: hierarchical with subdirectories"
echo ""
echo "3. UPDATE the blueprint tracker with:"
echo "   - Codebase metrics"
echo "   - Proposed structure"
echo "   - Progress tracking"
echo ""
echo "4. Write a detailed summary to:"
echo "   $SUMMARY_PATH"
echo ""
echo "Codex will review whether the documentation is sufficient"
echo "for a complete reconstruction of the codebase."
echo "==========================================="
