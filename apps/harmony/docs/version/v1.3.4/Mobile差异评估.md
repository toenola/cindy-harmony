# Harmony v1.3.4 Mobile 差异评估

评估日期：2026-10-27。本文对照最终源码，不按提交标题直接认定功能缺失；
优先级表示建议开发顺序，不代表已经复现的实机缺陷等级。

## 1. 比较范围与结论

- 上游增量：`3482d51f4..upstream/main`（2026-10-21 → 2026-10-27），共 1930 个提交。
- 其中触及 `apps/mobile` 的非合并提交 235 个；Mobile 净差异 579 个文件（+35203 / −10237）。
- 上游区间未修改 `apps/harmony`；合并只在根 `AGENTS.md` 与 `docs/dev-rules/repo-map.md`
  出现追加型冲突，已保留双方内容。
- Harmony 对照基线为 `caadf666e`（v1.3.3 富组件与消息体验完成）。

结论：本期 Mobile 增量约一半集中在伙伴 / 群聊 / 近况待办 / Duo / 语音等 Harmony 未纳入的
独立能力。与 Harmony 直接相关的是 **v1.3.3 刚移植的富组件回答又有两处 Host 侧变化**：
提示词改为「所有回答优先用 cindy-ui」，并新增按钮 `send` 发消息动作；解析器改为容忍序号缺口。
这两项不跟进会直接表现异常，建议本期最先处理。

## 2. Mobile 更新概览

| 更新领域 | 最终源码中的主要变化 | Harmony 判断 |
|---|---|---|
| 富组件回答 | 按钮 / 表单 `send` 发送用户消息（#6871）；序号缺口不再中断后续行；提示词改为默认用组件作答 | **兼容缺口，优先跟进** |
| 消息呈现 | `assistantPhase: 'commentary'` 进度文字不并入最终答复，完成后收进工作过程；转发请求信封去 JSON 转义显示 | 呈现回归，建议跟进 |
| 流式与历史 | 匿名流 / 迟到 final / 空 final 撤回（Host 发 `local-db:messages:deleted`）；历史缓存断档补齐、同时间戳边界 | Host 侧为主，Harmony 仅验证 |
| 任务列表 | 新字段 `lastActivityAt`（工作交接推进最近活动）；桌面项目别名同步到手机；无名电脑去重命名；右滑「已读」 | 小体量，建议跟进 |
| 交互确认 | 权限卡显示 Auto-review 询问原因 `metadata.autoReviewReason`，按命令 / 文件 / 插件 / 浏览器归类操作摘要 | 可选增强 |
| 发送与队列 | 发送气泡先上屏实色、状态改为左侧图标 + 下方状态行；排队消息操作收进菜单并支持调整顺序；带图消息失败标到具体图片 | 可选（视觉 / 交互对齐） |
| 错误与续跑 | 自动任务失败后保留手动重试入口；按失败输入判定续跑资格（`canContinueFailedTurn`）；分叉失败显示远程 Agent 本地化错误 | 可选，体量小 |
| 归档 | 归档绑定定时任务的任务前先确认；定时任务自动运行时 Host 会恢复已归档任务 | 可选 |
| 新建任务 | 边输入边建临时任务（provisional）并预热 Agent，粘贴 / 语音也触发预热 | 可选（性能项，延续 v1.3.3 结论） |
| 独立能力 | 伙伴与任务首页打平、伙伴近况待办、伙伴私聊引用回复、群聊通知与已读、云端对话附件；远程插件管理；局域网直连传输；Duo 远程桌面皮肤；提问卡语音；Android 应用内更新；`--mock` 模拟数据 | 独立规划 / 不迁移 |

## 3. 建议优先跟进

### B1. 富组件按钮 `send` 动作（兼容缺口，最高优先）

- `RICH_ANSWER_GUIDE` 已改为：`button` / `form` 可用 `send: expression` 代替 `set`，求值为
  1–16000 字符的非空字符串；Host 要求客户端把该文本**显示在按钮旁**，仅在用户显式点击后作为
  当前对话里一条可见的普通用户消息发送（走正常发送 / 排队与权限），只读界面不可发送；
  失败保留输入值，已被接受的同一文本在该设备上不可重复提交。
- 同时提示词要求「跨主题、跨长度都用 cindy-ui 组件作答」，按钮出现频率会明显上升。
- Harmony 现状：`RichAnswerView.ets` 的 button / form 只调用 `host.apply(node)` 处理 `set`；
  带 `send` 的按钮点击**没有任何反应**，也不显示将要发送的文本。
- 建议：移植 `richSendText` 与 `RichSubmissionController`（idle / sending / sent / failed，
  已发送记录写入现有 `RichInteractionMemory`），点击后复用 Composer 的正常发送 / 入队通道；
  分享预览、搜索结果等只读场景隐藏发送能力；任务运行中按 Mobile 语义入队。

