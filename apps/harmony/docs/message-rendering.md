# 消息流与渲染

本文说明历史、实时与渲染之间的契约；修改消息解析、分页、滚动或卡片呈现前阅读。先按 [Mobile 对齐](mobile-alignment.md)核对共享实现。

## 1. 目标

消息保留 Cindy 的结构化内容与历史状态，不能简化为纯文本。

消息流应与桌面端同源、与现有 Mobile 的展示语义对齐，但 UI 使用 ArkUI 原生布局。

## 2. 数据管线

```text
Device Link invoke / push
        ↓
core/messages/MessageStore.ets
        ↓
原始消息、历史窗口与 push 合并
        ↓
MessageRender.ets / MessagePayload.ets
        ↓
渲染项投影（含 RichAnswer.ets）
        ↓
Message window / paging
        ↓
TaskPage.ets / RichAnswerView.ets
```

原始数据不能在第一步被压扁为纯文本。至少保留：

- 消息身份和时间。
- 稳定 message id。
- Tool 调用和结果关联。
- Thinking 内容。
- Todo 状态。
- Work Group 结构。
- 图片、媒体和附件引用。
- 错误和交互等待信息。

## 3. 历史和实时

必须支持：

- 加载最新消息。
- 向上加载更早消息。
- 按消息附近窗口加载。
- 流式增量合并。
- 消息去重。
- 稳定排序。
- 重连后的 gap healing。
- 用户阅读旧消息时不被新消息强制拉底。
- 新消息提示和回到底部。
- 任务重新打开后的历史恢复。

运行中的工作过程按 Mobile 的正文边界实时收口：同一轮收到非空 assistant 正文后，
正文之前的工作组立即由“正在工作”变为“已工作”；正文之后若继续出现工具或思考，
再建立新的活动工作组。该变化不能等待整轮 done，也不能依赖退出会话后重载历史。
实时 push 与历史行同毫秒且 push 缺少 DB rowid 时，保留消息到达顺序。

历史分页节奏与 Mobile/iOS 对齐：最新页和更早页均以 80 条持久消息行为标准页，
Device Link payload 过大时再逐档缩小。短首屏在仍处于近顶区域时最多自动补三页；
用户明确上翻后，只要补页完成仍在近顶预取区，就继续串行加载，直到离开预取区、
历史到底、首项没有前移或请求失败。prepend 必须保持用户当前阅读锚点，冷开自动补窗
则继续贴住最新消息。

消息列表采用窗口化或增量渲染，不能因为历史增长而不断重建全部 UI。

## 4. 消息类型

### 普通内容

- 普通文本。
- 段落。
- 标题。
- 有序和无序列表。
- 引用。
- 表格。
- 行内代码。
- 代码块。
- 链接。
- 图片。

### Agent 工作过程

- Thinking。
- Tool Use。
- Tool Result。
- Work Group。
- Todo。
- 系统状态。
- 错误。

### 远程交互和媒体

- Permission pending。
- Ask User pending。
- Plan Review pending。
- 图片附件。
- 视频、音频和文件引用。
- Diff / Payload 摘要或详情入口。

## 5. Renderer 分层

ArkUI 原生渲染：

- 普通文本。
- 基础 Markdown。
- 列表和引用。
- 代码块和横向滚动。
- Tool / Thinking / Todo 折叠。
- 图片缩略图和预览入口。

ArkWeb 或专用 renderer：

- Mermaid。
- Math / KaTeX。
- 复杂 HTML。
- 需要浏览器布局的媒体或文档内容。

复杂内容不得在历史消息中丢失；尚无专用 renderer 的内容提供源码、摘要或查看入口。具体已落地的文件预览及安全限制见[决策记录](decision-log.md#文件预览与导出差异)。

## 6. 消息动作

核心动作：

- 复制消息。
- 复制代码。
- 复制文件路径。
- 图片预览。
- Fork。
- Rewind。
- 打开详情。

Rewind 和 Fork 属于改变任务上下文的动作，必须有确认、防重复提交和失败恢复。

## 7. 数据测试

应从现有 Mobile / Desktop fixture 生成或复用覆盖：

- 长文本。
- 流式文本。
- 代码块。
- 多层列表。
- Tool Use / Result。
- Thinking。
- Todo。
- Work Group。
- 图片、视频、音频和文件引用。
- 错误消息。
- 交互等待。
- 断线期间产生的消息。

## 8. 当前扩展入口

富组件回答解析 `RichAnswer.ets` 对齐共享 `richAnswer.ts`，经 `MessageRender.ets.richParts` 投影，`RichAnswerView.ets` 原生呈现；本机控件值由 `RichInteractionMemory.ets` 管理，有意差异见 D-011。
工具过程媒体和生图交付重试走 `ToolProcessMedia.ets`；历史摘要 / 详情走 `HistoryViewAdapter.ets`，读请求去重与独立重试走 `SnapshotReadPool.ets` / `RemoteReadRetries.ets`，连接代次来自 DlClient。
修改这些路径同时检查历史和实时输入，不能只验证重新打开任务后的结果。
