# Harmony v1.3.2 Mobile 差异评估

评估日期：2026-10-12。本文对照最终源码，不按提交标题直接认定功能缺失；
优先级表示建议开发顺序，不代表已经复现的实机缺陷等级。

## 1. 比较范围与结论

- 上游增量：`abcf92c2b..ebded1721`，共 2185 个提交。
- 其中触及 `apps/mobile` 的非合并提交为 490 个，不等于 490 个独立功能。
- Mobile 净差异涉及 1358 个文件，包含测试、原生模块、资源、多语言和页面重构。
- Harmony 对照基线是已完成实现的 `05284d936`，不能沿用 v1.3.1 实现前的缺口表。
- 本次只合并上游并记录评估，不跨仓修改服务端，也不修改 Harmony 运行时代码。

结论：建议本版先确保现有任务在新 Host 上仍可正确选择模型、发送、确认和阅读。
Mobile 这一个月还增加了大量独立能力，不应把整个 Mobile 更新量当作一个补丁版本的默认范围。

## 2. Mobile 更新概览

| 更新领域 | 最终源码中的主要变化 | Harmony 判断 |
|---|---|---|
| 任务与模型 | 新建模型改读 Host 显式默认；关闭模型要求重新选择；远程 Agent、共享供应商和供应商组；任务标签、分组状态 | 默认与发送校验直接跟进；远程路由单独规划；标签可选 |
| 历史与工作过程 | 可见正文优先、工具详情延迟加载；运行中最近活动行及增量 patch；成果摘要；重连保留历史；预读与最近任务保活 | 在 v1.3.1 历史适配上增量补齐，不重新造消息 Store |
| 发送与确认 | 持久发件箱、Host 投递回执、撤销在途发送；历史接管前保留消息；确认显式拒绝；统一自定义回答入口 | 核心可靠性，建议纳入优先范围 |
| 连接与文件 | 前台恢复保留有效握手；恢复请求限流；回包压缩及有界解压；文件直传、分块和大附件 | 移植语义与验证故障半径，不能照搬 RN 实现 |
| 现有界面体验 | 更多订阅额度、重置倒计时、token 速度；图片查看与本地预览；系统分享接收；外观选择和原生导航 | 按现有能力先补兼容与回归，新增入口另确认 |
| 独立产品能力 | 跨账号共享任务；伙伴群聊、记忆和 Todo；Orca 协同；插件页面及调用；远程桌面持续增强 | 独立规划，不因上游合并自动承诺交付 |

## 3. 建议优先跟进

### A1. 新建默认模型与发送前重新选择

- Mobile #5816 改为读取 `maker:get-new-maker-defaults`，不再从最近任务推断模型。
  没有显式默认、旧 Host 或读取失败时回落目录默认；未就绪时有限重读，本页选择优先于迟到读取。
  模型、档位及 Fast 的显式选择通过现有草稿偏好通道写回 Host。
- Mobile 另有 `modelNeedsReselection`：已保存选择被关闭后须由用户重新选择，不能静默换来源。
- Harmony `NewSessionPage.ets` 仍从 `latestSessionForAgent` 推断默认；有目录就绪保护，
  但没有 Host 新建模型默认读写链。`ComposerCatalog.ets` 对选中行保留可见性豁免，
  新建发送入口还需精确校验模型、来源、停用状态及显式关闭状态。
- 建议：新建默认读源与 Mobile 同源，按设备及 Agent 保护异步结果；
  将“现有任务展示实际路由”和“新任务允许发送”分开。不要覆盖用户当前显式选择或目录记忆。

证据：`apps/mobile/app/sessions/new.tsx`、`apps/mobile/src/session/newSession.ts`、
`apps/mobile/src/session/modelReselection.ts`；Harmony `pages/NewSessionPage.ets`、`core/ComposerCatalog.ets`。

### A2. 确认回执与 Ask User 自定义回答

- Mobile `resolveInteractionResilient` 明确检查 `{ accepted: false }`，不能将显式拒绝当作 ACK 丢失。
  只有传输失败才用权威 pending 列表补证；旧 Host 返回 void 保持兼容。
