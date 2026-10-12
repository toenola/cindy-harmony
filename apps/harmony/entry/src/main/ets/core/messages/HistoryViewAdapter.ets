/** Host-owned reading projections. Does not change persisted messages or transcripts. */
import { DlClient, DlInvokeOptions } from '../device-link/DlClient';
import { unwrapInvokeResult } from '../tasks/TaskStore';
import { RemoteMessage, parseMessage, readBool, readNum, readObj, readStr, recordOrEmpty } from '../tasks/TaskModels';

export const HISTORY_PLACEHOLDER_PREFIX = 'history-work:';

export class HistoryProjectionPage {
  messages: RemoteMessage[] = [];
  nextCursor: string = '';
  hasMore: boolean = false;
}

/** Mobile retains a prefix only when the new first source has an exact boundary. */
export function projectedHistoryPrefix(current: RemoteMessage[], latest: RemoteMessage[], hasMore: boolean): RemoteMessage[] {
  if (!hasMore || latest.length === 0) return [];
  const first = latest[0];
  const source = readStr(readObj(first.agentMeta, 'historyWork'), 'firstMessageId') || first.id;
  const boundary = current.findIndex((row: RemoteMessage) => row.id === first.id
    || (readStr(readObj(row.agentMeta, 'historyWork'), 'firstMessageId') || row.id) === source);
  return boundary > 0 ? current.slice(0, boundary) : [];
}

export function historyViewUnavailable(message: string): boolean {
  return /CHANNEL_NOT_ALLOWED|UNSUPPORTED_CAPABILITY|not registered|No handler/i.test(message);
}

export function parseHistoryProjection(value: Object | undefined, sessionId: string): HistoryProjectionPage {
  const root = recordOrEmpty(value);
  if (root['version'] !== 1 || !Array.isArray(root['items'])) throw new Error('Invalid history view');
  const page = new HistoryProjectionPage();
  page.nextCursor = readStr(root, 'nextCursor');
  page.hasMore = readBool(root, 'hasMore', false);
  appendProjectionItems(root['items'], sessionId, page.messages);
  if (page.hasMore && page.nextCursor.length === 0) throw new Error('History cursor did not advance');
  return page;
}

function appendProjectionItems(value: Object, sessionId: string, rows: RemoteMessage[], depth: number = 0): void {
  if (!Array.isArray(value) || depth > 32) throw new Error('Invalid history items');
  for (const raw of value as Object[]) {
    const item = recordOrEmpty(raw);
    if (item['type'] === 'messages' && Array.isArray(item['messages'])) {
      for (const message of item['messages'] as Object[]) rows.push(parseMessage(recordOrEmpty(message)));
    } else if (item['type'] === 'work') {
      if (Array.isArray(item['children'])) {
        appendProjectionItems(item['children'], sessionId, rows, depth + 1);
        continue;
      }
      const summary = readObj(item, 'summary');
      const key = readStr(summary, 'key');
      if (!key || !readStr(summary, 'firstMessageId') || !readStr(summary, 'lastMessageId')) {
        throw new Error('Invalid history work reference');
      }
      const row = new RemoteMessage();
      row.id = HISTORY_PLACEHOLDER_PREFIX + key;
      row.clientId = row.id;
      row.sessionId = sessionId;
      row.role = 'thinking';
      const start = readNum(summary, 'startedAtMs', 0);
      row.createdAt = new Date(Number.isFinite(start) ? start : 0).toISOString();
      const content: Record<string, Object> = {};
      content['text'] = '';
      content['durationMs'] = Math.max(0, readNum(summary, 'endedAtMs', start) - start);
      row.content = content;
      row.agentMeta['historyWork'] = summary;
      rows.push(row);
    } else throw new Error('Unsupported history item');
  }
}

export class HistoryViewAdapter {
  private cursors: Map<string, string> = new Map();
  private generations: Map<string, number> = new Map();
  private pending: Map<string, Promise<HistoryProjectionPage>> = new Map();
  private disabled: Set<string> = new Set();
  private connectionIds: Map<string, string> = new Map();
  private intents: Map<string, Map<string, Record<string, Object>>> = new Map();
  private intentWrites: Map<string, Promise<void>> = new Map();
  private key(deviceId: string, sessionId: string): string { return JSON.stringify([deviceId, sessionId]); }

  replaceCursor(deviceId: string, sessionId: string, cursor: string): void {
    this.cursors.set(this.key(deviceId, sessionId), cursor);
  }

  async release(client: DlClient, deviceId: string, sessionId: string, workKey: string = ''): Promise<void> {
    const key = this.key(deviceId, sessionId);
    const intents = this.intents.get(key);
    if (intents === undefined) return;
    if (workKey) intents.delete(workKey); else intents.clear();
    const connection = client.connectionIdentity(deviceId);
    const previous = this.intentWrites.get(key) ?? Promise.resolve();
    const write = previous.catch(() => {}).then(async (): Promise<void> => {
      if (connection !== client.connectionIdentity(deviceId)) return;
      const refs: Object[] = [];
      (this.intents.get(key) ?? new Map<string, Record<string, Object>>())
        .forEach((ref: Record<string, Object>) => refs.push(ref));
      await this.invoke(client, deviceId, 'local-db:messages:view-intent', [sessionId, refs]);
    });
    this.intentWrites.set(key, write);
    try { await write; }
    finally { if (this.intentWrites.get(key) === write) this.intentWrites.delete(key); }
  }

