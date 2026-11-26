# 鸿蒙「我的中转站」开发计划

> 状态：2026-11-26，功能代码与主机互通验证已完成，已生成包含 ARM64 原生库的签名 HAP，可进入真机覆盖安装验收。模拟器按用户要求不再尝试。真机验收尚未执行；尚未指定发布版本。

## 用户能做什么

在鸿蒙设置页查看当前中转、加入自建中转或切回官方中转。界面参考 iOS「我的中转站」。在「中转服务」区显示当前中转名称、地址说明与可用操作，Agent-Net 开关单独展示。加入支持传统 Cindy Device Link 自建中转，也支持仅 Agent-Net 的中转。仅 Agent-Net 路线的设置应按 iOS 处理，避免关闭唯一可用的加密连接。

从分享链接开始，显示目标站点、提交申请、显示核对码、等待主人审批。审批和身份校验通过后保存成员资格并切换连接。核对 iOS 的粘贴、系统深链及同账号加入入口，并为适用的入口验证完整闭环。涉及其他账号分享时按原有邀请流程处理，保留两端的账号边界。传统与仅 Agent-Net 两类中转都能发现电脑、打开任务、读取历史、发送消息、接收流式回复，并能显式切回官方。

## 阶段与验收

先验证应用能调用原生库，再接通加入与凭证保存。两种中转共用加入与切换界面，各自完成连接和互通验证。设置页可以同步开发，等对应链路通过验收后再开放入口。

- [x] **编译和接入原生核心。** 复用共享 Rust 加密与传输核心，提供受类型标记保护的 NAPI create/command/destroy；ARM64 库已进入签名 HAP。原生资源随连接关闭释放，销毁可重复调用。真实 Rust ABI 已参与主机互通测试；鸿蒙 NAPI 加载与帧率留到真机验收。
- [x] **加入与账户隔离。** 支持粘贴和系统深链、同账号目录与一键申请、一次性提交、核对码、审批轮询、取消和主人证书校验。账号目录使用官方服务的版本比较写入，临时申请和链接用完清理。其他账号的分享按 iOS 提示先在电脑加入，不从手机越过账号边界。
- [x] **安全保存成员资格。** 按区域与账号隔离。Asset Store 的 SECRET 只有 1024 字节：SECRET 保存加密的长度和摘要，完整记录分段存入开启 `REQUIRE_ATTR_ENCRYPTED` 的系统属性（每段不超过 2048 字节）。记录原子覆盖，读回校验长度和摘要，错误时停止连接，不用明文 Preferences 保存种子或中转凭证。
- [x] **传统中转。** 独立 WS、设备目录和媒体路由；主人证书、每帧签名、新鲜度、接收端挑战和重放检查均在业务消息进入客户端前完成。真实 V1 服务已验证加入、审批、握手与 invoke，伪造和重放均被拒绝。
- [x] **Agent-Net 与混合中转。** 新版证书审批、加密连接、目录、远程调用、推送帧和加密附件复用共享可移植核心。混合站点先用同一把签名密钥提交 V2 CSR，再走 V1 审批，一次批准后保存两种资格；开关只选择传输，不重新加入。仅 Agent-Net 的站点不能关闭加密，错误不自动降级。
- [x] **设置页。** 已接入当前站点、同账号站点列表、粘贴加入、核对码、取消、Agent-Net 开关和切回官方。五种语言资源齐全，颜色采用现有浅深色语义资源。真实设备上的窄屏、折叠态、键盘和双模式目检待验收。
- [x] **切换边界。** 重建本机连接并隔离旧请求、旧推送和媒体回包；任务列表快照、消息缓存与待核对发送账本使用账号和中转范围。草稿不主动删除，待发送记录不自动重新投递；电脑任务继续运行。附件重试固定原始地址和凭证，切换后拒绝继续执行。
- [x] **主机互通与构建。** 499 条 Harmony 单测通过；两项集成测试通过，覆盖真实中转、Rust 核心、审批、设备签名、加密 invoke、多块附件，以及混合站点双资格和切换。签名包构建成功，原生库为 AArch64，仅依赖系统 `libace_napi.z.so` 和 `libc.so`。
- [ ] **真机签名覆盖安装与端到端验收。** 等用户回家连接设备后，用当前 signed HAP 覆盖安装，完成下面的真机清单。主机测试不替代鸿蒙系统 API 与设备 UI 验收。

