/**
 * 任务详情页：按渲染模型展示消息流 + Composer。
 *
 * 消息流由 MessageRender.buildRenderItems 构建（tool 配对 / thinking /
 * todo 卡 / 系统消息），正文走 MarkdownParser 渲染为 ArkUI 原生组件。
 * - thinking 默认折叠，点击展开；
 * - tool_group 默认展开，点击折叠；
 * - 消息动作（复制/Fork/Rewind）在切片 2.3 接入。
 */

import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { AppServices } from '../core/AppServices';
import { pickImageUris, buildImageCandidate } from '../core/attachments/ImagePicker';
import { uploadImage, presignGet } from '../core/attachments/AttachmentUpload';
import { RemoteImageRef, RemoteMediaFetchResult } from '../core/attachments/AttachmentModels';
import { parseAttachmentOssRef } from '../core/attachments/AttachmentOssRef';
import { PendingInteraction } from '../core/interactions/InteractionStore';
import { RemoteSession, readStr } from '../core/tasks/TaskModels';
import {
  RenderItem, RenderMessageItem, RenderThinkingItem,
  RenderToolGroupItem, RenderToolItem, RenderTodoCardItem, RenderTodoItem,
  RenderWorkGroupItem, RenderTextSegment,
  buildRenderItems, summarizeText,
} from '../core/messages/MessageRender';
import {
  MdBlock, tokenizeInline, InlineToken, parseMarkdown,
} from '../core/messages/MarkdownParser';

/** 活动 work_group 收起态的实时步骤预览行（对齐 Mobile collapsedBody）。 */
class WorkPreviewRow {
  key: string = '';
  kind: string = '';
  text: string = '';
  done: boolean = false;
}


@Entry
@Component
struct TaskPage {
  @State items: RenderItem[] = [];
  @State input: string = '';
  @State sending: boolean = false;
  @State error: string = '';
  @State loadFailed: boolean = false;
  /** thinking 展开的 key（默认折叠）。 */
  @State expandedThinking: string[] = [];
  /** tool_group 折叠的 key（默认展开）。 */
  /** work_group 展开的 key（默认折叠）。 */
  @State expandedWorkGroups: string[] = [];
  /** user 长文本块展开的 key（默认折叠）。 */
  @State expandedTextBlocks: string[] = [];
  private deviceId: string = '';
  private sessionId: string = '';
  private unsubs: Array<() => void> = [];
  private listScroller: Scroller = new Scroller();
  private initialScrolled: boolean = false;
  /** 初始列表仍在布局/补齐历史时，禁止 onReachStart 抢走底部锚点。 */
  private initialScrollSettling: boolean = true;
  private initialScrollGeneration: number = 0;
  private sessionOpenResolved: boolean = false;
  /** 加载更早消息进行中（防重复触发）。 */
  private loadingOlder: boolean = false;
  /** List 当前可见的首个渲染项；比 onReachStart 更可靠地识别真正到顶。 */
  private visibleStartIndex: number = 0;
  /** 单条/短首屏无法产生 List 滚动索引时，用真实手势触发一次历史分页。 */
  private listTouchStartY: number = 0;
  /** 当前手势是否明确表达了“向下回看更早消息”的意图。 */
  private listTouchPulledDown: boolean = false;
  private listTouchLoadTriggered: boolean = false;
  /** 待发送图片（上传状态）。 */
  @State composerImages: ComposerImage[] = [];
  private pickingImages: boolean = false;
  /** 历史图片：ref.url → 可加载的 OSS URL（懒解析 + 缓存）。 */
  @State imageSources: Map<string, string> = new Map();
  private ossUrlCache: Map<string, string> = new Map();
  /** 全屏预览中的图片 URL（空 = 无预览）。 */
  @State previewImageUrl: string = '';
  /** 挂起的交互请求（Permission / Ask User / Plan Review）。 */
  @State pendingInteractions: PendingInteraction[] = [];
  /** Ask User 选项选择（requestId → 选中的 label 列表）。 */
  @State askSelections: Map<string, string[]> = new Map();
  /** Ask User 自定义输入（requestId → 文本）。 */
  @State askCustomInputs: Map<string, string> = new Map();
  /** 当前设备是否关闭远程控制（只读提示）。 */
  @State deviceDisabled: boolean = false;
  /** 活动工作组的实时计时基准；与 Mobile 每 500ms 刷新一次。 */
  @State workClockNowMs: number = Date.now();
  private workClockTimer: number = -1;

  aboutToAppear(): void {
    this.stopWorkClock();
    const params = router.getParams() as Record<string, Object>;
    this.deviceId = readStr(params, 'deviceId');
    this.sessionId = readStr(params, 'sessionId');
    this.initialScrolled = false;
    this.initialScrollSettling = true;
    this.initialScrollGeneration += 1;
    this.sessionOpenResolved = false;
    this.visibleStartIndex = 0;
    this.listTouchStartY = 0;
    this.listTouchPulledDown = false;
    this.listTouchLoadTriggered = false;

    this.unsubs.push(AppServices.instance.messages.onChanged(() => {
      this.refreshItems();
    }));
    this.refreshItems();

    // 交互确认：订阅挂起交互 + 拉快照。
    this.unsubs.push(AppServices.instance.interactions.onChanged(() => {
      this.pendingInteractions = AppServices.instance.interactions.getPending(this.sessionId);
    }));
    this.pendingInteractions = AppServices.instance.interactions.getPending(this.sessionId);
    void AppServices.instance.interactions.refreshPending(this.deviceId, this.sessionId);

    // 撤权检查：设备关闭远程控制时只读。
    this.unsubs.push(AppServices.instance.tasks.onChanged(() => {
      this.deviceDisabled = this.checkDeviceDisabled();
      this.syncMessageCount();
    }));
    this.deviceDisabled = this.checkDeviceDisabled();
    this.syncMessageCount();

    AppServices.instance.messages.openSession(this.deviceId, this.sessionId).then(() => {
      this.sessionOpenResolved = true;
      this.scrollToBottomOnce();
    });
  }

  aboutToDisappear(): void {
    this.initialScrollGeneration += 1;
    this.initialScrollSettling = false;
    this.stopWorkClock();
    for (const u of this.unsubs) {
      u();
    }
    this.unsubs = [];
    void AppServices.instance.messages.closeSession(this.sessionId);
  }

  /** 判断当前设备是否关闭远程控制（撤权只读）。 */
  private checkDeviceDisabled(): boolean {
    const devices = AppServices.instance.tasks.deviceList;
    for (let i = 0; i < devices.length; i++) {
      if (devices[i].deviceId === this.deviceId) {
        return !devices[i].remoteControlEnabled;
      }
    }
    return false;
  }

  private session(): RemoteSession | undefined {
    const sessions = AppServices.instance.tasks.getSessions(this.deviceId);
    for (let i = 0; i < sessions.length; i++) {
      if (sessions[i].id === this.sessionId) {
        return sessions[i];
      }
    }
    return undefined;
  }

  /** 把任务列表的服务端消息总数交给分页 Store，覆盖 device-link 短页场景。 */
  private syncMessageCount(): void {
    const session = this.session();
    if (session !== undefined && session.messageCount > 0) {
      AppServices.instance.messages.setMessageCount(this.sessionId, session.messageCount);
    }
  }

  private send(): void {
    const text = this.input.trim();
    const readyImages: RemoteImageRef[] = [];
    let uploading = false;
    for (let i = 0; i < this.composerImages.length; i++) {
      const c = this.composerImages[i];
      if (c.status === 'uploading') {
        uploading = true;
      } else if (c.status === 'ready' && c.ref !== null) {
        readyImages.push(c.ref);
      }
    }
    if ((text.length === 0 && readyImages.length === 0) || this.sending) {
      return;
    }
    if (this.deviceDisabled) {
      promptAction.showToast({ message: '设备已关闭远程控制，仅可查看' });
      return;
    }
    if (uploading) {
      promptAction.showToast({ message: '图片上传中，请稍候' });
      return;
    }
    const s = this.session();
    if (s === undefined) {
      this.error = '任务信息缺失，请返回列表重新进入';
      return;
    }
    this.sending = true;
    this.error = '';
    AppServices.instance.messages.sendText(this.deviceId, s, text, readyImages).then(() => {
      this.input = '';
      this.composerImages = [];
      this.sending = false;
    }).catch((e: Error) => {
      this.sending = false;
      this.error = `发送失败：${e.message}`;
    });
  }

