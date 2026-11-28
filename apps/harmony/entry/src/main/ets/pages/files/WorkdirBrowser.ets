import { image } from '@kit.ImageKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { WorkdirAnnotation } from './WorkdirAnnotation';
import { WorkdirModelLease, stageWorkdirModel } from '../../core/files/WorkdirModel';
import { WorkdirModelView } from './WorkdirModelView';
import { workdirPreferences } from '../../core/files/WorkdirPreferences';
import { HarmonyHttp } from '../../network/HarmonyHttp';
import { WorkdirHtmlSnapshot, buildWorkdirHtmlSnapshot } from '../../core/files/WorkdirHtmlSnapshot';
import { WorkdirHtmlReader } from './WorkdirHtmlReader';
import { util } from '@kit.ArkTS';
import { WorkdirDrawio } from './WorkdirDrawio';
import { presignGet, deleteUpload } from '../../core/attachments/AttachmentUpload';
import { WorkdirPdf } from './WorkdirPdf';
import { common } from '@kit.AbilityKit';
import { WorkdirPreviewMedia, workdirPreviewKind } from '../../core/files/WorkdirPreview';
import { RemoteFileService } from '../../core/files/RemoteFileService';
import { MermaidDiagramView } from '../../components/MermaidDiagramView';
import { MdBlock, parseMarkdown } from '../../core/messages/MarkdownParser';
import { pasteboard } from '@kit.BasicServicesKit';
import { uiMenuOptions, uiOverlayBuildId, uiOverlayTrace, uiSheetOptions, uiToast } from '../../components/common/UiOverlay';
import { UI_ICON_CLICK_EFFECT, UI_LIST_CLICK_EFFECT, UI_RADIUS_CONTROL, UI_RADIUS_PILL } from '../../components/UiKit';
import { i18n } from '@kit.LocalizationKit';
import { AppServices } from '../../core/AppServices';
import { readStr, recordOrEmpty } from '../../core/tasks/TaskModels';
import { WorkdirEntry, WorkdirReadFence, WorkdirRequest, WorkdirWatchDebounce, workdirEntries, workdirListRequest, workdirName, workdirParent } from '../../core/files/WorkdirFiles';

/** 网格里每个条目的视觉框：文件夹图标、文件图标、内容摘要卡片和图片缩略图都占同样大小，保证对齐。 */
const THUMB_WIDTH = 76;
const THUMB_HEIGHT = 96;
/** 标题栏左右两侧等宽（右侧胶囊放两个 44vp 图标按钮），保证标题居中。 */
const HEADER_SIDE = 96;

/**
 * 文件夹浏览页自带一层导航标题栏（返回 / 标题 / 搜索与更多），宿主 bindSheet 时不再显示系统标题和关闭按钮，
 * 避免两层标题（docs/overlay-standard.md §3.2 例外）。根目录时标题栏左侧按钮即「关闭」。
 */
export function workdirBrowserSheetOptions(onDisappear: () => void): SheetOptions {
  const options = uiSheetOptions('', onDisappear, SheetSize.LARGE);
  options.title = undefined;
  options.showClose = false;
  return options;
}