## 构建和验证

所有命令从 `apps/harmony` 执行。需要 API 26 的 DevEco 工具链、Node 与带 `aarch64-unknown-linux-ohos` 目标的 Rust；环境变量配置见工程开发指南。签名只使用既有配置，不修改签名、不卸载应用。

```sh
# 共享 Rust 核心 → OHOS ARM64 NAPI 库；产物保留在 Harmony 的缓存与 entry/libs。
sh native/agent-net/build.sh --stage

# 重建 Harmony 使用的共享 JS 桥接产物；修改共享逻辑或 host/polyfill 后需重跑。
node native/portable/build.mjs

# 主机单测与签名构建依次执行。
"$HARMONY_TOOLS/bin/hvigorw" test --mode module -p product=default -p module=entry@default
devecocli build --modules entry@default
```

安装产物为 `entry/build/default/outputs/default/entry-default-signed.hap`。原生库和 JS 产物的生成缓存不提交；`portable/index.js` 是供严格 ArkTS 构建消费的共享逻辑打包结果，随源码保存，不手工修改。

主机互通测试在 macOS 使用真实 Rust 动态库和回环中转，测试数据放在独立临时目录并在结束后清理。系统网络与安全存储用主机适配器替代，因此它们仍需真机验证。首次准备测试依赖和主机 Rust 库：

```sh
npm install --prefix .cache/interop --no-audit --no-fund ws@8.18.3 koffi@2.14.1 esbuild@0.28.2 jose@6.2.2
CARGO_TARGET_DIR="$PWD/.cache/agent-net-host" cargo build --locked --release --lib --manifest-path ../../packages/agent-net-native/Cargo.toml
node scripts/build-interop.mjs
node scripts/relay-arkts-interop.mjs
node scripts/relay-interop.mjs
```

- `relay-arkts-interop.mjs` 直接编译生产 ArkTS 业务入口，验证 V1 审批、真实密钥与证书、对端挑战、invoke、伪造/重放拒绝、同账号目录并发冲突与临时链接清理、安全存储跨段及篡改拒绝、Agent-Net 开关与切回官方。实测约 2.3 秒。
- `relay-interop.mjs` 验证生产共享传输与真实 Rust 引擎、V2 ArkTS 审批、两端加密建链与 invoke、超过一个加密块的附件在发送/接收两端解密，以及真实 V1/V2 服务上的混合加入流程。另验证 Harmony 缺少 Web API 时的 UTF-8 和取消逻辑。实测约 5 秒。

### 真机清单

1. 使用原签名 `install -r` 覆盖安装，确认已有登录、任务草稿与设置仍在。签名不一致即停止，交由用户在 DevEco Studio 处理。
2. 在设置里分别通过传统链接、仅 Agent-Net 链接和同账号目录加入；核对主人电脑的批准、拒绝、过期与取消。验证安全存储成功且重启可恢复。
3. 混合站点切换 Agent-Net，两端开关匹配；打开真实任务、读取历史、发送消息、接收流式回复与交互、上传和查看图片/文档。仅 Agent-Net 站点不能关掉加密。
4. 发送中、附件上传中、审批中分别断网/恢复、前后台切换；切回官方后旧响应不进入新路由，待确认消息先对账、不重复发送。检查另一台控制端未被影响。
5. 浅色、深色、窄屏、折叠态、键盘与返回操作；观察加密附件期间的内存和界面流畅度。当前连接使用加密 WebSocket 中继，不启用 UDP/LAN 直连优化。

## 切换与故障边界

- 官方账号令牌仅用于官方服务。中转地址、凭证选择和媒体访问随当前路由，分享链接里的秘密不进入日志、路由参数持久化或诊断。拒绝会改变凭证发送目标的重定向。
- 中转离线时按当前路线重连，用户可以手动切回官方。中转凭证失效时提示重新加入或切回官方，官方登录态继续有效。
- 切换中转时只重建本机连接，电脑上的任务继续运行。旧路由的结果、推送和媒体回包不得进入新路由；发送中断后复用已有对账机制，避免重复交付。记录保持任务、草稿和阅读位置的验证结果。

