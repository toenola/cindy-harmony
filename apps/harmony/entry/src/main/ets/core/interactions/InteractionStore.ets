/**
 * 交互确认 Store（Permission / Ask User / Plan Review）。
 *
 * 对齐 mobile 语义：
 * - push `maker:interaction-request` → 挂起交互（{ sessionId, request, persistId? }）；
 * - push `maker:interaction-dismissed` → 移除（{ sessionId, requestId }）；
 * - resolve：invoke `maker:resolve-interaction` [requestId, decision]；
 * - 打开会话时用 `maker:get-pending-interactions` [sessionId] 拉挂起快照。
 */

import { DlClient, DlInvokeOptions } from '../device-link/DlClient';
import { Envelope } from '../device-link/DlProtocol';
import { readStr, readObj, safeErrorMessage } from '../tasks/TaskModels';
import { unwrapInvokeResult } from '../tasks/TaskStore';

/** 挂起的交互请求。 */
export class PendingInteraction {
  sessionId: string = '';
  /** push 来源设备；同一 sessionId 在多个桌面上可能同时存在。 */
  deviceId: string = '';
  requestId: string = '';
  kind: string = '';
  /** 完整 request（字段按 kind 解释：permission / ask_user_question / plan_review）。 */
  raw: Record<string, Object> = {};
  persistId: string = '';
}

/** Ask User 草稿按 requestId 保存在 Store，页面重建/前后台切换不丢。 */
export class AskUserDraft {
  answers: Map<string, string> = new Map();
  currentIndex: number = 0;
  selectedLabels: string[] = [];
  customInput: string = '';
  showCustomInput: boolean = false;
}

export class PlanReviewDraft {
  planText: string = '';
  feedback: string = '';
  editMode: boolean = false;
  expanded: boolean = false;
  feedbackOpen: boolean = false;
}

class ActiveInteractionTarget {
  deviceId: string = '';
  sessionId: string = '';
  references: number = 0;
}

class InteractionScopeParts {
  deviceId: string = '';
  sessionId: string = '';
}

export class InteractionStore {
  private client: DlClient | undefined = undefined;
  private linkOpener: ((deviceId: string) => Promise<void>) | undefined = undefined;
  private listeners: Array<() => void> = [];
  /** deviceId + sessionId 复合键，避免跨设备同名任务共享 pending。 */
  private pendingByScope: Map<string, PendingInteraction[]> = new Map();
  /** resolve RPC 也跨越账号/连接生命周期；值是启动时的 Store 代次。 */
  private resolvingRequestIds: Map<string, number> = new Map();
  private resolveErrors: Map<string, string> = new Map();
  private askDrafts: Map<string, AskUserDraft> = new Map();
  private planDrafts: Map<string, PlanReviewDraft> = new Map();
  /** push/dismiss 会抬高代次，防打开页面时的慢快照覆盖刚到的实时事件。 */
  private mutationGenerations: Map<string, number> = new Map();
  /** 同一任务可并发补拉；只允许最后启动的一次快照提交。 */
  private refreshSequences: Map<string, number> = new Map();
  private nextRefreshSequence: number = 0;
  /** 当前真正打开的任务；重连后只补拉这些交互，避免扩大故障半径。 */
  private activeTargets: Map<string, ActiveInteractionTarget> = new Map();
  /** 同一任务的 pending 快照 single-flight；push/dismiss 代次继续负责裁决结果。 */
  private refreshOperations: Map<string, Promise<void>> = new Map();
  /** 登出/账号切换后，旧 resolve 回包不得写回新账号的交互状态。 */
  private stateGeneration: number = 0;

  attach(client: DlClient): void {
    this.client = client;
  }

  setLinkOpener(fn: (deviceId: string) => Promise<void>): void {
    this.linkOpener = fn;
  }

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

  getPending(sessionId: string, deviceId: string = ''): PendingInteraction[] {
    return this.pendingByScope.get(interactionScopeKey(deviceId, sessionId)) ?? [];
  }

  /** 是否有任意待处理交互（仅决定是否显示面板，不等同于 Composer 阻塞）。 */
  hasPending(sessionId: string, deviceId: string = ''): boolean {
    const list = this.pendingByScope.get(interactionScopeKey(deviceId, sessionId));
    return list !== undefined && list.length > 0;
  }

  isResolving(requestId: string): boolean {
    return this.resolvingRequestIds.has(requestId);
  }

  resolveError(requestId: string): string {
    return this.resolveErrors.get(requestId) ?? '';
  }

