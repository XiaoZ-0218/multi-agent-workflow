# Example: Add User Preferences — End-to-End Walkthrough (v2.2.0)

> Annotated walkthrough of a complete multi-agent workflow run with the
> **v2.2.0 shared-worktree wave model**. Task: "Add user preferences — API
> endpoints plus a settings UI panel." Two subtasks execute inside **ONE
> shared feature worktree** on **ONE feature branch**, producing **ONE PR**.
> Parallelism safety comes from disjoint per-subtask `owns` globs, not from
> filesystem isolation; dependencies mean **serial waves**, not stacked
> branches.

## What's Different From v2.1.0

- **One feature = one worktree + one branch + one PR.** v2.1.0's per-subtask
  worktrees, stacked branches, per-subtask PRs, draft PRs, the §11.8
  stacked-PR rebase hook, and the branch/worktree-path templates are all
  removed.
- **`owns` replaces isolation.** Every subtask declares the path globs it may
  write; same-wave (parallel) subtasks must have disjoint `owns`, validated
  during plan review.
- **Plan review is a separate review task** whose verdict arrives via
  `worker_done` — `gate-create` is no longer used for agent reviews.
- **User interaction uses the coordinator's native channel** — never
  `orca orchestration ask --to coordinator` (that verb is worker→coordinator
  only).
- **Phase 7 gains an INTEGRATION REVIEW** of the whole feature diff
  (`ORCA_WORKFLOW_MAX_INTEGRATION_REVIEW`, default 2).
- **The coordinator never runs `git checkout`** — it stays on the main branch
  for the entire run; all feature git ops happen inside the worktree via
  `(cd <wt> && git ...)`.
- The v2.0.1 "scope-reduction" confirm option is removed (parallel writes
  into the coordinator's main checkout are unsafe); users reduce scope via
  **Revise** instead.

## The Scenario

```
User: "Add user preferences — API endpoints, plus a UI panel in the
       dashboard that calls them."
```

Approved decomposition (final plan, Phase 2 output):

```json
[
  {
    "id": "sub-1",
    "logical_id": "prefs-api",
    "title": "Preferences API (Fastify + Postgres)",
    "deps": [],
    "owns": ["server/**", "migrations/**"],
    "complexity": "general",
    "spec": "Implement POST /api/preferences (upsert, JWT-scoped) and GET /api/preferences, plus an idempotent migration creating the user_preferences table.",
    "review_criteria": ["JWT scope enforced", "Schema matches plan", "Migration is idempotent"],
    "timeout_ms": 3600000
  },
  {
    "id": "sub-2",
    "logical_id": "prefs-ui",
    "title": "Preferences UI (React + React Query)",
    "deps": ["sub-1"],
    "owns": ["web/src/settings/**"],
    "complexity": "general",
    "spec": "Implement the /settings/preferences page (theme selector, language selector, email-digest switch) with React Query fetch + optimistic update and toast on save.",
    "review_criteria": ["Hooks consume the prefs-api contract", "Optimistic update on save", "A11y: aria-labels + keyboard nav"],
    "timeout_ms": 3600000
  }
]
```

Wave layout (topological levels of the DAG):

```
wave 0 (dispatched first):  sub-1   owns: server/**, migrations/**
wave 1 (after sub-1 PASS):  sub-2   owns: web/src/settings/**
```

Agent routing for this run (defaults): plan = `Plan`, review = `pi`,
execution = `claude`, fallback chain = `grok,pi`. Cross-review rule: the
review agent is never the implementation agent. Limits (defaults):
`ORCA_WORKFLOW_MAX_REVIEW_ROUNDS=3`, `ORCA_WORKFLOW_MAX_ESCALATE=2`,
`ORCA_WORKFLOW_MAX_USER_CONFIRM=3`, `ORCA_WORKFLOW_MAX_SUB_RETRY=3`,
`ORCA_WORKFLOW_MAX_GLOBAL_RETRY=2`, `ORCA_WORKFLOW_MAX_AUTOFIX=2`,
`ORCA_WORKFLOW_MAX_INTEGRATION_REVIEW=2`.

Prerequisite: the coordinator runs inside an Orca-managed checkout on the
main branch (`orca status --json` reports `.ok == true`).

---

## Phase 1: Requirements Gathering

The coordinator asks the user through its **own native interaction channel**.
It does NOT shell out to `orca orchestration ask --to coordinator` — that
verb exists so *workers* can reach the coordinator, not so the coordinator
can reach the user.

```
Coordinator → user (native channel):
  "Before planning I need five answers:
   1. Backend stack? (Node/Express, Go, Python/FastAPI, ...)
   2. Frontend stack? (React, Vue, plain HTML)
   3. Auth: how are user identities issued? (JWT, session, magic link)
   4. Persistence: Postgres, SQLite, KV store?
   5. Initial preference keys beyond theme / language / notifications?"

User → coordinator:
  "Node 22 + Fastify backend, React + Vite frontend, JWT auth, Postgres.
   Initial keys: theme, language, email_digest."
```

**Gap analysis:** ✅ all checklist items clear after round 1 of ≤5.
Transition to Phase 2.

---

## Phase 2: Plan Generation & Review

The plan agent gets a **fresh terminal** in the coordinator's checkout
(selector `active`). Planning is text-only: the plan artifact comes back in
the `worker_done` body and is **never written as a file into the main
checkout**.

```bash
PLAN_TERM=$(orca terminal create \
  --worktree active \
  --title "[plan:Plan] wf_20260727_001 plan" \
  --command "Plan" \
  --json | jq -r '.result.terminal.handle')

PLAN_TASK=$(orca orchestration task-create \
  --task-title "Plan: User Preferences (API + UI)" \
  --display-name "📝 Plan agent" \
  --spec "Generate a technical plan for adding user preferences to this repo.

Backend:  POST /api/preferences (upsert per user), GET /api/preferences.
          Schema {theme: light|dark|system, language: en|zh, email_digest: bool}.
          JWT middleware; preferences scoped to req.user.id. Postgres.
Frontend: /settings/preferences page, React Query fetch + optimistic update,
          toast on success/failure.

REQUIRED OUTPUT SHAPE (return as TEXT in your worker_done body; do NOT write
plan files into this checkout):
1. Architecture overview
2. Subtask DAG — every subtask MUST declare: id, logical_id, title, deps[],
   owns[] (path globs it may write), complexity (general|complex|image),
   spec, review_criteria[], timeout_ms
3. Migration / schema decisions
4. Test plan

DONE PROTOCOL: send worker_done EXACTLY ONCE to the coordinator handle with
taskId + dispatchId + verdict + artifact summary, then idle." \
  --json | jq -r '.result.task.id')

orca orchestration dispatch --task "$PLAN_TASK" --to "$PLAN_TERM" --inject --json
```

The coordinator waits with a rolling check (a timeout is a checkpoint, not a
failure — long agent runs routinely take 15–60 min):

```bash
orca orchestration check --wait \
  --types worker_done,escalation,decision_gate \
  --timeout-ms 900000 --json
```

The plan arrives as text. Review is a **separate task** dispatched to the
review agent (`pi`) on its own fresh terminal — verdict via `worker_done`,
NOT `gate-create`:

```bash
PREV_TERM=$(orca terminal create \
  --worktree active \
  --title "[review:pi] plan review r1" \
  --command "pi" \
  --json | jq -r '.result.terminal.handle')

PREV_TASK=$(orca orchestration task-create \
  --task-title "Review: plan round 1" \
  --display-name "🔍 Plan review r1" \
  --spec "Read-only review of the plan quoted below. Checklist:
- [ ] Every subtask declares owns[] path globs
- [ ] Same-wave (parallel) subtasks have DISJOINT owns
- [ ] deps[] form an acyclic graph
- [ ] review_criteria are concrete and testable
- [ ] No subtask needs write access outside its owns
Reply via worker_done EXACTLY ONCE: verdict PASS or FAIL + reasons, then idle.

PLAN:
<plan text from the plan worker's worker_done body>" \
  --json | jq -r '.result.task.id')

orca orchestration dispatch --task "$PREV_TASK" --to "$PREV_TERM" --inject --json
```

**Review verdict (round 1): PASS.** Wave 0 = `[sub-1]`, wave 1 = `[sub-2]` —
each wave holds a single subtask, so same-wave disjointness holds trivially;
cross-wave overlap would be acceptable anyway because waves are serial.
(`≤ ORCA_WORKFLOW_MAX_REVIEW_ROUNDS=3` review rounds and
`≤ ORCA_WORKFLOW_MAX_ESCALATE=2` human escalations were available; neither
was needed.) Both terminals are closed; transition to Phase 3.

---

## Phase 3: User Confirmation

Again via the coordinator's native channel (`≤ ORCA_WORKFLOW_MAX_USER_CONFIRM=3`
rounds; **Abort terminates the workflow immediately at any round**; there is
no scope-reduction option — use Revise):

