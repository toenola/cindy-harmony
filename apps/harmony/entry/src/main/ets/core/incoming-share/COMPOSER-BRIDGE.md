# 已实现的持久草稿 adopter（替代 draftPort stub）

## 构造与所有权

`createHarmonyIncomingComposerBridge(context)` 返回已实现 IncomingShareDraftPort 的
IncomingComposerDraftBridge，直接传给 `incomingShares.adopt(batchId,destination,bridge)`。
不需要root再实现复制文件、文本合并或批次去重。认证ready后调用
`await bridge.setOwner(ownerKey,sessionEpoch)`；同owner换代只fence在途，保留本账号草稿，
owner变化/显式logout清旧批次并回收独立草稿文件，销毁dispose。所有权必须等accountClientsReady后设置：预恢复阶段不要传空owner，否则会把仍待恢复的同账号草稿当logout清理。
监听onChanged，pendingTargets
给出当前账号已有持久导入的真实目标；根启动时也需检查它，以覆盖inbox已消费但目标页尚未打开就崩溃的窗口。空sessionId表示新任务，不通过创建任务来领取。

存储是filesDir/incoming-composer-ledger-v1.json（原子替换）及独立
incoming-composer-files/<UUID>/<原始安全文件名>。每个复制目标**先写WAL**，再从受控inbox根
复制到.partial、校验长度/fsync/rename，复制进度逐文件持久化；崩溃重试复用原目标。只接受同App
规范URI和inbox私有路径，删除只碰该Bridge自己的文件。不会发送/创建消息、远控模型或直连厂商。
最多64批，完成幂等receipt保留256条，账本不超过4MiB字符；超限明确失败并保留inbox，不静默丢内容。

## 已接入的公共元数据与页面

公共ComposerDocument/ComposerDraftStore receipt补丁已由Lead完成；AppServices已装配真实bridge并在
accountClientsReady后绑定owner。NewSessionPage已接本节端口、原composerImages/uploadImage与fileQueue，
仅consume owner/device/session=''；TaskPage由Lead接。新建页保留完整doc并通过原serializer生成首输入，
图片仍走原上传路径，领取只填入、不创建或发送。新建导入草稿按电脑保存，目标/账号不匹配时禁止发送。

以下是保持兼容所需的本地元数据契约：

为原ComposerDocument增加**仅本地存储**的 `incomingShareBatchIds: string[] = []`：

- composerDocumentToStorage把数组写到同名字段；parseStoredComposerDocument仅接收非空字符串、
  单个最长128、数组最多256，未带该字段按[]，不改version=1、不进消息wire。
- normalizeComposerDocument、replaceComposerTextRange、removeComposerNode新建out后，复制输入
  `incomingShareBatchIds.slice()`。reconcileComposerProjectedText的nextText==''分支返回带原receipt
  的空节点文档：用户手动删文字不等于重新领取分享。显式emptyComposerDocument/clear仍是真正新空草稿。
- ComposerDraftStore.save只有 `nodes.length===0 && incomingShareBatchIds.length===0` 才删除草稿；
  纯附件分享也必须把receipt与空正文一起持久化。

Bridge会先把拟保存文档经**真实** composerDocumentToStorage/parseStoredComposerDocument往返，
若receipt丢失，在写入UI前抛INCOMING_COMPOSER_RECEIPTS_UNSUPPORTED；不会靠内存“假幂等”。
这份补丁覆盖“普通草稿已flush、bridge ack尚未落盘”窗口，属于现有已授权本地草稿存储，不新增wire。

NewSessionPage保留newSessionDocument字段：restoreNewSessionDraft同时赋该doc；
applyNewSessionInput已用reconcileComposerProjectedText(newSessionDocument,value)更新并保存该doc。
显式发送/放弃后的clear才重置emptyComposerDocument。input字符串和原页面行为保持原样，
不用把附件塞进ComposerDocument。TaskPage已有composerDocument/setComposerDocument可直接复用。

## 两页只接以下薄端口

页面正常restore后，确认当前owner/device/session、当前paneActive、未处于编辑旧消息/队列、
原图片+文件总数可容纳，再 `await bridge.consume(destination,documentsPort)`。

`IncomingComposerDocuments` 只需要两个方法，所有合并算法在Bridge内：

```text
read(destination): Promise<ComposerDocument>
compareAndSave(destination, expectedStorage: string, document: ComposerDocument): Promise<boolean>
```

- read返回当前真实UI文档（新建页newSessionDocument、任务页composerDocument），不是截图/拼文本副本。
- compareAndSave在同一同步段核对owner/目标/页面代次及
  `composerDocumentToStorage(currentDocument)===expectedStorage`；不同返回false，Bridge最多重新读取3次。
