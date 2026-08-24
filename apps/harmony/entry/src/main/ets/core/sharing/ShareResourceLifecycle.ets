/**
 * 会话分享的资源生命周期（纯逻辑，不触碰系统 API）。
 *
 * 分享会同时持有三类需要显式释放的资源：
 * - PixelMap（截图位图，占内存最大）；
 * - 应用缓存目录里的临时 PNG 文件；
 * - 系统分享面板的回调注册。
 *
 * 取消、失败、页面销毁和 App 退后台都必须走同一条释放路径，否则用户反复分享
 * 长会话会累积几十 MB 位图。本类只记录"该释放什么"并保证幂等，真正的
 * `PixelMap.release()` / 删文件 / 反注册由调用方注入的回调执行。
 *
 * 代次（generation）用于丢弃过期异步结果：分享期间用户可能取消后重新发起，
 * 旧的截图 Promise 回来时不得覆盖新一轮的状态，也不得释放新一轮的资源。
 */

/** 分享流程状态。 */
export const SHARE_STAGE_IDLE = 'idle';
export const SHARE_STAGE_RENDERING = 'rendering';
export const SHARE_STAGE_PREVIEW = 'preview';
export const SHARE_STAGE_SHARING = 'sharing';
export const SHARE_STAGE_FAILED = 'failed';

/** 一次分享会话持有的可释放资源清单。 */
export class ShareResourceLedger {
  /** 已生成但尚未释放的位图句柄标识（调用方用它定位真实 PixelMap）。 */
  private bitmaps: string[] = [];
  /** 已写入缓存目录、尚未删除的临时文件绝对路径。 */
  private files: string[] = [];
  /** 分享面板回调是否仍注册中。 */
  private panelSubscribed: boolean = false;

  noteBitmap(handle: string): void {
    if (handle.length > 0 && this.bitmaps.indexOf(handle) < 0) this.bitmaps.push(handle);
  }

  noteFile(path: string): void {
    if (path.length > 0 && this.files.indexOf(path) < 0) this.files.push(path);
  }

  notePanelSubscribed(subscribed: boolean): void {
    this.panelSubscribed = subscribed;
  }

  pendingBitmaps(): string[] {
    return this.bitmaps.slice();
  }

  pendingFiles(): string[] {
    return this.files.slice();
  }

  hasPanelSubscription(): boolean {
    return this.panelSubscribed;
  }

  isEmpty(): boolean {
    return this.bitmaps.length === 0 && this.files.length === 0 && !this.panelSubscribed;
  }

  /** 取走全部待释放资源并清空账本；重复调用返回空清单（幂等）。 */
  drain(): ShareResourceRelease {
    const release = new ShareResourceRelease();
    release.bitmaps = this.bitmaps.slice();
    release.files = this.files.slice();
    release.unsubscribePanel = this.panelSubscribed;
    this.bitmaps = [];
    this.files = [];
    this.panelSubscribed = false;
    return release;
  }
}

/** 一次释放动作要处理的资源。 */
export class ShareResourceRelease {
  bitmaps: string[] = [];
  files: string[] = [];
  unsubscribePanel: boolean = false;

  isEmpty(): boolean {
    return this.bitmaps.length === 0 && this.files.length === 0 && !this.unsubscribePanel;
  }
}

/**
 * 分享流程状态机。
 *
 * 只负责阶段流转与代次校验；UI 读 `stage()` 决定显示生成中 / 预览 / 失败重试。
 */
export class ShareFlowState {
  private stage: string = SHARE_STAGE_IDLE;
  private generation: number = 0;
  private errorMessage: string = '';
  private ledger: ShareResourceLedger = new ShareResourceLedger();

  currentStage(): string {
    return this.stage;
  }

  currentGeneration(): number {
    return this.generation;
  }

  error(): string {
    return this.errorMessage;
  }

  resources(): ShareResourceLedger {
    return this.ledger;
  }

  /** 开始新一轮分享：推进代次并作废在途结果，返回本轮代次。 */
  begin(): number {
    this.generation += 1;
    this.stage = SHARE_STAGE_RENDERING;
    this.errorMessage = '';
    return this.generation;
  }

  /** 本轮代次是否仍然有效（用户没有取消或重新发起）。 */
  isCurrent(generation: number): boolean {
    return generation === this.generation && this.stage !== SHARE_STAGE_IDLE;
  }

  /** 截图完成，进入预览。过期代次返回 false，调用方据此立即释放本次资源。 */
  settlePreview(generation: number): boolean {
    if (!this.isCurrent(generation)) return false;
    this.stage = SHARE_STAGE_PREVIEW;
    return true;
  }

  /** 用户确认分享，拉起系统面板。 */
  settleSharing(generation: number): boolean {
    if (!this.isCurrent(generation) || this.stage !== SHARE_STAGE_PREVIEW) return false;
    this.stage = SHARE_STAGE_SHARING;
    return true;
  }

  /** 失败：保留错误信息供重试入口显示，但资源必须先释放。 */
  fail(generation: number, message: string): ShareResourceRelease {
    if (!this.isCurrent(generation)) return new ShareResourceRelease();
    this.stage = SHARE_STAGE_FAILED;
    this.errorMessage = message;
    return this.ledger.drain();
  }

  /**
   * 结束本轮（取消、分享完成、页面销毁、退后台共用）。
   *
   * 推进代次让所有在途异步结果作废，并交出全部待释放资源。重复调用是安全的：
   * 账本已空时返回空清单。
   */
  finish(): ShareResourceRelease {
    this.generation += 1;
    this.stage = SHARE_STAGE_IDLE;
    this.errorMessage = '';
    return this.ledger.drain();
  }
}

/** 分享是否正在占用资源；退后台时据此决定要不要立刻收工。 */
export function shareFlowBusy(stage: string): boolean {
  return stage === SHARE_STAGE_RENDERING
    || stage === SHARE_STAGE_PREVIEW
    || stage === SHARE_STAGE_SHARING;
}
