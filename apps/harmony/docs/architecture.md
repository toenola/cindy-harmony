# Harmony 架构与代码地图

本文说明当前模块职责、数据流和功能入口。定位代码、决定新逻辑归属或修改跨层行为前阅读；工具链见[开发指南](../项目鸿蒙端开发指南.md)，行为约束见 [Mobile 对齐](mobile-alignment.md)。下文源码路径以 `entry/src/main/ets` 为基准。

## 1. 客户端边界

Harmony 是独立 Stage 工程，使用 HarmonyOS 7.0 / API 26+、ArkUI、ArkTS，不兼容 API 26 以下系统。
Agent、任务权威数据、工作目录、SQLite、CLI、MCP 和插件执行留在电脑端；不将 Expo、React Native 或 Electron 搬入工程。
页面经 Store / Service 调用平台适配，不创建 WebSocket、不拼协议 envelope。原始数据、解析、投影和长生命周期状态归 `core/`。

**禁止鸿蒙直接向模型厂商或 Agent 厂商查询信息。** 模型列表与能力、账号状态、配额与用量、Agent 信息必须经 Device Link 从电脑获取，由电脑负责厂商通信、认证和缓存。
官方接口、第三方中转或代理、厂商 SDK / CLI 均不能绕过这一限制；电脑离线、接口不支持或失败时不得回退直连，也不得向鸿蒙下发或保存厂商 API Key、OAuth token 等凭证。电脑端代查允许，Cindy 自身登录、设备互联和附件链路仍按既有通道处理（D-013）。

共享事实源：`packages/device-link-protocol` 管 wire contract，`packages/device-link` 管连接行为，`packages/maker-shared` 管消息与交互，`packages/auth-client` 管认证语义，Mobile 管用户可见行为。
不另造 Harmony 协议，不默认把整个 TS workspace 编译进 ArkTS；已需共享的传输逻辑经 `native/portable/build.mjs` 打包，Agent-Net 加密经原生桥接，见[中转专题](self-hosted-relay-plan.md)。
整体 UI 用 ArkUI，ArkWeb 仅承载局部复杂文档；消息不能被压扁成不可恢复的纯文本。本地缓存用于恢复 UI 与减少请求，不替代远端事实。

## 2. 运行时数据流

```text
EntryAbility
  → Index 初始化 AppServices
  → AuthStore 恢复登录态和 token
  → DlClient 连接 Device Link Relay
  → AppServices 建立设备控制链、订阅 topic、分发 push
  → TaskStore / MessageStore / InteractionStore / GoalStore 等更新
  → TaskListPage / TaskPage 订阅 Store 并刷新 ArkUI
```

桌面端始终是任务、消息和执行状态的权威来源。Harmony 的本地持久化只保存登录凭证、草稿、列表偏好等客户端状态，不能替代远端事实。

## 3. 工程根目录地图

```text
apps/harmony/
├── AppScope/                    # 应用级身份、版本、名称与图标资源
├── docs/                        # Harmony 专项产品、架构、行为与验证文档
├── entry/                       # 当前唯一 HAP 模块：源码、资源、测试和产物
├── hvigor/                      # Hvigor 工程配置
├── build-profile.json5         # SDK、产品、构建模式和现有签名配置
├── code-linter.json5           # ArkTS / ArkUI lint 规则
├── hvigorfile.ts               # 工程级 Hvigor 插件入口
├── oh-package.json5            # 工程级 OHPM 依赖
├── oh-package-lock.json5       # OHPM 锁文件
├── local.properties            # 本机 DevEco / SDK 路径，不作为跨机器事实源
└── 项目鸿蒙端开发指南.md        # 本文
```

| 路径 | 作用 | 修改时注意 |
|---|---|---|
| `AppScope/app.json5` | bundle、vendor、版本号和应用图标 | 修改应用身份、版本或区域前先读对应产品规则 |
| `AppScope/resources/` | 应用级名称和图标资源 | 与 `entry` 页面级资源区分开 |
| `docs/` | Harmony 专项设计与行为资料 | 详细状态机留在专项文档，本文只负责导航 |
| `entry/` | 唯一 HAP 模块 | 日常业务开发主要在这里 |
| `hvigor/hvigor-config.json5` | Hvigor 配置 | 通常无需修改 |
| `build-profile.json5` | product、API 26、debug/release 与签名配置 | 含现有本机签名材料信息，禁止复制到文档、日志或提交说明；不得为绕过签名错误擅改 |
| `code-linter.json5` | 静态检查规则 | 不通过弱化规则制造通过 |
| `oh-package.json5` | 工程级测试依赖 | Harmony 工程不按 pnpm / Expo 工程处理 |

