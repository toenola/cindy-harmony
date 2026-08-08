/**
 * 消息 Store：历史加载 + 流式增量 + 发送/停止。
 *
 * - 打开会话：subscribe `session:<id>` topic → 拉最近一页历史（desc，
 *   limit=50），再反转为升序渲染。
 * - push：`local-db:messages:created` 逐条追加（按 id 去重）、
 *   `local-db:messages:deleted` 按 clientId 移除。
 * - 发送：invoke maker:send（createOpts 由会话字段构造，persistUserMessage 由 Harmony 生成）；
 *   Desktop accepted 事务先落库，再由 push/发送后重拉进入渲染，不直接乐观插入。
 * - 桌面端是权威来源；断线补齐（gap healing）属于切片 5。
 *
 * ArkTS 约束：对象字面量一律先声明 Record 再逐键赋值；调用 DlInvokeOptions
 * 显式 new，避免字面量缺字段。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { DlClient, DlInvokeOptions } from '../device-link/DlClient';
import { DlChannels, sessionTopic, Envelope } from '../device-link/DlProtocol';
import {
  RemoteMessage, RemoteSession, parseMessage, sortMessagesAsc,
  readStr, readObj, readBool,
} from '../tasks/TaskModels';
import { RemoteImageRef, RemoteMediaFetchResult } from '../attachments/AttachmentModels';
import { summarizeText } from './MessageRender';
import { unwrapInvokeResult } from '../tasks/TaskStore';

const DOMAIN = 0x0000;
const TAG = 'CindyMsg';

// 与 Desktop local-db:messages:list 的默认页大小一致。Harmony 走 Device Link 时，
// 工具结果可能还要经过压缩/裁页；100 条会让特殊会话在一次响应和 UI 重建中卡很久。
const HISTORY_PAGE_LIMIT = 50;

function hasTurnContinuation(event: Record<string, Object>): boolean {
  const value = event['turnContinuationId'];
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
}

/** 流式 tool 行（maker:event tool_use 增量，落库后由真实行替代）。 */
export class StreamingToolRow {
  toolUseId: string = '';
  toolName: string = '';
  /** 工具摘要（input 浓缩）。 */
  inputText: string = '';
  /** true = tool_result 事件已到（或收到 done）。 */
  settled: boolean = false;
  /** tool_result 明确标记失败。 */
  hasError: boolean = false;
}

/** 流式 assistant 消息（maker:event 增量累积，落库后清除）。 */
export class StreamingMessage {
  sessionId: string = '';
  /** 正文 delta 累积。 */
  text: string = '';
  /** 流式 tool 行（tool_use 事件增量，按 toolUseId 去重）。 */
  tools: StreamingToolRow[] = [];
  createdAt: string = '';
  /** 终态事件已到，但持久化 assistant 行可能尚未通过 push 回来。 */
  finished: boolean = false;
}

/** history:messages 一页响应（messages:list 复用）。 */
class HistoryPage {
  items: RemoteMessage[] = [];
  hasMore: boolean = false;
}

/** maker:send 的 user 消息形态（对齐 mobile chatMessage）。 */
class UserMessageArgs {
  type: string = 'user';
  content: string | Object[] = '';
}

/** maker:send 的 createOpts（由会话字段构造）。 */
class CreateOptsArgs {
  agentKind: string = '';
  workingDir: string = '';
  model: string = '';
  providerId: string | null = null;
  effort: string = '';
  permissionMode: string = '';
  planMode: boolean = false;
  fastMode: boolean = false;
}

export class MessageStore {
  private client: DlClient | undefined = undefined;
  private listeners: Array<() => void> = [];
  private messagesBySession: Map<string, RemoteMessage[]> = new Map();
  /** sessionId -> deviceId（当前订阅关系）。 */
  private subscribed: Map<string, string> = new Map();
  private hasMoreBySession: Map<string, boolean> = new Map();
  /** 会话列表透出的服务端消息总数，用于短页（payload 裁剪）时判断还有历史。 */
  private messageCountBySession: Map<string, number> = new Map();
  /** 流式 assistant 消息（maker:event 累积）。 */
  private streamingBySession: Map<string, StreamingMessage> = new Map();
  /** maker 权威运行态；与临时正文投影分开，避免终态事件丢失时 Composer 卡住。 */
  private runningBySession: Map<string, boolean> = new Map();
  /** 远程运行态查询的代次，防止旧快照覆盖在途 maker 事件。 */
  private runningStateRevisions: Map<string, number> = new Map();
  /** 历史加载失败标记（TaskPage 显示重试入口）。 */
  private loadFailedBySession: Map<string, boolean> = new Map();
  /** 发送消息的客户端 id；同时作为 Desktop transcript 的幂等键。 */
  private sendSequence: number = 0;
  /** 打开会话前先确保控制链路（AppServices 注入，内部做 link-open + 幂等）。 */
  private linkOpener: ((deviceId: string) => Promise<void>) | undefined = undefined;

  attach(client: DlClient): void {
    this.client = client;
  }

