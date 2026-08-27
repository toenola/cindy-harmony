/**
 * 项目顺序同步：Harmony 只保存控制端投影，项目顺序的正本仍在被控 Desktop。
 *
 * - 单台电脑范围：读取 / 写入被控端 sidebar-settings 顺序；
 * - 所有电脑范围：由页面使用本机 viewer 顺序，不把跨设备键写回任何一台电脑；
 * - 老 Desktop 没有 channel 或没有 owner stamp 时，静默回到 viewer 投影；
 * - push / GET / APPLY 共用 owner 与 fetch fence，迟到旧快照不能覆盖新顺序。
 */

import { DlClient, DlError, DlInvokeOptions } from '../device-link/DlClient';
import { readNum, readStr, safeErrorMessage } from './TaskModels';
import { unwrapInvokeResult } from './TaskStore';

export type TaskProjectOrderMode = 'activity' | 'custom';

export class TaskProjectOrderOwnerStamp {
  dataOwnerId: string | null = null;
  ownerGeneration: number = 0;
}

export class TaskProjectOrderSnapshot {
  authoritative: boolean = false;
  available: boolean = true;
  projectOrder: TaskProjectOrderMode = 'activity';
  manualProjectOrder: string[] = [];
  ownerStamp: TaskProjectOrderOwnerStamp | undefined = undefined;
}

export class TaskProjectOrderProject {
  key: string = '';
  deviceId: string = '';
  workingDir: string = '';
}

export type TaskProjectOrderFetchKind = 'ok' | 'unavailable' | 'transient';

export class TaskProjectOrderFetchResult {
  kind: TaskProjectOrderFetchKind = 'transient';
  snapshot: TaskProjectOrderSnapshot | undefined = undefined;
}

export const SIDEBAR_GET_PROJECT_ORDER = 'sidebar-settings:get-project-order';
export const SIDEBAR_APPLY_PROJECT_ORDER = 'sidebar-settings:apply-project-order';
export const SIDEBAR_PROJECT_ORDER_CHANGED = 'sidebar-settings:project-order-changed';

/** 与 TaskListPresentation 的项目分组规则保持一致。 */
export function normalizeTaskProjectPath(value: string): string {
  const trimmed = value.trim();
  const isWindows = /^[A-Za-z]:[\\/]/.test(trimmed)
    || trimmed.startsWith('\\\\') || trimmed.startsWith('//');
  let normalized = isWindows ? trimmed.replace(/\\/g, '/') : trimmed;
  while (normalized.length > 1 && normalized.endsWith('/')) {
    if (/^[A-Za-z]:\/$/.test(normalized)) break;
    normalized = normalized.slice(0, normalized.length - 1);
  }
  if (normalized.length === 0) return '';
  const segments = normalized.split('/');
  const comparable = isWindows
    ? segments.map((segment: string) => segment.toLowerCase()) : segments;
  for (let i = 0; i < comparable.length; i++) {
    const segment = comparable[i];
    const singleContainer = segment === '.cindy-worktrees'
      || segment === '.xdt-worktrees' || segment === '.worktrees';
    const claudeContainer = segment === '.claude'
      && i + 1 < comparable.length && comparable[i + 1] === 'worktrees';
    const worktreeNameIndex = i + (claudeContainer ? 2 : 1);
    if ((singleContainer || claudeContainer) && worktreeNameIndex < segments.length) {
      normalized = segments.slice(0, i).join('/');
      break;
    }
  }
  return isWindows ? normalized.toLowerCase() : normalized;
}

/** Harmony 列表的内部键，和页面的 taskProjectKey 保持同一形态。 */
export function taskProjectOrderKey(deviceId: string, workingDir: string): string {
  return `${deviceId}:${normalizeTaskProjectPath(workingDir)}`;
}

function foldedProjectOrderKey(value: string): string {
  const separator = value.indexOf(':');
  if (separator < 0) return value.trim();
  const deviceId = value.slice(0, separator).trim();
  const path = value.slice(separator + 1);
  return `${deviceId}:${normalizeTaskProjectPath(path)}`;
}

export function normalizeTaskProjectOrder(values: readonly string[]): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  for (let i = 0; i < values.length; i++) {
    const key = foldedProjectOrderKey(values[i]);
    if (key.length === 0 || seen.has(key)) continue;
    seen.add(key);
    out.push(key);
    if (out.length >= 10000) break;
  }
  return out;
}

