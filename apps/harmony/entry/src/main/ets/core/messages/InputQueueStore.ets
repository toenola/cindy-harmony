/**
 * Harmony 输入队列。
 *
 * 权威状态来自 Desktop `maker:input:get-projection` 与
 * `maker:input:projection` push；页面只消费归一化投影。所有操作复用 Mobile
 * 已使用的 `maker:input:*` 通道，不创建 Harmony 专用协议。
 */
import { DlClient, DlError, DlInvokeOptions, isSafeUnsentDlError } from '../device-link/DlClient';
import { RemoteImageRef, RemoteSerializedAttachment } from '../attachments/AttachmentModels';
import { RemoteSession, readBool, readObj, readStr } from '../tasks/TaskModels';
import { unwrapInvokeResult } from '../tasks/TaskStore';
import { buildPersistedUserContent } from './MessageStore';
import { SerializedComposerDocument } from './ComposerDocument';

const SETTLING_WINDOW_MS = 10000;

export class QueuedInputItem {
  clientId: string = '';
  text: string = '';
  persistedContent: string = '';
  createdAt: string = '';
  raw: Record<string, Object> = {};
  images: RemoteImageRef[] = [];
  files: RemoteSerializedAttachment[] = [];
}

export class InputProjectionState {
  sessionId: string = '';
  pendingQueue: QueuedInputItem[] = [];
  steeringQueueClientIds: string[] = [];
  queuePaused: boolean = false;
  queueExpanded: boolean = false;
  queueInteractionLocks: string[] = [];
  queueEditLocks: string[] = [];
  queueAbortPending: boolean = false;
  error: string = '';
  errorRetryText: string = '';
  credentialSwitchWaiting: boolean = false;
  credentialSwitchBlockedBy: string[] = [];
  autoResumePending: Record<string, Object> | undefined = undefined;
  continuationTurnClientId: string = '';
  continuationInFlightProjectionCapability: string = 'unknown';
}

class ActiveInputTarget {
  deviceId: string = '';
  references: number = 0;
}

class DeferredDispatchTarget {
  deviceId: string = '';
  session: RemoteSession = new RemoteSession();
}

class ConnectionDispatchTarget {
  deviceId: string = '';
  session: RemoteSession = new RemoteSession();
}

export class PendingQueueBubble {
  clientId: string = '';
  text: string = '';
  phase: string = 'queued';
  queueIndex: number = 0;
  errorText: string = '';
  images: RemoteImageRef[] = [];
  files: RemoteSerializedAttachment[] = [];
}

/**
 * ArkUI 的 ForEach 会按 key 复用节点；队列气泡的 clientId 在整个发送生命周期不变，
 * 因此 key 还必须包含会改变展示的投影字段，才能让“发送中 → 队列 N”和出队后的
 * 序号递补立即重建对应行。
 */
export function pendingQueueBubbleRenderKey(item: PendingQueueBubble): string {
  let contentHash = 0;
  const content = `${item.text}\n${item.errorText}`;
  for (let i = 0; i < content.length; i++) {
    contentHash = ((contentHash * 31) + content.charCodeAt(i)) >>> 0;
  }
  return `message-${item.clientId}-${item.phase}-${item.queueIndex}-${contentHash}`
    + `-${item.images.length}-${item.files.length}`;
}

function readStringArray(value: Object | undefined): string[] {
  const out: string[] = [];
  if (!Array.isArray(value)) return out;
  const list = value as Object[];
  for (let i = 0; i < list.length; i++) {
    if (typeof list[i] === 'string') out.push(list[i] as string);
  }
  return out;
}

/** 与 Mobile 的产品 turn 终态判定同源；provider continuation 边界不算终态。 */
export function isTerminalMakerInputEvent(event: Object | undefined): boolean {
  if (event === undefined || event === null || typeof event !== 'object' || Array.isArray(event)) {
    return false;
  }
  const record = event as Record<string, Object>;
  const continuation = record['turnContinuationId'];
  const hasContinuation = typeof continuation === 'number'
    && Number.isSafeInteger(continuation) && continuation >= 0;
  if (hasContinuation) return false;
  const type = readStr(record, 'type');
  if (type === 'done') return true;
  if (type === 'error') {
    const data = readObj(record, 'data');
    return readBool(data, 'isTerminal', !readBool(data, 'willRetry', false));
  }
  if (type === 'status') {
    const data = readObj(record, 'data');
    return data['isRunning'] === false;
  }
  return false;
}

function parseImages(value: Object | undefined): RemoteImageRef[] {
  const out: RemoteImageRef[] = [];
  if (!Array.isArray(value)) return out;
  const rows = value as Object[];
  for (let i = 0; i < rows.length; i++) {
    const raw = rows[i];
    if (raw === undefined || raw === null || typeof raw !== 'object' || Array.isArray(raw)) continue;
    const record = raw as Record<string, Object>;
    const image = new RemoteImageRef();
    image.url = readStr(record, 'url');
    if (image.url.length === 0) image.url = readStr(record, 'path');
    image.originalName = readStr(record, 'originalName');
    if (image.originalName.length === 0) image.originalName = readStr(record, 'name');
    image.mimeType = readStr(record, 'mimeType');
    const size = record['size'];
    image.size = typeof size === 'number' ? size : 0;
    image.sha256 = readStr(record, 'sha256');
    image.base64 = readStr(record, 'base64');
    if (image.url.length > 0 || image.base64.length > 0) out.push(image);
  }
  return out;
}

function parseAttachments(value: Object | undefined): RemoteSerializedAttachment[] {
  const out: RemoteSerializedAttachment[] = [];
  if (!Array.isArray(value)) return out;
  const rows = value as Object[];
  for (let i = 0; i < rows.length; i++) {
    const raw = rows[i];
    if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) continue;
    const row = raw as Record<string, Object>;
    const item = new RemoteSerializedAttachment();
    item.id = readStr(row, 'id'); item.name = readStr(row, 'name'); item.path = readStr(row, 'path');
    item.ext = readStr(row, 'ext'); item.sha256 = readStr(row, 'sha256');
    item.category = readStr(row, 'category'); item.mimeType = readStr(row, 'mimeType');
    item.url = readStr(row, 'url'); item.originalName = readStr(row, 'originalName');
    const size = row['size']; item.size = typeof size === 'number' ? size : 0;
    if (item.path.length > 0 && item.category !== 'image') out.push(item);
  }
  return out;
}

export function parseQueuedInputItem(raw: Record<string, Object>): QueuedInputItem | null {
  const sanitized: Record<string, Object> = {};
  const keys = Object.keys(raw);
  for (let i = 0; i < keys.length; i++) {
    if (keys[i] === 'trustedSessionReferenceContexts'
      || keys[i] === 'sessionReferencesRequireTrustedSnapshot') continue;
    sanitized[keys[i]] = raw[keys[i]];
  }
  const item = new QueuedInputItem();
  item.clientId = readStr(sanitized, 'clientId');
  item.text = readStr(sanitized, 'text');
  item.persistedContent = readStr(sanitized, 'persistedContent');
  item.raw = sanitized;
  const chat = readObj(sanitized, 'chatMessage');
  item.createdAt = readStr(chat, 'createdAt');
  item.images = parseImages(chat['images']);
  item.files = parseAttachments(sanitized['files']);
  if (item.clientId.length === 0
    || typeof sanitized['text'] !== 'string'
    || typeof sanitized['persistedContent'] !== 'string'
    || typeof sanitized['model'] !== 'string'
    || typeof sanitized['workingDir'] !== 'string'
    || sanitized['createOpts'] === null
    || typeof sanitized['createOpts'] !== 'object'
    || Array.isArray(sanitized['createOpts'])
    || readStr(chat, 'role') !== 'user') return null;
  return item;
}

