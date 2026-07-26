---
name: multi-agent-workflow
version: 2.0.0
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

> **Version**: 2.0.0 &ensp;|&ensp; **Runtime**: Orca IDE ≥ 1.x &ensp;|&ensp; **License**: MIT
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
│                              ┌─────────────────────┼──────┐      │
│                              │     WORKERS (parallel)      │      │
│                              │  ┌──────┐ ┌──────┐ ┌──────┐│      │
│                              │  │Sub-1 │ │Sub-2 │ │Sub-3 ││      │
│                              │  │Exec  │ │Exec  │ │Exec  ││      │
│                              │  │+Review│+Review│+Review││      │
│                              │  └──┬───┘ └──┬───┘ └──┬───┘│      │
│                              └─────┼────────┼────────┼─────┘      │
│  ┌──────────┐  ┌──────────┐       │        │        │            │
│  │ Phase 6  │←─┤ Collect  │←──────┴────────┴────────┘            │
│  │ Decide   │  │ All Done │                                       │
│  └────┬─────┘  └──────────┘                                       │
│       │                                                            │
│  ┌────┴─────┐  ┌──────────┐  ┌──────────┐                        │
│  │ Phase 7  │→│ Phase 8  │→│  Notify  │                        │
│  │ PR/Merge │  │ Cleanup  │  │  User    │                        │
│  └──────────┘  └──────────┘  └──────────┘                        │
└──────────────────────────────────────────────────────────────────┘
```

### Design Principles

| Principle | Implementation |
|-----------|---------------|
| **Fail-Safe by Default** | Every loop has a hard cap; no infinite retries |
| **Human-in-the-Loop at High-Value Gates** | Escalation only at plan-review and merge-conflict boundaries |
| **Collect-All-Then-Decide** | Subtask failures do NOT interrupt sibling workers; all results aggregate before the retry decision |
| **PR-Only Merge Path** | No direct `git merge`; all integrations go through pull requests |
| **Immutable Audit Trail** | Every decision gate, escalation, and termination is logged to `.orca/workflow-state.json` |
| **Degraded Delivery over Total Failure** | When retries are exhausted, completed artifacts are delivered; failed items are flagged for manual follow-up |

---

## 2. State Machine

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
        ┌────┴─────┐
        │DISPATCHING│◄─── Retry Failed Items ───┐
        │(Phase 4)  │                           │
        └────┬─────┘                            │
             │                                  │
        ┌────┴─────┐                            │
        │ EXECUTING │──► SUB_FAILURES           │
        │(Phase 5)  │                           │
        └────┬─────┘                            │
             │                                  │
        ┌────┴─────┐                            │
        │DECIDING  │──► RETRY ──────────────────┘
        │(Phase 6)  │──► DEGRADE (partial)
        └────┬─────┘──► ESCALATE_SUB
             │
        ┌────┴─────┐
        │ MERGING  │──► CONFLICT ──► AUTOFIX ──► HUMAN
        │(Phase 7)  │──► PARKED
        └────┬─────┘
             │
        ┌────┴─────┐
        │CLEANING  │
        │(Phase 8)  │
        └────┬─────┘
             │
        ┌────┴─────┐
        │  DONE    │
        └──────────┘
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
| `DISPATCHING` | All tasks dispatched | `EXECUTING` | — |
| `EXECUTING` | All workers done | `DECIDING` | — |
| `DECIDING` | All passed | `MERGING` | AllOK = yes |
| `DECIDING` | Retry (global retries < 2) | `DISPATCHING` | Only failed items |
| `DECIDING` | Degrade | `MERGING` | PartialOK flag set |
| `DECIDING` | Escalate → human aborts | `TERMINATED` | Terminate3 |
| `MERGING` | PR merged | `CLEANING` | — |
| `MERGING` | PR closed / parked | `CLEANING` | Park flag set |
| `CLEANING` | Cleanup complete | `DONE` | — |

---

## 3. Prerequisites & Environment

### 3.1 Runtime Checks

```bash
# 1. Verify Orca is running and reachable
orca status --json | jq -e '.ok and .result.app.running and .result.runtime.reachable' \
  || { echo "FATAL: Orca is not running or unreachable"; exit 1; }

# 2. Verify at least one worker terminal is available
WORKER_COUNT=$(orca terminal list --json | jq '[.result.terminals[] | select(.type == "worker")] | length')
if [ "$WORKER_COUNT" -lt 1 ]; then
  echo "FATAL: No worker terminals available. Create one with: orca terminal create --type worker"
  exit 1
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