/** 只重排当前可见项目，完整顺序中的隐藏设备/过滤项仍留在原槽位。 */
export function reorderVisibleTaskProjectOrder(
  currentFullOrder: readonly string[],
  visibleKeys: readonly string[],
  sourceKey: string,
  targetIndex: number,
): string[] | undefined {
  const visible = normalizeTaskProjectOrder(visibleKeys);
  const source = foldedProjectOrderKey(sourceKey);
  const sourceIndex = visible.findIndex((key: string) => foldedProjectOrderKey(key) === source);
  if (sourceIndex < 0) return undefined;
  const target = Math.max(0, Math.min(visible.length - 1, Math.round(targetIndex)));
  if (sourceIndex === target) return undefined;
  const nextVisible = visible.slice();
  const moved = nextVisible.splice(sourceIndex, 1)[0];
  nextVisible.splice(target, 0, moved);
  // reconcile 的 activeKeys 语义会移除不在 active 中的项；这里把完整账本本身
  // 也放入 active 集，才能保留其它设备或筛选隐藏项的相对位置。
  const fullOrder = reconcileTaskProjectOrder(
    currentFullOrder,
    currentFullOrder.concat(visible),
  );
  const visibleSet = new Set<string>(visible);
  const remaining = nextVisible.slice();
  const out: string[] = [];
  for (let i = 0; i < fullOrder.length; i++) {
    const key = fullOrder[i];
    if (visibleSet.has(key)) {
      const replacement = remaining.shift();
      out.push(replacement === undefined ? key : replacement);
    } else {
      out.push(key);
    }
  }
  for (let i = 0; i < remaining.length; i++) out.push(remaining[i]);
  return out;
}

/** 保留仍可见的旧顺序，新项目追加末尾；Windows 大小写变化不会产生重复组。 */
export function reconcileTaskProjectOrder(
  previous: readonly string[],
  activeKeys: readonly string[],
): string[] {
  const active: string[] = [];
  const activeByFold = new Map<string, string>();
  for (let i = 0; i < activeKeys.length; i++) {
    const key = foldedProjectOrderKey(activeKeys[i]);
    if (key.length === 0 || activeByFold.has(key)) continue;
    // activeKeys 可能来自 host 的旧格式或不同大小写路径；顺序账本只保留
    // 与本地分组一致的 canonical key，避免后续 visibleSet 比较时出现双份槽位。
    activeByFold.set(key, key);
    active.push(key);
  }
  const next: string[] = [];
  const seen = new Set<string>();
  for (let i = 0; i < previous.length; i++) {
    const match = activeByFold.get(foldedProjectOrderKey(previous[i]));
    if (match === undefined || seen.has(match)) continue;
    seen.add(match);
    next.push(match);
  }
  for (let i = 0; i < active.length; i++) {
    if (seen.has(active[i])) continue;
    seen.add(active[i]);
    next.push(active[i]);
  }
  return next;
}

function readStringList(value: Object | undefined): string[] {
  if (!Array.isArray(value)) return [];
  const values = value as Object[];
  const out: string[] = [];
  for (let i = 0; i < values.length; i++) {
    if (typeof values[i] === 'string') out.push(values[i] as string);
  }
  return normalizeTaskProjectOrder(out);
}

function parseOwnerStamp(value: Object | undefined): TaskProjectOrderOwnerStamp | undefined {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return undefined;
  }
  const record = value as Record<string, Object>;
  const ownerGeneration = readNum(record, 'ownerGeneration', -1);
  if (!Number.isInteger(ownerGeneration) || ownerGeneration < 0) return undefined;
  const owner = new TaskProjectOrderOwnerStamp();
  const rawOwner = record['dataOwnerId'];
  if (rawOwner === null) owner.dataOwnerId = null;
  else if (typeof rawOwner === 'string') owner.dataOwnerId = rawOwner as string;
  else return undefined;
  owner.ownerGeneration = ownerGeneration;
  return owner;
}

export function parseTaskProjectOrderSnapshot(raw: Object | undefined): TaskProjectOrderSnapshot {
  const out = new TaskProjectOrderSnapshot();
  if (raw === undefined || raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    return out;
  }
  const record = raw as Record<string, Object>;
  out.authoritative = record['authoritative'] === true;
  out.available = record['available'] !== false;
  out.projectOrder = record['projectOrder'] === 'custom' ? 'custom' : 'activity';
  out.manualProjectOrder = readStringList(record['manualProjectOrder']);
  out.ownerStamp = parseOwnerStamp(record['ownerStamp']) ?? parseOwnerStamp(raw);
  return out;
}

