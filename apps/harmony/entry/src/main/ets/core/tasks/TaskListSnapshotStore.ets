/**
 * 任务列表冷启动快照。
 *
 * 只保存列表首屏需要的瘦身字段；它是可丢弃的 last-known 投影，远端设备与会话
 * 快照返回后必须由 TaskStore 对账覆盖，不能成为业务真相。
 */
import { common } from '@kit.AbilityKit';
import { PresenceSnapshot } from '../device-link/DlProtocol';
import { SecureStore } from '../storage/SecureStore';
import { RemoteSession, parseSession, sortSessionsByUpdatedAt } from './TaskModels';

const KEY = 'task.list.snapshot.v2';
const LEGACY_KEY = 'task.list.snapshot.v1';
const MAX_DEVICES = 8;
const MAX_SESSIONS_PER_DEVICE = 100;
const MAX_TEXT_CHARS = 240;
const MAX_BYTES = 512 * 1024;
const SHRINK_STEPS: number[] = [MAX_SESSIONS_PER_DEVICE, 40, 15];

export class CachedTaskListDevice {
  deviceId: string = '';
  deviceName: string = '';
  sessions: RemoteSession[] = [];
}

function truncated(value: string): string {
  return value.slice(0, MAX_TEXT_CHARS);
}

function lastActivityAt(session: RemoteSession): string {
  return session.userSendAt.length > 0
    ? session.userSendAt
    : (session.updatedAt.length > 0 ? session.updatedAt : session.createdAt);
}

function sessionRecord(session: RemoteSession): Record<string, Object> {
  const out: Record<string, Object> = {};
  out['id'] = session.id;
  if (session.title.length > 0) out['title'] = truncated(session.title);
  if (session.workingDir.length > 0) out['workingDir'] = truncated(session.workingDir);
  if (session.worktreePath.length > 0) out['worktreePath'] = truncated(session.worktreePath);
  out['workspaceKind'] = session.workspaceKind === 'dialogue' ? 'dialogue' : 'project';
  if (session.model.length > 0) out['model'] = truncated(session.model);
  out['status'] = session.status;
  if (session.agentKind.length > 0) out['agentKind'] = truncated(session.agentKind);
  if (session.source.length > 0) out['source'] = truncated(session.source);
  if (session.orcaRole.length > 0) out['orcaRole'] = truncated(session.orcaRole);
  if (session.pinnedAt.length > 0) out['pinnedAt'] = session.pinnedAt;
  if (session.userSendAt.length > 0) out['userSendAt'] = session.userSendAt;
  out['createdAt'] = session.createdAt;
  if (session.updatedAt.length > 0) out['updatedAt'] = session.updatedAt;
  if (session.preview.length > 0) out['preview'] = truncated(session.preview);
  return out;
}

function normalizedSessions(input: RemoteSession[], limit: number): RemoteSession[] {
  const byId: Map<string, RemoteSession> = new Map();
  for (let i = 0; i < input.length; i++) {
    const session = input[i];
    if (session.id.length === 0
      || (session.status !== 'active' && session.status !== 'archived')
      || session.orcaRole === 'worker') continue;
    byId.set(session.id, session);
  }
  const sessions: RemoteSession[] = [];
  byId.forEach((session: RemoteSession) => sessions.push(session));
  sessions.sort(sortSessionsByUpdatedAt);
  return sessions.slice(0, limit);
}

function normalizedDevices(input: CachedTaskListDevice[], perDeviceLimit: number): CachedTaskListDevice[] {
  const devices: CachedTaskListDevice[] = [];
  const seen: Set<string> = new Set();
  for (let i = 0; i < input.length && devices.length < MAX_DEVICES; i++) {
    const source = input[i];
    if (source.deviceId.length === 0 || seen.has(source.deviceId)) continue;
    const sessions = normalizedSessions(source.sessions, perDeviceLimit);
    if (sessions.length === 0) continue;
    seen.add(source.deviceId);
    const device = new CachedTaskListDevice();
    device.deviceId = source.deviceId;
    device.deviceName = source.deviceName.length > 0 ? truncated(source.deviceName) : source.deviceId;
    device.sessions = sessions;
    devices.push(device);
  }
  devices.sort((a: CachedTaskListDevice, b: CachedTaskListDevice) =>
    lastActivityAt(b.sessions[0]).localeCompare(lastActivityAt(a.sessions[0])));
  return devices;
}

export function utf8ByteLength(value: string): number {
  let bytes = 0;
  for (let i = 0; i < value.length; i++) {
    const code = value.codePointAt(i) ?? 0;
    if (code > 0xffff) i += 1;
    bytes += code <= 0x7f ? 1 : (code <= 0x7ff ? 2 : (code <= 0xffff ? 3 : 4));
  }
  return bytes;
}

/** 空字符串表示没有可缓存内容；null 表示超限，保留上一份可用快照。 */
export function serializeTaskListSnapshot(
  accountId: string,
  input: CachedTaskListDevice[],
): string | null {
  if (accountId.length === 0) return '';
  for (let i = 0; i < SHRINK_STEPS.length; i++) {
    const devices = normalizedDevices(input, SHRINK_STEPS[i]);
    if (devices.length === 0) return '';
    const rows: Object[] = [];
    for (let d = 0; d < devices.length; d++) {
      const sessionRows: Object[] = [];
      for (let s = 0; s < devices[d].sessions.length; s++) {
        sessionRows.push(sessionRecord(devices[d].sessions[s]));
      }
      const row: Record<string, Object> = {};
      row['deviceId'] = devices[d].deviceId;
      row['deviceName'] = devices[d].deviceName;
      row['sessions'] = sessionRows;
      rows.push(row);
    }
    const root: Record<string, Object> = {};
    root['version'] = 2;
    root['accountId'] = accountId;
    root['devices'] = rows;
    const serialized = JSON.stringify(root);
    if (utf8ByteLength(serialized) <= MAX_BYTES) return serialized;
  }
  return null;
}

