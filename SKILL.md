---
name: multi-agent-workflow
version: 2.2.0
author: orca-workflow-team
tags: [orchestration, multi-agent, workflow, supervisor, cicd]
description: >
  Production-grade multi-agent orchestration workflow for Orca IDE.
  Implements a full lifecycle pipeline: requirements gathering → plan generation
  & review → user confirmation → task decomposition → wave-dispatched parallel
  execution with cross-review → result aggregation & decision → integration
  review & single-PR merge → archival. One user request = one feature = ONE
  worktree + ONE branch (`feature/<slug>`, based on `origin/main`) + ONE PR;
  subtasks share the feature worktree and are kept apart by declared `owns`
  path ownership, not by filesystem isolation. Built on `orca orchestration`
  primitives (task-create, dispatch, check, ask) with hard cycle caps,
  human-in-the-loop fallbacks, degraded-delivery exits, and full observability.
  Invoke this skill whenever the user needs to decompose a complex task across
  multiple agents, coordinate parallel workstreams, or execute a structured
  development pipeline from spec to merge.
applyTo: "**/*"
---

# Multi-Agent Orchestration Workflow — Production Skill

> **Version**: 2.2.0 &ensp;|&ensp; **Runtime**: Orca IDE ≥ 1.x &ensp;|&ensp; **License**: MIT
>
> Reference flowchart: [`docs/workflow.md`](./docs/workflow.md)

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [State Machine](#2-state-machine)
3. [Prerequisites & Environment](#3-prerequisites--environment)
4. [Configuration](#4-configuration)
5. [Phase 1 — Requirements Gathering](#5-phase-1--requirements-gathering)
6. [Phase 2 — Plan Generation & Review](#6-phase-2--plan-generation--review)
7. [Phase 3 — User Confirmation](#7-phase-3--user-confirmation)
8. [Phase 4 — Task Decomposition & Dispatch](#8-phase-4--task-decomposition--dispatch)
9. [Phase 5 — Parallel Execution & Sub-Review](#9-phase-5--parallel-execution--sub-review)
10. [Phase 6 — Aggregation & Decision](#10-phase-6--aggregation--decision)
11. [Phase 7 — Merge & Pull Request](#11-phase-7--merge--pull-request)
12. [Phase 8 — Cleanup & Archival](#12-phase-8--cleanup--archival)
13. [Observability & Logging](#13-observability--logging)
14. [Error Recovery Matrix](#14-error-recovery-matrix)
15. [Security & Permission Model](#15-security--permission-model)
16. [Testing & Validation](#16-testing--validation)
17. [Operational Runbooks](#17-operational-runbooks)
18. [API Command Reference](#18-api-command-reference)

---

## 1. Architecture Overview

The coordinator **stays on the main branch for the entire run**. It never runs
`git checkout`; its only git operations in its own checkout are `git fetch
origin` (and optionally `git pull --ff-only`). All implementation work happens
in **one** feature worktree created in Phase 4.

```
┌───────────────────────────────────────────────────────────────────────┐
│               COORDINATOR (This Agent — stays on main)                 │
│                                                                        │
│  ┌─────────┐  ┌──────────┐  ┌──────────┐  ┌────────────────────────┐  │
│  │ Phase 1 │→│ Phase 2  │→│ Phase 3  │→│        Phase 4         │  │
│  │ Gather  │  │ Plan+Rev │  │ Confirm  │  │ git fetch origin main │  │
│  └─────────┘  └──────────┘  └──────────┘  │ create ONE worktree   │  │
│                                            │ decompose → dispatch  │  │
│                                            │ wave 0                │  │
│                                            └───────────┬────────────┘  │
│                                                        │               │
│     ONE FEATURE WORKTREE   feature/<slug>   (base: origin/main)        │
│     ┌──────────────────────────────────────────────────┼───────────┐   │
│     │ Wave 0  (parallel, disjoint owns)                ▼           │   │
│     │   sub-1: [exec r0]→[review r0]→[fix r1]→[review r1] → PASS   │   │
│     │   sub-2: [exec r0]→[review r0]─────────────────────→ PASS    │   │
│     │          each […] = FRESH terminal + NEW task                │   │
│     │ Wave 1  (dispatched only after ALL parents PASS)             │   │
│     │   sub-3: sees parents' committed code in the same worktree   │   │
│     └──────────────────────────────────────────────────┬───────────┘   │
│  ┌──────────┐  ┌───────────────────────────────────────┘           │   │
│  │ Phase 6  │←│ collect every subtask verdict (PASS/FAIL)          │   │
│  │ Decide   │  └───────────────────────────────────────────────────┘   │
│  └────┬─────┘                                                          │
│  ┌────┴─────────────────────────────────────────────────────────────┐  │
│  │ Phase 7 (inside the feature worktree):                            │  │
│  │   rebase origin/main → autofix ≤2 → run tests →                   │  │
│  │   INTEGRATION REVIEW (fresh review terminal, ≤2 rounds) →         │  │
│  │   gh pr create (ONE PR) → poll gh pr view every 60s               │  │
│  └────┬──────────────────────────────────────────────────────────────┘  │
│  ┌────┴─────┐   ┌────────────────┐   ┌───────────┐                      │
│  │ Phase 8  │→ │ history.jsonl  │→ │  Notify   │  afterwards:          │
│  │ Cleanup  │   │ + park manifest│   │  User     │  git fetch only —    │
│  └──────────┘   └────────────────┘   └───────────┘  never checkout     │
└───────────────────────────────────────────────────────────────────────┘
```

### v2.2.0 — What's Different from v2.1.0

| Aspect | v2.1.0 | v2.2.0 |
|--------|--------|--------|
| Worktree | One per sub-task | **One per feature**: `feature/<slug>` based on `origin/main`; subtasks share it |
| Branches | Stacked — dependents branch off parent tips | **One feature branch**; dependencies mean serial waves, not stacked branches |
| PRs | One per sub-task; dependents start as draft | **One PR** for the whole feature, created at the end |
| Stacked-PR rebase hook (v2.1.0 §11.8) | Present | **Removed** — no stacked PRs exist to rebase |
| Parallelism safety | Filesystem isolation (one `git worktree` per sub-task) | **`owns` path globs** per subtask + disjointness validation at plan review; coordinator verifies `git status`/`git diff` after every round |
| Dispatch | All sub-tasks created up front in topo order | **Wave dispatch**: a subtask runs only after ALL its parents have `verdict=PASS`, seeing their committed code in the shared worktree |
| Review scope | Latest files in the sub-task's worktree | **`git diff <base_sha>..HEAD`** limited to the subtask's `owns`; execution/fix agents commit in small commits |
| Pre-PR quality gate | — | **NEW: integration review** — a fresh review-agent terminal reviews the whole feature (`plan + verdicts + tests + git diff origin/main...HEAD`) before `gh pr create`, ≤ 2 rounds |
| Branch/path templates | `ORCA_WORKFLOW_BRANCH_STRATEGY`, `ORCA_WORKFLOW_BRANCH_TEMPLATE`, `ORCA_WORKFLOW_WORKTREE_PATH_TEMPLATE` | **Removed** — the branch is always `feature/<slug>`; the worktree path comes from `orca worktree create`'s JSON result |
| Config vars | `ORCA_WORKFLOW_MAX_TERMINALS_PER_SUBTASK`, `ORCA_WORKFLOW_MIN_WORKERS` | **Removed**; **added** `ORCA_WORKFLOW_MAX_INTEGRATION_REVIEW=2` |
| Coordinator git | `git checkout main` during cleanup | **Never checks out** — `git fetch origin` only |
| Kept | — | Fresh terminal per round, cross-agent review (reviewer ≠ implementer), hard caps on every loop, collect-all-then-decide, park/degrade exits |

### Design Principles

| Principle | Implementation |
|-----------|---------------|
| **One Feature = One Worktree, One Branch, One PR** | Each user request produces exactly one `feature/<slug>` worktree + branch based on `origin/main`, and exactly one PR. No per-subtask worktrees, no stacked branches, no draft/per-subtask PRs. |
| **Isolation by Ownership Convention (honest model)** | Subtasks share the feature worktree. Parallel safety comes from each subtask declaring `owns` (file/dir globs); same-wave subtasks must have **disjoint** `owns`, validated during plan review. The coordinator enforces the convention after each round via `git status`/`git diff` checks and reverts any out-of-`owns` writes. This is a coordinator-enforced convention — **not** a filesystem sandbox. |
| **Wave Dispatch** | Subtasks whose deps are all PASS run in parallel (one wave); a dependent subtask is dispatched only after ALL its parents PASS, and sees their committed code naturally in the shared worktree. |
| **Per-Round Fresh Agent** | Every execution, fix, review, fallback, autofix, pr-fix, and integration-review round is a separate `orca terminal create` + a **new** task (chained with `--parent`). A task is never re-dispatched — Orca circuit-breaks a task after 3 consecutive failures. |
| **Cross-Agent Review** | The review agent is never the implementation agent (see `docs/agent-routing.md`). Review is read-only and scoped to `<base_sha>..HEAD` within the subtask's `owns`. |
| **Fail-Safe by Default** | Every loop has a hard cap; no infinite retries. |
| **Human-in-the-Loop at High-Value Gates** | User decisions at plan escalation, confirmation, subtask-failure handling, autofix exhaustion, and integration-review exhaustion — always via the coordinator's **native** user-interaction channel, never `orca orchestration ask --to coordinator`. |
| **Collect-All-Then-Decide** | A subtask failure does NOT interrupt its siblings; all verdicts aggregate before the global retry/degrade/abort decision. |
| **Single PR + No Direct Merge** | The workflow never runs `git merge`; the feature integrates through one PR; only a human merges. |
| **Immutable Audit Trail** | Every decision, terminal spawn, and state transition is written to `.orca/workflow-state.json` via jq atomic writes (tmp file + `mv`), never `>>`. |
| **Degraded Delivery over Total Failure** | When retries are exhausted, the coordinator reverts each failed subtask's commit range (clean because `owns` are disjoint) and ships the rest with a ⚠️ degraded banner. |

---

## 2. State Machine

v2.2.0 adds `INIT` to the `current_phase`/`current_state` enums, makes
`EXECUTING` **wave-based** (waves are topological levels of the subtask DAG),
gives `MERGING` explicit sub-steps (rebase → autofix → tests → integration
review → PR monitor), and makes `PARKED` a **feature-level** state (the whole
feature is parked, never an individual subtask).

```
                    ┌─────────┐
                    │  INIT   │
                    └────┬────┘
                         ▼
                  ┌───────────┐          ┌──────────────┐
                  │ GATHERING │          │ TERMINATED   │
                  │ (Phase 1) │          │ (any phase)  │
                  └─────┬─────┘          └──────────────┘
                        ▼
                  ┌───────────┐  review FAIL ≤3 rounds / escalate ≤2
                  │ PLANNING  │◄──────────────────────────┐
                  │ (Phase 2) │                           │
                  └─────┬─────┘                           │
                        ▼ review PASS (worker_done)       │
                  ┌───────────┐   Revise ─────────────────┘
                  │CONFIRMING │   Abort (any round) ──► TERMINATED (immediate)
                  │ (Phase 3) │
                  └─────┬─────┘   Approve
                        ▼
                  ┌────────────┐
                  │DISPATCHING │ fetch origin main → create ONE worktree
                  │ (Phase 4)  │ → decompose DAG → dispatch wave 0
                  └─────┬──────┘◄─────────────┐
                        ▼                     │
            ┌───────────────────────────┐     │
            │ EXECUTING (wave-based)    │     │
            │  wave k: subtasks whose   │     │
            │  parents all PASS run in  │     │
            │  parallel (disjoint owns) │     │
            │  per subtask:             │     │
            │   rounds 0..MAX_SUB_RETRY │     │
            │   exec/fix → cross-review │     │
            │   PASS → done             │     │
            │   final-round FAIL →      │     │
            │   verdict=FAIL (siblings  │     │
            │   continue)               │     │
            └─────────────┬─────────────┘     │
                          ▼ all verdicts in   │
                  ┌───────────┐               │
                  │ DECIDING  │ all PASS ────────────────► MERGING
                  │ (Phase 6) │ retry failed only ────────┘
                  │           │   (global_retries_used < 2 checked BEFORE increment)
                  │           │ degrade: revert failed commit ranges ──► MERGING
                  │           │   └─ revert unclean ──► PARKED (whole feature)
                  │           │ abort ──► TERMINATED
                  └───────────┘
                        ▼
            ┌──────────────────────────────────┐
            │ MERGING (Phase 7, feature-level) │
            │  rebase origin/main              │
            │  autofix ≤2 ── exhausted ──► human: manual resolve / PARKED
            │  run tests (record results)      │
            │  integration review ≤2 ── exhausted ──► human: release / PARKED
            │  gh pr create → poll every 60s   │
            │  MERGED ──► CLEANING             │
            │  CLOSED ──► PARKED               │
            └─────────────┬────────────────────┘
                          ▼
                  ┌───────────┐   MERGED ──► DONE
                  │ CLEANING  │   PARKED ──► manifest written,
                  │ (Phase 8) │              worktree+branch kept
                  └───────────┘
```

### State Transition Table

| From | Trigger | To | Guard |
|------|---------|----|-------|
| `INIT` | User request received | `GATHERING` | — |
| `GATHERING` | Requirements clear | `PLANNING` | Gap checklist (§5.3) satisfied |
| `GATHERING` | Clarification rounds exhausted | `TERMINATED` | > 5 rounds |
| `PLANNING` | Plan review PASS | `CONFIRMING` | Verdict arrives via `worker_done` from the review task — never `gate-create` |
| `PLANNING` | Review rounds exhausted + escalate ≤ 2 | `PLANNING` | Human direction resets the review counter |
| `PLANNING` | Escalate count > 2 | `TERMINATED` | Terminate1 |
| `CONFIRMING` | User approves | `DISPATCHING` | — |
| `CONFIRMING` | User revises (rounds < 3) | `PLANNING` | Feedback collected |
| `CONFIRMING` | User aborts | `TERMINATED` | **Immediate, at any round** (no off-by-one) |
| `CONFIRMING` | Rounds ≥ 3 without approval | `PLANNING` or `TERMINATED` | Forced user decision |
| `DISPATCHING` | Worktree created + wave 0 dispatched | `EXECUTING` | — |
| `DISPATCHING` | Worktree creation failed (infra) | `TERMINATED` | Coordinator-side failure only |
| `EXECUTING` (wave k) | All wave-k subtasks PASS | `EXECUTING` (wave k+1) | Next wave dispatched; skip subtasks whose parents FAILED |
| `EXECUTING`.sub-N | Cross-review PASS | subtask done | `verdict=PASS` recorded |
| `EXECUTING`.sub-N | Final round's review still FAIL | subtask `verdict=FAIL` | Siblings continue |
| `EXECUTING` | All dispatched subtasks have a verdict | `DECIDING` | — |
| `DECIDING` | All PASS | `MERGING` | — |
| `DECIDING` | Retry failed subtasks only | `DISPATCHING` | `global_retries_used < MAX_GLOBAL_RETRY` checked **before** incrementing → at most 2 retries |
| `DECIDING` | Degrade | `MERGING` | Coordinator reverts each failed subtask's commit range; `delivery_mode=degraded` |
| `DECIDING` | Degrade revert unclean | `PARKED` | Whole feature parked |
| `DECIDING` | Abort | `TERMINATED` | Terminate3 |
| `MERGING` | Rebase clean + tests recorded + integration review PASS + PR created | `MERGING` (monitor) | Poll `gh pr view` every 60s |
| `MERGING` | Autofix exhausted | human decision | Manual resolve or `PARKED` |
| `MERGING` | Integration review exhausted | human decision | Release anyway or `PARKED` |
| `MERGING` | PR MERGED | `CLEANING` | — |
| `MERGING` | PR CLOSED | `PARKED` | Keep worktree + branch |
| `CLEANING` | Merged path: branch deleted, worktree removed, terminals closed | `DONE` | — |
| `CLEANING` | Parked path: manifest written, worktree kept | `PARKED` | Recoverable |
| any | Fatal coordinator error / user abort | `TERMINATED` | State persisted first |

---

## 3. Prerequisites & Environment

### 3.1 Runtime Checks

```bash
# 1. Verify Orca is running and reachable
orca status --json | jq -e '.ok and .result.app.running and .result.runtime.reachable' \
  || { echo "FATAL: Orca is not running or unreachable"; exit 1; }

# 2. Verify the coordinator is inside an Orca-managed checkout (NEW in v2.2.0)
#    The coordinator lives in the main checkout for the whole run; the feature
#    worktree is created later by `orca worktree create`.
orca worktree current --json | jq -e '.result.worktree.id' >/dev/null \
  || { echo "FATAL: coordinator is not inside an Orca-managed checkout"; exit 1; }

#    Warn if the coordinator's checkout is not on main — it must stay on main.
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "main" ]; then
  echo "WARN: current branch is '$CURRENT_BRANCH', expected 'main' — the coordinator never checks out; start from main."
fi

# 3. Verify required tools
for tool in git gh jq; do
  command -v "$tool" >/dev/null || { echo "FATAL: $tool not found"; exit 1; }
done

# 4. Verify the main checkout is clean (WARN only — feature work happens elsewhere)
git diff --quiet && git diff --cached --quiet \
  || { echo "WARN: Working directory has uncommitted changes. Stash or commit before proceeding."; }
```

> **Deleted in v2.2.0: the worker-terminal count check.** Terminal objects have
> no `type`/`tags` fields and `orca terminal create` has no `--tags` flag, so a
> pre-flight "is there a tagged worker?" probe was meaningless. The coordinator
> spawns every worker terminal itself, fresh, at dispatch time.
> `ORCA_WORKFLOW_STRICT_PREREQ` is retained for the remaining checks in
> `scripts/check-prerequisites.sh`.

### 3.2 Required Tools

| Tool | Version | Check Command | Purpose |
|------|---------|---------------|---------|
| Orca IDE | ≥ 1.x | `orca status --json` | Orchestration runtime |
| Git | ≥ 2.30 | `git --version` | Version control |
| GitHub CLI | ≥ 2.0 | `gh --version` | PR creation & management |
| jq | ≥ 1.6 | `jq --version` | JSON parsing + atomic state writes |

### 3.3 Environment Variables

> Full list and precedence: [`docs/agent-routing.md`](./docs/agent-routing.md).

```bash
# === Limits (override workflow.limits.*) ===
export ORCA_WORKFLOW_MAX_REVIEW_ROUNDS=${ORCA_WORKFLOW_MAX_REVIEW_ROUNDS:-3}
export ORCA_WORKFLOW_MAX_ESCALATE=${ORCA_WORKFLOW_MAX_ESCALATE:-2}
export ORCA_WORKFLOW_MAX_USER_CONFIRM=${ORCA_WORKFLOW_MAX_USER_CONFIRM:-3}
export ORCA_WORKFLOW_MAX_SUB_RETRY=${ORCA_WORKFLOW_MAX_SUB_RETRY:-3}
export ORCA_WORKFLOW_MAX_GLOBAL_RETRY=${ORCA_WORKFLOW_MAX_GLOBAL_RETRY:-2}
export ORCA_WORKFLOW_MAX_AUTOFIX=${ORCA_WORKFLOW_MAX_AUTOFIX:-2}
export ORCA_WORKFLOW_MAX_INTEGRATION_REVIEW=${ORCA_WORKFLOW_MAX_INTEGRATION_REVIEW:-2}   # NEW in v2.2.0

# === Paths & logging ===
export ORCA_WORKFLOW_STATE_FILE="${ORCA_WORKFLOW_STATE_FILE:-.orca/workflow-state.json}"
export ORCA_WORKFLOW_LOG_LEVEL="${ORCA_WORKFLOW_LOG_LEVEL:-INFO}"

# === Behaviour switches ===
# true  → scripts/check-prerequisites.sh fails hard when a prerequisite is missing
#         (recommended for production / CI)
# false → WARN and continue (default for local dev and smoke tests)
export ORCA_WORKFLOW_STRICT_PREREQ="${ORCA_WORKFLOW_STRICT_PREREQ:-false}"
export ORCA_WORKFLOW_DRY_RUN="${ORCA_WORKFLOW_DRY_RUN:-false}"

# === Agent routing (override docs/agent-routing.md — same names as v2.1.0) ===
export ORCA_WORKFLOW_PLAN_AGENT="${ORCA_WORKFLOW_PLAN_AGENT:-claude}"   # fallback: pi
export ORCA_WORKFLOW_REVIEW_AGENT="${ORCA_WORKFLOW_REVIEW_AGENT:-pi}"
export ORCA_WORKFLOW_EXECUTION_AGENT="${ORCA_WORKFLOW_EXECUTION_AGENT:-kimi}"   # on error: claude (see fallback chain)
export ORCA_WORKFLOW_COMPLEX_EXECUTION_AGENT="${ORCA_WORKFLOW_COMPLEX_EXECUTION_AGENT:-kimi}"
export ORCA_WORKFLOW_IMAGE_AGENT="${ORCA_WORKFLOW_IMAGE_AGENT:-grok}"
export ORCA_WORKFLOW_FALLBACK_AGENT="${ORCA_WORKFLOW_FALLBACK_AGENT:-pi}"
# Fallback chain after a generic task failure (comma-separated, highest priority first)
export ORCA_WORKFLOW_FALLBACK_CHAIN="${ORCA_WORKFLOW_FALLBACK_CHAIN:-claude,grok,pi}"
```

> **Removed in v2.2.0** (no longer read — the per-feature worktree model needs
> no branch/path templates, and terminal counts are not pre-flight checked):
> `ORCA_WORKFLOW_BRANCH_STRATEGY`, `ORCA_WORKFLOW_BRANCH_TEMPLATE`,
> `ORCA_WORKFLOW_WORKTREE_PATH_TEMPLATE`,
> `ORCA_WORKFLOW_MAX_TERMINALS_PER_SUBTASK`, `ORCA_WORKFLOW_MIN_WORKERS`.

---

## 4. Configuration

### 4.1 Tunable Parameters

> 📖 **Agent routing is defined in [`docs/agent-routing.md`](./docs/agent-routing.md)** — the single source of truth.
> To change a preference, edit `agent-routing.md` plus the matching `ORCA_WORKFLOW_*`
> environment variable; never hardcode agent names into task specs.
>
> The `routing.*_agent_type` values below are cold-start defaults only; at runtime the
> effective values come from `agent-routing.md` + env overrides.

```json
{
  "workflow": {
    "version": "2.2.0",
    "limits": {
      "max_review_rounds": 3,
      "max_escalate_count": 2,
      "max_user_confirm_rounds": 3,
      "max_subtask_retries": 3,
      "max_global_retries": 2,
      "max_autofix_attempts": 2,
      "max_integration_review_rounds": 2,
      "max_clarification_rounds": 5
    },
    "timeouts_ms": {
      "worker_execution": 1800000,
      "human_response": 0,
      "pr_review_poll_interval": 60000
    },
    "routing": {
      "_note": "Single source of truth: docs/agent-routing.md. These are cold-start defaults only.",
      "plan_agent_type": "claude",
      "review_agent_type": "pi",
      "execution_agent_type": "kimi",
      "complex_execution_agent_type": "kimi",
      "image_agent_type": "grok",
      "fallback_agent_type": "pi",
      "default_model": "sonnet"
    },
    "terminals": {
      "spawn_per_role": true,
      "close_intermediate_terminals": true,
      "_note": "A fresh terminal is spawned for every round of every role, all inside the ONE shared feature worktree. `orca terminal create` has no --tags flag and terminal objects carry no type/tags fields: agent identity is carried by the --title prefix convention '[<role>:<agent>] …' and by the coordinator's state record (handle → role/round/agent_type)."
    },
    "merge": {
      "mode": "pr_only",
      "auto_merge_on_approval": false,
      "require_ci_pass": true,
      "delete_branch_after_merge": true
    },
    "observability": {
      "log_level": "INFO",
      "state_file": ".orca/workflow-state.json",
      "trace_all_gates": true
    }
  }
}
```

### 4.2 Configuration File Resolution

The workflow looks for configuration in this order (first wins):

1. Environment variables (`ORCA_WORKFLOW_*`)
2. `.orca/workflow-config.json` (project-local)
3. `~/.config/orca/workflow-defaults.json` (user-global)
4. Built-in defaults (shown above)

---

## 5. Phase 1 — Requirements Gathering

**Goal**: Ensure the user request contains sufficient information before proceeding.

### 5.1 Entry Condition

- State: `INIT` → `GATHERING`
- Input: Raw user request (natural language)

### 5.2 Process

The coordinator talks to the user through its **own native user-interaction
channel** (the chat surface it was invoked on). It must **never** use
`orca orchestration ask --to coordinator` — that channel is reserved for
**worker → coordinator** messages (see references/api-reference.md §18.1).

```
clarification_round = 0

while clarification_round < MAX_CLARIFICATION_ROUNDS:   # default 5
    gaps = analyze_request(user_input)

    if gaps is empty:
        emit REQUIREMENTS_READY event
        transition to PLANNING
        break

    clarification_round += 1
    response = await ask_user_via_native_channel(
        "Before I proceed, I need to clarify:\n{gaps_formatted}\n\nPlease provide details."
    )
    user_input = merge(user_input, response)

if clarification_round >= MAX_CLARIFICATION_ROUNDS:
    emit REQUIREMENTS_INCOMPLETE event
    transition to TERMINATED
```

### 5.3 Gap Analysis Checklist

Before advancing to Phase 2, confirm the following are present in the request:

- [ ] **Goal**: What is the deliverable? (concrete, not abstract)
- [ ] **Scope**: What is in-scope and explicitly out-of-scope?
- [ ] **Constraints**: Technology, format, deadline, quality bar?
- [ ] **Context**: Any existing codebase, docs, or prior work to reference?
- [ ] **Acceptance Criteria**: How will success be measured?

If ≥ 2 items are missing, pause and clarify.

### 5.4 Output

```json
{
  "phase": "GATHERING",
  "status": "complete",
  "clarified_requirement": "Full requirement text after clarification",
  "clarification_rounds": 2,
  "timestamp": "2026-07-27T10:00:00Z"
}
```

### 5.5 Error Handling

| Error | Severity | Action |
|-------|----------|--------|
| User unresponsive (> 5 min with no reply) | WARN | Retry once with a reminder; if still no response, persist state and exit with `TIMEOUT` |
| User request contradicts itself | WARN | Flag the contradiction explicitly; do not guess |
| Native channel unavailable | FATAL | Log error, persist state, exit |

---

## 6. Phase 2 — Plan Generation & Review

**Goal**: Generate a technical plan and have it pass review by a **separate
review agent** (≤ `MAX_REVIEW_ROUNDS` rounds, with ≤ `MAX_ESCALATE_COUNT`
human escalations as fallback).

### 6.1 Entry Condition

- State: `PLANNING`
- Input: Clarified requirement from Phase 1

### 6.2 Process

Key rules:

- The plan is produced by the **plan agent** as a dispatched task on a fresh terminal.
- The review is a **separate review task** dispatched to the **review agent**
  (default `pi`) on its own fresh terminal. The verdict arrives via
  **`worker_done`** — do **NOT** use `gate-create` for agent reviews.
  `gate-create` is reserved for coordinator-managed DAG decisions (see
  references/api-reference.md §18.1).
- The plan artifact is passed **as text** (task result / `worker_done` body).
  It is **never written as a file into the main checkout** — the coordinator's
  checkout stays clean.
- Plan/plan-review terminals are spawned in the coordinator's current (main)
  checkout: the feature worktree does not exist until Phase 4. Both agents are
  text-only here and must not modify files.

```python
review_round = 0
escalate_count = 0
feedback = None

# Step 1: create + dispatch the plan-generation task on a fresh terminal
plan_task_id = task_create(
    title=f"Plan: {requirement_summary}",
    display_name="📝 Plan Agent",
    spec=build_plan_spec(clarified_requirement),   # format: summary, approach,
)                                                  # subtask DAG w/ deps+owns, risks, acceptance
plan_handle = terminal_create(title=f"[plan:{PLAN_AGENT}] plan r0", command=agent_command_for(PLAN_AGENT))
terminal_wait(plan_handle, for_="tui-idle", timeout_ms=60000)   # ready before inject (§8.3.3)
dispatch(task=plan_task_id, to=plan_handle, inject=True)

while review_round < MAX_REVIEW_ROUNDS:              # default 3
    plan_text = await wait_worker_done(plan_task_id) # plan artifact = TEXT of the result

    # Step 2: SEPARATE review task → review agent → verdict via worker_done
    review_task_id = task_create(
        title=f"Plan review r{review_round}",
        spec=build_plan_review_spec(plan_text),      # includes checklist §6.3
        parent=plan_task_id,
    )
    review_handle = terminal_create(title=f"[review:{REVIEW_AGENT}] plan r{review_round}",
                                    command=agent_command_for(REVIEW_AGENT))
    terminal_wait(review_handle, for_="tui-idle", timeout_ms=60000)
    dispatch(task=review_task_id, to=review_handle, inject=True)
    verdict = await wait_worker_done(review_task_id) # {"verdict":"PASS"|"FAIL","feedback":...}
    terminal_close(review_handle)

    if verdict == "PASS":
        emit PLAN_APPROVED event
        transition to CONFIRMING
        break

    feedback = verdict.feedback
    review_round += 1
    if review_round < MAX_REVIEW_ROUNDS:
        # NEW task (never re-dispatch the old one) + FRESH terminal
        plan_task_id = task_create(title=f"Plan revision r{review_round}",
                                   spec=build_plan_spec(clarified_requirement, feedback),
                                   parent=plan_task_id)
        plan_handle = terminal_create(title=f"[plan:{PLAN_AGENT}] plan r{review_round}",
                                      command=agent_command_for(PLAN_AGENT))
        terminal_wait(plan_handle, for_="tui-idle", timeout_ms=60000)
        dispatch(task=plan_task_id, to=plan_handle, inject=True)
    else:
        # Escalate to the human via the NATIVE channel
        escalate_count += 1
        if escalate_count <= MAX_ESCALATE_COUNT:     # default 2
            human = await ask_user_via_native_channel(
                f"⚠️ Plan review failed after {MAX_REVIEW_ROUNDS} rounds "
                f"(escalation {escalate_count}/{MAX_ESCALATE_COUNT}).\n"
                f"Disagreement points:\n{feedback}\n"
                f"Provide direction, or terminate.")
            if human == "terminate":
                transition to TERMINATED (Terminate1); break
            review_round = 0                          # reset; fold human direction into spec
            plan_task_id = task_create(..., parent=plan_task_id)  # NEW task + fresh terminal
            ...
        else:
            transition to TERMINATED (Terminate1); break
```

### 6.3 Plan Review Checklist

The review agent's spec must include this checklist; the plan passes only if
all items hold:

1. **Completeness** — the plan covers every aspect of the clarified requirement.
2. **Feasibility** — each step is technically achievable by an execution agent.
3. **Clarity** — each subtask spec is unambiguous and self-contained.
4. **Risk** — the top 3 risks have credible mitigations.
5. **Ownership declared (NEW in v2.2.0)** — every subtask declares `owns`: a
   non-empty list of file/dir globs it is allowed to write.
6. **Ownership disjoint (NEW in v2.2.0)** — subtasks in the same wave (i.e.
   that can run in parallel) have **disjoint** `owns` globs. Overlapping globs
   are a review FAIL with the conflicting subtask ids listed.
7. **Valid DAG** — `deps` reference existing subtasks and contain no cycles.

### 6.4 Output

```json
{
  "phase": "PLANNING",
  "status": "complete",
  "plan_task_id": "task_xxx",
  "review_rounds": 2,
  "escalate_count": 0,
  "plan_artifact": "<full plan text, stored in state — never a file in the main checkout>",
  "review_verdict": "PASS",
  "timestamp": "2026-07-27T10:15:00Z"
}
```

---

## 7. Phase 3 — User Confirmation

**Goal**: Present the reviewed plan to the user for final sign-off before any
worktree or terminal is created.

### 7.1 Entry Condition

- State: `CONFIRMING`
- Input: Approved plan (text) from Phase 2

### 7.2 Process

Three options only — **Approve / Revise / Abort** — asked via the coordinator's
native channel:

```
confirm_round = 0

while confirm_round < MAX_USER_CONFIRM:          # default 3
    response = await ask_user_via_native_channel(
        "✅ The technical plan has passed internal review.\n\n"
        f"Summary:\n{plan_summary}\n\n"
        "Do you approve this plan?",
        options=["Approve — begin execution",
                 "Revise — provide feedback",
                 "Abort — cancel the task"])

    if response == "Approve":
        transition to DISPATCHING; break
    if response == "Abort":
        transition to TERMINATED (Terminate2)     # IMMEDIATE — at ANY round,
        break                                     # including the first

    # response == "Revise"
    confirm_round += 1
    if confirm_round < MAX_USER_CONFIRM:
        transition to PLANNING (with user_feedback)   # review counter resets
    else:
        force = await ask_user_via_native_channel(
            f"Plan has been revised {confirm_round} times without approval.\n"
            "Choose: continue revising, or terminate.",
            options=["Continue revising", "Terminate"])
        if force == "Continue revising":
            confirm_round = 0
            transition to PLANNING
        else:
            transition to TERMINATED (Terminate2)
```

**Abort is immediate at any round** — including round 0. v2.1.0 waited for the
round counter before honouring Abort (an off-by-one); v2.2.0 terminates as soon
as the user says so.

#### 7.2.1 Removed option: scope reduction

v2.0.1 offered a fourth option, "Reduce scope — work in-place without a
worktree or PR". It is **removed in v2.2.0**: in-place execution means parallel
subtask workers write into the **coordinator's own main checkout**, which is
unsafe (the coordinator must stay on a clean `main`, and `owns`-based
verification assumes all writes land in the feature worktree). Users who want a
smaller change should choose **Revise** and narrow the plan instead.

### 7.3 Output

```json
{
  "phase": "CONFIRMING",
  "status": "complete",
  "confirm_rounds": 1,
  "user_decision": "APPROVE",
  "timestamp": "2026-07-27T10:20:00Z"
}
```

---

## 8. Phase 4 — Task Decomposition & Dispatch

**Goal**: Create the **single** feature worktree + branch, decompose the plan
into a subtask DAG, compute waves, and dispatch wave 0 — one fresh terminal and
one new orchestration task per subtask.

### 8.1 Entry Condition

- State: `DISPATCHING`
- Input: Approved plan + user confirmation
- `feature_slug`: short kebab-case slug for the request (e.g. `add-user-prefs`)

### 8.2 Subtask Schema

Each subtask in the plan must declare:

```json
{
  "id": "sub-1",
  "logical_id": "prefs-api",
  "title": "Preferences API",
  "deps": [],
  "owns": ["src/prefs/**", "docs/prefs.md"],
  "complexity": "general",
  "spec": "Implement the preferences REST endpoints …",
  "review_criteria": [
    "All endpoints return the documented schemas",
    "Input validation rejects malformed payloads",
    "Unit tests cover the new handlers"
  ],
  "timeout_ms": 1800000
}
```

- `owns` (NEW in v2.2.0): file/dir globs, relative to the repo root, that this
  subtask — and only this subtask — may write. Same-wave subtasks must be
  disjoint (validated in §6.3).
- `complexity`: `general` | `complex` | `image`.

#### Agent Routing Rules

> 📖 **Agent selection: see [`docs/agent-routing.md`](./docs/agent-routing.md)** — single source of truth.

`complexity` picks the implementation agent; the role picks the rest:

- `"complex"` → `complex_execution_agent_type` (default `kimi`)
- `"image"` → `image_agent_type` (default `grok`)
- `"general"` or unset → `execution_agent_type` (default `kimi`; on error the
  fallback chain starts with `claude`)
- review role → `review_agent_type` (default `pi`) — **always ≠ the implementation agent**
- fix role → same agent as the subtask's implementation agent
- integration review → `review_agent_type` (reused; default `pi`)
- generic failure retries → `fallback_chain` (default `claude,grok,pi`)

`orca terminal create` has **no `--tags` flag** and terminal objects have no
`type`/`tags` fields. Agent identity is carried by (1) the `--title` prefix
convention `[<role>:<agent>] …` and (2) the coordinator's state record
(handle → role/round/agent_type).

### 8.3 Process — one worktree, then wave 0

```bash
FEATURE_SLUG="add-user-prefs"        # from the plan
STATE_FILE="${ORCA_WORKFLOW_STATE_FILE:-.orca/workflow-state.json}"

# 8.3.1 Fetch the base, then create the ONE feature worktree.
#       `orca worktree create` takes NO positional path arg and NO `--base`.
git fetch origin main

# Resume / existence check first: match by name (idempotent restarts)
WT_ID=$(orca worktree list --json | jq -r --arg n "$FEATURE_SLUG" \
  '[.result.worktrees[]? | select(.name == $n)] | .[0].id // empty')
# (exact JSON field names should be confirmed on first live run)

if [ -z "$WT_ID" ]; then
  WT_JSON=$(orca worktree create --name "$FEATURE_SLUG" --base-branch origin/main --json)
  WT_ID=$(echo "$WT_JSON"   | jq -r '.result.worktree.id')
  WT_PATH=$(echo "$WT_JSON" | jq -r '.result.worktree.path')
  BRANCH=$(echo "$WT_JSON"  | jq -r '.result.worktree.branch_name')
else
  WT_PATH=$(orca worktree list --json | jq -r --arg id "$WT_ID" \
    '.result.worktrees[] | select(.id == $id) | .path')
  BRANCH="feature/${FEATURE_SLUG}"
fi

# Record in state: worktree {id, path, branch_name, base_branch}
state_update ".worktree = {id:\"$WT_ID\", path:\"$WT_PATH\", branch_name:\"$BRANCH\", base_branch:\"origin/main\"}"

# 8.3.2 Decompose the plan into the subtask DAG and compute waves.
#       wave(sub) = 0 if deps == [] else 1 + max(wave(parent))
declare -A WAVE
compute_waves   # fills WAVE[sub-id]; validates acyclicity again

# 8.3.3 Dispatch wave 0: per subtask — task-create + FRESH terminal + dispatch --inject
for SUB in $(subtasks_in_wave 0); do
  AGENT=$(resolve_agent_type "${COMPLEXITY[$SUB]}")          # §8.2
  TASK_ID=$(orca orchestration task-create \
    --task-title "Sub: ${TITLE[$SUB]}" \
    --display-name "🔧 ${LOGICAL_ID[$SUB]}" \
    --spec "${SPEC[$SUB]}" \
    --deps "$(deps_json "$SUB")" \
    --json | jq -r '.result.task.id')

  TERM=$(orca terminal create \
    --worktree "id:$WT_ID" \
    --title "[execution:$AGENT] sub-$SUB r0" \
    --command "$(agent_command_for "$AGENT")" \
    --json | jq -r '.result.terminal.handle')

  # Wait for the agent CLI to be READY before injecting — dispatch --inject
  # types the preamble+task into the terminal, and a still-booting agent can
  # lose or garble it (lost preamble = the worker never reports worker_done
  # and the coordinator stalls at checkpoints). Applies to EVERY fresh
  # terminal in every phase (plan/review/execution/fix/fallback/autofix/
  # pr-fix/integration-review).
  orca terminal wait --terminal "$TERM" --for tui-idle --timeout-ms 60000 --json

  BASE_SHA=$(cd "$WT_PATH" && git rev-parse HEAD)            # record per dispatch

  orca orchestration dispatch --task "$TASK_ID" --to "$TERM" --inject --json

  record_subtask_state "$SUB" \
    status="dispatched" base_sha="$BASE_SHA" initial_base_sha="$BASE_SHA" keep_terminal="$TERM"
  # initial_base_sha is written ONCE here (round 0) and never overwritten;
  # base_sha is refreshed at every later dispatch (§9.2).
  append_terminal_history "$SUB" handle="$TERM" role="execution" round=0 agent_type="$AGENT"
done
```

### 8.4 Fallback Chain (per-subtask, per-round)

When an execution/fix round fails for infrastructure reasons (agent crash,
CLI error — *not* a review FAIL), retry with the fallback chain. **Each
fallback attempt is a NEW task + a NEW terminal.**

```bash
retry_with_fallback() {
  local sub_id="$1" failed_task_id="$2" round="$3"
  IFS=',' read -ra agents <<< "${ORCA_WORKFLOW_FALLBACK_CHAIN:-claude,grok,pi}"

  local prev_task="$failed_task_id"
  for agent in "${agents[@]}"; do
    local task_id handle
    task_id=$(orca orchestration task_create \
      --task-title "Sub: ${TITLE[$sub_id]} (fallback: $agent)" \
      --spec "$(build_fallback_spec "$sub_id")" \
      --parent "$prev_task" \
      --json | jq -r '.result.task.id')
    handle=$(orca terminal create \
      --worktree "id:$WT_ID" \
      --title "[fallback:$agent] sub-$sub_id r$round" \
      --command "$(agent_command_for "$agent")" \
      --json | jq -r '.result.terminal.handle')
    orca orchestration dispatch --task "$task_id" --to "$handle" --inject --json

    if wait_for_worker "$task_id" && [ "$(get_task_verdict "$task_id")" = "PASS" ]; then
      append_terminal_history "$sub_id" handle="$handle" role="fallback" round="$round" agent_type="$agent"
      return 0
    fi
    orca terminal close --terminal "$handle" --json
    prev_task="$task_id"
    echo "⚠️ fallback agent $agent failed, trying next…"
  done
  return 1
}
```

### 8.5 Injected Preamble (sent to every fresh terminal)

Every terminal — execution, fix, review, fallback, autofix, pr-fix,
integration-review — receives the same preamble shape via `dispatch --inject`:

```text
You are the {role} agent for subtask "{title}" (round {round}) in a multi-agent workflow.

Worktree: {worktree_path}   (SHARED feature worktree — sibling subtasks run here in parallel)
Branch: {branch_name}
Base SHA at this dispatch: {base_sha}
Your ownership (owns): {owns_globs}

## Rules
1. Work ONLY within paths matched by your owns globs. Never create, modify, or
   delete files outside them — the coordinator verifies after each round and
   reverts any out-of-owns writes.
2. Execution/fix only: commit your work in SMALL COMMITS on the branch above.
3. Review only: you are READ-ONLY. Review `git diff {base_sha}..HEAD` limited
   to the owns globs, against the review criteria below.
4. You are ONE round of one subtask. Do not review your own output; do not
   dispatch other agents; do not push, merge, or create PRs.
5. When finished, emit worker_done IMMEDIATELY and EXACTLY ONCE to the
   coordinator handle with {taskId, dispatchId, verdict, artifact summary} —
   send it BEFORE writing any long report or wrap-up, then idle (no polling,
   no further output). Put the verdict in BOTH the subject (prefix
   "PASS"/"FAIL") and the payload
   ({"verdict":"PASS"|"FAIL","reason":...}) — the coordinator reads the payload
   first and falls back to the subject prefix (smoke-run finding: some agents
   only write the subject). While working, send a heartbeat every 5 minutes
   per Orca's injected preamble — a stopped heartbeat plus an idle terminal
   is how the coordinator detects "finished but forgot to report".

## Task spec
{spec}

## Prior feedback (round > 0 only)
{prior_feedback}
```

### 8.6 Output

```json
{
  "phase": "DISPATCHING",
  "status": "complete",
  "feature_slug": "add-user-prefs",
  "worktree": {
    "id": "wt_abc123",
    "path": "../add-user-prefs",
    "branch_name": "feature/add-user-prefs",
    "base_branch": "origin/main"
  },
  "waves": [["sub-1", "sub-2"], ["sub-3"]],
  "subtasks": [
    {
      "id": "sub-1",
      "logical_id": "prefs-api",
      "orchestration_id": "task_xxx",
      "owns": ["src/prefs/**", "docs/prefs.md"],
      "base_sha": "a1b2c3d",
      "initial_base_sha": "a1b2c3d",
      "keep_terminal": "term_yyy",
      "terminals": [
        {"handle": "term_yyy", "role": "execution", "round": 0, "agent_type": "kimi", "status": "dispatched"}
      ]
    }
  ],
  "timestamp": "2026-07-27T10:30:00Z"
}
```

---

## 9. Phase 5 — Parallel Execution & Sub-Review

**Goal**: Run the subtask DAG **wave by wave** inside the shared feature
worktree. Within a wave, subtasks run in parallel (their `owns` are disjoint);
each subtask goes through a per-round **implement → cross-review** loop where
every round is a **fresh terminal + NEW task**.

### 9.1 Entry Condition

- State: `EXECUTING`
- The feature worktree exists and wave 0 has been dispatched (Phase 4)

### 9.2 Per-Subtask Round Loop

Rounds are numbered **0..MAX_SUB_RETRY** (default 3): round 0 is the initial
attempt, rounds 1..3 are ≤ 3 retries. Each round = one execution/fix dispatch +
one cross-review dispatch.

```
MAX_SUB_RETRY = ORCA_WORKFLOW_MAX_SUB_RETRY   # default 3

For each subtask in the current wave (in parallel):

  round = 0
  prior_feedback = null
  prev_task_id = subtask.orchestration_id     # round-0 task from Phase 4

  while round <= MAX_SUB_RETRY:
    # ---- Execution (round 0) or fix (round > 0) ----
    if round > 0:
      subtask.base_sha = (cd $WT_PATH && git rev-parse HEAD)   # per dispatch
      exec_task_id = task_create(spec=build_fix_spec(subtask, prior_feedback),
                                 parent=prev_task_id)          # NEW task, chained;
                                                               # NEVER re-dispatch the old one —
                                                               # Orca circuit-breaks a task after
                                                               # 3 consecutive failures
      exec_handle = terminal_create(fresh, title="[fix:<agent>] sub-N r{round}")
      terminal_wait(exec_handle, for_="tui-idle", timeout_ms=60000)   # ready before inject
      dispatch(task=exec_task_id, to=exec_handle, inject=True)
      prev_task_id = exec_task_id
      subtask.keep_terminal = exec_handle
      append_terminal_history(role="fix", round=round)
    else:
      wait_for_worker(prev_task_id)           # round 0 was dispatched in Phase 4

    # ---- Coordinator verification (owns enforcement) ----
    offending = git_paths_outside_owns(subtask.base_sha, subtask.owns)   # git status/diff
    if offending is non-empty:
      revert_offending_paths(offending)       # git checkout -- <paths> / git clean -fd <paths>
      record error; treat the round as FAIL with feedback "owns violation: <paths>"

    # ---- Cross-review: FRESH terminal, review agent ≠ implementation agent ----
    review_task_id = task_create(spec=build_review_spec(subtask, base_sha=subtask.base_sha),
                                 parent=prev_task_id)
    review_handle = terminal_create(fresh, title="[review:<review_agent>] sub-N r{round}")
    terminal_wait(review_handle, for_="tui-idle", timeout_ms=60000)   # ready before inject
    dispatch(task=review_task_id, to=review_handle, inject=True)
    verdict = wait_for_worker(review_task_id)
    terminal_close(review_handle)             # reviewer torn down after verdict
    append_terminal_history(role="review", round=round, verdict=verdict)

    if verdict == "PASS":
      record_subtask_state(verdict="PASS", review_rounds=round); break

    prior_feedback = verdict.feedback
    round += 1
    if round > MAX_SUB_RETRY:
      record_subtask_state(verdict="FAIL", reason="review never passed",
                           review_rounds=MAX_SUB_RETRY)   # siblings continue
```

**Key invariants**:

- Every round (execution, fix, review) is a **fresh terminal + NEW task**;
  tasks are chained with `--parent` to preserve history.
- The implementation/fix agent **must commit in small commits**; the review
  agent reviews **only** `git diff <base_sha>..HEAD` limited to the subtask's
  `owns`, where `base_sha` is the feature-branch HEAD recorded at that dispatch.
- The review agent is never the same agent type as the implementation agent.
- A subtask that fails its final round's review gets `verdict=FAIL`; its
  siblings continue unaffected.

### 9.3 Coordinator-Side Wait (rolling checkpoints)

The coordinator waits with `orca orchestration check --wait` in a **rolling
loop**. A timeout is a **checkpoint, not a failure** — long coding tasks
routinely take 15–60 minutes.

```bash
while :; do
  EVENT=$(orca orchestration check --wait \
    --types worker_done,escalation,decision_gate \
    --timeout-ms 300000 --json)   # never exceed 300000: the tool runtime
                                  # caps one foreground call at ~300s

  if is_timeout "$EVENT"; then
    # Checkpoint: verify liveness instead of failing. IN ORDER:
    orca orchestration dispatch-show --task "$TASK_ID" --json
      # dispatch status + last_heartbeat_at — a fresh heartbeat means
      # "alive, still working", NOT done. Never close/restart a worker
      # just because it has been silent.
    orca orchestration task-list --brief --json | jq '.result.tasks[] | {id,status}'
    orca terminal read --terminal "$HANDLE" --json   # or: terminal wait --for tui-idle --timeout-ms 30000
      # terminal IDLE + heartbeat stale + task still `dispatched`
      #   → worker finished but forgot worker_done: collect the result
      #     from the terminal output / task-list and mark it completed
      #     (manual task-update is recovery/override only — see below)
      # terminal still active → keep waiting.
    continue
  fi

  handle_event "$EVENT"     # worker_done → record verdict; escalation → native channel
                            # verdict extraction: payload.verdict first, then the
                            # subject's "PASS"/"FAIL" prefix as fallback (§8.5 rule 5)
                            # NOTE: a valid worker_done marks task+dispatch completed
                            # AUTOMATICALLY — do NOT follow with task-update.
  all_wave_verdicts_in && break
  # check --wait returns ONE message at a time. When N workers can finish
  # together, loop again IMMEDIATELY to drain the next pending event before
  # doing any heavy local work (state rewrites, summaries) — otherwise queued
  # completions sit unread and the wave stalls.
done
```

When every subtask in wave k has `verdict=PASS`, the coordinator dispatches
wave k+1 (same procedure as §8.3.3; each subtask sees its parents' committed
code in the shared worktree). Subtasks whose parents FAILED are skipped and
inherit `verdict=FAIL` with reason `"parent failed"`.

### 9.4 Wall-Clock Timeout Handling

Subtask wall-clock timeouts are enforced by the **coordinator**, which tracks
elapsed time per subtask (workers do not self-terminate):

```bash
if [ "$elapsed_ms" -gt "${TIMEOUT_MS[$SUB]}" ]; then
  orca orchestration task-update --id "$TASK_ID" --status failed \
    --result '{"verdict":"FAIL","reason":"wall-clock timeout"}'
  orca terminal close --terminal "$HANDLE" --json
  record_subtask_state "$SUB" verdict="FAIL" reason="timeout after ${elapsed_ms}ms"
fi
```

Infrastructure-level execution failures (agent crash, CLI error) may retry via
the fallback chain (§8.4) — each fallback attempt is a NEW task + NEW terminal.

### 9.5 Output

```json
{
  "phase": "EXECUTING",
  "status": "complete",
  "subtask_results": [
    {
      "id": "sub-1",
      "verdict": "PASS",
      "owns": ["src/prefs/**", "docs/prefs.md"],
      "review_rounds": 1,
      "terminals": [
        {"handle": "term_yyy", "role": "execution", "round": 0, "agent_type": "kimi", "status": "completed", "verdict": "PASS"},
        {"handle": "term_rrr", "role": "review", "round": 0, "agent_type": "pi", "status": "closed", "verdict": "FAIL"},
        {"handle": "term_zzz", "role": "fix", "round": 1, "agent_type": "kimi", "status": "completed", "verdict": "PASS"},
        {"handle": "term_sss", "role": "review", "round": 1, "agent_type": "pi", "status": "closed", "verdict": "PASS"}
      ],
      "keep_terminal": "term_zzz"
    },
    {"id": "sub-2", "verdict": "FAIL", "reason": "Cross-review never passed after 3 retries", "review_rounds": 3}
  ],
  "timestamp": "2026-07-27T11:00:00Z"
}
```

---

## 10. Phase 6 — Aggregation & Decision

**Goal**: Collect every subtask verdict (pass + fail), then either proceed or
ask the user — via the coordinator's **native channel** — how to handle the
failures.

### 10.1 Entry Condition

- State: `DECIDING`
- All dispatched subtasks have a terminal verdict (`PASS` or `FAIL`)

### 10.2 Decision Matrix

```
global_retries_used = 0        # persisted in state.retry_counts

analyze_results(all_subtask_results):

  if all passed:
    transition to MERGING
    return

  failed = [r for r in all_subtask_results if r.verdict == "FAIL"]

  decision = await ask_user_via_native_channel(
    f"{len(failed)} subtask(s) failed. Passed: {len(passed)}.\n"
    f"Failed: {format_failures(failed)}\n\n"
    f"What should we do?",
    options=[
      "Retry failed subtasks only",        # offered ONLY while the guard below holds
      "Degrade — revert failures, deliver the rest",
      "Abort — cancel the workflow",
    ])

  switch decision:
    case "Retry failed subtasks only":
      # Guard checked BEFORE incrementing → at most MAX_GLOBAL_RETRY (2) retries
      if global_retries_used < MAX_GLOBAL_RETRY:
        global_retries_used += 1
        transition to DISPATCHING (re-dispatch ONLY the failed subtasks:
                                   fresh terminals + NEW tasks, same worktree)
      else:
        re-ask without the retry option

    case "Degrade":
      # The coordinator reverts each failed subtask's commit range in the
      # feature worktree. This is clean because owns are disjoint — the
      # revert touches only that subtask's files.
      for sub in failed:
        (cd $WT_PATH && git revert --no-commit <sub.initial_base_sha>..HEAD -- <sub.owns…>)
        # initial_base_sha = feature-branch HEAD at the subtask's round-0
        # dispatch (recorded once in state); the revert therefore covers ALL
        # of the failed subtask's rounds, limited to its owns.
        if revert is unclean:
          park the WHOLE feature → PARKED (§12); return
      delivery_mode = "degraded"
      transition to MERGING

    case "Abort":
      transition to TERMINATED (Terminate3)
```

### 10.3 Shell Implementation

```bash
# Gather verdicts from state
PASSED=$(jq -r '.tasks.subtasks[] | select(.verdict == "PASS") | .id' "$STATE_FILE")
FAILED=$(jq -r '.tasks.subtasks[] | select(.verdict == "FAIL") | .id' "$STATE_FILE")

if [ -z "$FAILED" ]; then
  echo "✅ All subtasks passed. Proceeding to merge."
else
  RETRIES_USED=$(jq -r '.retry_counts.global_retries_used // 0' "$STATE_FILE")
  echo "⚠️ failed: $FAILED (global retries used: $RETRIES_USED/$ORCA_WORKFLOW_MAX_GLOBAL_RETRY)"
  # Present the decision via the coordinator's NATIVE channel (never ask --to coordinator)
fi

# Degrade: revert a failed subtask's commits (clean because owns are disjoint)
# before_sha = the subtask's initial_base_sha from state (round-0 dispatch HEAD)
degrade_revert() {
  local sub="$1" before_sha="$2" last_sha="${3:-HEAD}"
  ( cd "$WT_PATH" && git revert --no-commit "${before_sha}..${last_sha}" ) || {
    echo "⚠️ revert of sub-$sub is unclean — parking the whole feature"
    park_feature "degrade revert conflict on sub-$sub"
    return 1
  }
  ( cd "$WT_PATH" && git commit -m "revert: drop failed subtask $sub" )
}
```

### 10.4 Degraded Delivery Contract

When **Degrade** is chosen:

1. Each failed subtask's commit range is reverted in the feature worktree (§10.2).
2. The state file records `delivery_mode: "degraded"`.
3. The PR body (§11.5) carries a `⚠️ DEGRADED DELIVERY` banner listing the
   dropped subtasks, their failure reasons, and suggested manual follow-up.

### 10.5 Output

```json
{
  "phase": "DECIDING",
  "status": "complete",
  "all_passed": false,
  "decision": "DEGRADE",
  "passed_count": 2,
  "failed_count": 1,
  "global_retries_used": 1,
  "delivery_mode": "degraded",
  "timestamp": "2026-07-27T11:05:00Z"
}
```

---

## 11. Phase 7 — Merge & Pull Request

**Goal**: Rebase the single feature branch onto `origin/main`, run the project
tests, pass the **integration review**, create **one PR**, and monitor it to a
terminal state. All git operations run inside the feature worktree via
`(cd <wt> && git …)`; the coordinator never checks anything out itself.

### 11.1 Entry Condition

- State: `MERGING`
- All subtasks passed, or Phase 6 chose **Degrade** (failed ranges already reverted)

### 11.2 Rebase + Autofix Loop

```bash
cd "$WT_PATH"   # conceptually — every command runs as (cd "$WT_PATH" && …)
git fetch origin main
git rebase origin/main

autofix_count=0
while rebase_in_progress && [ $autofix_count -lt $MAX_AUTOFIX ]; do   # default 2
  autofix_count=$((autofix_count + 1))
  CONFLICT_FILES=$(git diff --name-only --diff-filter=U)
  echo "⚠️ rebase conflict (attempt $autofix_count/$MAX_AUTOFIX): $CONFLICT_FILES"

  # FRESH terminal resolves conflicts and continues the rebase
  AF_TASK=$(orca orchestration task-create \
    --task-title "autofix rebase $FEATURE_SLUG ($autofix_count)" \
    --spec "Resolve the merge conflicts in:\n$CONFLICT_FILES\nThen: git add -A && git rebase --continue. Do NOT push." \
    --json | jq -r '.result.task.id')
  AF_TERM=$(orca terminal create --worktree "id:$WT_ID" \
    --title "[autofix:$EXEC_AGENT] rebase $autofix_count" \
    --command "$(agent_command_for "$EXEC_AGENT")" --json | jq -r '.result.terminal.handle')
  orca orchestration dispatch --task "$AF_TASK" --to "$AF_TERM" --inject --json
  wait_for_worker "$AF_TASK"
  orca terminal close --terminal "$AF_TERM" --json

  # SUCCESS requires BOTH: the rebase has completed AND zero remaining ^UU files
  if ! rebase_in_progress && [ -z "$(git diff --name-only --diff-filter=U)" ]; then
    break
  fi
done

if rebase_in_progress || [ -n "$(git diff --name-only --diff-filter=U)" ]; then
  # Any autofix failure → HUMAN decision (native channel): manual resolve or PARK
  ask_user_via_native_channel "Rebase conflicts unresolved after $MAX_AUTOFIX autofix attempts." \
    options=["I resolved it manually — continue", "Park the feature"]
fi
```

The success check is deliberately strict: a completed `git rebase --continue`
alone is **not** sufficient — there must also be zero unmerged (`^UU`) paths
before the loop breaks.

### 11.3 Run the Project Tests

Run the project's own test command inside the feature worktree and record the
results in state (`phases.MERGING.test_results`):

```bash
( cd "$WT_PATH" && ./scripts/check-prerequisites.sh >/dev/null 2>&1 || true )
TEST_OUTPUT=$(cd "$WT_PATH" && <project test command> 2>&1)
TEST_EXIT=$?
state_update ".phases.MERGING.test_results = {command:\"<project test command>\", exit_code:$TEST_EXIT, ran_at:\"$(date -Iseconds)\"}"
```

Test failures do not auto-abort: they are fed into the integration review spec
(§11.4) and surfaced to the user if the review fails.

### 11.4 Integration Review (NEW in v2.2.0)

Before the PR is created, a **fresh review-agent terminal** reviews the
**whole feature** — not any single subtask. ≤ `MAX_INTEGRATION_REVIEW` (default
2) rounds.

```python
ir_round = 0
while ir_round < MAX_INTEGRATION_REVIEW:            # default 2
    spec = build_integration_review_spec(
        plan=plan_text,                              # the approved plan
        subtask_verdicts=collect_verdicts(),         # per-subtask PASS/FAIL + reasons
        test_results=phases.MERGING.test_results,    # §11.3
        diff="git diff origin/main...HEAD",          # three-dot diff of the whole feature
        mandate="READ-ONLY — do not modify any file",
    )
    ir_task = task_create(title=f"integration review r{ir_round}", spec=spec)
    ir_handle = terminal_create(fresh, title=f"[integration-review:{REVIEW_AGENT}] r{ir_round}")
    dispatch(task=ir_task, to=ir_handle, inject=True)
    verdict = await wait_worker_done(ir_task)
    terminal_close(ir_handle)
    record integration_review.rounds = ir_round + 1

    if verdict == "PASS":
        record integration_review.verdict = "PASS"; break

    ir_round += 1
    if ir_round < MAX_INTEGRATION_REVIEW:
        # FRESH fix terminal applies the findings and commits
        fix_task = task_create(title=f"integration fix r{ir_round}",
                               spec=build_integration_fix_spec(verdict.findings))
        fix_handle = terminal_create(fresh, title=f"[fix:{EXEC_AGENT}] integration r{ir_round}")
        dispatch(task=fix_task, to=fix_handle, inject=True)
        await wait_worker_done(fix_task)             # commits in the feature worktree
        # loop: ANOTHER fresh review terminal re-reviews
    else:
        record integration_review.verdict = "FAIL"
        human = await ask_user_via_native_channel(
            "Integration review failed after 2 rounds. Release anyway, or park the feature?",
            options=["Release anyway", "Park the feature"])
        # "Release anyway" → continue to §11.5 with the FAIL recorded in the PR body
        # "Park" → PARKED (§12)
```

### 11.5 Create the PR

```bash
PR_BODY=$(build_pr_body)   # contract below
PR_URL=$(cd "$WT_PATH" && gh pr create \
  --base main --head "$BRANCH" \
  --title "feat: $FEATURE_SLUG" \
  --body "$PR_BODY")
PR_EXIT=$?
if [ $PR_EXIT -ne 0 ]; then
  # ALWAYS check the exit code — never parse a URL out of a failed command
  echo "⚠️ gh pr create failed (exit $PR_EXIT): $PR_URL"
  # log, retry once; on second failure escalate to the user (native channel)
fi
state_update ".pr = {url:\"$PR_URL\", state:\"OPEN\", merged_at:null}"
```

**PR body contract** — the body must contain:

1. **Change summary** — what the feature does, from the approved plan.
2. **Artifacts** — table of produced/changed artifacts with paths.
3. **Per-subtask review rounds** — each subtask's id, verdict, and round count.
4. **Integration-review verdict** — rounds used and final verdict.
5. **`⚠️ DEGRADED DELIVERY` banner** — only when `delivery_mode == "degraded"`,
   listing dropped subtasks and their failure reasons.

### 11.6 PR Lifecycle Monitoring

Poll `gh pr view` every 60s. **Never create a decision gate inside the poll
loop** — monitoring is pure observation plus recorded transitions.

```bash
while :; do
  read PR_STATE PR_MERGE < <(cd "$WT_PATH" && gh pr view "$PR_URL" \
    --json state,mergeStateStatus -q '"\(.state) \(.mergeStateStatus)"')

  case "$PR_STATE" in
    MERGED)
      state_update ".pr.state = \"MERGED\" | .pr.merged_at = \"$(date -Iseconds)\""
      transition to CLEANING; break ;;
    CLOSED)
      state_update ".pr.state = \"CLOSED\""
      park_feature "PR closed without merge"; break ;;
    OPEN)
      # Changes Requested: reviewer feedback reaches the coordinator (via the
      # native channel, or on-demand `gh pr view --json reviews`) → fix round
      if changes_requested; then
        state_update ".pr.state = \"CHANGES_REQUESTED\""
        apply_pr_feedback    # see below — then keep monitoring
      fi ;;
  esac

  sleep "${PR_REVIEW_POLL_INTERVAL:-60}"   # ms→s per config timeouts_ms.pr_review_poll_interval
done
```

**Handling Changes Requested** — a FRESH pr-fix terminal applies the review
feedback, commits, and pushes; the poll loop above then keeps monitoring:

```bash
PF_TASK=$(orca orchestration task-create \
  --task-title "PR feedback fix $FEATURE_SLUG" \
  --spec "PR review feedback on $PR_URL:\n$pr_feedback\n\nApply the changes in the worktree at $WT_PATH, commit, and push. Then emit worker_done." \
  --json | jq -r '.result.task.id')
PF_TERM=$(orca terminal create --worktree "id:$WT_ID" \
  --title "[pr-fix:$EXEC_AGENT] $FEATURE_SLUG" \
  --command "$(agent_command_for "$EXEC_AGENT")" --json | jq -r '.result.terminal.handle')
orca orchestration dispatch --task "$PF_TASK" --to "$PF_TERM" --inject --json
wait_for_worker "$PF_TASK"        # worker commits + pushes; loop keeps monitoring
```

### 11.7 Output

```json
{
  "phase": "MERGING",
  "status": "complete",
  "pr": {
    "url": "https://github.com/org/repo/pull/123",
    "state": "MERGED",
    "merged_at": "2026-07-27T12:05:00Z"
  },
  "integration_review": {"rounds": 1, "verdict": "PASS"},
  "delivery_mode": "full",
  "timestamp": "2026-07-27T12:10:00Z"
}
```

---

## 12. Phase 8 — Cleanup & Archival

**Goal**: Reach a clean terminal state for the **feature** (not per subtask):
delete the merged branch + worktree, or preserve them with a parked manifest.
Handle **every** `pr_state` explicitly.

### 12.1 Entry Condition

- State: `CLEANING`
- `pr.state` is terminal: `MERGED` | `CLOSED` | `PARKED` (an `OPEN` PR at
  cleanup is a guard violation — see §12.2)

### 12.2 Process

```bash
PR_STATE=$(jq -r '.pr.state // "null"' "$STATE_FILE")

case "$PR_STATE" in
  MERGED)
    # Full cleanup: delete remote branch, remove the worktree, close terminals
    git push origin --delete "$BRANCH" || echo "WARN: branch delete failed (may need admin)"
    orca worktree rm --worktree "id:$WT_ID" --force --json
    # orca worktree rm removes the worktree; it deletes the local branch only
    # when the branch is fully merged (verified across two v2.2.0 smoke runs:
    # merged PR branch removed by orca, unmerged branch left behind). Delete
    # it explicitly so both cases are covered. Use -D (not -d): a squash- or
    # rebase-merged PR means the local tip is not an ancestor of main, so -d
    # would refuse. Missing branch is fine — orca may already have removed it.
    git branch -D "$BRANCH" 2>/dev/null || echo "INFO: local branch already gone"
    close_all_workflow_terminals      # includes keep_terminal(s)
    state_update '.phases.CLEANING.disposition = "MERGED"'
    ;;

  PARKED|CLOSED)
    # Preserve: write the parked manifest, KEEP worktree + branch, close terminals
    write_parked_manifest             # §12.3
    close_all_workflow_terminals
    state_update '.phases.CLEANING.disposition = "PARKED"'
    ;;

  OPEN|CHANGES_REQUESTED)
    # Guard: cleanup must never run on a live PR
    echo "WARN: pr_state=$PR_STATE at cleanup — refusing destructive actions; treating as PARKED"
    write_parked_manifest
    state_update '.phases.CLEANING.disposition = "PARKED_GUARD"'
    ;;

  *)
    echo "WARN: unexpected pr_state='$PR_STATE'; no destructive actions taken"
    ;;
esac

# ONE history line per workflow — jsonl append (this is NOT the state file)
echo "{\"workflow_id\":\"$WORKFLOW_ID\",\"feature_slug\":\"$FEATURE_SLUG\",\"branch\":\"$BRANCH\",\"pr_url\":\"$PR_URL\",\"pr_state\":\"$PR_STATE\",\"delivery_mode\":\"$DELIVERY_MODE\",\"timestamp\":\"$(date -Iseconds)\"}" \
  >> .orca/workflow-history.jsonl

# Afterwards the coordinator runs ONLY: git fetch origin  (never checkout, never pull --rebase)
git fetch origin
```

### 12.3 Parked Manifest

`.orca/parked/<feature-slug>.md`:

```markdown
# Parked Feature: add-user-prefs

- **Branch**: `feature/add-user-prefs`
- **Worktree path**: `../add-user-prefs`
- **PR**: https://github.com/org/repo/pull/123 (state: CLOSED)
- **Parked at**: 2026-07-27T12:15:00Z
- **Reason**: PR closed without merge
- **Stacked context**: n/a (v2.2.0 uses a single feature branch — no stacks)

## Recovery Steps
1. `cd ../add-user-prefs`
2. `git fetch origin main && git rebase origin/main`
3. Resolve any conflicts, then `git push --force-with-lease origin feature/add-user-prefs`
4. Reopen the PR (or create a new one) and re-run the integration review (§11.4)
5. Resume the workflow at Phase 7

## Subtask Verdicts
- sub-1 (prefs-api): PASS, 1 review round
- sub-2 (prefs-ui): PASS, 0 review rounds
```

### 12.4 Atomic State Writes

**Every** update to `.orca/workflow-state.json` goes through jq with an atomic
tmp-file + `mv`. Never append JSON with `>>` (the `.jsonl` history file above
is the only exception — it is line-delimited, not a JSON document):

```bash
state_update() {   # usage: state_update '<jq filter>'
  local tmp; tmp=$(mktemp .workflow-state.XXXXXX)
  jq "$1" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}
```

### 12.5 User Notification

```bash
# Via the coordinator's NATIVE channel:
echo "🎉 Workflow complete — $DELIVERY_REPORT"
# MERGED: PR url + summary of what shipped
# PARKED: pointer to .orca/parked/<feature-slug>.md with recovery steps
```

### 12.6 Output

```json
{
  "phase": "CLEANING",
  "status": "complete",
  "disposition": "MERGED",
  "branch_deleted": true,
  "worktree_removed": true,
  "parked_manifest": null,
  "timestamp": "2026-07-27T12:15:00Z"
}
```

---

## 13. Observability & Logging

> Moved to [`references/observability.md`](./references/observability.md) —
> the workflow state-file example, terminal `role` enum, log levels, and key
> metrics to track.

---

## 14. Error Recovery Matrix

| Failure Scenario | Detection | Automatic Recovery | Manual Recovery |
|-----------------|-----------|-------------------|-----------------|
| Orca becomes unreachable | `orca status` fails | Retry 3x with 5s backoff | Restart Orca, reload state from `.orca/workflow-state.json` |
| Task circuit breaker (3 consecutive failures on one task) | dispatch/check errors referencing the same task id | **Never re-dispatch the same task** — create a NEW task chained with `--parent` and dispatch it to a fresh terminal | Inspect why the task keeps failing before creating the next one |
| Lost `worker_done` (worker finished but the event never arrived) | `check --wait` timeout with the task still `dispatched` | Timeout = checkpoint: `dispatch-show` → `last_heartbeat_at` stale + `terminal read`/`terminal wait --for tui-idle` shows the worker IDLE → collect the result from the terminal output / `task-list` and mark the task completed (recovery override). Heartbeat fresh or terminal active = still working — keep waiting, never close/restart for silence alone | If the terminal is truly dead, close it and dispatch a NEW task to a fresh terminal |
| **owns violation** (worker wrote outside its `owns`) | Coordinator `git status --porcelain` / `git diff` check after each round shows paths outside the subtask's `owns` globs | Coordinator reverts the offending files (`git checkout -- <paths>`; `git clean -fd <paths>` for untracked), records an error, counts the round as FAIL with feedback | Persistent violations → fail the subtask, let Phase 6 decide |
| Plan review loops indefinitely | `review_round >= MAX_REVIEW_ROUNDS` | Escalate to the user (native channel, up to 2x) | User provides direction or terminates |
| Subtask wall-clock timeout | Elapsed > `timeout_ms` | `task-update --status failed` + `orca terminal close`; Phase 6 decides | Increase timeout, retry the subtask |
| Rebase produces unresolvable conflicts | Non-zero rebase after ≤2 autofix rounds | Escalate to the user with conflict details | User resolves manually or the feature is PARKED |
| Integration review never passes | `rounds >= MAX_INTEGRATION_REVIEW` with FAIL | Escalate to the user | Release anyway (verdict recorded in PR body) or PARK |
| `gh pr create` fails | Non-zero exit code (always checked) | Log, retry once | User creates the PR manually |
| PR CI blocked | `gh pr view` shows `mergeStateStatus: BLOCKED` | Fresh fix terminal reads the failure and pushes a fix | User investigates the CI failure |
| User abandons (no response on the native channel) | Response timeout | Persist state, exit cleanly | Resume from saved state when the user returns |
| Disk full during artifact write | Worker reports write error | Mark subtask FAIL | Free disk space, retry |

---

## 15. Security & Permission Model

### 15.1 Honest Isolation Model

**A git worktree is not a sandbox.** In v2.2.0 all subtasks share one feature
worktree, so any worker terminal can *technically* write anywhere in it.
Isolation is an **`owns` convention enforced by the coordinator**, not by the
filesystem:

1. Every worker preamble restricts writes to the subtask's `owns` globs (§8.5).
2. After **each round**, the coordinator runs `git status --porcelain` /
   `git diff --name-only <base_sha>..HEAD` in the feature worktree and maps
   changed paths against the subtask's `owns`. Anything outside is reverted
   (`git checkout -- <paths>` / `git clean -fd <paths>`) and recorded as an
   owns violation (§14).
3. Review and integration-review terminals are read-only **by preamble
   mandate**; the coordinator additionally verifies they produced no diff
   outside `owns` (for subtask reviews) or no diff at all (for reviews).

### 15.2 Boundaries

| Operation | Permission Required | Agent Capability |
|-----------|-------------------|-----------------|
| Read files in the feature worktree | File system access (default) | All worker terminals |
| Write files inside own `owns` globs | File system access (default) | Execution / fix / fallback / pr-fix terminals |
| Write files outside own `owns` globs | Convention — **reverted by the coordinator** after each round | No agent (enforced via §15.1) |
| Commit on the feature branch | Git credentials (local) | Execution / fix / fallback / autofix / pr-fix terminals (small commits) |
| Review diff `<base_sha>..HEAD` | Read-only | Review / integration-review terminals |
| `git push` (feature branch) | Git credentials configured | Coordinator only (Phase 7, §11.6) |
| `git push --delete` (feature branch) | Branch delete permission | Coordinator only (Phase 8) |
| `gh pr create` | GitHub token with `repo` scope | Coordinator only (Phase 7) |
| `gh pr merge` | Write access to target branch | **Human only — never automated** |
| `orca orchestration dispatch` / `task-create` / `task-update` | Orca runtime access | Coordinator only |
| `orca orchestration ask --to <coordinator>` | Orca runtime access | **Workers → coordinator only**; the coordinator asks the USER via its native channel |
| `orca worktree create` / `orca worktree rm` | Orca runtime access | Coordinator only (Phase 4 / Phase 8 — once per feature) |
| `orca terminal create` / `orca terminal close` | Orca runtime access | Coordinator only (every round, every role) |

### 15.3 Principles

1. **Coordinator-Enforced Ownership**: `owns` is a convention; the enforcement
   is the coordinator's post-round verification + revert loop (§15.1), not the
   filesystem. Plan-review disjointness validation (§6.3) keeps same-wave
   workers from legitimately needing the same paths.
2. **Least Privilege**: Workers can commit locally but cannot push, merge,
   delete branches, or create PRs. All of those are coordinator-only.
3. **No Automated Merge**: The workflow NEVER merges a PR. Human approval is
   always required.
4. **Single Push Path**: Pushes happen only from the coordinator in Phase 7
   (initial PR + pr-fix follow-ups); subtask workers never push.
5. **Immutable Audit Trail**: All decisions, terminal spawns, and state
   transitions are written to `.orca/workflow-state.json` (jq atomic writes)
   before being acted upon; `tasks.subtasks[*].terminals[]` is the per-round
   audit trail.
6. **Secret Isolation**: GitHub tokens and API keys come from the environment /
   credential store — never hardcoded in task specs, preambles, or the PR body.

---

## 16. Testing & Validation

> Moved to [`references/runbooks.md`](./references/runbooks.md) — dry-run
> mode, the per-phase validation checklist, and the integration test scenario.

---

## 17. Operational Runbooks

> Moved to [`references/runbooks.md`](./references/runbooks.md) — starting,
> resuming (parked), crash-recovery, and cancelling runbooks.

---

## 18. API Command Reference

> Moved to [`references/api-reference.md`](./references/api-reference.md) —
> the verified Orca CLI surface: `orca orchestration` / `worktree` /
> `terminal` commands and the external git/gh/jq commands.

---

## Appendix A: Full Workflow Diagram

See [`docs/workflow.md`](./docs/workflow.md) for the complete Mermaid flowchart with all states, transitions, and termination conditions.

## Appendix B: Example Walkthrough

See [`examples/basic-workflow.md`](./examples/basic-workflow.md) for a step-by-step annotated example.

## Appendix C: State File Schema

See [`.orca/workflow-state.schema.json`](./.orca/workflow-state.schema.json) for the JSON Schema definition of the state file.

---

> **Next Steps**: `cd` into your project's Orca-managed main checkout, run
> `./scripts/check-prerequisites.sh`, then describe your task to the
> coordinator agent in chat. The coordinator will guide you through each phase.
> For first-time setup, see [Prerequisites](#3-prerequisites--environment).
