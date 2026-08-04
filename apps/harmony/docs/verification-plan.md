# Harmony 验证计划

> 状态：待 DevEco 环境可用后执行

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

## 5. 当前限制

在 DevEco、模拟器或真机环境准备好之前，只能完成源码、协议和 fixture 级检查，不能宣称 Harmony 构建、安装或真机验证通过。
