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
import { readStr, readObj } from '../tasks/TaskModels';
import { unwrapInvokeResult } from '../tasks/TaskStore';

/** 挂起的交互请求。 */
export class PendingInteraction {
  sessionId: string = '';
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

export class InteractionStore {
  private client: DlClient | undefined = undefined;
  private listeners: Array<() => void> = [];
  private pendingBySession: Map<string, PendingInteraction[]> = new Map();
  private resolvingRequestIds: Set<string> = new Set();
  private resolveErrors: Map<string, string> = new Map();
  private askDrafts: Map<string, AskUserDraft> = new Map();
  private planDrafts: Map<string, PlanReviewDraft> = new Map();
  /** push/dismiss 会抬高代次，防打开页面时的慢快照覆盖刚到的实时事件。 */
  private mutationGenerations: Map<string, number> = new Map();

  attach(client: DlClient): void {
    this.client = client;
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

  getPending(sessionId: string): PendingInteraction[] {
    return this.pendingBySession.get(sessionId) ?? [];
  }

  /** 是否有阻塞交互（打开任务时决定是否显示交互面板）。 */
  hasPending(sessionId: string): boolean {
    const list = this.pendingBySession.get(sessionId);
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

  private bumpMutationGeneration(sessionId: string): void {
    this.mutationGenerations.set(sessionId, (this.mutationGenerations.get(sessionId) ?? 0) + 1);
  }

  /** push maker:interaction-request 处理。 */
  handleInteractionRequest(payload: Object | undefined): void {
    if (payload === undefined || typeof payload !== 'object') {
      return;
    }
    const p = payload as Record<string, Object>;
    const sessionId = readStr(p, 'sessionId');
    const rawRequest = readObj(p, 'request');
    if (sessionId.length === 0 || Object.keys(rawRequest).length === 0) {
      return;
    }
    const item = new PendingInteraction();
    item.sessionId = sessionId;
    item.requestId = readStr(rawRequest, 'requestId');
    item.kind = readStr(rawRequest, 'kind');
    item.raw = rawRequest;
    item.persistId = readStr(p, 'persistId');
    if (item.requestId.length === 0) {
      return;
    }
    const list = this.pendingBySession.get(sessionId) ?? [];
    // 按 requestId 去重（重复 push 覆盖）。
    const filtered = list.filter((x: PendingInteraction) => x.requestId !== item.requestId);
    filtered.push(item);
    this.pendingBySession.set(sessionId, filtered);
    this.bumpMutationGeneration(sessionId);
    this.notify();
  }

  /** push maker:interaction-dismissed 处理。 */
  handleInteractionDismissed(payload: Object | undefined): void {
    if (payload === undefined || typeof payload !== 'object') {
      return;
    }
    const p = payload as Record<string, Object>;
    const sessionId = readStr(p, 'sessionId');
    const requestId = readStr(p, 'requestId');
    if (sessionId.length === 0 || requestId.length === 0) {
      return;
    }
    const list = this.pendingBySession.get(sessionId);
    if (!list) {
      return;
    }
    const filtered = list.filter((x: PendingInteraction) => x.requestId !== requestId);
    if (filtered.length !== list.length) {
      this.pendingBySession.set(sessionId, filtered);
      this.resolvingRequestIds.delete(requestId);
      this.resolveErrors.delete(requestId);
      this.askDrafts.delete(requestId);
      this.planDrafts.delete(requestId);
      this.bumpMutationGeneration(sessionId);
      this.notify();
    }
  }

  /** 打开会话时拉挂起交互快照（对齐 mobile getPendingInteractions）。 */
  async refreshPending(deviceId: string, sessionId: string): Promise<void> {
    const client = this.client;
    if (!client) {
      return;
    }
    const generation = this.mutationGenerations.get(sessionId) ?? 0;
    try {
      const list = await this.queryPending(client, deviceId, sessionId);
      if ((this.mutationGenerations.get(sessionId) ?? 0) !== generation) return;
      this.pendingBySession.set(sessionId, list);
      this.notify();
    } catch (e) {
      // 拉取失败：保留现状（push 会继续补充）。
    }
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
    this.resolvingRequestIds.add(requestId);
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
          await client.invoke(deviceId, opts);
          resolved = true;
          break;
        } catch (e) {
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
            this.pendingBySession.set(sessionId, pending);
          }
        } catch (e) {
          // 权威查询也失败，保留原始错误与原卡片供重试。
        }
      }
      if (!resolved) throw new Error(lastError.length > 0 ? lastError : '提交失败');

      // 成功提交后本地移除（桌面端也会推 dismiss，双保险）。
      this.pendingBySession.forEach((list: PendingInteraction[], sid: string) => {
        const filtered = list.filter((x: PendingInteraction) => x.requestId !== requestId);
        if (filtered.length !== list.length) {
          this.pendingBySession.set(sid, filtered);
          this.bumpMutationGeneration(sid);
        }
      });
      this.askDrafts.delete(requestId);
      this.planDrafts.delete(requestId);
      this.resolveErrors.delete(requestId);
    } catch (e) {
      const message = errorMessage(e);
      this.resolveErrors.set(requestId, message);
      throw new Error(message);
    } finally {
      this.resolvingRequestIds.delete(requestId);
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
    return parsePendingList(unwrapInvokeResult(env), sessionId);
  }
}

function parsePendingList(result: Object | undefined, sessionId: string): PendingInteraction[] {
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
    item.requestId = readStr(request, 'requestId');
    item.kind = readStr(request, 'kind');
    item.raw = request;
    item.persistId = readStr(row, 'persistId');
    if (item.requestId.length > 0) list.push(item);
  }
  return list;
}

function errorMessage(value: Object): string {
  return value instanceof Error ? value.message : JSON.stringify(value);
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