  /** 注入链路建立器（AppServices 在组装时调用）。 */
  setLinkOpener(fn: (deviceId: string) => Promise<void>): void {
    this.linkOpener = fn;
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

  getMessages(sessionId: string): RemoteMessage[] {
    return this.messagesBySession.get(sessionId) ?? [];
  }

  /** 当前会话是否仍在执行；maker 运行态优先于历史投影。 */
  isSessionStreaming(sessionId: string): boolean {
    if (this.runningBySession.get(sessionId) === true) return true;
    const s = this.streamingBySession.get(sessionId);
    if (s !== undefined && !s.finished && (s.text.length > 0 || s.tools.length > 0)) return true;
    // 历史/断线恢复可能只留下 agentMeta.isStreaming 投影；只检查最后一个 user
    // 之后的尾部，避免旧 turn 的残留标记把整段历史当成正在运行。
    const messages = this.messagesBySession.get(sessionId) ?? [];
    for (let i = messages.length - 1; i >= 0; i--) {
      const message = messages[i];
      if (message.role === 'user') break;
      if (message.isStreaming && !message.turnCompleted) return true;
    }
    return false;
  }

  hasMore(sessionId: string): boolean {
    return this.hasMoreBySession.get(sessionId) ?? false;
  }

  /** 写入任务列表的服务端消息总数，并立即校正当前分页状态。 */
  setMessageCount(sessionId: string, count: number): void {
    if (count <= 0) {
      this.messageCountBySession.delete(sessionId);
      return;
    }
    this.messageCountBySession.set(sessionId, count);
    const current = this.messagesBySession.get(sessionId) ?? [];
    if (current.length === 0) return;
    this.hasMoreBySession.set(sessionId, count > countRealMessages(current));
  }

  /** 该会话历史是否加载失败（页面据此显示重试）。 */
  loadFailed(sessionId: string): boolean {
    return this.loadFailedBySession.get(sessionId) ?? false;
  }

  // ─── 打开 / 关闭 ────────────────────────────────────────────────────────────

  /** 打开会话：确保控制链路 → 拉历史（优先）→ 订阅实时流（并行，失败不阻塞）。 */
  async openSession(deviceId: string, sessionId: string): Promise<boolean> {
    const client = this.client;
    if (!client) {
      this.loadFailedBySession.set(sessionId, true);
      this.notify();
      return false;
    }
    if (this.subscribed.get(sessionId) === deviceId) {
      // 已打开：重新拉一次历史（重进页面恢复用）。
      const loaded = await this.loadInitial(deviceId, sessionId);
      void this.refreshSessionRunningState(deviceId, sessionId);
      return loaded;
    }
    // 先确保控制链路（link-open），否则 subscribe / history 会挂起或失败。
    if (this.linkOpener !== undefined) {
      try {
        await this.linkOpener(deviceId);
      } catch (e) {
        // link 失败不阻断历史加载尝试
      }
    }
    this.subscribed.set(sessionId, deviceId);
    // 订阅实时流（并行，失败不阻塞历史）。
    client.subscribe(deviceId, [sessionTopic(sessionId)]).catch(() => {
    });
    const loaded = await this.loadInitial(deviceId, sessionId);
    void this.refreshSessionRunningState(deviceId, sessionId);
    return loaded;
  }

  /** 关闭会话：注销订阅并清内存（页面退出时调用）。 */
  async closeSession(sessionId: string): Promise<void> {
    const deviceId = this.subscribed.get(sessionId);
    this.subscribed.delete(sessionId);
    this.messagesBySession.delete(sessionId);
    this.hasMoreBySession.delete(sessionId);
    this.messageCountBySession.delete(sessionId);
    this.loadFailedBySession.delete(sessionId);
    this.streamingBySession.delete(sessionId);
    this.runningBySession.delete(sessionId);
    this.runningStateRevisions.delete(sessionId);
    if (deviceId !== undefined) {
      const client = this.client;
      if (client) {
        try {
          await client.unsubscribe(deviceId, [sessionTopic(sessionId)]);
        } catch (e) {
          // fire-and-forget
        }
      }
    }
    this.notify();
  }

  /** 生成本端唯一的 transcript clientId；不依赖额外原生 UUID API。 */
  private nextSendClientId(): string {
    this.sendSequence += 1;
    const timestamp = Date.now().toString(36);
    const randomPart = Math.random().toString(36).slice(2, 10);
    const sequence = this.sendSequence.toString(36);
    return `harmony-${timestamp}-${randomPart}-${sequence}`;
  }

  // ─── 历史加载 ───────────────────────────────────────────────────────────────

  /**
   * 重连恢复：重新订阅 + gap healing（断线期间消息补齐）。
   * 拉最新窗口与现有合并去重——保留早于窗口的本地缓存，补上断线缺口。
   */
  async resubscribeAndHeal(deviceId: string, sessionId: string): Promise<void> {
    const client = this.client;
    if (!client) {
      return;
    }
    // relay 新连接后旧订阅失效，需重新 subscribe。
    try {
      await client.subscribe(deviceId, [sessionTopic(sessionId)]);
    } catch (e) {
      // 订阅失败不阻断 healing
    }
    try {
      const page = await this.requestMessagesList(deviceId, sessionId, HISTORY_PAGE_LIMIT, '');
      page.items.sort(sortMessagesAsc);
      const existing = this.messagesBySession.get(sessionId) ?? [];
      const merged = this.mergeWithoutDuplicates(page.items, existing);
      merged.sort(sortMessagesAsc);
      this.messagesBySession.set(sessionId, merged);
      this.hasMoreBySession.set(sessionId, this.hasMoreAfterPage(sessionId, page, merged));
      this.notify();
      void this.refreshSessionRunningState(deviceId, sessionId);
    } catch (e) {
      // healing 失败：保持现有消息，等下一次重连恢复。
    }
  }

  /** 重连 online 后，对所有已打开会话做恢复（AppServices 调用）。 */
  resubscribeAll(): void {
    const devices = new Set<string>();
    this.subscribed.forEach((deviceId: string, sessionId: string) => {
      devices.add(deviceId);
      void this.resubscribeAndHeal(deviceId, sessionId);
    });
    devices.forEach((deviceId: string) => {
      void this.hydrateActiveSessions(deviceId);
    });
  }

  /** 从被控端 active 快照恢复已存在的运行态；终态清理仍由显式 session 探针负责。 */
  async hydrateActiveSessions(deviceId: string): Promise<void> {
    const client = this.client;
    if (!client) return;
    const opts = new DlInvokeOptions();
    opts.channel = DlChannels.MAKER_LIST_ACTIVE;
    opts.args = [];
    try {
      const env = await client.invoke(deviceId, opts);
      const result = unwrapInvokeResult(env);
      if (!Array.isArray(result)) return;
      let changed = false;
      const active: Object[] = result as Object[];
      for (let i = 0; i < active.length; i++) {
        const row = active[i];
        if (row === undefined || typeof row !== 'object' || Array.isArray(row)) continue;
        const record = row as Record<string, Object>;
        const sessionId = readStr(record, 'sessionId');
        if (sessionId.length === 0 || !readBool(record, 'isTurnRunning', false)) continue;
        this.bumpRunningStateRevision(sessionId);
        if (this.runningBySession.get(sessionId) !== true) {
          this.markSessionRunning(sessionId, true);
          changed = true;
        }
      }
      if (changed) this.notify();
    } catch (e) {
      // 老版本 Desktop 或暂时断链时由单会话探针 / maker:event 兜底。
    }
  }

  /** maker:event 处理：运行态按终态语义收口，流式正文保留到持久化行回流。 */
  handleMakerEvent(sessionId: string, event: Object | undefined): void {
    if (event === undefined || typeof event !== 'object') {
      return;
    }
    const ev = event as Record<string, Object>;
    const type = readStr(ev, 'type');
    const data = readObj(ev, 'data');
    this.bumpRunningStateRevision(sessionId);

    if (type === 'compact_boundary') {
      // 压缩边界结束旧投影，但通常仍属于同一产品 turn；后续事件会重新建立新投影。
      this.markSessionRunning(sessionId, true);
      this.appendCompactBoundary(sessionId, data);
      return;
    }
    if (type === 'text') {
      this.markSessionRunning(sessionId, true);
      const delta = readStr(data, 'text');
      if (delta.length === 0) {
        return;
      }
      const s = this.ensureStreaming(sessionId);
      s.text += delta;
      this.notify();
      return;
    }
    if (type === 'tool_use') {
      this.markSessionRunning(sessionId, true);
      const toolUseId = readStr(data, 'toolUseId');
      if (toolUseId.length === 0) {
        return;
      }
      const s = this.ensureStreaming(sessionId);
      // 同 toolUseId 原地更新（不重复建行）。
      let row = s.tools.find((t: StreamingToolRow) => t.toolUseId === toolUseId);
      if (row === undefined) {
        row = new StreamingToolRow();
        row.toolUseId = toolUseId;
        s.tools.push(row);
      }
      row.toolName = readStr(data, 'toolName');
      row.settled = false;
      const rawInput = data['input'];
      if (rawInput !== undefined) {
        row.inputText = summarizeText(JSON.stringify(rawInput));
      }
      this.notify();
      return;
    }
    if (type === 'tool_result' || type === 'tool_result_full') {
      this.markSessionRunning(sessionId, true);
      // 结果事件：标记对应 tool 行完成（正文继续流式，落库行稍后到达）。
      const s = this.streamingBySession.get(sessionId);
      if (s === undefined) {
        this.notify();
        return;
      }
      const toolUseId = readStr(data, 'toolUseId');
      if (toolUseId.length > 0) {
        const row = s.tools.find((t: StreamingToolRow) => t.toolUseId === toolUseId);
        if (row !== undefined) {
          row.settled = true;
          row.hasError = readBool(data, 'isError', false)
            || readBool(data, 'is_error', false);
        }
      }
      this.notify();
      return;
    }
    if (type === 'thinking') {
      this.markSessionRunning(sessionId, true);
      // thinking 不增量；由落库行（role=thinking）驱动正文渲染。
      this.notify();
      return;
    }
    if (type === 'status') {
      const isRunning = ev['data'] !== undefined && typeof data['isRunning'] === 'boolean'
        ? data['isRunning'] as boolean
        : undefined;
      if (isRunning === true) {
        this.markSessionRunning(sessionId, true);
      } else if (isRunning === false) {
        if (hasTurnContinuation(ev)) {
          // provider segment ends, but the product turn continues.
          this.markSessionRunning(sessionId, true);
        } else {
          this.finalizeSessionStreaming(sessionId);
        }
      }
      this.notify();
      return;
    }
    if (type === 'done') {
      const s = this.streamingBySession.get(sessionId);
      if (s !== undefined) {
        s.tools.forEach((t: StreamingToolRow) => {
          t.settled = true;
        });
      }
      if (hasTurnContinuation(ev)) {
        // SDK segment 结束但产品 turn 仍会继续，不能把 Composer 切回停止态。
        this.markSessionRunning(sessionId, true);
      } else {
        this.finalizeSessionStreaming(sessionId);
      }
      this.notify();
      return;
    }
    if (type === 'error') {
      const terminal = readBool(data, 'isTerminal', !readBool(data, 'willRetry', false));
      if (terminal) {
        this.finalizeSessionStreaming(sessionId);
      } else {
        this.markSessionRunning(sessionId, true);
      }
      this.notify();
    }
  }


  /** 取或建流式消息。 */
  private ensureStreaming(sessionId: string): StreamingMessage {
    let s = this.streamingBySession.get(sessionId);
    if (s === undefined || s.finished) {
      s = new StreamingMessage();
      s.sessionId = sessionId;
      s.createdAt = new Date().toISOString();
      this.streamingBySession.set(sessionId, s);
    }
    return s;
  }

  private bumpRunningStateRevision(sessionId: string): number {
    const next = (this.runningStateRevisions.get(sessionId) ?? 0) + 1;
    this.runningStateRevisions.set(sessionId, next);
    return next;
  }

  private markSessionRunning(sessionId: string, running: boolean): void {
    if (running) {
      this.runningBySession.set(sessionId, true);
    } else {
      this.runningBySession.delete(sessionId);
    }
  }

  /** 终态收口：保留临时正文用于最终渲染，但去掉所有运行标记。 */
  private finalizeSessionStreaming(sessionId: string): void {
    this.runningBySession.delete(sessionId);
    this.finishStreamingProjection(sessionId);
  }

  /** 收口当前 provider 段的临时投影，但保留产品级 running 状态（交互/续跑）。 */
  private finishStreamingProjection(sessionId: string): void {
    const s = this.streamingBySession.get(sessionId);
    if (s !== undefined) {
      s.finished = true;
      s.tools.forEach((t: StreamingToolRow) => {
        t.settled = true;
      });
    }
    const messages = this.messagesBySession.get(sessionId);
    if (messages !== undefined) {
      for (let i = 0; i < messages.length; i++) {
        messages[i].isStreaming = false;
      }
    }
  }

  /** maker session status push：closed 是 session 生命周期终态，也要收口本地运行投影。 */
  handleMakerStatusChanged(payload: Object | undefined): void {
    if (payload === undefined || typeof payload !== 'object') return;
    const p = payload as Record<string, Object>;
    const sessionId = readStr(p, 'sessionId');
    if (sessionId.length === 0 || readStr(p, 'status') !== 'closed') return;
    this.bumpRunningStateRevision(sessionId);
    this.finalizeSessionStreaming(sessionId);
    this.notify();
  }

  /** maker:event 之外的 sessions 活动态是漏终态时的第二条收口路径。 */
  handleSessionActivity(payload: Object | undefined): void {
    if (payload === undefined || typeof payload !== 'object') return;
    const p = payload as Record<string, Object>;
    const sessionId = readStr(p, 'sessionId');
    if (sessionId.length === 0) return;
    const phase = readStr(p, 'phase');
    const rawRunning = p['isRunning'];
    this.bumpRunningStateRevision(sessionId);
    // phase 是 Desktop activity 协议的权威字段；只有旧版本没有 phase 时才回退
    // 到 isRunning，避免 completed/error 携带陈旧 true 时把 Composer 重新点亮。
    if (phase === 'running' || phase === 'needs-interaction') {
      this.markSessionRunning(sessionId, true);
      if (phase === 'needs-interaction') {
        this.finishStreamingProjection(sessionId);
      }
    } else if (phase === 'completed' || phase === 'error') {
      this.finalizeSessionStreaming(sessionId);
    } else if (rawRunning === true) {
      this.markSessionRunning(sessionId, true);
    } else if (rawRunning === false) {
      this.finalizeSessionStreaming(sessionId);
    } else {
      return;
    }
    this.notify();
  }

  /** 打开/重连时向被控端核实 live session，避免历史 isStreaming 标记永久卡住。 */
  private async refreshSessionRunningState(deviceId: string, sessionId: string): Promise<void> {
    const client = this.client;
    if (!client) return;
    const revision = this.runningStateRevisions.get(sessionId) ?? 0;
    const opts = new DlInvokeOptions();
    opts.channel = DlChannels.MAKER_SESSION_IN_TURN;
    opts.args = [sessionId];
    try {
      const env = await client.invoke(deviceId, opts);
      if ((this.runningStateRevisions.get(sessionId) ?? 0) !== revision) return;
      const result = unwrapInvokeResult(env);
      if (typeof result !== 'boolean') return;
      this.bumpRunningStateRevision(sessionId);
      if (result) {
        this.markSessionRunning(sessionId, true);
      } else {
        this.finalizeSessionStreaming(sessionId);
      }
      this.notify();
    } catch (e) {
      // 老版本 Desktop 未提供该只读探针时，继续依赖 maker:event / activity。
    }
  }


  /**
   * maker:event compact_boundary 的本地投影（对齐 mobile remoteSessionStore）。
   * 该行通常不会持久化到 Desktop DB，但 transcript replay / live event 都可能
   * 到达 Harmony，所以必须用稳定 id 去重。
   */
  private appendCompactBoundary(sessionId: string, data: Record<string, Object>): void {
    const boundaryId = readStr(data, 'boundaryId');
    const clientId = boundaryId.length > 0
      ? `harmony-system-compact:${boundaryId}`
      : `harmony-system-compact:fallback:${compactBoundaryFingerprint(data)}`;
    const existing = this.messagesBySession.get(sessionId) ?? [];
    if (existing.some((message: RemoteMessage) =>
      message.id === clientId || message.clientId === clientId)) {
      return;
    }

    // 只结束压缩前的临时流式投影；不要调用普通 done finalizer，避免压缩边界
    // 之后新一轮流式正文被误清掉。
    this.streamingBySession.delete(sessionId);
    for (let i = 0; i < existing.length; i++) {
      existing[i].isStreaming = false;
    }

    const boundary = new RemoteMessage();
    boundary.id = clientId;
    boundary.clientId = clientId;
    boundary.sessionId = sessionId;
    boundary.role = 'assistant';
    boundary.content = '';
    boundary.createdAt = new Date().toISOString();
    boundary.systemCardType = 'compact';
    boundary.systemCardData = data;
    existing.push(boundary);
    existing.sort(sortMessagesAsc);
    this.messagesBySession.set(sessionId, existing);
    this.notify();
  }

  /** 当前流式消息（无则 undefined）。 */
  getStreaming(sessionId: string): StreamingMessage | undefined {
    return this.streamingBySession.get(sessionId);
  }

  /**
   * 历史消息 + 流式临时消息（正文/工具行）合并，供渲染模型统一构建。
   * 流式工具行走 tool_use 角色 → buildRenderItems 自然产出 tool_group；
   * 流式正文走 assistant 角色 → 与历史消息同路径，thinking/tool 组由
   * work_group 聚合规则收进折叠面板。
   */
  getMessagesWithStreaming(sessionId: string): RemoteMessage[] {
    const base = this.messagesBySession.get(sessionId) ?? [];
    const s = this.streamingBySession.get(sessionId);
    if (s === undefined || (s.text.length === 0 && s.tools.length === 0)) {
      return base;
    }
    const isStreaming = !s.finished;
    const tmp: RemoteMessage[] = [];
    for (let i = 0; i < s.tools.length; i++) {
      const t = s.tools[i];
      const tm = new RemoteMessage();
      tm.id = `streaming-tool-${t.toolUseId}`;
      tm.role = 'tool_use';
      tm.toolUseId = t.toolUseId;
      tm.createdAt = s.createdAt;
      tm.isStreaming = isStreaming;
      const content: Record<string, Object> = {};
      content['toolUseId'] = t.toolUseId;
      content['toolName'] = t.toolName;
      const inputObj: Record<string, Object> = {};
      if (t.inputText.length > 0) {
        content['input'] = t.inputText;
      } else {
        content['input'] = inputObj;
      }
      tm.content = content;
      tmp.push(tm);
      if (t.settled) {
        const result = new RemoteMessage();
        result.id = `streaming-result-${t.toolUseId}`;
        result.role = 'tool_result';
        result.toolUseId = t.toolUseId;
        result.createdAt = s.createdAt;
        result.isStreaming = isStreaming;
        const resultContent: Record<string, Object> = {};
        resultContent['toolUseId'] = t.toolUseId;
        resultContent['isError'] = t.hasError;
        resultContent['text'] = '';
        result.content = resultContent;
        tmp.push(result);
      }
    }
    if (s.text.length > 0) {
      const tm = new RemoteMessage();
      tm.id = `streaming-text-${sessionId}`;
      tm.role = 'assistant';
      tm.createdAt = s.createdAt;
      tm.content = s.text;
      tm.isStreaming = isStreaming;
      tmp.push(tm);
    }
    return base.concat(tmp);
  }

  /** assistant 正文落库时清对应流式缓存；thinking/tool 落库不清（正文还在路上）。 */
  private clearStreamingIfAssistant(sessionId: string, message: RemoteMessage): void {
    if (message.role !== 'assistant') {
      return;
    }
    if (this.streamingBySession.delete(sessionId)) {
      this.notify();
    }
  }

  private async loadInitial(deviceId: string, sessionId: string): Promise<boolean> {
    const client = this.client;
    if (!client) return false;
    try {
      // 对齐 iOS：历史走 local-db:messages:list（返回完整行含 clientId，最新在前）。
      const page = await this.requestMessagesList(deviceId, sessionId, HISTORY_PAGE_LIMIT, '');
      page.items.sort(sortMessagesAsc);
      // 与已存在的（可能来自更早 push 的暂存）合并去重，避免整窗覆盖丢消息。
      const existing = this.messagesBySession.get(sessionId) ?? [];
      const merged = this.mergeWithoutDuplicates(page.items, existing);
      merged.sort(sortMessagesAsc);
      this.messagesBySession.set(sessionId, merged);
      this.hasMoreBySession.set(sessionId, this.hasMoreAfterPage(sessionId, page, merged));
      this.loadFailedBySession.delete(sessionId);
      // 临时诊断：确认 user 消息是否在数据层（对比渲染层丢失）。
      let userCount = 0;
      let assistantCount = 0;
      let otherCount = 0;
      for (let i = 0; i < page.items.length; i++) {
        const r = page.items[i].role;
        if (r === 'user') userCount += 1;
        else if (r === 'assistant') assistantCount += 1;
        else otherCount += 1;
      }
      hilog.info(DOMAIN, TAG, 'history loaded total=%{public}d user=%{public}d assistant=%{public}d other=%{public}d hasMore=%{public}s',
        page.items.length, userCount, assistantCount, otherCount, page.hasMore ? 'true' : 'false');
      this.notify();
      return true;
    } catch (e) {
      // 加载失败：标记失败（页面提供重试），不保持空列表假装成功。
      const msg = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.warn(DOMAIN, TAG, 'loadInitial failed session=%{public}s err=%{public}s',
        sessionId.slice(0, 8), msg);
      this.loadFailedBySession.set(sessionId, true);
      this.notify();
      return false;
    }
  }

  /** 向上翻页（加载更早消息，追加到列表头部）。 */
  async loadOlder(deviceId: string, sessionId: string): Promise<void> {
    const client = this.client;
    if (!client) return;
    if (!this.hasMore(sessionId)) return;
    const current = this.messagesBySession.get(sessionId) ?? [];
    // asc 序最早一条的 id 作为 before 游标（messages:list 是 desc，before = 更早）。
    const firstId = oldestMessageCursor(current);
    if (firstId.length === 0) return;
    try {
      const page = await this.requestMessagesList(deviceId, sessionId, HISTORY_PAGE_LIMIT, firstId);
      page.items.sort(sortMessagesAsc);
      const merged = this.mergeWithoutDuplicates(page.items, current);
      merged.sort(sortMessagesAsc);
      this.messagesBySession.set(sessionId, merged);
      const progressed = merged.length > current.length;
      this.hasMoreBySession.set(sessionId,
        progressed && this.hasMoreAfterPage(sessionId, page, merged));
      hilog.info(DOMAIN, TAG,
        'history older loaded before=%{public}s page=%{public}d added=%{public}d hasMore=%{public}s',
        firstId.slice(0, 8), page.items.length, Math.max(0, merged.length - current.length),
        this.hasMore(sessionId) ? 'true' : 'false');
      this.notify();
    } catch (e) {
      const msg = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.warn(DOMAIN, TAG, 'history older failed session=%{public}s err=%{public}s',
        sessionId.slice(0, 8), msg);
    }
  }

  /**
   * Mobile 同源判定：满页 / remoteRowsTrimmed / 服务端总数均说明上沿还有历史。
   * 若旧桌面端没有透出总数或裁页标记，非空短首屏也保留一次上翻机会；空页返回后
   * hasMore 会被置 false，避免持续重试。
   */
  private hasMoreAfterPage(sessionId: string, page: HistoryPage, merged: RemoteMessage[]): boolean {
    if (page.items.length === 0) return false;
    if (page.hasMore) return true;
    const total = this.messageCountBySession.get(sessionId) ?? 0;
    if (total > countRealMessages(merged)) return true;
    return merged.length > 0 && total === 0;
  }

  /**
   * local-db:messages:list（对齐 iOS 主历史通道）：最新在前（desc），
   * before 为更早分页游标（消息 id）。返回完整行含 clientId。
   */
  private requestMessagesList(
    deviceId: string,
    sessionId: string,
    limit: number,
    beforeId: string,
  ): Promise<HistoryPage> {
    const client = this.client;
    if (!client) {
      return Promise.reject(new Error('client not attached'));
    }
    const optsObj: Record<string, Object> = {};
    optsObj['limit'] = limit;
    if (beforeId.length > 0) {
      optsObj['before'] = beforeId;
    }
    const args: Object[] = [sessionId, optsObj];
    const opts = new DlInvokeOptions();
    opts.channel = 'local-db:messages:list';
    opts.args = args;
    return client.invoke(deviceId, opts).then((env: Envelope) => {
      const result = unwrapInvokeResult(env);
      const items: RemoteMessage[] = [];
      if (Array.isArray(result)) {
        const rows: Object[] = result as Object[];
        for (let i = 0; i < rows.length; i++) {
          const raw = rows[i];
          if (raw === undefined || typeof raw !== 'object' || Array.isArray(raw)) {
            continue;
          }
          try {
            items.push(parseMessage(raw as Record<string, Object>));
          } catch (e) {
            // 单条消息解析失败不拖垮整个会话历史（跳过并记录）。
            const msg = e instanceof Error ? e.message : JSON.stringify(e);
            hilog.warn(DOMAIN, TAG, 'skip unparsable message row=%{public}d err=%{public}s', i, msg);
          }
        }
      }
      const out = new HistoryPage();
      out.items = items;
      // messages:list 没有 hasMore 字段：满载即可能还有更早；但 device-link 为避免
      // 超过 relay 帧上限会裁掉页尾，并在保留行的 agentMeta 上打 remoteRowsTrimmed。
      // 这种页通常少于 limit，不能把它误判成已经到历史起点（Mobile 同源判定）。
      let remoteRowsTrimmed = false;
      for (let i = 0; i < items.length; i++) {
        if (readBool(items[i].agentMeta, 'remoteRowsTrimmed', false)) {
          remoteRowsTrimmed = true;
          break;
        }
      }
      out.hasMore = items.length >= limit || remoteRowsTrimmed;
      return out;
    }).catch((e: Error) => {
      // invoke 失败（网络 / 桌面端 IPC 错误）：记录确切原因供排查。
      hilog.warn(DOMAIN, TAG, 'messages:list failed session=%{public}s err=%{public}s',
        sessionId.slice(0, 8), e.message);
      throw e;
    });
  }

  // ─── push 增量 ──────────────────────────────────────────────────────────────

  handleSessionPush(deviceId: string, channel: string, payload: Object | undefined): void {
    switch (channel) {
      case 'local-db:messages:created':
        this.appendCreated(payload);
        break;
      case 'local-db:messages:deleted':
        this.removeDeleted(payload);
        break;
      case 'local-db:session:error-persisted': {
        const p = payload as Record<string, Object>;
        const sessionId = readStr(p, 'sessionId');
        if (sessionId.length > 0 && this.subscribed.has(sessionId)) {
          // 会话尾部落 error 行：重载一次让错误消息可见。
          void this.loadInitial(deviceId, sessionId);
        }
        break;
      }
      case 'local-db:sessions:activity':
        this.handleSessionActivity(payload);
        break;
      default:
        break;
    }
  }

  private appendCreated(payload: Object | undefined): void {
    if (payload === undefined || typeof payload !== 'object') return;
    const p = payload as Record<string, Object>;
    const sessionId = readStr(p, 'sessionId');
    const rawMessage = readObj(p, 'message');
    if (sessionId.length === 0 || Object.keys(rawMessage).length === 0) return;
    const message = parseMessage(rawMessage);
    if (message.id.length === 0) return;
    let list = this.messagesBySession.get(sessionId);
    if (!list) {
      // push 可能早于首次历史加载到达：先建列表，loadInitial 会合并去重。
      const fresh: RemoteMessage[] = [];
      fresh.push(message);
      fresh.sort(sortMessagesAsc);
      this.messagesBySession.set(sessionId, fresh);
      this.clearStreamingIfAssistant(sessionId, message);
      this.notify();
      return;
    }
    if (list.some((m: RemoteMessage) => m.id === message.id)) {
      this.clearStreamingIfAssistant(sessionId, message);
      return; // 去重
    }
    list.push(message);
    list.sort(sortMessagesAsc);
    // 正文行（assistant）落库 = 流式正文已持久化，清临时；thinking/tool 行落库保留
    // 流式正文（它们只是工作过程的持久化，正文还在路上）。
    this.clearStreamingIfAssistant(sessionId, message);
    this.notify();
  }

  private removeDeleted(payload: Object | undefined): void {
    if (payload === undefined || typeof payload !== 'object') return;
    const p = payload as Record<string, Object>;
    const sessionId = readStr(p, 'sessionId');
    const clientIds: string[] = [];
    const rawList = p['clientIds'];
    if (Array.isArray(rawList)) {
      const ids: Object[] = rawList as Object[];
      for (let i = 0; i < ids.length; i++) {
        if (typeof ids[i] === 'string') clientIds.push(ids[i] as string);
      }
    } else {
      const single = readStr(p, 'clientId');
      if (single.length > 0) clientIds.push(single);
    }
    if (sessionId.length === 0 || clientIds.length === 0) return;
    const list = this.messagesBySession.get(sessionId);
    if (!list) return;
    const filtered = list.filter((m: RemoteMessage) => !clientIds.includes(m.clientId));
    if (filtered.length !== list.length) {
      this.messagesBySession.set(sessionId, filtered);
      this.notify();
    }
  }

  // ─── 发送 / 停止 ────────────────────────────────────────────────────────────

  /**
   * 从被控 Desktop 取回历史消息中的本地媒体引用。
   *
   * xdt-image / cindy-media 是 Desktop 本地协议地址，不能直接交给 Harmony
   * Image。请求缩略图时新版 Desktop 会 inline 返回 webp，旧版或无法缩图时
   * 返回 OSS key；调用方再按响应形态选择 data URI 或 presign-get。
   */
  async fetchRemoteMedia(
    deviceId: string,
    url: string,
    thumbnail: boolean = true,
  ): Promise<RemoteMediaFetchResult> {
    const client = this.client;
    if (!client) {
      return Promise.reject(new Error('client not attached'));
    }
    const request: Record<string, Object> = {};
    request['url'] = url;
    if (thumbnail) {
      request['thumbnail'] = true;
    }
    const opts = new DlInvokeOptions();
    opts.channel = DlChannels.MEDIA_FETCH;
    opts.args = [request];
    try {
      const env = await client.invoke(deviceId, opts);
      const result = unwrapInvokeResult(env);
      if (result === undefined || typeof result !== 'object' || Array.isArray(result)) {
        throw new Error('media:fetch returned an invalid result');
      }
      const raw = result as Record<string, Object>;
      const out = new RemoteMediaFetchResult();
      out.ossKey = readStr(raw, 'ossKey');
      out.mimeType = readStr(raw, 'mimeType');
      const size = raw['size'];
      out.size = typeof size === 'number' ? size : 0;
      out.inlineBase64 = readStr(raw, 'inlineBase64');
      if (out.ossKey.length === 0 && out.inlineBase64.length === 0) {
        throw new Error('media:fetch returned neither ossKey nor inlineBase64');
      }
      return out;
    } catch (e) {
      const message = e instanceof Error ? e.message : JSON.stringify(e);
      const scheme = url.split('://')[0];
      hilog.warn(DOMAIN, TAG, 'media fetch failed scheme=%{public}s err=%{public}s', scheme, message);
      if (e instanceof Error) {
        throw e;
      }
      throw new Error(message);
    }
  }

  /** 发送文本（可带图片引用）。images 为已上传的 RemoteImageRef[]（chatMessage.images）。 */
  async sendText(
    deviceId: string,
    session: RemoteSession,
    text: string,
    images?: RemoteImageRef[],
  ): Promise<void> {
    const client = this.client;
    if (!client) return;

    const clientId = this.nextSendClientId();
    const message = new UserMessageArgs();
    message.content = buildAgentUserContent(text, images ?? []);
    const createOpts = new CreateOptsArgs();
    createOpts.agentKind = mapAgentKind(session.agentKind);
    createOpts.workingDir = session.workingDir;
    createOpts.model = session.model;
    createOpts.providerId = session.providerId.length > 0 ? session.providerId : null;
    createOpts.effort = session.effort;
    createOpts.permissionMode = session.permissionMode;
    createOpts.planMode = session.planModeEnabled;
    createOpts.fastMode = session.fastMode;

    const sendOpts: Record<string, Object> = {};
    sendOpts['messageUuid'] = clientId;
    const persistUserMessage: Record<string, Object> = {};
    persistUserMessage['clientId'] = clientId;
    persistUserMessage['content'] = buildPersistedUserContent(text, images ?? []);
    persistUserMessage['delivery'] = 'turn';
    sendOpts['persistUserMessage'] = persistUserMessage;

    const args: Object[] = [session.id, message, createOpts, sendOpts];
    const opts = new DlInvokeOptions();
    opts.channel = DlChannels.MAKER_SEND;
    opts.args = args;

    const env = await client.invoke(deviceId, opts);
    const result = unwrapInvokeResult(env) as Record<string, Object>;
    if (result['accepted'] !== true) {
      const reason = readStr(result, 'reason');
      throw new Error(reason.length > 0 ? reason : 'send not accepted');
    }
    // accepted 的 onAccepted 已先写入 Desktop DB；主动重拉一次兜住 topic push
    // 丢失或订阅建立竞态，保证当前 Harmony 页面立即看到自己的消息。
    await this.loadInitial(deviceId, session.id);
  }

  /** 停止当前执行。 */
  async abort(deviceId: string, sessionId: string): Promise<void> {
    const client = this.client;
    if (!client) return;
    const args: Object[] = [sessionId];
    const opts = new DlInvokeOptions();
    opts.channel = DlChannels.MAKER_ABORT;
    opts.args = args;
    await client.invoke(deviceId, opts);
  }

  /**
   * Fork：以某条消息为起点创建新任务（对齐 maker:fork，返回新会话 id）。
   * messageClientId 定位消息（对齐 mobile fork(sourceSessionId, messageClientId)）。
   */
  async fork(deviceId: string, sourceSessionId: string, messageClientId: string): Promise<string> {
    const client = this.client;
    if (!client) return '';
    const args: Object[] = [sourceSessionId, messageClientId];
    const opts = new DlInvokeOptions();
    opts.channel = 'maker:fork';
    opts.args = args;
    const env = await client.invoke(deviceId, opts);
    const result = unwrapInvokeResult(env) as Record<string, Object>;
    return readStr(result, 'id');
  }

  /** Rewind 预览（对齐 maker:rewind:preview，返回影响摘要文本）。 */
  async rewindPreview(deviceId: string, sessionId: string, clientId: string): Promise<string> {
    const client = this.client;
    if (!client) return '';
    const args: Object[] = [sessionId, clientId];
    const opts = new DlInvokeOptions();
    opts.channel = 'maker:rewind:preview';
    opts.args = args;
    const env = await client.invoke(deviceId, opts);
    const result = unwrapInvokeResult(env) as Record<string, Object>;
    // 预览响应含影响范围等；一期简化取 summary（桌面端可回空，展示由 commit 结果决定）。
    const summary = readStr(result, 'summary');
    if (summary.length > 0) {
      return summary;
    }
    return result['ok'] === true ? 'ok' : '';
  }

  /** Rewind 提交：回退到该消息（对齐 maker:rewind:commit，返回新会话 id）。 */
  async rewindCommit(deviceId: string, sessionId: string, clientId: string): Promise<string> {
    const client = this.client;
    if (!client) return '';
    const args: Object[] = [sessionId, clientId];
    const opts = new DlInvokeOptions();
    opts.channel = 'maker:rewind:commit';
    opts.args = args;
    const env = await client.invoke(deviceId, opts);
    const result = unwrapInvokeResult(env) as Record<string, Object>;
    return readStr(result, 'id');
  }

  // ─── 内部 ───────────────────────────────────────────────────────────────────

  private mergeWithoutDuplicates(
    older: RemoteMessage[],
    existing: RemoteMessage[],
  ): RemoteMessage[] {
    const byId = new Map<string, RemoteMessage>();
    for (const m of existing) {
      byId.set(messageIdentity(m), m);
    }
    for (const m of older) {
      const key = messageIdentity(m);
      if (!byId.has(key)) byId.set(key, m);
    }
    const out: RemoteMessage[] = [];
    byId.forEach((m: RemoteMessage) => {
      out.push(m);
    });
    return out;
  }
}

/** 取图片引用的可发送地址；兼容历史只保存 base64 的 content.images。 */
function imageRefUrl(image: RemoteImageRef): string {
  if (image.url.length > 0) return image.url;
  if (image.base64.length === 0) return '';
  const mimeType = image.mimeType.length > 0 ? image.mimeType : 'image/png';
  return mimeType.toLowerCase().startsWith('image/')
    ? `data:${mimeType};base64,${image.base64}`
    : '';
}

/** 生成送给 Desktop Agent 的 user content；图片必须是 content 内的 image block。 */
export function buildAgentUserContent(text: string, images: RemoteImageRef[]): string | Object[] {
  if (images.length === 0) return text;
  const blocks: Object[] = [];
  if (text.length > 0) {
    const textBlock: Record<string, Object> = {};
    textBlock['type'] = 'text';
    textBlock['text'] = text;
    blocks.push(textBlock);
  }
  for (let i = 0; i < images.length; i++) {
    const image = images[i];
    const imageUrl = imageRefUrl(image);
    if (imageUrl.length === 0) continue;
    const imageBlock: Record<string, Object> = {};
    imageBlock['type'] = 'image';
    imageBlock['path'] = imageUrl;
    if (image.mimeType.length > 0) imageBlock['mimeType'] = image.mimeType;
    if (image.originalName.length > 0) imageBlock['originalName'] = image.originalName;
    blocks.push(imageBlock);
  }
  return blocks.length === 0 ? text : blocks;
}

/** 生成 Desktop transcript 使用的 JSON content，保留图片历史引用。 */
export function buildPersistedUserContent(text: string, images: RemoteImageRef[]): string {
  const persistedImages: Object[] = [];
  for (let i = 0; i < images.length; i++) {
    const image = images[i];
    const imageUrl = imageRefUrl(image);
    if (imageUrl.length === 0) continue;
    const ref: Record<string, Object> = {};
    ref['url'] = imageUrl;
    if (image.originalName.length > 0) ref['originalName'] = image.originalName;
    if (image.mimeType.length > 0) ref['mimeType'] = image.mimeType;
    if (image.size > 0) ref['size'] = image.size;
    if (image.sha256.length > 0) ref['sha256'] = image.sha256;
    if (image.base64.length > 0) ref['base64'] = image.base64;
    persistedImages.push(ref);
  }
  const persisted: Record<string, Object> = {};
  const persistedFiles: Object[] = [];
  persisted['text'] = text;
  persisted['images'] = persistedImages;
  persisted['files'] = persistedFiles;
  return JSON.stringify(persisted);
}

/** 返回可以交给 Desktop local-db 游标的最早真实消息 id。 */
function oldestMessageCursor(messages: RemoteMessage[]): string {
  for (let i = 0; i < messages.length; i++) {
    const id = messages[i].id;
    if (id.length === 0 || isSyntheticMessageId(id)) {
      continue;
    }
    return id;
  }
  return '';
}

/** 本地流式/系统卡不是 Desktop DB 行，不能作为 before 游标。 */
function isSyntheticMessageId(id: string): boolean {
  return id.startsWith('mobile-system-')
    || id.startsWith('harmony-system-')
    || id.startsWith('streaming-');
}

/** 服务端消息总数只统计真实 DB 行，不把本地系统卡/流式投影算进去。 */
function countRealMessages(messages: RemoteMessage[]): number {
  let count = 0;
  for (let i = 0; i < messages.length; i++) {
    const id = messages[i].id;
    if (id.length > 0 && !isSyntheticMessageId(id)) {
      count += 1;
    }
  }
  return count;
}

/** 合并分页时优先使用真实 id/clientId，避免空 id 的多行互相覆盖。 */
function messageIdentity(message: RemoteMessage): string {
  if (message.id.length > 0) return `id:${message.id}`;
  if (message.clientId.length > 0) return `client:${message.clientId}`;
  return `fallback:${message.role}:${message.createdAt}:${message.rowid}`;
}

/** 兼容没有 boundaryId 的旧 compact_boundary 事件，生成可重放的稳定身份。 */
function compactBoundaryFingerprint(data: Record<string, Object>): string {
  const encoded = JSON.stringify(data);
  const source = encoded === undefined ? 'compact' : encoded;
  let hash = 0;
  for (let i = 0; i < source.length; i++) {
    hash = (hash * 31 + source.charCodeAt(i)) % 2147483647;
  }
  return String(Math.abs(hash));
}

/** 会话 agentKind（cc/codex/pi）→ maker:send 的 agentKind（claude-code/codex/pi）。 */
function mapAgentKind(kind: string): string {
  if (kind === 'cc') return 'claude-code';
  return kind;
}
