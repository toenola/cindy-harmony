# 智能路由模块接线

事实源固定 `91179cedad` 的 Mobile `hostModelGroups.ts`、`sourceRouteProviders.ts`、
`UnifiedModelPickerSheet.tsx`、`app/sessions/{new,[sessionId]}.tsx` 与电脑端
`model-groups/handlersCore.ts`。AppServices、新建页与任务详情已由Lead接入；真实电脑和设备验证仍待完成。

## 公共服务

由 AppServices 持有一个 `ModelRoutingStore(port)`。port.invoke 返回解包后的业务值，
不是 Device Link envelope。port.isOwner 只放行当前账号获准控制的电脑，分享访客、scoped
控制端拒绝；电脑端 `assertModelGroupsCaller` 仍为权威授权。退出调用 `setScope('', generation)`，
切账号/中转调用 `setScope(owner, newGeneration)`；每个对端连接代次更换或撤权时调用
`invalidateDevice(device)`。不会重置其他电脑。Store 无持久化、厂商请求、定时轮询或新增订阅。服务销毁调用 `dispose()` 清监听并使在途响应失效。

页面进入时订阅 `onChanged`，刷新时替换 `@State` 快照引用；页面隐藏释放订阅，不调用读取。
目录 `load(device)` 合并在途请求，成功/失败 15 秒复用，旧端 5 分钟复用；手动刷新
`load(device, true)` 仍合并在途，不清除有效的发送 ticket。旧端不支持与支持但 routes=[] 独立。

## 新建页

1. 在已有普通模型选择器内放 `ModelRoutingPanel`，传快照及本地 routeId；普通模型入口保留。
   sourceRoutes 是供应商合并来源；expandedRoutes 是可选择的展开模型路由，保留 parentName。
   老草稿可用 `implicitModelRoute(catalog,current)` 找展开路由，不把同名来源跨电脑合并。
2. 用户发送时 `prepare(device,id,context)`。图片上下文始终传；只有expanded source route传当前推理/速度，
   自定义模式不继承底层草稿effort/fast，按实际最终模式配置。SSH 传 sshHostId
   并限制 agentDeviceId=null，任务不允许移动时也传其实际位置，允许移动时不传位置。
3. `routeFor(ticket)` 在异步后重验身份，routed 时用返回的 route 走**原**创建链路；
   cc 映射 claude-code；agentDeviceId保留实际位置，仅修改当次有效参数，
   不改草稿选择和用户偏好。missing/unavailable 保留原模型，照原准入校验。
4. 已创建但首消息未派发时 `bindBeforeFirstInput(ticket,sessionId)`，只登记电脑托管、不 commit。
   调用方不得把创建成功当作首消息接受。确认原输入回执 accepted 后才调用
   `accepted(ticket,sessionId,buildModelRoutingNote(...))`。明确失败/取消不调用 accepted；
   回执未知由原投递账本对账后决定，不能提前 commit 或创建新 ticket 重发。
5. `cancel(ticket)` 使未接受 ticket 失效但**不删除已存在的电脑任务或绑定**；任务已创建且
   要主动解除绑定时由页面明确调用 unbind。操作生命周期结束 `release(ticket)` 释放去重句柄。

NewSessionPage已用ModelRoutingCreation.routedCreationRuntime按最终引擎capabilities计算permission/
plan/effort/fast，并同步到createOptions与乐观session（避免原outbox恢复回旧引擎参数）。ask/default
按目标可用模式匹配；不自动升级bypassPermissions。原plan意图沿native arm或legacy plan+restore，
目标不支持则保留输入并拒绝发送；不悄悄变成直接执行。模式指定effort不受支持时省略，速度受最终
模型与引擎能力约束，ultrafast仅Codex。local route移除旧远程位置；不修改底层草稿偏好。
选择模式可在底层模型目录不可用时发送；resolve沿用原模型的分支才刷新原目录并执行原准入。
provider:list与get-capabilities复用原owner Device Link，无厂商直连、无新增wire。route-note在精确
首输入accepted后提交。模型按钮允许仅有路由目录时打开，目录读取沿Store缓存合并。

