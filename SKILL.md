---
name: multi-agent-workflow
version: 2.0.1
author: orca-workflow-team
tags: [orchestration, multi-agent, workflow, supervisor, cicd]
description: >
  Production-grade multi-agent orchestration workflow for Orca IDE.
  Implements a full lifecycle pipeline: requirements gathering → plan generation
  & review → user confirmation → task decomposition → parallel execution with
  sub-review → result aggregation & decision → PR-based merge → archival.
  Built on `orca orchestration` primitives (task-create, dispatch, gate-create,
  ask, run) with hard cycle caps, human-in-the-loop fallbacks, degraded-delivery
  exits, and full observability. Invoke this skill whenever the user needs to
  decompose a complex task across multiple agents, coordinate parallel workstreams,
  or execute a structured development pipeline from spec to merge.
applyTo: "**/*"
---

# Multi-Agent Orchestration Workflow — Production Skill

> **Version**: 2.0.1 &ensp;|&ensp; **Runtime**: Orca IDE ≥ 1.x &ensp;|&ensp; **License**: MIT
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

```
┌──────────────────────────────────────────────────────────────────┐
│                     COORDINATOR (This Agent)                      │
│  ┌─────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────────┐  │
│  │ Phase 1 │→│ Phase 2  │→│ Phase 3  │→│    Phase 4        │  │
│  │ Gather  │  │ Plan+Rev │  │ Confirm  │  │ Decompose+Dispatch│  │
│  └─────────┘  └──────────┘  └──────────┘  └───────┬──────────┘  │
│                                                    │             │
│              one worktree + branch + first terminal per sub-task │
│                                                    │             │
│                              ┌─────────────────────┼──────┐      │
│                              │  PER-SUBTASK WORKTREES   │      │
│                              │   (stacked branches)     │      │
│                              │                        │      │
│                              │  ┌──────┐  ┌──────┐  ┌──────┐│    │
│                              │  │Sub-1 │  │Sub-2 │  │Sub-3 ││    │
│                              │  │wt+br │  │wt+br │  │wt+br ││    │
│                              │  │ ↓    │  │ ↓    │  │ ↓    ││    │
│                              │  │ term0│→ │ term0│  │ term0││    │
│                              │  │ exec │  │ exec │  │ exec ││    │
│                              │  │ ↓    │  │ ↓    │  │ ↓    ││    │
│                              │  │term1 │  │term1 │  │term1 ││    │
│                              │  │review│  │review│  │review││    │
│                              │  │ ...  │  │ ...  │  │ ...  ││    │
│                              │  └──┬───┘  └──┬───┘  └──┬───┘│    │
│                              │     │ stacked│        │     │    │
│                              │     │  ◄─────┘        │     │    │
│                              └─────┼────────────────┼─────┘    │
│  ┌──────────┐  ┌──────────┐       │        │        │            │
│  │ Phase 6  │←─┤ Collect  │←──────┴────────┴────────┘            │
│  │ Decide   │  │ All Done │   (one PR + worktree cleanup per     │
│  └────┬─────┘  └──────────┘    sub-task, in dependency order)    │
│       │                                                            │
│  ┌────┴─────┐  ┌──────────┐  ┌──────────┐                        │
│  │ Phase 7  │→│ Phase 8  │→│  Notify  │                        │
│  │PR/Merge  │  │ Cleanup  │  │  User    │                        │
│  │per-sub   │  │per-wt    │  │          │                        │
│  └─────────┘  └──────────┘  └──────────┘                        │
└──────────────────────────────────────────────────────────────────┘
```

### v2.1.0 — What's Different from v2.0.x

| Aspect | v2.0.x (legacy) | v2.1.0 |
|--------|------------------|--------|
| Worktree | One shared `feature/<slug>-<ts>` for the whole workflow | **One per sub-task**: `feature/<wf>/<sub>-<ts>` |
| Branch base | Always `main` | **Stacked**: deps-less → `main`; dependent → parent sub-task's branch |
| PR | One bundle PR for all sub-tasks | **One per sub-task**; dependent PRs start as draft |
| Review loop | Same worker terminal self-reviews up to MAX_SUB_RETRY | **Fresh terminal per round**: implement → review (new) → fix (new) → review (new) → … |
| Cross-review | Self-review only | **Cross-agent**: implement with `claude`/`kimi`, review with `pi` (see `docs/agent-routing.md`) |
| Parallelism safety | Sub-agents can clobber each other in shared worktree | Each sub-task has its own worktree; no cross-task contention |

### Design Principles

| Principle | Implementation |
|-----------|---------------|
| **Per-Subtask Isolation** | Each sub-task owns a dedicated worktree + branch + set of terminals; sub-tasks never share filesystem state |
| **Stacked Branches for Dependencies** | Dependent sub-tasks branch off parent tips (not main); preserves parallelism; auto-rebases onto `main` when the parent PR merges |
| **Per-Round Fresh Agent** | Implementation, cross-review, and fix are each a separate `orca terminal create` invocation in the same worktree — no Agent context reuse, no carry-over bias |
| **Fail-Safe by Default** | Every loop has a hard cap; no infinite retries |
| **Human-in-the-Loop at High-Value Gates** | Escalation only at plan-review, per-subtask merge-conflict, and parked-subtask boundaries |
| **Collect-All-Then-Decide** | Sub-task failures do NOT interrupt sibling sub-tasks; all results aggregate before the global retry decision |
| **Per-Subtask PR + No Direct Merge** | No direct `git merge`; each sub-task integrates through its own PR; dependent PRs auto-rebase onto `main` when the parent merges |
| **Immutable Audit Trail** | Every decision gate, escalation, terminal spawn, and PR transition is logged to `.orca/workflow-state.json` (with `subtask_id` scope since v2.1.0) |
| **Degraded Delivery over Total Failure** | When retries are exhausted, completed sub-tasks merge independently; failed sub-tasks are parked with per-subtask recovery manifests |

---

## 2. State Machine

v2.1.0 introduces a **per-sub-task subgraph** under `DISPATCHING`/`EXECUTING`/`MERGING`/`CLEANING`. The workflow-level state advances only when **all** sub-tasks reach the corresponding state; an individual sub-task can be `PARKED` without terminating the workflow.

```
                    ┌─────────┐
                    │  INIT   │
                    └────┬────┘
                         │
              ┌──────────┴──────────┐
              ▼                     ▼
        ┌──────────┐         ┌──────────────┐
        │GATHERING │         │ TERMINATED   │
        │(Phase 1) │         │ (any phase)  │
        └────┬─────┘         └──────────────┘
             │
        ┌────┴─────┐
        │ PLANNING  │◄──── Feedback / Retry ────┐
        │(Phase 2)  │──► ESCALATED ──► (Term?)  │
        └────┬─────┘                            │
             │                                  │
        ┌────┴─────┐                            │
        │CONFIRMING│──► REJECTED ───────────────┘
        │(Phase 3) │──► FORCE_TERMINATE
        └────┬─────┘
             │
        ┌────┴────────┐
        │DISPATCHING  │◄─── Retry Failed Items ───┐
        │(Phase 4)    │   (per-subtask worktrees) │
        └────┬────────┘                            │
             │ for each sub-task (topo order):      │
             │   create wt+br, spawn first terminal │
             ▼                                     │
        ┌──────────────────────────────────┐       │
        │ EXECUTING  (per-subtask, parallel)│       │
        │ ┌──────────────────────────────┐ │       │
        │ │ round 0: implement (new term)│ │       │
        │ │ round 1: review   (new term) │ │       │
        │ │ round 2: fix      (new term) │ │       │
        │ │ round 3: review   (new term) │ │       │
        │ │ ... up to MAX_SUB_RETRY      │ │       │
        │ │ pass → exit to MERGING_sub-N │ │       │
        │ │ fail → SUB_FAILURES ─────────┼─┼──► Phase 6
        │ └──────────────────────────────┘ │       │
        │ ... one block per sub-task ...   │       │
        └──────────────┬───────────────────┘       │
                       │ all sub-tasks done        │
        ┌──────────────▼───────────┐              │
        │ DECIDING  (Phase 6)      │              │
        │ RETRY ───────────────────┼──────────────┘
        │ DEGRADE / ESCALATE_SUB   │
        └──────────────┬───────────┘
                       │
        ┌──────────────▼───────────────────────┐
        │ MERGING  (Phase 7, per-subtask)      │
        │ for each sub-task (topo order):      │
        │   rebase onto base_branch            │
        │   push + gh pr create --base parent  │
        │   wait human gate                    │
        │   on parent merge → rebase + flip    │
        │ PARKED (per-subtask, recoverable)    │
        └──────────────┬───────────────────────┘
                       │ all merged / parked
        ┌──────────────▼───────────────────────┐
        │ CLEANING  (Phase 8, per-subtask,     │
        │ reverse-topo order)                  │
        │ delete branch, remove worktree,      │
        │ close keep_terminal, write park md   │
        └──────────────┬───────────────────────┘
                       │
                ┌──────┴──────┐
                ▼             ▼
          ┌────────┐    ┌────────────┐
          │  DONE  │    │TERMINATED  │
          └────────┘    └────────────┘
```

