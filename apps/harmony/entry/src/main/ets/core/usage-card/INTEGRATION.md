# 用量桌面服务卡片接线

## 真正的平台实现与证据

已用本机devecocli docs搜索/读取FormExtensionAbility、formInfo、ArkTS卡片配置及进程模型，
并逐项读API26已安装SDK声明。使用 `@kit.FormKit` 的 FormExtensionAbility、
formBindingData.createFormBindingData、formProvider.updateForm；FormParam.IDENTITY_KEY / DIMENSION_KEY
读取实际formId/规格；onSizeChanged处理规格变化；onRemoveForm清实例。

`usageformextension/UsageCard.ets` 是真实ArkTS卡片，不是普通App组件截图：
LocalStorageProp接收更新数据，2*2显示一项订阅余额，2*4并排两项；额度、重置说明、今日token与
实际费用、更新时间/过期提示来自本账号电脑的真实UsageSnapshot。点击用postCardAction(router)
打开EntryAbility，参数只含usageCardId；不含账号token、供应商凭证或任意文件路径。

## Lead公共接线

1. AppServices拿context后 `createHarmonyUsageCardStore(context)`，认证初始化/切账号/登出调用
   `await cards.setOwner(ownerKey,authGeneration)`。generation是**认证代次**；同owner仅换generation更新请求fence并保留电脑范围及可过期快照，只有owner变化/显式logout清scope。不要把每次普通重连当
   切账号来清卡片。已有物理卡片保留，其旧账号缓存与设备选择会清除，不能展示前账号额度。
2. 原用量读取成功时，调用 `cards.sync(ownerKey,generation,result.snapshot,result.deviceId,result.deviceName)`。
   不新增厂商调用。前台可复用原readUsageDashboard，按card对应范围读取，失败保留已有快照/年龄；
   后台FormExtension只发布缓存，无常驻socket，也不偷偷启动AppServices连接。
3. 卡片点击/配置打开Want携带的usageCardId或formInfo.FormParam.IDENTITY_KEY只作为formId。
   `cards.target(formId,currentOwner)` 返回null则无有效授权实例；空串表示自动范围，非空为指定电脑。
   打开现有用量详情并保持右栏/单栏语义，不能把untrusted Want里的deviceId直接当授权来源。
4. 对该卡片的用量范围选择更改后 `cards.configure(formId,deviceId)`；每张卡片各自存scope。
   可复用现有用量页设备范围选择器。设备被移除/撤权调用invalidateDevice(deviceId)清其投影，
   暂时离线不要调用此方法：离线应继续显示上次数据和过期提示。
5. form_config.json配置交给Lead统一注册：把独立目录
   `usageformextension/form_config.json` 复制为 `resources/base/profile/usage_form_config.json`。
   module.extensionAbilities增加name=UsageFormExtensionAbility、srcEntry=
   `./ets/usageformextension/UsageFormExtensionAbility.ets`、type=form、
   metadata=[{name:"ohos.extension.form",resource:"$profile:usage_form_config"}]。
   配置的formConfigAbility复用EntryAbility。未修改签名、EntryAbility或module.json5。

## 存储和刷新

- `HarmonyUsageCardStorage`只写filesDir/usage-cards-v1.json，通过临时文件+fsync+rename原子替换。
  卡片提供方运行在应用进程，读改写为同步无await窗口；每次读取磁盘当前owner，不用旧单例缓存。
  Ledger最多64实例/64电脑的脱敏投影；不保存UsageSnapshot原始任意字段，不存鉴权或模型调用材料。
- Store.sync必须匹配owner+认证generation。切账号先同步清文件中的旧快照，再按进程共享队列发布
  空内容，防止老快照在logout后最后回写。服务卡片不创建HTTP、厂商请求或后台WS。
- updateEnabled=true/updateDuration=1使用系统卡片刷新预算（单位30分钟），回调仅重发当前缓存并
  重新判断15分钟数据年龄；不承诺系统实时刷新。App前台成功取得快照时立即updateForm。
- publishAll逐个隔离formProvider.updateForm失败，不因一张被删卡阻止其他卡刷新；failedPublications()给出本Store待重试form。只捕获发布失败，ledger读写失败继续抛出供调用方报告，不吞清owner落盘错误。
- onRemoveForm只清该form引用；其电脑快照可供其他form复用。实际登出会清全部缓存。当前工程
  backup_config.allowToBackupRestore=false，无新增跨设备备份或账号迁移。
- 静态字符串复用既有五语言usage_*资源。signed-out/unavailable均显示既有usage_unavailable，
  点击进入App现有登录流程；如需更直接“请登录”说明，由Lead新增usage_card_sign_in资源并换此分支。

## 验证与具体未完成项

manifest/profile、EntryAbility Want、AppServices owner与sync、UsageDashboard快照sync已由Lead接入。
同owner generation换代保留配置与快照，旧generation sync拒绝；publishAll每张卡片故障隔离、
failedPublications可重试，ledger读写失败仍报告。这两项已补真实Store用例。

独立UsageCard.test.ets含9个真实Store行为用例（快照投影、多实例scope、重启、logout/迟到sync、
系统缓存过期、移除、撤权、在途发布logout顺序），默认导出usageCardTests，Lead注册。与IncomingShare
的5项加IncomingComposerDraftBridge的10项，合计24项F单测。按分工Worker未启动单测、Hvigor、语法检查、安装或真实Launcher操作。

本模块已有真实FormExtension和动态数据视图，仍**不能标记完整交付**：Lead需核对卡片范围更改接线，
串行编译并从桌面真实添加2*2/2*4、改变电脑范围、
刷新、点击跳转、删卡、断网、登出、重启、Light/Dark、大字体和折叠状态验证。卡片自定义App
资源与Progress等实际系统渲染能力仍以该设备验收为准，不能以源码替代。
