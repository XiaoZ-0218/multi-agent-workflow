# API Command Reference

> Extracted from SKILL.md (§18) — consult on demand for the verified Orca CLI
> surface: orchestration, worktree, terminal, and external commands.

## 18. API Command Reference

This is the **verified** Orca CLI surface on this machine — flags not listed
here do not exist. In particular: `orca terminal create` has **no `--tags`**,
`orca terminal close` uses **`--terminal`** (not `--handle`), `orca worktree
create` takes **no positional path arg and no `--base`**, `orca orchestration
dispatch` has **no `--spec`**, and `orca worktree remove` does not exist (use
`orca worktree rm`).

### 18.1 `orca orchestration` Commands Used

| Command | Phase(s) | Purpose |
|---------|----------|---------|
| `task-create --spec <text> [--task-title] [--display-name] [--deps <json_array>] [--parent <task_id>] --json` | 2, 4, 5, 7 | Create plan/review/subtask/fix/autofix/integration-review tasks; `--parent` chains rounds |
| `dispatch --task <id> --to <handle> [--inject] --json` | 2, 4, 5, 7 | Send a task to a fresh terminal. **No `--spec`** — new instructions require a NEW task |
| `check --wait --types worker_done,escalation,decision_gate --timeout-ms <n> --json` | 2, 5, 7 | Block for worker events; returns ONE message at a time — drain queued events before heavy local work; timeout = checkpoint, keep rolling (long tasks take 15–60 min; keep `<n>` ≤ 300000) |
| `task-list [--status] [--ready] [--brief] --json` | 5, 6, recovery | Poll statuses; liveness check after `check` timeouts; find stragglers (`--brief` caps echoed specs at 160 chars) |
| `dispatch-show --task <id> --json` | 5, recovery | Checkpoint liveness: dispatch status + `last_heartbeat_at` (fresh heartbeat = alive, NOT done) |
| `task-update --id <id> --status <pending\|ready\|dispatched\|completed\|failed\|blocked> [--result <json>]` | recovery ONLY | A valid `worker_done` auto-completes task+dispatch — never follow one with `task-update completed`. Manual updates are for timeouts/cancellations/overrides |
| `gate-create --task <id> --question <text> [--options <json_array>]` | coordinator-managed DAG decisions ONLY | Every gate must name who resolves it. **Never** for agent reviews (use a review task + `worker_done`); **never** inside the PR poll loop |
| `ask --to <coordinator_handle>` | worker → coordinator ONLY | Workers escalate to the coordinator. The coordinator asks the USER via its **native** channel |
| `run --spec <text>` | — | Orca's **native single-agent runner** — listed for completeness; this workflow is started by describing the task to the coordinator in chat (see references/runbooks.md §17.1) |

### 18.2 `orca worktree` Commands Used

| Command | Phase(s) | Purpose |
|---------|----------|---------|
| `worktree current --json` → `.result.worktree.id` | 3 | Prereq: coordinator must be inside an Orca-managed checkout |
| `worktree list --json` | 4, recovery | Existence/resume check, matched by name |
| `worktree create --name "<slug>" --base-branch origin/main --json` | 4 | Create the ONE feature worktree (branch `feature/<slug>`). Read id/path from the JSON result — exact field names should be confirmed on first live run |
| `worktree rm --worktree id:<id> --force --json` | 8 | Remove the feature worktree after merge |

### 18.3 `orca terminal` Commands Used

| Command | Phase(s) | Purpose |
|---------|----------|---------|
| `terminal list --json` → `.result.terminals[]` fields: `handle,title,worktreeId,worktreePath,branch,connected,writable,…` | 5, 8, recovery | Liveness inspection; no `type`/`tags` fields exist |
| `terminal create --worktree id:<id> --title "[<role>:<agent>] …" --command "<agent cli>" --json` | 2, 4, 5, 7 | Spawn a FRESH terminal for every round of every role. Selectors: `id:`/`name:`/`path:`/`branch:`/`active`. No `--tags` |
| `terminal wait --terminal <handle> --for tui-idle --timeout-ms <n> --json` | 2, 4, 5, 7 | **Mandatory after every `terminal create`, before `dispatch --inject`** (60s timeout) — a still-booting agent can lose the injected preamble. Also a short-timeout liveness probe at checkpoints |
| `terminal read --terminal <handle> --json` | 5, recovery | Checkpoint inspection: idle vs still-working; collect results when a worker forgot `worker_done` |
| `terminal close --terminal <handle> --json` | 5, 7, 8 | Tear down review terminals after each round; close keep_terminal(s) in Phase 8. Uses `--terminal`, not `--handle` |

### 18.4 External Commands Used

| Command | Phase(s) | Purpose |
|---------|----------|---------|
| `git fetch origin` (optionally `git pull --ff-only`) | 3, 4, 8 | The coordinator's ONLY git ops in its own checkout — it never runs `git checkout` |
| `(cd <wt> && git fetch origin main && git rebase origin/main)` | 7 | Rebase the feature branch inside the worktree |
| `(cd <wt> && git status --porcelain / git diff --name-only <base_sha>..HEAD)` | 5 | Post-round owns verification |
| `(cd <wt> && git revert --no-commit <range>)` | 6 | Degrade: revert a failed subtask's commit range |
| `(cd <wt> && git push …)` | 7 | Push the feature branch (coordinator only) |
| `git push origin --delete <branch>` | 8 | Delete the merged feature branch |
| `gh pr create --base main --head <branch> --title … --body …` | 7 | Create the ONE feature PR — **always check the exit code** |
| `gh pr view --json state,mergeStateStatus` | 7 | PR lifecycle monitoring, 60s polling |
| `jq` (tmp file + `mv`) | all | Atomic state-file writes |