export function parseInputProjection(
  value: Object | undefined,
  fallbackSessionId: string,
): InputProjectionState {
  const state = new InputProjectionState();
  state.sessionId = fallbackSessionId;
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return state;
  }
  const raw = value as Record<string, Object>;
  state.continuationInFlightProjectionCapability = Object.keys(raw)
    .includes('continuationTurnClientId') ? 'supported' : 'legacy';
  const sessionId = readStr(raw, 'sessionId');
  if (sessionId.length > 0) state.sessionId = sessionId;
  const queue = raw['pendingQueue'];
  if (Array.isArray(queue)) {
    const rows = queue as Object[];
    for (let i = 0; i < rows.length; i++) {
      const row = rows[i];
      if (row === undefined || row === null || typeof row !== 'object' || Array.isArray(row)) continue;
      const item = parseQueuedInputItem(row as Record<string, Object>);
      if (item !== null) state.pendingQueue.push(item);
    }
  }
  state.steeringQueueClientIds = readStringArray(raw['steeringQueueClientIds']);
  state.queuePaused = readBool(raw, 'queuePaused', false);
  state.queueExpanded = readBool(raw, 'queueExpanded', false);
  state.queueInteractionLocks = readStringArray(raw['queueInteractionLocks']);
  state.queueEditLocks = readStringArray(raw['queueEditLocks']);
  state.queueAbortPending = readBool(raw, 'queueAbortPending', false);
  state.error = readStr(raw, 'error');
  state.errorRetryText = readStr(raw, 'errorRetryText');
  const autoResumePending = raw['autoResumePending'];
  if (autoResumePending !== undefined && autoResumePending !== null
    && typeof autoResumePending === 'object' && !Array.isArray(autoResumePending)) {
    state.autoResumePending = autoResumePending as Record<string, Object>;
  }
  state.continuationTurnClientId = readStr(raw, 'continuationTurnClientId');
  const rawCredentialWait = raw['credentialSwitchWait'];
  state.credentialSwitchWaiting = rawCredentialWait !== undefined && rawCredentialWait !== null
    && typeof rawCredentialWait === 'object' && !Array.isArray(rawCredentialWait);
  const credentialWait = readObj(raw, 'credentialSwitchWait');
  state.credentialSwitchBlockedBy = readStringArray(credentialWait['blockedBySessionIds']);
  return state;
}

export class InputQueueStore {
  private client: DlClient | undefined = undefined;
  private linkOpener: ((deviceId: string) => Promise<void>) | undefined = undefined;
  private listeners: Array<() => void> = [];
  private projections: Map<string, InputProjectionState> = new Map();
  private enqueueingClientIds: Set<string> = new Set();
  private failedByClientId: Map<string, string> = new Map();
  /** 已从权威队列派发、等待正式 messages:created 回流的条目。 */
  private settlingBySession: Map<string, QueuedInputItem[]> = new Map();
  /** settling 最多保留 10 秒；消息 push 丢失时不能永久显示“正在同步”。 */
  private settlingAddedAtByClientId: Map<string, number> = new Map();
  private settlingExpiryTimers: Map<string, number> = new Map();
  /** 新任务尚未完成 create + 首条 enqueue 时，本地承接后续消息的 FIFO outbox。 */
  private deferredBySession: Map<string, QueuedInputItem[]> = new Map();
  private deferredDispatchTargets: Map<string, DeferredDispatchTarget> = new Map();
  private deferredPumps: Set<string> = new Set();
  /** 已从 deferred 移入本地 projection、但尚未被 Desktop 确认接收的条目。 */
  private deferredDispatchClientIds: Set<string> = new Set();
  /** 能证明尚未发出的断线消息；恢复投影成功后才按 FIFO 自动续发。 */
  private connectionWaitingBySession: Map<string, QueuedInputItem[]> = new Map();
  private connectionDispatchTargets: Map<string, ConnectionDispatchTarget> = new Map();
  private connectionPumps: Set<string> = new Set();
  /** 用户主动删除的条目不能被队列 diff 误判为“派发中”。 */
  private locallyRemovedClientIds: Set<string> = new Set();
  /** 删除回包与补拉都失败时，等待下一份权威投影裁决是否真的删除。 */
  private uncertainRemovalClientIds: Set<string> = new Set();
  /** 每个任务的输入投影权威代次；晚到 RPC 结果只能在代次未变化时提交。 */
  private authorityEpochs: Map<string, number> = new Map();
  private nextAuthorityEpoch: number = 0;
  private authorityEpochFloor: number = 0;
  /** 当前页面真正打开的任务；重连后只补这些投影，避免全量重放。 */
  private activeTargets: Map<string, ActiveInputTarget> = new Map();
  /** 投影所属桌面设备；用于 presence 离线/移除时精准失权。 */
  private sessionDevices: Map<string, string> = new Map();
  private sendSequence: number = 0;

  attach(client: DlClient): void {
    this.client = client;
  }

  setLinkOpener(fn: (deviceId: string) => Promise<void>): void {
    this.linkOpener = fn;
  }

  onChanged(listener: () => void): () => void {
    this.listeners.push(listener);
    return () => {
      const index = this.listeners.indexOf(listener);
      if (index >= 0) this.listeners.splice(index, 1);
    };
  }

  private notify(): void {
    for (let i = 0; i < this.listeners.length; i++) this.listeners[i]();
  }

  getProjection(sessionId: string): InputProjectionState {
    return this.projections.get(sessionId) ?? new InputProjectionState();
  }

  isLocallyFailed(clientId: string): boolean {
    return this.failedByClientId.has(clientId);
  }

  /** ACK 丢失后由消息历史确认已应用，移除仅供本地重试的失败气泡。 */
  resolveAppliedDelivery(sessionId: string, clientId: string): void {
    let changed = false;
    const projection = this.projections.get(sessionId);
    if (projection !== undefined) {
      const pending = projection.pendingQueue.filter(
        (item: QueuedInputItem) => item.clientId !== clientId);
      if (pending.length !== projection.pendingQueue.length) {
        projection.pendingQueue = pending;
        this.bumpAuthorityEpoch(sessionId);
        this.projections.set(sessionId, projection);
        changed = true;
      }
    }
    const settling = this.settlingBySession.get(sessionId);
    if (settling !== undefined) {
      const next = settling.filter((item: QueuedInputItem) => item.clientId !== clientId);
      if (next.length !== settling.length) {
        if (next.length > 0) this.settlingBySession.set(sessionId, next);
        else this.settlingBySession.delete(sessionId);
        changed = true;
      }
    }
    if (this.failedByClientId.delete(clientId)) changed = true;
    if (this.enqueueingClientIds.delete(clientId)) changed = true;
    if (this.locallyRemovedClientIds.delete(clientId)) changed = true;
    if (this.deferredDispatchClientIds.delete(clientId)) changed = true;
    const waiting = this.connectionWaitingBySession.get(sessionId);
    if (waiting !== undefined) {
      const next = waiting.filter((item: QueuedInputItem) => item.clientId !== clientId);
      if (next.length !== waiting.length) {
        if (next.length > 0) this.connectionWaitingBySession.set(sessionId, next);
        else {
          this.connectionWaitingBySession.delete(sessionId);
          this.connectionDispatchTargets.delete(sessionId);
        }
        changed = true;
      }
    }
    if (changed) this.notify();
  }

  clearLocalFailure(clientId: string): void {
    if (!this.failedByClientId.delete(clientId)) return;
    this.enqueueingClientIds.delete(clientId);
    this.notify();
  }

  markLocalFailure(sessionId: string, clientId: string, message: string): void {
    if (sessionId.length === 0 || clientId.length === 0) return;
    this.restoreFailedQueueItem(sessionId, clientId, message, null);
  }

  /** 新任务同步段先落乐观气泡，随后后台创建与 enqueue 复用同一 clientId。 */
  seedOptimisticText(
    deviceId: string,
    session: RemoteSession,
    text: string,
    images: RemoteImageRef[],
    stableClientId: string,
    replaceExisting: boolean = false,
    files: RemoteSerializedAttachment[] = [],
  ): void {
    if (session.id.length === 0 || stableClientId.length === 0) return;
    this.rememberSessionDevice(deviceId, session.id);
    const existing = this.findItem(session.id, stableClientId);
    if (existing !== null && !replaceExisting) {
      this.failedByClientId.delete(stableClientId);
      this.notify();
      return;
    }
    const serialized = new SerializedComposerDocument();
    serialized.text = text.trim();
    const item = this.buildQueuedMessage(session, serialized, images, files, stableClientId);
    const projection = this.getProjection(session.id);
    projection.sessionId = session.id;
    if (existing !== null) {
      projection.pendingQueue = projection.pendingQueue.map((queued: QueuedInputItem) =>
        queued.clientId === stableClientId ? item : queued);
    } else {
      projection.pendingQueue = projection.pendingQueue.concat([item]);
    }
    this.bumpAuthorityEpoch(session.id);
    this.projections.set(session.id, projection);
    this.failedByClientId.delete(stableClientId);
    this.notify();
  }

