/**
 * 任务（会话）Store：设备列表 + 每设备的会话列表。
 *
 * - 设备列表来自 presence-changed 广播（relay 同账号设备在线状态）。
 * - 会话列表：打开设备时 invoke local-db:sessions:list 拉取一次，
 *   之后靠 `sessions` topic 的 push（created / patched / activity /
 *   error-persisted）增量维护。
 * - 桌面端是权威源：pull 失败或 push 语义不清时整表重拉（reload），
 *   鸿蒙端不做本地持久化真相。
 */

import { DlClient, DlInvokeOptions } from '../device-link/DlClient';
import { PresenceSnapshot, DlChannels, Envelope } from '../device-link/DlProtocol';
import {
  RemoteSession, DeviceView, parseDeviceView, parseSession, sortSessionsByUpdatedAt,
  readStr, readObj,
} from './TaskModels';

export class TaskStore {
  private client: DlClient | undefined = undefined;
  private listeners: Array<() => void> = [];
  private devices: Map<string, PresenceSnapshot> = new Map();
  private sessionsByDevice: Map<string, RemoteSession[]> = new Map();
  /** 本机 deviceId（hello-ack 返回）；presence / REST 里的自己一律不进列表。 */
  private selfDeviceId: string = '';

  attach(client: DlClient): void {
    this.client = client;
  }

  /** 设置本机 deviceId（AppServices 在 hello-ack 时调用）。 */
  setSelfDeviceId(deviceId: string): void {
    this.selfDeviceId = deviceId;
  }

  /** 订阅变更；返回退订函数（页面 aboutToDisappear 调用）。 */
  onChanged(listener: () => void): () => void {
    this.listeners.push(listener);
    return () => {
      const idx = this.listeners.indexOf(listener);
      if (idx >= 0) {
        this.listeners.splice(idx, 1);
      }
    };
  }

  private notify(): void {
    for (const l of this.listeners) {
      l();
    }
  }

  // ─── 设备 ───────────────────────────────────────────────────────────────────

  /** 在线设备列表（online 优先，lastSeenAt 降序）。 */
  get deviceList(): PresenceSnapshot[] {
    const list: PresenceSnapshot[] = [];
    this.devices.forEach((snap: PresenceSnapshot) => {
      list.push(snap);
    });
    list.sort((a: PresenceSnapshot, b: PresenceSnapshot) => {
      if (a.online !== b.online) return a.online ? -1 : 1;
      return b.lastSeenAt - a.lastSeenAt;
    });
    return list;
  }

  getDeviceName(deviceId: string): string {
    const snap = this.devices.get(deviceId);
    return snap ? snap.deviceName : deviceId.slice(0, 8);
  }

  /**
   * 合并 REST /api/device-link/devices 的全量快照（登录连接后的初始设备列表）。
   * presence-changed 继续做增量补丁；这里的快照可能旧于在途 presence 补丁，
   * 用「presence 已见过的设备不降级」策略避免把刚上线的设备打回离线。
   */
  mergeServerDevices(views: DeviceView[]): void {
    for (let i = 0; i < views.length; i++) {
      const v = views[i];
      // 自己、非桌面平台（iOS/Android/Harmony 控制端）不进列表：
      // 设备列表只展示「提供服务的桌面电脑」。
      if (v.isSelf || v.deviceId === this.selfDeviceId) {
        continue;
      }
      if (!isDesktopPlatform(v.platform)) {
        continue;
      }
      const existing = this.devices.get(v.deviceId);
      if (existing !== undefined && existing.online && !v.online) {
        continue; // presence 已见过该设备在线，REST 旧快照不回退
      }
      const snap = new PresenceSnapshot();
      snap.deviceId = v.deviceId;
      snap.deviceName = v.name;
      snap.platform = v.platform;
      snap.appVersion = v.appVersion;
      snap.online = v.online;
      snap.busy = v.busy;
      snap.remoteControlEnabled = v.remoteControlEnabled;
      snap.lastSeenAt = v.lastSeenAt;
      this.devices.set(v.deviceId, snap);
    }
    this.notify();
  }

  handlePresence(snap: PresenceSnapshot): void {
    if (snap.deviceId.length === 0) return;
    if (snap.deviceId === this.selfDeviceId) return; // 自己不进设备列表
    if (!isDesktopPlatform(snap.platform)) return; // 只展示桌面电脑
    this.devices.set(snap.deviceId, snap);
    if (!snap.online) {
      // 离线设备仍保留条目（显示离线态），不清会话缓存。
    }
    this.notify();
  }

  // ─── 会话 ───────────────────────────────────────────────────────────────────

  getSessions(deviceId: string): RemoteSession[] {
    return this.sessionsByDevice.get(deviceId) ?? [];
  }

  /** 拉取某设备的会话列表（打开设备时调用）。 */
  async loadSessions(deviceId: string): Promise<void> {
    const client = this.client;
    if (!client) return;
    try {
      const opts = new DlInvokeOptions();
      opts.channel = DlChannels.SESSIONS_LIST;
      opts.args = [];
      const env = await client.invoke(deviceId, opts);
      const result = unwrapInvokeResult(env);
      const sessions = this.parseSessionList(result);
      this.sessionsByDevice.set(deviceId, sessions);
      this.notify();
    } catch (e) {
      // 拉取失败：保留旧列表；调用方（页面）负责提示重试。
    }
  }

  /** sessions topic 的 push 分发。 */
  handleSessionsPush(deviceId: string, channel: string, payload: Object | undefined): void {
    switch (channel) {
      case DlChannels.SESSIONS_CREATED:
        // 新会话行：整表重拉最可靠（列表通常不大）。
        void this.loadSessions(deviceId);
        break;
      case DlChannels.SESSIONS_PATCHED:
        this.applySessionPatch(deviceId, payload);
        break;
      case DlChannels.SESSION_ACTIVITY:
        this.applyActivity(deviceId, payload);
        break;
      case DlChannels.SESSION_ERROR_PERSISTED:
        void this.loadSessions(deviceId);
        break;
      default:
        break;
    }
  }

