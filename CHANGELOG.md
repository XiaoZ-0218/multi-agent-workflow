# Changelog

All notable changes to the **multi-agent-workflow** skill are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.2.1] — 2026-07-27

### Changed
- **Plan agent routing**: plan generation (Phase 2) now routes to
  **claude code** (preferred) with **pi** as fallback, replacing the Orca
  built-in `Plan` agent. `ORCA_WORKFLOW_PLAN_AGENT` and the cold-start
  `routing.plan_agent_type` default change `Plan` → `claude`. When the
  fallback (pi) is in effect, the plan review for that round must switch
  off pi (use claude code or grok) to preserve the cross-agent
  "reviewer ≠ implementer" rule. Single source of truth:
  `docs/agent-routing.md` §6.

## [2.2.0] — 2026-07-27

### Changed (BREAKING)
- **One worktree per feature**: the v2.1.0 per-sub-task worktrees are
  gone. A run now creates exactly one `feature/<slug>` branch + worktree
  based on `origin/main`; all sub-tasks execute inside it and integrate
  as **one PR** at the end. The coordinator stays on the main branch for
  the entire run — it never runs `git checkout`, and its only git ops in
  its own checkout are `git fetch origin` (optionally
  `git pull --ff-only`).
- **Stacked branches, draft PRs, and per-sub-task PRs removed**: the
  §11.8 stacked-PR rebase hook, the `branch_strategy` block, and the
  branch/worktree-path templates are all deleted. Dependencies now mean
  **wave-based serial dispatch**: a sub-task is dispatched only after
  every parent has verdict=PASS, and it sees the parents' committed
  code naturally in the shared worktree.
- **Degraded delivery is now surgical**: the coordinator reverts each
  failed sub-task's commit range in the feature worktree (clean because
  `owns` are disjoint); if the revert is unclean, the whole feature is
  parked instead of shipping partial work.
- **Parked manifest renamed**: one `.orca/parked/<feature-slug>.md` per
  parked feature (was one per sub-task), recording branch, worktree
  path, PR url, reason, and recovery steps.
- **State-file top level reshaped**: new `feature_slug`, `worktree{}`,
  `pr{}`, and `integration_review{}` blocks; the v2.1.0 legacy aggregate
  `branch` / `pr_url` fields are dropped. `current_phase` /
  `current_state` enums now include `INIT`, and `pr.state` no longer
  has a `DRAFT` value.
- **Scope-reduction option removed**: the v2.0.1 Phase 3 "reduce scope"
  path allowed parallel writes into the coordinator's main checkout and
  is unsafe. Users reduce scope via Revise instead.

### Added
- **`owns` field on every sub-task** (file/dir ownership globs).
  Parallel-write safety comes from disjoint ownership rather than
  filesystem isolation; plan review now validates that every sub-task
  declares `owns` and that same-wave sub-tasks are disjoint.
- **Per-dispatch `base_sha` + scoped review**: the coordinator records
  the feature-branch HEAD at each dispatch, and the cross-review agent
  reviews only the `<base_sha>..HEAD` changes within the sub-task's
  `owns`.
- **Integration review phase** (Phase 7): a fresh review agent audits
  the whole feature — plan, per-sub-task verdicts, test results, and
  `git diff origin/main...HEAD` — before the PR is created. Bounded by
  the new `ORCA_WORKFLOW_MAX_INTEGRATION_REVIEW` (default 2).
- **Pre-flight check for the coordinator checkout**:
  `scripts/check-prerequisites.sh` now verifies `orca worktree current`
  so a run never starts from a checkout Orca does not manage.

### Fixed
- **CLI surface corrected everywhere** to the real Orca commands:
  `worktree create --base-branch` (no positional path arg, no `--base`),
  `worktree rm` ("worktree remove" does not exist),
  `terminal close --terminal` (no `--handle`), no `--tags` on
  `terminal create` (agent identity is carried by the title prefix and
  the coordinator's state record), `dispatch` has no `--spec` (new
  instructions require a NEW task), and blocking waits use
  `check --wait` in a rolling loop.
- **Phase 3 Abort off-by-one**: Abort now terminates immediately at any
  confirmation round instead of surviving one extra round.
- **Phase 6 retry off-by-one**: the global retry budget is checked
  before incrementing, so `ORCA_WORKFLOW_MAX_GLOBAL_RETRY=2` allows at
  most 2 retries (not 3).
- **PR-monitor gate spam**: the merge monitor now polls
  `gh pr view --json state,mergeStateStatus` every 60s and never calls
  `gate-create` inside the poll loop.
