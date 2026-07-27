# Changelog

All notable changes to the **multi-agent-workflow** skill are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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