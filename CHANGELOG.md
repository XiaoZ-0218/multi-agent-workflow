# 更新日志

**multi-agent-workflow** 技能的所有重要变更都记录在本文件中。

格式基于 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)，
本项目遵循 [语义化版本](https://semver.org/spec/v2.0.0.html)。

## [2.2.2] — 2026-07-31

### 变更
- **SKILL.md 结构瘦身（纯文档重构，无行为变更）**：§13 Observability &
  Logging 拆至 `references/observability.md`；§16 Testing & Validation 与
  §17 Operational Runbooks 拆至 `references/runbooks.md`；§18 API Command
  Reference 拆至 `references/api-reference.md`。内容原样搬运，SKILL.md 原位
  保留指向新文件的指针，全仓库相关交叉引用同步重接线。
- **阶段章节拆分**：§5–§12 八个阶段章节同样拆分为
  `references/phase-1-gathering.md` … `references/phase-8-cleaning.md`
  （内容逐字搬运）；SKILL.md 中各阶段节标题保持不变（TOC 锚点不受影响），
  正文仅保留 3–6 条骨架要点与指向对应 `references/phase-*.md` 的指针。
- **状态机去重**：SKILL.md §2 的 State Transition Table 与
  `docs/workflow.md` 的状态流转表重复，SKILL.md 侧表格已删除并改为指针；
  仅存在于 SKILL.md 侧的转移行（CONFIRMING 强制用户决策、任意状态致命错误
  终止、父任务失败的子任务跳过）已合并进 `docs/workflow.md`。
- **路由环境变量去重**：SKILL.md §3.3 的 Agent routing 环境变量
  （`ORCA_WORKFLOW_*_AGENT`、fallback chain）与 `docs/agent-routing.md`
  （单一起源）重复，已删除，仅保留指针；limits/paths/behaviour 变量留在
  原处。
- **版本对齐**：SKILL.md frontmatter 与 README badge 由 2.2.0 更新为
  2.2.2（2.2.1 条目此前未同步版本号，属历史漂移，一并修正）。
- **SKILL.md 最后一轮非操作性内容精简（纯文档重构，无行为变更）**：
  删除 §1 的 v2.2.0→v2.1.0 迁移对照表（其独有信息——移除的环境变量
  清单——已补入本文件 [2.2.0] 条目）；§2 ASCII 状态图替换为单行流程
  加 `docs/workflow.md` 指针（文字说明保留）；§3.1 内联预检 shell 块
  替换为 `scripts/check-prerequisites.sh` 指针（脚本检查项为其超集，
  无检查项丢失）；§3.3 环境变量并入 §4.1（每个变量仅一处定义），§3
  保留一行指针；删除整节目录（TOC）。所有运行规则、循环上限与禁令
  均未改动。

## [2.2.1] — 2026-07-27

### 变更
- **通用执行路由**：默认执行 Agent 现为 **kimi**（原为 claude
  code）；报错时重试切换到 claude code。
  `ORCA_WORKFLOW_EXECUTION_AGENT` 和 `routing.execution_agent_type`
  由 `claude` 改为 `kimi`，`ORCA_WORKFLOW_FALLBACK_CHAIN` 由
  `grok,pi` 改为 `claude,grok,pi`。单一起源：
  `docs/agent-routing.md` §2/§4。
- **计划 Agent 路由**：计划生成（Phase 2）现在路由到
  **claude code**（首选），以 **pi** 为备选，取代 Orca
  内置的 `Plan` Agent。`ORCA_WORKFLOW_PLAN_AGENT` 和冷启动默认的
  `routing.plan_agent_type` 由 `Plan` 改为 `claude`。当备选（pi）
  生效时，该轮计划审查必须避开 pi（改用 claude code 或 grok），
  以保持「审查 ≠ 实现」的跨 Agent 规则。单一起源：
  `docs/agent-routing.md` §6。

### 新增
- **每次分发前的 Agent 就绪门禁**：在 `terminal create` 和
  `dispatch --inject` 之间现在必须执行 `orca terminal wait
  --terminal <handle> --for tui-idle --timeout-ms 60000`
  （§6.2、§8.3.3、§9.2、§18.3）。仍在启动中的 Agent CLI 可能丢失或
  乱码注入的 preamble+任务 —— 之后 worker 永远不会上报
  `worker_done`，协调者会卡在检查点上。
- **主动检查点存活探测**：§9.3 的滚动等待循环现在在每次
  `check --wait` 超时后检查 `dispatch-show` 的
  `last_heartbeat_at`，并结合 `terminal read` /
  `terminal wait --for tui-idle`。新鲜的心跳意味着「活着，
  仍在工作」（绝不因静默就关闭/重启）；陈旧的心跳加空闲终端意味着
  「已完成但忘记上报」——立即收取结果，而不是再多等几轮。

### 修复
- **事件迟到导致的波次停滞**：`check --wait` 每次只返回一条
  消息；协调者必须在处理繁重的本地工作之前立即重新检查，以排空
  排队的完成事件（§9.3）。
- **重复完成**：合法的 `worker_done` 会自动将 task+dispatch
  标记为已完成；手动 `task-update` 现在仅在文档中作为恢复/覆盖手段
  （§18.1）。
- **Worker 上报顺序**：§8.5 规则 5 要求先发送 `worker_done`
  再写长报告，并且工作期间每 5 分钟发送一次心跳（按 Orca 注入的
  preamble）。

## [2.2.0] — 2026-07-27

### 变更（破坏性）
- **每个 feature 一个 worktree**：v2.1.0 的按子任务建
  worktree 已移除。一次运行现在基于 `origin/main` 只创建一个
  `feature/<slug>` 分支 + worktree；所有子任务在其中执行，最终
  合并为**一个 PR**。协调者在整个运行期间停留在主分支上 —— 它
  从不运行 `git checkout`，在自己的 checkout 中仅有的 git 操作是
  `git fetch origin`（可选 `git pull --ff-only`）。
- **移除堆叠分支、draft PR 和按子任务的 PR**：§11.8 堆叠 PR
  rebase 钩子、`branch_strategy` 配置块以及分支/worktree 路径模板
  全部删除。依赖关系现在意味着**按波次串行分发**：子任务只有在
  所有父任务 verdict=PASS 之后才会被分发，并且它能在共享
  worktree 中自然看到父任务已提交的代码。
- **降级交付现在更精细**：协调者在 feature worktree 中回滚
  每个失败子任务的 commit 区间（因 `owns` 互不相交而干净）；如果
  回滚不干净，则整个 feature 挂起（parked），而不是交付部分成果。
- **挂起清单更名**：每个挂起的 feature 对应一个
  `.orca/parked/<feature-slug>.md`（原来是每个子任务一个），记录
  分支、worktree 路径、PR URL、原因和恢复步骤。
- **状态文件顶层结构调整**：新增 `feature_slug`、`worktree{}`、
  `pr{}` 和 `integration_review{}` 块；v2.1.0 遗留的聚合字段
  `branch` / `pr_url` 已删除。`current_phase` /
  `current_state` 枚举现在包含 `INIT`，`pr.state` 不再有
  `DRAFT` 取值。
- **移除不再读取的环境变量**：`ORCA_WORKFLOW_BRANCH_STRATEGY`、
  `ORCA_WORKFLOW_BRANCH_TEMPLATE`、`ORCA_WORKFLOW_WORKTREE_PATH_TEMPLATE`、
  `ORCA_WORKFLOW_MAX_TERMINALS_PER_SUBTASK`、
  `ORCA_WORKFLOW_MIN_WORKERS`（每个 feature 一个 worktree 的模型不需要
  分支/路径模板，终端数量也不再做预检）；新增
  `ORCA_WORKFLOW_MAX_INTEGRATION_REVIEW`（默认 2）。
- **移除缩减范围选项**：v2.0.1 Phase 3 的「缩减范围」路径允许
  并行写入协调者的主 checkout，不安全。用户改用 Revise 来缩减范围。

### 新增
- **每个子任务的 `owns` 字段**（文件/目录所有权 glob）。
  并行写入安全性来自互不相交的所有权，而不是文件系统隔离；
  计划审查现在会校验每个子任务都声明了 `owns`，且同一波次子任务的
  `owns` 互不相交。
- **每次分发的 `base_sha` + 限定范围的审查**：协调者在每次
  分发时记录 feature 分支的 HEAD，交叉审查 Agent 只审查子任务
  `owns` 范围内 `<base_sha>..HEAD` 的变更。
- **合并前总体 Review 阶段**（Phase 7）：一个全新的审查 Agent
  在创建 PR 之前审计整个 feature —— 计划、各子任务 verdict、
  测试结果和 `git diff origin/main...HEAD`。受新增的
  `ORCA_WORKFLOW_MAX_INTEGRATION_REVIEW`（默认 2）限制。
- **协调者 checkout 的预检**：
  `scripts/check-prerequisites.sh` 现在会校验
  `orca worktree current`，确保运行永远不会从 Orca 不管理的
  checkout 启动。

### 修复
- **CLI 命令全面更正**为真实的 Orca 命令：
  `worktree create --base-branch`（没有位置路径参数，没有
  `--base`）、`worktree rm`（不存在 "worktree remove"）、
  `terminal close --terminal`（没有 `--handle`）、
  `terminal create` 没有 `--tags`（Agent 身份由标题前缀和协调者的
  状态记录承载）、`dispatch` 没有 `--spec`（新指令必须新建
  task），阻塞等待使用滚动循环中的 `check --wait`。
- **Phase 3 Abort 差一错误**：Abort 现在在任意确认轮立即终止，
  而不是多存活一轮。
- **Phase 6 重试差一错误**：全局重试预算在递增之前检查，因此
  `ORCA_WORKFLOW_MAX_GLOBAL_RETRY=2` 最多允许 2 次重试（而不是
  3 次）。
- **PR 监视门禁刷屏**：合并监视现在每 60 秒轮询一次
  `gh pr view --json state,mergeStateStatus`，绝不在轮询循环内调用
  `gate-create`。
- **自动修复成功判定反转**：rebase 自动修复现在只有在 rebase
  真正完成且没有残留 `^UU` 冲突标记时才计为成功（之前判定逻辑
  反了，会让带冲突的工作树通过）。
- **取消 runbook 损坏状态文件**：所有状态文件更新现在使用 jq
  原子写入（先写临时文件再 `mv`）；JSON 永远不用 `>>` 追加。
- **Phase 8 不再 checkout main**：清理在协调者自己的 checkout
  中进行；之后唯一的 git 操作是 `git fetch origin`。
- **安全章节**不再声称 git-worktree 提供文件系统沙箱 ——
  子任务共享一个 worktree，该说法是错误的。
- **Phase 8 现在删除本地 feature 分支**：两次 v2.2.0 冒烟运行
  验证了 `orca worktree rm --force` 会删除 worktree，并且仅在分支
  已完全合并时才删除本地分支 —— 未合并的分支会被留下。清理现在
  在协调者的 checkout 中运行 `git branch -D <branch>` 以覆盖两种
  情况（用 `-D` 而非 `-d`，因为 squash 合并的 PR 的本地顶端不是
  main 的祖先；「not found」表示 orca 已经删掉了它）。
- **`worker_done` verdict 位置**：preamble 契约（§8.5）现在要求
  verdict 同时出现在消息主题和 payload 中 —— 冒烟运行发现：有些
  Agent 只写主题。协调者优先读取 `payload.verdict`，回退到主题
  前缀。
  写入安全性由 `owns` 契约加审查门禁保证。

## [2.1.0] — 2026-07-27

### 变更（对状态文件消费者是破坏性的 —— 在 schema 层面是增量式的）
- **按子任务的 worktree**：Phase 4 为每个子任务创建一个
  `feature/<wf>/<sub>-<ts>` 分支 + worktree。v2.0.x 为整个工作流
  创建的单个共享 worktree 已移除。状态 schema 新增
  `tasks.subtasks[*].worktree_path` / `branch_name` / `base_branch`。
- **依赖关系的堆叠分支**：在 `branch_strategy.mode =
  "stacked"`（默认）下，带依赖的子任务基于其父任务的分支而不是
  `main`。Phase 7 新增的 **§11.8 堆叠 PR Rebase 钩子**在父任务
  合并后把依赖方 PR rebase 到 `main` 上并将其从 draft 转为就绪
  （`gh pr edit --base main` + `gh pr ready`）。
- **按子任务的 PR**：Phase 7 现在按拓扑顺序为每个子任务创建
  一个 PR。不再有单个捆绑 PR。每个子任务有自己的 gate-create
  生命周期监视。
- **每轮全新终端（跨 Agent 审查）**：Phase 5 的审查循环为
  每一轮派生一个**全新的 `orca terminal create`**。第 0 轮的执行
  终端复用自 Phase 4；之后的每一轮（修复 + 审查）都获得全新的
  终端。审查终端在每个 verdict 后拆除；最新的执行终端成为该
  子任务的 `keep_terminal`，一直存活到 Phase 8。审查 Agent 与
  实现 Agent 不同家（默认：`pi` 审查，`claude` 实现 —— 见
  `docs/agent-routing.md`）。
- **按子任务的清理**：Phase 8 按**逆拓扑顺序**执行。每个
  子任务按 `pr_state` 有自己的分支处理：merged → 删除分支 +
  移除 worktree + 关闭 `keep_terminal`；parked → 写
  `.orca/parked/<sub>.md`；skipped/fail → 全部丢弃。每个子任务
  向 `.orca/workflow-history.jsonl` 追加自己的一行。
- **按子任务的挂起清单**（原来是单个捆绑清单）：挂起的子任务
  获得 `.orca/parked/<sub>.md`，列出依赖、堆叠链 rebase 目标提示，
  以及明确的「只为这个子任务重跑 Phase 7」恢复步骤。

### 新增
- `workflow.branch_strategy` 配置块（mode、branch_template、
  worktree_path_template、draft_pr_when_stacked、
  rebase_on_parent_merge、flip_pr_base_on_parent_merge）。
- `workflow.terminals` 配置块（spawn_per_role、role 名称、
  close_intermediate_terminals、max_terminals_per_subtask）。
- `workflow.merge.per_subtask_pr` 开关。
- 新环境变量：`ORCA_WORKFLOW_BRANCH_STRATEGY`、
  `ORCA_WORKFLOW_BRANCH_TEMPLATE`、`ORCA_WORKFLOW_WORKTREE_PATH_TEMPLATE`、
  `ORCA_WORKFLOW_MAX_TERMINALS_PER_SUBTASK`、
  `ORCA_WORKFLOW_MIN_WORKERS`。
- 每个子任务的状态 schema 字段：`worktree_path`、`branch_name`、
  `base_branch`、`terminals[]`（含 handle / role / round /
  agent_type / status / verdict / 时间戳）、`keep_terminal`、
  `pr_url`、`pr_base`、`pr_state`、`merged_at`、`review_rounds`。
  另有 `errors[]` 和 `decisions[]` 上的 `subtask_id`，用于带范围
  的事件。
- `§11.8 堆叠 PR Rebase 钩子` —— 在每个子任务转为 `MERGED`
  后触发，将依赖方 rebase 到 `main` 上，翻转 PR base，把 draft
  转为就绪。
- 新的 `examples/basic-workflow.md` 演练，端到端演示两个堆叠
  子任务（`prefs-api` + `prefs-ui`）。
- `.gitignore` 覆盖 `.orca/workflow-state.json` 和
  `.orca/parked/`。

### 修复
- **README 版本 badge 漂移**（`v2.0.0` → `v2.1.0`）。
- **§15 安全章节措辞**：之前写的「在它们的 worktree 内」仿佛
  只有一个 worktree；现在正确列举按子任务的隔离、只读审查者约定
  和 §11.8 钩子的能力。
- **§18 API 参考**现在包含 `orca terminal create` / `close`
  行，并在每一行 `orca worktree` / `gh pr` 上注明按子任务的基数
  说明。
- **`scripts/check-prerequisites.sh`**：遵循
  `ORCA_WORKFLOW_MIN_WORKERS`（默认 1），让 CI 能对 v2.1.0 更高的
  并发断言最小终端池大小；新增 `branch_strategy` 有效性的软检查。

### 迁移说明（v2.0.x → v2.1.0）
- v2.0.x 写入的状态文件仍可解析 —— 新字段都是可选的。顶层
  `branch` / `pr_url` 作为根子任务的聚合保留，以兼容仪表盘。
- 升级的运维人员必须确保有足够的 worker 终端：
  用 `orca terminal create --type worker` 把 `WORKER_COUNT`
  提高到 `ORCA_WORKFLOW_MIN_WORKERS`（建议 3+）。
- 现有的单 worktree 运行**不会**被自动改写；v2.1.0 工作流
  总是创建按子任务的 worktree。

## [2.0.1] — 2026-07-26

### 修复
- **文档漂移**：将错误的 `orca orchestration run --skill multi-agent-workflow`
  在 SKILL.md（§16.3、§17.1、§18.1、页脚）、README.md（快速上手）
  和 examples/basic-workflow.md 中统一替换为
  `orca orchestration run --spec /path/to/spec.md`。
- **预检策略漂移**：`scripts/check-prerequisites.sh` 之前对缺少
  worker 终端发出 WARN，而 SKILL.md §3.1 将同一条件标记为 FATAL。
  引入 `ORCA_WORKFLOW_STRICT_PREREQ`（默认 `true` → FATAL；solo/
  干跑时设为 `false`），使两处表述一致且 solo 模式仍可运行。
- **§8.3 分发竞态**：并行分发循环现在记录失败而不是吞掉它们。
- **§3.3 环境变量**：补全 `ORCA_WORKFLOW_*_AGENT` 列表（之前只在
  `docs/agent-routing.md` 中有文档，SKILL.md 里从未写过），并加上
  `ORCA_WORKFLOW_STRICT_PREREQ` 和 `ORCA_WORKFLOW_DRY_RUN`。
- **§4.1 路由重复**：路由键现在明确注明为冷启动默认值；权威
  来源仍是 `docs/agent-routing.md`。

### 新增
- **§7.2 缩减范围契约**：Phase 3 现在提供明确的「缩减范围 ——
  只保留部分成果（无 PR / 无 worktree）」选项。新增的
  `§7.2.1 缩减范围契约`表格记录了逐阶段的跳过规则，并区分了它与
  §10.4 降级交付路径（后者由失败驱动，而非用户声明）。
- **MIT LICENSE** 文件（README 中引用了但缺失）。
- **CHANGELOG.md**（本文件）。
- README 中的**项目结构**图现在反映完整的文件布局
  （CHANGELOG、LICENSE、docs/agent-routing.md）。

## [2.0.0] — 2026-07-26

### 新增
- 8 阶段多智能体编排工作流的首个生产版本。
- 计划生成与审查（最多 3 轮 + 2 次升级）。
- 带明确 `Approve / Revise / Abort` 语义的用户确认。
- 带按子任务自我审查的并行分发（最多 3 次重试）。
- 聚合与决策（重试 / 降级 / 升级）。
- 仅 PR 的合并路径，带冲突自动修复（最多 2 次尝试）。
- 清理与归档，带挂起工作流恢复清单。
- 带完整 schema 的 `.orca/workflow-state.json` 审计轨迹。
- `docs/agent-routing.md` 作为 Agent 路由偏好的单一起源。
- 演示降级交付路径的冒烟测试（`docs/smoke-test.md`）。

### 已知限制（延续到 2.0.1）
- 命令参数笔误 `--skill multi-agent-workflow`（已在 2.0.1 修复）。
- 脚本与 SKILL.md 之间的预检策略漂移（已在 2.0.1 修复）。
- Phase 3 缺少明确的用户声明的缩减范围路径（已在 2.0.1 修复）。
