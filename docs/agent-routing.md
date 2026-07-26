# Agent 路由偏好

> **⚠️ 单一起源（Single Source of Truth）**：
> 所有 Agent 选型规则集中在本文件。修改偏好只需编辑这里，其他文件（`SKILL.md`、`examples/`）不包含 Agent 选型说明。

---

## ⚠️ 重要：Agent 选择 vs Model 选择

这是**两层独立的配置**：

| 层级 | 控制什么 | 在哪里设置 | 支持？ |
|------|---------|-----------|--------|
| **Agent** | 用哪个 Agent（kimi / claude code / grok / pi） | `orca orchestration dispatch` 时通过 worker 标签匹配 | ✅ |
| **Model** | Agent 用哪个模型（sonnet / opus / gpt-5.5） | `orca terminal create --command` 时传入 | ✅（但不在 dispatch 层） |

> 🔑 **关键结论**：Orca orchestration 的 `dispatch` 命令**不支持传 model 参数**。Model 必须在**创建 worker 终端时**通过 `--command` 指定。

---

## 总览

```
┌──────────────────────────────────────────────────────────────────┐
│                          任务类型                                 │
├──────────┬──────────────┬──────────────┬────────────┬───────────┤
│   Plan   │ Complex Exec │ General Exec │   Image    │  Review   │
│ (计划生成)│  (复杂执行)   │  (通用执行)   │ (图片生成)  │  (审查)   │
├──────────┼──────────────┼──────────────┼────────────┼───────────┤
│   Plan   │     kimi     │  claude code │    grok    │    pi     │
│          │  (kimi --auto)│   (优先)     │            │           │
└──────────┴──────────────┴──────────────┴────────────┴───────────┘
```

---

## 一、Agent 选择（dispatch 层）

### 1. 复杂执行任务 → kimi

**触发条件**：`complexity = "complex"`

**适用场景**：架构设计、大规模重构、系统级变更、技术选型、性能优化

**启动方式**：
```bash
kimi --auto
```

**配置项**：`routing.complex_execution_agent_type = "kimi"`

---

### 2. 通用执行任务 → claude code（优先）/ grok（次选）

**触发条件**：`complexity = "general"` 或未设置

**适用场景**：功能实现、Bug 修复、文档编写、单元测试、小范围重构

| 优先级 | Agent | 说明 |
|--------|-------|------|
| 🥇 第一优先 | **claude code** | 默认通用执行 Agent |
| 🥈 第二优先 | **grok** | claude code 不可用时切换 |

**配置项**：`routing.execution_agent_type = "claude"`

---

### 3. 图片生成 → grok

**触发条件**：`task_type = "image"` 或任务含图片/绘图/图表生成

**适用场景**：架构图、流程图、UI 原型、数据可视化、设计素材

**配置项**：`routing.image_agent_type = "grok"`

---

### 4. 报错兜底 → pi

**触发条件**：通用执行任务（claude code / grok）失败时

```
claude code 失败 → grok 重试 → pi 补上（分析+修复/标记失败）
```

- 不在初始分发时使用，仅在重试耗尽后启用
- pi 负责分析前序失败原因，决定是否可修复

---

### 5. 审查任务 → pi

**触发条件**：所有 Review Gate（计划审查、代码审查、自审查、PR 审查）

**配置项**：`routing.review_agent_type = "pi"`

---

### 6. 计划生成 → Plan

**触发条件**：Phase 2 计划生成任务

**配置项**：`routing.plan_agent_type = "Plan"`

---

## 二、Model 选择（terminal 创建层）

> ⚠️ Model 在 `orca terminal create --command` 时指定，**不在 dispatch 时**。

### 各 Agent 的 Model 配置方式

| Agent | 指定 Model 的方式 | 示例 |
|-------|------------------|------|
| **kimi** | `kimi --auto`（自带模型选择） | `orca terminal create --command "kimi --auto"` |
| **claude code** | 通过 Claude Code 自身配置 | `orca terminal create --command "claude"`（模型由 Claude Code 配置文件控制） |
| **grok** | 通过 Grok CLI 参数 | `orca terminal create --command "grok"` |
| **pi** | 自有模型，无外部选择 | `orca terminal create --command "pi"` |
| **Plan** | 跟随 default_model | 由 Orca 全局配置决定 |

### 创建带 Model 的 Worker 终端

```bash
# 通用执行 Worker（claude code，用 sonnet）
orca terminal create \
  --worktree active \
  --title "Worker - Claude Code" \
  --command "claude" \
  --json

# 如果你想用特定版本的 codex：
orca terminal create \
  --worktree active \
  --title "Worker - Codex GPT-5.5" \
  --command 'codex --model gpt-5.5 -c model_reasoning_effort="xhigh"' \
  --json

# 复杂任务 Worker（kimi）
orca terminal create \
  --worktree active \
  --title "Worker - Kimi" \
  --command "kimi --auto" \
  --json
```

### 打标签（让 select_worker 能匹配到）

创建终端后，需要在 Orca 中给终端打上对应标签，`select_worker()` 才能匹配：

```
终端标签示例：
  kimi Worker    → 标签: kimi
  Claude Worker  → 标签: claude
  Grok Worker    → 标签: grok
  Pi Worker      → 标签: pi
```

---

## 优先级速查

| 角色 | Agent 首选 | Agent 备选 | Agent 兜底 | Model |
|------|-----------|-----------|-----------|-------|
| **Complex Exec** | kimi | — | — | auto（kimi 自带） |
| **General Exec** | claude code | grok | pi | 由 Agent 配置决定 |
| **Image** | grok | — | — | 默认 |
| **Review** | pi | — | — | 自有模型 |
| **Plan** | Plan | — | — | default_model |

---

## 子任务声明示例

### 复杂任务（走 kimi）

```json
{
  "id": "sub-arch",
  "title": "微服务拆分方案设计",
  "complexity": "complex",
  "deps": [],
  "spec": "设计将单体应用拆分为 3 个微服务的架构方案..."
}
```

### 通用任务（走 claude code）

```json
{
  "id": "sub-feat",
  "title": "实现用户登录接口",
  "complexity": "general",
  "deps": ["sub-arch"],
  "spec": "实现 POST /api/auth/login 接口..."
}
```

### 图片生成（走 grok）

```json
{
  "id": "sub-img",
  "title": "生成系统架构图",
  "task_type": "image",
  "deps": ["sub-arch"],
  "spec": "根据微服务拆分方案，生成系统架构图（Mermaid / SVG）..."
}
```

---

## 环境变量覆盖

所有偏好均可通过环境变量在运行时覆盖（与 `SKILL.md` routing 配置一一对应）：

```bash
# === Agent 选择 ===

# 复杂执行任务
export ORCA_WORKFLOW_COMPLEX_EXECUTION_AGENT="kimi"

# 通用执行任务（默认 claude，可改为 grok）
export ORCA_WORKFLOW_EXECUTION_AGENT="claude"

# 图片生成
export ORCA_WORKFLOW_IMAGE_AGENT="grok"

# 审查 Agent
export ORCA_WORKFLOW_REVIEW_AGENT="pi"

# 兜底 Agent
export ORCA_WORKFLOW_FALLBACK_AGENT="pi"

# 通用任务失败后的重试链（逗号分隔，优先级从高到低）
export ORCA_WORKFLOW_FALLBACK_CHAIN="grok,pi"

# === Model 选择（在创建 terminal 时通过 --command 传入，不在这里） ===
# 参见上方「二、Model 选择」章节
```

> 📌 修改偏好时，更新上方对应章节即可，无需改动其他文件。

