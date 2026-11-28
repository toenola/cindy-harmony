# Harmony 验证清单

本文用于选择改动相关的单测、系统能力测试和设备交互场景；准备验证或交付时阅读。它是验收条件，不表示这些场景已经通过。命令、签名和目标选择见[开发指南](../项目鸿蒙端开发指南.md)。

## 1. 验证层级

### 工具和纯逻辑

- 协议 envelope 编解码。
- Device Link 状态机。
- 重连和请求去重。
- 消息归一化。
- 消息排序和分页。
- 消息窗口和滚动锚点。
- 图片附件状态机。
- Interaction decision 序列化。

### Harmony 单元 / 集成

- HTTP。
- WebSocket。
- Token 存储。
- 图片 URI 读取。
- 图片压缩。
- App 前后台状态。
- ArkUI Store 与页面生命周期。

### 模拟器 / 真机

- 登录。
- 设备发现。
- 任务列表。
- 历史消息加载。
- 流式输出。
- 图片选择和上传。
- Permission。
- Ask User。
- Plan Review。
- 停止任务。
- 前台重连。
- 撤权。
- Light / Dark。
- 键盘、返回手势和弹层。

## 2. 核心验收场景

1. 登录后重启 App，Token 仍然有效。
2. 发现桌面 Cindy 并打开已有任务。
3. 加载长历史消息并向上翻页。
4. 收到包含 Thinking、Tool、Todo、Work Group 的流式回复。
5. App 断开期间桌面产生消息，回到前台后历史缺口被补齐。
6. 发送普通文本并收到回复。
7. 选择多张图片、上传、发送并在历史中重新打开。
8. 上传失败后重试，不重复发送。
9. Permission 三种决策分别成功。
10. Ask User 多步骤、多选和 Skip 成功。
11. Plan Review 批准和反馈成功。
12. 停止正在执行的任务。
13. 桌面端撤销 Harmony 设备权限后，鸿蒙端变成只读或明确不可用。
14. Light / Dark 模式下主要页面都可用。
15. 切换后台和前台后不重复提交、不丢输入、不重复显示消息。

## 3. 消息完整性门禁

任何消息 fixture 不能只断言文本内容，还要检查：

- message id。
- 消息类型。
- Tool / Result 关联。
- Thinking 内容。
- Todo 状态。
- Work Group 层级。
- 附件引用。
- 媒体引用。
- 时间和排序。
- 断线后的补齐结果。

## 4. UI 门禁

- Light / Dark 都有验证记录。
- 复杂内容不会遮挡或无限撑开页面。
- MessageList 不因打开 sheet 而丢失滚动位置。
- Composer 在键盘弹出时仍可操作。
- 图片预览可关闭并回到原消息位置。
- Permission / Ask User / Plan Review 提交中不能重复点击。
- 小屏和折叠屏没有横向溢出。

## 5. 测试入口与剩余验收

`entry/src/test/List.test.ets` 聚合当前本地用例；`LocalUnit.test.ets` 不是唯一入口。
历史和输入队列覆盖见 `V132History` / `V132Queue` / `V132Delivery`，交互见 `V132Interactions`，
富回答与速度档见 `V133*`，新增能力见 `WorkdirFiles` / `PluginEngines` / `UsageCard` / `PromptRecommendation` 等测试。
系统 API 使用 `ohosTest` 与真实操作验证；主机 fixture 或互通测试不能代替系统网络、Asset Store、NAPI 加载和设备 UI 验收。

- 双栏姿态、分屏单栏、列表收起、三任务常驻与阅读位置：按 D-014 / D-015 实测。
- 中转传统 / 仅 Agent-Net / 混合加入、安全保存、切换和故障隔离：按[中转清单](self-hosted-relay-plan.md#真机清单)实测。
- 用量、插件额度与输入建议：按 [Mobile 对齐](mobile-alignment.md) §6–9 验证读取时机、旧结果隔离与双模式。
- 文件预览：HTML 网络封锁顺序、Draw.io 多页 / 压缩、GLTF 文件 URI / 光照 / 编码仍按[决策记录](decision-log.md)验证，不能从纯逻辑测试推断系统表现。
- 早期切片中相机、Ask User 多题 / 草稿、Issue Confirm、补窗等已存在生产入口，不再作为“待实现”任务；新增回归仍检查媒体失败提示、手打 / 粘贴原子、工作组与 Thinking 标题、工具折叠、长消息收起及角色时间呈现是否对齐 Mobile。

安装与运行必须有目标和回执，未跑的模式、设备、链路与场景明确记为未验证，不沿用旧版本的通过结论。
