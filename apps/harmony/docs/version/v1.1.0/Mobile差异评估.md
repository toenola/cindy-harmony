# v1.1.0 Mobile 差异评估

本文记录官方 Mobile 近期变更与 Harmony 当前实现的差额，并裁决 v1.1.0 的跟进方式。
行为以 Mobile / 共享纯逻辑为准；视觉和系统能力按 HarmonyOS 原生方式实现。

## 评估结论

| 能力 | Harmony 现状 | v1.1.0 裁决 | 优先级 |
|---|---|---|---|
| 计划卡跨用户轮次归属 | `MessageRender.ets` 仍可能让旧计划吞并后续轮次 | 直接修复，边界使用上一用户消息位置而非可变末尾位置 | P0 |
| 工作过程完成时长 | 当前更接近从首个 activity 起算 | 直接修复，从本轮用户消息时间开始计时 | P0 |
| `autoReviewUnavailable` | 缺少完整本地化 / 显示 | 补齐解析、资源文案和失败展示 | P1 |
| Pi slash 命令人话展示 | 内部 `/skill:git` 可能原样暴露 | 存储 / 发送保持内部值，展示 / 复制 / 编辑投影为 `/git` | P1 |
| 发送后贴住最新消息 | 只请求滚动，历史阅读态可能仍关闭跟随 | 发送成功接管时强制恢复 `followingLatest` 和默认尾窗 | P0 |
| 队列操作触控区 | 当前约 36vp | 提升到至少 44vp，视觉仍保持紧凑 | P2 |
| 模型元信息布局 | 功能已有，窄屏信息密度与无障碍待对齐 | 使用共享布局语义，完成窄屏、字体放大和读屏标签 | P1 |
| Pi 命令 / Skill 清单 | 当前任务页查询未传 `sessionId` | 已有任务绑定当前 `sessionId`；新任务预览保持未绑定 | P0 |
| 远端默认模型 | 未完整处理 `newSessionDefault` 与 Pi 标记 | 解析 `['pi', 'claude-code']` 等标记，并保留 provider 身份 | P0 |
| 消息生命周期与内存治理 | 已有请求 lease、订阅串行、80 行快照和 1600 行 LRU | 增加 push authority、自动化任务策略、64MiB / 800 行预算与保护租约 | P0 |
| Device Link 1013 冷却 | 普通稳定连接会过早清除拥塞历史 | 拆分 10 秒普通稳定窗与 15 分钟拥塞稳定窗 | P0 |
| 新任务乐观标题 | 文字首条已有 | 增加纯图片 / 纯文件标题，并收紧 preview 生命周期 | P1 |
| 会话分享图片 | 未实现 | 使用 Harmony 原生截图 / 绘制和系统分享能力实现 | P1 |
| Mobile beta / OTA | Harmony 无 Expo OTA | 建立 Harmony beta / release 交付身份、版本同步和更新渠道边界 | P1 |
| THEMIS 用户归因 | Harmony 无对应适配 | 建立可选安全观测 adapter：登录绑定、登出清空、缺 SDK 安全 no-op | P1，外部依赖 |
| Metro / iOS Simulator 安全接管 | 技术栈不适用 | 落成 DevEco CLI 的精确工程、精确设备、signed HAP 安装流程 | P2 |
| iOS 受限照片权限 | iOS API 不适用 | 验证 Harmony PhotoViewPicker 受限选择、URI 读取和失效恢复 | P2 |
| CAPTCHA | 未接入 | 明确排除，不创建页面、token 或协议半成品 | 不做 |

## 已有能力的回归口径

以下能力不重复重写，但必须纳入 v1.1.0 回归：

- 消息历史请求 lease 与订阅串行化。
- 最新 80 条消息持久快照及恢复。
- 文本首条消息的乐观标题。
- 收起态 Composer、附件入口、上传队列和发送后收起。
- 队列入队、撤回、立即发送及草稿保护。
- Device Link 重连后的任务、消息订阅与 gap healing。

## Mobile 特有能力的“已完成”判定

### beta / OTA

不移植 Expo Updates。完成标准是 Harmony beta / release 构建身份有明确来源，版本号三处
一致，测试包和正式包不会串渠道；若接入更新服务，必须沿用现有服务协议，不在 Harmony
本地私造不兼容 manifest。

### THEMIS

不直接引用 Mobile 的 Expo 原生模块。完成标准是：

- SDK 存在且当前区域允许时，登录后写入当前用户标识，登出时清空。
- SDK 不存在、初始化失败或当前区域不启用时安全降级，不阻断登录和退出。
- 不把用户标识写入日志、版本文档或普通 Preferences。
- 接入真实厂商 SDK 前完成隐私、区域和冷更 / 重新签名影响评审。

### Metro / 模拟器

不实现 Metro 接管。完成标准是 DevEco 流程始终针对当前 worktree 的 `apps/harmony`，
显式选择设备，构建后校验 `entry-default-signed.hap`，只做覆盖安装；签名不一致时停止，
禁止卸载、清数据或重置模拟器。

### 受限照片授权

不请求 iOS 权限。完成标准是 Harmony 系统选图器在用户只选择部分照片时仍能读取返回 URI，
应用重启或 URI 失效后给出可恢复的重新选择提示，不扩大到无必要的全图库权限。

## 协议边界

- Harmony 当前未宣告可靠传输 capability，不照搬 Mobile ACK / replay 状态机。
- 1013 拥塞冷却属于客户端连接稳定性，可在不新增协议字段的前提下实现。
- Pi roster 的 `sessionId`、远端默认模型和会话分享数据均先复用现有 channel / payload。
- 如实现中发现必须新增 wire 字段，先按根目录协议兼容规则完成兼容设计，再决定是否扩展范围。
