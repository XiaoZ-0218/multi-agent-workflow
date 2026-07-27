# Example: Stacked Sub-Task Workflow (v2.1.0)

> Annotated walkthrough of a complete multi-agent workflow run with the
> **v2.1.0 per-sub-task worktree model**. Task: "Add a user-preferences
> feature with two stacked sub-tasks — a backend API sub-task with no
> dependencies, and a frontend UI sub-task that depends on the API."
>
> Highlights what v2.1.0 changes vs v2.0.x:
> - Each sub-task gets its own branch + worktree (not one shared worktree).
> - Sub-task 2 stacks on Sub-task 1's branch until Sub-task 1 merges.
> - Every cross-review round spawns a fresh review terminal.
> - Each sub-task produces its own PR; dependent PRs start as draft.

---

## Phase 1: Requirements Gathering

**Coordinator analyzes the request:**

```
User: "Add user preferences — API endpoints, plus a UI panel in the
       dashboard that calls them."
```

**Gaps detected:** Which framework (backend + frontend)? Auth model? Where to persist prefs?

```bash
orca orchestration ask \
  --to coordinator \
  --question "I need a few clarifications before planning:
1. Backend stack? (Node/Express, Go, Python/FastAPI, ...)
2. Frontend stack? (React, Vue, plain HTML)
3. Auth: how are user identities issued? (JWT, session, magic link)
4. Persistence: Postgres, SQLite, KV store?
5. Initial preference keys: theme, language, notification toggles — anything else?" \
  --timeout-ms 0
```

**User responds:** "Node 22 + Fastify backend, React + Vite frontend, JWT auth, Postgres. Initial keys: theme, language, email_digest."

**Gap analysis:** ✅ All 5 checklist items clear. Transition to Phase 2.

---

## Phase 2: Plan Generation & Review

```bash
PLAN_TASK=$(orca orchestration task-create \
  --task-title "Plan: User Preferences (API + UI)" \
  --display-name "📝 Plan Agent" \
  --spec "Generate a technical plan for adding user preferences to /projects/my-app.

Backend:
- POST /api/preferences  (upsert per-user)
- GET  /api/preferences  (return current user's prefs)
- Schema: {theme: 'light'|'dark'|'system', language: 'en'|'zh', email_digest: bool}
- JWT middleware; preferences scoped to req.user.id

Frontend:
- /settings/preferences page with three controls (theme selector, language
  selector, email digest switch)
- React Query for fetch + optimistic update on save
- Toast on success/failure

Output:
1. Architecture overview
2. File-by-file change list (backend + frontend)
3. Migration / schema decisions
4. Implementation steps (ordered)
5. Test plan" \
  --json | jq -r '.result.task.id')

orca orchestration dispatch --task "$PLAN_TASK" --to "$PLAN_WORKER" --inject

# Review gate (round 1)
orca orchestration gate-create \
  --task "$PLAN_TASK" \
  --question "Review the user-preferences plan. PASS / FAIL with reasons." \
  --options '["PASS","FAIL"]' \
  --json
```

**Gate result:** PASS on round 1. Transition to Phase 3.

---

## Phase 3: User Confirmation

```bash
orca orchestration ask \
  --to coordinator \
  --question "✅ Plan approved internally.

Summary:
- Two sub-tasks: prefs-api (no deps) + prefs-ui (depends on prefs-api).
- Stacked branches: prefs-ui will target prefs-api's branch as a draft
  until prefs-api merges, then auto-rebase onto main.
- Approve?" \
  --options "Approve — begin execution,Revise,Abort"
```

**User:** "Approve"

---

## Phase 4: Task Decomposition & Dispatch (per sub-task)

### Sub-task DAG

```json
[
  {
    "id": "sub-1",
    "logical_id": "prefs-api",
    "title": "Preferences API (Fastify + Postgres)",
    "deps": [],
    "complexity": "general",
    "spec": "Implement POST /api/preferences and GET /api/preferences ...",
    "review_criteria": ["JWT scope enforced", "Schema matches plan", "Migration is idempotent"]
  },
  {
    "id": "sub-2",
    "logical_id": "prefs-ui",
    "title": "Preferences UI (React + React Query)",
    "deps": ["sub-1"],
    "complexity": "general",
    "spec": "Implement /settings/preferences page ...",
    "review_criteria": ["Hooks consume prefs-api contract", "Optimistic update on save", "A11y: aria-labels + keyboard nav"]
  }
]
```

