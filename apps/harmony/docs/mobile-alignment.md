# 行为对齐 Mobile（iOS / Android）的实现原则

> 状态：已决定（2026-08-04）；本文说明行为事实源与 Harmony 专属对齐要求，修改任何用户可见行为前阅读。
>
> 本文件是 Harmony 客户端**用户可见行为**的实现准绳：实现任何消息 / 交互 /
> 渲染 / 加载行为前，先读对应的 Mobile 或共享纯逻辑源码，确认语义后再写
> ArkTS；**禁止凭猜测或想当然发明行为**。

视觉与组件选型不按 iOS 皮肤迁移，以[鸿蒙界面规范](./harmony-ui-design.md)为准。下文的 iOS 样式案例记录存量依据，涉及视觉冲突时按鸿蒙界面规范收敛。

## 1. 为什么

- **三端体验一致**：Mobile（iOS / Android）本身是对齐 Desktop 行为实现的；
  Harmony 再对齐 Mobile，就能保证三个客户端展示与交互一致，用户换设备不困惑。
- **降低开发成本**：判定逻辑、阈值、状态机、数据模型都有现成权威实现，
  移植语义比重新设计快得多。
- **避免理解偏差**：曾因未读 Mobile 代码，误以为"粘贴文本块"由
  `pastedTextRanges` 驱动，实际是**视觉行数阈值折叠**
  （`userMessageCollapse.ts`），导致反复返工。对照源码可避免这类问题。

## 2. 强制流程

实现任何**用户可见行为**（消息展示、折叠、滚动、分页、发送状态、附件、
交互确认等）前，必须：

1. 在下方对照表中找到对应模块的 Mobile / 共享源文件；
2. **完整读懂**该文件的判定逻辑与状态机；
3. 确认行为语义（阈值、配对规则、降级路径、错误处理）后再写 ArkTS；
4. 实现后回看：鸿蒙端行为是否与 Mobile 在相同输入下一致。

纯 UI 视觉表现仍用 ArkUI 原生组件；对齐的是**行为语义**，不是 RN 代码。

## 3. 模块对照表

| 行为模块 | 权威参考源码（必须先读） | Harmony 对应 |
|---|---|---|
| 消息归一化（tool 配对 / content 预览 / kind 归一化） | `packages/maker-shared/src/messageNormalize.ts` | `core/messages/MessageRender.ets` |
| 渲染模型构建（message / thinking / tool_group / work_group / todo / media） | `packages/maker-shared/src/messageRender.ts` | `core/messages/MessageRender.ets` |
| 长消息自动收起（行数阈值） | `apps/mobile/src/session/userMessageCollapse.ts` | `core/messages/MessageRender.ets` |
| 消息渲染组件（气泡 / 折叠 / 动作栏 / 菜单） | `apps/mobile/src/session/MessageRenderer.tsx` | `pages/TaskPage.ets` |
| 历史加载 / 流式合并 / 去重 / push 应用 | `apps/mobile/src/session/remoteSessionStore.ts` | `core/messages/MessageStore.ets` |
| 断线补齐（gap healing） | `apps/mobile/src/session/historyWindowGap.ts` | `core/messages/HistoryGap.ets`、`HistoryWindowCoverage.ets`、`MessageStore.ets` |
| 消息滚动（分页触发 / 锚点 / 阅读位置） | `apps/mobile/src/session/messageScroll.ts` | `pages/TaskPage.ets`、`core/messages/MessagePaging.ets` |
| 回复后的输入建议 | `apps/mobile/src/session/usePromptRecommendation.ts`、`promptRecommendationPreference.ts`、`usePromptRecommendationVisibility.ts`、`PromptRecommendation.tsx` | `core/messages/PromptRecommendation*.ets`、`components/PromptRecommendationPanel.ets` |
| 输入投影（发送中 / 队列 / 失败重试 / 暂停） | `apps/mobile/src/session/inputProjection.ts` | `core/messages/InputQueueStore.ets`、`ComposerDocument.ets`；附件见 `core/attachments/` |
| 行内原子（quote / 粘贴段 / slash） | `apps/mobile/src/session/sentMessageAtoms.ts` | `core/messages/ComposerDocument.ets`、`MessageRender.ets` |
| Composer 文档模型（手打 / 粘贴 / 引用恢复） | `apps/mobile/src/session/composerDocument.ts` | `core/messages/ComposerDocument.ets`、`ComposerDraftStore.ets` |
| 用量概览（额度 / 30 天趋势 / 模型分组） | `apps/mobile/src/widgets/UsageDashboard.tsx`、`UsageQuotaColumns.tsx`、`usageWidgetSync.ts`；共享 `deviceLinkContract.ts` | `core/usage/UsageDashboard.ets`、`components/UsageDashboardPanel.ets` |
| 图片 / 附件（选择 / 压缩 / 上传 / 恢复） | `apps/mobile/src/session/mobileImageAttachment.ts`、`mobileImagePreprocess.ts`、`mobileAttachmentUpload.ts`、`messageAttachments.ts` | `core/attachments/ComposerImageQueue.ets`、`ImagePreprocess.ets`、`AttachmentUpload.ets`；`core/messages/MessagePayload.ets` |
| 会话引用 / 历史窗口 | `apps/mobile/src/session/sessionReferences.ts` | `core/messages/HistoryViewAdapter.ets`、`pages/TaskPage.ets` |
| 交互确认（Permission / Ask User / Plan Review） | `apps/mobile/src/session/` 的交互实现；共享交互契约 | `core/interactions/InteractionStore.ets`、`InteractionPresentation.ets`、`pages/TaskPage.ets` |

