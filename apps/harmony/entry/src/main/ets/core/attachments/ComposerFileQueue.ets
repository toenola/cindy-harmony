/** 普通文件附件：DocumentViewPicker → 校验 → OSS 上传 → 可重试/回收。 */
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { promptAction } from '@kit.ArkUI';
import { AppServices } from '../AppServices';
import {
  RemoteSerializedAttachment,
  createComposerAttachmentLocalId,
} from './AttachmentModels';
import { deleteUpload, uploadDocument, isUploadRevisionCurrent } from './AttachmentUpload';
import { parseAttachmentOssRef } from './AttachmentOssRef';

export const MAX_COMPOSER_ATTACHMENTS = 20;

export class ComposerFile {
  /** 跨 @Prop 深拷贝仍可定位父页面真实条目的本地 ID。 */
  localId: string = createComposerAttachmentLocalId();
  uri: string = '';
  name: string = '';
  size: number = 0;
  status: string = 'uploading';
  errorText: string = '';
  ref: RemoteSerializedAttachment | null = null;
  removed: boolean = false;
  uploadRevision: number = 0;
}

export class ComposerFileQueue {
  files: ComposerFile[] = [];
  picking: boolean = false;
  onChanged: (files: ComposerFile[]) => void = () => {};
  onPickingChanged: (picking: boolean) => void = () => {};
  isBusy: () => boolean = () => false;
  /** 图片与文件共用每条消息 20 个的上限。 */
  occupiedByOtherAttachments: () => number = () => 0;

  /** 页面退场时使系统文件选择器的迟到回包失效；不能依赖系统 picker 可取消。 */
  private pickerGeneration: number = 0;

  private emit(): void { this.onChanged(this.files.slice()); }

  remainingSlots(): number {
    return Math.max(0, MAX_COMPOSER_ATTACHMENTS
      - this.occupiedByOtherAttachments() - this.files.length);
  }

  readyFiles(): RemoteSerializedAttachment[] {
    const out: RemoteSerializedAttachment[] = [];
    for (let i = 0; i < this.files.length; i++) {
      const ref = this.files[i].ref;
      if (this.files[i].status === 'ready' && ref !== null) out.push(ref);
    }
    return out;
  }

  /** 创建失败时把已上传文件引用放回托盘；图片数量会通过共享容量回调计入上限。 */
  restoreReady(refs: RemoteSerializedAttachment[]): number {
    if (refs.length === 0) return 0;
    const next = this.files.slice();
    let remaining = this.remainingSlots();
    let restored = 0;
    for (let i = 0; i < refs.length; i++) {
      const ref = refs[i];
      const duplicate = next.some((item: ComposerFile) => item.ref !== null && (
        (ref.id.length > 0 && item.ref?.id === ref.id)
        || (ref.sha256.length > 0 && item.ref?.sha256 === ref.sha256)
        || (ref.path.length > 0 && item.ref?.path === ref.path)
      ));
      if (duplicate) {
        restored += 1;
        continue;
      }
      if (remaining <= 0) continue;
      const file = new ComposerFile();
      file.uri = ref.path;
      file.name = ref.name.length > 0 ? ref.name : `attachment-${next.length + 1}`;
      file.size = ref.size;
      file.status = 'ready';
      file.ref = ref;
      next.push(file);
      remaining -= 1;
      restored += 1;
    }
    this.files = next;
    this.emit();
    return restored;
  }

  allSettled(): boolean {
    for (let i = 0; i < this.files.length; i++) {
      if (this.files[i].status !== 'ready' || this.files[i].ref === null) return false;
    }
    return true;
  }

  hasUploading(): boolean {
    return this.files.some((item: ComposerFile) => item.status === 'uploading');
  }

  hasFailed(): boolean {
    return this.files.some((item: ComposerFile) => item.status === 'failed');
  }

  pick(context: common.UIAbilityContext): void {
    if (this.picking || this.isBusy()) return;
    const remaining = this.remainingSlots();
    if (remaining <= 0) {
      promptAction.showToast({ message: `每条消息最多添加 ${MAX_COMPOSER_ATTACHMENTS} 个附件` });
      return;
    }
    const generation = ++this.pickerGeneration;
    this.picking = true;
    this.onPickingChanged(true);
    setTimeout(() => {
      if (generation !== this.pickerGeneration || this.isBusy()) {
        if (generation === this.pickerGeneration) {
          this.picking = false;
          this.onPickingChanged(false);
        }
        return;
      }
      const documentPicker = new picker.DocumentViewPicker(context);
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = remaining;
      options.selectMode = picker.DocumentSelectMode.FILE;
      documentPicker.select(options).then((uris: string[]) => {
        if (generation !== this.pickerGeneration) return;
        this.picking = false;
        this.onPickingChanged(false);
        if (!this.isBusy()) this.enqueue(uris);
      }).catch(() => {
        if (generation !== this.pickerGeneration) return;
        this.picking = false;
        this.onPickingChanged(false);
      });
    }, 160);
  }