```
Coordinator → user (native channel):
  "✅ Plan approved internally (review round 1: PASS).

   - ONE feature worktree + branch feature/add-user-prefs off origin/main,
     ONE PR at the end.
   - Wave 0: sub-1 prefs-api  (owns server/**, migrations/**)
   - Wave 1: sub-2 prefs-ui   (owns web/src/settings/**) — starts only after
     sub-1 passes review.
   - Estimated: ~2–3 h, up to 3 review rounds per subtask, whole-feature
     integration review before the PR.

   [Approve]  [Revise]  [Abort]"

User → coordinator: "Approve"
```

---

## Phase 4: Feature Worktree & Wave 0 Dispatch

The coordinator stays on main. Its only git ops in its own checkout are
`git fetch origin` (optionally `git pull --ff-only`).

```bash
git fetch origin main

# Resume/existence check, matched by name:
orca worktree list --json \
  | jq -r '.result.worktrees[]? | select(.name=="add-user-prefs") | .id'
# → empty: no leftover worktree from an earlier run
# (confirm exact JSON field names on first live run)

# Create the ONE feature worktree; the branch feature/add-user-prefs is based
# on origin/main. No positional path arg, no --base flag.
WT_JSON=$(orca worktree create \
  --name "add-user-prefs" \
  --base-branch origin/main \
  --json)
WT_ID=$(jq -r '.result.worktree.id' <<<"$WT_JSON")       # → wt_7f3a2c
WT_PATH=$(jq -r '.result.worktree.path' <<<"$WT_JSON")   # → /Users/dev/worktrees/add-user-prefs
WT_BRANCH=$(jq -r '.result.worktree.branch' <<<"$WT_JSON") # → feature/add-user-prefs
# (confirm exact JSON field names on first live run)
```

