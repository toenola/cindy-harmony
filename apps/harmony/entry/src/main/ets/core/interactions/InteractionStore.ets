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

export class InteractionStore {
  private client: DlClient | undefined = undefined;
  private listeners: Array<() => void> = [];
  private pendingBySession: Map<string, PendingInteraction[]> = new Map();

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
      this.notify();
    }
  }

  /** 打开会话时拉挂起交互快照（对齐 mobile getPendingInteractions）。 */
  async refreshPending(deviceId: string, sessionId: string): Promise<void> {
    const client = this.client;
    if (!client) {
      return;
    }
    try {
      const opts = new DlInvokeOptions();
      opts.channel = 'maker:get-pending-interactions';
      opts.args = [sessionId];
      const env = await client.invoke(deviceId, opts);
      const result = unwrapInvokeResult(env);
      const list: PendingInteraction[] = [];
      if (Array.isArray(result)) {
        const rows: Object[] = result as Object[];
        for (let i = 0; i < rows.length; i++) {
          const raw = rows[i];
          if (raw === undefined || typeof raw !== 'object' || Array.isArray(raw)) {
            continue;
          }
          const row = raw as Record<string, Object>;
          const request = readObj(row, 'request');
          if (Object.keys(request).length === 0) {
            continue;
          }
          const item = new PendingInteraction();
          item.sessionId = sessionId;
          item.requestId = readStr(request, 'requestId');
          item.kind = readStr(request, 'kind');
          item.raw = request;
          item.persistId = readStr(row, 'persistId');
          if (item.requestId.length > 0) {
            list.push(item);
          }
        }
      }
      this.pendingBySession.set(sessionId, list);
      this.notify();
    } catch (e) {
      // 拉取失败：保留现状（push 会继续补充）。
    }
  }

  /** 提交决策（对齐 maker:resolve-interaction [requestId, decision]）。 */
  async resolve(deviceId: string, requestId: string, decision: Record<string, Object>): Promise<void> {
    const client = this.client;
    if (!client) {
      return;
    }
    const opts = new DlInvokeOptions();
    opts.channel = 'maker:resolve-interaction';
    opts.args = [requestId, decision];
    await client.invoke(deviceId, opts);
    // 成功提交后本地移除（桌面端也会推 dismiss，双保险）。
    this.pendingBySession.forEach((list: PendingInteraction[], sid: string) => {
      const filtered = list.filter((x: PendingInteraction) => x.requestId !== requestId);
      if (filtered.length !== list.length) {
        this.pendingBySession.set(sid, filtered);
      }
    });
    this.notify();
  }
}
