/**
 * 会话最近消息的可丢弃本地快照。
 *
 * - 按账号、设备、会话隔离，只保存与最新历史页一致的最近窗口；
 * - 保留 RemoteMessage 的结构化字段，只剥离 base64 / data URI 等大块媒体字节；
 * - 本地快照只负责冷启动恢复，远端 messages:list 始终负责权威对账。
 */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { SecureStore } from '../storage/SecureStore';
import { RemoteMessage, parseMessage, sortMessagesAsc } from '../tasks/TaskModels';

const KEY = 'message.session.snapshot.v1';
export const MAX_CACHED_MESSAGE_SESSIONS = 12;
export const MAX_CACHED_SESSION_MESSAGES = 80;
const MAX_CACHE_BYTES = 4 * 1024 * 1024;
const MAX_CONTENT_CHARS = 200000;
const MAX_CONTENT_DEPTH = 12;
const PERSIST_DEBOUNCE_MS = 600;
const HISTORY_FILE_LIMIT = 12 * 1024 * 1024;
const HISTORY_MESSAGE_LIMIT = 1500;
const HISTORY_DIRECTORY = 'cindy-message-history-v1';

export class CachedSessionMessages {
  deviceId: string = '';
  sessionId: string = '';
  updatedAt: number = 0;
  messages: RemoteMessage[] = [];
}

export class CachedHistoryWindow {
  messages: RemoteMessage[] = [];
  hasMore: boolean = false;
}

function utf8ByteLength(value: string): number {
  let bytes = 0;
  for (let i = 0; i < value.length; i++) {
    const code = value.codePointAt(i) ?? 0;
    if (code > 0xffff) i += 1;
    bytes += code <= 0x7f ? 1 : (code <= 0x7ff ? 2 : (code <= 0xffff ? 3 : 4));
  }
  return bytes;
}

function messageKey(message: RemoteMessage): string {
  if (message.id.length > 0) return message.id;
  if (message.clientId.length > 0) return message.clientId;
  return `${message.role}:${message.createdAt}`;
}

function sanitizeString(value: string, depth: number): string {
  if (value.startsWith('data:') && value.indexOf(';base64,') >= 0) return '';
  if (value.length <= MAX_CONTENT_CHARS && !(value.length > 16000 && value.indexOf('base64') >= 0)) {
    return value;
  }
  const trimmed = value.trim();
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    try {
      const parsed = JSON.parse(value) as Object;
      const sanitized = sanitizeValue(parsed, depth + 1);
      return sanitized === undefined ? '' : JSON.stringify(sanitized);
    } catch (e) {
      // 非 JSON 超长正文保守截断；正常消息不会触发此兜底。
    }
  }
  return value.slice(0, MAX_CONTENT_CHARS);
}

function sanitizeValue(value: Object | undefined, depth: number): Object | undefined {
  if (value === undefined || depth > MAX_CONTENT_DEPTH) return undefined;
  if (typeof value === 'string') return sanitizeString(value as string, depth);
  if (typeof value === 'number' || typeof value === 'boolean') return value;
  if (Array.isArray(value)) {
    const source = value as Object[];
    const out: Object[] = [];
    for (let i = 0; i < source.length; i++) {
      const next = sanitizeValue(source[i], depth + 1);
      if (next !== undefined) out.push(next);
    }
    return out;
  }
  if (value === null || typeof value !== 'object') return value;
  const source = value as Record<string, Object>;
  const out: Record<string, Object> = {};
  const keys = Object.keys(source);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    if (key === 'base64') continue;
    const next = sanitizeValue(source[key], depth + 1);
    if (next !== undefined) out[key] = next;
  }
  return out;
}

