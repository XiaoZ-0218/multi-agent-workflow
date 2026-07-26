# Example: Basic End-to-End Workflow

> Annotated walkthrough of a complete multi-agent workflow run.
> Task: "Add dark mode support to the Settings page of a React app."

---

## Phase 1: Requirements Gathering

**Coordinator analyzes the request:**

```
User: "Add dark mode support to the Settings page"
```

**Gaps detected:** Which React app? What design system? Toggle or system-preference?

```bash
orca orchestration ask \
  --to coordinator \
  --question "I need a few clarifications before planning:\n
1. Is this a specific repo? (provide path or URL)\n
2. Should dark mode respect the OS-level preference (prefers-color-scheme)?\n
3. Do you have a design system (Tailwind, CSS modules, styled-components)?\n
4. Should the toggle be on the Settings page only, or globally in a navbar?" \
  --timeout-ms 0
```

**User responds:** "Repo is `/projects/my-app`. Use Tailwind's `dark:` classes. Respect OS preference by default, but let users override in Settings. Toggle on Settings page."

**Gap analysis:** ✅ All 5 checklist items now clear. Transition to Phase 2.

---

## Phase 2: Plan Generation & Review

### Task Creation

```bash
PLAN_TASK=$(orca orchestration task-create \
  --task-title "Plan: Dark Mode for Settings Page" \
  --display-name "📝 Plan Agent" \
  --spec "Generate a technical plan for adding dark mode to the Settings page of /projects/my-app.

Requirements:
- Use Tailwind CSS dark: prefix classes
- Detect OS preference (prefers-color-scheme) as default
- Add toggle on Settings page for user override
- Persist user preference in localStorage
- Apply to the Settings page and its child components

Output a markdown plan with:
1. Architecture overview
2. Component changes (list each file)
3. Data flow (OS detect → Context → Components)
4. Implementation steps (ordered)
5. Test plan" \
  --json | jq -r '.result.task.id')

orca orchestration dispatch --task "$PLAN_TASK" --to "$PLAN_WORKER" --inject
```

### Review Gate

The Plan Agent produces a plan. Now review it:

```bash
orca orchestration gate-create \
  --task "$PLAN_TASK" \
  --question "Review the dark mode plan against:
1. Does it handle OS preference correctly?
2. Is the localStorage persistence strategy robust?
3. Are all affected components listed?
4. Is the Tailwind dark: class approach consistent?" \
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
- Create a ThemeContext with 'light' | 'dark' | 'system' modes
- Add a <ThemeToggle /> component on Settings page
- Apply dark: classes to Settings, Sidebar, ProfileCard
- Persist to localStorage key 'theme-preference'
- 5 files changed, estimated 2h effort

Approve this plan?" \
  --options "Approve — begin execution,Revise,Abort"
```

**User:** "Approve"

---

## Phase 4: Task Decomposition & Dispatch

### Subtask DAG

```json
[
  {
    "id": "sub-1",
    "title": "Create ThemeContext + Hook",
    "deps": [],
    "complexity": "general",
    "spec": "Create src/contexts/ThemeContext.tsx with Provider, useTheme hook..."
  },
  {
    "id": "sub-2",
    "title": "Add ThemeToggle to Settings",
    "deps": ["sub-1"],
    "complexity": "general",
    "spec": "Create src/components/ThemeToggle.tsx, integrate into Settings page..."
  },
  {
    "id": "sub-3",
    "title": "Apply dark: classes to components",
    "deps": ["sub-1"],
    "complexity": "general",
    "spec": "Add Tailwind dark: variants to Settings, Sidebar, ProfileCard..."
  }
]
```

### Worktree & Dispatch

```bash
orca worktree create --name "feature/dark-mode-20260726" --base main

# All subtasks are "general" complexity → Agent 选择见 docs/agent-routing.md

# Sub-1 dispatched first (no deps)
orca orchestration task-create --task-title "Sub: ThemeContext" --deps '[]' ...
WORKER=$(select_worker "general")
orca orchestration dispatch --task "$SUB1_ID" --to "$WORKER" --inject &

# Sub-2 and Sub-3 dispatched after Sub-1 completes (deps satisfied)
# (Orca orchestration respects deps ordering)
```