修改对外版本时要同时核对 `AppScope/app.json5` 的 `versionName` / `versionCode` 与 `entry/src/main/ets/AppConfig.ets` 的 `appVersion`，避免安装包版本和 Device Link 上报版本漂移。

以下均为本地或构建生成内容，不是源码：

| 路径 | 作用 |
|---|---|
| `.idea/` | DevEco Studio 工程状态 |
| `.hvigor/` | Hvigor 同步缓存和日志 |
| `oh_modules/` | OHPM 安装依赖 |
| `entry/build/` | HAP、source map 和中间构建产物 |
| `entry/.test/` | 本地单测生成代码、缓存与报告；HTML 报告在 `.test/default/outputs/test/reports/index.html` |

## 4. `entry` 模块与源码目录

### 4.1 `entry` 顶层

```text
entry/
├── build-profile.json5         # entry 模块构建选项与 target
├── hvigorfile.ts               # HAP 模块 Hvigor 插件入口
├── obfuscation-rules.txt       # release 混淆规则；当前未启用混淆
├── oh-package.json5            # entry 模块依赖
└── src/
    ├── main/                   # 正式运行代码和资源
    ├── test/                   # 主机侧纯 ArkTS 单元测试
    ├── ohosTest/               # 设备 / 模拟器侧系统能力测试
    └── mock/                   # Harmony 测试 mock 配置
```

`entry/src/main/module.json5` 是 Stage 模块声明，管理：

- 主 Ability：`EntryAbility`；
- 设备类型：phone；
- `INTERNET` 权限；
- 页面路由清单；
- `cindy://session` 深链；
- backup extension。

新增页面时，除创建 `pages/*.ets` 外，还要更新 `entry/src/main/resources/base/profile/main_pages.json`。

### 4.2 正式 ArkTS 源码

```text
entry/src/main/ets/
├── AppConfig.ets               # 区域端点、客户端身份、locale、appVersion
├── entryability/               # 应用 / 窗口 / 前后台生命周期和深链接收
├── entrybackupability/         # 系统备份扩展
├── pages/                      # 页面布局和页面内交互
├── components/                 # 跨页面 ArkUI 组件和 UI token
├── core/                       # Store、协议、解析、投影和业务状态机
└── network/                    # Harmony HTTP / WebSocket 系统 API 适配
```

| 目录 | 作用 | 关键入口 |
|---|---|---|
| `entryability/` | Ability、窗口、系统栏、前后台、Want / 深链生命周期 | `EntryAbility.ets` |
| `entrybackupability/` | backup extension；当前配置不恢复业务数据 | `EntryBackupAbility.ets` |
| `pages/` | 页面布局、导航、builder 与交互接线 | `Index.ets`、`TaskListPage.ets`、`TaskPage.ets` |
| `components/` | 可复用输入区、字体、圆角、动效、点击反馈和 transition | `ConversationComposer.ets`、`UiKit.ets` |
| `core/` | 长生命周期业务状态、协议适配、数据解析和纯逻辑 | `AppServices.ets` |
| `network/` | 对 HarmonyOS HTTP / WebSocket API 的薄封装 | `HarmonyHttp.ets`、`HarmonyWsAdapter.ets`、`WsAdapter.ets` |

### 4.3 页面目录 `pages/`