function messageRecord(message: RemoteMessage): Record<string, Object> {
  const out: Record<string, Object> = {};
  if (message.id.length > 0) out['id'] = message.id;
  if (message.clientId.length > 0) out['clientId'] = message.clientId;
  if (message.sessionId.length > 0) out['sessionId'] = message.sessionId;
  if (message.rowid > 0) out['rowid'] = message.rowid;
  out['role'] = message.role;
  const content = sanitizeValue(message.content, 0);
  if (content !== undefined) out['content'] = content;
  if (message.toolUseId.length > 0) out['toolUseId'] = message.toolUseId;
  out['createdAt'] = message.createdAt;
  if (message.systemCardType.length > 0) out['systemCardType'] = message.systemCardType;
  const systemCardData = sanitizeValue(message.systemCardData, 0);
  if (systemCardData !== undefined && Object.keys(systemCardData as Record<string, Object>).length > 0) {
    out['systemCardData'] = systemCardData;
  }
  const agentMeta = sanitizeValue(message.agentMeta, 0);
  if (agentMeta !== undefined && Object.keys(agentMeta as Record<string, Object>).length > 0) {
    out['agentMeta'] = agentMeta;
  }
  if (message.hasTurnCompleted) out['turnCompleted'] = message.turnCompleted;
  else if (message.turnCompleted) out['turnCompleted'] = true;
  if (message.terminalPlanSnapshot) out['terminalPlanSnapshot'] = true;
  if (message.terminalPlanAtMs > 0) out['terminalPlanAtMs'] = message.terminalPlanAtMs;
  if (message.isStreaming) out['isStreaming'] = true;
  if (message.localOnly) out['localOnly'] = true;
  return out;
}

export function normalizeSessionCacheMessages(
  input: RemoteMessage[],
  limit: number = MAX_CACHED_SESSION_MESSAGES,
): RemoteMessage[] {
  const byKey = new Map<string, RemoteMessage>();
  for (let i = 0; i < input.length; i++) {
    const source = input[i];
    if (source.createdAt.length === 0 || (source.id.length === 0 && source.clientId.length === 0)) continue;
    const parsed = parseMessage(messageRecord(source));
    byKey.set(messageKey(parsed), parsed);
  }
  const out: RemoteMessage[] = [];
  byKey.forEach((message: RemoteMessage) => out.push(message));
  out.sort(sortMessagesAsc);
  const safeLimit = Math.max(1, Math.min(MAX_CACHED_SESSION_MESSAGES, Math.floor(limit)));
  return out.slice(Math.max(0, out.length - safeLimit));
}

function normalizeEntries(input: CachedSessionMessages[]): CachedSessionMessages[] {
  const byKey = new Map<string, CachedSessionMessages>();
  for (let i = 0; i < input.length; i++) {
    const source = input[i];
    if (source.deviceId.length === 0 || source.sessionId.length === 0) continue;
    const messages = normalizeSessionCacheMessages(source.messages);
    if (messages.length === 0) continue;
    const entry = new CachedSessionMessages();
    entry.deviceId = source.deviceId;
    entry.sessionId = source.sessionId;
    entry.updatedAt = source.updatedAt > 0 ? source.updatedAt : Date.now();
    entry.messages = messages;
    byKey.set(`${entry.deviceId}\u0000${entry.sessionId}`, entry);
  }
  const out: CachedSessionMessages[] = [];
  byKey.forEach((entry: CachedSessionMessages) => out.push(entry));
  out.sort((a: CachedSessionMessages, b: CachedSessionMessages) => b.updatedAt - a.updatedAt);
  return out.slice(0, MAX_CACHED_MESSAGE_SESSIONS);
}

function encodeSnapshot(accountId: string, entries: CachedSessionMessages[]): string {
  const rows: Object[] = [];
  for (let i = 0; i < entries.length; i++) {
    const row: Record<string, Object> = {};
    row['deviceId'] = entries[i].deviceId;
    row['sessionId'] = entries[i].sessionId;
    row['updatedAt'] = entries[i].updatedAt;
    const messages: Object[] = [];
    for (let j = 0; j < entries[i].messages.length; j++) {
      messages.push(messageRecord(entries[i].messages[j]));
    }
    row['messages'] = messages;
    rows.push(row);
  }
  const root: Record<string, Object> = {};
  root['version'] = 1;
  root['accountId'] = accountId;
  root['sessions'] = rows;
  return JSON.stringify(root);
}