---

## Phase 5: Parallel Execution

> Agent 路由见 `docs/agent-routing.md`

**Worker 1** (ThemeContext):
- Attempt 1: Produces ThemeContext.tsx ✅
- Self-review: PASS

**Worker 2** (ThemeToggle):
- Attempt 1: Produces ThemeToggle.tsx, but missing keyboard accessibility
- Self-review: FAIL — "Add aria-label and keyboard handlers"
- Attempt 2: Fixes accessibility ✅
- Self-review: PASS

**Worker 3** (dark: classes):
- Attempt 1: Applies dark: classes correctly ✅
- Self-review: PASS

All three workers report `worker_done`.

---

## Phase 6: Aggregation & Decision

```bash
# Coordinator polls all subtask statuses
TASK_RESULTS=$(orca orchestration task-list --json | jq '[.result.tasks[] | {id, status, result}]')

# Result: All 3 passed
echo "✅ 3/3 subtasks passed. Proceeding to merge."
```

No failed tasks — transition directly to Phase 7.

---

## Phase 7: Merge & PR

### Change Summary

```
## Summary
Added dark mode support to the Settings page with OS-level preference detection.

## Files Changed
 src/contexts/ThemeContext.tsx    | 85 ++++++++++
 src/components/ThemeToggle.tsx   | 62 +++++++
 src/pages/Settings.tsx           | 12 +-
 src/components/Sidebar.tsx       | 24 +--
 src/components/ProfileCard.tsx   | 18 +-
 5 files changed, 178 insertions(+), 23 deletions(-)
```

### Conflict Check

```bash
git fetch origin main
git merge-base --is-ancestor origin/main HEAD && echo "Clean" || echo "Needs rebase"
# Output: Clean
```

### PR Creation

```bash
gh pr create \
  --title "feat: add dark mode support to Settings page" \
  --body "$(cat /tmp/pr_body.md)" \
  --base main \
  --head feature/dark-mode-20260726
```

PR opened: `https://github.com/org/my-app/pull/42`

### PR Lifecycle

- CI passes ✅
- Human reviewer approves ✅
- PR merged ✅

---

## Phase 8: Cleanup

```bash
# Delete remote branch
git push origin --delete feature/dark-mode-20260726

# Remove local worktree
orca worktree remove feature/dark-mode-20260726

# Switch back to main
git checkout main && git pull
```

### Notification

```bash
orca orchestration ask \
  --to coordinator \
  --question "🎉 Dark mode feature complete!

Delivered:
- ThemeContext with OS-detection + localStorage persistence
- ThemeToggle with full keyboard accessibility
- dark: classes on Settings, Sidebar, ProfileCard
- PR #42 merged into main

All artifacts are in the main branch." \
  --timeout-ms 0
```

---

## Metrics for This Run

| Metric | Value |
|--------|-------|
| Total duration | ~35 min |
| Clarification rounds | 1 |
| Plan review rounds | 1 |
| Escalations | 0 |
| Subtask pass rate | 3/3 (100%) |
| Global retries | 0 |
| Delivery mode | full |
| Autofix attempts | 0 |

---

## What If Something Failed?

### Scenario: Subtask 3 fails after 3 retries

In Phase 6, the coordinator would present:

```
⚠️ 1/3 subtasks failed:
- Sub-3 (dark: classes): Tailwind v4 migration broke dark: prefix in ProfileCard

Choose: [Retry failed] [Degrade — deliver 2/3] [Escalate to human] [Abort]
```

If the user chooses **Degrade**, the PR body includes:

```markdown
## ⚠️ PARTIAL DELIVERY
The following item could not be completed:
- **ProfileCard dark mode**: Tailwind v4 migration broke dark: prefix.
  Suggested: manually update to v4 syntax (dark: → dark-mode:)
```

The state file records `delivery_mode: "degraded"` and a parked manifest is written for the failed item.