- **Autofix success-verification inversion**: a rebase autofix now
  counts as SUCCESS only when the rebase actually completed AND zero
  `^UU` conflict markers remain (previously the check was inverted,
  letting conflicted trees through).
- **Cancel runbook corrupting the state file**: all state-file updates
  now use jq atomic writes (write tmp file, then `mv`); JSON is never
  appended with `>>`.
- **Phase 8 no longer checks out main**: cleanup runs from the
  coordinator's own checkout; the only git op afterwards is
  `git fetch origin`.
- **Security section** no longer claims git-worktree filesystem
  sandboxing — sub-tasks share one worktree, so that claim was false.
- **Phase 8 now deletes the local feature branch**: verified across two
  v2.2.0 smoke runs that `orca worktree rm --force` removes the worktree
  and deletes the local branch only when it is fully merged — an
  unmerged branch is left behind. Cleanup now runs
  `git branch -D <branch>` from the coordinator's checkout to cover both
  cases (`-D`, not `-d`, because a squash-merged PR's local tip is not
  an ancestor of main; "not found" means orca already removed it).
- **`worker_done` verdict placement**: the preamble contract (§8.5) now
  requires the verdict in BOTH the message subject and the payload —
  smoke-run finding: some agents only write the subject. The
  coordinator reads `payload.verdict` first and falls back to the
  subject prefix.
  Write safety is the `owns` contract plus the review gates.

## [2.1.0] — 2026-07-27

### Changed (BREAKING for state-file consumers — additive at the schema level)
- **Per-sub-task worktrees**: Phase 4 creates one `feature/<wf>/<sub>-<ts>`
  branch + worktree per sub-task. The single shared worktree that v2.0.x
  produced for the whole workflow is gone. State schema gains
  `tasks.subtasks[*].worktree_path` / `branch_name` / `base_branch`.
- **Stacked branches for dependencies**: under `branch_strategy.mode =
  "stacked"` (default), a sub-task with deps bases off its parent's branch
  instead of `main`. Phase 7's new **§11.8 Stacked-PR Rebase Hook**
  rebase-flips dependent PRs onto `main` and promotes them from draft once
  the parent merges (`gh pr edit --base main` + `gh pr ready`).
- **Per-sub-task PRs**: Phase 7 now creates one PR per sub-task in
  topological order. No more single bundle PR. Each sub-task gets its
  own gate-create lifecycle monitor.
- **Per-round fresh terminal (cross-agent review)**: Phase 5's review loop
  spawns a **fresh `orca terminal create`** for every round. Round 0's
  execution terminal is reused from Phase 4; every subsequent round
  (fix + review) gets a brand-new terminal. Review terminals are torn
  down after each verdict; the newest execution terminal becomes the
  sub-task's `keep_terminal` and survives until Phase 8. Review Agent is
  distinct from implementation Agent (default: `pi` reviews, `claude`
  implements — see `docs/agent-routing.md`).
- **Per-sub-task cleanup**: Phase 8 runs in **reverse topological order**.
  Each sub-task gets its own case dispatch on `pr_state`: merged →
  delete branch + remove worktree + close `keep_terminal`; parked →
  write `.orca/parked/<sub>.md`; skipped/fail → drop everything. Each
  sub-task appends its own line to `.orca/workflow-history.jsonl`.
- **Per-sub-task parked manifest** (was one bundle manifest): parked
  sub-tasks get `.orca/parked/<sub>.md` listing deps, stacked-chain
  rebase target hint, and explicit "rerun Phase 7 for this sub-task
  only" recovery steps.

### Added
- `workflow.branch_strategy` config block (mode, branch_template,
  worktree_path_template, draft_pr_when_stacked, rebase_on_parent_merge,
  flip_pr_base_on_parent_merge).
- `workflow.terminals` config block (spawn_per_role, role names,
  close_intermediate_terminals, max_terminals_per_subtask).
- `workflow.merge.per_subtask_pr` flag.
- New env vars: `ORCA_WORKFLOW_BRANCH_STRATEGY`,
  `ORCA_WORKFLOW_BRANCH_TEMPLATE`, `ORCA_WORKFLOW_WORKTREE_PATH_TEMPLATE`,
  `ORCA_WORKFLOW_MAX_TERMINALS_PER_SUBTASK`,
  `ORCA_WORKFLOW_MIN_WORKERS`.
- State-schema fields per sub-task: `worktree_path`, `branch_name`,
  `base_branch`, `terminals[]` (with handle / role / round / agent_type /
  status / verdict / timestamps), `keep_terminal`, `pr_url`, `pr_base`,
  `pr_state`, `merged_at`, `review_rounds`. Plus `subtask_id` on
  `errors[]` and `decisions[]` for scoped events.
