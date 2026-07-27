#!/usr/bin/env bash
# check-prerequisites.sh — Pre-flight validation for multi-agent-workflow v2.2.0
# Run before starting any workflow to ensure all dependencies are met.
#
# v2.2.0 notes:
# - The coordinator ("主 Agent") runs the entire workflow on the main branch in
#   its own checkout and never runs `git checkout`; all feature work happens in
#   ONE shared git worktree + ONE feature branch + ONE PR.
# - The v2.1.0 worker-terminal count check (ORCA_WORKFLOW_MIN_WORKERS) and the
#   branch-strategy soft check (ORCA_WORKFLOW_BRANCH_STRATEGY) are REMOVED:
#   terminal objects have no type/tags fields, and per-subtask worktrees /
#   stacked branches no longer exist.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
WARN=0
FAIL=0

pass() { echo -e "${GREEN}✅ PASS${NC}: $1"; PASS=$((PASS + 1)); }
warn() { echo -e "${YELLOW}⚠️  WARN${NC}: $1"; WARN=$((WARN + 1)); }
fail() { echo -e "${RED}❌ FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

STRICT_PREREQ="${ORCA_WORKFLOW_STRICT_PREREQ:-false}"

echo "=== Multi-Agent Workflow Prerequisites Check (v2.2.0) ==="
echo ""

# 1. Orca IDE
echo "--- Orca IDE ---"
if command -v orca &>/dev/null; then
  ORCA_STATUS=$(orca status --json 2>/dev/null || echo '{"ok":false}')
  if echo "$ORCA_STATUS" | jq -e '.ok and .result.app.running and .result.runtime.reachable' &>/dev/null; then
    pass "Orca is running and runtime is reachable (PID: $(echo "$ORCA_STATUS" | jq -r '.result.app.pid'))"
  else
    fail "Orca is installed but not fully up (need .ok, app.running and runtime.reachable). Start it with: orca open"
  fi
else
  fail "Orca CLI not found. Install from https://orca.app"
fi

# 2. Orca-managed checkout + current branch
#    v2.2.0: the coordinator runs the whole workflow from its own checkout on
#    the main branch (it never runs `git checkout`), so it MUST be inside an
#    Orca-managed checkout. `orca worktree current --json` fails otherwise.
echo "--- Coordinator Checkout ---"
if command -v orca &>/dev/null; then
  CURRENT_WT=$(orca worktree current --json 2>/dev/null || echo '{"ok":false}')
  if echo "$CURRENT_WT" | jq -e '.ok and .result.worktree.id' &>/dev/null; then
    pass "Running inside an Orca-managed checkout (worktree id: $(echo "$CURRENT_WT" | jq -r '.result.worktree.id'))"
  elif [ "$STRICT_PREREQ" = "true" ]; then
    fail "Not inside an Orca-managed checkout — the v2.2.0 coordinator must run in one (set ORCA_WORKFLOW_STRICT_PREREQ=false to downgrade to a warning)"
  else
    warn "Not inside an Orca-managed checkout — worktree creation in Phase 4 (DISPATCHING) will be unavailable"
  fi
else
  warn "Cannot check the current worktree (Orca CLI not available)"
fi
if git rev-parse --git-dir &>/dev/null; then
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [ "$CURRENT_BRANCH" = "main" ]; then
    pass "Current branch is main — the coordinator stays on main for the entire run"
  else
    warn "Current branch is '$CURRENT_BRANCH', not main — the v2.2.0 coordinator should stay on main (feature work happens in the shared feature worktree)"
  fi
fi

# 3. Git
echo "--- Git ---"
if command -v git &>/dev/null; then
  GIT_VERSION=$(git --version | awk '{print $3}')
  if printf '%s\n' "2.30" "$GIT_VERSION" | sort -V -C 2>/dev/null; then
    pass "Git $GIT_VERSION (≥ 2.30 required)"
  else
    fail "Git $GIT_VERSION is too old (≥ 2.30 required)"
  fi
else
  fail "Git not found. Install with: brew install git"
fi

# 4. GitHub CLI
echo "--- GitHub CLI ---"
if command -v gh &>/dev/null; then
  GH_VERSION=$(gh --version | head -1 | awk '{print $3}')
  if printf '%s\n' "2.0" "$GH_VERSION" | sort -V -C 2>/dev/null; then
    if gh auth status &>/dev/null; then
      pass "GitHub CLI $GH_VERSION (authenticated)"
    else
      warn "GitHub CLI $GH_VERSION installed but not authenticated. Run: gh auth login"
    fi
  else
    fail "GitHub CLI $GH_VERSION is too old (≥ 2.0 required)"
  fi
else
  fail "GitHub CLI not found. Install with: brew install gh"
fi

# 5. jq
echo "--- jq ---"
if command -v jq &>/dev/null; then
  JQ_VERSION=$(jq --version | cut -d- -f2)
  pass "jq $JQ_VERSION"
else
  fail "jq not found. Install with: brew install jq"
fi

# 6. Worker terminals (informational only in v2.2.0)
#    v2.1.0 counted pre-existing worker terminals (ORCA_WORKFLOW_MIN_WORKERS),
#    but terminal objects have no type/tags fields, so no such count exists.
#    The coordinator spawns a FRESH terminal for every execution / review /
#    fix / fallback / autofix / pr-fix / integration-review round itself, so
#    no pre-created worker pool is required.
echo "--- Worker Terminals ---"
echo -e "ℹ️  INFO: no worker pool needed — the v2.2.0 coordinator creates fresh terminals per round itself (orca terminal create --worktree id:<id> --title \"[<role>:<agent>] ...\")"

# 7. Git working directory
echo "--- Working Directory ---"
if git rev-parse --git-dir &>/dev/null; then
  if git diff --quiet && git diff --cached --quiet; then
    pass "Working directory is clean"
  else
    warn "Working directory has uncommitted changes — stash or commit before the coordinator starts the run"
  fi
else
  warn "Not in a git repository — worktree creation will be unavailable"
fi

echo ""
echo "=== Summary ==="
echo -e "${GREEN}Passed: $PASS${NC}"
echo -e "${YELLOW}Warnings: $WARN${NC}"
echo -e "${RED}Failed: $FAIL${NC}"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "❌ Fix the failures above before starting a workflow."
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo ""
  echo "⚠️  Warnings present. The workflow may still run, but some features will be limited."
  exit 0
else
  echo ""
  echo "✅ All checks passed. Ready to start a workflow."
  exit 0
fi