- 相同则**替换**UI文档（不append），立即调用现有ComposerDraftStore.save，await flush。
  新建key=`__new-session__`、无device；任务key=sessionId、deviceId。flush失败抛Error，不返回成功。
  入参中的document已经包含新的本地receipt和完整quote/mention等节点，不再重新textComposerDocument。
- 若await期间账号/目标变化，应拒绝旧页面写入；UI在consume阶段沿原busy禁用发送/重复领取。
  Bridge也会再次检查账号代次。接收不触发send，页面离开不discard。

consume返回IncomingComposerDelivery：document（真实合并结果）、batchIds、files（稳定id、独立uri、
name/mime/size及来源）。按files原顺序分别送现有imageQueue.enqueue(imageUris)和fileQueue.enqueue(fileUris)，
两个队列都按URI去重。收集实际images/files的uri后 `bridge.ack(delivery,actualQueuedUris)`；
少任何一个会抛INCOMING_COMPOSER_QUEUE_INCOMPLETE，不能清导入。ack仍保留独立文件和来源以供冷启动
重建队列；再次consume不会重复追加正文。文件名保留供原fileQueue从URI取名，MIME保留可分到图片队列。

现有upload队列的本地URI去重只覆盖活跃页，冷启动可能重做未确认上传；Bridge保证不重复正文/任务输入，
不冒称上传对象只写一次。附件用户明确移除时，先按原队列remove/cancel，再bridge.removeFile(target,file.id)，
否则重启会按仍归草稿所有的来源恢复。普通打字继续走原ComposerDraftStore，不需要另加高频账本写入。

## 明示发送和未知回执（保留原outbox为权威）

- consume/ack绝不发送。用户点原发送按钮时，拿**原管线已有clientId**，先
  `bridge.prepareInput(delivery,clientId)` 持久登记输入所有权移交意图，然后才执行原enqueue。
  Bridge.isBusy()时不允许该移交，防止仍在合并的草稿与发送竞争；不另造第二套clientId。
- 原持久发件箱已经持有正文和可恢复附件引用/独立副本，调用
  `bridge.reconcileInput(target,clientId,'owned')`，才释放本Bridge的草稿文件并保留消费receipt。
  不能只因网络write()返回就传owned，不能在附件仍依赖本Bridge本地文件时提前删除。
- 明确未写入发件箱传'absent'，恢复同一份草稿；回执不确定传'unknown'，保持queued，不生成新输入。
  冷启动先看pendingInputs(target)（含clientId、原sessionId、batchIds），由原outbox按这些**同clientId**回查/对账；未定时禁止把这份输入
  当新草稿重新发送。consume会排除queued批次的附件，但不会自行修改原页面发送状态。
- 新建任务prepareInput第三参数传预生成sessionId。reserveDocument沿原createDocumentClientId生成的
  stableClientId；确认持久RemoteRefs后owned同步落账，再clear/启动原创建发送。reserve/owned同步失败且
  尚未远端dispatch时，discardReserved精确ID并reconcile absent，不能保留一个reserved副本再按新ID发送。
- owned receipt还持久保存原clientId/sessionId。committedInputs(target,documentReceiptIds)覆盖owned已落账、
  页面尚未clear就崩溃的窗口；此时沿原任务恢复，绝不能按新ID重发，即便原outbox已被接受后清理。
  hasCommittedInput(target)供新建页确定是否读取该电脑的旧草稿；实际恢复只匹配仍在文档中的receipt。
- owned/discard/remove的账本写入仍同步抛错。提交后垃圾回收失败不撤销所有权、不reject已提交结果；
  cleanupPending()/retryCleanup()保留并重试受控垃圾。不能因异步GC失败删掉原发件箱。
- 原普通队列若尚未把batch映射到现有clientId，请Lead在原enqueue边界加上述两次调用；不改wire。
  明确放弃导入才调用discard(target)；有queued未知输入时拒绝丢弃，先沿原投递账本处理。

## 已写验证与仍需串行验证

IncomingComposerDraftBridge.test.ets有10项生产行为用例：相同批次/目标、文件复制后WAL失败重启、
文档flush后ack前崩溃、内存receipt但flush失败必须再次flush、部分队列领取、移除/重启、账号变化
在途复制、未知原clientId与原outbox移交、CAS有界重试及quote节点、相邻文本canonical CAS、
owned后GC失败与原新任务ID恢复。run7的两项失败来自测试port把磁盘原字符串与parser归一化的活文档
CAS比较；已修port使用实际read文档序列化值，生产append同时归一化到parser相同形状，保留两个崩溃
断言及真实serializer。该轮修改与新增用例待Lead串行复跑；Worker未启动Hvigor、设备或构建。