| 文件 | 当前职责 |
|---|---|
| `Index.ets` | 冷启动入口：初始化 `AppServices`、恢复登录态，进入登录页或任务列表 |
| `LoginPage.ets` | 手机验证码登录 |
| `TaskListPage.ets` | 主页面：设备范围、项目 / 沟通 / 用量 Tab（自动化归入沟通）、搜索、排序、折叠、任务操作和宽屏分栏 |
| `TaskListPresentation.ets` | 任务分类、标题、项目名、时间和排序等纯展示逻辑 |
| `TaskSplitLayout.ets` | 按窗口与安全区尺寸判断分栏，并计算列表宽度和拖拽范围 |
| `TaskWindowMetrics.ets` | 根据系统栏、导航指示条和挖孔避让区计算安全区尺寸 |
| `NewSessionPage.ets` | 新建或编辑任务：Agent、模型、权限、工作目录、附件、首条消息和恢复 |
| `TaskPage.ets` | 会话详情：消息流、工作过程、Tool / Todo、Composer、附件、交互请求、搜索、分页和媒体预览 |
| `SettingsPage.ets` | 设置入口和退出登录 |
| `RelayJoinPage.ets` | 同账号中转的一键加入、等待管理电脑放行与成功返回；复用 `RelaySettingsPanel` 的加入状态 |

当前大量会话 builder 仍集中在 `TaskPage.ets`，任务列表 UI 集中在 `TaskListPage.ets`。不要按早期架构草图假设每种卡片都已有独立组件。

任务双栏以窗口宽 ≥600vp、安全区宽 ≥760vp 且高 ≥480vp 为准，不根据横竖屏或折叠状态判断；
系统分屏与悬浮窗一律单栏（D-015）。双栏时详情标题栏最左侧可收起 / 展开任务列表，收起状态只在本次页面内保持。
列表宽度为 300vp 至 `min(420vp, 窗口宽 − 400vp)`，默认 `min(320vp, 窗口宽 × 34%)`；
300vp 下限是为标题栏控件保留的 Harmony 差异。双栏最多常驻最近三个任务，`core/tasks/ResidentTaskPanes.ets`
负责实例顺序，隐藏页暂停订阅与滚动，消息缓存租约由 `MessageStore.ets` 管理。项目显示别名的只读同步位于
`core/tasks/TaskProjectAliasStore.ets`，不改变项目路径或排序。具体姿态和阅读位置仍需使用 API 26 设备验收。

### 4.4 共享组件 `components/`

| 文件 | 作用 |
|---|---|
| `ConversationComposer.ets` | 任务页输入区：文本、图片 / 文件、结构化 atom、模型 chip、发送和停止 |
| `UiKit.ets` | 字体缩放、圆角、点击反馈、动效时长 / 曲线、overlay / reveal transition 等共享 token |

需要统一多个页面的视觉或动效时，优先在 `UiKit.ets` 或语义资源中建立统一口径，不在页面散落数值补丁。

### 4.5 `core/` 业务目录

| 路径 | 作用 | 关键入口 |
|---|---|---|
| `core/AppServices.ets` | 应用级单例组装；连接 Auth、Device Link 和各 Store，管理设备链、全局订阅、push 分发、重连恢复与深链 | 页面获取应用服务的总入口 |
| `core/ComposerCatalog.ets` | 任务页与新建页共享的 provider、模型、权限模式和推理强度目录 | 改模型 / 权限菜单先看这里 |
| `core/auth/` | 验证码、登录、token 刷新、登录态恢复和退出 | `AuthApi.ets`、`AuthStore.ets` |
| `core/device-link/` | envelope、channel、握手、心跳、invoke、订阅、presence 和重连 | `DlProtocol.ets`、`DlClient.ets` |
| `core/tasks/` | 设备 / 任务模型、列表状态、新任务创建、偏好、Agent 切换和 Pi 分支树 | `TaskModels.ets`、`TaskStore.ets` |
| `core/messages/` | 历史、流式合并、发送队列、渲染投影、Markdown、Tool / Todo、搜索、草稿和媒体状态 | `MessageStore.ets`、`MessageRender.ets` |
| `core/attachments/` | 选图、预处理、presign、上传、OSS 引用以及图片 / 文件 Composer 队列 | `ComposerImageQueue.ets`、`ComposerFileQueue.ets` |
| `core/interactions/` | Permission、Ask User、Plan Review 的 pending、草稿、resolve 和展示投影 | `InteractionStore.ets`、`InteractionPresentation.ets` |
| `core/goals/` | Goal mode 状态和 start / clear / pause / resume | `GoalModels.ets`、`GoalStore.ets` |
| `core/navigation/` | `cindy://session/...` 深链解析 | `SessionDeepLink.ets` |
| `core/storage/` | Preferences 持久化包装；保存 token、deviceId 和本地偏好 | `SecureStore.ets` |
| `core/dev/` | HTTP、WebSocket Header 和 storage 的设备探针 | `SystemProbe.ets`；只用于 `ohosTest` 或临时诊断 |

