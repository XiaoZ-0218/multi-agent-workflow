# Phase 3 — User Confirmation

> Extracted from SKILL.md §7 — the full operational procedure for this phase. The coordinator reads this file when entering the phase; SKILL.md keeps only the skeleton.

**Goal**: Present the reviewed plan to the user for final sign-off before any
worktree or terminal is created.

### 7.1 Entry Condition

- State: `CONFIRMING`
- Input: Approved plan (text) from Phase 2

### 7.2 Process

Three options only — **Approve / Revise / Abort** — asked via the coordinator's
native channel:

```
confirm_round = 0

while confirm_round < MAX_USER_CONFIRM:          # default 3
    response = await ask_user_via_native_channel(
        "✅ The technical plan has passed internal review.\n\n"
        f"Summary:\n{plan_summary}\n\n"
        "Do you approve this plan?",
        options=["Approve — begin execution",
                 "Revise — provide feedback",
                 "Abort — cancel the task"])

    if response == "Approve":
        transition to DISPATCHING; break
    if response == "Abort":
        transition to TERMINATED (Terminate2)     # IMMEDIATE — at ANY round,
        break                                     # including the first

    # response == "Revise"
    confirm_round += 1
    if confirm_round < MAX_USER_CONFIRM:
        transition to PLANNING (with user_feedback)   # review counter resets
    else:
        force = await ask_user_via_native_channel(
            f"Plan has been revised {confirm_round} times without approval.\n"
            "Choose: continue revising, or terminate.",
            options=["Continue revising", "Terminate"])
        if force == "Continue revising":
            confirm_round = 0
            transition to PLANNING
        else:
            transition to TERMINATED (Terminate2)
```

**Abort is immediate at any round** — including round 0. v2.1.0 waited for the
round counter before honouring Abort (an off-by-one); v2.2.0 terminates as soon
as the user says so.

#### 7.2.1 Removed option: scope reduction

v2.0.1 offered a fourth option, "Reduce scope — work in-place without a
worktree or PR". It is **removed in v2.2.0**: in-place execution means parallel
subtask workers write into the **coordinator's own main checkout**, which is
unsafe (the coordinator must stay on a clean `main`, and `owns`-based
verification assumes all writes land in the feature worktree). Users who want a
smaller change should choose **Revise** and narrow the plan instead.

### 7.3 Output

```json
{
  "phase": "CONFIRMING",
  "status": "complete",
  "confirm_rounds": 1,
  "user_decision": "APPROVE",
  "timestamp": "2026-07-27T10:20:00Z"
}
```

---