  cancelPicking(): void {
    this.pickerGeneration += 1;
    if (!this.picking) return;
    this.picking = false;
    this.onPickingChanged(false);
  }

  enqueue(uris: string[]): void {
    if (this.isBusy()) return;
    const max = this.remainingSlots();
    let accepted = 0;
    for (let i = 0; i < uris.length && accepted < max; i++) {
      const uri = uris[i];
      if (this.files.some((item: ComposerFile) => item.uri === uri)) continue;
      this.upload(uri);
      accepted += 1;
    }
    if (uris.length > accepted && accepted >= max) {
      promptAction.showToast({ message: `每条消息最多添加 ${MAX_COMPOSER_ATTACHMENTS} 个附件` });
    }
  }

  private fileName(uri: string): string {
    const slash = uri.lastIndexOf('/');
    const raw = slash >= 0 ? uri.slice(slash + 1) : uri;
    try { return decodeURIComponent(raw) || 'attachment'; } catch (e) { return raw || 'attachment'; }
  }

  private upload(uri: string): void {
    const file = new ComposerFile();
    file.uri = uri;
    file.name = this.fileName(uri);
    this.files = this.files.concat([file]);
    this.startUpload(file);
  }

  private isCurrentUpload(file: ComposerFile, revision: number): boolean {
    return isUploadRevisionCurrent(
      file.uploadRevision, revision, file.removed, this.files.indexOf(file) >= 0);
  }

  private startUpload(file: ComposerFile): void {
    file.removed = false;
    file.status = 'uploading';
    file.errorText = '';
    file.ref = null;
    file.uploadRevision += 1;
    const revision = file.uploadRevision;
    this.emit();
    AppServices.instance.auth.getAccessToken().then((token: string | null) => {
      if (!this.isCurrentUpload(file, revision)) throw new Error('stale file upload');
      if (token === null || token.length === 0) throw new Error('未登录');
      return uploadDocument(file.uri, file.name, token);
    }).then((attachment: RemoteSerializedAttachment) => {
      if (!this.isCurrentUpload(file, revision)) {
        this.recycleAttachment(attachment);
        return;
      }
      file.ref = attachment;
      file.size = attachment.size;
      file.status = 'ready';
      this.emit();
    }).catch((e: Error) => {
      if (!this.isCurrentUpload(file, revision)) return;
      file.status = 'failed';
      file.errorText = e.message;
      this.emit();
    });
  }

  remove(localId: string): void {
    if (this.isBusy()) return;
    const index = this.files.findIndex((item: ComposerFile) => item.localId === localId);
    if (index < 0) return;
    const file = this.files[index];
    file.uploadRevision += 1;
    file.removed = true;
    this.files = this.files.filter((item: ComposerFile) => item.localId !== localId);
    this.emit();
    this.recycle(file);
  }

  retry(localId: string): void {
    if (this.isBusy()) return;
    const file = this.files.find((item: ComposerFile) => item.localId === localId);
    if (file === undefined || file.removed || file.status !== 'failed') return;
    this.startUpload(file);
  }

  /**
   * 从发送成功的文件 ID 集合中移除已发送项。
   *
   * 附件会经过 @Prop 镜像和异步上传，不能用对象引用判断“这一批”是否仍在
   * 队列中；父页面传回稳定 localId 后再由队列定位真实对象。
   */
  removeSent(sentLocalIds: string[]): void {
    const sent = new Set<string>();
    for (let i = 0; i < sentLocalIds.length; i++) {
      if (sentLocalIds[i].length > 0) sent.add(sentLocalIds[i]);
    }
    const remaining: ComposerFile[] = [];
    for (let i = 0; i < this.files.length; i++) {
      if (!sent.has(this.files[i].localId)) {
        remaining.push(this.files[i]);
      } else {
        this.files[i].removed = true;
        this.files[i].uploadRevision += 1;
      }
    }
    this.files = remaining;
    this.emit();
  }

  private recycle(file: ComposerFile): void {
    if (file.ref !== null) this.recycleAttachment(file.ref);
  }

  private recycleAttachment(ref: RemoteSerializedAttachment): void {
    const parsed = parseAttachmentOssRef(ref.path);
    if (parsed === null || parsed.ossKey.length === 0) return;
    void AppServices.instance.auth.getAccessToken().then((token: string | null) => {
      if (token !== null && token.length > 0) return deleteUpload(parsed.ossKey, token);
      return Promise.resolve();
    }).catch(() => {});
  }
}