  // ─── 图片附件（选图 / 上传 / 移除 / 重试）────────────────────────────────────

  private pickImages(): void {
    if (this.pickingImages) {
      return;
    }
    this.pickingImages = true;
    pickImageUris(9).then((uris: string[]) => {
      this.pickingImages = false;
      for (let i = 0; i < uris.length; i++) {
        this.uploadComposerImage(uris[i], this.composerImages.length + i);
      }
    }).catch(() => {
      this.pickingImages = false;
    });
  }

  private uploadComposerImage(uri: string, index: number): void {
    const img = new ComposerImage();
    img.uri = uri;
    img.name = `image-${index + 1}`;
    this.composerImages = this.composerImages.concat([img]);
    buildImageCandidate(uri, index).then((candidate) => {
      img.name = candidate.name;
      return AppServices.instance.auth.getAccessToken().then((token: string | null) => {
        if (token === null || token.length === 0) {
          throw new Error('未登录');
        }
        return uploadImage(candidate, token);
      });
    }).then((ref: RemoteImageRef) => {
      img.status = 'ready';
      img.ref = ref;
      this.syncComposerImages();
    }).catch(() => {
      img.status = 'failed';
      this.syncComposerImages();
    });
  }

  private syncComposerImages(): void {
    this.composerImages = this.composerImages.slice();
  }

  private removeComposerImage(img: ComposerImage): void {
    const out: ComposerImage[] = [];
    for (let i = 0; i < this.composerImages.length; i++) {
      if (this.composerImages[i] !== img) {
        out.push(this.composerImages[i]);
      }
    }
    this.composerImages = out;
  }

  private retryComposerImage(img: ComposerImage): void {
    // 移除原失败项，再以同一 uri 重新上传（避免新旧两个对象并存）。
    const out: ComposerImage[] = [];
    for (let i = 0; i < this.composerImages.length; i++) {
      if (this.composerImages[i] !== img) {
        out.push(this.composerImages[i]);
      }
    }
    this.composerImages = out;
    this.uploadComposerImage(img.uri, this.composerImages.length);
  }

  private abort(): void {
    AppServices.instance.messages.abort(this.deviceId, this.sessionId).catch(() => {
    });
  }

  private retryLoad(): void {
    this.loadFailed = false;
    this.initialScrolled = false;
    this.initialScrollSettling = true;
    this.initialScrollGeneration += 1;
    this.sessionOpenResolved = false;
    this.visibleStartIndex = 0;
    this.listTouchStartY = 0;
    this.listTouchPulledDown = false;
    this.listTouchLoadTriggered = false;
    this.syncMessageCount();
    AppServices.instance.messages.openSession(this.deviceId, this.sessionId).then(() => {
      this.sessionOpenResolved = true;
      this.scrollToBottomOnce();
    });
  }

  /** 历史 + 流式统一进入同一个渲染模型，并把会话是否正在流式传入聚合层。 */
  private refreshItems(): void {
    this.syncMessageCount();
    const messages = AppServices.instance.messages.getMessagesWithStreaming(this.sessionId);
    const streaming = AppServices.instance.messages.isSessionStreaming(this.sessionId);
    this.syncWorkClock(streaming);
    this.items = buildRenderItems(messages, streaming);
    this.loadFailed = AppServices.instance.messages.loadFailed(this.sessionId);
    this.ensureImageUrls();
    if (this.sessionOpenResolved && this.items.length > 0 && !this.initialScrolled) {
      this.scrollToBottomOnce();
    }
  }

  /** 活动工作组使用实时 elapsed，而不是每次事件生成的 duration 快照。 */
  private syncWorkClock(active: boolean): void {
    if (!active) {
      this.stopWorkClock();
      return;
    }
    this.workClockNowMs = Date.now();
    if (this.workClockTimer >= 0) return;
    this.workClockTimer = setInterval(() => {
      this.workClockNowMs = Date.now();
    }, 500);
  }

  private stopWorkClock(): void {
    if (this.workClockTimer >= 0) {
      clearInterval(this.workClockTimer);
      this.workClockTimer = -1;
    }
  }

  private workElapsedMs(item: RenderWorkGroupItem): number {
    if (item.isStreaming && item.startedAtMs > 0) {
      return Math.max(0, this.workClockNowMs - item.startedAtMs);
    }
    return item.durationMs;
  }

  /** 进入会话/重试后定位到最新消息；等待列表完成布局，并阻止首屏翻页抢占锚点。 */
  private scrollToBottomOnce(): void {
    if (this.initialScrolled) {
      return;
    }
    if (this.items.length === 0) {
      return;
    }
    this.initialScrolled = true;
    const generation = this.initialScrollGeneration;
    const scroll = (): void => {
      if (generation !== this.initialScrollGeneration || this.items.length === 0) return;
      // List 的默认对齐是 START：滚到最后一项后，后续懒布局会把它重新放回
      // 中间。明确使用 END，并且不再紧接着调用 scrollEdge(Bottom)；后者在
      // 虚拟列表尚未完成测量时会再次改写 offset，正是“到底后弹回中间”的来源。
      this.listScroller.scrollToIndex(this.items.length - 1, false, ScrollAlign.END);
    };
    setTimeout(scroll, 120);
    setTimeout(scroll, 450);
    setTimeout(scroll, 900);
    setTimeout(() => {
      if (generation === this.initialScrollGeneration) {
        this.initialScrollSettling = false;
      }
    }, 1050);
  }

  /** 短首屏没有可用滚动索引时，对齐 Mobile：用户手指下滑才请求更早历史。 */
  private handleListTouch(event: TouchEvent): void {
    if (event.changedTouches.length === 0) return;
    const point = event.changedTouches[0];
    if (event.type === TouchType.Down) {
      this.listTouchStartY = point.displayY;
      this.listTouchPulledDown = false;
      this.listTouchLoadTriggered = false;
      return;
    }
    if (event.type === TouchType.Move) {
      const deltaY = point.displayY - this.listTouchStartY;
      // 先记录手势方向，再判断是否已经到顶。用户可能从中间开始下拖，
      // 到顶时 onReachStart/onScrollIndex 才会到达；不能因为那一帧 visibleStartIndex
      // 仍大于 0 就丢掉这次“回看历史”的意图。
      if (deltaY > 12) {
        this.listTouchPulledDown = true;
      }
      if (this.listTouchLoadTriggered || !this.sessionOpenResolved) {
        return;
      }
      // 未展示的历史在列表上方，因此用户应以“手指向下拖”的方式回看更早消息。
      if (deltaY > 48 && this.visibleStartIndex <= 0) {
        this.listTouchLoadTriggered = true;
        this.loadOlder();
      }
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.listTouchStartY = 0;
      this.listTouchPulledDown = false;
      this.listTouchLoadTriggered = false;
    }
  }

  /** 滚动到顶部：加载更早历史，并锚定到旧内容起始位置（阅读位置保持）。 */
  private loadOlder(): void {
    if (this.loadingOlder) {
      return;
    }
    if (!AppServices.instance.messages.hasMore(this.sessionId)) {
      return;
    }
    const msgs = AppServices.instance.messages.getMessages(this.sessionId);
    if (msgs.length === 0) {
      return;
    }
    // 不能用“新增原始消息数”作为 List index：多个 thinking/tool 行会被渲染模型
    // 合成一个 work_group，原始消息下标与可见 ListItem 下标并不相等。
    const previousFirstRenderKey = this.items.length > 0 ? this.items[0].key : '';
    this.loadingOlder = true;
    AppServices.instance.messages.loadOlder(this.deviceId, this.sessionId).then(() => {
      this.loadingOlder = false;
      const after = AppServices.instance.messages.getMessages(this.sessionId).length;
      const added = after - msgs.length;
      if (added > 0) {
        // 新加载的更早消息插在头部：回到 prepend 前的第一条渲染项，保持当前阅读点。
        // 这是桌面/Mobile 的 mVCP 语义在 ArkUI List 上的稳定 key 版本。
        setTimeout(() => {
          const anchorIndex = this.renderItemIndex(previousFirstRenderKey);
          if (anchorIndex >= 0) {
            this.listScroller.scrollToIndex(anchorIndex, false);
          } else {
            // 极旧历史没有稳定 work_group key 时保留一个保守兜底，避免阅读位置跳回顶部。
            const fallbackIndex = Math.min(added, Math.max(0, this.items.length - 1));
            this.listScroller.scrollToIndex(fallbackIndex, false);
          }
        }, 50);
      }
    }).catch(() => {
      this.loadingOlder = false;
    });
  }

