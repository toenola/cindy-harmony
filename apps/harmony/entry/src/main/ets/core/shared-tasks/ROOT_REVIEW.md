# D 公共接线只读审查

> 集成结论（2026-11-28）：下列四项为历史发现，均已修复并纳入 Harmony 回归。raw wire 只接物理 ID；主断链只取消物理 owner jobs；消息信任及 online 补拉按 owner/guest 分开；guest ready 刷新问题卡、关闭精准清 pending/draft。当前完整套件 684 项通过。以下保留问题依据，不再表示当前仍存在这些缺陷；真实双账号设备验收尚未进行。

审查范围：`core/SharedTaskRuntime.ets`、`core/AppServices.ets`、`core/device-link/DlClient.ets`、`core/attachments/ScopedAttachmentRoutes.ets`、`AttachmentUpload.ets`、`pages/TaskPage.ets`，并追读现有 MessageStore/InteractionStore/InvokeScheduler。未修改公共文件或 InputQueue。行号为本次读取时定位，集成人并行变更可使行号漂移。

## P1：主 relay 原始帧仍可伪装本地 canonical guest 来源

`DlClient.handleFrame:473` 只 decode 后分发；`DlProtocol.decodeEnvelope:222` 不限制 src/dst 长度。`handlePush:599–603` 把 env.src 直接交给 AppServices.dispatchPush，后者与真正独立 guest 的 canonical peer 共用投影。因此当前自建主 relay 若发 src=已注册AN/official guest canonical key，可注入该任务消息/交互。`handlePresence:553–565` 也只检查deviceId非空，假canonical presence可经AppServices.onPresence使该guest的InputQueue.invalidateDevice失权。注册式出站fail-closed没有覆盖这条入站路径。

建议：所有 DlClient 原始wire入站只接受物理src/dst（非空时≤128），presence payload.deviceId同样≤128；canonical投影仅经Root持有的独立guest回调dispatch，不能来自owner socket。独立guest socket codec已在交给其私有DlClient前恢复物理地址，因此无需放宽长peer。补真实raw socket测试：注册guest后主relay发送同canonical src的push/link-close/presence不得触达guest；真正guest dispatch仍能更新。

## P2：主 relay 断开仍清掉共享调用调度队列

`DlClient.failAllPending:830–836` 无条件 `invokeScheduler.clear(err)`；新的scoped invoke也用同一个scheduler（623–638）。clear遍历所有物理分组的job，不区分canonical peer。12个guest在途操作占满后，第13个排队；主relay断开/重连/stop会拒绝这个仍有效独立guest的排队操作。InputQueue现有canonical过滤和独立shared outbox正确，但不能修复更下层的队列清理。

建议：主socket失败只取消物理owner jobs；canonical guest只由其独立transport断线/撤权或显式removeScopedPeer取消。可给scheduler增加按job.peerId过滤的clear，或给scoped生命周期单独的受控scheduler；保留原物理设备容量预算。测试：真实主client+guest注册，压满guest并发形成队列，再断主relay，释放guest在途后排队项仍从guest发出，且owner排队项已拒绝。

## P2：主 relay 状态清理仍影响独立 guest 消息恢复

`AppServices.buildEvents.onStatus:987` 每次主relay非online都调用全局 `messages.invalidateLiveTailTrust()`；后者 `MessageStore:1665–1684` 递增全局recoveryGeneration、清全部subscription ACK/heal操作、重置所有任务运行/用量状态。即使guest socket从未掉线，其订阅/stream状态也被清除，且要等主relay恢复或guest再重连才重新背书。

建议：主relay失效只fence物理owner会话，guest重连仅fence本peer；避免使用会改变guest read identity的全局recoveryGeneration。以peer/session代次保留真正独立transport的ACK及在途读取。测试保持guest streaming+已ACK时断主relay，guest ACK/运行态及其后续push持续有效；只有guest断线才失效。

## P2：独立 guest 重连与撤权没有补齐交互卡片生命周期

`AppServices.createSharedTasks.ready:734–740` 在guest重新ready时只resync InputQueue及messages，未像主relay online路径补拉 `interactions.refreshPending(peer,sessionId)`。若断线期间出现或被房主处理了权限/提问，session:get与消息历史不会恢复InteractionStore的pending快照。`closed:744–748` 也未按该scope清pending卡片和决策草稿；TaskPage.resolveInteraction虽最终会被未注册peer挡住，旧卡仍可显示/点击。

建议：guest真正ready后按其单一peer/session调用现有refreshPending，不对所有owner会话做全局恢复；guest revoked/closed时增加InteractionStore按该scope的失效/清理入口，递增该scope代次以拒绝迟到refresh/resolve，保留其它任务交互。测试guest断线期间房主新增/处理卡片，重连后按最新pending显示；撤权立刻删除该scope待处理操作，其他scope不变。

## 已核对的有效边界及尚未验收

Root固定official REST/WS和账号代次、native加密seed注入、scoped附件注册、main REST设备快照跳过canonical、shared稳定账号outbox、owner专属动作及hostOwnedConfirmation gate均有实际生产接线。Guest工厂等待实际hello、link、topic ACK和session快照；重连prepare重建真实订阅，不是假ACK。preSend末参已贯穿ActualScopedPeerPort→GuestClient→内部DlClient实际调度点，并新增真实排队测试。

Worker自审修复独占模块：AN新来源失败不再被标成完整空目录；bridge/native失败与迟到创建释放资源；并发旧账号失败不删除新账号加载句柄；管理其它任务不误撤当前guest且继续watch；媒体不把已有OSS ref/网页直链送宿主本地fetch，错误task/transport不得切官方。新增AgentNet和Media生产入口测试，共42条D单测待集成人执行。

以上是源码审查证据，不是设备或双账号验收。无Hvigor/设备/网络互通执行；AN签名加密正确性仍需固定上游测试与signed HAP双账号官方/AN收发、附件、撤权、重连真实验证。