ACP 响应在 prepare 阶段明确抛 `MODEL_ROUTING_ENGINE_UNSUPPORTED`，不改草稿、不开任务、
不静默换旧模型。resolve 请求没有已核验的 allowedEngines 字段，不能自行添加。电脑后续持续
托管可能再选择 ACP 的边界需联调核验；本模块只能保护本次明确选出的来源，不能声称电脑的
后续自动接替已受鸿蒙引擎限制。若必须全程排除 ACP，不能通过新增自造 wire 解决。

## 公共接线状态（本轮已修，待串行验证）

InputQueueStore buildQueuedMessage/applySessionContextToQueuedItem已保留session.agentDeviceId，回本机
重建createOpts排除旧位置。seedOptimisticText同文reserved语义保留由Lead实现，未重写。
TaskPage明确路由现在固定next/current位置、SSH=null；route effort/fast走原实际事务，同模型也
实际更新，effort不支持省略/清默认，速度按目标能力，不在参数更新失败时accepted。详情按真正可
重试错误includeOffer，Panel接错误/offer动作；offer用其具体route切换后bindOfferAfterSwitch再沿
原retry，不重新resolve。普通确认/跨引擎事务保持。accepted带buildModelRoutingNote。
真实电脑的延迟切换、旧端不支持set-effort空档和持续托管ACP限制仍待设备验证；未增加新wire。

## 任务详情

打开模型选择器/前台恢复/对应任务的权威模型或绑定 patch 后按需 `refreshSession`；
不要对任意流式消息 push 全量重读。只有原错误横幅存在且能重试时 includeOffer=true。
同一任务在途读合并。任务切换时丢弃旧页面操作，Store 不会代页面判断当前聚焦任务。

选择路由：prepare → routeFor → 现有模型切换（含跨引擎 pending intent）成功后 accepted；
没有 routed 来源时提示不可用并保留原模型，不为既有任务提交 unavailable。
真实模型/执行位置由现有 session runtimeEffective / agentDeviceId 显示，pendingSwitch
来自电脑 binding，不能写本地假模型。托管状态 autoSwitch/isSourceRoute/parentName 直接投影。
bind/commit/route-note失败会保留独立sessionSnapshot.error，分别为MODEL_ROUTING_BIND_INCOMPLETE、MODEL_ROUTING_COMMIT_INCOMPLETE、MODEL_ROUTING_ROUTE_NOTE_INCOMPLETE；绑定权威回读成功不表示commit或说明写入已完成，所以该错误保留至较新成功的选路或明确解绑。错误触发onChanged，不重发任何已接受输入；账号/peer失效后的迟到失败不会回写。

解除调用 unbind；只有电脑 unbound=true 才清本地投影，保留实际模型。

错误横幅提议：使用 sessionSnapshot.offer 的具体 route 调已有选择器换模型，成功后
`bindOfferAfterSwitch(device,sessionId,offer)`，然后调用原横幅重试/继续；不能重新 resolve
其 routeId（那可能得到另一个来源）。提议没有 decisionId，不推进新任务轮流位置。
ACP 提议只显示不支持原因，不提供动作。

`buildModelRoutingNote` 写既有 source=model-group 消息说明（现有字段虽然叫 pluginName，
这里没有启用插件/ACP）。reason 从 result.why/exceptions/quota 做本地化；不要把内部原因码直接
显示。sourceName + agentDeviceId 转电脑名称保留实际身份，读不到额度不借同名本机额度。

## 通道与压力

| 意图 | 既有 channel / args | 次数 |
|---|---|---|
| 目录 | model-groups:get / [{includeSourceRoutes:true}] | 一次打开按TTL读取，合并并发 |
| 解析 | model-groups:resolve / [{selection:{type:'route',id},context,location?,sshHostId?}] | 每次明确发送/选择一次 |
| 绑定 | model-groups:bind-session / [{sessionId,selection,route}] | 每ticket一次成功绑定；提议换源成功一次 |
| 接受 | model-groups:commit / [decisionId] | 首消息接受/换模型成功后一次，在途或失败不自动重试 |
| 说明 | model-groups:route-note / [{sessionId,note}] | 接受后一次 |
| 托管 | model-groups:get-session-binding / [{sessionId}] | 对应详情按需读取 |
| 提议 | model-groups:switch-offer / [{sessionId}] | 仅错误横幅可重试时一次 |
| 解除 | model-groups:unbind-session / [{sessionId}] | 用户动作一次 |