## 4. 已踩坑案例（教训）

**粘贴文本块**：曾假设由消息数据里的 `pastedTextRanges` 标记驱动折叠，
开发了发送侧 diff 检测 + 渲染侧区间解析。实际 Mobile 的行为是
`userMessageCollapse.ts` 的**视觉行数阈值**（手打 14 行 / 自动化 4 行），
`pastedTextRanges` 只用于行内原子渲染。教训：行为差异先查源码，不猜数据。

## 5. 例外与边界

- 尚未移植的能力不因本规则自动进入开发范围；已经存在的入口仍须对齐，不再沿用一期排除清单判断现状；
- 若 Mobile 行为本身有 bug 或明显不适配鸿蒙（如依赖 iOS 私有能力），
  记录差异到 `decision-log.md` 再偏离；
- 跨端协议层（Device Link / 认证）仍以 `packages/device-link-protocol` 与
  `packages/device-link` 为权威，本文件只管客户端行为表现。

## 6. 鸿蒙首页用量入口

按用户指定，底部为「项目 / 沟通 / 自动化」。自动化任务的置顶与搜索结果归入自动化页签。用量由列表顶部入口打开，在展开屏占右侧详情区域，左侧保留此前的列表和滚动位置；单栏时全屏显示，返回后恢复原列表。
原任务详情节点和选择保留，点击左侧任务可返回会话。品牌额度图标使用与 iOS 同源的
OpenAI / Anthropic provider path，不使用 CLI Agent mark；不展示底部 Cindy 余额行。

用量复用 iOS 的 `device-link:usage-widget:snapshot:v1` 只读快照，额度和历史均由电脑端获取，
不在手机直连模型厂商。全部电脑范围依次尝试在线可控制电脑（优先 macOS），选定电脑范围
只读该电脑；快照里的 `usage.scope` 决定历史是本机还是全部电脑。打开、手动刷新或连接恢复
时读取；在线候选电脑变化后可恢复读取，不对会话 push 重复拉取，也不增加网络定时轮询。

图表和图例共用同一模型分组：模型数据结构完整时使用模型桶，缺失时整体回退到旧版 harness
桶；超过四个非空分组保留前三个模型，其余合并。空快照或不支持与真实零用量分开呈现。
跨账号、设备范围或中转代次清理旧快照，迟到结果不得回写；保留同范围失败前的快照和更新时间。

真机统一验收项：Light / Dark、折叠 / 展开、底栏切换、自动化对话及搜索、真实额度与历史、
手动刷新、离线恢复、电脑版本不支持、切换账号/设备/中转后的旧数据隔离。