### Per-sub-task worktree + branch + first terminal

```bash
WORKFLOW_SLUG="add-user-prefs"
TS="20260727-1030"

# ===== Sub-task 1 (prefs-api) — base = main =====
BRANCH_1="feature/${WORKFLOW_SLUG}/prefs-api-${TS}"
WT_1="../${WORKFLOW_SLUG}-prefs-api"

git fetch origin main
orca worktree create --name "$BRANCH_1" --base "origin/main" "$WT_1"

EXEC_T1=$(orca terminal create \
  --worktree "$BRANCH_1" \
  --title "sub-1 r0 execution (claude)" \
  --command "claude" \
  --tags "claude,execution" \
  --json | jq -r '.result.terminal.handle')

SUB1_TASK=$(orca orchestration task-create \
  --task-title "Sub: Preferences API" \
  --display-name "🔧 prefs-api" \
  --spec "..." \
  --deps '[]' \
  --json | jq -r '.result.task.id')

orca orchestration dispatch --task "$SUB1_TASK" --to "$EXEC_T1" --inject

# State records for sub-1
record_subtask_state "sub-1" \
  worktree_path="$WT_1" branch_name="$BRANCH_1" base_branch="main" \
  keep_terminal="$EXEC_T1"
append_terminal_history "sub-1" handle="$EXEC_T1" role="execution" round=0 agent_type="claude"

# ===== Sub-task 2 (prefs-ui) — base = sub-1's branch (stacked) =====
BRANCH_2="feature/${WORKFLOW_SLUG}/prefs-ui-${TS}"
WT_2="../${WORKFLOW_SLUG}-prefs-ui"

# NB: sub-1 has not finished executing yet at this point if we want true
# parallelism. In v2.1.0 stacked mode, sub-2 only waits for sub-1's
# EXECUTION TERMINAL to complete, NOT for the PR. The branch is created
# now based on whatever HEAD sub-1's branch currently has; sub-2 will
# rebase onto sub-1's tip after sub-1 finishes its execution round.
git fetch origin main
orca worktree create --name "$BRANCH_2" --base "origin/main" "$WT_2"
# (Stacked rebase onto sub-1 happens in §8.3.3 once sub-1's execution terminal completes)

EXEC_T2=$(orca terminal create \
  --worktree "$BRANCH_2" \
  --title "sub-2 r0 execution (claude)" \
  --command "claude" \
  --tags "claude,execution" \
  --json | jq -r '.result.terminal.handle')

SUB2_TASK=$(orca orchestration task-create \
  --task-title "Sub: Preferences UI" \
  --display-name "🔧 prefs-ui" \
  --spec "..." \
  --deps '["sub-1"]' \
  --json | jq -r '.result.task.id')

orca orchestration dispatch --task "$SUB2_TASK" --to "$EXEC_T2" --inject

record_subtask_state "sub-2" \
  worktree_path="$WT_2" branch_name="$BRANCH_2" base_branch="$BRANCH_1" \
  keep_terminal="$EXEC_T2"
append_terminal_history "sub-2" handle="$EXEC_T2" role="execution" round=0 agent_type="claude"
```

State after Phase 4:

```json
{
  "tasks": {
    "subtasks": [
      {"id":"sub-1","logical_id":"prefs-api","worktree_path":"../add-user-prefs-prefs-api",
       "branch_name":"feature/add-user-prefs/prefs-api-20260727-1030","base_branch":"main",
       "keep_terminal":"term_aaa",
       "terminals":[{"handle":"term_aaa","role":"execution","round":0,"agent_type":"claude"}]},
      {"id":"sub-2","logical_id":"prefs-ui","worktree_path":"../add-user-prefs-prefs-ui",
       "branch_name":"feature/add-user-prefs/prefs-ui-20260727-1030","base_branch":"feature/add-user-prefs/prefs-api-20260727-1030",
       "keep_terminal":"term_bbb",
       "terminals":[{"handle":"term_bbb","role":"execution","round":0,"agent_type":"claude"}]}
    ]
  }
}
```

---

## Phase 5: Parallel Execution & Cross-Review

Both sub-tasks run concurrently. Each goes through a **per-round cross-review** loop with a **fresh terminal every round**.

### Sub-task 1 (prefs-api)