```bash
export ORCA_WORKFLOW_MAX_REVIEW_ROUNDS=${ORCA_WORKFLOW_MAX_REVIEW_ROUNDS:-3}
export ORCA_WORKFLOW_MAX_ESCALATE=${ORCA_WORKFLOW_MAX_ESCALATE:-2}
export ORCA_WORKFLOW_MAX_USER_CONFIRM=${ORCA_WORKFLOW_MAX_USER_CONFIRM:-3}
export ORCA_WORKFLOW_MAX_SUB_RETRY=${ORCA_WORKFLOW_MAX_SUB_RETRY:-3}
export ORCA_WORKFLOW_MAX_GLOBAL_RETRY=${ORCA_WORKFLOW_MAX_GLOBAL_RETRY:-2}
export ORCA_WORKFLOW_MAX_AUTOFIX=${ORCA_WORKFLOW_MAX_AUTOFIX:-2}
export ORCA_WORKFLOW_STATE_FILE="${ORCA_WORKFLOW_STATE_FILE:-.orca/workflow-state.json}"
export ORCA_WORKFLOW_LOG_LEVEL="${ORCA_WORKFLOW_LOG_LEVEL:-INFO}"
```

---

## 4. Configuration

### 4.1 Tunable Parameters

```json
{
  "workflow": {
    "version": "2.0.0",
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
      "_note": "Agent 选型详见 docs/agent-routing.md。修改偏好只需编辑该文件，不要改这里。",
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
        options=["Approve — begin execution", "Revise — provide feedback", "Abort — cancel the task"]
    )

    if response == "Approve":
        transition to DISPATCHING
        break

    confirm_round += 1
    if confirm_round < MAX_USER_CONFIRM:
        if response == "Revise":
            # Collect feedback, return to Phase 2 with reset review counter
            transition to PLANNING (with user_feedback)
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

**Goal**: Break the approved plan into a DAG of subtasks, create a feature branch/worktree, and dispatch subtasks to worker terminals.

### 8.1 Entry Condition

- State: `DISPATCHING`
- Input: Approved plan + user confirmation

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

### 8.3 Process

```bash
# Step 1: Check if worktree/branch already exists
EXISTING=$(orca worktree list --json 2>/dev/null | jq -r '.result.worktrees[] | select(.name | startswith("feature/")) | .name')

if [ -z "$EXISTING" ]; then
  # Create new feature branch + worktree
  BRANCH="feature/${TASK_SLUG}-$(date +%Y%m%d-%H%M)"
  orca worktree create --name "$BRANCH" --base main
  echo "Created worktree: $BRANCH"
else
  echo "Reusing existing worktree: $EXISTING"
fi

# Step 2: Create orchestration tasks for each subtask
for SUB in "${SUBTASK_IDS[@]}"; do
  TASK_ID=$(orca orchestration task-create \
    --task-title "Sub: ${SUB_TITLES[$SUB]}" \
    --display-name "🔧 ${SUB_NAMES[$SUB]}" \
    --spec "${SUB_SPECS[$SUB]}" \
    --deps "$(echo ${SUB_DEPS[$SUB]} | jq -c '.')" \
    --json | jq -r '.result.task.id')

  echo "Created subtask: $TASK_ID ($SUB)"

  # Dispatch to worker (non-blocking — all dispatch in parallel)
  WORKER=$(select_worker "${SUB_COMPLEXITIES[$SUB]}")
  orca orchestration dispatch \
    --task "$TASK_ID" \
    --to "$WORKER" \
    --inject \
    --json &

  SUBTASK_MAP["$SUB"]="$TASK_ID"
done

wait  # All dispatches fired
```

### 8.4 Worker Selection Logic

```bash
# Agent 偏好定义在 docs/agent-routing.md，通过环境变量注入到此函数
select_worker() {
  local task_type="${1:-general}"
  local agent_type

  case "$task_type" in
    complex) agent_type="${ORCA_WORKFLOW_COMPLEX_EXECUTION_AGENT}" ;;
    image)   agent_type="${ORCA_WORKFLOW_IMAGE_AGENT}" ;;
    *)       agent_type="${ORCA_WORKFLOW_EXECUTION_AGENT}" ;;
  esac

  # 匹配对应标签的 worker 终端，无匹配则取第一个可用
  orca terminal list --json | jq -r --arg type "$agent_type" '
    [.result.terminals[] | select(.tags[]? == $type)] | if length > 0 then .[0].handle
    else .result.terminals[0].handle end
  '
}
```

#### 报错兜底逻辑

通用任务失败后按优先级链重试（Agent 列表由 `docs/agent-routing.md` 定义）：

```bash
retry_with_fallback() {
  local task_id="$1"
  # 从环境变量读取兜底链，格式: "agent1,agent2,agent3"
  IFS=',' read -ra agents <<< "${ORCA_WORKFLOW_FALLBACK_CHAIN:-}"

  for agent in "${agents[@]}"; do
    WORKER=$(select_worker_by_tag "$agent")
    orca orchestration dispatch --task "$task_id" --to "$WORKER" --inject --json
    wait_for_worker "$task_id"

    if [[ "$(get_task_verdict "$task_id")" == "PASS" ]]; then
      return 0
    fi
    echo "⚠️ $agent failed, trying next..."
  done

  echo "❌ All agents exhausted for $task_id"
  return 1
}
```

### 8.5 Injected Preamble (sent to each worker)

Each worker receives this preamble via `dispatch --inject`:

```text
You are executing subtask "{title}" as part of a multi-agent workflow.

