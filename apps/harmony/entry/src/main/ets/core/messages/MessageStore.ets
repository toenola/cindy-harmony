/**
 * 消息 Store：历史加载 + 流式增量 + 发送/停止。
 *
 * - 打开会话：subscribe `session:<id>` topic → 拉最近一页历史（desc，
 *   limit=80），再反转为升序渲染。
 * - push：`local-db:messages:created` 逐条追加（按 id 去重）、
 *   `local-db:messages:deleted` 按 clientId 移除。
 * - 发送：invoke maker:send（createOpts 由会话字段构造，persistUserMessage 由 Harmony 生成）；
 *   Desktop accepted 事务先落库，再由 push/发送后重拉进入渲染，不直接乐观插入。
 * - 桌面端是权威来源；断线补齐（gap healing）属于切片 5。
 *
 * ArkTS 约束：对象字面量一律先声明 Record 再逐键赋值；调用 DlInvokeOptions
 * 显式 new，避免字面量缺字段。
 */

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DlClient, DlInvokeOptions } from '../device-link/DlClient';
import { DlChannels, sessionTopic, Envelope } from '../device-link/DlProtocol';
import {
  RemoteMessage, RemoteSession, parseMessage, parseSession, sortMessagesAsc,
  readStr, readObj, readBool, readNum, mergeAgentTaskTerminalStatus, safeErrorMessage,
} from '../tasks/TaskModels';
import { RemoteImageRef, RemoteMediaFetchResult } from '../attachments/AttachmentModels';
import {
  applyCodexPlanSnapshotOnDone,
  markCodexPlanTurnFailed,
  summarizeText,
} from './MessageRender';
import { unwrapInvokeResult } from '../tasks/TaskStore';
import {
  classifySessionRetention,
  estimateMessageRowsBytes,
  hasProtectedMessageRow,
  pushAuthorityAccepted,
  RetentionCandidate,
  selectRegularBudgetEvictions,
  trimMessageWindow,
} from './MessageRetentionPolicy';
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
import {
  historyRetryLimits,
  isPayloadTooLargeError,
  shouldInferOlderMessagesFromCount,
  shouldKeepOlderMessagesAffordance,
} from './MessagePaging';
import {
  MAX_CACHED_MESSAGE_SESSIONS,
  SessionMessageCacheStore,
} from './SessionMessageCacheStore';
import {
  applyGenerationStatusEvent,
  resetGenerationMetricsForNewTurn,
  SessionGenerationStatus,
} from './GenerationStatus';

const DOMAIN = 0x0000;
const TAG = 'CindyMsg';

// 与 Mobile/iOS 的会话历史页一致；Device Link 帧过大时 requestMessagesList
// 会按 80 → 40 → 20 → 10 → 5 → 1 自动降档。
const HISTORY_PAGE_LIMIT = 80;
const RECONNECT_MESSAGE_WINDOW_LIMIT = 80;
/** 对齐 Mobile：连续正文增量按两帧左右合并，避免每个 token 都重建整棵消息树。 */
export const TEXT_DELTA_BATCH_INTERVAL_MS = 32;
/** 进程内保留更多已上翻历史；超限时按最近访问淘汰整个非活动会话。 */
const MAX_MEMORY_CACHED_MESSAGE_ROWS = 1600;

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

/** 空权威窗口与实时尾部交错时的延迟清窗状态。 */
export class AuthoritativeEmptyDeferrals {
  private sessions: Set<string> = new Set();

  update(sessionId: string, shouldDefer: boolean): void {
    if (shouldDefer) this.sessions.add(sessionId);
    else this.sessions.delete(sessionId);
  }

  cancel(sessionId: string): void {
    this.sessions.delete(sessionId);
  }

  consume(sessionId: string): boolean {
    if (!this.sessions.has(sessionId)) return false;
    this.sessions.delete(sessionId);
    return true;
  }

  clear(): void {
    this.sessions.clear();
  }
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

/**
 * maker:event 会早于 Desktop 的异步消息落库。Codex 的 update_plan 又会复用同一
 * toolUseId 原地更新，所以必须短暂保留最新快照，避免晚到的首次 0/N 持久行把
 * 已完成状态覆盖回去。
 */
class LivePlanSnapshot {
  content: Record<string, Object> = {};
  persistId: string = '';
  toolUseId: string = '';
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
  /** 仅在运行 boolean 翻转时通知，避免任务列表随每个流式事件整页重绘。 */
  private runningStateListeners: Array<() => void> = [];
  private messagesBySession: Map<string, RemoteMessage[]> = new Map();
  /** Mobile 同源的 live plan overlay；按 toolUseId 与 persistId 双重索引。 */
  private livePlanSnapshotsBySession: Map<string, Map<string, LivePlanSnapshot>> = new Map();
  /** sessionId -> deviceId（当前订阅关系）。 */
  private subscribed: Map<string, string> = new Map();
  private hasMoreBySession: Map<string, boolean> = new Map();
  /** 会话列表透出的服务端消息总数，用于短页（payload 裁剪）时判断还有历史。 */
  private messageCountBySession: Map<string, number> = new Map();
  /** 流式 assistant 消息（maker:event 累积）。 */
  private streamingBySession: Map<string, StreamingMessage> = new Map();
  /** maker 权威运行态；与临时正文投影分开，避免终态事件丢失时 Composer 卡住。 */
  private runningBySession: Map<string, boolean> = new Map();
  /** 产品级 turn 的本地计时起点；同一轮的多种 running 信号交接不能重置。 */
  private runStartedAtBySession: Map<string, number> = new Map();
  /** 远程运行态查询的代次，防止旧快照覆盖在途 maker 事件。 */
  private runningStateRevisions: Map<string, number> = new Map();
  /** maker status 的真实 turn 边界；孤儿 Agent 卡只能在本边界内显示。 */
  private makerTurnRunningBySession: Map<string, boolean> = new Map();
  /** maker status 的输出 token / 生成时长；实时速率只认服务端可靠字段。 */
  private generationStatusBySession: Map<string, SessionGenerationStatus> = new Map();
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
  /** 最近消息持久快照；只保存稳定消息行，不保存临时 running / streaming 投影。 */
  private readonly sessionMessageCache: SessionMessageCacheStore = new SessionMessageCacheStore();
  /** 已知会话所属设备，供内存消息变更写回按设备隔离的持久缓存。 */
  private cachedDeviceBySession: Map<string, string> = new Map();
  /** 非活动会话进程内缓存的 LRU 顺序。 */
  private cacheAccessBySession: Map<string, number> = new Map();
  private cacheAccessSequence: number = 0;
  /**
   * 任务快照查询（AppServices 注入 TaskStore）。驻留分类只认权威 `source`，
   * 未注入时全部按普通任务处理，宁可多驻留也不误回收。
   */
  private sessionSnapshotResolver: ((sessionId: string, deviceId: string) => RemoteSession | undefined) | undefined =
    undefined;
  /** 页面打开代次：关闭后的旧历史响应不得覆盖新 lease。 */
  private sessionLeaseRevisions: Map<string, number> = new Map();
  /** 同一会话的 subscribe / unsubscribe 串行，避免快速重进时旧退订撤销新订阅。 */
  private subscriptionOperations: Map<string, Promise<void>> = new Map();
  /** 同一会话的断线恢复 single-flight；新连接代次会主动清掉旧操作。 */
  private resubscribeOperations: Map<string, Promise<void>> = new Map();
  /** 同一设备的 active 快照 single-flight；避免在线事件与设备刷新重复探针。 */
  private activeHydrationOperations: Map<string, Promise<void>> = new Map();
  /** 同一会话的运行态探针 single-flight。 */
  private runningStateOperations: Map<string, Promise<void>> = new Map();
  private recoveryGeneration: number = 0;
  /** 空历史到达时若仍有 live 投影，先延迟清窗；终态探针收口后再应用该权威空窗。 */
  private deferredAuthoritativeEmptySessions: AuthoritativeEmptyDeferrals =
    new AuthoritativeEmptyDeferrals();
  /** 在当前产品 turn 内已固化的临时行；权威空窗收口时不能连最终投影一起删掉。 */
  private pendingStreamingProjectionKeysBySession: Map<string, Set<string>> = new Map();
  /** 消息 push 代次；旧的空历史响应不能覆盖请求期间刚到的权威增量。 */
  private authoritativeMessageRevisions: Map<string, number> = new Map();
  /** 正文内容立即累积，但 UI 通知按 Mobile 的 32ms 窗口合并。 */
  private pendingTextDeltaNotificationSessions: Set<string> = new Set();
  private textDeltaNotificationTimer: number = -1;

  async initCache(context: common.Context): Promise<void> {
    await this.sessionMessageCache.init(context);
  }

  setCacheAccountScope(accountId: string): void {
    this.sessionMessageCache.setAccountScope(accountId);
  }

