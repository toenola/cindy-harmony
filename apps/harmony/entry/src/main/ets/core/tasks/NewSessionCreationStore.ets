/**
 * 新任务乐观创建管线。
 *
 * 页面同步写入预生成 sessionId / clientId 的任务行与首条气泡后立即跳进详情；
 * 建链、幂等创建、首条 enqueue 与 ACK 丢失探测都在本 Store 后台串行完成，
 * 不依赖 NewSessionPage 的生命周期。
 */
import { DlClient, DlError, DlInvokeOptions } from '../device-link/DlClient';
import { DlChannels, sessionTopic } from '../device-link/DlProtocol';
import { RemoteImageRef, RemoteSerializedAttachment } from '../attachments/AttachmentModels';
import { InputQueueStore, QueuedInputItem } from '../messages/InputQueueStore';
import { MessageStore } from '../messages/MessageStore';
import { RemoteSession, parseSession, readStr } from './TaskModels';
import { TaskStore, unwrapInvokeResult } from './TaskStore';

const CREATE_ATTEMPTS = 3;
const CREATE_RETRY_BASE_DELAY_MS = 800;
const ENQUEUE_PROBE_DELAYS_MS: number[] = [1500, 2500, 4000, 8000];
const TEMPORARY_TOPIC_TIMEOUT_MS = 2_500;
const TEMPORARY_TOPIC_RETRY_MS = 2_000;
const TEMPORARY_TOPIC_HANDOFF_GRACE_MS = 300;

function creationDelay(ms: number): Promise<void> {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

export function isTransientNewSessionError(error: Object): boolean {
  let code = '';
  if (error instanceof DlError) {
    code = error.code;
  } else if (error !== null && typeof error === 'object' && !Array.isArray(error)) {
    const rawCode = (error as Record<string, Object>)['code'];
    if (typeof rawCode === 'string') code = rawCode;
  }
  const message = error instanceof Error ? error.message : JSON.stringify(error);
  const text = `${code} ${message}`;
  const permanent = ['REMOTE_DISABLED', 'CHANNEL_NOT_ALLOWED', 'DEVICE_UNRESPONSIVE'];
  for (let i = 0; i < permanent.length; i++) {
    if (text.indexOf(permanent[i]) >= 0) return false;
  }
  const transient = [
    'DbClient not ready',
    'NOT_CONNECTED',
    'LINK_NOT_OPEN',
    'BACKPRESSURE',
    'DEVICE_OFFLINE',
    'DEVICE_LINK_TIMEOUT',
    'INVOKE_TIMEOUT',
    'REQUEST_TIMEOUT',
    'NETWORK_UNAVAILABLE',
    'Network request failed',
  ];
  for (let i = 0; i < transient.length; i++) {
    if (text.indexOf(transient[i]) >= 0) return true;
  }
  const lower = text.toLowerCase();
  return lower.indexOf('backpressure') >= 0
    || lower.indexOf('timeout') >= 0
    || lower.indexOf('temporar') >= 0;
}

export function exactNewSessionRecord(
  value: Object | undefined,
  expectedSessionId: string,
): Record<string, Object> | undefined {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return undefined;
  }
  const record = value as Record<string, Object>;
  return readStr(record, 'id') === expectedSessionId ? record : undefined;
}

export function decideNewSessionRecoveryAction(intent: string, exactProbe: string): string {
  if (exactProbe === 'found') return 'resume';
  if (exactProbe === 'missing') return intent === 'edit' ? 'edit' : 'create';
  return 'hold';
}

export function shouldBlockNewSessionRemoteOperation(
  pendingLocalCreation: boolean,
  status: string,
): boolean {
  return pendingLocalCreation || status === 'running' || status === 'create-failed';
}

export class NewSessionCreationParams {
  deviceId: string = '';
  session: RemoteSession = new RemoteSession();
  createOptions: Record<string, Object> = {};
  firstMessageClientId: string = '';
  firstMessageText: string = '';
  firstMessageImages: RemoteImageRef[] = [];
  firstMessageFiles: RemoteSerializedAttachment[] = [];
  planModeArm: boolean = false;
  legacyPlanRestore: string = '';
}

