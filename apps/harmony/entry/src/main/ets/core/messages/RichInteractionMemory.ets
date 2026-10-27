/**
 * 富组件回答的本地视图值（输入框、滑块、开关、Tabs 等）。
 *
 * 对齐 `packages/maker-shared/src/richAnswer.ts` 的 RichInteractionMemory：键由宿主按
 * 「账号 / 设备 / 任务 / 消息 / 片段」组成，只做本机视图缓存，绝不发送给模型或同步到其它设备。
 * 上限：256 条、序列化 512 KB、单条 2048 个键或 64 KB。
 */
import { common } from '@kit.AbilityKit';
import { SecureStore } from '../storage/SecureStore';
import { RichValue, richIsRecord, richIsValue } from './RichAnswer';

const ID = /^[a-zA-Z0-9_-]{1,80}$/;
const MAX_ENTRIES = 256;
const MAX_SERIALIZED = 524288;
const MAX_ENTRY_KEYS = 2048;
const MAX_ENTRY_SIZE = 65536;
const WRITE_DEBOUNCE_MS = 200;
export const RICH_MEMORY_STORAGE_KEY = 'cindy.richAnswer.viewState.v1';

export interface RichStateStorage {
  read(): Promise<string>;
  write(serialized: string): Promise<void>;
}

function serializeEntry(values: Map<string, RichValue>): string {
  const fields: string[] = [];
  values.forEach((value: RichValue, key: string) => {
    fields.push(JSON.stringify(key) + ':' + JSON.stringify(value));
  });
  return '{' + fields.join(',') + '}';
}

export class RichInteractionMemory {
  private entries: Map<string, Map<string, RichValue>> = new Map();
  private listeners: Set<() => void> = new Set();
  private loading: Promise<void> | undefined = undefined;
  private timer: number = -1;
  private writes: Promise<void> = Promise.resolve();
  private storage: RichStateStorage | undefined;

  constructor(storage?: RichStateStorage) {
    this.storage = storage;
  }

  get(key: string): Map<string, RichValue> {
    const values = this.entries.get(key);
    return values !== undefined ? values : new Map();
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return (): void => {
      this.listeners.delete(listener);
    };
  }

  private notify(): void {
    this.listeners.forEach((listener: () => void) => listener());
  }

  load(): Promise<void> {
    if (this.loading === undefined) this.loading = this.hydrate();
    return this.loading;
  }

  private async hydrate(): Promise<void> {
    const storage = this.storage;
    if (storage === undefined) return;
    try {
      const raw = await storage.read();
      if (raw.length === 0 || raw.length > MAX_SERIALIZED) return;
      const stored = parseStoredEntries(raw);
      if (stored === null) return;
      // 慢读取不能覆盖读取期间用户已经输入的值。
      this.entries.forEach((edited: Map<string, RichValue>, key: string) => {
        const merged = new Map(stored.get(key) ?? new Map<string, RichValue>());
        edited.forEach((value: RichValue, name: string) => { merged.set(name, value); });
        stored.delete(key);
        stored.set(key, merged);
      });
      this.entries = stored;
      this.trim();
      this.notify();
    } catch (_error) {
      // 视图值恢复失败不能妨碍阅读回答。
    }
  }

  set(key: string, patch: Map<string, RichValue>): Map<string, RichValue> {
    const next = new Map(this.get(key));
    patch.forEach((value: RichValue, name: string) => { next.set(name, value); });
    if (next.size > MAX_ENTRY_KEYS || serializeEntry(next).length > MAX_ENTRY_SIZE) {
      return this.get(key);
    }
    this.entries.delete(key);
    this.entries.set(key, next);
    this.trim();
    this.notify();
    if (this.storage !== undefined) {
      if (this.timer !== -1) clearTimeout(this.timer);
      this.timer = setTimeout(() => {
        this.timer = -1;
        void this.flush();
      }, WRITE_DEBOUNCE_MS);
    }
    return next;
  }

  serialize(): string {
    const pairs: string[] = [];
    this.entries.forEach((values: Map<string, RichValue>, key: string) => {
      pairs.push('[' + JSON.stringify(key) + ',' + serializeEntry(values) + ']');
    });
    return '{"version":1,"entries":[' + pairs.join(',') + ']}';
  }

  private trim(): void {
    while (this.entries.size > MAX_ENTRIES || this.serialize().length > MAX_SERIALIZED) {
      const oldest = this.entries.keys().next();
      if (oldest.done) return;
      this.entries.delete(oldest.value);
    }
  }

  async flush(): Promise<void> {
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    await this.load();
    const storage = this.storage;
    if (storage === undefined) return;
    const serialized = this.serialize();
    this.writes = this.writes
      .then(() => storage.write(serialized))
      .catch(() => undefined);
    return this.writes;
  }

  clear(): void {
    this.entries.clear();
    this.notify();
  }
}

/** 解析持久化内容；格式不符时返回 null，单条不合法时丢弃该条。 */
export function parseStoredEntries(raw: string): Map<string, Map<string, RichValue>> | null {
  const parsed = JSON.parse(raw) as Object;
  if (!richIsRecord(parsed)) return null;
  const record = parsed as Record<string, Object>;
  const list = record['entries'];
  if (record['version'] !== 1 || !Array.isArray(list)) return null;
  const pairs = list as Object[];
  const stored: Map<string, Map<string, RichValue>> = new Map();
  for (let i = Math.max(0, pairs.length - MAX_ENTRIES); i < pairs.length; i++) {
    if (!Array.isArray(pairs[i])) continue;
    const pair = pairs[i] as Object[];
    if (typeof pair[0] !== 'string' || !richIsRecord(pair[1])) continue;
    const source = pair[1] as Record<string, Object>;
    const values: Map<string, RichValue> = new Map();
    Object.keys(source).forEach((name: string) => {
      if (ID.test(name) && richIsValue(source[name])) values.set(name, source[name] as RichValue);
    });
    if (serializeEntry(values).length <= MAX_ENTRY_SIZE) stored.set(pair[0] as string, values);
  }
  return stored;
}

/** 复用应用沙箱 Preferences；init 前读写都是空操作。 */
export class SecureStoreRichStateStorage implements RichStateStorage {
  private store: SecureStore = new SecureStore();

  async init(context: common.Context): Promise<void> {
    await this.store.init(context);
  }

  read(): Promise<string> {
    return this.store.get(RICH_MEMORY_STORAGE_KEY, '');
  }

  async write(serialized: string): Promise<void> {
    try {
      await this.store.set(RICH_MEMORY_STORAGE_KEY, serialized);
    } catch (_error) {
      // 存储未初始化或写失败时保留内存值。
    }
  }
}