  /** 登出/切换账号：本地消息、运行投影和落盘快照必须一起失效。 */
  async clearAllCachedSessions(): Promise<void> {
    // 先推进恢复代次，再等待旧订阅的 best-effort 退订；等待期间若仍有旧回包，
    // 不能把已经清空的账号状态重新种回内存。
    this.recoveryGeneration += 1;
    const subscribedSessionIds: string[] = [];
    const subscribedDeviceIds: string[] = [];
    this.subscribed.forEach((deviceId: string, sessionId: string) => {
      subscribedSessionIds.push(sessionId);
      subscribedDeviceIds.push(deviceId);
      this.nextSessionLease(sessionId);
    });
    this.subscribed.clear();
    const client = this.client;
    if (client !== undefined) {
      const pendingUnsubscribes: Promise<void>[] = [];
      for (let i = 0; i < subscribedSessionIds.length; i++) {
        const sessionId = subscribedSessionIds[i];
        const deviceId = subscribedDeviceIds[i];
        pendingUnsubscribes.push(this.queueSubscriptionOperation(
          sessionId, async (): Promise<void> => {
            try {
              await client.unsubscribe(deviceId, [sessionTopic(sessionId)]);
            } catch (e) {
              // 登出/切号仍继续清本地；断链后的订阅会由 relay 自身释放。
            }
          }));
      }
      await Promise.all(pendingUnsubscribes);
    }
    this.messagesBySession.clear();
    this.livePlanSnapshotsBySession.clear();
    this.hasMoreBySession.clear();
    this.messageCountBySession.clear();
    this.streamingBySession.clear();
    const hadRunningSession = this.runningBySession.size > 0;
    this.runningBySession.clear();
    this.runStartedAtBySession.clear();
    this.makerTurnRunningBySession.clear();
    this.generationStatusBySession.clear();
    this.taskUpdatesBySession.clear();
    this.parkedTaskUpdatesBySession.clear();
    this.loadFailedBySession.clear();
    this.consideredHistoryGaps.clear();
    this.historyCoverageBySession.clear();
    this.subscriptionAckedSessions.clear();
    this.cachedDeviceBySession.clear();
    this.cacheAccessBySession.clear();
    this.cacheAccessSequence = 0;
    this.runningStateRevisions.clear();
    this.historyHealGenerations.clear();
    this.sessionLeaseRevisions.clear();
    this.subscriptionOperations.clear();
    this.resubscribeOperations.clear();
    this.activeHydrationOperations.clear();
    this.runningStateOperations.clear();
    this.deferredAuthoritativeEmptySessions.clear();
    this.pendingStreamingProjectionKeysBySession.clear();
    this.authoritativeMessageRevisions.clear();
    this.clearTextDeltaNotifications();
    await this.sessionMessageCache.clear();
    if (hadRunningSession) this.notifyRunningStateChanged();
    this.notify();
  }

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

  /** 列表只关心运行边界，不订阅正文、工具和 token 级消息更新。 */
  onRunningStateChanged(listener: () => void): () => void {
    this.runningStateListeners.push(listener);
    return () => {
      const idx = this.runningStateListeners.indexOf(listener);
      if (idx >= 0) this.runningStateListeners.splice(idx, 1);
    };
  }

  private notify(): void {
    for (const l of this.listeners) {
      l();
    }
  }

  private notifyRunningStateChanged(): void {
    for (const listener of this.runningStateListeners) listener();
  }

  private scheduleTextDeltaNotification(sessionId: string): void {
    this.pendingTextDeltaNotificationSessions.add(sessionId);
    if (this.textDeltaNotificationTimer >= 0) return;
    this.textDeltaNotificationTimer = setTimeout(() => {
      this.textDeltaNotificationTimer = -1;
      if (this.pendingTextDeltaNotificationSessions.size === 0) return;
      this.pendingTextDeltaNotificationSessions.clear();
      this.notify();
    }, TEXT_DELTA_BATCH_INTERVAL_MS);
  }

  /** 结构/终态边界会自行 notify，只需吞掉尚未发出的正文通知，保证同帧只刷新一次。 */
  private consumePendingTextDeltaNotification(sessionId: string): boolean {
    const consumed = this.pendingTextDeltaNotificationSessions.delete(sessionId);
    if (this.pendingTextDeltaNotificationSessions.size === 0
      && this.textDeltaNotificationTimer >= 0) {
      clearTimeout(this.textDeltaNotificationTimer);
      this.textDeltaNotificationTimer = -1;
    }
    return consumed;
  }

  private clearTextDeltaNotifications(): void {
    this.pendingTextDeltaNotificationSessions.clear();
    if (this.textDeltaNotificationTimer >= 0) {
      clearTimeout(this.textDeltaNotificationTimer);
      this.textDeltaNotificationTimer = -1;
    }
  }

  private touchSessionCache(sessionId: string): void {
    if (sessionId.length === 0) return;
    this.cacheAccessSequence += 1;
    this.cacheAccessBySession.set(sessionId, this.cacheAccessSequence);
  }

  private rememberSessionDevice(sessionId: string, deviceId: string): void {
    if (sessionId.length === 0 || deviceId.length === 0) return;
    const previousDeviceId = this.cachedDeviceBySession.get(sessionId)
      ?? this.subscribed.get(sessionId) ?? '';
    if (previousDeviceId.length > 0 && previousDeviceId !== deviceId) {
      // MessageStore 当前只持有一个 session lease；切换到另一台设备前，
      // 先把旧设备稳定窗口写回其缓存，再清掉消息、运行态和历史代次，
      // 避免同名 session 在新设备首个历史响应前短暂串出旧内容。
      this.persistSessionMessages(sessionId);
      this.clearSessionProjectionForDeviceSwitch(sessionId);
    }
    this.cachedDeviceBySession.set(sessionId, deviceId);
    this.touchSessionCache(sessionId);
  }

  /**
   * 详情页读取也必须带设备边界。
   *
   * MessageStore 内部仍按 sessionId 保存当前打开的一份投影，但同一个 id
   * 可能同时存在于多台 Desktop。写入侧已经由 pushAuthorityAccepted 拦截
   * 外来事件；读取侧若继续无条件返回旧 Map，切换设备的首帧就会短暂显示
   * 上一台电脑的历史、工作步骤或生成指标。
   */
  private sessionReadAllowed(sessionId: string, deviceId: string): boolean {
    if (deviceId.length === 0) return true;
    const owner = this.cachedDeviceBySession.get(sessionId)
      ?? this.subscribed.get(sessionId) ?? '';
    return owner.length === 0 || owner === deviceId;
  }

  private clearSessionProjectionForDeviceSwitch(sessionId: string): void {
    const previousSubscribedDeviceId = this.subscribed.get(sessionId);
    this.nextSessionLease(sessionId);
    // 同一个 sessionId 在另一台 Desktop 上重新打开时，先撤销旧设备的 relay 订阅。
    // 退订必须进入同一条串行队列，保证随后新设备的 subscribe 不会被旧退订覆盖。
    this.subscribed.delete(sessionId);
    this.subscriptionAckedSessions.delete(sessionId);
    const client = this.client;
    if (previousSubscribedDeviceId !== undefined && client !== undefined) {
      void this.queueSubscriptionOperation(sessionId, async (): Promise<void> => {
        try {
          await client.unsubscribe(previousSubscribedDeviceId, [sessionTopic(sessionId)]);
        } catch (e) {
          // 切换仍继续；断链后的旧订阅会由 relay 自身释放。
        }
      });
    }
    this.consumePendingTextDeltaNotification(sessionId);
    this.messagesBySession.delete(sessionId);
    this.livePlanSnapshotsBySession.delete(sessionId);
    this.hasMoreBySession.delete(sessionId);
    this.messageCountBySession.delete(sessionId);
    this.streamingBySession.delete(sessionId);
    this.runningBySession.delete(sessionId);
    this.runStartedAtBySession.delete(sessionId);
    this.makerTurnRunningBySession.delete(sessionId);
    this.generationStatusBySession.delete(sessionId);
    this.taskUpdatesBySession.delete(sessionId);
    this.parkedTaskUpdatesBySession.delete(sessionId);
    this.loadFailedBySession.delete(sessionId);
    this.consideredHistoryGaps.delete(sessionId);
    this.historyCoverageBySession.delete(sessionId);
    this.resubscribeOperations.delete(sessionId);
    this.runningStateOperations.delete(sessionId);
    this.bumpRunningStateRevision(sessionId);
    this.historyHealGenerations.set(sessionId,
      (this.historyHealGenerations.get(sessionId) ?? 0) + 1);
    this.deferredAuthoritativeEmptySessions.cancel(sessionId);
    this.pendingStreamingProjectionKeysBySession.delete(sessionId);
    this.authoritativeMessageRevisions.delete(sessionId);
    this.cachedDeviceBySession.delete(sessionId);
    this.cacheAccessBySession.delete(sessionId);
  }

  /** maker/session push 也必须经过与 messages:created 相同的设备归属围栏。 */
  private acceptDeviceScopedSessionEvent(sessionId: string, deviceId: string): boolean {
    if (deviceId.length === 0) return true;
    if (!pushAuthorityAccepted(deviceId,
      this.subscribed.get(sessionId) ?? '',
      this.cachedDeviceBySession.get(sessionId) ?? '')) {
      return false;
    }
    this.rememberSessionDevice(sessionId, deviceId);
    return true;
  }

  private persistSessionMessages(sessionId: string): void {
    const deviceId = this.cachedDeviceBySession.get(sessionId) ?? '';
    if (deviceId.length === 0) return;
    this.sessionMessageCache.save(deviceId, sessionId, this.messagesBySession.get(sessionId) ?? []);
  }

  private rememberLivePlanSnapshot(sessionId: string, snapshot: LivePlanSnapshot): void {
    let sessionSnapshots = this.livePlanSnapshotsBySession.get(sessionId);
    if (sessionSnapshots === undefined) {
      sessionSnapshots = new Map<string, LivePlanSnapshot>();
      this.livePlanSnapshotsBySession.set(sessionId, sessionSnapshots);
    }
    sessionSnapshots.set(`tool:${snapshot.toolUseId}`, snapshot);
    if (snapshot.persistId.length > 0) {
      sessionSnapshots.set(`persist:${snapshot.persistId}`, snapshot);
    }
  }

  private rememberLivePlanContent(
    sessionId: string,
    toolUseId: string,
    content: Record<string, Object>,
  ): void {
    const previous = this.livePlanSnapshotsBySession.get(sessionId)?.get(`tool:${toolUseId}`);
    const snapshot = new LivePlanSnapshot();
    snapshot.content = content;
    snapshot.toolUseId = toolUseId;
    snapshot.persistId = previous?.persistId ?? '';
    this.rememberLivePlanSnapshot(sessionId, snapshot);
  }

  /** 晚到或重拉的旧 DB 行只能补身份，不能让计划内容倒退。 */
  private overlayLivePlanSnapshot(sessionId: string, message: RemoteMessage): void {
    if (message.role !== 'tool_use') return;
    const sessionSnapshots = this.livePlanSnapshotsBySession.get(sessionId);
    if (sessionSnapshots === undefined) return;
    let content: Record<string, Object> = {};
    if (message.content !== undefined && typeof message.content === 'object'
      && !Array.isArray(message.content)) {
      content = message.content as Record<string, Object>;
    }
    const contentToolUseId = readStr(content, 'toolUseId');
    const snapshot = sessionSnapshots.get(`persist:${message.id}`)
      ?? sessionSnapshots.get(`persist:${message.clientId}`)
      ?? (message.toolUseId.length > 0
        ? sessionSnapshots.get(`tool:${message.toolUseId}`) : undefined)
      ?? (contentToolUseId.length > 0
        ? sessionSnapshots.get(`tool:${contentToolUseId}`) : undefined);
    if (snapshot === undefined) return;
    message.content = snapshot.content;
    message.toolUseId = snapshot.toolUseId;
    message.terminalPlanSnapshot = readBool(snapshot.content, 'terminalPlanSnapshot', false);
    message.terminalPlanAtMs = readNum(snapshot.content, 'terminalPlanAtMs', 0);
    if (typeof snapshot.content['turnCompleted'] === 'boolean') {
      message.hasTurnCompleted = true;
      message.turnCompleted = snapshot.content['turnCompleted'] as boolean;
    }
  }