/** 空字符串表示没有内容；null 表示即使收缩后仍超限，应保留上一份快照。 */
export function serializeSessionMessageSnapshot(
  accountId: string,
  input: CachedSessionMessages[],
): string | null {
  if (accountId.length === 0) return '';
  const entries = normalizeEntries(input);
  if (entries.length === 0) return '';
  let encoded = encodeSnapshot(accountId, entries);
  while (utf8ByteLength(encoded) > MAX_CACHE_BYTES) {
    if (entries.length > 1) {
      entries.pop();
    } else if (entries[0].messages.length > 1) {
      const keep = Math.max(1, Math.floor(entries[0].messages.length / 2));
      entries[0].messages = entries[0].messages.slice(entries[0].messages.length - keep);
    } else {
      return null;
    }
    encoded = encodeSnapshot(accountId, entries);
  }
  return encoded;
}

export function parseSessionMessageSnapshot(raw: string, accountId: string): CachedSessionMessages[] {
  if (raw.length === 0 || accountId.length === 0 || utf8ByteLength(raw) > MAX_CACHE_BYTES) return [];
  try {
    const parsed = JSON.parse(raw) as Object;
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return [];
    const root = parsed as Record<string, Object>;
    if (root['version'] !== 1 || root['accountId'] !== accountId || !Array.isArray(root['sessions'])) return [];
    const rows = root['sessions'] as Object[];
    const out: CachedSessionMessages[] = [];
    for (let i = 0; i < rows.length && out.length < MAX_CACHED_MESSAGE_SESSIONS; i++) {
      const rawRow = rows[i];
      if (rawRow === null || typeof rawRow !== 'object' || Array.isArray(rawRow)) continue;
      const row = rawRow as Record<string, Object>;
      const entry = new CachedSessionMessages();
      entry.deviceId = typeof row['deviceId'] === 'string' ? row['deviceId'] as string : '';
      entry.sessionId = typeof row['sessionId'] === 'string' ? row['sessionId'] as string : '';
      entry.updatedAt = typeof row['updatedAt'] === 'number' ? row['updatedAt'] as number : 0;
      const rawMessages = Array.isArray(row['messages']) ? row['messages'] as Object[] : [];
      const messages: RemoteMessage[] = [];
      for (let j = 0; j < rawMessages.length; j++) {
        const rawMessage = rawMessages[j];
        if (rawMessage === null || typeof rawMessage !== 'object' || Array.isArray(rawMessage)) continue;
        messages.push(parseMessage(rawMessage as Record<string, Object>));
      }
      entry.messages = normalizeSessionCacheMessages(messages);
      out.push(entry);
    }
    return normalizeEntries(out);
  } catch (e) {
    return [];
  }
}

export class SessionMessageCacheStore {
  private readonly store: SecureStore = new SecureStore();
  private raw: string = '';
  private accountId: string = '';
  private entries: CachedSessionMessages[] = [];
  private timer: number = -1;
  private initialized: boolean = false;
  private writeEpoch: number = 0;
  private mutation: Promise<void> = Promise.resolve();
  private historyDirectory: string = '';
  private historyPending: Map<string, CachedSessionMessages> = new Map();
  private historyMorePending: Map<string, boolean> = new Map();

  async init(context: common.Context): Promise<void> {
    await this.store.init(context);
    this.historyDirectory = `${context.filesDir}/${HISTORY_DIRECTORY}`;
    this.raw = await this.store.get(KEY, '');
    this.initialized = true;
  }

