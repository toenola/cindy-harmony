# Harmony v1.3.5 Mobile 差异评估

评估日期：2026-11-09。本文对照最终源码，不按提交标题直接认定功能缺失；
优先级表示建议开发顺序，不代表已经复现的实机缺陷等级。

## 1. 比较范围与结论

- 上游增量：`4fc89c26c..upstream/main`（`ae7bd0721`，2026-10-27 → 2026-11-09），共 4377 个提交（含 1558 个合并提交）。
- 其中触及 `apps/mobile` 的非合并提交 572 个；Mobile 净差异 1256 个文件（+112706 / −8435），
  按文件数约一半是测试与 i18n 语言包（新增 es / fr / de / pt-BR / pt-PT 与两套文言）。
- 上游区间未修改 `apps/harmony`；合并只在根 `AGENTS.md` 与 `docs/dev-rules/development-workflow.md`
  出现冲突：采用上游重写后的结构，保留 Harmony 工作区范围与 fork 分支规则。
- Harmony 对照基线为 `68229e661`（v1.3.4 分屏单栏与列表收起）。

结论：本期 Mobile 增量绝大部分是伙伴 / 群聊、远程桌面与模拟器画面、插件卡片与 PR 卡片、
桌面小组件、Duo 键盘皮肤、语音、邮件、自建中转等 Harmony 未纳入的独立能力。
与 Harmony 直接相关的是三类：**富组件解析器又一轮容错**（不跟进会丢正文）、**项目归组改认
`projectDir`**（不跟进会分错组）、**编辑最后一条用户消息**（Mobile 新增的核心消息动作）。
设备连接协议对官方中转没有破坏性变化，Harmony 现有连接不受影响。

## 2. Mobile 更新概览

| 更新领域 | 最终源码中的主要变化 | Harmony 判断 |
|---|---|---|
| 富组件回答 | 向容器 `append` 正文落进隐式 markdown 子节点；`props` 写成字符串、`props.children` 内联子节点被还原；结束行失败只重试那一行；媒体协议大小写不敏感；工具结果里与富组件重复的图片不再单独出 | **兼容缺口，优先跟进** |
| 项目归组 | 任务新增 `projectDir`（显式项目归属，优先于 `workingDir`）；Windows worktree 容器名大小写不敏感；项目标题用组内原始目录 | **建议跟进** |
| 消息动作 | 编辑最后一条用户消息（回退 + 重发）；运行中编辑按钮收进「…」菜单、发送时才中断；错误提示行不显示消息动作 | **建议跟进** |
| 归档 | 在已归档任务里发消息自动取消归档；菜单「恢复」改称「取消归档」 | 小体量，建议跟进 |
| 交互确认 | Codex 原生提问带 `id`、答案约束（必填 / 限定选项 / 长度）；可选提问 2 分钟无人作答自动关闭，开始作答需发 `inProgress` 暂停；权限卡新增 `mcp` 类、`write_stdin` / `mcp_url` 标题 | 建议跟进（可选提问会被提前关闭） |
| 错误呈现 | 队列错误条已展示的那条错误不在历史里重复出现（按 `persistId` 精确匹配）；上下文溢出 / 输出上限错误统一分类 | 建议跟进 |
| 流式与历史 | 历史先存半截再补全时保留完整正文；跨过最终回答的思考块并回同一段「已工作」；远程运行中工作组预览不再循环刷新；异步历史定位不覆盖跳底 | Host / 共享逻辑为主，Harmony 仅验证 |
| 上下文用量 | `percentage` 按 0–100 解读；新增文本估算明细行；数字进位规则（999999 读作 1M） | 小项，可选 |
| 队列 | 自动发送的排队消息按 `pastedTextRanges` 显示折叠占位 | 小项，可选 |
| 附件 | 附件预览全屏与统一查看器；待发图片可左右滑动；从相册附加视频；安卓 PDF 交给系统阅读器；文本预览排版 | 可选（视频上传仍属一期不做） |
| 独立能力 | 伙伴 / 群聊全部增量；按伙伴筛选任务；远程桌面与插件设备画面；插件卡片原生呈现、PR 卡片与合并后自动归档；MCP App 交互页确认；桌面小组件；会话导入；自建中转；供应商分享 / 组；Duo 键盘与折叠布局；语音与声纹；邮件阅读；文言界面；Expo SDK 58；Metro / 模拟器脚本 | 独立规划 / 不迁移 |

## 3. 建议优先跟进