证据：`packages/maker-shared/src/richAnswer.ts`（`richSendText`、`RichSubmissionController`）、
`richAnswerGuide.ts`、`apps/mobile/app/sessions/[sessionId].tsx`、`apps/mobile/src/session/RichAnswer.tsx`；
Harmony `core/messages/RichAnswer.ets`、`components/RichAnswerView.ets`、`core/messages/RichInteractionMemory.ets`。

### B2. 富组件序号缺口容错（兼容缺口）

- 上游 `RichAnswerStream`：`seq` 出现跳号时不再抛错，而是把缺失行计入 `issues` 并继续应用后续行。
- Harmony `RichAnswer.ets:227` 仍是 `if (seq !== this.seq + 1) throw new Error('gap')`，且抛错时
  不推进 `this.seq`，导致**缺失一行后，后面所有行都会因 gap 被丢弃**，只剩缺口前的内容。
  模型输出单行 JSON 格式错误或 Host `compactRichAnswer` 截断时都会触发。
- 建议：按上游改为 `issues += min(seq - this.seq - 1, MAX_NODES)` 后继续；补一条「中间一行损坏、
  后续节点仍渲染」的单测。

### B3. 进度文字不并入最终答复

- `messageRender.ts` 新增 `canPrependToAnswer`：`agentMeta.assistantPhase === 'commentary'` 的消息
  不能向前并入最终答复段，完成后收进工作过程折叠（#b6d92e2c1）。
- Harmony `MessageRender.ets:2403` 的 `answerStart` 回溯只看 `isAssistantAnswerCandidate`，
  Codex 的进度说明会被当成最终答复的一部分直接展示。
- 建议：在回溯条件中加入同等判定，两处 `answerStart` 都要改。

### B4. 任务列表与设备小项

| 项 | 现状 | 建议 |
|---|---|---|
| `lastActivityAt` | Host 新增该列，目标 / 工作交接时推进；Harmony 仍按 `userSendAt → updatedAt` 排序 | `TaskModels` 读取该字段，排序改为 `lastActivityAt → userSendAt → updatedAt`（`getSessionListActivityAt`） |
| 项目别名 | 新放行 `local-db:project-aliases:list`、`sidebar-settings:get-project-aliases` 与推送 `local-db:project-aliases:changed`；Harmony 项目名只取路径末段，桌面改名后不一致 | 读取 Host 别名（只读），按 `projectAliasSync.ts` 规则解析，旧 Host `CHANNEL_NOT_ALLOWED` 时退回路径名 |
| 电脑名称 | `deviceDisplayName`：路由 ID 不得作为显示名，同名电脑追加稳定序号 | 设备列表 / 任务来源处统一走该规则 |
| 转发请求 | `forwardedRequestDisplayText` 把 `[来源]` 信封中的 JSON 引号串解码为可读文本（多语言方言） | 仅显示层移植，原文不改 |

## 4. 仅验证、不预先改代码

- **流式 final 对账**：Host `messagePersistBroadcaster` 现在会为迟到 final 复用原消息身份、
  对空 final 撤回草稿并广播 `local-db:messages:deleted`。Harmony 已处理删除事件；需在 Codex
  长任务中实测「重试后不重复回答、旧条目 final 不覆盖新流」。出问题再参考
  `apps/mobile/src/session/remoteSessionStore.ts` 的匿名流身份逻辑。
- **历史断档**：`readContinuousHistoryPage` 在替换缓存窗口前补齐漏掉的页、同时间戳不当作边界。
  对照 Harmony `HistoryGap.ets` / `HistoryWindowCoverage.ets` 实测长任务冷启动与重连后不丢段。
- **插话送达**：Host 修复了 Claude 等待后台任务时插话无法送达（#459e12f4c），Mobile 修了过期队列
  误报「未送达」；Harmony 实测插话回执状态即可。

## 5. 可选增强

| 主题 | 说明 |
|---|---|
| 权限卡原因与操作归类 | 显示 `metadata.autoReviewReason`，按 command / file-read / file-write / plugin / browser / tool 归类预览（`interaction.ts` `PermissionActionSummary`），MCP 工具名拆出插件名 |
| 发送状态新样式 | 发送气泡先上屏实色，状态放左侧图标与下方状态行（命中区 44），真实上传失败时标出那张图 |
| 排队消息菜单 | 逐条操作收进菜单并支持上移 / 下移；Harmony 现为图标胶囊按钮（见既有反馈记忆），改动前需确认是否跟随 |
| 右滑已读 | `clearSessionAttention(sessionId, 'explicit')`，有定时运行的任务同时标记运行已读；需与「滑动只露按钮、点击才执行」的既有约束一起设计 |
| 失败后手动重试 | 自动任务失败后保留重试入口，`canContinueFailedTurn` 判定可否从对话继续，鉴权 / 配置类错误仍走配置门禁 |
| 归档前确认 | 任务绑定定时任务时归档前确认；查询超时按无绑定处理 |
| 新建预热 | 打字 / 粘贴时 `maker:session:prewarm`，旧 Host 拒绝时忽略 |

