---
name: multi-agent-workflow
version: 2.2.2
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

> **Version**: 2.2.2 &ensp;|&ensp; **Runtime**: Orca IDE ≥ 1.x &ensp;|&ensp; **License**: MIT
>
> Reference flowchart: [`docs/workflow.md`](./docs/workflow.md)

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

`INIT → GATHERING → PLANNING → CONFIRMING → DISPATCHING → EXECUTING ⇄ DECIDING → MERGING → CLEANING → DONE` — `PARKED` and `TERMINATED` are side exits reachable from several states (see the transition table).

### State Transition Table

The full Mermaid diagram and the authoritative state transition table live in
[`docs/workflow.md`](./docs/workflow.md) (状态流转表). They cover every
transition — including the MERGING sub-steps, the PARKED exits, and
fatal-error termination — and are the single source of truth for guards and
triggers.

---

## 3. Prerequisites & Environment

### 3.1 Runtime Checks

Run `scripts/check-prerequisites.sh` before every run. It checks: Orca
running & reachable; the coordinator is inside an Orca-managed checkout
(`orca worktree current`) and on the `main` branch; required tools `git` ≥
2.30, `gh` ≥ 2.0 (authenticated), `jq`; and a clean working tree. Missing
hard requirements fail the run; checkout/branch/clean-tree problems warn
(`ORCA_WORKFLOW_STRICT_PREREQ=true` escalates the Orca-checkout check to a
hard failure).

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

Environment variables are defined in §4.1 below. Agent routing variables
(`ORCA_WORKFLOW_*_AGENT`, `ORCA_WORKFLOW_FALLBACK_CHAIN`) are defined in
[`docs/agent-routing.md`](./docs/agent-routing.md) — the single source of
truth for routing, including precedence and the fallback chain.

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

Environment variables override the config keys above (highest precedence,
§4.2). Each variable is defined only here:

```bash
# VAR → config key
export ORCA_WORKFLOW_MAX_REVIEW_ROUNDS=3        # limits.max_review_rounds
export ORCA_WORKFLOW_MAX_ESCALATE=2             # limits.max_escalate_count
export ORCA_WORKFLOW_MAX_USER_CONFIRM=3         # limits.max_user_confirm_rounds
export ORCA_WORKFLOW_MAX_SUB_RETRY=3            # limits.max_subtask_retries
export ORCA_WORKFLOW_MAX_GLOBAL_RETRY=2         # limits.max_global_retries
export ORCA_WORKFLOW_MAX_AUTOFIX=2              # limits.max_autofix_attempts
export ORCA_WORKFLOW_MAX_INTEGRATION_REVIEW=2   # limits.max_integration_review_rounds
export ORCA_WORKFLOW_STATE_FILE=.orca/workflow-state.json  # observability.state_file
export ORCA_WORKFLOW_LOG_LEVEL=INFO             # observability.log_level

# Env-only switches (no config key)
export ORCA_WORKFLOW_STRICT_PREREQ=false  # true → check-prerequisites.sh fails hard on a missing prerequisite (recommended for CI)
export ORCA_WORKFLOW_DRY_RUN=false        # true → plan only, no dispatch (see references/runbooks.md)
```

### 4.2 Configuration File Resolution

The workflow looks for configuration in this order (first wins):

1. Environment variables (`ORCA_WORKFLOW_*`)
2. `.orca/workflow-config.json` (project-local)
3. `~/.config/orca/workflow-defaults.json` (user-global)
4. Built-in defaults (shown above)

---

## 5. Phase 1 — Requirements Gathering

> Full procedure: [`references/phase-1-gathering.md`](./references/phase-1-gathering.md) — **read it before executing this phase.**

- Clarify the raw user request; state `INIT` → `GATHERING`.
- Ask via the coordinator's **native** user-interaction channel only — never `orca orchestration ask --to coordinator` (that channel is worker → coordinator only).
- Hard cap `MAX_CLARIFICATION_ROUNDS=5`; exceeding it → `TERMINATED`.
- Gap checklist (5 items: Goal / Scope / Constraints / Context / Acceptance Criteria); ≥ 2 items missing → pause and clarify.
- Output: `clarified_requirement` JSON; on success → `PLANNING`.

---

## 6. Phase 2 — Plan Generation & Review

> Full procedure: [`references/phase-2-planning.md`](./references/phase-2-planning.md) — **read it before executing this phase.**

