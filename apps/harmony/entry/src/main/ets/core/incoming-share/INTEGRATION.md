# 系统分享接收接线

## 已核验平台入口

通过本机 devecocli docs search/read 核对 `share-interface-description`，并读取已安装 API26
原始 SDK 的 `@hms.collaboration.systemShare.d.ts`、uniformTypeDescriptor 和 fileIo 声明。
入口是 `ohos.want.action.sendData` → `systemShare.getSharedData(want)` → `SharedData.getRecords()`，
每条 SharedRecord 的 utd/content/uri/title 为官方字段，未猜测或扩展 Want 中的分享数据键。

参考官方固定快照 `91179cedad` 的 IncomingShareBridge/useIncomingShareComposer/incomingShare：
登录前保留，预览选目标，领取后进入真实 composer，绝不在接收时发消息。

## EntryAbility / AppServices（Lead已接入，以下保持接口契约）

- 拿到 context 后构造：`new IncomingShareStore(new HarmonyIncomingShareStorage(context),
  new HarmonyIncomingShareStaging(context))`，再构造 `new HarmonyIncomingShareReceiver(store)`。
- onCreate/onNewWant 的系统分享 Want 调 `receiver.receive(want)`；其他 Want 不处理。先初始化
  inbox 再对外显示预览。异常提示接收失败，保留既有草稿，不自行授权更多 URI 或广泛文件权限。
- Auth ready 后调用 `await store.setOwner(ownerKey)`；未登录传空，账号切换/登出同样调用，
  已归属旧账号的未领取内容删除；空账号收到的内容可由首次登录领取。不要为普通重绘重复设置账号。
- 订阅 onChanged 并以替换引用方式读取 pending()；退出页面解除监听，服务销毁 dispose。
- 前台/新接收前调用 expire()：只清 inbox 中超过24小时未领取的文件，不扫描/删除其他草稿。

## 预览及真实草稿端口

`incomingshareextension/IncomingSharePreview.ets` 是独立原生组件。传 pending batch、由当前
实际设备/任务列表生成的 IncomingShareTarget[]（含每台电脑的新任务及已有任务、真实deviceId/sessionId、
权限禁用态）、本地化labels，onConfirm(targetId)只做以下领取，不发消息。

`IncomingShareDestination` 包含 deviceId、sessionId（空表示新任务）及 Store 填入的 ownerKey。
`IncomingShareDraftPort.adopt(batchId,destination,text,files):Promise<boolean>` 必须：

1. 检查 destination.ownerKey 仍为当前账号、目标电脑/任务可编辑，原文件总数不超20。
2. 以 batchId **持久幂等**领取：把暂存文件复制/移到草稿自己的受控目录，将文字与附件顺序
   交给原 ComposerImageQueue/ComposerFileQueue 与草稿入口。返回 true 前要记录领取身份；
   中途失败保留 inbox，重试同batchId不能再次附加文字/附件。禁止直接使用 inbox 源URI作为长期草稿路径。
3. 返回true仅表示真实草稿已有独立副本；Store 持久化消费标记后才清理 inbox 原件。
   若消费标记保存失败，保留 inbox 以便按同batchId幂等恢复。原发送按钮才发消息。

Store只负责本地接收，不拥有远端消息ID、上传重试账本或原队列发送状态；公共接线不能用新建
任务或 send 代替 adopt。此端口已由同目录IncomingComposerDraftBridge及HarmonyIncomingComposer实现，详见COMPOSER-BRIDGE.md；Lead仅接两页薄read/compareAndSave和原队列enqueue/ack，不再实现独立adopter。公共接线与设备验证前仍不等于完整系统分享交付。

单个官方共享/群邀请链接可展示“打开邀请”，调用 store.openInvitation(batchId,open)；open(text,owner)
由共享/群模块的**真实官方邀请解析器及确认UI**提供，返回false不消费。不在此处猜邀请URL规则，
混合文件或多条内容不转邀请。不涉及扫码登录。

## 文件、重复回调与边界

- filesDir 私有原子替换账本 `incoming-share-inbox-v1.json`，最多8批、每批最多20项，单文件沿
  现有 MAX_ATTACHMENT_BYTES=30MiB，文本上限200000字。文件在 `incoming-share-files/<UUID>`；
  只读本次系统授予 file/datashare URI，复制后只保存受控副本。清理函数核对根目录及UUID，
  不能用来删除任意外部路径。现有backup_config禁止备份恢复，不扩展备份权限。
- 同一个Want对象的重回调复用receipt；不同Want但内容相同的并发/待处理批次通过SHA256指纹合并。
  已消费receipt最多保留128条。接收器不永久按内容去重，用户稍后明确重复分享同样内容仍可进入。
- 已核验SDK未给出跨进程/跨启动统一分享投递ID；消费后OS若构造全新Want再次投递完全相同内容，
  无法可靠区分“系统重投”与“用户新分享”。不能声称该极端分支已有exactly-once保证；若宿主获得
  真正稳定原生receipt，可直接receiveHarmonyShare(want,receiptId,store)强化该边界。
- 崩溃发生在文件复制后、账本保存前可能留孤立UUID文件。不能无依据扫描删除，因为草稿可能有
  尚未完成的转存；需设备验收确认并后续接受控引用清理，不冒充已覆盖该崩溃窗口。
- IncomingShare.test 覆盖5个入口行为，IncomingComposerDraftBridge.test另有10项持久领取行为。新建页已接真实doc/上传队列/明确发送所有权移交，TaskPage由Lead接；本轮CAS修复与新增测试待Lead串行复跑。

## 文案键（前缀incoming_share_，由Lead统一写五语言资源）

| labels属性 | 简中 | 繁中 | 英文 | 日文 | 韩文 |
|---|---|---|---|---|---|
| title | 分享到 Cindy | 分享到 Cindy | Share to Cindy | Cindy に共有 | Cindy로 공유 |
| target | 选择电脑和任务 | 選擇電腦與任務 | Choose computer and task | コンピュータとタスクを選択 | 컴퓨터 및 작업 선택 |
| confirm | 放入输入框 | 放入輸入框 | Add to composer | 入力欄に追加 | 입력창에 추가 |
| cancel | 取消 | 取消 | Cancel | キャンセル | 취소 |
| hint | 内容只会填入，点击发送后才会提交 | 內容只會填入，點擊傳送後才會提交 | Content is added to the draft. Tap Send when ready. | 内容を入力欄に追加します。送信ボタンで送信します。 | 초안에만 추가됩니다. 준비되면 전송을 누르세요. |
| openInvite | 打开邀请 | 開啟邀請 | Open invitation | 招待を開く | 초대 열기 |

## 待统一配置与验收

EntryAbility.skills 增加 sendData；官方要求 uris 穷举支持UTD，建议 general.text、general.hyperlink、
general.image、general.file 各maxFileSupported:20，最终以实际系统匹配验证（不新增全盘读权限）。
实际相册/文件管理/浏览器分享→冷启动/登录→预览→已有/新任务→草稿→显式发送，以及取消、
重复回调、30MiB边界、多文件、切账号、邀请码解析、Light/Dark/窄屏/展开均尚待Lead串行验收。