- `§11.8 Stacked-PR Rebase Hook` — fires after each sub-task transitions
  to `MERGED`, rebases dependents onto `main`, flips PR base, promotes
  drafts.
- New `examples/basic-workflow.md` walkthrough demonstrating two stacked
  sub-tasks (`prefs-api` + `prefs-ui`) end-to-end.
- `.gitignore` covering `.orca/workflow-state.json` and `.orca/parked/`.

### Fixed
- **README version badge drift** (`v2.0.0` → `v2.1.0`).
- **§15 Security wording**: previously said "within their worktree" as
  if there were one worktree; now correctly enumerates per-sub-task
  isolation, the read-only reviewer convention, and the §11.8 hook
  capabilities.
- **§18 API Reference** now includes `orca terminal create` / `close`
  rows and per-sub-task cardinality notes on every `orca worktree` /
  `gh pr` row.
- **`scripts/check-prerequisites.sh`**: honors `ORCA_WORKFLOW_MIN_WORKERS`
  (default 1) so CI can assert minimum terminal pool size for v2.1.0's
  higher concurrency; adds a soft check for `branch_strategy` validity.

### Migration notes (v2.0.x → v2.1.0)
- State files written by v2.0.x still parse — new fields are optional.
  Top-level `branch` / `pr_url` are kept as aggregates of the root
  sub-task for dashboard compat.
- Operators upgrading must ensure enough worker terminals:
  `orca terminal create --type worker` to raise `WORKER_COUNT` to
  `ORCA_WORKFLOW_MIN_WORKERS` (recommended 3+).
- Existing single-worktree runs are **not** auto-rewritten; the v2.1.0
  workflow always creates per-sub-task worktrees.

## [2.0.1] — 2026-07-26

### Fixed
- **Documentation drift**: `orca orchestration run --skill multi-agent-workflow` (incorrect) replaced
  with `orca orchestration run --spec /path/to/spec.md` across SKILL.md (§16.3, §17.1, §18.1, footer),
  README.md (Quick Start), and examples/basic-workflow.md.
- **Pre-flight policy drift**: `scripts/check-prerequisites.sh` previously emitted WARN for missing
  worker terminals while SKILL.md §3.1 marked the same condition FATAL. Introduced
  `ORCA_WORKFLOW_STRICT_PREREQ` (default `true` → FATAL; set `false` for solo/dry-run) so both
  surfaces agree and solo mode stays runnable.
- **§8.3 dispatch race**: parallel dispatch loop now records failures instead of swallowing them.
- **§3.3 environment variables**: added complete `ORCA_WORKFLOW_*_AGENT` list (was previously only
  documented in `docs/agent-routing.md`, never in SKILL.md) plus `ORCA_WORKFLOW_STRICT_PREREQ` and
  `ORCA_WORKFLOW_DRY_RUN`.
- **§4.1 routing duplication**: routing keys are now explicitly noted as cold-start defaults; the
  authoritative source remains `docs/agent-routing.md`.

### Added
- **§7.2 scope-reduction contract**: Phase 3 now offers an explicit "Reduce scope — keep partial
  work only (no PR / no worktree)" option. New `§7.2.1 Scope-Reduction Contract` table documents
  the per-phase skip rules and distinguishes this from the §10.4 Degraded Delivery path
  (which is failure-driven, not user-declared).
- **MIT LICENSE** file (was referenced in README but missing).
- **CHANGELOG.md** (this file).
- **Project structure** diagram in README now reflects the full file layout (CHANGELOG, LICENSE,
  docs/agent-routing.md).

## [2.0.0] — 2026-07-26

### Added
- Initial production release of the 8-phase multi-agent orchestration workflow.
- Plan generation & review (max 3 rounds + 2 escalations).
- User confirmation with explicit `Approve / Revise / Abort` semantics.
- Parallel dispatch with per-subtask self-review (max 3 retries).
- Aggregation & decision (retry / degrade / escalate).
- PR-only merge path with conflict autofix (max 2 attempts).
- Cleanup & archival with parked-workflow recovery manifests.
- `.orca/workflow-state.json` audit trail with full schema.
- `docs/agent-routing.md` as single source of truth for agent routing preferences.
- Smoke test (`docs/smoke-test.md`) demonstrating degraded-delivery path.

### Known limitations (carried into 2.0.1)
- Command-flag typo `--skill multi-agent-workflow` (fixed in 2.0.1).
- Pre-flight policy drift between script and SKILL.md (fixed in 2.0.1).
- Phase 3 lacked an explicit user-declared scope-reduction path (fixed in 2.0.1).