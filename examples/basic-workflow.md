# 示例：添加用户偏好设置 —— 端到端完整演练（v2.2.0）

> 一次完整多智能体工作流运行的带注释演练，基于
> **v2.2.0 共享 worktree 波次模型**。任务：「添加用户偏好设置 —— API
> 接口加一个设置 UI 面板。」两个子任务在**同一个共享特性 worktree**、
> **同一条特性分支**上执行，最终产出**同一个 PR**。
> 并行安全性来自各子任务互不相交的 `owns` glob，而不是文件系统隔离；
> 依赖关系意味着**串行波次**，而不是堆叠分支。

## 与 v2.1.0 的差异

- **一个特性 = 一个 worktree + 一条分支 + 一个 PR。** v2.1.0 的按子任务
  worktree、堆叠分支、按子任务 PR、draft PR、§11.8
  堆叠 PR rebase 钩子，以及分支/worktree 路径模板，全部移除。
- **`owns` 取代隔离。** 每个子任务声明自己可写入的路径 glob；
  同一波次（并行）的子任务 `owns` 必须互不相交，由计划审查校验。
- **计划审查是一个独立的审查任务**，其 verdict 通过
  `worker_done` 返回 —— Agent 审查不再使用 `gate-create`。
- **用户交互走协调者的原生渠道** —— 绝不使用
  `orca orchestration ask --to coordinator`（该动词仅供 worker→协调者使用）。
- **Phase 7 新增合并前总体 Review（integration review）**，针对整个特性
  diff（`ORCA_WORKFLOW_MAX_INTEGRATION_REVIEW`，默认 2）。
- **协调者绝不运行 `git checkout`** —— 整个运行期间它都停留在 main
  分支上；所有特性相关的 git 操作都在 worktree 内通过
  `(cd <wt> && git ...)` 完成。
- v2.0.1 的「缩减范围」确认选项已移除（向协调者的 main 检出并行写入
  是不安全的）；用户改用**「修订」**来缩减范围。

## 场景设定

```
用户："添加用户偏好设置 —— API 接口，外加 dashboard 里一个调用它们的
       UI 面板。"
```

获批的拆分方案（最终计划，Phase 2 输出）：

```json
[
  {
    "id": "sub-1",
    "logical_id": "prefs-api",
    "title": "Preferences API (Fastify + Postgres)",
    "deps": [],
    "owns": ["server/**", "migrations/**"],
    "complexity": "general",
    "spec": "Implement POST /api/preferences (upsert, JWT-scoped) and GET /api/preferences, plus an idempotent migration creating the user_preferences table.",
    "review_criteria": ["JWT scope enforced", "Schema matches plan", "Migration is idempotent"],
    "timeout_ms": 3600000
  },
  {
    "id": "sub-2",
    "logical_id": "prefs-ui",
    "title": "Preferences UI (React + React Query)",
    "deps": ["sub-1"],
    "owns": ["web/src/settings/**"],
    "complexity": "general",
    "spec": "Implement the /settings/preferences page (theme selector, language selector, email-digest switch) with React Query fetch + optimistic update and toast on save.",
    "review_criteria": ["Hooks consume the prefs-api contract", "Optimistic update on save", "A11y: aria-labels + keyboard nav"],
    "timeout_ms": 3600000
  }
]
```

波次布局（DAG 的拓扑分层）：

```
波次 0（最先分发）：       sub-1   owns: server/**, migrations/**
波次 1（sub-1 PASS 之后）：sub-2   owns: web/src/settings/**
```

本次运行的 Agent 路由（默认值）：计划 = `claude`（备选 `pi`），审查 = `pi`，
执行 = `kimi`，兜底链 = `claude,grok,pi`。交叉审查规则：审查 Agent 绝不
与实现 Agent 同家。限额（默认值）：
`ORCA_WORKFLOW_MAX_REVIEW_ROUNDS=3`、`ORCA_WORKFLOW_MAX_ESCALATE=2`、
`ORCA_WORKFLOW_MAX_USER_CONFIRM=3`、`ORCA_WORKFLOW_MAX_SUB_RETRY=3`、
`ORCA_WORKFLOW_MAX_GLOBAL_RETRY=2`、`ORCA_WORKFLOW_MAX_AUTOFIX=2`、
`ORCA_WORKFLOW_MAX_INTEGRATION_REVIEW=2`。

前置条件：协调者运行在 Orca 管理的 main 分支检出内
（`orca status --json` 报告 `.ok == true`）。

---

## Phase 1：需求收集

协调者通过**自己的原生交互渠道**向用户提问。它不会 shell 调用
`orca orchestration ask --to coordinator` —— 那个动词是给 *worker* 联系
协调者用的，不是给协调者联系用户用的。

```
协调者 → 用户（原生渠道）：
  "开始计划之前我需要五个答案：
   1. 后端技术栈？（Node/Express、Go、Python/FastAPI……）
   2. 前端技术栈？（React、Vue、纯 HTML）
   3. 鉴权：用户身份如何签发？（JWT、session、magic link）
   4. 持久化：Postgres、SQLite、KV 存储？
   5. 除了 theme / language / notifications 之外，初始偏好键还有哪些？"

用户 → 协调者：
  "Node 22 + Fastify 后端，React + Vite 前端，JWT 鉴权，Postgres。
   初始键：theme、language、email_digest。"
```

**缺口分析：** ✅ 第 1 轮（上限 ≤5 轮）后检查清单全部明确。
进入 Phase 2。

---

## Phase 2：计划生成与审查

计划 Agent 在协调者的检出中获得一个**全新终端**
（选择器 `active`）。计划过程是纯文本的：计划产物通过
`worker_done` 正文返回，**绝不作为文件写入 main 检出**。