## 6. 不纳入本期

- 伙伴相关全部增量（首页打平、近况待办、私聊长按菜单与引用回复、群聊通知、云端对话附件、
  跟随任务标记）：Harmony 尚无伙伴入口。
- 远程插件管理与原配置页、邮件草稿：涉及插件权限与 WebView，需独立规划。
- 局域网直连传输（`ca4b907522`）：可选传输层，Harmony 继续走 relay，不影响功能。
- 供应商分享模型权限、供应商组换号确认、Orca Worker 模型路由：随对应独立能力评估。
- 任务级上下文窗口档位（`maker:set-context-window-budget`）、worktree 分支同步：Mobile 未接入。
- Duo 远程桌面皮肤、语音 / 提问卡语音、Android 应用内更新、`--mock` 模拟数据、RN 性能与测试卫生提交：不迁移。

## 7. 折叠屏适配对照（iPhone Duo）

上游的 “Duo” 指 iPhone Duo（Apple 折叠屏）。原则：**按窗口几何适配，不按设备名判断，
不把手机等同于窄屏**（`docs/design-evidence/iphone-duo-adaptation.md`）。iOS 通过原生模块拿到
窗口安全区、`verticalBarEdge` 和系统保留区域（`division` 折痕 / `occlusion` 摄像头）；
旧 iOS 与 Android 只用普通窗口几何，不虚构折痕位置。

| 规则 | 上游（`sessionPaneLayout.ts`、`windowGeometry.ts`） | Harmony 现状（`pages/TaskSplitLayout.ets`） |
|---|---|---|
| 双栏触发 | ① 纵向折痕两侧分别 ≥240 / ≥320 → 以折痕为界固定分栏；② 无折痕时，宽 ≥600、安全区宽 ≥760 且高 ≥480 → 可拖动双栏。**不看横竖屏、不看折叠状态** | 折叠状态必须为展开 + 宽 > 高 + 宽 ≥640；竖屏、半折、盒盖一律单栏 |
| 列表宽度 | 240 – min(420, 宽 − 400)，默认 min(320, 宽 × 34%)；折痕分栏不可拖 | 宽度比例 25% – 60%，列表 ≥300、详情 ≥320，默认 1/3 |
| 折痕 / 摄像头避让 | 悬浮控件整组放在第二分区并避开摄像头，不跨折痕；上下折时键盘盖住下半区，输入区改到上半区（`keyboardControlRegion`） | 未读取折痕区域，也未避让挖孔 |
| 宽窄切换 | 详情、编辑器、消息列表保持组件身份；抽屉等真实退场完成后才跳转 | 退出双栏时保留当前详情 ✓；草稿、滚动位置需实测 |
| 双栏常驻 | 首页与任务侧栏共用一个列表实例；最近 3 个任务的消息列表常驻，隐藏的列表暂停订阅、补页和贴底 | 未做 |
| 弹层 | 宽窗 / 横窗中限宽、四周留白、垂直居中；窄屏竖向才贴底 | 模型、权限等弹层已锚定按钮并限定在详情栏，其余弹层待核对 |
| 内容排版 | 消息与交互面板按实际栏宽排版 | 富组件已按测量宽度 ✓ |
| 不迁移 | iOS 系统竖排工具栏、Liquid Glass、远程桌面折叠布局与复古硬件皮肤 | — |

HarmonyOS 对应能力：`display.getCurrentFoldCreaseRegion()`（折痕区域）、窗口避让区
`TYPE_CUTOUT`（挖孔）、`foldStatusChange` / 窗口尺寸变化。开发时以 API 26 文档和实机为准。

用户决定（2026-10-27，见 decision-log D-014，主力机 Pura X Max）：

- **跟进**：双栏改为按窗口尺寸判断（上游无折痕分支的阈值与列表宽度规则），不再看横竖屏和折叠状态；
  双栏下最近 3 个任务的消息列表常驻。
- **不跟进**：折痕固定分栏、折痕避让、上下折键盘换区——鸿蒙拿不到折痕数据，半折姿态也不适用。
- 摄像头挖孔避让走系统避让区，与折痕无关，按需单独评估。

## 8. 本次完成

基于 `feat/v1.3.3`（`caadf666e`）创建 `feat/v1.3.4`，合并 `upstream/main`
（合并提交 `31d9a6855`，带 DCO；本机签名配置未纳入提交），梳理 Mobile 提交与共享包差异，
并对 B1–B3 在 Harmony 源码中逐项确认了缺口位置。
