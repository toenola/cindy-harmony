/**
 * Harmony 端语音词典只读投影。
 *
 * 词典正本和 CRDT 合并都在桌面端；Harmony 只按 Mobile 的协议拉取/接收快照，
 * 选择一份最新且可证明更完整的快照展示。缓存按账号与桌面设备隔离，登出时清理。
 */

import { common } from '@kit.AbilityKit';
import { SecureStore } from '../storage/SecureStore';

const KEY_PREFIX = 'voice.dictionary.v1.';
const MAX_ENTRIES = 1000;
const MAX_ALIASES = 8;
const MAX_TERM_CHARS = 120;

export class VoiceDictionaryAlias {
  text: string = '';
  count: number = 1;
}

export class VoiceDictionaryEntry {
  text: string = '';
  frequency: number = 1;
  aliases: VoiceDictionaryAlias[] = [];
}

export class VoiceDictionarySnapshot {
  entries: VoiceDictionaryEntry[] = [];
  fetchedAt: number = 0;
  stateVector: Record<string, string> | undefined = undefined;
  emittedAt: number | undefined = undefined;
}

export class VoiceDictionaryEntryView {
  key: string = '';
  text: string = '';
  aliases: string[] = [];
  frequency: number = 1;
}

function normalizeTerm(value: Object | undefined): string {
  if (typeof value !== 'string') return '';
  return (value as string)
    .replace(/\r\n?/g, '\n')
    .split('\n')
    .map((line: string) => line.replace(/\s+/g, ' ').trim())
    .filter((line: string) => line.length > 0)
    .join(' ')
    .slice(0, MAX_TERM_CHARS)
    .trim();
}

function termKey(value: string): string {
  return normalizeTerm(value).toLowerCase();
}

function positiveNumber(value: Object | undefined): number {
  return typeof value === 'number' && Number.isFinite(value as number) && (value as number) > 0
    ? Math.floor(value as number) : 1;
}

function normalizeStateVector(value: Object | undefined): Record<string, string> | undefined {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return undefined;
  }
  const raw = value as Record<string, Object>;
  const out: Record<string, string> = {};
  const keys = Object.keys(raw);
  for (let i = 0; i < keys.length; i++) {
    const stamp = raw[keys[i]];
    if (typeof stamp === 'string' && (stamp as string).length > 0) {
      out[keys[i]] = stamp as string;
    }
  }
  return Object.keys(out).length > 0 ? out : undefined;
}

function parseEntries(value: Object | undefined): VoiceDictionaryEntry[] {
  if (!Array.isArray(value)) return [];
  const rows = value as Object[];
  const entries: VoiceDictionaryEntry[] = [];
  for (let i = 0; i < rows.length && entries.length < MAX_ENTRIES; i++) {
    const raw = rows[i];
    if (raw === undefined || raw === null || typeof raw !== 'object' || Array.isArray(raw)) continue;
    const record = raw as Record<string, Object>;
    const text = normalizeTerm(record['text']);
    if (text.length === 0) continue;
    const entry = new VoiceDictionaryEntry();
    entry.text = text;
    entry.frequency = positiveNumber(record['frequency']);
    const rawAliases = record['aliases'];
    if (Array.isArray(rawAliases)) {
      const aliases = rawAliases as Object[];
      for (let j = 0; j < aliases.length && entry.aliases.length < MAX_ALIASES; j++) {
        const rawAlias = aliases[j];
        if (rawAlias === undefined || rawAlias === null
          || typeof rawAlias !== 'object' || Array.isArray(rawAlias)) continue;
        const alias = rawAlias as Record<string, Object>;
        const aliasText = normalizeTerm(alias['text']);
        if (aliasText.length === 0) continue;
        const item = new VoiceDictionaryAlias();
        item.text = aliasText;
        item.count = positiveNumber(alias['count']);
        entry.aliases.push(item);
      }
    }
    entries.push(entry);
  }
  return entries;
}

/** 解析 desktop 的 `{ ok: true, entries, ... }` 结果；坏响应不进入缓存。 */
export function parseVoiceDictionarySnapshot(value: Object | undefined): VoiceDictionarySnapshot | null {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return null;
  }
  const raw = value as Record<string, Object>;
  if (raw['ok'] !== true) return null;
  const snapshot = new VoiceDictionarySnapshot();
  snapshot.entries = parseEntries(raw['entries']);
  snapshot.fetchedAt = Date.now();
  snapshot.stateVector = normalizeStateVector(raw['stateVector']);
  const emittedAt = raw['emittedAt'];
  if (typeof emittedAt === 'number' && Number.isFinite(emittedAt as number) && (emittedAt as number) > 0) {
    snapshot.emittedAt = Math.floor(emittedAt as number);
  }
  return snapshot;
}

