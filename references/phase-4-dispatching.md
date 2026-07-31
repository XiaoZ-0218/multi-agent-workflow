# Phase 4 — Task Decomposition & Dispatch

> Extracted from SKILL.md §8 — the full operational procedure for this phase. The coordinator reads this file when entering the phase; SKILL.md keeps only the skeleton.

**Goal**: Create the **single** feature worktree + branch, decompose the plan
into a subtask DAG, compute waves, and dispatch wave 0 — one fresh terminal and
one new orchestration task per subtask.

### 8.1 Entry Condition

- State: `DISPATCHING`
- Input: Approved plan + user confirmation
- `feature_slug`: short kebab-case slug for the request (e.g. `add-user-prefs`)

### 8.2 Subtask Schema

Each subtask in the plan must declare:

```json
{
  "id": "sub-1",
  "logical_id": "prefs-api",
  "title": "Preferences API",
  "deps": [],
  "owns": ["src/prefs/**", "docs/prefs.md"],
  "complexity": "general",
  "spec": "Implement the preferences REST endpoints …",
  "review_criteria": [
    "All endpoints return the documented schemas",
    "Input validation rejects malformed payloads",
    "Unit tests cover the new handlers"
  ],
  "timeout_ms": 1800000
}
```

- `owns` (NEW in v2.2.0): file/dir globs, relative to the repo root, that this
  subtask — and only this subtask — may write. Same-wave subtasks must be
  disjoint (validated in §6.3).
- `complexity`: `general` | `complex` | `image`.

#### Agent Routing Rules

> 📖 **Agent selection: see [`docs/agent-routing.md`](./docs/agent-routing.md)** — single source of truth.

`complexity` picks the implementation agent; the role picks the rest:

- `"complex"` → `complex_execution_agent_type` (default `kimi`)
- `"image"` → `image_agent_type` (default `grok`)
- `"general"` or unset → `execution_agent_type` (default `kimi`; on error the
  fallback chain starts with `claude`)
- review role → `review_agent_type` (default `pi`) — **always ≠ the implementation agent**
- fix role → same agent as the subtask's implementation agent
- integration review → `review_agent_type` (reused; default `pi`)
- generic failure retries → `fallback_chain` (default `claude,grok,pi`)

`orca terminal create` has **no `--tags` flag** and terminal objects have no
`type`/`tags` fields. Agent identity is carried by (1) the `--title` prefix
convention `[<role>:<agent>] …` and (2) the coordinator's state record
(handle → role/round/agent_type).

### 8.3 Process — one worktree, then wave 0

```bash
FEATURE_SLUG="add-user-prefs"        # from the plan
STATE_FILE="${ORCA_WORKFLOW_STATE_FILE:-.orca/workflow-state.json}"

# 8.3.1 Fetch the base, then create the ONE feature worktree.
#       `orca worktree create` takes NO positional path arg and NO `--base`.
git fetch origin main

# Resume / existence check first: match by name (idempotent restarts)
WT_ID=$(orca worktree list --json | jq -r --arg n "$FEATURE_SLUG" \
  '[.result.worktrees[]? | select(.name == $n)] | .[0].id // empty')
# (exact JSON field names should be confirmed on first live run)

if [ -z "$WT_ID" ]; then
  WT_JSON=$(orca worktree create --name "$FEATURE_SLUG" --base-branch origin/main --json)
  WT_ID=$(echo "$WT_JSON"   | jq -r '.result.worktree.id')
  WT_PATH=$(echo "$WT_JSON" | jq -r '.result.worktree.path')
  BRANCH=$(echo "$WT_JSON"  | jq -r '.result.worktree.branch_name')
else
  WT_PATH=$(orca worktree list --json | jq -r --arg id "$WT_ID" \
    '.result.worktrees[] | select(.id == $id) | .path')
  BRANCH="feature/${FEATURE_SLUG}"
fi

# Record in state: worktree {id, path, branch_name, base_branch}
state_update ".worktree = {id:\"$WT_ID\", path:\"$WT_PATH\", branch_name:\"$BRANCH\", base_branch:\"origin/main\"}"

# 8.3.2 Decompose the plan into the subtask DAG and compute waves.
#       wave(sub) = 0 if deps == [] else 1 + max(wave(parent))
declare -A WAVE
compute_waves   # fills WAVE[sub-id]; validates acyclicity again

# 8.3.3 Dispatch wave 0: per subtask — task-create + FRESH terminal + dispatch --inject
for SUB in $(subtasks_in_wave 0); do
  AGENT=$(resolve_agent_type "${COMPLEXITY[$SUB]}")          # §8.2
  TASK_ID=$(orca orchestration task-create \
    --task-title "Sub: ${TITLE[$SUB]}" \
    --display-name "🔧 ${LOGICAL_ID[$SUB]}" \
    --spec "${SPEC[$SUB]}" \
    --deps "$(deps_json "$SUB")" \
    --json | jq -r '.result.task.id')

  TERM=$(orca terminal create \
    --worktree "id:$WT_ID" \
    --title "[execution:$AGENT] sub-$SUB r0" \
    --command "$(agent_command_for "$AGENT")" \
    --json | jq -r '.result.terminal.handle')

  # Wait for the agent CLI to be READY before injecting — dispatch --inject
  # types the preamble+task into the terminal, and a still-booting agent can
  # lose or garble it (lost preamble = the worker never reports worker_done
  # and the coordinator stalls at checkpoints). Applies to EVERY fresh
  # terminal in every phase (plan/review/execution/fix/fallback/autofix/
  # pr-fix/integration-review).
  orca terminal wait --terminal "$TERM" --for tui-idle --timeout-ms 60000 --json

  BASE_SHA=$(cd "$WT_PATH" && git rev-parse HEAD)            # record per dispatch

  orca orchestration dispatch --task "$TASK_ID" --to "$TERM" --inject --json

  record_subtask_state "$SUB" \
    status="dispatched" base_sha="$BASE_SHA" initial_base_sha="$BASE_SHA" keep_terminal="$TERM"
  # initial_base_sha is written ONCE here (round 0) and never overwritten;
  # base_sha is refreshed at every later dispatch (§9.2).
  append_terminal_history "$SUB" handle="$TERM" role="execution" round=0 agent_type="$AGENT"
done
```

