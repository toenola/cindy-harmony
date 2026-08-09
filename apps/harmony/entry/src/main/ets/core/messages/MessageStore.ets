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
  RemoteMessage, RemoteSession, parseMessage, parseSession, sortMessagesAsc,
  readStr, readObj, readBool, readNum,
} from '../tasks/TaskModels';
import { RemoteImageRef, RemoteMediaFetchResult } from '../attachments/AttachmentModels';
import { summarizeText } from './MessageRender';
import { unwrapInvokeResult } from '../tasks/TaskStore';
import {
  AgentTaskUpdate,
  applyAgentTaskUpdateEvent,
  isSameAgentTaskAlias,
  normalizeAgentTaskUpdate,
} from './AgentTaskStore';
import {
  findHistoryWindowGap,
  historyPageCoversMs,
  historyPageTailCursor,
  historyPageTailMs,
  historyWindowGapKey,
  HISTORY_BACKFILL_MAX_GAPS_PER_VISIT,
  HISTORY_BACKFILL_MAX_REQUESTS,
  HISTORY_BACKFILL_MAX_ROWS,
  HISTORY_GAP_MAX_CONSIDERED_PER_VISIT,
  HISTORY_GAP_PROBE_MAX_STEPS,
  HistoryWindowGap,
} from './HistoryGap';
import {
  MessageWindowCoverage,
  reconcileLatestMessageWindow,
  extendCoverageEarlier,
  extendCoverageLiveTail,
} from './HistoryWindowCoverage';
import { revealNearestCompleteHistoryTurn } from './HistoryTurnPaging';
import { historyRetryLimits, isPayloadTooLargeError } from './MessagePaging';

const DOMAIN = 0x0000;
const TAG = 'CindyMsg';

// 与 Desktop local-db:messages:list 的默认页大小一致。Harmony 走 Device Link 时，
// 工具结果可能还要经过压缩/裁页；100 条会让特殊会话在一次响应和 UI 重建中卡很久。
const HISTORY_PAGE_LIMIT = 50;
const RECONNECT_MESSAGE_WINDOW_LIMIT = 80;
/** 单次手势内部连续取页的保险预算；到预算后保留 buffer，下次从同一位置续取。 */
const HISTORY_TURN_MAX_REQUESTS = 24;
const HISTORY_TURN_MAX_ROWS = 1200;

function hasTurnContinuation(event: Record<string, Object>): boolean {
  const value = event['turnContinuationId'];
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
}

/** 流式 tool 行（maker:event tool_use 增量，落库后由真实行替代）。 */
export class StreamingToolRow {
  toolUseId: string = '';
  toolName: string = '';
  /** 原始结构化 input；工作步骤的人话摘要依赖 description / commandActions 等字段。 */
  input: Object | undefined = undefined;
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
  /** maker:event 顶层持久消息身份；用于只清理真正对应的 live 投影。 */
  persistId: string = '';
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
  effectiveLimit: number = 0;
  reducedByPayloadTooLarge: boolean = false;
}

/** Rewind 的文件影响预览；文件回退失败不等于对话不能回退。 */
export class RewindPreview {
  canRewind: boolean = true;
  error: string = '';
  filesChanged: string[] = [];
  insertions: number = 0;
  deletions: number = 0;
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
  /** 已取回但尚未按完整 turn 揭示的旧行。 */
  private olderTurnBufferBySession: Map<string, RemoteMessage[]> = new Map();
  /** buffer 之前是否仍可能存在未取回的权威历史。 */
  private olderSourceHasMoreBySession: Map<string, boolean> = new Map();
  /** 会话列表透出的服务端消息总数，用于短页（payload 裁剪）时判断还有历史。 */
  private messageCountBySession: Map<string, number> = new Map();
  /** 流式 assistant 消息（maker:event 累积）。 */
  private streamingBySession: Map<string, StreamingMessage> = new Map();
  /** maker 权威运行态；与临时正文投影分开，避免终态事件丢失时 Composer 卡住。 */
  private runningBySession: Map<string, boolean> = new Map();
  /** 远程运行态查询的代次，防止旧快照覆盖在途 maker 事件。 */
  private runningStateRevisions: Map<string, number> = new Map();
  /** maker status 的真实 turn 边界；孤儿 Agent 卡只能在本边界内显示。 */
  private makerTurnRunningBySession: Map<string, boolean> = new Map();
  private taskUpdatesBySession: Map<string, Map<string, AgentTaskUpdate>> = new Map();
  private parkedTaskUpdatesBySession: Map<string, Map<string, AgentTaskUpdate>> = new Map();
  /** 历史加载失败标记（TaskPage 显示重试入口）。 */
  private loadFailedBySession: Map<string, boolean> = new Map();
  /** 发送消息的客户端 id；同时作为 Desktop transcript 的幂等键。 */
  private sendSequence: number = 0;
  /** 打开会话前先确保控制链路（AppServices 注入，内部做 link-open + 幂等）。 */
  private linkOpener: ((deviceId: string) => Promise<void>) | undefined = undefined;
  /** 历史补洞代次：切会话/重新 heal 后旧请求不得继续 merge。 */
  private historyHealGenerations: Map<string, number> = new Map();
  /** 本次访问已经探测过的合法停顿/缺口，避免反复请求同一处。 */
  private consideredHistoryGaps: Map<string, Set<string>> = new Map();
  /** 已验证连续窗口；只有 subscribe ACK 后到达的实时尾部可推进 until。 */
  private historyCoverageBySession: Map<string, MessageWindowCoverage> = new Map();
  private subscriptionAckedSessions: Set<string> = new Set();

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

