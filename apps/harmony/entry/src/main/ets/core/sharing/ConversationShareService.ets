/**
 * Harmony 原生会话分享服务。
 *
 * 用 ArkUI 原生能力生成图片并交给系统分享面板，**不照搬** Mobile 的
 * SVG + WebView 实现：
 * - 截图走 `UIContext.getComponentSnapshot().createFromBuilder`，`checkImageStatus`
 *   保证头像 / 附件图等资源加载完成后才出图（未就绪时由调用方的 builder 画占位）；
 * - 编码走 `image.createImagePacker().packToFile`，落在应用缓存目录；
 * - 分享走 Share Kit 的 `systemShare.ShareController`，通过 file URI 交接。
 *
 * 尺寸上限见 docs/version/v1.1.0/技术设计.md §6.3：受 GPU 纹理上限约束
 * （常见 8192×8192，超限报 100001）。分段与"是否必须让用户缩小范围"的判定
 * 全部由 ConversationShareProjection 的 planShareSegments 负责，本文件只执行。
 *
 * 所有失败、取消、页面销毁与退后台路径都汇聚到 `release()`，由
 * ShareResourceLifecycle 的账本保证幂等，不泄漏 PixelMap 与临时文件。
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import {
  planShareSegments,
  ShareSegmentPlan,
  shareImageFileName,
} from './ConversationShareProjection';
import {
  ShareFlowState,
  ShareResourceRelease,
  SHARE_STAGE_FAILED,
} from './ShareResourceLifecycle';

const DOMAIN = 0x0000;
const TAG = 'CindyShare';

/** PNG 编码质量；PNG 为无损格式，该值只影响编码器内部策略。 */
const SHARE_PNG_QUALITY = 100;
/** 留一帧给离屏节点树完成布局测量后再截图。 */
const SHARE_SNAPSHOT_DELAY_MS = 32;

/** 一次导出产生的图片文件。 */
export class ShareImageFile {
  path: string = '';
  uri: string = '';
}

/** 分享准备结果。 */
export class SharePreparation {
  files: ShareImageFile[] = [];
  /** true = 内容超出自动分图能力，UI 必须提示用户缩小范围。 */
  requiresNarrowing: boolean = false;
  /** 有内容因折叠而未导出，UI 可提示"仅分享当前可见内容"。 */
  omittedCollapsedContent: boolean = false;
  error: string = '';

  get ok(): boolean {
    return this.error.length === 0 && !this.requiresNarrowing && this.files.length > 0;
  }
}

/**
 * 单段截图的入参。builder 由页面提供：它负责把冻结后的分享投影画成离屏节点树，
 * 并在图片资源未就绪时画占位，避免整次分享被一张失败图片阻塞。
 */
export class ShareSegmentRequest {
  builder: CustomBuilder | undefined = undefined;
  /** builder 根画布实际使用的计划宽度；服务层据此拒绝无界请求。 */
  widthPx: number = 0;
  /** builder 根画布实际使用的最大高度；服务层据此拒绝无界请求。 */
  heightPx: number = 0;
}

export class ConversationShareService {
  private flow: ShareFlowState = new ShareFlowState();
  /** 句柄 → PixelMap，供释放时按账本定位真实对象。 */
  private bitmaps: Map<string, image.PixelMap> = new Map();
  private bitmapSequence: number = 0;
  private controller: systemShare.ShareController | undefined = undefined;
  /** dismiss 反注册要求传回同一个回调引用，必须保留。 */
  private dismissHandler: (() => void) | undefined = undefined;
  /**
   * 截图必须由持有 UI 树的页面提供 UIContext（`getComponentSnapshot()` 只在
   * UIContext 上可用）。页面 aboutToAppear 时注入，aboutToDisappear 时清空。
   */
  private uiContext: UIContext | undefined = undefined;

  attachUiContext(context: UIContext | undefined): void {
    this.uiContext = context;
  }

  currentStage(): string {
    return this.flow.currentStage();
  }

  lastError(): string {
    return this.flow.error();
  }

  /** 开始新一轮分享；返回代次，调用方在每次 await 之后校验。 */
  begin(): number {
    return this.flow.begin();
  }

  isCurrent(generation: number): boolean {
    return this.flow.isCurrent(generation);
  }