/** 文件大小：与 iOS 一致，1 位小数（≥100 取整），如 2.1 KB、7.0 KB、128 KB。 */
function workdirSizeLabel(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return '';
  if (bytes < 1024) return `${bytes} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit++; }
  return `${value >= 100 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`;
}

/** 修改日期：按系统语言本地化，同年只显示月日（中文「11月12日」），跨年带年份。 */
function workdirDateLabel(modified: number): string {
  if (!(modified > 0)) return '';
  const date = new Date(modified);
  const locale = i18n.System.getSystemLocale();
  try {
    const sameYear = date.getFullYear() === new Date().getFullYear();
    const format = sameYear
      ? new Intl.DateTimeFormat(locale, { month: 'short', day: 'numeric' })
      : new Intl.DateTimeFormat(locale, { year: 'numeric', month: 'short', day: 'numeric' });
    return format.format(date);
  } catch (_error) {
    return date.toLocaleDateString();
  }
}

@Component
export struct WorkdirBrowser {
  @Prop device: string = '';
  @Prop workdir: string = '';
  @Prop deviceName: string = '';
  @Prop initialFile: string = '';
  private initialFilePending: boolean = true;
  @Prop initialPath: string = '';
  close: () => void = (): void => {};
  annotate: ((bytes: ArrayBuffer) => boolean) | undefined = undefined;
  reference: ((path: string, folder: boolean) => void) | undefined = undefined;

  private copy(path: string): void {
    if (!this.current()) return;
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, path);
    void pasteboard.getSystemPasteboard().setData(data).then((): void => {
      if (this.current()) uiToast(this.getUIContext(), '已复制路径');
    }).catch((): void => {
      if (this.current()) uiToast(this.getUIContext(), '复制失败');
    });
  }
  @State private thumbs: Map<string, string> = new Map();
  private thumbVisible: Map<string, WorkdirEntry> = new Map();
  private thumbPending: Set<string> = new Set();
  private thumbActive: number = 0;
  @State private headerMenu: string = '';
  @State private itemMenuKey: string = '';
  @State private path: string = '';
  @State private entries: WorkdirEntry[] = [];
  @State private searchSummary: string = '';
  @State private sourceLines: string[] = [];
  @State private matches: WorkdirEntry[] = [];
  @State private loading: boolean = false;
  @State private error: string = '';
  @State private watching: boolean = false;
  @State private listMode: boolean = false;
  @State private sort: string = 'name';
  @State private searching: boolean = false;
  @State private contents: boolean = false;
  @State private query: string = '';
  @State private preview: WorkdirEntry | null = null;
  @State private body: string = '';
  @State private modelLease: WorkdirModelLease | null = null;
  @State private htmlSnapshot: WorkdirHtmlSnapshot | null = null;
  @State private drawing: boolean = false;
  @State private drawingBusy: boolean = false;
  @State private drawingImage: image.PixelMap | null = null;
  @State private drawingWidth: number = 0;
  @State private drawingHeight: number = 0;
  @State private diagramReady: boolean = false;
  @State private previewKind: string = '';
  @State private previewUrl: string = '';
  @State private blocks: MdBlock[] = [];
  @State private sharing: boolean = false;
  private media: WorkdirPreviewMedia | null = null;
  private shareService: RemoteFileService = new RemoteFileService();
  private siblings: WorkdirEntry[] = [];
  private shareSeq: number = 0;
  private mediaEpoch: number = 0;
  private mediaScope: string = '';
  @State private columns: number = 3;
  private active: boolean = false;
  private preferenceRevision: number = 0;
  private foreground: boolean = true;
  private epoch: number = 0;
  private readFence: WorkdirReadFence = new WorkdirReadFence();
  private watchDebounce: WorkdirWatchDebounce = new WorkdirWatchDebounce();
  private searchSeq: number = 0;
  private previewSeq: number = 0;
  private owner: string = '';
  private ownerDevice: string = '';
  private ownerWorkdir: string = '';
  private watchScope: string = '';
  private watchRun: Promise<void> = Promise.resolve();
  private watchTimer: number = -1;
  private watchDirty: boolean = false;
  @State private showIgnoredDirs: boolean = false;
  @State private showIgnoredSupported: boolean | undefined = undefined;
  private ignoredReady: boolean = false;
  private lastListedIgnored: boolean = false;
  private ignoredScope: string = '';
  private searchTimer: number = -1;
  private index: string[] | null = null;
  private indexRun: Promise<string[]> | null = null;
  private cache: Map<string, WorkdirEntry[]> = new Map();
  private offWatch?: () => void;
  private offStatus?: () => void;
  private offLifecycle?: () => void;

  aboutToAppear(): void {
    const services = AppServices.instance;
    this.active = true;
    this.owner = services.usageCardOwner;
    this.ownerDevice = this.device;
    this.ownerWorkdir = this.workdir;
    this.path = this.initialPath;
    const revision = this.preferenceRevision;
    void workdirPreferences.restore(getContext(this) as common.Context, this.owner, this.device, this.workdir)
      .then((value: string): void => {
        if (!this.current() || revision !== this.preferenceRevision) return;
        const fields = value.split(':');
        if (fields.length !== 2 || ['name', 'date', 'size'].indexOf(fields[1]) < 0) return;
        this.listMode = fields[0] === 'list';
        this.sort = fields[1];
      }).catch((): void => {});
    this.offWatch = services.onWorkdirChanged(this.device, this.workdir, () => this.current(), () => this.changed());
    this.offStatus = services.onStatus((status: string): void => {
      if (!this.current()) { this.close(); return; }
      this.resetWatch(status === 'online' && this.foreground);
      if (status === 'online' && this.foreground) {
        if (this.showIgnoredDirs) void this.resolveIgnoredCapability().then((): void => this.reload());
        else this.reload();
      }
    });
    this.offLifecycle = services.onModulePush((device: string, channel: string, payload: Object | undefined): void => {
      if (channel === 'app-foreground') this.foreground = payload === true;
      else if (channel !== 'link-closed' || device !== this.device) return;
      this.resetWatch(channel === 'app-foreground' && this.foreground);
      if (channel === 'app-foreground' && this.foreground) this.reload();
      if (channel === 'link-closed' && (payload === 'revoked' || payload === 'ACCESS_REVOKED')) {
        this.cache.clear();
        this.entries = [];
        this.close();
      }
    });
    this.resetWatch(true);
    void this.restoreIgnoredPreference();
  }

  aboutToDisappear(): void {
    this.active = false;
    this.closeDrawing();
    this.resetWatch(false);
    this.offWatch?.();
    this.offStatus?.();
    this.offLifecycle?.();
    clearTimeout(this.searchTimer);
    this.cache.clear();
    this.thumbVisible.clear();
    this.thumbs = new Map();
    this.modelLease?.dispose();
    this.modelLease = null;
    this.media?.dispose();
    this.media = null;
    ++this.shareSeq;
    this.shareService.release();
  }

  private current(): boolean {
    const services = AppServices.instance;
    return this.active && this.owner.length > 0 && this.owner === services.usageCardOwner &&
      this.device === this.ownerDevice && this.workdir === this.ownerWorkdir &&
      services.canReadWorkdir(this.device, this.workdir);
  }

  private resetWatch(want: boolean): void {
    const epoch = ++this.epoch;
    this.watching = false;
    this.watchDirty = false;
    this.watchDebounce.cancel();
    clearTimeout(this.watchTimer);
    const device = this.ownerDevice;
    const root = this.ownerWorkdir;
    const services = AppServices.instance;
    this.watchRun = this.watchRun.then(async (): Promise<void> => {
      if (this.watchScope) {
        const previous = this.watchScope;
        this.watchScope = '';
        await services.releaseWorkdir(device, root, previous).catch((): void => {});
      }
      if (!want || epoch !== this.epoch || !this.current()) return;
      this.watchScope = services.moduleScope;
      await services.subscribeWorkdir(device, root, () => epoch === this.epoch && this.current());
      if (epoch === this.epoch && this.current()) this.watching = true;
    }).catch((): void => {});
  }

  // An event only dirties this visible directory. One read in flight, at most one
  // trailing reload, no polling or recovery action against the shared connection.
  private changed(): void {
    if (!this.foreground || !this.current()) return;
    clearTimeout(this.watchTimer);
    this.watchTimer = setTimeout(this.watchDebounce.next((): boolean => this.foreground && this.current(),
      (): void => {
        if (this.loading) this.watchDirty = true;
        else this.reload();
      }), 600);
  }

  private call(request: WorkdirRequest, current: () => boolean): Promise<Object | undefined> {
    return AppServices.instance.invokeOwnedWorkdir(this.device, request, () => this.current() && current());
  }

  private async restoreIgnoredPreference(): Promise<void> {
    try {
      const enabled = await workdirPreferences.restoreShowIgnored(getContext(this) as common.Context);
      if (!this.current()) return;
      this.showIgnoredDirs = enabled;
      if (enabled) await this.resolveIgnoredCapability();
    } catch (_error) {
      // Use the normal hidden listing when preferences or capability lookup fail.
    } finally {
      if (this.current()) { this.ignoredReady = true; this.reload(); }
    }
  }

  private async resolveIgnoredCapability(): Promise<void> {
    const scope = AppServices.instance.moduleScope;
    if (!this.current() || (scope === this.ignoredScope && this.showIgnoredSupported !== undefined)) return;
    this.ignoredScope = scope;
    this.showIgnoredSupported = undefined;
    const current = (): boolean => this.current() && scope === AppServices.instance.moduleScope;
    try {
      const caps = await this.previewMedia().capabilities(current);
      if (current()) this.showIgnoredSupported = caps['showIgnoredDirs'] === true;
    } catch (_error) {
      // A transient failure is not an old host. The next explicit menu open may retry.
    }
  }

  private toggleIgnoredDirectories(): void {
    if (!this.current() || !this.ignoredReady || this.showIgnoredSupported !== true ||
      this.ignoredScope !== AppServices.instance.moduleScope) return;
    this.showIgnoredDirs = !this.showIgnoredDirs;
    workdirPreferences.saveShowIgnored(getContext(this) as common.Context, this.showIgnoredDirs);
    this.cache.clear();
    this.reload();
  }

  private reload(): void {
    if (!this.current() || !this.foreground || !this.ignoredReady) return;
    if (this.loading) { this.watchDirty = true; return; }
    const path = this.path;
    const request = workdirListRequest(this.workdir, path, this.showIgnoredDirs,
      this.ignoredScope === AppServices.instance.moduleScope ? this.showIgnoredSupported : undefined);
    const showIgnored = request.showIgnoredDirs === true;
    const preference = this.showIgnoredDirs;
    const current = this.readFence.capture(path, (): string => this.path,
      (): boolean => this.current() && this.showIgnoredDirs === preference);
    this.loading = true;
    this.error = '';
    void this.call(request, current)
      .then((value: Object | undefined): void => {
        if (!current() || !this.current()) return;
        this.entries = workdirEntries(value);
        if (this.initialFilePending && this.initialFile) {
          this.initialFilePending = false;
          const target = this.entries.find((entry: WorkdirEntry): boolean =>
            entry.path === this.initialFile && !entry.folder);
          if (target !== undefined) this.open(target);
        }
        this.cache.set(path, this.entries);
        if (this.cache.size > 24) this.cache.delete(this.cache.keys().next().value as string);
        // Desktop's filename index is independent of directory visibility.
        if (this.lastListedIgnored === showIgnored) {
          this.index = null;
          if (this.searching && !this.contents) this.search();
        }
        this.lastListedIgnored = showIgnored;
      })
      .catch((error: Error): void => {
        if (current() && this.current()) this.error = this.failure(error);
      })
      .finally((): void => {
        this.loading = false;
        if (this.watchDirty && this.current()) { this.watchDirty = false; this.reload(); }
      });
  }

  private go(path: string): void {
    if (!this.current()) return;
    this.preview = null;
    ++this.previewSeq;
    this.searching = false;
    ++this.searchSeq;
    this.thumbVisible.clear();
    this.path = path;
    this.entries = this.cache.get(path) ?? [];
    this.reload();
  }

  private search(): void {
    clearTimeout(this.searchTimer);
    const seq = ++this.searchSeq;
    const current = (): boolean => this.searching && seq === this.searchSeq;
    const query = this.query.trim();
    this.matches = [];
    this.searchSummary = '';
    if (!this.searching || !this.current()) return;
    if (!this.contents) {
      if (!this.index && !this.indexRun) {
        const request = new WorkdirRequest('listAllFiles', this.workdir);
        request.cap = 20000;
        this.indexRun = this.call(request, () => this.searching && !this.contents).then((value: Object | undefined): string[] => {
          const files = recordOrEmpty(value)['files'];
          return Array.isArray(files) ? (files as string[]) : [];
        });
      }
      if (this.index) { this.applyIndex(this.index, query); return; }
      const run = this.indexRun;
      if (!run) return;
      void run.then((files: string[]): void => {
        if (!this.current()) return;
        this.index = files;
        if (current()) this.applyIndex(files, query);
      }).catch((error: Error): void => {
        if (this.current() && current()) this.error = this.failure(error);
      }).finally((): void => {
        if (this.indexRun === run) this.indexRun = null;
      });
      return;
    }
    if (query.length < 2) return;
    this.searchTimer = setTimeout((): void => {
      const request = new WorkdirRequest('searchCollect', this.workdir);
      request.query = query;
      request.maxMatches = 200;
      void this.call(request, current).then((value: Object | undefined): void => {
        if (!current() || !this.current()) return;
        const result = recordOrEmpty(value);
        const matches = result['matches'];
        if (!Array.isArray(matches)) return;
        this.searchSummary = (Number(result['totalMatches']) || 0) + ' 处匹配，' +
          (Number(result['totalFiles']) || 0) + ' 个文件' + (result['truncated'] === true ? '（结果已截断）' : '');
        this.matches = (matches as Object[]).map((match: Object): WorkdirEntry => {
          const row = recordOrEmpty(match);
          const path = readStr(row, 'relPath');
          const entry = new WorkdirEntry(workdirName(path), path, false, 0, 0, Number(row['lineNumber']) || 0);
          const text = readStr(row, 'lineText').trim();
          const matchAt = Math.max(0, text.toLowerCase().indexOf(query.toLowerCase()));
          const left = Math.max(0, matchAt - 40);
          entry.excerpt = (left > 0 ? '…' : '') + text.slice(left, left + 220);
          return entry;
        });
      }).catch((error: Error): void => {
        if (current() && this.current()) this.error = this.failure(error);
      });
    }, 450);
  }

  private failure(error: Error): string {
    const message = String(error);
    if (message.includes('CHANNEL_NOT_ALLOWED')) return '电脑版本不支持文件浏览，请更新电脑端';
    if (message.includes('PERMISSION') || message.includes('REMOTE_DISABLED')) return '没有访问此工作目录的权限';
    return '未能读取远程文件，请重新同步';
  }

  private applyIndex(files: string[], query: string): void {
    if (!query) return;
    const key = query.toLowerCase();
    this.matches = files.filter((path: string): boolean => path.toLowerCase().includes(key)).slice(0, 200)
      .map((path: string): WorkdirEntry => new WorkdirEntry(workdirName(path), path, false, 0, 0));
  }

  private previewMedia(): WorkdirPreviewMedia {
    const services = AppServices.instance;
    if (this.media === null || this.mediaScope !== services.moduleScope) {
      this.media?.dispose();
      this.mediaScope = services.moduleScope;
      this.mediaEpoch++;
      this.media = new WorkdirPreviewMedia(services.createOwnedHostMedia(), this.device, this.workdir,
        (request: WorkdirRequest, current: () => boolean): Promise<Object | undefined> => this.call(request, current));
    }
    return this.media as WorkdirPreviewMedia;
  }

  private open(row: WorkdirEntry): void {
    if (row.folder) { this.go(row.path); return; }
    this.siblings = this.searching ? [row] : this.rows().filter((entry: WorkdirEntry): boolean => !entry.folder);
    this.readPreview(row);
  }

  private pagePreview(offset: number): void {
    const current = this.preview;
    if (current === null) return;
    const index = this.siblings.findIndex((row: WorkdirEntry): boolean => row.path === current.path);
    const next = this.siblings[index + offset];
    if (next !== undefined && index >= 0) this.readPreview(next);
  }

  private readPreview(row: WorkdirEntry): void {
    this.preview = row;
    this.previewKind = workdirPreviewKind(row.path);
    this.previewUrl = '';
    this.body = '正在读取…';
    this.diagramReady = false;
    this.htmlSnapshot = null;
    this.modelLease?.dispose();
    this.modelLease = null;
    this.blocks = [];
    this.sourceLines = [];
    const seq = ++this.previewSeq;
    const current = (): boolean => seq === this.previewSeq && this.preview !== null && this.current();
    if (row.line > 0) this.previewKind = 'text';
    if (this.previewKind === 'html') {
      void buildWorkdirHtmlSnapshot(this.workdir, row.path,
        (request: WorkdirRequest): Promise<Object | undefined> => this.call(request, current),
        async (path: string): Promise<ArrayBuffer> => {
          const url = await this.previewMedia().url(path, 0, current, 1024 * 1024);
          if (!current()) throw new Error('OWNER_CHANGED');
          const inline = /^data:image\/[a-z0-9.+-]+;base64,([A-Za-z0-9+/=]+)$/i.exec(url);
          if (inline === null) return await new HarmonyHttp().downloadBytes(url);
          const bytes = new util.Base64Helper().decodeSync(inline[1]);
          return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
        }, current).then((snapshot: WorkdirHtmlSnapshot): void => {
          if (current()) this.htmlSnapshot = snapshot;
        }).catch((error: Error): void => { if (current()) this.body = this.failure(error); });
      return;
    }
    if (this.previewKind === 'model') {
      void stageWorkdirModel(getContext(this) as common.Context, row.path,
        async (path: string, budget: number): Promise<ArrayBuffer> => {
          const url = await this.previewMedia().url(path, 0, current, budget);
          if (!current()) throw new Error('OWNER_CHANGED');
          const inline = /^data:image\/[a-z0-9.+-]+;base64,([A-Za-z0-9+/=]+)$/i.exec(url);
          if (inline === null) return await new HarmonyHttp().downloadBytes(url);
          const bytes = new util.Base64Helper().decodeSync(inline[1]);
          return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
        }, current).then((lease: WorkdirModelLease): void => {
          if (current()) this.modelLease = lease;
          else lease.dispose();
        }).catch((error: Error): void => { if (current()) this.body = this.failure(error); });
      return;
    }
    if (this.previewKind === 'unsupported') {
      this.body = '此类型暂不支持端内预览，可以导出或分享';
      return;
    }
    if (['image', 'audio', 'video', 'pdf'].indexOf(this.previewKind) >= 0) {
      const media = this.previewMedia();
      const epoch = this.mediaEpoch;
      void media.url(row.path, row.modified, current)
        .then((url: string): void => { if (current() && epoch === this.mediaEpoch) this.previewUrl = url; })
        .catch((error: Error): void => { if (current()) this.body = this.failure(error); });
      return;
    }
    void this.call(new WorkdirRequest('readFile', this.workdir, row.path), current)
      .then((value: Object | undefined): void => {
        if (!current()) return;
        const envelope = recordOrEmpty(value);
        const result = recordOrEmpty(envelope['data']);
        if (typeof result['content'] !== 'string') {
          this.body = '此文件无法预览，可以导出或分享';
          return;
        }
        this.body = readStr(result, 'content');
        if (row.line > 0) {
          const lines = this.body.split(/\r?\n/);
          if (row.line <= lines.length) this.sourceLines = lines;
          else this.body = '文件已变化或预览已截断，无法定位该行。\n\n' + this.body;
        }
        this.diagramReady = this.previewKind === 'mermaid' || this.previewKind === 'drawio';
        if (this.previewKind === 'markdown') this.blocks = parseMarkdown(this.body);
      }).catch((error: Error): void => {
        if (current()) this.body = this.failure(error);
      });
  }

  private closeDrawing(): void {
    this.drawing = false;
    if (this.drawingImage) void this.drawingImage.release();
    this.drawingImage = null;
  }

  private async openDrawing(): Promise<void> {
    const row = this.preview;
    if (!row || !this.previewUrl || this.drawingBusy || !this.annotate) return;
    this.drawingBusy = true;
    const seq = this.previewSeq;
    const current = (): boolean => seq === this.previewSeq && this.current();
    try {
      const url = await this.previewMedia().url(row.path, row.modified, current, 16 * 1024 * 1024);
      const inline = /^data:image\/[a-z0-9.+-]+;base64,([A-Za-z0-9+/=]+)$/i.exec(url);
      const decoded = inline === null ? null : new util.Base64Helper().decodeSync(inline[1]);
      const bytes = decoded === null ? await new HarmonyHttp().downloadBytes(url) :
        decoded.buffer.slice(decoded.byteOffset, decoded.byteOffset + decoded.byteLength);
      if (!current() || bytes.byteLength > 16 * 1024 * 1024) throw new Error('IMAGE_LIMIT');
      const source = image.createImageSource(bytes);
      try {
        const info = await source.getImageInfo();
        const width = info.size.width;
        const height = info.size.height;
        if (width <= 0 || height <= 0 || width * height > 16000000) throw new Error('IMAGE_LIMIT');
        if (!current()) return;
        const decodedImage = await source.createPixelMap();
        if (!current()) { void decodedImage.release(); return; }
        this.drawingWidth = width;
        this.drawingHeight = height;
        this.drawingImage = decodedImage;
        this.drawing = true;
      } finally {
        void source.release();
      }
    } catch (_error) {
      if (current()) uiToast(this.getUIContext(), '无法标注此图片');
    } finally {
      this.drawingBusy = false;
    }
  }

  private async share(row: WorkdirEntry): Promise<void> {
    if (this.sharing || row.folder || !this.current()) return;
    this.sharing = true;
    const seq = ++this.shareSeq;
    const current = (): boolean => seq === this.shareSeq && this.current();
    const services = AppServices.instance;
    const scope = services.moduleScope;
    let stagingKey = '';
    const release = (key: string): void => {
      if (scope !== services.moduleScope) return;
      void services.auth.getAccessToken().then((token: string | null): void => {
        if (token && scope === services.moduleScope) void deleteUpload(key, token).catch((): void => {});
      }).catch((): void => {});
    };
    try {
      const url = await this.previewMedia().exportUrl(row.path, row.modified, current,
        async (key: string): Promise<string> => {
          stagingKey = key;
          const token = await services.auth.getAccessToken();
          if (!token || scope !== services.moduleScope || !current()) throw new Error('OWNER_CHANGED');
          return await presignGet(key, token);
        }, release);
      if (!current()) return;
      await this.shareService.shareUrl(getContext(this) as common.UIAbilityContext, url, row.name, current);
    } catch (_error) {
      if (current()) uiToast(this.getUIContext(), '无法导出此文件，请稍后重试');
    } finally {
      if (stagingKey) release(stagingKey);
      if (current()) this.sharing = false;
    }
  }

  @Builder
  previewContent() {
    if (this.previewKind === 'model' && this.modelLease !== null) {
      WorkdirModelView({ lease: this.modelLease })
    } else if (this.previewKind === 'html' && this.htmlSnapshot !== null) {
      WorkdirHtmlReader({ snapshot: this.htmlSnapshot })
    } else if (this.previewUrl && this.previewKind === 'pdf') {
      WorkdirPdf({ url: this.previewUrl })
    } else if (this.previewUrl && this.previewKind === 'image') {
      Image(this.previewUrl).width('100%').height('100%').objectFit(ImageFit.Contain)
    } else if (this.previewUrl && (this.previewKind === 'video' || this.previewKind === 'audio')) {
      Video({ src: this.previewUrl }).controls(true).autoPlay(false).width('100%').height('100%')
    } else if (this.previewKind === 'drawio' && this.diagramReady) {
      WorkdirDrawio({ source: this.body })
    } else if (this.previewKind === 'mermaid' && this.diagramReady) {
      MermaidDiagramView({ source: this.body, zoomable: true, deferSource: true })
    } else if (this.sourceLines.length > 0) {
      List({ initialIndex: Math.max(0, (this.preview?.line ?? 1) - 1) }) {
        ForEach(this.sourceLines, (line: string, index: number) => {
          ListItem() {
            Text((index + 1).toString() + '  ' + line).width('100%')
              .fontFamily('monospace').fontSize(13).copyOption(CopyOptions.LocalDevice)
              .fontColor(index + 1 === this.preview?.line ? $r('app.color.accent') : $r('app.color.text_primary'))
          }
        }, (_line: string, index: number): string => String(index))
      }.width('100%').height('100%')
    } else {
      Scroll() {
        if (this.blocks.length > 0) {
          Column({ space: 10 }) {
            ForEach(this.blocks, (block: MdBlock) => {
              Text(block.type === 'code' ? block.code : (block.type === 'list' ? block.items.join('\n') :
                (block.type === 'table' ? [block.headers.join(' · ')].concat(
                  block.rows.map((row: string[]): string => row.join(' · '))).join('\n') : block.text)))
                .width('100%').fontSize(block.type === 'heading' ? 20 : 15)
                .fontWeight(block.type === 'heading' ? FontWeight.Medium : FontWeight.Regular)
                .fontFamily(block.type === 'code' ? 'monospace' : 'sans-serif')
                .fontColor($r('app.color.text_primary')).copyOption(CopyOptions.LocalDevice)
            }, (block: MdBlock): string => String(block.seq))
          }.width('100%')
        } else {
          Text(this.body).width('100%').fontColor($r('app.color.text_primary'))
            .fontFamily(this.previewKind === 'text' ? 'monospace' : 'sans-serif').copyOption(CopyOptions.LocalDevice)
        }
      }.width('100%').height('100%')
    }
  }

  private rows(): WorkdirEntry[] {
    if (this.searching) return this.matches;
    return this.entries.slice().sort((a: WorkdirEntry, b: WorkdirEntry): number => {
      if (a.folder !== b.folder) return a.folder ? -1 : 1;
      const order = this.sort === 'date' ? b.modified - a.modified :
        (this.sort === 'size' ? b.size - a.size : 0);
      return order || a.name.localeCompare(b.name);
    });
  }

  private levels(): string[] {
    const levels: string[] = [''];
    this.path.split('/').filter((part: string): boolean => !!part).forEach((part: string): void => {
      const parent = levels[levels.length - 1];
      levels.push(parent ? parent + '/' + part : part);
    });
    return levels;
  }

  private absolute(path: string): string {
    const sep = this.workdir.includes('\\') ? '\\' : '/';
    return path ? this.workdir.replace(/[\\/]+$/, '') + sep + path.split('/').join(sep) : this.workdir;
  }

  private savePreferences(list: boolean, sort: string): void {
    this.listMode = list;
    this.sort = sort;
    const revision = ++this.preferenceRevision;
    workdirPreferences.save(getContext(this) as common.Context, this.owner, this.device, this.workdir,
      (list ? 'list' : 'grid') + ':' + sort, (): boolean => revision === this.preferenceRevision &&
        this.owner === AppServices.instance.usageCardOwner);
  }

  /** 标题 ⌄：祖先路径（根在上），当前层打勾。 */
  @Builder
  pathMenu() {
    Menu() {
      ForEach(this.levels(), (path: string) => {
        MenuItem({
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.folder')),
          content: workdirName(path || this.workdir),
        })
          .selected(path === this.path)
          .selectIcon(true)
          .onClick((): void => this.go(path))
      }, (path: string): string => path + ':' + (path === this.path))
    }
    .id(uiOverlayBuildId('workdir-path'))
  }

  /** 「…」：显示方式与排序、路径操作、同步，分组展示。 */
  @Builder
  moreMenu() {
    Menu() {
      MenuItemGroup() {
        MenuItem({
          symbolStartIcon: new SymbolGlyphModifier(this.listMode ? $r('sys.symbol.square_grid_2x2') : $r('sys.symbol.list_bullet')),
          content: this.listMode ? '切换网格' : '切换列表',
        }).onClick((): void => this.savePreferences(!this.listMode, this.sort))
      }
      MenuItemGroup() {
        MenuItem({ content: '按名称排序' }).selected(this.sort === 'name').selectIcon(true)
          .onClick((): void => this.savePreferences(this.listMode, 'name'))
        MenuItem({ content: '按修改时间排序' }).selected(this.sort === 'date').selectIcon(true)
          .onClick((): void => this.savePreferences(this.listMode, 'date'))
        MenuItem({ content: '按大小排序' }).selected(this.sort === 'size').selectIcon(true)
          .onClick((): void => this.savePreferences(this.listMode, 'size'))
      }
      MenuItemGroup() {
        MenuItem({ content: $r('app.string.workdir_show_ignored_dirs'),
          labelInfo: this.showIgnoredSupported === false ?
            $r('app.string.workdir_show_ignored_dirs_unsupported') : '' })
          .enabled(this.ignoredReady && this.showIgnoredSupported === true)
          .selected(this.showIgnoredDirs && this.showIgnoredSupported === true).selectIcon(true)
          .onClick((): void => this.toggleIgnoredDirectories())
      }
      MenuItemGroup() {
        MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.text_clipboard')), content: '复制路径' })
          .onClick((): void => this.copy(this.absolute(this.path)))
        if (this.reference !== undefined) {
          MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.link')), content: '引用到任务' })
            .onClick((): void => { if (this.current()) this.reference?.(this.path, true); })
        }
        MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.arrow_clockwise')), content: '重新同步' })
          .onClick((): void => this.reload())
      }
    }
    .id(uiOverlayBuildId('workdir-more'))
  }

  @Builder
  itemMenu(row: WorkdirEntry) {
    Menu() {
      MenuItem({ content: '复制路径' }).onClick((): void => this.copy(this.absolute(row.path)))
      if (!row.folder) {
        MenuItem({ content: '导出／分享' }).onClick((): void => { void this.share(row); })
      }
      if (this.reference !== undefined) {
        MenuItem({ content: '引用到任务' }).onClick((): void => { if (this.current()) this.reference?.(row.path, row.folder); })
      }
    }
  }

  private rowMenuKey(row: WorkdirEntry): string {
    return row.path + ':' + row.line + ':' + row.modified;
  }

  private thumbnailKey(row: WorkdirEntry): string {
    return JSON.stringify([row.path, row.modified, row.size]);
  }

  private thumbnailVisible(row: WorkdirEntry, visible: boolean): void {
    const key = this.thumbnailKey(row);
    if (visible) this.thumbVisible.set(key, row);
    else this.thumbVisible.delete(key);
    this.pumpThumbnails();
  }

  private pumpThumbnails(): void {
    if (!this.current() || !this.foreground || this.searching || this.preview !== null) return;
    for (const pair of this.thumbVisible) {
      if (this.thumbActive >= 2) return;
      const key = pair[0];
      const row = pair[1];
      if (row.folder || this.thumbs.has(key) || this.thumbPending.has(key)) continue;
      const imageThumb = workdirPreviewKind(row.path) === 'image';
      if (!imageThumb && (row.size <= 0 || row.size > 24 * 1024 ||
        !/\.(txt|md|mdx|json|xml|ya?ml|csv|toml|tsx?|jsx?|ets|py|go|rs|java|css|html?)$/i.test(row.path))) continue;
      ++this.thumbActive;
      this.thumbPending.add(key);
      const path = this.path;
      const current = (): boolean => this.current() && this.foreground && this.path === path;
      void this.call(new WorkdirRequest(imageThumb ? 'thumbnail' : 'readFile', this.workdir, row.path),
        (): boolean => current() && this.thumbVisible.has(key)).then((value: Object | undefined): void => {
        if (!current()) return;
        const result = recordOrEmpty(value);
        let thumb = '';
        if (imageThumb) {
          const base64 = readStr(result, 'dataBase64');
          if (result['ok'] === true && base64.length <= 256 * 1024 && /^[A-Za-z0-9+/=]+$/.test(base64)) {
            thumb = 'data:image/webp;base64,' + base64;
          }
        } else if (result['ok'] === true) {
          thumb = readStr(recordOrEmpty(result['data']), 'content').slice(0, 500);
        }
        this.storeThumbnail(key, thumb);
      }).catch((): void => {
        if (current() && this.thumbVisible.has(key)) this.storeThumbnail(key, '');
      }).finally((): void => {
        --this.thumbActive;
        this.thumbPending.delete(key);
        this.pumpThumbnails();
      });
    }
  }

  private storeThumbnail(key: string, value: string): void {
    const next = new Map(this.thumbs);
    next.set(key, value);
    if (next.size > 96) {
      const first = Array.from(next.keys()).find((entry: string): boolean => !this.thumbVisible.has(entry));
      if (first !== undefined) next.delete(first);
    }
    this.thumbs = next;
  }

  private thumbnail(row: WorkdirEntry): string {
    return this.thumbs.get(this.thumbnailKey(row)) ?? '';
  }

  /** 元信息与 iOS 一致：文件「大小 · 日期」，文件夹只显示日期；搜索命中显示「路径:行号」。 */
  private meta(row: WorkdirEntry): string {
    if (row.line > 0) return row.path + ':' + row.line;
    const date = workdirDateLabel(row.modified);
    if (row.folder) return date;
    const size = row.size > 0 ? workdirSizeLabel(row.size) : '';
    if (size && date) return size + ' · ' + date;
    return size || date || row.path;
  }

  /** 网格视觉框：内容摘要卡片 / 图片缩略图 / 统一的文件夹与文件图标，尺寸一致。 */
  @Builder
  thumbFrame(row: WorkdirEntry) {
    if (!row.folder && this.thumbnail(row).startsWith('data:image/')) {
      Image(this.thumbnail(row))
        .width(THUMB_WIDTH)
        .height(THUMB_HEIGHT)
        .objectFit(ImageFit.Cover)
        .borderRadius(UI_RADIUS_CONTROL)
        .border({ width: 1, color: $r('app.color.border') })
        .clip(true)
    } else if (!row.folder && this.thumbnail(row)) {
      Text(this.thumbnail(row))
        .fontSize(7)
        .lineHeight(9)
        .fontFamily('monospace')
        .fontColor($r('app.color.text_secondary'))
        .maxLines(9)
        .textOverflow({ overflow: TextOverflow.Clip })
        .textAlign(TextAlign.Start)
        .align(Alignment.TopStart)
        .width(THUMB_WIDTH)
        .height(THUMB_HEIGHT)
        .padding(6)
        .backgroundColor($r('app.color.bg_card'))
        .border({ width: 1, color: $r('app.color.border') })
        .borderRadius(UI_RADIUS_CONTROL)
        .clip(true)
    } else {
      Stack() {
        SymbolGlyph(row.folder ? $r('sys.symbol.folder') : $r('sys.symbol.doc'))
          .fontSize(row.folder ? THUMB_WIDTH : THUMB_WIDTH - 8)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width(THUMB_WIDTH)
      .height(THUMB_HEIGHT)
    }
  }

  @Builder
  gridCell(row: WorkdirEntry) {
    Column() {
      this.thumbFrame(row)
      Text(row.name)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
        .margin({ top: 8 })
      Text(this.meta(row))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
        .margin({ top: 2 })
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 8, bottom: 8 })
  }

  @Builder
  listRow(row: WorkdirEntry) {
    Row({ space: 12 }) {
      Stack() {
        if (!row.folder && this.thumbnail(row).startsWith('data:image/')) {
          Image(this.thumbnail(row))
            .width(40)
            .height(40)
            .objectFit(ImageFit.Cover)
            .borderRadius(UI_RADIUS_CONTROL)
            .border({ width: 1, color: $r('app.color.border') })
            .clip(true)
        } else {
          SymbolGlyph(row.folder ? $r('sys.symbol.folder') : $r('sys.symbol.doc'))
            .fontSize(30)
            .fontColor([$r('app.color.text_secondary')])
        }
      }
      .width(40)
      .height(40)
      Column({ space: 2 }) {
        Text(row.name)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.meta(row))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (row.excerpt) {
          Text(row.excerpt)
            .fontSize(12)
            .fontFamily('monospace')
            .fontColor($r('app.color.text_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .margin({ top: 2 })
            .backgroundColor($r('app.color.bg_chip'))
            .borderRadius(UI_RADIUS_CONTROL)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (row.folder) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(12)
          .fontColor([$r('app.color.text_tertiary')])
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ top: 8, bottom: 8 })
  }

  @Builder
  item(row: WorkdirEntry, compact: boolean) {
    Column() {
      if (compact) {
        this.listRow(row)
      } else {
        this.gridCell(row)
      }
    }
    .width('100%')
    .clickEffect(UI_LIST_CLICK_EFFECT)
    .onClick((): void => this.open(row))
    .gesture(LongPressGesture().onAction((): void => { this.itemMenuKey = this.rowMenuKey(row); }))
    .bindMenu(this.itemMenuKey === this.rowMenuKey(row), this.itemMenu(row),
      uiMenuOptions((): void => {
        if (this.itemMenuKey === this.rowMenuKey(row)) this.itemMenuKey = '';
      }))
  }

  private atRoot(): boolean {
    return !this.drawing && this.preview === null && !this.searching && !this.path;
  }

  /** 左上角按钮：依次退出圈点、预览、搜索、子目录；根目录时关闭浏览（与原「返回」语义一致）。 */
  private back(): void {
    if (this.drawing) { this.closeDrawing(); }
    else if (this.preview !== null) {
      this.preview = null; ++this.previewSeq;
      this.modelLease?.dispose(); this.modelLease = null;
    }
    else if (this.searching) { this.searching = false; ++this.searchSeq; }
    else if (this.path) this.go(workdirParent(this.path));
    else this.close();
  }

  /** 标题栏：圆形返回 / 关闭，标题 + ⌄（祖先路径），右侧胶囊放搜索与更多；中性底色，不用强调色实心。 */
  @Builder
  header() {
    Row() {
      Row() {
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph(this.atRoot() ? $r('sys.symbol.xmark') : $r('sys.symbol.chevron_left'))
            .fontSize(20)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(44)
        .height(44)
        .backgroundColor($r('app.color.bg_chip'))
        .clickEffect(UI_ICON_CLICK_EFFECT)
        .accessibilityText(this.atRoot() ? '关闭' : '返回')
        .onClick((): void => this.back())
      }
      .width(HEADER_SIDE)
      .justifyContent(FlexAlign.Start)

      Column({ space: 2 }) {
        if (this.preview !== null) {
          Text(this.preview?.name ?? '')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        } else {
          Row({ space: 4 }) {
            Text(workdirName(this.path || this.workdir))
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .flexShrink(1)
            SymbolGlyph($r('sys.symbol.chevron_down'))
              .fontSize(13)
              .fontColor([$r('app.color.text_secondary')])
          }
          .constraintSize({ minHeight: 44 })
          .padding({ left: 8, right: 8 })
          .borderRadius(UI_RADIUS_PILL)
          .clickEffect(UI_ICON_CLICK_EFFECT)
          .accessibilityText(workdirName(this.path || this.workdir))
          .onClick((): void => {
            uiOverlayTrace('workdir-path', 'open');
            this.headerMenu = 'path';
          })
          .bindMenu(this.headerMenu === 'path', this.pathMenu(),
            uiMenuOptions((): void => { if (this.headerMenu === 'path') this.headerMenu = ''; }, Placement.Bottom,
              'workdir-path'))
          Text((this.deviceName || this.device) + ' · 工作目录')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)

      Row() {
        if (this.preview === null && !this.drawing) {
          Row() {
            Button({ type: ButtonType.Circle, stateEffect: true }) {
              SymbolGlyph($r('sys.symbol.magnifyingglass'))
                .fontSize(19)
                .fontColor([this.searching ? $r('app.color.accent') : $r('app.color.text_primary')])
            }
            .width(44)
            .height(44)
            .backgroundColor(Color.Transparent)
            .clickEffect(UI_ICON_CLICK_EFFECT)
            .accessibilityText('搜索')
            .onClick((): void => { this.searching = !this.searching; this.search(); })
            Button({ type: ButtonType.Circle, stateEffect: true }) {
              SymbolGlyph($r('sys.symbol.more'))
                .fontSize(19)
                .fontColor([$r('app.color.text_primary')])
            }
            .width(44)
            .height(44)
            .backgroundColor(Color.Transparent)
            .clickEffect(UI_ICON_CLICK_EFFECT)
            .accessibilityText('更多')
            .onClick((): void => {
              uiOverlayTrace('workdir-more', 'open');
              this.headerMenu = 'more';
              const wasSupported = this.showIgnoredSupported === true &&
                this.ignoredScope === AppServices.instance.moduleScope;
              void this.resolveIgnoredCapability().then((): void => {
                if (!wasSupported && this.showIgnoredDirs && this.showIgnoredSupported === true) this.reload();
              });
            })
            .bindMenu(this.headerMenu === 'more', this.moreMenu(),
              uiMenuOptions((): void => { if (this.headerMenu === 'more') this.headerMenu = ''; }, Placement.BottomRight,
                'workdir-more'))
          }
          .height(44)
          .borderRadius(UI_RADIUS_PILL)
          .backgroundColor($r('app.color.bg_chip'))
        }
      }
      .width(HEADER_SIDE)
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .constraintSize({ minHeight: 60 })
  }

  /** 预览底部、搜索切换等文字操作：中性胶囊，44vp 高。 */
  @Builder
  pillButton(label: string, enabled: boolean, action: () => void) {
    Button(label, { type: ButtonType.Capsule, stateEffect: true })
      .height(44)
      .padding({ left: 16, right: 16 })
      .fontSize(14)
      .fontColor($r('app.color.text_primary'))
      .backgroundColor($r('app.color.bg_chip'))
      .enabled(enabled)
      .opacity(enabled ? 1 : 0.45)
      .onClick(action)
  }

  build() {
    Column({ space: 8 }) {
      this.header()
      if (this.drawing) {
        WorkdirAnnotation({ source: this.drawingImage, pixelWidth: this.drawingWidth, pixelHeight: this.drawingHeight,
          cancel: (): void => this.closeDrawing(),
          attach: (bytes: ArrayBuffer): boolean => this.current() && (this.annotate?.(bytes) ?? false)
        }).layoutWeight(1)
      } else if (this.preview !== null) {
        Column() { this.previewContent() }.width('100%').layoutWeight(1)
          .gesture(SwipeGesture({ direction: SwipeDirection.Horizontal })
            .onAction((event: GestureEvent): void => {
              if (this.previewKind !== 'model') this.pagePreview(Math.abs(event.angle) < 90 ? -1 : 1);
            }))
        Row({ space: 8 }) {
          this.pillButton('上一项', true, (): void => this.pagePreview(-1))
          this.pillButton(this.sharing ? '准备中…' : '导出／分享', !this.sharing,
            (): void => { if (this.preview !== null) void this.share(this.preview); })
          if (this.previewKind === 'image' && this.annotate !== undefined) {
            this.pillButton(this.drawingBusy ? '准备中…' : '圈点', !this.drawingBusy && !!this.previewUrl,
              (): void => { void this.openDrawing(); })
          }
          this.pillButton('下一项', true, (): void => this.pagePreview(1))
        }.width('100%').justifyContent(FlexAlign.Center)
      } else {
        if (this.searching) {
          Row({ space: 8 }) {
            TextInput({ text: this.query, placeholder: '搜索工作目录' }).layoutWeight(1)
              .height(44)
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_placeholder'))
              .caretColor($r('app.color.accent'))
              .backgroundColor($r('app.color.bg_chip'))
              .borderRadius(UI_RADIUS_PILL)
              .onChange((value: string): void => { this.query = value; this.search(); })
            this.pillButton(this.contents ? '搜文件名' : '搜内容', true,
              (): void => { this.contents = !this.contents; this.search(); })
          }
        }
        if (this.searching && this.contents && this.searchSummary) {
          Text(this.searchSummary).fontSize(12).fontColor($r('app.color.text_secondary'))
        }
        if (this.error) {
          Text(this.error).fontColor($r('app.color.text_secondary')).onClick((): void => this.reload())
        }
        if (this.loading && this.entries.length === 0) {
          LoadingProgress().width(28).height(28)
          Blank()
        } else if (this.listMode || this.searching) {
          List() {
            ForEach(this.rows(), (row: WorkdirEntry) => {
              ListItem() { this.item(row, true) }
            }, (row: WorkdirEntry): string => row.path + ':' + row.line + ':' + row.modified)
          }.width('100%').layoutWeight(1).cachedCount(5)
            .divider({ strokeWidth: 0.5, color: $r('app.color.border'), startMargin: 52 })
        } else {
          Grid() {
            ForEach(this.rows(), (row: WorkdirEntry) => {
              GridItem() { this.item(row, false) }
                  .onVisibleAreaChange([0, 0.25], (visible: boolean, ratio: number): void => {
                    this.thumbnailVisible(row, visible && ratio >= 0.25);
                  })
            }, (row: WorkdirEntry): string => row.path + ':' + row.modified)
          }.columnsTemplate('1fr '.repeat(this.columns).trim()).rowsGap(8).width('100%').layoutWeight(1).cachedCount(5)
        }
        if (!this.searching) {
          Text(this.entries.filter((row: WorkdirEntry): boolean => row.folder).length + ' 个文件夹、' +
            this.entries.filter((row: WorkdirEntry): boolean => !row.folder).length + ' 个文件')
            .fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          Text(this.watching ? '已连接 · 即时同步' : '未启用即时同步')
            .fontSize(12).fontColor($r('app.color.text_secondary'))
        }
      }
    }.width('100%').height('100%').padding(16)
      .onAreaChange((_old: Area, next: Area): void => {
        this.columns = Math.min(6, Math.max(3, Math.floor(Number(next.width) / 130)));
      })
  }
}