  private setSessionMessages(sessionId: string, messages: RemoteMessage[]): void {
    for (let i = 0; i < messages.length; i++) {
      this.overlayLivePlanSnapshot(sessionId, messages[i]);
    }
    this.messagesBySession.set(sessionId, messages);
    this.touchSessionCache(sessionId);
    this.persistSessionMessages(sessionId);
  }

  private removeSessionMessages(sessionId: string, removePersistent: boolean): void {
    this.messagesBySession.delete(sessionId);
    if (removePersistent) this.persistSessionMessages(sessionId);
  }

  /** 只在内存仍为空时种入冷启动快照，网络先返回时绝不让慢缓存反向覆盖。 */
  private hydrateCachedMessagesIfEmpty(deviceId: string, sessionId: string): boolean {
    if ((this.messagesBySession.get(sessionId)?.length ?? 0) > 0) return false;
    const cached = this.sessionMessageCache.read(deviceId, sessionId);
    if (cached.length === 0) return false;
    this.messagesBySession.set(sessionId, cached);
    this.touchSessionCache(sessionId);
    this.notify();
    return true;
  }

  private nextSessionLease(sessionId: string): number {
    const next = (this.sessionLeaseRevisions.get(sessionId) ?? 0) + 1;
    this.sessionLeaseRevisions.set(sessionId, next);
    return next;
  }

  private sessionLeaseCurrent(sessionId: string, deviceId: string, lease: number): boolean {
    return this.sessionLeaseRevisions.get(sessionId) === lease
      && this.subscribed.get(sessionId) === deviceId;
  }

  private currentSessionLease(deviceId: string, sessionId: string): number {
    const lease = this.sessionLeaseRevisions.get(sessionId) ?? -1;
    return lease >= 0 && this.sessionLeaseCurrent(sessionId, deviceId, lease) ? lease : -1;
  }

  private queueSubscriptionOperation(sessionId: string, operation: () => Promise<void>): Promise<void> {
    const previous = this.subscriptionOperations.get(sessionId) ?? Promise.resolve();
    const current = previous.catch(() => {
    }).then(operation);
    this.subscriptionOperations.set(sessionId, current);
    void current.then(() => {
      if (this.subscriptionOperations.get(sessionId) === current) {
        this.subscriptionOperations.delete(sessionId);
      }
    }).catch(() => {
      if (this.subscriptionOperations.get(sessionId) === current) {
        this.subscriptionOperations.delete(sessionId);
      }
    });
    return current;
  }

  private memoryCachedSessionIds(): string[] {
    const ids = new Set<string>();
    this.messagesBySession.forEach((_messages: RemoteMessage[], sessionId: string) => ids.add(sessionId));
    this.streamingBySession.forEach((_streaming: StreamingMessage, sessionId: string) => ids.add(sessionId));
    this.taskUpdatesBySession.forEach((_updates: Map<string, AgentTaskUpdate>, sessionId: string) => ids.add(sessionId));
    this.livePlanSnapshotsBySession.forEach(
      (_snapshots: Map<string, LivePlanSnapshot>, sessionId: string) => ids.add(sessionId));
    const out: string[] = [];
    ids.forEach((sessionId: string) => out.push(sessionId));
    return out;
  }

  private memoryCachedMessageRows(): number {
    let rows = 0;
    this.messagesBySession.forEach((messages: RemoteMessage[]) => {
      rows += messages.length;
    });
    return rows;
  }

  private evictMemorySession(sessionId: string): void {
    this.consumePendingTextDeltaNotification(sessionId);
    this.messagesBySession.delete(sessionId);
    this.livePlanSnapshotsBySession.delete(sessionId);
    this.hasMoreBySession.delete(sessionId);
    this.messageCountBySession.delete(sessionId);
    this.loadFailedBySession.delete(sessionId);
    this.streamingBySession.delete(sessionId);
    this.markSessionRunning(sessionId, false);
    this.makerTurnRunningBySession.delete(sessionId);
    this.generationStatusBySession.delete(sessionId);
    this.taskUpdatesBySession.delete(sessionId);
    this.parkedTaskUpdatesBySession.delete(sessionId);
    this.runningStateRevisions.delete(sessionId);
    this.historyHealGenerations.delete(sessionId);
    this.consideredHistoryGaps.delete(sessionId);
    this.historyCoverageBySession.delete(sessionId);
    this.subscriptionAckedSessions.delete(sessionId);
    this.deferredAuthoritativeEmptySessions.cancel(sessionId);
    this.pendingStreamingProjectionKeysBySession.delete(sessionId);
    this.authoritativeMessageRevisions.delete(sessionId);
    this.cachedDeviceBySession.delete(sessionId);
    this.cacheAccessBySession.delete(sessionId);
  }

  private evictInactiveSessionCaches(): void {
    let ids = this.memoryCachedSessionIds();
    while (ids.length > MAX_CACHED_MESSAGE_SESSIONS
      || this.memoryCachedMessageRows() > MAX_MEMORY_CACHED_MESSAGE_ROWS) {
      // 单个用户刚查看过的超长会话不整窗丢弃；行数上限是多会话缓存的软预算。
      if (ids.length <= 1) return;
      let victim = '';
      let oldest = Number.MAX_SAFE_INTEGER;
      for (let i = 0; i < ids.length; i++) {
        const sessionId = ids[i];
        if (this.subscribed.has(sessionId)) continue;
        const access = this.cacheAccessBySession.get(sessionId) ?? 0;
        if (access < oldest) {
          oldest = access;
          victim = sessionId;
        }
      }
      if (victim.length === 0) return;
      this.evictMemorySession(victim);
      ids = this.memoryCachedSessionIds();
    }
    this.enforceRegularMessageBudget();
  }

  /**
   * 普通任务全局预算（800 行 / 64 MiB，先达者为准）。
   *
   * 只淘汰内存对象；持久快照删除是独立决策，不在此处执行——重开仍可从最近一页
   * 乐观恢复。订阅中的会话和含本地保护行（系统卡、乐观消息、流式行）的会话整窗跳过。
   */
  private enforceRegularMessageBudget(): void {
    const candidates: RetentionCandidate[] = [];
    this.messagesBySession.forEach((messages: RemoteMessage[], sessionId: string) => {
      const candidate = new RetentionCandidate();
      candidate.sessionId = sessionId;
      candidate.retention = classifySessionRetention(this.sessionSnapshot(sessionId));
      candidate.rowCount = messages.length;
      candidate.bytes = estimateMessageRowsBytes(messages);
      candidate.accessOrder = this.cacheAccessBySession.get(sessionId) ?? 0;
      candidate.leased = this.subscribed.has(sessionId);
      candidate.hasProtectedRows = hasProtectedMessageRow(messages);
      candidates.push(candidate);
    });
    const victims = selectRegularBudgetEvictions(candidates);
    for (let i = 0; i < victims.length; i++) this.evictMemorySession(victims[i]);
  }

  /** 自动化任务的驻留分类需要任务快照；缺失时按普通任务保守处理。 */
  private sessionSnapshot(sessionId: string): RemoteSession | undefined {
    const deviceId = this.cachedDeviceBySession.get(sessionId) ?? '';
    return this.sessionSnapshotResolver === undefined
      ? undefined : this.sessionSnapshotResolver(sessionId, deviceId);
  }

  /**
   * 注入任务快照查询（由 AppServices 用 TaskStore 提供）。
   * 驻留分类只认权威 `source` 字段，禁止用标题猜测 scheduler。
   */
  setSessionSnapshotResolver(
    resolver: (sessionId: string, deviceId: string) => RemoteSession | undefined,
  ): void {
    this.sessionSnapshotResolver = resolver;
  }

  getMessages(sessionId: string, deviceId: string = ''): RemoteMessage[] {
    if (!this.sessionReadAllowed(sessionId, deviceId)) return [];
    this.touchSessionCache(sessionId);
    return this.messagesBySession.get(sessionId) ?? [];
  }

  hasMessageClientId(sessionId: string, clientId: string, deviceId: string = ''): boolean {
    if (clientId.length === 0) return false;
    if (!this.sessionReadAllowed(sessionId, deviceId)) return false;
    const messages = this.messagesBySession.get(sessionId) ?? [];
    return messages.some((message: RemoteMessage) =>
      message.clientId === clientId || message.id === clientId);
  }