  /** 截图完成进入预览；过期代次返回 false，调用方据此丢弃本轮结果。 */
  settlePreview(generation: number): boolean {
    return this.flow.settlePreview(generation);
  }

  /** 按内容尺寸规划分段；requiresNarrowing 时不进入截图。 */
  plan(contentHeightPx: number, contentWidthPx: number): ShareSegmentPlan {
    const uiContext = this.uiContext;
    if (uiContext === undefined) return planShareSegments(contentHeightPx, contentWidthPx);
    const limit = uiContext.getComponentSnapshot().getSizeLimitation();
    return planShareSegments(contentHeightPx, contentWidthPx, limit.maxWidth, limit.maxHeight);
  }

  /**
   * 逐段截图并编码为缓存目录中的 PNG。
   *
   * 任一段失败即整体失败并释放已产生的资源：半套图片分享出去比失败更糟。
   */
  async renderSegments(
    context: common.UIAbilityContext,
    generation: number,
    segments: ShareSegmentRequest[],
    timestampMs: number,
  ): Promise<SharePreparation> {
    const out = new SharePreparation();
    for (let i = 0; i < segments.length; i++) {
      if (!this.flow.isCurrent(generation)) {
        // 已被取消或重新发起：立即收工，不再产生新资源。
        out.error = 'cancelled';
        return out;
      }
      const segment = segments[i];
      if (segment.builder === undefined || segment.widthPx <= 0 || segment.heightPx <= 0) {
        out.error = 'invalid-segment';
        return out;
      }
      try {
        const pixelMap = await this.snapshotSegment(segment);
        if (!this.flow.isCurrent(generation)) {
          // 过期结果：本段位图必须就地释放，不进账本也不返回。
          this.releasePixelMapNow(pixelMap);
          out.error = 'cancelled';
          return out;
        }
        // packToFile 在 await 期间仍读取 PixelMap；此时不能把位图交给共享释放账本，
        // 否则用户取消会提前 release 正在编码的对象。编码完成前由本调用栈独占。
        let file: ShareImageFile;
        try {
          file = await this.packToCache(context, pixelMap, i + 1, timestampMs);
        } finally {
          this.releasePixelMapNow(pixelMap);
        }
        if (!this.flow.isCurrent(generation)) {
          // 取消发生在编码期间：文件尚未进入账本，必须在这里就地删除。
          this.unlinkFileNow(file.path);
          out.error = 'cancelled';
          return out;
        }
        this.flow.resources().noteFile(file.path);
        out.files.push(file);
      } catch (e) {
        const message = e instanceof Error ? (e as Error).message : 'snapshot-failed';
        hilog.error(DOMAIN, TAG, 'share segment %{public}d failed: %{public}s', i + 1, message);
        out.error = message;
        return out;
      }
    }
    return out;
  }

  /** 拉起系统分享面板；面板关闭或分享完成后统一释放。 */
  async share(
    context: common.UIAbilityContext,
    generation: number,
    files: ShareImageFile[],
    onFinished: () => void,
  ): Promise<void> {
    if (!this.flow.settleSharing(generation) || files.length === 0) return;
    const records: systemShare.SharedRecord[] = [];
    for (let i = 0; i < files.length; i++) {
      records.push({
        utd: uniformTypeDescriptor.UniformDataType.PNG,
        uri: files[i].uri,
      });
    }
    const data = new systemShare.SharedData(records[0]);
    for (let i = 1; i < records.length; i++) data.addRecord(records[i]);
    const controller = new systemShare.ShareController(data);
    this.controller = controller;
    this.flow.resources().notePanelSubscribed(true);
    const settle = (): void => {
      this.release();
      onFinished();
    };
    controller.on('shareCompleted', settle);
    controller.on('dismiss', settle);
    this.dismissHandler = settle;
    try {
      await controller.show(context, {
        previewMode: systemShare.SharePreviewMode.DETAIL,
        // 多图必须批量交给目标应用；SINGLE 会让用户只能从分段中选一张。
        selectionMode: files.length > 1
          ? systemShare.SelectionMode.BATCH : systemShare.SelectionMode.SINGLE,
      });
    } catch (e) {
      const message = e instanceof Error ? (e as Error).message : 'share-panel-failed';
      hilog.error(DOMAIN, TAG, 'share panel failed: %{public}s', message);
      this.fail(generation, message);
      onFinished();
    }
  }

