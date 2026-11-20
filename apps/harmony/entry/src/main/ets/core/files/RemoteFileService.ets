/** 远端生成文件的本机临时落盘与系统分享。 */

import { common, wantConstant } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { systemShare } from '@kit.ShareKit';
import { HarmonyHttp } from '../../network/HarmonyHttp';

function safeFileName(value: string): string {
  const normalized = value.replace(/\\/g, '/');
  const slash = normalized.lastIndexOf('/');
  const base = (slash >= 0 ? normalized.slice(slash + 1) : normalized).trim();
  const safe = base.replace(/[^A-Za-z0-9._()\-\u4e00-\u9fff]/g, '_');
  return safe.length > 0 ? safe.slice(0, 120) : 'Cindy-File';
}

export class RemoteFileService {
  private controller: systemShare.ShareController | undefined = undefined;
  private paths: string[] = [];

  /** 下载到应用缓存后交给系统阅读器；切走页面时保留文件，避免阅读器尚未读取就被清理。 */
  async openPdfUrl(context: common.UIAbilityContext, url: string, name: string): Promise<void> {
    const bytes = await new HarmonyHttp().downloadBytes(url);
    if (bytes.byteLength === 0) throw new Error('PDF 文件为空');
    const base = safeFileName(name);
    const path = `${context.cacheDir}/cindy-pdf-${Date.now()}-${base.toLowerCase().endsWith('.pdf') ? base : base + '.pdf'}`;
    const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try { fileIo.writeSync(file.fd, bytes); } finally { fileIo.closeSync(file); }
    await context.startAbility({
      action: 'ohos.want.action.viewData',
      uri: fileUri.getUriFromPath(path),
      type: 'com.adobe.pdf',
      flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION,
    });
  }

  async shareUrl(context: common.UIAbilityContext, url: string, name: string): Promise<void> {
    const bytes = await new HarmonyHttp().downloadBytes(url);
    const path = `${context.cacheDir}/cindy-file-${Date.now()}-${safeFileName(name)}`;
    const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
    try {
      fileIo.writeSync(file.fd, bytes);
    } catch (e) {
      try {
        fileIo.closeSync(file);
      } catch (_) {
      }
      try {
        fileIo.unlinkSync(path);
      } catch (_) {
      }
      throw (e instanceof Error ? e : new Error('write-share-file-failed'));
    }
    fileIo.closeSync(file);
    this.paths.push(path);

    const data = new systemShare.SharedData({
      utd: uniformTypeDescriptor.UniformDataType.FILE,
      uri: fileUri.getUriFromPath(path),
      title: safeFileName(name),
    });
    const controller = new systemShare.ShareController(data);
    this.controller = controller;
    const settle = (): void => this.release();
    controller.on('shareCompleted', settle);
    controller.on('dismiss', settle);
    try {
      await controller.show(context, {
        previewMode: systemShare.SharePreviewMode.DETAIL,
        selectionMode: systemShare.SelectionMode.SINGLE,
      });
    } catch (e) {
      this.release();
      throw (e instanceof Error ? e : new Error('share-panel-failed'));
    }
  }

  release(): void {
    if (this.controller !== undefined) {
      this.controller = undefined;
    }
    const paths = this.paths;
    this.paths = [];
    for (let i = 0; i < paths.length; i++) {
      try {
        fileIo.unlinkSync(paths[i]);
      } catch (_) {
      }
    }
  }
}
