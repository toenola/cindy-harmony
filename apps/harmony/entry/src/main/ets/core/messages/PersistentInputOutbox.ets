/**
 * 本机待确认输入的写穿账本。每条输入独立原子替换，进程重启后只恢复为待核对气泡，
 * 绝不根据文件存在自动调用 maker:input:enqueue。
 */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

const MAX_RECORD_BYTES = 2 * 1024 * 1024;
const DIRECTORY_NAME = 'cindy-input-outbox-v1';

function utf8ByteLength(value: string): number {
  let bytes = 0;
  for (let i = 0; i < value.length; i++) {
    const code = value.codePointAt(i) ?? 0;
    if (code > 0xffff) i += 1;
    bytes += code <= 0x7f ? 1 : (code <= 0x7ff ? 2 : (code <= 0xffff ? 3 : 4));
  }
  return bytes;
}

export class PersistedInput {
  accountId: string = '';
  deviceId: string = '';
  sessionId: string = '';
  item: Record<string, Object> = {};
  sendStarted: boolean = false;
}

function recordName(accountId: string, deviceId: string, sessionId: string, clientId: string): string {
  const identity = JSON.stringify([accountId, deviceId, sessionId, clientId]);
  let a = 2166136261;
  let b = 5381;
  for (let i = 0; i < identity.length; i++) {
    a = Math.imul(a ^ identity.charCodeAt(i), 16777619);
    b = Math.imul(b, 33) ^ identity.charCodeAt(i);
  }
  return `${(a >>> 0).toString(16)}-${(b >>> 0).toString(16)}.json`;
}

export class PersistentInputOutbox {
  private directory: string = '';
  private accountId: string = '';
  private records: Map<string, PersistedInput> = new Map();

  init(context: common.Context): void {
    this.directory = `${context.filesDir}/${DIRECTORY_NAME}`;
    try { fileIo.mkdirSync(this.directory); } catch (_error) { }
  }

  setAccountScope(accountId: string): void {
    this.accountId = accountId;
    this.records.clear();
    if (!accountId || !this.directory) return;
    let names: string[] = [];
    try { names = fileIo.listFileSync(this.directory); } catch (_error) { return; }
    for (const name of names) {
      if (!/^[0-9a-f]+-[0-9a-f]+\.json$/.test(name)) continue;
      try {
        const path = `${this.directory}/${name}`;
        const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
        let raw = '';
        try {
          const size = fileIo.statSync(file.fd).size;
          if (size <= 0 || size > MAX_RECORD_BYTES) continue;
          const buffer = new ArrayBuffer(size);
          if (fileIo.readSync(file.fd, buffer) !== size) continue;
          raw = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buffer));
        } finally { fileIo.closeSync(file); }
        const parsed = JSON.parse(raw) as Record<string, Object>;
        if (parsed['version'] !== 1 || parsed['accountId'] !== accountId
          || typeof parsed['deviceId'] !== 'string' || typeof parsed['sessionId'] !== 'string'
          || parsed['item'] === null || typeof parsed['item'] !== 'object') continue;
        const source = parsed['item'] as Record<string, Object>;
        if (typeof source['clientId'] !== 'string' || typeof source['text'] !== 'string'
          || typeof source['persistedContent'] !== 'string') continue;
        const record = new PersistedInput();
        record.accountId = accountId;
        record.deviceId = parsed['deviceId'] as string;
        record.sessionId = parsed['sessionId'] as string;
        record.item = source;
        record.sendStarted = parsed['sendStarted'] === true;
        if (name !== recordName(accountId, record.deviceId, record.sessionId, source['clientId'] as string)) continue;
        this.records.set(name, record);
      } catch (_error) { }
    }
  }

  forSession(deviceId: string, sessionId: string): PersistedInput[] {
    const rows: PersistedInput[] = [];
    this.records.forEach((record: PersistedInput) => {
      if (record.accountId === this.accountId && record.deviceId === deviceId && record.sessionId === sessionId) {
        rows.push(record);
      }
    });
    rows.sort((a: PersistedInput, b: PersistedInput) => {
      const aChat = a.item['chatMessage'] as Record<string, Object>;
      const bChat = b.item['chatMessage'] as Record<string, Object>;
      return String(aChat?.['createdAt'] ?? '').localeCompare(String(bChat?.['createdAt'] ?? ''));
    });
    return rows;
  }

  put(deviceId: string, sessionId: string, item: Record<string, Object>, sendStarted: boolean): void {
    // 独立的纯逻辑 Local Test 不启动 Ability，也不装配文件存储。
    // 正式 AppServices.init 总是先调用 init，落盘错误仍会阻止发送前清空输入。
    if (!this.directory) return;
    const clientId = item['clientId'];
    if (!this.accountId || !deviceId || !sessionId || typeof clientId !== 'string' || !clientId) {
      throw new Error('发件箱未就绪，请稍后重试');
    }
    const record = new PersistedInput();
    record.accountId = this.accountId;
    record.deviceId = deviceId;
    record.sessionId = sessionId;
    record.item = item;
    record.sendStarted = sendStarted;
    const raw = JSON.stringify({ version: 1, accountId: record.accountId,
      deviceId, sessionId, item, sendStarted });
    if (utf8ByteLength(raw) > MAX_RECORD_BYTES) throw new Error('待发送内容过大，无法保存发件箱');
    const name = recordName(this.accountId, deviceId, sessionId, clientId as string);
    const path = `${this.directory}/${name}`;
    const temp = `${path}.tmp`;
    try {
      const file = fileIo.openSync(temp, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try { fileIo.writeSync(file.fd, raw); } finally { fileIo.closeSync(file); }
      fileIo.renameSync(temp, path);
      this.records.set(name, record);
    } catch (_error) {
      try { fileIo.unlinkSync(temp); } catch (_ignored) { }
      throw new Error('发件箱保存失败，请稍后重试');
    }
  }

  remove(deviceId: string, sessionId: string, clientId: string): void {
    if (!this.accountId || !this.directory) return;
    const name = recordName(this.accountId, deviceId, sessionId, clientId);
    this.records.delete(name);
    try { fileIo.unlinkSync(`${this.directory}/${name}`); } catch (_error) { }
  }

  clear(): void {
    this.records.clear();
    this.accountId = '';
    if (!this.directory) return;
    try {
      const names = fileIo.listFileSync(this.directory);
      for (const name of names) {
        if (/^[0-9a-f]+-[0-9a-f]+\.json(\.tmp)?$/.test(name)) {
          try { fileIo.unlinkSync(`${this.directory}/${name}`); } catch (_error) { }
        }
      }
    } catch (_error) { }
  }
}
