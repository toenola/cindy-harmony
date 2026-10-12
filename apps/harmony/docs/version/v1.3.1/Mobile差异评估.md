# Harmony v1.3.1 Mobile 差异评估

评估日期：2026-09-10。本文是源码对照和排期建议，不代表功能已经实现或完成设备验证。

## 1. 分支与比较范围

- 从 `feat/v1.3.0` 的 `4ef9bc886` 创建 `feat/v1.3.1`。
- 上次上游基线：`8de9825e7`；本次上游：`abcf92c2b`。
- 上游区间共 958 个提交，其中触及 `apps/mobile` 的非合并提交为 200 个；这不是 200 个独立功能。
- 普通合并提交：`054464f64`，带 DCO 签名，无冲突。
- 上游区间没有修改 `apps/harmony`，合并也未改变 Harmony 文件。本机签名配置和原有未跟踪目录保留。
- 仅完成本地分支和合并，未推送，未调整应用内版本号。

## 2. 建议优先跟进

以下优先级表示开发顺序，不是已经复现的缺陷等级。

| 顺序 | Mobile 更新 | 鸿蒙现状与判断 | 建议范围 |
|---|---|---|---|
| 1 | 按可见内容分页，工作详情按需读取；协商历史视图能力，兼容旧 Host | `DlProtocol.ets` / `MessageStore.ets` 仍使用原始消息分页，未接入 `messages:view`、`messages:work-details`、`messages:view-intent`。已有历史补齐和订阅代次保护，应增量演进 | 增加历史视图适配、能力协商与旧 Host 回退；折叠工作组只取摘要，展开再取详情 |
| 2 | 流式正文与历史交接、迟到响应作废、重连请求合并、独立重试、离线缓存可读 | 鸿蒙已有 `resubscribeAndHeal`、恢复代次、串行订阅和缓存，不应认定这些能力全部缺失；需逐条核对本次新增边界 | 优先验证终态正文不丢、不乱序；同窗口请求合并；一个读取失败不重放所有读取；新推送不被旧快照覆盖 |
| 3 | 多账号供应商目录、停用来源的实际路由显示、模型可见性与有效配置同步 | 鸿蒙已按 `providerId` 分组并支持付费限制；但 `ComposerCatalog.ets` 直接过滤 `suspended`，没有 Mobile 的现有任务实际路由豁免 | 保留现有任务当前停用来源的选中行，同时禁止将其用于新路由；核对多账号来源、默认来源与加载未就绪状态 |
| 4 | 切换小上下文模型前保护 | 鸿蒙保存并展示上下文用量，但当前模型目录和切换链未发现对应窗口保护 | 移植 Mobile 语义：已知用量下，本地达到目标窗口需确认；SSH 达到目标窗口 90% 时阻止切换；未知数据不自行猜测 |
| 5 | 新建任务记住项目/对话选择及每台电脑最后显式目录 | 鸿蒙已有本地新任务草稿，但未发现等价的按账号、设备持久化目录映射 | 在现有新建草稿入口补记忆；显式选择优先于最近任务推断，路径原样保存，账号间隔离 |
| 6 | 项目机器标注，同名设备用 ID 消歧 | 鸿蒙已有设备与项目分组；需要按实际页面核对是否满足新规则 | 全设备视图显示机器身份，选定单设备后避免重复标注；同名设备消歧，离线状态保持可见 |

主要源码证据（路径相对仓库根）：

- 历史能力协商：`apps/mobile/src/device-link/historyViewCapability.ts`。
- 历史视图生命周期：`apps/mobile/src/session/remoteHistoryViews.ts`、`remoteHistoryView.ts`。
- 同窗口读取合并与逐项发布：`apps/mobile/src/device-link/sessionSnapshotSingleFlight.ts`。
- 鸿蒙现有恢复：`apps/harmony/entry/src/main/ets/core/messages/MessageStore.ets`。
- 供应商新旧路由差异：`apps/mobile/src/session/providerModelSections.ts`，对照 `apps/harmony/entry/src/main/ets/core/ComposerCatalog.ets`。
- 窗口保护：`apps/mobile/src/session/modelWindowSwitchConfirmation.ts`。
- 新建偏好：`apps/mobile/src/session/newSessionPreferenceStore.ts`。
- 机器标注：`apps/mobile/src/session/homeProjectMachineIdentity.ts`。

## 3. 随现有能力补齐体验

