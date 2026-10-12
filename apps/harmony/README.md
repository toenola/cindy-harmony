# Cindy Harmony

HarmonyOS 原生远程控制客户端，使用 ArkUI + ArkTS 开发，面向 HarmonyOS 7.0 / API 26+。

本应用不在鸿蒙设备本地运行 Claude Code、Codex、Pi 或 Agent。Agent、任务数据、工作目录和工具仍然运行在桌面 Cindy；Harmony 端通过 Device Link 进行远程控制。

## 当前阶段

当前为 [v1.3.1 候选版本](./docs/version/v1.3.1/README.md)：四项 Mobile 对齐实现与 Harmony Local Test 已完成，可构建签名 HAP；API 26 设备交互验收待完成。

## 文档

- [文档索引](./docs/README.md)
- [一期产品范围](./docs/product-scope.md)
- [实施计划](./docs/implementation-plan.md)
- [架构方案](./docs/architecture.md)
- [开发环境](./docs/dev-environment.md)
- [Device Link 适配](./docs/device-link-adaptation.md)
- [消息流与渲染](./docs/message-rendering.md)
- [图片附件](./docs/image-attachment.md)
- [交互确认](./docs/interaction-flows.md)
- [UI 设计](./docs/ui-design.md)
- [验证计划](./docs/verification-plan.md)
- [决策记录](./docs/decision-log.md)

## 相关代码

现有实现主要参考：

- `apps/mobile/src/device-link/`
- `apps/mobile/src/session/`
- `packages/device-link/`
- `packages/maker-shared/`
- `packages/auth-client/`
- `packages/device-link-protocol/`