Record the worktree in `.orca/workflow-state.json` — **all** state updates
are jq atomic writes (tmp file + `mv`), never `>>` into JSON:

```bash
jq --arg id "$WT_ID" --arg path "$WT_PATH" --arg branch "$WT_BRANCH" '
    .feature_slug = "add-user-prefs"
  | .worktree = {id: $id, path: $path, branch_name: $branch, base_branch: "origin/main"}
  | .current_phase = "DISPATCHING"
' .orca/workflow-state.json > .orca/workflow-state.json.tmp \
  && mv .orca/workflow-state.json.tmp .orca/workflow-state.json
```

Wave computation: `sub-1` has no deps → wave 0; `sub-2` depends on `sub-1` →
wave 1. **Only wave 0 is dispatched now.** Even though the worktree is
shared, `sub-2` must wait for `sub-1`'s verdict — it will see sub-1's
committed code naturally in the same checkout later.

```bash
# Every dispatch records the subtask's base_sha = current feature-branch HEAD.
SUB1_BASE=$(cd "$WT_PATH" && git rev-parse HEAD)   # 9f02c1ab… (== origin/main at creation)

EXEC_S1=$(orca terminal create \
  --worktree "id:$WT_ID" \
  --title "[execution:claude] sub-1 r0 prefs-api" \
  --command "claude" \
  --json | jq -r '.result.terminal.handle')            # → term_s1e0

SUB1_TASK=$(orca orchestration task-create \
  --task-title "Sub: prefs-api (round 0)" \
  --display-name "🔧 prefs-api r0" \
  --deps '[]' \
  --spec "ROLE: execution agent for subtask sub-1 (prefs-api), round 0 of 3.
WORKTREE: $WT_PATH   (branch: feature/add-user-prefs, base: origin/main)
BASE_SHA: $SUB1_BASE  — your work is reviewed as $SUB1_BASE..HEAD
OWNS: server/**, migrations/**  — write ONLY inside these globs; the worktree
      is shared with other subtasks.
SPEC: Implement POST /api/preferences (upsert, JWT-scoped) and
      GET /api/preferences, plus an idempotent migration creating
      user_preferences(user_id, theme, language, email_digest, updated_at).
REVIEW CRITERIA: JWT scope enforced; schema matches plan; migration idempotent.
COMMIT: commit your work in small commits.
DONE: send worker_done EXACTLY ONCE to the coordinator handle with
      taskId + dispatchId + verdict + artifact summary, then idle." \
  --json | jq -r '.result.task.id')                    # → task_s1r0

orca orchestration dispatch --task "$SUB1_TASK" --to "$EXEC_S1" --inject --json
```

State after Phase 4 (`.orca/workflow-state.json`):

```json
{
  "workflow_id": "wf_20260727_001",
  "version": "2.2.0",
  "started_at": "2026-07-27T10:30:12Z",
  "current_phase": "DISPATCHING",
  "current_state": "WAVE0_DISPATCHED",
  "termination_reason": null,
  "delivery_mode": null,
  "feature_slug": "add-user-prefs",
  "worktree": {
    "id": "wt_7f3a2c",
    "path": "/Users/dev/worktrees/add-user-prefs",
    "branch_name": "feature/add-user-prefs",
    "base_branch": "origin/main"
  },
  "pr": { "url": null, "state": null, "merged_at": null },
  "phases": {
    "GATHERING": { "completed_at": "2026-07-27T10:36:00Z", "rounds": 1 },
    "PLANNING": { "completed_at": "2026-07-27T10:47:00Z", "review_rounds": 1, "verdict": "PASS" },
    "CONFIRMING": { "completed_at": "2026-07-27T10:49:00Z", "rounds": 1, "decision": "approve" }
  },
  "tasks": {
    "plan": { "task_id": "task_plan01", "review_task_id": "task_prev01", "verdict": "PASS", "review_rounds": 1 },
    "subtasks": [
      {
        "id": "sub-1",
        "logical_id": "prefs-api",
        "title": "Preferences API (Fastify + Postgres)",
        "complexity": "general",
        "deps": [],
        "owns": ["server/**", "migrations/**"],
        "status": "dispatched",
        "verdict": null,
        "reason": null,
        "base_sha": "9f02c1ab3d9e4a0f7c2b1e5d8a6f4c3b2a19087f",
        "initial_base_sha": "9f02c1ab3d9e4a0f7c2b1e5d8a6f4c3b2a19087f",
        "review_rounds": 0,
        "terminals": [
          { "handle": "term_s1e0", "role": "execution", "round": 0, "agent_type": "claude", "status": "running", "verdict": null, "spawned_at": "2026-07-27T10:52:00Z", "closed_at": null }
        ],
        "keep_terminal": null
      },
      {
        "id": "sub-2",
        "logical_id": "prefs-ui",
        "title": "Preferences UI (React + React Query)",
        "complexity": "general",
        "deps": ["sub-1"],
        "owns": ["web/src/settings/**"],
        "status": "pending",
        "verdict": null,
        "reason": null,
        "base_sha": null,
        "initial_base_sha": null,
        "review_rounds": 0,
        "terminals": [],
        "keep_terminal": null
      }
    ]
  },
  "integration_review": { "rounds": 0, "verdict": null },
  "decisions": [
    { "phase": "CONFIRMING", "decision": "approve", "at": "2026-07-27T10:49:00Z" }
  ],
  "retry_counts": { "global_retries_used": 0 },
  "errors": []
}
```