  private applySessionPatch(deviceId: string, payload: Object | undefined): void {
    if (payload === undefined || typeof payload !== 'object') return;
    const p = payload as Record<string, Object>;
    const sessionId = readStr(p, 'sessionId');
    if (sessionId.length === 0) return;
    const patch = readObj(p, 'patch');
    const list = this.sessionsByDevice.get(deviceId);
    if (!list) return;
    let changed = false;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === sessionId) {
        list[i] = this.mergeSession(list[i], patch);
        changed = true;
        break;
      }
    }
    if (changed) {
      list.sort(sortSessionsByUpdatedAt);
      this.notify();
    }
  }

  private applyActivity(deviceId: string, payload: Object | undefined): void {
    if (payload === undefined || typeof payload !== 'object') return;
    const p = payload as Record<string, Object>;
    const sessionId = readStr(p, 'sessionId');
    if (sessionId.length === 0) return;
    const detail = readStr(p, 'compactDetail');
    const list = this.sessionsByDevice.get(deviceId);
    if (!list) return;
    let changed = false;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === sessionId) {
        if (detail.length > 0) list[i].preview = detail;
        changed = true;
        break;
      }
    }
    if (changed) this.notify();
  }

  private mergeSession(base: RemoteSession, patch: Record<string, Object>): RemoteSession {
    // 以 base 为底，patch 覆盖已知字段（未知字段忽略，等待下次整表重拉）。
    const merged = new RemoteSession();
    merged.id = base.id;
    merged.userId = base.userId;
    merged.title = base.title;
    merged.workingDir = base.workingDir;
    merged.workspaceKind = base.workspaceKind;
    merged.model = base.model;
    merged.providerId = base.providerId;
    merged.effort = base.effort;
    merged.permissionMode = base.permissionMode;
    merged.planModeEnabled = base.planModeEnabled;
    merged.fastMode = base.fastMode;
    merged.status = base.status;
    merged.agentKind = base.agentKind;
    merged.source = base.source;
    merged.orcaRole = base.orcaRole;
    merged.pinnedAt = base.pinnedAt;
    merged.userSendAt = base.userSendAt;
    merged.createdAt = base.createdAt;
    merged.updatedAt = base.updatedAt;
    merged.preview = base.preview;
    merged.messageCount = base.messageCount;
    return parseSession(mergeFields(this.sessionToRecord(merged), patch));
  }

  private sessionToRecord(s: RemoteSession): Record<string, Object> {
    const count: Record<string, Object> = {};
    count['messages'] = s.messageCount;
    const out: Record<string, Object> = {};
    out['id'] = s.id;
    out['userId'] = s.userId;
    out['title'] = s.title;
    out['workingDir'] = s.workingDir;
    out['workspaceKind'] = s.workspaceKind;
    out['model'] = s.model;
    out['providerId'] = s.providerId;
    out['effort'] = s.effort;
    out['permissionMode'] = s.permissionMode;
    out['planModeEnabled'] = s.planModeEnabled;
    out['fastMode'] = s.fastMode;
    out['status'] = s.status;
    out['agentKind'] = s.agentKind;
    out['source'] = s.source;
    out['orcaRole'] = s.orcaRole;
    out['pinnedAt'] = s.pinnedAt;
    out['userSendAt'] = s.userSendAt;
    out['createdAt'] = s.createdAt;
    out['updatedAt'] = s.updatedAt;
    out['preview'] = s.preview;
    out['_count'] = count;
    return out;
  }

  private parseSessionList(result: Object | undefined): RemoteSession[] {
    const out: RemoteSession[] = [];
    if (result === undefined) {
      return out;
    }
    const list: Object[] = result as Object[];
    for (let i = 0; i < list.length; i++) {
      const raw: Object = list[i];
      if (raw !== undefined && typeof raw === 'object' && !Array.isArray(raw)) {
        out.push(parseSession(raw as Record<string, Object>));
      }
    }
    out.sort(sortSessionsByUpdatedAt);
    return out;
  }
}

/** 是否为桌面平台（darwin / win32 / linux）；控制端（ios/android/harmony）不算。 */
function isDesktopPlatform(platform: string): boolean {
  return platform === 'darwin' || platform === 'win32' || platform === 'linux';
}

/** 把 patch 合并进 base（仅覆盖 patch 中的键）。 */
function mergeFields(base: Record<string, Object>, patch: Record<string, Object>): Record<string, Object> {
  const out: Record<string, Object> = {};
  const baseKeys = Object.keys(base);
  for (let i = 0; i < baseKeys.length; i++) {
    out[baseKeys[i]] = base[baseKeys[i]];
  }
  const patchKeys = Object.keys(patch);
  for (let i = 0; i < patchKeys.length; i++) {
    out[patchKeys[i]] = patch[patchKeys[i]];
  }
  return out;
}

/** 解析 invoke-result 信封：ok=true 返回 result，否则抛错。 */
export function unwrapInvokeResult(env: Envelope): Object | undefined {
  const p = env.payload as Record<string, Object>;
  const ok = p['ok'];
  if (ok === true) {
    return p['result'] as Object | undefined;
  }
  const err = p['error'] as Record<string, Object> | undefined;
  const code = err !== undefined ? readStr(err, 'code') : 'IPC_ERROR';
  const message = err !== undefined ? readStr(err, 'message') : 'invoke failed';
  throw new Error(`[${code}] ${message}`);
}
