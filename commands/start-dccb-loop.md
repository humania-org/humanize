---
description: "Start code-to-blueprint distillation loop"
argument-hint: "[--max N] [--codex-model MODEL:EFFORT] [--codex-timeout SECONDS] [--output-dir DIR]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-dccb-loop.sh:*)"]
hide-from-slash-command-tool: "true"
---

# Start DCCB Loop (Distill Code to Conceptual Blueprint)

Execute the setup script to initialize the loop:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-dccb-loop.sh" $ARGUMENTS
```

This command starts an iterative distillation loop where:

1. You (Claude) analyze the codebase and produce architecture documentation
2. Write the documentation to the specified output directory (dccb-doc/)
3. When you try to exit, Codex reviews whether the documentation is reconstruction-ready
4. If Codex finds gaps, you receive feedback and continue refining
5. If Codex outputs "COMPLETE", the loop ends

## What is DCCB?

DCCB (Distill Code to Conceptual Blueprint) creates architecture documentation from existing code.

The goal is to create a **Conceptual Blueprint** - a minimal, self-contained architecture document that:
- Does NOT depend on reading the actual code
- Represents the "minimal necessary mental model" of the system
- Is sufficient to guide a complete reconstruction of the codebase
- Serves as the "obligation boundary" for human understanding

## Dynamic Documentation Structure

**CRITICAL**: The documentation structure is NOT fixed. It adapts to the codebase:

| Codebase Size | Expected Documentation Structure |
|---------------|----------------------------------|
| ~1K lines | Single `blueprint.md` file |
| ~10K lines | 5-10 files, possibly 1-2 subdirectories |
| ~100K lines | Hierarchical structure with multiple subdirectories |
| ~1M lines | Deep hierarchy mirroring major subsystems |

### Example Structures

**Small project (1K lines):**
```
dccb-doc/
└── blueprint.md
```

**Medium project (10K lines):**
```
dccb-doc/
├── index.md
├── architecture.md
├── data-models.md
├── workflows.md
└── interfaces.md
```

**Large project (100K+ lines):**
```
dccb-doc/
├── index.md
├── core/
│   ├── index.md
│   ├── concepts.md
│   └── interfaces.md
├── api/
│   ├── index.md
│   └── endpoints.md
└── infrastructure/
    ├── index.md
    └── deployment.md
```

## Key Principles

### Functional Equivalence (NOT Exact Replication)
The goal is to enable building a **functionally equivalent** system - NOT a 1:1 clone. A reader should be able to implement the same capabilities in ANY language or framework.

### Self-Contained Documentation
The blueprint should be readable without referring to the source code. It explains the "what" and "why", not the "how" of specific implementations.

### De-Specialization
Remove code-specific details like variable names, function signatures, or framework-specific idioms. Focus on the underlying concepts and patterns.

**The documentation must NOT contain:**
- Line number references (e.g., "see line 42")
- File path references to the original codebase (e.g., "in src/foo/bar.py")
- References pointing to specific implementations in the existing code

### Minimal Necessary Model
Include only what's essential to understand and rebuild the system. Every section must justify its inclusion by being necessary for reconstruction.

### Proportional Structure
Documentation depth should match codebase complexity. Don't over-document small projects or under-document large ones.

## Important Rules

1. **Analyze first**: Before writing documentation, thoroughly explore and understand the codebase
2. **Propose structure**: Based on codebase analysis, propose an appropriate documentation structure
3. **Write self-contained docs**: Each document should be understandable without code references
4. **Maintain consistency**: Use consistent terminology across all documents
5. **Keep files under 1800 lines**: Split large documents into logical parts if needed
6. **No cheating**: Do not exit without writing meaningful documentation
7. **Trust the process**: Codex's feedback helps improve documentation quality

## Stopping the Loop

- Reach the maximum iteration count
- Codex confirms completion with "COMPLETE" (documentation is reconstruction-ready)
- User runs `/humanize:cancel-dccb-loop`
