# Agent 路由偏好（v2.2.0）

> **⚠️ 单一起源（Single Source of Truth）**：
> 所有 Agent 选型规则集中在本文件。修改偏好只需编辑这里，其他文件（`SKILL.md`、`examples/`）不包含 Agent 选型说明。

---

## ⚠️ 重要：Agent 选择 vs Model 选择

这是**两层独立的配置**：

| 层级 | 控制什么 | 在哪里设置 | 支持？ |
|------|---------|-----------|--------|
| **Agent** | 用哪个 Agent（kimi / claude code / grok / pi） | 创建 worker 终端时决定（`--title` 前缀约定 + 协调者状态记录，详见下文「Worker 终端身份标识」） | ✅ |
| **Model** | Agent 用哪个模型（sonnet / opus / gpt-5.5） | `orca terminal create --command` 时传入 | ✅（但不在 dispatch 层） |

> 🔑 **关键结论**：Orca orchestration 的 `dispatch` 命令**不支持传 model 参数**（也不带 `--spec`，新指令必须新建 task）。Model 必须在**创建 worker 终端时**通过 `--command` 指定。

---

## 总览

```
┌──────────────────────────────────────────────────────────────────┐
│                          任务类型                                 │
├──────────┬──────────────┬──────────────┬────────────┬───────────┤
│   Plan   │ Complex Exec │ General Exec │   Image    │  Review   │
│ (计划生成)│  (复杂执行)   │  (通用执行)   │ (图片生成)  │  (审查)   │
├──────────┼──────────────┼──────────────┼────────────┼───────────┤
│  claude  │     kimi     │     kimi     │    grok    │    pi     │
│ (pi 备选)│  (kimi --auto)│(报错→claude) │            │           │
└──────────┴──────────────┴──────────────┴────────────┴───────────┘
```

---

## 一、Agent 选择（终端创建层）

> 📌 v2.2.0 说明：`orca orchestration dispatch --task <id> --to <handle> --inject --json` 按终端句柄分发，本身不做 Agent 匹配；Agent 身份由创建终端时的 `--title` 前缀和协调者状态记录承载（见「Worker 终端身份标识」）。

### 1. 复杂执行任务 → kimi

**触发条件**：`complexity = "complex"`

**适用场景**：架构设计、大规模重构、系统级变更、技术选型、性能优化

**启动方式**：
```bash
kimi --auto
```

**配置项**：`routing.complex_execution_agent_type = "kimi"`

---

### 2. 通用执行任务 → kimi（优先）/ claude code（报错切换）

**触发条件**：`complexity = "general"` 或未设置

**适用场景**：功能实现、Bug 修复、文档编写、单元测试、小范围重构

| 优先级 | Agent | 说明 |
|--------|-------|------|
| 🥇 第一优先 | **kimi** | 默认通用执行 Agent（与复杂执行同家，`kimi --auto`） |
| 🥈 第二优先 | **claude code** | kimi 报错/不可用时切换（走兜底链，见 §4） |

**配置项**：`routing.execution_agent_type = "kimi"`

---

### 3. 图片生成 → grok

**触发条件**：`complexity = "image"` 或任务含图片/绘图/图表生成

**适用场景**：架构图、流程图、UI 原型、数据可视化、设计素材

**配置项**：`routing.image_agent_type = "grok"`

---

### 4. 报错兜底 → claude code → grok → pi

**触发条件**：通用执行任务（kimi / claude code）失败时

```
kimi 失败 → claude code 重试 → grok 重试 → pi 补上（分析+修复/标记失败）
```

- 不在初始分发时使用，仅在重试耗尽后按兜底链（默认 `claude,grok,pi`）启用
- 每次兜底尝试 = **新建 task + 新建终端**（不复用失败 task，避免 Orca 熔断）
- pi 负责分析前序失败原因，决定是否可修复

---

### 5. 审查任务 → pi

**触发条件**：所有 Review 任务（计划审查、子任务交叉审查、合并前总体 Review）

**配置项**：`routing.review_agent_type = "pi"`

> 🔑 **跨 Agent 规则**：审查 Agent 必须与实现 Agent 不同家（review agent ≠ implementation agent）。审查在**全新终端**上进行，只读审查子任务 `owns` 范围内 `<base_sha>..HEAD` 的变更。
>
> 📌 **合并前总体 Review（integration review，v2.2.0 新增）**复用 `review_agent_type`（默认 pi），且必须与实现 Agent 不同家。

---

### 6. 计划生成 → claude code（首选）/ pi（备选）

**触发条件**：Phase 2 计划生成任务

| 优先级 | Agent | 说明 |
|--------|-------|------|
| 🥇 第一优先 | **claude code** | 默认计划生成 Agent |
| 🥈 第二优先 | **pi** | claude code 不可用时切换 |

**配置项**：`routing.plan_agent_type = "claude"`

> ⚠️ 若计划生成切到 pi（备选），当轮计划审查不得再用 pi（默认 review agent）——改用 claude code 或 grok，保持「审查 ≠ 实现」的跨 Agent 规则。

---

## 二、Model 选择（terminal 创建层）

> ⚠️ Model 在 `orca terminal create --command` 时指定，**不在 dispatch 时**。

### 各 Agent 的 Model 配置方式