#### `core/tasks/` 文件定位

| 文件 | 作用 |
|---|---|
| `TaskModels.ets` | `DeviceView`、`RemoteSession`、`RemoteMessage`、安全字段读取、解析和排序 |
| `TaskStore.ets` | presence、任务快照、实时 patch / activity 和任务元信息修改 |
| `NewSessionCreationStore.ets` | 乐观创建、临时任务、重试恢复和首条消息交接 |
| `TaskListPreferenceStore.ets` | 列表 Tab、排序、项目展开状态等本地偏好 |
| `SessionAgentSwitch.ets` | 会话内 Agent 切换能力和 intent 解析 |
| `PiSessionTree.ets` | Pi 分支树快照和导航结果解析 |

#### `core/messages/` 文件定位

| 文件或文件组 | 作用 |
|---|---|
| `MessageStore.ets` | 权威消息 Store：历史窗口、订阅、流式消息 / 工具合并、发送、停止和回退 |
| `MessageRender.ets` | 将原始消息投影成文本、Thinking、Tool、Todo、工作组、Agent task 等渲染项 |
| `MessagePayload.ets` | 附件、媒体、tool result 媒体和 diff payload 解析 |
| `InputQueueStore.ets` | pending / queued input 投影、发送队列和事件收敛 |
| `ComposerDocument.ets` | 结构化输入文档、长粘贴、引用、mention、slash command 和持久化 |
| `ComposerDraftStore.ets` | 每个会话的本地 Composer 草稿 |
| `MarkdownParser.ets`、`MarkdownTableLayout.ets` | Markdown token 和表格列宽 |
| `ToolUsePresentation.ets` | Tool 操作的人话展示投影 |
| `WorkGroupPresentation.ets` | 工作过程收起态的实时步骤、重复读取收敛和探索摘要投影 |
| `AgentTaskStore.ets` | 子 Agent / workflow progress 更新归一化与合并 |
| `AutoResumePresentation.ets` | 自动续跑卡状态和错误摘要 |
| `SessionTailPresentation.ets` | 会话尾部错误、继续提示和恢复入口 |
| `SystemCardPresentation.ets` | Goal、Agent 切换、learn、compact 等系统卡投影 |
| `MessageSearch.ets` | 搜索命中、索引切换和分页提示 |
| `HistoryGap.ets`、`HistoryWindowCoverage.ets`、`MessagePaging.ets` | 历史缺口、覆盖范围与大 payload 降级 |
| `RemoteMediaState.ets` | 远端媒体解析、原生加载失败和重试状态机 |
| `LearnCommand.ets` | `/learn` 命令识别和请求构造 |

#### `core/attachments/` 文件定位

| 文件 | 作用 |
|---|---|
| `AttachmentModels.ets` | 远端图片、序列化附件、presign 和媒体拉取模型 |
| `ImagePicker.ets` | 图库结果、图片类型探测和字节读取 |
| `ImagePreprocess.ets` | 长边、体积、JPEG 质量等预处理决策 |
| `AttachmentUpload.ets` | presign、字节上传、重试判定、文件分类和 MIME |
| `AttachmentOssRef.ets` | `cindy-oss-attach` 与旧 `xdt-oss-attach` 引用编解码 |
| `ComposerImageQueue.ets` | 选图、截图、拍照、上传、重试、预览恢复和回收 |
| `ComposerFileQueue.ets` | 文件选择、上传、重试、发送后回收 |

### 4.6 资源目录

```text
entry/src/main/resources/
├── base/
│   ├── element/                # Light 默认颜色、字符串和尺寸
│   ├── media/                  # 登录、启动、图标等默认媒体
│   └── profile/                # 页面路由和 backup 配置
└── dark/
    ├── element/                # Dark 同名颜色覆盖
    └── media/                  # Dark 登录品牌资源覆盖
```

