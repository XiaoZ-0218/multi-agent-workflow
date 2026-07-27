# Changelog

All notable changes to the **multi-agent-workflow** skill are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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