```
round 0:
  exec_terminal    = term_aaa  (created in Phase 4)
  exec_dispatch    = wait_for_worker(term_aaa)
  review_terminal  = spawn fresh terminal tagged "pi,review" → term_rrr
  review_dispatch  = build_review_spec(prefs-api, wt=../add-user-prefs-prefs-api)
  review_verdict   = FAIL — "Migration is idempotent only on second run; needs ON CONFLICT DO NOTHING"

  Close term_rrr.

round 1:
  fix_terminal     = spawn fresh terminal tagged "claude,fix" → term_aaa2
  fix_dispatch     = build_fix_spec(prefs-api, prior_feedback)
  fix_verdict      = PASS — migration updated
  review_terminal  = spawn fresh terminal tagged "pi,review" → term_rrr2
  review_verdict   = PASS — all criteria met
  Close term_rrr2.

keep_terminal     = term_aaa2  (newest implementation wins)
sub-1 verdict     = PASS, review_rounds = 2
```

### Sub-task 2 (prefs-ui)

```
round 0:
  exec_terminal    = term_bbb   (created in Phase 4)
  review_terminal  = spawn fresh "pi,review" → term_sss
  review_verdict   = PASS on first attempt (clear acceptance criteria)
  Close term_sss.

keep_terminal     = term_bbb
sub-2 verdict     = PASS, review_rounds = 1
```

### Coordinator-side aggregation

```bash
# Both sub-tasks reach terminal verdicts
SUB1_VERDICT=$(jq -r '.tasks.subtasks[] | select(.id=="sub-1") | .verdict' .orca/workflow-state.json)
SUB2_VERDICT=$(jq -r '.tasks.subtasks[] | select(.id=="sub-2") | .verdict' .orca/workflow-state.json)
# Both = "PASS" → transition to MERGING
```

---

## Phase 6: Aggregation & Decision

Both sub-tasks passed. No global retry needed. Transition to Phase 7.

---

## Phase 7: Per-Sub-Task PR Creation (in topological order)

### Sub-task 1: prefs-api PR (base = main)

```bash
WT=../add-user-prefs-prefs-api
BRANCH=feature/add-user-prefs/prefs-api-20260727-1030

( cd "$WT" && git fetch origin main && git rebase origin/main )
( cd "$WT" && git push -u origin "$BRANCH" )

gh pr create \
  --base main \
  --head "$BRANCH" \
  --title "sub-1: Preferences API (Fastify + Postgres)" \
  --body "$(build_pr_body sub-1)"

# Output: https://github.com/org/my-app/pull/100
```

State: `subtasks[0].pr_state = "OPEN"`, `pr_base = "main"`.

### Sub-task 2: prefs-ui PR (base = sub-1's branch, **DRAFT**)

```bash
WT=../add-user-prefs-prefs-ui
BRANCH=feature/add-user-prefs/prefs-ui-20260727-1030
BASE=feature/add-user-prefs/prefs-api-20260727-1030

# NB: sub-2's branch was rebased onto sub-1's tip earlier in §8.3.3, after
# sub-1 finished its execution round. So sub-2 already contains sub-1's code.
( cd "$WT" && git fetch origin "$BASE" && git rebase "$BASE" )
( cd "$WT" && git push -u origin "$BRANCH" )

gh pr create \
  --base "$BASE" \
  --head "$BRANCH" \
  --draft \
  --title "sub-2: Preferences UI (React + React Query)" \
  --body "$(build_pr_body sub-2)"

# Output: https://github.com/org/my-app/pull/101
```

State: `subtasks[1].pr_state = "DRAFT"`, `pr_base = "<sub-1 branch>"`.

### Human reviews sub-1 (PR #100)

- CI passes ✅
- Reviewer approves & merges ✅
- `subtasks[0].pr_state = "MERGED"`, `merged_at = "2026-07-27T11:50:00Z"`

### §11.8 Stacked-PR Rebase Hook fires

```bash
# on_parent_merge fires automatically after sub-1 merges
on_parent_merge sub-1

# Inside the hook for sub-2:
( cd ../add-user-prefs-prefs-ui && git fetch origin main && git rebase origin/main )
( cd ../add-user-prefs-prefs-ui && git push --force-with-lease origin "$BRANCH_2" )

gh pr edit 101 --base main
gh pr ready 101
```

State now: `subtasks[1].pr_state = "OPEN"`, `pr_base = "main"`.

### Human reviews sub-2 (PR #101)

