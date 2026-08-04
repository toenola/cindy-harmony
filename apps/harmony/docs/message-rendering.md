# 消息流与渲染

> 状态：Draft

## 1. 目标

一期不做“纯文本消息 Demo”，而是完整承载 Cindy 核心 AI 交互产生的消息类型和历史状态。

消息流应与桌面端同源、与现有 Mobile 的展示语义对齐，但 UI 使用 ArkUI 原生布局。

## 2. 数据管线

```text
Device Link invoke / push
        ↓
RemoteMessageStore
        ↓
Raw message preservation
        ↓
MessageNormalizer
        ↓
RenderItem builder
        ↓
Message window / paging
        ↓
ArkUI MessageList
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

复杂内容不能因为一期没有完整编辑能力而在历史消息中丢失；可以先提供源码、摘要或查看入口。

## 6. 消息动作

一期核心动作：

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