### State Transition Table

| From | Trigger | To | Guard |
|------|---------|----|-------|
| `INIT` | User request received | `GATHERING` | — |
| `GATHERING` | Requirements clear | `PLANNING` | Q1 = yes |
| `GATHERING` | Max clarification rounds | `TERMINATED` | > 5 rounds |
| `PLANNING` | Review passed | `CONFIRMING` | Q2 = yes |
| `PLANNING` | Review rounds exhausted + escalate ≤ 2 | `PLANNING` | Escalate → human input → retry |
| `PLANNING` | Escalate count > 2 | `TERMINATED` | Terminate1 |
| `CONFIRMING` | User approves | `DISPATCHING` | — |
| `CONFIRMING` | User rejects (retries < 3) | `PLANNING` | Feedback collected |
| `CONFIRMING` | User rejects (retries ≥ 3) | `TERMINATED` | Terminate2 or force-continue |
| `DISPATCHING` | All sub-tasks have worktree+branch+first terminal | `EXECUTING` | — |
| `DISPATCHING` | Sub-task creation failed (infra) | `TERMINATED` | Coordinator-side failure only; per-subtask failures don't terminate dispatch |
| `EXECUTING.sub-N` | Cross-review PASS | `EXECUTING` (waiting on siblings) | All sub-tasks must reach this for workflow to advance |
| `EXECUTING.sub-N` | Round budget exhausted | `EXECUTING.sub-N` (FAIL) | Per-sub-task failure; siblings continue |
| `EXECUTING` | All sub-tasks have terminal verdict | `DECIDING` | — |
| `DECIDING` | All sub-tasks passed | `MERGING` | AllOK = yes |
| `DECIDING` | Retry (global retries < 2) | `DISPATCHING` | Only failed sub-tasks get new worktree+branch |
| `DECIDING` | Degrade | `MERGING` | PartialOK flag set; passed sub-tasks continue to PR |
| `DECIDING` | Escalate → human aborts | `TERMINATED` | Terminate3 |
| `MERGING.sub-N` | Parent merged → rebase + flip base | `MERGING.sub-N` (rebase) | Only if this sub-task has deps |
| `MERGING.sub-N` | PR merged | `MERGING` (waiting on siblings) | — |
| `MERGING.sub-N` | Auto-fix exhausted + human parks | `MERGING.sub-N` (PARKED) | Per-sub-task parking; siblings continue |
| `MERGING` | All sub-tasks merged or parked | `CLEANING` | — |
| `CLEANING.sub-N` | Worktree + branch removed + keep_terminal closed | `CLEANING` (next sibling) | Reverse-topo order |
| `CLEANING` | All sub-tasks cleaned | `DONE` | — |

---

## 3. Prerequisites & Environment

### 3.1 Runtime Checks

```bash
# 1. Verify Orca is running and reachable
orca status --json | jq -e '.ok and .result.app.running and .result.runtime.reachable' \
  || { echo "FATAL: Orca is not running or unreachable"; exit 1; }

# 2. Verify at least one worker terminal is available.
#    Default policy (matches scripts/check-prerequisites.sh):
#    - ORCA_WORKFLOW_STRICT_PREREQ=true  → FATAL: workflow cannot run parallel
#      subtasks without a worker. Production / CI should set this.
#    - ORCA_WORKFLOW_STRICT_PREREQ=false → WARN: the coordinator falls back to
#      acting as the sole worker. Default for local dev and smoke tests.
WORKER_COUNT=$(orca terminal list --json | jq '[.result.terminals[] | select(.type == "worker")] | length')
if [ "$WORKER_COUNT" -lt 1 ]; then
  if [ "${ORCA_WORKFLOW_STRICT_PREREQ:-false}" = "true" ]; then
    echo "FATAL: No worker terminals available. Create one with: orca terminal create --type worker"
    exit 1
  else
    echo "WARN: No worker terminals available — solo mode (coordinator = sole worker)."
  fi
fi

# 3. Verify worktree is clean (no uncommitted changes blocking branch creation)
git diff --quiet && git diff --cached --quiet \
  || { echo "WARN: Working directory has uncommitted changes. Stash or commit before proceeding."; }
```

### 3.2 Required Tools

| Tool | Version | Check Command | Purpose |
|------|---------|---------------|---------|
| Orca IDE | ≥ 1.x | `orca status --json` | Orchestration runtime |
| Git | ≥ 2.30 | `git --version` | Version control |
| GitHub CLI | ≥ 2.0 | `gh --version` | PR creation & management |
| jq | ≥ 1.6 | `jq --version` | JSON parsing in shell |

### 3.3 Environment Variables

> 完整列表及优先级参见 [`docs/agent-routing.md`](./docs/agent-routing.md#环境变量覆盖)。

```bash
# === 流程限制（覆盖 workflow.limits.*）===
export ORCA_WORKFLOW_MAX_REVIEW_ROUNDS=${ORCA_WORKFLOW_MAX_REVIEW_ROUNDS:-3}
export ORCA_WORKFLOW_MAX_ESCALATE=${ORCA_WORKFLOW_MAX_ESCALATE:-2}
export ORCA_WORKFLOW_MAX_USER_CONFIRM=${ORCA_WORKFLOW_MAX_USER_CONFIRM:-3}
export ORCA_WORKFLOW_MAX_SUB_RETRY=${ORCA_WORKFLOW_MAX_SUB_RETRY:-3}
export ORCA_WORKFLOW_MAX_GLOBAL_RETRY=${ORCA_WORKFLOW_MAX_GLOBAL_RETRY:-2}
export ORCA_WORKFLOW_MAX_AUTOFIX=${ORCA_WORKFLOW_MAX_AUTOFIX:-2}

# === 路径与日志 ===
export ORCA_WORKFLOW_STATE_FILE="${ORCA_WORKFLOW_STATE_FILE:-.orca/workflow-state.json}"
export ORCA_WORKFLOW_LOG_LEVEL="${ORCA_WORKFLOW_LOG_LEVEL:-INFO}"

# === 行为开关 ===
# true  → check-prerequisites.sh 缺失 worker 时返回 FAIL（生产 / CI 推荐）
# false → 允许 solo / dry-run（coordinator 自身作为唯一 worker；本地与冒烟测试默认）
export ORCA_WORKFLOW_STRICT_PREREQ="${ORCA_WORKFLOW_STRICT_PREREQ:-false}"

# === Agent 路由（覆盖 docs/agent-routing.md）===
export ORCA_WORKFLOW_PLAN_AGENT="${ORCA_WORKFLOW_PLAN_AGENT:-Plan}"
export ORCA_WORKFLOW_REVIEW_AGENT="${ORCA_WORKFLOW_REVIEW_AGENT:-pi}"
export ORCA_WORKFLOW_EXECUTION_AGENT="${ORCA_WORKFLOW_EXECUTION_AGENT:-claude}"
export ORCA_WORKFLOW_COMPLEX_EXECUTION_AGENT="${ORCA_WORKFLOW_COMPLEX_EXECUTION_AGENT:-kimi}"
export ORCA_WORKFLOW_IMAGE_AGENT="${ORCA_WORKFLOW_IMAGE_AGENT:-grok}"
export ORCA_WORKFLOW_FALLBACK_AGENT="${ORCA_WORKFLOW_FALLBACK_AGENT:-pi}"
# 通用任务失败后的兜底链（逗号分隔，优先级从高到低）
export ORCA_WORKFLOW_FALLBACK_CHAIN="${ORCA_WORKFLOW_FALLBACK_CHAIN:-grok,pi}"

# === 模拟 ===
export ORCA_WORKFLOW_DRY_RUN="${ORCA_WORKFLOW_DRY_RUN:-false}"
```

---

## 4. Configuration

### 4.1 Tunable Parameters

> 📖 **Agent 选型（routing）详见 [`docs/agent-routing.md`](./docs/agent-routing.md)** —— 单一起源。
> 修改偏好只改 `agent-routing.md` 与对应的 `ORCA_WORKFLOW_*` 环境变量；不要把 agent 名称硬编码进任务 spec。
>
> 下方配置中 `routing.*_agent_type` 仅作冷启动默认值；运行时实际生效的是 `agent-routing.md` + env override。

```json
{
  "workflow": {
    "version": "2.0.1",
    "limits": {
      "max_review_rounds": 3,
      "max_escalate_count": 2,
      "max_user_confirm_rounds": 3,
      "max_subtask_retries": 3,
      "max_global_retries": 2,
      "max_autofix_attempts": 2,
      "max_clarification_rounds": 5
    },
    "timeouts_ms": {
      "worker_execution": 1800000,
      "human_response": 0,
      "pr_review_poll_interval": 60000
    },
    "routing": {
      "_note": "见 docs/agent-routing.md（单一起源）。",
      "plan_agent_type": "Plan",
      "review_agent_type": "pi",
      "execution_agent_type": "claude",
      "complex_execution_agent_type": "kimi",
      "image_agent_type": "grok",
      "fallback_agent_type": "pi",
      "default_model": "sonnet"
    },
    "terminals": {
      "_note": "Worker 终端需预先创建并打标签。模型选择在 terminal create 时通过 --command 指定，dispatch 层不支持传 model。"
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

```
clarification_round = 0

while clarification_round < MAX_CLARIFICATION_ROUNDS:
    gaps = analyze_request(user_input)

    if gaps is empty:
        emit REQUIREMENTS_READY event
        transition to PLANNING
        break

    clarification_round += 1
    response = await orca orchestration ask \
      --to coordinator \
      --question "Before I proceed, I need to clarify:\n{gaps_formatted}\n\nPlease provide details."

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
  "timestamp": "2026-07-26T10:00:00Z"
}
```

### 5.5 Error Handling

| Error | Severity | Action |
|-------|----------|--------|
| User unresponsive (> 5 min with no reply to `ask`) | WARN | Retry once with a reminder; if still no response, persist state and exit with `TIMEOUT` |
| User request contradicts itself | WARN | Flag contradiction explicitly in the `ask`; do not guess |
| `orca orchestration ask` command fails | FATAL | Log error, check Orca connectivity, exit |

---

## 6. Phase 2 — Plan Generation & Review

**Goal**: Generate a technical plan document and have it pass review (max review rounds, with human escalation fallback).

### 6.1 Entry Condition

- State: `PLANNING`
- Input: Clarified requirement from Phase 1

### 6.2 Process

```python
review_round = 0
escalate_count = 0

