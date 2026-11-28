# Device Link 适配

本文说明 Harmony 连接适配与恢复不变量；修改网络、invoke、订阅或重连前阅读。跨端契约以共享协议为准；加入、路由和凭证细节见[中转专题](self-hosted-relay-plan.md)。

## 1. 目标

Harmony 端继续使用当前 Cindy Device Link，不重新设计协议。

主要参考：

- `packages/device-link/src/client.ts`
- `packages/device-link/src/protocol.ts`
- `apps/mobile/src/device-link/rnWebSocket.ts`
- `apps/mobile/src/device-link/mobileMakerTransport.ts`
- `apps/mobile/src/device-link/DeviceLinkContext.tsx`
- `packages/device-link-protocol/`

## 2. Harmony Host Adapter

`network/HarmonyWsAdapter.ets` 实现 `WsAdapter.ets` 接口，由 `core/device-link/DlClient.ets` 驱动：

```text
connect(url, headers)
send(text)
close()
onOpen
onMessage
onClose
onError
```

系统适配与设备验证需覆盖：

- `wss`。
- 连接握手时的 `Authorization: Bearer <token>`。
- TLS 错误。
- close code 和 error reason。
- 大消息和二进制/文本边界。
- 前后台切换后的 close / reconnect 行为。

不要把 Token 放入 URL 查询参数作为默认方案。

## 3. 必须保持的协议行为

- hello / hello-ack。
- link-open / link-accept。
- invoke / invoke-result。
- push topic。
- request id 配对。
- 心跳。
- 重连。
- ACK、可靠传输、分片和重组。
- timeout 和错误分类。
- 撤权。
- 重连后重新订阅和补齐消息。

UI 未暴露某能力不允许底层删除可靠传输和消息恢复语义。

## 4. 远程业务通道

业务 Store 使用既有电脑端通道：

- 设备发现。
- 任务列表。
- 任务详情和消息历史。
- 消息发送。
- 停止执行。
- 图片附件引用和上传链路。
- Permission resolve。
- Ask User resolve。
- Plan Review resolve。
- Fork / Rewind 所需调用。

新增 channel 前必须先检查：

1. 桌面端是否已有对应能力。
2. `device-link` allowlist 是否允许。
3. `packages/device-link-protocol` 是否已有契约。
4. 是否需要跨端兼容和测试 fixture。

## 5. 重连不变量

- 连接断开期间不认为远端状态已丢失。
- 回到前台后重新认证或刷新 Token。
- 重新建立 link 并订阅当前任务。
- 以桌面端历史消息为准补齐缺口。
- 本地 pending message 不能重复发送。
- 待处理交互不能因为 UI 重建而重复 resolve。

## 6. 服务端边界

本工程不因平台适配擅改服务端或桌面 Agent。如果发现：

- `platform` 字段被固定枚举校验。
- Harmony WebSocket 无法完成安全认证。
- 图片上传缺少必要的 remote channel。
- 现有协议无法表达消息或交互状态。

必须先记录协议缺口和兼容方案，再决定是否修改共享协议。

## 7. 路由与请求调度入口

`AppServices.ets` 组装连接并分发 push；`DlClient.ets` 管连接代次、pending 请求、订阅与恢复；
`InvokePolicy.ets` / `InvokeScheduler.ets` 区分请求策略与调度。`ConnectionAttemptState.ets` 管连接尝试，不能把某台电脑的超时升级为共享 WS 故障。
传统自建路线用 `LegacyRelaySocket.ets`，加密路线用 `AgentNetSocket.ets` / `AgentNetEngine.ets`，选择由 `RelayRoute.ets` 负责。
改协议前先读[兼容规则](../../../docs/dev-rules/protocol-compatibility.md)、[远程恢复规则](../../../docs/dev-rules/remote-and-mobile-adaptation.md)和[服务器通道审查](../../../docs/dev-rules/server-channel-review.md)，不能只凭单端通过认定互通成立。