  /**
   * 会话参数尚未权威就绪时只进入本地 outbox，不触发任何远端 RPC。
   * 创建管线收口后 enableDeferredDispatch 会按 FIFO 逐条交接给正常输入队列。
   */
  deferDocument(
    deviceId: string,
    session: RemoteSession,
    serialized: SerializedComposerDocument,
    images: RemoteImageRef[],
    files: RemoteSerializedAttachment[],
  ): string {
    this.rememberSessionDevice(deviceId, session.id);
    const item = this.buildQueuedMessage(session, serialized, images, files);
    const current = this.deferredBySession.get(session.id) ?? [];
    this.deferredBySession.set(session.id, current.concat([item]));
    this.notify();
    return item.clientId;
  }

  /** 创建失败回编辑/首条发送失败时，把后续消息按原顺序交回页面统一恢复。 */
  takeDeferred(sessionId: string): QueuedInputItem[] {
    const items = this.deferredBySession.get(sessionId) ?? [];
    this.deferredBySession.delete(sessionId);
    this.deferredDispatchTargets.delete(sessionId);
    if (items.length > 0) this.notify();
    return items;
  }

  /** 首条消息确认后解除 outbox 派发门；循环本身保证同一任务只存在一个 pump。 */
  enableDeferredDispatch(deviceId: string, session: RemoteSession): void {
    if (session.id.length === 0) return;
    const target = new DeferredDispatchTarget();
    target.deviceId = deviceId;
    target.session = session;
    this.deferredDispatchTargets.set(session.id, target);
    void this.pumpDeferred(session.id);
  }

  /** pump 在途、失败队首或仍有本地条目时，新消息必须继续排在同一 FIFO 尾部。 */
  shouldDeferNewInput(sessionId: string): boolean {
    return this.deferredDispatchTargets.has(sessionId)
      || this.deferredPumps.has(sessionId)
      || (this.deferredBySession.get(sessionId)?.length ?? 0) > 0;
  }

  getBubbles(sessionId: string): PendingQueueBubble[] {
    const projection = this.getProjection(sessionId);
    const bubbles: PendingQueueBubble[] = [];
    const settling = this.settlingBySession.get(sessionId) ?? [];
    for (let i = 0; i < settling.length; i++) {
      const item = settling[i];
      const bubble = new PendingQueueBubble();
      bubble.clientId = item.clientId;
      bubble.text = item.text;
      bubble.phase = 'settling';
      bubble.images = item.images;
      bubble.files = item.files;
      bubbles.push(bubble);
    }
    for (let i = 0; i < projection.pendingQueue.length; i++) {
      const item = projection.pendingQueue[i];
      const bubble = new PendingQueueBubble();
      bubble.clientId = item.clientId;
      bubble.text = item.text;
      bubble.queueIndex = i + 1;
      bubble.images = item.images;
      bubble.files = item.files;
      bubble.errorText = this.failedByClientId.get(item.clientId) ?? '';
      if (bubble.errorText.length > 0) bubble.phase = 'failed';
      else if (this.enqueueingClientIds.has(item.clientId)
        || projection.steeringQueueClientIds.includes(item.clientId)) bubble.phase = 'sending';
      else if (projection.queueEditLocks.includes(item.clientId)) bubble.phase = 'editing';
      else bubble.phase = projection.queuePaused ? 'paused' : 'queued';
      bubbles.push(bubble);
    }
    const deferred = this.deferredBySession.get(sessionId) ?? [];
    for (let i = 0; i < deferred.length; i++) {
      const item = deferred[i];
      const bubble = new PendingQueueBubble();
      bubble.clientId = item.clientId;
      bubble.text = item.text;
      bubble.queueIndex = projection.pendingQueue.length + i + 1;
      bubble.images = item.images;
      bubble.files = item.files;
      bubble.phase = 'waiting';
      bubbles.push(bubble);
    }
    const connectionWaiting = this.connectionWaitingBySession.get(sessionId) ?? [];
    for (let i = 0; i < connectionWaiting.length; i++) {
      const item = connectionWaiting[i];
      const bubble = new PendingQueueBubble();
      bubble.clientId = item.clientId;
      bubble.text = item.text;
      bubble.queueIndex = projection.pendingQueue.length + deferred.length + i + 1;
      bubble.images = item.images;
      bubble.files = item.files;
      bubble.phase = this.enqueueingClientIds.has(item.clientId)
        ? 'sending' : 'connection-waiting';
      bubbles.push(bubble);
    }
    return bubbles;
  }

  handleProjectionPush(payload: Object | undefined): void {
    const projection = parseInputProjection(payload, '');
    if (projection.sessionId.length === 0) return;
    this.bumpAuthorityEpoch(projection.sessionId);
    this.applyProjectionState(projection.sessionId, projection);
    this.reconcileTransientState(projection);
    this.notify();
  }

  /** 正式消息回流后移除 settling 气泡，实现同 clientId 原位落定。 */
  setDeliveredClientIds(sessionId: string, clientIds: Set<string>): void {
    let changed = this.releaseConfirmedDeferredClients(sessionId, clientIds);
    const settling = this.settlingBySession.get(sessionId);
    if (settling !== undefined && settling.length > 0) {
      const next = settling.filter((item: QueuedInputItem) => !clientIds.has(item.clientId));
      if (next.length !== settling.length) {
        for (let i = 0; i < settling.length; i++) {
          if (clientIds.has(settling[i].clientId)) this.clearSettlingClock(settling[i].clientId);
        }
        if (next.length > 0) this.settlingBySession.set(sessionId, next);
        else this.settlingBySession.delete(sessionId);
        changed = true;
      }
    }
    if (changed) {
      this.notify();
      void this.pumpDeferred(sessionId);
      void this.pumpConnectionWaiting(sessionId);
    }
  }

  private applyProjectionState(sessionId: string, next: InputProjectionState): void {
    const previous = this.projections.get(sessionId);
    if (previous !== undefined && previous.pendingQueue.length > 0) {
      const nextIds = new Set<string>();
      for (let i = 0; i < next.pendingQueue.length; i++) nextIds.add(next.pendingQueue[i].clientId);
      const vanished: QueuedInputItem[] = [];
      // Desktop 正常 drain 从队首连续移除；中段消失按远端删除处理。
      for (let i = 0; i < previous.pendingQueue.length; i++) {
        const item = previous.pendingQueue[i];
        if (nextIds.has(item.clientId)) break;
        if (!this.locallyRemovedClientIds.has(item.clientId)) vanished.push(item);
      }
      // steer 可以从中段移除，按上一投影的 steering id 单独补入 settling。
      for (let i = 0; i < previous.steeringQueueClientIds.length; i++) {
        const clientId = previous.steeringQueueClientIds[i];
        if (nextIds.has(clientId) || this.locallyRemovedClientIds.has(clientId)
          || vanished.some((item: QueuedInputItem) => item.clientId === clientId)) continue;
        const item = previous.pendingQueue.find((row: QueuedInputItem) => row.clientId === clientId);
        if (item !== undefined) vanished.push(item);
      }
      if (vanished.length > 0) {
        const existing = this.settlingBySession.get(sessionId) ?? [];
        const merged = existing.slice();
        for (let i = 0; i < vanished.length; i++) {
          if (!merged.some((item: QueuedInputItem) => item.clientId === vanished[i].clientId)) {
            merged.push(vanished[i]);
            this.noteSettlingAdded(sessionId, vanished[i].clientId);
          }
        }
        this.settlingBySession.set(sessionId, merged);
      }
    }
    let removalResolved = false;
    this.locallyRemovedClientIds.forEach((clientId: string) => {
      const remains = next.pendingQueue.some(
        (item: QueuedInputItem) => item.clientId === clientId);
      if (!remains) {
        // 权威缺席确认 remove 已生效；不能再生成 settling 幽灵行，也不能继续挡住 FIFO。
        this.clearTransientClient(clientId);
        removalResolved = true;
      } else if (this.uncertainRemovalClientIds.delete(clientId)) {
        // 补拉失败后第一次权威“仍存在”裁决 remove 未生效，恢复普通队列语义。
        this.locallyRemovedClientIds.delete(clientId);
        removalResolved = true;
      }
    });
    this.projections.set(sessionId, next);
    if (removalResolved) void this.pumpDeferred(sessionId);
  }