### C1. 富组件解析器容错（兼容缺口，最高优先）

上游 `RichAnswerStream`（`packages/maker-shared/src/richAnswer.ts`）新增四类容错，都是针对真实模型输出：

| 容错 | 上游行为 | Harmony 现状（`core/messages/RichAnswer.ets`） |
|---|---|---|
| 向容器 `append` 正文 | 每个容器建一个隐式 markdown 子节点承接正文；只在它仍是容器末子节点时续写，删除子树时清理映射 | 只接受 text / markdown / heading / code / math / diagram，**整段正文被丢弃**（上游案例：stack / details 上的 5 次 append 全部丢失） |
| `props` 写成字符串 | 仅 `TEXT_PROP_KINDS` 接受，转成 `{ text }`；其他种类视为不可读 | 抛错丢节点 |
| `props.children` 内联子节点 | 容器的内联子节点（含嵌套）还原为真实子节点，声明的 `id` 优先，坏草稿只计 issue 不连坐兄弟 | 未处理，内联子节点不显示 |
| 结束行重试 | `complete` 时最后一行失败会记检查点，源文本变长后只重试那一行，不重放已提交内容 | 无检查点 |
| 媒体来源 | 协议名大小写不敏感并规范成小写；`richAnswerMediaSources` 供消息渲染去重 | 未规范化 |

建议：整段对照上游 `line()` / `attachInlineChildren()` / `inlineChildId()` / `props(v, kind)` 移植，
补「容器 append」「字符串 props」「内联子节点」「结束行重试」四条用例。
同时在 `MessageRender.ets` 的工具媒体投影里移植 `inlineMediaByMessage`：同一轮已在富组件里
显示过的图片，不再在工具结果里重复出一次。

证据：上游提交 `892209f894`、`4441b33708`、`440b555514`、`82c77599ed`、`3ccd17cb3c`、
`5dea1a009d`、`045fde139e`、`652b8e274c`、`5f4e21fc0a`；`messageRender.ts` 的 `buildLinearItems`。

### C2. 项目归组改认 `projectDir`

- `8cff805d31`：Host 为 Agent 任务记录显式项目归属 `projectDir`，任意兄弟 worktree 也能归到所属项目；
  老任务、老 Host 没有该字段时退回 `workingDir`（`sessionProjectDirectory`）。
- Harmony `TaskModels` 未读取 `projectDir`，项目分组、项目别名匹配、自动化分组键仍按 `workingDir`，
  与电脑端会出现分组不一致。
- 建议：`TaskModels` 读取 `projectDir`；分组键、`TaskProjectAliasStore` 别名匹配、概览项目数统一走
  「`projectDir ?? workingDir`」；`groupingWorktreeBaseRepo` 对 Windows 盘符 / UNC 路径的容器名
  忽略大小写；附件名取 basename 时同时按 `\` 与 `/` 切分。

### C3. 编辑最后一条用户消息

- `3cc73d8dd4`（#8287）：最后一条用户消息的操作行新增编辑入口，顺序为 `[time][copy][fork][edit][more]`；
  点击后复用底部输入框并显示「正在编辑消息」提示条，与排队消息编辑同款。
- 发送 = `maker:rewind:commit` 带 `requireLatestUser: true` 回退到这条消息，再以编辑内容重发；
  取消则原样恢复原草稿与附件。回退预览决定是否提示文件回滚，仅对话模式下 `allowFileRestore=false`。
- 约束：排队区有消息或附件上传中时不能进入；编辑期间出现新用户消息自动退出；与排队消息编辑互斥；
  提交锁覆盖回退 → 重发 → 恢复草稿全程；回退成功但重发未受理时，编辑内容留在输入框、原草稿接在后面；
  回退提交后离开任务，内容写入该任务草稿。
- 后续 `feat(chat)`：任务运行中编辑入口收进「…」菜单，**点编辑不中断，点发送时才中断**；
  遇到 `SESSION_RUNNING` 有限重试约 15 秒。
- Harmony 已有 Rewind（`MessageStore.ets` `maker:rewind:commit`）与排队消息编辑横幅，可在此基础上实现。
  旧 Host 不认识 `requireLatestUser` 时的表现需先在源码确认。

### C4. 交互确认：Codex 原生提问

- Host 仍按 `answers[id] ?? answers[question] ?? answers[header]` 取答案，Harmony 按问题文本提交**不会失败**。
- 但 Codex 的非阻塞提问（`isBlocking: false`）在 Host 侧 **120 秒无响应自动关闭**；Mobile 在用户开始作答时
  发送 `{ kind: 'ask_user_question', answers: {}, inProgress: true }` 暂停计时（`InteractionPanel.tsx`）。
  Harmony 不发送，用户慢慢填写时问题可能先被关掉。
- 答案约束：MCP 表单字段带 `answerConstraints`（必填 / 限定选项 / 最短最长），Mobile 用 `askAnswerError`
  在提交前提示；限定选项时选项按原样显示（不过滤）。
- 建议：解析 `id` / `isBlocking` / `answerConstraints`；首次编辑时发送一次 `inProgress`；提交前校验并按问题提示；
  答案键改为 `id || question`。权限卡同步 `mcp` 类与 `write_stdin`、`mcp_url` 两个标题。

## 3A. 用户追加（2026-11-09 确认纳入本期）

### D1. Mermaid 图表（含时序图）在手机上渲染

- 现状：Harmony 没有任何 Mermaid 渲染，也没有 ArkWeb 使用先例；Markdown 里的 ```` ```mermaid ```` 代码块和
  富组件 `diagram` 节点（`RichAnswer.ets:593` 转成 mermaid 围栏）都只显示为源码。