function dominates(a: Record<string, string> | undefined, b: Record<string, string> | undefined): boolean {
  if (a === undefined || b === undefined) return false;
  const keys = Object.keys(b);
  for (let i = 0; i < keys.length; i++) {
    if (a[keys[i]] === undefined || a[keys[i]] < b[keys[i]]) return false;
  }
  return true;
}

/** 同一桌面设备只接收更新鲜的快照；版本向量可证明包含关系时优先。 */
export function isFresherVoiceDictionarySnapshot(
  candidate: VoiceDictionarySnapshot,
  current: VoiceDictionarySnapshot,
): boolean {
  if (candidate.stateVector !== undefined && current.stateVector !== undefined) {
    const candidateDominates = dominates(candidate.stateVector, current.stateVector);
    const currentDominates = dominates(current.stateVector, candidate.stateVector);
    if (candidateDominates !== currentDominates) return candidateDominates;
  } else if (candidate.stateVector !== undefined) {
    return true;
  } else if (current.stateVector !== undefined) {
    return false;
  }
  if (candidate.emittedAt !== undefined && current.emittedAt !== undefined) {
    return candidate.emittedAt > current.emittedAt;
  }
  if (candidate.emittedAt !== undefined) return true;
  if (current.emittedAt !== undefined) return false;
  return candidate.fetchedAt > current.fetchedAt;
}

/** 从各桌面缓存中选择一份完整度最高的快照，避免离线旧快照把已删除词条带回来。 */
export function buildVoiceDictionaryEntryViews(
  snapshots: VoiceDictionarySnapshot[],
  maxAliases: number = 3,
): VoiceDictionaryEntryView[] {
  let freshest: VoiceDictionarySnapshot | undefined = undefined;
  for (let i = 0; i < snapshots.length; i++) {
    const candidate = snapshots[i];
    if (candidate.fetchedAt <= 0) continue;
    if (freshest === undefined || isFresherAcrossHosts(candidate, freshest)) freshest = candidate;
  }
  if (freshest === undefined) return [];

  const seen: Set<string> = new Set();
  const views: VoiceDictionaryEntryView[] = [];
  for (let i = 0; i < freshest.entries.length; i++) {
    const entry = freshest.entries[i];
    const key = termKey(entry.text);
    if (key.length === 0 || seen.has(key)) continue;
    seen.add(key);
    const view = new VoiceDictionaryEntryView();
    view.key = key;
    view.text = entry.text;
    view.frequency = entry.frequency;
    const aliases = entry.aliases.slice().sort((a: VoiceDictionaryAlias, b: VoiceDictionaryAlias) =>
      b.count - a.count || a.text.localeCompare(b.text));
    for (let j = 0; j < aliases.length && j < maxAliases; j++) view.aliases.push(aliases[j].text);
    views.push(view);
  }
  views.sort((a: VoiceDictionaryEntryView, b: VoiceDictionaryEntryView) =>
    b.frequency - a.frequency || a.text.localeCompare(b.text));
  return views;
}

function isFresherAcrossHosts(candidate: VoiceDictionarySnapshot, current: VoiceDictionarySnapshot): boolean {
  if (candidate.stateVector !== undefined && current.stateVector !== undefined) {
    const candidateDominates = dominates(candidate.stateVector, current.stateVector);
    const currentDominates = dominates(current.stateVector, candidate.stateVector);
    if (candidateDominates !== currentDominates) return candidateDominates;
  } else if (candidate.stateVector !== undefined) {
    return true;
  } else if (current.stateVector !== undefined) {
    return false;
  }
  return candidate.fetchedAt > current.fetchedAt;
}

function storageKey(accountId: string, hostDeviceId: string): string {
  return `${KEY_PREFIX}${accountId || 'anonymous'}.${hostDeviceId}`;
}

function snapshotRecord(snapshot: VoiceDictionarySnapshot): Record<string, Object> {
  const entries: Object[] = [];
  for (let i = 0; i < snapshot.entries.length; i++) {
    const entry = snapshot.entries[i];
    const aliases: Object[] = [];
    for (let j = 0; j < entry.aliases.length; j++) {
      const aliasRecord: Record<string, Object> = {};
      aliasRecord['text'] = entry.aliases[j].text;
      aliasRecord['count'] = entry.aliases[j].count;
      aliases.push(aliasRecord);
    }
    const entryRecord: Record<string, Object> = {};
    entryRecord['text'] = entry.text;
    entryRecord['frequency'] = entry.frequency;
    entryRecord['aliases'] = aliases;
    entries.push(entryRecord);
  }
  const out: Record<string, Object> = {};
  out['entries'] = entries;
  out['fetchedAt'] = snapshot.fetchedAt;
  if (snapshot.stateVector !== undefined) out['stateVector'] = snapshot.stateVector;
  if (snapshot.emittedAt !== undefined) out['emittedAt'] = snapshot.emittedAt;
  return out;
}

