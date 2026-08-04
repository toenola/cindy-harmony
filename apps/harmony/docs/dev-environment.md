# Harmony 开发环境

> 状态：待实机确认

## 1. 目标

- HarmonyOS 6.1+
- API 24+
- ArkUI + ArkTS
- Stage 模型
- 独立 DevEco Studio 工程

不考虑 API 24 以下兼容，因此不为旧系统添加兼容分支。但仍必须兼容当前 Cindy 的 Device Link 协议和桌面端版本。

## 2. 工程目录

`apps/harmony` 本身作为 DevEco 工程根目录，预计包含：

```text
AppScope/
entry/
build-profile.json5
hvigorfile.ts
oh-package.json5
```

暂不把它作为普通 pnpm / Expo 应用处理，也不把 Node 依赖混入 Harmony 工程。是否需要根目录 wrapper script，等工程可以在 DevEco 正常构建后再决定。

## 3. 必须确认的 SDK 能力

在正式实现前，通过最小 Spike 确认：

- ArkUI Navigation、List、Scroll、Text、TextInput、Dialog、Sheet。
- Light / Dark 主题和语义资源。
- WebSocket `wss`。
- WebSocket 握手时自定义 `Authorization` Header。
- HTTP、JSON、TLS 和超时。
- Token 安全存储。
- 图片选择、相册 URI 和文件读取。
- 系统浏览器和 OAuth callback（如采用 OAuth）。
- App 前后台生命周期。
- ArkWeb 和复杂内容通信边界。

## 4. 本地开发顺序

1. 安装 DevEco Studio 和目标 HarmonyOS SDK。
2. 创建或打开 `apps/harmony`。
3. 使用最小 ArkUI 页面确认编译和启动。
4. 添加 HTTP / WebSocket 网络探针。
5. 添加安全存储探针。
6. 添加图片选择和 URI 读取探针。
7. 再接入 Cindy 认证和 Device Link。

## 5. 当前状态和未验证项

已完成：

- DevEco Studio 已生成标准 Stage + ArkTS 工程。
- 目标和兼容 SDK 为 `6.1.1(24)`。
- `entry:assembleHap` 空工程构建成功。
- 已生成 unsigned HAP；当前没有 signing config，因此尚未生成 signed HAP。

仍未验证：

- ArkTS 对现有 TypeScript 包的直接复用边界。
- Harmony WebSocket 自定义 Header 行为。
- 真机或模拟器安装、前后台切换、弱网重连和大消息传输。
- Token 安全存储、图片选择和图片 URI 读取。
- 最终 bundleName、签名配置和发布身份。