```bash
PLAN_TERM=$(orca terminal create \
  --worktree active \
  --title "[plan:claude] wf_20260727_001 plan" \
  --command "claude" \
  --json | jq -r '.result.terminal.handle')

PLAN_TASK=$(orca orchestration task-create \
  --task-title "Plan: User Preferences (API + UI)" \
  --display-name "📝 Plan agent" \
  --spec "Generate a technical plan for adding user preferences to this repo.

Backend:  POST /api/preferences (upsert per user), GET /api/preferences.
          Schema {theme: light|dark|system, language: en|zh, email_digest: bool}.
          JWT middleware; preferences scoped to req.user.id. Postgres.
Frontend: /settings/preferences page, React Query fetch + optimistic update,
          toast on success/failure.

REQUIRED OUTPUT SHAPE (return as TEXT in your worker_done body; do NOT write
plan files into this checkout):
1. Architecture overview
2. Subtask DAG — every subtask MUST declare: id, logical_id, title, deps[],
   owns[] (path globs it may write), complexity (general|complex|image),
   spec, review_criteria[], timeout_ms
3. Migration / schema decisions
4. Test plan

DONE PROTOCOL: send worker_done EXACTLY ONCE to the coordinator handle with
taskId + dispatchId + verdict + artifact summary, then idle." \
  --json | jq -r '.result.task.id')

orca orchestration dispatch --task "$PLAN_TASK" --to "$PLAN_TERM" --inject --json
```

协调者以滚动方式等待（超时只是检查点，不是失败 —— Agent 运行
 15–60 分钟是常态）：

```bash
orca orchestration check --wait \
  --types worker_done,escalation,decision_gate \
  --timeout-ms 900000 --json
```

计划以文本形式到达。审查是一个**独立任务**，分发到审查 Agent（`pi`）
自己的全新终端上 —— verdict 通过 `worker_done` 返回，
而不是 `gate-create`：

```bash
PREV_TERM=$(orca terminal create \
  --worktree active \
  --title "[review:pi] plan review r1" \
  --command "pi" \
  --json | jq -r '.result.terminal.handle')

PREV_TASK=$(orca orchestration task-create \
  --task-title "Review: plan round 1" \
  --display-name "🔍 Plan review r1" \
  --spec "Read-only review of the plan quoted below. Checklist:
- [ ] Every subtask declares owns[] path globs
- [ ] Same-wave (parallel) subtasks have DISJOINT owns
- [ ] deps[] form an acyclic graph
- [ ] review_criteria are concrete and testable
- [ ] No subtask needs write access outside its owns
Reply via worker_done EXACTLY ONCE: verdict PASS or FAIL + reasons, then idle.

PLAN:
<plan text from the plan worker's worker_done body>" \
  --json | jq -r '.result.task.id')

orca orchestration dispatch --task "$PREV_TASK" --to "$PREV_TERM" --inject --json
```

**审查结论（第 1 轮）：PASS。** 波次 0 = `[sub-1]`，波次 1 = `[sub-2]` ——
每个波次只有一个子任务，同波次不相交性自然成立；跨波次重叠本来也
可以接受，因为波次是串行的。（可用额度为
`≤ ORCA_WORKFLOW_MAX_REVIEW_ROUNDS=3` 轮审查和
`≤ ORCA_WORKFLOW_MAX_ESCALATE=2` 次人工升级；均未用到。）
两个终端都关闭；进入 Phase 3。

---

## Phase 3：用户确认

同样走协调者的原生渠道（`≤ ORCA_WORKFLOW_MAX_USER_CONFIRM=3`
轮；**「中止」会在任意轮次立即终止工作流**；没有缩减范围选项 ——
请用「修订」）：

```
协调者 → 用户（原生渠道）：
  "✅ 计划已内部获批（审查第 1 轮：PASS）。

   - 一个特性 worktree + 基于 origin/main 的分支 feature/add-user-prefs，
     最后产出一个 PR。
   - 波次 0：sub-1 prefs-api（owns server/**, migrations/**）
   - 波次 1：sub-2 prefs-ui（owns web/src/settings/**）—— 仅在
     sub-1 通过审查后才开始。
   - 预估：约 2–3 小时；每个子任务最多 3 轮审查；PR 之前做一次
     整个特性的合并前总体 Review。

   [批准]  [修订]  [中止]"

用户 → 协调者："批准"
```

---

## Phase 4：特性 worktree 与波次 0 分发

协调者停留在 main。它在自有检出里仅有的 git 操作是
`git fetch origin`（可选 `git pull --ff-only`）。

```bash
git fetch origin main

# 续跑/存在性检查，按名称匹配：
orca worktree list --json \
  | jq -r '.result.worktrees[]? | select(.name=="add-user-prefs") | .id'
# → 为空：没有上一次运行残留的 worktree
#（首次实跑时确认 JSON 字段名的准确拼写）

# 创建唯一的一个特性 worktree；分支 feature/add-user-prefs 基于
# origin/main。没有位置路径参数，也没有 --base 标志。
WT_JSON=$(orca worktree create \
  --name "add-user-prefs" \
  --base-branch origin/main \
  --json)
WT_ID=$(jq -r '.result.worktree.id' <<<"$WT_JSON")       # → wt_7f3a2c
WT_PATH=$(jq -r '.result.worktree.path' <<<"$WT_JSON")   # → /Users/dev/worktrees/add-user-prefs
WT_BRANCH=$(jq -r '.result.worktree.branch' <<<"$WT_JSON") # → feature/add-user-prefs
#（首次实跑时确认 JSON 字段名的准确拼写）
```

