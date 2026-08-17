/**
 * Composer 图片附件队列：选择（相册/截图/拍照）、上传、重试与回收。
 *
 * 任务详情页与新建任务页共用同一套图片流转；页面只持有 @State 镜像并响应
 * onChanged 回调，上传状态机与中转 OSS 对象回收集中在这里维护。
 */

import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import {
  photoAccessHelper, PickerOptions, SelectMode, PickerOrientation, SingleLineConfig,
} from '@kit.MediaLibraryKit';
import { AppServices } from '../AppServices';
import { pickImageUris, pickScreenshotUris, takePhotoUri, buildImageCandidate } from './ImagePicker';
import { uploadImage, deleteUpload, presignGet, isUploadRevisionCurrent } from './AttachmentUpload';
import { RemoteImageRef } from './AttachmentModels';
import { parseAttachmentOssRef } from './AttachmentOssRef';
import { ComposerImage } from '../../components/ConversationComposer';

export const MAX_COMPOSER_IMAGES = 20;

/** 上下文 Sheet 内嵌的最近照片选择器配置（两页一致）。 */
export function createRecentPickerOptions(): PickerOptions {
  const options = new PickerOptions();
  options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
  options.maxSelectNumber = MAX_COMPOSER_IMAGES;
  options.maxPhotoSelectNumber = MAX_COMPOSER_IMAGES;
  options.selectMode = SelectMode.MULTI_SELECT;
  options.orientation = PickerOrientation.HORIZONTAL;
  options.isPhotoTakingSupported = false;
  const singleLine = new SingleLineConfig();
  singleLine.itemBorderRadius = 6;
  singleLine.itemGap = 6;
  options.singleLineConfig = singleLine;
  return options;
}

export class ComposerImageQueue {
  /** 页面 @State 镜像同步：images 变化时回调（切片触发刷新）。 */
  onChanged: (images: ComposerImage[]) => void = () => {};
  /** 选图 busy 状态变化回调（Sheet/按钮禁用联动）。 */
  onPickingChanged: (picking: boolean) => void = () => {};
  /** 页面级忙碌判定（发送中/创建中），忙碌时禁止增删图片。 */
  isBusy: () => boolean = () => false;
  occupiedByOtherAttachments: () => number = () => 0;

  images: ComposerImage[] = [];
  picking: boolean = false;

  private setPicking(picking: boolean): void {
    this.picking = picking;
    this.onPickingChanged(picking);
  }

  private emit(): void {
    this.onChanged(this.images.slice());
  }

  remainingSlots(): number {
    return Math.max(0, MAX_COMPOSER_IMAGES - this.occupiedByOtherAttachments() - this.images.length);
  }

  readyImages(): RemoteImageRef[] {
    const ready: RemoteImageRef[] = [];
    for (let i = 0; i < this.images.length; i++) {
      const image = this.images[i];
      if (image.status === 'ready' && image.ref !== null) ready.push(image.ref);
    }
    return ready;
  }

  /** 新任务首条 enqueue 确认失败时，把已上传引用原样放回详情页托盘。 */
  restoreReady(refs: RemoteImageRef[]): number {
    if (refs.length === 0) return 0;
    const next = this.images.slice();
    let remaining = this.remainingSlots();
    let restored = 0;
    for (let i = 0; i < refs.length; i++) {
      const ref = refs[i];
      let duplicate = false;
      for (let j = 0; j < next.length; j++) {
        const existing = next[j].ref;
        if (existing !== null && (
          (ref.url.length > 0 && existing.url === ref.url)
          || (ref.sha256.length > 0 && existing.sha256 === ref.sha256)
          || (ref.url.length === 0 && ref.sha256.length === 0 && ref.base64.length > 0
            && existing.base64 === ref.base64)
        )) {
          duplicate = true;
          break;
        }
      }
      if (duplicate) {
        restored += 1;
        continue;
      }
      if (remaining <= 0) continue;
      const image = new ComposerImage();
      image.uri = ref.base64.length > 0
        ? `data:${ref.mimeType.length > 0 ? ref.mimeType : 'image/png'};base64,${ref.base64}`
        : ref.url;
      image.name = ref.originalName.length > 0 ? ref.originalName : `image-${next.length + 1}`;
      image.status = 'ready';
      image.ref = ref;
      next.push(image);
      remaining -= 1;
      restored += 1;
      this.resolveRestoredPreview(image);
    }
    this.images = next;
    this.emit();
    return restored;
  }