  appendLocalSystemCard(
    sessionId: string,
    type: string,
    data: Record<string, Object>,
    deviceId: string = '',
  ): void {
    if (!this.sessionReadAllowed(sessionId, deviceId)) return;
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
    this.setSessionMessages(sessionId, next);
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
    if (!this.sessionReadAllowed(sessionId, deviceId)) return false;
    // 同一 sessionId 可能在 A → B → A 间快速切换；仅比较当前 deviceId
    // 无法区分第一台 A 的迟到回包与第二台 A 的新页面。around 只服务当前打开的
    // 会话，因此固定本次订阅 lease，回包只能写回发起时的那一代。
    const expectedLease = this.currentSessionLease(deviceId, sessionId);
    if (expectedLease < 0) return false;
    if (this.linkOpener !== undefined) await this.linkOpener(deviceId);
    if (!this.sessionLeaseCurrent(sessionId, deviceId, expectedLease)) return false;
    const options: Record<string, Object> = {};
    options['radius'] = Math.max(1, Math.min(100, Math.floor(radius)));
    const invoke = new DlInvokeOptions();
    invoke.channel = 'local-db:messages:around-client-id';
    invoke.args = [sessionId, clientId, options];
    const env = await client.invoke(deviceId, invoke);
    // 定位请求可能跨越会话切换；旧设备返回后再次确认 owner，禁止把旧窗口
    // 的 around 结果合并到当前设备的同名任务；同一设备重新打开也必须拒绝旧 lease。
    if (!this.sessionLeaseCurrent(sessionId, deviceId, expectedLease)) return false;
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
      this.setSessionMessages(sessionId, merged);
      this.notify();
    }
    return this.hasMessageClientId(sessionId, clientId, deviceId);
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
    if (!this.sessionReadAllowed(sessionId, deviceId)) return 'unknown';
    const local = this.getMessages(sessionId, deviceId);
    if (local.some((message: RemoteMessage) =>
      message.clientId === clientId || message.id === clientId)) return 'applied';
    try {
      const page = await this.requestMessagesList(deviceId, sessionId, limit, '');
      if (!this.sessionReadAllowed(sessionId, deviceId)) return 'unknown';
      if (page.items.some((message: RemoteMessage) =>
        message.clientId === clientId || message.id === clientId)) return 'applied';
      if (page.hasMore || page.items.length >= limit) return 'unknown';
      return 'missing';
    } catch (e) {
      return 'unknown';
    }
  }

  getTaskUpdates(sessionId: string, deviceId: string = ''): Map<string, AgentTaskUpdate> {
    if (!this.sessionReadAllowed(sessionId, deviceId)) {
      return new Map<string, AgentTaskUpdate>();
    }
    return this.taskUpdatesBySession.get(sessionId) ?? new Map<string, AgentTaskUpdate>();
  }

  isMakerTurnRunning(sessionId: string, deviceId: string = ''): boolean {
    if (!this.sessionReadAllowed(sessionId, deviceId)) return false;
    return this.makerTurnRunningBySession.get(sessionId) === true;
  }

  /** 当前产品 turn 的运行事实，供列表状态覆盖可能迟到的 completed 未读态。 */
  isSessionRunning(sessionId: string, deviceId: string = ''): boolean {
    // 任务列表可以同时投影多个设备；没有当前打开会话的订阅归属时，
    // 不让旧的全局 running 投影越过设备边界，只把它作为详情页 fallback。
    if (deviceId.length > 0 && this.subscribed.get(sessionId) !== deviceId) return false;
    return this.runningBySession.get(sessionId) === true;
  }

  /** 底部活动条的独立计时起点；0 表示当前没有运行中的产品 turn。 */
  getSessionRunStartedAt(sessionId: string, deviceId: string = ''): number {
    if (!this.sessionReadAllowed(sessionId, deviceId)) return 0;
    return this.runStartedAtBySession.get(sessionId) ?? 0;
  }

  /** 当前产品 turn 的服务端生成指标；返回副本，避免页面意外改写 Store。 */
  getGenerationStatus(sessionId: string, deviceId: string = ''): SessionGenerationStatus {
    const status = new SessionGenerationStatus();
    if (!this.sessionReadAllowed(sessionId, deviceId)) return status;
    const source = this.generationStatusBySession.get(sessionId) ?? new SessionGenerationStatus();
    status.isRunning = this.runningBySession.get(sessionId) === true;
    status.status = source.status;
    status.outputTokens = source.outputTokens;
    status.generationDurationMs = source.generationDurationMs;
    status.generationActive = source.generationActive;
    status.generationReliable = source.generationReliable;
    return status;
  }