  available(client: DlClient, deviceId: string, sessionId: string): boolean {
    const key = this.key(deviceId, sessionId);
    const connection = client.connectionIdentity(deviceId);
    if (this.connectionIds.get(key) !== connection) {
      this.reset(deviceId, sessionId);
      this.connectionIds.set(key, connection);
    }
    return client.supportsHistoryView(deviceId) && !this.disabled.has(this.key(deviceId, sessionId));
  }

  reset(deviceId: string, sessionId: string): void {
    const key = this.key(deviceId, sessionId);
    this.generations.set(key, (this.generations.get(key) ?? 0) + 1);
    this.cursors.delete(key);
    this.disabled.delete(key);
    this.intents.delete(key);
  }

  clear(): void {
    this.generations.forEach((generation: number, key: string) => this.generations.set(key, generation + 1));
    this.cursors.clear();
    this.disabled.clear();
    this.pending.clear();
    this.intents.clear();
    this.connectionIds.clear();
    this.intentWrites.clear();
  }

  async page(client: DlClient, deviceId: string, sessionId: string, older: boolean, identity: string, isCurrent: () => boolean): Promise<HistoryProjectionPage> {
    const key = this.key(deviceId, sessionId);
    const generation = this.generations.get(key) ?? 0;
    this.generations.set(key, generation);
    const before = older ? this.cursors.get(key) ?? '' : '';
    const requestKey = JSON.stringify([key, generation, identity, before]);
    const existing = this.pending.get(requestKey);
    if (existing !== undefined) return existing;
    const operation = this.readPage(client, deviceId, sessionId, before, generation, older, isCurrent);
    this.pending.set(requestKey, operation);
    try { return await operation; }
    finally { if (this.pending.get(requestKey) === operation) this.pending.delete(requestKey); }
  }

  private async readPage(client: DlClient, deviceId: string, sessionId: string, before: string,
    generation: number, older: boolean, isCurrent: () => boolean): Promise<HistoryProjectionPage> {
    const key = this.key(deviceId, sessionId);
    const options: Record<string, Object> = {};
    if (before) options['before'] = before;
    try {
      const page = parseHistoryProjection(await this.invoke(client, deviceId, 'local-db:messages:view', [sessionId, options]), sessionId);
      if (!isCurrent() || (this.generations.get(key) ?? 0) !== generation) throw new Error('History read superseded');
      if (older && page.hasMore && page.nextCursor === before) throw new Error('History cursor did not advance');
      if (older || !this.cursors.has(key)) this.cursors.set(key, page.nextCursor);
      return page;
    } catch (e) {
      if (e instanceof Error && historyViewUnavailable(e.message)
        && isCurrent() && (this.generations.get(key) ?? 0) === generation) this.disabled.add(key);
      throw e instanceof Error ? e : new Error('History read failed');
    }
  }

  async details(client: DlClient, deviceId: string, sessionId: string,
    summary: Record<string, Object>, isCurrent: () => boolean, onPage: (rows: RemoteMessage[]) => void): Promise<void> {
    if (!isCurrent()) return;
    const key = this.key(deviceId, sessionId);
    const intents = this.intents.get(key) ?? new Map<string, Record<string, Object>>();
    intents.set(readStr(summary, 'key'), summary);
    this.intents.set(key, intents);
    const previous = this.intentWrites.get(key) ?? Promise.resolve();
    const write = previous.catch(() => {}).then(async (): Promise<void> => {
      if (!isCurrent()) return;
      const refs: Object[] = [];
      intents.forEach((ref: Record<string, Object>) => refs.push(ref));
      await this.invoke(client, deviceId, 'local-db:messages:view-intent', [sessionId, refs]);
    });
    this.intentWrites.set(key, write);
    try { await write; }
    finally { if (this.intentWrites.get(key) === write) this.intentWrites.delete(key); }
    let after = '';
    const seen = new Set<string>();
    while (isCurrent()) {
      const options: Record<string, Object> = {};
      if (after) options['after'] = after;
      const root = recordOrEmpty(await this.invoke(client, deviceId, 'local-db:messages:work-details', [sessionId, summary, options]));
      if (!isCurrent()) return;
      if (root['version'] !== 1 || !Array.isArray(root['messages'])) throw new Error('Invalid history details');
      const rows: RemoteMessage[] = [];
      for (const raw of root['messages'] as Object[]) rows.push(parseMessage(recordOrEmpty(raw)));
      onPage(rows);
      if (!readBool(root, 'hasMore', false)) return;
      after = readStr(root, 'nextCursor');
      if (!after || seen.has(after)) throw new Error('History detail cursor did not advance');
      seen.add(after);
    }
  }

  private async invoke(client: DlClient, deviceId: string, channel: string, args: Object[]): Promise<Object | undefined> {
    const options = new DlInvokeOptions(); options.channel = channel; options.args = args;
    return unwrapInvokeResult(await client.invoke(deviceId, options));
  }
}
