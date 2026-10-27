# Harmony v1.3.3 Mobile 差异评估

评估日期：2026-10-21。本文对照最终源码，不按提交标题直接认定功能缺失；
优先级表示建议开发顺序，不代表已经复现的实机缺陷等级。

## 1. 比较范围与结论

- 上游增量：`ebded1721..3482d51f4`，共 1754 个提交（2026-10-12 → 2026-10-21）。
- 其中触及 `apps/mobile` 的非合并提交为 313 个；Mobile 净差异 857 个文件
  （+55169 / −11429），约 35% 为测试、10% 为多语言资源。
- 上游区间未修改 `apps/harmony`；合并后 Harmony 跟踪文件与 `feat/v1.3.2` 完全一致。
- Harmony 对照基线为 `167e7e108`（v1.3.2 源码完成、review 修复后）。

结论：本期有两项 **Host 已经上线、Harmony 不跟进就会直接表现异常** 的兼容缺口——
富组件回答（`cindy-ui`）和 Codex 超快速度（`fastMode: 'ultrafast'`）。建议先解决这两项，
再补失败采样折叠等消息呈现回归；伙伴、云端伙伴、MCP Apps、侧边追问、声纹、系统分享接收等
仍属独立产品能力，不默认纳入。

## 2. Mobile 更新概览

| 更新领域 | 最终源码中的主要变化 | Harmony 判断 |
|---|---|---|
| 回答呈现 | `cindy-ui` 流式组件协议（图表 / 统计 / SVG / 表单控件 / 视频站播放器）；失败采样折叠；Harness 切换边界排序；工具原生图片 / 视频留在工作详情 | **兼容缺口，优先跟进** |
| 模型 | Codex Ultrafast 与 Ultra 思考档；Auto 默认按模型 ID 跟随来源；收藏其他电脑上的模型 | Ultrafast 是兼容缺口；其余可选 |
| 交互 | 新交互类型「代输入」`input_handoff`；异步询问的跨轮次补充回复；问题内文件 / URL 可点击 | Harmony 已安全降级，可选增强 |
| 发送与缓存 | 发件箱投递少走往返、打字预热 `maker:session:prewarm`；桌面 / 手机统一任务缓存与完成补读 | 预热可选；5b 持久发件箱仍待独立规划 |
| 错误与网络 | 统一错误卡 + 「诊断」入口；区分本机断网与远程电脑离线；离线无缓存提示；`device-removed` 连接问题 | 体验增强，按需跟进 |
| 界面体验 | 我的消息气泡颜色；归档筛选提醒点；项目标题滑动新建与项目搜索；图片加载占位；Codex 重置自动使用 | 可选 |
| 独立能力 | 云端伙伴、伙伴自带 IM 机器人、群聊引用回复 / 解散；MCP Apps 与通用交互卡；邮件卡片；侧边追问；本地声纹过滤；iOS 系统分享接收；远程桌面；Cindy Make（已隐藏） | 独立规划 |

## 3. 建议优先跟进

### A1. 富组件回答 `cindy-ui`（兼容缺口，最高优先）

