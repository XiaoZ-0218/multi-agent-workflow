# Phase 7 — Merge & Pull Request

> Extracted from SKILL.md §11 — the full operational procedure for this phase. The coordinator reads this file when entering the phase; SKILL.md keeps only the skeleton.


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
