# Device Link 适配

> 状态：Draft

## 1. 目标

Harmony 端继续使用当前 Cindy Device Link，不重新设计协议。

主要参考：

- `packages/device-link/src/client.ts`
- `packages/device-link/src/protocol.ts`
- `apps/mobile/src/device-link/rnWebSocket.ts`
- `apps/mobile/src/device-link/mobileMakerTransport.ts`
- `apps/mobile/src/device-link/DeviceLinkContext.tsx`
- `cindy-protocol/`

## 2. Harmony Host Adapter

需要实现一个由 Harmony 原生网络能力驱动的 WebSocket adapter：

```text
connect(url, headers)
send(text)
close()
onOpen
onMessage
onClose
onError
```

必须优先确认：

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

第一版可以不暴露全部高级 UI，但底层不应为了省事删除可靠传输和消息恢复语义。

## 4. 远程业务通道

一期优先使用现有桌面端能力：

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
3. `cindy-protocol` 是否已有契约。
4. 是否需要跨端兼容和测试 fixture。

## 5. 重连不变量

- 连接断开期间不认为远端状态已丢失。
- 回到前台后重新认证或刷新 Token。
- 重新建立 link 并订阅当前任务。
- 以桌面端历史消息为准补齐缺口。
- 本地 pending message 不能重复发送。
- 待处理交互不能因为 UI 重建而重复 resolve。

## 6. 服务端边界

一期原则上不修改服务端和桌面 Agent。如果发现：

- `platform` 字段被固定枚举校验。
- Harmony WebSocket 无法完成安全认证。
- 图片上传缺少必要的 remote channel。
- 现有协议无法表达消息或交互状态。

必须先记录协议缺口和兼容方案，再决定是否修改共享协议。