---

## Phase 5: Execution Waves & Cross-Review

Rounds are numbered `0..ORCA_WORKFLOW_MAX_SUB_RETRY` (0..3 = 1 initial
attempt + ≤3 retries). Every round = execution/fix on a **fresh terminal via
a NEW task** (chained with `--parent`; never re-dispatch the same task — Orca
circuit-breaks a task after 3 consecutive failures), then cross-review on
**another fresh terminal** with the review agent (`pi` ≠ `claude`). While
waiting, the coordinator runs `orca orchestration check --wait ...` in a
rolling loop; a timeout just means "peek at `task-list` and the worker
terminals for liveness, then wait again." Subtask wall-clock timeouts are
enforced by the coordinator itself (`task-update --status failed` +
`orca terminal close --terminal <handle>`), and a failed execution may be
retried via the fallback chain (`grok,pi`) — each fallback attempt is also a
NEW task + NEW terminal. Neither happens in this run.

### Wave 0 — sub-1 (prefs-api)

**Round 0 — execution.** `claude` on `term_s1e0` implements the API in three
small commits (`9f02c1ab..41d8e77c`), sends `worker_done` once, idles.

**Round 0 — cross-review** on a fresh `pi` terminal, restricted to the
recorded range and the subtask's `owns`:

```bash
REV_S1=$(orca terminal create \
  --worktree "id:$WT_ID" \
  --title "[review:pi] sub-1 r0 review" \
  --command "pi" \
  --json | jq -r '.result.terminal.handle')              # → term_s1r0

SUB1_REVIEW=$(orca orchestration task-create \
  --task-title "Review: prefs-api r0" \
  --display-name "🔍 prefs-api r0 review" \
  --parent "$SUB1_TASK" \
  --spec "ROLE: read-only review agent for subtask sub-1 (prefs-api), round 0.
Review ONLY the range 9f02c1ab..HEAD inside owns (server/**, migrations/**):
  (cd $WT_PATH && git log --oneline 9f02c1ab..HEAD && \
                  git diff 9f02c1ab..HEAD -- server migrations)
Do NOT modify any file.
CRITERIA: JWT scope enforced; schema matches plan; migration idempotent.
DONE: worker_done EXACTLY ONCE with verdict PASS|FAIL + reasons, then idle." \
  --json | jq -r '.result.task.id')

orca orchestration dispatch --task "$SUB1_REVIEW" --to "$REV_S1" --inject --json
```

**Verdict: FAIL** — `migrations/20260727110000_create_user_preferences.sql`
errors on a second run (bare `CREATE TABLE` + plain `INSERT` seed); not
idempotent. Close `term_s1r0`. `sub-1.review_rounds = 1`.

**Round 1 — fix.** NEW task chained with `--parent`, FRESH terminal, prior
feedback quoted in the preamble, and a **newly recorded `base_sha`** (the
current feature-branch HEAD):

```bash
SUB1_BASE=$(cd "$WT_PATH" && git rev-parse HEAD)   # 41d8e77c… — overwrite sub-1.base_sha
                                                    # (initial_base_sha stays 9f02c1ab…)

FIX_S1=$(orca terminal create \
  --worktree "id:$WT_ID" \
  --title "[fix:claude] sub-1 r1 prefs-api" \
  --command "claude" \
  --json | jq -r '.result.terminal.handle')              # → term_s1e1

SUB1_FIX=$(orca orchestration task-create \
  --task-title "Fix: prefs-api (round 1)" \
  --display-name "🛠 prefs-api r1 fix" \
  --parent "$SUB1_TASK" \
  --spec "ROLE: fix agent for subtask sub-1 (prefs-api), round 1 of 3.
WORKTREE: $WT_PATH   (branch: feature/add-user-prefs)
BASE_SHA: $SUB1_BASE  — your work is reviewed as $SUB1_BASE..HEAD
OWNS: server/**, migrations/**  — write ONLY inside these globs.
PRIOR FEEDBACK (review round 0, FAIL): the migration is not idempotent —
  second run fails on CREATE TABLE. Use CREATE TABLE IF NOT EXISTS and
  ON CONFLICT DO NOTHING for the seed row.
COMMIT: commit your work in small commits.
DONE: worker_done EXACTLY ONCE with taskId + dispatchId + verdict + summary,
      then idle." \
  --json | jq -r '.result.task.id')

orca orchestration dispatch --task "$SUB1_FIX" --to "$FIX_S1" --inject --json
```

The fix lands as one commit (`41d8e77c..c3b55d9e`).

**Round 1 — cross-review** on ANOTHER fresh `pi` terminal (`term_s1r1`),
range `41d8e77c..HEAD`, same criteria. **Verdict: PASS** — migration now
idempotent; all criteria met. Close `term_s1r1`.

`sub-1`: verdict=PASS, review_rounds=2, keep_terminal=`term_s1e1` (the newest
implementation terminal wins; `term_s1e0` is closed).

### Wave 1 — sub-2 (prefs-ui)

Gate check: ALL parents of `sub-2` have verdict=PASS ✅ (`sub-1`). The
dispatcher now sends `sub-2` into the **same** worktree — it naturally sees
sub-1's committed API code.

