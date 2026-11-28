# D：实际共享任务适配与接线

固定事实源 `91179cedad`：device-link `sharedTaskApi/Peer/Envelope/Invitation`、device-link-protocol `sharedTask/protocol`、Mobile `useSharedTaskApi` / `agentNetSharing` / `agentNetMedia`，以及 host `sharedTaskDispatch`。全部实现只在独占目录，没有修改公共协议或现有 owner portable 文件。

## 现在可调用的工厂

`SharedTasksHost.ets::createSharedTasksHost(options: SharedTasksHostOptions): SharedTasksHost` 已是实际适配器。Options 精确类型在同文件：

- `officialApiBase`、`officialWsUrl`、构建 scheme `app`；必须给官方端点，不能给当前自建 control relay。`allowOfficial?()` 对应现有是否允许传统通道偏好；不允许时不回落传统。
- `accountId()`、`scope()`：现有 Auth 的账号及账号/区域/授权/连接配置代次；模块不新建认证、不读用户token文件。
- `apiFetch(path, {baseUrl,method,body?,cache:'no-store',timeoutMs:12000,assertCurrent})`：接 Auth 当前带身份请求。官方API由适配器强制固定 base；请求前后检查scope。API错误需保留code/status。
- `ownerInvoke(deviceId,channel,args)`：接已有同账号 `invokeOwnedModule`，只调用 `maker:shared-task`；`openOwner(detail)` 验证目标仍是同账号可控电脑后打开原任务。
- `getToken()`、`getHello()`、`createOfficialWs()`、`refreshAuth()`：现有认证/原生WsAdapter工厂，独立DlClient只短暂消费回调结果，不保存副本。
- `media: SharedTaskMediaPorts`：上层本任务授权的文件IO与媒体引用/结果包装。上传、取回严格走该scoped peer；不走owner P2P/exportFileStart。AN加密数据后台已实现，见下。
- `guestReady(transport: SharedTaskReadyTransport)`：**工厂已完成真实hello、双端shared-task-v2、link-accept、服务器session topic订阅ACK、匹配session:get，才调用此回调**。登记 `transport.target.peer -> transport.scopedPort()`（直接符合公共ScopedPeerPort）；把transport.session放在该canonical peer名下。`transport.subscribe(listener)`只登记已就绪的本地push监听，不能伪造订阅ACK；公共后续subscribe也会调用真实服务器。`transport.onClosed`撤销公共注册和session订阅。
- 可选 `agentNet: createSharedTaskAgentNetAdapter(ports)`；Host组合官方与AN目录，最多四路AN origin并发/12秒总预算，失败分片保留unavailable/authorityIncomplete；有pin的AN请求失败绝不回落官方。不同authority同ID冲突fail-closed。

Host.dispose关闭自己的guest/native业务连接；根层在账号/区域边界调用。Store.dispose只清自身视图、access和timer；如Host生命周期更长，由根层统一释放。

## 独立 guest DlClient 与 scope

`SharedTaskGuestClient.ets::createSharedTaskGuestClient(detail,memberId,ports)` 返回 ready transport。`SharedTaskScope.ets` 对齐上述固定peer/protocol原文：canonical本地key是JSON四元组padEnd(129,'~')，wire src/dst始终物理ID；source只能来自可信socket/已验签AN delegation，不接受发送端伪造source。缺能力、provider混scope、错误task/member/物理host、无scope routed回复都拒绝。

内部DlClient与公共canonical路由guard的冲突已经解决：内部client只用其固定host的**物理ID**，`SharedTaskSocket`私有实例注入`SharedTaskScopeCodec(...,physicalClient=true)`，仅为该task+host添加scope。入站先严格验证scope再在私有client内还原物理地址，外部target永远canonical。没有全局放开长peer、没有递归注册自身、没有未注册peer回退owner。内部任何其它物理目标都会被socket codec拒绝。

readyTransport还提供 routing的getStatus/connectionIdentity/onStatus、真实invokeEnvelope/subscribeTopics/unsubscribeTopics；`scopedPort()`已经适配公共DlClient的unwrapped invoke与Promise<void>订阅。订阅目前仅接受这个`session:<id>`，不允许全局`sessions`。host-owned workdir/fs-watch的扩展需按实际绑定另接，不能把任意目录topic放行。

## 原生 AN 注入：确切声明

