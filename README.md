# Multi-Agent Orchestration Workflow

> **Production-grade multi-agent pipeline for Orca IDE** — take a user request from requirements through to a merged PR, with wave-parallel execution, cross-agent review, human-in-the-loop fallbacks, and full audit trail.

**English** | [简体中文](./README.zh-CN.md)

[![Skill Version](https://img.shields.io/badge/skill-v2.2.2-blue)](./SKILL.md)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![Orca](https://img.shields.io/badge/runtime-Orca%20IDE-orange)](https://orca.app)

---

## What It Does

This skill implements a **complete 8-phase workflow** that coordinates multiple AI agents to deliver complex software tasks:

```
User Request → Clarify → Plan → Review → Confirm → Execute (wave-parallel) → Decide → Rebase + Tests + Integration Review → PR → Cleanup
```

### Key Features

- **🔄 Full Lifecycle**: Requirements → Plan → Execute → Review → Integration Review → Merge → Cleanup
- **🌳 One Worktree Per Feature (v2.2.0)**: the whole feature lives on a single `feature/<slug>` branch in one worktree based on `origin/main`. The coordinator never leaves `main` (no `git checkout`, ever), and the run ends with exactly **one PR**
- **🧩 Owns-Based Parallel Safety (v2.2.0)**: every sub-task declares the files/dirs it `owns`; same-wave sub-tasks must have **disjoint ownership**, validated during plan review. Parallel-write safety comes from disjoint write sets, not filesystem isolation
- **🌊 Wave Dispatch (v2.2.0)**: dependencies map to serial waves — a sub-task is dispatched only after all its parents pass, and sees their committed code naturally in the shared worktree
- **🆕 Fresh Agent Per Round**: implementation, cross-review, and fix each run in a **fresh terminal** — no Agent context reuse, no carry-over bias
- **🧑‍⚖️ Scoped Cross-Agent Review**: reviews use a different Agent (`pi`) than implementation (`claude`/`kimi`), per `docs/agent-routing.md`, and each review is scoped to the sub-task's own commit range (`base_sha..HEAD`) within its `owns`
- **🔬 Integration Review (v2.2.0)**: a fresh review agent audits the *whole* feature — plan, per-sub-task verdicts, test results, full diff vs `origin/main` — before the PR is opened
- **🛡️ Hard Cycle Caps**: every loop has a maximum iteration count — no infinite retries
- **👤 Human-in-the-Loop**: escalation at plan-review, decision, and merge boundaries; **only a human merges the PR**
- **📉 Degrade-or-Park**: failed sub-tasks get their commit ranges surgically reverted in the feature worktree (clean because `owns` are disjoint) for a degraded release; if the revert is unclean, the whole feature is parked with a recovery manifest
- **🔍 Full Audit Trail**: every decision, terminal spawn, verdict, and PR transition is logged to `.orca/workflow-state.json`
- **🔒 Single PR, Human-Only Merge**: no direct `git merge` — one PR per feature, monitored by the coordinator, merged by a human

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
# 1. Navigate to your project checkout — it must be Orca-managed.
#    The coordinator stays on the main branch for the entire run.
cd /path/to/project

# 2. Run the pre-flight checks
/path/to/multi-agent-workflow/scripts/check-prerequisites.sh

# 3. Open the checkout in Orca and describe the task to the coordinator
#    agent in the main checkout's chat, e.g.:
#    "Add a /health endpoint to the API, with tests."
```

The skill drives every `orca` command itself — worktree creation, wave dispatch, reviews, the PR — and prompts you at each human checkpoint, starting with requirements gathering.

> Aside: Orca's native `orca orchestration run --spec <text>` coordinator loop exists as an alternative entrypoint, but the chat-driven flow above is the recommended path.

---

## Architecture (v2.2.0)

```
┌──────────────────────────────────────────────────────────────────┐
│                COORDINATOR (This Agent — always on main)         │
│  Phase 1 Gather → Phase 2 Plan+Review → Phase 3 Confirm          │
│  Phase 4: create ONE feature worktree (feature/<slug> off        │
│           origin/main) → decompose DAG → dispatch wave 0         │
│                              │                                   │
│        ┌─────────────────────▼────────────────────────┐          │
│        │          FEATURE WORKTREE (shared)           │          │
│        │  Wave 0: sub-A (owns: api/**) ∥ sub-B (ui/**)│          │
│        │  Wave 1: sub-C  ← runs after deps PASS       │          │
│        │  per sub-task, per round, FRESH terminals:   │          │
│        │    exec (small commits) → cross-review       │          │
│        │    (base_sha..HEAD, within owns) → fix → …   │          │
│        └─────────────────────┬────────────────────────┘          │
│  Phase 6 ← collect verdicts: retry / degrade / park              │
│  Phase 7: rebase origin/main → tests → INTEGRATION               │
│           REVIEW (fresh agent, whole-feature diff) → ONE PR      │
│           → human reviews & merges the PR                        │
│  Phase 8: delete branch, remove worktree, close terminals        │
│           (or park: .orca/parked/<feature-slug>.md)              │
└──────────────────────────────────────────────────────────────────┘
```

### State Machine

8 phases with a per-wave sub-task subgraph under `DISPATCHING` / `EXECUTING` and a whole-feature subgraph under `MERGING` / `CLEANING`. Terminal exits: plan non-convergence, user rejection/abort, feature failure (PARKED is recoverable).

See [`docs/workflow.md`](./docs/workflow.md) for the full Mermaid diagram.

---

## Phases

| # | Phase | What Happens | Key Command |
|---|-------|-------------|-------------|
| 1 | **Gathering** | Clarify requirements with the user via the coordinator's native channel (≤5 rounds) | native user interaction |
| 2 | **Planning** | Generate technical plan; a separate review task returns its verdict via `worker_done` (max 3 rounds + 2 escalations) | `task-create` + `dispatch --inject` |
| 3 | **Confirming** | User approves the plan (max 3 rounds; Abort stops immediately) | native user interaction |
| 4 | **Dispatching** | Create the ONE feature worktree + branch off `origin/main`, compute waves from the DAG, dispatch wave 0 | `worktree create --base-branch origin/main` + `terminal create` + `task-create` + `dispatch --inject` |
| 5 | **Executing** | Per-round fresh terminals: exec/fix agents commit in small commits; cross-review is scoped to `base_sha..HEAD` within the sub-task's `owns` | `terminal create` + `dispatch --inject` + `check --wait` |
| 6 | **Deciding** | Collect verdicts; user chooses retry (max 2) / degrade (revert failed commit ranges) / abort | `task-list` + native user interaction |
| 7 | **Merging** | Rebase onto `origin/main` (autofix ≤2), run tests, **integration review** by a fresh agent (≤2 rounds), then ONE PR; human merges | `git rebase` + `gh pr create` + `gh pr view` |
| 8 | **Cleaning** | Per-feature cleanup: delete branch, remove worktree, close `keep_terminal`; or write `.orca/parked/<feature-slug>.md` | `worktree rm` + `terminal close` |

---

## Configuration

All parameters are tunable via environment variables:

```bash
export ORCA_WORKFLOW_MAX_REVIEW_ROUNDS=3       # Plan review retries
export ORCA_WORKFLOW_MAX_ESCALATE=2            # Human escalations before terminate
export ORCA_WORKFLOW_MAX_USER_CONFIRM=3        # User confirmation retries
export ORCA_WORKFLOW_MAX_SUB_RETRY=3           # Per-sub-task execution/fix retries
export ORCA_WORKFLOW_MAX_GLOBAL_RETRY=2        # Failed-batch retry rounds
export ORCA_WORKFLOW_MAX_AUTOFIX=2             # Auto conflict-resolution attempts during rebase
export ORCA_WORKFLOW_MAX_INTEGRATION_REVIEW=2  # Integration review rounds (new in v2.2.0)
export ORCA_WORKFLOW_STRICT_PREREQ=false       # Treat missing prereqs as fatal when true
export ORCA_WORKFLOW_DRY_RUN=false             # Plan-only mode, no dispatches
```

See [`SKILL.md`](./SKILL.md) for the full configuration reference.

---

## Project Structure

```
multi-agent-workflow/
├── SKILL.md                          # The skill definition (this is what Orca loads)
├── README.md                         # This file
├── README.zh-CN.md                   # 简体中文版的 README
├── CHANGELOG.md                      # Version history
├── LICENSE                           # MIT license
├── docs/
│   ├── workflow.md                   # Mermaid flowchart (full state diagram)
│   └── agent-routing.md              # Single source of truth for agent routing
├── references/
│   ├── phase-1-gathering.md          # Phase 1 full procedure (extracted from SKILL.md §5)
│   ├── phase-2-planning.md           # Phase 2 full procedure (extracted from SKILL.md §6)
│   ├── phase-3-confirming.md         # Phase 3 full procedure (extracted from SKILL.md §7)
│   ├── phase-4-dispatching.md        # Phase 4 full procedure (extracted from SKILL.md §8)
│   ├── phase-5-executing.md          # Phase 5 full procedure (extracted from SKILL.md §9)
│   ├── phase-6-deciding.md           # Phase 6 full procedure (extracted from SKILL.md §10)
│   ├── phase-7-merging.md            # Phase 7 full procedure (extracted from SKILL.md §11)
│   ├── phase-8-cleaning.md           # Phase 8 full procedure (extracted from SKILL.md §12)
│   ├── observability.md              # State file, log levels, metrics (from SKILL.md §13)
│   ├── runbooks.md                   # Testing & operational runbooks (from SKILL.md §16–§17)
│   └── api-reference.md              # Orca CLI command reference (from SKILL.md §18)
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
| [`SKILL.md`](./SKILL.md) | Full skill definition (reference material split into `references/`) |
| [`docs/workflow.md`](./docs/workflow.md) | Complete Mermaid state diagram and state transition table |
| [`references/`](./references) | On-demand reference docs: full per-phase procedures (phase-1..8), observability, testing/runbooks, API command reference |
| [`examples/basic-workflow.md`](./examples/basic-workflow.md) | Step-by-step walkthrough |

---

## Recovery

### After a Crash

```bash
# Load saved state
cat .orca/workflow-state.json | jq '.current_phase'

# Recover based on phase
# (see references/runbooks.md for detailed recovery procedures)
```

### After Parking

```bash
# Each parked feature leaves one manifest
ls .orca/parked/

# Read recovery instructions
cat .orca/parked/<feature-slug>.md
```

---

## License

MIT © 2026 — See [LICENSE](./LICENSE) for details.