  /** todo 卡标题（对齐 iOS：{completed}/{total} · 进行中内容）。 */
  private todoTitle(item: RenderTodoCardItem): string {
    let doneCount = 0;
    let activeContent = '';
    for (let i = 0; i < item.todos.length; i++) {
      const t = item.todos[i];
      if (t.status === 'completed') {
        doneCount += 1;
      } else if (t.status === 'in_progress' && activeContent.length === 0) {
        activeContent = t.content;
      }
    }
    const base = `${doneCount}/${item.todos.length}`;
    return activeContent.length > 0 ? `${base} · ${activeContent}` : base;
  }

  /** 思考卡标题（对齐 iOS：思考中 / 思考 Xs / 思考内容已隐藏）。 */
  private thinkingTitle(item: RenderThinkingItem): string {
    if (item.redacted) {
      return '思考内容已隐藏';
    }
    if (item.durationMs > 0) {
      return `思考 ${this.formatDuration(item.durationMs)}`;
    }
    return '思考过程';
  }

  /** 工作过程标题（对齐 iOS：已工作 Xs / 工作过程）。 */
  private workGroupTitle(item: RenderWorkGroupItem): string {
    if (item.isStreaming) {
      return '正在工作…';
    }
    if (item.durationMs >= 0) {
      return `已工作 ${this.formatDuration(item.durationMs)}`;
    }
    return '工作过程';
  }

  /** 活动态收起面板显示最近 5 条步骤，与 Mobile MAX_LIVE_WORK_ACTIVITIES 对齐。 */
  private workPreviewRows(item: RenderWorkGroupItem): WorkPreviewRow[] {
    const rows: WorkPreviewRow[] = [];
    this.appendWorkPreviewRows(item.children, rows);
    if (rows.length <= 5) {
      return rows;
    }
    return rows.slice(rows.length - 5);
  }

  private appendWorkPreviewRows(children: RenderItem[], rows: WorkPreviewRow[]): void {
    for (let i = 0; i < children.length; i++) {
      const child = children[i];
      if (child.type === 'work_group') {
        this.appendWorkPreviewRows((child as RenderWorkGroupItem).children, rows);
      } else if (child.type === 'thinking') {
        const thinking = child as RenderThinkingItem;
        const row = new WorkPreviewRow();
        row.key = child.key;
        row.kind = 'thinking';
        row.text = thinking.body.trim().length > 0
          ? summarizeText(thinking.body, 120)
          : '思考中…';
        rows.push(row);
      } else if (child.type === 'tool_group') {
        const tools = (child as RenderToolGroupItem).tools;
        for (let j = 0; j < tools.length; j++) {
          const tool = tools[j];
          const row = new WorkPreviewRow();
          row.key = `${child.key}-${tool.seq}`;
          row.kind = 'tool';
          row.done = tool.hasResult;
          row.text = this.toolStepLabel(tool);
          rows.push(row);
        }
      }
    }
  }

  /** 工作步骤文案：优先显示文件/命令等关键输入，避免只显示“正在工作”。 */
  private toolStepLabel(tool: RenderToolItem): string {
    const name = tool.toolName.length > 0 ? tool.toolName : 'tool';
    const lower = name.toLowerCase();
    let action = `调用 ${name}`;
    if (lower.includes('read') || lower === 'cat') {
      action = '读取';
    } else if (lower.includes('grep') || lower.includes('search') || lower.includes('find')) {
      action = '搜索';
    } else if (lower.includes('glob') || lower === 'ls' || lower.includes('list')) {
      action = '查找';
    } else if (lower.includes('write') || lower.includes('edit') || lower.includes('patch')) {
      action = '修改';
    } else if (lower.includes('bash') || lower.includes('shell') || lower.includes('exec') || lower.includes('run')) {
      action = '执行';
    }
    const detail = this.toolStepDetail(tool);
    if (action === `调用 ${name}`) {
      return detail.length > 0 ? `${action} · ${detail}` : action;
    }
    return detail.length > 0 ? `${action} ${detail}` : `${action} ${name}`;
  }

  private toolStepDetail(tool: RenderToolItem): string {
    if (tool.inputRaw.length > 0) {
      try {
        const parsed = JSON.parse(tool.inputRaw) as Object;
        if (parsed !== undefined && parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
          const record = parsed as Record<string, Object>;
          const keys: string[] = ['file_path', 'filePath', 'path', 'command', 'pattern', 'query', 'url'];
          for (let i = 0; i < keys.length; i++) {
            const value = readStr(record, keys[i]);
            if (value.length > 0) return summarizeText(value, 100);
          }
        }
      } catch (e) {
        // inputRaw 可能是旧版非 JSON 摘要，回退到 inputText。
      }
    }
    return tool.inputText.length > 0 ? summarizeText(tool.inputText, 100) : '';
  }

  private toolRowLabel(tool: RenderToolItem): string {
    const name = tool.toolName.length > 0 ? tool.toolName : 'tool';
    const lower = name.toLowerCase();
    if (lower.includes('read') || lower === 'cat') return `读取 ${name}`;
    if (lower.includes('grep') || lower.includes('search') || lower.includes('find')) return `搜索 ${name}`;
    if (lower.includes('glob') || lower === 'ls' || lower.includes('list')) return `查找 ${name}`;
    if (lower.includes('write') || lower.includes('edit') || lower.includes('patch')) return `修改 ${name}`;
    if (lower.includes('bash') || lower.includes('shell') || lower.includes('exec') || lower.includes('run')) return `执行 ${name}`;
    return `调用 ${name}`;
  }

  private compactBoundaryLabel(item: RenderMessageItem): string {
    const message = item.message;
    if (message !== undefined && readStr(message.systemCardData, 'trigger') === 'manual') {
      return '手动压缩';
    }
    return '自动压缩';
  }

  /** 时长格式化（对齐 shared formatDuration：Xs / Xm Ys / Xh Ym）。 */
  private formatDuration(ms: number): string {
    if (ms <= 0) {
      return '1s';
    }
    const totalSeconds = Math.max(1, Math.round(ms / 1000));
    if (totalSeconds < 60) {
      return `${totalSeconds}s`;
    }
    const minutes = Math.floor(totalSeconds / 60);
    const seconds = totalSeconds % 60;
    if (minutes < 60) {
      return seconds > 0 ? `${minutes}m ${seconds}s` : `${minutes}m`;
    }
    const hours = Math.floor(minutes / 60);
    const restMinutes = minutes % 60;
    return restMinutes > 0 ? `${hours}h ${restMinutes}m` : `${hours}h`;
  }

  private toggleExpanded(list: string[], key: string): string[] {
    const idx = list.indexOf(key);
    if (idx >= 0) {
      const out = list.slice(0, idx).concat(list.slice(idx + 1));
      return out;
    }
    return list.concat([key]);
  }

  private isIn(list: string[], key: string): boolean {
    return list.indexOf(key) >= 0;
  }