```bash
SUB2_BASE=$(cd "$WT_PATH" && git rev-parse HEAD)   # c3b55d9e… — sub-2's first dispatch:
                                                    # record as base_sha AND initial_base_sha

EXEC_S2=$(orca terminal create \
  --worktree "id:$WT_ID" \
  --title "[execution:claude] sub-2 r0 prefs-ui" \
  --command "claude" \
  --json | jq -r '.result.terminal.handle')            # → term_s2e0

SUB2_TASK=$(orca orchestration task-create \
  --task-title "Sub: prefs-ui (round 0)" \
  --display-name "🔧 prefs-ui r0" \
  --deps '["sub-1"]' \
  --spec "ROLE: execution agent for subtask sub-2 (prefs-ui), round 0 of 3.
WORKTREE: $WT_PATH   (branch: feature/add-user-prefs)
BASE_SHA: $SUB2_BASE  — your work is reviewed as $SUB2_BASE..HEAD
OWNS: web/src/settings/**  — write ONLY inside this glob; the worktree is
      shared. The API you consume is already committed under server/**.
SPEC: Implement /settings/preferences (theme selector, language selector,
      email-digest switch) with React Query fetch + optimistic update and a
      toast on save, against GET/POST /api/preferences.
REVIEW CRITERIA: hooks consume the prefs-api contract; optimistic update;
      a11y (aria-labels + keyboard nav).
COMMIT: commit your work in small commits.
DONE: worker_done EXACTLY ONCE with taskId + dispatchId + verdict + summary,
      then idle." \
  --json | jq -r '.result.task.id')

orca orchestration dispatch --task "$SUB2_TASK" --to "$EXEC_S2" --inject --json
```

**Round 0 — execution:** two small commits (`c3b55d9e..7ea01f42`).
**Round 0 — cross-review** on fresh `pi` terminal `term_s2r0`, range
`c3b55d9e..HEAD` within `web/src/settings/**`. **Verdict: PASS** on the first
attempt. `sub-2`: verdict=PASS, review_rounds=1, keep_terminal=`term_s2e0`.

### Terminal ledger (per round)

| Handle | Stage | Role | Round | Agent | Verdict | Fate |
|--------|-------|------|-------|-------|---------|------|
| `term_plan` | Planning | plan | — | Plan | plan delivered | closed after review |
| `term_prev` | Planning | review | 1 | pi | PASS | closed |
| `term_s1e0` | sub-1 | execution | 0 | claude | done | closed (superseded by r1) |
| `term_s1r0` | sub-1 | review | 0 | pi | FAIL | closed |
| `term_s1e1` | sub-1 | fix | 1 | claude | done | **keep_terminal** → closed in Phase 8 |
| `term_s1r1` | sub-1 | review | 1 | pi | PASS | closed |
| `term_s2e0` | sub-2 | execution | 0 | claude | done | **keep_terminal** → closed in Phase 8 |
| `term_s2r0` | sub-2 | review | 0 | pi | PASS | closed |
| `term_ir1` | Phase 7 | integration-review | 1 | pi | FAIL | closed |
| `term_irf` | Phase 7 | fix | 1 | claude | done | closed in Phase 8 |
| `term_ir2` | Phase 7 | integration-review | 2 | pi | PASS | closed |

### State after Phase 5 (excerpt: `tasks.subtasks`)

```json
{
  "subtasks": [
    {
      "id": "sub-1",
      "logical_id": "prefs-api",
      "title": "Preferences API (Fastify + Postgres)",
      "complexity": "general",
      "deps": [],
      "owns": ["server/**", "migrations/**"],
      "status": "completed",
      "verdict": "PASS",
      "reason": null,
      "base_sha": "41d8e77c0b2f4a69183d5c7e9f1a3b5d7c9e1f02",
      "initial_base_sha": "9f02c1ab3d9e4a0f7c2b1e5d8a6f4c3b2a19087f",
      "review_rounds": 2,
      "terminals": [
        { "handle": "term_s1e0", "role": "execution", "round": 0, "agent_type": "claude", "status": "closed", "verdict": "done", "spawned_at": "2026-07-27T10:52:00Z", "closed_at": "2026-07-27T11:19:00Z" },
        { "handle": "term_s1r0", "role": "review", "round": 0, "agent_type": "pi", "status": "closed", "verdict": "FAIL", "spawned_at": "2026-07-27T11:12:00Z", "closed_at": "2026-07-27T11:18:00Z" },
        { "handle": "term_s1e1", "role": "fix", "round": 1, "agent_type": "claude", "status": "idle", "verdict": "done", "spawned_at": "2026-07-27T11:19:00Z", "closed_at": null },
        { "handle": "term_s1r1", "role": "review", "round": 1, "agent_type": "pi", "status": "closed", "verdict": "PASS", "spawned_at": "2026-07-27T11:31:00Z", "closed_at": "2026-07-27T11:37:00Z" }
      ],
      "keep_terminal": "term_s1e1"
    },
    {
      "id": "sub-2",
      "logical_id": "prefs-ui",
      "title": "Preferences UI (React + React Query)",
      "complexity": "general",
      "deps": ["sub-1"],
      "owns": ["web/src/settings/**"],
      "status": "completed",
      "verdict": "PASS",
      "reason": null,
      "base_sha": "c3b55d9e8a4f2c6071b3d5e7f9a1c3e5b7d9f1a3",
      "initial_base_sha": "c3b55d9e8a4f2c6071b3d5e7f9a1c3e5b7d9f1a3",
      "review_rounds": 1,
      "terminals": [
        { "handle": "term_s2e0", "role": "execution", "round": 0, "agent_type": "claude", "status": "idle", "verdict": "done", "spawned_at": "2026-07-27T11:38:00Z", "closed_at": null },
        { "handle": "term_s2r0", "role": "review", "round": 0, "agent_type": "pi", "status": "closed", "verdict": "PASS", "spawned_at": "2026-07-27T11:52:00Z", "closed_at": "2026-07-27T11:58:00Z" }
      ],
      "keep_terminal": "term_s2e0"
    }
  ]
}
```