- 上游 `ANSWER_DELIVERY_PROMPT` 已注入每个任务和伙伴的系统提示，指导模型用
  ` ```cindy-ui ` 围栏输出逐行 JSON 操作（create / append / patch / move / remove），
  组件包括 text / markdown / heading / icon / stack / row / grid / divider / image / video /
  audio / code / math / diagram / stat / chart / svg / range / input / check / select /
  details / tabs / button / form。
- Host 向远程端下发的是原文；超长时 `compactRichAnswer` 只保留完整操作行，不会替控制端转成
  Markdown。桌面任务列表预览已用 `richAnswerText` 处理，**会话正文没有处理**。
- Harmony 没有任何 `cindy-ui` 解析：模型越常用这个协议，Harmony 会话里出现大段 JSON 代码块的
  频率就越高；复制正文也会复制到 JSON 源码。
- 建议分两步：
  1. **兜底（必须）**：移植 `splitRichAnswer` / `richAnswerText`，至少把组件文档转成可读文本，
     复制走 `richAnswerText`，让 `isDeliveryProseText` 把含组件的回答视为正式交付。
  2. **原生渲染**：用 ArkUI 原生组件实现 `RichAnswerStream` 的增量解析与布局
     （< 600vp 自动单列、`mobileColumns`、颜色只用语义角色、双主题），chart / svg 用 Canvas
     或 Shape，控件状态按「账号 / 设备 / 消息」本地持久化，按钮只改本地值。
     视频站链接（YouTube）可先降级为链接。
- 约束：128 KB / 2048 节点 / 深度 32 上限，未知或格式错误的操作显示可读兜底，绝不执行代码。

证据：`packages/maker-shared/src/richAnswer.ts`、`richAnswerVisual.ts`、`richAnswerGuide.ts`、
`apps/mobile/src/session/RichAnswer.tsx`、`MessageRenderer.tsx`（`splitRichAnswer` / `richAnswerText`）、
`apps/desktop/src/main/device-link/dispatch.ts`（`compactRemoteMessageContent`）。

### A2. Codex 超快速度 `fastMode: 'ultrafast'` 与 Ultra 档（兼容缺口）

- #6559 把 `fastMode` 从布尔扩展为 `boolean | 'ultrafast'`，并补 `ultra` 思考档；
  上游专门修了「跨账号与远程边界保留 Ultrafast」。
- Harmony 用 `readBool` 读取 `fastMode`，字符串值一律回落为 `false`：
  - `TaskModels.ets` 读任务时，Ultrafast 任务被显示为未开快速；
  - `InputQueueStore.ets`（排队派发与重建发送）和 `MessageStore.ets` 把 `createOpts.fastMode`
    写成 `false` 回传 Host，存在把桌面设好的 Ultrafast **静默降级**的风险
    （Host 是否在已有任务上采用该字段需在开发时核实）；
  - `SessionAgentSwitch.ets` 遇到非布尔 `fastMode` 直接判定意图无效。
- 建议：把 fastMode 建模为三态并原样往返；未知值不改写；模型行展示超快状态、能力按目录声明；
  思考档列表接受 `ultra`。回归旧 Host 只返回布尔的情况。

证据：`packages/maker-shared/src/deviceLinkContract.ts`、`systemCard.ts`、
`apps/mobile/src/session/types.ts`、`unifiedMobileModels.ts`、`ModelSpeedIcon.tsx`；
Harmony `core/tasks/TaskModels.ets`、`SessionAgentSwitch.ets`、`NewSessionRuntimeDefaults.ets`、
`core/messages/InputQueueStore.ets`、`MessageStore.ets`、`components/ComposerModelOptionRow.ets`。

### A3. 消息呈现增量

- **失败采样折叠**：Codex 流重试时，失败那次的部分输出带 `agentMeta.failedSamplingAttempt`；
  Mobile 不把它当最终回答 / 交付正文 / 回合完成，而是收进工作过程折叠。Harmony 不识别该字段，
  会把失败草稿当正式回答显示，重试成功后看起来像重复回答。
- **Harness 切换边界**：`agent_switch` 行属于它之后那次发送，乐观气泡不得越过尚未被下一条
  发送观察到的切换行（#6260）。Harmony 已支持跨 Agent 切换，需核对乐观消息排序。
- **工具原生媒体**：MCP / Anthropic / Pi 内容块中的图片、视频留在对应工具步骤里，
  不从正文或命令里推断（`toolProcessMedia.ts`）。Harmony 已有 `tool_media`，需对照提取规则。
- **来源标签**：新增 `mcp-app:` 前缀的插件来源与跨电脑来源任务 `deviceId::sessionId`
  （显示但不可跳转）。Harmony v1.3.2 已接入来源呈现，补这两个分支即可。

证据：`packages/maker-shared/src/messageRender.ts`、`messageSource.ts`、`toolProcessMedia.ts`、
`apps/mobile/src/session/messageNormalize.ts`、`optimisticUserMessages.ts`；
Harmony `core/messages/MessageRender.ets`、`MessageStore.ets`、`pages/TaskPage.ets`。

## 4. 已安全降级、可选增强

| 主题 | 现状与建议 |
|---|---|
| 代输入 `input_handoff` | 新交互：Agent 把验证码、扫码等需要主人填写的步骤交给主人，逐步签名提交，结束时写入隐藏续接行 `[Input handoff ended]`。Harmony 当作未知交互显示「请求」状态卡，不阻塞输入框，隐藏续接行也会按 `[UI_ACTION_TRIGGER]` 隐藏，**不会卡死**。真正支持要接每步提交通道、二维码 / 图片步骤和设备码，建议独立切片 |
| 异步询问补充回复 | 卡片被取消或过期但用户已在编辑时保留草稿，确认取消后改作普通用户消息（插话或入队）。依赖 `retainedDraft` 与 `aroundMessagesByClientId`，可在 v1.3.2 确认回执基础上增量做 |
| 问题内引用可点击 | `questionReferences.ts` 拆出文件路径与 URL，引用变化后重新校验文件。体量小 |
| 发送预热 | `maker:session:prewarm` 打字时预热 Agent，旧 Host 返回 `CHANNEL_NOT_ALLOWED` 时忽略。纯性能项 |
| 错误卡与诊断 | 统一错误卡布局，展开详情后提供「诊断」（预填内容需脱敏 reason）；旧任务闭流错误提供可读历史恢复入口 |
| 网络归因 | 区分本机网络故障与远程电脑离线；离线且无缓存时显示历史未缓存提示；新增 `device-removed` 连接问题（提示重新登录） |
| Codex 重置自动使用 | 新增 `maker:usage:codex-reset-auto-use`，按电脑与 ChatGPT 账号保存条件。Harmony 已读 Codex 额度，可在现有用量菜单扩展 |
| 界面细节 | 我的消息气泡颜色（只染自己的消息、保证文字可读）、归档筛选提醒点、图片加载占位与转圈、项目标题滑动新建任务与项目搜索、待发送队列图片预览 |

## 5. 独立功能，不默认纳入 v1.3.3

| 能力 | 本次增量 | 为什么需要独立确认 |
|---|---|---|
| 伙伴 / 云端伙伴 | 云端伙伴与换主力电脑；伙伴自带 IM 机器人；跨设备完整历史；群聊引用回复、解散、设置管理 | Harmony 尚无伙伴入口，需整套数据与导航 |
| MCP Apps / 插件卡片 / 邮件卡 | 标准 MCP Apps、通用交互卡、邮件草稿发送与阅读 | 涉及沙箱 WebView 与插件权限规则 |
| 侧边追问 | `maker:side-chat:v1` / `list:v1`、选区追问入口 | 新的任务关系与导航 |
| 跨电脑 Agent 管理 | Agent 跨电脑管理定时任务、给其他电脑任务发消息 | 远程 Agent 路由仍单独规划 |
| 语音 / 声纹、系统分享接收、远程桌面 | 本地声纹过滤；iOS 分享内容路由到任务；远程桌面剪贴板与控制恢复 | 原生工程量大，Harmony 一期不做语音与分享接收 |
| Cindy Make | 个人版同步与提交给官方 | 上游已隐藏并禁用全部入口，不跟进 |

## 6. 不直接迁移

- 不复制 Android 应用内更新、R8、iOS 原生顶栏 / Liquid Glass、模拟器脚本和 RN 测试卫生规则。
- 文件预览、HTML 缓存、远程文件取回等大量修复针对 Mobile 自己的缓存实现；Harmony 的文件链路不同，
  只在对应场景实测出问题时再参考。
- 共享访客、供应商组、远程 Agent 相关修复随对应独立能力一起评估。

## 7. 本次完成与后续验证

已完成：基于 `feat/v1.3.2` 创建 `feat/v1.3.3`，合并上游 `3482d51f4`（合并提交 `fdc73c434`，
无冲突，带 DCO），梳理 Mobile 提交 / 净差异并对关键源码做了对照。

开发阶段（2026-10-22）已按 A1 兜底 → A2 → A3 → A1 原生渲染完成第 3 节全部项，结果与验证见
[README](./README.md)。开发时的两点修正：

- A2：Host 对设置类频道是加法编码（`fastMode: true` + `fastModeTier: 'ultrafast'`），旧 Harmony 读到的是
  「快速」而非「关闭」；真正的风险在回写——发送和 lazy create 会把 `true` 写回 Host，把超快降为快速。
- A3：工具结果的 `cindy_process_media` 展示信封不处理时，Harmony 会把整段 JSON 当工具输出显示；
  同期上游的生图交付重试（#6420）体量小，一并纳入。Harness 切换边界与跨电脑来源无需移植（D-012）。

第 4 节可选增强、5b 持久发件箱与第 5 节独立能力仍需另行确认。
