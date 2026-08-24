# 行为对齐 Mobile（iOS / Android）的实现原则

> 状态：已决定（2026-08-04）
>
> 本文件是 Harmony 客户端**用户可见行为**的实现准绳：实现任何消息 / 交互 /
> 渲染 / 加载行为前，先读对应的 Mobile 或共享纯逻辑源码，确认语义后再写
> ArkTS；**禁止凭猜测或想当然发明行为**。

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
| 断线补齐（gap healing） | `apps/mobile/src/session/historyWindowGap.ts` | 切片 5 |
| 消息滚动（分页触发 / 锚点 / 阅读位置） | `apps/mobile/src/session/messageScroll.ts` | 切片 2.4 |
| 输入投影（发送中 / 队列 / 失败重试 / 暂停） | `apps/mobile/src/session/inputProjection.ts` | 切片 3 |
| 行内原子（quote / 粘贴段 / slash） | `apps/mobile/src/session/sentMessageAtoms.ts` | 后续增强 |
| Composer 文档模型（手打 / 粘贴 / 引用恢复） | `apps/mobile/src/session/composerDocument.ts` | 切片 3 |
| 图片 / 附件（选择 / 压缩 / 上传 / 恢复） | `apps/mobile/src/session/mobileImageAttachment.ts`、`mobileImagePreprocess.ts`、`mobileAttachmentUpload.ts`、`messageAttachments.ts` | 切片 3 |
| 会话引用 / 历史窗口 | `apps/mobile/src/session/sessionReferences.ts` | 后续 |
| 交互确认（Permission / Ask User / Plan Review） | 切片 4 开始时查 `apps/mobile/src` 对应实现 | 切片 4 |

## 4. 已踩坑案例（教训）

**粘贴文本块**：曾假设由消息数据里的 `pastedTextRanges` 标记驱动折叠，
开发了发送侧 diff 检测 + 渲染侧区间解析。实际 Mobile 的行为是
`userMessageCollapse.ts` 的**视觉行数阈值**（手打 14 行 / 自动化 4 行），
`pastedTextRanges` 只用于行内原子渲染。教训：行为差异先查源码，不猜数据。

## 5. 例外与边界

- 一期明确不做的能力（语音 / 推送 / 视频上传等）不适用本对齐要求；
- 若 Mobile 行为本身有 bug 或明显不适配鸿蒙（如依赖 iOS 私有能力），
  记录差异到 `decision-log.md` 再偏离；
- 跨端协议层（Device Link / 认证）仍以 `packages/device-link-protocol` 与
  `packages/device-link` 为权威，本文件只管客户端行为表现。
