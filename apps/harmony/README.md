# Cindy Harmony

HarmonyOS 7.0 / API 26+ 原生客户端，使用 ArkUI + ArkTS。本文供首次进入工程时阅读；开发前从[开发指南](项目鸿蒙端开发指南.md)开始，按[文档索引](docs/README.md)进入专题。

任务执行、工作目录、CLI、MCP 与插件运行在电脑端，鸿蒙通过 Device Link 控制电脑；厂商信息也必须经电脑端获取，不在手机直连厂商。

- 工程与工具：[开发指南](项目鸿蒙端开发指南.md)（command-line-tools、DevEco CLI、hvigorw、签名安装、日志）。
- 功能入口：[架构与代码地图](docs/architecture.md)。
- 用户可见行为：[Mobile 对齐](docs/mobile-alignment.md)；有意差异见[决策记录](docs/decision-log.md)。
- 交付：[验证清单](docs/verification-plan.md)；分版本范围和证据留在[版本资料](docs/version/README.md)。

开发和验证范围限 `apps/harmony`。安装只用现有签名生成的 signed HAP；签名错误停止交由用户处理，禁止 unsigned 覆盖、卸载绕过、清数据或重置模拟器。