## Rules
1. You have up to {MAX_SUB_RETRY} attempts to produce a passing artifact.
2. After each attempt, self-review against these criteria:
   {review_criteria}
3. If you pass: set status=completed with result={"verdict":"PASS","artifact":"path"}
4. If you fail after {MAX_SUB_RETRY} attempts: set status=completed with result={"verdict":"FAIL","reason":"...","retries":{MAX_SUB_RETRY}}
5. Do NOT alert the coordinator on failure — the coordinator collects all results.
6. When done, emit worker_done per your terminal's preamble protocol.

## Context
{plan_summary}

## Your Task
{spec}
```

### 8.6 Output

```json
{
  "phase": "DISPATCHING",
  "status": "complete",
  "branch": "feature/my-task-20260726-1030",
  "subtasks": [
    {"id": "sub-1", "orchestration_id": "task_xxx", "worker": "term_yyy"},
    {"id": "sub-2", "orchestration_id": "task_aaa", "worker": "term_bbb"},
    {"id": "sub-3", "orchestration_id": "task_ccc", "worker": "term_ddd"}
  ],
  "timestamp": "2026-07-26T10:25:00Z"
}
```

---

## 9. Phase 5 — Parallel Execution & Sub-Review

**Goal**: Each subtask executes independently with internal retry logic. The coordinator does NOT intervene until all workers report done.

### 9.1 Entry Condition

- State: `EXECUTING`
- Workers are running independently

### 9.2 Worker-Side Logic (injected in preamble)

```
sub_retry = 0
MAX_SUB_RETRY = 3

while sub_retry < MAX_SUB_RETRY:
    artifact = execute_subtask(spec, plan_context)

    review = self_review(artifact, review_criteria)
    if review.passed:
        task_update(status="completed", result={
            "verdict": "PASS",
            "artifact": artifact.path,
            "retries": sub_retry
        })
        emit worker_done
        break

    sub_retry += 1
    if sub_retry < MAX_SUB_RETRY:
        incorporate_review_feedback(review.feedback)
    else:
        task_update(status="completed", result={
            "verdict": "FAIL",
            "reason": review.feedback,
            "retries": sub_retry
        })
        emit worker_done
```

### 9.3 Coordinator-Side Wait

```bash
# Poll all subtask statuses until all are terminal (completed or failed)
while true; do
  ALL_DONE=true
  for TASK_ID in "${SUBTASK_ORCH_IDS[@]}"; do
    STATUS=$(orca orchestration task-list --json | jq -r --arg id "$TASK_ID" \
      '.result.tasks[] | select(.id == $id) | .status')
    if [[ "$STATUS" != "completed" && "$STATUS" != "failed" ]]; then
      ALL_DONE=false
      break
    fi
  done

  if $ALL_DONE; then
    break
  fi
  sleep 10
done

echo "All subtasks have completed."
```

### 9.4 Timeout Handling

If any subtask exceeds its `timeout_ms`:

```bash
# Mark timed-out task as failed
orca orchestration task-update \
  --id "$TIMED_OUT_TASK" \
  --status "failed" \
  --result '{"verdict":"FAIL","reason":"Timeout exceeded","retries":-1}' \
  --json
```

### 9.5 Output

```json
{
  "phase": "EXECUTING",
  "status": "complete",
  "subtask_results": [
    {"id": "sub-1", "verdict": "PASS", "artifact": "research-notes.md", "retries": 1},
    {"id": "sub-2", "verdict": "PASS", "artifact": "draft.md", "retries": 0},
    {"id": "sub-3", "verdict": "FAIL", "reason": "Image generation API unavailable", "retries": 3}
  ],
  "timestamp": "2026-07-26T11:00:00Z"
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

# Simulate a simple request
echo "Write a hello-world script in Python" | \
  orca orchestration run --skill multi-agent-workflow

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

# 3. Start the coordinator
orca orchestration run --skill multi-agent-workflow

# The coordinator will prompt for the task description via Phase 1
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
| `run` | All | Start the coordinator event loop |
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

> **Next Steps**: Run `orca orchestration run --skill multi-agent-workflow` in any Orca-managed worktree to start. The coordinator will guide you through each phase. For first-time setup, see [Prerequisites](#3-prerequisites--environment).