  private resolveRestoredPreview(image: ComposerImage): void {
    if (image.ref === null || image.ref.base64.length > 0) return;
    const parsed = parseAttachmentOssRef(image.ref.url);
    if (parsed === null || parsed.ossKey.length === 0) return;
    void AppServices.instance.auth.getAccessToken().then((token: string | null) => {
      if (token === null || token.length === 0) return Promise.reject(new Error('未登录'));
      return presignGet(parsed.ossKey, token);
    }).then((url: string) => {
      if (image.removed || this.images.indexOf(image) < 0) return;
      image.uri = url;
      this.emit();
    }).catch(() => {
      // 预览失败不影响已上传引用再次发送；托盘仍保留附件名和删除入口。
    });
  }

  /** 有任一图片不在 ready 态时不可发送（上传中或失败）。 */
  allSettled(): boolean {
    for (let i = 0; i < this.images.length; i++) {
      if (this.images[i].status !== 'ready' || this.images[i].ref === null) return false;
    }
    return true;
  }

  hasUploading(): boolean {
    for (let i = 0; i < this.images.length; i++) {
      if (this.images[i].status === 'uploading') return true;
    }
    return false;
  }

  hasFailed(): boolean {
    for (let i = 0; i < this.images.length; i++) {
      if (this.images[i].status === 'failed') return true;
    }
    return false;
  }

  /** 从发送成功的图片集合中移除已发送项（详情页保留后续新增的图片）。 */
  removeSent(sent: ComposerImage[]): void {
    const remaining: ComposerImage[] = [];
    for (let i = 0; i < this.images.length; i++) {
      if (sent.indexOf(this.images[i]) < 0) {
        remaining.push(this.images[i]);
      } else {
        this.images[i].removed = true;
        this.images[i].uploadRevision += 1;
      }
    }
    this.images = remaining;
    this.emit();
  }

  pickImages(): void {
    if (this.picking || this.isBusy()) return;
    const remaining = this.remainingSlots();
    if (remaining <= 0) {
      promptAction.showToast({ message: `最多添加 ${MAX_COMPOSER_IMAGES} 张图片` });
      return;
    }
    this.setPicking(true);
    setTimeout(() => {
      pickImageUris(remaining).then((uris: string[]) => {
        this.setPicking(false);
        this.enqueue(uris);
      }).catch(() => {
        this.setPicking(false);
      });
    }, 160);
  }

  pickScreenshots(context: common.UIAbilityContext): void {
    if (this.picking || this.isBusy()) return;
    const remaining = this.remainingSlots();
    if (remaining <= 0) {
      promptAction.showToast({ message: `最多添加 ${MAX_COMPOSER_IMAGES} 张图片` });
      return;
    }
    this.setPicking(true);
    setTimeout(() => {
      pickScreenshotUris(context, remaining).then((uris: string[]) => {
        this.setPicking(false);
        this.enqueue(uris);
      }).catch(() => {
        this.setPicking(false);
        promptAction.showToast({ message: '无法打开截图选择器' });
      });
    }, 160);
  }

  takePhoto(context: common.UIAbilityContext): void {
    if (this.picking || this.isBusy() || this.remainingSlots() <= 0) {
      if (this.remainingSlots() <= 0) {
        promptAction.showToast({ message: `最多添加 ${MAX_COMPOSER_IMAGES} 张图片` });
      }
      return;
    }
    this.setPicking(true);
    setTimeout(() => {
      takePhotoUri(context).then((uri: string) => {
        this.setPicking(false);
        if (uri.length > 0) this.enqueue([uri]);
      }).catch(() => {
        this.setPicking(false);
        promptAction.showToast({ message: '无法打开相机' });
      });
    }, 160);
  }