- Harmony `InteractionStore.resolve` 解包后未检查 accepted，直接进入本地成功路径。
  静态源码已显示这一契约缺口，建议优先处理；保留原卡片和草稿并展示失败，不用 pending 消失覆盖明确拒绝。
- 共享层新增 `visibleAskOptions`：把模型自己生成的“其他（回复说明）”等逃生选项替换为宿主的自定义输入，
  但保留“其他任务”等实质性选项。Harmony 当前 `askOptionPresentations` 原样保留所有非空选项。
- 建议同步上述语义及五语边界，回归选择即时响应、焦点切换、重复提交与请求作用域。

证据：`apps/mobile/src/session/interactionModel.ts`、`packages/maker-shared/src/interaction.ts`；
Harmony `core/interactions/InteractionStore.ets`、`InteractionPresentation.ets`。

### A3. 历史视图的延迟详情、活动行和成果摘要

- Mobile 历史请求带 `lazyDetails: true`、`workLines: true`；Host 可下发最近活动行，
  用 `maker:history-work-patch` 局部更新。展开但详情尚未返回时继续保留已有活动行。
- 工作摘要新增 artifacts、子 Agent 实际 model 与 parentToolUseId 等信息；共享控制器校验 patch 的基准 revision，
  不让旧 patch 覆盖新范围。上游也修复了长 Codex 历史退回逐条读取及页面过小的问题。
- Harmony 已有 `messages:view`、按需 work-details、游标、revision 和旧 Host 回退，
  但请求只传 before，未启用 lazyDetails/workLines；AppServices 未消费 history-work-patch，
  渲染尚未使用摘要中的成果信息。
- 建议在现有适配器增量支持活动行与摘要，保留已有详情直到同 revision 的新结果真正接管；
  核对长正文、工具体和嵌套工作组的请求预算，不直接复制新的字节常量或扩大所有响应。

证据：`apps/mobile/src/device-link/mobileMakerTransport.ts`、`DeviceLinkContext.tsx`、
`packages/maker-shared/src/historyView.ts`、`historyViewController.ts`、`historyViewRender.ts`；
Harmony `core/messages/HistoryViewAdapter.ets`、`MessageStore.ets`、`core/AppServices.ets`。

### A4. 持久发送及历史接管

- Mobile #4339 增加账号隔离、先落盘再发布的 durable outbox，明确 queued/sending/confirming/host-owned/failed。
  `inputDeliveryVersion` 与 deliveryReceipts 才证明 Host 的持久接收；旧队列 ACK 仅证明内存接收。
  不确定是否已发送时不能无条件重发；在途取消、清理失败和草稿交接均保留账本。
- 后续修复要求正式用户消息已进入本地历史缓存后再释放 outbox，迟到缓存写入不能覆盖已确认消息。
- Harmony 已有队列投影、稳定 clientId、失败编辑、草稿保护和远端幂等接线，
  但 `InputProjectionState` 未解析持久投递回执，新建及投递状态仍主要保存在内存中。
  草稿落盘不等价于发送账本落盘。
- 建议独立切片设计：将既有队列接入持久发送所有权，不另造第二套权威队列；
  覆盖强杀重启、先发后断、取消与 ACK 竞态、存储满和旧 Host 无回执等边界。

证据：`apps/mobile/src/session/durableOutbox.ts`、`durableOutboxDelivery.ts`、`mobileDurableOutbox.ts`；
Harmony `core/messages/InputQueueStore.ets`、`ComposerDraftStore.ets`、`core/tasks/NewSessionCreationStore.ets`。

### A5. 前后台与弱网恢复

- 上游 #4443/#5154/#5465 等归并恢复调度、限制远程请求、区分繁忙与失联，丢弃过期输入。
  #5812 保留重连前历史和阅读位置；2026-10-12 的更新保留仍在握手窗口内的连接，避免短暂失焦反复重启。
- Harmony 有 1013 冷却、连接代次、有限读取重试和请求合并，并非没有恢复机制；
  但 `AppServices.onAppForeground` 调用 connectNow，而 connectNow 没有仍有效的 connecting 窗口豁免。
