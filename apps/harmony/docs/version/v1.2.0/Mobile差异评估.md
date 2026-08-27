# Harmony v1.2.0 Mobile 差异评估

本文记录本版与 Mobile / Desktop 事实源的对照结果，并区分直接跟进、Harmony 等价实现和仅能在设备上验证的项目。

## 评估结论

| 能力 | 事实源语义 | Harmony v1.2.0 处理 | 状态 |
|---|---|---|---|
| 远程任务搜索 | Mobile 以 conversation search 查标题与消息正文 | 复用 `local-db:conversations:search`，按设备并发，结果带设备/项目上下文 | 代码完成 |
| 旧端/离线搜索 | 远端能力不可用时不能宣称完整结果 | 回退 `sessions:list`，再回退当前控制端缓存，并标记缓存结果 | 代码完成 |
| 项目顺序 | Desktop 保存正本，控制端消费 owner/generation | 通过 sidebar get/apply/push 等现有 channel 做 Harmony 投影，隐藏项目槽位保持不变 | 代码完成 |
| 消息分享范围 | 只导出当前可见且用户选中的消息 | 独立选择态保存稳定消息 ID，冻结投影后复用现有图片分享链路 | 代码完成 |
| 生成速度 | 只在服务端指标可靠且生成中时展示速率 | 解析输出 token、生成时长和可靠性；不可靠时只显示累计量 | 代码完成 |
| 输入队列 | 本地入队不能自证远端已接收 | 以 projection、正式消息或权威补拉中的 clientId 作为证据 | 代码完成 |
| Device Link 恢复 | 重连后恢复订阅与各类快照，旧结果不能污染新状态 | 为设备、任务、消息、队列、交互和项目顺序使用各自 single-flight/fence | 代码完成 |
| Subagent 历史终态 | 持久终态优先于结果文本猜测 | `agentTaskStatus` 贯穿历史、live 更新、列表节点和只读详情 | 代码完成 |
| 电脑端专属交互 | Harmony 不接管 Desktop-only 操作 | 明确标题/说明；terminal 状态隐藏无效操作；未知类型只读提示回电脑处理 | 代码完成 |
| Subagent 详情 | 共享协议没有权威控制时只读 | 在当前详情栏展示稳定 key 对应的父子树、工具过程与结果 | 代码完成 |
| OTA、Ollama、插件管理 | 属于 Desktop 或其它平台能力 | 不新增 Harmony 平行协议或本机管理入口 | 明确排除 |

## 平台等价与验证边界

- Harmony 不复制 Mobile 的 Expo、React Native、Metro 或 iOS API；系统选图、图片分享和布局使用 Harmony 原生能力。
- Device Link payload 和 channel 只使用当前仓库已存在的契约；没有修改其它端或服务端来“配合”本版。
- 自动化验证已覆盖纯逻辑和异步代次边界；安装、启动、系统分享面板、跨端拖动和弱网链路必须在真实设备上补验。
- 真实设备不可用时，候选版本保持“待设备/UI验收”，不将本地构建结果当作交互验收证据。
