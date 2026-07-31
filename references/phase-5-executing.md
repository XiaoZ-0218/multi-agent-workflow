# Phase 5 — Parallel Execution & Sub-Review

> Extracted from SKILL.md §9 — the full operational procedure for this phase. The coordinator reads this file when entering the phase; SKILL.md keeps only the skeleton.

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