# Step 1: Create the plan-generation task
plan_task_id = task_create(
    title=f"Plan: {requirement_summary}",
    display_name="📝 Plan Agent",
    spec=f"""Based on the following requirement, produce a detailed technical plan document.

Requirement:
{clarified_requirement}

Output format:
1. Executive Summary (≤ 5 lines)
2. Technical Approach (architecture, stack, key decisions)
3. Implementation Steps (ordered, with estimated effort)
4. Risk Assessment (top 3 risks with mitigations)
5. Acceptance Criteria (measurable, testable)

Write in markdown. Be concrete — no hand-waving."""
)

# Step 2: Dispatch to worker
dispatch(task_id=plan_task_id, to=select_worker("plan"))

# Step 3: Wait for worker_done, then enter review loop
while review_round < MAX_REVIEW_ROUNDS:
    # Wait for plan artifact
    plan_doc = await wait_for_artifact(plan_task_id)

    # Create review gate
    gate_result = gate_create_and_await(
        task=plan_task_id,
        question=f"""Review the technical plan against these criteria:
1. Completeness: Does it cover all aspects of the requirement?
2. Feasibility: Is each step technically achievable?
3. Clarity: Can an execution agent follow it without ambiguity?
4. Risk: Are the top 3 risks identified with credible mitigations?

Respond: PASS (all criteria met) or FAIL with specific issues listed.""",
        options=["PASS", "FAIL"]
    )

    if gate_result == "PASS":
        emit PLAN_APPROVED event
        transition to CONFIRMING
        break

    review_round += 1
    if review_round < MAX_REVIEW_ROUNDS:
        # Re-dispatch with feedback
        task_update(plan_task_id, status="pending")
        dispatch(
            task=plan_task_id,
            to=select_worker("plan"),
            inject=True,
            preamble=f"Previous plan was rejected. Address these issues:\n{gate_result.feedback}"
        )
    else:
        # Escalate to human
        escalate_count += 1
        if escalate_count <= MAX_ESCALATE_COUNT:
            human_response = await ask_coordinator(
                f"⚠️ Plan review failed after {MAX_REVIEW_ROUNDS} rounds (escalation {escalate_count}/{MAX_ESCALATE_COUNT}).\n\n"
                f"Disagreement points:\n{gate_result.feedback}\n\n"
                f"Please provide direction or choose to terminate.",
                options=["Provide direction (free-text)", "Terminate — plan cannot converge"]
            )
            if human_response == "Terminate":
                transition to TERMINATED (Terminate1)
                break
            # Reset review round, incorporate human direction
            review_round = 0
            task_update(plan_task_id, status="pending")
            dispatch(plan_task_id, preamble=f"Human direction: {human_response}\nGenerate revised plan.")
        else:
            transition to TERMINATED (Terminate1)
            break
```

### 6.3 Shell Implementation

```bash
# Create plan task
PLAN_TASK=$(orca orchestration task-create \
  --task-title "Plan: ${REQUIREMENT_SUMMARY}" \
  --display-name "📝 Plan Agent" \
  --spec "..." \
  --json | jq -r '.result.task.id')

# Select plan worker
PLAN_WORKER=$(orca terminal list --json | jq -r '.result.terminals[] | select(.tags[]? == "plan") | .handle' | head -1)
[ -z "$PLAN_WORKER" ] && PLAN_WORKER=$(orca terminal list --json | jq -r '.result.terminals[0].handle')

# Dispatch
orca orchestration dispatch --task "$PLAN_TASK" --to "$PLAN_WORKER" --inject --json

# Create review gate — routed per routing.review_agent_type
orca orchestration gate-create \
  --task "$PLAN_TASK" \
  --question "Review the technical plan. PASS or FAIL with reasons?" \
  --options '["PASS","FAIL"]' \
  --json
```

### 6.4 Output

```json
{
  "phase": "PLANNING",
  "status": "complete",
  "plan_task_id": "task_xxx",
  "review_rounds": 2,
  "escalate_count": 0,
  "plan_artifact": "path/to/plan.md",
  "review_verdict": "PASS",
  "timestamp": "2026-07-26T10:15:00Z"
}
```

---

## 7. Phase 3 — User Confirmation

**Goal**: Present the approved plan to the user for final sign-off before execution begins.

### 7.1 Entry Condition

- State: `CONFIRMING`
- Input: Approved plan artifact from Phase 2

### 7.2 Process

```
confirm_round = 0

while confirm_round < MAX_USER_CONFIRM:
    response = await ask_coordinator(
        f"✅ Technical plan has passed internal review.\n\n"
        f"Summary:\n{plan_summary}\n\n"
        f"Do you approve this plan?",
        options=[
            "Approve — begin execution",
            "Revise — provide feedback",
            "Reduce scope — keep partial work only (no PR / no worktree)",
            "Abort — cancel the task"
        ]
    )

    if response == "Approve":
        transition to DISPATCHING
        break

    confirm_round += 1
    if confirm_round < MAX_USER_CONFIRM:
        if response == "Revise":
            # Collect feedback, return to Phase 2 with reset review counter
            transition to PLANNING (with user_feedback)
        elif response == "Reduce scope":
            # User explicitly limits side-effects. Record scope_reduction in state,
            # skip Phase 4 worktree creation, ship artifacts in-place, mark
            # delivery_mode=degraded even when all subtasks pass.
            set_scope_reduction_flag({
                "skip_worktree": true,
                "skip_pr": true,
                "reason": user_reason
            })
            transition to DISPATCHING (in-place, no worktree)
        elif response == "Abort":
            transition to TERMINATED (Terminate2)
    else:
        # Force decision
        force = await ask_coordinator(
            f"Plan has been revised {confirm_round} times without approval.\n"
            f"Current state: {plan_summary}\n\n"
            f"Choose: continue revising, or terminate.",
            options=["Continue revising", "Terminate"]
        )
        if force == "Continue revising":
            confirm_round = 0  # reset
            transition to PLANNING
        else:
            transition to TERMINATED (Terminate2)
