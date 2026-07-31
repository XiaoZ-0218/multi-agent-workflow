# Phase 1 — Requirements Gathering

> Extracted from SKILL.md §5 — the full operational procedure for this phase. The coordinator reads this file when entering the phase; SKILL.md keeps only the skeleton.

**Goal**: Ensure the user request contains sufficient information before proceeding.

### 5.1 Entry Condition

- State: `INIT` → `GATHERING`
- Input: Raw user request (natural language)

### 5.2 Process

The coordinator talks to the user through its **own native user-interaction
channel** (the chat surface it was invoked on). It must **never** use
`orca orchestration ask --to coordinator` — that channel is reserved for
**worker → coordinator** messages (see references/api-reference.md §18.1).

```
clarification_round = 0

while clarification_round < MAX_CLARIFICATION_ROUNDS:   # default 5
    gaps = analyze_request(user_input)

    if gaps is empty:
        emit REQUIREMENTS_READY event
        transition to PLANNING
        break

    clarification_round += 1
    response = await ask_user_via_native_channel(
        "Before I proceed, I need to clarify:\n{gaps_formatted}\n\nPlease provide details."
    )
    user_input = merge(user_input, response)

if clarification_round >= MAX_CLARIFICATION_ROUNDS:
    emit REQUIREMENTS_INCOMPLETE event
    transition to TERMINATED
```

### 5.3 Gap Analysis Checklist

Before advancing to Phase 2, confirm the following are present in the request:

- [ ] **Goal**: What is the deliverable? (concrete, not abstract)
- [ ] **Scope**: What is in-scope and explicitly out-of-scope?
- [ ] **Constraints**: Technology, format, deadline, quality bar?
- [ ] **Context**: Any existing codebase, docs, or prior work to reference?
- [ ] **Acceptance Criteria**: How will success be measured?

If ≥ 2 items are missing, pause and clarify.

### 5.4 Output

```json
{
  "phase": "GATHERING",
  "status": "complete",
  "clarified_requirement": "Full requirement text after clarification",
  "clarification_rounds": 2,
  "timestamp": "2026-07-27T10:00:00Z"
}
```

### 5.5 Error Handling

| Error | Severity | Action |
|-------|----------|--------|
| User unresponsive (> 5 min with no reply) | WARN | Retry once with a reminder; if still no response, persist state and exit with `TIMEOUT` |
| User request contradicts itself | WARN | Flag the contradiction explicitly; do not guess |
| Native channel unavailable | FATAL | Log error, persist state, exit |

---
