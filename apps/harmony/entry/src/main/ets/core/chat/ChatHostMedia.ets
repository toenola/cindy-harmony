/** Original computer attachment projection. References stay opaque, including their
 * sessionId/remoteHostId/workdir query; a group ID never becomes a cloud room ID. */
export interface ChatHostAttachment {
  id: string; name: string; category: string; mimeType: string; size: number;
  reference: string; state: string; annotated: boolean;
}
export type ChatHostMediaResolver = (deviceId: string, reference: string, thumbnail: boolean) => Promise<string>;
export type ChatHostMediaOpen = (deviceId: string, reference: string, name: string, mime: string) => void;

export function chatHostAttachments(value: Object | undefined): ChatHostAttachment[] {
  if (!Array.isArray(value)) return [];
  const result: ChatHostAttachment[] = [];
  (value as Object[]).slice(0, 20).forEach((raw: Object): void => {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return;
    const row = raw as Record<string, Object>;
    if (typeof row['id'] !== 'string' || !(row['id'] as string).length) return;
    const url = typeof row['url'] === 'string' ? row['url'] as string : '';
    const path = typeof row['path'] === 'string' ? row['path'] as string : '';
    // Same older-host fallback as BotGroupMessageAttachments; never derive a path
    // from a filename, group project directory, process card or message body.
    let reference = url;
    if (!reference && path && path.length <= 16384 && !/[\x00-\x1f]/.test(path)) {
      reference = `xdt-file://open?path=${encodeURIComponent(path)}`;
    }
    if (reference.length > 32768 || /[\x00-\x20]/.test(reference)
      || !/^(?:https?|cindy-media|xdt-image|xdt-file|cindy-oss-attach|xdt-oss-attach):\/\//i.test(reference)) reference = '';
    const category = typeof row['category'] === 'string' ? row['category'] as string : 'file';
    const state = row['state'] === undefined || row['state'] === null ? '' : row['state'] === 'loading' ? 'loading' : 'unavailable';
    result.push({ id: (row['id'] as string).slice(0, 256), name: typeof row['name'] === 'string' ? (row['name'] as string).slice(0, 1024) : '',
      category: ['image', 'pdf', 'text', 'office', 'file'].includes(category) ? category : 'file',
      mimeType: typeof row['mimeType'] === 'string' ? (row['mimeType'] as string).slice(0, 256) : '',
      size: typeof row['size'] === 'number' && Number.isFinite(row['size'] as number) && (row['size'] as number) >= 0 ? row['size'] as number : 0,
      reference, state, annotated: row['annotated'] === true });
  });
  return result;
}

interface ChatHostMediaCache { url: string; until: number; bytes: number }
class ChatHostMediaJob {
  key: string; device: string; reference: string; thumbnail: boolean;
  generation: number;
  wanted: Array<() => boolean> = [];
  succeed: (value: string) => void = (_value: string): void => {};
  fail: (error: Error) => void = (_error: Error): void => {};
  promise: Promise<string>;
  constructor(key: string, device: string, reference: string, thumbnail: boolean, generation: number, wanted: () => boolean) {
    this.key = key; this.device = device; this.reference = reference; this.thumbnail = thumbnail; this.wanted.push(wanted);
    this.generation = generation;
    this.promise = new Promise<string>((resolve, reject) => { this.succeed = resolve; this.fail = reject; });
  }
}
/** Instance-only passive reads: max two transfers, deduplication, visibility checks,
 * 20s failure cooldown, 16MiB/128-result cache. No timer or automatic retry.
 * Root owns the media transfer/temporary-object lease; this layer only holds URLs. */
export class ChatHostThumbnailQueue {
  private resolve: ChatHostMediaResolver;
  private current: () => boolean;
  private now: () => number;
  private released: boolean = false;
  private generation: number = 0;
  private active: number = 0;
  private bytes: number = 0;
  private jobs: Map<string, ChatHostMediaJob> = new Map();
  private pending: ChatHostMediaJob[] = [];
  private cache: Map<string, ChatHostMediaCache> = new Map();
  private failed: Map<string, number> = new Map();
  constructor(resolve: ChatHostMediaResolver, current: () => boolean, now: () => number = (): number => Date.now()) {
    this.resolve = resolve; this.current = current; this.now = now;
  }
  request(device: string, reference: string, thumbnail: boolean, wanted: () => boolean = (): boolean => true): Promise<string> {
    if (this.released || !this.current() || !wanted()) return Promise.reject(new Error('OWNER_CHANGED'));
    const key = JSON.stringify([device, reference, thumbnail]), cached = this.cache.get(key);
    if (cached && cached.until > this.now()) {
      this.cache.delete(key); this.cache.set(key, cached); return Promise.resolve(cached.url);
    }
    if (cached) { this.bytes -= cached.bytes; this.cache.delete(key); }
    const existing = this.jobs.get(key);
    if (existing) { existing.wanted = existing.wanted.filter((visible: () => boolean): boolean => visible()); existing.wanted.push(wanted); return existing.promise; }
    if ((this.failed.get(key) ?? 0) > this.now()) return Promise.reject(new Error('MEDIA_UNAVAILABLE'));
    if (!device || !reference || this.jobs.size >= 64) return Promise.reject(new Error('MEDIA_UNAVAILABLE'));
    const job = new ChatHostMediaJob(key, device, reference, thumbnail, this.generation, wanted);
    this.jobs.set(key, job); this.pending.push(job); this.drain(); return job.promise;
  }
  /** A user's explicit retry can bypass passive failure cooldown and an Image URL
   * that failed native decoding. It still coalesces with a live request. */
  retry(device: string, reference: string, thumbnail: boolean, wanted: () => boolean = (): boolean => true): Promise<string> {
    const key = JSON.stringify([device, reference, thumbnail]), old = this.cache.get(key);
    if (old) { this.bytes -= old.bytes; this.cache.delete(key); }
    this.failed.delete(key); return this.request(device, reference, thumbnail, wanted);
  }
  /** Root replaces/disposes its temporary media lease on background. Drop URLs and
   * fence even in-flight results, including if foreground resumes before they finish. */
  reset(): void {
    this.generation++;
    this.jobs.forEach((job: ChatHostMediaJob): void => job.fail(new Error('OWNER_CHANGED')));
    this.jobs.clear(); this.pending = []; this.cache.clear(); this.failed.clear(); this.bytes = 0;
  }
  release(): void { if (this.released) return; this.released = true; this.reset(); }
  private drain(): void {
    while (!this.released && this.active < 2 && this.pending.length) {
      const job = this.pending.shift(); if (!job) return;
      if (!this.current() || !job.wanted.some((wanted: () => boolean): boolean => wanted())) {
        this.jobs.delete(job.key); job.fail(new Error('MEDIA_NOT_VISIBLE')); continue;
      }
      this.active++; this.run(job);
    }
  }
  private async run(job: ChatHostMediaJob): Promise<void> {
    try {
      const url = await this.resolve(job.device, job.reference, job.thumbnail);
      if (this.released || job.generation !== this.generation || !this.current()) throw new Error('OWNER_CHANGED');
      if (!url) throw new Error('MEDIA_UNAVAILABLE');
      const bytes = url.length * 2 + job.reference.length * 2 + 256;
      if (bytes <= 16 * 1024 * 1024) {
        const value: ChatHostMediaCache = { url, bytes, until: this.now() + 60000 };
        this.cache.set(job.key, value); this.bytes += bytes;
        while (this.bytes > 16 * 1024 * 1024 || this.cache.size > 128) {
          const first = this.cache.keys().next(); if (first.done) break;
          const old = this.cache.get(first.value); this.cache.delete(first.value); this.bytes -= old?.bytes ?? 0;
        }
      }
      this.failed.delete(job.key); job.succeed(url);
    } catch (_) {
      if (!this.released && job.generation === this.generation && this.current()) {
        this.failed.set(job.key, this.now() + 20000);
        if (this.failed.size > 128) { const first = this.failed.keys().next(); if (!first.done) this.failed.delete(first.value); }
      }
      job.fail(new Error(this.released || job.generation !== this.generation || !this.current() ? 'OWNER_CHANGED' : 'MEDIA_UNAVAILABLE'));
    } finally { if (this.jobs.get(job.key) === job) this.jobs.delete(job.key); this.active--; this.drain(); }
  }
}

export class ChatHostMediaStrings { attachment: string = ''; loading: string = ''; unavailable: string = ''; onComputer: string = ''; open: string = ''; }
export function chatHostMediaStrings(locale: string): ChatHostMediaStrings {
  let words: string[];
  if (locale.startsWith('zh-TW') || locale.startsWith('zh-Hant')) words = ['附件', '正在載入', '暫時無法載入', '檔案在電腦上，目前無法取得', '開啟'];
  else if (locale.startsWith('zh')) words = ['附件', '正在加载', '暂时无法加载', '文件在电脑上，目前无法获取', '打开'];
  else if (locale.startsWith('ja')) words = ['添付ファイル', '読み込み中', '現在読み込めません', 'ファイルはコンピューターにあります', '開く'];
  else if (locale.startsWith('ko')) words = ['첨부 파일', '불러오는 중', '지금 불러올 수 없습니다', '파일이 컴퓨터에 있습니다', '열기'];
  else words = ['Attachment', 'Loading', 'Temporarily unavailable', 'The file is on the computer and cannot be fetched yet', 'Open'];
  const copy = new ChatHostMediaStrings(); copy.attachment = words[0]; copy.loading = words[1]; copy.unavailable = words[2]; copy.onComputer = words[3]; copy.open = words[4]; return copy;
}