把 worktree 记入 `.orca/workflow-state.json` —— **所有**状态更新
都是 jq 原子写入（tmp 文件 + `mv`），绝不对 JSON 用 `>>`：

```bash
jq --arg id "$WT_ID" --arg path "$WT_PATH" --arg branch "$WT_BRANCH" '
    .feature_slug = "add-user-prefs"
  | .worktree = {id: $id, path: $path, branch_name: $branch, base_branch: "origin/main"}
  | .current_phase = "DISPATCHING"
' .orca/workflow-state.json > .orca/workflow-state.json.tmp \
  && mv .orca/workflow-state.json.tmp .orca/workflow-state.json
```

波次计算：`sub-1` 无依赖 → 波次 0；`sub-2` 依赖 `sub-1` →
波次 1。**现在只分发波次 0。** 尽管 worktree 是共享的，`sub-2`
也必须等待 `sub-1` 的 verdict —— 之后它会在同一个检出里自然地看到
sub-1 已提交的代码。

```bash
# 每次分发都记录子任务的 base_sha = 特性分支当前 HEAD。
SUB1_BASE=$(cd "$WT_PATH" && git rev-parse HEAD)   # 9f02c1ab…（创建时 == origin/main）

EXEC_S1=$(orca terminal create \
  --worktree "id:$WT_ID" \
  --title "[execution:kimi] sub-1 r0 prefs-api" \
  --command "kimi --auto" \
  --json | jq -r '.result.terminal.handle')            # → term_s1e0

SUB1_TASK=$(orca orchestration task-create \
  --task-title "Sub: prefs-api (round 0)" \
  --display-name "🔧 prefs-api r0" \
  --deps '[]' \
  --spec "ROLE: execution agent for subtask sub-1 (prefs-api), round 0 of 3.
WORKTREE: $WT_PATH   (branch: feature/add-user-prefs, base: origin/main)
BASE_SHA: $SUB1_BASE  — your work is reviewed as $SUB1_BASE..HEAD
OWNS: server/**, migrations/**  — write ONLY inside these globs; the worktree
      is shared with other subtasks.
SPEC: Implement POST /api/preferences (upsert, JWT-scoped) and
      GET /api/preferences, plus an idempotent migration creating
      user_preferences(user_id, theme, language, email_digest, updated_at).
REVIEW CRITERIA: JWT scope enforced; schema matches plan; migration idempotent.
COMMIT: commit your work in small commits.
DONE: send worker_done EXACTLY ONCE to the coordinator handle with
      taskId + dispatchId + verdict + artifact summary, then idle." \
  --json | jq -r '.result.task.id')                    # → task_s1r0

orca orchestration dispatch --task "$SUB1_TASK" --to "$EXEC_S1" --inject --json
```

Phase 4 之后的状态（`.orca/workflow-state.json`）：

```json
{
  "workflow_id": "wf_20260727_001",
  "version": "2.2.0",
  "started_at": "2026-07-27T10:30:12Z",
  "current_phase": "DISPATCHING",
  "current_state": "WAVE0_DISPATCHED",
  "termination_reason": null,
  "delivery_mode": null,
  "feature_slug": "add-user-prefs",
  "worktree": {
    "id": "wt_7f3a2c",
    "path": "/Users/dev/worktrees/add-user-prefs",
    "branch_name": "feature/add-user-prefs",
    "base_branch": "origin/main"
  },
  "pr": { "url": null, "state": null, "merged_at": null },
  "phases": {
    "GATHERING": { "completed_at": "2026-07-27T10:36:00Z", "rounds": 1 },
    "PLANNING": { "completed_at": "2026-07-27T10:47:00Z", "review_rounds": 1, "verdict": "PASS" },
    "CONFIRMING": { "completed_at": "2026-07-27T10:49:00Z", "rounds": 1, "decision": "approve" }
  },
  "tasks": {
    "plan": { "task_id": "task_plan01", "review_task_id": "task_prev01", "verdict": "PASS", "review_rounds": 1 },
    "subtasks": [
      {
        "id": "sub-1",
        "logical_id": "prefs-api",
        "title": "Preferences API (Fastify + Postgres)",
        "complexity": "general",
        "deps": [],
        "owns": ["server/**", "migrations/**"],
        "status": "dispatched",
        "verdict": null,
        "reason": null,
        "base_sha": "9f02c1ab3d9e4a0f7c2b1e5d8a6f4c3b2a19087f",
        "initial_base_sha": "9f02c1ab3d9e4a0f7c2b1e5d8a6f4c3b2a19087f",
        "review_rounds": 0,
        "terminals": [
          { "handle": "term_s1e0", "role": "execution", "round": 0, "agent_type": "kimi", "status": "running", "verdict": null, "spawned_at": "2026-07-27T10:52:00Z", "closed_at": null }
        ],
        "keep_terminal": null
      },
      {
        "id": "sub-2",
        "logical_id": "prefs-ui",
        "title": "Preferences UI (React + React Query)",
        "complexity": "general",
        "deps": ["sub-1"],
        "owns": ["web/src/settings/**"],
        "status": "pending",
        "verdict": null,
        "reason": null,
        "base_sha": null,
        "initial_base_sha": null,
        "review_rounds": 0,
        "terminals": [],
        "keep_terminal": null
      }
    ]
  },
  "integration_review": { "rounds": 0, "verdict": null },
  "decisions": [
    { "phase": "CONFIRMING", "decision": "approve", "at": "2026-07-27T10:49:00Z" }
  ],
  "retry_counts": { "global_retries_used": 0 },
  "errors": []
}
```

---

## Phase 5：执行波次与交叉审查