  readAskDraft(requestId: string): AskUserDraft | null {
    const draft = this.askDrafts.get(requestId);
    return draft === undefined ? null : cloneAskDraft(draft);
  }

  saveAskDraft(requestId: string, draft: AskUserDraft): void {
    if (requestId.length === 0) return;
    this.askDrafts.set(requestId, cloneAskDraft(draft));
    this.notify();
  }

  readPlanDraft(requestId: string): PlanReviewDraft | null {
    const draft = this.planDrafts.get(requestId);
    return draft === undefined ? null : clonePlanDraft(draft);
  }

  savePlanDraft(requestId: string, draft: PlanReviewDraft): void {
    if (requestId.length === 0) return;
    this.planDrafts.set(requestId, clonePlanDraft(draft));
    this.notify();
  }

  private bumpMutationGeneration(deviceId: string, sessionId: string): void {
    const scope = interactionScopeKey(deviceId, sessionId);
    this.mutationGenerations.set(scope, (this.mutationGenerations.get(scope) ?? 0) + 1);
  }

  /** push maker:interaction-request 处理。 */
  handleInteractionRequest(payload: Object | undefined, deviceId: string = ''): void {
    if (payload === undefined || typeof payload !== 'object') {
      return;
    }
    const p = payload as Record<string, Object>;
    const sessionId = readStr(p, 'sessionId');
    const sourceDeviceId = deviceId.length > 0 ? deviceId : readStr(p, 'deviceId');
    const rawRequest = readObj(p, 'request');
    if (sessionId.length === 0 || Object.keys(rawRequest).length === 0) {
      return;
    }
    const item = new PendingInteraction();
    item.sessionId = sessionId;
    item.deviceId = sourceDeviceId;
    item.requestId = readStr(rawRequest, 'requestId');
    item.kind = readStr(rawRequest, 'kind');
    item.raw = rawRequest;
    item.persistId = readStr(p, 'persistId');
    if (item.requestId.length === 0) {
      return;
    }
    const scope = interactionScopeKey(sourceDeviceId, sessionId);
    const list = this.pendingByScope.get(scope) ?? [];
    // 按 requestId 去重（重复 push 覆盖）。
    const filtered = list.filter((x: PendingInteraction) => x.requestId !== item.requestId);
    filtered.push(item);
    this.pendingByScope.set(scope, filtered);
    this.bumpMutationGeneration(sourceDeviceId, sessionId);
    this.notify();
  }

  /** push maker:interaction-dismissed 处理。 */
  handleInteractionDismissed(payload: Object | undefined, deviceId: string = ''): void {
    if (payload === undefined || typeof payload !== 'object') {
      return;
    }
    const p = payload as Record<string, Object>;
    const sessionId = readStr(p, 'sessionId');
    const sourceDeviceId = deviceId.length > 0 ? deviceId : readStr(p, 'deviceId');
    const requestId = readStr(p, 'requestId');
    if (sessionId.length === 0 || requestId.length === 0) {
      return;
    }
    const scopes: string[] = [];
    if (sourceDeviceId.length > 0) {
      scopes.push(interactionScopeKey(sourceDeviceId, sessionId));
    } else {
      // 兼容未携带来源设备的旧 push；无法判定归属时只清理同 sessionId 的命中项。
      this.pendingByScope.forEach((list: PendingInteraction[], scope: string) => {
        for (let i = 0; i < list.length; i++) {
          if (list[i].sessionId === sessionId && list[i].requestId === requestId) {
            scopes.push(scope);
            break;
          }
        }
      });
    }
    let changed = false;
    for (let i = 0; i < scopes.length; i++) {
      const scope = scopes[i];
      const list = this.pendingByScope.get(scope);
      if (list === undefined) continue;
      const filtered = list.filter((x: PendingInteraction) => x.requestId !== requestId);
      if (filtered.length === list.length) continue;
      this.pendingByScope.set(scope, filtered);
      const parts = splitInteractionScope(scope);
      this.bumpMutationGeneration(parts.deviceId, parts.sessionId);
      changed = true;
    }
    if (changed) {
      this.resolvingRequestIds.delete(requestId);
      this.resolveErrors.delete(requestId);
      this.askDrafts.delete(requestId);
      this.planDrafts.delete(requestId);
      this.notify();
    }
  }

  /** 打开会话时拉挂起交互快照（对齐 mobile getPendingInteractions）。 */
  async refreshPending(deviceId: string, sessionId: string): Promise<void> {
    const scope = interactionScopeKey(deviceId, sessionId);
    const existing = this.refreshOperations.get(scope);
    if (existing !== undefined) {
      await existing;
      return;
    }
    const operation = this.refreshPendingOnce(deviceId, sessionId);
    this.refreshOperations.set(scope, operation);
    try {
      await operation;
    } finally {
      if (this.refreshOperations.get(scope) === operation) {
        this.refreshOperations.delete(scope);
      }
    }
  }