export class NewSessionCreationTask {
  sessionId: string = '';
  deviceId: string = '';
  status: string = 'running'; // running | create-failed | enqueue-failed
  error: string = '';
  firstMessageClientId: string = '';
  firstMessageText: string = '';
  firstMessageImages: RemoteImageRef[] = [];
  firstMessageFiles: RemoteSerializedAttachment[] = [];
  session: RemoteSession = new RemoteSession();
  params: NewSessionCreationParams = new NewSessionCreationParams();
  temporaryTopicRequested: boolean = false;
  temporaryTopicHandedOff: boolean = false;
}

class NewSessionExactProbeResult {
  status: string = 'unknown'; // found | missing | unknown
  session: Record<string, Object> | undefined = undefined;
}

/** create-failed 返回新建页时的一次性草稿；不落盘，也不改变远端状态。 */
export class NewSessionEditDraft {
  deviceId: string = '';
  agentKind: string = 'claude-code';
  workspaceKind: string = 'dialogue';
  workingDir: string = '';
  model: string = '';
  providerId: string = '';
  effort: string = '';
  permissionMode: string = '';
  planModeEnabled: boolean = false;
  fastMode: boolean = false;
  text: string = '';
  images: RemoteImageRef[] = [];
  files: RemoteSerializedAttachment[] = [];
}

export class NewSessionCreationStore {
  private client: DlClient | undefined = undefined;
  private tasksStore: TaskStore | undefined = undefined;
  private inputQueue: InputQueueStore | undefined = undefined;
  private messages: MessageStore | undefined = undefined;
  private linkOpener: ((deviceId: string) => Promise<void>) | undefined = undefined;
  private tasks: Map<string, NewSessionCreationTask> = new Map();
  private listeners: Array<() => void> = [];
  private editDraft: NewSessionEditDraft | null = null;
  /** ACK 丢失也必须最终退订；清理项跨 stop 保留到下一次 online。 */
  private pendingTopicRemovals: Map<string, Set<string>> = new Map();
  private topicRemovalInFlight: Map<string, number> = new Map();
  private topicRemovalEpochs: Map<string, number> = new Map();
  private nextTopicRemovalEpoch: number = 0;
  private topicRemovalRetryTimers: Map<string, number> = new Map();

