# 图片与附件

本文说明选择、预处理、上传、发送和历史恢复；修改输入托盘或附件链路前阅读。页面与新建任务共用 `ComposerImageQueue.ets` / `ComposerFileQueue.ets`，不要在页面再造上传状态机。

## 生产链路

`ImagePicker.ets`（相册 / 截图 / 拍照、URI 与字节）→ `ImagePreprocess.ets` → `AttachmentUpload.ets`（presign / 上传）→ 队列 ready 引用 → 发送 → `MessagePayload.ets` / `RemoteMediaState.ets` 历史解析与预览。

- 图片托盘上限 20，`occupiedByOtherAttachments` 计入剩余名额；内嵌最近照片选择器不直接拍照，独立拍照入口走 `takePhotoUri`。
- GIF 原样保动画；PNG / WebP 仅长边超过 2048 时缩尺寸并输出 PNG 保透明；其他图长边超过 2048 或大于 400 KiB 才处理，JPEG 质量 80。
- 处理失败或产物更大回退原图；产物在内存，文件名扩展名 / MIME 随实际编码更新。
- 队列管理选择中、uploading / ready / failed、进度、重试与回收；页面只通过回调更新 `@State` 镜像。离页使 picker 迟到回包失效，不假设系统选择器可取消。
- `AttachmentOssRef.ets` 同时识别 `cindy-oss-attach` 与旧 `xdt-oss-attach`。

## 不变量

- 上传完成但消息失败时复用已上传引用，不能重复上传或发送；新任务首条入队失败恢复 ready 托盘。
- 前后台切换不将上传中误判为已发送；重连先对账，不重复交付。
- 上传 revision、账号、设备、中转范围隔离旧响应；中转切换后不得沿用新凭证重试旧地址，详见[中转专题](self-hosted-relay-plan.md)。
- `LocalAttachmentPreviews.ets` 只交接短期内存 URI，不接管文件删除；托盘 / 上传层负责自身资源回收。
- 本地缓存不是远端历史图片的唯一来源；历史归一化不得丢弃图片、视频、音频或文件引用。
- 媒体获取和解码失败要可见且可重试；缩略图与全屏预览关闭后保持原消息位置。

## 范围与验证

已有文件选择 / 上传队列，不能再宣称“仅图片附件”。视频 / 音频、文件夹上传和远程文件编辑不由本专题承诺；不支持某类上传不等于可删除历史引用。
覆盖多选、拍照取消、格式 / 尺寸 / 大小、重编码命名、失败重试、发送失败恢复、前后台、旧代次、历史重新打开及远程媒体失败。

Mobile 行为源：`mobileImageAttachment.ts`、`mobileImagePreprocess.ts`、`mobileAttachmentUpload.ts`、`messageAttachments.ts`（位于 `apps/mobile/src/session/`）；引用契约见 `packages/device-link/src/attachmentOssRef.ts`。涉及媒体落盘或协议时同时读仓库[媒体规则](../../../docs/dev-rules/media-storage-and-protocols.md)。