  /** 返回渲染列表中稳定 key 的位置；渲染项可能把多条原始消息折成一个 work_group。 */
  private renderItemIndex(key: string): number {
    if (key.length === 0) {
      return -1;
    }
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].key === key) {
        return i;
      }
    }
    return -1;
  }

  build() {
    Column() {
      Row() {
        Button('‹')
          .fontSize(18)
          .onClick(() => router.back())
        Text(this.sessionTitle())
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .margin({ left: 8 })
          .layoutWeight(1)
      }
      .width('100%')
      .padding(12)

      if (this.items.length === 0) {
        // 加载中 / 失败态：中间区域占位，输入框始终固定在底部。
        Column({ space: 12 }) {
          if (this.loadFailed) {
            Text('加载失败，请检查连接后重试')
              .fontSize(13)
              .fontColor($r('app.color.danger'))
            Button('重试')
              .fontSize(12)
              .onClick(() => this.retryLoad())
          } else {
            Text('加载中…')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
          }
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 4, scroller: this.listScroller }) {
          ForEach(this.items, (item: RenderItem) => {
            ListItem() {
              this.renderItem(item)
            }
          }, (item: RenderItem) => item.key)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16 })
        .onScrollIndex((start: number, _end: number, _center: number) => {
          this.visibleStartIndex = start;
          // 不要因为短首屏/初始布局停在 index=0 就自动追翻整段历史。
          // 只有当前手势已经明确向下拖动时，触顶回调才有资格拉一页更早消息。
          if (!this.initialScrollSettling
            && start <= 0
            && this.listTouchPulledDown
            && !this.listTouchLoadTriggered) {
            this.listTouchLoadTriggered = true;
            this.loadOlder();
          }
        })
        .onTouch((event: TouchEvent) => {
          this.handleListTouch(event);
        })
        .onReachStart(() => {
          // 滚动到顶：加载更早消息（对齐 Mobile 的下拉回看语义）。
          if (this.initialScrollSettling
            || !this.listTouchPulledDown
            || this.listTouchLoadTriggered) return;
          this.listTouchLoadTriggered = true;
          this.loadOlder();
        })
      }

      if (this.deviceDisabled) {
        Text('设备已关闭远程控制，仅可查看')
          .fontSize(12)
          .fontColor($r('app.color.warn'))
          .width('100%')
          .padding({ left: 16, right: 16 })
      }

      if (this.pendingInteractions.length > 0) {
        // 挂起的交互确认面板（Permission / Ask User / Plan Review）。
        Column({ space: 8 }) {
          ForEach(this.pendingInteractions, (item: PendingInteraction) => {
            this.pendingInteractionCard(item)
          }, (item: PendingInteraction) => item.requestId)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      }

      if (this.error.length > 0) {
        Text(this.error)
          .fontSize(12)
          .fontColor($r('app.color.danger'))
          .width('100%')
          .padding({ left: 16, right: 16 })
      }

      if (this.composerImages.length > 0) {
        // 待发送图片 tray（上传状态：… / 重试 / ✓）。
        List() {
          ForEach(this.composerImages, (img: ComposerImage) => {
            ListItem() {
              this.composerImageItem(img)
            }
          }, (img: ComposerImage) => img.uri)
        }
        .listDirection(Axis.Horizontal)
        .width('100%')
        .height(86)
        .padding({ left: 16, right: 16 })
      }

      Row({ space: 8 }) {
        Button('🖼')
          .fontSize(14)
          .onClick(() => this.pickImages())
        TextInput({ placeholder: '输入消息…', text: this.input })
          .onChange((v: string) => {
            this.input = v;
          })
          .onSubmit((enterKey: EnterKeyType) => {
            if (enterKey === EnterKeyType.Send) {
              this.send();
            }
          })
          .layoutWeight(1)
        Button('停止')
          .fontSize(12)
          .onClick(() => this.abort())
        Button(this.sending ? '发送中…' : '发送')
          .fontSize(12)
          .enabled(!this.sending && (this.input.trim().length > 0 || this.composerImages.length > 0))
          .onClick(() => this.send())
      }
      .width('100%')
      .padding(12)

      // 全屏图片预览层
      if (this.previewImageUrl.length > 0) {
        Stack() {
          Image(this.previewImageUrl)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
          Text('✕')
            .fontSize(18)
            .fontColor('#fff')
            .backgroundColor($r('app.color.overlay'))
            .width(32)
            .height(32)
            .textAlign(TextAlign.Center)
            .borderRadius(16)
            .position({ x: 16, y: 48 })
            .onClick(() => {
              this.previewImageUrl = '';
            })
        }
        .width('100%')
        .height('100%')
        .position({ x: 0, y: 0 })
        .zIndex(99)
        .backgroundColor('#e6000000')
        .onClick(() => {
          this.previewImageUrl = '';
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  // ─── 渲染项分派 ─────────────────────────────────────────────────────────────

  @Builder
  renderItem(item: RenderItem) {
    if (item.type === 'message') {
      if ((item as RenderMessageItem).kind === 'system'
        && (item as RenderMessageItem).message !== undefined
        && (item as RenderMessageItem).message?.systemCardType === 'compact') {
        this.compactBoundaryBlock(item as RenderMessageItem)
      } else {
        this.messageBlock(item as RenderMessageItem)
      }
    } else if (item.type === 'thinking') {
      this.thinkingBlock(item as RenderThinkingItem)
    } else if (item.type === 'tool_group') {
      this.toolGroupBlock(item as RenderToolGroupItem)
    } else if (item.type === 'todo') {
      this.todoBlock(item as RenderTodoCardItem)
    } else if (item.type === 'work_group') {
      this.workGroupBlock(item as RenderWorkGroupItem)
    }
  }

  /**
   * 工作过程折叠面板：历史默认折叠，活动中的 work_group 保留 Mobile 同款
   * 收起态实时步骤预览；点击后展示完整 thinking / tool 行。
   */
  @Builder
  workGroupBlock(item: RenderWorkGroupItem) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text('▱')
          .fontSize(14)
          .fontColor($r('app.color.text_tertiary'))
        Text(this.workGroupTitle(item))
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
        if (item.isStreaming) {
          Text(this.formatDuration(this.workElapsedMs(item)))
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
        }
        Text(this.isIn(this.expandedWorkGroups, item.key) ? '⌄' : '›')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
      .onClick(() => {
        this.expandedWorkGroups = this.toggleExpanded(this.expandedWorkGroups, item.key);
      })
      .width('100%')

      if (item.isStreaming
        && !this.isIn(this.expandedWorkGroups, item.key)
        && this.workPreviewRows(item).length > 0) {
        Column() {
          ForEach(this.workPreviewRows(item), (row: WorkPreviewRow) => {
            this.workPreviewRow(row)
          }, (row: WorkPreviewRow) => `${item.key}-${row.key}`)
        }
        .width('100%')
        .padding({ left: 10, top: 2, bottom: 2 })
        .border({ width: { left: 2 }, color: { left: $r('app.color.border') } })
      }

      if (this.isIn(this.expandedWorkGroups, item.key)) {
        Column({ space: 4 }) {
          ForEach(item.children, (child: RenderItem) => {
            // shared/Desktop 的 outer work_group 展开后直接展示活动内容；Harmony
            // 模型为保持时长边界可能保留一层 nested work_group，这里只展开它的
            // chrome，不再给用户第二个“已工作”折叠入口。
            this.workGroupChild(child)
          }, (child: RenderItem) => `${item.key}-${child.key}`)
        }
        .width('100%')
        .padding({ left: 10, top: 2, bottom: 2 })
        .border({ width: { left: 2 }, color: { left: $r('app.color.border') } })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  workPreviewRow(row: WorkPreviewRow) {
    Row({ space: 6 }) {
      Text(row.kind === 'thinking' ? '✧' : (row.done ? '✓' : '…'))
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
      Text(row.text)
        .fontSize(13)
        .fontStyle(row.kind === 'thinking' ? FontStyle.Italic : FontStyle.Normal)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text('›')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .padding({ top: 3, bottom: 3 })
  }

  @Builder
  workGroupChild(child: RenderItem) {
    if (child.type === 'work_group') {
      ForEach((child as RenderWorkGroupItem).children, (nested: RenderItem) => {
        this.workGroupChild(nested)
      }, (nested: RenderItem) => `${child.key}-${nested.key}`)
    } else {
      this.renderItem(child)
    }
  }

  /** 自动压缩边界：与 Desktop CompactBoundaryCard 同款“分隔线 + 居中 chip”。 */
  @Builder
  compactBoundaryBlock(item: RenderMessageItem) {
    Row({ space: 8 }) {
      Divider()
        .color($r('app.color.border'))
        .layoutWeight(1)
      Row({ space: 4 }) {
        Text('▱')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
        Text(this.compactBoundaryLabel(item))
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
      }
      .padding({ left: 9, right: 9, top: 5, bottom: 5 })
      .backgroundColor($r('app.color.bg_chip'))
      .border({ width: 1, color: $r('app.color.border') })
      .borderRadius(16)
      Divider()
        .color($r('app.color.border'))
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }

  /** 历史消息图片缩略图（点击全屏预览）。 */
  @Builder
  imageThumb(ref: RemoteImageRef) {
    Image(this.imageSources.get(ref.url) ?? '')
      .width(88)
      .height(88)
      .borderRadius(8)
      .objectFit(ImageFit.Cover)
      .backgroundColor($r('app.color.bg_chip'))
      .onClick(() => this.openImagePreview(ref))
  }

  /** 交互卡分派（按 kind）。 */
  @Builder
  pendingInteractionCard(item: PendingInteraction) {
    if (item.kind === 'permission') {
      this.permissionCard(item)
    } else if (item.kind === 'ask_user_question') {
      this.askUserCard(item)
    } else if (item.kind === 'plan_review') {
      this.planReviewCard(item)
    } else {
      Text(`交互请求（${item.kind}）`)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .padding(12)
        .backgroundColor($r('app.color.bg_card'))
        .borderRadius(10)
    }
  }

  /** Permission 卡：允许一次 / 始终允许 / 拒绝。 */
  @Builder
  permissionCard(item: PendingInteraction) {
    Column({ space: 6 }) {
      Text('权限请求')
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
      Text(this.permissionToolName(item))
        .fontSize(14)
      Text(this.permissionInputSummary(item))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
      Row({ space: 8 }) {
        Button('拒绝')
          .fontSize(12)
          .backgroundColor($r('app.color.text_secondary'))
          .onClick(() => this.resolveInteraction(item, this.permissionDecision(item, 'deny')))
        Button('允许一次')
          .fontSize(12)
          .onClick(() => this.resolveInteraction(item, this.permissionDecision(item, 'allow-once')))
        if (this.permissionCanAlwaysAllow(item)) {
          Button('始终允许')
            .fontSize(12)
            .onClick(() => this.resolveInteraction(item, this.permissionDecision(item, 'always-allow')))
        }
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(10)
  }

  /** Ask User 卡：问题 + 选项（单选/多选）+ 自定义输入 + 提交。 */
  @Builder
  askUserCard(item: PendingInteraction) {
    Column({ space: 6 }) {
      Text(this.askQuestion(item))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
      if (this.askOptions(item).length > 0) {
        ForEach(this.askOptions(item), (opt: string) => {
          Row({ space: 6 }) {
            Text(this.isAskSelected(item, opt) ? '☑' : '☐')
              .fontSize(13)
              .fontColor(this.isAskSelected(item, opt) ? $r('app.color.accent') : $r('app.color.text_secondary'))
            Text(opt)
              .fontSize(13)
          }
          .width('100%')
          .onClick(() => this.toggleAskSelection(item, opt))
        }, (opt: string) => `${item.requestId}-${opt}`)
      }
      if (this.askAllowsCustom(item)) {
        TextInput({ placeholder: '自定义输入…', text: this.askCustomInputs.get(item.requestId) ?? '' })
          .onChange((v: string) => {
            const next = new Map(this.askCustomInputs);
            next.set(item.requestId, v);
            this.askCustomInputs = next;
          })
          .fontSize(13)
      }
      Row({ space: 8 }) {
        Button('跳过')
          .fontSize(12)
          .backgroundColor($r('app.color.text_secondary'))
          .onClick(() => this.resolveInteraction(item, this.askSkip(item)))
        Button('提交')
          .fontSize(12)
          .onClick(() => this.resolveInteraction(item, this.askDecision(item)))
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(10)
  }

  /** Plan Review 卡：计划查看 + 批准 / 反馈拒绝。 */
  @Builder
  planReviewCard(item: PendingInteraction) {
    Column({ space: 6 }) {
      Text('计划审批')
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
      Text(this.planText(item))
        .fontSize(12)
        .fontColor($r('app.color.code_text'))
        .maxLines(8)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Row({ space: 8 }) {
        Button('拒绝')
          .fontSize(12)
          .backgroundColor($r('app.color.text_secondary'))
          .onClick(() => this.resolveInteraction(item, this.planDecision(item, false, '')))
        Button('批准')
          .fontSize(12)
          .onClick(() => this.resolveInteraction(item, this.planDecision(item, true, this.planText(item))))
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(10)
  }

  /** 待发送图片项（缩略图 + 上传状态 + 移除）。 */
  @Builder
  composerImageItem(img: ComposerImage) {
    Column({ space: 2 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Image(img.uri)
          .width(56)
          .height(56)
          .borderRadius(6)
          .objectFit(ImageFit.Cover)
        Text('✕')
          .fontSize(10)
          .fontColor('#fff')
          .backgroundColor($r('app.color.overlay'))
          .width(16)
          .height(16)
          .textAlign(TextAlign.Center)
          .borderRadius(8)
          .onClick(() => this.removeComposerImage(img))
      }
      if (img.status === 'uploading') {
        Text('上传中…')
          .fontSize(10)
          .fontColor($r('app.color.text_secondary'))
      } else if (img.status === 'failed') {
        Text('重试')
          .fontSize(10)
          .fontColor($r('app.color.danger'))
          .onClick(() => this.retryComposerImage(img))
      } else {
        Text('✓')
          .fontSize(10)
          .fontColor($r('app.color.success'))
      }
    }
    .padding({ right: 8 })
  }

  @Builder
  messageBlock(item: RenderMessageItem) {
    Column({ space: 4 }) {
      // Desktop / iOS 的普通 user/assistant 消息没有“助手 03:52”前缀；
      // 该元信息会把过程正文伪装成多条独立消息。系统卡仍保留身份提示。
      if (item.kind !== 'user' && item.kind !== 'assistant') {
        Row({ space: 8 }) {
          Text(item.label)
            .fontSize(11)
            .fontColor(this.labelColor(item.kind))
          Text(this.timeLabel(item.message !== undefined ? item.message.createdAt : ''))
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
      }

      if (item.kind === 'user' && item.segments.length > 1) {
        // 手打 + 粘贴段混合：手打正常渲染，粘贴段 chip（对齐 iOS InlineReferenceChip）。
        ForEach(item.segments, (seg: RenderTextSegment) => {
          if (seg.isPasted) {
            this.pastedChip(item, seg)
          } else if (seg.mdBlocks.length > 0) {
            this.mdBlocks(seg.mdBlocks)
          }
        }, (seg: RenderTextSegment) => `${item.key}-${seg.seq}`)
      } else if (item.kind === 'user' && item.segments.length > 0 && item.segments[0].isPasted) {
        // 无粘贴标记但超长（14/4 视觉行）：整条折叠显示前 10 行，点击展开。
        this.pastedBlock(item, item.segments[0])
      } else if (item.mdBlocks.length > 0) {
        this.mdBlocks(item.mdBlocks)
      }

      // 图片缩略图（历史图片懒解析后加载）。
      if (item.images.length > 0) {
        Row({ space: 6 }) {
          ForEach(item.images, (ref: RemoteImageRef) => {
            this.imageThumb(ref)
          }, (ref: RemoteImageRef) => ref.url)
        }
        .width('100%')
        .margin({ top: 4 })
      }

      // 操作栏只挂在 user 和已 seal 的最终 assistant 上；中间过程正文不再
      // 各自生成“复制/分叉/回退”，从视觉上恢复为一轮 turn 一条答复。
      if (item.kind === 'user'
        || (item.kind === 'assistant' && item.message !== undefined && item.message.turnCompleted)) {
        Row({ space: 16 }) {
          Text('复制')
            .fontSize(11)
            .fontColor($r('app.color.accent'))
            .onClick(() => this.copyMessage(item))
          if (this.canFork(item)) {
            Text('分叉')
              .fontSize(11)
              .fontColor($r('app.color.accent'))
              .onClick(() => this.confirmFork(item))
          }
          if (this.canRewind(item)) {
            Text('回退')
              .fontSize(11)
              .fontColor($r('app.color.accent'))
              .onClick(() => this.confirmRewind(item))
          }
        }
        .width('100%')
        .padding({ top: 2 })
      }
    }
    // user：右对齐气泡（对齐 iOS userBubble：surfaceElevated + 边框 + 圆角 12 + maxWidth 86%）；
    // assistant 等：无气泡全宽左对齐（对齐 iOS agentBubble）。
    .width(item.kind === 'user' ? '86%' : '100%')
    .alignSelf(item.kind === 'user' ? ItemAlign.End : ItemAlign.Start)
    .backgroundColor(item.kind === 'user' ? $r('app.color.bg_card') : Color.Transparent)
    .borderRadius(item.kind === 'user' ? 12 : 0)
    .border({ width: item.kind === 'user' ? 1 : 0, color: $r('app.color.border') })
    .padding({
      left: item.kind === 'user' ? 12 : 0,
      right: item.kind === 'user' ? 12 : 0,
      top: item.kind === 'user' ? 10 : 10,
      bottom: item.kind === 'user' ? 10 : 10,
    })
    .margin({ top: 4, bottom: 4 })
  }

  /** 粘贴段 chip：文件图标 + display 摘要，点击展开全文（对齐 iOS InlineReferenceChip）。 */
  @Builder
  pastedChip(item: RenderMessageItem, seg: RenderTextSegment) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text('📄')
          .fontSize(14)
        Text(seg.display.length > 0 ? seg.display : `已粘贴文本（${seg.text.length} 字）`)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.isIn(this.expandedTextBlocks, `${item.key}-${seg.seq}`) ? '▾' : '▸')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
      }
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .backgroundColor($r('app.color.bg_chip'))
      .borderRadius(8)
      .width('100%')
      .onClick(() => {
        this.expandedTextBlocks = this.toggleExpanded(this.expandedTextBlocks, `${item.key}-${seg.seq}`);
      })

      if (this.isIn(this.expandedTextBlocks, `${item.key}-${seg.seq}`)) {
        this.mdBlocks(seg.mdBlocks)
        Text('收起')
          .fontSize(12)
          .fontColor($r('app.color.accent'))
          .onClick(() => {
            this.expandedTextBlocks = this.toggleExpanded(this.expandedTextBlocks, `${item.key}-${seg.seq}`);
          })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  pastedBlock(item: RenderMessageItem, seg: RenderTextSegment) {
    Column({ space: 4 }) {
      if (this.isIn(this.expandedTextBlocks, `${item.key}-${seg.seq}`)) {
        this.mdBlocks(seg.mdBlocks)
        Text('收起')
          .fontSize(12)
          .fontColor($r('app.color.accent'))
          .onClick(() => {
            this.expandedTextBlocks = this.toggleExpanded(this.expandedTextBlocks, `${item.key}-${seg.seq}`);
          })
      } else {
        // 折叠态：显示正文前 10 行截断（对齐 iOS numberOfLines=10），点击展开全文。
        Text(seg.text)
          .fontSize(15)
          .maxLines(10)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .onClick(() => {
            this.expandedTextBlocks = this.toggleExpanded(this.expandedTextBlocks, `${item.key}-${seg.seq}`);
          })
        Text('展开全文')
          .fontSize(12)
          .fontColor($r('app.color.accent'))
          .onClick(() => {
            this.expandedTextBlocks = this.toggleExpanded(this.expandedTextBlocks, `${item.key}-${seg.seq}`);
          })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 8, bottom: 8 })
  }

  @Builder
  thinkingBlock(item: RenderThinkingItem) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text(this.isIn(this.expandedThinking, item.key) ? '▾' : '▸')
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
        Text(this.thinkingTitle(item))
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
      }
      .onClick(() => {
        this.expandedThinking = this.toggleExpanded(this.expandedThinking, item.key);
      })

      if (this.isIn(this.expandedThinking, item.key)) {
        if (item.redacted) {
          Text('思考内容已隐藏')
            .fontSize(12)
            .fontStyle(FontStyle.Italic)
            .fontColor($r('app.color.text_secondary'))
        } else if (item.mdBlocks.length > 0) {
          // 对齐 iOS ThinkingCard：正文斜体小字 + 左侧 Rail 线。
          Column() {
            this.mdBlocks(item.mdBlocks)
          }
          .width('100%')
          .padding({ left: 10, top: 2, bottom: 2 })
          .border({ width: { left: 2 }, color: { left: $r('app.color.border') } })
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  toolGroupBlock(item: RenderToolGroupItem) {
    Column({ space: 2 }) {
      // work_group 展开后只显示每个真实调用行；tool_group 自己再加“调用 bash”
      // 标题会与行标题叠加，历史数据里尤其容易形成重复的 Bash 行。
      ForEach(item.tools, (t: RenderToolItem) => {
        this.toolRow(t)
      }, (t: RenderToolItem) => `${item.key}-${t.seq}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  toolRow(t: RenderToolItem) {
    Column({ space: 2 }) {
      Row({ space: 6 }) {
        Text(t.hasResult ? '✓' : '…')
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
        Text(this.toolRowLabel(t))
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')

      if (t.inputText.length > 0) {
        Text(t.inputText)
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor($r('app.color.text_secondary'))
          .lineHeight(18)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      if (t.hasResult && t.resultText.length > 0) {
        Text(t.resultText)
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor($r('app.color.text_secondary'))
          .lineHeight(18)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 12, top: 4, bottom: 4 })
  }

  @Builder
  todoBlock(item: RenderTodoCardItem) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text(this.todoTitle(item))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')

      ForEach(item.todos, (t: RenderTodoItem) => {
        Row({ space: 6 }) {
          Text(this.todoMark(t.status))
            .fontSize(13)
            .fontColor(this.todoColor(t.status))
          Text(t.content)
            .fontSize(13)
            .fontColor(t.status === 'completed' ? $r('app.color.text_secondary') : $r('app.color.text_primary'))
          if (t.status === 'in_progress') {
            Text('…')
              .fontSize(13)
              .fontColor($r('app.color.warn'))
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }, (t: RenderTodoItem) => `${item.key}-${t.seq}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(10)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(12)
    .border({ width: 1, color: $r('app.color.border') })
    .margin({ top: 4, bottom: 4 })
  }

  // ─── Markdown 渲染 ──────────────────────────────────────────────────────────

  @Builder
  mdBlocks(blocks: MdBlock[]) {
    ForEach(blocks, (b: MdBlock) => {
      this.mdBlock(b)
    }, (b: MdBlock) => `${b.type}-${b.seq}`)
  }

  @Builder
  mdBlock(b: MdBlock) {
    if (b.type === 'heading') {
      Text(b.text)
        .fontSize(b.level <= 2 ? 18 : 16)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .lineHeight(b.level <= 2 ? 26 : 24)
        .padding({ top: 4, bottom: 4 })
    } else if (b.type === 'paragraph') {
      this.inlineText(b.text)
    } else if (b.type === 'list') {
      Column({ space: 2 }) {
        ForEach(b.items, (it: string, idx?: number) => {
          Row({ space: 6 }) {
            Text(b.ordered ? `${(idx ?? 0) + 1}.` : '•')
              .fontSize(15)
              .fontColor($r('app.color.text_secondary'))
            this.inlineText(it)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }, (it: string, idx?: number) => `${b.seq}:${idx ?? 0}:${it}`)
      }
      .padding({ top: 2, bottom: 2 })
    } else if (b.type === 'quote') {
      Text(b.text)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .lineHeight(22)
        .padding({ left: 10 })
        .border({ width: { left: 3 }, color: { left: $r('app.color.border') } })
        .width('100%')
    } else if (b.type === 'code') {
      Column({ space: 4 }) {
        Text(b.code)
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor($r('app.color.code_text'))
          .lineHeight(18)
          .padding(10)
          .backgroundColor($r('app.color.bg_code'))
          .border({ width: 1, color: $r('app.color.border') })
          .borderRadius(12)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .width('100%')
      .padding({ top: 2, bottom: 2 })
    } else if (b.type === 'table') {
      this.tableBlock(b)
    } else if (b.type === 'divider') {
      Divider()
        .color($r('app.color.border'))
        .margin({ top: 6, bottom: 6 })
    }
  }

  @Builder
  tableBlock(b: MdBlock) {
    Column() {
      Row() {
        ForEach(b.headers, (h: string, hIndex?: number) => {
          Row() {
            this.inlineText(h)
          }
          .layoutWeight(1)
          .padding({ left: 6, right: 6, top: 4, bottom: 4 })
          .border({ width: { right: 1, bottom: 1 }, color: $r('app.color.border') })
        }, (h: string, hIndex?: number) => `${b.seq}-h-${hIndex ?? 0}`)
      }
      .width('100%')

      ForEach(b.rows, (row: string[], rowIndex?: number) => {
        Row() {
          ForEach(row, (cell: string, cellIndex?: number) => {
            Row() {
              this.inlineText(cell)
            }
            .layoutWeight(1)
            .padding({ left: 6, right: 6, top: 4, bottom: 4 })
            .border({ width: { right: 1, bottom: 1 }, color: $r('app.color.border') })
          }, (cell: string, cellIndex?: number) => `${b.seq}-${rowIndex ?? 0}-${cellIndex ?? 0}`)
        }
        .width('100%')
      }, (row: string[], rowIndex?: number) => `${b.seq}-r-${rowIndex ?? 0}`)
    }
    .width('100%')
    .border({ width: { left: 1, top: 1 }, color: $r('app.color.border') })
  }

  @Builder
  inlineText(text: string) {
    Text() {
      ForEach(tokenizeInline(text), (t: InlineToken) => {
        if (t.kind === 'code') {
          Span(t.value)
            .fontFamily('monospace')
            .fontColor($r('app.color.code_text'))
            .textBackgroundStyle({ color: $r('app.color.bg_chip') })
        } else if (t.kind === 'strong') {
          Span(t.value)
            .fontWeight(FontWeight.Bold)
        } else if (t.kind === 'link' && this.isLocalReference(t.url)) {
          // Desktop 将文件路径、代码文件名等本地引用显示为中性的 code chip，
          // 只有真正的外部链接使用 accent；这样不会把 .ets / HAP 误染成蓝色。
          Span(t.value)
            .fontFamily('monospace')
            .fontColor($r('app.color.code_text'))
            .textBackgroundStyle({ color: $r('app.color.bg_chip') })
            .onClick(() => this.openUrl(t.url))
        } else if (t.kind === 'link') {
          Span(t.value)
            .fontColor($r('app.color.accent'))
            .onClick(() => this.openUrl(t.url))
        } else {
          Span(t.value)
        }
      }, (t: InlineToken) => `${t.seq}`)
    }
    .fontSize(15)
    .lineHeight(24)
    .width('100%')
    .textAlign(TextAlign.Start)
  }

  // ─── 样式/工具 ──────────────────────────────────────────────────────────────

  private isLocalReference(url: string): boolean {
    const lower = url.toLowerCase();
    return !lower.startsWith('http://')
      && !lower.startsWith('https://')
      && !lower.startsWith('mailto:')
      && !lower.startsWith('#');
  }

  private labelColor(kind: string): Resource {
    switch (kind) {
      case 'error':
        return $r('app.color.danger');
      case 'agent_switch':
        return $r('app.color.accent');
      case 'user':
        return $r('app.color.text_secondary');
      default:
        return $r('app.color.text_secondary');
    }
  }

  private todoMark(status: string): string {
    if (status === 'completed') return '☑';
    if (status === 'in_progress') return '◐';
    return '☐';
  }

  private todoColor(status: string): Resource {
    if (status === 'completed') return $r('app.color.success');
    if (status === 'in_progress') return $r('app.color.warn');
    return $r('app.color.text_tertiary');
  }

  private timeLabel(iso: string): string {
    if (iso.length < 16) {
      return iso;
    }
    return iso.slice(11, 16);
  }

  private sessionTitle(): string {
    const s = this.session();
    if (s !== undefined && s.title.length > 0) {
      return s.title;
    }
    return '任务';
  }

  // ─── 消息动作（复制 / Fork / Rewind）───────────────────────────────────────

  /** Fork 条件（对齐 mobile）：assistant 消息，或非首条的 user 消息。 */
  private canFork(item: RenderMessageItem): boolean {
    if (item.kind === 'assistant') {
      return true;
    }
    return item.kind === 'user' && !this.isFirstUserMessage(item);
  }

  /** Rewind 条件（对齐 mobile）：仅 user 消息且非首条。 */
  private canRewind(item: RenderMessageItem): boolean {
    return item.kind === 'user' && !this.isFirstUserMessage(item);
  }

  /** 判断是否为消息流中的首条 user 消息。 */
  private isFirstUserMessage(item: RenderMessageItem): boolean {
    for (let i = 0; i < this.items.length; i++) {
      const it = this.items[i];
      if (it.type === 'message') {
        const m = it as RenderMessageItem;
        if (m.kind === 'user') {
          return m.key === item.key;
        }
      }
    }
    return false;
  }

  private copyMessage(item: RenderMessageItem): void {
    const text = item.body;
    if (text.length === 0) {
      return;
    }
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      promptAction.showToast({ message: '已复制' });
    }).catch(() => {
      promptAction.showToast({ message: '复制失败' });
    });
  }

  private confirmFork(item: RenderMessageItem): void {
    this.resolveClientId(item).then((clientId: string) => {
      if (clientId.length === 0) {
        promptAction.showToast({ message: '无法定位消息' });
        return;
      }
      AlertDialog.show({
        title: '分叉任务',
        message: '将以这条消息为起点创建新任务，原任务保持不变。',
        primaryButton: {
          value: '取消',
          action: () => {
          },
        },
        secondaryButton: {
          value: '分叉',
          action: () => this.doFork(clientId),
        },
      });
    });
  }

  private confirmRewind(item: RenderMessageItem): void {
    this.resolveClientId(item).then((clientId: string) => {
      if (clientId.length === 0) {
        promptAction.showToast({ message: '无法定位消息' });
        return;
      }
      AlertDialog.show({
        title: '回退任务',
        message: '将回退到这条消息，之后的消息会被移除。',
        primaryButton: {
          value: '取消',
          action: () => {
          },
        },
        secondaryButton: {
          value: '回退',
          action: () => this.doRewind(clientId),
        },
      });
    });
  }

  /** 取消息的 clientId（messages:list 返回完整行，含 clientId）。 */
  private resolveClientId(item: RenderMessageItem): Promise<string> {
    const msg = item.message;
    return Promise.resolve(msg !== undefined ? msg.clientId : '');
  }

  // ─── 历史图片（懒解析 OSS URL / 缩略图 / 全屏预览）─────────────────────────

  /** 遍历当前消息流的图片引用，补齐缺失的可加载 URL。 */
  private ensureImageUrls(): void {
    for (let i = 0; i < this.items.length; i++) {
      const item = this.items[i];
      if (item.type !== 'message') {
        continue;
      }
      const m = item as RenderMessageItem;
      for (let j = 0; j < m.images.length; j++) {
        const ref = m.images[j];
        if (this.imageSources.has(ref.url)) {
          continue;
        }
        this.resolveImageUrl(ref).then((url: string) => {
          if (url.length === 0) {
            return;
          }
          const next = new Map(this.imageSources);
          next.set(ref.url, url);
          this.imageSources = next;
        });
      }
    }
  }

  /**
   * 解析图片引用为可加载 URL：
   * - http(s) 直链直接使用；
   * - cindy/xdt OSS 引用走 presign-get；
   * - Desktop 本地媒体引用走 device-link:media:fetch，再兼容 inline 缩略图和 OSS。
   */
  private resolveImageUrl(ref: RemoteImageRef): Promise<string> {
    const url = ref.url;
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return Promise.resolve(url);
    }
    if (url.startsWith('data:image/')) {
      return Promise.resolve(url);
    }
    const parsed = parseAttachmentOssRef(url);
    if (parsed !== null) {
      return this.resolveOssUrl(parsed.ossKey).catch(() => {
        return '';
      });
    }
    if (!this.isDesktopLocalImageUrl(url)) {
      return Promise.resolve('');
    }

    return AppServices.instance.messages.fetchRemoteMedia(this.deviceId, url, true).then(
      (fetched: RemoteMediaFetchResult) => {
        if (fetched.inlineBase64.length > 0) {
          const mimeType = fetched.mimeType.length > 0
            ? fetched.mimeType
            : (ref.mimeType.length > 0 ? ref.mimeType : 'image/webp');
          return `data:${mimeType};base64,${fetched.inlineBase64}`;
        }
        if (fetched.ossKey.length === 0) {
          return '';
        }
        return this.resolveOssUrl(fetched.ossKey);
      },
    ).catch(() => {
      return '';
    });
  }

  /** 解析被控端历史媒体 URL 的最小图片 scheme 集合。 */
  private isDesktopLocalImageUrl(url: string): boolean {
    return url.startsWith('xdt-image://')
      || url.startsWith('cindy-media://')
      || url.startsWith('xdt-file://');
  }

  /** OSS key → 临时可加载地址，并在页面生命周期内复用。 */
  private resolveOssUrl(ossKey: string): Promise<string> {
    const cached = this.ossUrlCache.get(ossKey);
    if (cached !== undefined) {
      return Promise.resolve(cached);
    }
    return AppServices.instance.auth.getAccessToken().then((token: string | null) => {
      if (token === null || token.length === 0) {
        throw new Error('未登录');
      }
      return presignGet(ossKey, token);
    }).then((getUrl: string) => {
      this.ossUrlCache.set(ossKey, getUrl);
      return getUrl;
    });
  }

  /** 用系统浏览器打开链接（Markdown 链接点击）。 */
  private openUrl(url: string): void {
    if (url.length === 0) {
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    context.startAbility({
      action: 'ohos.want.action.viewData',
      uri: url,
    }).catch(() => {
      promptAction.showToast({ message: '无法打开链接' });
    });
  }

  private openImagePreview(ref: RemoteImageRef): void {
    const src = this.imageSources.get(ref.url) ?? '';
    if (src.length > 0) {
      this.previewImageUrl = src;
    }
  }

  // ─── 交互确认（Permission / Ask User / Plan Review）──────────────────────────

  private resolveInteraction(item: PendingInteraction, decision: Record<string, Object>): void {
    AppServices.instance.interactions.resolve(this.deviceId, item.requestId, decision).catch(() => {
      promptAction.showToast({ message: '提交失败，请重试' });
    });
  }

  private requestStr(item: PendingInteraction, key: string): string {
    const v = item.raw[key];
    return typeof v === 'string' ? v : '';
  }

  private requestObj(item: PendingInteraction, key: string): Record<string, Object> {
    const v = item.raw[key];
    if (v !== undefined && typeof v === 'object' && !Array.isArray(v)) {
      return v as Record<string, Object>;
    }
    return {};
  }

  private requestBool(item: PendingInteraction, key: string): boolean {
    const v = item.raw[key];
    return v === true;
  }

  // ── Permission ──
  private permissionToolName(item: PendingInteraction): string {
    const toolName = this.requestStr(item, 'toolName');
    return toolName.length > 0 ? toolName : '工具调用';
  }

  private permissionInputSummary(item: PendingInteraction): string {
    const input = this.requestObj(item, 'input');
    if (Object.keys(input).length === 0) {
      return '';
    }
    const s = JSON.stringify(input);
    return s.length > 120 ? `${s.slice(0, 120)}…` : s;
  }

  private permissionCanAlwaysAllow(item: PendingInteraction): boolean {
    return this.requestBool(item, 'canAlwaysAllow');
  }

  private permissionDecision(item: PendingInteraction, behavior: string): Record<string, Object> {
    const d: Record<string, Object> = {};
    d['kind'] = 'permission';
    if (behavior === 'deny') {
      d['behavior'] = 'deny';
      d['reason'] = 'User denied';
    } else {
      d['behavior'] = 'allow';
      // 始终允许：session 级 permissionUpdates（request 携带时透传）。
      if (behavior === 'always-allow') {
        const suggestions = this.sessionSuggestions(item);
        if (suggestions.length > 0) {
          d['permissionUpdates'] = suggestions;
        }
      }
    }
    return d;
  }

  private sessionSuggestions(item: PendingInteraction): Object[] {
    const raw = item.raw['permissionSuggestions'];
    const out: Object[] = [];
    if (Array.isArray(raw)) {
      const list: Object[] = raw as Object[];
      for (let i = 0; i < list.length; i++) {
        const s = list[i];
        if (s !== undefined && typeof s === 'object' && !Array.isArray(s)) {
          const r = s as Record<string, Object>;
          if (r['destination'] === 'session') {
            out.push(s);
          }
        }
      }
    }
    return out;
  }

  // ── Ask User ──
  /** questions 是数组，取第一个问题（多步骤一期先逐题 resolve）。 */
  private firstQuestion(item: PendingInteraction): Record<string, Object> {
    const raw = item.raw['questions'];
    if (Array.isArray(raw)) {
      const list: Object[] = raw as Object[];
      if (list.length > 0) {
        const first = list[0];
        if (first !== undefined && typeof first === 'object' && !Array.isArray(first)) {
          return first as Record<string, Object>;
        }
      }
    }
    return {};
  }

  private askQuestion(item: PendingInteraction): string {
    const q = this.firstQuestion(item);
    const v = q['question'];
    return typeof v === 'string' ? v : '';
  }

  private askMultiSelect(item: PendingInteraction): boolean {
    const q = this.firstQuestion(item);
    return q['multiSelect'] === true;
  }

  private askOptions(item: PendingInteraction): string[] {
    const q = this.firstQuestion(item);
    const raw = q['options'];
    const out: string[] = [];
    if (Array.isArray(raw)) {
      const list: Object[] = raw as Object[];
      for (let i = 0; i < list.length; i++) {
        const o = list[i];
        if (o !== undefined && typeof o === 'object' && !Array.isArray(o)) {
          const label = (o as Record<string, Object>)['label'];
          if (typeof label === 'string' && label.length > 0) {
            out.push(label);
          }
        }
      }
    }
    return out;
  }

  private askAllowsCustom(item: PendingInteraction): boolean {
    const q = this.firstQuestion(item);
    const allows = q['allowsCustomAnswer'];
    return allows === true || allows === undefined;
  }

  private isAskSelected(item: PendingInteraction, label: string): boolean {
    const selected = this.askSelections.get(item.requestId);
    return selected !== undefined && selected.indexOf(label) >= 0;
  }

  private toggleAskSelection(item: PendingInteraction, label: string): void {
    const selected = this.askSelections.get(item.requestId) ?? [];
    const idx = selected.indexOf(label);
    let next: string[];
    if (idx >= 0) {
      next = selected.slice(0, idx).concat(selected.slice(idx + 1));
    } else {
      next = selected.concat([label]);
    }
    const map = new Map(this.askSelections);
    map.set(item.requestId, next);
    this.askSelections = map;
  }

  private askDecision(item: PendingInteraction): Record<string, Object> {
    const q = this.firstQuestion(item);
    const qv = q['question'];
    const question = typeof qv === 'string' ? qv : '';
    const selected = this.askSelections.get(item.requestId) ?? [];
    const custom = (this.askCustomInputs.get(item.requestId) ?? '').trim();
    const parts = selected.slice();
    if (custom.length > 0) {
      parts.push(custom);
    }
    // 多选按协议编码为 JSON 数组；单选直接文本。
    const answer = this.askMultiSelect(item) ? JSON.stringify(parts) : parts.join('\n');
    const answers: Record<string, Object> = {};
    answers[question] = answer;
    const d: Record<string, Object> = {};
    d['kind'] = 'ask_user_question';
    d['answers'] = answers;
    return d;
  }

  /** Skip：跳过当前问题（空答案，桌面端继续下一题/结束）。 */
  private askSkip(item: PendingInteraction): Record<string, Object> {
    const q = this.firstQuestion(item);
    const qv = q['question'];
    const question = typeof qv === 'string' ? qv : '';
    const answers: Record<string, Object> = {};
    answers[question] = '';
    const d: Record<string, Object> = {};
    d['kind'] = 'ask_user_question';
    d['answers'] = answers;
    return d;
  }

  // ── Plan Review ──
  private planText(item: PendingInteraction): string {
    return this.requestStr(item, 'plan');
  }

  private planDecision(item: PendingInteraction, approved: boolean, plan: string): Record<string, Object> {
    const d: Record<string, Object> = {};
    d['kind'] = 'plan_review';
    d['behavior'] = approved ? 'allow' : 'deny';
    if (approved) {
      d['editedPlan'] = plan;
    } else {
      d['reason'] = 'User rejected';
    }
    return d;
  }

  private doFork(clientId: string): void {
    AppServices.instance.messages.fork(this.deviceId, this.sessionId, clientId).then((newSessionId: string) => {
      if (newSessionId.length > 0) {
        promptAction.showToast({ message: '已创建新任务' });
        // 返回任务列表（列表会刷新显示新任务）。
        router.back();
      } else {
        promptAction.showToast({ message: '分叉失败' });
      }
    }).catch(() => {
      promptAction.showToast({ message: '分叉失败' });
    });
  }

  private doRewind(clientId: string): void {
    AppServices.instance.messages.rewindCommit(this.deviceId, this.sessionId, clientId).then((newSessionId: string) => {
      if (newSessionId.length > 0) {
        promptAction.showToast({ message: '已回退' });
        router.back();
      } else {
        promptAction.showToast({ message: '回退失败' });
      }
    }).catch(() => {
      promptAction.showToast({ message: '回退失败' });
    });
  }
}

/** 待发送图片（上传状态机：uploading → ready / failed）。 */
class ComposerImage {
  uri: string = '';
  name: string = '';
  status: string = 'uploading';
  ref: RemoteImageRef | null = null;
}