- Mobile 做法（`apps/mobile/src/session/mermaidWebView.tsx`、`mermaidWebViewHtml.ts`）：
  - 随包分发固定版本 Mermaid（`MOBILE_MERMAID_VERSION = 11.16.0`，由 `scripts/sync-rich-content-assets.mjs`
    与 `scripts/lib/mermaid-compatibility.mjs` 生成），静态页零外链，运行时内联注入，1 秒执行超时；
  - 消息内内嵌预览高 220、锁定缩放，首屏先画源码避免白条；渲染成功后截图缓存并释放 WebView；
  - 点击进入全屏查看器：允许双指缩放（上限 5 倍）、`fit` 复位，可导出 PNG；
  - 原文解析失败时用 `@cindy/maker-shared/mermaid-autofix` 的 `repairMermaidSource` 修复版重试一次，仍失败则停留源码；
  - 主题色由 App 注入，深浅色分别用 Mermaid `dark` / `default` 主题。
- 鸿蒙方案：产品范围允许「复杂 Markdown 内容局部使用 ArkWeb 承载」。在 `resources/rawfile` 随包放 Mermaid 运行时，
  用 ArkWeb 渲染；列表中只保留截图（PixelMap）不常驻 Web 组件，全屏查看器才挂载可缩放的 Web。
- 风险：包体增加约 3 MB；长列表中 Web 组件的创建、截图与回收需要实测；`repairMermaidSource` 需移植或随 HTML 注入。

### D2. 使用和切换其他电脑上的模型

- 现状：任务的 Agent 跑在其他电脑（`agentDeviceId` 非空）时，`TaskPage.ets` 的 `runtimeRouteLocked()` 主动锁住
  模型、Agent、推理档位与速度的切换；新建任务的模型选择器也只列被控电脑自己的供应商，无法选其他电脑的模型。
- Mobile 做法（`remoteAgentCatalogs.ts`、`useRemoteAgentCatalogs.ts`、`sessionAgentSwitch.ts`、`newSession.ts`）：
  - 手机经 device-link **直接**向同账号其他在线电脑取 `maker:provider:list`，只保留开了「允许被远程调用」
    （`remoteInvocationEnabled`）的供应商，按电脑分段、标题带电脑名，接在被控电脑自己的供应商之后；
  - 排除被控电脑、手机与已撤销设备；离线电脑不列，但任务当前 Agent 所在的电脑始终保留并标为离线；
  - 现有任务切换：`maker:switch-session-agent` 末尾带 `{ agentDeviceId }`（`null` = 改回被控电脑），
    被控端持有 pending intent，Harmony 已移植的 `SessionAgentSwitch.ets` 可直接复用；
  - 新建任务：草稿带 `agentDeviceId`，`maker:create-session` 一并提交；记住的远程选择在目录读完后不可用时退回本机。
  - 供应商分享（别人分享给被控电脑的供应商，经 `maker:provider-share:received-catalogs` 代读）按「一台电脑」接在后面。
- 鸿蒙方案：`DlClient.invoke(deviceId, …)` 已支持按设备调用，无需新协议。读取目录只连 Cindy 电脑端，
  不直连模型厂商，符合「厂商信息经电脑端获取」的约束。本期先做同账号其他电脑；供应商分享按同一结构可后续接入。