### 8.4 Fallback Chain (per-subtask, per-round)

When an execution/fix round fails for infrastructure reasons (agent crash,
CLI error — *not* a review FAIL), retry with the fallback chain. **Each
fallback attempt is a NEW task + a NEW terminal.**

```bash
retry_with_fallback() {
  local sub_id="$1" failed_task_id="$2" round="$3"
  IFS=',' read -ra agents <<< "${ORCA_WORKFLOW_FALLBACK_CHAIN:-claude,grok,pi}"

  local prev_task="$failed_task_id"
  for agent in "${agents[@]}"; do
    local task_id handle
    task_id=$(orca orchestration task_create \
      --task-title "Sub: ${TITLE[$sub_id]} (fallback: $agent)" \
      --spec "$(build_fallback_spec "$sub_id")" \
      --parent "$prev_task" \
      --json | jq -r '.result.task.id')
    handle=$(orca terminal create \
      --worktree "id:$WT_ID" \
      --title "[fallback:$agent] sub-$sub_id r$round" \
      --command "$(agent_command_for "$agent")" \
      --json | jq -r '.result.terminal.handle')
    orca orchestration dispatch --task "$task_id" --to "$handle" --inject --json

    if wait_for_worker "$task_id" && [ "$(get_task_verdict "$task_id")" = "PASS" ]; then
      append_terminal_history "$sub_id" handle="$handle" role="fallback" round="$round" agent_type="$agent"
      return 0
    fi
    orca terminal close --terminal "$handle" --json
    prev_task="$task_id"
    echo "⚠️ fallback agent $agent failed, trying next…"
  done
  return 1
}
```

### 8.5 Injected Preamble (sent to every fresh terminal)

Every terminal — execution, fix, review, fallback, autofix, pr-fix,
integration-review — receives the same preamble shape via `dispatch --inject`:

```text
You are the {role} agent for subtask "{title}" (round {round}) in a multi-agent workflow.

Worktree: {worktree_path}   (SHARED feature worktree — sibling subtasks run here in parallel)
Branch: {branch_name}
Base SHA at this dispatch: {base_sha}
Your ownership (owns): {owns_globs}

## Rules
1. Work ONLY within paths matched by your owns globs. Never create, modify, or
   delete files outside them — the coordinator verifies after each round and
   reverts any out-of-owns writes.
2. Execution/fix only: commit your work in SMALL COMMITS on the branch above.
3. Review only: you are READ-ONLY. Review `git diff {base_sha}..HEAD` limited
   to the owns globs, against the review criteria below.
4. You are ONE round of one subtask. Do not review your own output; do not
   dispatch other agents; do not push, merge, or create PRs.
5. When finished, emit worker_done IMMEDIATELY and EXACTLY ONCE to the
   coordinator handle with {taskId, dispatchId, verdict, artifact summary} —
   send it BEFORE writing any long report or wrap-up, then idle (no polling,
   no further output). Put the verdict in BOTH the subject (prefix
   "PASS"/"FAIL") and the payload
   ({"verdict":"PASS"|"FAIL","reason":...}) — the coordinator reads the payload
   first and falls back to the subject prefix (smoke-run finding: some agents
   only write the subject). While working, send a heartbeat every 5 minutes
   per Orca's injected preamble — a stopped heartbeat plus an idle terminal
   is how the coordinator detects "finished but forgot to report".

## Task spec
{spec}

## Prior feedback (round > 0 only)
{prior_feedback}
```

### 8.6 Output

```json
{
  "phase": "DISPATCHING",
  "status": "complete",
  "feature_slug": "add-user-prefs",
  "worktree": {
    "id": "wt_abc123",
    "path": "../add-user-prefs",
    "branch_name": "feature/add-user-prefs",
    "base_branch": "origin/main"
  },
  "waves": [["sub-1", "sub-2"], ["sub-3"]],
  "subtasks": [
    {
      "id": "sub-1",
      "logical_id": "prefs-api",
      "orchestration_id": "task_xxx",
      "owns": ["src/prefs/**", "docs/prefs.md"],
      "base_sha": "a1b2c3d",
      "initial_base_sha": "a1b2c3d",
      "keep_terminal": "term_yyy",
      "terminals": [
        {"handle": "term_yyy", "role": "execution", "round": 0, "agent_type": "kimi", "status": "dispatched"}
      ]
    }
  ],
  "timestamp": "2026-07-27T10:30:00Z"
}
```

