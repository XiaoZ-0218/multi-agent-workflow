# Multi-Agent Orchestration Workflow

> **Production-grade multi-agent pipeline for Orca IDE** — take a user request from requirements through to merged PR, with parallel execution, review gates, human-in-the-loop fallbacks, and full audit trail.

[![Skill Version](https://img.shields.io/badge/skill-v2.1.0-blue)](./SKILL.md)
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
- **🌳 Per-Sub-Task Worktrees (v2.1.0)**: each feature/fix gets its own branch + worktree — no cross-task contention, clean per-task diffs, individually mergeable PRs
- **🔗 Stacked Branches (v2.1.0)**: dependent sub-tasks branch off parent tips (not `main`), preserving parallelism; auto-rebase onto `main` when the parent PR merges
- **🆕 Fresh Agent Per Round (v2.1.0)**: implementation, cross-review, and fix each run in a **fresh terminal** — no Agent context reuse, no carry-over bias
- **🧑‍⚖️ Cross-Agent Review**: reviews use a different Agent (`pi`) than implementation (`claude`/`kimi`), per `docs/agent-routing.md`
- **🛡️ Hard Cycle Caps**: Every loop has a maximum iteration count — no infinite retries
- **👤 Human-in-the-Loop**: Escalation at plan-review and per-sub-task merge-conflict boundaries only
- **📉 Degraded Delivery**: When retries exhaust, completed sub-tasks ship independently; failed sub-tasks get per-sub-task parked manifests
- **🔍 Full Audit Trail**: Every decision, gate, terminal spawn, and PR transition is logged to `.orca/workflow-state.json` (with `subtask_id` scope since v2.1.0)
- **🔒 PR-Only Merge**: No direct `git merge` — each sub-task integrates through its own PR; dependent PRs flip base to `main` via the §11.8 stacked-PR rebase hook

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

## Architecture (v2.1.0)

```
┌──────────────────────────────────────────────────────────────────┐
│                     COORDINATOR (This Agent)                      │
│  Phase 1 → Phase 2 → Phase 3 → Phase 4 (per-sub-task worktrees)  │
│                                      │                            │
│                              ┌───────┼─────────┐                  │
│                              │  Sub-1 wt+br  Sub-2 wt+br         │
│                              │  base=main    base=sub-1           │
│                              │  ↓            ↓                   │
│                              │  exec₀        exec₀                │
│                              │  review₁      review₁              │
│                              │  fix₂         done                 │
│                              │  review₃                            │
│                              └───────┬─────────┘                  │
│  Phase 6 ← Collect (all verdicts) ┘                              │
│  Phase 7 (per-sub-task PR, topo order) → §11.8 stacked rebase    │
│  Phase 8 (per-sub-task cleanup, reverse-topo) → Done              │
└──────────────────────────────────────────────────────────────────┘
```

### State Machine

8 phases with per-sub-task subgraph under `DISPATCHING` / `EXECUTING` / `MERGING` / `CLEANING`. Terminal exits: plan non-convergence, user rejection, sub-task failure (per-sub-task PARKED is recoverable).

See [`docs/workflow.md`](./docs/workflow.md) for the full Mermaid diagram.

---

## Phases

| # | Phase | What Happens | Key Command |
|---|-------|-------------|-------------|
| 1 | **Gathering** | Clarify requirements with the user | `orca orchestration ask` |
| 2 | **Planning** | Generate technical plan, review it (max 3 rounds) | `task-create` + `dispatch` + `gate-create` |
| 3 | **Confirming** | User approves the plan (max 3 rounds) | `orca orchestration ask` |
| 4 | **Dispatching** | **Per-sub-task**: create wt+branch (stacked on parent or main), spawn fresh execution terminal | `worktree create` + `terminal create` + `task-create` + `dispatch` |
| 5 | **Executing** | **Per-round cross-review**: round > 0 spawns fresh fix + review terminals | `terminal create` + `dispatch` + `terminal close` |
| 6 | **Deciding** | Collect all per-sub-task verdicts, decide retry / degrade / escalate | `task-list` + `ask` |
| 7 | **Merging** | **Per-sub-task PR** in topo order; §11.8 stacked-PR rebase hook flips dependent PRs to `main` after parent merges | `gh pr create` + `gh pr edit --base` + `gate-create` |
| 8 | **Cleaning** | **Per-sub-task** reverse-topo cleanup: delete branch, remove worktree, close `keep_terminal`, write per-sub-task park manifest if needed | `worktree remove` + `terminal close` |

---

## Configuration

All parameters are tunable via environment variables:

```bash
export ORCA_WORKFLOW_MAX_REVIEW_ROUNDS=3      # Plan review retries
export ORCA_WORKFLOW_MAX_ESCALATE=2           # Human escalations before terminate
export ORCA_WORKFLOW_MAX_USER_CONFIRM=3        # User confirmation retries
export ORCA_WORKFLOW_MAX_SUB_RETRY=3           # Per-sub-task cross-review rounds
export ORCA_WORKFLOW_MAX_GLOBAL_RETRY=2        # Full-batch retry rounds
export ORCA_WORKFLOW_MAX_AUTOFIX=2             # Auto conflict-resolution attempts (per-sub-task, in §11.4 / §11.8)

# v2.1.0 — branch strategy & per-role terminals
export ORCA_WORKFLOW_BRANCH_STRATEGY=stacked              # stacked | serial (default stacked)
export ORCA_WORKFLOW_BRANCH_TEMPLATE='feature/{workflow_slug}/{sub_slug}-{timestamp}'
export ORCA_WORKFLOW_WORKTREE_PATH_TEMPLATE='../{workflow_slug}-{sub_slug}'
export ORCA_WORKFLOW_MAX_TERMINALS_PER_SUBTASK=8          # hard cap on review+fix terminal count
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
