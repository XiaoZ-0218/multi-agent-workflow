# Workflow State Diagram

> Full Mermaid flowchart for the Multi-Agent Orchestration Workflow **v2.1.0**.
> Rendering: paste this into any Mermaid-compatible viewer (GitHub, Mermaid Live, Obsidian).
>
> v2.1.0 key change: each sub-task owns its own worktree + branch + set of fresh
> terminals. Dependent sub-tasks are **stacked** on their parent's branch until
> the parent PR merges — at which point the §11.8 rebase hook flips the
> dependent PR's base to `main`.

```mermaid
graph TD
    Start([User Request]) --> Meet[Phase 1: Requirements Gathering<br/>Coordinator analyzes request]
    Meet --> Q1{Is the request<br/>sufficiently clear?}
    Q1 -->|No| Ask[Ask clarifying questions<br/>orca orchestration ask]
    Ask --> Meet
    Q1 -->|Yes| DocGen[Phase 2: Plan Generation<br/>task-create + dispatch]

    subgraph PlanLoop ["Phase 2: Plan Review Loop (max 3 review rounds + 2 escalations)"]
        DocGen --> Review[Review Agent<br/>gate-create]
        Review --> Q2{Review passed?<br/>Round ≤ MAX_REVIEW_ROUNDS}
        Q2 -->|No, retries remain| Fix[Revise plan<br/>with review feedback]
        Fix --> Review
        Q2 -->|Retries exhausted| Escalate[Escalate to Human<br/>orca orchestration ask]
        Escalate --> EscCnt{Escalation count?}
        EscCnt -->|≤ MAX_ESCALATE| DocGen
        EscCnt -->|> MAX_ESCALATE| Terminate1["❌ TERMINATED<br/>Plan cannot converge"]
    end

    Q2 -->|Yes| Confirm[Phase 3: User Confirmation<br/>Present plan summary]
    Confirm --> Q3{User approves?<br/>Round ≤ MAX_USER_CONFIRM}
    Q3 -->|No, retries remain| Feedback[Collect user feedback]
    Feedback --> DocGen
    Q3 -->|Retries exhausted| ForceChoice{Force decision}
    ForceChoice -->|Continue revising| DocGen
    ForceChoice -->|Terminate| Terminate2["❌ TERMINATED<br/>Directional misalignment"]
    Q3 -->|Yes| Plan[Phase 4: Task Decomposition<br/>Generate sub-task DAG]

    Plan --> DispatchLoop{For each sub-task<br/>in topo order}
    DispatchLoop -->|sub-N| CreateWT[Phase 4: Create worktree + branch<br/>base = main or parent branch<br/>orca worktree create]
    CreateWT --> SpawnFirst[Phase 4: Spawn FRESH execution terminal<br/>tagged with sub-task's complexity Agent<br/>orca terminal create]
    SpawnFirst --> Dispatch[Phase 4: Dispatch implementation spec<br/>orca orchestration dispatch]
    SpawnFirst -.record.-> State1[(state.tasks.subtasks sub-N<br/>worktree_path, branch_name,<br/>keep_terminal, base_branch)]

    subgraph SubA ["Sub-task A (deps-less): branch base = main"]
        Dispatch --> SubA_Impl[Sub-A Round 0: Implementation<br/>execution terminal]
        SubA_Impl --> SubA_Review[Sub-A Round 0: Cross-Review<br/>FRESH review terminal<br/>tagged review Agent]
        SubA_Review --> SubA_Q{Pass?}
        SubA_Q -->|Yes| SubA_Done["✅ Sub-A complete"]
        SubA_Q -->|No| SubA_Fix[Sub-A Round 1: Fix<br/>FRESH execution terminal<br/>tagged execution Agent]
        SubA_Fix --> SubA_Review2[Sub-A Round 1: Re-Review<br/>FRESH review terminal]
        SubA_Review2 --> SubA_Q2{Pass?}
        SubA_Q2 -->|Yes| SubA_Done
        SubA_Q2 -->|No, budget left| SubA_Fix
        SubA_Q2 -->|No, budget gone| SubA_Fail["❌ Sub-A FAIL"]
    end

    subgraph SubB ["Sub-task B (deps on A): branch base = Sub-A's branch (stacked)"]
        SpawnFirstB[Phase 4: Sub-B wt+branch based on A<br/>FRESH execution terminal]
        DispatchB[Phase 4: Dispatch sub-B spec]
        SpawnFirstB --> DispatchB
        SpawnFirstB -.record.-> State2[(state.tasks.subtasks sub-B<br/>worktree_path, branch_name,<br/>base_branch = A's branch)]

        DispatchB --> SubB_Impl[Sub-B Round 0: Implementation<br/>in sub-B worktree]
        SubB_Impl --> SubB_Review[Sub-B Round 0: Cross-Review<br/>FRESH review terminal]
        SubB_Review --> SubB_Q{Pass?}
        SubB_Q -->|Yes| SubB_Done["✅ Sub-B complete (waiting for A to merge)"]
        SubB_Q -->|No| SubB_Fix[Sub-B Round 1: Fix<br/>FRESH execution terminal]
        SubB_Fix --> SubB_Review2[Sub-B Round 1: Re-Review<br/>FRESH review terminal]
        SubB_Review2 --> SubB_Q2{Pass?}
        SubB_Q2 -->|Yes| SubB_Done
        SubB_Q2 -->|No, budget left| SubB_Fix
        SubB_Q2 -->|No, budget gone| SubB_Fail["❌ Sub-B FAIL"]
    end

    SubA_Done --> Collect[Phase 6: Collect All Sub-task Verdicts]
    SubB_Done --> Collect
    SubA_Fail --> Collect
    SubB_Fail --> Collect

    Collect --> Analyze[Phase 6: Analyze Results]
    Analyze --> AllOK{All sub-tasks<br/>passed?}
    AllOK -->|Yes| TopoMerge[Phase 7: Per-sub-task PR<br/>in topological order]
    AllOK -->|No| RetryDecision{Retry strategy?<br/>Global retries ≤ MAX_GLOBAL_RETRY}
    RetryDecision -->|Retry failed, retries remain| DispatchLoop
    RetryDecision -->|Degrade delivery| PartialOK[Mark: partial delivery<br/>Passed sub-tasks ship<br/>Failed sub-tasks flagged]
    RetryDecision -->|Retries exhausted, escalate| EscalateSub[Escalate to Human<br/>orca orchestration ask]
    EscalateSub --> HumanSubDecision{Human decision}
    HumanSubDecision -->|Provide direction| DispatchLoop
    HumanSubDecision -->|Accept partial delivery| PartialOK
    HumanSubDecision -->|Abort| Terminate3["❌ TERMINATED<br/>Sub-task(s) cannot<br/>be completed"]
    PartialOK --> TopoMerge

    TopoMerge --> SubAPR[Phase 7: Sub-A<br/>rebase onto main<br/>push, gh pr create<br/>base = main]
    SubAPR --> SubAPoll{Sub-A PR status?}
    SubAPoll -->|Changes requested| SubAFix[Sub-A PR-fix<br/>FRESH execution terminal<br/>commit + push]
    SubAFix --> SubAPoll
    SubAPoll -->|Merged| SubAOnMerge[/§11.8 Stacked-PR Hook:<br/>for each dependent of A: rebase<br/>onto main, gh pr edit --base main,<br/>gh pr ready/]

    SubAOnMerge --> SubBPR[Phase 7: Sub-B (was draft)<br/>now: rebase onto main<br/>gh pr edit --base main<br/>gh pr ready]
    SubBPR --> SubBPoll{Sub-B PR status?}
    SubBPoll -->|Changes requested| SubBFix[Sub-B PR-fix<br/>FRESH execution terminal]
    SubBFix --> SubBPoll
    SubBPoll -->|Merged| SubBDone["✅ Sub-B complete"]
    SubBPoll -->|Closed| SubBPark["🅿️ Sub-B PARKED<br/>per-sub-task manifest written"]
    SubAPoll -->|Closed| SubAPark["🅿️ Sub-A PARKED<br/>per-sub-task manifest written"]

    SubADone[Sub-A merged]
    SubADone --> CleanupLoop
    SubBDone --> CleanupLoop
    SubAPark --> CleanupLoop
    SubBPark --> CleanupLoop

    CleanupLoop{For each sub-task<br/>in REVERSE-topo order}
    CleanupLoop -->|merged| CleanMerge[Phase 8: delete remote branch<br/>+ orca worktree remove<br/>+ orca terminal close keep_terminal]
    CleanupLoop -->|parked| CleanPark[Phase 8: write .orca/parked/&lt;sub&gt;.md<br/>+ orca terminal close keep_terminal]
    CleanupLoop -->|skipped/fail| CleanDrop[Phase 8: delete branch + worktree<br/>+ orca terminal close]

    CleanMerge --> Final[Phase 8: Archive<br/>Append per-sub-task history line<br/>to .orca/workflow-history.jsonl]
    CleanPark --> Final
    CleanDrop --> Final
    Final --> Notify[Notify User<br/>orca orchestration ask]
    Notify --> End([Done])
```