  private reconcileTransientState(projection: InputProjectionState): void {
    const ids = new Set<string>();
    for (let i = 0; i < projection.pendingQueue.length; i++) {
      ids.add(projection.pendingQueue[i].clientId);
    }
    const resolvedEnqueues: string[] = [];
    this.enqueueingClientIds.forEach((clientId: string) => {
      if (ids.has(clientId)) resolvedEnqueues.push(clientId);
    });
    for (let i = 0; i < resolvedEnqueues.length; i++) {
      this.enqueueingClientIds.delete(resolvedEnqueues[i]);
      this.failedByClientId.delete(resolvedEnqueues[i]);
    }
    if (this.releaseConfirmedDeferredClients(projection.sessionId, ids)) {
      void this.pumpDeferred(projection.sessionId);
    }
  }

  /** projection 或正式 transcript 命中 clientId 即是 ACK 丢失路径的权威成功证明。 */
  private releaseConfirmedDeferredClients(sessionId: string, clientIds: Set<string>): boolean {
    let changed = false;
    const confirmed: string[] = [];
    this.deferredDispatchClientIds.forEach((clientId: string) => {
      if (clientIds.has(clientId)) confirmed.push(clientId);
    });
    for (let i = 0; i < confirmed.length; i++) {
      this.deferredDispatchClientIds.delete(confirmed[i]);
      this.enqueueingClientIds.delete(confirmed[i]);
      this.failedByClientId.delete(confirmed[i]);
      changed = true;
    }
    return changed;
  }

