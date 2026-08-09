/**
 * Harmony 输入队列。
 *
 * 权威状态来自 Desktop `maker:input:get-projection` 与
 * `maker:input:projection` push；页面只消费归一化投影。所有操作复用 Mobile
 * 已使用的 `maker:input:*` 通道，不创建 Harmony 专用协议。
 */
import { DlClient, DlInvokeOptions } from '../device-link/DlClient';
import { RemoteImageRef, RemoteSerializedAttachment } from '../attachments/AttachmentModels';
import { RemoteSession, readBool, readObj, readStr } from '../tasks/TaskModels';
import { unwrapInvokeResult } from '../tasks/TaskStore';
import { buildPersistedUserContent } from './MessageStore';
import { SerializedComposerDocument } from './ComposerDocument';

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
  credentialSwitchBlockedBy: string[] = [];
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

function readStringArray(value: Object | undefined): string[] {
  const out: string[] = [];
  if (!Array.isArray(value)) return out;
  const list = value as Object[];
  for (let i = 0; i < list.length; i++) {
    if (typeof list[i] === 'string') out.push(list[i] as string);
  }
  return out;
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
  const item = new QueuedInputItem();
  item.clientId = readStr(raw, 'clientId');
  item.text = readStr(raw, 'text');
  item.persistedContent = readStr(raw, 'persistedContent');
  item.raw = raw;
  const chat = readObj(raw, 'chatMessage');
  item.createdAt = readStr(chat, 'createdAt');
  item.images = parseImages(chat['images']);
  item.files = parseAttachments(raw['files']);
  if (item.clientId.length === 0 || item.persistedContent.length === 0
    || Object.keys(chat).length === 0) return null;
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
  /** 用户主动删除的条目不能被队列 diff 误判为“派发中”。 */
  private locallyRemovedClientIds: Set<string> = new Set();
  private operationRevisions: Map<string, number> = new Map();
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
    return bubbles;
  }

  handleProjectionPush(payload: Object | undefined): void {
    const projection = parseInputProjection(payload, '');
    if (projection.sessionId.length === 0) return;
    this.applyProjectionState(projection.sessionId, projection);
    this.reconcileTransientState(projection);
    this.notify();
  }

  /** 正式消息回流后移除 settling 气泡，实现同 clientId 原位落定。 */
  setDeliveredClientIds(sessionId: string, clientIds: Set<string>): void {
    const settling = this.settlingBySession.get(sessionId);
    if (settling === undefined || settling.length === 0) return;
    const next = settling.filter((item: QueuedInputItem) => !clientIds.has(item.clientId));
    if (next.length === settling.length) return;
    this.settlingBySession.set(sessionId, next);
    this.notify();
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
          }
        }
        this.settlingBySession.set(sessionId, merged);
      }
    }
    this.locallyRemovedClientIds.forEach((clientId: string) => {
      if (!next.pendingQueue.some((item: QueuedInputItem) => item.clientId === clientId)) {
        this.locallyRemovedClientIds.delete(clientId);
      }
    });
    this.projections.set(sessionId, next);
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
  }

  async refresh(deviceId: string, sessionId: string): Promise<boolean> {
    try {
      const result = await this.invoke(deviceId, 'maker:input:get-projection', [sessionId]);
      const projection = parseInputProjection(result, sessionId);
      this.applyProjectionState(sessionId, projection);
      this.reconcileTransientState(projection);
      this.notify();
      return true;
    } catch (e) {
      return false;
    }
  }

  clearSession(sessionId: string): void {
    this.operationRevisions.set(sessionId, (this.operationRevisions.get(sessionId) ?? 0) + 1);
    const projection = this.projections.get(sessionId);
    if (projection !== undefined) {
      for (let i = 0; i < projection.pendingQueue.length; i++) {
        this.enqueueingClientIds.delete(projection.pendingQueue[i].clientId);
        this.failedByClientId.delete(projection.pendingQueue[i].clientId);
      }
    }
    this.projections.delete(sessionId);
    this.settlingBySession.delete(sessionId);
    this.notify();
  }

  async enqueueText(
    deviceId: string,
    session: RemoteSession,
    text: string,
    images: RemoteImageRef[],
  ): Promise<string> {
    const serialized = new SerializedComposerDocument();
    serialized.text = text.trim();
    return this.enqueueDocument(deviceId, session, serialized, images, []);
  }

  async enqueueDocument(
    deviceId: string,
    session: RemoteSession,
    serialized: SerializedComposerDocument,
    images: RemoteImageRef[],
    files: RemoteSerializedAttachment[],
  ): Promise<string> {
    const item = this.buildQueuedMessage(session, serialized, images, files);
    const projection = this.getProjection(session.id);
    projection.sessionId = session.id;
    projection.pendingQueue = projection.pendingQueue.concat([item]);
    this.projections.set(session.id, projection);
    this.enqueueingClientIds.add(item.clientId);
    this.failedByClientId.delete(item.clientId);
    this.notify();

    const sendOptions: Record<string, Object> = {};
    sendOptions['sendAtMs'] = Date.now();
    try {
      const result = await this.invoke(deviceId, 'maker:input:enqueue', [session.id, item.raw, sendOptions]);
      this.applyProjectionResult(session.id, result);
      this.enqueueingClientIds.delete(item.clientId);
      this.failedByClientId.delete(item.clientId);
      this.notify();
      return item.clientId;
    } catch (e) {
      // NOT_CONNECTED 可能发生在 host 已接收之后；先权威对账再决定是否标失败。
      const applied = await this.refresh(deviceId, session.id);
      if (applied && this.findItem(session.id, item.clientId) !== null) {
        this.enqueueingClientIds.delete(item.clientId);
        this.failedByClientId.delete(item.clientId);
        this.notify();
        return item.clientId;
      }
      this.enqueueingClientIds.delete(item.clientId);
      const message = e instanceof Error ? e.message : JSON.stringify(e);
      this.failedByClientId.set(item.clientId, message);
      // refresh 失败可能用空投影覆盖；失败气泡必须留在本地供重试/删除。
      const current = this.getProjection(session.id);
      if (this.findItem(session.id, item.clientId) === null) {
        current.sessionId = session.id;
        current.pendingQueue = current.pendingQueue.concat([item]);
        this.projections.set(session.id, current);
      }
      this.notify();
      throw new Error(message);
    }
  }

  async retry(deviceId: string, sessionId: string, clientId: string): Promise<void> {
    const item = this.findItem(sessionId, clientId);
    if (item === null || this.enqueueingClientIds.has(clientId)) return;
    this.enqueueingClientIds.add(clientId);
    this.failedByClientId.delete(clientId);
    this.notify();
    const sendOptions: Record<string, Object> = {};
    sendOptions['sendAtMs'] = Date.now();
    try {
      const result = await this.invoke(deviceId, 'maker:input:enqueue', [sessionId, item.raw, sendOptions]);
      this.applyProjectionResult(sessionId, result);
      this.enqueueingClientIds.delete(clientId);
      this.notify();
    } catch (e) {
      this.enqueueingClientIds.delete(clientId);
      const message = e instanceof Error ? e.message : JSON.stringify(e);
      this.failedByClientId.set(clientId, message);
      this.notify();
      throw new Error(message);
    }
  }

  async remove(deviceId: string, sessionId: string, clientId: string): Promise<void> {
    const projection = this.getProjection(sessionId);
    const index = projection.pendingQueue.findIndex((item: QueuedInputItem) => item.clientId === clientId);
    const removed = index >= 0 ? projection.pendingQueue[index] : undefined;
    this.locallyRemovedClientIds.add(clientId);
    if (index >= 0) projection.pendingQueue.splice(index, 1);
    this.failedByClientId.delete(clientId);
    this.notify();
    try {
      const result = await this.invoke(deviceId, 'maker:input:remove', [sessionId, clientId]);
      this.applyProjectionResult(sessionId, result);
      this.notify();
    } catch (e) {
      if (removed !== undefined && this.findItem(sessionId, clientId) === null) {
        projection.pendingQueue.splice(Math.min(index, projection.pendingQueue.length), 0, removed);
      }
      this.locallyRemovedClientIds.delete(clientId);
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
    const result = await this.invoke(deviceId, 'maker:input:move', [sessionId, clientId, targetIndex]);
    this.applyProjectionResult(sessionId, result);
    this.notify();
  }

  async setEditLock(
    deviceId: string,
    sessionId: string,
    clientId: string,
    locked: boolean,
  ): Promise<void> {
    const result = await this.invoke(deviceId, 'maker:input:set-edit-lock',
      [sessionId, clientId, locked]);
    this.applyProjectionResult(sessionId, result);
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
    const result = await this.invoke(deviceId, 'maker:input:update-content',
      [sessionId, clientId, next.raw]);
    this.applyProjectionResult(sessionId, result);
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
    const result = await this.invoke(deviceId, 'maker:input:stop', args);
    this.applyProjectionResult(sessionId, result);
    this.notify();
  }

  async resume(deviceId: string, sessionId: string): Promise<void> {
    const result = await this.invoke(deviceId, 'maker:input:resume', [sessionId]);
    this.applyProjectionResult(sessionId, result);
    this.notify();
  }

  async retryLastError(deviceId: string, sessionId: string): Promise<void> {
    const result = await this.invoke(deviceId, 'maker:input:retry-last-error', [sessionId]);
    this.applyProjectionResult(sessionId, result);
    this.notify();
  }

  async clearError(deviceId: string, sessionId: string): Promise<void> {
    const result = await this.invoke(deviceId, 'maker:input:clear-error', [sessionId]);
    this.applyProjectionResult(sessionId, result);
    this.notify();
  }

  private applyProjectionResult(sessionId: string, result: Object | undefined): void {
    if (result === undefined || typeof result !== 'object' || Array.isArray(result)) return;
    const projection = parseInputProjection(result, sessionId);
    this.applyProjectionState(sessionId, projection);
    this.reconcileTransientState(projection);
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
  ): QueuedInputItem {
    const trimmed = serialized.text;
    const clientId = this.nextClientId();
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

  private async invoke(
    deviceId: string,
    channel: string,
    args: Object[],
  ): Promise<Object | undefined> {
    const client = this.client;
    if (!client) throw new Error('Device Link 未连接');
    if (this.linkOpener !== undefined) await this.linkOpener(deviceId);
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