| 更新主题 | 评估与建议 |
|---|---|
| 历史磁盘缓存与重进任务 | 鸿蒙 `SessionMessageCacheStore.ets` 目前上限为 12 个任务、每任务 80 条、总量约 4 MiB，是最近窗口快照，不等价于 Mobile 历史视图磁盘缓存。若目标是长历史重进即读，应单独设计分页缓存、失效和账号隔离，不能只调大常量。Mobile 区间曾加入 1 GiB 上限，后续又取消容量淘汰，应以最终源码为准 |
| 长任务渲染与滚动 | Mobile 增加列表回收、已完成块复用、折叠详情延迟构造、流式更新范围缩小、手势优先滚底。鸿蒙应对照行为与性能目标，使用 ArkUI 实现；优先测上翻补页、边读边生成、发送后已完成分组稳定 |
| 发送与附件连续性 | Mobile 统一待发送与正式消息附件布局、保留本地预览直至正式媒体接管。鸿蒙已有队列与附件，应回归发送确认时是否闪图、跳高、清空新草稿，而非重新增加一套队列 |
| 收起输入框与前后台恢复 | Mobile #4218 修复的是 WebView 延迟输入同步，#4209 修复 WebView 恢复。鸿蒙 `ConversationComposer.ets` 使用原生 TextArea 的 onChange，不适合照搬脚本；应测试中文组合输入、收起再展开、后台返回后编辑与草稿保留 |
| 图片与分享 | Mobile 更新 HEIC/HEIF 归一化、图片缩放复位、分享长图保留正文/粘贴图片及本地尺寸。鸿蒙已有图片处理与分享模块，按这些场景验证格式、预览与分享结果，再补实缺 |
| 用量与价格 | Mobile 菜单增加配额/用量摘要，模型页展示折扣。鸿蒙当前有上下文 tokens 显示，不等价于账户额度；可以补充，但需按真实 provider 路由和币种投影，不能将账户总量当成当前任务用量 |
| 同步状态提示 | Mobile 普通同步使用延迟标题动画，异常采用悬浮提示。鸿蒙应保留可读内容，区分首屏加载、后台更新和连接失败，避免每次同步阻断交互 |
| 工作过程呈现 | 压缩/目标记录轻量分隔、Subagent 简化标题与 token 摘要、消息菜单图标等，可在既有工作组与系统卡片实现中逐项对照 |
| 本地诊断 | Mobile 增加详细本地 Debug 日志与手动上传摘要。鸿蒙已有日志入口但不等价于该完整链路，可独立补充；必须先核对凭证、存储和脱敏规则 |

对应参考：`remoteHistoryDiskCache.ts`、`historyDiskStore.ts`、`messageTailFollower.ts`、`messageRenderReconcile.ts`、`sentMessageImagePreviews.ts`、`readSessionMenuAccountUsage.ts`，以及 `apps/mobile/src/debug/`。

## 4. 大功能独立评估

| 能力 | 本次发现 | 建议 |
|---|---|---|
| Cindy 登录多账号切换 | Mobile 新增添加/切换已保存账号，以及凭证轮转、账号代次和资源隔离；鸿蒙 AuthStore 当前为单账号字段 | 独立规划。必须同时覆盖凭证事务、设备连接、消息缓存、草稿与推送归属，不能只增加账号菜单 |
| 伙伴与跨电脑远程控制 | Mobile 新增伙伴入口、直聊和远程资源能力（#3912） | 独立核对产品范围和 Host 能力；区别于现有同账号设备任务控制 |
| 远程桌面 | Mobile 新增桌面画面、输入控制、剪贴板、音频、网络统计及 ICE/TURN 恢复 | 单独项目规模，涉及 Harmony 媒体与输入适配。建议不默认塞入 1.3.1 兼容修复范围 |
| 语音听写 | Mobile 调整光标插入、选区、停止后的用户编辑与词汇学习 | 鸿蒙现有语音词典只读同步不代表已有完整听写；完整输入能力单独规划 |

以上大功能仍独立规划。2026-09-10 用户已确认本期四项改动，具体范围以 [开发计划](./开发计划.md) 为准。

## 5. 不直接迁移的更新

- iOS 系统导航栏、菜单、Sheet、原生字体垂直对齐和列表锚定代码：对齐体验，继续采用鸿蒙原生组件与既定弹层规则。
- React Native worklet、Android WebView 85、Metro/Gradle、iOS 模拟器构建修复：不属于 ArkUI 工程实现。
- Expo OTA、自托管原生热更、SSO Canary OTA：不复制到 Harmony 更新链。
- SkillHub 提交虽触及 Mobile，本次未在 Mobile 页面与源码中检出完整 SkillHub 入口，不能只按提交标题认定手机新增了完整技能市场。

## 6. 建议的 1.3.1 范围与验证

建议按“消息完整性与连接恢复 → 模型来源兼容及窗口保护 → 新建偏好 → 现有交互回归”的顺序推进。历史视图改造相对较大，可单独成组交付；多账号登录、伙伴、远程桌面和完整语音能力另列范围。

本次已完成 Git 合并检查、Harmony 合并差异检查及关键源码对照。未运行单元测试、HAP 构建、Mobile/根级测试或设备验证；Harmony 业务代码未改变，因此不将本次合并视为新版功能或运行时兼容性验收。

后续实现需覆盖：新旧 Host、离线/切网/后台返回、长历史上翻与流式交接、多设备同名项目、供应商停用与账号来源变化，以及 Light/Dark、窄屏/展开横屏。具体断言以各模块最终源码为准。
