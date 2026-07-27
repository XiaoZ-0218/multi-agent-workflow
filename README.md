# Multi-Agent Orchestration Workflow

> **Production-grade multi-agent pipeline for Orca IDE** — take a user request from requirements through to merged PR, with parallel execution, review gates, human-in-the-loop fallbacks, and full audit trail.

[![Skill Version](https://img.shields.io/badge/skill-v2.0.0-blue)](./SKILL.md)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![Orca](https://img.shields.io/badge/runtime-Orca%20IDE-orange)](https://orca.app)

---

## What It Does

This skill implements a **complete 8-phase workflow** that coordinates multiple AI agents to deliver complex software tasks:

```
User Request → Clarify → Plan → Review → Confirm → Execute (parallel) → Decide → PR → Merge → Archive
```

### Key Features

- **🔄 Full Lifecycle**: Requirements → Plan → Execute → Review → Merge → Cleanup
- **🔀 Parallel Execution**: Multiple subtasks run simultaneously with internal retry loops
- **🛡️ Hard Cycle Caps**: Every loop has a maximum iteration count — no infinite retries
- **👤 Human-in-the-Loop**: Escalation at plan-review and merge-conflict boundaries only
- **📉 Degraded Delivery**: When retries exhaust, completed artifacts are delivered; failures are flagged
- **🔍 Full Audit Trail**: Every decision, gate, and transition is logged to `.orca/workflow-state.json`
- **🔒 PR-Only Merge**: No direct `git merge` — all integrations go through pull requests

---

## Quick Start

### Prerequisites

- [Orca IDE](https://orca.app) running
- Git ≥ 2.30
- GitHub CLI (`gh`) ≥ 2.0
- `jq` ≥ 1.6

### Installation

```bash
# Clone into your workspace
cd ~/workspace
git clone https://github.com/your-org/multi-agent-workflow.git

# Or copy the SKILL.md into your project
cp SKILL.md /path/to/your/project/
```

### Usage

```bash
# 1. Navigate to your project worktree
cd /path/to/project

# 2. Write your task to a markdown spec file
cat > /tmp/task.md <<'EOF'
# <Title>

## Goal
...

## Scope
...

## Acceptance Criteria
...
EOF

# 3. Start the workflow (the coordinator will guide you through each phase)
orca orchestration run --spec /tmp/task.md
```

The coordinator agent will prompt you through each phase — starting with requirements gathering.

---

## Architecture

```
┌──────────────────────────────────────────────┐
│               COORDINATOR                     │
│  Phase 1 → Phase 2 → Phase 3 → Phase 4       │
│  Gather    Plan+Rev  Confirm   Dispatch       │
│                                      │        │
│                         ┌────────────┼────┐   │
│                         │   WORKERS (parallel)│
│                         │  Sub-1  Sub-2  Sub-3│
│                         │  +Review +Review    │
│                         └────────────┼────┘   │
│  Phase 6 ← Collect All ←────────────┘        │
│  Decide                                       │
│     │                                         │
│  Phase 7 → Phase 8 → Done                    │
│  PR/Merge  Cleanup                            │
└──────────────────────────────────────────────┘
```

### State Machine

8 states with defined transitions, 3 terminal exits (plan non-convergence, user rejection, subtask failure), degraded delivery path, and parked-workflow archiving.

See [`docs/workflow.md`](./docs/workflow.md) for the full Mermaid diagram.

---

## Phases

| # | Phase | What Happens | Key Command |
|---|-------|-------------|-------------|
| 1 | **Gathering** | Clarify requirements with the user | `orca orchestration ask` |
| 2 | **Planning** | Generate technical plan, review it (max 3 rounds) | `task-create` + `dispatch` + `gate-create` |
| 3 | **Confirming** | User approves the plan (max 3 rounds) | `orca orchestration ask` |
| 4 | **Dispatching** | Decompose into subtask DAG, create worktree, dispatch | `task-create` + `dispatch` |
| 5 | **Executing** | Workers run in parallel with internal retry (max 3) | Workers self-manage |
| 6 | **Deciding** | Collect all results, decide: retry / degrade / escalate | `task-list` + `ask` |
| 7 | **Merging** | Check conflicts, create PR, monitor until merge | `gh pr create` + `gate-create` |
| 8 | **Cleaning** | Remove worktree, archive, notify user | `orca worktree remove` |

---

## Configuration

All parameters are tunable via environment variables:

```bash
export ORCA_WORKFLOW_MAX_REVIEW_ROUNDS=3      # Plan review retries
export ORCA_WORKFLOW_MAX_ESCALATE=2           # Human escalations before terminate
export ORCA_WORKFLOW_MAX_USER_CONFIRM=3        # User confirmation retries
export ORCA_WORKFLOW_MAX_SUB_RETRY=3           # Per-subtask retries
export ORCA_WORKFLOW_MAX_GLOBAL_RETRY=2        # Full-batch retry rounds
export ORCA_WORKFLOW_MAX_AUTOFIX=2             # Auto conflict-resolution attempts
```

See [`SKILL.md#4-configuration`](./SKILL.md#4-configuration) for the full configuration reference.

---

## Project Structure

```
multi-agent-workflow/
├── SKILL.md                          # The skill definition (this is what Orca loads)
├── README.md                         # This file
├── CHANGELOG.md                      # Version history
├── LICENSE                           # MIT license
├── docs/
│   ├── workflow.md                   # Mermaid flowchart (full state diagram)
│   └── agent-routing.md              # Single source of truth for agent routing
├── examples/
│   └── basic-workflow.md             # Annotated walkthrough of a complete run
├── .orca/
│   ├── workflow-config.json          # Project-local default configuration
│   └── workflow-state.schema.json    # JSON Schema for the state file
└── scripts/
    └── check-prerequisites.sh        # Pre-flight validation script
```

---

## Documentation

| Document | Description |
|----------|-------------|
| [`SKILL.md`](./SKILL.md) | Full skill definition and API reference (18 sections) |
| [`docs/workflow.md`](./docs/workflow.md) | Complete Mermaid state diagram |
| [`examples/basic-workflow.md`](./examples/basic-workflow.md) | Step-by-step walkthrough |

---

## Recovery

### After a Crash

```bash
# Load saved state
cat .orca/workflow-state.json | jq '.current_phase'

# Recover based on phase
# (see SKILL.md §17.3 for detailed recovery procedures)
```

### After Parking

```bash
# Find parked task
ls .orca/parked/

# Read recovery instructions
cat .orca/parked/feature-*.md
```

---

## License

MIT © 2026 — See [LICENSE](./LICENSE) for details.
