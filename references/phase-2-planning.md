# Phase 2 — Plan Generation & Review

> Extracted from SKILL.md §6 — the full operational procedure for this phase. The coordinator reads this file when entering the phase; SKILL.md keeps only the skeleton.


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