  enqueue(uris: string[]): void {
    let remaining = this.remainingSlots();
    let accepted = 0;
    for (let i = 0; i < uris.length && remaining > 0; i++) {
      const uri = uris[i];
      let duplicate = false;
      for (let j = 0; j < this.images.length; j++) {
        if (this.images[j].uri === uri) {
          duplicate = true;
          break;
        }
      }
      if (duplicate) continue;
      this.upload(uri, this.images.length + accepted);
      accepted += 1;
      remaining -= 1;
    }
    if (uris.length > accepted && remaining <= 0) {
      promptAction.showToast({ message: `最多添加 ${MAX_COMPOSER_IMAGES} 张图片` });
    }
  }

  upload(uri: string, index: number): void {
    const image = new ComposerImage();
    image.uri = uri;
    image.name = `image-${index + 1}`;
    this.images = this.images.concat([image]);
    this.startUpload(image, index);
  }

  private isCurrentUpload(image: ComposerImage, revision: number): boolean {
    return isUploadRevisionCurrent(
      image.uploadRevision, revision, image.removed, this.images.indexOf(image) >= 0);
  }

  private startUpload(image: ComposerImage, index: number, preserveName: boolean = false): void {
    const previousName = preserveName ? image.name : '';
    image.removed = false;
    image.status = 'uploading';
    image.ref = null;
    image.uploadRevision += 1;
    const revision = image.uploadRevision;
    this.emit();
    buildImageCandidate(image.uri, index).then((candidate) => {
      if (!this.isCurrentUpload(image, revision)) throw new Error('stale image upload');
      if (previousName.length > 0) candidate.name = previousName;
      image.name = candidate.name;
      return AppServices.instance.auth.getAccessToken().then((token: string | null) => {
        if (!this.isCurrentUpload(image, revision)) throw new Error('stale image upload');
        if (token === null || token.length === 0) throw new Error('未登录');
        return uploadImage(candidate, token);
      });
    }).then((ref: RemoteImageRef) => {
      if (!this.isCurrentUpload(image, revision)) {
        this.recycleRef(ref);
        return;
      }
      image.ref = ref;
      if (ref.originalName.length > 0) image.name = ref.originalName;
      image.status = 'ready';
      this.emit();
    }).catch(() => {
      if (this.isCurrentUpload(image, revision)) {
        image.status = 'failed';
        this.emit();
      }
    });
  }

  remove(localId: string): void {
    if (this.isBusy()) return;
    const index = this.images.findIndex((item: ComposerImage) => item.localId === localId);
    if (index < 0) return;
    const image = this.images[index];
    image.uploadRevision += 1;
    image.removed = true;
    this.images = this.images.filter((item: ComposerImage) => item.localId !== localId);
    this.emit();
    this.recycle(image);
  }

  retry(localId: string): void {
    if (this.isBusy()) return;
    const index = this.images.findIndex((item: ComposerImage) => item.localId === localId);
    if (index < 0) return;
    const image = this.images[index];
    if (image.removed || image.status !== 'failed') return;
    // 同一对象原位重试，保持托盘顺序、文件名和 UI identity。
    this.startUpload(image, index, true);
  }

  /** 回收中转 OSS 对象（best-effort，不阻断 Composer 操作）。 */
  private recycle(image: ComposerImage): void {
    if (image.ref !== null) this.recycleRef(image.ref);
  }

  private recycleRef(ref: RemoteImageRef): void {
    const parsed = parseAttachmentOssRef(ref.url);
    if (parsed === null || parsed.ossKey.length === 0) return;
    void AppServices.instance.auth.getAccessToken().then((token: string | null) => {
      if (token !== null && token.length > 0) return deleteUpload(parsed.ossKey, token);
      return Promise.resolve();
    }).catch(() => {
      // 删除中转对象失败不影响本地状态。
    });
  }
}
