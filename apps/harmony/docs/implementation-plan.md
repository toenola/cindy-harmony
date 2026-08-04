# Harmony 一期实施计划

> 状态：Draft
>
> 本计划按依赖关系组织，不按开发周期估算。每个工作包完成后都必须有对应的源码、fixture 或验证证据。

## 1. 开工前置

- [ ] 确认 HarmonyOS 6.1 / API 24+ 的 DevEco Studio 和 SDK 版本。
- [ ] 创建标准 Stage 工程并确保能在模拟器或真机启动。
- [ ] 检查 `cindy-protocol` submodule 状态并确认协议版本。
- [ ] 确认认证区域和一期登录方式。
- [ ] 确认 WebSocket 是否支持 `Authorization` Header、`wss` 和连接回调。
- [ ] 确认安全存储、图片选择、文件 URI 和系统浏览器能力。

## 2. 平台基础层

- [ ] Harmony WebSocket adapter。
- [ ] HTTP / JSON adapter。
- [ ] Token 安全存储。
- [ ] App 前后台生命周期处理。
- [ ] 图片 URI、文件访问和资源权限。
- [ ] Light / Dark 主题 token。
- [ ] 网络错误、权限错误和系统返回行为。

## 3. 认证和 Device Link

- [ ] 登录页面和登录 Store。
- [ ] Token 刷新和登出。
- [ ] Device Link 握手。
- [ ] link-open / link-accept。
- [ ] invoke / invoke-result。
- [ ] push topic。
- [ ] 心跳、重连和连接状态。
- [ ] 撤权和设备不可用状态。
- [ ] 重连后任务和消息重新订阅。

## 4. 任务和消息基础

- [ ] 设备列表 Store。
- [ ] 任务列表 Store。
- [ ] 任务详情 Store。
- [ ] 历史消息分页。
- [ ] 消息窗口和滚动锚点。
- [ ] 消息去重、稳定排序和流式合并。
- [ ] 断线后的 host-authoritative gap healing。
- [ ] 原始消息保留和渲染模型构建。

## 5. 完整消息流

- [ ] 普通文本和 Markdown。
- [ ] 代码、列表、引用、表格、链接。
- [ ] Thinking。
- [ ] Tool Use / Tool Result。
- [ ] Todo。
- [ ] Work Group。
- [ ] 系统消息、错误消息和状态消息。
- [ ] 图片、媒体和文件引用的保留及预览。
- [ ] 消息复制、代码复制、Fork、Rewind。
- [ ] 消息搜索和跳转。
- [ ] 复杂 Markdown 内容的 ArkWeb 承载边界。

## 6. 输入和图片附件

- [ ] 多行文本 Composer。
- [ ] 发送、停止、发送中和失败重试。
- [ ] 基本 pending queue，保证输入不丢失。
- [ ] 图片选择。
- [ ] 多图附件。
- [ ] 图片尺寸处理和压缩。
- [ ] 图片上传状态机。
- [ ] 上传失败恢复。
- [ ] 附件引用发送。
- [ ] 已发送图片在历史消息中恢复。
- [ ] 图片预览和媒体获取失败提示。

## 7. 用户交互

- [ ] Permission 完整流程。
- [ ] Ask User 完整流程。
- [ ] Plan Review 完整流程。
- [ ] 请求 ID 去重。
- [ ] 提交中的防重复操作。
- [ ] App 切后台后恢复待处理交互。
- [ ] 请求过期、远端拒绝和连接失败处理。

## 8. 页面和设计

- [ ] 登录页。
- [ ] 首页。
- [ ] 任务列表。
- [ ] 任务详情。
- [ ] 消息 Composer。
- [ ] Permission / Ask User / Plan Review 页面或弹层。
- [ ] 设置页。
- [ ] Light / Dark 双模式。
- [ ] Harmony 原生导航、返回和系统手势。
- [ ] 现有 Cindy Logo、字体和登录素材适配。

## 9. 明确不进入一期

- [ ] 语音输入和语音会话。
- [ ] 后台推送。
- [ ] 视频/音频上传。
- [ ] 文件编辑器。
- [ ] 自动化。
- [ ] Orca。
- [ ] 插件。
- [ ] SSH 工作区。
- [ ] 多登录渠道。
- [ ] 高级模型和运行参数设置。