```

#### 7.2.1 Scope-Reduction Contract

When the user chooses **"Reduce scope"** at Phase 3, the workflow records
`scope_reduction` in the state file and applies these skip rules:

| Phase | Default | Scope-Reduced |
|-------|---------|---------------|
| 4 (Dispatch) | Create `feature/*` worktree | **No new worktree** — operate on the active worktree |
| 5 (Execute) | Workers write into worktree | Workers write into the active worktree |
| 6 (Decide) | `delivery_mode: full` when all pass | `delivery_mode: degraded` (state-only, no PR) |
| 7 (Merge) | `gh pr create` + lifecycle gate | **Skipped** — record `skip_reason: user scope reduction` |
| 8 (Cleanup) | Remove worktree + branch | `disposition: SKIPPED`, no destructive ops |

This is distinct from the **Degraded Delivery** contract in §10.4, which is
triggered by subtask *failures*. Scope-reduction is a user-declared outcome
that applies even when every subtask passes.

### 7.3 Output

```json
{
  "phase": "CONFIRMING",
  "status": "complete",
  "confirm_rounds": 1,
  "user_decision": "APPROVE",
  "timestamp": "2026-07-26T10:20:00Z"
}
```

---

## 8. Phase 4 — Task Decomposition & Dispatch

**Goal**: Break the approved plan into a DAG of subtasks. For **each** sub-task, create its own branch + worktree, and spawn the **first execution terminal** attached to that worktree. Stacked branches preserve parallelism when sub-tasks have dependencies.

### 8.1 Entry Condition

- State: `DISPATCHING`
- Input: Approved plan + user confirmation
- `branch_strategy.mode` from `.orca/workflow-config.json` (default `stacked`)

### 8.2 Task Decomposition Schema

Each subtask must declare:

```json
{
  "id": "sub-1",
  "title": "Research & Analysis",
  "description": "Investigate the target codebase and identify integration points",
  "dependencies": [],
  "complexity": "general",
  "expected_artifact": "research-notes.md",
  "review_criteria": [
    "All integration points identified",
    "Dependencies documented",
    "Risks flagged"
  ],
  "timeout_ms": 600000
}
```

#### Agent Routing Rules

> 📖 **Agent 选型详见 [`docs/agent-routing.md`](./docs/agent-routing.md)**。
> 所有偏好集中在一个文件，修改时只需编辑它。

`complexity` / `task_type` 字段决定 worker 匹配到哪个 `routing.*_agent_type` 配置项：
- `"complex"` → `complex_execution_agent_type`
- `"image"` → `image_agent_type`
- `"general"` 或未设置 → `execution_agent_type`
- 所有重试耗尽 → `fallback_agent_type`（兜底）

v2.1.0 新增：`task_role`（`execution` / `review` / `fix`）决定 *哪个* Agent 跑这一轮。`execution` 用上面的 `execution_agent_type`；`review` 强制用 `review_agent_type`（默认 `pi`）；`fix` 复用 `execution_agent_type`，并允许在 spec 里覆写为 `complex_execution_agent_type`。

### 8.3 Process — per-subtask worktree + branch + first terminal

```bash
WORKFLOW_SLUG="${TASK_SLUG}"   # from plan, e.g. "add-user-prefs"
TS="$(date +%Y%m%d-%H%M)"
BRANCH_TPL="${ORCA_WORKFLOW_BRANCH_TEMPLATE:-feature/{workflow_slug}/{sub_slug}-{timestamp}}"
WT_PATH_TPL="${ORCA_WORKFLOW_WORKTREE_PATH_TEMPLATE:-../{workflow_slug}-{sub_slug}}"

# Step 1: sort sub-tasks topologically so deps are created first
TOPO_IDS=($(topo_sort "${SUBTASK_IDS[@]}"))

# Step 2: for each sub-task, create its own wt+branch+terminal
DISPATCH_FAILED=()
for SUB in "${TOPO_IDS[@]}"; do
  # 8.3.1 Resolve base branch (stacked-branches rule)
  if [ "${#SUB_DEPS[$SUB]}" -eq 0 ]; then
    BASE_BRANCH="main"
  else
    # Base off the FIRST parent's branch (linearized stacks; for diamond DAGs
    # we rebase onto all parents in §8.4.1).
    PARENT="${SUB_DEPS[$SUB][0]}"
    BASE_BRANCH="${SUBTASK_BRANCH[$PARENT]}"
  fi

  SUB_SLUG="${SUB_SLUGS[$SUB]}"   # e.g. "prefs-api"
  BRANCH="$(apply_template "$BRANCH_TPL" workflow_slug="$WORKFLOW_SLUG" sub_slug="$SUB_SLUG" timestamp="$TS")"
  WT_PATH="$(apply_template "$WT_PATH_TPL"  workflow_slug="$WORKFLOW_SLUG" sub_slug="$SUB_SLUG")"

  # 8.3.2 Create the worktree
  git fetch origin "$BASE_BRANCH"
  orca worktree create --name "$BRANCH" --base "origin/$BASE_BRANCH" "$WT_PATH"

  # 8.3.3 Stacked: rebase onto parent tip if parent is local-only
  if [ "$BASE_BRANCH" != "main" ] && [ "$BASE_BRANCH" != "origin/main" ]; then
    ( cd "$WT_PATH" && git rebase "$BASE_BRANCH" ) || {
      echo "⚠️  Failed to base $BRANCH off $BASE_BRANCH — escalating"
      DISPATCH_FAILED+=("$SUB")
      continue
    }
  fi

  # 8.3.4 Spawn the FIRST execution terminal attached to this worktree
  EXEC_AGENT_TYPE=$(resolve_agent_type "${SUB_COMPLEXITIES[$SUB]}")
  EXEC_TERMINAL=$(orca terminal create \
    --worktree "$BRANCH" \
    --title "sub-$SUB r0 execution ($EXEC_AGENT_TYPE)" \
    --command "$(agent_command_for "$EXEC_AGENT_TYPE")" \
    --tags "$EXEC_AGENT_TYPE" \
    --json | jq -r '.result.terminal.handle')

  # 8.3.5 Create orchestration task + dispatch into the new terminal
  TASK_ID=$(orca orchestration task-create \
    --task-title "Sub: ${SUB_TITLES[$SUB]}" \
    --display-name "🔧 ${SUB_DISPLAY[$SUB]}" \
    --spec "${SUB_SPECS[$SUB]}" \
    --deps "$(echo ${SUB_DEPS[$SUB]} | jq -c '.')" \
    --json | jq -r '.result.task.id')

  orca orchestration dispatch \
    --task "$TASK_ID" \
    --to "$EXEC_TERMINAL" \
    --inject \
    --json > "/tmp/dispatch-${TASK_ID}.json" 2>&1 || DISPATCH_FAILED+=("$SUB")

  # 8.3.6 Record in state so Phase 5/7/8 can find the worktree + terminal
  record_subtask_state "$SUB" \
    worktree_path="$WT_PATH" \
    branch_name="$BRANCH" \
    base_branch="$BASE_BRANCH" \
    status="dispatched" \
    keep_terminal="$EXEC_TERMINAL"

  append_terminal_history "$SUB" \
    handle="$EXEC_TERMINAL" \
    role="execution" \
    round=0 \
    agent_type="$EXEC_AGENT_TYPE"

  SUBTASK_MAP["$SUB"]="$TASK_ID"
done

if [ "${#DISPATCH_FAILED[@]}" -gt 0 ]; then
  echo "⚠️  Phase 4 dispatch failed for: ${DISPATCH_FAILED[*]}"
  echo "DISPATCH_FAILED=${DISPATCH_FAILED[*]}" >> "$STATE_FILE"
fi
```

### 8.4 Worker Selection Logic

`select_worker` now resolves **two** things at once: which **Agent** to run (via `task_type`) and which **role** (via `task_role`). The result is a *new* terminal per call — never a reuse.

```bash
# Returns: {handle, agent_type} of a freshly-spawned terminal for this role.
spawn_terminal_for_role() {
  local sub_id="$1"
  local task_type="${2:-general}"
  local task_role="${3:-execution}"     # execution | review | fix
  local round="${4:-0}"

  case "$task_role" in
    review)    agent_type="${ORCA_WORKFLOW_REVIEW_AGENT}" ;;
    fix)
      # Fix rounds may escalate to the complex-execution Agent if the spec
      # marks the sub-task as complex.
      if [ "${SUB_COMPLEXITIES[$sub_id]}" = "complex" ]; then
        agent_type="${ORCA_WORKFLOW_COMPLEX_EXECUTION_AGENT}"
      else
        agent_type="${ORCA_WORKFLOW_EXECUTION_AGENT}"
      fi
      ;;
    *)
      # execution round (round 0)
      case "$task_type" in
        complex) agent_type="${ORCA_WORKFLOW_COMPLEX_EXECUTION_AGENT}" ;;
        image)   agent_type="${ORCA_WORKFLOW_IMAGE_AGENT}" ;;
        *)       agent_type="${ORCA_WORKFLOW_EXECUTION_AGENT}" ;;
      esac
      ;;
  esac

  # Match a tagged worker terminal — if none tagged, fall back to the first
  # available. The terminal may still need to be created if the pool is empty.
  local handle
  handle=$(orca terminal list --json | jq -r --arg type "$agent_type" --arg role "$task_role" '
    [.result.terminals[] | select(.tags[]? == $type or .tags[]? == $role)] | .[0].handle // .result.terminals[0].handle
  ')

  # v2.1.0: spawn a NEW terminal every time. The dispatch layer reuses the
  # handle only for routing; the runtime context inside is fresh.
  local branch="${SUBTASK_BRANCH[$sub_id]}"
  local new_handle
  new_handle=$(orca terminal create \
    --worktree "$branch" \
    --title "sub-$sub_id r$round $task_role ($agent_type)" \
    --command "$(agent_command_for "$agent_type")" \
    --tags "$agent_type,$task_role" \
    --json | jq -r '.result.terminal.handle')

  echo "$new_handle $agent_type"
}
```

#### 报错兜底逻辑（per-subtask, per-round）

通用任务失败后按优先级链 **开新终端** 重试。Agent 列表由 `docs/agent-routing.md` 定义：

```bash
retry_with_fallback() {
  local sub_id="$1"
  local task_id="$2"
  local task_type="${3:-general}"
  # 从环境变量读取兜底链，格式: "agent1,agent2,agent3"
  IFS=',' read -ra agents <<< "${ORCA_WORKFLOW_FALLBACK_CHAIN:-}"

  for agent in "${agents[@]}"; do
    # Spawn a FRESH terminal tagged with this fallback agent
    local handle branch
    handle=$(orca terminal create \
      --worktree "${SUBTASK_BRANCH[$sub_id]}" \
      --title "sub-$sub_id fallback ($agent)" \
      --command "$(agent_command_for "$agent")" \
      --tags "$agent,fallback" \
      --json | jq -r '.result.terminal.handle')

    orca orchestration dispatch --task "$task_id" --to "$handle" --inject --json
    wait_for_worker "$task_id"

    if [[ "$(get_task_verdict "$task_id")" == "PASS" ]]; then
      append_terminal_history "$sub_id" handle="$handle" role="fallback" round=-1 agent_type="$agent"
      return 0
    fi
    orca terminal close --handle "$handle"   # failed fallback terminal torn down
    echo "⚠️ $agent failed, trying next..."
  done

  echo "❌ All agents exhausted for sub-$sub_id"
  return 1
}
```

### 8.5 Injected Preamble (sent to each fresh terminal)

Every terminal — whether round-0 execution, review, fix, or fallback — receives the same preamble shape via `dispatch --inject`. The `Role` and `Round` lines are filled in per the spawning call:

```text
You are executing subtask "{title}" (sub-{sub_id}) as part of a multi-agent workflow.

Role: {execution | review | fix | fallback}
Round: {round}
Worktree: {worktree_path} (branch {branch_name})
Base: {base_branch}

## Rules
1. You are ONE round of a sub-task. Other rounds — including cross-review — are
   spawned as separate terminals by the coordinator; do NOT try to review your
   own output.
2. If you are execution/fix: produce the artifact in the worktree above, then
   set status=completed with result={"verdict":"PASS","artifact":"path"}.
   If you are review: cross-review the latest commits/files in the worktree
   against {review_criteria}, then set status=completed with
   result={"verdict":"PASS"} or {"verdict":"FAIL","reason":"..."}.
3. Do NOT alert the coordinator on failure — the coordinator collects all results.
4. When done, emit worker_done per your terminal's preamble protocol.

## Context
{plan_summary}

## Your Task
{spec}

## Previous round feedback (review/fix only)
{prior_feedback}
```

### 8.6 Output

```json
{
  "phase": "DISPATCHING",
  "status": "complete",
  "subtasks": [
    {
      "id": "sub-1",
      "logical_id": "prefs-api",
      "orchestration_id": "task_xxx",
      "worktree_path": "../add-user-prefs-prefs-api",
      "branch_name": "feature/add-user-prefs/prefs-api-20260727-1030",
      "base_branch": "main",
      "keep_terminal": "term_yyy",
      "terminals": [{"handle":"term_yyy","role":"execution","round":0,"agent_type":"claude"}]
    },
    {
      "id": "sub-2",
      "logical_id": "prefs-ui",
      "orchestration_id": "task_aaa",
      "worktree_path": "../add-user-prefs-prefs-ui",
      "branch_name": "feature/add-user-prefs/prefs-ui-20260727-1030",
      "base_branch": "feature/add-user-prefs/prefs-api-20260727-1030",
      "keep_terminal": "term_bbb",
      "terminals": [{"handle":"term_bbb","role":"execution","round":0,"agent_type":"claude"}]
    }
  ],
  "timestamp": "2026-07-27T10:30:00Z"
}
```

---

## 9. Phase 5 — Parallel Execution & Sub-Review

**Goal**: Each sub-task independently goes through a **per-round cross-review** loop. **Every round spawns a fresh terminal** in the sub-task's worktree — no Agent context is reused across rounds. The coordinator does not intervene until all sub-tasks reach a terminal verdict.

### 9.1 Entry Condition

- State: `EXECUTING`
- Every sub-task has `worktree_path`, `branch_name`, `base_branch`, and a `keep_terminal` (round-0 execution terminal) recorded in state from Phase 4

### 9.2 Per-Sub-Task Round Loop

```
MAX_SUB_RETRY = ORCA_WORKFLOW_MAX_SUB_RETRY  (default 3)

For each sub-task (parallel across sub-tasks):

  round = 0
  last_verdict = null
  last_feedback = null

  while round <= MAX_SUB_RETRY:
    if round == 0:
      # Round 0's execution terminal was created in Phase 4 and dispatched
      # there. Wait for it; don't spawn a new one.
      exec_handle = subtask.keep_terminal
      role = "execution"
      task_id = subtask.orchestration_id
    else:
      # Subsequent rounds: ALWAYS spawn a fresh terminal
      exec_handle, exec_agent = spawn_terminal_for_role(
        sub_id=subtask.id,
        task_type=subtask.complexity,
        task_role="fix",         # round > 0 means fix-after-review
        round=round,
      )
      role = "fix"
      task_id = f"fix-{subtask.id}-r{round}"
      subtask.keep_terminal = exec_handle   # newest implementation wins
      append_terminal_history(subtask.id, handle=exec_handle, role="execution", round=round, agent_type=exec_agent)

    # Dispatch (or wait, for round 0) and block until verdict
    if round > 0:
      dispatch_and_wait(
        task_id=task_id,
        to=exec_handle,
        spec=build_fix_spec(subtask, last_feedback),
        timeout_ms=subtask.timeout_ms,
      )
    else:
      wait_for_worker(task_id, timeout_ms=subtask.timeout_ms)

    close_intermediate_terminals_for_round(subtask.id, role)   # not the keep_terminal

    # ---- Cross-review: a fresh terminal with the review agent ----
    review_handle, review_agent = spawn_terminal_for_role(
      sub_id=subtask.id,
      task_type="general",
      task_role="review",
      round=round,
    )
    append_terminal_history(subtask.id, handle=review_handle, role="review", round=round, agent_type=review_agent)

    review_task_id = f"review-{subtask.id}-r{round}"
    review_verdict = dispatch_and_wait(
      task_id=review_task_id,
      to=review_handle,
      spec=build_review_spec(subtask, latest_diff=subtask.worktree_path),
      timeout_ms=subtask.timeout_ms,
    )
    orca terminal close --handle "$review_handle"   # reviewer is read-only; torn down after verdict

    if review_verdict == "PASS":
      last_verdict = "PASS"
      break
    else:
      last_feedback = review_verdict.reason
      round += 1
      if round > MAX_SUB_RETRY:
        last_verdict = "FAIL"
        break
      # Loop continues: fresh execution terminal will be spawned at the top

  record_subtask_state(subtask.id, status="completed", verdict=last_verdict, review_rounds=round)
```

**Key invariants**:
- Round 0's execution terminal is reused from Phase 4 (no double-spawn).
- Every round > 0 spawns a **fresh** execution terminal tagged with the fix Agent.
- Every round's review terminal is a **fresh** terminal tagged with the review Agent.
- Reviewer terminals are torn down after verdict — they don't carry state.
- The most recent execution terminal is `keep_terminal` and survives until Phase 8.

### 9.3 Coordinator-Side Wait

The coordinator drives the loop in §9.2 for every sub-task **in parallel**. Sub-task loops don't block each other — `wait_for_worker` is per-task. The coordinator only collects results when **all** sub-tasks reach `verdict=PASS|FAIL`.

```bash
# Fan out: launch the per-sub-task loop concurrently
declare -A SUBTASK_VERDICTS
while :; do
  ALL_DONE=true
  for SUB in "${TOPO_IDS[@]}"; do
    local v="${SUBTASK_VERDICTS[$SUB]:-}"
    if [ -z "$v" ]; then
      # not done yet — check the latest verdict in state
      v=$(jq -r --arg id "$SUB" '.tasks.subtasks[] | select(.id == $id) | .verdict' "$STATE_FILE")
      SUBTASK_VERDICTS["$SUB"]="$v"
    fi
    if [ -z "$v" ]; then ALL_DONE=false; fi
  done
  $ALL_DONE && break
  sleep 5
done

echo "All subtasks have completed."
```

### 9.4 Timeout Handling

If any **terminal** exceeds its `timeout_ms`, that terminal is closed and the sub-task fails that round (or escalates to Phase 6 if it's the keep_terminal).

```bash
# Per-terminal timeout enforced inside dispatch_and_wait via:
#   - signal SIGTERM after timeout_ms
#   - then `orca terminal close --handle "$handle"`
#   - record verdict=FAIL reason="Terminal timeout after ${ms}ms"

orca orchestration task-update \
  --id "$TIMED_OUT_TASK_ID" \
  --status "failed" \
  --result '{"verdict":"FAIL","reason":"Terminal timeout","round":-1}' \
  --json
```

### 9.5 Output

```json
{
  "phase": "EXECUTING",
  "status": "complete",
  "subtask_results": [
    {
      "id": "sub-1",
      "verdict": "PASS",
      "artifact": "research-notes.md",
      "review_rounds": 1,
      "worktree_path": "../add-user-prefs-prefs-api",
      "branch_name": "feature/add-user-prefs/prefs-api-20260727-1030",
      "terminals": [
        {"handle":"term_yyy","role":"execution","round":0,"agent_type":"claude","verdict":"PASS"},
        {"handle":"term_rrr","role":"review",   "round":0,"agent_type":"pi",   "verdict":"FAIL"},
        {"handle":"term_zzz","role":"execution","round":1,"agent_type":"claude","verdict":"PASS"},
        {"handle":"term_sss","role":"review",   "round":1,"agent_type":"pi",   "verdict":"PASS"}
      ],
      "keep_terminal": "term_zzz"
    },
    {"id":"sub-2","verdict":"FAIL","reason":"Cross-review never passed after 3 rounds","review_rounds":3}
  ],
  "timestamp": "2026-07-27T11:00:00Z"
}
```

---

## 10. Phase 6 — Aggregation & Decision

**Goal**: Collect all subtask results (pass + fail), analyze, and decide next action.

### 10.1 Entry Condition

- State: `DECIDING`
- All workers have reported done

### 10.2 Decision Matrix

```
global_retry_count = 0

analyze_results(all_subtask_results):

  if all passed:
    transition to MERGING
    return

  failed = [r for r in all_subtask_results if r.verdict == "FAIL"]

  while global_retry_count < MAX_GLOBAL_RETRIES:
    decision = present_decision_to_coordinator(
      passed=len(passed),
      failed=failed,
      retry_count=global_retry_count
    )

    switch decision:
      case "RETRY_FAILED":
        global_retry_count += 1
        if global_retry_count < MAX_GLOBAL_RETRIES:
          transition to DISPATCHING (only failed items)
          return
        else:
          force_escalate()

      case "DEGRADE_DELIVER":
        set_partial_delivery_flag()
        transition to MERGING
        return

      case "ESCALATE_HUMAN":
        human_decision = await ask_coordinator(
          f"{len(failed)} subtasks failed (global retry {global_retry_count}/{MAX_GLOBAL_RETRIES}).\n"
          f"Failed: {format_failures(failed)}\n"
          f"Passed: {len(passed)} items ready.\n\n"
          f"What should we do?",
          options=["Retry failed items", "Accept partial delivery", "Abort"]
        )
        switch human_decision:
          case "Retry": → continue loop
          case "Accept partial": → set_partial_delivery_flag(); transition to MERGING; return
          case "Abort": → transition to TERMINATED (Terminate3); return
```

### 10.3 Shell Implementation

```bash
# Gather results
PASSED=()
FAILED=()
for TASK_ID in "${SUBTASK_ORCH_IDS[@]}"; do
  RESULT=$(orca orchestration task-list --json | jq -r --arg id "$TASK_ID" \
    '.result.tasks[] | select(.id == $id) | .result')
  VERDICT=$(echo "$RESULT" | jq -r '.verdict')
  if [ "$VERDICT" = "PASS" ]; then
    PASSED+=("$TASK_ID")
  else
    FAILED+=("$TASK_ID")
  fi
done

if [ ${#FAILED[@]} -eq 0 ]; then
  echo "✅ All subtasks passed. Proceeding to merge."
else
  echo "⚠️ ${#FAILED[@]} subtask(s) failed: ${FAILED[*]}"
  # Present decision to coordinator
  orca orchestration ask \
    --to coordinator \
    --question "${#FAILED[@]} subtask(s) failed. Passed: ${#PASSED[@]}.\nFailed: ${FAILED[*]}\n\nChoose action:" \
    --options "Retry failed items,Degrade (deliver passed items only),Abort"
fi
```

### 10.4 Degraded Delivery Contract

When `DEGRADE_DELIVER` is chosen:

1. A `PARTIAL_DELIVERY.md` manifest is created listing:
   - ✅ Delivered artifacts
   - ❌ Failed items with reason and suggested manual follow-up
2. The PR description includes a `⚠️ PARTIAL DELIVERY` banner
3. The state file records `delivery_mode: "degraded"`

### 10.5 Output

```json
{
  "phase": "DECIDING",
  "status": "complete",
  "all_passed": false,
  "decision": "DEGRADE_DELIVER",
  "passed_count": 2,
  "failed_count": 1,
  "global_retries_used": 1,
  "delivery_mode": "degraded",
  "timestamp": "2026-07-26T11:05:00Z"
}
```

---

## 11. Phase 7 — Merge & Pull Request

**Goal**: Generate a change summary, check for conflicts, create a PR, and guide it to completion.

### 11.1 Entry Condition

- State: `MERGING`
- All artifacts ready (full or degraded)

### 11.2 Change Summary Generation

The coordinator generates a structured PR body:

```markdown
## Summary
{brief description of all changes}

## Artifacts
| # | Subtask | Status | Artifact |
|---|---------|--------|----------|
| 1 | Research | ✅ | research-notes.md |
| 2 | Writing  | ✅ | draft.md |
| 3 | Graphics | ❌ | N/A — image API unavailable |

## Files Changed
{git diff --stat output}

## Verification
- [ ] All review gates passed
- [ ] No dangerous keyword hits
- [ ] Acceptance criteria met

## ⚠️ Partial Delivery (if applicable)
The following items could not be completed and require manual follow-up:
- **Graphics**: Image generation API was unavailable after 3 retries.
  Suggested: use an alternative service (Midjourney, DALL·E) or source from stock.
```

### 11.3 Conflict Check & Auto-Fix

```bash
autofix_count=0

while [ $autofix_count -lt $MAX_AUTOFIX ]; do
  # Fetch latest base
  git fetch origin main

  # Check for merge conflicts
  if git merge-base --is-ancestor origin/main HEAD; then
    echo "✅ No conflicts — branch is ahead of main."
    break
  fi

  # Attempt rebase
  if git rebase origin/main 2>/dev/null; then
    echo "✅ Rebase succeeded."
    break
  fi

  # Conflict detected
  autofix_count=$((autofix_count + 1))
  CONFLICT_FILES=$(git diff --name-only --diff-filter=U)

  echo "⚠️ Merge conflict detected (attempt $autofix_count/$MAX_AUTOFIX)"
  echo "Conflicting files: $CONFLICT_FILES"

  if [ $autofix_count -lt $MAX_AUTOFIX ]; then
    # Attempt AI-assisted conflict resolution
    echo "Attempting auto-resolution..."
    # The coordinator (this agent) reads conflict markers and resolves
    # If successful → continue loop
    # If not → break to human escalation
    if ! auto_resolve_conflicts "$CONFLICT_FILES"; then
      break
    fi
  fi
done

if [ $autofix_count -ge $MAX_AUTOFIX ] || ! git rebase --continue 2>/dev/null; then
  # Escalate to human
  orca orchestration ask \
    --to coordinator \
    --question "⚠️ Unable to auto-resolve merge conflicts after $autofix_count attempts.\n\nConflicting files:\n$CONFLICT_FILES\n\nPlease resolve manually or choose to park." \
    --options "Resolved — continue,Park — keep branch for later"
fi
```

### 11.4 PR Creation (PR-Only Path)

```bash
# Push branch
git push -u origin "$BRANCH"

# Create PR
PR_URL=$(gh pr create \
  --title "${TASK_TITLE}" \
  --body "$(cat /tmp/pr_body.md)" \
  --base main \
  --head "$BRANCH" \
  2>&1)

echo "PR created: $PR_URL"
```

### 11.5 PR Lifecycle Monitoring

```bash
while true; do
  PR_STATE=$(gh pr view --json state,mergeStateStatus -q '[.state, .mergeStateStatus] | join(",")')

  case "$PR_STATE" in
    "OPEN,BLOCKED")
      echo "PR is blocked (likely conflicts or CI). Checking..."
      # The coordinator can attempt to fix and push
      ;;
    "OPEN,CLEAN"|"OPEN,UNKNOWN")
      echo "PR is open and clean. Waiting for review..."
      # Create a gate to wait for human review
      orca orchestration gate-create \
        --task "$PR_TASK_ID" \
        --question "PR ${PR_URL} is ready for review. Status?" \
        --options '["Approved & Merged","Changes Requested","Closed"]' \
        --json
      ;;
    "MERGED,"*)
      echo "✅ PR merged."
      transition to CLEANING
      break
      ;;
    "CLOSED,"*)
      echo "⚠️ PR was closed without merging."
      transition to CLEANING (with park flag)
      break
      ;;
  esac

  sleep "${PR_REVIEW_POLL_INTERVAL:-60}"
done
```

### 11.6 Handling Review Feedback

When a PR receives change requests:

```bash
# Apply fixes
git checkout "$BRANCH"
# ... make changes ...

# Commit and push to same branch
git add -A
git commit -m "fix: address PR review feedback"
git push origin "$BRANCH"

# The PR updates automatically — return to monitoring loop
```

### 11.7 Output

```json
{
  "phase": "MERGING",
  "status": "complete",
  "pr_url": "https://github.com/org/repo/pull/123",
  "pr_state": "MERGED",
  "autofix_attempts": 0,
  "delivery_mode": "full",
  "timestamp": "2026-07-26T12:00:00Z"
}
```

---

## 12. Phase 8 — Cleanup & Archival

**Goal**: Remove temporary resources, archive state, and notify the user.

### 12.1 Entry Condition

- State: `CLEANING`
- PR merged or parked

### 12.2 Merged Path — Full Cleanup

```bash
# Delete remote branch
git push origin --delete "$BRANCH"

# Remove local worktree
orca worktree remove "$BRANCH"

# Switch back to main
git checkout main
git pull

# Record completion
cat >> .orca/workflow-history.jsonl << EOF
{"workflow_id":"$WORKFLOW_ID","status":"COMPLETED","branch":"$BRANCH","timestamp":"$(date -Iseconds)"}
EOF
```

### 12.3 Parked Path — Archival

```bash
# Create parked task manifest
mkdir -p .orca/parked

cat > ".orca/parked/${BRANCH}.md" << PARK_EOF
# Parked Workflow: ${TASK_TITLE}

- **Branch**: \`${BRANCH}\`
- **Worktree path**: \`${WORKTREE_PATH}\`
- **Parked at**: $(date -Iseconds)
- **Reason**: ${PARK_REASON}
- **PR**: ${PR_URL}

## Recovery Steps
1. \`cd "${WORKTREE_PATH}"\`
2. \`git fetch origin && git rebase origin/main\`
3. Resolve any new conflicts
4. \`gh pr edit ${PR_URL} --add-label "ready-for-review"\` or create a new PR
5. Resume from Phase 7 of the workflow

## Artifacts
$(ls -1 artifacts/)
PARK_EOF

echo "Workflow parked. Recovery instructions: .orca/parked/${BRANCH}.md"
```

### 12.4 User Notification

```bash
DELIVERY_REPORT=$(generate_delivery_report)

orca orchestration ask \
  --to coordinator \
  --question "🎉 Workflow complete!\n\n${DELIVERY_REPORT}\n\nArtifacts are in the workspace." \
  --timeout-ms 0
```

### 12.5 Output

```json
{
  "phase": "CLEANING",
  "status": "complete",
  "disposition": "MERGED",
  "branch_deleted": true,
  "worktree_removed": true,
  "park_manifest": null,
  "timestamp": "2026-07-26T12:05:00Z"
}
```

---

## 13. Observability & Logging

### 13.1 Workflow State File

A single JSON file at `.orca/workflow-state.json` tracks the entire run:

```json
{
  "workflow_id": "wf_20260726_001",
  "version": "2.0.0",
  "started_at": "2026-07-26T10:00:00Z",
  "current_phase": "EXECUTING",
  "current_state": "EXECUTING",
  "phases": {
    "GATHERING": {
      "status": "complete",
      "entered_at": "2026-07-26T10:00:00Z",
      "exited_at": "2026-07-26T10:05:00Z",
      "clarification_rounds": 2
    }
  },
  "tasks": {
    "plan": {"id": "task_xxx", "status": "completed", "verdict": "PASS"},
    "subtasks": [
      {"id": "task_yyy", "status": "completed", "verdict": "PASS", "artifact": "..."},
      {"id": "task_zzz", "status": "completed", "verdict": "FAIL", "reason": "..."}
    ]
  },
  "decisions": [
    {"gate": "plan_review", "result": "PASS", "round": 2, "timestamp": "..."},
    {"gate": "sub_failure_decision", "decision": "DEGRADE", "timestamp": "..."}
  ],
  "delivery_mode": "full",
  "termination_reason": null
}
```

### 13.2 Log Levels

| Level | When to Use |
|-------|------------|
| `DEBUG` | Every gate creation, task dispatch, poll iteration |
| `INFO` | Phase transitions, decisions, normal progress |
| `WARN` | Retries triggered, clarifications needed, timeouts |
| `ERROR` | Task failures, conflict detection, escalate triggers |
| `FATAL` | Orca connectivity loss, unrecoverable state corruption |

### 13.3 Key Metrics to Track

- `workflow.total_duration_ms`
- `workflow.phase_duration_ms{phase="PLANNING"}`
- `workflow.review_rounds_total`
- `workflow.escalation_count_total`
- `workflow.subtask_pass_rate`
- `workflow.global_retries_used`
- `workflow.delivery_mode{full|degraded}`

---

## 14. Error Recovery Matrix

| Failure Scenario | Detection | Automatic Recovery | Manual Recovery |
|-----------------|-----------|-------------------|-----------------|
| Orca becomes unreachable | `orca status` fails | Retry 3x with 5s backoff | Restart Orca, reload state from `.orca/workflow-state.json` |
| Worker terminal dies mid-execution | Task stuck in `dispatched` > timeout | Re-dispatch to a new worker with context from state file | `orca terminal create --type worker` |
| Plan review loops indefinitely | `review_round >= MAX_REVIEW_ROUNDS` | Escalate to human (up to 2x) | Human provides direction or terminates |
| Subtask times out | Wall clock > `timeout_ms` | Mark as FAIL, let Phase 6 decide | Increase timeout, re-dispatch |
| Git rebase produces unresolvable conflicts | `git rebase` exits non-zero after auto-fix attempts | Escalate to human with conflict details | Human resolves manually or parks |
| PR CI fails | `gh pr view` shows `mergeStateStatus: BLOCKED` | Coordinator reads CI logs and attempts fix | Human investigates CI failure |
| User abandons (no response to `ask`) | `ask` timeout + follow-up timeout | Persist state, exit cleanly | Resume from saved state when user returns |
| Disk full during artifact write | Worker reports write error | Mark subtask FAIL | Free disk space, re-dispatch |

---

## 15. Security & Permission Model

### 15.1 Boundaries

| Operation | Permission Required | Agent Capability |
|-----------|-------------------|-----------------|
| Read files in workspace | File system access (default) | All agents |
| Write files in workspace | File system access (default) | Execution agents only |
| `git push` to remote | Git credentials configured | Coordinator only (Phase 7) |
| `git push --delete` | Force-push permission on branch | Coordinator only (Phase 8) |
| `gh pr create` | GitHub token with `repo` scope | Coordinator only (Phase 7) |
| `gh pr merge` | Write access to target branch | Human only (never automated) |
| `orca orchestration dispatch` | Orca runtime access | Coordinator only |
| `orca orchestration gate-resolve` | Orca runtime access | Designated reviewer agents |
| `orca worktree remove` | Orca runtime access | Coordinator only (Phase 8) |

### 15.2 Principles

1. **Least Privilege**: Workers can only read/write within their worktree; they cannot merge or delete branches.
2. **No Automated Merge**: The workflow NEVER auto-merges a PR. Human approval is always required.
3. **Immutable Audit Trail**: All decisions and state transitions are written to `.orca/workflow-state.json` before being acted upon.
4. **Secret Isolation**: GitHub tokens and API keys are read from environment/credential store, never hardcoded in task specs.

---

## 16. Testing & Validation

### 16.1 Dry-Run Mode

Set `ORCA_WORKFLOW_DRY_RUN=true` to simulate without side effects:

```bash
export ORCA_WORKFLOW_DRY_RUN=true
```

In dry-run mode:
- `task-create` prints the spec but does not create tasks
- `dispatch` prints the preamble but does not inject
- `gh pr create` prints the PR body but does not push
- `git push` is replaced with `git push --dry-run`

### 16.2 Phase Validation Checklist

After each phase, validate:

- [ ] **Phase 1**: Clarified requirement is non-empty and has ≥ 3 concrete details
- [ ] **Phase 2**: Plan artifact exists, review verdict is PASS
- [ ] **Phase 3**: User confirmation recorded with timestamp
- [ ] **Phase 4**: All subtasks created, deps form a valid DAG (no cycles)
- [ ] **Phase 5**: All workers reported done (completed or failed)
- [ ] **Phase 6**: Decision recorded (retry/degrade/escalate)
- [ ] **Phase 7**: PR URL is valid, git state is clean
- [ ] **Phase 8**: Worktree removed or park manifest created

### 16.3 Integration Test Scenario

```bash
# Test the full workflow with a trivial task
export ORCA_WORKFLOW_DRY_RUN=true
export ORCA_WORKFLOW_STRICT_PREREQ=false   # allow solo runs in CI

# Write the spec to a temp file (any markdown describing the task)
cat > /tmp/spec.md <<'EOF'
# Hello-World Smoke Test

## Goal
Write a hello-world script in Python that prints "Hello, World!".

## Scope
- Single file `hello.py`
- No tests required (smoke test only)

## Constraints
- Python 3.10+
- No external dependencies

## Acceptance Criteria
- `python hello.py` exits 0 with stdout "Hello, World!"
EOF

# Start the coordinator with the spec file
orca orchestration run --spec /tmp/spec.md

# Verify state file was written correctly
jq '.phases | keys' .orca/workflow-state.json
# Expected: ["GATHERING","PLANNING","CONFIRMING","DISPATCHING","EXECUTING","DECIDING","MERGING","CLEANING"]
```

---

## 17. Operational Runbooks

### 17.1 Starting a New Workflow

```bash
# 1. Navigate to the project worktree
cd /path/to/project

# 2. Verify prerequisites
./scripts/check-prerequisites.sh

# 3. Write the spec to a markdown file
cat > /tmp/task.md <<'EOF'
# <Title>
## Goal
...
## Scope
...
## Acceptance Criteria
...
EOF

# 4. Start the coordinator with the spec file
orca orchestration run --spec /tmp/task.md

# The coordinator will prompt for any clarifications via Phase 1
```

### 17.2 Resuming a Parked Workflow

```bash
# 1. Find the parked manifest
ls .orca/parked/

# 2. Read recovery instructions
cat .orca/parked/feature-my-task-20260726.md

# 3. Follow the recovery steps in the manifest
cd /path/to/parked/worktree
git rebase origin/main

# 4. Re-enter the workflow at Phase 7
orca orchestration gate-create \
  --task "$PR_TASK_ID" \
  --question "Resume parked PR review" \
  ...
```

### 17.3 Recovering from a Crash

```bash
# 1. Load the saved state
STATE=$(cat .orca/workflow-state.json)
CURRENT_PHASE=$(echo "$STATE" | jq -r '.current_phase')

# 2. Determine recovery action
case "$CURRENT_PHASE" in
  "GATHERING"|"PLANNING"|"CONFIRMING")
    echo "Early phase — restart from beginning is safe."
    # Reset and start over
    ;;
  "DISPATCHING"|"EXECUTING")
    echo "Mid phase — check which tasks need re-dispatch."
    # Query task-list for incomplete tasks and re-dispatch
    ;;
  "DECIDING"|"MERGING"|"CLEANING")
    echo "Late phase — resume from saved decision state."
    # Continue from the last decision point
    ;;
esac
```

### 17.4 Cancelling a Running Workflow

```bash
# Graceful cancellation
orca orchestration run-stop

# Mark all in-flight tasks as failed
for TASK_ID in $(orca orchestration task-list --json | jq -r '.result.tasks[] | select(.status == "dispatched") | .id'); do
  orca orchestration task-update --id "$TASK_ID" --status "failed" \
    --result '{"verdict":"FAIL","reason":"Workflow cancelled by user"}'
done

# Persist state
echo '{"status":"CANCELLED","cancelled_at":"'$(date -Iseconds)'"}' >> .orca/workflow-state.json
```

---

## 18. API Command Reference

### 18.1 `orca orchestration` Commands Used

| Command | Phase(s) | Purpose |
|---------|----------|---------|
| `task-create` | 2, 4 | Create plan tasks and subtasks |
| `task-list` | 5, 6 | Poll task statuses |
| `task-update` | 2, 5, 6 | Update task status/results |
| `dispatch` | 2, 4, 6 | Send task spec to a worker terminal |
| `gate-create` | 2, 6, 7 | Create a blocking decision gate |
| `gate-resolve` | 2, 6, 7 | Resolve a pending gate |
| `ask` | 1, 2, 3, 6, 7, 8 | Blocking question to coordinator (human) |
| `run --spec <file>` | All | Start the coordinator event loop with a markdown spec |
| `run-stop` | Recovery | Gracefully stop a running workflow |
| `reset` | Recovery | Reset orchestration state |

### 18.2 `orca worktree` Commands Used

| Command | Phase(s) | Purpose |
|---------|----------|---------|
| `worktree list` | 4 | Check existing worktrees |
| `worktree create` | 4 | Create isolated feature worktree |
| `worktree remove` | 8 | Delete worktree after merge |

### 18.3 External Commands Used

| Command | Phase(s) | Purpose |
|---------|----------|---------|
| `git fetch/push/rebase` | 7 | Branch management |
| `git diff --stat` | 7 | Change summary |
| `gh pr create/view` | 7 | PR lifecycle |
| `jq` | All | JSON parsing |

---

## Appendix A: Full Workflow Diagram

See [`docs/workflow.md`](./docs/workflow.md) for the complete Mermaid flowchart with all states, transitions, and termination conditions.

## Appendix B: Example Walkthrough

See [`examples/basic-workflow.md`](./examples/basic-workflow.md) for a step-by-step annotated example.

## Appendix C: State File Schema

See [`.orca/workflow-state.schema.json`](./.orca/workflow-state.schema.json) for the JSON Schema definition of the state file.

---

> **Next Steps**: Write your task to a markdown spec file and run `orca orchestration run --spec /path/to/spec.md` in any Orca-managed worktree. The coordinator will guide you through each phase. For first-time setup, see [Prerequisites](#3-prerequisites--environment).