  hasMessageClientId(sessionId: string, clientId: string): boolean {
    if (clientId.length === 0) return false;
    const messages = this.messagesBySession.get(sessionId) ?? [];
    return messages.some((message: RemoteMessage) =>
      message.clientId === clientId || message.id === clientId);
  }

  appendLocalSystemCard(
    sessionId: string,
    type: string,
    data: Record<string, Object>,
  ): void {
    const message = new RemoteMessage();
    const key = `harmony-local-${type}-${Date.now()}-${++this.sendSequence}`;
    message.id = key;
    message.clientId = key;
    message.sessionId = sessionId;
    message.role = 'system';
    message.systemCardType = type;
    message.systemCardData = data;
    message.createdAt = new Date().toISOString();
    message.localOnly = true;
    const current = this.messagesBySession.get(sessionId) ?? [];
    const next = current.concat([message]);
    next.sort(sortMessagesAsc);
    this.messagesBySession.set(sessionId, next);
    this.notify();
  }

  /** 消息链接定位使用独立 around 窗口，不污染连续历史分页 coverage。 */
  async loadAroundClientId(
    deviceId: string,
    sessionId: string,
    clientId: string,
    radius: number = 60,
  ): Promise<boolean> {
    const client = this.client;
    if (!client || clientId.length === 0) return false;
    if (this.linkOpener !== undefined) await this.linkOpener(deviceId);
    const options: Record<string, Object> = {};
    options['radius'] = Math.max(1, Math.min(100, Math.floor(radius)));
    const invoke = new DlInvokeOptions();
    invoke.channel = 'local-db:messages:around-client-id';
    invoke.args = [sessionId, clientId, options];
    const env = await client.invoke(deviceId, invoke);
    const result = unwrapInvokeResult(env);
    const rows: RemoteMessage[] = [];
    if (Array.isArray(result)) {
      const source = result as Object[];
      for (let i = 0; i < source.length; i++) {
        const raw = source[i];
        if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) continue;
        rows.push(parseMessage(raw as Record<string, Object>));
      }
    }
    if (rows.length > 0) {
      const current = this.messagesBySession.get(sessionId) ?? [];
      const merged = this.mergeWithoutDuplicates(rows, current);
      merged.sort(sortMessagesAsc);
      this.messagesBySession.set(sessionId, merged);
      this.notify();
    }
    return this.hasMessageClientId(sessionId, clientId);
  }

  /**
   * 首条消息 ACK 丢失时的权威兜底：applied / missing / unknown。
   * 最新窗口打满或被 relay 裁剪时，未命中不能证明消息从未落库。
   */
  async probeMessageClientId(
    deviceId: string,
    sessionId: string,
    clientId: string,
    limit: number = 200,
  ): Promise<string> {
    const local = this.messagesBySession.get(sessionId) ?? [];
    if (local.some((message: RemoteMessage) =>
      message.clientId === clientId || message.id === clientId)) return 'applied';
    try {
      const page = await this.requestMessagesList(deviceId, sessionId, limit, '');
      if (page.items.some((message: RemoteMessage) =>
        message.clientId === clientId || message.id === clientId)) return 'applied';
      if (page.hasMore || page.items.length >= limit) return 'unknown';
      return 'missing';
    } catch (e) {
      return 'unknown';
    }
  }

  getTaskUpdates(sessionId: string): Map<string, AgentTaskUpdate> {
    return this.taskUpdatesBySession.get(sessionId) ?? new Map<string, AgentTaskUpdate>();
  }

  isMakerTurnRunning(sessionId: string): boolean {
    return this.makerTurnRunningBySession.get(sessionId) === true;
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
    const buffered = this.olderTurnBufferBySession.get(sessionId) ?? [];
    const fetched = this.mergeWithoutDuplicates(buffered, current);
    const sourceHasMore = count > countRealMessages(fetched);
    this.olderSourceHasMoreBySession.set(sessionId, sourceHasMore);
    this.hasMoreBySession.set(sessionId, buffered.length > 0 || sourceHasMore);
  }

  /** 该会话历史是否加载失败（页面据此显示重试）。 */
  loadFailed(sessionId: string): boolean {
    return this.loadFailedBySession.get(sessionId) ?? false;
  }

  // ─── 打开 / 关闭 ────────────────────────────────────────────────────────────

  /** 打开会话：确保控制链路 → 拉历史（优先）→ 订阅实时流（并行，失败不阻塞）。 */
  isSessionOpen(sessionId: string): boolean {
    return this.subscribed.has(sessionId);
  }

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
      if (loaded) this.scheduleHistoryHeal(deviceId, sessionId, true);
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
    this.subscriptionAckedSessions.delete(sessionId);
    const existingCoverage = this.historyCoverageBySession.get(sessionId);
    if (existingCoverage !== undefined) existingCoverage.liveTailTrusted = false;
    // 订阅实时流（并行，失败不阻塞历史）。
    client.subscribe(deviceId, [sessionTopic(sessionId)]).then(() => {
      if (this.subscribed.get(sessionId) === deviceId) this.subscriptionAckedSessions.add(sessionId);
    }).catch(() => {
    });
    const loaded = await this.loadInitial(deviceId, sessionId);
    if (loaded) this.scheduleHistoryHeal(deviceId, sessionId, true);
    void this.refreshSessionRunningState(deviceId, sessionId);
    return loaded;
  }

  /** 关闭会话：注销订阅并清内存（页面退出时调用）。 */
  async closeSession(sessionId: string): Promise<void> {
    const deviceId = this.subscribed.get(sessionId);
    this.subscribed.delete(sessionId);
    this.messagesBySession.delete(sessionId);
    this.hasMoreBySession.delete(sessionId);
    this.olderTurnBufferBySession.delete(sessionId);
    this.olderSourceHasMoreBySession.delete(sessionId);
    this.messageCountBySession.delete(sessionId);
    this.loadFailedBySession.delete(sessionId);
    this.streamingBySession.delete(sessionId);
    this.runningBySession.delete(sessionId);
    this.makerTurnRunningBySession.delete(sessionId);
    this.taskUpdatesBySession.delete(sessionId);
    this.parkedTaskUpdatesBySession.delete(sessionId);
    this.runningStateRevisions.delete(sessionId);
    this.historyHealGenerations.set(sessionId,
      (this.historyHealGenerations.get(sessionId) ?? 0) + 1);
    this.consideredHistoryGaps.delete(sessionId);
    this.historyCoverageBySession.delete(sessionId);
    this.subscriptionAckedSessions.delete(sessionId);
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
    this.subscriptionAckedSessions.delete(sessionId);
    const previousCoverage = this.historyCoverageBySession.get(sessionId);
    if (previousCoverage !== undefined) previousCoverage.liveTailTrusted = false;
    try {
      await client.subscribe(deviceId, [sessionTopic(sessionId)]);
      if (this.subscribed.get(sessionId) === deviceId) this.subscriptionAckedSessions.add(sessionId);
    } catch (e) {
      // 订阅失败不阻断 healing
    }
    try {
      const page = await this.requestMessagesList(
        deviceId, sessionId, RECONNECT_MESSAGE_WINDOW_LIMIT, '');
      page.items.sort(sortMessagesAsc);
      const merged = this.applyLatestWindow(sessionId, page);
      this.setOlderAvailability(
        sessionId, this.hasMoreAfterPage(sessionId, page, merged));
      this.notify();
      this.scheduleHistoryHeal(deviceId, sessionId, true);
      void this.refreshSessionRunningState(deviceId, sessionId);
    } catch (e) {
      // healing 失败：保持现有消息，等下一次重连恢复。
    }
  }

  /**
   * 重连/重进后补齐窗口内部缺口。探测与翻页都只复用 messages:list(before)，
   * 与 Mobile 同源且不新增 Harmony 专用协议。
   */
  private scheduleHistoryHeal(deviceId: string, sessionId: string, resetVisit: boolean): void {
    const generation = (this.historyHealGenerations.get(sessionId) ?? 0) + 1;
    this.historyHealGenerations.set(sessionId, generation);
    if (resetVisit || !this.consideredHistoryGaps.has(sessionId)) {
      this.consideredHistoryGaps.set(sessionId, new Set<string>());
    }
    void this.healHistoryWindow(deviceId, sessionId, generation);
  }

  private historyHealCancelled(sessionId: string, generation: number): boolean {
    return this.historyHealGenerations.get(sessionId) !== generation
      || !this.subscribed.has(sessionId);
  }

  private mergeHistoryRows(sessionId: string, rows: RemoteMessage[]): void {
    if (rows.length === 0) return;
    const current = this.messagesBySession.get(sessionId) ?? [];
    const merged = this.mergeWithoutDuplicates(rows, current);
    merged.sort(sortMessagesAsc);
    this.messagesBySession.set(sessionId, merged);
  }

  private async healHistoryWindow(
    deviceId: string,
    sessionId: string,
    generation: number,
  ): Promise<void> {
    const considered = this.consideredHistoryGaps.get(sessionId) ?? new Set<string>();
    this.consideredHistoryGaps.set(sessionId, considered);
    let examined = 0;
    let pagedGaps = 0;
    while (examined < HISTORY_GAP_MAX_CONSIDERED_PER_VISIT
      && pagedGaps < HISTORY_BACKFILL_MAX_GAPS_PER_VISIT
      && !this.historyHealCancelled(sessionId, generation)) {
      const gap = findHistoryWindowGap(
        this.messagesBySession.get(sessionId) ?? [], considered);
      if (gap === null) return;
      considered.add(historyWindowGapKey(gap));
      examined += 1;
      const outcome = await this.backfillHistoryGap(deviceId, sessionId, generation, gap);
      if (outcome === 'cancelled') return;
      if (outcome !== 'contiguous' && outcome !== 'failed') pagedGaps += 1;
      if (outcome === 'failed') return;
      this.notify();
    }
  }

  private async backfillHistoryGap(
    deviceId: string,
    sessionId: string,
    generation: number,
    gap: HistoryWindowGap,
  ): Promise<string> {
    let before = gap.newerId;
    let rows = 0;
    let requests = 0;
    try {
      // 先用一行探测合法停顿；同毫秒组最多向前推进 8 次。
      for (let step = 0; step < HISTORY_GAP_PROBE_MAX_STEPS; step++) {
        if (this.historyHealCancelled(sessionId, generation)) return 'cancelled';
        const probe = await this.requestMessagesList(deviceId, sessionId, 1, before);
        if (this.historyHealCancelled(sessionId, generation)) return 'cancelled';
        requests += 1;
        if (probe.items.length === 0) return 'exhausted';
        const next = historyPageTailCursor(probe.items);
        const ms = historyPageTailMs(probe.items);
        if (next.length === 0 || ms < 0) {
          this.mergeHistoryRows(sessionId, probe.items);
          rows += probe.items.length;
          break;
        }
        if (ms <= gap.olderMs) return 'contiguous';
        this.mergeHistoryRows(sessionId, probe.items);
        rows += probe.items.length;
        before = next;
        if (ms !== gap.newerMs) break;
      }

      while (rows < HISTORY_BACKFILL_MAX_ROWS && requests < HISTORY_BACKFILL_MAX_REQUESTS) {
        if (this.historyHealCancelled(sessionId, generation)) return 'cancelled';
        const page = await this.requestMessagesList(deviceId, sessionId, HISTORY_PAGE_LIMIT, before);
        if (this.historyHealCancelled(sessionId, generation)) return 'cancelled';
        requests += 1;
        if (page.items.length === 0) return 'exhausted';
        this.mergeHistoryRows(sessionId, page.items);
        rows += page.items.length;
        if (historyPageCoversMs(page.items, gap.olderMs)) {
          hilog.info(DOMAIN, TAG,
            'history gap healed session=%{public}s rows=%{public}d requests=%{public}d',
            sessionId.slice(0, 8), rows, requests);
          return 'covered';
        }
        const next = historyPageTailCursor(page.items);
        if (next.length === 0 || next === before) return 'exhausted';
        before = next;
      }
      return 'budget';
    } catch (e) {
      const message = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.warn(DOMAIN, TAG, 'history gap heal failed session=%{public}s err=%{public}s',
        sessionId.slice(0, 8), message);
      return 'failed';
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

  /** socket 断线会同时撤销实时尾部背书与订阅 ACK。 */
  invalidateLiveTailTrust(): void {
    this.subscriptionAckedSessions.clear();
    this.historyCoverageBySession.forEach((coverage: MessageWindowCoverage) => {
      coverage.liveTailTrusted = false;
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
  handleMakerEvent(sessionId: string, event: Object | undefined, persistId: string = ''): void {
    if (event === undefined || typeof event !== 'object') {
      return;
    }
    const ev = event as Record<string, Object>;
    const type = readStr(ev, 'type');
    const data = readObj(ev, 'data');
    this.bumpRunningStateRevision(sessionId);

    if (type === 'agent_task_update') {
      const rawSource = readStr(ev, 'source');
      const source = rawSource === 'codex' || rawSource === 'pi' || rawSource === 'claude-code'
        ? rawSource : '';
      const previous = this.recallParkedTaskUpdates(
        sessionId, data, source, this.taskUpdatesBySession.get(sessionId));
      const next = applyAgentTaskUpdateEvent(previous, data, source, new Date().toISOString());
      if (next !== null) {
        this.taskUpdatesBySession.set(sessionId, next);
        this.notify();
      }
      return;
    }

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
      const s = this.ensureStreaming(sessionId, persistId);
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
      const s = this.ensureStreaming(sessionId, persistId);
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
        row.input = rawInput;
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
        if (this.makerTurnRunningBySession.get(sessionId) !== true) {
          this.sweepTaskUpdatesAtTurnStart(sessionId);
        }
        this.makerTurnRunningBySession.set(sessionId, true);
        this.markSessionRunning(sessionId, true);
      } else if (isRunning === false) {
        if (hasTurnContinuation(ev)) {
          // provider segment ends, but the product turn continues.
          this.markSessionRunning(sessionId, true);
        } else {
          this.makerTurnRunningBySession.delete(sessionId);
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
        this.makerTurnRunningBySession.delete(sessionId);
        this.finalizeSessionStreaming(sessionId);
      }
      this.notify();
      return;
    }
    if (type === 'error') {
      const terminal = readBool(data, 'isTerminal', !readBool(data, 'willRetry', false));
      if (terminal) {
        this.makerTurnRunningBySession.delete(sessionId);
        this.finalizeSessionStreaming(sessionId);
      } else {
        this.markSessionRunning(sessionId, true);
      }
      this.notify();
    }
  }

  private sweepTaskUpdatesAtTurnStart(sessionId: string): void {
    this.parkedTaskUpdatesBySession.delete(sessionId);
    const current = this.taskUpdatesBySession.get(sessionId);
    if (current === undefined || current.size === 0) return;
    const parked = new Map<string, AgentTaskUpdate>();
    current.forEach((update: AgentTaskUpdate, key: string) => {
      if (update.provider === 'codex' && update.status === 'running') parked.set(key, update);
    });
    if (parked.size > 0) this.parkedTaskUpdatesBySession.set(sessionId, parked);
    this.taskUpdatesBySession.delete(sessionId);
  }

  private recallParkedTaskUpdates(
    sessionId: string,
    data: Object | undefined,
    source: string,
    previous: Map<string, AgentTaskUpdate> | undefined,
  ): Map<string, AgentTaskUpdate> | undefined {
    const parked = this.parkedTaskUpdatesBySession.get(sessionId);
    if (parked === undefined || parked.size === 0) return previous;
    const probe = normalizeAgentTaskUpdate(data, source);
    if (probe === null) return previous;
    let recalled: Map<string, AgentTaskUpdate> | undefined = undefined;
    parked.forEach((update: AgentTaskUpdate, key: string) => {
      if (!isSameAgentTaskAlias(update, probe)) return;
      if (recalled === undefined) recalled = new Map<string, AgentTaskUpdate>(previous ?? new Map());
      recalled.set(key, update);
      parked.delete(key);
    });
    if (parked.size === 0) this.parkedTaskUpdatesBySession.delete(sessionId);
    return recalled ?? previous;
  }


  /** 取或建流式消息。 */
  private ensureStreaming(sessionId: string, persistId: string = ''): StreamingMessage {
    let s = this.streamingBySession.get(sessionId);
    if (s !== undefined && persistId.length > 0 && s.persistId.length === 0) {
      // 老生产者先发无身份事件、后续帧才补 persistId：迁移身份，不重建正文。
      s.persistId = persistId;
    }
    if (s !== undefined && (s.finished
      || (persistId.length > 0 && s.persistId.length > 0 && s.persistId !== persistId))) {
      // 新的持久块开始前，把旧投影固化进本地窗口。随后旧块 DB push 回流时按
      // persistId 原位替换，不能清掉仍在增长的新块。
      this.materializeStreamingProjection(sessionId, s);
      s = undefined;
    }
    if (s === undefined) {
      s = new StreamingMessage();
      s.sessionId = sessionId;
      s.persistId = persistId;
      s.createdAt = new Date().toISOString();
      this.streamingBySession.set(sessionId, s);
    }
    return s;
  }

  private materializeStreamingProjection(sessionId: string, streaming: StreamingMessage): void {
    const list = this.messagesBySession.get(sessionId) ?? [];
    for (let i = 0; i < streaming.tools.length; i++) {
      const tool = streaming.tools[i];
      if (!list.some((message: RemoteMessage) => message.role === 'tool_use'
        && message.toolUseId === tool.toolUseId)) {
        const use = new RemoteMessage();
        use.id = `streaming-tool-${tool.toolUseId}`;
        use.clientId = use.id;
        use.sessionId = sessionId;
        use.role = 'tool_use';
        use.toolUseId = tool.toolUseId;
        use.createdAt = streaming.createdAt;
        const content: Record<string, Object> = {};
        content['toolUseId'] = tool.toolUseId;
        content['toolName'] = tool.toolName;
        const emptyInput: Record<string, Object> = {};
        content['input'] = tool.input ?? emptyInput;
        use.content = content;
        list.push(use);
      }
      if (tool.settled && !list.some((message: RemoteMessage) => message.role === 'tool_result'
        && message.toolUseId === tool.toolUseId)) {
        const result = new RemoteMessage();
        result.id = `streaming-result-${tool.toolUseId}`;
        result.clientId = result.id;
        result.sessionId = sessionId;
        result.role = 'tool_result';
        result.toolUseId = tool.toolUseId;
        result.createdAt = streaming.createdAt;
        const resultContent: Record<string, Object> = {};
        resultContent['toolUseId'] = tool.toolUseId;
        resultContent['isError'] = tool.hasError;
        resultContent['text'] = '';
        result.content = resultContent;
        list.push(result);
      }
    }
    if (streaming.text.length > 0) {
      const identity = streaming.persistId.length > 0
        ? streaming.persistId : `streaming-text-${sessionId}:${streaming.createdAt}`;
      const index = list.findIndex((message: RemoteMessage) =>
        message.id === identity || message.clientId === identity);
      const assistant = new RemoteMessage();
      assistant.id = identity;
      assistant.clientId = identity;
      assistant.sessionId = sessionId;
      assistant.role = 'assistant';
      assistant.createdAt = streaming.createdAt;
      assistant.content = streaming.text;
      assistant.isStreaming = false;
      if (index >= 0) list[index] = assistant;
      else list.push(assistant);
    }
    list.sort(sortMessagesAsc);
    this.messagesBySession.set(sessionId, list);
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
    this.makerTurnRunningBySession.delete(sessionId);
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
      this.makerTurnRunningBySession.delete(sessionId);
      this.finalizeSessionStreaming(sessionId);
    } else if (rawRunning === true) {
      this.markSessionRunning(sessionId, true);
    } else if (rawRunning === false) {
      this.makerTurnRunningBySession.delete(sessionId);
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
        this.makerTurnRunningBySession.delete(sessionId);
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
    const persistedToolUseIds = new Set<string>();
    const persistedToolResultIds = new Set<string>();
    for (let i = 0; i < base.length; i++) {
      let nestedUseId = '';
      const rawContent = base[i].content;
      if (rawContent !== undefined && rawContent !== null
        && typeof rawContent === 'object' && !Array.isArray(rawContent)) {
        nestedUseId = readStr(rawContent as Record<string, Object>, 'toolUseId');
      }
      if (base[i].role === 'tool_use') {
        const useId = base[i].toolUseId.length > 0
          ? base[i].toolUseId : nestedUseId;
        if (useId.length > 0) persistedToolUseIds.add(useId);
      } else if (base[i].role === 'tool_result') {
        const useId = base[i].toolUseId.length > 0
          ? base[i].toolUseId : nestedUseId;
        if (useId.length > 0) persistedToolResultIds.add(useId);
      }
    }
    for (let i = 0; i < s.tools.length; i++) {
      const t = s.tools[i];
      if (!persistedToolUseIds.has(t.toolUseId)) {
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
        content['input'] = t.input ?? inputObj;
        tm.content = content;
        tmp.push(tm);
      }
      if (t.settled && !persistedToolResultIds.has(t.toolUseId)) {
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
      tm.id = s.persistId.length > 0 ? s.persistId : `streaming-text-${sessionId}`;
      tm.clientId = tm.id;
      tm.sessionId = sessionId;
      tm.role = 'assistant';
      tm.createdAt = s.createdAt;
      tm.content = s.text;
      tm.isStreaming = isStreaming;
      tmp.push(tm);
    }
    return base.concat(tmp);
  }

  /** assistant 正文落库时只清同 persistId 投影；旧块 push 不能清掉新块。 */
  private clearStreamingIfAssistant(sessionId: string, message: RemoteMessage): void {
    if (message.role !== 'assistant') {
      return;
    }
    const streaming = this.streamingBySession.get(sessionId);
    if (streaming === undefined) return;
    if (streaming.persistId.length > 0
      && message.id !== streaming.persistId
      && message.clientId !== streaming.persistId) return;
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
      const merged = this.applyLatestWindow(sessionId, page);
      this.setOlderAvailability(
        sessionId, this.hasMoreAfterPage(sessionId, page, merged));
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

  /** 破坏性消息操作完成后重拉当前整窗，避免旧分页与服务端截断结果混合。 */
  async reloadSession(deviceId: string, sessionId: string): Promise<boolean> {
    this.historyHealGenerations.set(sessionId,
      (this.historyHealGenerations.get(sessionId) ?? 0) + 1);
    this.consideredHistoryGaps.delete(sessionId);
    this.historyCoverageBySession.delete(sessionId);
    this.clearOlderTurnState(sessionId);
    this.messagesBySession.delete(sessionId);
    return this.loadInitial(deviceId, sessionId);
  }

  /** Pi 分支切换后的权威替换；旧分支消息不能与新窗口 merge。 */
  async replaceSessionWindow(deviceId: string, sessionId: string): Promise<boolean> {
    const generation = (this.historyHealGenerations.get(sessionId) ?? 0) + 1;
    this.historyHealGenerations.set(sessionId, generation);
    this.consideredHistoryGaps.delete(sessionId);
    this.historyCoverageBySession.delete(sessionId);
    this.clearOlderTurnState(sessionId);
    try {
      const page = await this.requestMessagesList(deviceId, sessionId, HISTORY_PAGE_LIMIT, '');
      if ((this.historyHealGenerations.get(sessionId) ?? 0) !== generation
        || this.subscribed.get(sessionId) !== deviceId) return false;
      page.items.sort(sortMessagesAsc);
      const reconciled = reconcileLatestMessageWindow(
        [], page.items, page.hasMore, null, this.subscriptionAckedSessions.has(sessionId));
      this.messagesBySession.set(sessionId, reconciled.items);
      if (reconciled.coverage !== null) this.historyCoverageBySession.set(sessionId, reconciled.coverage);
      this.setOlderAvailability(
        sessionId, this.hasMoreAfterPage(sessionId, page, page.items));
      this.streamingBySession.delete(sessionId);
      this.runningBySession.delete(sessionId);
      this.makerTurnRunningBySession.delete(sessionId);
      this.loadFailedBySession.delete(sessionId);
      this.notify();
      return true;
    } catch (e) {
      return false;
    }
  }

  /**
   * 向上翻页：一次用户触发只揭示上一轮完整的「user + 回复/工作过程」。
   * relay 把大页裁成一行时会在内部继续向前请求，命中顶层 user 前不改可见列表，
   * 从而避免一条 tool/thinking 被临时并进现有 work_group。
   */
  async loadOlder(deviceId: string, sessionId: string): Promise<void> {
    const client = this.client;
    if (!client) return;
    if (!this.hasMore(sessionId)) return;
    const generation = this.historyHealGenerations.get(sessionId) ?? 0;
    let current = this.messagesBySession.get(sessionId) ?? [];
    let buffered = (this.olderTurnBufferBySession.get(sessionId) ?? []).slice();
    let sourceHasMore = this.olderSourceHasMoreBySession.get(sessionId)
      ?? this.hasMore(sessionId);
    let reveal = revealNearestCompleteHistoryTurn(buffered, sourceHasMore);
    let requests = 0;
    let fetchedRows = 0;
    let lastCursor = '';
    let requestLimit = HISTORY_PAGE_LIMIT;
    try {
      while (reveal.needsOlderPage
        && requests < HISTORY_TURN_MAX_REQUESTS
        && fetchedRows < HISTORY_TURN_MAX_ROWS) {
        const cursorRows = buffered.length > 0 ? buffered : current;
        const before = oldestMessageCursor(cursorRows);
        if (before.length === 0 || before === lastCursor) {
          // 无可用游标或游标没有前移，不等同于权威历史耗尽。保留半轮和入口，
          // 禁止把尚未命中 user 边界的行作为孤儿内容提前揭示。
          break;
        }
        lastCursor = before;
        const page = await this.requestMessagesList(
          deviceId, sessionId, requestLimit, before);
        if ((this.historyHealGenerations.get(sessionId) ?? 0) !== generation
          || this.subscribed.get(sessionId) !== deviceId) return;
        requests += 1;
        fetchedRows += page.items.length;
        page.items.sort(sortMessagesAsc);

        // before 理论上排除当前游标；仍按 identity 过滤，兼容旧 host 的包含式分页。
        const previousSize = buffered.length;
        const allFetched = this.mergeWithoutDuplicates(page.items, buffered.concat(current));
        const currentIds = new Set<string>();
        for (let i = 0; i < current.length; i++) currentIds.add(messageIdentity(current[i]));
        buffered = [];
        for (let i = 0; i < allFetched.length; i++) {
          if (!currentIds.has(messageIdentity(allFetched[i]))) buffered.push(allFetched[i]);
        }
        buffered.sort(sortMessagesAsc);
        const progressed = buffered.length > previousSize;
        const fetchedWindow = this.mergeWithoutDuplicates(buffered, current);
        sourceHasMore = this.hasMoreAfterPage(sessionId, page, fetchedWindow);
        reveal = revealNearestCompleteHistoryTurn(buffered, sourceHasMore);
        if (page.items.length === 0) break;
        if (!progressed) {
          // 旧 host 的包含式 before 加上 relay 裁页，可能只返当前游标本身。
          // 缩小页大小可降低响应裁剪概率；仍不前进时保留 hasMore 给下次重试。
          if (sourceHasMore && requestLimit > 1) {
            requestLimit = Math.max(1, Math.floor(requestLimit / 2));
            lastCursor = '';
            continue;
          }
          break;
        }
        requestLimit = HISTORY_PAGE_LIMIT;
      }

      // 请求预算只负责防止异常 host 死循环；未命中 user 时继续保留 buffer，
      // 不把半轮内容塞进现有工作组。下一次触发会从 buffer 最早游标续取。
      this.olderTurnBufferBySession.set(sessionId, reveal.buffered);
      this.olderSourceHasMoreBySession.set(sessionId, sourceHasMore);
      if (reveal.reveal.length === 0) {
        this.hasMoreBySession.set(sessionId, reveal.buffered.length > 0 || sourceHasMore);
        hilog.info(DOMAIN, TAG,
          'history turn buffered session=%{public}s rows=%{public}d requests=%{public}d',
          sessionId.slice(0, 8), reveal.buffered.length, requests);
        this.notify();
        return;
      }

      // 收集期间可能有实时尾部 push；最终 merge 使用最新窗口，且只 notify 一次。
      if ((this.historyHealGenerations.get(sessionId) ?? 0) !== generation
        || this.subscribed.get(sessionId) !== deviceId) return;
      current = this.messagesBySession.get(sessionId) ?? current;
      const merged = this.mergeWithoutDuplicates(reveal.reveal, current);
      merged.sort(sortMessagesAsc);
      this.messagesBySession.set(sessionId, merged);
      const coverage = extendCoverageEarlier(
        this.historyCoverageBySession.get(sessionId) ?? null,
        reveal.reveal,
        current.length > 0 ? current[0] : null);
      if (coverage !== null) this.historyCoverageBySession.set(sessionId, coverage);
      this.hasMoreBySession.set(sessionId,
        reveal.buffered.length > 0 || sourceHasMore);
      hilog.info(DOMAIN, TAG,
        'history turn revealed requests=%{public}d fetched=%{public}d added=%{public}d hasMore=%{public}s',
        requests, fetchedRows, Math.max(0, merged.length - current.length),
        this.hasMore(sessionId) ? 'true' : 'false');
      this.notify();
    } catch (e) {
      // 一轮内部可能已经跨过多个 relay 裁页；后续页断线时保留已取回的半轮，
      // 下次手势从 buffer 最早游标续取，既不逐条闪入 UI，也不重复请求这些行。
      if ((this.historyHealGenerations.get(sessionId) ?? 0) === generation
        && this.subscribed.get(sessionId) === deviceId) {
        this.olderTurnBufferBySession.set(sessionId, buffered);
        this.olderSourceHasMoreBySession.set(sessionId, sourceHasMore);
        this.hasMoreBySession.set(sessionId, buffered.length > 0 || sourceHasMore);
      }
      const msg = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.warn(DOMAIN, TAG, 'history older failed session=%{public}s err=%{public}s',
        sessionId.slice(0, 8), msg);
    }
  }

  private clearOlderTurnState(sessionId: string): void {
    this.olderTurnBufferBySession.delete(sessionId);
    this.olderSourceHasMoreBySession.delete(sessionId);
  }

  private setOlderAvailability(sessionId: string, sourceHasMore: boolean): void {
    this.olderSourceHasMoreBySession.set(sessionId, sourceHasMore);
    const buffered = this.olderTurnBufferBySession.get(sessionId) ?? [];
    this.hasMoreBySession.set(sessionId, buffered.length > 0 || sourceHasMore);
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
  private async requestMessagesList(
    deviceId: string,
    sessionId: string,
    limit: number,
    beforeId: string,
  ): Promise<HistoryPage> {
    const limits = historyRetryLimits(limit);
    let lastError: Error = new Error('messages:list failed');
    for (let i = 0; i < limits.length; i++) {
      try {
        const page = await this.requestMessagesListOnce(deviceId, sessionId, limits[i], beforeId);
        page.effectiveLimit = limits[i];
        page.reducedByPayloadTooLarge = limits[i] !== limit;
        if (page.reducedByPayloadTooLarge) page.hasMore = true;
        return page;
      } catch (e) {
        lastError = e instanceof Error ? e : new Error(JSON.stringify(e));
        if (!isPayloadTooLargeError(lastError) || i === limits.length - 1) throw lastError;
      }
    }
    throw lastError;
  }

  private requestMessagesListOnce(
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
      out.effectiveLimit = limit;
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
          this.historyCoverageBySession.delete(sessionId);
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
    // 新的权威工具行到达后清掉之前为跨 persistId 保活而固化的临时工具行。
    if ((message.role === 'tool_use' || message.role === 'tool_result')
      && message.toolUseId.length > 0) {
      const syntheticPrefix = message.role === 'tool_use' ? 'streaming-tool-' : 'streaming-result-';
      list = list.filter((existing: RemoteMessage) => !(existing.toolUseId === message.toolUseId
        && existing.role === message.role && existing.id.startsWith(syntheticPrefix)));
      this.messagesBySession.set(sessionId, list);
    }
    const existingIndex = list.findIndex((m: RemoteMessage) =>
      m.id === message.id || (message.clientId.length > 0 && m.clientId === message.clientId));
    if (existingIndex >= 0) {
      if (preferIncomingCreatedMessage(list[existingIndex], message)) {
        list[existingIndex] = message;
        list.sort(sortMessagesAsc);
        this.messagesBySession.set(sessionId, list);
        this.notify();
      }
      this.clearStreamingIfAssistant(sessionId, message);
      return;
    }
    list.push(message);
    list.sort(sortMessagesAsc);
    if (this.subscriptionAckedSessions.has(sessionId)) {
      extendCoverageLiveTail(this.historyCoverageBySession.get(sessionId) ?? null, message);
    }
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
    this.historyCoverageBySession.delete(sessionId);
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
    skipCache: boolean = false,
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
    if (skipCache) {
      request['skipCache'] = true;
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

  async dismissErrorMessage(deviceId: string, sessionId: string, clientId: string): Promise<void> {
    const client = this.client;
    if (!client) return;
    const messages = this.messagesBySession.get(sessionId) ?? [];
    for (let i = 0; i < messages.length; i++) {
      if (messages[i].clientId !== clientId && messages[i].id !== clientId) continue;
      let content: Record<string, Object> = {};
      if (messages[i].content !== undefined && messages[i].content !== null
        && typeof messages[i].content === 'object' && !Array.isArray(messages[i].content)) {
        content = messages[i].content as Record<string, Object>;
      } else {
        content['message'] = typeof messages[i].content === 'string' ? messages[i].content as string : '';
      }
      content['dismissed'] = true;
      messages[i].content = content;
      break;
    }
    this.messagesBySession.set(sessionId, messages);
    this.notify();
    if (this.linkOpener !== undefined) await this.linkOpener(deviceId);
    const opts = new DlInvokeOptions();
    opts.channel = 'local-db:messages:dismiss-error';
    opts.args = [sessionId, clientId];
    await client.invoke(deviceId, opts);
  }

  async ackInterruptedTurn(deviceId: string, sessionId: string): Promise<void> {
    const client = this.client;
    if (!client) return;
    if (this.linkOpener !== undefined) await this.linkOpener(deviceId);
    const opts = new DlInvokeOptions();
    opts.channel = 'local-db:sessions:ack-interrupted';
    opts.args = [sessionId];
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

  /** Rewind 预览（对齐 maker:rewind:preview）。 */
  async rewindPreview(deviceId: string, sessionId: string, clientId: string): Promise<RewindPreview> {
    const client = this.client;
    if (!client) return new RewindPreview();
    const args: Object[] = [sessionId, clientId];
    const opts = new DlInvokeOptions();
    opts.channel = 'maker:rewind:preview';
    opts.args = args;
    const env = await client.invoke(deviceId, opts);
    const result = unwrapInvokeResult(env) as Record<string, Object>;
    const preview = new RewindPreview();
    preview.canRewind = readBool(result, 'canRewind', true);
    preview.error = readStr(result, 'error');
    preview.insertions = readNum(result, 'insertions', 0);
    preview.deletions = readNum(result, 'deletions', 0);
    const rawFiles = result['filesChanged'];
    if (Array.isArray(rawFiles)) {
      const files = rawFiles as Object[];
      for (let i = 0; i < files.length; i++) {
        if (typeof files[i] === 'string') preview.filesChanged.push(files[i] as string);
      }
    }
    return preview;
  }

  /** Rewind 提交：返回更新后的同一任务，绝不是新任务 id。 */
  async rewindCommit(deviceId: string, sessionId: string, clientId: string): Promise<RemoteSession | null> {
    const client = this.client;
    if (!client) return null;
    const args: Object[] = [sessionId, clientId];
    const opts = new DlInvokeOptions();
    opts.channel = 'maker:rewind:commit';
    opts.args = args;
    const env = await client.invoke(deviceId, opts);
    const result = unwrapInvokeResult(env) as Record<string, Object>;
    if (result === undefined || result === null || typeof result !== 'object' || Array.isArray(result)) {
      return null;
    }
    return parseSession(result);
  }

  /** 删除一条可见消息；assistant 可能由服务端扩展为同一轮的多条 clientId。 */
  async deleteMessage(deviceId: string, sessionId: string, clientId: string): Promise<string[]> {
    const client = this.client;
    if (!client) return [];
    const opts = new DlInvokeOptions();
    opts.channel = 'maker:message:delete';
    opts.args = [sessionId, clientId];
    const result = unwrapInvokeResult(await client.invoke(deviceId, opts)) as Record<string, Object>;
    const deleted: string[] = [];
    const rawIds = result['clientIds'];
    if (Array.isArray(rawIds)) {
      const ids = rawIds as Object[];
      for (let i = 0; i < ids.length; i++) {
        if (typeof ids[i] === 'string') deleted.push(ids[i] as string);
      }
    }
    if (deleted.length === 0) {
      const single = readStr(result, 'clientId');
      if (single.length > 0) deleted.push(single);
    }
    if (deleted.length > 0) {
      const current = this.messagesBySession.get(sessionId) ?? [];
      const next: RemoteMessage[] = [];
      for (let i = 0; i < current.length; i++) {
        if (deleted.indexOf(current[i].clientId) < 0) next.push(current[i]);
      }
      this.messagesBySession.set(sessionId, next);
      this.historyCoverageBySession.delete(sessionId);
      this.notify();
    }
    return deleted;
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

  private applyLatestWindow(sessionId: string, page: HistoryPage): RemoteMessage[] {
    // 最新窗重拉会重新裁定连续区间；旧 buffer 不能跨权威窗口复用。
    this.clearOlderTurnState(sessionId);
    if (page.items.length === 0) {
      const streaming = this.streamingBySession.get(sessionId);
      if (streaming !== undefined && !streaming.finished
        && (streaming.text.length > 0 || streaming.tools.length > 0)) {
        return this.messagesBySession.get(sessionId) ?? [];
      }
    }
    const current = this.messagesBySession.get(sessionId) ?? [];
    const localOnly = current.filter((message: RemoteMessage) => message.localOnly);
    const reconciled = reconcileLatestMessageWindow(
      current,
      page.items,
      page.hasMore,
      this.historyCoverageBySession.get(sessionId) ?? null,
      this.subscriptionAckedSessions.has(sessionId),
    );
    reconciled.items = this.mergeWithoutDuplicates(localOnly, reconciled.items);
    reconciled.items.sort(sortMessagesAsc);
    this.messagesBySession.set(sessionId, reconciled.items);
    if (reconciled.coverage !== null) {
      this.historyCoverageBySession.set(sessionId, reconciled.coverage);
    } else {
      this.historyCoverageBySession.delete(sessionId);
    }
    return reconciled.items;
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

/** created push 是权威行；唯一例外是不能让新截断占位覆盖已有完整行。 */
export function preferIncomingCreatedMessage(
  existing: RemoteMessage,
  incoming: RemoteMessage,
): boolean {
  const existingTruncated = readBool(existing.agentMeta, 'remoteContentTruncated', false);
  const incomingTruncated = readBool(incoming.agentMeta, 'remoteContentTruncated', false);
  if (!existingTruncated && incomingTruncated) return false;
  return true;
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
