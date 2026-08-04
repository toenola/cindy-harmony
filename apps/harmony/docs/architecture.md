# Harmony 架构方案

> 状态：Draft

## 1. 总体结构

```text
ArkUI 页面
    ↓
ArkTS Components / ViewModel
    ↓
Domain Stores
    ↓
Auth / Device Link / Message / Attachment Services
    ↓
HarmonyOS HTTP / WebSocket / Secure Storage
    ↓
Cindy Auth Server / Device Link Relay / Desktop Cindy
```

Harmony 端是远程控制壳，不运行桌面 Agent。

## 2. 工程边界

`apps/harmony` 是独立 DevEco Stage 工程：

- 不放入 `apps/mobile`。
- 不直接依赖 Expo、React Native 或 Electron。
- 不修改桌面 Agent 的执行环境。
- 不在鸿蒙端运行 Claude Code、Codex、Pi、MCP 或本地 SQLite。
- 不新增一套 Harmony 专用远程协议。

## 3. ArkUI 页面层

页面层只负责导航和布局：

```text
pages/
├── LoginPage
├── HomePage
├── TaskPage
└── SettingsPage
```

用户交互页面可以使用独立的 route 或 sheet：

```text
PermissionPage / Dialog
AskUserPage / Dialog
PlanReviewPage
ImagePreviewPage
```

页面不能直接创建 WebSocket，也不能直接拼装 Device Link envelope。

## 4. Component 层

组件只消费结构化 ViewModel：

```text
components/
├── TaskList
├── MessageList
├── MessageItem
├── WorkGroupBlock
├── ToolBlock
├── TodoBlock
├── Composer
├── AttachmentTray
├── InteractionSurface
└── ConnectionBanner
```

组件不应该知道桌面端数据库、远程 channel 名称或 Token 细节。

## 5. Domain Store

建议以 Store 管理长生命周期状态：

```text
core/
├── auth/
├── device-link/
├── tasks/
├── messages/
├── attachments/
├── interactions/
└── storage/
```

Store 负责：

- 状态归一化。
- 订阅和取消订阅。
- 历史消息窗口。
- 重连后的数据补齐。
- 消息去重和流式合并。
- 附件上传状态。
- Interaction request / resolve 状态。

## 6. 跨端复用策略

当前不强行把整个 TypeScript workspace 编译进 ArkTS：

- `cindy-protocol` 是 wire protocol 权威源。
- `packages/device-link` 是 Device Link 行为和兼容性参考。
- `packages/maker-shared` 是消息、任务和交互模型参考。
- `packages/auth-client` 是认证 API 和错误语义参考。
- `apps/mobile` 是已有控制端行为、fixture 和资源参考。

如果后续确认某段纯 TypeScript 可被 ArkTS 稳定使用，再单独抽取共享；不要先建立复杂的 JS/ArkTS bridge。

## 7. 消息数据不变量

- 桌面端是消息和任务的权威来源。
- 鸿蒙端不能把 Tool、Thinking、Todo、媒体或附件降级为不可恢复的纯文本。
- 本地缓存用于恢复 UI 和减少重复请求，不取代远端事实。
- 任何消息窗口更新都必须具备稳定排序和去重键。
- 重连后必须能够从远端补齐离线期间的消息。

## 8. 复杂内容承载

默认使用 ArkUI 原生组件展示：

- 普通文本
- Markdown 基础块
- 代码
- 列表
- 引用
- Tool / Todo 折叠
- 图片缩略图

可以局部使用 ArkWeb 展示：

- Mermaid
- Math / KaTeX
- 复杂 HTML Markdown
- 复杂媒体预览

ArkWeb 是局部内容 renderer，不改变应用整体使用 ArkUI 的决定。