- CI passes ✅
- Reviewer approves & merges ✅
- `subtasks[1].pr_state = "MERGED"`

---

## Phase 8: Per-Sub-Task Cleanup (reverse-topological order)

Reverse-topo = `[sub-2, sub-1]`.

```bash
# ===== Sub-task 2 (prefs-ui) — merged =====
git push origin --delete "feature/add-user-prefs/prefs-ui-20260727-1030"
orca worktree remove "feature/add-user-prefs/prefs-ui-20260727-1030"
orca terminal close --handle "term_bbb"      # sub-2 keep_terminal

# ===== Sub-task 1 (prefs-api) — merged =====
git push origin --delete "feature/add-user-prefs/prefs-api-20260727-1030"
orca worktree remove "feature/add-user-prefs/prefs-api-20260727-1030"
orca terminal close --handle "term_aaa2"     # sub-1 keep_terminal

# Workflow-level
git checkout main && git pull

# Append per-sub-task history lines
cat >> .orca/workflow-history.jsonl <<EOF
{"workflow_id":"wf_20260727_001","subtask_id":"sub-1","branch":"feature/.../prefs-api-...","pr_state":"MERGED","disposition":"MERGED","timestamp":"..."}
{"workflow_id":"wf_20260727_001","subtask_id":"sub-2","branch":"feature/.../prefs-ui-...","pr_state":"MERGED","disposition":"MERGED","timestamp":"..."}
EOF
```

### Notification

```bash
orca orchestration ask \
  --to coordinator \
  --question "🎉 User preferences feature complete!

Per-sub-task delivery:
- sub-1 prefs-api → PR #100 → MERGED into main
- sub-2 prefs-ui  → PR #101 → MERGED into main (was draft on prefs-api
                   branch; auto-rebased onto main after #100 merged)

Both worktrees removed; both keep_terminals closed. Per-sub-task history
written to .orca/workflow-history.jsonl." \
  --timeout-ms 0
```

---

## Metrics for This Run

| Metric | Value |
|--------|-------|
| Total duration | ~45 min |
| Clarification rounds | 1 |
| Plan review rounds | 1 |
| Escalations | 0 |
| Sub-task pass rate | 2/2 (100%) |
| Per-sub-task review rounds | sub-1 = 2, sub-2 = 1 |
| Cross-review terminals spawned | 3 (term_rrr, term_rrr2, term_sss) |
| Global retries | 0 |
| Delivery mode | full |
| Autofix attempts | 0 |
| Stacked rebase hook fires | 1 (on sub-1 merge) |

---

## Failure Scenarios

### Scenario A: sub-2 review never passes (3 rounds exhausted)

In Phase 6, the coordinator sees:

```
⚠️ 1/2 sub-tasks failed:
- sub-2 (prefs-ui): Cross-review never passed after 3 rounds.
  Last feedback: "Optimistic update still reverts on rollback"
```

Decision options:
- **Retry failed sub-task**: a fresh worktree + branch is created for sub-2; the loop restarts. Sibling sub-1 is untouched.
- **Degrade**: ship sub-1's merged PR; write `.orca/parked/sub-2.md` and skip sub-2's PR.
- **Escalate / Abort**.

### Scenario B: sub-1 merges, sub-2's rebase fails

§11.8 catches the conflict, spawns an **autofix terminal** (fresh execution terminal tagged `autofix`), and asks the autofix Agent to resolve conflict markers. If autofix succeeds, the rebase continues and `gh pr edit --base main` flips the base. If autofix exhausts, sub-2 is parked with a per-sub-task manifest; sub-1 is already merged and remains so.

---

## What's Different From v2.0.x

| Phase | v2.0.x | v2.1.0 (this example) |
|-------|--------|------------------------|
| 4 | One shared `feature/dark-mode-...` worktree | Two worktrees: `../add-user-prefs-prefs-api` + `../add-user-prefs-prefs-ui` |
| 5 | Self-review in same worker terminal | 3 fresh review/fix terminals across rounds |
| 7 | One bundle PR | Two PRs: #100 (sub-1, base=main) + #101 (sub-2, base=sub-1 branch, draft) |
| 7 (after sub-1 merge) | N/A | §11.8 rebase hook flips #101's base to main, promotes from draft |
| 8 | Single branch delete + worktree remove | Reverse-topo per-sub-task cleanup with per-sub-task history lines |