轮次编号为 `0..ORCA_WORKFLOW_MAX_SUB_RETRY`（0..3 = 1 次初始
尝试 + 至多 3 次重试）。每一轮 = 在**全新终端上以新 task** 执行/修复
（用 `--parent` 串联；绝不重复 dispatch 同一个 task —— Orca 会对连续
失败 3 次的 task 触发熔断），然后在**另一个全新终端**上用审查 Agent
（`pi` ≠ `kimi`）做交叉审查。等待期间，协调者以滚动循环运行
`orca orchestration check --wait ...`；超时只意味着「看一眼
`task-list` 和 worker 终端确认存活，然后继续等」。子任务的墙钟超时由
协调者自己执行（`task-update --status failed` +
`orca terminal close --terminal <handle>`），失败的执行可以走兜底链
（`claude,grok,pi`）重试 —— 每次兜底尝试同样是新 task + 新终端。
本次运行两者都没有发生。

### 波次 0 —— sub-1（prefs-api）

**第 0 轮 —— 执行。** `kimi` 在 `term_s1e0` 上用三个小 commit
实现 API（`9f02c1ab..41d8e77c`），发送一次 `worker_done`，转入空闲。

**第 0 轮 —— 交叉审查**，在一个全新的 `pi` 终端上进行，范围限定在
已记录的区间和该子任务的 `owns` 内：

```bash
REV_S1=$(orca terminal create \
  --worktree "id:$WT_ID" \
  --title "[review:pi] sub-1 r0 review" \
  --command "pi" \
  --json | jq -r '.result.terminal.handle')              # → term_s1r0

SUB1_REVIEW=$(orca orchestration task-create \
  --task-title "Review: prefs-api r0" \
  --display-name "🔍 prefs-api r0 review" \
  --parent "$SUB1_TASK" \
  --spec "ROLE: read-only review agent for subtask sub-1 (prefs-api), round 0.
Review ONLY the range 9f02c1ab..HEAD inside owns (server/**, migrations/**):
  (cd $WT_PATH && git log --oneline 9f02c1ab..HEAD && \
                  git diff 9f02c1ab..HEAD -- server migrations)
Do NOT modify any file.
CRITERIA: JWT scope enforced; schema matches plan; migration idempotent.
DONE: worker_done EXACTLY ONCE with verdict PASS|FAIL + reasons, then idle." \
  --json | jq -r '.result.task.id')

orca orchestration dispatch --task "$SUB1_REVIEW" --to "$REV_S1" --inject --json
```

**Verdict：FAIL** —— `migrations/20260727110000_create_user_preferences.sql`
第二次运行时报错（裸 `CREATE TABLE` + 普通 `INSERT` 种子数据）；不具备
幂等性。关闭 `term_s1r0`。`sub-1.review_rounds = 1`。

**第 1 轮 —— 修复。** 用 `--parent` 串联的新 task、全新终端、前言里
引用上轮反馈，并**重新记录 `base_sha`**（特性分支当前 HEAD）：

```bash
SUB1_BASE=$(cd "$WT_PATH" && git rev-parse HEAD)   # 41d8e77c… —— 覆盖 sub-1.base_sha
                                                    #（initial_base_sha 保持 9f02c1ab… 不变）

FIX_S1=$(orca terminal create \
  --worktree "id:$WT_ID" \
  --title "[fix:kimi] sub-1 r1 prefs-api" \
  --command "kimi --auto" \
  --json | jq -r '.result.terminal.handle')              # → term_s1e1

SUB1_FIX=$(orca orchestration task-create \
  --task-title "Fix: prefs-api (round 1)" \
  --display-name "🛠 prefs-api r1 fix" \
  --parent "$SUB1_TASK" \
  --spec "ROLE: fix agent for subtask sub-1 (prefs-api), round 1 of 3.
WORKTREE: $WT_PATH   (branch: feature/add-user-prefs)
BASE_SHA: $SUB1_BASE  — your work is reviewed as $SUB1_BASE..HEAD
OWNS: server/**, migrations/**  — write ONLY inside these globs.
PRIOR FEEDBACK (review round 0, FAIL): the migration is not idempotent —
  second run fails on CREATE TABLE. Use CREATE TABLE IF NOT EXISTS and
  ON CONFLICT DO NOTHING for the seed row.
COMMIT: commit your work in small commits.
DONE: worker_done EXACTLY ONCE with taskId + dispatchId + verdict + summary,
      then idle." \
  --json | jq -r '.result.task.id')

orca orchestration dispatch --task "$SUB1_FIX" --to "$FIX_S1" --inject --json
```

修复落为单个 commit（`41d8e77c..c3b55d9e`）。

**第 1 轮 —— 交叉审查**，在另一个全新的 `pi` 终端（`term_s1r1`）上进行，
范围 `41d8e77c..HEAD`，标准不变。**Verdict：PASS** —— 迁移现在具备
幂等性；全部标准满足。关闭 `term_s1r1`。

`sub-1`：verdict=PASS，review_rounds=2，keep_terminal=`term_s1e1`
（最新的实现终端胜出；`term_s1e0` 已关闭）。

### 波次 1 —— sub-2（prefs-ui）

门检查：`sub-2` 的所有父任务均已 verdict=PASS ✅（`sub-1`）。
分发器现在把 `sub-2` 送进**同一个** worktree —— 它自然地看到
sub-1 已提交的 API 代码。