## State Transition Table

| From | Trigger | To | Guard |
|------|---------|----|-------|
| `INIT` | User request received | `GATHERING` | — |
| `GATHERING` | Requirements clear | `PLANNING` | Q1 = yes |
| `GATHERING` | Max clarifications | `TERMINATED` | > 5 rounds |
| `PLANNING` | Review passed | `CONFIRMING` | Q2 = yes |
| `PLANNING` | Rounds exhausted + escalate ≤ 2 | `PLANNING` | Escalate → retry |
| `PLANNING` | Escalate > 2 | `TERMINATED` | Terminate1 |
| `CONFIRMING` | User approves | `DISPATCHING` | — |
| `CONFIRMING` | User rejects (< 3) | `PLANNING` | With feedback |
| `CONFIRMING` | User rejects (≥ 3) | `TERMINATED` | Terminate2 |
| `DISPATCHING` | All sub-tasks have wt+branch+first terminal | `EXECUTING` | — |
| `DISPATCHING.sub-N` | Worktree/branch/terminal creation failed | `TERMINATED` | Infra-only failure; per-sub-task failures don't terminate |
| `EXECUTING.sub-N` | Cross-review PASS | `EXECUTING` (waiting on siblings) | All sub-tasks must reach terminal verdict to advance |
| `EXECUTING.sub-N` | Round budget exhausted | `EXECUTING.sub-N` (FAIL) | Siblings continue |
| `EXECUTING` | All sub-tasks terminal | `DECIDING` | — |
| `DECIDING` | All passed | `MERGING` | AllOK = yes |
| `DECIDING` | Retry (< 2) | `DISPATCHING` | Failed sub-tasks only — get new wt+branch |
| `DECIDING` | Degrade | `MERGING` | PartialOK set; passed sub-tasks continue to PR |
| `DECIDING` | Human aborts | `TERMINATED` | Terminate3 |
| `MERGING.sub-N` | Parent merged → rebase + flip base | `MERGING.sub-N` (rebase) | Only if sub-task has deps (§11.8 hook) |
| `MERGING.sub-N` | PR merged | `MERGING` (waiting on siblings) | — |
| `MERGING.sub-N` | Auto-fix exhausted + human parks | `MERGING.sub-N` (PARKED) | Per-sub-task parking; siblings continue |
| `MERGING` | All merged or parked | `CLEANING` | — |
| `CLEANING.sub-N` | Branch deleted + worktree removed + keep_terminal closed | `CLEANING` (next sibling) | Reverse-topo order |
| `CLEANING` | All sub-tasks cleaned | `DONE` | — |

## Termination Exits

| Exit | Trigger Condition | Per-Sub-Task State |
|------|------------------|-------------------|
| **Terminate1** | Plan cannot pass review after 2 human escalations | No sub-tasks started — plan was never approved |
| **Terminate2** | User rejects plan > 3 times | No sub-tasks started — user disagreed with direction |
| **Terminate3** | Sub-tasks fail after global retry + human abort | Completed sub-tasks preserved in their own worktrees; failed sub-tasks have per-sub-task park manifests |
| **Per-sub-task PARKED** | Auto-fix exhausted on one sub-task | Siblings continue; that sub-task gets `.orca/parked/<sub>.md` |
| **Workflow DONE** | All sub-tasks merged (or parked) | Each merged sub-task's branch deleted, worktree removed, keep_terminal closed |