- 建议优先移植不打断有效握手、分资源限流和繁忙提示等语义，回归阅读位置、迟到回包和草稿。
  多控制端共享 Host 时，一个 peer 静默不得导致所有控制端重连。
- 回包 gzip/内容标签是另一个性能增强：上游仅按请求声明启用，Harmony 未声明，因此不能据缺少解压器认定现有必然不兼容。
  若接入，必须同时实现声明、严格输出上限及内容缓存归属；可靠传输、RTT 重发和文件 peer 也不能只复制能力名。

证据：`packages/device-link/src/client.ts`、`invokeTransfer.ts`、
`apps/mobile/src/device-link/DeviceLinkContext.tsx`；Harmony `core/device-link/DlClient.ets`、`core/AppServices.ets`。

### A6. 既有消息呈现的增量兼容

- `/goal` 末尾 goal_status/goal_setup 协议块只在显示层剥离，不删原始消息或改 Agent transcript。
- Host 写入的来源设备、插件、伙伴与来源任务可展示标签及跳转；不能由 Harmony 自行猜测来源。
- 新生成期间已结束回答、工作组和流式正文须保持身份、顺序和已有动作栏；
  停止后消息菜单的删除能力及错误/等待状态需对照最终权威权限。
- 建议先补目标裁决与来源元数据投影，其他菜单与流式变化作为既有能力回归，不能只照搬标题判断已经缺失。

证据：`packages/maker-shared/src/goalVerdict.ts`、`messageSource.ts`、`workRunGrouping.ts`、
`apps/mobile/src/session/messageNormalize.ts`、`MessageRenderer.tsx`；
Harmony `core/messages/InternalOutputSanitizer.ets`、`MessageRender.ets`、`pages/TaskPage.ets`。

## 4. 可选体验增强与鸿蒙等价实现

| 主题 | 源码差异与建议 |
|---|---|
| 账户额度与速度 | Mobile 增加 Claude/SuperGrok 额度、ChatGPT credits、重置倒计时与 token 速度图。Harmony v1.3.1 只覆盖网关和部分 OpenAI 用量，不代表覆盖全部订阅。按实际 Agent 运行电脑读取，无法证明账号归属时不展示错误余额；账户余额不当作单任务用量 |
| 标签与首页状态 | Mobile 有任务标签管理、折叠分组状态聚合、未读和需要关注的状态修复。Harmony 已有分组、排序、搜索与设备消歧；按现有列表增量扩展，不重做整套导航 |
| 文件与大附件 | Mobile 新增 file peer、分块直传和读取队列，放宽直连附件限制。Harmony 仍有 30 MiB 上传保护，生成文件下载/分享并非 peer 直传。先做协议、内存和临时文件方案；不能直接删大小限制冒充大文件支持，旧 Host 保留现有路径 |
| 图片查看与本地预览 | Mobile 修复本地图片打开闪黑、工具栏、缩放和翻页，并增加 SVG 预览。Harmony 已有本地发送预览接管和原生预览，先实测这些场景再改，不能仅凭 Mobile 的 RN 手势问题认定 ArkUI 同样存在 |
| 外观与原生交互 | Mobile 新增跟随系统/浅色/深色偏好并调整色板、导航与分栏。Harmony 已有双主题、折叠屏分栏和原生玻璃控件；外观偏好可等价实现，不复制 iOS 导航栈、Liquid Glass 或 Android Drawer |
| 系统分享接收与图片标注 | Mobile 可把系统分享文件转入新任务，并发送图片标注区域。Harmony 现有向外分享不等于接收分享；这两项需要独立的原生接入、文件所有权与登录恢复方案，可另行选择 |
| 长时间性能与缓存 | Mobile 统一最近 5 个任务的保活/订阅策略，优化首页投影和预览订阅，并增加历史预读。Harmony 有任务数、消息数及磁盘预算，不能认定全部缺失；应测大量任务、长历史和长期前后台后再选择 ArkUI 对应策略，不机械采用 5 的常量 |

