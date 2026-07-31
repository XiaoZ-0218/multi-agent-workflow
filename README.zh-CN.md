# 多智能体编排工作流

> **面向 Orca IDE 的生产级多智能体流水线** —— 把用户需求从需求澄清一路推进到合并完成的 PR，支持波次并行执行、跨 Agent 交叉审查、人工兜底介入，以及完整的审计追踪。

[English](./README.md) | **简体中文**

[![Skill Version](https://img.shields.io/badge/skill-v2.2.2-blue)](./SKILL.md)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![Orca](https://img.shields.io/badge/runtime-Orca%20IDE-orange)](https://orca.app)

---

## 功能概述

本技能实现了一套**完整的 8 阶段工作流**，协调多个 AI Agent 交付复杂的软件任务：

```
用户请求 → 澄清 → 计划 → 审查 → 确认 → 执行（波次并行）→ 决策 → Rebase + 测试 + 合并前总体 Review → PR → 清理
```

### 核心特性

- **🔄 全生命周期**：需求 → 计划 → 执行 → 审查 → 合并前总体 Review → 合并 → 清理
- **🌳 每个 feature 一个 worktree（v2.2.0）**：整个 feature 都活在基于 `origin/main` 的单一 `feature/<slug>` 分支、单一 worktree 中。协调者始终不离开 `main`（从不执行 `git checkout`），一次运行最终恰好产出**一个 PR**
- **🧩 基于 owns 的并行安全（v2.2.0）**：每个子任务声明自己 `owns` 的文件/目录；同一波次的子任务必须**所有权互不相交**，由计划审查校验。并行写的安全性来自互不相交的写集合，而非文件系统隔离
- **🌊 波次分发（v2.2.0）**：依赖关系映射为串行的波次 —— 子任务只有在全部父任务通过后才被分发，并能在共享 worktree 中自然看到父任务已 commit 的代码
- **🆕 每轮全新 Agent**：实现、交叉审查、修复各自在**全新终端**中运行 —— 不复用 Agent 上下文，不带入前序偏差
- **🧑‍⚖️ 限定范围的跨 Agent 交叉审查**：审查使用与实现（`claude`/`kimi`）不同家的 Agent（`pi`），见 `docs/agent-routing.md`；每次审查限定在该子任务自身 `owns` 范围内的 commit 区间（`base_sha..HEAD`）
- **🔬 合并前总体 Review（v2.2.0）**：在创建 PR 之前，由一个全新审查 Agent 审计*整个* feature —— 计划、各子任务 verdict、测试结果、相对 `origin/main` 的完整 diff
- **🛡️ 硬性循环上限**：每个循环都有最大迭代次数 —— 不存在无限重试
- **👤 人工介入**：在计划审查、决策、合并边界处升级给人工；**PR 只能由人工合并**
- **📉 降级或挂起**：失败的子任务会在 feature worktree 中被外科手术式地 revert 其 commit 区间（因 `owns` 互不相交所以干净），产出降级版本；若 revert 不干净，则整个 feature 挂起并留下恢复清单
- **🔍 完整审计追踪**：每个决策、终端创建、verdict、PR 状态变迁都记录到 `.orca/workflow-state.json`
- **🔒 单一 PR、仅人工合并**：不做直接的 `git merge` —— 每个 feature 一个 PR，由协调者监控、由人工合并

---

## 快速上手

### 前置条件

- [Orca IDE](https://orca.app) 正在运行
- Git ≥ 2.30
- GitHub CLI（`gh`）≥ 2.0
- `jq` ≥ 1.6

### 安装

```bash
# 克隆到你的工作区
cd ~/workspace
git clone https://github.com/your-org/multi-agent-workflow.git

# 或者把 SKILL.md 复制到你的项目中
cp SKILL.md /path/to/your/project/
```

### 使用方法

```bash
# 1. 进入你的项目检出目录 —— 必须由 Orca 管理。
#    协调者在整个运行期间都停留在 main 分支上。
cd /path/to/project

# 2. 运行前置检查
/path/to/multi-agent-workflow/scripts/check-prerequisites.sh

# 3. 在 Orca 中打开该检出目录，在主检出目录的聊天中
#    向协调者 agent 描述任务，例如：
#    “给 API 添加一个 /health 端点，并附带测试。”
```

技能会自行驱动每一条 `orca` 命令 —— worktree 创建、波次分发、审查、PR —— 并在每个人工检查点提示你，从需求收集开始。

> 补充说明：Orca 原生的 `orca orchestration run --spec <text>` 协调者循环是一个可选的替代入口，但上文这种由聊天驱动的流程是推荐路径。

---

## 架构（v2.2.0）

```
┌──────────────────────────────────────────────────────────────────┐
│              协调者（本 Agent —— 始终在 main 分支）              │
│  阶段 1 收集 → 阶段 2 计划+审查 → 阶段 3 确认                    │
│  阶段 4：创建唯一的 feature worktree（feature/<slug> 基于        │
│        origin/main）→ 分解 DAG → 分发波次 0                      │
│                              │                                   │
│        ┌─────────────────────▼────────────────────────┐          │
│        │        feature worktree（共享）              │          │
│        │  波次 0：sub-A（owns: api/**）∥ sub-B（ui/**）│         │
│        │  波次 1：sub-C  ← 依赖 PASS 后运行           │          │
│        │  每个子任务、每一轮都用全新终端：            │          │
│        │    执行（小步 commit）→ 交叉审查             │          │
│        │    （base_sha..HEAD，owns 内）→ 修复 → …     │          │
│        └─────────────────────┬────────────────────────┘          │
│  阶段 6 ← 收集 verdict：重试 / 降级 / 挂起                       │
│  阶段 7：rebase origin/main → 测试 → 合并前总体                  │
│           Review（全新 agent，整 feature diff）→ 唯一 PR         │
│           → 人工审查并合并 PR                                    │
│  阶段 8：删除分支、移除 worktree、关闭终端                       │
│           （或挂起：.orca/parked/<feature-slug>.md）             │
└──────────────────────────────────────────────────────────────────┘
```

### 状态机

共 8 个阶段，`DISPATCHING` / `EXECUTING` 下挂按波次划分的子任务子图，`MERGING` / `CLEANING` 下挂整个 feature 的子图。终止出口：计划不收敛、用户拒绝/中止、feature 失败（PARKED 是可恢复的）。

完整的 Mermaid 图见 [`docs/workflow.md`](./docs/workflow.md)。

---

## 各阶段

| # | 阶段 | 做了什么 | 关键命令 |
|---|-------|-------------|-------------|
| 1 | **需求收集** | 通过协调者的原生通道与用户澄清需求（≤5 轮） | 原生用户交互 |
| 2 | **计划生成** | 生成技术计划；一个独立的审查任务通过 `worker_done` 返回 verdict（最多 3 轮 + 2 次人工升级） | `task-create` + `dispatch --inject` |
| 3 | **计划确认** | 用户批准计划（最多 3 轮；Abort 立即停止） | 原生用户交互 |
| 4 | **分发** | 基于 `origin/main` 创建唯一的 feature worktree + 分支，从 DAG 计算波次，分发波次 0 | `worktree create --base-branch origin/main` + `terminal create` + `task-create` + `dispatch --inject` |
| 5 | **执行** | 每轮使用全新终端：执行/修复 agent 小步 commit；交叉审查限定在子任务 `owns` 范围内的 `base_sha..HEAD` | `terminal create` + `dispatch --inject` + `check --wait` |
| 6 | **决策** | 收集 verdict；用户选择重试（最多 2 次）/ 降级（revert 失败的 commit 区间）/ 中止 | `task-list` + 原生用户交互 |
| 7 | **合并** | Rebase 到 `origin/main`（自动修复冲突 ≤2 次）、跑测试、由全新 agent 做**合并前总体 Review**（≤2 轮），然后产出唯一 PR；由人工合并 | `git rebase` + `gh pr create` + `gh pr view` |
| 8 | **清理** | 按 feature 清理：删除分支、移除 worktree、关闭 `keep_terminal`；或写入 `.orca/parked/<feature-slug>.md` | `worktree rm` + `terminal close` |

---

## 配置

所有参数均可通过环境变量调整：

```bash
export ORCA_WORKFLOW_MAX_REVIEW_ROUNDS=3       # 计划审查重试次数
export ORCA_WORKFLOW_MAX_ESCALATE=2            # 终止前的人工升级次数
export ORCA_WORKFLOW_MAX_USER_CONFIRM=3        # 用户确认重试次数
export ORCA_WORKFLOW_MAX_SUB_RETRY=3           # 每个子任务的执行/修复重试次数
export ORCA_WORKFLOW_MAX_GLOBAL_RETRY=2        # 失败批次的重试轮数
export ORCA_WORKFLOW_MAX_AUTOFIX=2             # rebase 期间自动解决冲突的尝试次数
export ORCA_WORKFLOW_MAX_INTEGRATION_REVIEW=2  # 合并前总体 Review 轮数（v2.2.0 新增）
export ORCA_WORKFLOW_STRICT_PREREQ=false       # 为 true 时将前置条件缺失视为致命错误
export ORCA_WORKFLOW_DRY_RUN=false             # 仅计划模式，不做分发
```

完整配置参考见 [`SKILL.md`](./SKILL.md)。

---

## 项目结构

```
multi-agent-workflow/
├── SKILL.md                          # 技能定义（Orca 加载的就是它）
├── README.md                         # English README
├── README.zh-CN.md                   # 本文件
├── CHANGELOG.md                      # 版本历史
├── LICENSE                           # MIT 许可证
├── docs/
│   ├── workflow.md                   # Mermaid 流程图（完整状态图）
│   └── agent-routing.md              # Agent 路由的单一起源
├── references/
│   ├── phase-1-gathering.md          # Phase 1 需求收集完整流程（从 SKILL.md §5 拆出）
│   ├── phase-2-planning.md           # Phase 2 计划生成与评审完整流程（从 SKILL.md §6 拆出）
│   ├── phase-3-confirming.md         # Phase 3 用户确认完整流程（从 SKILL.md §7 拆出）
│   ├── phase-4-dispatching.md        # Phase 4 任务分解与分发完整流程（从 SKILL.md §8 拆出）
│   ├── phase-5-executing.md          # Phase 5 并行执行与子评审完整流程（从 SKILL.md §9 拆出）
│   ├── phase-6-deciding.md           # Phase 6 结果汇总与决策完整流程（从 SKILL.md §10 拆出）
│   ├── phase-7-merging.md            # Phase 7 合并与 PR 完整流程（从 SKILL.md §11 拆出）
│   ├── phase-8-cleaning.md           # Phase 8 清理与归档完整流程（从 SKILL.md §12 拆出）
│   ├── observability.md              # 可观测性与日志（从 SKILL.md §13 拆出：状态文件示例、日志级别、指标）
│   ├── runbooks.md                   # 测试验证与运维手册（从 SKILL.md §16–§17 拆出）
│   └── api-reference.md              # Orca CLI 命令参考（从 SKILL.md §18 拆出）
├── examples/
│   └── basic-workflow.md             # 一次完整运行的带注释走读
├── .orca/
│   ├── workflow-config.json          # 项目级默认配置
│   └── workflow-state.schema.json    # 状态文件的 JSON Schema
└── scripts/
    └── check-prerequisites.sh        # 前置检查脚本
```

---

## 文档

| 文档 | 说明 |
|----------|-------------|
| [`SKILL.md`](./SKILL.md) | 完整技能定义（API 参考等已拆至 `references/`） |
| [`docs/workflow.md`](./docs/workflow.md) | 完整的 Mermaid 状态图与状态流转表 |
| [`references/`](./references) | 按需查阅的参考文档：各阶段完整流程（phase-1..8）、可观测性、测试/运维手册、API 命令参考 |
| [`examples/basic-workflow.md`](./examples/basic-workflow.md) | 分步骤走读 |

---

## 故障恢复

### 崩溃后

```bash
# 加载已保存的状态
cat .orca/workflow-state.json | jq '.current_phase'

# 根据所处阶段恢复
# （详细恢复步骤见 references/runbooks.md）
```

### 挂起后

```bash
# 每个挂起的 feature 会留下一份清单
ls .orca/parked/

# 阅读恢复说明
cat .orca/parked/<feature-slug>.md
```

---

## 许可证

MIT © 2026 —— 详见 [LICENSE](./LICENSE)。