```bash
SUB2_BASE=$(cd "$WT_PATH" && git rev-parse HEAD)   # c3b55d9e… —— sub-2 的首次分发：
                                                    # 同时记为 base_sha 和 initial_base_sha

EXEC_S2=$(orca terminal create \
  --worktree "id:$WT_ID" \
  --title "[execution:kimi] sub-2 r0 prefs-ui" \
  --command "kimi --auto" \
  --json | jq -r '.result.terminal.handle')            # → term_s2e0

SUB2_TASK=$(orca orchestration task-create \
  --task-title "Sub: prefs-ui (round 0)" \
  --display-name "🔧 prefs-ui r0" \
  --deps '["sub-1"]' \
  --spec "ROLE: execution agent for subtask sub-2 (prefs-ui), round 0 of 3.
WORKTREE: $WT_PATH   (branch: feature/add-user-prefs)
BASE_SHA: $SUB2_BASE  — your work is reviewed as $SUB2_BASE..HEAD
OWNS: web/src/settings/**  — write ONLY inside this glob; the worktree is
      shared. The API you consume is already committed under server/**.
SPEC: Implement /settings/preferences (theme selector, language selector,
      email-digest switch) with React Query fetch + optimistic update and a
      toast on save, against GET/POST /api/preferences.
REVIEW CRITERIA: hooks consume the prefs-api contract; optimistic update;
      a11y (aria-labels + keyboard nav).
COMMIT: commit your work in small commits.
DONE: worker_done EXACTLY ONCE with taskId + dispatchId + verdict + summary,
      then idle." \
  --json | jq -r '.result.task.id')

orca orchestration dispatch --task "$SUB2_TASK" --to "$EXEC_S2" --inject --json
```

**第 0 轮 —— 执行：** 两个小 commit（`c3b55d9e..7ea01f42`）。
**第 0 轮 —— 交叉审查**，在全新的 `pi` 终端 `term_s2r0` 上进行，范围
`c3b55d9e..HEAD`，限定 `web/src/settings/**`。**Verdict：PASS**，
一次通过。`sub-2`：verdict=PASS，review_rounds=1，
keep_terminal=`term_s2e0`。

### 终端台账（按轮次）

| 句柄 | 阶段 | 角色 | 轮次 | Agent | Verdict | 归宿 |
|--------|-------|------|-------|-------|---------|------|
| `term_plan` | 计划 | plan | — | claude | 计划已交付 | 审查后关闭 |
| `term_prev` | 计划 | review | 1 | pi | PASS | 已关闭 |
| `term_s1e0` | sub-1 | execution | 0 | kimi | done | 已关闭（被 r1 取代） |
| `term_s1r0` | sub-1 | review | 0 | pi | FAIL | 已关闭 |
| `term_s1e1` | sub-1 | fix | 1 | kimi | done | **keep_terminal** → Phase 8 关闭 |
| `term_s1r1` | sub-1 | review | 1 | pi | PASS | 已关闭 |
| `term_s2e0` | sub-2 | execution | 0 | kimi | done | **keep_terminal** → Phase 8 关闭 |
| `term_s2r0` | sub-2 | review | 0 | pi | PASS | 已关闭 |
| `term_ir1` | Phase 7 | integration-review | 1 | pi | FAIL | 已关闭 |
| `term_irf` | Phase 7 | fix | 1 | kimi | done | Phase 8 关闭 |
| `term_ir2` | Phase 7 | integration-review | 2 | pi | PASS | 已关闭 |

### Phase 5 之后的状态（节选：`tasks.subtasks`）

```json
{
  "subtasks": [
    {
      "id": "sub-1",
      "logical_id": "prefs-api",
      "title": "Preferences API (Fastify + Postgres)",
      "complexity": "general",
      "deps": [],
      "owns": ["server/**", "migrations/**"],
      "status": "completed",
      "verdict": "PASS",
      "reason": null,
      "base_sha": "41d8e77c0b2f4a69183d5c7e9f1a3b5d7c9e1f02",
      "initial_base_sha": "9f02c1ab3d9e4a0f7c2b1e5d8a6f4c3b2a19087f",
      "review_rounds": 2,
      "terminals": [
        { "handle": "term_s1e0", "role": "execution", "round": 0, "agent_type": "kimi", "status": "closed", "verdict": "done", "spawned_at": "2026-07-27T10:52:00Z", "closed_at": "2026-07-27T11:19:00Z" },
        { "handle": "term_s1r0", "role": "review", "round": 0, "agent_type": "pi", "status": "closed", "verdict": "FAIL", "spawned_at": "2026-07-27T11:12:00Z", "closed_at": "2026-07-27T11:18:00Z" },
        { "handle": "term_s1e1", "role": "fix", "round": 1, "agent_type": "kimi", "status": "idle", "verdict": "done", "spawned_at": "2026-07-27T11:19:00Z", "closed_at": null },
        { "handle": "term_s1r1", "role": "review", "round": 1, "agent_type": "pi", "status": "closed", "verdict": "PASS", "spawned_at": "2026-07-27T11:31:00Z", "closed_at": "2026-07-27T11:37:00Z" }
      ],
      "keep_terminal": "term_s1e1"
    },
    {
      "id": "sub-2",
      "logical_id": "prefs-ui",
      "title": "Preferences UI (React + React Query)",
      "complexity": "general",
      "deps": ["sub-1"],
      "owns": ["web/src/settings/**"],
      "status": "completed",
      "verdict": "PASS",
      "reason": null,
      "base_sha": "c3b55d9e8a4f2c6071b3d5e7f9a1c3e5b7d9f1a3",
      "initial_base_sha": "c3b55d9e8a4f2c6071b3d5e7f9a1c3e5b7d9f1a3",
      "review_rounds": 1,
      "terminals": [
        { "handle": "term_s2e0", "role": "execution", "round": 0, "agent_type": "kimi", "status": "idle", "verdict": "done", "spawned_at": "2026-07-27T11:38:00Z", "closed_at": null },
        { "handle": "term_s2r0", "role": "review", "round": 0, "agent_type": "pi", "status": "closed", "verdict": "PASS", "spawned_at": "2026-07-27T11:52:00Z", "closed_at": "2026-07-27T11:58:00Z" }
      ],
      "keep_terminal": "term_s2e0"
    }
  ]
}
```