function cloneSnapshot(value: TaskProjectOrderSnapshot): TaskProjectOrderSnapshot {
  const out = new TaskProjectOrderSnapshot();
  out.authoritative = value.authoritative;
  out.available = value.available;
  out.projectOrder = value.projectOrder;
  out.manualProjectOrder = value.manualProjectOrder.slice();
  if (value.ownerStamp !== undefined) {
    const stamp = new TaskProjectOrderOwnerStamp();
    stamp.dataOwnerId = value.ownerStamp.dataOwnerId;
    stamp.ownerGeneration = value.ownerStamp.ownerGeneration;
    out.ownerStamp = stamp;
  }
  return out;
}

function isMissingProjectOrderChannel(error: Object | undefined): boolean {
  if (error instanceof DlError) {
    return error.code === 'CHANNEL_NOT_ALLOWED'
      || error.code === 'REMOTE_DISABLED'
      || error.code === 'DEVICE_LINK_CHANNEL_NOT_ALLOWED'
      || error.code === 'DEVICE_LINK_REMOTE_DISABLED';
  }
  if (error !== null && typeof error === 'object' && !Array.isArray(error)) {
    const code = readStr(error as Record<string, Object>, 'code');
    if (code === 'CHANNEL_NOT_ALLOWED' || code === 'REMOTE_DISABLED'
      || code === 'DEVICE_LINK_CHANNEL_NOT_ALLOWED'
      || code === 'DEVICE_LINK_REMOTE_DISABLED') return true;
  }
  const text = safeErrorMessage(error);
  return text.indexOf('[CHANNEL_NOT_ALLOWED]') >= 0
    || text.indexOf('[REMOTE_DISABLED]') >= 0
    || text.indexOf('[DEVICE_LINK_CHANNEL_NOT_ALLOWED]') >= 0
    || text.indexOf('[DEVICE_LINK_REMOTE_DISABLED]') >= 0;
}

function remapHostKey(deviceId: string, hostKey: string): string | undefined {
  const trimmed = hostKey.trim();
  if (trimmed.length === 0) return undefined;
  if (trimmed.startsWith('local:')) {
    const path = normalizeTaskProjectPath(trimmed.slice('local:'.length));
    return path.length > 0 ? taskProjectOrderKey(deviceId, path) : undefined;
  }
  return undefined;
}

export function taskProjectOrderKeysFromHost(
  deviceId: string,
  hostKeys: readonly string[],
): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  for (let i = 0; i < hostKeys.length; i++) {
    const key = remapHostKey(deviceId, hostKeys[i]);
    if (key === undefined || seen.has(key)) continue;
    seen.add(key);
    out.push(key);
  }
  return out;
}

function remapControllerKeyToHost(
  deviceId: string,
  key: string,
  projects: readonly TaskProjectOrderProject[],
  knownHostKeys: readonly string[],
): string | undefined {
  const normalized = foldedProjectOrderKey(key);
  let candidate: string | undefined = undefined;
  for (let i = 0; i < projects.length; i++) {
    const project = projects[i];
    if (project.deviceId !== deviceId || foldedProjectOrderKey(project.key) !== normalized) continue;
    const path = normalizeTaskProjectPath(project.workingDir);
    candidate = path.length > 0 ? `local:${path}` : undefined;
    break;
  }
  if (candidate === undefined && normalized.startsWith(`${deviceId}:`)) {
    const path = normalizeTaskProjectPath(normalized.slice(deviceId.length + 1));
    candidate = path.length > 0 ? `local:${path}` : undefined;
  }
  if (candidate === undefined) return undefined;
  for (let i = 0; i < knownHostKeys.length; i++) {
    if (foldedProjectOrderKey(knownHostKeys[i]) === foldedProjectOrderKey(candidate)) {
      return knownHostKeys[i].trim();
    }
  }
  return candidate;
}

function controllerOrderToHost(
  deviceId: string,
  order: readonly string[],
  projects: readonly TaskProjectOrderProject[],
  knownHostKeys: readonly string[],
): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  for (let i = 0; i < order.length; i++) {
    const hostKey = remapControllerKeyToHost(deviceId, order[i], projects, knownHostKeys);
    if (hostKey === undefined || seen.has(hostKey)) continue;
    seen.add(hostKey);
    out.push(hostKey);
  }
  return out;
}

export class TaskProjectOrderStore {
  private client: DlClient | undefined = undefined;
  private linkOpener: ((deviceId: string) => Promise<void>) | undefined = undefined;
  private ownerIdReader: (() => string) | undefined = undefined;
  private snapshots: Map<string, TaskProjectOrderSnapshot> = new Map();
  private fetches: Map<string, Promise<TaskProjectOrderFetchResult>> = new Map();
  private fetchFence: Map<string, number> = new Map();
  private connectionGeneration: number = 0;
  private listeners: Array<(deviceId: string) => void> = [];
  private pushStamps: Map<string, TaskProjectOrderOwnerStamp> = new Map();
  private stampedDevices: Set<string> = new Set();

