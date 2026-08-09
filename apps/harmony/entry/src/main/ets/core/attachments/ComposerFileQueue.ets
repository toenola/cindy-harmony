/** 普通文件附件：DocumentViewPicker → 校验 → OSS 上传 → 可重试/回收。 */
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { promptAction } from '@kit.ArkUI';
import { AppServices } from '../AppServices';
import { RemoteSerializedAttachment } from './AttachmentModels';
import { deleteUpload, uploadDocument } from './AttachmentUpload';
import { parseAttachmentOssRef } from './AttachmentOssRef';

export const MAX_COMPOSER_ATTACHMENTS = 20;

export class ComposerFile {
  uri: string = '';
  name: string = '';
  size: number = 0;
  status: string = 'uploading';
  errorText: string = '';
  ref: RemoteSerializedAttachment | null = null;
  removed: boolean = false;
}

export class ComposerFileQueue {
  files: ComposerFile[] = [];
  picking: boolean = false;
  onChanged: (files: ComposerFile[]) => void = () => {};
  onPickingChanged: (picking: boolean) => void = () => {};
  isBusy: () => boolean = () => false;
  /** 图片与文件共用每条消息 20 个的上限。 */
  occupiedByOtherAttachments: () => number = () => 0;

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
    this.picking = true;
    this.onPickingChanged(true);
    setTimeout(() => {
      const documentPicker = new picker.DocumentViewPicker(context);
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = remaining;
      options.selectMode = picker.DocumentSelectMode.FILE;
      documentPicker.select(options).then((uris: string[]) => {
        this.picking = false;
        this.onPickingChanged(false);
        this.enqueue(uris);
      }).catch(() => {
        this.picking = false;
        this.onPickingChanged(false);
      });
    }, 160);
  }

  enqueue(uris: string[]): void {
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
    this.emit();
    AppServices.instance.auth.getAccessToken().then((token: string | null) => {
      if (token === null || token.length === 0) throw new Error('未登录');
      return uploadDocument(uri, file.name, token);
    }).then((attachment: RemoteSerializedAttachment) => {
      file.ref = attachment;
      file.size = attachment.size;
      if (file.removed) {
        this.recycle(file);
        return;
      }
      file.status = 'ready';
      this.emit();
    }).catch((e: Error) => {
      if (file.removed) return;
      file.status = 'failed';
      file.errorText = e.message;
      this.emit();
    });
  }

  remove(file: ComposerFile): void {
    if (this.isBusy()) return;
    file.removed = true;
    this.files = this.files.filter((item: ComposerFile) => item !== file);
    this.emit();
    this.recycle(file);
  }

  retry(file: ComposerFile): void {
    if (this.isBusy()) return;
    file.removed = true;
    this.files = this.files.filter((item: ComposerFile) => item !== file);
    this.upload(file.uri);
  }

  removeSent(sent: ComposerFile[]): void {
    this.files = this.files.filter((item: ComposerFile) => sent.indexOf(item) < 0);
    this.emit();
  }

  private recycle(file: ComposerFile): void {
    if (file.ref === null) return;
    const parsed = parseAttachmentOssRef(file.ref.path);
    if (parsed === null || parsed.ossKey.length === 0) return;
    void AppServices.instance.auth.getAccessToken().then((token: string | null) => {
      if (token !== null && token.length > 0) return deleteUpload(parsed.ossKey, token);
      return Promise.resolve();
    }).catch(() => {});
  }
}