注意：`base_sha` 保存的是子任务**最近一次**分发时记录的 SHA
（sub-1：第 1 轮修复分发；sub-2：第 0 轮分发）—— 每轮审查恰好覆盖
当轮的 `<base_sha>..HEAD`。`initial_base_sha` 在第 0 轮分发时写入一次，
之后绝不覆盖；它锚定降级回滚的范围（限定在 `owns` 内的
`<initial_base_sha>..HEAD`，见 §10）。

---

## Phase 6：汇总与决策

两个子任务都达到 verdict=PASS → 直接进入 Phase 7。没有全局重试
（`global_retries_used` 保持 0，上限 `ORCA_WORKFLOW_MAX_GLOBAL_RETRY=2`）。
未全部通过的路径见文末的**失败场景附栏**。

---

## Phase 7：Rebase、测试、合并前总体 Review 与 PR

所有步骤都**在特性 worktree 内**运行；协调者绝不离开 main。

### Rebase 到 origin/main

```bash
( cd "$WT_PATH" && git fetch origin main && git rebase origin/main )
# → 干净：main 只多了一个无关的文档 commit；与我们的 owns 无重叠
```

如果出现冲突，会运行 ≤ `ORCA_WORKFLOW_MAX_AUTOFIX=2` 次自动修复
循环 —— 一个全新终端解决冲突标记并运行 `git rebase --continue`，
SUCCESS 要求 rebase 已完成**且** `^UU` 文件为零；任何自动修复失败都
升级给人工（手动解决或 PARK）。这里不需要。

### 项目测试（在 worktree 内）

```bash
( cd "$WT_PATH" && npm test )
# ✔ 42 通过，0 失败 —— 记录到状态的 phases.MERGING 下
```

### 合并前总体 Review（v2.2.0 新增）

各子任务审查已分别通过；现在用一个全新的 `pi` 终端把**整个特性作为
一个整体**审查 —— 只读职责，verdict 通过 `worker_done` 返回：

```bash
IR1=$(orca terminal create \
  --worktree "id:$WT_ID" \
  --title "[integration-review:pi] feature r1" \
  --command "pi" \
  --json | jq -r '.result.terminal.handle')                # → term_ir1

IR1_TASK=$(orca orchestration task-create \
  --task-title "Integration review r1" \
  --display-name "🧪 integration review r1" \
  --spec "ROLE: read-only INTEGRATION review agent for feature add-user-prefs,
round 1 of 2. Review the WHOLE feature as one unit:
  (cd $WT_PATH && git diff origin/main...HEAD)
INPUTS: approved plan (quoted below); per-subtask verdicts (sub-1 PASS in
round 1, sub-2 PASS in round 0); test results (42 passed, 0 failed).
FOCUS: cross-subtask consistency (API contract vs client usage), migration
safety, dead code, missing error handling. Do NOT modify any file.
DONE: worker_done EXACTLY ONCE with verdict PASS|FAIL + findings, then idle.

PLAN:
<approved plan text>" \
  --json | jq -r '.result.task.id')

orca orchestration dispatch --task "$IR1_TASK" --to "$IR1" --inject --json
```

**第 1 轮 verdict：FAIL** —— API 的错误信封不一致：服务端返回
`400 {"error":{"code":"INVALID_PREFS","message":"…"}}`，但
`web/src/settings/api.ts` 把失败类型声明为 `{message: string}`，
导致 UI 在校验错误时 toast 出 "undefined"。关闭 `term_ir1`。

一个全新的修复终端应用这些发现并提交（第 1 轮修复）：

```bash
IRFIX=$(orca terminal create \
  --worktree "id:$WT_ID" \
  --title "[fix:kimi] integration fix r1" \
  --command "kimi --auto" \
  --json | jq -r '.result.terminal.handle')                # → term_irf

IRFIX_TASK=$(orca orchestration task-create \
  --task-title "Integration fix r1" \
  --display-name "🛠 integration fix r1" \
  --parent "$IR1_TASK" \
  --spec "ROLE: fix agent for the add-user-prefs integration review, round 1.
WORKTREE: $WT_PATH   (branch: feature/add-user-prefs)
FINDINGS (verbatim from integration review round 1): align the error envelope —
  server returns {error:{code,message}}; web types expect {message}. Make the
  web client consume the server envelope and map known codes to toasts.
COMMIT: commit your work in small commits.
DONE: worker_done EXACTLY ONCE with taskId + dispatchId + verdict + summary,
      then idle." \
  --json | jq -r '.result.task.id')

orca orchestration dispatch --task "$IRFIX_TASK" --to "$IRFIX" --inject --json
# 修复落为单个 commit → HEAD = 8bd40c17…
```

**第 2 轮：** 另一个全新的 `pi` 终端（`term_ir2`）重新审查
`git diff origin/main...HEAD`。**Verdict：PASS。** 状态：
`integration_review = {rounds: 2, verdict: "PASS"}`。如果第 2 轮也失败
（达到上限 `ORCA_WORKFLOW_MAX_INTEGRATION_REVIEW=2`），则由人工选择：
照样发布，或者 PARK。

### 创建唯一的 PR（检查退出码）