`SharedTaskAgentNet.ets` 的 `SharedTaskAgentNetPorts`：

- `bridge`：独立portable的 `parseSharingInvitation(input):string`、`buildSharingInvitation(receiptJson,server,app):string`、`createAgentNetSharing(configJson,host):Promise<AgentNetSharingConnection>`。
- `scope/accountId/deviceId/region/getHello/media`：现有账号/设备/区域与界面媒体端口。
- `accountOrigin?(): SharedAgentNetOrigin|null`：现有已验证Agent-Net身份的 **server/v/networkId/rootPublicKey/region/privateMember/subject** 元数据，不是用户输入或邀请码猜测。模块从该authority实际读目录、验证pin并归一化本账号owner subject；privateMember只在当前identity的server+network+root全匹配时使用。共享邀请选择的来源由模块保存与比较。
- `loadRoutes(scope):Promise<SharedAgentNetRoute[]>` / `saveRoutes(scope,routes)`：沿批准的账号数据区保存元数据pin。包含v/server/networkId/rootPublicKey/hostDeviceId/resourceId/kind/region/memberId/retired/keyId及可选当前成员投影；**不含邀请、seed、私钥、token**。1024上限，写串行，退休路由不回退其它服务。
- `randomKeyId():string`：系统安全随机18字节base64url（24字符），只是secure seed的引用ID。相同未退休member可复用，退休/新member必须换引用。
- `createNative(config: SharedAgentNetConfig,current:()=>boolean):Promise<SharingNativeHost>`。以下是完整native对象函数：

```text
check(): void
command(engine: string, input: string): string
sha256(base64url: string): string
identityCard(nonce: string): Promise<string>
memberAuthorization(method: string, path: string, body: string): Promise<string>
request(address: string, method: string, headersJson: string, body: string, binary: boolean): Promise<string>
socket(address: string, headersJson: string, callbacks: SharingWireCallbacks): SharingWireSocket
message(text: string): void
close(code: number): void
error(): void
destroyEngine(engine: string): void
destroy(): void
```

engine为`business`、`applicant`、`transport`；command直接沿已有AgentNetEngine.command，`{op:identity/sign/random/verify/...}`入参、`{ok,value}`响应；applicant还处理已有media*命令。business signer按账号/物理device的secure seed，context=`cindy-agent-net/sharing-business/2`；applicant/transport按config.keyId取同一secure seed，context为`JSON.stringify(['cindy-agent-net/sharing-transport/2',rootPublicKey,'shared-task',resourceId])`。applicant无UDP，transport为既有增强NativeTransport；v2 deviceId=当前物理device，v3 deviceId=`guest:`+business signingKey。**engine按需初始化**：业务目录/加入阶段没有member/keyId，不应提前要求applicant seed；只有connect阶段调用其identity。新seed只在本模块 `SharingSeedStore` 的 Harmony AssetStore 加密独立 namespace；仅原生装配短暂读取到内存，不进 preferences、portable config、路由元数据或日志。

request只允许config.server下既有`/api/agent-net/*`目标，禁止redirect，携带模块已签名headers，返回`{status,headers,body:base64url}` JSON；socket即既有binary WireSocket（回调open/message(data,binary)/close(code)/error）。identityCard调用现有Auth `/api/me/identity-card` `{audience:'cindy-agent-net-sharing',purpose:'network-session',nonce}`并返回`{card,expiresAt}` JSON，不能把refresh token或账号bearer送给私有服务。memberAuthorization仅对当前匹配私网的真实成员调用现有`api.header(method,path,body)`。

模块已真正使用固定官方AgentNetSharingClient加签、身份卡nonce绑定、possession SharingTransport、root certificate/delegation/issuer/executors/guest keys/member/root/network/resource核验，独立scoped AgentNetSocket+NativeTransport，并在到期前60秒续租，单次租约获取沿官方有界退避。新邀请的来源pin冲突被拒绝；本账号已是该私网成员时不会借共享邀请降格加入。

## AN portable 资产（交集成人串行执行）

没有修改既有 `core/device-link/portable`。独立源码为`core/shared-tasks/portable/SharingBridge.mjs`；`portable/build.mjs`只提取固定91179cedad的agent-net/agent-net-protocol/device-link-protocol与peer helpers到Harmony `.cache`，然后esbuild生成同目录`sharing.js`，避免本地旧packages混进新行为。默认offline；缓存缺失直接失败，不偷偷下载。需要安装时按已有依赖流程明确使用`--allow-download`。Worker此前仅完成一次独立资产生成（267.8KB，banner标注固定 upstream），未执行Hvigor、测试、安装或Git写操作；后续生成完全交Lead串行执行。