参考入口：`apps/mobile/src/session/readSessionMenuAccountUsage.ts`、`sessionUsageAccount.ts`、
`RunningTokenRatePopover.tsx`、`TaskTags.tsx`、`ImageLightbox.tsx`、`incomingShare.ts`、
`RecentMessageHistories.tsx`、`recentTasks.ts`、`remoteHistoryPrefetch.ts`、
`apps/mobile/src/device-link/peerFileTransport.tsx`、`apps/mobile/src/theme/themePreferenceStore.ts`。

## 5. 独立功能，不默认纳入 v1.3.2

| 能力 | 本次增量 | 为什么需要独立确认 |
|---|---|---|
| 跨账号共享任务 | 邀请链接、访客加入、共享分组、成员权限、多端确认及邀请持久去重 | Harmony 当前同账号设备控制不是跨账号共享；需落实访客只读设置、撤权、附件和凭证边界 |
| 远程 Agent/共享供应商/供应商组 | 任务和文件留在 Host，Agent 可在另一电脑运行；他人供应商共享及组内换电脑 | 新增运行设备与权限身份，影响新建、模型切换、额度读源、失败恢复和隐私，不是多加一个 provider 分组 |
| 伙伴扩展 | 群聊直接 Chat Server、分工、记忆、导入、Todo 和执行成果 | Harmony 尚无完整伙伴入口；不能通过普通任务列表包装成已支持伙伴群聊或 Todo |
| Orca 协同 | Lead/Worker 视图、派活、队列/插话、远端 Worker 和运行设备选择 | 子 Agent 卡片不等于完整协同，需要团队状态和导航链单独实现 |
| 插件页面与调用 | 已装插件页面、配置及原生交互、Composer 调用入口 | Host 已安装插件不等于 Harmony 有交互；需遵守插件权限、网络、凭证及旧插件兼容规则，不在手机本地重造执行运行时 |
| 远程桌面/完整语音 | 原生视频、画中画、剪贴板、分辨率、控制恢复；语音采集与润色增强 | Harmony 有语音词典同步但非完整听写，亦无远程桌面媒体链；按独立原生工程范围规划 |

源码入口：`SharedTaskAdmissionDialog.tsx`、`useSharedTaskConfirmation.tsx`、`remoteAgentCatalogs.ts`、
`remoteProviderGroups.ts`、`BotGroupChatScreen.tsx`、`CompanionTodos.tsx`、`useSessionOrcaCollab.ts`、
`pluginInvocations.ts`，以及 `apps/mobile/src/remote-desktop/`。以上文件名位于 `apps/mobile/src/session/`，除另注明外。

## 6. 已覆盖与不直接迁移

- v1.3.1 已实现历史视图/详情基础、读取合并/有限重试、迟到响应保护、模型来源身份、
  小上下文切换保护、按账号设备的目录记忆、机器标注和发送图片本地预览。上述基础不重做。
- v1.3.1 的设备验收仍未完成；不能用本次 198 项单测与签名构建将旧的实机待验收项标成通过。
- 不复制 Expo OTA、APK 更新、iOS Share Extension、WebView 兼容修复、Swift/Gradle/Metro 构建及 RN worklet。
  对应产品体验只有明确选择后才做 Harmony 原生等价实现。
- 不默认跟进 Mobile 已移除的自动化管理入口，也不根据中间 WIP/revert 提交认定最终功能。
- 图像、媒体、语言和主题的状态需以真正设备验证确认；静态代码对照只证明实现差异。

## 7. 本次完成与后续验证

已完成 Git 合并及规则冲突处理、Mobile 提交/净差异梳理、关键源码对照、
合并后 198 项 Harmony 单测和签名 HAP 构建。新分支未推送，候选功能未实现。
未运行根目录或其他端的测试，未安装到设备，未证明新的 Host 协议与 UI 场景全部兼容。

建议范围顺序：默认模型及确认回执 → 历史增量/阅读位置与弱网恢复 → 持久发送 → 消息呈现，
可选体验及独立产品能力由用户另行确认。具体完成标准见 [开发计划](./开发计划.md)。
