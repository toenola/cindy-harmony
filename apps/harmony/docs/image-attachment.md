# 图片附件

> 状态：一期必须实现

## 1. 目标

用户可以在 Harmony 任务对话中选择图片并发送给桌面 Cindy / Agent；图片发送后可以在历史消息中恢复、预览和再次打开。

## 2. 端到端流程

```text
Harmony 图片选择或拍照
        ↓
本地 URI 读取
        ↓
尺寸处理和压缩
        ↓
附件元数据 / 摘要
        ↓
上传到现有附件服务
        ↓
生成远程附件引用
        ↓
发送消息
        ↓
桌面 Cindy 获取附件
        ↓
任务消息显示图片
```

## 3. 必须支持

- 相册图片选择。
- 多图选择。
- 图片 URI 读取。
- 图片格式、尺寸和大小检查。
- 图片压缩。
- 上传进度。
- 上传失败提示和重试。
- 发送中的附件状态。
- 消息发送失败状态。
- 发送后历史消息恢复。
- 缩略图。
- 全屏预览。
- 远程媒体获取失败提示。

相机拍照是否纳入首个可运行版本，需要根据 Harmony 权限和图片 URI 能力单独确认；图片选择链路不能等待相机能力。

## 4. 不变量

- 上传成功但消息发送失败时，不能重复上传或产生重复消息。
- App 前后台切换不能把上传中的附件错误标记为已发送。
- 重连后不能重复提交同一附件引用。
- 本地缓存不能成为远端历史图片的唯一来源。
- 历史中的图片、视频、音频和文件引用不能被归一化逻辑静默删除。

## 5. 参考实现

- `apps/mobile/src/session/mobileImageAttachment.ts`
- `apps/mobile/src/session/mobileImagePreprocess.ts`
- `apps/mobile/src/session/mobileAttachmentUpload.ts`
- `apps/mobile/src/session/messageAttachments.ts`
- `packages/device-link/src/attachmentOssRef.ts`
- `docs/dev-rules/media-storage-and-protocols.md`

## 6. 暂不支持

- 视频上传。
- 音频上传。
- 文件夹上传。
- 远程文件编辑。

不支持上传不等于不支持展示。历史数据模型和消息 renderer 仍然需要识别这些引用。
