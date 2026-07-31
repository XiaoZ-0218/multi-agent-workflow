# Testing, Validation & Operational Runbooks

> Extracted from SKILL.md (§16–§17) — consult on demand for dry-run mode,
> the phase validation checklist, the integration test scenario, and the
> start/resume/crash-recovery/cancel runbooks.

## 16. Testing & Validation

### 16.1 Dry-Run Mode

Set `ORCA_WORKFLOW_DRY_RUN=true` to simulate without side effects:

```bash
export ORCA_WORKFLOW_DRY_RUN=true
```

In dry-run mode the coordinator **prints every action and skips every
mutation** — no `worktree create`, no `terminal create`, no `task-create` /
`dispatch`, no `git push`, no `gh pr create` — **but it still writes the state
file** with `"dry_run": true` at the top level. State writes are intentional:
they let tests assert on the phase structure (§16.3) without any real side
effects.

### 16.2 Phase Validation Checklist

After each phase, validate:

- [ ] **Phase 1**: Clarified requirement is non-empty and has ≥ 3 concrete details
- [ ] **Phase 2**: Plan artifact (text) captured, review verdict PASS via `worker_done`, owns-disjointness validated
- [ ] **Phase 3**: User confirmation recorded with timestamp
- [ ] **Phase 4**: Exactly one worktree recorded in state; subtask deps form a valid DAG; same-wave `owns` disjoint; wave 0 dispatched
- [ ] **Phase 5**: All dispatched subtasks have verdicts; no writes outside `owns` remain unreverted
- [ ] **Phase 6**: Decision recorded (retry/degrade/abort); `global_retries_used ≤ 2`
- [ ] **Phase 7**: Rebase clean (zero `^UU`), tests recorded, integration-review verdict recorded, PR URL valid
- [ ] **Phase 8**: Worktree removed or parked manifest created; exactly one history line appended

### 16.3 Integration Test Scenario

```bash
# Test the full workflow with a trivial task, in dry-run mode
export ORCA_WORKFLOW_DRY_RUN=true
export ORCA_WORKFLOW_STRICT_PREREQ=false   # allow WARN-only prerequisite checks in CI

cd /path/to/project          # an Orca-managed checkout on main
./scripts/check-prerequisites.sh

# Describe the task to the coordinator agent in chat (NOT `orca orchestration run`):
#
#   "Dry-run smoke test: write a hello-world script hello.py that prints
#    'Hello, World!'. Python 3.10+, no external dependencies, no tests
#    required. Acceptance: `python hello.py` exits 0 with stdout 'Hello, World!'."
#
# The coordinator walks all 8 phases, printing the actions it WOULD take
# (worktree create, terminal spawns, dispatches, PR creation) and performing
# none of them — except the state file.

# Verify the state file was written with the full phase structure
jq -r '.dry_run' .orca/workflow-state.json
# Expected: true

jq '.phases | keys' .orca/workflow-state.json
# Expected: ["CLEANING","CONFIRMING","DECIDING","DISPATCHING","EXECUTING","GATHERING","MERGING","PLANNING"]
```

---

## 17. Operational Runbooks

### 17.1 Starting a New Workflow

```bash
# 1. Navigate to the project's MAIN checkout (the coordinator never leaves main)
cd /path/to/project

# 2. Verify prerequisites
./scripts/check-prerequisites.sh

# 3. Describe the task to the coordinator agent in chat, e.g.:
#    "Implement user preferences: a REST API for reading/updating prefs and a
#     settings page that consumes it. Acceptance: …"
#
#    Do NOT use `orca orchestration run --spec <file>` — that is Orca's native
#    single-agent runner, not this workflow (see references/api-reference.md §18.1).
#
# The coordinator takes over from Phase 1 and prompts you for clarifications.
```

### 17.2 Resuming a Parked Workflow

```bash
# 1. Find the parked manifest
ls .orca/parked/

# 2. Read the recovery instructions
cat .orca/parked/add-user-prefs.md

# 3. Follow them — typically:
cd ../add-user-prefs            # the KEPT feature worktree
git fetch origin main && git rebase origin/main
# resolve conflicts if any
git push --force-with-lease origin feature/add-user-prefs

# 4. Tell the coordinator (chat) to resume the workflow at Phase 7:
#    it re-runs the integration review (§11.4) and PR monitoring (§11.6)
```

### 17.3 Recovering from a Crash

```bash
# 1. Load the saved state
CURRENT_PHASE=$(jq -r '.current_phase' .orca/workflow-state.json)

# 2. Determine the recovery action by phase
case "$CURRENT_PHASE" in
  "INIT"|"GATHERING"|"PLANNING"|"CONFIRMING")
    echo "Early phase — restarting from the beginning is safe."
    ;;
  "DISPATCHING"|"EXECUTING")
    echo "Mid-flight — reuse the feature worktree if it exists, re-dispatch stragglers."
    # Worktree existence/resume check (matched by name):
    orca worktree list --json | jq -r --arg n "$FEATURE_SLUG" \
      '.result.worktrees[]? | select(.name == $n) | .id'
    # In-flight tasks:
    orca orchestration task-list --json | jq '.result.tasks[] | select(.status == "dispatched")'
    # Subtasks without a verdict → re-dispatch as NEW tasks (never reuse a
    # failed task id) on FRESH terminals, per §8.3.3.
    ;;
  "DECIDING"|"MERGING"|"CLEANING")
    echo "Late phase — resume from the recorded decision / pr.state."
    jq '.pr' .orca/workflow-state.json
    ;;
esac
```

### 17.4 Cancelling a Running Workflow

```bash
# 1. Mark all in-flight tasks as failed
for TASK_ID in $(orca orchestration task-list --json | jq -r '.result.tasks[] | select(.status == "dispatched") | .id'); do
  orca orchestration task-update --id "$TASK_ID" --status "failed" \
    --result '{"verdict":"FAIL","reason":"Workflow cancelled by user"}'
done

# 2. Persist the cancellation with a jq ATOMIC WRITE — never append JSON with >>
TMP=$(mktemp .workflow-state.XXXXXX)
jq --arg ts "$(date -Iseconds)" \
  '.current_state = "TERMINATED" | .termination_reason = "cancelled by user" | .terminated_at = $ts' \
  .orca/workflow-state.json > "$TMP" && mv "$TMP" .orca/workflow-state.json

# 3. Close any remaining workflow terminals
orca terminal list --json | jq -r '.result.terminals[].handle' | while read -r H; do
  orca terminal close --terminal "$H" --json 2>/dev/null || true
done
