# Harmony 文档

这里记录 HarmonyOS 原生客户端的产品范围、架构、实现计划、设计约束和验证资料。

这些文档只约束 `apps/harmony`，不是全仓库的通用规则。跨 Desktop、Mobile 和 Harmony 都适用的规则，应放在根目录 `docs/dev-rules/`、`docs/product-rules/` 或 `docs/design-rules/`。

## 文档列表

- [一期产品范围](./product-scope.md)：本期必须实现和明确排除的功能
- [实施计划](./implementation-plan.md)：按垂直切片拆分，每个切片以真机可见成果收尾
- [行为对齐 Mobile（必读）](./mobile-alignment.md)：实现消息 / 交互行为前先读对应 iOS/Android 源码
- [架构方案](./architecture.md)：ArkUI、ArkTS、业务层、Device Link 和消息管线
- [开发环境](./dev-environment.md)：DevEco Studio、API 24+、构建和运行准备
- [Device Link 适配](./device-link-adaptation.md)：WebSocket、握手、重连和 invoke/push
- [消息流与渲染](./message-rendering.md)：历史消息、消息模型、Markdown 和媒体展示
- [图片附件](./image-attachment.md)：选图、压缩、上传、发送和历史恢复
- [交互确认](./interaction-flows.md)：Permission、Ask User 和 Plan Review
- [UI 设计](./ui-design.md)：Harmony 原生 UI 与 Cindy 设计系统的落地边界
- [验证计划](./verification-plan.md)：协议、真机、断线、历史消息和交互验收
- [决策记录](./decision-log.md)：重要技术选择及其原因

## 文档状态

- 目标平台：HarmonyOS 6.1 / API 24+
- 开发语言：ArkTS
- UI：ArkUI
- 客户端形态：远程控制桌面 Cindy
- 当前状态：DevEco 空工程已创建，`assembleHap` 构建成功；尚未完成模拟器或真机安装验证