- The plan agent generates the plan; a **separate review agent** reviews it.
- Review is an independent task; the verdict arrives via `worker_done` — never `gate-create`.
- The plan artifact travels as text only; it is never written as a file into the main checkout.
- Caps: `MAX_REVIEW_ROUNDS=3` + human escalation `MAX_ESCALATE=2`; exhaustion → `TERMINATED` (Terminate1).
- Review checklist includes declared `owns`, disjoint same-wave `owns`, and an acyclic DAG.
- Review PASS → `CONFIRMING`.

---

## 7. Phase 3 — User Confirmation

> Full procedure: [`references/phase-3-confirming.md`](./references/phase-3-confirming.md) — **read it before executing this phase.**

- User sign-off via the native channel; three options only: Approve / Revise / Abort.
- `Revise` cap `MAX_USER_CONFIRM=3`; `Abort` terminates immediately at any round (Terminate2).
- No reduce-scope option (removed in v2.2.0).
- Approve → `DISPATCHING`; Revise → back to `PLANNING` with the user's feedback.

---

## 8. Phase 4 — Task Decomposition & Dispatch

> Full procedure: [`references/phase-4-dispatching.md`](./references/phase-4-dispatching.md) — **read it before executing this phase.**

- Create the ONE feature worktree + branch `feature/<slug>` based on `origin/main`; decompose the plan into the subtask DAG, compute waves, dispatch wave 0.
- Same-wave `owns` must be disjoint; the review agent is never the implementation agent.
- Every fresh terminal: `orca terminal wait --for tui-idle` before `dispatch --inject`.
- Fallback chain default `claude,grok,pi`; each fallback = a NEW task + a NEW terminal.
- Output: worktree record, waves, and per-subtask `base_sha`/`initial_base_sha` state.

---

## 9. Phase 5 — Parallel Execution & Sub-Review

> Full procedure: [`references/phase-5-executing.md`](./references/phase-5-executing.md) — **read it before executing this phase.**

- Subtasks run wave by wave in the shared worktree; every execute/fix/review round = a fresh terminal + a NEW task (chained with `--parent`).
- Rounds 0..`MAX_SUB_RETRY` (default 3); review covers only `<base_sha>..HEAD` within the subtask's `owns`.
- Coordinator waits with `check --wait` in a rolling loop; a timeout is a checkpoint, not a failure.
- Final-round FAIL records `verdict=FAIL`; sibling subtasks continue unaffected.
- Only when every subtask in the wave has PASS does the next wave get dispatched.

---

## 10. Phase 6 — Aggregation & Decision

> Full procedure: [`references/phase-6-deciding.md`](./references/phase-6-deciding.md) — **read it before executing this phase.**

- Collect every subtask's terminal verdict; all PASS → `MERGING`.
- On failures, ask the user via the native channel: Retry (failed subtasks only, cap `MAX_GLOBAL_RETRY=2`, guard checked before incrementing) / Degrade / Abort.
- Abort → `TERMINATED` (Terminate3).
- Degrade: revert each failed subtask's `initial_base_sha..HEAD` range within its `owns`; an unclean revert parks the whole feature (`PARKED`).
- Degrade sets `delivery_mode=degraded`; the PR body carries a ⚠️ banner.

---

## 11. Phase 7 — Merge & Pull Request

> Full procedure: [`references/phase-7-merging.md`](./references/phase-7-merging.md) — **read it before executing this phase.**

- Rebase onto `origin/main` (autofix ≤ `MAX_AUTOFIX=2`; success = rebase complete AND zero `^UU` paths) → run the project tests → integration review (≤ `MAX_INTEGRATION_REVIEW=2`, fresh read-only terminal) → create ONE PR → poll every 60s.
- No `gate-create` inside the poll loop; Changes Requested → a fresh pr-fix terminal.
- All git operations run inside the feature worktree; the coordinator never checks anything out.
- MERGED → `CLEANING`; CLOSED → park the feature.

---

## 12. Phase 8 — Cleanup & Archival

> Full procedure: [`references/phase-8-cleaning.md`](./references/phase-8-cleaning.md) — **read it before executing this phase.**

- MERGED → delete the remote/local branch, remove the worktree, close terminals; PARKED/CLOSED → keep branch + worktree, write `.orca/parked/<slug>.md`.
- An `OPEN` PR at cleanup is guarded — refuse destructive actions, treat as parked.
- All state writes are jq atomic tmp-file + `mv`; afterwards the coordinator runs only `git fetch origin`.
- Output: one `workflow-history.jsonl` line + user notification.

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