| 路径 | 作用 |
|---|---|
| `base/element/color.json` | Light 模式语义颜色 token |
| `dark/element/color.json` | Dark 模式同名 token；新增颜色必须与 Light 成对 |
| `base/element/string.json` | 模块和 Ability 资源字符串 |
| `base/element/float.json` | 尺寸资源 |
| `base/media/`、`dark/media/` | 登录、启动、图标和主题媒体 |
| `base/profile/main_pages.json` | ArkUI 页面路由清单 |
| `base/profile/backup_config.json` | backup 配置 |

`AppScope/resources` 是应用级名称 / 图标，`entry/src/main/resources` 是模块页面使用的主题和媒体；不要混放。

### 4.7 测试目录

| 路径或文件 | 作用 |
|---|---|
| `entry/src/test/List.test.ets` | 本地单测聚合入口 |
| `entry/src/test/LocalUnit.test.ets` | 主要纯逻辑测试，覆盖协议、解析、列表、消息、分页、交互、附件和任务创建 |
| `entry/src/ohosTest/ets/test/List.test.ets` | 设备测试聚合入口 |
| `entry/src/ohosTest/ets/test/Ability.test.ets` | Ability 设备测试 |
| `entry/src/ohosTest/ets/test/SystemProbe.test.ets` | 网络 Header、TLS 与 Preferences 探针；占位地址 / token 未配置时不能当作日常自动验证 |
| `entry/src/ohosTest/module.json5` | ohosTest 模块声明 |
| `entry/src/mock/mock-config.json5` | Harmony 测试 mock 配置 |

纯函数和 Store 级行为优先进入 `src/test`；依赖真实 Ability、系统网络、媒体选择器或设备文件 URI 的能力才进入 `ohosTest` 和模拟器 / 真机验收。

## 5. 需求到代码定位表

| 要修改的能力 | 先读 | Harmony 主要入口 | 最少验证 |
|---|---|---|---|
| 启动、前后台、状态栏、深链 | 根 `docs/dev-rules/remote-and-mobile-adaptation.md`（涉及恢复时） | `EntryAbility.ets` → `Index.ets` → `AppServices.ets` → `navigation/` | 冷启动、前后台、深链目标 |
| 登录、token、退出 | `architecture.md` | `LoginPage.ets` → `auth/AuthStore.ets` → `auth/AuthApi.ets` → `storage/` | 首登、重启恢复、失效刷新、退出 |
| 任务列表、Tab、排序、项目分组 | `mobile-alignment.md` | `TaskListPage.ets` → `TaskListPresentation.ets` → `TaskStore.ets` → `TaskListPreferenceStore.ets` | 项目 / 沟通 / 用量、搜索、排序、窄屏 / 分栏 |
| 新建任务 | `mobile-alignment.md` | `NewSessionPage.ets` → `ComposerCatalog.ets` → `NewSessionCreationStore.ets` | 创建中、失败恢复、首条消息、附件 |
| 会话消息与工作过程 | `message-rendering.md`、`mobile-alignment.md` | `TaskPage.ets` → `MessageRender.ets` → `MessageStore.ets` | 历史、流式、Thinking / Tool / Todo、折叠 |
| 历史分页和断线缺口 | `message-rendering.md` | `TaskPage.ets` / `TaskScrollState.ets` → `MessageStore.ets` → `HistoryGap.ets` / `HistoryWindowCoverage.ets` / `MessagePaging.ets` | 冷开补窗、近顶连续预取、锚点、断线补齐、去重 |
| Composer、草稿和发送队列 | `mobile-alignment.md` | `ConversationComposer.ets` → `ComposerDocument.ets` / `ComposerDraftStore.ets` → `InputQueueStore.ets` | 键盘、草稿恢复、发送 / 失败 / 停止 |
| 图片 / 文件上传 | `image-attachment.md` | `attachments/` → `ConversationComposer.ets` → `TaskPage.ets` | 上传中、成功、失败重试、发送后回收 |
| 历史图片恢复和预览 | `image-attachment.md` | `MessagePayload.ets` → `RemoteMediaState.ets` → `TaskPage.ets` | 加载、失败、重试、全屏预览 |
| Permission / Ask User / Plan Review | `interaction-flows.md`、`mobile-alignment.md` | `InteractionStore.ets` → `InteractionPresentation.ets` → `TaskPage.ets` | 选择反馈、提交中、错误、重试、防重复 |
| Goal mode | 对应 Mobile / Desktop 公开行为 | `GoalModels.ets` → `GoalStore.ets` → `TaskPage.ets` | start / pause / resume / clear 与系统卡 |
| Agent / 模型 / 权限菜单 | `mobile-alignment.md` | `ComposerCatalog.ets` → `NewSessionPage.ets` / `TaskPage.ets` | provider、模型、effort、权限组合 |
| Device Link、invoke、订阅和重连 | `device-link-adaptation.md`、根 `docs/dev-rules/protocol-compatibility.md` 与 `remote-and-mobile-adaptation.md` | `DlProtocol.ets` → `DlClient.ets` → `AppServices.ets` → `network/` | 握手、超时、断线、重连、撤权和补拉 |
| Light / Dark、字体、动效、点击反馈 | 根 `docs/design-rules/DESIGN.md`、`ui-design.md` | `resources/base|dark/element/color.json` → `UiKit.ets` → 页面 / 组件 | 双模式、减弱动态效果、60 / 120Hz 设备 |
| 设置和本地偏好 | 根 `docs/dev-rules/configuration-and-overrides.md` | `SettingsPage.ets` → 对应 Store → `SecureStore.ets` | 默认值、升级迁移、重启恢复、退出清理 |
| 区域、端点和版本身份 | 根 `docs/product-rules/region-and-editions.md` | `AppConfig.ets` → `AppScope/app.json5` | cn / global 身份、端点、上报版本与安装包版本 |