  /** 标记失败并释放资源；UI 保留错误信息用于重试入口。 */
  fail(generation: number, message: string): void {
    this.applyRelease(this.flow.fail(generation, message));
  }

  /**
   * 结束本轮并释放全部资源（取消、完成、页面销毁、退后台共用）。
   * 幂等：账本已空时不做任何事。
   */
  release(): void {
    this.applyRelease(this.flow.finish());
  }

  /** 失败态是否仍可重试（错误信息已保留）。 */
  canRetry(): boolean {
    return this.flow.currentStage() === SHARE_STAGE_FAILED;
  }

  /**
   * 单段离屏截图。
   *
   * `checkImageStatus: true` 让框架等待 builder 里的图片资源加载完成后再出图，
   * 避免头像 / 附件图还没解码就被截成空白（未就绪的图由 builder 自己画占位）。
   * `delay` 留一帧给离屏节点树完成布局与测量。
   */
  private async snapshotSegment(segment: ShareSegmentRequest): Promise<image.PixelMap> {
    const uiContext = this.uiContext;
    if (uiContext === undefined) throw new Error('ui-context-missing');
    const builder = segment.builder;
    if (builder === undefined) throw new Error('invalid-segment');
    return await uiContext.getComponentSnapshot().createFromBuilder(
      builder, SHARE_SNAPSHOT_DELAY_MS, true);
  }

  private async packToCache(
    context: common.UIAbilityContext,
    pixelMap: image.PixelMap,
    sequence: number,
    timestampMs: number,
  ): Promise<ShareImageFile> {
    // 临时文件只写应用缓存目录：不进仓库，也不进长期用户数据目录。
    const path = `${context.cacheDir}/${shareImageFileName(sequence, timestampMs)}`;
    const packer = image.createImagePacker();
    const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
    try {
      try {
        await packer.packToFile(pixelMap, file.fd, {
          format: 'image/png',
          quality: SHARE_PNG_QUALITY,
        });
      } finally {
        fileIo.closeSync(file);
        packer.release();
      }
    } catch (e) {
      // 关闭 fd 后再删除编码失败留下的半文件；它尚未进入共享释放账本。
      this.unlinkFileNow(path);
      const message = e instanceof Error ? (e as Error).message : 'pack-to-file-failed';
      throw new Error(message);
    }
    const out = new ShareImageFile();
    out.path = path;
    out.uri = fileUri.getUriFromPath(path);
    return out;
  }

  private rememberBitmap(pixelMap: image.PixelMap): string {
    this.bitmapSequence += 1;
    const handle = `bitmap-${this.bitmapSequence}`;
    this.bitmaps.set(handle, pixelMap);
    this.flow.resources().noteBitmap(handle);
    return handle;
  }

  private releaseBitmapByHandle(handle: string): void {
    const pixelMap = this.bitmaps.get(handle);
    if (pixelMap === undefined) return;
    this.bitmaps.delete(handle);
    this.releasePixelMapNow(pixelMap);
  }

  private releasePixelMapNow(pixelMap: image.PixelMap): void {
    try {
      pixelMap.release();
    } catch (e) {
      // 已释放或系统侧已回收：释放失败不应打断分享收尾。
    }
  }

  private unlinkFileNow(path: string): void {
    try {
      fileIo.unlinkSync(path);
    } catch (e) {
      // 文件可能尚未创建或已被系统清理。
    }
  }

  private applyRelease(release: ShareResourceRelease): void {
    if (release.isEmpty()) return;
    for (let i = 0; i < release.bitmaps.length; i++) {
      this.releaseBitmapByHandle(release.bitmaps[i]);
    }
    for (let i = 0; i < release.files.length; i++) {
      this.unlinkFileNow(release.files[i]);
    }
    if (release.unsubscribePanel && this.controller !== undefined) {
      const controller = this.controller;
      const dismissHandler = this.dismissHandler;
      try {
        controller.off('shareCompleted');
        if (dismissHandler !== undefined) controller.off('dismiss', dismissHandler);
      } catch (e) {
        // 面板已销毁时反注册会抛，忽略。
      }
      this.controller = undefined;
      this.dismissHandler = undefined;
    }
  }
}