Note: `base_sha` holds the SHA recorded at the subtask's **latest** dispatch
(sub-1: its round-1 fix dispatch; sub-2: its round-0 dispatch) — each review
covers exactly `<base_sha>..HEAD` for its round. `initial_base_sha` is written
once at the round-0 dispatch and never overwritten; it anchors the
degrade-revert range (`<initial_base_sha>..HEAD` limited to `owns`, §10).

---

## Phase 6: Aggregation & Decision

Both subtasks reached verdict=PASS → straight to Phase 7. No global retry
(`global_retries_used` stays 0 of `ORCA_WORKFLOW_MAX_GLOBAL_RETRY=2`). For
the not-all-pass path, see the **Failure-Scenario Sidebar** at the end.

---

## Phase 7: Rebase, Tests, Integration Review & PR

All steps run **inside the feature worktree**; the coordinator never leaves
main.

### Rebase onto origin/main

```bash
( cd "$WT_PATH" && git fetch origin main && git rebase origin/main )
# → clean: main gained one unrelated docs commit; no overlap with our owns
```

Had there been conflicts, the autofix loop would run ≤
`ORCA_WORKFLOW_MAX_AUTOFIX=2` attempts — a fresh terminal resolves markers
and runs `git rebase --continue`, and SUCCESS requires the rebase to have
completed AND zero `^UU` files; any autofix failure escalates to a human
(manual resolve or PARK). Not needed here.

### Project tests (in the worktree)

```bash
( cd "$WT_PATH" && npm test )
# ✔ 42 passed, 0 failed — recorded in state under phases.MERGING
```

### Integration review (new in v2.2.0)

Per-subtask reviews passed in isolation; now a FRESH `pi` terminal reviews
the **whole feature as one unit** — read-only mandate, verdict via
`worker_done`:

```bash
IR1=$(orca terminal create \
  --worktree "id:$WT_ID" \
  --title "[integration-review:pi] feature r1" \
  --command "pi" \
  --json | jq -r '.result.terminal.handle')                # → term_ir1

IR1_TASK=$(orca orchestration task-create \
  --task-title "Integration review r1" \
  --display-name "🧪 integration review r1" \
  --spec "ROLE: read-only INTEGRATION review agent for feature add-user-prefs,
round 1 of 2. Review the WHOLE feature as one unit:
  (cd $WT_PATH && git diff origin/main...HEAD)
INPUTS: approved plan (quoted below); per-subtask verdicts (sub-1 PASS in
round 1, sub-2 PASS in round 0); test results (42 passed, 0 failed).
FOCUS: cross-subtask consistency (API contract vs client usage), migration
safety, dead code, missing error handling. Do NOT modify any file.
DONE: worker_done EXACTLY ONCE with verdict PASS|FAIL + findings, then idle.

PLAN:
<approved plan text>" \
  --json | jq -r '.result.task.id')

orca orchestration dispatch --task "$IR1_TASK" --to "$IR1" --inject --json
```

**Round 1 verdict: FAIL** — the API error envelope is inconsistent: the
server replies `400 {"error":{"code":"INVALID_PREFS","message":"…"}}` but
`web/src/settings/api.ts` types failures as `{message: string}`, so the UI
toasts "undefined" on validation errors. Close `term_ir1`.

A FRESH fix terminal applies the findings and commits (round 1 fix):

```bash
IRFIX=$(orca terminal create \
  --worktree "id:$WT_ID" \
  --title "[fix:claude] integration fix r1" \
  --command "claude" \
  --json | jq -r '.result.terminal.handle')                # → term_irf

IRFIX_TASK=$(orca orchestration task-create \
  --task-title "Integration fix r1" \
  --display-name "🛠 integration fix r1" \
  --parent "$IR1_TASK" \
  --spec "ROLE: fix agent for the add-user-prefs integration review, round 1.
WORKTREE: $WT_PATH   (branch: feature/add-user-prefs)
FINDINGS (verbatim from integration review round 1): align the error envelope —
  server returns {error:{code,message}}; web types expect {message}. Make the
  web client consume the server envelope and map known codes to toasts.
COMMIT: commit your work in small commits.
DONE: worker_done EXACTLY ONCE with taskId + dispatchId + verdict + summary,
      then idle." \
  --json | jq -r '.result.task.id')

orca orchestration dispatch --task "$IRFIX_TASK" --to "$IRFIX" --inject --json
# fix lands as one commit → HEAD = 8bd40c17…
```

**Round 2:** ANOTHER FRESH `pi` terminal (`term_ir2`) re-reviews
`git diff origin/main...HEAD`. **Verdict: PASS.** State:
`integration_review = {rounds: 2, verdict: "PASS"}`. Had round 2 also failed
(limit `ORCA_WORKFLOW_MAX_INTEGRATION_REVIEW=2` reached), the human would
choose: release anyway or PARK.

### Create the ONE PR (exit code checked)

