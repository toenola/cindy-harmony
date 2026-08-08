/**
 * 附件模型（对齐 mobile RemoteSerializedAttachment / RemoteImageRef）。
 *
 * 字段名契约与桌面端保持一致：image 引用必须用 `originalName`
 * （桌面 isValidImageRef 按 desktop ImageRef schema 校验，`name` 会被静默过滤）。
 */

/** 发送时随消息携带的图片引用（chatMessage.images）。 */
export class RemoteImageRef {
  url: string = '';
  /** 兼容历史 content.images 的 inline base64 形态。 */
  base64: string = '';
  originalName: string = '';
  name: string = '';
  mimeType: string = '';
  size: number = 0;
  sha256: string = '';
}

/** 上传完成后的附件（本地侧描述）。 */
export class RemoteSerializedAttachment {
  id: string = '';
  name: string = '';
  /** OSS 引用串（cindy-oss-attach://…）。 */
  path: string = '';
  ext: string = '';
  size: number = 0;
  sha256: string = '';
  category: string = ''; // 'image' | 'pdf' | 'text' | 'office'
  mimeType: string = '';
  url: string = '';
  originalName: string = '';
}

/** presign 响应。 */
export class AttachmentPresignResult {
  putUrl: string = '';
  key: string = '';
  expiresAt: string = '';
}

/**
 * Device Link 媒体取件响应（对齐 MobileRemoteMediaFetchResult）。
 *
 * 新版 Desktop 请求缩略图时可能直接回 inlineBase64；旧版和原图路径则
 * 回 ossKey，二者都必须由控制端兼容。
 */
export class RemoteMediaFetchResult {
  ossKey: string = '';
  mimeType: string = '';
  size: number = 0;
  inlineBase64: string = '';
}

/** 选图后的候选（对齐 MobileImageAttachmentCandidate）。 */
export class ImageAttachmentCandidate {
  uri: string = '';
  name: string = '';
  size: number = 0;
  mimeType: string = '';
  width: number = 0;
  height: number = 0;
}

/** 最大附件字节数（对齐 MOBILE_MAX_ATTACHMENT_BYTES，30MB）。 */
export const MAX_ATTACHMENT_BYTES = 30 * 1024 * 1024;

export function isImageCategory(category: string): boolean {
  return category === 'image';
}