```bash
( cd "$WT_PATH" && git push -u origin feature/add-user-prefs )

PR_URL=$(gh pr create \
  --base main \
  --head feature/add-user-prefs \
  --title "feat: user preferences (API + settings UI)" \
  --body "$(cat <<'EOF'
## Summary
- **sub-1 prefs-api** — POST/GET `/api/preferences` (JWT-scoped) + idempotent
  `user_preferences` migration. Review: PASS in round 1 (round 0 FAIL:
  non-idempotent migration, fixed).
- **sub-2 prefs-ui** — `/settings/preferences` page (React Query, optimistic
  update, a11y). Review: PASS in round 0.

## Artifacts
- Plan + all review verdicts: orchestration history `wf_20260727_001`
- Tests (run in the feature worktree after rebase): 42 passed, 0 failed

## Integration review
PASS in round 2 of 2 (round 1 FAIL: API error envelope aligned between server
and web types).

_Delivery mode: full — both subtasks shipped._
EOF
)")
if [ $? -ne 0 ] || [ -z "$PR_URL" ]; then
  echo "gh pr create failed — park the feature and surface to the user" >&2
fi
# → https://github.com/org/my-app/pull/118
```

（若有任何子任务被丢弃，PR 正文会带上 `⚠️ degraded` 横幅。）

### 监控直至合并

```bash
while true; do
  PR_JSON=$(gh pr view 118 --json state,mergeStateStatus)
  STATE=$(jq -r '.state' <<<"$PR_JSON")
  case "$STATE" in
    MERGED) break ;;
    CLOSED) echo "PR closed without merge → park the feature"; break ;;
  esac
  # CHANGES_REQUESTED → 由全新的 pr-fix 终端应用反馈、推送，
  # 然后继续监控。
  sleep 60   # 每 60s 轮询一次 —— 此循环内绝不用 gate-create
done
```

人工在 13:05 批准并合并 → `pr.state = "MERGED"`，
`pr.merged_at = "2026-07-27T13:05:41Z"`。进入 Phase 8。

---

## Phase 8：清理

MERGED 路径 —— 删除远端分支、移除唯一的 worktree、关闭保留的终端；
之后协调者只做 fetch（绝不 checkout）：

```bash
git push origin --delete feature/add-user-prefs

orca worktree rm --worktree "id:$WT_ID" --force --json   #（不存在 "worktree remove" 命令）

# orca worktree rm 仅在本地分支已完全合并时才删除它 ——
# 未合并的分支会被留下（已在两次 v2.2.0 冒烟运行中验证）。
# 显式删除以覆盖两种情况；用 -D 而非 -d（squash 合并的 PR，
# 其本地 tip 不是 main 的祖先）；报 "not found" 只说明 orca 已经删过了。
git branch -D feature/add-user-prefs 2>/dev/null || true

orca terminal close --terminal term_s1e1 --json   # sub-1 的 keep_terminal
orca terminal close --terminal term_s2e0 --json   # sub-2 的 keep_terminal
orca terminal close --terminal term_irf  --json   # 合并前总体 Review 的修复终端

git fetch origin    # 协调者此后唯一的 git 操作 —— 绝不 git checkout
```

向 `.orca/workflow-history.jsonl` 追加**一条**历史记录，原子写入
（在 tmp 文件中构建新文件，然后 `mv` —— 绝不对 JSON 用 `>>`）：

```bash
LINE=$(jq -nc '{
  workflow_id: "wf_20260727_001", feature_slug: "add-user-prefs",
  branch: "feature/add-user-prefs",
  pr_url: "https://github.com/org/my-app/pull/118", pr_state: "MERGED",
  delivery_mode: "full", duration_min: 156,
  timestamp: "2026-07-27T13:06:20Z"}')
TMP=$(mktemp .orca/workflow-history.jsonl.XXXXXX)
{ [ -f .orca/workflow-history.jsonl ] && cat .orca/workflow-history.jsonl; \
  printf '%s\n' "$LINE"; } > "$TMP"
mv "$TMP" .orca/workflow-history.jsonl
```

最终状态更新（jq 原子写入）与最终状态：

```bash
jq '
    .current_phase = "CLEANING" | .current_state = "DONE"
  | .delivery_mode = "full"
  | .pr.state = "MERGED" | .pr.merged_at = "2026-07-27T13:05:41Z"
  | .integration_review = {rounds: 2, verdict: "PASS"}
  | .phases.CLEANING = {completed_at: "2026-07-27T13:06:20Z"}
' .orca/workflow-state.json > .orca/workflow-state.json.tmp \
  && mv .orca/workflow-state.json.tmp .orca/workflow-state.json
```