  attach(
    client: DlClient,
    linkOpener: (deviceId: string) => Promise<void>,
    ownerIdReader: () => string,
  ): void {
    this.client = client;
    this.linkOpener = linkOpener;
    this.ownerIdReader = ownerIdReader;
  }

  onChanged(listener: (deviceId: string) => void): () => void {
    this.listeners.push(listener);
    return (): void => {
      const index = this.listeners.indexOf(listener);
      if (index >= 0) this.listeners.splice(index, 1);
    };
  }

  snapshot(deviceId: string): TaskProjectOrderSnapshot | undefined {
    const snapshot = this.snapshots.get(deviceId);
    return snapshot === undefined ? undefined : cloneSnapshot(snapshot);
  }

  /** 连接代次变化后，允许新连接的 owner generation 重新从较小值开始。 */
  resetConnectionFence(): void {
    this.connectionGeneration += 1;
    this.fetchFence.clear();
    this.pushStamps.clear();
    this.stampedDevices.clear();
    this.fetches.clear();
  }

  clearAll(): void {
    this.snapshots.clear();
    this.resetConnectionFence();
  }

  async fetch(deviceId: string): Promise<TaskProjectOrderFetchResult> {
    const existing = this.fetches.get(deviceId);
    if (existing !== undefined) return existing;
    const token = this.fetchFence.get(deviceId) ?? 0;
    const connectionGeneration = this.connectionGeneration;
    const promise = this.fetchInternal(deviceId, token, connectionGeneration);
    this.fetches.set(deviceId, promise);
    void promise.finally(() => {
      if (this.fetches.get(deviceId) === promise) this.fetches.delete(deviceId);
    });
    return promise;
  }

  private async fetchInternal(
    deviceId: string,
    fenceToken: number,
    connectionGeneration: number,
  ): Promise<TaskProjectOrderFetchResult> {
    const result = new TaskProjectOrderFetchResult();
    const client = this.client;
    if (client === undefined || deviceId.length === 0) {
      result.kind = 'transient';
      return result;
    }
    try {
      if (this.linkOpener !== undefined) await this.linkOpener(deviceId);
      const opts = new DlInvokeOptions();
      opts.channel = SIDEBAR_GET_PROJECT_ORDER;
      opts.args = [];
      const raw = unwrapInvokeResult(await client.invoke(deviceId, opts));
      const snapshot = parseTaskProjectOrderSnapshot(raw);
      if (this.connectionGeneration === connectionGeneration
        && (this.fetchFence.get(deviceId) ?? 0) === fenceToken) {
        this.snapshots.set(deviceId, snapshot);
        this.notify(deviceId);
      }
      result.kind = 'ok';
      result.snapshot = this.snapshot(deviceId) ?? snapshot;
      return result;
    } catch (error) {
      if (isMissingProjectOrderChannel(error)) {
        const unavailable = new TaskProjectOrderSnapshot();
        unavailable.available = false;
        unavailable.authoritative = false;
        if (this.connectionGeneration === connectionGeneration
          && (this.fetchFence.get(deviceId) ?? 0) === fenceToken) {
          this.snapshots.set(deviceId, unavailable);
          this.notify(deviceId);
        }
        result.kind = 'unavailable';
        result.snapshot = this.snapshot(deviceId) ?? unavailable;
        return result;
      }
      result.kind = 'transient';
      result.snapshot = this.snapshot(deviceId);
      return result;
    }
  }