function parseStoredSnapshot(raw: string): VoiceDictionarySnapshot | null {
  if (raw.length === 0) return null;
  try {
    const parsed = JSON.parse(raw) as Record<string, Object>;
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return null;
    const snapshot = new VoiceDictionarySnapshot();
    snapshot.entries = parseEntries(parsed['entries']);
    const fetchedAt = parsed['fetchedAt'];
    snapshot.fetchedAt = typeof fetchedAt === 'number' && Number.isFinite(fetchedAt as number)
      ? (fetchedAt as number) : 0;
    snapshot.stateVector = normalizeStateVector(parsed['stateVector']);
    const emittedAt = parsed['emittedAt'];
    if (typeof emittedAt === 'number' && Number.isFinite(emittedAt as number)) {
      snapshot.emittedAt = emittedAt as number;
    }
    return snapshot.fetchedAt > 0 ? snapshot : null;
  } catch (_) {
    return null;
  }
}

export class VoiceDictionaryStore {
  private readonly store: SecureStore = new SecureStore();
  private readonly memory: Map<string, VoiceDictionarySnapshot> = new Map();
  private readonly listeners: Array<() => void> = [];
  private accountId: string = '';
  /** 账号切换/登出代次；阻止旧账号的异步缓存读写复活到当前作用域。 */
  private accountGeneration: number = 0;

  async init(context: common.Context): Promise<void> {
    await this.store.init(context);
  }

  setAccountScope(accountId: string): void {
    const next = accountId.trim();
    if (next === this.accountId) return;
    this.accountId = next;
    this.accountGeneration += 1;
    this.memory.clear();
    this.emitChanged();
  }

  onChanged(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => {
      const index = this.listeners.indexOf(listener);
      if (index >= 0) this.listeners.splice(index, 1);
    };
  }

  private emitChanged(): void {
    for (let i = 0; i < this.listeners.length; i++) this.listeners[i]();
  }

  async hydrate(hostDeviceId: string): Promise<void> {
    const host = hostDeviceId.trim();
    if (host.length === 0 || this.memory.has(host)) return;
    const generation = this.accountGeneration;
    const accountId = this.accountId;
    const snapshot = parseStoredSnapshot(await this.store.get(storageKey(accountId, host), ''));
    if (snapshot !== null && generation === this.accountGeneration && accountId === this.accountId) {
      const current = this.memory.get(host);
      if (current !== undefined && current.fetchedAt >= snapshot.fetchedAt) return;
      this.memory.set(host, snapshot);
      this.emitChanged();
    }
  }

  async accept(hostDeviceId: string, snapshot: VoiceDictionarySnapshot): Promise<boolean> {
    const host = hostDeviceId.trim();
    if (host.length === 0 || snapshot.fetchedAt <= 0) return false;
    const generation = this.accountGeneration;
    const accountId = this.accountId;
    const current = this.memory.get(host);
    if (current !== undefined && !isFresherVoiceDictionarySnapshot(snapshot, current)) return false;
    this.memory.set(host, snapshot);
    this.emitChanged();
    // 词典是受限的只读缓存；写失败不影响在线展示。
    try {
      if (generation !== this.accountGeneration || accountId !== this.accountId) return true;
      await this.store.set(storageKey(accountId, host), JSON.stringify(snapshotRecord(snapshot)));
    } catch (_) {
    }
    return true;
  }

  snapshot(hostDeviceId: string): VoiceDictionarySnapshot | undefined {
    return this.memory.get(hostDeviceId.trim());
  }

  all(hostDeviceIds: string[]): VoiceDictionarySnapshot[] {
    const out: VoiceDictionarySnapshot[] = [];
    for (let i = 0; i < hostDeviceIds.length; i++) {
      const snapshot = this.memory.get(hostDeviceIds[i].trim());
      if (snapshot !== undefined) out.push(snapshot);
    }
    return out;
  }

  async clear(): Promise<void> {
    const accountId = this.accountId;
    this.accountGeneration += 1;
    const hosts: string[] = [];
    this.memory.forEach((_snapshot: VoiceDictionarySnapshot, host: string) => hosts.push(host));
    this.memory.clear();
    for (let i = 0; i < hosts.length; i++) {
      await this.store.remove(storageKey(accountId, hosts[i])).catch(() => {
      });
    }
    this.emitChanged();
  }
}