  /** 当前会话是否仍在执行；maker 运行态优先于历史投影。 */
  isSessionStreaming(sessionId: string, deviceId: string = ''): boolean {
    if (!this.sessionReadAllowed(sessionId, deviceId)) return false;
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

  hasMore(sessionId: string, deviceId: string = ''): boolean {
    if (!this.sessionReadAllowed(sessionId, deviceId)) return false;
    return this.hasMoreBySession.get(sessionId) ?? false;
  }

  /**
   * 写入任务列表的服务端消息总数。只在分页尚未给出结论时用于乐观推断；
   * 真实分页已经返回后不能再覆盖它，否则尾部新增会被误判为顶部还有历史。
   */
  setMessageCount(sessionId: string, count: number, deviceId: string = ''): void {
    if (!this.sessionReadAllowed(sessionId, deviceId)) return;
    if (count <= 0) {
      this.messageCountBySession.delete(sessionId);
      return;
    }
    this.messageCountBySession.set(sessionId, count);
    const current = this.messagesBySession.get(sessionId) ?? [];
    if (current.length === 0) return;
    if (shouldInferOlderMessagesFromCount(
      this.hasMoreBySession.has(sessionId), count, countRealMessages(current))) {
      this.hasMoreBySession.set(sessionId, true);
    }
  }

  /** 该会话历史是否加载失败（页面据此显示重试）。 */
  loadFailed(sessionId: string, deviceId: string = ''): boolean {
    if (!this.sessionReadAllowed(sessionId, deviceId)) return false;
    return this.loadFailedBySession.get(sessionId) ?? false;
  }

  // ─── 打开 / 关闭 ────────────────────────────────────────────────────────────

  /** 打开会话：确保控制链路 → 拉历史（优先）→ 订阅实时流（并行，失败不阻塞）。 */
  isSessionOpen(sessionId: string, deviceId: string = ''): boolean {
    if (deviceId.length > 0) return this.subscribed.get(sessionId) === deviceId;
    return this.subscribed.has(sessionId);
  }

  async openSession(deviceId: string, sessionId: string): Promise<boolean> {
    this.rememberSessionDevice(sessionId, deviceId);
    this.hydrateCachedMessagesIfEmpty(deviceId, sessionId);
    const client = this.client;
    if (!client) {
      this.loadFailedBySession.set(sessionId, true);
      this.notify();
      return false;
    }
    const lease = this.nextSessionLease(sessionId);
    if (this.subscribed.get(sessionId) === deviceId) {
      if (!this.subscriptionAckedSessions.has(sessionId)) {
        void this.queueSubscriptionOperation(sessionId, async (): Promise<void> => {
          if (!this.sessionLeaseCurrent(sessionId, deviceId, lease)) return;
          try {
            await client.subscribe(deviceId, [sessionTopic(sessionId)]);
            if (this.sessionLeaseCurrent(sessionId, deviceId, lease)) {
              this.subscriptionAckedSessions.add(sessionId);
            }
          } catch (e) {
            // 历史仍可独立恢复，下一次重连/重进继续补订阅。
          }
        });
      }
      // 已打开：重新拉一次历史（重进页面恢复用）。
      const loaded = await this.loadInitial(deviceId, sessionId, lease);
      if (!this.sessionLeaseCurrent(sessionId, deviceId, lease)) return false;
      if (loaded) this.scheduleHistoryHeal(deviceId, sessionId, true);
      void this.refreshSessionRunningState(deviceId, sessionId, lease);
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
    if (this.sessionLeaseRevisions.get(sessionId) !== lease) return false;
    this.subscribed.set(sessionId, deviceId);
    this.subscriptionAckedSessions.delete(sessionId);
    const existingCoverage = this.historyCoverageBySession.get(sessionId);
    if (existingCoverage !== undefined) existingCoverage.liveTailTrusted = false;
    // 订阅实时流（并行，失败不阻塞历史）；与旧 unsubscribe 串行，快速重进不会丢订阅。
    void this.queueSubscriptionOperation(sessionId, async (): Promise<void> => {
      if (!this.sessionLeaseCurrent(sessionId, deviceId, lease)) return;
      try {
        await client.subscribe(deviceId, [sessionTopic(sessionId)]);
        if (this.sessionLeaseCurrent(sessionId, deviceId, lease)) {
          this.subscriptionAckedSessions.add(sessionId);
        }
      } catch (e) {
        // 订阅失败不阻塞历史窗口恢复。
      }
    });
    const loaded = await this.loadInitial(deviceId, sessionId, lease);
    if (!this.sessionLeaseCurrent(sessionId, deviceId, lease)) return false;
    if (loaded) this.scheduleHistoryHeal(deviceId, sessionId, true);
    void this.refreshSessionRunningState(deviceId, sessionId, lease);
    return loaded;
  }

  /**
   * 页面离开只停用实时订阅，保留历史、分页与当前运行投影用于快速重进。
   * 真正内存回收由 LRU 负责；落盘只保留稳定消息的最近一页。
   */
  async closeSession(sessionId: string, deviceId: string = ''): Promise<void> {
    if (deviceId.length > 0 && this.subscribed.get(sessionId) !== deviceId) return;
    this.consumePendingTextDeltaNotification(sessionId);
    const subscribedDeviceId = this.subscribed.get(sessionId);
    this.nextSessionLease(sessionId);
    this.subscribed.delete(sessionId);
    this.touchSessionCache(sessionId);
    this.persistSessionMessages(sessionId);
    // 让关闭前发出的运行探针失效；缓存中的 running 状态留给重进后的新探针裁定。
    this.bumpRunningStateRevision(sessionId);
    this.resubscribeOperations.delete(sessionId);
    this.runningStateOperations.delete(sessionId);
    this.clearGenerationMetrics(sessionId);
    this.historyHealGenerations.set(sessionId,
      (this.historyHealGenerations.get(sessionId) ?? 0) + 1);
    this.subscriptionAckedSessions.delete(sessionId);
    const coverage = this.historyCoverageBySession.get(sessionId);
    if (coverage !== undefined) coverage.liveTailTrusted = false;
    if (subscribedDeviceId !== undefined) {
      const client = this.client;
      if (client) {
        await this.queueSubscriptionOperation(sessionId, async (): Promise<void> => {
          try {
            await client.unsubscribe(subscribedDeviceId, [sessionTopic(sessionId)]);
          } catch (e) {
            // 退订失败不影响本地停用；重连时 registry 会重建。
          }
        });
      }
    }
    // 退订等待期间可能已在同一页面重新打开 B；旧的 close 不能再压缩或淘汰 B 的投影。
    if (deviceId.length > 0 && this.subscribed.get(sessionId) !== undefined) return;
    await this.sessionMessageCache.flush();
    this.compactSessionWindowOnLeave(sessionId);
    this.evictInactiveSessionCaches();
    this.notify();
  }

  /**
   * 离开任务后压缩尾窗。
   *
   * 自动化任务只保留一个最新 80 行窗口（回收隐藏内容），普通任务同样压回默认尾窗，
   * 之后按全局预算竞争。裁剪走软窗口：本地系统卡、乐观消息、流式行等无服务端副本
   * 的行全部保留，保护行较多时允许略超上限。
   *
   * 这里只回收内存；持久快照已在上面 persist / flush 过，不在此删除。
   */
  private compactSessionWindowOnLeave(sessionId: string): void {
    const current = this.messagesBySession.get(sessionId);
    if (current === undefined || current.length <= HISTORY_PAGE_LIMIT) return;
    const trimmed = trimMessageWindow(current, HISTORY_PAGE_LIMIT);
    if (trimmed.length === current.length) return;
    // 窗口被裁剪后覆盖范围不再连续，必须让 gap healing 重新判定。
    this.historyCoverageBySession.delete(sessionId);
    this.hasMoreBySession.set(sessionId, true);
    this.messagesBySession.set(sessionId, trimmed);
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
    const existing = this.resubscribeOperations.get(sessionId);
    if (existing !== undefined) {
      await existing;
      return;
    }
    const operation = this.resubscribeAndHealOnce(deviceId, sessionId);
    this.resubscribeOperations.set(sessionId, operation);
    try {
      await operation;
    } finally {
      if (this.resubscribeOperations.get(sessionId) === operation) {
        this.resubscribeOperations.delete(sessionId);
      }
    }
  }

  private async resubscribeAndHealOnce(deviceId: string, sessionId: string): Promise<void> {
    const client = this.client;
    if (!client) {
      return;
    }
    const recoveryGeneration = this.recoveryGeneration;
    const lease = this.sessionLeaseRevisions.get(sessionId) ?? 0;
    if (recoveryGeneration !== this.recoveryGeneration
      || !this.sessionLeaseCurrent(sessionId, deviceId, lease)) return;
    // relay 新连接后旧订阅失效，需重新 subscribe。
    this.subscriptionAckedSessions.delete(sessionId);
    const previousCoverage = this.historyCoverageBySession.get(sessionId);
    if (previousCoverage !== undefined) previousCoverage.liveTailTrusted = false;
    try {
      await this.queueSubscriptionOperation(sessionId, async (): Promise<void> => {
        if (recoveryGeneration !== this.recoveryGeneration
          || !this.sessionLeaseCurrent(sessionId, deviceId, lease)) return;
        await client.subscribe(deviceId, [sessionTopic(sessionId)]);
      });
      if (recoveryGeneration === this.recoveryGeneration
        && this.sessionLeaseCurrent(sessionId, deviceId, lease)) {
        this.subscriptionAckedSessions.add(sessionId);
      }
    } catch (e) {
      // 订阅失败不阻断 healing
    }
    if (recoveryGeneration !== this.recoveryGeneration
      || !this.sessionLeaseCurrent(sessionId, deviceId, lease)) return;
    const messageRevision = this.authoritativeMessageRevisions.get(sessionId) ?? 0;
    try {
      const page = await this.requestMessagesList(
        deviceId, sessionId, RECONNECT_MESSAGE_WINDOW_LIMIT, '');
      if (recoveryGeneration !== this.recoveryGeneration
        || !this.sessionLeaseCurrent(sessionId, deviceId, lease)) return;
      page.items.sort(sortMessagesAsc);
      const streaming = this.streamingBySession.get(sessionId);
      this.deferredAuthoritativeEmptySessions.update(sessionId,
        shouldDeferAuthoritativeEmptyWindow(
          page.items.length,
          streaming !== undefined && !streaming.finished,
          messageRevision,
          this.authoritativeMessageRevisions.get(sessionId) ?? 0,
        ));
      const merged = this.applyLatestWindow(sessionId, page);
      this.setOlderAvailability(
        sessionId, this.hasMoreAfterPage(sessionId, page, merged));
      this.notify();
      this.scheduleHistoryHeal(deviceId, sessionId, true);
      void this.refreshSessionRunningState(deviceId, sessionId, lease);
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
    this.setSessionMessages(sessionId, merged);
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
      const message = safeErrorMessage(e);
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
    this.recoveryGeneration += 1;
    this.resubscribeOperations.clear();
    this.activeHydrationOperations.clear();
    this.runningStateOperations.clear();
    this.subscriptionAckedSessions.clear();
    this.historyCoverageBySession.forEach((coverage: MessageWindowCoverage) => {
      coverage.liveTailTrusted = false;
    });
    let generationChanged = false;
    this.generationStatusBySession.forEach((status: SessionGenerationStatus) => {
      if (status.outputTokens === 0 && status.generationDurationMs === 0
        && !status.generationActive && status.generationReliable) return;
      status.outputTokens = 0;
      status.generationDurationMs = 0;
      status.generationActive = false;
      status.generationReliable = true;
      generationChanged = true;
    });
    if (generationChanged) this.notify();
  }

  /** 从被控端 active 快照恢复已存在的运行态；终态清理仍由显式 session 探针负责。 */
  async hydrateActiveSessions(deviceId: string): Promise<void> {
    const existing = this.activeHydrationOperations.get(deviceId);
    if (existing !== undefined) {
      await existing;
      return;
    }
    const operation = this.hydrateActiveSessionsOnce(deviceId);
    this.activeHydrationOperations.set(deviceId, operation);
    try {
      await operation;
    } finally {
      if (this.activeHydrationOperations.get(deviceId) === operation) {
        this.activeHydrationOperations.delete(deviceId);
      }
    }
  }

  private async hydrateActiveSessionsOnce(deviceId: string): Promise<void> {
    const client = this.client;
    if (!client) return;
    const recoveryGeneration = this.recoveryGeneration;
    // 设备级 active 快照可能经历 A→B→A 的快速切换；仅比较当前
    // subscribed[sessionId] 会把第一台 A 的迟到结果误认成第二台 A 的结果。
    // 为本次请求固定每个已打开会话的 lease，回包只能写回发起时那一代页面。
    const sessionLeases: Map<string, number> = new Map();
    this.subscribed.forEach((ownerDeviceId: string, sessionId: string) => {
      if (ownerDeviceId !== deviceId) return;
      sessionLeases.set(sessionId, this.sessionLeaseRevisions.get(sessionId) ?? -1);
    });
    const opts = new DlInvokeOptions();
    opts.channel = DlChannels.MAKER_LIST_ACTIVE;
    opts.args = [];
    try {
      const env = await client.invoke(deviceId, opts);
      if (recoveryGeneration !== this.recoveryGeneration) return;
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
        // active 快照是设备级返回值，只能恢复当前仍归属于该设备的打开会话。
        // 同名 sessionId 在切换设备、关闭页面或迟到回包时不能污染另一份投影。
        if (this.subscribed.get(sessionId) !== deviceId
          || this.sessionLeaseRevisions.get(sessionId) !== sessionLeases.get(sessionId)) continue;
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

  /** 把重复 update_plan 同步到唯一持久行，并记住可覆盖迟到 DB 行的最新内容。 */
  private applyLivePlanToolUse(
    sessionId: string,
    data: Record<string, Object>,
    persistId: string,
  ): boolean {
    if (readStr(data, 'toolName') !== 'update_plan') return false;
    const toolUseId = readStr(data, 'toolUseId');
    if (toolUseId.length === 0) return true;
    const content: Record<string, Object> = {};
    content['toolUseId'] = toolUseId;
    content['toolName'] = 'update_plan';
    if (data['input'] !== undefined) content['input'] = data['input'];
    const snapshot = new LivePlanSnapshot();
    snapshot.content = content;
    snapshot.persistId = persistId;
    snapshot.toolUseId = toolUseId;
    this.rememberLivePlanSnapshot(sessionId, snapshot);

    const messages = this.messagesBySession.get(sessionId) ?? [];
    const index = messages.findIndex((message: RemoteMessage) => {
      if (message.role !== 'tool_use') return false;
      if (persistId.length > 0 && (message.id === persistId || message.clientId === persistId)) {
        return true;
      }
      if (message.toolUseId === toolUseId) return true;
      if (message.content === undefined || typeof message.content !== 'object'
        || Array.isArray(message.content)) return false;
      return readStr(message.content as Record<string, Object>, 'toolUseId') === toolUseId;
    });
    if (index >= 0) {
      messages[index].content = content;
      messages[index].toolUseId = toolUseId;
      messages[index].terminalPlanSnapshot = false;
      messages[index].terminalPlanAtMs = 0;
      messages[index].hasTurnCompleted = false;
      this.setSessionMessages(sessionId, messages);
    }
    return true;
  }

  /** done 可能先于持久工具行到达；终态也必须写进 live overlay。 */
  private completeLivePlanSnapshotOnDone(
    sessionId: string,
    plan: Object | undefined,
    turnId: string,
    terminalStatus: string,
    planUpdatedAtMs: number,
    cancelled: boolean,
  ): void {
    if (turnId.length === 0) return;
    const toolUseId = `plan:${turnId}`;
    const live = this.livePlanSnapshotsBySession.get(sessionId)?.get(`tool:${toolUseId}`);
    if (live === undefined) return;
    const row = new RemoteMessage();
    row.role = 'tool_use';
    row.toolUseId = toolUseId;
    row.content = live.content;
    if (!applyCodexPlanSnapshotOnDone(
      [row], plan, turnId, terminalStatus, planUpdatedAtMs, cancelled)) return;
    if (row.content === undefined || typeof row.content !== 'object'
      || Array.isArray(row.content)) return;
    this.rememberLivePlanContent(sessionId, toolUseId, row.content as Record<string, Object>);
  }

  /** maker:event 处理：运行态按终态语义收口，流式正文保留到持久化行回流。 */
  handleMakerEvent(
    sessionId: string,
    event: Object | undefined,
    persistId: string = '',
    deviceId: string = '',
  ): void {
    if (event === undefined || typeof event !== 'object') {
      return;
    }
    if (!this.acceptDeviceScopedSessionEvent(sessionId, deviceId)) return;
    const ev = event as Record<string, Object>;
    const type = readStr(ev, 'type');
    const data = readObj(ev, 'data');
    const eventSource = readStr(ev, 'source');
    this.bumpRunningStateRevision(sessionId);

    if (type === 'agent_task_update') {
      const rawSource = eventSource;
      const source = rawSource === 'codex' || rawSource === 'pi' || rawSource === 'claude-code'
        ? rawSource : '';
      const previous = this.recallParkedTaskUpdates(
        sessionId, data, source, this.taskUpdatesBySession.get(sessionId));
      const next = applyAgentTaskUpdateEvent(previous, data, source, new Date().toISOString());
      if (next !== null) {
        this.consumePendingTextDeltaNotification(sessionId);
        this.taskUpdatesBySession.set(sessionId, next);
        this.notify();
      }
      return;
    }

    if (type === 'compact_boundary') {
      // 压缩边界结束旧投影，但通常仍属于同一产品 turn；后续事件会重新建立新投影。
      this.consumePendingTextDeltaNotification(sessionId);
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
      const active = this.streamingBySession.get(sessionId);
      const startsNewProjection = active !== undefined && (active.finished
        || (persistId.length > 0 && active.persistId.length > 0
          && active.persistId !== persistId));
      if (startsNewProjection) this.consumePendingTextDeltaNotification(sessionId);
      const s = this.ensureStreaming(sessionId, persistId);
      s.text += delta;
      if (startsNewProjection) this.notify();
      else this.scheduleTextDeltaNotification(sessionId);
      return;
    }
    if (type === 'tool_use') {
      this.markSessionRunning(sessionId, true);
      this.applyLivePlanToolUse(sessionId, data, persistId);
      const toolUseId = readStr(data, 'toolUseId');
      if (toolUseId.length === 0) {
        return;
      }
      this.consumePendingTextDeltaNotification(sessionId);
      const active = this.streamingBySession.get(sessionId);
      const updatesCurrentTool = active !== undefined
        && active.tools.some((tool: StreamingToolRow) => tool.toolUseId === toolUseId);
      if (active !== undefined && active.text.length > 0 && !updatesCurrentTool) {
        // Mobile 会在新工具开始前先固化已经出现的进度正文。Harmony 若继续把二者
        // 塞进同一个 StreamingMessage，临时投影会固定输出“工具→正文”，渲染层便
        // 把最新工具误判为正文前的已完成工作组，实时步骤和计时都会消失。
        this.materializeStreamingProjection(sessionId, active);
        this.streamingBySession.delete(sessionId);
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
      this.consumePendingTextDeltaNotification(sessionId);
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
      this.consumePendingTextDeltaNotification(sessionId);
      this.markSessionRunning(sessionId, true);
      // thinking 不增量；由落库行（role=thinking）驱动正文渲染。
      this.notify();
      return;
    }
    if (type === 'status') {
      this.consumePendingTextDeltaNotification(sessionId);
      const isRunning = ev['data'] !== undefined && typeof data['isRunning'] === 'boolean'
        ? data['isRunning'] as boolean
        : undefined;
      if (isRunning === true) {
        const isTurnStart = this.makerTurnRunningBySession.get(sessionId) !== true;
        if (isTurnStart) {
          this.sweepTaskUpdatesAtTurnStart(sessionId);
        }
        this.makerTurnRunningBySession.set(sessionId, true);
        this.markSessionRunning(sessionId, true);
        this.applyGenerationStatus(sessionId, data, true, isTurnStart, false);
      } else if (isRunning === false) {
        if (hasTurnContinuation(ev)) {
          // provider segment ends, but the product turn continues.
          this.markSessionRunning(sessionId, true);
          this.applyGenerationStatus(sessionId, data, false, false, true);
        } else {
          this.applyGenerationStatus(sessionId, data, false, false, false);
          this.makerTurnRunningBySession.delete(sessionId);
          this.finalizeSessionStreaming(sessionId);
        }
      }
      this.notify();
      return;
    }
    if (type === 'done') {
      this.consumePendingTextDeltaNotification(sessionId);
      const s = this.streamingBySession.get(sessionId);
      if (s !== undefined) {
        s.tools.forEach((t: StreamingToolRow) => {
          t.settled = true;
        });
      }
      if (eventSource === 'codex' && !hasTurnContinuation(ev)) {
        if (s !== undefined) {
          this.materializeStreamingProjection(sessionId, s);
          this.streamingBySession.delete(sessionId);
        }
        const raw = readObj(data, 'raw');
        const turnId = readStr(raw, 'id');
        const terminalStatus = readStr(raw, 'status');
        const planUpdatedAtMs = readNum(data, 'planUpdatedAtMs', 0);
        const cancelled = readBool(data, 'cancelled', false);
        this.completeLivePlanSnapshotOnDone(
          sessionId,
          data['plan'],
          turnId,
          terminalStatus,
          planUpdatedAtMs,
          cancelled,
        );
        const messages = this.messagesBySession.get(sessionId) ?? [];
        if (applyCodexPlanSnapshotOnDone(
          messages,
          data['plan'],
          turnId,
          terminalStatus,
          planUpdatedAtMs,
          cancelled,
        )) this.setSessionMessages(sessionId, messages);
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
      this.consumePendingTextDeltaNotification(sessionId);
      const terminal = readBool(data, 'isTerminal', !readBool(data, 'willRetry', false));
      if (terminal) {
        if (eventSource === 'codex') {
          const active = this.streamingBySession.get(sessionId);
          if (active !== undefined) {
            this.materializeStreamingProjection(sessionId, active);
            this.streamingBySession.delete(sessionId);
          }
          markCodexPlanTurnFailed(this.messagesBySession.get(sessionId) ?? []);
        }
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
        this.rememberPendingStreamingProjection(sessionId, use);
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
        this.rememberPendingStreamingProjection(sessionId, result);
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
      this.rememberPendingStreamingProjection(sessionId, assistant);
    }
    list.sort(sortMessagesAsc);
    this.setSessionMessages(sessionId, list);
  }

  private bumpRunningStateRevision(sessionId: string): number {
    const next = (this.runningStateRevisions.get(sessionId) ?? 0) + 1;
    this.runningStateRevisions.set(sessionId, next);
    return next;
  }

  private markSessionRunning(sessionId: string, running: boolean): void {
    const wasRunning = this.runningBySession.get(sessionId) === true;
    if (running) {
      this.runningBySession.set(sessionId, true);
      let generation = this.generationStatusBySession.get(sessionId);
      if (!wasRunning) {
        generation = resetGenerationMetricsForNewTurn(generation ?? new SessionGenerationStatus());
        generation.isRunning = true;
        this.generationStatusBySession.set(sessionId, generation);
      } else if (generation !== undefined) {
        generation.isRunning = true;
      }
      if (!this.runStartedAtBySession.has(sessionId)) {
        this.runStartedAtBySession.set(sessionId, Date.now());
      }
    } else {
      this.runningBySession.delete(sessionId);
      this.runStartedAtBySession.delete(sessionId);
      const generation = this.generationStatusBySession.get(sessionId);
      if (generation !== undefined) {
        generation.isRunning = false;
        generation.generationActive = false;
      }
    }
    if (wasRunning !== running) this.notifyRunningStateChanged();
  }

  private applyGenerationStatus(
    sessionId: string,
    data: Record<string, Object>,
    isRunning: boolean,
    isTurnStart: boolean,
    hasTurnContinuation: boolean,
  ): void {
    const current = this.generationStatusBySession.get(sessionId) ?? new SessionGenerationStatus();
    const next = applyGenerationStatusEvent(
      current, data, isRunning, isTurnStart, hasTurnContinuation);
    this.generationStatusBySession.set(sessionId, next);
  }

  private clearGenerationMetrics(sessionId: string): void {
    const current = this.generationStatusBySession.get(sessionId);
    if (current === undefined) return;
    current.outputTokens = 0;
    current.generationDurationMs = 0;
    current.generationActive = false;
    current.generationReliable = true;
  }

  /** 终态收口：保留临时正文用于最终渲染，但去掉所有运行标记。 */
  private finalizeSessionStreaming(sessionId: string): void {
    this.markSessionRunning(sessionId, false);
    this.finishStreamingProjection(sessionId);
    const protectedProjectionKeys = this.pendingStreamingProjectionKeysBySession.get(sessionId)
      ?? new Set<string>();
    this.pendingStreamingProjectionKeysBySession.delete(sessionId);
    this.applyDeferredAuthoritativeEmpty(sessionId, protectedProjectionKeys);
  }

  private applyDeferredAuthoritativeEmpty(
    sessionId: string,
    protectedProjectionKeys: Set<string>,
  ): void {
    if (!this.deferredAuthoritativeEmptySessions.consume(sessionId)) return;
    const merged = reconcileDeferredAuthoritativeEmptyMessages(
      this.messagesBySession.get(sessionId) ?? [], protectedProjectionKeys);
    this.setSessionMessages(sessionId, merged);
    this.historyCoverageBySession.delete(sessionId);
    this.setOlderAvailability(sessionId, false);
  }

  private rememberPendingStreamingProjection(sessionId: string, message: RemoteMessage): void {
    let keys = this.pendingStreamingProjectionKeysBySession.get(sessionId);
    if (keys === undefined) {
      keys = new Set<string>();
      this.pendingStreamingProjectionKeysBySession.set(sessionId, keys);
    }
    keys.add(messageIdentity(message));
  }

  private discardPendingStreamingProjection(sessionId: string, message: RemoteMessage): void {
    const keys = this.pendingStreamingProjectionKeysBySession.get(sessionId);
    if (keys === undefined) return;
    keys.delete(messageIdentity(message));
    if ((message.role === 'tool_use' || message.role === 'tool_result')
      && message.toolUseId.length > 0) {
      const prefix = message.role === 'tool_use' ? 'streaming-tool-' : 'streaming-result-';
      keys.delete(`id:${prefix}${message.toolUseId}`);
    } else if (message.role === 'assistant') {
      const prefix = `id:streaming-text-${sessionId}`;
      const syntheticKeys: string[] = [];
      keys.forEach((key: string) => {
        if (key.startsWith(prefix)) syntheticKeys.push(key);
      });
      for (let i = 0; i < syntheticKeys.length; i++) keys.delete(syntheticKeys[i]);
    }
    if (keys.size === 0) this.pendingStreamingProjectionKeysBySession.delete(sessionId);
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
  handleMakerStatusChanged(payload: Object | undefined, deviceId: string = ''): void {
    if (payload === undefined || typeof payload !== 'object') return;
    const p = payload as Record<string, Object>;
    const sessionId = readStr(p, 'sessionId');
    if (sessionId.length === 0 || readStr(p, 'status') !== 'closed') return;
    if (!this.acceptDeviceScopedSessionEvent(sessionId, deviceId)) return;
    this.consumePendingTextDeltaNotification(sessionId);
    this.bumpRunningStateRevision(sessionId);
    this.makerTurnRunningBySession.delete(sessionId);
    this.finalizeSessionStreaming(sessionId);
    this.notify();
  }

  /** maker:event 之外的 sessions 活动态是漏终态时的第二条收口路径。 */
  handleSessionActivity(payload: Object | undefined, deviceId: string = ''): void {
    if (payload === undefined || typeof payload !== 'object') return;
    const p = payload as Record<string, Object>;
    const sessionId = readStr(p, 'sessionId');
    if (sessionId.length === 0) return;
    if (!this.acceptDeviceScopedSessionEvent(sessionId, deviceId)) return;
    this.consumePendingTextDeltaNotification(sessionId);
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
  private async refreshSessionRunningState(
    deviceId: string,
    sessionId: string,
    expectedLease: number,
  ): Promise<void> {
    const existing = this.runningStateOperations.get(sessionId);
    if (existing !== undefined) {
      await existing;
      return;
    }
    const operation = this.refreshSessionRunningStateOnce(deviceId, sessionId, expectedLease);
    this.runningStateOperations.set(sessionId, operation);
    try {
      await operation;
    } finally {
      if (this.runningStateOperations.get(sessionId) === operation) {
        this.runningStateOperations.delete(sessionId);
      }
    }
  }

  private async refreshSessionRunningStateOnce(
    deviceId: string,
    sessionId: string,
    expectedLease: number,
  ): Promise<void> {
    const client = this.client;
    if (!client) return;
    const recoveryGeneration = this.recoveryGeneration;
    const revision = this.runningStateRevisions.get(sessionId) ?? 0;
    const opts = new DlInvokeOptions();
    opts.channel = DlChannels.MAKER_SESSION_IN_TURN;
    opts.args = [sessionId];
    try {
      const env = await client.invoke(deviceId, opts);
      if (recoveryGeneration !== this.recoveryGeneration) return;
      if (!this.sessionLeaseCurrent(sessionId, deviceId, expectedLease)) return;
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
    this.setSessionMessages(sessionId, existing);
    this.notify();
  }

  /** 当前流式消息（无则 undefined）。 */
  getStreaming(sessionId: string, deviceId: string = ''): StreamingMessage | undefined {
    if (!this.sessionReadAllowed(sessionId, deviceId)) return undefined;
    return this.streamingBySession.get(sessionId);
  }

  /**
   * 历史消息 + 流式临时消息（正文/工具行）合并，供渲染模型统一构建。
   * 流式工具行走 tool_use 角色 → buildRenderItems 自然产出 tool_group；
   * 流式正文走 assistant 角色 → 与历史消息同路径，thinking/tool 组由
   * work_group 聚合规则收进折叠面板。
   */
  getMessagesWithStreaming(sessionId: string, deviceId: string = ''): RemoteMessage[] {
    if (!this.sessionReadAllowed(sessionId, deviceId)) return [];
    this.touchSessionCache(sessionId);
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
  private clearStreamingIfAssistant(sessionId: string, message: RemoteMessage): boolean {
    if (message.role !== 'assistant') {
      return false;
    }
    const streaming = this.streamingBySession.get(sessionId);
    if (streaming === undefined) return false;
    if (streaming.persistId.length > 0
      && message.id !== streaming.persistId
      && message.clientId !== streaming.persistId) return false;
    return this.streamingBySession.delete(sessionId);
  }

  private async loadInitial(
    deviceId: string,
    sessionId: string,
    expectedLease: number,
  ): Promise<boolean> {
    const client = this.client;
    if (!client) return false;
    const messageRevision = this.authoritativeMessageRevisions.get(sessionId) ?? 0;
    try {
      // 对齐 iOS：历史走 local-db:messages:list（返回完整行含 clientId，最新在前）。
      const page = await this.requestMessagesList(deviceId, sessionId, HISTORY_PAGE_LIMIT, '');
      if (!this.sessionLeaseCurrent(sessionId, deviceId, expectedLease)) {
        return false;
      }
      page.items.sort(sortMessagesAsc);
      const streaming = this.streamingBySession.get(sessionId);
      this.deferredAuthoritativeEmptySessions.update(sessionId,
        shouldDeferAuthoritativeEmptyWindow(
          page.items.length,
          streaming !== undefined && !streaming.finished,
          messageRevision,
          this.authoritativeMessageRevisions.get(sessionId) ?? 0,
        ));
      const merged = this.applyLatestWindow(sessionId, page);
      this.setOlderAvailability(
        sessionId, this.hasMoreAfterPage(sessionId, page, merged));
      this.loadFailedBySession.delete(sessionId);
      this.notify();
      return true;
    } catch (e) {
      if (!this.sessionLeaseCurrent(sessionId, deviceId, expectedLease)) {
        return false;
      }
      // 加载失败：标记失败（页面提供重试），不保持空列表假装成功。
      const msg = safeErrorMessage(e);
      hilog.warn(DOMAIN, TAG, 'loadInitial failed session=%{public}s err=%{public}s',
        sessionId.slice(0, 8), msg);
      this.loadFailedBySession.set(sessionId, true);
      this.notify();
      return false;
    }
  }

  /** 破坏性消息操作完成后重拉当前整窗，避免旧分页与服务端截断结果混合。 */
  async reloadSession(deviceId: string, sessionId: string): Promise<boolean> {
    if (!this.sessionReadAllowed(sessionId, deviceId)) return false;
    const lease = this.currentSessionLease(deviceId, sessionId);
    if (lease < 0) return false;
    this.historyHealGenerations.set(sessionId,
      (this.historyHealGenerations.get(sessionId) ?? 0) + 1);
    this.consideredHistoryGaps.delete(sessionId);
    this.historyCoverageBySession.delete(sessionId);
    this.removeSessionMessages(sessionId, true);
    this.deferredAuthoritativeEmptySessions.cancel(sessionId);
    this.pendingStreamingProjectionKeysBySession.delete(sessionId);
    return this.loadInitial(deviceId, sessionId, lease);
  }

  /** Pi 分支切换后的权威替换；旧分支消息不能与新窗口 merge。 */
  async replaceSessionWindow(deviceId: string, sessionId: string): Promise<boolean> {
    if (!this.sessionReadAllowed(sessionId, deviceId)) return false;
    const generation = (this.historyHealGenerations.get(sessionId) ?? 0) + 1;
    this.historyHealGenerations.set(sessionId, generation);
    this.consideredHistoryGaps.delete(sessionId);
    this.historyCoverageBySession.delete(sessionId);
    try {
      const page = await this.requestMessagesList(deviceId, sessionId, HISTORY_PAGE_LIMIT, '');
      if ((this.historyHealGenerations.get(sessionId) ?? 0) !== generation
        || this.subscribed.get(sessionId) !== deviceId) return false;
      page.items.sort(sortMessagesAsc);
      const reconciled = reconcileLatestMessageWindow(
        [], page.items, page.hasMore, null, this.subscriptionAckedSessions.has(sessionId));
      this.setSessionMessages(sessionId, reconciled.items);
      if (reconciled.coverage !== null) this.historyCoverageBySession.set(sessionId, reconciled.coverage);
      this.setOlderAvailability(
        sessionId, this.hasMoreAfterPage(sessionId, page, page.items));
      this.streamingBySession.delete(sessionId);
      this.deferredAuthoritativeEmptySessions.cancel(sessionId);
      this.pendingStreamingProjectionKeysBySession.delete(sessionId);
      this.markSessionRunning(sessionId, false);
      this.makerTurnRunningBySession.delete(sessionId);
      this.loadFailedBySession.delete(sessionId);
      this.notify();
      return true;
    } catch (e) {
      return false;
    }
  }

  /**
   * 向上翻页：与 Mobile/iOS 一样，一次请求合并一整页持久化消息行。
   * 渲染层会在 prepend 后重新聚合被页边界切开的 work group；数据层不能再把
   * 一页人为拆成“一次只露出一轮”，否则长工具轮次会让用户反复撞顶。
   */
  async loadOlder(deviceId: string, sessionId: string): Promise<number> {
    const client = this.client;
    if (!client) return 0;
    if (!this.sessionReadAllowed(sessionId, deviceId)) return 0;
    if (!this.hasMore(sessionId, deviceId)) return 0;
    const generation = this.historyHealGenerations.get(sessionId) ?? 0;
    const current = this.messagesBySession.get(sessionId) ?? [];
    const before = oldestMessageCursor(current);
    if (before.length === 0) return 0;
    try {
      const page = await this.requestMessagesList(
        deviceId, sessionId, HISTORY_PAGE_LIMIT, before);
      if ((this.historyHealGenerations.get(sessionId) ?? 0) !== generation
        || this.subscribed.get(sessionId) !== deviceId) return 0;
      page.items.sort(sortMessagesAsc);

      // 请求期间可能有实时尾部 push；最终 merge 使用最新窗口且只 notify 一次。
      const latestCurrent = this.messagesBySession.get(sessionId) ?? current;
      const merged = this.mergeWithoutDuplicates(page.items, latestCurrent);
      merged.sort(sortMessagesAsc);
      this.setSessionMessages(sessionId, merged);
      const coverage = extendCoverageEarlier(
        this.historyCoverageBySession.get(sessionId) ?? null,
        page.items,
        latestCurrent.length > 0 ? latestCurrent[0] : null);
      if (coverage !== null) this.historyCoverageBySession.set(sessionId, coverage);
      this.setOlderAvailability(
        sessionId, this.hasMoreAfterPage(sessionId, page, merged, false));
      const added = Math.max(0, merged.length - latestCurrent.length);
      hilog.info(DOMAIN, TAG,
        'history page merged fetched=%{public}d added=%{public}d hasMore=%{public}s',
        page.items.length, added,
        this.hasMore(sessionId, deviceId) ? 'true' : 'false');
      this.notify();
      return added;
    } catch (e) {
      const msg = safeErrorMessage(e);
      hilog.warn(DOMAIN, TAG, 'history older failed session=%{public}s err=%{public}s',
        sessionId.slice(0, 8), msg);
      throw (e instanceof Error ? e : new Error(msg));
    }
  }

  private setOlderAvailability(sessionId: string, sourceHasMore: boolean): void {
    this.hasMoreBySession.set(sessionId, sourceHasMore);
  }

  /**
   * Mobile 同源判定：满页 / remoteRowsTrimmed / 服务端总数均说明上沿还有历史。
   * 首次最新窗口允许用已知总数辅助推断；真实向前分页的短页按 iOS 语义视为
   * 历史到底，避免尾部新消息增长把顶部入口重新点亮。
   */
  private hasMoreAfterPage(
    sessionId: string,
    page: HistoryPage,
    merged: RemoteMessage[],
    allowMessageCountInference: boolean = true,
  ): boolean {
    if (shouldKeepOlderMessagesAffordance(page.items.length, page.hasMore)) return true;
    if (!allowMessageCountInference || page.items.length === 0) return false;
    const total = this.messageCountBySession.get(sessionId) ?? 0;
    if (total > countRealMessages(merged)) return true;
    return false;
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
        lastError = e instanceof Error ? e : new Error(safeErrorMessage(e));
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
            const msg = safeErrorMessage(e);
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
    }).catch((e: Object | undefined) => {
      // invoke 失败（网络 / 桌面端 IPC 错误）：记录确切原因供排查。
      hilog.warn(DOMAIN, TAG, 'messages:list failed session=%{public}s err=%{public}s',
        sessionId.slice(0, 8), safeErrorMessage(e));
      throw e instanceof Error ? e : new Error(safeErrorMessage(e));
    });
  }

  // ─── push 增量 ──────────────────────────────────────────────────────────────

  handleSessionPush(deviceId: string, channel: string, payload: Object | undefined): void {
    if (payload !== undefined && typeof payload === 'object' && !Array.isArray(payload)) {
      const sessionId = readStr(payload as Record<string, Object>, 'sessionId');
      if (sessionId.length > 0) {
        // authority fence：设备身份不符的实时帧一律丢弃，不更新窗口、缓存归属或订阅状态。
        // 快速 A → B → A 切换时，B 的迟到 push 不得写进 A 的窗口。
        if (!this.acceptDeviceScopedSessionEvent(sessionId, deviceId)) return;
      }
    }
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
          void this.loadInitial(deviceId, sessionId, this.currentSessionLease(deviceId, sessionId));
        }
        break;
      }
      case 'local-db:sessions:activity':
        this.handleSessionActivity(payload, deviceId);
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
    let message: RemoteMessage;
    try {
      message = parseMessage(rawMessage);
    } catch (e) {
      // 单条异常 push 不能中断同一连接上的其它消息；历史列表也采用同样的
      // best-effort 解析语义。
      const error = safeErrorMessage(e);
      hilog.warn(DOMAIN, TAG, 'skip unparsable created message session=%{public}s err=%{public}s',
        sessionId.slice(0, 8), error);
      return;
    }
    if (message.id.length === 0) return;
    this.consumePendingTextDeltaNotification(sessionId);
    this.authoritativeMessageRevisions.set(sessionId,
      (this.authoritativeMessageRevisions.get(sessionId) ?? 0) + 1);
    this.deferredAuthoritativeEmptySessions.cancel(sessionId);
    this.discardPendingStreamingProjection(sessionId, message);
    let list = this.messagesBySession.get(sessionId);
    if (!list) {
      // push 可能早于首次历史加载到达：先建列表，loadInitial 会合并去重。
      const fresh: RemoteMessage[] = [];
      fresh.push(message);
      fresh.sort(sortMessagesAsc);
      this.setSessionMessages(sessionId, fresh);
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
      this.setSessionMessages(sessionId, list);
    }
    const existingIndex = list.findIndex((m: RemoteMessage) =>
      m.id === message.id || (message.clientId.length > 0 && m.clientId === message.clientId));
    if (existingIndex >= 0) {
      let changed = false;
      if (preferIncomingCreatedMessage(list[existingIndex], message)) {
        mergeAgentTaskTerminalStatus(list[existingIndex], message, true);
        list[existingIndex] = message;
        list.sort(sortMessagesAsc);
        this.setSessionMessages(sessionId, list);
        changed = true;
      } else if (list[existingIndex].agentTaskStatus.length === 0
        && message.agentTaskStatus.length > 0) {
        list[existingIndex].agentTaskStatus = message.agentTaskStatus;
        list[existingIndex].agentMeta['agentTaskStatus'] = message.agentTaskStatus;
        this.setSessionMessages(sessionId, list);
        changed = true;
      }
      changed = this.clearStreamingIfAssistant(sessionId, message) || changed;
      if (changed) this.notify();
      return;
    }
    list.push(message);
    list.sort(sortMessagesAsc);
    this.setSessionMessages(sessionId, list);
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
    this.consumePendingTextDeltaNotification(sessionId);
    this.authoritativeMessageRevisions.set(sessionId,
      (this.authoritativeMessageRevisions.get(sessionId) ?? 0) + 1);
    this.deferredAuthoritativeEmptySessions.cancel(sessionId);
    this.historyCoverageBySession.delete(sessionId);
    const list = this.messagesBySession.get(sessionId);
    if (!list) return;
    const filtered = list.filter((m: RemoteMessage) => !clientIds.includes(m.clientId));
    if (filtered.length !== list.length) {
      this.setSessionMessages(sessionId, filtered);
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
      const message = safeErrorMessage(e);
      const scheme = url.split('://')[0];
      hilog.warn(DOMAIN, TAG, 'media fetch failed scheme=%{public}s err=%{public}s', scheme, message);
      if (e instanceof Error) {
        throw e;
      }
      throw new Error(message);
    }
  }

  /** 读取被控端绝对路径的文本预览；与 Mobile 的公开通道同源。 */
  async readTextFilePreview(deviceId: string, filePath: string): Promise<Record<string, Object>> {
    const client = this.client;
    if (!client) return Promise.reject(new Error('client not attached'));
    const request: Record<string, Object> = {};
    request['filePath'] = filePath;
    const opts = new DlInvokeOptions();
    opts.channel = DlChannels.TEXT_FILE_READ_PREVIEW;
    opts.args = [request];
    const env = await client.invoke(deviceId, opts);
    const result = unwrapInvokeResult(env);
    if (result === undefined || result === null || typeof result !== 'object' || Array.isArray(result)) {
      throw new Error('text-file:read-preview returned an invalid result');
    }
    return result as Record<string, Object>;
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
    const lease = this.currentSessionLease(deviceId, session.id);
    if (lease >= 0) await this.loadInitial(deviceId, session.id, lease);
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
    if (!this.sessionReadAllowed(sessionId, deviceId)) return;
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
    this.setSessionMessages(sessionId, messages);
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
    if (!this.sessionReadAllowed(sessionId, deviceId)) return [];
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
      this.setSessionMessages(sessionId, next);
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
      const current = byId.get(key);
      if (current === undefined) {
        byId.set(key, m);
      } else {
        const beforeStatus = current.agentTaskStatus;
        mergeAgentTaskTerminalStatus(current, m, false);
        if (beforeStatus.length === 0 && m.agentTaskStatus.length > 0) {
          current.agentTaskStatus = m.agentTaskStatus;
          current.agentMeta['agentTaskStatus'] = m.agentTaskStatus;
        }
      }
    }
    const out: RemoteMessage[] = [];
    byId.forEach((m: RemoteMessage) => {
      out.push(m);
    });
    return out;
  }

  private applyLatestWindow(sessionId: string, page: HistoryPage): RemoteMessage[] {
    // 最新窗重拉会重新裁定连续区间；已上翻的连续旧窗由 reconcile 保留。
    if (page.items.length === 0) {
      const streaming = this.streamingBySession.get(sessionId);
      if (streaming !== undefined && shouldPreserveCachedMessagesForAuthoritativeEmpty(
        page.items.length, !streaming.finished)
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
    this.setSessionMessages(sessionId, reconciled.items);
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
    const message = messages[i];
    const id = message.id;
    if (message.localOnly || id.length === 0 || isSyntheticMessageId(id)) {
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

/** 请求期间若有新 push，返回的旧空窗口不能进入延迟清窗。 */
export function shouldDeferAuthoritativeEmptyWindow(
  authoritativeRows: number,
  hasLiveProjection: boolean,
  requestMessageRevision: number,
  currentMessageRevision: number,
): boolean {
  return shouldPreserveCachedMessagesForAuthoritativeEmpty(
    authoritativeRows, hasLiveProjection)
    && requestMessageRevision === currentMessageRevision;
}

export function shouldPreserveCachedMessagesForAuthoritativeEmpty(
  authoritativeRows: number,
  hasLiveProjection: boolean,
): boolean {
  return authoritativeRows === 0 && hasLiveProjection;
}

/**
 * live turn 终态后应用此前延迟的权威空窗：清理旧服务端行，同时保留本地卡片与
 * 本轮尚未等到 DB push 的最终临时投影。
 */
export function reconcileDeferredAuthoritativeEmptyMessages(
  current: RemoteMessage[],
  protectedProjectionKeys: Set<string>,
): RemoteMessage[] {
  const reconciled = reconcileLatestMessageWindow(current, [], false, null, false);
  const byKey = new Map<string, RemoteMessage>();
  for (let i = 0; i < reconciled.items.length; i++) {
    byKey.set(messageIdentity(reconciled.items[i]), reconciled.items[i]);
  }
  for (let i = 0; i < current.length; i++) {
    const message = current[i];
    const key = messageIdentity(message);
    if ((message.localOnly || protectedProjectionKeys.has(key)) && !byKey.has(key)) {
      byKey.set(key, message);
    }
  }
  const out: RemoteMessage[] = [];
  byKey.forEach((message: RemoteMessage) => out.push(message));
  out.sort(sortMessagesAsc);
  return out;
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