```text
# cwd apps/harmony，由Lead串行执行
node entry/src/main/ets/core/shared-tasks/portable/build.mjs
```

`sharing.d.ts`已声明导出（含scoped媒体删除helper），另`installSharingWebApis(parseUrl,queryPairs)`在使用邀请parser之前调用：parseUrl返回native URL属性JSON；queryPairs返回保留重复键的`[[key,value],...]` JSON。它仅为现有URL polyfill补缺失origin/searchParams，不替换已存在构造函数，参数重复检查遵循官方实现。原owner桥无须增加export。

## AN 媒体已经实现的后台

readyTransport.agentNetMedia：

- `upload(size,mime,read(offset,length)->Promise<base64url>):Promise<json{key,sha256,size}>`
- `download(key,write(base64url,offset)->Promise<void>):Promise<json{size,mimeType}>`

实际调用固定`uploadNativeMedia/readNativeMedia`，每次验证current，最多两个媒体操作，逐chunk读取/加密/写入，不构造整文件base64；slot与Mobile同源哈希，上传绑定当前verified scopedPeerTarget/recipient transport key，返回key含grantId/sharedTaskId/deviceId。取回校验slot/network/sharedTask并由当前lease授权解密。`SharedTaskMedia.ets` 已实现有授权的暂存IO、完整性元数据与已有附件ref/预览结果包装；不能把an3 receipt交普通OSS，也不能用同账号P2P/exportFileStart兜底。普通路径本身不提供授权，预览仍应先经该任务host媒体RPC确认。

## Harmony 原生装配与加密持久化

实际导出保持 Root 约定，无需新增 Rust command 或改现有 portable：

```ts
import { HarmonySharingNative, sharingParseUrl, sharingQueryPairs } from './shared-tasks/HarmonySharingNative';
import { createSharedTaskMediaPorts } from './shared-tasks/SharedTaskMedia';
import * as sharing from './shared-tasks/portable/sharing';

sharing.installSharingWebApis(sharingParseUrl, sharingQueryPairs);
const native = new HarmonySharingNative({ auth, secureStore: privateClientStorage, scope });
const media = createSharedTaskMediaPorts({ auth, officialApiBase, scope, readyGuest, context });
// createSharedTaskAgentNetAdapter ports:
// createNative: (config, current) => native.create(config, current)
// randomKeyId: () => native.randomKeyId()
// accountOrigin: () => native.accountOrigin()
// accountOrigins: () => native.accountOrigins()
// loadRoutes: (s) => native.loadRoutes(s)
// saveRoutes: (s, routes) => native.saveRoutes(s, routes)
```

`SharingSeedStore(storage?,system?)` 的可选第二参是 `SharingSeedSystemPort`（utf8Encode/utf8Decode/sha256/randomBytes/base64）。生产不注入则使用Harmony系统默认；不会因测试空桩切换到伪随机或明文。`SharedTaskMediaOptions.attachmentCodec?` 同样只隔离现有系统编码边界，生产默认保持原AttachmentOssRef；Unit只用已解码的非法key验证授权拒绝，不声称真实OSS成功。邀请及媒体URL校验采用严格纯字符串语法，不触发平台URL副作用。

`HarmonySharingNativeOptions.secureStore` 显式接受现有 `SecureStore` 类；兼容别名 `SharingSecretStore = SecureStore`。这个依赖仅存不含秘密的 routes 元数据。`context` 是 `common.UIAbilityContext`，`readyGuest(peer)` 返回已就绪注册的 transport 或 null。`getHello` 仍放 AgentNet adapter options，不加到 native 构造。

新 business/applicant/transport 签名seed使用 `SharingSeedStore`：namespace `cindy.shared-task-seed.v1.<SHA256(region,account,key)>`，`REQUIRE_ATTR_ENCRYPTED` + `DEVICE_UNLOCKED` + `SYNC NEVER`；并发首次创建不覆盖已有密钥，失败拒绝明文回退。原已加入私网 member 的seed只消费既有 RelayRoute 加密成员凭据。固定 Mobile 同样保留账号加密签名身份以便重登恢复，不在普通 logout 轮换身份；logout/账号代次切换关闭所有native引擎、socket、请求、pending引用，所有seed/网络await前后均守代次。Root应保存native实例并在runtime.dispose调用 `native.dispose()` 取消auth监听，媒体调用 `media.dispose()` 清理其授权暂存文件。