  private async refreshPendingOnce(deviceId: string, sessionId: string): Promise<void> {
    const client = this.client;
    if (!client) {
      return;
    }
    const stateGeneration = this.stateGeneration;
    const scope = interactionScopeKey(deviceId, sessionId);
    const generation = this.mutationGenerations.get(scope) ?? 0;
    const sequence = ++this.nextRefreshSequence;
    this.refreshSequences.set(scope, sequence);
    try {
      if (this.linkOpener !== undefined) await this.linkOpener(deviceId);
      if (stateGeneration !== this.stateGeneration) return;
      const list = await this.queryPending(client, deviceId, sessionId);
      if (stateGeneration !== this.stateGeneration) return;
      if (this.refreshSequences.get(scope) !== sequence) return;
      if ((this.mutationGenerations.get(scope) ?? 0) !== generation) return;
      this.pendingByScope.set(scope, list);
      this.notify();
    } catch (e) {
      // 拉取失败：保留现状（push 会继续补充）。
    }
  }

  /** 折叠屏可能同时持有同一任务的多个宿主，按引用计数登记。 */
  activateSession(deviceId: string, sessionId: string): void {
    if (deviceId.length === 0 || sessionId.length === 0) return;
    const scope = interactionScopeKey(deviceId, sessionId);
    const target = this.activeTargets.get(scope) ?? new ActiveInteractionTarget();
    target.deviceId = deviceId;
    target.sessionId = sessionId;
    target.references += 1;
    this.activeTargets.set(scope, target);
  }

  deactivateSession(deviceId: string, sessionId: string): void {
    const scope = interactionScopeKey(deviceId, sessionId);
    const target = this.activeTargets.get(scope);
    if (target === undefined) return;
    target.references -= 1;
    if (target.references <= 0) this.activeTargets.delete(scope);
  }

  /** Relay 重连后只补拉当前打开任务的 pending interactions。 */
  async resyncActiveSessions(): Promise<void> {
    const pending: Promise<void>[] = [];
    this.activeTargets.forEach((target: ActiveInteractionTarget) => {
      pending.push(this.refreshPending(target.deviceId, target.sessionId));
    });
    await Promise.all(pending);
  }

  /** 登出/连接显式停止时清理账号级交互状态。 */
  clearAll(): void {
    this.stateGeneration += 1;
    this.pendingByScope.clear();
    this.resolvingRequestIds.clear();
    this.resolveErrors.clear();
    this.askDrafts.clear();
    this.planDrafts.clear();
    this.mutationGenerations.clear();
    this.refreshSequences.clear();
    this.activeTargets.clear();
    this.refreshOperations.clear();
    this.nextRefreshSequence += 1;
    this.notify();
  }