表中专题名相对于本文目录；根目录规则路径需从仓库根读取。


## 6. 新增能力的实际入口

早期组件草图不是现有目录：大量 builder 仍在 `TaskPage.ets` / `TaskListPage.ets`。

| 能力 | 入口 |
| --- | --- |
| 沟通、邀请和群聊 | `core/chat/ChatStore.ets`、`ChatServerApi.ets`；同目录 `INTEGRATION.md` |
| 项目与资源 | `core/projects/ProjectStore.ets`、`core/resources/ResourceStore.ets`；资源目录 `INTEGRATION.md` |
| 文件夹、预览、同步 | `core/files/WorkdirFiles.ets`、`WorkdirPreview.ets`、`RemoteFileService.ets`；差异见决策记录 |
| 用量、输入建议 | `core/usage/`、`core/messages/PromptRecommendation*.ets`；精确读取时机见 Mobile 对齐 |
| 弹层、设置行 | `components/common/UiOverlay.ets`、`components/SettingsRows.ets` |
| 系统推送、用量卡片、外部分享 | `pushextensionability/`、`usageformextension/`、`entryability/EntryAbility.ets` 与 `module.json5` |
| 历史摘要与详情、读取合并 | `HistoryViewAdapter.ets`、`SnapshotReadPool.ets`、`RemoteReadRetries.ets`（均在 `core/messages/`） |
| 目录记忆、项目机器标注 | `core/tasks/NewSessionPreferenceStore.ets`、`ProjectMachineIdentity.ets` |
| 富组件回答 | `core/messages/RichAnswer.ets` → `MessageRender.ets` → `TaskPage.ets` → `components/RichAnswerView.ets`；本机视图值在 `RichInteractionMemory.ets` |
| 模型速度档 | `core/tasks/ModelSpeed.ets` 统一线协议读写，不在页面直接读写 `fastMode` |
| 工具过程媒体、生图交付重试 | `core/messages/ToolProcessMedia.ets` → `MessageRender.ets` → `TaskPage.ets` |

新增页面同时登记 `base/profile/main_pages.json`；对外版本同时核对 `AppScope/app.json5` 与 `AppConfig.ets`，避免包版本与上报版本漂移。
当前能力已超出一期范围，不能再把一期“不做”列表当功能开关。尚有差异与待验收项见[决策记录](decision-log.md)、[验证清单](verification-plan.md)和[版本资料](version/README.md)。