官方媒体走固定官方 `presign-put {size,contentType,ext,sharedTaskId}` 与原生HTTPS PUT；本地媒体取回先经对应 scoped guest 的 `device-link:media:fetch` 授权，再固定官方 `presign-get {key}`；已有OSS附件ref直接由固定官方presign或当前AN lease检查任务成员资格，不把OSS ref发送给只支持宿主本地媒体的fetch RPC。普通网页URL维持直链语义，仍先检查guest有效。失败上传只在该scope仍有效时清理已分配key，不重试写操作。AN走实际native chunk媒体后台，下载只写当前模块随机cache文件，guest关闭/失败/dispose清理；从不借owner媒体链。

## Store、UI 和真实接口

SharedTasksStore.configure(scope,accountId,name,online) / setVisible / setTaskVisible / onChanged / refresh / select / selectOwnerTask / join / open / start / invite / remove / leave / closeSharing / dispose。SharedTasksPanel由设置入口或任务内共享入口复用；createSharedTaskLabels(locale)五语言；onCopy必须接真实剪贴板写入。普通TaskPage继续使用原消息Store、InputQueue/clientId和附件队列，所有guest调用通过登记的scopedPort；TaskPage模型/Agent/权限/归档等owner操作gate及hostOwnedConfirmation禁答由根层接。SharedTaskAccess在退出/撤权同步关闭、释放订阅并拒绝迟到媒体/消息结果。

传统API始终官方：GET `/api/device-link/shared-tasks`、GET `/:id`、POST `/join {invitation,displayName}`、POST `/:id/leave {}`。owner电脑管理`maker:shared-task` state/open(sessionId)、invite/close/remove(sharedTaskId,memberId?)；手机不直接create共享。新invitation/open后补权威目录确认实际来源，来源不明不造官方邀请链接。名额沿服务错误，不硬编码配额。权威404 NOT_FOUND、ACCESS_REVOKED、closed才结束访问；临时失败保留历史。guest详情5秒single-flight watch；管理另一任务/目录时，当前可见guest另作串行有界权威读取，避免失去撤权watch或错误结束别的任务；目录30/60秒，隐藏停止，消息靠scoped推送。

官方邀请parser/builder和15分钟内存意图在SharedTaskInvitation.ets，不自动读剪贴板、不落盘邀请；首次登录接续，切账号/退出页清空。`parseOfficialSharedTaskInvitation` 同时接传统fragment链接、裸token和固定上游原生handoff：`cindy/cindycn/cindydev://shared-task/join?invitation=...&server=...` 或 `://shared-session?...`，严格host/path、两个唯一query、无hash/credential/port/额外字段。原生intent仍只比较配置的官方server，foreign返回different-server，不替换请求endpoint。解析不自动join。

`SharedTaskMediaKey.ets::requiresScopedMediaCleanup(key)` 是无SDK的删除路由guard：task-owned namespace（含an3-hex）始终true；raw `agent-net-v3/<slot>/<network>/<grant>/<object>/<hash>/<mime>` 中grant非`-`的delegated receipt为true，grant=`-`的普通owner AN保持false。它不替代实际authority完整key解析。普通AttachmentUpload删除应先跳过requiresScopedMediaCleanup，再走原owner agent-net-v3分支；不得把整个agent-net-v3前缀一律跳过，否则owner删除分支不可达。实际scoped删除现已补齐，接线见后面的删除端口说明；不能借RelayRoute.owner socket清共享对象。

## 验证与尚未验收

- `SharedTasksStore.test.ets` -> sharedTasksStoreTests，8条真实管理/退出/角色/撤权中媒体/partial authority/管理另一任务不误撤当前guest/目录视图仍watch当前guest用例。
- `SharedTaskScope.test.ets` -> sharedTaskScopeTests，6条真实wire/source/peer/capability降级测试。
- `SharedTaskGuestClient.test.ets` -> sharedTaskGuestClientTests，6条**实际独立DlClient open path**：native fake socket hello→scoped link→真实订阅ACK→session:get；无scope同ID伪响应拒绝；旧relay失败不发送control；订阅不得合成ACK/不得订阅sessions；真实内部12并发排队后的user preSend失效不得发包。
- `SharedTasksHost.test.ets` -> sharedTasksHostTests，11条实际HTTP适配/固定来源/AN失败不回官方/账号迟到响应/原始authority错误码与HTTP状态保留，以及纯字符串邀请URL边界测试。