```json
{
  "workflow_id": "wf_20260727_001",
  "version": "2.2.0",
  "started_at": "2026-07-27T10:30:12Z",
  "current_phase": "CLEANING",
  "current_state": "DONE",
  "termination_reason": null,
  "delivery_mode": "full",
  "feature_slug": "add-user-prefs",
  "worktree": {
    "id": "wt_7f3a2c",
    "path": "/Users/dev/worktrees/add-user-prefs",
    "branch_name": "feature/add-user-prefs",
    "base_branch": "origin/main"
  },
  "pr": {
    "url": "https://github.com/org/my-app/pull/118",
    "state": "MERGED",
    "merged_at": "2026-07-27T13:05:41Z"
  },
  "phases": {
    "GATHERING": { "completed_at": "2026-07-27T10:36:00Z", "rounds": 1 },
    "PLANNING": { "completed_at": "2026-07-27T10:47:00Z", "review_rounds": 1, "verdict": "PASS" },
    "CONFIRMING": { "completed_at": "2026-07-27T10:49:00Z", "rounds": 1, "decision": "approve" },
    "DISPATCHING": { "completed_at": "2026-07-27T10:52:00Z", "waves": 2 },
    "EXECUTING": { "completed_at": "2026-07-27T11:58:00Z", "passed": 2, "failed": 0 },
    "DECIDING": { "completed_at": "2026-07-27T11:59:00Z", "outcome": "all_pass" },
    "MERGING": { "completed_at": "2026-07-27T13:05:41Z", "rebase": "clean", "tests": "42 passed, 0 failed", "pr_url": "https://github.com/org/my-app/pull/118" },
    "CLEANING": { "completed_at": "2026-07-27T13:06:20Z" }
  },
  "tasks": {
    "plan": { "task_id": "task_plan01", "review_task_id": "task_prev01", "verdict": "PASS", "review_rounds": 1 },
    "subtasks": [
      { "id": "sub-1", "logical_id": "prefs-api", "status": "completed", "verdict": "PASS", "review_rounds": 2, "keep_terminal": "term_s1e1" },
      { "id": "sub-2", "logical_id": "prefs-ui", "status": "completed", "verdict": "PASS", "review_rounds": 1, "keep_terminal": "term_s2e0" }
    ]
  },
  "integration_review": { "rounds": 2, "verdict": "PASS" },
  "decisions": [
    { "phase": "CONFIRMING", "decision": "approve", "at": "2026-07-27T10:49:00Z" },
    { "phase": "DECIDING", "decision": "proceed_to_merge", "at": "2026-07-27T11:59:00Z" }
  ],
  "retry_counts": { "global_retries_used": 0 },
  "errors": []
}
```

（Phase 5 中每个子任务的完整 `owns`/`base_sha`/`terminals[]` 记录仍在
文件里；此处为可读性做了删减。）

### 通知

```
协调者 → 用户（原生渠道）：
  "🎉 用户偏好设置已发布。
   - PR #118 已 MERGED 进 main（合并前总体 Review PASS，第 2 轮，共 2 轮）
   - 分支 feature/add-user-prefs 已删除；worktree wt_7f3a2c 已移除；
     worker 终端已关闭
   - 历史已追加到 .orca/workflow-history.jsonl
   没有挂起的项；交付模式：full。"
```

---

## 本次运行的指标

| 指标 | 数值 |
|--------|-------|
| 总墙钟时间 | 约 2 小时 36 分钟（10:30 → 13:06） |
| 澄清轮数 | 1（≤5） |
| 计划审查轮数 | 1（≤3） |
| 人工升级次数 | 0（≤2） |
| 用户确认轮数 | 1（≤3） |
| 子任务通过率 | 2/2（100%） |
| 各子任务审查轮数 | sub-1 = 2，sub-2 = 1 |
| 已用子任务重试 | sub-1 = 3 次中用 1 次，sub-2 = 3 次中用 0 次 |
| 合并前总体 Review 轮数 | 2（≤2） |
| 全局重试 | 0（≤2） |
| 自动修复尝试 | 0（≤2） |
| 兜底尝试 | 0 |
| 拉起终端数 | 11 |
| worktree / 分支 / PR 数 | 1 / 1 / 1 |
| 交付模式 | full |

---

## 失败场景附栏：sub-2 耗尽重试

反事实假设：sub-2 的交叉审查持续失败 —— 「乐观更新在回滚时被还原」
一直拖到第 3 轮（轮次 `0..3` = 1 次初始尝试 + 3 次重试 =
`ORCA_WORKFLOW_MAX_SUB_RETRY`）。最后一轮审查之后，协调者把 `sub-2`
标记为 verdict=FAIL。**兄弟子任务不受影响** —— sub-1 的 PASS 依然
有效。在 Phase 6，协调者通过**原生渠道**（而非 `gate-create`）把决策
呈现给用户：

```
协调者 → 用户（原生渠道）：
  "⚠️ 1/2 子任务失败：
   - sub-2（prefs-ui）：4 轮（0..3）后审查仍未通过。
     最近反馈：'乐观更新在回滚时仍被还原。'
   请选择：
   [1] 仅重试失败的子任务
   [2] 降级 —— 丢弃 sub-2，发布 sub-1
   [3] 中止 —— 挂起整个特性"
```

- **[1] 仅重试失败的子任务。** 在
  `global_retries_used < ORCA_WORKFLOW_MAX_GLOBAL_RETRY`（2）时允许，
  **先检查再**自增 → 至多 2 次全局重试。`sub-2` 以全新的 task 链和
  全新终端重新进入轮次循环；`sub-1` 不受影响 —— 它的 verdict 和
  commit 保持有效。
- **[2] 降级。** 协调者**在特性 worktree 内**回滚 sub-2 的 commit
  区间：

  ```bash
  ( cd "$WT_PATH" && git revert --no-edit c3b55d9e..7ea01f42 )
  # c3b55d9e = sub-2.initial_base_sha（第 0 轮分发时的 HEAD）→ 该区间
  # 覆盖 sub-2 的所有轮次；sub-1 的 commit 不受影响。
  ```

  回滚之所以干净，**是因为 owns 互不相交** —— sub-2 的 commit 只触碰
  `web/src/settings/**`，没有其他子任务写过那里。随后以
  `delivery_mode = "degraded"` 继续执行到 Phase 7，并在 PR 正文中加上
  ⚠️ degraded 横幅。如果回滚**不**干净 → 改为挂起整个特性。
- **[3] 中止 → TERMINATED**，整个特性被挂起：写
  `.orca/parked/add-user-prefs.md`（分支、worktree 路径、PR url（如有）、
  原因、恢复步骤），**保留** worktree 和分支以便日后恢复，关闭终端，
  并追加单条历史记录，`pr_state: "PARKED"`。