```bash
( cd "$WT_PATH" && git push -u origin feature/add-user-prefs )

PR_URL=$(gh pr create \
  --base main \
  --head feature/add-user-prefs \
  --title "feat: user preferences (API + settings UI)" \
  --body "$(cat <<'EOF'
## Summary
- **sub-1 prefs-api** — POST/GET `/api/preferences` (JWT-scoped) + idempotent
  `user_preferences` migration. Review: PASS in round 1 (round 0 FAIL:
  non-idempotent migration, fixed).
- **sub-2 prefs-ui** — `/settings/preferences` page (React Query, optimistic
  update, a11y). Review: PASS in round 0.

## Artifacts
- Plan + all review verdicts: orchestration history `wf_20260727_001`
- Tests (run in the feature worktree after rebase): 42 passed, 0 failed

## Integration review
PASS in round 2 of 2 (round 1 FAIL: API error envelope aligned between server
and web types).

_Delivery mode: full — both subtasks shipped._
EOF
)")
if [ $? -ne 0 ] || [ -z "$PR_URL" ]; then
  echo "gh pr create failed — park the feature and surface to the user" >&2
fi
# → https://github.com/org/my-app/pull/118
```

(The body would carry a `⚠️ degraded` banner had any subtask been dropped.)

### Monitor until merged

```bash
while true; do
  PR_JSON=$(gh pr view 118 --json state,mergeStateStatus)
  STATE=$(jq -r '.state' <<<"$PR_JSON")
  case "$STATE" in
    MERGED) break ;;
    CLOSED) echo "PR closed without merge → park the feature"; break ;;
  esac
  # CHANGES_REQUESTED → fresh pr-fix terminal applies the feedback, pushes,
  # and monitoring continues.
  sleep 60   # poll every 60s — NEVER gate-create inside this loop
done
```

A human approves and merges at 13:05 → `pr.state = "MERGED"`,
`pr.merged_at = "2026-07-27T13:05:41Z"`. Transition to Phase 8.

---

## Phase 8: Cleanup

MERGED path — delete the remote branch, remove the ONE worktree, close the
kept terminals, and afterwards the coordinator only fetches (never checks
out):

```bash
git push origin --delete feature/add-user-prefs

orca worktree rm --worktree "id:$WT_ID" --force --json   # ("worktree remove" does NOT exist)

# orca worktree rm deletes the local branch only when it is fully merged —
# an unmerged branch is left behind (verified across two v2.2.0 smoke runs).
# Delete explicitly to cover both cases; -D not -d (a squash-merged PR's local
# tip is not an ancestor of main); "not found" just means orca already did it.
git branch -D feature/add-user-prefs 2>/dev/null || true

orca terminal close --terminal term_s1e1 --json   # sub-1 keep_terminal
orca terminal close --terminal term_s2e0 --json   # sub-2 keep_terminal
orca terminal close --terminal term_irf  --json   # integration fix terminal

git fetch origin    # the coordinator's only git op afterwards — NEVER git checkout
```

Append **ONE** history line to `.orca/workflow-history.jsonl`, atomically
(build the new file in a tmp file, then `mv` — never `>>` JSON):

```bash
LINE=$(jq -nc '{
  workflow_id: "wf_20260727_001", feature_slug: "add-user-prefs",
  branch: "feature/add-user-prefs",
  pr_url: "https://github.com/org/my-app/pull/118", pr_state: "MERGED",
  delivery_mode: "full", duration_min: 156,
  timestamp: "2026-07-27T13:06:20Z"}')
TMP=$(mktemp .orca/workflow-history.jsonl.XXXXXX)
{ [ -f .orca/workflow-history.jsonl ] && cat .orca/workflow-history.jsonl; \
  printf '%s\n' "$LINE"; } > "$TMP"
mv "$TMP" .orca/workflow-history.jsonl
```

Final state update (jq atomic write) and final state:

```bash
jq '
    .current_phase = "CLEANING" | .current_state = "DONE"
  | .delivery_mode = "full"
  | .pr.state = "MERGED" | .pr.merged_at = "2026-07-27T13:05:41Z"
  | .integration_review = {rounds: 2, verdict: "PASS"}
  | .phases.CLEANING = {completed_at: "2026-07-27T13:06:20Z"}
' .orca/workflow-state.json > .orca/workflow-state.json.tmp \
  && mv .orca/workflow-state.json.tmp .orca/workflow-state.json
```