  async refresh(deviceId: string, sessionId: string): Promise<boolean> {
    this.rememberSessionDevice(deviceId, sessionId);
    try {
      const expectedEpoch = this.captureAuthorityEpoch(sessionId);
      const result = await this.invoke(deviceId, 'maker:input:get-projection', [sessionId]);
      const projection = parseInputProjection(result, sessionId);
      if (this.applyProjectionIfCurrent(sessionId, projection, expectedEpoch)) {
        this.notify();
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  clearSession(sessionId: string): void {
    // 保留 per-session tombstone；clear 前启动的旧请求不得在同 id 重建后复活。
    this.bumpAuthorityEpoch(sessionId);
    this.dropProjection(sessionId);
    this.connectionWaitingBySession.delete(sessionId);
    this.connectionDispatchTargets.delete(sessionId);
    this.sessionDevices.delete(sessionId);
    this.notify();
  }

  /** 创建失败/不确定发送只清投影，保留活动页面的设备归属供后续补拉。 */
  discardProjection(sessionId: string): void {
    this.dropProjection(sessionId);
    this.bumpAuthorityEpoch(sessionId);
    this.notify();
  }

  /** 页面打开/关闭登记。相同任务可由折叠屏多个宿主同时持有，按引用计数释放。 */
  activateSession(deviceId: string, sessionId: string): void {
    if (deviceId.length === 0 || sessionId.length === 0) return;
    this.rememberSessionDevice(deviceId, sessionId);
    const target = this.activeTargets.get(sessionId) ?? new ActiveInputTarget();
    target.deviceId = deviceId;
    target.references += 1;
    this.activeTargets.set(sessionId, target);
  }

  deactivateSession(deviceId: string, sessionId: string): void {
    const target = this.activeTargets.get(sessionId);
    if (target === undefined || target.deviceId !== deviceId) return;
    target.references -= 1;
    if (target.references <= 0) this.activeTargets.delete(sessionId);
  }

  /** Relay 重连后补拉当前打开任务的输入投影。 */
  async resyncActiveSessions(): Promise<void> {
    const pending: Promise<void>[] = [];
    this.activeTargets.forEach((target: ActiveInputTarget, sessionId: string) => {
      pending.push(this.refreshThenPumpConnection(target.deviceId, sessionId));
    });
    await Promise.all(pending);
  }

  async resyncDevice(deviceId: string): Promise<void> {
    const pending: Promise<void>[] = [];
    this.activeTargets.forEach((target: ActiveInputTarget, sessionId: string) => {
      if (target.deviceId === deviceId) {
        pending.push(this.refreshThenPumpConnection(deviceId, sessionId));
      }
    });
    await Promise.all(pending);
  }

  private async refreshThenPumpConnection(deviceId: string, sessionId: string): Promise<void> {
    const refreshed = await this.refresh(deviceId, sessionId);
    if (refreshed) await this.pumpConnectionWaiting(sessionId);
  }

  /** 目标桌面离线、撤权或从权威设备快照移除：旧投影立即删除并 fence 在途 RPC。 */
  invalidateDevice(deviceId: string): void {
    let changed = false;
    const sessionIds: string[] = [];
    this.sessionDevices.forEach((ownerDeviceId: string, sessionId: string) => {
      if (ownerDeviceId === deviceId) sessionIds.push(sessionId);
    });
    for (let i = 0; i < sessionIds.length; i++) {
      this.dropProjection(sessionIds[i]);
      this.bumpAuthorityEpoch(sessionIds[i]);
      changed = true;
    }
    if (changed) this.notify();
  }

  /** REST 设备列表是全量快照；缺席设备与明确不可用设备都按移除处理。 */
  reconcileDeviceSnapshot(seenDeviceIds: Set<string>, availableDeviceIds: Set<string>): void {
    const invalidDevices = new Set<string>();
    this.sessionDevices.forEach((deviceId: string) => {
      if (!seenDeviceIds.has(deviceId) || !availableDeviceIds.has(deviceId)) {
        invalidDevices.add(deviceId);
      }
    });
    invalidDevices.forEach((deviceId: string) => this.invalidateDevice(deviceId));
    availableDeviceIds.forEach((deviceId: string) => {
      void this.resyncDevice(deviceId);
    });
  }

  /** socket 断开使所有在途快照失权，但保留最后投影供离线 UI 平滑展示。 */
  invalidateActiveAuthorities(): void {
    this.activeTargets.forEach((_target: ActiveInputTarget, sessionId: string) => {
      this.bumpAuthorityEpoch(sessionId);
    });
  }

  captureAuthorityEpoch(sessionId: string): number {
    return this.authorityEpochs.get(sessionId) ?? this.authorityEpochFloor;
  }

  invalidateAuthority(sessionId: string): void {
    this.bumpAuthorityEpoch(sessionId);
  }

  /** maker 终态是 continuation owner 的权威 fence；即使 clear push 丢失也要收口。 */
  noteTurnTerminal(sessionId: string): void {
    if (sessionId.length === 0) return;
    this.bumpAuthorityEpoch(sessionId);
    const current = this.projections.get(sessionId);
    if (current !== undefined && current.continuationTurnClientId.length > 0) {
      current.continuationTurnClientId = '';
      this.projections.set(sessionId, current);
      this.notify();
    }
  }

  /** 全局登出/账号切换使用的代次地板；旧请求不能给重建后的同名任务灌回数据。 */
  clearAll(): void {
    this.projections.clear();
    this.settlingBySession.clear();
    this.settlingAddedAtByClientId.clear();
    this.settlingExpiryTimers.forEach((timer: number) => clearTimeout(timer));
    this.settlingExpiryTimers.clear();
    this.deferredBySession.clear();
    this.deferredDispatchTargets.clear();
    this.deferredPumps.clear();
    this.deferredDispatchClientIds.clear();
    this.connectionWaitingBySession.clear();
    this.connectionDispatchTargets.clear();
    this.connectionPumps.clear();
    this.enqueueingClientIds.clear();
    this.failedByClientId.clear();
    this.locallyRemovedClientIds.clear();
    this.uncertainRemovalClientIds.clear();
    this.activeTargets.clear();
    this.sessionDevices.clear();
    this.authorityEpochFloor = ++this.nextAuthorityEpoch;
    this.authorityEpochs.clear();
    this.notify();
  }

  async enqueueText(
    deviceId: string,
    session: RemoteSession,
    text: string,
    images: RemoteImageRef[],
    stableClientId: string = '',
  ): Promise<string> {
    const serialized = new SerializedComposerDocument();
    serialized.text = text.trim();
    return this.enqueueDocument(deviceId, session, serialized, images, [], stableClientId);
  }

  async enqueueDocument(
    deviceId: string,
    session: RemoteSession,
    serialized: SerializedComposerDocument,
    images: RemoteImageRef[],
    files: RemoteSerializedAttachment[],
    stableClientId: string = '',
    planModeOverride: boolean | null = null,
  ): Promise<string> {
    this.rememberSessionDevice(deviceId, session.id);
    if (stableClientId.length > 0) {
      const existing = this.findItem(session.id, stableClientId);
      if (existing !== null) {
        await this.retry(deviceId, session.id, stableClientId);
        return stableClientId;
      }
    }
    const item = this.buildQueuedMessage(
      session, serialized, images, files, stableClientId, planModeOverride);
    if (this.client?.getStatus() !== 'online'
      || (this.connectionWaitingBySession.get(session.id)?.length ?? 0) > 0
      || this.connectionPumps.has(session.id)) {
      this.parkForConnection(deviceId, session, item);
      return item.clientId;
    }
    const projection = this.getProjection(session.id);
    projection.sessionId = session.id;
    projection.pendingQueue = projection.pendingQueue.concat([item]);
    this.bumpAuthorityEpoch(session.id);
    this.projections.set(session.id, projection);
    this.enqueueingClientIds.add(item.clientId);
    this.failedByClientId.delete(item.clientId);
    this.notify();

    const sendOptions: Record<string, Object> = {};
    sendOptions['sendAtMs'] = Date.now();
    try {
      const expectedEpoch = this.captureAuthorityEpoch(session.id);
      const result = await this.invoke(deviceId, 'maker:input:enqueue', [session.id, item.raw, sendOptions]);
      this.applyProjectionResultIfCurrent(session.id, result, expectedEpoch);
      this.enqueueingClientIds.delete(item.clientId);
      this.failedByClientId.delete(item.clientId);
      this.notify();
      return item.clientId;
    } catch (e) {
      if (isSafeUnsentDlError(e)) {
        this.removeLocalProjectionItem(session.id, item.clientId);
        this.parkForConnection(deviceId, session, item);
        return item.clientId;
      }
      // NOT_CONNECTED 可能发生在 host 已接收之后；先权威对账再决定是否标失败。
      const applied = await this.refresh(deviceId, session.id);
      if (applied && this.findItem(session.id, item.clientId) !== null) {
        this.enqueueingClientIds.delete(item.clientId);
        this.failedByClientId.delete(item.clientId);
        this.notify();
        return item.clientId;
      }
      const message = e instanceof Error ? e.message : JSON.stringify(e);
      // 空权威投影会先把乐观项移到 settling；恢复失败入口前必须清掉同 id
      // 的 settling，否则 UI 会同时出现“同步中 + 发送失败”两张气泡。
      this.restoreFailedQueueItem(session.id, item.clientId, message, item);
      throw new Error(message);
    }
  }

  async retry(deviceId: string, sessionId: string, clientId: string): Promise<void> {
    const item = this.findItem(sessionId, clientId);
    if (item === null || this.enqueueingClientIds.has(clientId)) return;
    this.enqueueingClientIds.add(clientId);
    this.failedByClientId.delete(clientId);
    const deferredDispatch = this.deferredDispatchClientIds.has(clientId);
    this.notify();
    const sendOptions: Record<string, Object> = {};
    sendOptions['sendAtMs'] = Date.now();
    try {
      const expectedEpoch = this.captureAuthorityEpoch(sessionId);
      const result = await this.invoke(deviceId, 'maker:input:enqueue', [sessionId, item.raw, sendOptions]);
      this.applyProjectionResultIfCurrent(sessionId, result, expectedEpoch);
      this.enqueueingClientIds.delete(clientId);
      this.deferredDispatchClientIds.delete(clientId);
      this.notify();
      void this.pumpDeferred(sessionId);
      void this.pumpConnectionWaiting(sessionId);
    } catch (e) {
      if (deferredDispatch && !this.deferredDispatchClientIds.has(clientId)) {
        this.enqueueingClientIds.delete(clientId);
        this.failedByClientId.delete(clientId);
        this.notify();
        void this.pumpDeferred(sessionId);
        return;
      }
      const message = e instanceof Error ? e.message : JSON.stringify(e);
      this.restoreFailedQueueItem(sessionId, clientId, message, item);
      throw new Error(message);
    }
  }

  async remove(deviceId: string, sessionId: string, clientId: string): Promise<void> {
    const connectionWaiting = this.connectionWaitingBySession.get(sessionId) ?? [];
    if (connectionWaiting.some((item: QueuedInputItem) => item.clientId === clientId)) {
      const next = connectionWaiting.filter((item: QueuedInputItem) => item.clientId !== clientId);
      if (next.length > 0) this.connectionWaitingBySession.set(sessionId, next);
      else {
        this.connectionWaitingBySession.delete(sessionId);
        this.connectionDispatchTargets.delete(sessionId);
      }
      this.clearTransientClient(clientId);
      this.notify();
      return;
    }
    const deferred = this.deferredBySession.get(sessionId) ?? [];
    const deferredIndex = deferred.findIndex(
      (item: QueuedInputItem) => item.clientId === clientId);
    if (deferredIndex >= 0) {
      const next = deferred.filter((item: QueuedInputItem) => item.clientId !== clientId);
      if (next.length > 0) this.deferredBySession.set(sessionId, next);
      else this.deferredBySession.delete(sessionId);
      this.clearTransientClient(clientId);
      this.notify();
      void this.pumpDeferred(sessionId);
      return;
    }
    const projection = this.getProjection(sessionId);
    const index = projection.pendingQueue.findIndex((item: QueuedInputItem) => item.clientId === clientId);
    const removed = index >= 0 ? projection.pendingQueue[index] : undefined;
    const removedFailure = this.failedByClientId.get(clientId) ?? '';
    this.bumpAuthorityEpoch(sessionId);
    this.locallyRemovedClientIds.add(clientId);
    this.uncertainRemovalClientIds.delete(clientId);
    if (index >= 0) projection.pendingQueue.splice(index, 1);
    this.failedByClientId.delete(clientId);
    this.notify();
    const expectedEpoch = this.captureAuthorityEpoch(sessionId);
    try {
      const result = await this.invoke(deviceId, 'maker:input:remove', [sessionId, clientId]);
      this.applyProjectionResultIfCurrent(sessionId, result, expectedEpoch);
      this.deferredDispatchClientIds.delete(clientId);
      this.notify();
      void this.pumpDeferred(sessionId);
    } catch (e) {
      if ((e instanceof DlError && e.code === 'NOT_FOUND')
        || (e instanceof Error && e.message.indexOf('[NOT_FOUND]') >= 0)) {
        this.clearTransientClient(clientId);
        this.notify();
        void this.pumpDeferred(sessionId);
        return;
      }
      // Desktop 可能已先 emit 删除后的 projection、仅 RPC ACK 丢失。先权威补拉，
      // 缺席即按成功收口；只有仍无法裁决时才把本地条目恢复为可操作状态。
      await this.refresh(deviceId, sessionId);
      if (!this.locallyRemovedClientIds.has(clientId)
        && this.findItem(sessionId, clientId) === null) {
        this.clearTransientClient(clientId);
        this.notify();
        void this.pumpDeferred(sessionId);
        return;
      }
      if (this.findItem(sessionId, clientId) !== null) {
        this.locallyRemovedClientIds.delete(clientId);
        this.uncertainRemovalClientIds.delete(clientId);
      }
      if (removed !== undefined && this.findItem(sessionId, clientId) === null) {
        const current = this.getProjection(sessionId);
        this.bumpAuthorityEpoch(sessionId);
        current.pendingQueue.splice(Math.min(index, current.pendingQueue.length), 0, removed);
        this.projections.set(sessionId, current);
        this.uncertainRemovalClientIds.add(clientId);
        if (removedFailure.length > 0) this.failedByClientId.set(clientId, removedFailure);
      }
      this.notify();
      const message = e instanceof Error ? e.message : JSON.stringify(e);
      throw new Error(message);
    }
  }

  async move(
    deviceId: string,
    sessionId: string,
    clientId: string,
    targetIndex: number,
  ): Promise<void> {
    const expectedEpoch = this.captureAuthorityEpoch(sessionId);
    const result = await this.invoke(deviceId, 'maker:input:move', [sessionId, clientId, targetIndex]);
    this.applyProjectionResultIfCurrent(sessionId, result, expectedEpoch);
    this.notify();
  }

  async setEditLock(
    deviceId: string,
    sessionId: string,
    clientId: string,
    locked: boolean,
  ): Promise<void> {
    const expectedEpoch = this.captureAuthorityEpoch(sessionId);
    const result = await this.invoke(deviceId, 'maker:input:set-edit-lock',
      [sessionId, clientId, locked]);
    this.applyProjectionResultIfCurrent(sessionId, result, expectedEpoch);
    this.notify();
  }

  async updateText(
    deviceId: string,
    sessionId: string,
    clientId: string,
    text: string,
  ): Promise<void> {
    const item = this.findItem(sessionId, clientId);
    if (item === null) return;
    const next = this.cloneItemWithText(item, text);
    const expectedEpoch = this.captureAuthorityEpoch(sessionId);
    const result = await this.invoke(deviceId, 'maker:input:update-content',
      [sessionId, clientId, next.raw]);
    this.applyProjectionResultIfCurrent(sessionId, result, expectedEpoch);
    this.notify();
  }

  async updateDocument(
    deviceId: string,
    sessionId: string,
    clientId: string,
    serialized: SerializedComposerDocument,
  ): Promise<void> {
    const item = this.findItem(sessionId, clientId);
    if (item === null) return;
    const next = this.cloneItemWithDocument(item, serialized);
    const expectedEpoch = this.captureAuthorityEpoch(sessionId);
    const result = await this.invoke(deviceId, 'maker:input:update-content',
      [sessionId, clientId, next.raw]);
    this.applyProjectionResultIfCurrent(sessionId, result, expectedEpoch);
    this.notify();
  }

  async steer(deviceId: string, sessionId: string, clientId: string): Promise<void> {
    const item = this.findItem(sessionId, clientId);
    if (item === null) return;
    const options: Record<string, Object> = {};
    options['removeFromQueue'] = true;
    options['touchUserSend'] = true;
    await this.invoke(deviceId, 'maker:input:steer', [sessionId, item.raw, options]);
    await this.refresh(deviceId, sessionId);
  }

  async stop(deviceId: string, sessionId: string): Promise<void> {
    const projection = this.getProjection(sessionId);
    const args: Object[] = [sessionId];
    if (projection.pendingQueue.length > 0) {
      const options: Record<string, Object> = {};
      options['keepQueue'] = true;
      options['pauseQueue'] = true;
      args.push(options);
    }
    // Stop 是终态写：先立新代次屏障，旧 refresh / 队列写即使先返回也不得覆盖它。
    const expectedEpoch = this.bumpAuthorityEpoch(sessionId);
    const result = await this.invoke(deviceId, 'maker:input:stop', args);
    this.applyProjectionResultIfCurrent(sessionId, result, expectedEpoch);
    this.notify();
  }

  async resume(deviceId: string, sessionId: string): Promise<void> {
    const expectedEpoch = this.captureAuthorityEpoch(sessionId);
    const result = await this.invoke(deviceId, 'maker:input:resume', [sessionId]);
    this.applyProjectionResultIfCurrent(sessionId, result, expectedEpoch);
    this.notify();
  }

  async retryLastError(deviceId: string, sessionId: string): Promise<void> {
    const expectedEpoch = this.captureAuthorityEpoch(sessionId);
    const result = await this.invoke(deviceId, 'maker:input:retry-last-error', [sessionId]);
    this.applyProjectionResultIfCurrent(sessionId, result, expectedEpoch);
    this.notify();
  }

  async clearError(deviceId: string, sessionId: string): Promise<void> {
    const expectedEpoch = this.captureAuthorityEpoch(sessionId);
    const result = await this.invoke(deviceId, 'maker:input:clear-error', [sessionId]);
    this.applyProjectionResultIfCurrent(sessionId, result, expectedEpoch);
    this.notify();
  }

  private applyProjectionResultIfCurrent(
    sessionId: string,
    result: Object | undefined,
    expectedEpoch: number,
  ): boolean {
    if (result === undefined || typeof result !== 'object' || Array.isArray(result)) return false;
    const projection = parseInputProjection(result, sessionId);
    return this.applyProjectionIfCurrent(sessionId, projection, expectedEpoch);
  }

  private applyProjectionIfCurrent(
    sessionId: string,
    projection: InputProjectionState,
    expectedEpoch: number,
  ): boolean {
    if (this.captureAuthorityEpoch(sessionId) !== expectedEpoch) return false;
    this.bumpAuthorityEpoch(sessionId);
    this.applyProjectionState(sessionId, projection);
    this.reconcileTransientState(projection);
    return true;
  }

  private bumpAuthorityEpoch(sessionId: string): number {
    const next = ++this.nextAuthorityEpoch;
    this.authorityEpochs.set(sessionId, next);
    return next;
  }

  private rememberSessionDevice(deviceId: string, sessionId: string): void {
    if (deviceId.length > 0 && sessionId.length > 0) this.sessionDevices.set(sessionId, deviceId);
  }

  private dropProjection(sessionId: string): void {
    const projection = this.projections.get(sessionId);
    if (projection !== undefined) {
      for (let i = 0; i < projection.pendingQueue.length; i++) {
        this.clearTransientClient(projection.pendingQueue[i].clientId);
      }
    }
    const settling = this.settlingBySession.get(sessionId) ?? [];
    for (let i = 0; i < settling.length; i++) {
      this.clearSettlingClock(settling[i].clientId);
      this.clearTransientClient(settling[i].clientId);
    }
    this.projections.delete(sessionId);
    this.settlingBySession.delete(sessionId);
    const deferred = this.deferredBySession.get(sessionId) ?? [];
    for (let i = 0; i < deferred.length; i++) {
      this.clearTransientClient(deferred[i].clientId);
    }
    this.deferredBySession.delete(sessionId);
    this.deferredDispatchTargets.delete(sessionId);
  }

  private removeLocalProjectionItem(sessionId: string, clientId: string): void {
    const projection = this.projections.get(sessionId);
    if (projection !== undefined) {
      projection.pendingQueue = projection.pendingQueue.filter(
        (item: QueuedInputItem) => item.clientId !== clientId);
      this.bumpAuthorityEpoch(sessionId);
      this.projections.set(sessionId, projection);
    }
    const settling = this.settlingBySession.get(sessionId);
    if (settling !== undefined) {
      const next = settling.filter((item: QueuedInputItem) => item.clientId !== clientId);
      if (next.length > 0) this.settlingBySession.set(sessionId, next);
      else this.settlingBySession.delete(sessionId);
      this.clearSettlingClock(clientId);
    }
    this.enqueueingClientIds.delete(clientId);
    this.failedByClientId.delete(clientId);
  }

  private parkForConnection(
    deviceId: string,
    session: RemoteSession,
    item: QueuedInputItem,
  ): void {
    const target = new ConnectionDispatchTarget();
    target.deviceId = deviceId;
    target.session = session;
    this.connectionDispatchTargets.set(session.id, target);
    const waiting = this.connectionWaitingBySession.get(session.id) ?? [];
    if (!waiting.some((queued: QueuedInputItem) => queued.clientId === item.clientId)) {
      this.connectionWaitingBySession.set(session.id, waiting.concat([item]));
    }
    this.enqueueingClientIds.delete(item.clientId);
    this.failedByClientId.delete(item.clientId);
    this.notify();
  }

  /**
   * await enqueue 期间仍允许新消息追加到同一 outbox。出队必须重新读取最新队列，
   * 不能用 await 前的数组回写，否则会覆盖并丢掉刚追加的尾项。
   */
  private consumeConnectionWaitingHead(sessionId: string, clientId: string): boolean {
    const latest = this.connectionWaitingBySession.get(sessionId) ?? [];
    if (latest.length === 0 || latest[0].clientId !== clientId) return false;
    const next = latest.slice(1);
    if (next.length > 0) {
      this.connectionWaitingBySession.set(sessionId, next);
    } else {
      this.connectionWaitingBySession.delete(sessionId);
      this.connectionDispatchTargets.delete(sessionId);
    }
    return true;
  }

  /** 仅在权威投影同步成功后调用；队首未安全送达时阻塞后续，避免消息超车。 */
  private async pumpConnectionWaiting(sessionId: string): Promise<void> {
    if (this.connectionPumps.has(sessionId)) return;
    const active = this.activeTargets.get(sessionId);
    const target = this.connectionDispatchTargets.get(sessionId);
    if (active === undefined || target === undefined || active.deviceId !== target.deviceId) return;
    this.connectionPumps.add(sessionId);
    try {
      for (;;) {
        const waiting = this.connectionWaitingBySession.get(sessionId) ?? [];
        const currentTarget = this.connectionDispatchTargets.get(sessionId);
        if (waiting.length === 0 || currentTarget === undefined) {
          this.connectionWaitingBySession.delete(sessionId);
          this.connectionDispatchTargets.delete(sessionId);
          return;
        }
        const item = waiting[0];
        this.applySessionContextToQueuedItem(item, currentTarget.session);
        this.enqueueingClientIds.add(item.clientId);
        this.notify();
        const sendOptions: Record<string, Object> = {};
        sendOptions['sendAtMs'] = Date.now();
        try {
          const expectedEpoch = this.captureAuthorityEpoch(sessionId);
          const result = await this.invoke(currentTarget.deviceId,
            'maker:input:enqueue', [sessionId, item.raw, sendOptions]);
          this.applyProjectionResultIfCurrent(sessionId, result, expectedEpoch);
          this.consumeConnectionWaitingHead(sessionId, item.clientId);
          this.enqueueingClientIds.delete(item.clientId);
          this.failedByClientId.delete(item.clientId);
          this.notify();
        } catch (e) {
          this.enqueueingClientIds.delete(item.clientId);
          if (isSafeUnsentDlError(e)) {
            this.notify();
            return;
          }
          // 已发出但 ACK 不确定：只做一次权威对账；无法确认时转人工失败，绝不自动重放。
          const applied = await this.refresh(currentTarget.deviceId, sessionId);
          if (applied && this.findItem(sessionId, item.clientId) !== null) {
            this.consumeConnectionWaitingHead(sessionId, item.clientId);
            this.notify();
            continue;
          }
          if (!this.consumeConnectionWaitingHead(sessionId, item.clientId)) return;
          const message = e instanceof Error ? e.message : JSON.stringify(e);
          this.restoreFailedQueueItem(sessionId, item.clientId, message, item);
          return;
        }
      }
    } finally {
      this.connectionPumps.delete(sessionId);
    }
  }

  /** 队首失败会留在正常 pendingQueue 并阻断后续；用户重试成功后 retry() 会再次唤醒。 */
  private async pumpDeferred(sessionId: string): Promise<void> {
    if (this.deferredPumps.has(sessionId)) return;
    const target = this.deferredDispatchTargets.get(sessionId);
    if (target === undefined) return;
    this.deferredPumps.add(sessionId);
    try {
      for (;;) {
        const currentTarget = this.deferredDispatchTargets.get(sessionId);
        const deferred = this.deferredBySession.get(sessionId) ?? [];
        if (currentTarget === undefined || deferred.length === 0) {
          if (deferred.length === 0) this.deferredDispatchTargets.delete(sessionId);
          return;
        }
        const projectionBeforeDispatch = this.getProjection(sessionId);
        let failedBarrier = false;
        this.deferredDispatchClientIds.forEach((clientId: string) => {
          if (projectionBeforeDispatch.pendingQueue.some(
            (queued: QueuedInputItem) => queued.clientId === clientId)) failedBarrier = true;
        });
        if (failedBarrier) return;
        const item = deferred[0];
        this.applySessionContextToQueuedItem(item, currentTarget.session);
        if (deferred.length > 1) this.deferredBySession.set(sessionId, deferred.slice(1));
        else this.deferredBySession.delete(sessionId);
        const projection = this.getProjection(sessionId);
        projection.sessionId = sessionId;
        projection.pendingQueue = projection.pendingQueue.concat([item]);
        this.bumpAuthorityEpoch(sessionId);
        this.projections.set(sessionId, projection);
        this.deferredDispatchClientIds.add(item.clientId);
        this.notify();
        try {
          await this.retry(currentTarget.deviceId, sessionId, item.clientId);
        } catch (e) {
          // 失败条目已由 retry 标成可见失败气泡；保留剩余 outbox，避免后发消息超车。
          return;
        }
      }
    } finally {
      this.deferredPumps.delete(sessionId);
    }
  }

  /** dialogue 的 workingDir 等字段可能到 create 后才权威，派发前统一刷新发送快照。 */
  private applySessionContextToQueuedItem(item: QueuedInputItem, session: RemoteSession): void {
    const raw = item.raw;
    raw['model'] = session.model;
    raw['effort'] = session.effort;
    raw['permissionMode'] = session.permissionMode.length > 0 ? session.permissionMode : 'ask';
    raw['workingDir'] = session.workingDir;
    const createOpts = readObj(raw, 'createOpts');
    createOpts['agentKind'] = session.agentKind === 'codex' || session.agentKind === 'pi'
      ? session.agentKind : 'claude-code';
    createOpts['workingDir'] = session.workingDir;
    createOpts['model'] = session.model;
    createOpts['effort'] = session.effort;
    createOpts['permissionMode'] = session.permissionMode.length > 0 ? session.permissionMode : 'ask';
    createOpts['fastMode'] = session.fastMode;
    if (session.providerId.length > 0) createOpts['providerId'] = session.providerId;
    if (session.remoteHostId.length > 0) createOpts['remoteHostId'] = session.remoteHostId;
    if (session.sdkSessionId.length > 0) createOpts['resumeSessionId'] = session.sdkSessionId;
    raw['createOpts'] = createOpts;
    item.raw = raw;
  }

  private clearTransientClient(clientId: string): void {
    this.enqueueingClientIds.delete(clientId);
    this.failedByClientId.delete(clientId);
    this.locallyRemovedClientIds.delete(clientId);
    this.uncertainRemovalClientIds.delete(clientId);
    this.deferredDispatchClientIds.delete(clientId);
  }

  private noteSettlingAdded(sessionId: string, clientId: string): void {
    if (clientId.length === 0 || this.settlingAddedAtByClientId.has(clientId)) return;
    this.settlingAddedAtByClientId.set(clientId, Date.now());
    const timer = setTimeout(() => {
      this.settlingExpiryTimers.delete(clientId);
      const addedAt = this.settlingAddedAtByClientId.get(clientId) ?? 0;
      if (addedAt === 0 || Date.now() - addedAt < SETTLING_WINDOW_MS) return;
      const settling = this.settlingBySession.get(sessionId) ?? [];
      const next = settling.filter((item: QueuedInputItem) => item.clientId !== clientId);
      if (next.length === settling.length) {
        this.clearSettlingClock(clientId);
        return;
      }
      if (next.length > 0) this.settlingBySession.set(sessionId, next);
      else this.settlingBySession.delete(sessionId);
      this.clearSettlingClock(clientId);
      this.notify();
    }, SETTLING_WINDOW_MS);
    this.settlingExpiryTimers.set(clientId, timer);
  }

  private clearSettlingClock(clientId: string): void {
    this.settlingAddedAtByClientId.delete(clientId);
    const timer = this.settlingExpiryTimers.get(clientId);
    if (timer !== undefined) clearTimeout(timer);
    this.settlingExpiryTimers.delete(clientId);
  }

  /** settling 与 pending 必须互斥；失败时恢复唯一、可操作的 pending 气泡。 */
  private restoreFailedQueueItem(
    sessionId: string,
    clientId: string,
    message: string,
    fallback: QueuedInputItem | null,
  ): void {
    let recovered = fallback;
    const settling = this.settlingBySession.get(sessionId);
    if (settling !== undefined) {
      const next: QueuedInputItem[] = [];
      for (let i = 0; i < settling.length; i++) {
        if (settling[i].clientId === clientId) {
          if (recovered === null) recovered = settling[i];
          this.clearSettlingClock(clientId);
        } else {
          next.push(settling[i]);
        }
      }
      if (next.length > 0) this.settlingBySession.set(sessionId, next);
      else this.settlingBySession.delete(sessionId);
    }
    const projection = this.getProjection(sessionId);
    if (recovered !== null && !projection.pendingQueue.some(
      (item: QueuedInputItem) => item.clientId === clientId)) {
      projection.sessionId = sessionId;
      projection.pendingQueue = projection.pendingQueue.concat([recovered]);
      this.bumpAuthorityEpoch(sessionId);
      this.projections.set(sessionId, projection);
    }
    this.enqueueingClientIds.delete(clientId);
    this.failedByClientId.set(clientId, message);
    this.notify();
  }

  private findItem(sessionId: string, clientId: string): QueuedInputItem | null {
    const queue = this.getProjection(sessionId).pendingQueue;
    for (let i = 0; i < queue.length; i++) {
      if (queue[i].clientId === clientId) return queue[i];
    }
    return null;
  }

  private nextClientId(): string {
    this.sendSequence += 1;
    return `harmony-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}-${this.sendSequence.toString(36)}`;
  }

  private buildQueuedMessage(
    session: RemoteSession,
    serialized: SerializedComposerDocument,
    images: RemoteImageRef[],
    files: RemoteSerializedAttachment[],
    stableClientId: string = '',
    planModeOverride: boolean | null = null,
  ): QueuedInputItem {
    const trimmed = serialized.text;
    const clientId = stableClientId.length > 0 ? stableClientId : this.nextClientId();
    const createdAt = new Date().toISOString();
    const imageObjects: Object[] = [];
    const fileObjects: Object[] = [];
    for (let i = 0; i < images.length; i++) {
      const image = images[i];
      const ref: Record<string, Object> = {};
      ref['url'] = image.url;
      ref['path'] = image.url;
      ref['name'] = image.originalName.length > 0 ? image.originalName : `image-${i + 1}`;
      ref['originalName'] = image.originalName;
      ref['mimeType'] = image.mimeType;
      ref['size'] = image.size;
      ref['sha256'] = image.sha256;
      imageObjects.push(ref);

      const file: Record<string, Object> = {};
      file['id'] = `${clientId}-image-${i}`;
      file['name'] = ref['name'];
      file['originalName'] = ref['name'];
      file['path'] = image.url;
      file['url'] = image.url;
      file['ext'] = imageExtension(image.originalName, image.mimeType);
      file['size'] = image.size;
      file['sha256'] = image.sha256;
      file['category'] = 'image';
      file['mimeType'] = image.mimeType;
      fileObjects.push(file);
    }

    const persistedFiles: Object[] = [];
    const chatFiles: Object[] = [];
    for (let i = 0; i < files.length; i++) {
      const attachment = files[i];
      fileObjects.push(attachment);
      const ref: Record<string, Object> = {};
      ref['name'] = attachment.name;
      ref['path'] = attachment.path;
      if (attachment.sha256.length > 0) {
        ref['size'] = attachment.size;
        ref['sha256'] = attachment.sha256;
      }
      persistedFiles.push(ref);
      chatFiles.push(ref);
    }

    const chat: Record<string, Object> = {};
    chat['clientId'] = clientId;
    chat['role'] = 'user';
    chat['content'] = trimmed;
    chat['images'] = imageObjects;
    chat['files'] = chatFiles;
    chat['isStreaming'] = false;
    chat['createdAt'] = createdAt;

    const createOpts: Record<string, Object> = {};
    createOpts['agentKind'] = session.agentKind === 'codex' || session.agentKind === 'pi'
      ? session.agentKind : 'claude-code';
    createOpts['workingDir'] = session.workingDir;
    createOpts['model'] = session.model;
    createOpts['effort'] = session.effort;
    createOpts['permissionMode'] = session.permissionMode.length > 0 ? session.permissionMode : 'ask';
    createOpts['planMode'] = planModeOverride === null
      ? session.planModeEnabled : planModeOverride;
    createOpts['fastMode'] = session.fastMode;
    createOpts['displayReasoning'] = 'summarized';
    if (session.providerId.length > 0) createOpts['providerId'] = session.providerId;
    if (session.remoteHostId.length > 0) createOpts['remoteHostId'] = session.remoteHostId;
    if (session.sdkSessionId.length > 0) createOpts['resumeSessionId'] = session.sdkSessionId;

    const raw: Record<string, Object> = {};
    raw['clientId'] = clientId;
    raw['text'] = trimmed;
    const persisted = JSON.parse(buildPersistedUserContent(trimmed, images)) as Record<string, Object>;
    persisted['files'] = persistedFiles;
    if (serialized.quotesEncoded) persisted['quotesEncoded'] = true;
    if (serialized.agentReferences.length > 0) persisted['agentReferences'] = serialized.agentReferences;
    if (serialized.pastedTextRanges.length > 0) persisted['pastedTextRanges'] = serialized.pastedTextRanges;
    if (serialized.slashCommandRanges.length > 0) persisted['slashCommandRanges'] = serialized.slashCommandRanges;
    raw['persistedContent'] = JSON.stringify(persisted);
    if (serialized.agentReferences.length > 0) raw['agentReferences'] = serialized.agentReferences;
    if (fileObjects.length > 0) raw['files'] = fileObjects;
    raw['model'] = session.model;
    raw['effort'] = session.effort;
    raw['permissionMode'] = session.permissionMode.length > 0 ? session.permissionMode : 'ask';
    raw['workingDir'] = session.workingDir;
    raw['chatMessage'] = chat;
    raw['createOpts'] = createOpts;

    const item = new QueuedInputItem();
    item.clientId = clientId;
    item.text = trimmed;
    item.persistedContent = raw['persistedContent'] as string;
    item.createdAt = createdAt;
    item.raw = raw;
    item.images = images.slice();
    item.files = files.slice();
    return item;
  }

  private cloneItemWithText(item: QueuedInputItem, text: string): QueuedInputItem {
    const raw = JSON.parse(JSON.stringify(item.raw)) as Record<string, Object>;
    const trimmed = text.trim();
    raw['text'] = trimmed;
    let persisted: Record<string, Object> = {};
    try {
      persisted = JSON.parse(item.persistedContent) as Record<string, Object>;
    } catch (e) {
      persisted = JSON.parse(buildPersistedUserContent(trimmed, item.images)) as Record<string, Object>;
    }
    persisted['text'] = trimmed;
    // 纯文本编辑会使旧 ranges 失效，但附件与其它稳定字段必须保留。
    persisted['pastedTextRanges'] = [];
    persisted['slashCommandRanges'] = [];
    persisted['agentReferences'] = [];
    persisted['quotesEncoded'] = false;
    raw['persistedContent'] = JSON.stringify(persisted);
    raw['agentReferences'] = [];
    const chat = readObj(raw, 'chatMessage');
    chat['content'] = trimmed;
    raw['chatMessage'] = chat;
    const next = parseQueuedInputItem(raw);
    return next ?? item;
  }

  private cloneItemWithDocument(
    item: QueuedInputItem,
    serialized: SerializedComposerDocument,
  ): QueuedInputItem {
    const raw = JSON.parse(JSON.stringify(item.raw)) as Record<string, Object>;
    raw['text'] = serialized.text;
    let persisted: Record<string, Object> = {};
    try {
      persisted = JSON.parse(item.persistedContent) as Record<string, Object>;
    } catch (e) {
      persisted = JSON.parse(buildPersistedUserContent(serialized.text, item.images)) as Record<string, Object>;
    }
    persisted['text'] = serialized.text;
    persisted['quotesEncoded'] = serialized.quotesEncoded;
    persisted['pastedTextRanges'] = serialized.pastedTextRanges;
    persisted['slashCommandRanges'] = serialized.slashCommandRanges;
    persisted['agentReferences'] = serialized.agentReferences;
    raw['persistedContent'] = JSON.stringify(persisted);
    raw['agentReferences'] = serialized.agentReferences;
    const chat = readObj(raw, 'chatMessage');
    chat['content'] = serialized.text;
    raw['chatMessage'] = chat;
    const next = parseQueuedInputItem(raw);
    return next ?? item;
  }

  private async invoke(
    deviceId: string,
    channel: string,
    args: Object[],
  ): Promise<Object | undefined> {
    const client = this.client;
    if (!client) throw new Error('Device Link 未连接');
    if (this.linkOpener !== undefined) {
      try {
        await this.linkOpener(deviceId);
      } catch (e) {
        // link-open 自身即使 ACK 不确定，本次 maker:input 调用也还没有开始发送。
        if (e instanceof DlError) throw new DlError(e.code, e.message, false);
        const message = e instanceof Error ? e.message : JSON.stringify(e);
        throw new DlError('LINK_NOT_OPEN', message, false);
      }
    }
    const options = new DlInvokeOptions();
    options.channel = channel;
    options.args = args;
    const envelope = await client.invoke(deviceId, options);
    return unwrapInvokeResult(envelope);
  }
}

function imageExtension(name: string, mimeType: string): string {
  const dot = name.lastIndexOf('.');
  if (dot >= 0 && dot < name.length - 1) return name.slice(dot + 1).toLowerCase();
  if (mimeType === 'image/png') return 'png';
  if (mimeType === 'image/webp') return 'webp';
  if (mimeType === 'image/gif') return 'gif';
  return 'jpg';
}