全部通过原 owner Device Link，传统/Agent-Net、官方/自建中转选择由公共 port 保持；模块不
另起连接、无厂商直连。超时/繁忙/429 由已有通道处理；写超时保留不确定结果，不自动重复提交。
缓存/票据均在内存，最多128个未释放ticket。断线只让该对端响应失效，不断开共享socket。

## 文案交接（统一加入公共语言资源）

ModelRoutingPanel 的 labels 全部由页面注入，下表 key 统一加前缀 model_routing_。
rowHint 由页面把 sources/strategy/effort 格式化；策略和原因沿官方对应模型组文案，未知码不显示。

| labels属性 / key | 简中 base | 繁中 zh_TW | 英文 en_US | 日文 ja_JP | 韩文 ko_KR |
|---|---|---|---|---|---|
| title | 智能路由 | 智慧路由 | Smart routing | スマートルーティング | 스마트 라우팅 |
| empty | 这台电脑尚未配置路由 | 這台電腦尚未設定路由 | No routes configured on this computer | このコンピュータにはルートがありません | 이 컴퓨터에 설정된 경로가 없습니다 |
| unsupported | 这台电脑暂不支持智能路由 | 這台電腦暫不支援智慧路由 | This computer does not support smart routing | このコンピュータはスマートルーティングに未対応です | 이 컴퓨터는 스마트 라우팅을 지원하지 않습니다 |
| loading | 正在读取路由 | 正在讀取路由 | Loading routes | ルートを読み込み中 | 경로 불러오는 중 |
| unavailable | 暂时无法读取路由，请重试 | 暫時無法讀取路由，請重試 | Unable to load routes. Try again. | ルートを読み込めません。再試行してください | 경로를 불러올 수 없습니다. 다시 시도하세요 |
| refresh | 刷新 | 重新整理 | Refresh | 更新 | 새로고침 |
| unbind | 解除托管，保留当前模型 | 解除託管，保留目前模型 | Detach and keep current model | 管理を解除して現在のモデルを維持 | 관리 해제 및 현재 모델 유지 |
| managed | 持续托管 | 持續託管 | Managed routing | 継続管理中 | 지속 관리 중 |
| fixed | 当前路由 | 目前路由 | Current route | 現在のルート | 현재 경로 |
| pending | 下一条消息将切换来源 | 下一則訊息將切換來源 | Source changes on the next message | 次のメッセージから切り替え | 다음 메시지부터 소스 전환 |
| fallback | 换来源继续 | 換來源繼續 | Switch source and continue | ソースを切り替えて続行 | 소스 변경 후 계속 |
| kept | 暂无可用来源，保留原模型 | 暫無可用來源，保留原模型 | No available source. Keeping original model. | 利用可能なソースがないため元のモデルを維持 | 사용 가능한 소스가 없어 기존 모델 유지 |
| unsupportedEngine | 此路由选中了暂不支持的引擎，请更换路由 | 此路由選中了暫不支援的引擎，請更換路由 | This route selected an unsupported engine. Choose another route. | 未対応のエンジンです。別のルートを選んでください | 지원하지 않는 엔진입니다. 다른 경로를 선택하세요 |
| selected | 已选择 | 已選取 | Selected | 選択中 | 선택됨 |
| ordinary | 选择普通模型 | 選擇一般模型 | Choose a model | モデルを選択 | 모델 선택 |

## 验证状态

独立 `ModelRouting.test.ets` 覆盖15个行为分支（新增目标引擎权限/plan/effort/速度），Lead 将 default 导出的
modelRoutingTests 注册到公共 LocalUnit/List 入口。按分工未执行单测、Hvigor、静态编译或设备安装；
未修改签名。仍需验证：注册后编译/单测、真实owner电脑新建/首发/换模型/解绑、未知回执与取消、
两台电脑同名来源/离线/旧端、重连及切账号、ACP解析及持续托管限制、Light/Dark/窄屏/折叠与大字体。