  attach(
    client: DlClient,
    tasksStore: TaskStore,
    inputQueue: InputQueueStore,
    messages: MessageStore,
    linkOpener: (deviceId: string) => Promise<void>,
  ): void {
    this.client = client;
    this.tasksStore = tasksStore;
    this.inputQueue = inputQueue;
    this.messages = messages;
    this.linkOpener = linkOpener;
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

  getTask(sessionId: string): NewSessionCreationTask | null {
    return this.tasks.get(sessionId) ?? null;
  }

  shouldBlockSessionSync(sessionId: string): boolean {
    const status = this.tasks.get(sessionId)?.status ?? '';
    return status === 'running' || status === 'create-failed';
  }

  start(params: NewSessionCreationParams): void {
    if (params.deviceId.length === 0 || params.session.id.length === 0
      || params.firstMessageClientId.length === 0 || this.tasks.has(params.session.id)) return;
    params.session.pendingLocalCreation = true;
    const task = new NewSessionCreationTask();
    task.sessionId = params.session.id;
    task.deviceId = params.deviceId;
    task.firstMessageClientId = params.firstMessageClientId;
    task.firstMessageText = params.firstMessageText;
    task.firstMessageImages = params.firstMessageImages.slice();
    task.firstMessageFiles = params.firstMessageFiles.slice();
    task.session = params.session;
    task.params = params;
    this.tasks.set(task.sessionId, task);
    this.tasksStore?.upsertSession(task.deviceId, task.session);
    this.inputQueue?.seedOptimisticText(
      task.deviceId,
      task.session,
      task.firstMessageText,
      task.firstMessageImages,
      task.firstMessageClientId,
      false,
      task.firstMessageFiles,
    );
    this.notify();
    void this.run(task);
  }

  retry(sessionId: string): void {
    const task = this.tasks.get(sessionId);
    if (task === undefined || task.status !== 'create-failed') return;
    this.beginRecovery(task);
    void this.recoverAfterExactProbe(task, 'retry');
  }

  /** 返回编辑前必须先确认远端 exact id 不存在；不确定时保留失败态，禁止盲删。 */
  async returnToEdit(
    sessionId: string,
    additionalText: string = '',
    additionalImages: RemoteImageRef[] = [],
    additionalFiles: RemoteSerializedAttachment[] = [],
  ): Promise<string> {
    const task = this.tasks.get(sessionId);
    if (task === undefined || task.status !== 'create-failed') return 'cancelled';
    this.beginRecovery(task);
    return this.recoverAfterExactProbe(
      task, 'edit', additionalText, additionalImages, additionalFiles);
  }

  private beginRecovery(task: NewSessionCreationTask): void {
    task.status = 'running';
    task.error = '';
    task.session.pendingLocalCreation = true;
    this.tasksStore?.upsertSession(task.deviceId, task.session);
    this.inputQueue?.clearLocalFailure(task.firstMessageClientId);
    this.notify();
  }

  private async recoverAfterExactProbe(
    task: NewSessionCreationTask,
    intent: string,
    additionalText: string = '',
    additionalImages: RemoteImageRef[] = [],
    additionalFiles: RemoteSerializedAttachment[] = [],
  ): Promise<string> {
    const probe = await this.probeCreatedSessionForRecovery(task);
    if (!this.isCurrent(task)) return 'cancelled';
    const action = decideNewSessionRecoveryAction(intent, probe.status);
    if (action === 'hold') {
      task.status = 'create-failed';
      task.error = '暂时无法确认电脑上是否已经创建该任务，请稍后重试';
      this.inputQueue?.markLocalFailure(
        task.sessionId, task.firstMessageClientId, task.error);
      this.notify();
      return 'unknown';
    }
    if (action === 'edit') {
      this.foldDeferredIntoTask(task);
      this.stashTaskForEdit(task, additionalText, additionalImages, additionalFiles);
      this.dismiss(task.sessionId, true);
      return 'edit';
    }
    void this.run(task, action === 'resume' ? probe.session : undefined);
    return action;
  }

  private stashTaskForEdit(
    task: NewSessionCreationTask,
    additionalText: string,
    additionalImages: RemoteImageRef[],
    additionalFiles: RemoteSerializedAttachment[],
  ): void {
    const draft = new NewSessionEditDraft();
    draft.deviceId = task.deviceId;
    draft.agentKind = task.session.agentKind === 'cc' ? 'claude-code' : task.session.agentKind;
    draft.workspaceKind = task.session.workspaceKind;
    draft.workingDir = task.session.workingDir;
    draft.model = task.session.model;
    draft.providerId = task.session.providerId;
    draft.effort = task.session.effort;
    draft.permissionMode = task.params.legacyPlanRestore.length > 0
      ? task.params.legacyPlanRestore : task.session.permissionMode;
    draft.planModeEnabled = task.session.planModeEnabled;
    draft.fastMode = task.session.fastMode;
    draft.text = task.firstMessageText;
    const extra = additionalText.trim();
    if (extra.length > 0) {
      draft.text = draft.text.length > 0 ? `${draft.text}\n\n${extra}` : extra;
    }
    draft.images = task.firstMessageImages.concat(additionalImages);
    draft.files = task.firstMessageFiles.concat(additionalFiles);
    this.editDraft = draft;
  }

  consumeEditDraft(): NewSessionEditDraft | null {
    const draft = this.editDraft;
    this.editDraft = null;
    return draft;
  }

  /** create-failed 返回编辑：删除只存在于本地的任务与投影。 */
  dismiss(sessionId: string, removeSyntheticSession: boolean): void {
    const task = this.tasks.get(sessionId);
    if (task === undefined) return;
    this.tasks.delete(sessionId);
    this.releaseTemporaryTopic(task);
    if (removeSyntheticSession) {
      this.tasksStore?.removeLocalSession(task.deviceId, sessionId);
      this.inputQueue?.clearSession(sessionId);
    }
    this.notify();
  }

  /** enqueue-failed 草稿已被详情页接回 Composer，任务状态可安全清理。 */
  finishDraftHandoff(sessionId: string): void {
    const task = this.tasks.get(sessionId);
    if (task === undefined) return;
    this.tasks.delete(sessionId);
    this.releaseTemporaryTopic(task);
    this.notify();
  }

  clearAll(): void {
    this.editDraft = null;
    if (this.tasks.size === 0) return;
    const pending: NewSessionCreationTask[] = [];
    this.tasks.forEach((task: NewSessionCreationTask) => pending.push(task));
    this.tasks.clear();
    for (let i = 0; i < pending.length; i++) {
      this.releaseTemporaryTopic(pending[i]);
      if (pending[i].session.pendingLocalCreation) {
        this.tasksStore?.removeLocalSession(pending[i].deviceId, pending[i].sessionId);
      }
    }
    this.notify();
  }

  /** Relay 恢复后补做 ACK 丢失/stop 窗口内没能完成的 topic 清理。 */
  onRelayOnline(): void {
    const deviceIds: string[] = [];
    this.pendingTopicRemovals.forEach((_topics: Set<string>, deviceId: string) => {
      deviceIds.push(deviceId);
    });
    for (let i = 0; i < deviceIds.length; i++) this.flushTopicRemovals(deviceIds[i]);
  }

  private isCurrent(task: NewSessionCreationTask): boolean {
    return this.tasks.get(task.sessionId) === task;
  }

  private async run(
    task: NewSessionCreationTask,
    confirmedSession: Record<string, Object> | undefined = undefined,
  ): Promise<void> {
    try {
      if (this.linkOpener !== undefined) await this.linkOpener(task.deviceId);
      if (!this.isCurrent(task)) return;
      // 会话页尚处于 sync guard 时先登记 topic，避免首 turn 事件落在订阅空窗。
      this.subscribeTemporaryTopic(task);
      const created = confirmedSession ?? await this.createSessionIdempotent(task);
      if (!this.isCurrent(task)) return;
      await this.adoptCreatedSession(task, created, confirmedSession);
      if (!this.isCurrent(task)) return;

      if (task.params.planModeArm) {
        try {
          await this.invoke(task, 'maker:set-plan-mode', [task.sessionId, true]);
        } catch (e) {
          // 新协议计划模式是 best-effort；失败降级为普通首条发送。
        }
      }
      if (!this.isCurrent(task)) return;

      this.inputQueue?.seedOptimisticText(
        task.deviceId,
        task.session,
        task.firstMessageText,
        task.firstMessageImages,
        task.firstMessageClientId,
        true,
        task.firstMessageFiles,
      );
      try {
        await this.inputQueue?.retry(task.deviceId, task.sessionId, task.firstMessageClientId);
        if (!this.isCurrent(task)) return;
      } catch (enqueueError) {
        const verdict = await this.probeFirstMessageDelivery(task);
        if (!this.isCurrent(task)) return;
        if (verdict === 'queued') {
          this.inputQueue?.clearLocalFailure(task.firstMessageClientId);
        } else if (verdict === 'applied') {
          this.inputQueue?.resolveAppliedDelivery(task.sessionId, task.firstMessageClientId);
        } else {
          await this.failEnqueue(task, verdict === 'missing'
            ? '首条消息尚未送达，请先核对任务内容后再重新发送'
            : '首条消息状态尚未确认，请先核对任务内容，避免重复发送');
          return;
        }
      }
      if (!this.isCurrent(task)) return;

      if (task.params.legacyPlanRestore.length > 0) {
        try {
          await this.invoke(task, 'maker:set-permission-mode',
            [task.sessionId, task.params.legacyPlanRestore]);
        } catch (e) {
          // 旧协议计划权限恢复为 best-effort，不反转已成功的首条发送。
        }
      }
      if (!this.isCurrent(task)) return;
      // 远端任务已成立：把 topic 直接交给详情页正式 owner，避免补偿 unsubscribe
      // 在其 subscribe 之后晚到，误退掉仍在使用的同名 topic。
      task.temporaryTopicHandedOff = true;
      task.session.pendingLocalCreation = false;
      this.tasksStore?.setPendingLocalCreation(task.deviceId, task.sessionId, false);
      this.tasks.delete(task.sessionId);
      this.notify();
      this.finishTemporaryTopicHandoff(task);
      this.inputQueue?.enableDeferredDispatch(task.deviceId, task.session);
    } catch (error) {
      if (!this.isCurrent(task)) return;
      this.releaseTemporaryTopic(task);
      const message = error instanceof Error ? error.message : JSON.stringify(error);
      task.status = 'create-failed';
      task.error = message.length > 0 ? message : '新任务创建失败，请重试';
      this.inputQueue?.markLocalFailure(task.sessionId, task.firstMessageClientId, task.error);
      this.notify();
    }
  }

  private async createSessionIdempotent(
    task: NewSessionCreationTask,
  ): Promise<Record<string, Object>> {
    let lastError: Error = new Error('新任务创建失败');
    for (let attempt = 0; attempt < CREATE_ATTEMPTS; attempt++) {
      if (attempt > 0) {
        try {
          const existing = await this.probeCreatedSession(task);
          if (!this.isCurrent(task)) throw new Error('新任务创建已取消');
          return existing;
        } catch (e) {
          if (!this.isCurrent(task)) throw new Error('新任务创建已取消');
          // 同一预生成 id 的下一次 create 仍幂等；probe 不确定不换 id。
        }
        await creationDelay(CREATE_RETRY_BASE_DELAY_MS * Math.pow(2, attempt - 1));
        if (!this.isCurrent(task)) throw new Error('新任务创建已取消');
      }
      if (!this.isCurrent(task)) throw new Error('新任务创建已取消');
      try {
        const result = await this.invoke(
          task, DlChannels.MAKER_CREATE_SESSION, [task.params.createOptions]);
        if (!this.isCurrent(task)) throw new Error('新任务创建已取消');
        if (result === undefined || result === null || typeof result !== 'object'
          || Array.isArray(result)) throw new Error('新任务创建失败');
        const record = result as Record<string, Object>;
        if (readStr(record, 'sessionId') !== task.sessionId) {
          throw new Error('电脑没有采用本次任务编号，已停止发送首条消息');
        }
        return record;
      } catch (error) {
        const normalized = error instanceof Error ? error : new Error(JSON.stringify(error));
        lastError = normalized;
        if (!isTransientNewSessionError(normalized)) throw normalized;
      }
    }
    try {
      const existing = await this.probeCreatedSession(task);
      if (!this.isCurrent(task)) throw new Error('新任务创建已取消');
      return existing;
    } catch (e) {
      if (!this.isCurrent(task)) throw new Error('新任务创建已取消');
      // 最终 probe 仍不确定时保留同 id 进入用户重试面。
    }
    throw lastError;
  }

  private async probeCreatedSession(
    task: NewSessionCreationTask,
  ): Promise<Record<string, Object>> {
    const result = await this.invoke(task, DlChannels.SESSIONS_GET, [task.sessionId]);
    if (!this.isCurrent(task)) throw new Error('新任务创建已取消');
    const exact = exactNewSessionRecord(result, task.sessionId);
    if (exact === undefined) throw new Error('电脑返回了不匹配的任务信息');
    return exact;
  }

  private async probeCreatedSessionForRecovery(
    task: NewSessionCreationTask,
  ): Promise<NewSessionExactProbeResult> {
    const outcome = new NewSessionExactProbeResult();
    try {
      outcome.session = await this.probeCreatedSession(task);
      outcome.status = 'found';
    } catch (error) {
      if (this.isNotFoundError(error)) outcome.status = 'missing';
    }
    return outcome;
  }

  private async adoptCreatedSession(
    task: NewSessionCreationTask,
    createResult: Record<string, Object>,
    authoritativeHint: Record<string, Object> | undefined = undefined,
  ): Promise<void> {
    let authoritative = authoritativeHint;
    if (authoritative === undefined) {
      try {
        authoritative = await this.probeCreatedSession(task);
      } catch (e) {
        // create 回包足以继续；权威行稍后由 sessions push / 列表快照覆盖。
      }
    }
    if (!this.isCurrent(task)) return;
    if (authoritative !== undefined) {
      const session = parseSession(authoritative);
      session.pendingLocalCreation = true;
      task.session = session;
    } else {
      const workDir = readStr(createResult, 'workDir') || readStr(createResult, 'workingDir');
      if (workDir.length > 0) task.session.workingDir = workDir;
      task.session.pendingLocalCreation = true;
    }
    this.tasksStore?.upsertSession(task.deviceId, task.session);
  }

  private async probeFirstMessageDelivery(task: NewSessionCreationTask): Promise<string> {
    let confirmedMissing = 0;
    for (let i = 0; i < ENQUEUE_PROBE_DELAYS_MS.length; i++) {
      await creationDelay(ENQUEUE_PROBE_DELAYS_MS[i]);
      if (!this.isCurrent(task)) return 'unknown';
      if (this.messages?.hasMessageClientId(task.sessionId, task.firstMessageClientId)) {
        return 'applied';
      }
      const projectionLoaded = await this.inputQueue?.refresh(task.deviceId, task.sessionId) ?? false;
      if (!this.isCurrent(task)) return 'unknown';
      if (!projectionLoaded) continue;
      const projection = this.inputQueue?.getProjection(task.sessionId);
      if (projection !== undefined && projection.pendingQueue.some((item) =>
        item.clientId === task.firstMessageClientId)) return 'queued';
      const messageVerdict = await this.messages?.probeMessageClientId(
        task.deviceId, task.sessionId, task.firstMessageClientId, 200) ?? 'unknown';
      if (!this.isCurrent(task)) return 'unknown';
      if (messageVerdict === 'applied') return 'applied';
      if (messageVerdict === 'missing') {
        confirmedMissing += 1;
        if (confirmedMissing >= 2) return 'missing';
      }
    }
    return 'unknown';
  }

  private async failEnqueue(task: NewSessionCreationTask, message: string): Promise<void> {
    if (!this.isCurrent(task)) return;
    this.foldDeferredIntoTask(task);
    task.status = 'enqueue-failed';
    task.error = message;
    task.session.pendingLocalCreation = false;
    this.inputQueue?.discardProjection(task.sessionId);
    this.tasksStore?.setPendingLocalCreation(task.deviceId, task.sessionId, false);
    task.temporaryTopicHandedOff = true;
    this.notify();
    this.finishTemporaryTopicHandoff(task);
  }

  private subscribeTemporaryTopic(task: NewSessionCreationTask): void {
    const client = this.client;
    if (client === undefined || task.temporaryTopicRequested) return;
    const topic = sessionTopic(task.sessionId);
    // 同 id 重试先撤销上一轮未发出的补偿清理；已经发出的 unsubscribe 位于本次
    // subscribe 之前，同一连接上的最终状态仍以这次 subscribe 为准。
    this.cancelQueuedTopicRemoval(task.deviceId, topic);
    // 先记 lease，再发 RPC；clearAll 与 ACK 丢失窗口都能据此安排补偿 unsubscribe。
    task.temporaryTopicRequested = true;
    void client.subscribe(task.deviceId, [topic], TEMPORARY_TOPIC_TIMEOUT_MS).then(() => {
      if (task.temporaryTopicHandedOff) {
        return;
      }
      if (this.isCurrent(task) && task.temporaryTopicRequested) {
        return;
      } else {
        this.queueTopicRemoval(task.deviceId, topic);
      }
    }).catch(() => {
      // 请求可能已在 Desktop 生效但 ACK 丢失；释放过的 lease 必须保留补偿清理。
      if (!task.temporaryTopicHandedOff
        && (!task.temporaryTopicRequested || !this.isCurrent(task))) {
        this.queueTopicRemoval(task.deviceId, topic);
      }
    });
  }

  private releaseTemporaryTopic(task: NewSessionCreationTask): void {
    if (task.temporaryTopicHandedOff) return;
    if (!task.temporaryTopicRequested) return;
    task.temporaryTopicRequested = false;
    this.queueTopicRemoval(task.deviceId, sessionTopic(task.sessionId));
  }

  /** notify 后让仍在场的 TaskPage 先登记正式订阅；页面已离场时才补做退订。 */
  private finishTemporaryTopicHandoff(task: NewSessionCreationTask): void {
    setTimeout(() => {
      if (this.messages?.isSessionOpen(task.sessionId)) {
        task.temporaryTopicRequested = false;
        return;
      }
      task.temporaryTopicHandedOff = false;
      this.releaseTemporaryTopic(task);
    }, TEMPORARY_TOPIC_HANDOFF_GRACE_MS);
  }

  private queueTopicRemoval(deviceId: string, topic: string): void {
    const key = `${deviceId}:${topic}`;
    this.topicRemovalEpochs.set(key, ++this.nextTopicRemovalEpoch);
    const topics = this.pendingTopicRemovals.get(deviceId) ?? new Set<string>();
    topics.add(topic);
    this.pendingTopicRemovals.set(deviceId, topics);
    this.flushTopicRemovals(deviceId);
  }

  private cancelQueuedTopicRemoval(deviceId: string, topic: string): void {
    const key = `${deviceId}:${topic}`;
    const topics = this.pendingTopicRemovals.get(deviceId);
    const hasPending = topics?.has(topic) === true;
    const hasInFlight = this.topicRemovalInFlight.has(key);
    if (!hasPending && !hasInFlight) {
      // 常规新任务没有旧 lease 需要失效，不为每个 session 永久保留空 epoch。
      this.topicRemovalEpochs.delete(key);
      return;
    }
    // 即使旧 unsubscribe 已在途也推进代次；它的完成回调不能消费之后的新 removal。
    this.topicRemovalEpochs.set(key, ++this.nextTopicRemovalEpoch);
    if (topics === undefined) return;
    topics.delete(topic);
    if (topics.size === 0) this.pendingTopicRemovals.delete(deviceId);
    if (!hasInFlight) this.topicRemovalEpochs.delete(key);
  }

  private flushTopicRemovals(deviceId: string): void {
    const client = this.client;
    const topics = this.pendingTopicRemovals.get(deviceId);
    if (client === undefined || client.getStatus() !== 'online'
      || topics === undefined || topics.size === 0) return;
    const topic = Array.from(topics)[0];
    const key = `${deviceId}:${topic}`;
    if (this.topicRemovalInFlight.has(key)) return;
    const epoch = this.topicRemovalEpochs.get(key) ?? ++this.nextTopicRemovalEpoch;
    this.topicRemovalEpochs.set(key, epoch);
    this.topicRemovalInFlight.set(key, epoch);
    let waitForRetry = false;
    void client.unsubscribe(deviceId, [topic], TEMPORARY_TOPIC_TIMEOUT_MS).then(() => {
      if (this.topicRemovalEpochs.get(key) === epoch) {
        const current = this.pendingTopicRemovals.get(deviceId);
        current?.delete(topic);
        if (current !== undefined && current.size === 0) this.pendingTopicRemovals.delete(deviceId);
      }
    }).catch(() => {
      if (this.topicRemovalEpochs.get(key) === epoch) {
        waitForRetry = true;
        this.scheduleTopicRemovalRetry(deviceId);
      }
    }).finally(() => {
      if (this.topicRemovalInFlight.get(key) === epoch) {
        this.topicRemovalInFlight.delete(key);
      }
      const current = this.pendingTopicRemovals.get(deviceId);
      if (!this.topicRemovalInFlight.has(key) && current?.has(topic) !== true) {
        this.topicRemovalEpochs.delete(key);
      }
      if (!waitForRetry) this.flushTopicRemovals(deviceId);
    });
  }

  private scheduleTopicRemovalRetry(deviceId: string): void {
    if (this.topicRemovalRetryTimers.has(deviceId)) return;
    const timer = setTimeout(() => {
      this.topicRemovalRetryTimers.delete(deviceId);
      this.flushTopicRemovals(deviceId);
    }, TEMPORARY_TOPIC_RETRY_MS);
    this.topicRemovalRetryTimers.set(deviceId, timer);
  }

  /** 首条失败或返回编辑时，后续 outbox 与首条按发送顺序合并为一份可重发草稿。 */
  private foldDeferredIntoTask(task: NewSessionCreationTask): void {
    const followUps: QueuedInputItem[] = this.inputQueue?.takeDeferred(task.sessionId) ?? [];
    if (followUps.length === 0) return;
    const texts: string[] = [];
    if (task.firstMessageText.length > 0) texts.push(task.firstMessageText);
    for (let i = 0; i < followUps.length; i++) {
      if (followUps[i].text.length > 0) texts.push(followUps[i].text);
      task.firstMessageImages = task.firstMessageImages.concat(followUps[i].images);
      task.firstMessageFiles = task.firstMessageFiles.concat(followUps[i].files);
    }
    task.firstMessageText = texts.join('\n\n');
  }

  private isNotFoundError(error: Object): boolean {
    if (error instanceof DlError && error.code === 'NOT_FOUND') return true;
    const message = error instanceof Error ? error.message : JSON.stringify(error);
    return message.indexOf('[NOT_FOUND]') >= 0;
  }

  private async invoke(
    task: NewSessionCreationTask,
    channel: string,
    args: Object[],
  ): Promise<Object | undefined> {
    if (this.client === undefined) throw new Error('Device Link 未连接');
    if (this.linkOpener !== undefined) await this.linkOpener(task.deviceId);
    if (!this.isCurrent(task)) throw new Error('新任务创建已取消');
    const options = new DlInvokeOptions();
    options.channel = channel;
    options.args = args;
    const envelope = await this.client.invoke(task.deviceId, options);
    if (!this.isCurrent(task)) throw new Error('新任务创建已取消');
    return unwrapInvokeResult(envelope);
  }
}