- `SharedTaskSeedStore.test.ets` -> sharedTaskSeedStoreTests，4条实际加密seed存储入口：加密属性与账号/区域/用途隔离/稳定身份、系统库错误不创建替代密钥、错误随机字节不写Asset、logout期间迟到查询不返回或新写seed。系统Crypto/Text/Base64与Asset端口在Unit测试中显式替换为确定性bytes假体，不使用LocalUnit空桩模拟成功；生产默认仍仅使用系统实现。

- `SharedTaskAgentNet.test.ets` -> sharedTaskAgentNetTests，11条生产AN适配器/Socket/portable删除入口，替换签名网络端口：新来源失败partial、来源pin冲突、native/bridge失败与账号切换资源清理、退休member新seed引用、关闭期间迟到连接。
- `SharedTaskMedia.test.ets` -> sharedTaskMediaTests，14条生产媒体factory.fetch/delete/cleanup guard入口：本地RPC、网页直链、迟到撤权、task/transport边界、缺注册/dispose、跨任务OSS与AN不得回退官方。

D共60条，共7套；新增AgentNet/Media套件需Lead注册，所有增量待Lead串行运行，Worker未执行测试/构建/签名/设备。run6的ETS delete错误已全部替换成按键过滤复制，wire仍真正移除src；.at兼容与弹窗message也已修。

尚需根层最终装配与注册，TaskPage访客gate、深链接线，signed HAP和双账号官方/AN实际收发/附件/撤权验证。AssetStore设备解锁/权限及原生HTTP/WS/附件实际兼容均未在设备验收。代码有实际协议实现和真实open路径测试，但未将源码或fake relay测试标成真实双账号验收。

## Scoped media deletion

The actual deletion chain is implemented in the owned module:

- `SharedTaskMediaPorts.delete?(target, key)` -> `SharedTaskMedia.delete(target, key)`.
- `SharedTaskGuestTransport.delete?(key)`, the concrete GuestClient and SharedTaskAccess fence authorization before and after the awaited operation.
- `readyTransport.agentNetMedia.delete?(key)` -> AgentNetSharingSocket -> the actual portable connection's `deleteMedia(key)`.

Root may add `delete(key)` to its scoped attachment route and retain the original canonical peer for each uploaded key. Missing route/port must reject; an optional call returning undefined must never count as completed deletion. Replacement or revoked guests cannot take over an old operation. Ordinary owner AN receipts remain on their original owner path through `requiresScopedMediaCleanup`.

Official task keys are checked against the current task namespace before authenticated `DELETE /api/device-link/media {key}` at the fixed official API. Budget is 12 seconds with no redirects/cache or automatic write retry. AN receipts go exclusively through the current verified guest lease: the fixed upstream full receipt parser validates the key, then slot/network/sharedTaskId are matched to the live scoped source before its existing `DELETE /media/:id`. Native proof/member/root checks remain in the actual current PortableAgentNetClient. No owner or official fallback exists for native deletion; unsupported old bridges reject. Existing downloaded consumer copies keep their normal local cache lifecycle.

`SharedTaskMediaOptions.http?` exposes only the native HTTP system boundary; production defaults to HarmonyHttp. Unit tests replace it explicitly and exercise the actual fixed deletion route, key, method, concurrency and generation checks. They do not claim real OSS deletion or native crypto verification.

**Portable source changed:** Lead must regenerate `portable/sharing.js` from build.mjs before compiling/running the new tests. Worker has not generated the artifact. Pure TS declarations include `deleteMedia?` and the production helper `deleteScopedAgentNetMedia(key, scopeJson, current, remove)`. The helper is also tested using real receipt parsing; in production its remove callback is closed over the already authenticated `live.api`, never an input-selected origin.

Additional production tests cover official DELETE, native lease selection, cross-task and transport rejection, revocation during deletion, missing capability, complete native receipt/source validation, actual socket delegation and GuestClient's canonical target. D now contains 60 tests in the same seven suites; all deletion additions await Lead's serialized run.