export function parseTaskListSnapshot(raw: string, accountId: string): CachedTaskListDevice[] {
  if (accountId.length === 0 || raw.length === 0 || utf8ByteLength(raw) > MAX_BYTES) return [];
  try {
    const root = JSON.parse(raw) as Record<string, Object>;
    if (root === null || typeof root !== 'object' || Array.isArray(root)
      || root['version'] !== 2 || root['accountId'] !== accountId
      || !Array.isArray(root['devices'])) return [];
    const rawDevices = root['devices'] as Object[];
    const devices: CachedTaskListDevice[] = [];
    for (let d = 0; d < rawDevices.length && devices.length < MAX_DEVICES; d++) {
      const rawDevice = rawDevices[d];
      if (rawDevice === null || typeof rawDevice !== 'object' || Array.isArray(rawDevice)) continue;
      const record = rawDevice as Record<string, Object>;
      const deviceId = typeof record['deviceId'] === 'string' ? record['deviceId'] as string : '';
      const deviceName = typeof record['deviceName'] === 'string' ? record['deviceName'] as string : '';
      const rows = Array.isArray(record['sessions']) ? record['sessions'] as Object[] : [];
      const sessions: RemoteSession[] = [];
      for (let s = 0; s < rows.length && sessions.length < MAX_SESSIONS_PER_DEVICE; s++) {
        const row = rows[s];
        if (row === null || typeof row !== 'object' || Array.isArray(row)) continue;
        sessions.push(parseSession(row as Record<string, Object>));
      }
      const device = new CachedTaskListDevice();
      device.deviceId = deviceId;
      device.deviceName = deviceName;
      device.sessions = sessions;
      devices.push(device);
    }
    return normalizedDevices(devices, MAX_SESSIONS_PER_DEVICE);
  } catch (e) {
    return [];
  }
}

export function snapshotDevices(
  devices: PresenceSnapshot[],
  sessionsForDevice: (deviceId: string) => RemoteSession[],
): CachedTaskListDevice[] {
  const out: CachedTaskListDevice[] = [];
  for (let i = 0; i < devices.length; i++) {
    if (!devices[i].remoteControlEnabled) continue;
    const cached = new CachedTaskListDevice();
    cached.deviceId = devices[i].deviceId;
    cached.deviceName = devices[i].deviceName;
    cached.sessions = sessionsForDevice(devices[i].deviceId);
    out.push(cached);
  }
  return out;
}

export class TaskListSnapshotStore {
  private readonly store: SecureStore = new SecureStore();
  private raw: string = '';
  private pendingRaw: string | null = null;
  private pendingCollect: (() => CachedTaskListDevice[]) | undefined = undefined;
  private accountId: string = '';
  private timer: number = -1;
  private initialized: boolean = false;
  /** 登出会推进代次；写队列保证最后一次动作一定是清理，不能被在途 set 复活。 */
  private writeEpoch: number = 0;
  private mutation: Promise<void> = Promise.resolve();

  async init(context: common.Context): Promise<void> {
    await this.store.init(context);
    this.raw = await this.store.get(KEY, '');
    void this.store.remove(LEGACY_KEY);
    this.initialized = true;
  }

  setAccountScope(accountId: string): void {
    this.accountId = accountId;
  }

  restore(): CachedTaskListDevice[] {
    return parseTaskListSnapshot(this.raw, this.accountId);
  }

  save(collect: () => CachedTaskListDevice[]): void {
    if (!this.initialized || this.accountId.length === 0) return;
    this.pendingCollect = collect;
    if (this.timer >= 0) clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      this.timer = -1;
      const collectNow = this.pendingCollect;
      this.pendingCollect = undefined;
      if (collectNow === undefined || this.accountId.length === 0) return;
      const serialized = serializeTaskListSnapshot(this.accountId, collectNow());
      if (serialized === null || serialized === this.raw || serialized === this.pendingRaw) return;
      this.pendingRaw = serialized;
      const next = this.pendingRaw;
      this.pendingRaw = null;
      if (next === null || next === this.raw) return;
      this.raw = next;
      const epoch = this.writeEpoch;
      this.mutation = this.mutation.then(async (): Promise<void> => {
        if (epoch !== this.writeEpoch) return;
        if (next.length === 0) await this.store.remove(KEY);
        else await this.store.set(KEY, next);
      }).catch(() => {
        // 快照只是首屏加速；写盘失败不影响远端权威数据和页面交互。
      });
    }, 350);
  }

  async clear(): Promise<void> {
    this.writeEpoch += 1;
    if (this.timer >= 0) clearTimeout(this.timer);
    this.timer = -1;
    this.pendingCollect = undefined;
    this.pendingRaw = null;
    this.raw = '';
    this.accountId = '';
    if (this.initialized) {
      this.mutation = this.mutation.then(() => this.store.remove(KEY)).catch(() => {
      });
      await this.mutation;
    }
  }
}
