# Phase 8 — Cleanup & Archival

> Extracted from SKILL.md §12 — the full operational procedure for this phase. The coordinator reads this file when entering the phase; SKILL.md keeps only the skeleton.

**Goal**: Reach a clean terminal state for the **feature** (not per subtask):
delete the merged branch + worktree, or preserve them with a parked manifest.
Handle **every** `pr_state` explicitly.

### 12.1 Entry Condition

- State: `CLEANING`
- `pr.state` is terminal: `MERGED` | `CLOSED` | `PARKED` (an `OPEN` PR at
  cleanup is a guard violation — see §12.2)

### 12.2 Process

```bash
PR_STATE=$(jq -r '.pr.state // "null"' "$STATE_FILE")

case "$PR_STATE" in
  MERGED)
    # Full cleanup: delete remote branch, remove the worktree, close terminals
    git push origin --delete "$BRANCH" || echo "WARN: branch delete failed (may need admin)"
    orca worktree rm --worktree "id:$WT_ID" --force --json
    # orca worktree rm removes the worktree; it deletes the local branch only
    # when the branch is fully merged (verified across two v2.2.0 smoke runs:
    # merged PR branch removed by orca, unmerged branch left behind). Delete
    # it explicitly so both cases are covered. Use -D (not -d): a squash- or
    # rebase-merged PR means the local tip is not an ancestor of main, so -d
    # would refuse. Missing branch is fine — orca may already have removed it.
    git branch -D "$BRANCH" 2>/dev/null || echo "INFO: local branch already gone"
    close_all_workflow_terminals      # includes keep_terminal(s)
    state_update '.phases.CLEANING.disposition = "MERGED"'
    ;;

  PARKED|CLOSED)
    # Preserve: write the parked manifest, KEEP worktree + branch, close terminals
    write_parked_manifest             # §12.3
    close_all_workflow_terminals
    state_update '.phases.CLEANING.disposition = "PARKED"'
    ;;

  OPEN|CHANGES_REQUESTED)
    # Guard: cleanup must never run on a live PR
    echo "WARN: pr_state=$PR_STATE at cleanup — refusing destructive actions; treating as PARKED"
    write_parked_manifest
    state_update '.phases.CLEANING.disposition = "PARKED_GUARD"'
    ;;

  *)
    echo "WARN: unexpected pr_state='$PR_STATE'; no destructive actions taken"
    ;;
esac

# ONE history line per workflow — jsonl append (this is NOT the state file)
echo "{\"workflow_id\":\"$WORKFLOW_ID\",\"feature_slug\":\"$FEATURE_SLUG\",\"branch\":\"$BRANCH\",\"pr_url\":\"$PR_URL\",\"pr_state\":\"$PR_STATE\",\"delivery_mode\":\"$DELIVERY_MODE\",\"timestamp\":\"$(date -Iseconds)\"}" \
  >> .orca/workflow-history.jsonl

# Afterwards the coordinator runs ONLY: git fetch origin  (never checkout, never pull --rebase)
git fetch origin
```

### 12.3 Parked Manifest

`.orca/parked/<feature-slug>.md`:

```markdown
# Parked Feature: add-user-prefs

- **Branch**: `feature/add-user-prefs`
- **Worktree path**: `../add-user-prefs`
- **PR**: https://github.com/org/repo/pull/123 (state: CLOSED)
- **Parked at**: 2026-07-27T12:15:00Z
- **Reason**: PR closed without merge
- **Stacked context**: n/a (v2.2.0 uses a single feature branch — no stacks)

## Recovery Steps
1. `cd ../add-user-prefs`
2. `git fetch origin main && git rebase origin/main`
3. Resolve any conflicts, then `git push --force-with-lease origin feature/add-user-prefs`
4. Reopen the PR (or create a new one) and re-run the integration review (§11.4)
5. Resume the workflow at Phase 7

## Subtask Verdicts
- sub-1 (prefs-api): PASS, 1 review round
- sub-2 (prefs-ui): PASS, 0 review rounds
```

### 12.4 Atomic State Writes

**Every** update to `.orca/workflow-state.json` goes through jq with an atomic
tmp-file + `mv`. Never append JSON with `>>` (the `.jsonl` history file above
is the only exception — it is line-delimited, not a JSON document):

```bash
state_update() {   # usage: state_update '<jq filter>'
  local tmp; tmp=$(mktemp .workflow-state.XXXXXX)
  jq "$1" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}
```

### 12.5 User Notification

```bash
# Via the coordinator's NATIVE channel:
echo "🎉 Workflow complete — $DELIVERY_REPORT"
# MERGED: PR url + summary of what shipped
# PARKED: pointer to .orca/parked/<feature-slug>.md with recovery steps
```

### 12.6 Output

```json
{
  "phase": "CLEANING",
  "status": "complete",
  "disposition": "MERGED",
  "branch_deleted": true,
  "worktree_removed": true,
  "parked_manifest": null,
  "timestamp": "2026-07-27T12:15:00Z"
}
```

---
