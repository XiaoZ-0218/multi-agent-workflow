#!/usr/bin/env bash
# check-prerequisites.sh — Pre-flight validation for multi-agent-workflow
# Run before starting any workflow to ensure all dependencies are met.

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

echo "=== Multi-Agent Workflow Prerequisites Check ==="
echo ""

# 1. Orca IDE
echo "--- Orca IDE ---"
if command -v orca &>/dev/null; then
  ORCA_STATUS=$(orca status --json 2>/dev/null || echo '{"ok":false}')
  if echo "$ORCA_STATUS" | jq -e '.ok and .result.app.running' &>/dev/null; then
    pass "Orca is running (PID: $(echo "$ORCA_STATUS" | jq -r '.result.app.pid'))"
  else
    fail "Orca is installed but not running. Start it with: orca open"
  fi
else
  fail "Orca CLI not found. Install from https://orca.app"
fi

# 2. Git
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

# 3. GitHub CLI
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

# 4. jq
echo "--- jq ---"
if command -v jq &>/dev/null; then
  JQ_VERSION=$(jq --version | cut -d- -f2)
  pass "jq $JQ_VERSION"
else
  fail "jq not found. Install with: brew install jq"
fi

# 5. Worker terminals
#    SKILL.md §3.1 marks this as FATAL by default, but solo / dry-run runs are
#    legitimately valid without a worker pool. Set ORCA_WORKFLOW_STRICT_PREREQ=true
#    to enforce the FATAL policy; default is WARN to keep local smoke-tests working.
#
#    v2.1.0: each sub-task gets its own first execution terminal in Phase 4,
#    plus per-round review + fix terminals in Phase 5. A workflow with N
#    sub-tasks and ~2 review rounds each can need up to 3N terminals
#    concurrently. ORCA_WORKFLOW_MIN_WORKERS lets ops/CI assert the lower
#    bound for their expected parallelism (default 1, recommended 3+).
echo "--- Worker Terminals ---"
STRICT_PREREQ="${ORCA_WORKFLOW_STRICT_PREREQ:-false}"
MIN_WORKERS="${ORCA_WORKFLOW_MIN_WORKERS:-1}"
if command -v orca &>/dev/null; then
  WORKER_COUNT=$(orca terminal list --json 2>/dev/null | jq '[.result.terminals[]? | select(.type == "worker" or .tags[]? == "worker")] | length' 2>/dev/null || echo "0")
  if [ "$WORKER_COUNT" -ge "$MIN_WORKERS" ]; then
    pass "$WORKER_COUNT worker terminal(s) available (min requested: $MIN_WORKERS)"
  elif [ "$WORKER_COUNT" -ge 1 ]; then
    if [ "$STRICT_PREREQ" = "true" ]; then
      fail "Only $WORKER_COUNT worker terminal(s) available; need at least $MIN_WORKERS for v2.1.0 sub-task parallelism. Create more: orca terminal create --type worker"
    else
      warn "Only $WORKER_COUNT worker terminal(s); ORCA_WORKFLOW_MIN_WORKERS=$MIN_WORKERS — sub-tasks will run more serially than expected. Create more for full parallelism: orca terminal create --type worker"
    fi
  else
    if [ "$STRICT_PREREQ" = "true" ]; then
      fail "No worker terminals found. Create one: orca terminal create --type worker (set ORCA_WORKFLOW_STRICT_PREREQ=false to allow solo runs)"
    else
      warn "No worker terminals found. Solo/dry-run mode still works. Create one for parallel execution: orca terminal create --type worker"
    fi
  fi
else
  warn "Cannot check worker terminals (Orca not available)"
fi

# 5b. Branch strategy soft check (v2.1.0)
#     stacked mode requires per-sub-task worktrees; serial mode falls back
#     to one worktree at a time. Modern git (>= 2.30) supports multiple
#     worktrees without issue, so this is informational only.
echo "--- Branch Strategy ---"
BRANCH_STRATEGY="${ORCA_WORKFLOW_BRANCH_STRATEGY:-$(jq -r '.workflow.branch_strategy.mode // "stacked"' .orca/workflow-config.json 2>/dev/null || echo "stacked")}"
case "$BRANCH_STRATEGY" in
  stacked|serial) pass "branch_strategy=$BRANCH_STRATEGY" ;;
  *)             fail "Unknown ORCA_WORKFLOW_BRANCH_STRATEGY=$BRANCH_STRATEGY (expected: stacked | serial)" ;;
esac

# 6. Git working directory
echo "--- Working Directory ---"
if git rev-parse --git-dir &>/dev/null; then
  if git diff --quiet && git diff --cached --quiet; then
    pass "Working directory is clean"
  else
    warn "Working directory has uncommitted changes — stash or commit before creating worktrees"
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
