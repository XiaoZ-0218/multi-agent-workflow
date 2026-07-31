# Observability & Logging

> Extracted from SKILL.md (§13) — consult on demand when you need the
> workflow state-file example, log levels, or the metrics list.

## 13. Observability & Logging

### 13.1 Workflow State File

A single JSON file at `.orca/workflow-state.json` tracks the entire run. All
writes are jq atomic writes (§12.4). v2.1.0's aggregate `branch`/`pr_url`
compat fields are dropped; `current_phase`/`current_state` enums now include
`INIT`; `pr.state ∈ {OPEN, CHANGES_REQUESTED, MERGED, CLOSED, PARKED, null}`
(no DRAFT — v2.2.0 never creates draft PRs).

```json
{
  "workflow_id": "wf_20260727_001",
  "version": "2.2.0",
  "started_at": "2026-07-27T10:00:00Z",
  "current_phase": "EXECUTING",
  "current_state": "EXECUTING",
  "termination_reason": null,
  "delivery_mode": null,
  "feature_slug": "add-user-prefs",
  "worktree": {
    "id": "wt_abc123",
    "path": "../add-user-prefs",
    "branch_name": "feature/add-user-prefs",
    "base_branch": "origin/main"
  },
  "pr": {
    "url": null,
    "state": null,
    "merged_at": null
  },
  "phases": {
    "GATHERING": {"status": "complete", "entered_at": "2026-07-27T10:00:00Z", "exited_at": "2026-07-27T10:05:00Z", "clarification_rounds": 2},
    "PLANNING": {"status": "complete", "entered_at": "2026-07-27T10:05:00Z", "exited_at": "2026-07-27T10:15:00Z", "review_rounds": 2, "escalate_count": 0},
    "CONFIRMING": {"status": "complete", "entered_at": "2026-07-27T10:15:00Z", "exited_at": "2026-07-27T10:20:00Z", "user_decision": "APPROVE"},
    "DISPATCHING": {"status": "complete", "entered_at": "2026-07-27T10:20:00Z", "exited_at": "2026-07-27T10:30:00Z", "waves": [["sub-1", "sub-2"], ["sub-3"]]},
    "EXECUTING": {"status": "in_progress", "entered_at": "2026-07-27T10:30:00Z", "current_wave": 0},
    "DECIDING": {"status": "pending"},
    "MERGING": {"status": "pending"},
    "CLEANING": {"status": "pending"}
  },
  "tasks": {
    "plan": {"id": "task_xxx", "status": "completed", "verdict": "PASS"},
    "subtasks": [
      {
        "id": "task_yyy",
        "logical_id": "sub-1",
        "title": "Preferences API",
        "complexity": "general",
        "deps": [],
        "owns": ["src/prefs/**", "docs/prefs.md"],
        "status": "completed",
        "verdict": "PASS",
        "reason": null,
        "base_sha": "a1b2c3d",
        "initial_base_sha": "a1b2c3d",
        "review_rounds": 1,
        "terminals": [
          {"handle": "term_yyy", "role": "execution", "round": 0, "agent_type": "kimi", "status": "completed", "verdict": "PASS", "spawned_at": "2026-07-27T10:30:00Z", "closed_at": null},
          {"handle": "term_rrr", "role": "review", "round": 0, "agent_type": "pi", "status": "closed", "verdict": "FAIL", "spawned_at": "2026-07-27T10:45:00Z", "closed_at": "2026-07-27T10:52:00Z"},
          {"handle": "term_zzz", "role": "fix", "round": 1, "agent_type": "kimi", "status": "completed", "verdict": "PASS", "spawned_at": "2026-07-27T10:52:00Z", "closed_at": null},
          {"handle": "term_sss", "role": "review", "round": 1, "agent_type": "pi", "status": "closed", "verdict": "PASS", "spawned_at": "2026-07-27T11:05:00Z", "closed_at": "2026-07-27T11:12:00Z"}
        ],
        "keep_terminal": "term_zzz"
      }
    ]
  },
  "integration_review": {"rounds": 0, "verdict": null},
  "decisions": [
    {"phase": "PLANNING", "kind": "plan_review", "result": "PASS", "round": 2, "timestamp": "2026-07-27T10:15:00Z"},
    {"phase": "CONFIRMING", "kind": "user_confirmation", "result": "APPROVE", "timestamp": "2026-07-27T10:20:00Z"}
  ],
  "retry_counts": {"global_retries_used": 0},
  "errors": []
}
```

Terminal `role` enum: `execution` | `review` | `fix` | `fallback` | `autofix` |
`pr-fix` | `integration-review`.

### 13.2 Log Levels

| Level | When to Use |
|-------|------------|
| `DEBUG` | Every task creation, dispatch, poll iteration, `check --wait` timeout checkpoint |
| `INFO` | Phase transitions, wave dispatch, decisions, normal progress |
| `WARN` | Retries triggered, clarifications needed, owns violations reverted, timeouts |
| `ERROR` | Task failures, conflict detection, integration-review FAIL, escalate triggers |
| `FATAL` | Orca connectivity loss, unrecoverable state corruption |

### 13.3 Key Metrics to Track

- `workflow.total_duration_ms`
- `workflow.phase_duration_ms{phase="PLANNING"}`
- `workflow.review_rounds_total` (per-subtask cross-review rounds)
- `workflow.integration_review_rounds_total` (NEW in v2.2.0)
- `workflow.escalation_count_total`
- `workflow.subtask_pass_rate`
- `workflow.global_retries_used`
- `workflow.delivery_mode{full|degraded}`

(Stacked-PR metrics from v2.1.0 are dropped — there are no stacked PRs.)
