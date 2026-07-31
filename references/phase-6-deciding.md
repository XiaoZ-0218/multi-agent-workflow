# Phase 6 — Aggregation & Decision

> Extracted from SKILL.md §10 — the full operational procedure for this phase. The coordinator reads this file when entering the phase; SKILL.md keeps only the skeleton.

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