  setAccountScope(accountId: string): void {
    if (this.accountId !== accountId) {
      this.historyPending.clear();
      this.historyMorePending.clear();
      if (this.timer >= 0) clearTimeout(this.timer);
      this.timer = -1;
      this.writeEpoch += 1;
    }
    this.accountId = accountId;
    this.entries = parseSessionMessageSnapshot(this.raw, accountId);
  }

  read(deviceId: string, sessionId: string): RemoteMessage[] {
    const history = this.readHistory(deviceId, sessionId);
    if (history.messages.length > 0) return history.messages;
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].deviceId === deviceId && this.entries[i].sessionId === sessionId) {
        return normalizeSessionCacheMessages(this.entries[i].messages);
      }
    }
    return [];
  }

  /** 长历史按会话独立存盘；文件内容仍校验账号与设备，旧账号绝不能借哈希碰撞读到内容。 */
  readHistory(deviceId: string, sessionId: string): CachedHistoryWindow {
    const empty = new CachedHistoryWindow();
    if (!this.accountId || !deviceId || !sessionId || !this.historyDirectory) return empty;
    try {
      const path = this.historyPath(this.accountId, deviceId, sessionId);
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      let raw = '';
      try {
        const size = fileIo.statSync(file.fd).size;
        if (size <= 0 || size > HISTORY_FILE_LIMIT) return empty;
        const buffer = new ArrayBuffer(size);
        const read = fileIo.readSync(file.fd, buffer);
        if (read !== size) return empty;
        raw = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buffer));
      } finally {
        fileIo.closeSync(file);
      }
      const root = JSON.parse(raw) as Record<string, Object>;
      if (root['version'] !== 1 || root['accountId'] !== this.accountId
        || root['deviceId'] !== deviceId || root['sessionId'] !== sessionId
        || !Array.isArray(root['messages'])) return empty;
      const rows = root['messages'] as Object[];
      const messages: RemoteMessage[] = [];
      for (let i = 0; i < rows.length && i < HISTORY_MESSAGE_LIMIT; i++) {
        const row = rows[i];
        if (row !== null && typeof row === 'object' && !Array.isArray(row)) {
          messages.push(parseMessage(row as Record<string, Object>));
        }
      }
      messages.sort(sortMessagesAsc);
      const window = new CachedHistoryWindow();
      window.messages = messages;
      window.hasMore = root['hasMore'] === true;
      return window;
    } catch (_error) {
      return empty;
    }
  }

  private historyPath(accountId: string, deviceId: string, sessionId: string): string {
    const identity = JSON.stringify([accountId, deviceId, sessionId]);
    let a = 2166136261;
    let b = 5381;
    for (let i = 0; i < identity.length; i++) {
      a = Math.imul(a ^ identity.charCodeAt(i), 16777619);
      b = Math.imul(b, 33) ^ identity.charCodeAt(i);
    }
    return `${this.historyDirectory}/${(a >>> 0).toString(16)}-${(b >>> 0).toString(16)}.json`;
  }

  save(deviceId: string, sessionId: string, messages: RemoteMessage[], hasMore: boolean = false): void {
    if (!this.initialized || this.accountId.length === 0 || deviceId.length === 0 || sessionId.length === 0) return;
    // 高频 push 这里只截取引用并重排会话；去重、深层净化留到 600ms 去抖后的实际写盘。
    const recent = messages.slice(Math.max(0, messages.length - MAX_CACHED_SESSION_MESSAGES));
    const next: CachedSessionMessages[] = [];
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].deviceId === deviceId && this.entries[i].sessionId === sessionId) continue;
      next.push(this.entries[i]);
    }
    if (recent.length > 0) {
      const entry = new CachedSessionMessages();
      entry.deviceId = deviceId;
      entry.sessionId = sessionId;
      entry.updatedAt = Date.now();
      entry.messages = recent;
      next.push(entry);
    }
    next.sort((a: CachedSessionMessages, b: CachedSessionMessages) => b.updatedAt - a.updatedAt);
    this.entries = next.slice(0, MAX_CACHED_MESSAGE_SESSIONS);
    const history = new CachedSessionMessages();
    history.deviceId = deviceId;
    history.sessionId = sessionId;
    history.messages = messages.slice(Math.max(0, messages.length - HISTORY_MESSAGE_LIMIT));
    this.historyPending.set(`${deviceId}\u0000${sessionId}`, history);
    this.historyMorePending.set(`${deviceId}\u0000${sessionId}`, hasMore);
    this.schedulePersist();
  }

  private persistHistory(): void {
    const accountId = this.accountId;
    if (!accountId || !this.historyDirectory) return;
    const pending = this.historyPending;
    const more = this.historyMorePending;
    this.historyPending = new Map();
    this.historyMorePending = new Map();
    try { fileIo.mkdirSync(this.historyDirectory); } catch (_error) { }
    pending.forEach((entry: CachedSessionMessages, key: string) => {
      const path = this.historyPath(accountId, entry.deviceId, entry.sessionId);
      if (entry.messages.length === 0) {
        try { fileIo.unlinkSync(path); } catch (_error) { }
        return;
      }
      const rows: Object[] = [];
      for (const message of entry.messages) rows.push(messageRecord(message));
      let encoded = JSON.stringify({ version: 1, accountId, deviceId: entry.deviceId,
        sessionId: entry.sessionId, hasMore: more.get(key) === true, messages: rows });
      while (utf8ByteLength(encoded) > HISTORY_FILE_LIMIT && rows.length > 1) {
        rows.splice(0, Math.max(1, Math.floor(rows.length / 4)));
        encoded = JSON.stringify({ version: 1, accountId, deviceId: entry.deviceId,
          sessionId: entry.sessionId, hasMore: true, messages: rows });
      }
      if (utf8ByteLength(encoded) > HISTORY_FILE_LIMIT) return;
      const temp = `${path}.tmp`;
      try {
        const file = fileIo.openSync(temp, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
        try { fileIo.writeSync(file.fd, encoded); } finally { fileIo.closeSync(file); }
        fileIo.renameSync(temp, path);
      } catch (_error) {
        try { fileIo.unlinkSync(temp); } catch (_ignored) { }
      }
    });
  }

  private schedulePersist(): void {
    if (this.timer >= 0) clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      this.timer = -1;
      void this.persistNow();
    }, PERSIST_DEBOUNCE_MS);
  }

  private async persistNow(): Promise<void> {
    if (!this.initialized) return;
    this.persistHistory();
    const serialized = serializeSessionMessageSnapshot(this.accountId, this.entries);
    if (serialized === null || serialized === this.raw) return;
    this.raw = serialized;
    const epoch = this.writeEpoch;
    this.mutation = this.mutation.then(async (): Promise<void> => {
      if (epoch !== this.writeEpoch) return;
      if (serialized.length === 0) await this.store.remove(KEY);
      else await this.store.set(KEY, serialized);
    }).catch(() => {
      // 快照写盘失败不影响远端消息和页面交互。
    });
    await this.mutation;
  }

  async flush(): Promise<void> {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    await this.persistNow();
  }

  async clear(): Promise<void> {
    this.writeEpoch += 1;
    if (this.timer >= 0) clearTimeout(this.timer);
    this.timer = -1;
    this.raw = '';
    this.accountId = '';
    this.entries = [];
    this.historyPending.clear();
    this.historyMorePending.clear();
    if (this.historyDirectory) {
      try {
        const files = fileIo.listFileSync(this.historyDirectory);
        for (const name of files) {
          if (/^[0-9a-f]+-[0-9a-f]+\.json(\.tmp)?$/.test(name)) {
            try { fileIo.unlinkSync(`${this.historyDirectory}/${name}`); } catch (_error) { }
          }
        }
      } catch (_error) { }
    }
    if (!this.initialized) return;
    this.mutation = this.mutation.then(() => this.store.remove(KEY)).catch(() => {
    });
    await this.mutation;
  }
}