```json
{
  "workflow_id": "wf_20260727_001",
  "version": "2.2.0",
  "started_at": "2026-07-27T10:30:12Z",
  "current_phase": "CLEANING",
  "current_state": "DONE",
  "termination_reason": null,
  "delivery_mode": "full",
  "feature_slug": "add-user-prefs",
  "worktree": {
    "id": "wt_7f3a2c",
    "path": "/Users/dev/worktrees/add-user-prefs",
    "branch_name": "feature/add-user-prefs",
    "base_branch": "origin/main"
  },
  "pr": {
    "url": "https://github.com/org/my-app/pull/118",
    "state": "MERGED",
    "merged_at": "2026-07-27T13:05:41Z"
  },
  "phases": {
    "GATHERING": { "completed_at": "2026-07-27T10:36:00Z", "rounds": 1 },
    "PLANNING": { "completed_at": "2026-07-27T10:47:00Z", "review_rounds": 1, "verdict": "PASS" },
    "CONFIRMING": { "completed_at": "2026-07-27T10:49:00Z", "rounds": 1, "decision": "approve" },
    "DISPATCHING": { "completed_at": "2026-07-27T10:52:00Z", "waves": 2 },
    "EXECUTING": { "completed_at": "2026-07-27T11:58:00Z", "passed": 2, "failed": 0 },
    "DECIDING": { "completed_at": "2026-07-27T11:59:00Z", "outcome": "all_pass" },
    "MERGING": { "completed_at": "2026-07-27T13:05:41Z", "rebase": "clean", "tests": "42 passed, 0 failed", "pr_url": "https://github.com/org/my-app/pull/118" },
    "CLEANING": { "completed_at": "2026-07-27T13:06:20Z" }
  },
  "tasks": {
    "plan": { "task_id": "task_plan01", "review_task_id": "task_prev01", "verdict": "PASS", "review_rounds": 1 },
    "subtasks": [
      { "id": "sub-1", "logical_id": "prefs-api", "status": "completed", "verdict": "PASS", "review_rounds": 2, "keep_terminal": "term_s1e1" },
      { "id": "sub-2", "logical_id": "prefs-ui", "status": "completed", "verdict": "PASS", "review_rounds": 1, "keep_terminal": "term_s2e0" }
    ]
  },
  "integration_review": { "rounds": 2, "verdict": "PASS" },
  "decisions": [
    { "phase": "CONFIRMING", "decision": "approve", "at": "2026-07-27T10:49:00Z" },
    { "phase": "DECIDING", "decision": "proceed_to_merge", "at": "2026-07-27T11:59:00Z" }
  ],
  "retry_counts": { "global_retries_used": 0 },
  "errors": []
}
```

(The full per-subtask `owns`/`base_sha`/`terminals[]` records from Phase 5
remain in the file; trimmed here for readability.)

### Notification

```
Coordinator → user (native channel):
  "🎉 User preferences shipped.
   - PR #118 MERGED into main (integration review PASS, round 2 of 2)
   - Branch feature/add-user-prefs deleted; worktree wt_7f3a2c removed;
     worker terminals closed
   - History appended to .orca/workflow-history.jsonl
   Nothing parked; delivery mode: full."
```

---

## Metrics for This Run

| Metric | Value |
|--------|-------|
| Total wall-clock | ~2 h 36 min (10:30 → 13:06) |
| Clarification rounds | 1 (≤5) |
| Plan review rounds | 1 (≤3) |
| Human escalations | 0 (≤2) |
| User confirm rounds | 1 (≤3) |
| Subtask pass rate | 2/2 (100%) |
| Per-subtask review rounds | sub-1 = 2, sub-2 = 1 |
| Subtask retries used | sub-1 = 1 of 3, sub-2 = 0 of 3 |
| Integration review rounds | 2 (≤2) |
| Global retries | 0 (≤2) |
| Autofix attempts | 0 (≤2) |
| Fallback attempts | 0 |
| Terminals spawned | 11 |
| Worktrees / branches / PRs | 1 / 1 / 1 |
| Delivery mode | full |

---

## Failure-Scenario Sidebar: sub-2 Exhausts Its Retries

Counterfactual: sub-2's cross-review keeps failing — "optimistic update
reverts on rollback" persists through round 3 (rounds `0..3` = 1 initial
attempt + 3 retries = `ORCA_WORKFLOW_MAX_SUB_RETRY`). After the final round's
review the coordinator marks `sub-2` verdict=FAIL. **Siblings continue** —
sub-1's PASS stands. In Phase 6 the coordinator surfaces the decision through
its **native channel** (not `gate-create`):

```
Coordinator → user (native channel):
  "⚠️ 1/2 subtasks failed:
   - sub-2 (prefs-ui): review never passed after 4 rounds (0..3).
     Last feedback: 'Optimistic update still reverts on rollback.'
   Choose:
   [1] Retry failed subtasks only
   [2] Degrade — drop sub-2, ship sub-1
   [3] Abort — park the whole feature"
```

- **[1] Retry failed subtasks only.** Allowed while
  `global_retries_used < ORCA_WORKFLOW_MAX_GLOBAL_RETRY` (2), checked
  **before** incrementing → at most 2 global retries. `sub-2` re-enters its
  round loop with a fresh task chain and fresh terminals; `sub-1` is
  untouched — its verdict and commits stand.
- **[2] Degrade.** The coordinator reverts sub-2's commit range **inside the
  feature worktree**:

  ```bash
  ( cd "$WT_PATH" && git revert --no-edit c3b55d9e..7ea01f42 )
  # c3b55d9e = sub-2.initial_base_sha (round-0 dispatch HEAD) → the range
  # covers ALL of sub-2's rounds; sub-1's commits are untouched.
  ```

  The revert is clean **because owns are disjoint** — sub-2's commits touch
  only `web/src/settings/**`, which no other subtask ever wrote. Execution
  continues to Phase 7 with `delivery_mode = "degraded"` and a ⚠️ degraded
  banner in the PR body. If the revert is **not** clean → park the whole
  feature instead.
- **[3] Abort → TERMINATED**, and the whole feature is parked: write
  `.orca/parked/add-user-prefs.md` (branch, worktree path, PR url if any,
  reason, recovery steps), **KEEP** the worktree + branch for later
  resumption, close the terminals, and append the single history line with
  `pr_state: "PARKED"`.