请统一注册default incomingComposerDraftBridgeTests；native复制、纯附件、两页真实队列、重启、
切账号/断网、明确发送与未知回执仍需Lead串行验证。存量inbox“复制后WAL前”的旧孤立文件窗口不
由Bridge随意扫描；Bridge自身新复制目标已先入WAL，之后可按持久garbage安全回收。

## 本轮四个公共文件修复与命令意图

TaskPage已接原draft恢复完成fence、consume/编辑/命令/发送互斥，容量预检在CAS前，失败blocked与
明示resume，CAS flush后再次核对模式与revision。queued恢复只沿原outbox同ID，owned后clear前
崩溃按committedInputs处理；completed receipt新增documentStorage，只有真实doc仍等于发送前
快照才清空，若用户之后改过则保留正文并显示未知，不能删新草稿。调用prepareInput/prepareCommand
前需把delivery.document更新为实际当前composerDocument（不是最初consume时的旧doc）。

Bridge.prepareCommand(delivery,actionId)只写本地command-pending WAL，不发消息、不伪造普通outbox。
pendingCommands(target)列出未确认动作，普通consume/pendingInputs排除它们；不能用outbox不存在
推断动作没执行。completeCommand(target,actionId,runId)仅在原learn:start返回非空真实runId后
提交消费receipt，保存runId和原任务，GC失败与消费独立。超时/异常/缺runId保留意图，明确显示
投递未知，用户在原任务查看；该Host命令没有幂等键，不提供自动或新ID重复执行。

MessageEdit.mergeMessageEditDraft对所有part做receipt有界union（纯receipt也保留），复制nodes防止
normalize反向改动stash。InputQueueStore.discardReserved先确认没开始dispatch，再调用新增
PersistentInputOutbox.removeReservedStrict，成功才精准移除该ID的内存deferred/projection/delivery。
严格端口只认API26 unlinkSync的13900002为ENOENT，其它错误保留records并抛；一般remove不变。
InputQueue seedOptimisticText保留reserved同文语义由Lead实现；本轮补缺失recordOrEmpty import。

IncomingComposerDraftBridge.test现20项：新增命令未知/重启/真实runId消费、defer后owned落盘失败
回滚再tap仅一个ID（含远程来源恢复/回本机）、编辑stash及纯附件空doc重启。原CAS/账号/GC测试
保留。独立SDK fake实际调用PersistentInputOutbox public init/scope/put/removeReservedStrict，覆盖
unlink权限失败保留盘与records/重启、sendStarted拒删、成功删除、精确ENOENT与字符串伪ENOENT拒绝。
由Lead串行运行：CINDY_ARKTS_TYPESCRIPT=<可require的TypeScript模块> node
entry/src/test/incoming-reservation-sdk.mjs（工作目录apps/harmony）。Worker未运行测试或构建。

NewSessionPage实际doc快照接线已完成：prepare前更新delivery.document，恢复只匹配快照才clear。

## 最终普通草稿/忙态边界修复

TaskPage对sending/queueBusy/pickingImages/pickingFiles统一Watch；IncomingComposerIdleGate只合并
同一UI轮的空闲通知，回调前重验原lifecycle和全部idle，再进入原consume互斥。不会监听
incomingImportBusy的结束而形成无限领取循环；无网络轮询，不生成发送动作。

NewSessionPage不再用hasCommittedInput历史决定普通草稿scope。IncomingNewSessionDrafts先
readScopedOnly；只有真实pending或文档receipt选择device草稿，其余走原global。旧普通scoped
内容只在global仍空且CAS成功并flush后clearScopedOnly；已有/并发global新编辑优先，旧source
保留，绝不覆盖。相同正文global说明上次迁回已写成功，可仅清重复source。新端口不改变原read/
claim/save/clear调用语义，不让迁回触发原removeLegacyDraftLater。

ComposerDraftStore新增readScopedOnly、clearScopedOnly（需expectedStorage）、
compareAndFlushGlobal（expectedStorage+页面fence），所有global读写沿原每scope操作队列。
CAS native写期间若发生新save则立即flush较新global，返回false且不清source。错误保留恢复来源。
新增5项实际入口回归：idle合并/过期lifecycle、scoped读取清理不删global、普通scoped安全迁回后
另一电脑仍读同全局、并发global新编辑获胜且source保留、只有pending/receipt使用device作用域。
测试使用真实ComposerDraftStore与内存SecureStore子类，不做源码扫描、不等真实定时器。
