# Workflow 状态图

> 多智能体编排 Workflow **v2.2.0** 的完整 Mermaid 流程图。
> 渲染方式：粘贴到任意支持 Mermaid 的查看器（GitHub、Mermaid Live、Obsidian）。
> 本文档全文（含图内节点标签）为简体中文；状态机枚举值等技术标识保持英文。
>
> v2.2.0 关键变更：**每个 feature 一个 worktree**。协调者全程停留在
> main 分支（绝不 `git checkout`）；所有子任务都在同一个共享的 feature
> worktree 中执行，基于 `origin/main` 的同一个 `feature/<slug>` 分支上，
> 整个 feature 以**一个** PR 交付。并行安全来自每个子任务声明的 `owns`
> 文件所有权 glob —— 同一波次的子任务 `owns` 必须互不相交，在计划审查阶段
> 校验 —— 分发按 DAG **波次**进行：有依赖的子任务只有在其**全部**父任务
> 达到 verdict=PASS 后才启动，并能在共享 worktree 中自然看到父任务已提交
> 的代码。创建 PR 之前，由一个专门的**合并前总体 Review**（integration
> review，全新只读审查终端）审查整个 feature：方案、各子任务 verdict、测试
> 结果，以及 `git diff origin/main...HEAD`。

```mermaid
graph TD
    Start([用户发起请求]) --> Meet[主 Agent @main: 需求对接<br/>全程不离开 main 分支]
    Meet --> Q1{信息是否清晰?}
    Q1 -->|否| Ask[向用户追问]
    Ask --> Meet
    Q1 -->|是| DocGen[方案 Agent: 生成技术方案<br/>产物以文本传递, 不落盘 main]

    subgraph PlanLoop [方案审核循环: 最多 3+2 轮]
        DocGen --> Review[Review Agent 审方案<br/>含 owns 不相交校验]
        Review --> Q2{通过? 轮次 ≤ 3}
        Q2 -->|否, 未超限| Fix[修改方案, 附 Review 意见]
        Fix --> Review
        Q2 -->|超限| Escalate[升级人工, 说明分歧点]
        Escalate --> EscCnt{人工介入 ≤ 2 次?}
        EscCnt -->|是| DocGen
        EscCnt -->|否| Terminate1[❌ 终止: 方案无法收敛]
    end

    Q2 -->|是| Confirm[向用户确认方案]
    Confirm --> Q3{用户确认? 最多 3 次}
    Q3 -->|不通过, 未超限| Feedback[收集反馈]
    Feedback --> DocGen
    Q3 -->|不通过, 超限| ForceChoice{强制决策}
    ForceChoice -->|继续修改| DocGen
    ForceChoice -->|终止| Terminate2[❌ 终止: 方向偏差过大]
    Q3 -->|通过| Plan[主 Agent: 拆解子任务<br/>每个声明 deps + owns 文件所有权]
    Q3 -->|Abort 任意轮次| Terminate2

    Plan --> BranchExist{同名 worktree 已存在?<br/>崩溃恢复场景}
    BranchExist -->|是, 复用恢复| Dispatch
    BranchExist -->|否| CreateWT[创建 feature worktree<br/>base = origin/main]
    CreateWT --> Dispatch[按 DAG 波次分发:<br/>无依赖先并行, 有依赖等父任务通过]

    subgraph ParallelExec [执行阶段: 同一 worktree, owns 不相交]
        Dispatch --> Sub1[子任务 1 执行<br/>完成后 commit 到 feature 分支]
        Sub1 --> SubReview1[新开 Review Agent<br/>只审该子任务的 commit 范围]
        SubReview1 --> SubCheck1{通过? ≤ 3 轮}
        SubCheck1 -->|否| SubFix1[新开 Fix Agent<br/>附 review 意见]
        SubFix1 --> SubReview1
        SubCheck1 -->|超限| SubFail1[标记失败 + 原因]
        SubCheck1 -->|是| SubDone1[✅ 子任务 1]

        Dispatch --> Sub2[子任务 2 执行<br/>完成后 commit]
        Sub2 --> SubReview2[新开 Review Agent]
        SubReview2 --> SubCheck2{通过? ≤ 3 轮}
        SubCheck2 -->|否| SubFix2[新开 Fix Agent]
        SubFix2 --> SubReview2
        SubCheck2 -->|超限| SubFail2[标记失败 + 原因]
        SubCheck2 -->|是| SubDone2[✅ 子任务 2]
    end

    SubDone1 --> Collect[主 Agent: 收集全部结果<br/>check --wait 滚动等待]
    SubFail1 --> Collect
    SubDone2 --> Collect
    SubFail2 --> Collect

    Collect --> AllOK{全部通过?}
    AllOK -->|是| Prep
    AllOK -->|否| RetryDecision{重试策略?<br/>全局 ≤ 2 轮}
    RetryDecision -->|重试失败项, 新建 task| Dispatch
    RetryDecision -->|降级交付| PartialOK[revert 失败子任务的 commits<br/>PR 标注缺失项]
    RetryDecision -->|超限| EscalateSub[升级人工]
    EscalateSub --> HumanSubDecision{人工决策}
    HumanSubDecision -->|指定方向| Dispatch
    HumanSubDecision -->|接受部分交付| PartialOK
    HumanSubDecision -->|放弃| Terminate3[❌ 终止: 子任务无法完成]
    PartialOK --> Prep

    Prep[主 Agent: 变更摘要 + 在 feature worktree 跑项目测试]
    Prep --> Rebase[feature 分支 rebase 到 origin/main]
    Rebase --> Block{冲突?}
    Block -->|有| AutoFix[新开 Agent 自动解冲突<br/>≤ 2 次]
    AutoFix --> FixOK{解决?}
    FixOK -->|是| OverallReview
    FixOK -->|否| DeliverBlock[交付人工, 附冲突详情]
    DeliverBlock --> HumanSolve{人工处理}
    HumanSolve -->|已解决| OverallReview
    HumanSolve -->|放弃| Park
    Block -->|无| OverallReview

    subgraph FinalGate [合并前总体 Review: 新开 Agent, 与实现不同家]
        OverallReview[总体 Review Agent<br/>审 git diff origin/main...HEAD<br/>+ 测试结果 + 方案对照] --> OVQ{通过? ≤ 2 轮}
        OVQ -->|否| OVFix[新开 Fix Agent<br/>按 findings 修复并 commit]
        OVFix --> OverallReview
        OVQ -->|超限| OVEsc[升级人工: 放行或 park]
    end

    OVQ -->|是| CreatePR[gh pr create --base main<br/>附变更摘要 + 总体 review 结论]
    OVEsc -->|人工放行| CreatePR
    OVEsc -->|park| Park

    CreatePR --> PRWait{PR 状态?<br/>人工 review}
    PRWait -->|有意见| FixPR[新开 Fix Agent<br/>push 到同一分支]
    FixPR --> PRWait
    PRWait -->|已合并| Cleanup[删除远端分支<br/>orca worktree rm + 关闭终端<br/>主 Agent 仅 git fetch]
    PRWait -->|被关闭| Park[保留分支/worktree<br/>写 .orca/parked/ 恢复指引]

    Cleanup --> Final[归档: 结果/产物/分支状态<br/>jq 原子更新 state 文件]
    Park --> Final
    Final --> Notify[通知用户, 附交付报告]
    Notify --> End([结束])
```