## 实现参考

- 鸿蒙设置入口在 [SettingsPage.ets](../entry/src/main/ets/pages/SettingsPage.ets)，深链入口从 [EntryAbility.ets](../entry/src/main/ets/entryability/EntryAbility.ets) 追踪。设置页消费路由和审批状态，加入请求与凭证处理放在业务层。
- iOS 行为以 [设置页](../../mobile/app/settings.tsx)、[加入页](../../mobile/app/relay-join.tsx) 和 [Agent-Net 加入](../../mobile/src/device-link/agentNetPairing.ts) 为准；看 [中转状态](../../mobile/src/device-link/selfHostedRelay.ts)、[中转路由](../../mobile/src/device-link/selfHostedRelayRouting.ts) 与 [设备签名](../../mobile/src/device-link/selfHostedRelayFrameAuth.ts) 确认边界。
- 鸿蒙连接从 [AppServices.ets](../entry/src/main/ets/core/AppServices.ets) 和 [DlClient.ets](../entry/src/main/ets/core/device-link/DlClient.ets) 进入，并核对设备列表和 [附件传输](../entry/src/main/ets/core/attachments/AttachmentUpload.ets) 的 HTTP 路由。新版连接对照 [Mobile Agent-Net 运行时](../../mobile/src/device-link/agentNetRuntime.ts) 和 [可移植连接入口](../../../packages/agent-net/src/portable.ts)。
- 契约以 [自建中转方案](../../../docs/self-hosted-relay-plan.md) 的加入、切换与设备签名章节，以及 [Agent-Net 会话方案](../../../docs/agent-net-session-plan.md) 为准。修改连接前同时核对 [协议兼容](../../../docs/dev-rules/protocol-compatibility.md)、[凭证与本地存储](../../../docs/dev-rules/credentials-and-local-storage.md)、[服务器通道](../../../docs/dev-rules/server-channel-review.md) 和 [远程适配](../../../docs/dev-rules/remote-and-mobile-adaptation.md)。

## 真机反馈修正（2026-11-26）

- 账号目录在官方连接阶段就必须初始化共享解析器所需的 URL 和 URLSearchParams，不能等 Agent-Net 建链后才初始化。集成测试显式移除这两个全局对象，覆盖中转列表和邀请解析，防止主机内置 API 掩盖鸿蒙缺失。
- 设置固定提供「我的中转站」入口，读取失败显示错误与重试，空列表说明需在电脑开启服务。目录请求禁用缓存，并在官方鉴权 401 时刷新一次。
- 点击账号下的站点进入独立加入页，显示站点与管理电脑、等待放行、成功和完成返回；同账号不要求用户复制分享链接或核对二维码。

### 真机原生与邀请诊断

- 鸿蒙动态加载 NAPI 模块时优先从 `default` 取得原生导出；读取不到 create/command/destroy 时返回明确错误，避免同账号申请阶段的 TypeError。
- 共享设置分组和行已提取为 `components/SettingsRows.ets`，中转入口复用同一布局；加入页保持顶部对齐并限制宽屏内容宽度，操作使用主题色。
- 同账号邀请返回 `RELAY_UNAVAILABLE` 与根公钥不匹配必须分别处理，前者表示管理电脑没有发出邀请，不应误报证书问题。真机已复现这类回写；当前对端服务的恢复与完整成功加入仍需继续确认。

### 真机保存与同步修正（2026-11-26）

- Asset Store 的保存、查询与删除统一声明 `REQUIRE_ATTR_ENCRYPTED`；否则会发生保存成功但后续查询不存在，进而错误使用官方连接。自建加入与加密模式切换现在必须确认当前路由为自建才能显示成功。
- 自建中转 hello-ack 的本地 userId 不写回官方登录账号标识，避免改变凭证与缓存所属账号。
- 一台电脑的认证超时只结束该电脑排队中的请求，不再上报为共享 WS 故障；集成测试用可控时钟回调验证超时不会触发传输错误。
- 真机已确认启动连接地址为自建中转，收到已签名的 link-accept、invoke-result 和 push；任务列表显示 18 个列表项。其他离线电脑仍可能单独超时，不影响已连接电脑。