| Agent | 指定 Model 的方式 | 示例 |
|-------|------------------|------|
| **kimi** | `kimi --auto`（自带模型选择） | `orca terminal create --worktree id:<worktreeId> --command "kimi --auto" --json` |
| **claude code** | 通过 Claude Code 自身配置 | `orca terminal create --worktree id:<worktreeId> --command "claude" --json`（模型由 Claude Code 配置文件控制） |
| **grok** | 通过 Grok CLI 参数 | `orca terminal create --worktree id:<worktreeId> --command "grok" --json` |
| **pi** | 自有模型，无外部选择 | `orca terminal create --worktree id:<worktreeId> --command "pi" --json` |

### 创建带 Model 的 Worker 终端

```bash
# 通用执行 Worker（claude code，用 sonnet）
orca terminal create \
  --worktree id:<worktreeId> \
  --title "[execution:claude] sub-1 r0" \
  --command "claude" \
  --json

# 如果你想用特定版本的 codex：
orca terminal create \
  --worktree id:<worktreeId> \
  --title "[execution:codex] sub-2 r0" \
  --command 'codex --model gpt-5.5 -c model_reasoning_effort="xhigh"' \
  --json

# 复杂任务 Worker（kimi）
orca terminal create \
  --worktree id:<worktreeId> \
  --title "[execution:kimi] sub-3 r0" \
  --command "kimi --auto" \
  --json
```

### Worker 终端身份标识

`orca terminal create` **没有 `--tags` 参数**，终端对象也没有 tags / type 字段。Agent 身份通过下面两个机制承载，协调者据此把任务分发到正确的终端：

1. **`--title` 前缀约定**：`[<role>:<agent>] <子任务> r<轮次>`，例如：
   ```
   [execution:claude] sub-1 r0        # 通用执行，第 0 轮
   [review:pi] sub-1 r0               # 交叉审查，第 0 轮
   [fix:claude] sub-1 r1              # 修复，第 1 轮
   [fallback:grok] sub-1 r1           # 兜底重试
   [autofix:claude] rebase attempt-1  # rebase 冲突自动修复
   [pr-fix:claude] pr changes         # PR Changes Requested 修复
   [integration-review:pi] feature r0 # 合并前总体 Review
   ```
   role 取值：`execution | review | fix | fallback | autofix | pr-fix | integration-review`。

2. **协调者状态文件记录**：在 `.orca/workflow-state.json` 的 `subtasks[].terminals[]` 中登记每个终端的 `{handle, role, round, agent_type, status, verdict, spawned_at, closed_at}`。分发时（`orca orchestration dispatch --to <handle>`）按句柄查表，不依赖终端自带元数据。

> 📌 每轮执行 / 修复 / 审查都使用**全新终端 + 全新 task**（task 之间用 `--parent` 串联），绝不重复 dispatch 同一个 task —— Orca 会对连续失败 3 次的 task 触发熔断。

---

## 优先级速查

| 角色 | Agent 首选 | Agent 备选 | Agent 兜底 | Model |
|------|-----------|-----------|-----------|-------|
| **Complex Exec** | kimi | — | — | auto（kimi 自带） |
| **General Exec** | kimi | claude code | grok → pi | auto（kimi 自带） |
| **Image** | grok | — | — | 默认 |
| **Review**（含 integration review） | pi | — | — | 自有模型 |
| **Plan** | claude code | pi | — | 由 Agent 配置决定 |

---

## 子任务声明示例

> 📌 v2.2.0 起每个子任务必须声明 `owns`（文件/目录所有权 glob）。同一波次（并行）子任务的 `owns` 必须互不相交，由计划审查校验。

### 复杂任务（走 kimi）

```json
{
  "id": "sub-arch",
  "title": "微服务拆分方案设计",
  "complexity": "complex",
  "deps": [],
  "owns": ["docs/arch/**"],
  "spec": "设计将单体应用拆分为 3 个微服务的架构方案..."
}
```

### 通用任务（走 kimi）

```json
{
  "id": "sub-feat",
  "title": "实现用户登录接口",
  "complexity": "general",
  "deps": ["sub-arch"],
  "owns": ["server/**"],
  "spec": "实现 POST /api/auth/login 接口..."
}
```

### 图片生成（走 grok）

```json
{
  "id": "sub-img",
  "title": "生成系统架构图",
  "complexity": "image",
  "deps": ["sub-arch"],
  "owns": ["docs/diagrams/**"],
  "spec": "根据微服务拆分方案，生成系统架构图（Mermaid / SVG）..."
}
```

---

## 环境变量覆盖

所有偏好均可通过环境变量在运行时覆盖（对应 SKILL.md §4.1 中 `routing.*_agent_type` 的冷启动默认值；SKILL.md §3.3 仅保留指向本文件的指针）：

```bash
# === Agent 选择 ===

# 计划生成 Agent（默认 claude，不可用时切 pi）
export ORCA_WORKFLOW_PLAN_AGENT="claude"

# 复杂执行任务
export ORCA_WORKFLOW_COMPLEX_EXECUTION_AGENT="kimi"

# 通用执行任务（默认 kimi，报错切 claude）
export ORCA_WORKFLOW_EXECUTION_AGENT="kimi"

# 图片生成
export ORCA_WORKFLOW_IMAGE_AGENT="grok"

# 审查 Agent（含 integration review）
export ORCA_WORKFLOW_REVIEW_AGENT="pi"

# 兜底 Agent
export ORCA_WORKFLOW_FALLBACK_AGENT="pi"

# 通用任务失败后的重试链（逗号分隔，优先级从高到低）
export ORCA_WORKFLOW_FALLBACK_CHAIN="claude,grok,pi"

# === Model 选择（在创建 terminal 时通过 --command 传入，不在这里） ===
# 参见上方「二、Model 选择」章节
```

> 📌 修改偏好时，更新上方对应章节即可，无需改动其他文件。