## 状态流转表

`PARKED` 在 v2.2.0 中是 **feature 级**状态（每次运行恰好只有一个
worktree、一个分支、一个 PR）。`MERGING` 的子步骤按固定顺序执行：
`rebase → autofix → tests → integration-review → pr-create → pr-monitor`。

| 起始状态 | 触发条件 | 目标状态 | 约束条件 |
|------|---------|----|-------|
| `INIT` | 收到用户请求；前置条件已验证 | `GATHERING` | `orca status --json` 正常；协调者位于 Orca 管理的 `main` 检出中 |
| `GATHERING` | 需求已澄清 | `PLANNING` | Q1 = 是 |
| `GATHERING` | 澄清轮次耗尽 | `TERMINATED` | > 5 轮；与用户的交互只走协调者的原生通道 |
| `PLANNING` | Review Agent verdict = PASS（经 `worker_done`） | `CONFIRMING` | 审查是独立分发的 task（绝不 gate-create）；清单要求每个子任务声明 `owns`，且同一波次的 `owns` 互不相交 |
| `PLANNING` | 审查 FAIL，轮次未超限 | `PLANNING` | 轮次 ≤ MAX_REVIEW_ROUNDS (3)；方案按 Review 意见修改，以文本传递 |
| `PLANNING` | 轮次耗尽，升级人工 | `PLANNING` | 升级次数 ≤ MAX_ESCALATE (2) |
| `PLANNING` | 升级次数耗尽 | `TERMINATED` | Terminate1 |
| `CONFIRMING` | 用户批准 | `DISPATCHING` | — |
| `CONFIRMING` | 用户否决，轮次未超限 | `PLANNING` | 轮次 ≤ MAX_USER_CONFIRM (3)；反馈带回（仅可继续修改 —— 不提供缩减范围选项） |
| `CONFIRMING` | 用户否决，轮次耗尽 | `TERMINATED` | Terminate2 |
| `CONFIRMING` | 轮次 ≥ 3 仍未获批准 | `PLANNING` 或 `TERMINATED` | 强制用户决策（对应图中的「强制决策」节点） |
| `CONFIRMING` | 用户中止 | `TERMINATED` | 任意轮次立即生效（v2.2.0 off-by-one 修复） |
| `DISPATCHING` | 发现同名 worktree | `DISPATCHING`（恢复） | `orca worktree list --json` 按名称匹配 —— 崩溃恢复场景；复用，不重建 |
| `DISPATCHING` | worktree 已创建 + 波次 0 已分发 | `EXECUTING` | `git fetch origin main` + `orca worktree create --name "<slug>" --base-branch origin/main`；状态记录 worktree {id, path, branch_name, base_branch} |
| `DISPATCHING` | worktree 创建失败 | `TERMINATED` | 基础设施级失败 |
| `EXECUTING`（波次 w） | 波次 w 的全部子任务 verdict=PASS | `EXECUTING`（波次 w+1） | 有依赖的子任务只有在全部父任务 PASS 后才分发；它在共享 worktree 中能看到父任务已提交的代码；父任务 FAILED 的子任务被跳过 |
| `EXECUTING.sub-N` | 交叉审查 PASS | `EXECUTING`（等待波次） | 审查只覆盖子任务 `owns` 范围内 `<base_sha>..HEAD` 的变更；审查者 ≠ 实现者；每轮使用全新终端 |
| `EXECUTING.sub-N` | 审查 FAIL，轮次未超限 | `EXECUTING.sub-N`（第 r+1 轮） | 轮次 0..MAX_SUB_RETRY（1 次初始 + ≤ 3 次重试）；在全新终端上新建 task 并用 `--parent` 串联 —— 绝不重复分发同一个 task |
| `EXECUTING.sub-N` | 最后一轮审查仍 FAIL | `EXECUTING.sub-N`（FAIL） | verdict=FAIL 连同原因一并记录；兄弟子任务继续执行 |
| `EXECUTING` | 所有子任务达到终态 verdict | `DECIDING` | 协调者通过滚动 `check --wait` 等待；等待超时是活性检查点，不算失败 |
| `DECIDING` | 全部 PASS | `MERGING` | AllOK = 是 |
| `DECIDING` | 仅重试失败的子任务 | `DISPATCHING` | 仅当 global_retries_used < MAX_GLOBAL_RETRY (2) 时允许，在自增**之前**检查 —— 最多重试 2 次 |
| `DECIDING` | 降级交付 | `MERGING` | 协调者在 feature worktree 中 revert 每个失败子任务的 commit 范围 —— 因 `owns` 互不相交所以干净；revert 不干净 → `PARKED` |
| `DECIDING` | 人工中止 | `TERMINATED` | Terminate3 |
| `MERGING.rebase` | `git rebase origin/main` 无冲突 | `MERGING.tests` | 在 feature worktree 内执行 |
| `MERGING.rebase` | 有冲突 | `MERGING.autofix` | ≤ MAX_AUTOFIX (2) 次尝试；全新终端解决冲突并运行 `git rebase --continue` |
| `MERGING.autofix` | rebase 完成**且** `^UU` 文件数为零 | `MERGING.tests` | 成功需同时满足两个条件 —— 然后跳出循环 |
| `MERGING.autofix` | 任意一次 autofix 失败 / 尝试次数耗尽 | 人工决策 | 人工解决 → `MERGING.tests`；放弃 → `PARKED` |
| `MERGING.tests` | 项目测试已在 worktree 中运行，结果已记录 | `MERGING.integration-review` | 结果写入 integration-review 的 spec |
| `MERGING.integration-review` | verdict PASS | `MERGING.pr-create` | 全新只读审查终端；spec = 方案 + 各子任务 verdict + 测试结果 + `git diff origin/main...HEAD` |
| `MERGING.integration-review` | verdict FAIL，轮次未超限 | `MERGING.integration-review`（第 r+1 轮） | 全新 fix 终端按 findings 修复并 commit；再用另一个全新审查终端复审；≤ MAX_INTEGRATION_REVIEW (2) 轮 |
| `MERGING.integration-review` | 轮次耗尽 | 人工决策 | 仍然放行 → `MERGING.pr-create`；park → `PARKED` |
| `MERGING.pr-create` | `gh pr create` 退出码为 0 | `MERGING.pr-monitor` | Body = 变更摘要、产物、各子任务审查轮次、integration-review verdict，如适用附 ⚠️ 降级交付横幅 |
| `MERGING.pr-monitor` | 轮询：`MERGED` | `CLEANING` | 每 60s 运行 `gh pr view --json state,mergeStateStatus`；绝不在轮询循环里 gate-create |
| `MERGING.pr-monitor` | Changes Requested | `MERGING.pr-monitor`（pr-fix 轮） | 全新 fix 终端 → push 到同一分支 → 继续监控 |
| `MERGING.pr-monitor` | `CLOSED` | `PARKED` | feature 级 park |
| `PARKED` | park 清单已写入 | `CLEANING` | `.orca/parked/<feature-slug>.md`：分支、worktree 路径、PR url、原因、恢复步骤；worktree + 分支**保留** |
| `CLEANING` | 已合并：删除远端分支、移除 worktree、关闭 keep_terminal | `CLEANING`（归档） | `git push origin --delete <branch>`；`orca worktree rm --worktree id:<id> --force`；每种 pr_state 都显式处理（清理时仍为 OPEN = 告警/拦截） |
| `CLEANING` | 历史已追加，状态已定稿 | `DONE` | 向 `.orca/workflow-history.jsonl` 追加**一行**；状态更新用 jq 原子写入（临时文件 + mv）；此后协调者仅运行 `git fetch origin` |
| 任意状态 | 协调者致命错误 / 用户中止 | `TERMINATED` | 先持久化状态再终止 |

## 终止出口

| 出口 | 触发条件 | Feature 状态 |
|------|------------------|---------------|
| **Terminate1** | 方案在 3 轮审查 + 2 次人工升级内仍无法通过审查 | 从未创建 worktree —— 方案未获批准；无需清理 |
| **Terminate2** | 用户 3 次否决方案，或在任意确认轮次中止 | 从未创建 worktree —— 用户不认可该方向 |
| **Terminate3** | 全局重试（≤ 2 次）后子任务仍失败，且人工选择中止 | 已通过子任务的 commits 保留在 feature 分支上；worktree + 分支按 Phase 8 清理流程处置 |
| **Feature 级 PARKED**（可恢复） | 降级 revert 不干净；rebase autofix 耗尽 + 人工 park；integration review 轮次耗尽 + 人工 park；PR 未合并被关闭 | worktree + 分支**保留**；`.orca/parked/<feature-slug>.md` 记录分支、worktree 路径、PR url、原因、恢复步骤 |
| **DONE** | PR 已合并（完整交付或降级交付） | 远端分支已删除，worktree 已移除，keep_terminal 已关闭，向 `.orca/workflow-history.jsonl` 追加一行历史 |