## 4. 小体量，建议顺手跟进

| 项 | 上游变化 | 建议 |
|---|---|---|
| 发消息自动取消归档 | 消息确定发出（入队或 Host 已接收）后，若任务已归档则 `patch-meta` 为 `active`；伙伴托管、分享来的任务、协同 Worker 除外 | 在发送成功回调接入；菜单文案「恢复」改为「取消归档」 |
| 错误不重复显示 | 终止错误事件携带 `persistId`；队列错误条正在展示的那条，历史里按该 ID 隐藏，清除后恢复 | 对照 `mobileHistoryRender.ts` 的 `activeErrorClientId` |
| 错误提示不出操作行 | `messageActions.ts`：错误提示行隐藏消息动作，错误详情仍可见 | 对齐 |
| 上下文用量 | `percent` 可能是 0–1 或 0–100，新增的 `percentage` / `contextPercent` 一律按 0–100；`textEstimate` 估算明细行 | 对照 `sessionControls.ts` |
| 排队预览 | `queueItemVisibleText` 对自动发送消息按 `pastedTextRanges` 显示占位文本；空内容不再回退到原文 | 对照 `queue.ts` |
| HY4 子 Agent | 子 Agent 父工具 ID 识别新增 `chatcmpl-tool-` 前缀 | 一行正则 |

## 5. 仅验证、不预先改代码

- **半截正文交接**（`331054e1ef`）：电脑端先存半截、再用同一 ID 补全时，Mobile 继续显示完整正文直至历史补齐。
  Harmony 需在长回复中途冷启动 / 切任务实测，不停留在半截；出问题参考 `historyViewHandoff.ts`。
- **思考块跨过最终回答**（`31a4b4b094`）：Host 把思考行锚点改为真实起点；Harmony 实测不再出现两段「已工作」。
- **远程运行中工作组预览**（`e81736b38c`）：Mobile 曾因预览与重新分组互相触发而报错；Harmony 实测运行中任务工作组展开稳定。
- **异步历史定位与跳底**、**慢返回后恢复跟随**：在长任务里实测搜索定位后点「回到底部」不被覆盖。

## 6. 可选增强

| 主题 | 说明 |
|---|---|
| 附件预览 | 全屏查看与统一查看器、待发图片左右滑动、载入原图时底栏提示、PDF 交系统阅读器（`attachmentPreview.ts`） |
| 相册视频附件 | 照片与视频合并选择；一期仍明确不做视频上传，需单独决策 |
| 流式操作行占位 | 流式时为操作行预留高度，结束时不跳动 |
| 代码块复制 | 代码块复制按钮只显示图标 |
| 费用明细 | 对话价值按模型与渠道拆分、附加费用（`estimatedSessionValue` 带 `includeBreakdown`） |
| 新语言 | es / fr / de / pt-BR / pt-PT；文言界面与文言回复（`classicalReply.ts`）。需评估 Harmony 资源目录与文案维护成本 |

## 7. 不纳入本期

- 伙伴 / 群聊全部增量（群话题、点名、通知、已读同步、AI 回复模式、群附件、富回答、按伙伴筛选任务等）：Harmony 尚无伙伴入口。
- 插件卡片原生呈现、PR / MR 卡片与合并后自动归档、卡片链接开后续任务、插件选择模型、MCP App 交互页确认：
  Harmony 目前不渲染插件卡片（`cardIds`），与插件能力一并独立规划。
- 远程桌面、插件设备画面（模拟器）、Duo 键盘与复古皮肤、安卓折叠屏远控布局。
- 桌面小组件（新通道 `device-link:usage-widget:snapshot:v1`）：鸿蒙服务卡片可作为后续独立主题。
- 自建中转与帧签名（`selfHostedRelay*`）、供应商分享 / 组、会话导入、语音与声纹、邮件阅读、Expo SDK 58、Metro / 模拟器脚本。
- 设备连接：官方中转握手与帧格式未变；`relayJoinIntent`、`lowPriorityReadGate` 等为 Mobile 内部优化，Harmony 不迁移。

## 8. 本次完成

基于 `feat/v1.3.4`（`68229e661`）创建 `feat/v1.3.5`，合并 `upstream/main`
（合并提交 `1f88848c2`，带 DCO；本机签名配置未纳入提交），梳理 Mobile 提交与共享包差异，
并对 C1–C4 在 Harmony 源码中逐项确认了缺口位置。