  /** 提交决策（对齐 maker:resolve-interaction [requestId, decision]）。 */
  async resolve(
    deviceId: string,
    sessionId: string,
    requestId: string,
    decision: Record<string, Object>,
  ): Promise<void> {
    const client = this.client;
    if (!client) throw new Error('Device Link 未连接');
    if (this.resolvingRequestIds.has(requestId)) return;
    const stateGeneration = this.stateGeneration;
    this.resolvingRequestIds.set(requestId, stateGeneration);
    this.resolveErrors.delete(requestId);
    this.notify();
    try {
      let lastError = '';
      let resolved = false;
      for (let attempt = 0; attempt <= 3; attempt++) {
        try {
          const opts = new DlInvokeOptions();
          opts.channel = 'maker:resolve-interaction';
          opts.args = [requestId, decision];
          const envelope = await client.invoke(deviceId, opts);
          unwrapInvokeResult(envelope);
          if (stateGeneration !== this.stateGeneration) return;
          resolved = true;
          break;
        } catch (e) {
          if (stateGeneration !== this.stateGeneration) return;
          lastError = errorMessage(e);
          if (attempt >= 3 || !isRetryableResolveError(lastError)) break;
          await interactionDelay(300 * Math.pow(2, attempt));
        }
      }

      // 超时 / ack 丢失不能直接判失败：pending 权威列表里已经没有该 requestId
      // 就说明决定已生效，避免诱导用户重复提交。
      if (!resolved) {
        try {
          const pending = await this.queryPending(client, deviceId, sessionId);
          if (stateGeneration !== this.stateGeneration) return;
          let stillPending = false;
          for (let i = 0; i < pending.length; i++) {
            if (pending[i].requestId === requestId) {
              stillPending = true;
              break;
            }
          }
          if (!stillPending) {
            resolved = true;
          } else {
            this.pendingByScope.set(interactionScopeKey(deviceId, sessionId), pending);
          }
        } catch (e) {
          // 权威查询也失败，保留原始错误与原卡片供重试。
        }
      }
      if (stateGeneration !== this.stateGeneration) return;
      if (!resolved) throw new Error(lastError.length > 0 ? lastError : '提交失败');

      // 成功提交后本地移除（桌面端也会推 dismiss，双保险）。
      const scope = interactionScopeKey(deviceId, sessionId);
      const list = this.pendingByScope.get(scope) ?? [];
      const filtered = list.filter((x: PendingInteraction) => x.requestId !== requestId);
      if (filtered.length !== list.length) {
        this.pendingByScope.set(scope, filtered);
        this.bumpMutationGeneration(deviceId, sessionId);
      }
      this.askDrafts.delete(requestId);
      this.planDrafts.delete(requestId);
      this.resolveErrors.delete(requestId);
    } catch (e) {
      if (stateGeneration !== this.stateGeneration) return;
      const message = errorMessage(e);
      this.resolveErrors.set(requestId, message);
      throw new Error(message);
    } finally {
      if (this.resolvingRequestIds.get(requestId) === stateGeneration) {
        this.resolvingRequestIds.delete(requestId);
      }
      this.notify();
    }
  }

  private async queryPending(
    client: DlClient,
    deviceId: string,
    sessionId: string,
  ): Promise<PendingInteraction[]> {
    const opts = new DlInvokeOptions();
    opts.channel = 'maker:get-pending-interactions';
    opts.args = [sessionId];
    const env = await client.invoke(deviceId, opts);
    return parsePendingList(unwrapInvokeResult(env), deviceId, sessionId);
  }
}

function parsePendingList(
  result: Object | undefined,
  deviceId: string,
  sessionId: string,
): PendingInteraction[] {
  const list: PendingInteraction[] = [];
  if (!Array.isArray(result)) return list;
  const rows: Object[] = result as Object[];
  for (let i = 0; i < rows.length; i++) {
    const raw = rows[i];
    if (raw === undefined || raw === null || typeof raw !== 'object' || Array.isArray(raw)) continue;
    const row = raw as Record<string, Object>;
    const request = readObj(row, 'request');
    if (Object.keys(request).length === 0) continue;
    const item = new PendingInteraction();
    item.sessionId = sessionId;
    item.deviceId = deviceId;
    item.requestId = readStr(request, 'requestId');
    item.kind = readStr(request, 'kind');
    item.raw = request;
    item.persistId = readStr(row, 'persistId');
    if (item.requestId.length > 0) list.push(item);
  }
  return list;
}

function interactionScopeKey(deviceId: string, sessionId: string): string {
  return `${deviceId}\u0000${sessionId}`;
}

function splitInteractionScope(scope: string): InteractionScopeParts {
  const separator = scope.indexOf('\u0000');
  const parts = new InteractionScopeParts();
  if (separator < 0) {
    parts.sessionId = scope;
    return parts;
  }
  parts.deviceId = scope.slice(0, separator);
  parts.sessionId = scope.slice(separator + 1);
  return parts;
}

function errorMessage(value: Object | undefined): string {
  return safeErrorMessage(value);
}

function isRetryableResolveError(message: string): boolean {
  return message.indexOf('NOT_CONNECTED') >= 0 || message.indexOf('BACKPRESSURE') >= 0;
}

function interactionDelay(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(resolve, ms);
  });
}

function cloneAskDraft(draft: AskUserDraft): AskUserDraft {
  const clone = new AskUserDraft();
  clone.currentIndex = Math.max(0, Math.floor(draft.currentIndex));
  clone.selectedLabels = draft.selectedLabels.slice();
  clone.customInput = draft.customInput;
  clone.showCustomInput = draft.showCustomInput;
  draft.answers.forEach((value: string, key: string) => clone.answers.set(key, value));
  return clone;
}

function clonePlanDraft(draft: PlanReviewDraft): PlanReviewDraft {
  const clone = new PlanReviewDraft();
  clone.planText = draft.planText;
  clone.feedback = draft.feedback;
  clone.editMode = draft.editMode;
  clone.expanded = draft.expanded;
  clone.feedbackOpen = draft.feedbackOpen;
  return clone;
}
