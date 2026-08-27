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
import { CachedTaskListDevice } from './TaskListSnapshotStore';

export class SessionMetaPatch {
  title: string | undefined = undefined;
  pinnedAt: string | null | undefined = undefined;
  status: string | undefined = undefined;
}

export class SessionLiveActivity {
  phase: string = '';
  attention: boolean = false;
  compactDetail: string = '';
  interactionKind: string = '';
}

export class TaskStore {
  private client: DlClient | undefined = undefined;
  private listeners: Array<() => void> = [];
  private devices: Map<string, PresenceSnapshot> = new Map();
  private sessionsByDevice: Map<string, RemoteSession[]> = new Map();
  private sessionLoadRevisions: Map<string, number> = new Map();
  /** 同一设备的列表恢复 single-flight；代次仍负责拒绝清理后的旧结果。 */
  private sessionLoadOperations: Map<string, Promise<boolean>> = new Map();
  /** 同一设备的运行态补快照 single-flight；撤权/重连通过 sessionLoadRevisions 使旧结果失效。 */
  private activeRefreshOperations: Map<string, Promise<void>> = new Map();
  private pendingActivityByDevice: Map<string, Map<string, string>> = new Map();
  /** sessionId 可能跨设备重复；运行态投影使用 deviceId + sessionId 复合键。 */
  private liveActivityBySession: Map<string, SessionLiveActivity> = new Map();
  /** 同一任务的元数据写使用字段级代次；旧响应/旧失败不能覆盖新操作。 */
  private metaWriteGenerations: Map<string, number> = new Map();
  /**
   * 整个任务投影的单调代次。登出/换号只递增、不复用；所有异步响应写回前
   * 都必须校验，避免旧账号与新账号恰好使用相同 deviceId/sessionId 时串数据。
   */
  private stateGeneration: number = 0;
  /** 本机 deviceId（hello-ack 返回）；presence / REST 里的自己一律不进列表。 */
  private selfDeviceId: string = '';
  /** 冷启动快照种入、尚未被 REST / presence 权威设备状态对账的设备。 */
  private cachedDeviceIds: Set<string> = new Set();

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
    const serverDeviceIds: Set<string> = new Set();
    for (let i = 0; i < views.length; i++) serverDeviceIds.add(views[i].deviceId);
    const staleCachedDeviceIds: string[] = [];
    this.cachedDeviceIds.forEach((deviceId: string) => {
      if (!serverDeviceIds.has(deviceId)) staleCachedDeviceIds.push(deviceId);
    });
    for (let i = 0; i < staleCachedDeviceIds.length; i++) {
      this.devices.delete(staleCachedDeviceIds[i]);
      this.invalidateSessions(staleCachedDeviceIds[i]);
    }
    this.cachedDeviceIds.clear();
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
      if (!snap.remoteControlEnabled) {
        this.invalidateSessions(v.deviceId);
      }
    }
    this.notify();
  }

  handlePresence(snap: PresenceSnapshot): void {
    if (snap.deviceId.length === 0) return;
    if (snap.deviceId === this.selfDeviceId) return; // 自己不进设备列表
    if (!isDesktopPlatform(snap.platform)) return; // 只展示桌面电脑
    this.devices.set(snap.deviceId, snap);
    if (!snap.remoteControlEnabled) {
      // 显式关闭远程控制立即丢弃任务镜像；短暂离线仍保留最近快照。
      this.invalidateSessions(snap.deviceId);
    }
    this.notify();
  }

  // ─── 会话 ───────────────────────────────────────────────────────────────────

  private invalidateSessions(deviceId: string): void {
    const revision = (this.sessionLoadRevisions.get(deviceId) ?? 0) + 1;
    this.sessionLoadRevisions.set(deviceId, revision);
    this.sessionLoadOperations.delete(deviceId);
    this.activeRefreshOperations.delete(deviceId);
    const activityPrefix = liveActivityKeyPrefix(deviceId);
    const ownedActivityKeys: string[] = [];
    this.liveActivityBySession.forEach((_activity: SessionLiveActivity, key: string) => {
      if (key.startsWith(activityPrefix)) ownedActivityKeys.push(key);
    });
    for (let i = 0; i < ownedActivityKeys.length; i++) {
      this.liveActivityBySession.delete(ownedActivityKeys[i]);
    }
    this.sessionsByDevice.delete(deviceId);
    this.pendingActivityByDevice.delete(deviceId);
  }

  getSessions(deviceId: string): RemoteSession[] {
    return this.sessionsByDevice.get(deviceId) ?? [];
  }

  /**
   * 跨设备按 id 查任务快照。消息驻留策略用它读取权威 `source`；
   * 快照尚未到达时返回 undefined，调用方按普通任务保守处理。
   */
  findSessionById(sessionId: string, deviceId: string = ''): RemoteSession | undefined {
    if (sessionId.length === 0) return undefined;
    if (deviceId.length > 0) {
      const scoped = this.sessionsByDevice.get(deviceId) ?? [];
      for (let i = 0; i < scoped.length; i++) {
        if (scoped[i].id === sessionId) return scoped[i];
      }
      return undefined;
    }
    let found: RemoteSession | undefined = undefined;
    this.sessionsByDevice.forEach((sessions: RemoteSession[]) => {
      if (found !== undefined) return;
      for (let i = 0; i < sessions.length; i++) {
        if (sessions[i].id === sessionId) {
          found = sessions[i];
          return;
        }
      }
    });
    return found;
  }

  /**
   * 冷启动先种入 last-known 列表；设备一律标离线，避免缓存伪造实时可用性。
   * REST / presence 到达后 mergeServerDevices / handlePresence 会完成权威对账。
   */
  hydrateTaskListSnapshot(snapshot: CachedTaskListDevice[]): void {
    if (this.devices.size > 0 || this.sessionsByDevice.size > 0) return;
    for (let i = 0; i < snapshot.length; i++) {
      const cached = snapshot[i];
      if (cached.deviceId.length === 0 || cached.sessions.length === 0) continue;
      const device = new PresenceSnapshot();
      device.deviceId = cached.deviceId;
      device.deviceName = cached.deviceName.length > 0 ? cached.deviceName : cached.deviceId;
      device.online = false;
      device.remoteControlEnabled = true;
      const latestAt = cached.sessions[0].updatedAt.length > 0
        ? cached.sessions[0].updatedAt : cached.sessions[0].createdAt;
      const parsedAt = Date.parse(latestAt);
      device.lastSeenAt = Number.isNaN(parsedAt) ? 0 : parsedAt;
      this.devices.set(device.deviceId, device);
      this.sessionsByDevice.set(device.deviceId, cached.sessions.slice());
      this.cachedDeviceIds.add(device.deviceId);
    }
    if (this.cachedDeviceIds.size > 0) this.notify();
  }

  /** 显式登出时同时清掉内存镜像，防止下一账号看到上一账号的 last-known 列表。 */
  clearAll(): void {
    this.stateGeneration += 1;
    this.devices.clear();
    this.sessionsByDevice.clear();
    this.sessionLoadRevisions.clear();
    this.sessionLoadOperations.clear();
    this.activeRefreshOperations.clear();
    this.pendingActivityByDevice.clear();
    this.liveActivityBySession.clear();
    this.metaWriteGenerations.clear();
    this.cachedDeviceIds.clear();
    this.notify();
  }

  getLiveActivity(sessionId: string, deviceId: string = ''): SessionLiveActivity | null {
    if (deviceId.length > 0) {
      return this.liveActivityBySession.get(liveActivityKey(deviceId, sessionId)) ?? null;
    }
    const suffix = liveActivityKeySuffix(sessionId);
    let found: SessionLiveActivity | undefined = undefined;
    this.liveActivityBySession.forEach((activity: SessionLiveActivity, key: string) => {
      if (found === undefined && key.endsWith(suffix)) found = activity;
    });
    return found ?? null;
  }

  /** 新建任务拿到 sessionId 后先占位，避免 sessions:created push 晚到导致详情页空壳。 */
  upsertSession(deviceId: string, session: RemoteSession): void {
    if (session.status === 'deleted') {
      // deleted 是终态；搜索结果、created push 或本地占位都不能把墓碑重新
      // 投影成可见任务。
      this.removeSession(deviceId, session.id);
      return;
    }
    const list = this.sessionsByDevice.get(deviceId) ?? [];
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === session.id) {
        list[i] = session;
        list.sort(sortSessionsByUpdatedAt);
        this.sessionsByDevice.set(deviceId, list);
        this.notify();
        return;
      }
    }
    list.push(session);
    list.sort(sortSessionsByUpdatedAt);
    this.sessionsByDevice.set(deviceId, list);
    this.notify();
  }

  /** 拉取某设备的 active + archived 列表；deleted 永不进入本地投影。 */
  async loadSessions(deviceId: string): Promise<boolean> {
    const existing = this.sessionLoadOperations.get(deviceId);
    if (existing !== undefined) {
      return await existing;
    }
    const operation = this.loadSessionsOnce(deviceId);
    this.sessionLoadOperations.set(deviceId, operation);
    try {
      return await operation;
    } finally {
      if (this.sessionLoadOperations.get(deviceId) === operation) {
        this.sessionLoadOperations.delete(deviceId);
      }
    }
  }

  private async loadSessionsOnce(deviceId: string): Promise<boolean> {
    const client = this.client;
    if (!client) return false;
    const stateGeneration = this.stateGeneration;
    const revision = (this.sessionLoadRevisions.get(deviceId) ?? 0) + 1;
    this.sessionLoadRevisions.set(deviceId, revision);
    try {
      const opts = new DlInvokeOptions();
      opts.channel = DlChannels.SESSIONS_LIST;
      const includePinned: Record<string, Object> = {};
      includePinned['includePinned'] = true;
      opts.args = [200, 'all', includePinned];
      const env = await client.invoke(deviceId, opts);
      if (stateGeneration !== this.stateGeneration
        || this.sessionLoadRevisions.get(deviceId) !== revision) return false;
      const device = this.devices.get(deviceId);
      if (device !== undefined && !device.remoteControlEnabled) return false;
      const result = unwrapInvokeResult(env);
      // 空数组是权威的“当前没有任务”；其它形态代表旧端/异常响应，不能
      // 被 parseSessionList 当成空列表从而覆盖当前可用快照。
      if (!Array.isArray(result)) return false;
      const sessions = this.parseSessionList(result);
      const previous = this.sessionsByDevice.get(deviceId) ?? [];
      const pendingById = new Map<string, RemoteSession>();
      for (let i = 0; i < previous.length; i++) {
        if (previous[i].pendingLocalCreation) pendingById.set(previous[i].id, previous[i]);
      }
      for (let i = 0; i < sessions.length; i++) {
        if (pendingById.has(sessions[i].id)) {
          sessions[i].pendingLocalCreation = true;
          pendingById.delete(sessions[i].id);
        }
      }
      // create-session 尚未在列表快照中可见时继续保留合成本地行；否则详情页会
      // 在“立即跳转”后被一次应用级 sessions 刷新挖空。
      pendingById.forEach((session: RemoteSession) => sessions.push(session));
      sessions.sort(sortSessionsByUpdatedAt);
      this.applyPendingActivity(deviceId, sessions);
      this.sessionsByDevice.set(deviceId, sessions);
      this.pendingActivityByDevice.delete(deviceId);
      this.notify();
      void this.refreshActiveSessions(deviceId);
      return true;
    } catch (e) {
      // 调用方根据 false 做有界退避；旧列表继续保留。
      return false;
    }
  }

  /** 从搜索结果打开缓存中尚不存在的历史任务；返回后写入当前设备快照。 */
  async loadSession(deviceId: string, sessionId: string): Promise<RemoteSession | undefined> {
    const client = this.client;
    if (!client || sessionId.length === 0) return undefined;
    const stateGeneration = this.stateGeneration;
    const revision = this.sessionLoadRevisions.get(deviceId) ?? 0;
    try {
      const opts = new DlInvokeOptions();
      opts.channel = DlChannels.SESSIONS_GET;
      opts.args = [sessionId];
      const result = unwrapInvokeResult(await client.invoke(deviceId, opts));
      if (stateGeneration !== this.stateGeneration
        || revision !== (this.sessionLoadRevisions.get(deviceId) ?? 0)) return undefined;
      const device = this.devices.get(deviceId);
      if (device !== undefined && !device.remoteControlEnabled) return undefined;
      if (result === undefined || result === null || typeof result !== 'object'
        || Array.isArray(result)) return undefined;
      const session = parseSession(result as Record<string, Object>);
      if (session.id !== sessionId || session.status === 'deleted') return undefined;
      this.upsertSession(deviceId, session);
      return session;
    } catch (_error) {
      // 搜索结果仍可用摘要打开；详情页的消息 Store 会继续按 sessionId 拉历史。
      return undefined;
    }
  }

  /** maker:list-active 是列表运行态的权威补快照；只消费明确的 boolean 状态。 */
  async refreshActiveSessions(deviceId: string): Promise<void> {
    const existing = this.activeRefreshOperations.get(deviceId);
    if (existing !== undefined) {
      await existing;
      return;
    }
    const operation = this.refreshActiveSessionsOnce(deviceId);
    this.activeRefreshOperations.set(deviceId, operation);
    try {
      await operation;
    } finally {
      if (this.activeRefreshOperations.get(deviceId) === operation) {
        this.activeRefreshOperations.delete(deviceId);
      }
    }
  }

  private async refreshActiveSessionsOnce(deviceId: string): Promise<void> {
    const client = this.client;
    if (!client) return;
    const stateGeneration = this.stateGeneration;
    const revision = this.sessionLoadRevisions.get(deviceId) ?? 0;
    const device = this.devices.get(deviceId);
    if (device !== undefined && !device.remoteControlEnabled) return;
    try {
      const opts = new DlInvokeOptions();
      opts.channel = 'maker:list-active';
      opts.args = [];
      const result = unwrapInvokeResult(await client.invoke(deviceId, opts));
      if (stateGeneration !== this.stateGeneration
        || revision !== (this.sessionLoadRevisions.get(deviceId) ?? 0)) return;
      const currentDevice = this.devices.get(deviceId);
      if (currentDevice !== undefined && !currentDevice.remoteControlEnabled) return;
      if (!Array.isArray(result)) return;
      const rows = result as Object[];
      let changed = false;
      const activeIds = new Set<string>();
      for (let i = 0; i < rows.length; i++) {
        const raw = rows[i];
        if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) continue;
        const row = raw as Record<string, Object>;
        const sessionId = readStr(row, 'sessionId');
        const rawRunning = row['isTurnRunning'];
        if (sessionId.length === 0 || typeof rawRunning !== 'boolean') continue;
        const activityKey = liveActivityKey(deviceId, sessionId);
        const current = this.liveActivityBySession.get(activityKey);
        if (rawRunning) {
          activeIds.add(sessionId);
          const activity = current ?? new SessionLiveActivity();
          if (current === undefined || current.phase !== 'running') {
            activity.phase = 'running';
            this.liveActivityBySession.set(activityKey, activity);
            changed = true;
          }
        } else if (current !== undefined && current.phase === 'running') {
          this.liveActivityBySession.delete(activityKey);
          changed = true;
        }
      }
      // Desktop 的结果可能只包含当前活动任务；省略项同样代表该设备已不在运行。
      // 只清理自己设备、明确属于 running 的投影，避免抹掉 needs-interaction 等状态。
      const knownSessions = this.sessionsByDevice.get(deviceId) ?? [];
      for (let i = 0; i < knownSessions.length; i++) {
        const sessionId = knownSessions[i].id;
        const activityKey = liveActivityKey(deviceId, sessionId);
        const current = this.liveActivityBySession.get(activityKey);
        if (current !== undefined && current.phase === 'running' && !activeIds.has(sessionId)) {
          this.liveActivityBySession.delete(activityKey);
          changed = true;
        }
      }
      if (changed) this.notify();
    } catch (_error) {
      // 老被控端没有可选快照时继续依赖 sessions activity push。
    }
  }

  /**
   * 统一任务元数据写入口。先乐观更新，再用被控端完整 RemoteSession 对账；
   * 同任务旧响应不得覆盖后发操作，失败则恢复整行并重拉权威列表。
   */
  async patchSession(deviceId: string, sessionId: string, patch: SessionMetaPatch): Promise<boolean> {
    const client = this.client;
    if (!client || sessionId.length === 0) return false;
    const stateGeneration = this.stateGeneration;
    const revision = this.sessionLoadRevisions.get(deviceId) ?? 0;
    const list = this.sessionsByDevice.get(deviceId) ?? [];
    let before: RemoteSession | undefined = undefined;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === sessionId) {
        before = list[i];
        break;
      }
    }
    if (before === undefined) return false;
    const writeKey = `${deviceId}:${sessionId}`;
    const generation = (this.metaWriteGenerations.get(writeKey) ?? 0) + 1;
    this.metaWriteGenerations.set(writeKey, generation);
    this.applyOptimisticMetaPatch(deviceId, before, patch);
    try {
      const opts = new DlInvokeOptions();
      opts.channel = 'local-db:sessions:patch-meta';
      opts.args = [sessionId, patch];
      const result = unwrapInvokeResult(await client.invoke(deviceId, opts));
      if (stateGeneration !== this.stateGeneration
        || revision !== (this.sessionLoadRevisions.get(deviceId) ?? 0)) return false;
      if (this.metaWriteGenerations.get(writeKey) !== generation) return true;
      if (result !== undefined && result !== null && typeof result === 'object' && !Array.isArray(result)) {
        const session = parseSession(result as Record<string, Object>);
        if (session.status === 'deleted') this.removeSession(deviceId, sessionId);
        else this.upsertSession(deviceId, session);
      } else {
        void this.loadSessions(deviceId);
      }
      return true;
    } catch (e) {
      if (stateGeneration === this.stateGeneration
        && revision === (this.sessionLoadRevisions.get(deviceId) ?? 0)
        && this.metaWriteGenerations.get(writeKey) === generation) {
        this.upsertSession(deviceId, before);
        void this.loadSessions(deviceId);
      }
      return false;
    }
  }

  async regenerateTitle(deviceId: string, sessionId: string): Promise<string> {
    const client = this.client;
    if (!client || sessionId.length === 0) return '';
    const stateGeneration = this.stateGeneration;
    const revision = this.sessionLoadRevisions.get(deviceId) ?? 0;
    try {
      const request: Record<string, Object> = {};
      request['sessionId'] = sessionId;
      const opts = new DlInvokeOptions();
      opts.channel = 'maker:regenerate-title';
      opts.args = [request];
      const result = unwrapInvokeResult(await client.invoke(deviceId, opts));
      if (stateGeneration !== this.stateGeneration
        || revision !== (this.sessionLoadRevisions.get(deviceId) ?? 0)) return '';
      if (result === undefined || result === null || typeof result !== 'object' || Array.isArray(result)) return '';
      return readStr(result as Record<string, Object>, 'title');
    } catch (e) {
      return '';
    }
  }

  private applyOptimisticMetaPatch(
    deviceId: string,
    before: RemoteSession,
    patch: SessionMetaPatch,
  ): void {
    const emptyPatch: Record<string, Object> = {};
    const next = this.mergeSession(before, emptyPatch);
    if (patch.title !== undefined) next.title = patch.title;
    if (patch.pinnedAt !== undefined) next.pinnedAt = patch.pinnedAt ?? '';
    if (patch.status !== undefined) next.status = patch.status;
    next.updatedAt = new Date().toISOString();
    if (next.status === 'deleted') this.removeSession(deviceId, next.id);
    else this.upsertSession(deviceId, next);
  }

  private removeSession(deviceId: string, sessionId: string): void {
    const list = this.sessionsByDevice.get(deviceId);
    if (list === undefined) {
      this.clearLiveActivity(deviceId, sessionId);
      return;
    }
    const filtered = list.filter((item: RemoteSession) => item.id !== sessionId);
    if (filtered.length === list.length) {
      this.clearLiveActivity(deviceId, sessionId);
      return;
    }
    this.sessionsByDevice.set(deviceId, filtered);
    this.clearLiveActivity(deviceId, sessionId);
    this.notify();
  }

  private clearLiveActivity(deviceId: string, sessionId: string): void {
    this.liveActivityBySession.delete(liveActivityKey(deviceId, sessionId));
  }

  setPendingLocalCreation(deviceId: string, sessionId: string, pending: boolean): void {
    const list = this.sessionsByDevice.get(deviceId);
    if (list === undefined) return;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id !== sessionId) continue;
      if (list[i].pendingLocalCreation === pending) return;
      list[i].pendingLocalCreation = pending;
      this.notify();
      return;
    }
  }

  /**
   * 新建任务成功收口：解除本地创建锁，并立即启动一轮更高代次的权威列表对账。
   * sessions:created 触发的旧请求可能早于 create-session 落库；这里的新请求会让
   * 旧响应失效，避免它在返回任务列表前把刚创建的行覆盖掉。
   */
  completeLocalCreation(deviceId: string, sessionId: string): void {
    this.setPendingLocalCreation(deviceId, sessionId, false);
    void this.loadSessions(deviceId);
  }

  removeLocalSession(deviceId: string, sessionId: string): void {
    this.removeSession(deviceId, sessionId);
  }

  /** sessions topic 的 push 分发。 */
  handleSessionsPush(deviceId: string, channel: string, payload: Object | undefined): void {
    const device = this.devices.get(deviceId);
    if (device !== undefined && !device.remoteControlEnabled) return;
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
    // push 可能在首次快照、重连快照或 created push 之前到达；active 行不能静默丢掉，
    // 由桌面端权威列表补齐。Mobile 对未知 active 会话也走 reseed。
    if (!list) {
      if (readStr(patch, 'status') === 'active') void this.loadSessions(deviceId);
      return;
    }
    let changed = false;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === sessionId) {
        list[i] = this.mergeSession(list[i], patch);
        changed = true;
        break;
      }
    }
    if (!changed && readStr(patch, 'status') === 'active') {
      void this.loadSessions(deviceId);
      return;
    }
    if (changed) {
      if (readStr(patch, 'status') === 'deleted') {
        // deleted 是终态，不让它进入本地任务投影；列表与搜索都依赖这里
        // 及时移除，避免只靠 UI 过滤留下旧任务缓存。
        this.removeSession(deviceId, sessionId);
        return;
      }
      list.sort(sortSessionsByUpdatedAt);
      this.notify();
    }
  }

  private applyActivity(deviceId: string, payload: Object | undefined): void {
    if (payload === undefined || typeof payload !== 'object') return;
    const p = payload as Record<string, Object>;
    const sessionId = readStr(p, 'sessionId');
    if (sessionId.length === 0) return;
    const activityKey = liveActivityKey(deviceId, sessionId);
    const device = this.devices.get(deviceId);
    if (device !== undefined && !device.remoteControlEnabled) return;
    const detail = readStr(p, 'compactDetail');
    const phase = readStr(p, 'phase');
    const attention = p['attention'] === true;
    const interactionKind = readStr(p, 'interactionKind');
    if ((phase === 'completed' || phase === 'error') && !attention) {
      this.liveActivityBySession.delete(activityKey);
    } else if (phase === 'running' || phase === 'needs-interaction'
      || phase === 'completed' || phase === 'error') {
      const activity = new SessionLiveActivity();
      activity.phase = phase;
      activity.attention = attention;
      activity.compactDetail = detail;
      activity.interactionKind = interactionKind;
      this.liveActivityBySession.set(activityKey, activity);
    }
    if (detail.length > 0) this.rememberActivity(deviceId, sessionId, detail);
    const list = this.sessionsByDevice.get(deviceId);
    if (!list) {
      void this.loadSessions(deviceId);
      return;
    }
    let changed = false;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === sessionId) {
        if (detail.length > 0) list[i].preview = detail;
        changed = true;
        break;
      }
    }
    if (!changed) {
      void this.loadSessions(deviceId);
      return;
    }
    if (changed) this.notify();
  }

  private rememberActivity(deviceId: string, sessionId: string, detail: string): void {
    let pending = this.pendingActivityByDevice.get(deviceId);
    if (pending === undefined) {
      pending = new Map<string, string>();
      this.pendingActivityByDevice.set(deviceId, pending);
    }
    pending.set(sessionId, detail);
  }

  private applyPendingActivity(deviceId: string, sessions: RemoteSession[]): void {
    const pending = this.pendingActivityByDevice.get(deviceId);
    if (pending === undefined) return;
    for (let i = 0; i < sessions.length; i++) {
      const detail = pending.get(sessions[i].id);
      if (detail !== undefined) sessions[i].preview = detail;
    }
  }

  private mergeSession(base: RemoteSession, patch: Record<string, Object>): RemoteSession {
    // 以 base 为底，patch 覆盖已知字段（未知字段忽略，等待下次整表重拉）。
    const merged = new RemoteSession();
    merged.id = base.id;
    merged.userId = base.userId;
    merged.title = base.title;
    merged.workingDir = base.workingDir;
    merged.worktreePath = base.worktreePath;
    merged.extraDirs = base.extraDirs.slice();
    merged.remoteHostId = base.remoteHostId;
    merged.workspaceKind = base.workspaceKind;
    merged.model = base.model;
    merged.providerId = base.providerId;
    merged.effort = base.effort;
    merged.permissionMode = base.permissionMode;
    merged.planModeEnabled = base.planModeEnabled;
    merged.fastMode = base.fastMode;
    merged.sdkSessionId = base.sdkSessionId;
    merged.totalTokenUsage = base.totalTokenUsage;
    merged.contextTokens = base.contextTokens;
    merged.contextWindow = base.contextWindow;
    merged.status = base.status;
    merged.agentKind = base.agentKind;
    merged.source = base.source;
    merged.orcaRole = base.orcaRole;
    merged.parentSessionId = base.parentSessionId;
    merged.pinnedAt = base.pinnedAt;
    merged.userSendAt = base.userSendAt;
    merged.createdAt = base.createdAt;
    merged.updatedAt = base.updatedAt;
    merged.preview = base.preview;
    merged.messageCount = base.messageCount;
    merged.pendingLocalCreation = base.pendingLocalCreation;
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
    out['worktreePath'] = s.worktreePath;
    out['extraDirs'] = s.extraDirs;
    out['remoteHostId'] = s.remoteHostId;
    out['workspaceKind'] = s.workspaceKind;
    out['model'] = s.model;
    out['providerId'] = s.providerId;
    out['effort'] = s.effort;
    out['permissionMode'] = s.permissionMode;
    out['planModeEnabled'] = s.planModeEnabled;
    out['fastMode'] = s.fastMode;
    out['sdkSessionId'] = s.sdkSessionId;
    out['totalTokenUsage'] = s.totalTokenUsage;
    out['contextTokens'] = s.contextTokens;
    out['contextWindow'] = s.contextWindow;
    out['status'] = s.status;
    out['agentKind'] = s.agentKind;
    out['source'] = s.source;
    out['orcaRole'] = s.orcaRole;
    out['parentSessionId'] = s.parentSessionId;
    out['pinnedAt'] = s.pinnedAt;
    out['userSendAt'] = s.userSendAt;
    out['createdAt'] = s.createdAt;
    out['updatedAt'] = s.updatedAt;
    out['preview'] = s.preview;
    out['pendingLocalCreation'] = s.pendingLocalCreation;
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
        const session = parseSession(raw as Record<string, Object>);
        if (session.status !== 'deleted') out.push(session);
      }
    }
    out.sort(sortSessionsByUpdatedAt);
    return out;
  }
}

function liveActivityKeyPrefix(deviceId: string): string {
  return `${deviceId}\u0000`;
}

function liveActivityKey(deviceId: string, sessionId: string): string {
  return `${liveActivityKeyPrefix(deviceId)}${sessionId}`;
}

function liveActivityKeySuffix(sessionId: string): string {
  return `\u0000${sessionId}`;
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