## 7. 回复后的输入建议

设置里的「输入建议」仅保存在本手机，默认开启，可关闭或恢复默认。读取偏好失败时默认不开启，
避免覆盖原先关闭的选择；写入失败仍保留当前进程选择并明确告知未保存。

与 iOS 一致，复用电脑端 `maker:predict-prompt`：仅观察到正在运行→完成且完成版本推进时，
允许在 500ms 防抖后发起一次非 cache-only 请求。历史进入只查缓存；缓存未就绪最多在
1 / 3 / 5 秒后再读，不转成模型生成。请求失败等待连接恢复且只查缓存，普通重绘不得重复生成。
失败的回合不推荐，跨账号/设备/任务及退出后迟到响应失效。开关关闭取消尚未发出的请求；
已经发出的模型请求不重复发起，迟到结果不显示。

输入框上方显示单行建议胶囊，点击只填入草稿并聚焦，不自动发送；横向滑动忽略本次完成版本，
重进同一任务也不再次弹出。普通打字或聚焦只隐藏，不消费缓存；清空草稿或收起输入卡可恢复。
附件、引用、编辑消息/队列、待确认交互、发送中与隐藏任务详情不展示。输入建议不参与模型提示词
编写或工具协议修改，所有模型调用仍由电脑端完成。

真机统一验收项追加：设置本机开关、关闭/恢复默认、回复结束后建议显示、点击填入不发送、
横向滑动忽略、聚焦和输入/清空、附件和引用遮挡、历史不新生成、断线恢复、切任务/账号隔离。

## 8. 用量图形和提问面板布局

用量页品牌图标使用与 iOS 相同的 provider SVG 几何，分别提供 Light / Dark 原生图片资源，
不依赖 ArkUI Shape 子路径继承主题色；24vp 图标与 16vp 账号文字按中心对齐。日均虚线用
独立的短横条覆盖在走势图上，位置仍按同一平均值/峰值比例计算，不能被柱形或绘图裁剪吞掉。

Ask User 提问面板根据扣除标题栏和键盘后的实际可用高度设置上限，按正文和底部操作的真实测量高度收缩。
短内容不得用固定高度或 layoutWeight 撑开正文；仅长内容超过上限时滚动。标题仅显示文字，不加图标。问题、选项、自定义回答和错误
提示在正文区域滚动，提交/下一题等操作固定在底部；底部主次按钮统一 44vp 点击高度、88vp 最小宽度和相同外边距，滚动正文显式顶部对齐，避免短问题被默认居中。不能把整张
提问卡再次包进固定 240vp 的外层 Scroll，导致确认按钮出现在裁剪区域外。多问题切换与原有
回答校验、取消和跳过语义不变。验收包括展开/合盖、长问题、多选项、键盘打开和底部确认按钮。

会话列表的 Claude / Codex 图标按用户指定复用用量页的 provider SVG，使用 24vp 图片置于 28vp 图标槽中，Light / Dark 跟随同源主题资源。

## 9. Ask User 的 iOS 分组样式

卡内只保留弱提示「等待回答」、问题标题和选项数/单多选/其他回答说明。按用户最新要求，
不显示方框外的队列说明行。选项与其他回答输入合成一个圆角分组，仅使用行间分隔线。
选项最小高度 46vp、14vp 正文、20vp 指示器，问题标题 15vp，与对话中的文字协调；
卡片内边距 16vp、区块间距 12vp。底部按钮统一 44vp 高度、88vp 最小宽度，禁用提交
使用弱化语义色。正文高度按测量值收缩，长内容才滚动，不用固定高度或权重撑出留白。
多题、约束选项、错误校验和回答提交仍走原有逻辑。

## 10. 弹层样式

菜单、底部表单、确认对话框和轻提示的视觉以鸿蒙系统弹层为准，信息组织借鉴 iOS（分组、当前值、二级箭头），
不再自造「Stack + 遮罩」浮层。具体 API、材质和迁移检查单见 [弹层标准](./overlay-standard.md)。