  async apply(
    deviceId: string,
    controllerOrder: readonly string[],
    projects: readonly TaskProjectOrderProject[],
    mode: TaskProjectOrderMode,
  ): Promise<TaskProjectOrderFetchResult> {
    const result = new TaskProjectOrderFetchResult();
    const client = this.client;
    const current = this.snapshots.get(deviceId);
    if (client === undefined || current === undefined || !current.available
      || current.ownerStamp === undefined) {
      result.kind = 'unavailable';
      result.snapshot = this.snapshot(deviceId);
      return result;
    }
    const ownerStamp = current.ownerStamp;
    const ownerId = this.ownerIdReader?.() ?? '';
    if (ownerId.length > 0 && ownerStamp.dataOwnerId !== ownerId) {
      result.kind = 'transient';
      result.snapshot = this.snapshot(deviceId);
      return result;
    }
    // APPLY 与 fetch / push 共用同一条写入围栏。先推进 fence，使已经在路上的
    // 旧 GET 回包即使晚于 APPLY 返回，也不能把刚提交的顺序倒灌回来。
    const requestFence = (this.fetchFence.get(deviceId) ?? 0) + 1;
    this.fetchFence.set(deviceId, requestFence);
    const connectionGeneration = this.connectionGeneration;
    try {
      if (this.linkOpener !== undefined) await this.linkOpener(deviceId);
      const opts = new DlInvokeOptions();
      opts.channel = SIDEBAR_APPLY_PROJECT_ORDER;
      const payload: Record<string, Object> = {};
      // Record<string, Object> 不接受 null，但 wire payload 仍须保留 null owner。
      payload['dataOwnerId'] = ownerStamp.dataOwnerId as Object;
      payload['ownerGeneration'] = ownerStamp.ownerGeneration;
      payload['manualProjectOrder'] = controllerOrderToHost(
        deviceId,
        controllerOrder,
        projects,
        current.manualProjectOrder,
      );
      payload['projectOrder'] = mode;
      opts.args = [payload];
      const raw = unwrapInvokeResult(await client.invoke(deviceId, opts));
      const next = parseTaskProjectOrderSnapshot(raw);
      // push 若已先到达，保留 push 的最新水印；否则 APPLY 回包就是当前权威快照。
      if (this.connectionGeneration === connectionGeneration
        && (this.fetchFence.get(deviceId) ?? 0) === requestFence) {
        this.snapshots.set(deviceId, next);
        this.notify(deviceId);
      }
      result.kind = 'ok';
      result.snapshot = this.snapshot(deviceId) ?? next;
      return result;
    } catch (error) {
      result.kind = isMissingProjectOrderChannel(error) ? 'unavailable' : 'transient';
      result.snapshot = this.snapshot(deviceId);
      return result;
    }
  }

  /** 将被控端 local:/path 顺序转换成 Harmony 多设备列表键。 */
  controllerKeys(deviceId: string): string[] {
    const snapshot = this.snapshots.get(deviceId);
    return snapshot === undefined ? [] : taskProjectOrderKeysFromHost(
      deviceId,
      snapshot.manualProjectOrder,
    );
  }

  handlePush(
    deviceId: string,
    payload: Object | undefined,
    ownerStampValue: Object | undefined = undefined,
  ): boolean {
    const incomingSnapshot = parseTaskProjectOrderSnapshot(payload);
    const payloadRecord = payload !== undefined && payload !== null
      && typeof payload === 'object' && !Array.isArray(payload)
      ? payload as Record<string, Object> : undefined;
    const hasPayloadStamp = payloadRecord !== undefined
      && (payloadRecord['ownerStamp'] !== undefined
        || payloadRecord['dataOwnerId'] !== undefined
        || payloadRecord['ownerGeneration'] !== undefined);
    const incomingStamp = parseOwnerStamp(ownerStampValue)
      ?? incomingSnapshot.ownerStamp;
    const incomingPresent = ownerStampValue !== undefined || hasPayloadStamp;
    // GET 回包也可能先建立了带 owner 的快照；后续无水印 push 不能把它降级成
    // 无法 apply 的本地投影，带水印 push 则必须继续沿用同一代次比较。
    const current = this.snapshots.get(deviceId);
    const previous = this.pushStamps.get(deviceId) ?? current?.ownerStamp;
    const controllerOwnerId = this.ownerIdReader?.() ?? '';
    if (controllerOwnerId.length === 0) return false;
    if (!incomingPresent && (this.stampedDevices.has(deviceId)
      || current?.ownerStamp !== undefined)) return false;
    if (incomingPresent && incomingStamp === undefined) return false;
    if (incomingStamp !== undefined) {
      if (incomingStamp.dataOwnerId !== controllerOwnerId) return false;
      if (previous !== undefined && incomingStamp.ownerGeneration < previous.ownerGeneration) return false;
      this.stampedDevices.add(deviceId);
      this.pushStamps.set(deviceId, incomingStamp);
    }
    incomingSnapshot.available = true;
    if (incomingStamp !== undefined) incomingSnapshot.ownerStamp = incomingStamp;
    this.snapshots.set(deviceId, incomingSnapshot);
    this.fetchFence.set(deviceId, (this.fetchFence.get(deviceId) ?? 0) + 1);
    this.notify(deviceId);
    return true;
  }

  private notify(deviceId: string): void {
    for (let i = 0; i < this.listeners.length; i++) this.listeners[i](deviceId);
  }
}
