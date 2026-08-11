/**
 * 任务详情页：按渲染模型展示消息流 + Composer。
 *
 * 消息流由 MessageRender.buildRenderItems 构建（tool 配对 / thinking /
 * todo 卡 / 系统消息），正文走 MarkdownParser 渲染为 ArkUI 原生组件。
 * - thinking 默认折叠，点击展开；
 * - tool_group 默认展开，点击折叠；
 * - 消息动作（复制/Fork/Rewind）在切片 2.3 接入。
 *
 * 视觉与运行时选项解析复用 components/UiKit 与 core/ComposerCatalog，
 * 图片附件流转复用 core/attachments/ComposerImageQueue。
 */

import { LengthMetrics, router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { accessibility } from '@kit.AccessibilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { PhotoPickerComponent, PickerController, PickerOptions, DataType } from '@kit.MediaLibraryKit';
import { AppServices } from '../core/AppServices';
import { presignGet } from '../core/attachments/AttachmentUpload';
import {
  RemoteImageRef,
  RemoteMediaFetchResult,
  RemoteSerializedAttachment,
} from '../core/attachments/AttachmentModels';
import { parseAttachmentOssRef } from '../core/attachments/AttachmentOssRef';
import { ComposerImageQueue, MAX_COMPOSER_IMAGES, createRecentPickerOptions } from '../core/attachments/ComposerImageQueue';
import { ComposerFile, ComposerFileQueue } from '../core/attachments/ComposerFileQueue';
import {
  AskUserDraft,
  PendingInteraction,
  PlanReviewDraft,
} from '../core/interactions/InteractionStore';
import {
  AskOptionPresentation,
  PlanOutlinePresentation,
  PlanReviewEvidencePresentation,
  askOptionPresentations,
  buildPlanReviewEvidence,
  buildPermissionDecision,
  interactionKindLabel,
  pendingInteractionsBlockRemoteComposer,
  permissionCanAlwaysAllow,
  permissionRequestFingerprint,
  permissionRiskSummary,
  sortPendingInteractions,
} from '../core/interactions/InteractionPresentation';
import { DlInvokeOptions } from '../core/device-link/DlClient';
import { GoalModeState } from '../core/goals/GoalModels';
import { GoalStartOptions } from '../core/goals/GoalStore';
import { ComposerImage, ConversationComposer } from '../components/ConversationComposer';
import {
  UI_CLICK_EFFECT,
  UI_ICON_CLICK_EFFECT,
  UI_LIST_CLICK_EFFECT,
  UI_CURVE_MOVE,
  UI_MOTION_FAST,
  UI_MOTION_SPINNER_CYCLE,
  UI_RADIUS_CONTAINER,
  UI_RADIUS_CONTROL,
  UI_RADIUS_PILL,
  uiAnimateFastState,
  uiAnimateState,
  uiFontSize,
  uiLineHeight,
  uiOverlayTransition,
  uiRevealTransition,
} from '../components/UiKit';
import {
  ComposerChoiceOption,
  ComposerModelOption,
  ModelSelectionHint,
  ProviderListOptions,
  composerModelKey,
  effortLevelLabel,
  modelProviderKind,
  parseChoiceOptions,
  parseModelOptions,
  parseModelVisibilityOverrides,
  parseProviderModelOptions,
  permissionModeDescription,
} from '../core/ComposerCatalog';
import { SessionMetaPatch, unwrapInvokeResult } from '../core/tasks/TaskStore';
import { RemoteSession, readBool, readNum, readObj, readStr, recordOrEmpty } from '../core/tasks/TaskModels';
import {
  NewSessionCreationTask,
  shouldBlockNewSessionRemoteOperation,
} from '../core/tasks/NewSessionCreationStore';
import {
  PiSessionTreeNode,
  PiSessionTreeSnapshot,
  parsePiNavigateResult,
  parsePiSessionTree,
} from '../core/tasks/PiSessionTree';
import {
  SessionAgentSwitchIntent,
  parseSessionAgentSwitchIntent,
  supportsSessionAgentSwitch,
} from '../core/tasks/SessionAgentSwitch';
import {
  RenderItem, RenderMessageItem, RenderThinkingItem,
  RenderToolGroupItem, RenderToolItem, RenderToolMediaItem, RenderTodoCardItem, RenderTodoItem,
  RenderWorkGroupItem, RenderTextSegment, RenderAgentTaskItem, RenderSubagentGroupItem,
  buildRenderItems, summarizeText, collapsedUserMessageLineLimit,
  todoCardContentSignature, todoCardIndexAtRankFromTail, todoCardRankFromTail,
} from '../core/messages/MessageRender';
import {
  RenderDiffPayload,
  RenderDiffSegment,
  RenderMediaPayload,
} from '../core/messages/MessagePayload';
import {
  MdBlock, tokenizeInline, InlineToken, InlineTokenGroup, groupInlineTokens,
} from '../core/messages/MarkdownParser';
import { buildMarkdownTableColumnWidths } from '../core/messages/MarkdownTableLayout';
import {
  MessageSearchHit,
  MessageSearchPagingPresentation,
  findMessageSearchHits,
  messageSearchPagingPresentation,
  nextMessageSearchIndex,
  reconcileMessageSearchIndex,
} from '../core/messages/MessageSearch';
import {
  PendingQueueBubble,
  QueuedInputItem,
} from '../core/messages/InputQueueStore';
import { RewindPreview } from '../core/messages/MessageStore';
import { deriveAgentTaskStatus } from '../core/messages/AgentTaskStore';
import {
  AutoResumePresentation,
  appendAutoResumePendingMessage,
  deriveAutoResumePresentation,
} from '../core/messages/AutoResumePresentation';
import {
  SystemCardPresentation,
  SystemCardRow,
  deriveSystemCardPresentation,
} from '../core/messages/SystemCardPresentation';
import {
  LearnCommandMatch,
  buildLearnStartRequest,
  parseLearnCommand,
} from '../core/messages/LearnCommand';
import {
  CONTINUE_AFTER_APP_EXIT_PROMPT,
  CONTINUE_AFTER_ERROR_PROMPT,
  SessionTailPresentation,
  deriveSessionTailPresentation,
  isContinuationText,
} from '../core/messages/SessionTailPresentation';
import {
  formatSessionActivityElapsed,
  sessionActivityElapsedMs,
} from '../core/messages/SessionActivityPresentation';
import {
  firstVisibleMessageRenderIndex,
  FOLLOW_LATEST_RETRY_DELAYS,
  INITIAL_HISTORY_AUTOFILL_PAGES,
  messageListBottomIndex,
  messageListRenderNodeKey,
  shouldAutoLoadEarlier,
} from './TaskScrollState';
import {
  ComposerDocument,
  ComposerAtomPresentation,
  ComposerNode,
  SerializedComposerDocument,
  composerDocumentHasContent,
  composerDocumentFromPersistedContent,
  composerDocumentProjectedText,
  composerAtomPresentations,
  emptyComposerDocument,
  isLongComposerPaste,
  pastedTextNode,
  mentionNode,
  reconcileComposerProjectedText,
  removeComposerNode,
  replaceComposerTextRange,
  serializeComposerDocument,
  slashCommandNode,
  textComposerDocument,
  textNode,
} from '../core/messages/ComposerDocument';
import {
  RemoteMediaResolveIntent,
  RemoteMediaViewState,
  beginManualMediaRetry,
  beginNativeMediaRecovery,
  beginRemoteMediaResolve,
  failNativeMediaLoad,
  remoteMediaResolveFailed,
  remoteMediaResolveReady,
} from '../core/messages/RemoteMediaState';
import { AgentTaskUpdate, WorkflowProgressEntry } from '../core/messages/AgentTaskStore';
import {
  ToolActionPresentation,
  projectToolUseActions,
} from '../core/messages/ToolUsePresentation';
import {
  WorkPreviewRow,
  workExplorationSummary,
  workPreviewRows,
} from '../core/messages/WorkGroupPresentation';

const TODO_STATUS_ICON_SIZE = 13;
const TODO_STATUS_STROKE_WIDTH = 1.25;
const TODO_STATUS_CHECKMARK_SIZE = 9;
const TODO_STATUS_ACTIVE_DOT_SIZE = 4;
const TODO_STATUS_SPINNER_DASH: number[] = [24, 16];
const TODO_STATUS_FRAME_RATE: ExpectedFrameRateRange = {
  min: 60,
  max: 120,
  expected: 120,
};

/** 步骤状态统一使用 13vp 可见外径；只旋转外层，圆弧几何保持静态。 */
@Component
struct TodoRunningStatusIcon {
  @State rotation: number = 0;
  private reduceMotion: boolean = false;

  aboutToAppear(): void {
    try {
      this.reduceMotion = accessibility.isAnimationReduceEnabledSync();
    } catch (_err) {
      this.reduceMotion = false;
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Circle()
        .width(TODO_STATUS_ICON_SIZE)
        .height(TODO_STATUS_ICON_SIZE)
        .fill(Color.Transparent)
        .stroke($r('app.color.text_secondary'))
        .strokeWidth(TODO_STATUS_STROKE_WIDTH)
        .strokeDashArray(TODO_STATUS_SPINNER_DASH)
        .strokeLineCap(LineCapStyle.Round)
    }
    .width(TODO_STATUS_ICON_SIZE)
    .height(TODO_STATUS_ICON_SIZE)
    .rotate({ angle: this.rotation })
    .animation({
      duration: UI_MOTION_SPINNER_CYCLE,
      curve: Curve.Linear,
      iterations: -1,
      expectedFrameRateRange: TODO_STATUS_FRAME_RATE,
    })
    .onAppear(() => {
      if (!this.reduceMotion) this.rotation = 360;
    })
  }
}

class ComposerPaletteItem {
  kind: string = '';
  name: string = '';
  description: string = '';
  relPath: string = '';
}

class PiTreeRow {
  node: PiSessionTreeNode = new PiSessionTreeNode();
  depth: number = 0;
}

const MODEL_AGENT_KINDS: string[] = ['claude-code', 'codex', 'pi'];

function modelAgentLabel(kind: string): string {
  if (kind === 'claude-code' || kind === 'cc') return 'Claude';
  if (kind === 'codex') return 'Codex';
  return 'Pi';
}

function modelAgentId(kind: string): string {
  return kind === 'cc' ? 'claude-code' : kind;
}
function queryValue(query: string, key: string): string {
  const pairs = query.split('&');
  for (let i = 0; i < pairs.length; i++) {
    const eq = pairs[i].indexOf('=');
    if (eq <= 0 || pairs[i].slice(0, eq) !== key) continue;
    try {
      return decodeURIComponent(pairs[i].slice(eq + 1));
    } catch (e) {
      return '';
    }
  }
  return '';
}

function isAbsoluteMediaPath(value: string): boolean {
  return value.startsWith('/') || /^[A-Za-z]:[\\/]/.test(value) || value.startsWith('\\\\');
}

function normalizeImageUrlScheme(value: string): string {
  return value.replace(
    /^(https?|data|xdt-image|cindy-media|xdt-file|file|cindy-oss-attach|xdt-oss-attach):/i,
    (scheme: string) => scheme.toLowerCase(),
  );
}

function isImageMimeType(value: string): boolean {
  return value.toLowerCase().startsWith('image/');
}


@Component
export struct TaskPageContent {
  /** 宽屏双栏中由父页面传入；为空时沿用独立详情页的路由参数。 */
  @Prop paneDeviceId: string = '';
  @Prop paneSessionId: string = '';
  @Prop paneMessageClientId: string = '';
  @State items: RenderItem[] = [];
  @State input: string = '';
  /** TextArea 只是这一语义文档的投影。 */
  private composerDocument: ComposerDocument = new ComposerDocument();
  private composerDraftGeneration: number = 0;
  @State sending: boolean = false;
  /** Desktop 输入投影产生的排队/派发/失败气泡。 */
  @State queueBubbles: PendingQueueBubble[] = [];
  @State queuePaused: boolean = false;
  @State queueProjectionError: string = '';
  @State queueErrorRetryText: string = '';
  @State queueCredentialWaiting: boolean = false;
  @State queueCredentialBlockedCount: number = 0;
  @State queueAbortPending: boolean = false;
  @State queueInteractionLocked: boolean = false;
  @State queueBusy: boolean = false;
  private interactionSessionActivated: boolean = false;
  /** 新任务后台创建态；running/create-failed 期间详情页不得发普通 session RPC。 */
  @State newSessionCreationStatus: string = '';
  @State newSessionCreationError: string = '';
  @State newSessionCreationClientId: string = '';
  @State selectedQueueClientId: string = '';
  @State editingQueueClientId: string = '';
  private stashedComposerInput: string = '';
  private stashedComposerDocument: ComposerDocument = new ComposerDocument();
  private editingQueueOriginalText: string = '';
  @State error: string = '';
  @State loadFailed: boolean = false;
  /** 首次历史请求已经结束；空任务据此从“正在同步”切到真实空态。 */
  @State initialLoadResolved: boolean = false;
  /** 空列表请求超过 200ms 后才显形，避免快速本地读取闪一下 loading。 */
  @State showInitialSync: boolean = false;
  /** 会话仍在流式生成；驱动 Header、Composer 和消息尾部状态。 */
  @State sessionStreaming: boolean = false;
  /** 真实消息区宽度；折叠双栏下不能拿整块屏幕宽度估算 Markdown 表格。 */
  @State messageAreaWidth: number = 0;
  private tableColumnWidthCache: Map<MdBlock, number[]> = new Map();
  /** 用户是否仍明确跟随消息尾部。 */
  @State followingLatest: boolean = true;
  /** 离底期间收到尾部更新时，在回到底部浮标上显示提示点。 */
  @State hasNewMessages: boolean = false;
  /** Composer 焦点态切换为多行卡片几何。 */
  @State composerFocused: boolean = false;
  /** 会话内本地搜索；Header 搜索按钮展开紧凑搜索栏。 */
  @State searchOpen: boolean = false;
  @State searchQuery: string = '';
  @State searchActiveIndex: number = 0;
  @State searchActiveSourceKey: string = '';
  @State focusedSearchItemKey: string = '';
  @State focusedMessageClientId: string = '';
  @State tailHiddenErrorClientIds: string[] = [];
  @State tailInterruptAcked: boolean = false;
  @State tailBannerBusy: boolean = false;
  /** thinking 展开的 key（默认折叠）。 */
  @State expandedThinking: string[] = [];
  /** tool_group 折叠的 key（默认展开）。 */
  /** work_group 展开的 key（默认折叠）。 */
  @State expandedWorkGroups: string[] = [];
  /** todo 默认展开；这里只记录用户主动收起的 key。 */
  @State collapsedTodoCards: string[] = [];
  /** 单条工具结果展开 key（默认折叠）。 */
  @State expandedTools: string[] = [];
  /** user 长文本块展开的 key（默认折叠）。 */
  @State expandedTextBlocks: string[] = [];
  private deviceId: string = '';
  private sessionId: string = '';
  private unsubs: Array<() => void> = [];
  private listScroller: Scroller = new Scroller();
  private initialScrolled: boolean = false;
  /** 初始列表仍在布局/补齐历史时，禁止 onReachStart 抢走底部锚点。 */
  private initialScrollSettling: boolean = true;
  private initialScrollGeneration: number = 0;
  /** 流式贴底补滚代次；会话切换/主动跳转时作废上一轮布局重试。 */
  private followScrollGeneration: number = 0;
  private followScrollScheduled: boolean = false;
  private followScrollTrailingRequested: boolean = false;
  private initialLoadGeneration: number = 0;
  private sessionOpenResolved: boolean = false;
  private sessionSyncStarted: boolean = false;
  private routeMessageClientId: string = '';
  private messageFocusGeneration: number = 0;
  private messageFocusLoadStarted: boolean = false;
  private inputQueueActivated: boolean = false;
  private creationDraftHandoffDone: boolean = false;
  private leavingForCreationEdit: boolean = false;
  /** 加载更早消息进行中（防重复触发，并驱动列表头入口）。 */
  @State loadingOlder: boolean = false;
  /** Store 的分页结论镜像为响应式状态，确保短页落地后顶部入口立即消失。 */
  @State hasOlderMessages: boolean = false;
  /** List 当前可见的首尾渲染项，用于贴底意图和历史分页。 */
  private visibleStartIndex: number = 0;
  private visibleEndIndex: number = -1;
  /** 单条/短首屏无法产生 List 滚动索引时，用真实手势触发一次历史分页。 */
  private listTouchStartY: number = 0;
  private listTouchActive: boolean = false;
  /** 当前手势是否明确表达了“向下回看更早消息”的意图。 */
  private listTouchPulledDown: boolean = false;
  /** 当前手势是否明确向消息尾部移动。 */
  private listTouchPushedUp: boolean = false;
  private listTouchLoadTriggered: boolean = false;
  private historyReviewIntent: boolean = false;
  /** 冷开短窗口的剩余自动补页次数；真实上翻后不再受此预算限制。 */
  private initialHistoryAutofillRemaining: number = INITIAL_HISTORY_AUTOFILL_PAGES;
  private historyLastAttemptFirstKey: string = '';
  /** 新手势、跳尾或离页会作废尚未执行的历史锚点恢复。 */
  private historyAnchorRestoreGeneration: number = 0;
  /** 快速响应撞上手指仍按住时，等 Touch Up 再恢复，不丢弃整页锚点。 */
  private pendingHistoryAnchorRestore: (() => void) | undefined = undefined;
  /** 待发送图片（上传状态，由共享队列同步镜像）。 */
  @State composerImages: ComposerImage[] = [];
  @State pickingImages: boolean = false;
  private imageQueue: ComposerImageQueue = new ComposerImageQueue();
  @State composerFiles: ComposerFile[] = [];
  @State pickingFiles: boolean = false;
  private fileQueue: ComposerFileQueue = new ComposerFileQueue();
  /** 发送开始后的输入变更不会被旧请求的成功回调清空。 */
  private composerInputRevision: number = 0;
  /** Composer 加号的原生上下文 Sheet。 */
  @State contextSheetOpen: boolean = false;
  @State contextSheetPage: string = 'main';
  @State contextSelectedUris: string[] = [];
  /** 详情页任务菜单沿用列表页同一套受控操作，不依赖系统 ActionSheet 的不透明状态。 */
  @State sessionActionOpen: boolean = false;
  @State sessionRenameMode: boolean = false;
  @State sessionRenameDraft: string = '';
  @State sessionActionBusy: boolean = false;
  @State sessionTreeOpen: boolean = false;
  @State sessionTreeLoading: boolean = false;
  @State sessionTreeSwitchingId: string = '';
  @State sessionTreeError: string = '';
  @State sessionTree: PiSessionTreeSnapshot | null = null;
  private sessionTreeGeneration: number = 0;
  /** iOS 风格消息操作层：空 key 表示关闭。 */
  @State messageActionItemKey: string = '';
  @State messageActionBusyId: string = '';
  @State composerPaletteMode: string = '';
  @State composerPaletteItems: ComposerPaletteItem[] = [];
  @State composerPaletteLoading: boolean = false;
  private composerPaletteFrom: number = 0;
  private composerPaletteQuery: string = '';
  private composerPaletteGeneration: number = 0;
  /** 同名 Agent Skill 被明确选择时，下一次 `/learn` 让行给 Agent。 */
  private selectedLearnRoute: string = '';
  @State planModeSupported: boolean = false;
  @State planModeEnabled: boolean = false;
  @State permissionOptions: ComposerChoiceOption[] = [];
  @State modelOptions: ComposerModelOption[] = [];
  /** 被控端 provider:list 的真实目录；为空时才回退 capabilities.availableModels。 */
  @State providerModelOptions: ComposerModelOption[] = [];
  @State providerModelAgent: string = '';
  @State modelVisibilityOverrides: Map<string, boolean> = new Map();
  @State effortOptions: ComposerChoiceOption[] = [];
  @State fastModeCapability: boolean = false;
  /** 模型浮窗可以浏览其它 Agent 的能力目录；选中后走真实 agent-switch RPC。 */
  @State modelAgentTab: string = '';
  @State modelSearchQuery: string = '';
  @State alternateModelOptions: ComposerModelOption[] = [];
  @State alternateEffortOptions: ComposerChoiceOption[] = [];
  @State alternateFastModeCapability: boolean = false;
  @State sessionAgentSwitchSupported: boolean = false;
  /** 被控端公开的 pending intent；仅用于提示，不提前改任务行的 agent/model。 */
  @State pendingAgentSwitchIntent: SessionAgentSwitchIntent | null = null;
  @State modelOptionsTargetId: string = '';
  @State contextRpcBusy: boolean = false;
  @State goalState: GoalModeState | null = null;
  @State goalObjective: string = '';
  @State goalMaxTurns: string = '';
  @State goalBudgetTokens: string = '';
  @State goalNoProgressLimit: string = '3';
  @State goalActionBusy: boolean = false;
  private recentPickerOptions: PickerOptions = createRecentPickerOptions();
  @State recentPickerController: PickerController = new PickerController();
  private permissionModeBeforePlan: string = 'default';
  private agentSwitchReadGeneration: number = 0;
  private agentSwitchWriteGeneration: number = 0;
  private agentSwitchConfirmed: boolean = false;
  /** 历史图片：ref.url → 可加载的 OSS URL（懒解析 + 缓存）。 */
  @State imageSources: Map<string, string> = new Map();
  @State imageStates: Map<string, RemoteMediaViewState> = new Map();
  private imageResolutions: Map<string, Promise<string>> = new Map();
  private ossUrlCache: Map<string, string> = new Map();
  /** 全屏预览中的图片 URL（空 = 无预览）。 */
  @State previewImageUrl: string = '';
  /** 挂起的交互请求（Permission / Ask User / Plan Review）。 */
  @State pendingInteractions: PendingInteraction[] = [];
  /** Ask User 草稿的页面级响应式快照；Store 的普通 Map 本身不会触发 ArkUI 局部重绘。 */
  @State askDraftSnapshots: Map<string, AskUserDraft> = new Map();
  /** 多卡时只展示一个 active request；新快照优先保留用户正在处理的卡。 */
  @State activeInteractionRequestId: string = '';
  /** 高风险 Permission 首击只进入确认态；同一 request 的第二击才真正提交。 */
  @State armedPermissionRequestId: string = '';
  @State armedPermissionAction: string = '';
  @State armedPermissionFingerprint: string = '';
  /** 当前设备是否关闭远程控制（只读提示）。 */
  @State deviceDisabled: boolean = false;
  /** 活动工作组的实时计时基准；与 Mobile 每 500ms 刷新一次。 */
  @State workClockNowMs: number = Date.now();
  private workClockTimer: number = -1;

  aboutToAppear(): void {
    this.stopWorkClock();
    this.imageQueue.onChanged = (images: ComposerImage[]): void => {
      this.composerImages = images;
    };
    this.imageQueue.onPickingChanged = (picking: boolean): void => {
      this.pickingImages = picking;
    };
    this.imageQueue.isBusy = (): boolean => this.sending;
    this.imageQueue.occupiedByOtherAttachments = (): number => this.fileQueue.files.length;
    this.fileQueue.onChanged = (files: ComposerFile[]): void => {
      this.composerFiles = files;
    };
    this.fileQueue.onPickingChanged = (picking: boolean): void => {
      this.pickingFiles = picking;
    };
    this.fileQueue.isBusy = (): boolean => this.sending;
    this.fileQueue.occupiedByOtherAttachments = (): number => this.imageQueue.images.length;
    const params = recordOrEmpty(router.getParams());
    this.deviceId = this.paneDeviceId.length > 0
      ? this.paneDeviceId
      : readStr(params, 'deviceId');
    this.sessionId = this.paneSessionId.length > 0
      ? this.paneSessionId
      : readStr(params, 'sessionId');
    this.routeMessageClientId = this.paneMessageClientId.length > 0
      ? this.paneMessageClientId : readStr(params, 'message');
    this.focusedMessageClientId = '';
    this.tailHiddenErrorClientIds = [];
    this.tailInterruptAcked = false;
    this.tailBannerBusy = false;
    this.messageFocusGeneration += 1;
    this.messageFocusLoadStarted = false;
    this.sessionSyncStarted = false;
    this.inputQueueActivated = false;
    this.creationDraftHandoffDone = false;
    this.leavingForCreationEdit = false;
    this.newSessionCreationStatus = '';
    this.newSessionCreationError = '';
    this.newSessionCreationClientId = '';
    this.initialScrolled = false;
    this.initialScrollSettling = true;
    this.initialScrollGeneration += 1;
    this.followScrollGeneration += 1;
    this.followScrollScheduled = false;
    this.followScrollTrailingRequested = false;
    this.initialLoadGeneration += 1;
    this.sessionOpenResolved = false;
    this.initialLoadResolved = false;
    this.showInitialSync = false;
    this.followingLatest = true;
    this.hasNewMessages = false;
    this.visibleStartIndex = 0;
    this.visibleEndIndex = -1;
    this.listTouchStartY = 0;
    this.listTouchActive = false;
    this.listTouchPulledDown = false;
    this.listTouchPushedUp = false;
    this.listTouchLoadTriggered = false;
    this.hasOlderMessages = false;
    this.historyReviewIntent = false;
    this.initialHistoryAutofillRemaining = INITIAL_HISTORY_AUTOFILL_PAGES;
    this.historyLastAttemptFirstKey = '';
    this.historyAnchorRestoreGeneration += 1;
    this.pendingHistoryAnchorRestore = undefined;
    this.agentSwitchConfirmed = false;
    this.pendingAgentSwitchIntent = null;
    this.composerDocument = emptyComposerDocument();
    this.input = '';
    this.imageSources = new Map();
    this.imageStates = new Map();
    this.imageResolutions.clear();

    this.unsubs.push(AppServices.instance.messages.onChanged(() => {
      this.refreshItems();
    }));
    this.refreshItems();

    // 输入队列由应用级 Store 持有；页面仅镜像展示并触发操作。
    this.unsubs.push(AppServices.instance.inputQueue.onChanged(() => {
      this.refreshQueueState();
      this.refreshItems();
    }));
    this.refreshQueueState();

    // 交互确认：先镜像已有本地状态；远端快照由 session sync guard 统一放行。
    this.unsubs.push(AppServices.instance.interactions.onChanged(() => {
      this.syncPendingInteractions();
      if (this.armedPermissionRequestId.length > 0
        && !this.pendingInteractions.some((item: PendingInteraction) =>
          item.requestId === this.armedPermissionRequestId)) {
        this.clearArmedPermission();
      }
    }));
    this.syncPendingInteractions();

    // 撤权检查：设备关闭远程控制时只读。
    this.unsubs.push(AppServices.instance.tasks.onChanged(() => {
      this.deviceDisabled = this.checkDeviceDisabled();
      this.syncMessageCount();
      this.syncComposerContextState();
    }));
    this.deviceDisabled = this.checkDeviceDisabled();
    this.syncMessageCount();
    this.syncComposerContextState();

    // 目标模式走 session topic 推送；普通任务放行后再补拉一次快照。
    this.unsubs.push(AppServices.instance.goals.onChanged(() => {
      this.goalState = AppServices.instance.goals.getState(this.sessionId);
    }));
    this.goalState = AppServices.instance.goals.getState(this.sessionId);
    this.restoreComposerDraft();

    this.unsubs.push(AppServices.instance.newSessionCreations.onChanged(() => {
      this.refreshNewSessionCreation();
    }));
    this.refreshNewSessionCreation();
  }

  aboutToDisappear(): void {
    this.initialScrollGeneration += 1;
    this.followScrollGeneration += 1;
    this.followScrollScheduled = false;
    this.followScrollTrailingRequested = false;
    this.initialLoadGeneration += 1;
    this.messageFocusGeneration += 1;
    this.historyAnchorRestoreGeneration += 1;
    this.pendingHistoryAnchorRestore = undefined;
    this.loadingOlder = false;
    this.listTouchActive = false;
    this.agentSwitchReadGeneration += 1;
    this.agentSwitchWriteGeneration += 1;
    this.initialScrollSettling = false;
    this.contextSheetOpen = false;
    this.sessionActionOpen = false;
    this.sessionTreeOpen = false;
    this.sessionTreeGeneration += 1;
    this.composerPaletteGeneration += 1;
    this.composerPaletteMode = '';
    this.composerDraftGeneration += 1;
    void AppServices.instance.composerDrafts.flush(this.sessionId);
    if (this.editingQueueClientId.length > 0) {
      void AppServices.instance.inputQueue.setEditLock(
        this.deviceId, this.sessionId, this.editingQueueClientId, false).catch(() => {
      });
    }
    if (this.inputQueueActivated) {
      AppServices.instance.inputQueue.deactivateSession(this.deviceId, this.sessionId);
      this.inputQueueActivated = false;
    }
    if (this.interactionSessionActivated) {
      AppServices.instance.interactions.deactivateSession(this.deviceId, this.sessionId);
      this.interactionSessionActivated = false;
    }
    this.stopWorkClock();
    for (const u of this.unsubs) {
      u();
    }
    this.unsubs = [];
    void AppServices.instance.messages.closeSession(this.sessionId);
  }

  private refreshNewSessionCreation(): void {
    const task = AppServices.instance.newSessionCreations.getTask(this.sessionId);
    this.newSessionCreationStatus = task?.status ?? '';
    this.newSessionCreationError = task?.error ?? '';
    this.newSessionCreationClientId = task?.firstMessageClientId ?? '';
    if (task?.status === 'enqueue-failed' && !this.creationDraftHandoffDone) {
      this.handoffFailedFirstMessage(task);
    }
    if (!this.leavingForCreationEdit
      && !AppServices.instance.newSessionCreations.shouldBlockSessionSync(this.sessionId)) {
      this.startSessionSyncOnce();
    }
  }

  private syncPendingInteractions(): void {
    const sorted = sortPendingInteractions(
      AppServices.instance.interactions.getPending(this.sessionId));
    this.pendingInteractions = sorted;
    const askDraftSnapshots: Map<string, AskUserDraft> = new Map();
    for (let i = 0; i < sorted.length; i++) {
      if (sorted[i].kind !== 'ask_user_question') continue;
      const draft = AppServices.instance.interactions.readAskDraft(sorted[i].requestId);
      if (draft !== null) askDraftSnapshots.set(sorted[i].requestId, draft);
    }
    this.askDraftSnapshots = askDraftSnapshots;
    let activeExists = false;
    for (let i = 0; i < sorted.length; i++) {
      if (sorted[i].requestId === this.activeInteractionRequestId) {
        activeExists = true;
        break;
      }
    }
    if (!activeExists) {
      this.activeInteractionRequestId = sorted.length > 0 ? sorted[0].requestId : '';
    }
  }

  private activeInteractionIndex(): number {
    for (let i = 0; i < this.pendingInteractions.length; i++) {
      if (this.pendingInteractions[i].requestId === this.activeInteractionRequestId) return i;
    }
    return this.pendingInteractions.length > 0 ? 0 : -1;
  }

  private selectPendingInteraction(requestId: string): void {
    if (requestId === this.activeInteractionRequestId) return;
    this.activeInteractionRequestId = requestId;
    this.clearArmedPermission();
  }

  private isCreationBlockingRemoteOps(): boolean {
    return shouldBlockNewSessionRemoteOperation(
      this.session()?.pendingLocalCreation === true,
      this.newSessionCreationStatus,
    );
  }

  private handoffFailedFirstMessage(task: NewSessionCreationTask): void {
    this.creationDraftHandoffDone = true;
    const current = composerDocumentProjectedText(this.composerDocument);
    let restored = task.firstMessageText;
    if (current.trim().length > 0) {
      restored = restored.length > 0 ? `${restored}\n\n${current}` : current;
    }
    this.setComposerDocument(reconcileComposerProjectedText(this.composerDocument, restored));
    const recoveredImages = this.imageQueue.restoreReady(task.firstMessageImages);
    const recoveredFiles = this.fileQueue.restoreReady(task.firstMessageFiles);
    const missingAttachments = task.firstMessageImages.length - recoveredImages
      + task.firstMessageFiles.length - recoveredFiles;
    this.error = missingAttachments > 0
      ? `${task.error}；有 ${missingAttachments} 个附件因数量上限未恢复`
      : task.error;
    AppServices.instance.newSessionCreations.finishDraftHandoff(this.sessionId);
  }

  /** 创建完成后只启动一次详情页的完整远端同步。 */
  private startSessionSyncOnce(): void {
    if (this.sessionSyncStarted || this.deviceId.length === 0 || this.sessionId.length === 0) return;
    this.sessionSyncStarted = true;
    AppServices.instance.inputQueue.activateSession(this.deviceId, this.sessionId);
    this.inputQueueActivated = true;
    AppServices.instance.interactions.activateSession(this.deviceId, this.sessionId);
    this.interactionSessionActivated = true;
    void AppServices.instance.inputQueue.refresh(this.deviceId, this.sessionId);
    void AppServices.instance.interactions.refreshPending(this.deviceId, this.sessionId);
    void AppServices.instance.goals.refresh(this.deviceId, this.sessionId);
    void this.loadComposerCapabilities();
    void this.invokeContextRpc('notification:clear-session-attention', [this.sessionId, 'explicit']).catch(() => {
      // 已读清除是幂等增强；旧被控端不支持时不阻塞详情页。
    });
    this.beginInitialLoad();
  }

  private refreshQueueState(): void {
    const projection = AppServices.instance.inputQueue.getProjection(this.sessionId);
    this.queueBubbles = AppServices.instance.inputQueue.getBubbles(this.sessionId);
    this.queuePaused = projection.queuePaused;
    this.queueProjectionError = projection.error;
    this.queueErrorRetryText = projection.errorRetryText;
    this.queueCredentialWaiting = projection.credentialSwitchWaiting;
    this.queueCredentialBlockedCount = projection.credentialSwitchBlockedBy.length;
    this.queueAbortPending = projection.queueAbortPending;
    this.queueInteractionLocked = projection.queueInteractionLocks.length > 0;
  }

  private queueActionBlocked(): boolean {
    return this.queueBusy || this.isCreationBlockingRemoteOps() || this.deviceDisabled
      || this.queueAbortPending || this.queueInteractionLocked;
  }

  /**
   * 首次取数延迟 200ms 再显形。Mobile 的本地历史通常瞬时返回，不应闪一下
   * loading；慢链路才显示“正在同步”，空结果则稳定落到“暂无消息”。
   */
  private beginInitialLoad(): void {
    const generation = this.initialLoadGeneration;
    setTimeout(() => {
      if (generation === this.initialLoadGeneration
        && !this.initialLoadResolved
        && this.items.length === 0) {
        this.showInitialSync = true;
      }
    }, 200);
    AppServices.instance.messages.openSession(this.deviceId, this.sessionId).then((loaded: boolean) => {
      if (generation !== this.initialLoadGeneration) return;
      this.sessionOpenResolved = true;
      this.initialLoadResolved = true;
      this.showInitialSync = false;
      this.loadFailed = !loaded || AppServices.instance.messages.loadFailed(this.sessionId);
      this.refreshItems();
      if (loaded) {
        if (this.routeMessageClientId.length > 0) this.focusMessageTarget();
        else this.scrollToBottomOnce();
      }
    });
  }

  /** 判断当前设备是否关闭远程控制（撤权只读）。 */
  private checkDeviceDisabled(): boolean {
    const devices = AppServices.instance.tasks.deviceList;
    for (let i = 0; i < devices.length; i++) {
      if (devices[i].deviceId === this.deviceId) {
        return !devices[i].remoteControlEnabled;
      }
    }
    return false;
  }

  private isEmbedded(): boolean {
    return this.paneDeviceId.length > 0 && this.paneSessionId.length > 0;
  }

  private handleMessageAreaChange(_oldArea: Area, newArea: Area): void {
    const value = newArea.width;
    const width = typeof value === 'number' ? value : 0;
    if (Number.isFinite(width) && width > 0 && width !== this.messageAreaWidth) {
      this.messageAreaWidth = width;
      this.tableColumnWidthCache.clear();
    }
  }

  private session(): RemoteSession | undefined {
    const sessions = AppServices.instance.tasks.getSessions(this.deviceId);
    for (let i = 0; i < sessions.length; i++) {
      if (sessions[i].id === this.sessionId) {
        return sessions[i];
      }
    }
    return undefined;
  }

  /** 把任务列表的服务端消息总数交给分页 Store，供首窗落地前乐观推断。 */
  private syncMessageCount(): void {
    const session = this.session();
    if (session !== undefined && session.messageCount > 0) {
      AppServices.instance.messages.setMessageCount(this.sessionId, session.messageCount);
    }
    this.hasOlderMessages = AppServices.instance.messages.hasMore(this.sessionId);
  }

  /** sessions:patched 回流计划模式后，保持 Sheet 与桌面端真相一致。 */
  private syncComposerContextState(): void {
    const session = this.session();
    if (session === undefined) {
      return;
    }
    this.planModeEnabled = session.planModeEnabled || session.permissionMode === 'plan';
    if (session.permissionMode.length > 0 && session.permissionMode !== 'plan') {
      this.permissionModeBeforePlan = session.permissionMode;
    }
    if (this.pendingAgentSwitchIntent !== null
      && this.pendingAgentSwitchIntent.targetAgentKind === this.currentAgentTab()
      && this.pendingAgentSwitchIntent.model === session.model) {
      this.pendingAgentSwitchIntent = null;
    }
  }

  private agentKindForCapability(session: RemoteSession): string {
    return session.agentKind === 'cc' ? 'claude-code' : session.agentKind;
  }

  /** 当前会话的模型选中线索：被隐藏的当前模型也必须保留在目录中。 */
  private currentModelSelectionHint(): ModelSelectionHint | undefined {
    const session = this.session();
    if (session === undefined || session.model.length === 0) return undefined;
    const hint: ModelSelectionHint = { model: session.model, providerId: session.providerId };
    return hint;
  }

  private async loadProviderModelOptions(agent: string): Promise<void> {
    try {
      const request = new ProviderListOptions();
      request.capabilities = ['provider-logo-kinds-v2'];
      const result = await this.invokeContextRpc('maker:provider:list', [request]);
      this.modelVisibilityOverrides = parseModelVisibilityOverrides(result);
      this.providerModelOptions = parseProviderModelOptions(
        result, agent, this.modelVisibilityOverrides, this.currentModelSelectionHint());
      this.providerModelAgent = agent;
    } catch (e) {
      // 旧被控端没有 provider:list 时保持 capabilities 扁平回退，不影响模型页其它能力。
      this.providerModelOptions = [];
      this.providerModelAgent = '';
    }
  }

  /** 新主机用 planMode.supported；旧主机以 permissionModes 含 plan 兼容。 */
  private async loadComposerCapabilities(): Promise<void> {
    const session = this.session();
    if (session === undefined) {
      return;
    }
    try {
      const result = await this.invokeContextRpc('maker:get-capabilities', [
        this.agentKindForCapability(session),
      ]);
      if (result === undefined || result === null || typeof result !== 'object' || Array.isArray(result)) {
        return;
      }
      const capabilities = result as Record<string, Object>;
      this.permissionOptions = parseChoiceOptions(capabilities['permissionModes'], true);
      this.effortOptions = parseChoiceOptions(capabilities['effortLevels'], false);
      this.modelOptions = parseModelOptions(capabilities['availableModels']);
      this.fastModeCapability = readBool(capabilities, 'hasFastMode', false);
      await this.loadProviderModelOptions(this.currentAgentTab());
      this.sessionAgentSwitchSupported = readBool(capabilities, 'supportsSessionAgentSwitch', false);
      this.modelAgentTab = this.currentAgentTab();
      void this.loadPendingAgentSwitchIntent();
      if (this.session()?.permissionMode === 'plan') {
        let rememberedSupported = false;
        for (let i = 0; i < this.permissionOptions.length; i++) {
          if (this.permissionOptions[i].id === this.permissionModeBeforePlan) {
            rememberedSupported = true;
            break;
          }
        }
        if (!rememberedSupported) {
          let fallback = this.permissionOptions.length > 0 ? this.permissionOptions[0].id : 'ask';
          for (let i = 0; i < this.permissionOptions.length; i++) {
            if (this.permissionOptions[i].id === 'ask') {
              fallback = 'ask';
              break;
            }
          }
          this.permissionModeBeforePlan = fallback;
        }
      }
      this.planModeSupported = this.capabilityHasNativePlan(capabilities)
        || this.capabilityHasLegacyPlan(capabilities);
      this.syncComposerContextState();
    } catch (e) {
      // 旧主机不支持 capabilities 时隐藏对应运行时控制；其它上下文能力仍可用。
      this.planModeSupported = false;
      this.permissionOptions = [];
      this.modelOptions = [];
      this.effortOptions = [];
      this.fastModeCapability = false;
      this.sessionAgentSwitchSupported = false;
      this.pendingAgentSwitchIntent = null;
    }
  }

  private canSwitchSessionAgent(): boolean {
    return supportsSessionAgentSwitch(this.session(), this.sessionAgentSwitchSupported);
  }

  private async loadPendingAgentSwitchIntent(): Promise<void> {
    const session = this.session();
    const generation = ++this.agentSwitchReadGeneration;
    if (!supportsSessionAgentSwitch(session, this.sessionAgentSwitchSupported) || session === undefined) {
      this.pendingAgentSwitchIntent = null;
      return;
    }
    try {
      const result = await this.invokeContextRpc('maker:get-session-agent-switch-intent', [session.id]);
      if (generation !== this.agentSwitchReadGeneration || this.sessionId !== session.id) return;
      this.pendingAgentSwitchIntent = parseSessionAgentSwitchIntent(result);
    } catch (e) {
      if (generation !== this.agentSwitchReadGeneration || this.sessionId !== session.id) return;
      // 旧被控端可能没有只读 intent RPC；入口能力仍由 capabilities 决定。
      this.pendingAgentSwitchIntent = null;
    }
  }

  private capabilityHasNativePlan(capabilities: Record<string, Object>): boolean {
    return readBool(readObj(capabilities, 'planMode'), 'supported', false);
  }

  private capabilityHasLegacyPlan(capabilities: Record<string, Object>): boolean {
    const modes = capabilities['permissionModes'];
    if (!Array.isArray(modes)) {
      return false;
    }
    const permissionModes = modes as Object[];
    for (let i = 0; i < permissionModes.length; i++) {
      const mode = permissionModes[i];
      if (mode === 'plan') {
        return true;
      }
      if (mode !== null && typeof mode === 'object' && !Array.isArray(mode)
        && readStr(mode as Record<string, Object>, 'id') === 'plan') {
        return true;
      }
    }
    return false;
  }

  private async invokeContextRpc(channel: string, args: Object[]): Promise<Object | undefined> {
    if (this.isCreationBlockingRemoteOps()) {
      throw new Error('任务创建完成后才能修改任务设置');
    }
    await AppServices.instance.openLink(this.deviceId);
    const options = new DlInvokeOptions();
    options.channel = channel;
    options.args = args;
    const envelope = await AppServices.instance.client.invoke(this.deviceId, options);
    return unwrapInvokeResult(envelope);
  }

  private async togglePlanMode(): Promise<void> {
    if (this.contextRpcBusy || !this.planModeSupported || this.isCreationBlockingRemoteOps()) {
      return;
    }
    const session = this.session();
    if (session === undefined) {
      return;
    }
    const next = !this.planModeEnabled;
    this.contextRpcBusy = true;
    try {
      const capabilities = await this.capabilitiesRecord();
      if (this.capabilityHasNativePlan(capabilities)) {
        await this.invokeContextRpc('maker:set-plan-mode', [session.id, next]);
      } else {
        const mode = next ? 'plan' : this.permissionModeBeforePlan;
        await this.invokeContextRpc('maker:set-permission-mode', [session.id, mode]);
      }
      this.planModeEnabled = next;
    } catch (e) {
      promptAction.showToast({ message: '计划模式更新失败，请重试' });
    } finally {
      this.contextRpcBusy = false;
    }
  }

  /** 切换时复查一次能力，避免仅靠页面首次加载的兼容推断走错 RPC。 */
  private async capabilitiesRecord(): Promise<Record<string, Object>> {
    const session = this.session();
    if (session === undefined) {
      return {};
    }
    const result = await this.invokeContextRpc('maker:get-capabilities', [
      this.agentKindForCapability(session),
    ]);
    if (result !== undefined && result !== null && typeof result === 'object' && !Array.isArray(result)) {
      return result as Record<string, Object>;
    }
    return {};
  }

  private effectivePermissionMode(): string {
    const session = this.session();
    if (session === undefined) {
      return '';
    }
    return session.permissionMode === 'plan' ? this.permissionModeBeforePlan : session.permissionMode;
  }

  private currentAgentTab(): string {
    return modelAgentId(this.agentKindForCapability(this.session() ?? new RemoteSession()));
  }

  private browsingCurrentAgent(): boolean {
    return this.modelAgentTab.length === 0 || this.modelAgentTab === this.currentAgentTab();
  }

  private visibleModelOptions(): ComposerModelOption[] {
    if (this.providerModelOptions.length > 0 && this.providerModelAgent === this.modelAgentTab) {
      return this.providerModelOptions;
    }
    return this.browsingCurrentAgent() ? this.modelOptions : this.alternateModelOptions;
  }

  private visibleEffortOptions(): ComposerChoiceOption[] {
    return this.browsingCurrentAgent() ? this.effortOptions : this.alternateEffortOptions;
  }

  private visibleFastModeCapability(): boolean {
    return this.browsingCurrentAgent() ? this.fastModeCapability : this.alternateFastModeCapability;
  }

  private filteredModelOptions(): ComposerModelOption[] {
    const query = this.modelSearchQuery.trim().toLowerCase();
    const source = this.visibleModelOptions();
    if (query.length === 0) return source;
    const out: ComposerModelOption[] = [];
    for (let i = 0; i < source.length; i++) {
      const option = source[i];
      if (option.label.toLowerCase().includes(query)
        || option.id.toLowerCase().includes(query)
        || option.description.toLowerCase().includes(query)) {
        out.push(option);
      }
    }
    return out;
  }


  private modelOptionIsCurrent(option: ComposerModelOption): boolean {
    const session = this.session();
    if (!this.browsingCurrentAgent() || session === undefined || option.id !== session.model) return false;
    if (session.providerId.length > 0) return option.providerId === session.providerId;
    if (option.providerId.length === 0) return true;
    const source = this.visibleModelOptions();
    for (let i = 0; i < source.length; i++) {
      if (source[i].id === session.model) return source[i].providerId === option.providerId;
    }
    return false;
  }

  private effortOptionLabel(id: string, fallback: string): string {
    const options = this.visibleEffortOptions();
    for (let i = 0; i < options.length; i++) {
      if (options[i].id === id && options[i].label.length > 0) return options[i].label;
    }
    return effortLevelLabel(id, fallback);
  }

  private modelEffortText(option: ComposerModelOption): string {
    const session = this.session();
    const effort = this.modelOptionIsCurrent(option) && session !== undefined
      ? session.effort
      : option.defaultEffort;
    if (effort.length === 0) return '';
    return option.effortDisplayNames[effort] ?? this.effortOptionLabel(effort, effort);
  }

  private currentModelKey(): string {
    const source = this.visibleModelOptions();
    for (let i = 0; i < source.length; i++) {
      if (this.modelOptionIsCurrent(source[i])) return composerModelKey(source[i]);
    }
    return this.session()?.model ?? '';
  }

  private modelOptionsForTarget(target: string): ComposerModelOption[] {
    const source = this.visibleModelOptions();
    for (let i = 0; i < source.length; i++) {
      if (composerModelKey(source[i]) === target) return [source[i]];
    }
    for (let i = 0; i < source.length; i++) {
      if (source[i].id === target && this.modelOptionIsCurrent(source[i])) return [source[i]];
    }
    for (let i = 0; i < source.length; i++) {
      if (source[i].id === target) return [source[i]];
    }
    return [];
  }

  private currentModelOption(): ComposerModelOption | null {
    const source = this.visibleModelOptions();
    for (let i = 0; i < source.length; i++) {
      if (this.modelOptionIsCurrent(source[i])) return source[i];
    }
    const modelId = this.session()?.model ?? '';
    for (let i = 0; i < source.length; i++) {
      if (source[i].id === modelId) return source[i];
    }
    return null;
  }

  private currentModelLabel(): string {
    const option = this.currentModelOption();
    if (option !== null) {
      return option.label;
    }
    return this.session()?.model ?? '';
  }

  private currentModelEffortLabel(): string {
    const option = this.currentModelOption();
    if (option !== null) {
      const selectedEffort = this.session()?.effort ?? '';
      const effort = selectedEffort.length > 0 ? selectedEffort : option.defaultEffort;
      if (effort.length === 0) return '';
      return option.effortDisplayNames[effort] ?? this.effortOptionLabel(effort, effort);
    }
    const effort = this.session()?.effort ?? '';
    return effort.length > 0 ? this.effortOptionLabel(effort, effort) : '';
  }

  private currentModelEffortOptions(): ComposerChoiceOption[] {
    const targetId = this.modelOptionsTargetId.length > 0
      ? this.modelOptionsTargetId
      : this.currentModelKey();
    const source = this.modelOptionsForTarget(targetId);
    const model = source.length > 0 ? source[0] : this.currentModelOption();
    if (model === null || model.efforts.length === 0) return [];
    const effortSource = this.browsingCurrentAgent() ? this.effortOptions : this.alternateEffortOptions;
    const out: ComposerChoiceOption[] = [];
    for (let i = 0; i < model.efforts.length; i++) {
      const id = model.efforts[i];
      let matched: ComposerChoiceOption | null = null;
      for (let j = 0; j < effortSource.length; j++) {
        if (effortSource[j].id === id) {
          matched = effortSource[j];
          break;
        }
      }
      if (matched !== null) {
        const customLabel = model.effortDisplayNames[id];
        if (customLabel !== undefined && customLabel.length > 0) {
          const customized = new ComposerChoiceOption();
          customized.id = matched.id;
          customized.label = customLabel;
          customized.description = matched.description;
          out.push(customized);
        } else {
          out.push(matched);
        }
      } else {
        const fallback = new ComposerChoiceOption();
        fallback.id = id;
        fallback.label = model.effortDisplayNames[id] ?? effortLevelLabel(id, id);
        out.push(fallback);
      }
    }
    return out;
  }

  private modelAgentIsActive(kind: string): boolean {
    return this.modelAgentTab === kind;
  }


  private modelOptionHasOptions(option: ComposerModelOption): boolean {
    return option.efforts.length > 0 || (this.visibleFastModeCapability() && option.supportsFastMode);
  }

  private modelOptionsTarget(): ComposerModelOption[] {
    return this.modelOptionsForTarget(this.modelOptionsTargetId);
  }

  private modelOptionEffortSelected(option: ComposerChoiceOption): boolean {
    return option.id === (this.session()?.effort ?? '');
  }

  private currentModelSupportsFastMode(): boolean {
    const modelId = this.modelOptionsTargetId.length > 0
      ? this.modelOptionsTargetId
      : this.currentModelKey();
    const source = this.modelOptionsForTarget(modelId);
    const model = source.length > 0 ? source[0] : this.currentModelOption();
    return this.visibleFastModeCapability() && model !== null && model.supportsFastMode;
  }

  private openComposerControlSheet(page: string): void {
    if (this.sending || this.contextRpcBusy || this.deviceDisabled
      || this.isCreationBlockingRemoteOps()) {
      return;
    }
    if (page === 'model') {
      this.modelAgentTab = this.currentAgentTab();
      this.modelSearchQuery = '';
      this.modelOptionsTargetId = '';
      this.alternateModelOptions = [];
      this.alternateEffortOptions = [];
      this.alternateFastModeCapability = false;
      if (this.providerModelAgent !== this.currentAgentTab()) {
        void this.loadProviderModelOptions(this.currentAgentTab());
      }
    }
    this.contextSheetPage = page;
    this.getUIContext().getFocusController().clearFocus();
    this.contextSheetOpen = true;
  }

  private async browseModelAgent(kind: string): Promise<void> {
    if (kind === this.modelAgentTab || this.contextRpcBusy) return;
    if (!this.canSwitchSessionAgent()) {
      promptAction.showToast({ message: '当前任务不支持切换 Agent' });
      return;
    }
    this.modelAgentTab = kind;
    this.modelSearchQuery = '';
    this.contextRpcBusy = true;
    try {
      const result = await this.invokeContextRpc('maker:get-capabilities', [kind]);
      if (result === undefined || result === null || typeof result !== 'object' || Array.isArray(result)) {
        throw new Error('capabilities unavailable');
      }
      const capabilities = result as Record<string, Object>;
      this.alternateModelOptions = parseModelOptions(capabilities['availableModels']);
      this.alternateEffortOptions = parseChoiceOptions(capabilities['effortLevels'], false);
      this.alternateFastModeCapability = readBool(capabilities, 'hasFastMode', false);
      await this.loadProviderModelOptions(kind);
    } catch (e) {
      this.modelAgentTab = this.currentAgentTab();
      this.alternateModelOptions = [];
      this.alternateEffortOptions = [];
      this.alternateFastModeCapability = false;
      promptAction.showToast({ message: '无法加载该 Agent 的模型' });
    } finally {
      this.contextRpcBusy = false;
    }
  }

  private openModelOptions(option: ComposerModelOption): void {
    if (this.contextRpcBusy) return;
    const session = this.session();
    if (session === undefined) return;
    this.modelOptionsTargetId = composerModelKey(option);
    if (!this.modelOptionIsCurrent(option) || !this.browsingCurrentAgent()) {
      // 非当前模型先完成真实模型/Agent 切换；在远端状态回流前不伪造其推理设置。
      void this.selectComposerModel(option, false);
      return;
    }
    this.contextSheetPage = 'model-options';
  }

  private requestPermissionMode(option: ComposerChoiceOption): void {
    if (option.id === this.effectivePermissionMode() || this.contextRpcBusy) {
      return;
    }
    if (option.id === 'bypassPermissions') {
      this.getUIContext().showAlertDialog({
        title: '确认完全访问',
        message: 'Cindy 将不再逐项询问工具操作。请仅在信任当前任务和项目时使用。',
        primaryButton: {
          value: '取消',
          action: () => {
          },
        },
        secondaryButton: {
          value: '继续',
          action: () => {
            void this.applyPermissionMode(option);
          },
        },
      });
      return;
    }
    void this.applyPermissionMode(option);
  }

  private async applyPermissionMode(option: ComposerChoiceOption): Promise<void> {
    const session = this.session();
    if (session === undefined || this.contextRpcBusy) {
      return;
    }
    this.contextRpcBusy = true;
    try {
      await this.invokeContextRpc('maker:set-permission-mode', [session.id, option.id]);
      this.permissionModeBeforePlan = option.id;
      this.contextSheetOpen = false;
    } catch (e) {
      promptAction.showToast({ message: '权限模式更新失败，请重试' });
    } finally {
      this.contextRpcBusy = false;
    }
  }

  private async selectComposerModel(option: ComposerModelOption, keepOpen: boolean = false): Promise<void> {
    const session = this.session();
    if (session === undefined || this.contextRpcBusy) {
      return;
    }
    const targetAgent = this.modelAgentTab.length > 0 ? this.modelAgentTab : this.currentAgentTab();
    const currentAgent = this.currentAgentTab();
    if (targetAgent !== currentAgent && !this.canSwitchSessionAgent()) {
      promptAction.showToast({ message: '当前任务不支持切换 Agent' });
      return;
    }
    if (targetAgent !== currentAgent && !this.agentSwitchConfirmed) {
      this.getUIContext().showAlertDialog({
        title: `切换到 ${modelAgentLabel(targetAgent)}`,
        message: '当前任务的上下文会保留，Agent 将在安全边界切换；正在运行时会等本轮结束后生效。',
        primaryButton: {
          value: '取消',
          action: () => {
          },
        },
        secondaryButton: {
          value: '继续',
          action: () => {
            this.agentSwitchConfirmed = true;
            void this.selectComposerModel(option, keepOpen);
          },
        },
      });
      return;
    }
    if (session.model === option.id && targetAgent === currentAgent) {
      if (keepOpen) this.contextSheetPage = 'model-options';
      else this.contextSheetOpen = false;
      return;
    }
    this.contextRpcBusy = true;
    try {
      let result: Object | undefined;
      if (targetAgent !== currentAgent) {
        const writeGeneration = ++this.agentSwitchWriteGeneration;
        const effort = option.defaultEffort.length > 0
          ? option.defaultEffort
          : (option.efforts.length > 0 ? option.efforts[0] : '');
        result = await this.invokeContextRpc('maker:switch-session-agent', [
          session.id, targetAgent, option.id, option.providerId, effort, false,
        ]);
        if (writeGeneration !== this.agentSwitchWriteGeneration || this.sessionId !== session.id) return;
        await this.loadPendingAgentSwitchIntent();
      } else {
        const args: Object[] = option.providerId.length > 0
          ? [session.id, option.id, option.providerId]
          : [session.id, option.id];
        result = await this.invokeContextRpc('maker:set-model', args);
      }
      if (result !== undefined && result !== null && typeof result === 'object' && !Array.isArray(result)
        && readBool(result as Record<string, Object>, 'deferred', false)) {
        promptAction.showToast({ message: '将在当前运行结束后切换模型' });
      }
      if (keepOpen) {
        this.contextSheetPage = 'model-options';
      } else {
        this.contextSheetOpen = false;
      }
    } catch (e) {
      promptAction.showToast({ message: '模型切换失败，请重试' });
    } finally {
      this.contextRpcBusy = false;
    }
  }

  private async selectComposerEffort(option: ComposerChoiceOption): Promise<void> {
    const session = this.session();
    if (session === undefined || this.contextRpcBusy || session.effort === option.id) {
      return;
    }
    this.contextRpcBusy = true;
    try {
      await this.invokeContextRpc('maker:set-effort', [session.id, option.id]);
    } catch (e) {
      promptAction.showToast({ message: '推理强度更新失败，请重试' });
    } finally {
      this.contextRpcBusy = false;
    }
  }

  private async toggleFastMode(): Promise<void> {
    const session = this.session();
    if (session === undefined || this.contextRpcBusy || !this.currentModelSupportsFastMode()) {
      return;
    }
    this.contextRpcBusy = true;
    try {
      await this.invokeContextRpc('maker:set-fast-mode', [session.id, !session.fastMode]);
    } catch (e) {
      promptAction.showToast({ message: 'Fast 模式更新失败，请重试' });
    } finally {
      this.contextRpcBusy = false;
    }
  }

  private positiveIntegerOrDefault(value: string, fallback: number): number {
    const trimmed = value.trim();
    if (trimmed.length === 0) {
      return fallback;
    }
    const parsed = Number(trimmed);
    return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
  }

  private async startGoal(): Promise<void> {
    const objective = this.goalObjective.trim();
    if (objective.length === 0 || this.goalActionBusy || this.isCreationBlockingRemoteOps()) {
      if (objective.length === 0) {
        promptAction.showToast({ message: '请先填写目标' });
      }
      return;
    }
    const limits = new GoalStartOptions();
    limits.maxTurns = this.positiveIntegerOrDefault(this.goalMaxTurns, -1);
    limits.budgetTokens = this.positiveIntegerOrDefault(this.goalBudgetTokens, -1);
    limits.noProgressLimit = this.positiveIntegerOrDefault(this.goalNoProgressLimit, 3);
    this.goalActionBusy = true;
    try {
      // unknown 状态下先权威回读，避免快照尚未返回时覆盖已存在的目标。
      const statusSynced = await AppServices.instance.goals.refresh(this.deviceId, this.sessionId);
      if (!statusSynced) {
        promptAction.showToast({ message: '无法确认当前目标状态，请重试' });
        return;
      }
      const existing = AppServices.instance.goals.getState(this.sessionId);
      if (existing !== null) {
        this.goalState = existing;
        promptAction.showToast({ message: '当前任务已有目标' });
        return;
      }
      await AppServices.instance.goals.start(this.deviceId, this.sessionId, objective, limits);
      this.goalState = AppServices.instance.goals.getState(this.sessionId);
      this.setComposerDocument(emptyComposerDocument());
      this.contextSheetOpen = false;
      this.contextSheetPage = 'main';
      this.followLatestSoon();
    } catch (e) {
      promptAction.showToast({ message: '目标启动失败，请重试' });
    } finally {
      this.goalActionBusy = false;
    }
  }

  private async pauseOrResumeGoal(): Promise<void> {
    if (this.goalState === null || this.goalActionBusy || this.isCreationBlockingRemoteOps()) {
      return;
    }
    this.goalActionBusy = true;
    try {
      if (this.goalState.status === 'active') {
        await AppServices.instance.goals.pause(this.deviceId, this.sessionId);
      } else {
        await AppServices.instance.goals.resume(this.deviceId, this.sessionId);
      }
      this.goalState = AppServices.instance.goals.getState(this.sessionId);
    } catch (e) {
      promptAction.showToast({ message: '目标状态更新失败，请重试' });
    } finally {
      this.goalActionBusy = false;
    }
  }

  private confirmClearGoal(): void {
    if (this.goalActionBusy || this.isCreationBlockingRemoteOps()) {
      return;
    }
    this.getUIContext().showActionSheet({
      title: '终止目标',
      message: '目标会停止自动推进，但已经产生的消息会保留。',
      sheets: [{
        title: '终止目标',
        action: () => {
          void this.clearGoal();
        },
      }],
    });
  }

  private async clearGoal(): Promise<void> {
    if (this.isCreationBlockingRemoteOps()) return;
    this.goalActionBusy = true;
    try {
      await AppServices.instance.goals.clear(this.deviceId, this.sessionId);
      this.goalState = null;
    } catch (e) {
      promptAction.showToast({ message: '目标终止失败，请重试' });
    } finally {
      this.goalActionBusy = false;
    }
  }

  private goalStatusText(status: string): string {
    if (status === 'active') return '自动推进中';
    if (status === 'paused') return '已暂停';
    if (status === 'blocked') return '等待处理';
    if (status === 'complete') return '已完成';
    if (status === 'budgetLimited') return '已达到 token 上限';
    if (status === 'usageLimited') return '等待用量恢复';
    return status.length > 0 ? status : '状态未知';
  }

  private send(): void {
    const serialized: SerializedComposerDocument = serializeComposerDocument(this.composerDocument);
    const text = serialized.text;
    if (this.sending) return;
    if (pendingInteractionsBlockRemoteComposer(this.pendingInteractions)) {
      promptAction.showToast({ message: '请先处理待确认请求' });
      return;
    }
    if (this.editingQueueClientId.length > 0) {
      this.saveQueueEdit(text);
      return;
    }
    const learn = parseLearnCommand(text, this.selectedLearnRoute === 'agent-skill');
    if (learn.matched) {
      this.sendLearnCommand(learn);
      return;
    }
    this.selectedLearnRoute = '';
    if (this.deviceDisabled) {
      promptAction.showToast({ message: '设备已关闭远程控制，仅可查看' });
      return;
    }
    if (this.imageQueue.hasUploading()) {
      promptAction.showToast({ message: '图片上传中，请稍候' });
      return;
    }
    if (this.imageQueue.hasFailed()) {
      promptAction.showToast({ message: '请重试或移除上传失败的图片' });
      return;
    }
    if (this.fileQueue.hasUploading()) {
      promptAction.showToast({ message: '文件上传中，请稍候' });
      return;
    }
    if (this.fileQueue.hasFailed()) {
      promptAction.showToast({ message: '请重试或移除上传失败的文件' });
      return;
    }
    const readyImages = this.imageQueue.readyImages();
    const readyFiles = this.fileQueue.readyFiles();
    if (text.length === 0 && readyImages.length === 0 && readyFiles.length === 0) return;
    const s = this.session();
    if (s === undefined) {
      this.error = '任务信息缺失，请返回列表重新进入';
      return;
    }
    const sentImages = this.imageQueue.images.slice();
    const sentFiles = this.fileQueue.files.slice();
    const deferForCreation = this.isCreationBlockingRemoteOps()
      || AppServices.instance.inputQueue.shouldDeferNewInput(this.sessionId);
    // 点发送后当帧清空 composer；同一个 clientId 的 pending 气泡立即进入消息流。
    this.composerDocument = emptyComposerDocument();
    this.input = '';
    this.composerInputRevision += 1;
    AppServices.instance.composerDrafts.clear(this.sessionId);
    this.imageQueue.removeSent(sentImages);
    this.fileQueue.removeSent(sentFiles);
    this.error = '';
    if (deferForCreation) {
      AppServices.instance.inputQueue.deferDocument(
        this.deviceId, s, serialized, readyImages, readyFiles);
      this.followLatestSoon();
      return;
    }
    this.sending = true;
    this.error = '';
    AppServices.instance.inputQueue.enqueueDocument(
      this.deviceId, s, serialized, readyImages, readyFiles).then(() => {
      this.sending = false;
      this.followLatestSoon();
    }).catch((e: Error) => {
      this.sending = false;
      this.error = `消息未确认发送：${e.message}`;
    });
  }

  private sendLearnCommand(command: LearnCommandMatch): void {
    if (this.sending || this.deviceDisabled || this.isCreationBlockingRemoteOps()) return;
    if (this.composerImages.length > 0 || this.composerFiles.length > 0) {
      promptAction.showToast({ message: '技能学习命令不能同时发送附件' });
      return;
    }
    this.sending = true;
    const request = buildLearnStartRequest(command, this.sessionId);
    this.invokeContextRpc('learn:start', [request]).then((result: Object | undefined) => {
      const data: Record<string, Object> = {};
      if (result !== undefined && result !== null && typeof result === 'object' && !Array.isArray(result)) {
        const record = result as Record<string, Object>;
        data['runId'] = readStr(record, 'runId');
        data['detail'] = readStr(record, 'detail');
      }
      data['input'] = command.input;
      this.setComposerDocument(emptyComposerDocument(), false);
      AppServices.instance.composerDrafts.clear(this.sessionId);
      this.selectedLearnRoute = '';
      AppServices.instance.messages.appendLocalSystemCard(this.sessionId, 'learn', data);
      this.followLatestSoon();
    }).catch((e: Error) => {
      const data: Record<string, Object> = {};
      data['error'] = e.message.indexOf('learn-busy') >= 0 ? 'learn-busy' : 'learn-failed';
      data['detail'] = e.message;
      data['input'] = command.input;
      AppServices.instance.messages.appendLocalSystemCard(this.sessionId, 'learn', data);
      promptAction.showToast({ message: '技能学习未启动，草稿已保留' });
    }).finally(() => {
      this.sending = false;
    });
  }

  private queueItem(clientId: string): QueuedInputItem | null {
    const queue = AppServices.instance.inputQueue.getProjection(this.sessionId).pendingQueue;
    for (let i = 0; i < queue.length; i++) {
      if (queue[i].clientId === clientId) return queue[i];
    }
    return null;
  }

  private beginQueueEdit(clientId: string): void {
    if (this.queueActionBlocked() || this.editingQueueClientId === clientId) return;
    const item = this.queueItem(clientId);
    if (item === null) return;
    const previous = this.editingQueueClientId;
    const start = (): void => {
      this.stashedComposerInput = previous.length > 0 ? this.stashedComposerInput : this.input;
      if (previous.length === 0) this.stashedComposerDocument = this.composerDocument;
      this.editingQueueClientId = clientId;
      this.editingQueueOriginalText = item.text;
      this.setComposerDocument(
        composerDocumentFromPersistedContent(item.persistedContent) ?? textComposerDocument(item.text),
        false,
      );
      this.selectedQueueClientId = '';
      void AppServices.instance.inputQueue.setEditLock(
        this.deviceId, this.sessionId, clientId, true).catch(() => {
        this.cancelQueueEdit();
        promptAction.showToast({ message: '无法锁定这条队列消息' });
      });
    };
    if (previous.length > 0) {
      void AppServices.instance.inputQueue.setEditLock(
        this.deviceId, this.sessionId, previous, false).finally(start);
    } else {
      start();
    }
  }

  private saveQueueEdit(_text: string): void {
    const clientId = this.editingQueueClientId;
    const serialized = serializeComposerDocument(this.composerDocument);
    if (clientId.length === 0 || serialized.text.length === 0 || this.queueActionBlocked()) return;
    this.queueBusy = true;
    this.sending = true;
    const save = serialized.text === this.editingQueueOriginalText
      ? Promise.resolve()
      : AppServices.instance.inputQueue.updateDocument(
        this.deviceId, this.sessionId, clientId, serialized);
    save.then(() => AppServices.instance.inputQueue.setEditLock(
      this.deviceId, this.sessionId, clientId, false,
    )).then(() => {
      this.editingQueueClientId = '';
      this.setComposerDocument(this.stashedComposerDocument, false);
      this.stashedComposerInput = '';
      this.stashedComposerDocument = emptyComposerDocument();
      this.editingQueueOriginalText = '';
      this.composerInputRevision += 1;
    }).catch(() => {
      promptAction.showToast({ message: '队列消息未保存，请重试' });
    }).finally(() => {
      this.queueBusy = false;
      this.sending = false;
    });
  }

  private cancelQueueEdit(): void {
    const clientId = this.editingQueueClientId;
    if (clientId.length === 0) return;
    this.editingQueueClientId = '';
    this.setComposerDocument(this.stashedComposerDocument, false);
    this.stashedComposerInput = '';
    this.stashedComposerDocument = emptyComposerDocument();
    this.editingQueueOriginalText = '';
    this.composerInputRevision += 1;
    void AppServices.instance.inputQueue.setEditLock(
      this.deviceId, this.sessionId, clientId, false).catch(() => {
    });
  }

  private removeQueueItem(clientId: string): void {
    if (this.queueActionBlocked()) return;
    this.queueBusy = true;
    this.selectedQueueClientId = '';
    if (this.editingQueueClientId === clientId) this.cancelQueueEdit();
    AppServices.instance.inputQueue.remove(this.deviceId, this.sessionId, clientId).catch(() => {
      promptAction.showToast({ message: '队列消息未删除，请重试' });
    }).finally(() => {
      this.queueBusy = false;
    });
  }

  private moveQueueItem(clientId: string, direction: number): void {
    if (this.queueActionBlocked()) return;
    const queue = AppServices.instance.inputQueue.getProjection(this.sessionId).pendingQueue;
    const index = queue.findIndex((item: QueuedInputItem) => item.clientId === clientId);
    if (index < 0) return;
    const targetIndex = direction < 0 ? index - 1 : index + 2;
    if (targetIndex < 0 || targetIndex > queue.length) return;
    this.queueBusy = true;
    AppServices.instance.inputQueue.move(
      this.deviceId, this.sessionId, clientId, targetIndex,
    ).catch(() => {
      promptAction.showToast({ message: '队列顺序未更新，请重试' });
    }).finally(() => {
      this.queueBusy = false;
    });
  }

  private steerQueueItem(clientId: string): void {
    if (this.queueActionBlocked() || !this.sessionStreaming) return;
    this.queueBusy = true;
    this.selectedQueueClientId = '';
    AppServices.instance.inputQueue.steer(this.deviceId, this.sessionId, clientId).catch(() => {
      promptAction.showToast({ message: '插话未发送，请重试' });
    }).finally(() => {
      this.queueBusy = false;
    });
  }

  private retryQueueItem(clientId: string): void {
    if (this.queueActionBlocked()) return;
    this.queueBusy = true;
    AppServices.instance.inputQueue.retry(this.deviceId, this.sessionId, clientId).catch(() => {
      promptAction.showToast({ message: '消息仍未发送，请检查连接' });
    }).finally(() => {
      this.queueBusy = false;
    });
  }

  private resumeQueue(): void {
    if (this.queueActionBlocked()) return;
    this.queueBusy = true;
    AppServices.instance.inputQueue.resume(this.deviceId, this.sessionId).catch(() => {
      promptAction.showToast({ message: '队列未恢复，请重试' });
    }).finally(() => {
      this.queueBusy = false;
    });
  }

  private retryQueueError(): void {
    if (this.queueActionBlocked() || this.queueErrorRetryText.length === 0) return;
    this.queueBusy = true;
    AppServices.instance.inputQueue.retryLastError(this.deviceId, this.sessionId).catch(() => {
      promptAction.showToast({ message: '重试失败，请检查电脑端状态' });
    }).finally(() => {
      this.queueBusy = false;
    });
  }

  private clearQueueError(): void {
    if (this.queueActionBlocked()) return;
    this.queueBusy = true;
    AppServices.instance.inputQueue.clearError(this.deviceId, this.sessionId).catch(() => {
      promptAction.showToast({ message: '暂时无法忽略该错误' });
    }).finally(() => {
      this.queueBusy = false;
    });
  }

  // ─── Composer 上下文与图片附件 ──────────────────────────────────────────────

  private openContextSheet(): void {
    if (this.sending || this.pickingImages || this.pickingFiles || this.deviceDisabled) {
      return;
    }
    this.contextSheetPage = 'main';
    this.contextSelectedUris = [];
    try {
      this.recentPickerController.setData(DataType.SET_SELECTED_URIS, []);
    } catch (e) {
      // Picker 尚未挂载时无需清理；新组件会从空选择开始。
    }
    this.getUIContext().getFocusController().clearFocus();
    this.contextSheetOpen = true;
  }

  private selectRecentImage(uri: string): void {
    if (uri.length === 0 || this.contextSelectedUris.includes(uri)) {
      return;
    }
    if (this.contextSelectedUris.length >= this.imageQueue.remainingSlots()) {
      promptAction.showToast({ message: `最多添加 ${MAX_COMPOSER_IMAGES} 张图片` });
      return;
    }
    this.contextSelectedUris = this.contextSelectedUris.concat([uri]);
  }

  private deselectRecentImage(uri: string): void {
    this.contextSelectedUris = this.contextSelectedUris.filter((value: string) => value !== uri);
  }

  private addRecentSelection(): void {
    const uris = this.contextSelectedUris.slice();
    this.contextSheetOpen = false;
    this.contextSelectedUris = [];
    this.imageQueue.enqueue(uris);
  }

  /** Sheet 行点击入口：先校验容量并收起 Sheet，再交给共享队列选图。 */
  private pickImages(): void {
    if (this.pickingImages || this.sending) {
      return;
    }
    if (this.imageQueue.remainingSlots() <= 0) {
      promptAction.showToast({ message: `最多添加 ${MAX_COMPOSER_IMAGES} 张图片` });
      return;
    }
    this.contextSheetOpen = false;
    this.imageQueue.pickImages();
  }

  private pickScreenshots(): void {
    if (this.pickingImages || this.sending) {
      return;
    }
    if (this.imageQueue.remainingSlots() <= 0) {
      promptAction.showToast({ message: `最多添加 ${MAX_COMPOSER_IMAGES} 张图片` });
      return;
    }
    this.contextSheetOpen = false;
    this.imageQueue.pickScreenshots(getContext(this) as common.UIAbilityContext);
  }

  private takePhoto(): void {
    if (this.pickingImages || this.sending) {
      return;
    }
    if (this.imageQueue.remainingSlots() <= 0) {
      promptAction.showToast({ message: `最多添加 ${MAX_COMPOSER_IMAGES} 张图片` });
      return;
    }
    this.contextSheetOpen = false;
    this.imageQueue.takePhoto(getContext(this) as common.UIAbilityContext);
  }

  private pickFiles(): void {
    if (this.pickingFiles || this.sending) return;
    if (this.fileQueue.remainingSlots() <= 0) {
      promptAction.showToast({ message: '每条消息最多添加 20 个附件' });
      return;
    }
    this.contextSheetOpen = false;
    this.fileQueue.pick(getContext(this) as common.UIAbilityContext);
  }

  private abort(): void {
    if (this.queueActionBlocked()) return;
    this.queueBusy = true;
    AppServices.instance.inputQueue.stop(this.deviceId, this.sessionId).catch(() => {
      // 兼容尚未实现 input queue 的旧 Desktop。
      return AppServices.instance.messages.abort(this.deviceId, this.sessionId);
    }).finally(() => {
      this.queueBusy = false;
    });
  }

  private retryLoad(): void {
    this.loadFailed = false;
    this.initialScrolled = false;
    this.initialScrollSettling = true;
    this.initialScrollGeneration += 1;
    this.initialLoadGeneration += 1;
    this.sessionOpenResolved = false;
    this.initialLoadResolved = false;
    this.showInitialSync = false;
    this.followingLatest = true;
    this.hasNewMessages = false;
    this.visibleStartIndex = 0;
    this.visibleEndIndex = -1;
    this.listTouchStartY = 0;
    this.listTouchActive = false;
    this.listTouchPulledDown = false;
    this.listTouchPushedUp = false;
    this.listTouchLoadTriggered = false;
    this.hasOlderMessages = false;
    this.historyReviewIntent = false;
    this.initialHistoryAutofillRemaining = INITIAL_HISTORY_AUTOFILL_PAGES;
    this.historyLastAttemptFirstKey = '';
    this.historyAnchorRestoreGeneration += 1;
    this.pendingHistoryAnchorRestore = undefined;
    this.syncMessageCount();
    this.beginInitialLoad();
  }

  /** 历史 + 流式统一进入同一个渲染模型，并把会话是否正在流式传入聚合层。 */
  private refreshItems(): void {
    this.syncMessageCount();
    const previousTailToken = this.renderTailToken(this.items);
    const projection = AppServices.instance.inputQueue.getProjection(this.sessionId);
    const messages = appendAutoResumePendingMessage(
      AppServices.instance.messages.getMessagesWithStreaming(this.sessionId),
      projection.autoResumePending,
    );
    const deliveredClientIds = new Set<string>();
    for (let i = 0; i < messages.length; i++) {
      if (messages[i].clientId.length > 0) deliveredClientIds.add(messages[i].clientId);
    }
    AppServices.instance.inputQueue.setDeliveredClientIds(this.sessionId, deliveredClientIds);
    const streaming = AppServices.instance.messages.isSessionStreaming(this.sessionId);
    const nextItems = buildRenderItems(
      messages,
      streaming,
      AppServices.instance.messages.getTaskUpdates(this.sessionId),
      AppServices.instance.messages.isMakerTurnRunning(this.sessionId),
      projection.continuationTurnClientId,
      projection.continuationInFlightProjectionCapability,
      AppServices.instance.messages.isMakerTurnRunning(this.sessionId),
    );
    const nextTailToken = this.renderTailToken(nextItems);
    const tailChanged = previousTailToken.length > 0 && previousTailToken !== nextTailToken;
    this.sessionStreaming = streaming;
    if (streaming) this.tailInterruptAcked = true;
    this.syncWorkClock(streaming);
    this.tableColumnWidthCache.clear();
    this.reconcileCollapsedTodoCards(this.items, nextItems);
    this.items = nextItems;
    this.reconcileSearchSelection();
    this.loadFailed = AppServices.instance.messages.loadFailed(this.sessionId);
    this.ensureImageUrls();
    if (this.sessionOpenResolved && this.items.length > 0 && !this.initialScrolled) {
      if (this.routeMessageClientId.length > 0) this.focusMessageTarget();
      else this.scrollToBottomOnce();
      return;
    }
    if (!tailChanged || this.loadingOlder || !this.sessionOpenResolved) return;
    if (this.followingLatest) {
      this.followLatestSoon();
    } else {
      this.hasNewMessages = true;
    }
  }

  /** 尾部内容 token 同时覆盖同 key 的流式正文增长和工作组内部步骤变化。 */
  private renderTailToken(items: RenderItem[]): string {
    if (items.length === 0) return '';
    const item = items[items.length - 1];
    if (item.type === 'message') {
      const message = item as RenderMessageItem;
      const streaming = message.message !== undefined && message.message.isStreaming ? '1' : '0';
      return `${item.key}:message:${message.body.length}:${message.images.length}:${streaming}`;
    }
    if (item.type === 'work_group') {
      const work = item as RenderWorkGroupItem;
      return `${item.key}:work:${work.children.length}:${work.isStreaming ? '1' : '0'}:${this.renderTailToken(work.children)}`;
    }
    if (item.type === 'tool_group') {
      const tools = (item as RenderToolGroupItem).tools;
      if (tools.length === 0) return `${item.key}:tools:0`;
      const tool = tools[tools.length - 1];
      return `${item.key}:tools:${tools.length}:${tool.hasResult ? '1' : '0'}:${tool.resultText.length}:${tool.media.length}`;
    }
    if (item.type === 'tool_media') {
      const media = item as RenderToolMediaItem;
      return `${item.key}:media:${media.images.length}`;
    }
    if (item.type === 'agent_task') {
      const task = item as RenderAgentTaskItem;
      const status = this.agentTaskStatus(task);
      const progress = task.update !== null ? task.update.workflowProgress.length : 0;
      return `${item.key}:agent:${status}:${progress}`;
    }
    if (item.type === 'subagent_group') {
      const group = item as RenderSubagentGroupItem;
      return `${item.key}:subagent:${group.status}:${group.children.length}:${this.renderTailToken(group.children)}`;
    }
    if (item.type === 'thinking') {
      return `${item.key}:thinking:${(item as RenderThinkingItem).body.length}`;
    }
    return item.key;
  }

  /** List 顶部的“加载更早消息”也是一个 ListItem，所有渲染项索引都要补这个偏移。 */
  private renderListIndex(renderIndex: number): number {
    return renderIndex + (this.hasOlderMessages ? 1 : 0);
  }

  private renderItemContainsClientId(item: RenderItem, clientId: string): boolean {
    if (clientId.length === 0) return false;
    if (item.type === 'message') {
      const message = (item as RenderMessageItem).message;
      return message !== undefined && (message.clientId === clientId || message.id === clientId);
    }
    if (item.type === 'work_group') {
      const children = (item as RenderWorkGroupItem).children;
      return children.some((child: RenderItem) => this.renderItemContainsClientId(child, clientId));
    }
    if (item.type === 'subagent_group') {
      const children = (item as RenderSubagentGroupItem).children;
      return children.some((child: RenderItem) => this.renderItemContainsClientId(child, clientId));
    }
    return false;
  }

  private messageRenderIndex(clientId: string): number {
    for (let i = 0; i < this.items.length; i++) {
      if (this.renderItemContainsClientId(this.items[i], clientId)) return i;
    }
    return -1;
  }

  private focusMessageTarget(): void {
    const target = this.routeMessageClientId;
    if (target.length === 0) return;
    const index = this.messageRenderIndex(target);
    if (index >= 0) {
      this.initialScrolled = true;
      this.initialScrollSettling = false;
      this.followingLatest = false;
      this.focusedMessageClientId = target;
      // 深链定位只在首次找目标期间屏蔽自动分页；定位成功后必须解除，
      // 否则用户随后滚到顶部永远不会触发近顶预取。
      this.routeMessageClientId = '';
      const generation = this.messageFocusGeneration;
      setTimeout(() => {
        if (generation !== this.messageFocusGeneration) return;
        this.listScroller.scrollToIndex(this.renderListIndex(index), true, ScrollAlign.CENTER);
      }, 80);
      setTimeout(() => {
        if (generation === this.messageFocusGeneration
          && this.focusedMessageClientId === target) this.focusedMessageClientId = '';
      }, 1800);
      return;
    }
    if (!this.sessionOpenResolved || this.messageFocusLoadStarted) return;
    this.messageFocusLoadStarted = true;
    const generation = ++this.messageFocusGeneration;
    AppServices.instance.messages.loadAroundClientId(
      this.deviceId, this.sessionId, target, 60,
    ).then((found: boolean) => {
      if (generation !== this.messageFocusGeneration) return;
      this.refreshItems();
      this.messageFocusLoadStarted = false;
      if (found) {
        this.focusMessageTarget();
      } else {
        this.initialScrolled = false;
        this.routeMessageClientId = '';
        this.scrollToBottomOnce();
        promptAction.showToast({ message: '找不到这条消息，可能已被删除' });
      }
    }).catch(() => {
      if (generation !== this.messageFocusGeneration) return;
      this.messageFocusLoadStarted = false;
      promptAction.showToast({ message: '消息定位失败，请检查连接后重试' });
    });
  }

  private hasQueueStateBanner(): boolean {
    return this.queuePaused || this.queueProjectionError.length > 0
      || this.queueCredentialWaiting || this.queueAbortPending;
  }

  /** 固定的尾部 sentinel 索引；必须覆盖消息后的状态卡、尾部卡和排队气泡。 */
  private bottomSentinelListIndex(): number {
    return messageListBottomIndex(
      this.hasOlderMessages,
      this.items.length,
      this.hasQueueStateBanner(),
      this.tailPresentation() !== null,
      this.queueBubbles.length,
    );
  }

  /** 贴底态的流式补滚；不在用户回看历史或 prepend 期间抢阅读位置。 */
  private followLatestSoon(): void {
    if (this.followScrollScheduled) {
      this.followScrollTrailingRequested = true;
      return;
    }
    this.followScrollScheduled = true;
    this.followScrollTrailingRequested = false;
    const sessionGeneration = this.initialScrollGeneration;
    const followGeneration = this.followScrollGeneration;
    const scroll = (isLast: boolean): void => {
      if (isLast && followGeneration === this.followScrollGeneration) {
        this.followScrollScheduled = false;
        if (this.followScrollTrailingRequested) {
          this.followScrollTrailingRequested = false;
          this.followLatestSoon();
        }
      }
      if (sessionGeneration !== this.initialScrollGeneration
        || followGeneration !== this.followScrollGeneration
        || !this.followingLatest
        || this.loadingOlder
        || (this.items.length === 0 && this.queueBubbles.length === 0)) return;
      this.listScroller.scrollToIndex(this.bottomSentinelListIndex(), false, ScrollAlign.END);
    };
    for (let i = 0; i < FOLLOW_LATEST_RETRY_DELAYS.length; i++) {
      const isLast = i === FOLLOW_LATEST_RETRY_DELAYS.length - 1;
      setTimeout(() => scroll(isLast), FOLLOW_LATEST_RETRY_DELAYS[i]);
    }
  }

  private jumpToLatest(): void {
    this.followingLatest = true;
    this.hasNewMessages = false;
    this.historyAnchorRestoreGeneration += 1;
    if (this.pendingHistoryAnchorRestore !== undefined) {
      this.pendingHistoryAnchorRestore = undefined;
      this.loadingOlder = false;
    }
    this.followScrollGeneration += 1;
    this.followScrollScheduled = false;
    this.followScrollTrailingRequested = false;
    if (this.items.length > 0 || this.queueBubbles.length > 0) {
      this.listScroller.scrollToIndex(this.bottomSentinelListIndex(), true, ScrollAlign.END);
    }
  }

  private tailContinuationInFlight(): boolean {
    const projection = AppServices.instance.inputQueue.getProjection(this.sessionId);
    if (projection.pendingQueue.some((item: QueuedInputItem) => isContinuationText(item.text))) return true;
    return this.queueBubbles.some((item: PendingQueueBubble) => isContinuationText(item.text));
  }

  private tailPresentation(): SessionTailPresentation | null {
    const projection = AppServices.instance.inputQueue.getProjection(this.sessionId);
    return deriveSessionTailPresentation(
      AppServices.instance.messages.getMessages(this.sessionId),
      this.session(),
      projection.error,
      projection.credentialSwitchWaiting,
      this.sessionStreaming,
      this.tailContinuationInFlight(),
      this.tailInterruptAcked,
      this.tailHiddenErrorClientIds,
    );
  }

  private continueSessionTail(): void {
    const presentation = this.tailPresentation();
    const session = this.session();
    if (presentation === null || session === undefined || this.tailBannerBusy
      || (!presentation.retryable && !presentation.interrupted)) return;
    const prompt = presentation.interrupted
      ? CONTINUE_AFTER_APP_EXIT_PROMPT : CONTINUE_AFTER_ERROR_PROMPT;
    const serialized = new SerializedComposerDocument();
    serialized.text = prompt;
    this.tailBannerBusy = true;
    if (presentation.kind === 'error-tail') {
      this.tailHiddenErrorClientIds = this.tailHiddenErrorClientIds.concat([presentation.clientId]);
    } else {
      this.tailInterruptAcked = true;
    }
    AppServices.instance.inputQueue.enqueueDocument(
      this.deviceId, session, serialized, [], [], '', false,
    ).catch(() => {
      if (presentation.kind === 'error-tail') {
        this.tailHiddenErrorClientIds = this.tailHiddenErrorClientIds.filter(
          (clientId: string) => clientId !== presentation.clientId);
      } else {
        this.tailInterruptAcked = false;
      }
      promptAction.showToast({ message: '任务未能继续，请检查连接后重试' });
    }).finally(() => {
      this.tailBannerBusy = false;
    });
  }

  private dismissSessionTail(): void {
    const presentation = this.tailPresentation();
    if (presentation === null || this.tailBannerBusy) return;
    if (presentation.kind === 'error-tail') {
      this.tailHiddenErrorClientIds = this.tailHiddenErrorClientIds.concat([presentation.clientId]);
      void AppServices.instance.messages.dismissErrorMessage(
        this.deviceId, this.sessionId, presentation.clientId).catch(() => {
        // 老被控端可在本视图内降级为隐藏；下次重进仍会再次提示。
      });
    } else {
      this.tailInterruptAcked = true;
      void AppServices.instance.messages.ackInterruptedTurn(
        this.deviceId, this.sessionId).catch(() => {
      });
    }
    this.refreshItems();
  }

  /** 活动工作组使用实时 elapsed，而不是每次事件生成的 duration 快照。 */
  private syncWorkClock(active: boolean): void {
    if (!active) {
      this.stopWorkClock();
      return;
    }
    this.workClockNowMs = Date.now();
    if (this.workClockTimer >= 0) return;
    this.workClockTimer = setInterval(() => {
      this.workClockNowMs = Date.now();
    }, 500);
  }

  private stopWorkClock(): void {
    if (this.workClockTimer >= 0) {
      clearInterval(this.workClockTimer);
      this.workClockTimer = -1;
    }
  }

  private workElapsedMs(item: RenderWorkGroupItem): number {
    if (item.isStreaming && item.startedAtMs > 0) {
      return Math.max(0, this.workClockNowMs - item.startedAtMs);
    }
    return item.durationMs;
  }

  /** 底部“思考中”按产品 turn 独立计时，不复用某一个 work_group 的 startedAt。 */
  private sessionActivityElapsedText(): string {
    const startedAt = AppServices.instance.messages.getSessionRunStartedAt(this.sessionId);
    return formatSessionActivityElapsed(sessionActivityElapsedMs(this.workClockNowMs, startedAt));
  }

  /** 进入会话/重试后定位到最新消息；等待列表完成布局，并阻止首屏翻页抢占锚点。 */
  private scrollToBottomOnce(): void {
    if (this.initialScrolled) {
      return;
    }
    if (this.items.length === 0) {
      return;
    }
    this.initialScrolled = true;
    this.followingLatest = true;
    this.hasNewMessages = false;
    const generation = this.initialScrollGeneration;
    const scroll = (): void => {
      if (generation !== this.initialScrollGeneration || !this.followingLatest
        || this.loadingOlder || this.items.length === 0) return;
      // 滚到消息后的固定 sentinel，而不是可能仍在变高的流式消息节点；尾部状态卡
      // 与排队气泡也由该索引统一纳入真实列表末端。
      this.listScroller.scrollToIndex(this.bottomSentinelListIndex(), false, ScrollAlign.END);
    };
    setTimeout(scroll, 120);
    setTimeout(scroll, 450);
    setTimeout(scroll, 900);
    setTimeout(() => {
      if (generation === this.initialScrollGeneration) {
        this.initialScrollSettling = false;
        // 对齐 iOS：若首屏短到仍处于近顶区，最多自动补三页；较长首屏在
        // 落底后不 nearStart，不会产生额外请求。
        this.attemptAutoLoadEarlier();
      }
    }, 1050);
  }

  /** 短首屏没有可用滚动索引时，对齐 Mobile：用户手指下滑才请求更早历史。 */
  private handleListTouch(event: TouchEvent): void {
    if (event.changedTouches.length === 0) return;
    const point = event.changedTouches[0];
    if (event.type === TouchType.Down) {
      this.listTouchStartY = point.displayY;
      this.listTouchActive = true;
      this.historyAnchorRestoreGeneration += 1;
      this.listTouchPulledDown = false;
      this.listTouchPushedUp = false;
      this.listTouchLoadTriggered = false;
      return;
    }
    if (event.type === TouchType.Move) {
      const deltaY = point.displayY - this.listTouchStartY;
      // 手指向下超过 8vp 代表明确回看历史。长列表立即解除贴底，后续流式
      // content change 不再把用户拽回末尾；短列表不解除，避免 bounce 误判。
      if (deltaY > 8) {
        const beginsHistoryGesture = !this.listTouchPulledDown;
        this.listTouchPulledDown = true;
        // 空页、重复页或网络失败会保留同一首项去重；新的明确下拉手势
        // 解除这次止损，允许用户恢复网络后重试一次。
        if (beginsHistoryGesture && !this.loadingOlder) {
          this.historyLastAttemptFirstKey = '';
        }
        if (!this.historyReviewIntent) {
          this.historyReviewIntent = true;
        }
        if (this.visibleStartIndex > 0) {
          this.followingLatest = false;
        }
        this.attemptAutoLoadEarlier();
      }
      // 手指向上是回到最新消息的方向；尾项重新可见后恢复贴底跟随。
      if (deltaY < -8) {
        this.listTouchPushedUp = true;
        if (this.visibleEndIndex >= this.bottomSentinelListIndex()) {
          this.followingLatest = true;
          this.hasNewMessages = false;
        }
      }
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.listTouchActive = false;
      const pendingAnchorRestore = this.pendingHistoryAnchorRestore;
      this.pendingHistoryAnchorRestore = undefined;
      if (pendingAnchorRestore !== undefined) pendingAnchorRestore();
      if (this.listTouchPushedUp && this.visibleEndIndex >= this.bottomSentinelListIndex()) {
        this.followingLatest = true;
        this.hasNewMessages = false;
      }
      this.listTouchStartY = 0;
      this.listTouchPulledDown = false;
      this.listTouchPushedUp = false;
      this.listTouchLoadTriggered = false;
    }
  }

  /**
   * 加载一页更早历史。真实上翻保持旧首项锚点；冷开自动补窗则继续贴住尾部，
   * 避免后台 prepend 把用户从最新消息带到历史位置。
   */
  private loadOlder(
    continueSearch: boolean = false,
    initialAutofill: boolean = false,
  ): void {
    if (this.loadingOlder) {
      return;
    }
    const hadOlderMessages = this.hasOlderMessages;
    if (!hadOlderMessages) {
      return;
    }
    const msgs = AppServices.instance.messages.getMessages(this.sessionId);
    if (msgs.length === 0) {
      return;
    }
    const keepFollowingLatest = initialAutofill
      && !this.historyReviewIntent && this.followingLatest;
    if (!keepFollowingLatest) {
      // 一旦由用户进入历史分页就视为正在阅读旧内容；分页锚定完成前后的流式
      // 更新都不能再把阅读位置抢回尾部。
      this.followingLatest = false;
      this.followScrollGeneration += 1;
      this.followScrollScheduled = false;
      this.followScrollTrailingRequested = false;
      this.historyReviewIntent = true;
    }
    // 不能用“新增原始消息数”作为 List index：多个 thinking/tool 行会被渲染模型
    // 合成一个 work_group，原始消息下标与可见 ListItem 下标并不相等。
    const previousVisibleRenderIndex = firstVisibleMessageRenderIndex(
      hadOlderMessages,
      this.visibleStartIndex,
      this.items.length,
    );
    const previousVisibleRenderAnchor = previousVisibleRenderIndex >= 0
      ? this.renderAnchorKey(this.items[previousVisibleRenderIndex], this.items) : '';
    let previousVisibleOffsetY = 0;
    if (previousVisibleRenderIndex >= 0) {
      try {
        const rect = this.listScroller.getItemRect(
          this.renderListIndex(previousVisibleRenderIndex));
        if (Number.isFinite(rect.y)) previousVisibleOffsetY = rect.y;
      } catch (e) {
        // 极短列表或布局切换瞬间可能尚未绑定可见 item；稳定 key 仍可兜底。
      }
    }
    const requestFirstKey = this.items.length > 0
      ? this.renderAnchorKey(this.items[0], this.items) : '';
    this.historyLastAttemptFirstKey = requestFirstKey;
    const previousRenderCount = this.items.length;
    const anchorRestoreGeneration = ++this.historyAnchorRestoreGeneration;
    this.loadingOlder = true;
    AppServices.instance.messages.loadOlder(this.deviceId, this.sessionId).then((added: number) => {
      const historyHeaderChanged = hadOlderMessages !== this.hasOlderMessages;
      if (added > 0 || historyHeaderChanged) {
        const stillFollowingLatest = keepFollowingLatest
          && !this.historyReviewIntent && this.followingLatest && !this.listTouchActive;
        if (stillFollowingLatest) {
          this.loadingOlder = false;
          // 冷开补窗只向上扩充数据，不改变“正在看最新消息”的意图。
          this.followLatestSoon();
        } else {
          // 新加载的更早消息插在头部：回到 prepend 前的首个可见渲染项，保持阅读点。
          // 这是桌面/Mobile 的 mVCP 语义在 ArkUI List 上的稳定 key 版本。
          setTimeout(() => {
            const restoreAnchor = (): void => {
              this.loadingOlder = false;
              if (anchorRestoreGeneration !== this.historyAnchorRestoreGeneration) {
                setTimeout(() => this.attemptAutoLoadEarlier(), 60);
                return;
              }
              if (continueSearch && this.searchOpen && this.searchQuery.trim().length > 0) {
                this.reconcileSearchSelection();
                const hits = this.searchHits();
                if (hits.length > 0) this.focusSearchHit(hits[this.searchActiveIndex]);
              } else {
                const anchorIndex = this.renderItemIndexContainingAnchor(previousVisibleRenderAnchor);
                if (anchorIndex >= 0) {
                  this.listScroller.scrollToIndex(
                    this.renderListIndex(anchorIndex),
                    false,
                    ScrollAlign.START,
                    { extraOffset: LengthMetrics.vp(-previousVisibleOffsetY) },
                  );
                } else {
                  // fallback 也只能使用可见 render item 数，不能混用原始 DB 行数。
                  const visibleAdded = Math.max(0, this.items.length - previousRenderCount);
                  const fallbackIndex = Math.min(
                    Math.max(0, previousVisibleRenderIndex) + visibleAdded,
                    Math.max(0, this.items.length - 1),
                  );
                  this.listScroller.scrollToIndex(this.renderListIndex(fallbackIndex), false);
                }
              }
              setTimeout(() => this.attemptAutoLoadEarlier(), 60);
            };
            if (this.listTouchActive) {
              // ArkUI 不保证活动手势中的 prepend 自动维持内容；等抬手后再执行
              // 同一锚点，且 loadingOlder 保持 true，避免期间又发起下一页。
              this.pendingHistoryAnchorRestore = restoreAnchor;
            } else {
              restoreAnchor();
            }
          }, 50);
          return;
        }
      } else {
        this.loadingOlder = false;
      }
      setTimeout(() => this.attemptAutoLoadEarlier(), 240);
    }).catch(() => {
      this.loadingOlder = false;
    });
  }

  private nearHistoryStart(): boolean {
    const visibleCount = Math.max(1, this.visibleEndIndex - this.visibleStartIndex + 1);
    return this.visibleStartIndex <= Math.max(1, visibleCount * 2);
  }

  private attemptAutoLoadEarlier(): void {
    const firstKey = this.items.length > 0
      ? this.renderAnchorKey(this.items[0], this.items) : '';
    if (this.routeMessageClientId.length > 0 || !shouldAutoLoadEarlier(
      this.historyReviewIntent,
      this.initialHistoryAutofillRemaining,
      this.followingLatest,
      this.sessionOpenResolved,
      this.initialScrollSettling,
      this.loadingOlder,
      this.nearHistoryStart(),
      this.hasOlderMessages,
      this.items.length,
      firstKey,
      this.historyLastAttemptFirstKey,
    )) return;
    const initialAutofill = !this.historyReviewIntent;
    if (initialAutofill) this.initialHistoryAutofillRemaining -= 1;
    this.listTouchLoadTriggered = true;
    this.loadOlder(false, initialAutofill);
  }

  /** todo 卡标题（对齐 iOS：{completed}/{total} · 进行中内容）。 */
  private todoTitle(item: RenderTodoCardItem): string {
    let doneCount = 0;
    let activeContent = '';
    for (let i = 0; i < item.todos.length; i++) {
      const t = item.todos[i];
      if (t.status === 'completed') {
        doneCount += 1;
      } else if (t.status === 'in_progress' && activeContent.length === 0) {
        activeContent = t.content;
      }
    }
    const base = `${doneCount}/${item.todos.length}`;
    if (activeContent.length === 0 && item.todos.length > 0) {
      activeContent = item.todos[item.todos.length - 1].content;
    }
    return activeContent.length > 0 ? `${base} · ${activeContent}` : base;
  }

  /** 思考卡标题（对齐 iOS：思考中 / 思考 Xs / 思考内容已隐藏）。 */
  private thinkingTitle(item: RenderThinkingItem): string {
    if (item.redacted) {
      return '思考内容已隐藏';
    }
    if (item.durationMs > 0) {
      return `思考 ${this.formatDuration(item.durationMs)}`;
    }
    return '思考过程';
  }

  /** 工作过程标题（对齐 iOS：已工作 Xs / 工作过程）。 */
  private workGroupTitle(item: RenderWorkGroupItem): string {
    if (item.isStreaming) {
      return '正在工作…';
    }
    let base = '工作过程';
    if (item.durationMs >= 0) {
      base = `已工作 ${this.formatDuration(item.durationMs)}`;
    }
    const summary = workExplorationSummary(item);
    return summary.length > 0 ? `${base} · ${summary}` : base;
  }

  private compactBoundaryLabel(item: RenderMessageItem): string {
    const message = item.message;
    if (message !== undefined && readStr(message.systemCardData, 'trigger') === 'manual') {
      return '手动压缩';
    }
    return '自动压缩';
  }

  /** 时长格式化（对齐 shared formatDuration：Xs / Xm Ys / Xh Ym）。 */
  private formatDuration(ms: number): string {
    if (ms <= 0) {
      return '1s';
    }
    const totalSeconds = Math.max(1, Math.round(ms / 1000));
    if (totalSeconds < 60) {
      return `${totalSeconds}s`;
    }
    const minutes = Math.floor(totalSeconds / 60);
    const seconds = totalSeconds % 60;
    if (minutes < 60) {
      return seconds > 0 ? `${minutes}m ${seconds}s` : `${minutes}m`;
    }
    const hours = Math.floor(minutes / 60);
    const restMinutes = minutes % 60;
    return restMinutes > 0 ? `${hours}h ${restMinutes}m` : `${hours}h`;
  }

  private toggleExpanded(list: string[], key: string): string[] {
    const idx = list.indexOf(key);
    if (idx >= 0) {
      const out = list.slice(0, idx).concat(list.slice(idx + 1));
      return out;
    }
    return list.concat([key]);
  }

  private toggleTextBlock(key: string): void {
    uiAnimateState(this.getUIContext(), () => {
      this.expandedTextBlocks = this.toggleExpanded(this.expandedTextBlocks, key);
    });
  }

  private toggleThinkingBlock(key: string): void {
    uiAnimateState(this.getUIContext(), () => {
      this.expandedThinking = this.toggleExpanded(this.expandedThinking, key);
    });
  }

  private toggleWorkGroup(key: string): void {
    uiAnimateState(this.getUIContext(), () => {
      this.expandedWorkGroups = this.toggleExpanded(this.expandedWorkGroups, key);
    });
  }

  private toggleTodoCard(key: string): void {
    uiAnimateState(this.getUIContext(), () => {
      this.collapsedTodoCards = this.toggleExpanded(this.collapsedTodoCards, key);
    });
  }

  private todoCardExpanded(key: string): boolean {
    return !this.isIn(this.collapsedTodoCards, key);
  }

  /** 计划补齐更早历史后 key 可能从 orphan tool id 切到 turn id；按内容迁移折叠态。 */
  private reconcileCollapsedTodoCards(previous: RenderItem[], next: RenderItem[]): void {
    if (this.collapsedTodoCards.length === 0) return;
    const previousCards: RenderTodoCardItem[] = [];
    const nextCards: RenderTodoCardItem[] = [];
    this.collectTodoCards(previous, previousCards);
    this.collectTodoCards(next, nextCards);
    const migrated: string[] = [];
    const used = new Set<string>();
    for (let i = 0; i < this.collapsedTodoCards.length; i++) {
      const oldKey = this.collapsedTodoCards[i];
      const exact = nextCards.find((card: RenderTodoCardItem) => card.key === oldKey);
      if (exact !== undefined) {
        migrated.push(exact.key);
        used.add(exact.key);
        continue;
      }
      const oldCard = previousCards.find((card: RenderTodoCardItem) => card.key === oldKey);
      if (oldCard === undefined) continue;
      const signature = todoCardContentSignature(oldCard);
      const rank = todoCardRankFromTail(previousCards, oldCard.key);
      const replacementIndex = todoCardIndexAtRankFromTail(nextCards, signature, rank);
      const replacement = replacementIndex >= 0 ? nextCards[replacementIndex] : undefined;
      if (replacement !== undefined && !used.has(replacement.key)) {
        migrated.push(replacement.key);
        used.add(replacement.key);
      }
    }
    let changed = migrated.length !== this.collapsedTodoCards.length;
    for (let i = 0; !changed && i < migrated.length; i++) {
      if (migrated[i] !== this.collapsedTodoCards[i]) changed = true;
    }
    if (changed) this.collapsedTodoCards = migrated;
  }

  private collectTodoCards(items: RenderItem[], out: RenderTodoCardItem[]): void {
    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      if (item.type === 'todo') {
        out.push(item as RenderTodoCardItem);
      } else if (item.type === 'work_group') {
        this.collectTodoCards((item as RenderWorkGroupItem).children, out);
      } else if (item.type === 'subagent_group') {
        this.collectTodoCards((item as RenderSubagentGroupItem).children, out);
      }
    }
  }

  private toggleToolDetails(key: string): void {
    uiAnimateState(this.getUIContext(), () => {
      this.expandedTools = this.toggleExpanded(this.expandedTools, key);
    });
  }

  private isIn(list: string[], key: string): boolean {
    return list.indexOf(key) >= 0;
  }

  /** 保存稳定叶子，而不是可能因 prepend 改名的外层 work_group key。 */
  private renderAnchorKey(item: RenderItem, allItems: RenderItem[]): string {
    if (item.type === 'todo') {
      const todo = item as RenderTodoCardItem;
      const cards: RenderTodoCardItem[] = [];
      this.collectTodoCards(allItems, cards);
      const rank = todoCardRankFromTail(cards, todo.key);
      return `todo:${todo.key}\u001e${rank}\u001e${todoCardContentSignature(todo)}`;
    } else if (item.type === 'work_group') {
      const children = (item as RenderWorkGroupItem).children;
      for (let i = 0; i < children.length; i++) {
        const nested = this.renderAnchorKey(children[i], allItems);
        if (nested.length > 0) return nested;
      }
    } else if (item.type === 'subagent_group') {
      const children = (item as RenderSubagentGroupItem).children;
      for (let i = 0; i < children.length; i++) {
        const nested = this.renderAnchorKey(children[i], allItems);
        if (nested.length > 0) return nested;
      }
    } else if (item.type === 'tool_group') {
      const tools = (item as RenderToolGroupItem).tools;
      if (tools.length > 0 && tools[0].toolUseId.length > 0) {
        return `tool:${tools[0].toolUseId}`;
      }
    }
    return item.key.length > 0 ? `item:${item.key}` : '';
  }

  private renderItemContainsAnchor(item: RenderItem, anchor: string): boolean {
    if (anchor.length === 0) return false;
    if (anchor.startsWith('item:') && item.key === anchor.slice(5)) return true;
    if (anchor.startsWith('todo:') && item.type === 'todo') {
      const payload = anchor.slice(5);
      const separator = payload.indexOf('\u001e');
      const oldKey = separator >= 0 ? payload.slice(0, separator) : payload;
      return item.key === oldKey;
    }
    if (item.type === 'tool_group' && anchor.startsWith('tool:')) {
      const toolUseId = anchor.slice(5);
      return (item as RenderToolGroupItem).tools.some(
        (tool: RenderToolItem) => tool.toolUseId === toolUseId);
    }
    if (item.type === 'work_group') {
      const children = (item as RenderWorkGroupItem).children;
      return children.some((child: RenderItem) => this.renderItemContainsAnchor(child, anchor));
    }
    if (item.type === 'subagent_group') {
      const children = (item as RenderSubagentGroupItem).children;
      return children.some((child: RenderItem) => this.renderItemContainsAnchor(child, anchor));
    }
    return false;
  }

  /**
   * 子 Agent 外层也是普通对象节点：外层不重建时，内部 ForEach 不会重新执行。
   * 因此把自身 running/completed 与后代工作组的生命周期压成紧凑状态签名；
   * 新增或移除后代工作组也会改变签名。其它后代内容仍由各自节点更新。
   */
  private renderItemLifecycleState(item: RenderItem): string {
    if (item.type === 'work_group') {
      const work = item as RenderWorkGroupItem;
      return work.isStreaming ? 'w1' : 'w0';
    }
    if (item.type !== 'subagent_group') return '';
    const group = item as RenderSubagentGroupItem;
    const states: string[] = [];
    for (let i = 0; i < group.children.length; i++) {
      const state = this.renderItemLifecycleState(group.children[i]);
      if (state.length > 0) states.push(`${i}:${state.length}:${state}`);
    }
    return `s:${group.status.length}:${group.status}:${states.join(',')}`;
  }

  /** 业务 key 保持稳定，仅让会改变 builder 分支的工作/子 Agent 状态重建节点。 */
  private renderItemNodeKey(item: RenderItem, prefix: string = ''): string {
    const streaming = item.type === 'work_group'
      && (item as RenderWorkGroupItem).isStreaming;
    return messageListRenderNodeKey(
      `${prefix}${item.key}`,
      item.type,
      streaming,
      this.renderItemLifecycleState(item),
    );
  }

  private renderItemIndexContainingAnchor(anchor: string): number {
    for (let i = 0; i < this.items.length; i++) {
      if (this.renderItemContainsAnchor(this.items[i], anchor)) return i;
    }
    if (anchor.startsWith('todo:')) {
      const payload = anchor.slice(5);
      const firstSeparator = payload.indexOf('\u001e');
      const secondSeparator = firstSeparator >= 0
        ? payload.indexOf('\u001e', firstSeparator + 1) : -1;
      if (secondSeparator > firstSeparator) {
        const rank = Number(payload.slice(firstSeparator + 1, secondSeparator));
        const signature = payload.slice(secondSeparator + 1);
        if (Number.isSafeInteger(rank) && rank >= 0 && signature.length > 0) {
          const cards: RenderTodoCardItem[] = [];
          const topLevelIndices: number[] = [];
          for (let i = 0; i < this.items.length; i++) {
            const nested: RenderTodoCardItem[] = [];
            this.collectTodoCards([this.items[i]], nested);
            for (let j = 0; j < nested.length; j++) {
              cards.push(nested[j]);
              topLevelIndices.push(i);
            }
          }
          const cardIndex = todoCardIndexAtRankFromTail(cards, signature, rank);
          if (cardIndex >= 0) return topLevelIndices[cardIndex];
        }
      }
    }
    return -1;
  }

  private headerNotice(): string {
    if (this.deviceDisabled) return '设备已关闭远程控制，仅可查看';
    if (!this.initialLoadResolved && this.showInitialSync) return '正在同步';
    if (this.loadFailed) return '同步失败';
    if (this.pendingInteractions.length > 0) return `待处理 ${this.pendingInteractions.length}`;
    if (this.sessionStreaming) return '运行中';
    return '';
  }

  private searchHits(): MessageSearchHit[] {
    return findMessageSearchHits(this.items, this.searchQuery);
  }

  private reconcileSearchSelection(): void {
    if (!this.searchOpen || this.searchQuery.trim().length === 0) return;
    const hits = this.searchHits();
    const next = reconcileMessageSearchIndex(
      hits, this.searchActiveIndex, this.searchActiveSourceKey);
    if (next < 0) {
      this.searchActiveIndex = 0;
      this.searchActiveSourceKey = '';
      return;
    }
    this.searchActiveIndex = next;
    this.searchActiveSourceKey = hits[next].sourceKey;
  }

  private updateSearchQuery(value: string): void {
    this.searchQuery = value;
    this.searchActiveIndex = 0;
    const hits = this.searchHits();
    this.searchActiveSourceKey = hits.length > 0 ? hits[0].sourceKey : '';
    this.focusedSearchItemKey = '';
  }

  private focusSearchHit(hit: MessageSearchHit): void {
    let index = -1;
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].key === hit.itemKey) {
        index = i;
        break;
      }
    }
    if (index < 0) return;
    this.followingLatest = false;
    this.focusedSearchItemKey = hit.itemKey;
    this.listScroller.scrollToIndex(this.renderListIndex(index), true, ScrollAlign.CENTER);
    const sourceKey = hit.sourceKey;
    setTimeout(() => {
      if (this.searchActiveSourceKey === sourceKey) this.focusedSearchItemKey = '';
    }, 1600);
  }

  private moveSearch(delta: number): void {
    const hits = this.searchHits();
    if (hits.length === 0) return;
    const next = nextMessageSearchIndex(hits.length, this.searchActiveIndex, delta);
    if (next < 0) return;
    this.searchActiveIndex = next;
    this.searchActiveSourceKey = hits[next].sourceKey;
    this.focusSearchHit(hits[next]);
  }

  private searchPaging(): MessageSearchPagingPresentation {
    return messageSearchPagingPresentation(
      this.searchQuery,
      this.hasOlderMessages,
      this.loadingOlder,
      this.searchHits().length,
    );
  }

  private closeSearch(): void {
    uiAnimateState(this.getUIContext(), () => {
      this.searchOpen = false;
      this.searchQuery = '';
      this.searchActiveIndex = 0;
      this.searchActiveSourceKey = '';
      this.focusedSearchItemKey = '';
    });
  }

  private openSearch(): void {
    uiAnimateState(this.getUIContext(), () => {
      this.searchOpen = true;
    });
  }

  private closeImagePreview(): void {
    uiAnimateFastState(this.getUIContext(), () => {
      this.previewImageUrl = '';
    });
  }

  private hasComposerContent(): boolean {
    return composerDocumentHasContent(this.composerDocument)
      || this.composerImages.length > 0 || this.composerFiles.length > 0;
  }

  private canSend(): boolean {
    if (this.sending || this.deviceDisabled) return false;
    if (pendingInteractionsBlockRemoteComposer(this.pendingInteractions)) return false;
    if (!this.imageQueue.allSettled() || !this.fileQueue.allSettled()) return false;
    return composerDocumentHasContent(this.composerDocument)
      || this.imageQueue.readyImages().length > 0 || this.fileQueue.readyFiles().length > 0;
  }

  private restoreComposerDraft(): void {
    const sessionId = this.sessionId;
    const generation = ++this.composerDraftGeneration;
    void AppServices.instance.composerDrafts.read(sessionId).then((document: ComposerDocument | null) => {
      if (generation !== this.composerDraftGeneration || sessionId !== this.sessionId
        || document === null || this.creationDraftHandoffDone) return;
      this.setComposerDocument(document, false);
    });
  }

  private setComposerDocument(document: ComposerDocument, persist: boolean = true): void {
    this.composerDocument = document;
    this.input = composerDocumentProjectedText(document);
    this.composerInputRevision += 1;
    if (persist && this.editingQueueClientId.length === 0) {
      AppServices.instance.composerDrafts.save(this.sessionId, document);
    }
  }

  private applyComposerTextChange(value: string): void {
    this.selectedLearnRoute = '';
    const previous = composerDocumentProjectedText(this.composerDocument);
    let prefix = 0;
    while (prefix < previous.length && prefix < value.length
      && previous.charCodeAt(prefix) === value.charCodeAt(prefix)) prefix += 1;
    let suffix = 0;
    while (suffix < previous.length - prefix && suffix < value.length - prefix
      && previous.charCodeAt(previous.length - 1 - suffix)
        === value.charCodeAt(value.length - 1 - suffix)) suffix += 1;
    const inserted = value.slice(prefix, value.length - suffix);
    const document = isLongComposerPaste(inserted)
      ? replaceComposerTextRange(this.composerDocument, prefix, previous.length - suffix,
        [pastedTextNode(inserted)])
      : reconcileComposerProjectedText(this.composerDocument, value);
    this.setComposerDocument(document);
    this.updateComposerPalette(value);
  }

  private updateComposerPalette(value: string): void {
    let mode = '';
    let query = '';
    let from = 0;
    if (value.startsWith('/') && !/\s/.test(value.slice(1))) {
      mode = 'slash';
      query = value.slice(1);
    } else {
      const at = value.lastIndexOf('@');
      if (at >= 0 && (at === 0 || /\s/.test(value[at - 1]))) {
        const run = value.slice(at + 1);
        if (!/\s/.test(run)) {
          mode = 'at';
          query = run;
          from = at;
        }
      }
    }
    if (mode.length === 0) {
      this.composerPaletteGeneration += 1;
      this.composerPaletteMode = '';
      this.composerPaletteItems = [];
      this.composerPaletteLoading = false;
      return;
    }
    this.composerPaletteMode = mode;
    this.composerPaletteQuery = query;
    this.composerPaletteFrom = from;
    void this.loadComposerPalette(mode, query);
  }

  private parsePaletteRows(value: Object | undefined, field: string, kindFallback: string): ComposerPaletteItem[] {
    if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) return [];
    const record = value as Record<string, Object>;
    if (record['success'] === false || !Array.isArray(record[field])) return [];
    const rows = record[field] as Object[];
    const out: ComposerPaletteItem[] = [];
    for (let i = 0; i < rows.length; i++) {
      const raw = rows[i];
      if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) continue;
      const row = raw as Record<string, Object>;
      const item = new ComposerPaletteItem();
      item.kind = readStr(row, 'kind') || readStr(row, 'type') || kindFallback;
      item.name = readStr(row, 'name');
      item.description = readStr(row, 'description');
      item.relPath = readStr(row, 'relPath');
      if (item.name.length > 0 || item.relPath.length > 0) out.push(item);
    }
    return out;
  }

  private async loadComposerPalette(mode: string, query: string): Promise<void> {
    const generation = ++this.composerPaletteGeneration;
    this.composerPaletteLoading = true;
    try {
      let items: ComposerPaletteItem[] = [];
      const session = this.session();
      if (mode === 'slash') {
        const agent = this.agentKindForCapability(session ?? new RemoteSession());
        const options: Record<string, Object> = {};
        if ((session?.workingDir ?? '').length > 0) options['workingDir'] = session?.workingDir ?? '';
        const results = await Promise.all([
          this.invokeContextRpc('maker:list-agent-commands', [agent]).catch(() => undefined),
          this.invokeContextRpc('maker:list-agent-skills', [agent, options]).catch(() => undefined),
          this.invokeContextRpc('maker:list-desktop-commands', []).catch(() => undefined),
        ]);
        const skills = this.parsePaletteRows(results[1], 'skills', 'agent-skill');
        const desktop = this.parsePaletteRows(results[2], 'commands', 'desktop')
          .filter((item: ComposerPaletteItem) => item.name === 'learn');
        const builtins = this.parsePaletteRows(results[0], 'commands', 'agent-builtin');
        const seen = new Set<string>();
        const merged = skills.concat(desktop).concat(builtins);
        for (let i = 0; i < merged.length; i++) {
          const nameKey = merged[i].name.toLowerCase();
          const key = nameKey === 'learn' ? `${merged[i].kind}:${nameKey}` : nameKey;
          if (seen.has(key)) continue;
          seen.add(key);
          if (query.length === 0 || nameKey.startsWith(query.toLowerCase())) items.push(merged[i]);
          if (items.length >= 8) break;
        }
      } else {
        const options: Record<string, Object> = {};
        options['workingDir'] = session?.workingDir ?? '';
        options['cap'] = 2000;
        options['query'] = query;
        const result = await this.invokeContextRpc('maker:scan-at-resources', [
          this.agentKindForCapability(session ?? new RemoteSession()), options,
        ]);
        items = this.parsePaletteRows(result, 'items', 'file').slice(0, 8);
      }
      if (generation !== this.composerPaletteGeneration || mode !== this.composerPaletteMode
        || query !== this.composerPaletteQuery) return;
      this.composerPaletteItems = items;
    } catch (e) {
      if (generation === this.composerPaletteGeneration) this.composerPaletteItems = [];
    } finally {
      if (generation === this.composerPaletteGeneration) this.composerPaletteLoading = false;
    }
  }

  private paletteMentionRaw(item: ComposerPaletteItem): string {
    const path = item.relPath.length > 0 ? item.relPath : item.name;
    const normalized = item.kind === 'dir' && !path.endsWith('/') ? `${path}/` : path;
    return /\s/.test(normalized) || normalized.indexOf('"') >= 0
      ? `@"${normalized.replace(/"/g, '\\"')}"` : `@${normalized}`;
  }

  private selectComposerPaletteItem(item: ComposerPaletteItem): void {
    const to = composerDocumentProjectedText(this.composerDocument).length;
    let replacement: ComposerNode[] = [];
    if (this.composerPaletteMode === 'slash') {
      replacement = [slashCommandNode(item.name), textNode(' ')];
      this.selectedLearnRoute = item.name === 'learn' ? item.kind : '';
    } else {
      this.selectedLearnRoute = '';
      const raw = this.paletteMentionRaw(item);
      replacement = [mentionNode(item.kind, item.name, raw), textNode(' ')];
    }
    this.setComposerDocument(replaceComposerTextRange(
      this.composerDocument, this.composerPaletteFrom, to, replacement));
    this.composerPaletteGeneration += 1;
    this.composerPaletteMode = '';
    this.composerPaletteItems = [];
    setTimeout(() => focusControl.requestFocus('task-composer-input'), 0);
  }

  build() {
    Column() {
      this.taskHeader()
      if (this.searchOpen) {
        this.sessionSearchBar()
      }
      this.messageArea()

      if (this.pendingInteractions.length > 0) {
        // 与 Mobile 一致只展开一张 active 卡；其它请求按桌面优先级排队切换。
        Column({ space: 6 }) {
          if (this.pendingInteractions.length > 1) {
            this.pendingInteractionSwitcher()
          }
          Scroll() {
            if (this.activeInteractionIndex() >= 0) {
              this.pendingInteractionCard(this.pendingInteractions[this.activeInteractionIndex()])
            }
          }
          .width('100%')
          .constraintSize({ maxHeight: 240 })
        }
        .width('100%')
        .constraintSize({ maxWidth: 760, maxHeight: 286 })
        .alignSelf(ItemAlign.Center)
        .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      }

      if (this.error.length > 0) {
        Text(this.error)
          .fontSize(uiFontSize(12))
          .fontColor($r('app.color.danger'))
          .width('100%')
          .constraintSize({ maxWidth: 760 })
          .alignSelf(ItemAlign.Center)
          .padding({ left: 16, right: 16, top: 4 })
      }

      if (this.deviceDisabled) {
        Text('设备已关闭远程控制，仅可查看')
          .fontSize(uiFontSize(12))
          .fontColor($r('app.color.chat_text_secondary'))
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 16 })
          .border({ width: { top: 1 }, color: { top: $r('app.color.chat_header_divider') } })
      } else if (!pendingInteractionsBlockRemoteComposer(this.pendingInteractions)) {
        // 只有 Mobile 本端可终结的 pending 接管 Composer；桌面专属/未知卡仅作提示。
        if (this.composerPaletteMode.length > 0) {
          this.composerPalettePanel()
        }
        this.composerBar()
      }

      // 全屏图片预览层
      if (this.previewImageUrl.length > 0) {
        Stack() {
          Image(this.previewImageUrl)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
          Button() {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(uiFontSize(16))
              .fontColor([$r('app.color.chat_overlay_text')])
          }
          .type(ButtonType.Circle)
          .width(40)
          .height(40)
          .padding(0)
          .backgroundColor($r('app.color.overlay'))
          .clickEffect(UI_ICON_CLICK_EFFECT)
          .position({ x: 16, y: 48 })
          .onClick(() => this.closeImagePreview())
        }
        .width('100%')
        .height('100%')
        .position({ x: 0, y: 0 })
        .zIndex(99)
        .backgroundColor($r('app.color.chat_overlay_surface'))
        .transition(uiOverlayTransition())
        .onClick(() => this.closeImagePreview())
      }

      if (this.messageActionItemKey.length > 0) {
        this.messageActionLayer()
      }
      if (this.sessionActionOpen) {
        this.sessionActionLayer()
      }
      if (this.sessionTreeOpen) {
        this.sessionTreeLayer()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    .bindSheet($$this.contextSheetOpen, this.contextSheet(), {
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      dragBar: true,
      showClose: false,
      preferType: SheetType.BOTTOM,
      backgroundColor: $r('app.color.bg_card'),
      maskColor: $r('app.color.overlay'),
    })
  }

  private contextUsageLabel(): string {
    const session = this.session();
    if (session === undefined) return '';
    if (session.contextWindow > 0) {
      const percent = Math.min(100, Math.round(session.contextTokens * 100 / session.contextWindow));
      return `${session.contextTokens.toLocaleString()} / ${session.contextWindow.toLocaleString()} tokens · ${percent}%`;
    }
    if (session.totalTokenUsage > 0) return `${session.totalTokenUsage.toLocaleString()} tokens`;
    return '';
  }

  @Builder
  sessionActionLayer() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.task_list_overlay'))
        .onClick(() => this.closeSessionActions())

      Scroll() {
        Column({ space: 8 }) {
          Row({ space: 10 }) {
            Column({ space: 2 }) {
              Text(this.sessionTitle())
                .fontSize(uiFontSize(16))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(`${modelAgentLabel(this.session()?.agentKind ?? '')} · ${this.session()?.model || '默认模型'}`)
                .fontSize(uiFontSize(12))
                .fontColor($r('app.color.text_secondary'))
                .maxLines(1)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Button() {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(uiFontSize(14))
                .fontColor([$r('app.color.text_secondary')])
            }
            .type(ButtonType.Circle)
            .width(36)
            .height(36)
            .padding(0)
            .backgroundColor($r('app.color.bg_chip'))
            .onClick(() => this.closeSessionActions())
          }
          .width('100%')
          .padding({ bottom: 4 })

          if (this.sessionRenameMode) {
            TextInput({ placeholder: '任务名称', text: this.sessionRenameDraft })
              .fontSize(uiFontSize(15))
              .fontColor($r('app.color.text_primary'))
              .caretColor($r('app.color.accent'))
              .height(44)
              .padding({ left: 12, right: 12 })
              .backgroundColor($r('app.color.bg_chip'))
              .border({ width: 1, color: $r('app.color.border') })
              .borderRadius(UI_RADIUS_CONTROL)
              .enabled(!this.sessionActionBusy)
              .onChange((value: string) => this.sessionRenameDraft = value)
            Row({ space: 8 }) {
              Button('取消')
                .layoutWeight(1)
                .height(40)
                .fontSize(uiFontSize(14))
                .fontColor($r('app.color.text_primary'))
                .backgroundColor($r('app.color.bg_chip'))
                .borderRadius(UI_RADIUS_PILL)
                .enabled(!this.sessionActionBusy)
                .onClick(() => this.sessionRenameMode = false)
              Button(this.sessionActionBusy ? '保存中…' : '保存')
                .layoutWeight(1)
                .height(40)
                .fontSize(uiFontSize(14))
                .fontColor($r('app.color.chat_cta_text'))
                .backgroundColor($r('app.color.chat_cta'))
                .borderRadius(UI_RADIUS_PILL)
                .enabled(!this.sessionActionBusy && this.sessionRenameDraft.trim().length > 0)
                .onClick(() => this.saveSessionRename())
            }
          } else {
            this.sessionActionOption('重命名', $r('sys.symbol.doc_text'), false,
              () => this.sessionRenameMode = true)
            this.sessionActionOption('AI 起名', $r('sys.symbol.wand_and_stars'), false,
              () => void this.generateSessionRename())
            this.sessionActionOption('复制任务链接', $r('sys.symbol.link'), false, () => {
              this.copyPlainText(`cindy://session/${encodeURIComponent(this.sessionId)}`, '已复制任务链接');
            })
            if ((this.session()?.agentKind ?? '') === 'pi') {
              this.sessionActionOption('任务分支', $r('sys.symbol.split'), false,
                () => this.openSessionTree())
            }
            this.sessionActionOption((this.session()?.pinnedAt ?? '').length > 0 ? '取消置顶' : '置顶',
              $r('sys.symbol.pin'), false, () => this.toggleSessionPinned())
            this.sessionActionOption(this.session()?.status === 'archived' ? '恢复任务' : '归档任务',
              $r('sys.symbol.archivebox'), false, () => this.archiveOrRestoreSession())

            if ((this.session()?.workingDir ?? '').length > 0) {
              this.sessionMetadataRow('工作目录', this.session()?.workingDir ?? '', () => {
                this.copyPlainText(this.session()?.workingDir ?? '', '已复制工作目录');
              })
            }
            if ((this.session()?.worktreePath ?? '').length > 0) {
              this.sessionMetadataRow('Worktree', this.session()?.worktreePath ?? '', () => {
                this.copyPlainText(this.session()?.worktreePath ?? '', '已复制 Worktree 路径');
              })
            }
            if (this.contextUsageLabel().length > 0) {
              this.sessionMetadataRow('上下文用量', this.contextUsageLabel(), () => {})
            }
            ForEach(this.session()?.extraDirs ?? [], (path: string, index: number) => {
              this.sessionMetadataRow(index === 0 ? '附加目录' : '', path,
                () => this.copyPlainText(path, '已复制附加目录'))
            }, (path: string, index: number) => `${index}-${path}`)
            if ((this.session()?.parentSessionId ?? '').length > 0) {
              this.sessionMetadataRow('父任务', this.session()?.parentSessionId ?? '', () => {
                this.copyPlainText(this.session()?.parentSessionId ?? '', '已复制父任务 ID');
              })
            }
            if ((this.session()?.orcaRole ?? '').length > 0) {
              this.sessionMetadataRow('协作分支', this.session()?.orcaRole ?? '', () => {})
            }

            this.sessionActionOption('删除任务', $r('sys.symbol.trash'), true,
              () => this.confirmDeleteSession())
          }
        }
        .width('100%')
        .padding(16)
      }
      .width('calc(100% - 24vp)')
      .constraintSize({ maxWidth: 620, maxHeight: '82%' })
      .margin({ left: 12, right: 12, bottom: 12 })
      .backgroundColor($r('app.color.task_list_menu_surface'))
      .border({ width: 1, color: $r('app.color.border') })
      .borderRadius(UI_RADIUS_CONTAINER)
      .transition(uiOverlayTransition())
    }
    .width('100%')
    .height('100%')
    .position({ x: 0, y: 0 })
    .zIndex(98)
  }

  @Builder
  sessionActionOption(label: string, symbol: Resource, danger: boolean, action: () => void) {
    Button() {
      Row({ space: 10 }) {
        SymbolGlyph(symbol)
          .fontSize(uiFontSize(17))
          .fontColor([danger ? $r('app.color.danger') : $r('app.color.text_secondary')])
          .width(24)
        Text(label)
          .fontSize(uiFontSize(15))
          .fontColor(danger ? $r('app.color.danger') : $r('app.color.text_primary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
      }
      .width('100%')
    }
    .type(ButtonType.Normal)
    .width('100%')
    .height(44)
    .padding({ left: 10, right: 10 })
    .backgroundColor(Color.Transparent)
    .borderRadius(UI_RADIUS_CONTROL)
    .enabled(!this.sessionActionBusy && !this.isCreationBlockingRemoteOps())
    .clickEffect(UI_LIST_CLICK_EFFECT)
    .onClick(action)
  }

  private piTreeRows(): PiTreeRow[] {
    const out: PiTreeRow[] = [];
    const tree = this.sessionTree;
    if (tree === null) return out;
    const append = (nodes: PiSessionTreeNode[], depth: number): void => {
      for (let i = 0; i < nodes.length; i++) {
        const row = new PiTreeRow();
        row.node = nodes[i];
        row.depth = depth;
        out.push(row);
        append(nodes[i].children, depth + 1);
      }
    };
    append(tree.roots, 0);
    return out;
  }

  private piRoleLabel(role: string): string {
    if (role === 'user') return '用户';
    if (role === 'assistant') return '助手';
    if (role === 'tool') return '工具';
    if (role === 'summary') return '摘要';
    return role.length > 0 ? role : '分支';
  }

  @Builder
  sessionTreeLayer() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column().width('100%').height('100%').backgroundColor($r('app.color.overlay'))
        .onClick(() => this.closeSessionTree())
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text('任务分支')
            .fontSize(uiFontSize(18))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          Button() {
            SymbolGlyph($r('sys.symbol.xmark')).fontSize(uiFontSize(14))
              .fontColor([$r('app.color.text_secondary')])
          }
          .type(ButtonType.Circle).width(36).height(36).padding(0)
          .backgroundColor($r('app.color.bg_chip')).onClick(() => this.closeSessionTree())
        }
        .width('100%')
        if (this.sessionStreaming) {
          Text('任务运行中，结束后才能切换分支')
            .fontSize(uiFontSize(12)).fontColor($r('app.color.text_tertiary')).width('100%')
        }
        if (this.sessionTreeLoading) {
          Row({ space: 8 }) {
            LoadingProgress().width(16).height(16)
            Text('正在读取分支').fontSize(uiFontSize(13)).fontColor($r('app.color.text_secondary'))
          }.height(120).justifyContent(FlexAlign.Center)
        } else if (this.sessionTreeError.length > 0) {
          Column({ space: 8 }) {
            Text(this.sessionTreeError).fontSize(uiFontSize(13)).fontColor($r('app.color.danger'))
            Button('重试').onClick(() => void this.loadSessionTree())
          }.height(120).justifyContent(FlexAlign.Center)
        } else if (this.piTreeRows().length === 0) {
          Text('当前任务还没有可切换的分支')
            .fontSize(uiFontSize(13)).fontColor($r('app.color.text_tertiary'))
            .height(120)
        } else {
          List({ space: 0 }) {
            ForEach(this.piTreeRows(), (row: PiTreeRow) => {
              ListItem() {
                Row({ space: 8 }) {
                  Text(this.piRoleLabel(row.node.role))
                    .fontSize(uiFontSize(11)).fontColor($r('app.color.text_tertiary')).width(42)
                  Column({ space: 2 }) {
                    Text(row.node.label.length > 0 ? row.node.label : row.node.preview)
                      .fontSize(uiFontSize(13)).fontColor($r('app.color.text_primary'))
                      .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                    if (this.sessionTree?.leafId === row.node.id) {
                      Text('当前分支').fontSize(uiFontSize(11)).fontColor($r('app.color.accent'))
                    }
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                  if (this.sessionTreeSwitchingId === row.node.id) {
                    LoadingProgress().width(15).height(15)
                  } else {
                    this.disclosureChevron(false, $r('app.color.text_tertiary'))
                  }
                }
                .width('100%').constraintSize({ minHeight: 52 })
                .padding({ left: 8 + Math.min(row.depth, 8) * 14, right: 8, top: 6, bottom: 6 })
                .border({ width: { bottom: 1 }, color: { bottom: $r('app.color.border') } })
                .enabled(!this.sessionStreaming && !this.isCreationBlockingRemoteOps()
                  && this.sessionTreeSwitchingId.length === 0
                  && this.sessionTree?.leafId !== row.node.id)
                .clickEffect(UI_LIST_CLICK_EFFECT)
                .onClick(() => void this.navigateSessionTree(row.node.id))
              }
            }, (row: PiTreeRow) => row.node.id)
          }
          .width('100%').layoutWeight(1)
        }
      }
      .width('calc(100% - 24vp)').constraintSize({ maxWidth: 620, maxHeight: '82%' })
      .padding(16).margin({ left: 12, right: 12, bottom: 12 })
      .backgroundColor($r('app.color.task_list_menu_surface'))
      .border({ width: 1, color: $r('app.color.border') }).borderRadius(UI_RADIUS_CONTAINER)
      .transition(uiOverlayTransition())
    }
    .width('100%').height('100%').zIndex(101)
  }

  @Builder
  sessionMetadataRow(label: string, value: string, action: () => void) {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(uiFontSize(12))
        .fontColor($r('app.color.text_tertiary'))
        .width(72)
      Text(value)
        .fontSize(uiFontSize(13))
        .fontColor($r('app.color.text_secondary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.bg_chip'))
    .borderRadius(UI_RADIUS_CONTROL)
    .clickEffect(UI_LIST_CLICK_EFFECT)
    .onClick(action)
  }

  /** Header 与搜索栏共用的圆形图标按钮，统一触控反馈和选中态。 */
  @Builder
  taskIconButton(symbol: Resource, size: number, selected: boolean, enabled: boolean, action: () => void) {
    Button() {
      SymbolGlyph(symbol)
        .fontSize(uiFontSize(20))
        .fontColor([$r('app.color.text_primary')])
    }
    .type(ButtonType.Circle)
    .width(size)
    .height(size)
    .padding(0)
    .backgroundColor(selected ? $r('app.color.bg_chip') : Color.Transparent)
    .clickEffect(UI_ICON_CLICK_EFFECT)
    .enabled(enabled)
    .opacity(enabled ? 1 : 0.4)
    .onClick(action)
  }

  /** iOS 同层级会话 Header：50vp 内容高、44vp 返回热区与 40vp 动作槽。 */
  @Builder
  taskHeader() {
    Row({ space: 4 }) {
      if (!this.isEmbedded()) {
        this.taskIconButton($r('sys.symbol.chevron_left'), 44, false, true, () => router.back())
      }

      Column({ space: 1 }) {
        Text(this.sessionTitle())
          .fontSize(uiFontSize(16))
          .lineHeight(uiLineHeight(22))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.headerNotice().length > 0) {
          Text(this.headerNotice())
            .fontSize(uiFontSize(11))
            .lineHeight(uiLineHeight(16))
            .fontColor(this.sessionStreaming
              ? $r('app.color.chat_status_accent')
              : $r('app.color.chat_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 4 })

      if ((this.session()?.workingDir ?? '').length > 0) {
        this.taskIconButton($r('sys.symbol.folder'), 40, false,
          !this.isCreationBlockingRemoteOps(), () => this.showProjectActions())
      }

      if (this.items.length > 0) {
        this.taskIconButton($r('sys.symbol.magnifyingglass'), 40, this.searchOpen, true, () => {
          if (this.searchOpen) this.closeSearch();
          else this.openSearch();
        })
      }

      this.taskIconButton($r('sys.symbol.ellipsis_circle'), 40, false,
        !this.isCreationBlockingRemoteOps(),
        () => this.showSessionActions())
    }
    .width('100%')
    .constraintSize({ minHeight: 50 })
    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
    .backgroundColor(this.isEmbedded()
      ? $r('app.color.bg_page')
      : $r('app.color.chat_header_surface'))
    .backgroundBlurStyle(this.isEmbedded() ? BlurStyle.NONE : BlurStyle.Thin)
    .border({ width: { bottom: 1 }, color: { bottom: $r('app.color.chat_header_divider') } })
  }

  @Builder
  sessionSearchBar() {
    Column() {
      Row({ space: 4 }) {
        Search({ value: this.searchQuery, placeholder: '搜索消息' })
          .height(36)
          .textFont({ size: uiFontSize(15) })
          .layoutWeight(1)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(UI_RADIUS_PILL)
          .onChange((value: string) => this.updateSearchQuery(value))
        if (this.searchQuery.trim().length > 0) {
          Text(this.searchHits().length === 0
            ? '0/0'
            : `${this.searchActiveIndex + 1}/${this.searchHits().length}`)
            .fontSize(uiFontSize(12))
            .fontColor($r('app.color.chat_text_secondary'))
            .constraintSize({ minWidth: 32 })
            .textAlign(TextAlign.Center)
        }
        this.taskIconButton($r('sys.symbol.chevron_up'), 36, false,
          this.searchHits().length > 0, () => this.moveSearch(-1))
        this.taskIconButton($r('sys.symbol.chevron_down'), 36, false,
          this.searchHits().length > 0, () => this.moveSearch(1))
        this.taskIconButton($r('sys.symbol.xmark'), 36, false, true, () => this.closeSearch())
      }
      .width('100%')
      .padding({ left: 12, right: 8, top: 6, bottom: 6 })
      if (this.searchPaging().visible) {
        Button(this.searchPaging().label)
          .fontSize(uiFontSize(12))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary'))
          .height(30)
          .padding({ left: 12, right: 12 })
          .borderRadius(UI_RADIUS_PILL)
          .backgroundColor(Color.Transparent)
          .enabled(this.searchPaging().enabled)
          .clickEffect(UI_CLICK_EFFECT)
          .onClick(() => this.loadOlder(true))
      }
    }
    .width('100%')
    .backgroundColor(this.isEmbedded()
      ? $r('app.color.bg_page')
      : $r('app.color.chat_header_surface'))
    .border({ width: { bottom: 1 }, color: { bottom: $r('app.color.chat_header_divider') } })
    .transition(uiRevealTransition())
  }

  private pendingQueueStatusText(item: PendingQueueBubble): string {
    if (item.clientId === this.newSessionCreationClientId) {
      if (this.newSessionCreationStatus === 'running') return '正在创建任务…';
      if (this.newSessionCreationStatus === 'create-failed') return '任务创建失败';
    }
    if (item.phase === 'sending') return '正在发送…';
    if (item.phase === 'waiting') return '等待任务创建后发送…';
    if (item.phase === 'connection-waiting') return '等待连接恢复后发送…';
    if (item.phase === 'settling') return '已发送，正在同步…';
    if (item.phase === 'editing') return '正在编辑';
    if (item.phase === 'paused') return `队列 ${item.queueIndex} · 已暂停`;
    if (item.phase === 'failed') return '发送失败';
    return `队列 ${item.queueIndex}`;
  }

  private isCreateFailureBubble(item: PendingQueueBubble): boolean {
    return this.newSessionCreationStatus === 'create-failed'
      && this.newSessionCreationClientId.length > 0
      && item.clientId === this.newSessionCreationClientId;
  }

  private retryNewSessionCreation(): void {
    AppServices.instance.newSessionCreations.retry(this.sessionId);
  }

  private async returnNewSessionToEdit(): Promise<void> {
    if (!this.imageQueue.allSettled() || !this.fileQueue.allSettled()) {
      promptAction.showToast({ message: '请等待附件上传完成，或移除上传失败的附件' });
      return;
    }
    const store = AppServices.instance.newSessionCreations;
    this.leavingForCreationEdit = true;
    this.sending = true;
    this.getUIContext().getFocusController().clearFocus();
    const action = await store.returnToEdit(
      this.sessionId,
      composerDocumentProjectedText(this.composerDocument),
      this.imageQueue.readyImages(),
      this.fileQueue.readyFiles(),
    );
    if (action === 'edit') {
      AppServices.instance.composerDrafts.clear(this.sessionId);
      router.replaceUrl({
        url: 'pages/NewSessionPage',
        params: { deviceId: this.deviceId },
      });
      return;
    }
    this.leavingForCreationEdit = false;
    this.sending = false;
    if (action === 'resume') {
      promptAction.showToast({ message: '已找到电脑上的任务，正在继续发送首条消息' });
    } else if (action === 'unknown') {
      promptAction.showToast({ message: '暂时无法确认任务状态，请稍后重试' });
    }
  }

  @Builder
  queueInlineAction(label: string, danger: boolean, enabled: boolean, action: () => void) {
    Button(label)
      .type(ButtonType.Normal)
      .height(30)
      .padding({ left: 12, right: 12 })
      .fontSize(uiFontSize(12))
      .fontWeight(FontWeight.Medium)
      .fontColor(danger ? $r('app.color.danger') : $r('app.color.text_primary'))
      .backgroundColor($r('app.color.bg_chip'))
      .borderRadius(UI_RADIUS_PILL)
      .enabled(enabled)
      .opacity(enabled ? 1 : 0.45)
      .clickEffect(UI_CLICK_EFFECT)
      .onClick(action)
  }

  @Builder
  pendingQueueBubble(item: PendingQueueBubble) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        if (item.phase === 'sending' || item.phase === 'settling' || item.phase === 'waiting') {
          LoadingProgress()
            .width(13)
            .height(13)
            .color($r('app.color.text_tertiary'))
        }
        Text(this.pendingQueueStatusText(item))
          .fontSize(uiFontSize(11))
          .fontColor(item.phase === 'failed'
            ? $r('app.color.danger') : $r('app.color.text_tertiary'))
        Row().layoutWeight(1)
        if (item.images.length > 0) {
          Text(`${item.images.length} 张图片`)
            .fontSize(uiFontSize(11))
            .fontColor($r('app.color.text_tertiary'))
        }
        if (item.files.length > 0) {
          Text(`${item.files.length} 个文件`)
            .fontSize(uiFontSize(11))
            .fontColor($r('app.color.text_tertiary'))
        }
      }
      .width('100%')

      if (item.text.length > 0) {
        Text(item.text)
          .fontSize(uiFontSize(14))
          .lineHeight(uiLineHeight(20))
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .maxLines(8)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      if (item.errorText.length > 0) {
        Text(item.errorText)
          .fontSize(uiFontSize(11))
          .fontColor($r('app.color.danger'))
          .maxLines(2)
          .width('100%')
      }

      if (this.isCreateFailureBubble(item)
        || (!this.isCreationBlockingRemoteOps()
          && (this.selectedQueueClientId === item.clientId || item.phase === 'failed'))) {
        Row({ space: 6 }) {
          if (this.isCreateFailureBubble(item)) {
            this.queueInlineAction('重试创建', false, !this.queueBusy,
              () => this.retryNewSessionCreation())
            this.queueInlineAction('返回编辑', false, !this.queueBusy,
              () => void this.returnNewSessionToEdit())
          } else if (item.phase === 'failed') {
            this.queueInlineAction('重试发送', false, !this.queueBusy,
              () => this.retryQueueItem(item.clientId))
          } else if (item.phase === 'queued' || item.phase === 'paused') {
            this.queueInlineAction('上移', false, item.queueIndex > 1 && !this.queueBusy,
              () => this.moveQueueItem(item.clientId, -1))
            this.queueInlineAction('下移', false,
              item.queueIndex < AppServices.instance.inputQueue
                .getProjection(this.sessionId).pendingQueue.length && !this.queueBusy,
              () => this.moveQueueItem(item.clientId, 1))
            this.queueInlineAction('编辑', false, !this.queueBusy,
              () => this.beginQueueEdit(item.clientId))
            this.queueInlineAction('插话', false, this.sessionStreaming && !this.queueBusy,
              () => this.steerQueueItem(item.clientId))
          }
          Row().layoutWeight(1)
          if (!this.isCreateFailureBubble(item)) {
            this.queueInlineAction('删除消息', true, !this.queueBusy,
              () => this.removeQueueItem(item.clientId))
          }
        }
        .width('100%')
        .transition(uiRevealTransition())
      }
    }
    .width('88%')
    .alignSelf(ItemAlign.End)
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: item.phase === 'failed'
      ? $r('app.color.danger') : $r('app.color.border') })
    .borderRadius(UI_RADIUS_CONTAINER)
    .clickEffect(UI_LIST_CLICK_EFFECT)
    .onClick(() => {
      if (!this.isCreationBlockingRemoteOps()
        && (item.phase === 'queued' || item.phase === 'paused')) {
        this.selectedQueueClientId = this.selectedQueueClientId === item.clientId ? '' : item.clientId;
      }
    })
  }

  @Builder
  queueStateBanner() {
    Column({ space: 8 }) {
      if (this.queueProjectionError.length > 0) {
        Text(this.queueProjectionError)
          .fontSize(uiFontSize(12))
          .lineHeight(uiLineHeight(18))
          .fontColor($r('app.color.danger'))
          .width('100%')
        Row({ space: 8 }) {
          this.queueInlineAction('重试发送', false,
            this.queueErrorRetryText.length > 0 && !this.queueActionBlocked(),
            () => this.retryQueueError())
          this.queueInlineAction('忽略错误', false, !this.queueActionBlocked(),
            () => this.clearQueueError())
        }
        .width('100%')
      } else if (this.queueCredentialWaiting) {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(13)
            .height(13)
            .color($r('app.color.text_tertiary'))
          Text(this.queueCredentialBlockedCount > 0
            ? `正在等待 ${this.queueCredentialBlockedCount} 个任务完成凭证切换`
            : '正在等待电脑完成凭证切换')
            .fontSize(uiFontSize(12))
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
        }
        .width('100%')
      } else if (this.queueAbortPending) {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(13)
            .height(13)
            .color($r('app.color.text_tertiary'))
          Text('正在停止当前工作…')
            .fontSize(uiFontSize(12))
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
        }
        .width('100%')
      } else if (this.queuePaused) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.clock'))
            .fontSize(uiFontSize(14))
            .fontColor([$r('app.color.text_secondary')])
          Text('待发送队列已暂停')
            .fontSize(uiFontSize(12))
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
          this.queueInlineAction('继续发送', false, !this.queueActionBlocked(),
            () => this.resumeQueue())
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 12, right: 8, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.border') })
    .borderRadius(UI_RADIUS_CONTAINER)
  }

  @Builder
  sessionTailBanner() {
    if (this.tailPresentation() !== null) {
      Column({ space: 9 }) {
        Text(this.tailPresentation()?.text ?? '')
          .fontSize(uiFontSize(12))
          .lineHeight(uiLineHeight(18))
          .fontColor(this.tailPresentation()?.interrupted === true
            ? $r('app.color.text_secondary') : $r('app.color.danger'))
          .width('100%')
        Row({ space: 8 }) {
          if (this.tailPresentation()?.retryable === true
            || this.tailPresentation()?.interrupted === true) {
            this.queueInlineAction(this.tailPresentation()?.interrupted === true ? '继续任务' : '重试',
              false, !this.tailBannerBusy && !this.deviceDisabled,
              () => this.continueSessionTail())
          }
          this.queueInlineAction('忽略', false, !this.tailBannerBusy && !this.deviceDisabled,
            () => this.dismissSessionTail())
        }
        .width('100%')
      }
      .width('100%')
      .padding(12)
      .backgroundColor($r('app.color.bg_card'))
      .border({ width: 1, color: $r('app.color.border') })
      .borderRadius(UI_RADIUS_CONTAINER)
    }
  }

  @Builder
  messageArea() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      if (this.items.length === 0 && this.queueBubbles.length === 0) {
        Column({ space: 8 }) {
          if (this.loadFailed) {
            Text('加载失败，请检查连接后重试')
              .fontSize(uiFontSize(12))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.danger'))
            Button('重试')
              .fontSize(uiFontSize(12))
              .fontColor($r('app.color.text_primary'))
              .height(32)
              .padding({ left: 12, right: 12 })
              .borderRadius(UI_RADIUS_PILL)
              .backgroundColor($r('app.color.bg_chip'))
              .clickEffect(UI_CLICK_EFFECT)
              .onClick(() => this.retryLoad())
          } else if (this.newSessionCreationStatus === 'running') {
            LoadingProgress()
              .width(14)
              .height(14)
              .color($r('app.color.text_tertiary'))
            Text('正在创建任务')
              .fontSize(uiFontSize(12))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_tertiary'))
          } else if (this.newSessionCreationStatus === 'create-failed') {
            Text(this.newSessionCreationError.length > 0
              ? this.newSessionCreationError : '任务创建失败，请返回编辑后重试')
              .fontSize(uiFontSize(12))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.danger'))
              .textAlign(TextAlign.Center)
          } else if (!this.initialLoadResolved && this.showInitialSync) {
            LoadingProgress()
              .width(14)
              .height(14)
              .color($r('app.color.text_tertiary'))
            Text('正在同步')
              .fontSize(uiFontSize(12))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_tertiary'))
          } else if (this.initialLoadResolved) {
            Text('暂无消息')
              .fontSize(uiFontSize(12))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_tertiary'))
          }
        }
        .width('100%')
        .height('100%')
        .constraintSize({ minHeight: 168 })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        List({ space: 16, scroller: this.listScroller }) {
          if (this.hasOlderMessages) {
            ListItem() {
              Button(this.loadingOlder ? '加载中' : '加载更早消息')
                .fontSize(uiFontSize(12))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_tertiary'))
                .height(32)
                .padding({ left: 12, right: 12 })
                .borderRadius(UI_RADIUS_PILL)
                .backgroundColor(Color.Transparent)
                .enabled(!this.loadingOlder)
                .clickEffect(UI_CLICK_EFFECT)
                .onClick(() => this.loadOlder())
            }
          }
          ForEach(this.items, (item: RenderItem) => {
            ListItem() {
              this.renderItem(item)
            }
            .backgroundColor((item.key === this.focusedSearchItemKey
              || this.renderItemContainsClientId(item, this.focusedMessageClientId))
              ? $r('app.color.bg_chip') : Color.Transparent)
            .borderRadius(UI_RADIUS_CONTAINER)
            .animation({ duration: UI_MOTION_FAST, curve: UI_CURVE_MOVE })
          }, (item: RenderItem) => this.renderItemNodeKey(item))
          if (this.hasQueueStateBanner()) {
            ListItem() {
              this.queueStateBanner()
            }
          }
          if (this.tailPresentation() !== null) {
            ListItem() {
              this.sessionTailBanner()
            }
          }
          ForEach(this.queueBubbles, (item: PendingQueueBubble) => {
            ListItem() {
              this.pendingQueueBubble(item)
            }
          }, (item: PendingQueueBubble) => `message-${item.clientId}`)
          // 稳定尾锚不能复用正在流式增高的消息节点，否则 ArkUI 重测同一项时会
          // 把 scrollToIndex 的旧几何解释成历史位置，造成每次新内容都反向跳动。
          ListItem() {
            Row()
              .width('100%')
              .height(1)
          }
        }
        .width('100%')
        .height('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 16 })
        .onScrollIndex((start: number, end: number, _center: number) => {
          this.visibleStartIndex = start;
          this.visibleEndIndex = end;
          if (this.listTouchPushedUp && end >= this.bottomSentinelListIndex()) {
            this.followingLatest = true;
            this.hasNewMessages = false;
          }
          this.attemptAutoLoadEarlier();
        })
        .onTouch((event: TouchEvent) => {
          this.handleListTouch(event);
        })
        .onReachStart(() => {
          this.attemptAutoLoadEarlier();
        })
      }

      if ((this.items.length > 0 || this.queueBubbles.length > 0) && !this.followingLatest) {
        Button() {
          Stack({ alignContent: Alignment.Center }) {
            SymbolGlyph($r('sys.symbol.chevron_down'))
              .fontSize(uiFontSize(20))
              .fontColor([$r('app.color.chat_text_secondary')])
            if (this.hasNewMessages) {
              Circle()
                .width(8)
                .height(8)
                .fill($r('app.color.chat_cta'))
                .position({ x: 24, y: 3 })
            }
          }
          .width(36)
          .height(36)
        }
        .width(36)
        .height(36)
        .padding(0)
        .borderRadius(UI_RADIUS_PILL)
        .backgroundColor($r('app.color.chat_fab_surface'))
        .border({ width: 1, color: $r('app.color.chat_fab_border') })
        .margin({ right: 23, bottom: 12 })
        .clickEffect(UI_ICON_CLICK_EFFECT)
        .transition(uiRevealTransition())
        .onClick(() => this.jumpToLatest())
      }
    }
    .width('100%')
    .constraintSize({ maxWidth: 760 })
    .alignSelf(ItemAlign.Center)
    .layoutWeight(1)
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.handleMessageAreaChange(oldArea, newArea);
    })
  }

  /** Mobile 同款 Composer：活动状态独立于 50vp 输入胶囊，焦点态再展开为卡片。 */
  @Builder
  composerPalettePanel() {
    Column({ space: 2 }) {
      Row({ space: 8 }) {
        SymbolGlyph(this.composerPaletteMode === 'slash'
          ? $r('sys.symbol.list_bullet') : $r('sys.symbol.at'))
          .fontSize(uiFontSize(14))
          .fontColor([$r('app.color.text_secondary')])
        Text(this.composerPaletteMode === 'slash' ? '命令与技能' : '文件、目录与 Agent')
          .fontSize(uiFontSize(12))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
        if (this.composerPaletteLoading) {
          LoadingProgress().width(14).height(14).color($r('app.color.accent'))
        }
      }
      .width('100%')
      .height(30)
      .padding({ left: 12, right: 12 })

      if (!this.composerPaletteLoading && this.composerPaletteItems.length === 0) {
        Text(this.composerPaletteMode === 'slash' ? '没有匹配的命令' : '没有匹配的资源')
          .fontSize(uiFontSize(13))
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .padding({ left: 12, right: 12, top: 10, bottom: 12 })
      } else {
        List({ space: 0 }) {
          ForEach(this.composerPaletteItems, (item: ComposerPaletteItem) => {
            ListItem() {
              Row({ space: 10 }) {
                Text(this.composerPaletteMode === 'slash' ? `/${item.name}` : item.name)
                  .fontSize(uiFontSize(14))
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .constraintSize({ minWidth: 92 })
                Text(item.description.length > 0 ? item.description : item.relPath)
                  .fontSize(uiFontSize(12))
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
              }
              .width('100%')
              .height(42)
              .padding({ left: 12, right: 12 })
              .clickEffect(UI_LIST_CLICK_EFFECT)
              .onClick(() => this.selectComposerPaletteItem(item))
            }
          }, (item: ComposerPaletteItem) => `${item.kind}:${item.name}:${item.relPath}`)
        }
        .width('100%')
        .constraintSize({ maxHeight: 220 })
      }
    }
    .width('calc(100% - 24vp)')
    .constraintSize({ maxWidth: 736 })
    .alignSelf(ItemAlign.Center)
    .margin({ left: 12, right: 12, top: 4 })
    .backgroundColor($r('app.color.task_list_menu_surface'))
    .border({ width: 1, color: $r('app.color.border') })
    .borderRadius(UI_RADIUS_CONTAINER)
    .transition(uiRevealTransition())
  }

  @Builder
  composerBar() {
    ConversationComposer({
      input: this.input,
      focused: this.composerFocused,
      images: this.composerImages,
      files: this.composerFiles,
      atoms: composerAtomPresentations(this.composerDocument),
      sending: this.sending,
      streaming: this.sessionStreaming,
      streamingElapsedText: this.sessionActivityElapsedText(),
      hasContent: this.hasComposerContent(),
      canSend: this.canSend(),
      composerEnabled: !this.deviceDisabled && !this.leavingForCreationEdit
        && !pendingInteractionsBlockRemoteComposer(this.pendingInteractions),
      pickingImages: this.pickingImages,
      contextBusy: this.contextRpcBusy,
      hasPermissionOptions: this.permissionOptions.length > 0,
      hasModelOptions: this.visibleModelOptions().length > 0 && this.currentModelLabel().length > 0,
      permissionMode: this.effectivePermissionMode(),
      planModeEnabled: this.planModeEnabled,
      modelLabel: this.currentModelLabel(),
      effortLabel: this.currentModelEffortLabel(),
      showAddButton: true,
      showStreamingStatus: true,
      inputId: 'task-composer-input',
      onInputChange: (value: string): void => {
        if (this.leavingForCreationEdit) return;
        this.applyComposerTextChange(value);
      },
      onFocusChange: (focused: boolean): void => {
        this.composerFocused = focused;
      },
      onAdd: (): void => this.openContextSheet(),
      onPermission: (): void => this.openComposerControlSheet('permission'),
      onModel: (): void => this.openComposerControlSheet('model'),
      onPlanToggle: (): void => {
        void this.togglePlanMode();
      },
      onSend: (): void => this.send(),
      onAbort: (): void => this.abort(),
      onPreviewImage: (image: ComposerImage): void => {
        if (image.status !== 'ready' || image.uri.length === 0) return;
        uiAnimateFastState(this.getUIContext(), () => {
          this.previewImageUrl = image.uri;
        });
      },
      onRemoveImage: (image: ComposerImage): void => this.imageQueue.remove(image),
      onRetryImage: (image: ComposerImage): void => this.imageQueue.retry(image),
      onRemoveFile: (file: ComposerFile): void => this.fileQueue.remove(file),
      onRetryFile: (file: ComposerFile): void => this.fileQueue.retry(file),
      onRemoveAtom: (atom: ComposerAtomPresentation): void => {
        this.setComposerDocument(removeComposerNode(this.composerDocument, atom.index));
      },
    })
  }

  /** iOS 加号同层级：原生可拖拽 Sheet，主视图与目标模式二级视图共用。 */
  @Builder
  contextSheet() {
    Column() {
      Row() {
        if (this.contextSheetPage !== 'main') {
          this.taskIconButton($r('sys.symbol.chevron_left'), 36, false, true, () => {
            uiAnimateState(this.getUIContext(), () => {
              this.contextSheetPage = this.contextSheetPage === 'model-options' ? 'model' : 'main';
            });
          })
        } else {
          Row().width(36).height(36)
        }
        Text(this.contextSheetPage === 'goal'
          ? '目标模式'
          : this.contextSheetPage === 'permission'
            ? '权限模式'
            : this.contextSheetPage === 'model-options'
              ? '推理设置'
              : this.contextSheetPage === 'model'
                ? '模型'
                : '上下文')
          .fontSize(uiFontSize(17))
          .lineHeight(uiLineHeight(24))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
        Row().width(36).height(36)
      }
      .width('100%')
      .height(44)
      .padding({ left: 12, right: 12 })

      Divider()
        .strokeWidth(0.5)
        .color($r('app.color.border'))

      if (this.contextSheetPage === 'goal') {
        this.goalContextView()
      } else if (this.contextSheetPage === 'permission') {
        this.permissionContextView()
      } else if (this.contextSheetPage === 'model') {
        this.modelContextView()
      } else if (this.contextSheetPage === 'model-options') {
        this.modelOptionsContextView()
      } else {
        this.contextMainView()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_card'))
  }

  @Builder
  contextMainView() {
    Scroll() {
      Column() {
        Column({ space: 6 }) {
          PhotoPickerComponent({
            pickerOptions: this.recentPickerOptions,
            pickerController: this.recentPickerController,
            onSelect: (uri: string): void => this.selectRecentImage(uri),
            onDeselect: (uri: string): void => this.deselectRecentImage(uri),
          })
            .width('100%')
            .height(104)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })

        if (this.contextSelectedUris.length > 0) {
          Button(`加入对话 (${this.contextSelectedUris.length})`)
            .width('calc(100% - 32vp)')
            .height(42)
            .fontSize(uiFontSize(15))
            .fontColor($r('app.color.chat_cta_text'))
            .backgroundColor($r('app.color.chat_cta'))
            .borderRadius(UI_RADIUS_CONTROL)
            .margin({ left: 16, right: 16, bottom: 10 })
            .clickEffect(UI_CLICK_EFFECT)
            .onClick(() => this.addRecentSelection())
        }

        Divider().strokeWidth(0.5).color($r('app.color.border')).margin({ left: 64 })

        if (this.planModeSupported) {
          Row({ space: 12 }) {
            this.contextRowIcon($r('sys.symbol.list_bullet'))
            Column({ space: 2 }) {
              Text('计划模式')
                .fontSize(uiFontSize(16))
                .lineHeight(uiLineHeight(22))
                .fontColor($r('app.color.text_primary'))
              Text('先生成计划，确认后再执行')
                .fontSize(uiFontSize(12))
                .lineHeight(uiLineHeight(18))
                .fontColor($r('app.color.text_tertiary'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.planModeEnabled })
              .enabled(!this.contextRpcBusy)
              .onChange(() => {
                void this.togglePlanMode();
              })
          }
          .width('100%')
          .constraintSize({ minHeight: 64 })
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })

          Divider().strokeWidth(0.5).color($r('app.color.border')).margin({ left: 64 })
        }

        this.contextActionRow(
          $r('sys.symbol.flag'),
          '目标模式',
          this.goalState === null ? '让 Cindy 持续推进一个目标' : this.goalStatusText(this.goalState.status),
          () => {
            if (this.goalState === null && this.goalObjective.trim().length === 0) {
              this.goalObjective = this.input;
            }
            this.contextSheetPage = 'goal';
            void AppServices.instance.goals.refresh(this.deviceId, this.sessionId);
          },
        )
        Divider().strokeWidth(0.5).color($r('app.color.border')).margin({ left: 64 })
        this.contextActionRow($r('sys.symbol.picture'), '照片', '', () => this.pickImages())
        Divider().strokeWidth(0.5).color($r('app.color.border')).margin({ left: 64 })
        this.contextActionRow($r('sys.symbol.snapshot'), '截图', '', () => this.pickScreenshots())
        Divider().strokeWidth(0.5).color($r('app.color.border')).margin({ left: 64 })
        this.contextActionRow($r('sys.symbol.camera'), '拍照', '', () => this.takePhoto())
        Divider().strokeWidth(0.5).color($r('app.color.border')).margin({ left: 64 })
        this.contextActionRow($r('sys.symbol.doc'), '文件', 'PDF、Office 与文本文件', () => this.pickFiles())
      }
      .width('100%')
      .padding({ bottom: 24 })
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  permissionContextView() {
    Scroll() {
      Column() {
        ForEach(this.permissionOptions, (option: ComposerChoiceOption) => {
          Row({ space: 12 }) {
            this.contextRowIcon($r('sys.symbol.lock'))
            Column({ space: 2 }) {
              Text(option.label)
                .fontSize(uiFontSize(16))
                .lineHeight(uiLineHeight(22))
                .fontColor($r('app.color.text_primary'))
              if (option.description.length > 0) {
                Text(option.description)
                  .fontSize(uiFontSize(12))
                  .lineHeight(uiLineHeight(18))
                  .fontColor($r('app.color.text_tertiary'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            if (option.id === this.effectivePermissionMode()) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(uiFontSize(18))
                .fontColor([$r('app.color.chat_cta')])
            }
          }
          .width('100%')
          .constraintSize({ minHeight: 58 })
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .opacity(this.contextRpcBusy ? 0.55 : 1)
          .clickEffect(UI_LIST_CLICK_EFFECT)
          .onClick(() => this.requestPermissionMode(option))
          Divider().strokeWidth(0.5).color($r('app.color.border')).margin({ left: 64 })
        }, (option: ComposerChoiceOption) => option.id)
      }
      .width('100%')
      .padding({ top: 8, bottom: 24 })
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  modelAgentMark(kind: string, active: boolean) {
    Text(kind === 'claude-code' ? '♟' : kind === 'codex' ? '✣' : 'π')
      .fontSize(uiFontSize(kind === 'pi' ? 20 : 18))
      .fontWeight(FontWeight.Medium)
      .fontColor(active ? $r('app.color.chat_cta_text') : $r('app.color.text_secondary'))
      .width(24)
      .height(24)
      .textAlign(TextAlign.Center)
  }

  @Builder
  modelProviderMark(option: ComposerModelOption) {
    if (modelProviderKind(option) === 'claude') {
      Text('♟')
        .fontSize(uiFontSize(22))
        .fontColor($r('app.color.text_secondary'))
        .width(30)
        .height(30)
        .textAlign(TextAlign.Center)
    } else if (modelProviderKind(option) === 'deepseek') {
      Text('◉')
        .fontSize(uiFontSize(22))
        .fontColor($r('app.color.text_secondary'))
        .width(30)
        .height(30)
        .textAlign(TextAlign.Center)
    } else if (modelProviderKind(option) === 'openai') {
      Text('✣')
        .fontSize(uiFontSize(21))
        .fontColor($r('app.color.text_secondary'))
        .width(30)
        .height(30)
        .textAlign(TextAlign.Center)
    } else {
      Stack({ alignContent: Alignment.Center }) {
          Text(option.providerName.length > 0
          ? option.providerName.charAt(0).toUpperCase()
          : 'S')
          .fontSize(uiFontSize(16))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary'))
      }
      .width(30)
      .height(30)
      .border({ width: 2, color: $r('app.color.text_secondary') })
      .borderRadius(15)
    }
  }

  @Builder
  modelAgentSwitcher() {
    Row({ space: 4 }) {
      ForEach(MODEL_AGENT_KINDS, (kind: string) => {
        Button() {
          Row({ space: 7 }) {
            this.modelAgentMark(kind, this.modelAgentIsActive(kind))
            Text(modelAgentLabel(kind))
              .fontSize(uiFontSize(16))
              .fontWeight(this.modelAgentIsActive(kind) ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.modelAgentIsActive(kind)
                ? $r('app.color.chat_cta_text') : $r('app.color.text_secondary'))
          }
          .justifyContent(FlexAlign.Center)
          .width('100%')
          .height('100%')
        }
        .layoutWeight(1)
        .height(42)
        .padding(0)
        .borderRadius(UI_RADIUS_PILL)
        .backgroundColor(this.modelAgentIsActive(kind)
          ? $r('app.color.chat_cta') : Color.Transparent)
        .enabled(!this.contextRpcBusy
          && (this.modelAgentIsActive(kind) || this.canSwitchSessionAgent()))
        .clickEffect(UI_CLICK_EFFECT)
        .onClick(() => {
          void this.browseModelAgent(kind);
        })
      }, (kind: string) => kind)
    }
    .width('100%')
    .height(52)
    .padding(5)
    .backgroundColor($r('app.color.bg_chip'))
    .border({ width: 1, color: $r('app.color.border') })
    .borderRadius(UI_RADIUS_PILL)
    .margin({ left: 16, right: 16, top: 10 })
  }

  @Builder
  modelOptionRow(option: ComposerModelOption) {
    Row({ space: 10 }) {
      this.modelProviderMark(option)
      Column({ space: 1 }) {
        Row({ space: 8 }) {
          Text(option.label)
            .fontSize(uiFontSize(17))
            .lineHeight(uiLineHeight(23))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (option.subscription) {
            Text('订阅')
              .fontSize(uiFontSize(12))
              .fontColor($r('app.color.text_secondary'))
              .backgroundColor($r('app.color.bg_chip'))
              .borderRadius(UI_RADIUS_CONTROL)
              .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          }
          if (this.modelEffortText(option).length > 0) {
            Text(this.modelEffortText(option))
              .fontSize(uiFontSize(15))
              .lineHeight(uiLineHeight(22))
              .fontColor($r('app.color.text_secondary'))
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.modelOptionIsCurrent(option)) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(uiFontSize(20))
          .fontColor([$r('app.color.text_primary')])
          .margin({ right: 2 })
      }
      Button() {
        SymbolGlyph($r('sys.symbol.slider_horizontal_2'))
          .fontSize(uiFontSize(20))
          .fontColor([$r('app.color.text_secondary')])
      }
      .width(38)
      .height(38)
      .padding(0)
      .borderRadius(UI_RADIUS_PILL)
      .backgroundColor(Color.Transparent)
      .enabled(!this.contextRpcBusy && this.modelOptionHasOptions(option))
      .opacity(this.modelOptionHasOptions(option) ? 1 : 0.4)
      .clickEffect(UI_ICON_CLICK_EFFECT)
      .onClick(() => this.openModelOptions(option))
    }
    .width('calc(100% - 32vp)')
    .constraintSize({ minHeight: 66 })
    .padding({ left: 4, right: 4, top: 8, bottom: 8 })
    .margin({ left: 16, right: 16 })
    .backgroundColor(this.modelOptionIsCurrent(option)
      ? $r('app.color.bg_chip') : Color.Transparent)
    .borderRadius(UI_RADIUS_PILL)
    .opacity(this.contextRpcBusy ? 0.6 : 1)
    .clickEffect(UI_LIST_CLICK_EFFECT)
    .onClick(() => {
      void this.selectComposerModel(option);
    })
  }

  @Builder
  modelContextView() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.canSwitchSessionAgent()) {
          this.modelAgentSwitcher()
        }

        if (this.pendingAgentSwitchIntent !== null) {
          Row({ space: 9 }) {
            SymbolGlyph($r('sys.symbol.clock'))
              .fontSize(uiFontSize(15))
              .fontColor([$r('app.color.text_secondary')])
            Column({ space: 2 }) {
              Text('Agent 切换等待中')
                .fontSize(uiFontSize(13))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text(`${modelAgentLabel(this.pendingAgentSwitchIntent.targetAgentKind)} · ${this.pendingAgentSwitchIntent.model}`)
                .fontSize(uiFontSize(12))
                .fontColor($r('app.color.text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('calc(100% - 32vp)')
          .padding({ left: 12, right: 12, top: 9, bottom: 9 })
          .margin({ left: 16, right: 16 })
          .backgroundColor($r('app.color.bg_chip'))
          .borderRadius(UI_RADIUS_CONTROL)
        }

        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(uiFontSize(20))
            .fontColor([$r('app.color.text_secondary')])
          TextInput({ placeholder: '搜索模型...', text: this.modelSearchQuery })
            .fontSize(uiFontSize(15))
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_secondary'))
            .backgroundColor(Color.Transparent)
            .layoutWeight(1)
            .height(40)
            .padding(0)
            .onChange((value: string) => {
              this.modelSearchQuery = value;
            })
        }
        .width('calc(100% - 32vp)')
        .height(44)
        .padding({ left: 14, right: 12 })
        .border({ width: 1, color: $r('app.color.border') })
        .borderRadius(UI_RADIUS_PILL)
        .margin({ left: 16, right: 16, top: 2, bottom: 2 })

        Column() {
          if (this.filteredModelOptions().length === 0) {
            Text(this.contextRpcBusy ? '正在加载模型...' : '没有匹配的模型')
              .fontSize(uiFontSize(14))
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 28, bottom: 28 })
          } else {
            ForEach(this.filteredModelOptions(), (option: ComposerModelOption) => {
              this.modelOptionRow(option)
            }, (option: ComposerModelOption) => composerModelKey(option))
          }
        }
        .width('100%')
        .padding({ top: 2, bottom: 20 })
      }
      .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  modelOptionsContextView() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.modelOptionsTarget().length > 0) {
          Row({ space: 10 }) {
            this.modelProviderMark(this.modelOptionsTarget()[0])
            Column({ space: 2 }) {
              Text(this.modelOptionsTarget()[0].label)
                .fontSize(uiFontSize(19))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text('选择推理强度')
                .fontSize(uiFontSize(13))
                .fontColor($r('app.color.text_secondary'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 18, bottom: 8 })
        }

        if (this.currentModelEffortOptions().length > 0) {
          Column({ space: 8 }) {
            Text('推理强度')
              .fontSize(uiFontSize(14))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
              ForEach(this.currentModelEffortOptions(), (option: ComposerChoiceOption) => {
                Button(option.label)
                  .height(38)
                  .fontSize(uiFontSize(14))
                  .fontColor(this.modelOptionEffortSelected(option)
                    ? $r('app.color.chat_cta_text') : $r('app.color.text_primary'))
                  .backgroundColor(this.modelOptionEffortSelected(option)
                    ? $r('app.color.chat_cta') : $r('app.color.bg_chip'))
                  .borderRadius(UI_RADIUS_PILL)
                  .margin({ right: 8, bottom: 8 })
                  .enabled(!this.contextRpcBusy)
                  .clickEffect(UI_CLICK_EFFECT)
                  .onClick(() => {
                    void this.selectComposerEffort(option);
                  })
              }, (option: ComposerChoiceOption) => option.id)
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 20, right: 20, top: 12 })
        }

        if (this.currentModelSupportsFastMode()) {
          Row({ space: 12 }) {
            this.contextRowIcon($r('sys.symbol.bolt'))
            Column({ space: 2 }) {
              Text('Fast 模式')
                .fontSize(uiFontSize(16))
                .fontColor($r('app.color.text_primary'))
              Text('使用当前模型的快速服务通道')
                .fontSize(uiFontSize(12))
                .fontColor($r('app.color.text_tertiary'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.session()?.fastMode ?? false })
              .enabled(!this.contextRpcBusy)
              .onChange(() => {
                void this.toggleFastMode();
              })
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 8, bottom: 8 })
        }
      }
      .width('100%')
      .padding({ bottom: 24 })
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  contextRowIcon(symbol: Resource) {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph(symbol)
        .fontSize(uiFontSize(22))
        .fontColor([$r('app.color.text_primary')])
    }
    .width(36)
    .height(36)
    .borderRadius(UI_RADIUS_CONTROL)
    .backgroundColor($r('app.color.bg_chip'))
  }

  @Builder
  contextActionRow(symbol: Resource, title: string, subtitle: string, action: () => void) {
    Row({ space: 12 }) {
      this.contextRowIcon(symbol)
      Column({ space: 2 }) {
        Text(title)
          .fontSize(uiFontSize(16))
          .lineHeight(uiLineHeight(22))
          .fontColor($r('app.color.text_primary'))
        if (subtitle.length > 0) {
          Text(subtitle)
            .fontSize(uiFontSize(12))
            .lineHeight(uiLineHeight(18))
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(uiFontSize(14))
        .fontColor([$r('app.color.text_tertiary')])
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .clickEffect(UI_LIST_CLICK_EFFECT)
    .onClick(action)
  }

  @Builder
  goalContextView() {
    Scroll() {
      if (this.goalState === null) {
        Column({ space: 14 }) {
          Column({ space: 6 }) {
            Text('目标')
              .fontSize(uiFontSize(13))
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            TextArea({ placeholder: '描述要持续推进的结果', text: this.goalObjective })
              .fontSize(uiFontSize(15))
              .placeholderFont({ size: uiFontSize(15) })
              .lineHeight(uiLineHeight(22))
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_tertiary'))
              .caretColor($r('app.color.chat_input_caret'))
              .height(108)
              .width('100%')
              .padding(10)
              .backgroundColor($r('app.color.composer_surface'))
              .border({ width: 1, color: $r('app.color.composer_border') })
              .borderRadius(UI_RADIUS_CONTROL)
              .onChange((value: string) => {
                this.goalObjective = value;
              })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          Text('可选限制')
            .fontSize(uiFontSize(13))
            .fontColor($r('app.color.text_secondary'))
            .width('100%')

          Row({ space: 8 }) {
            Column({ space: 5 }) {
              Text('最大轮数').fontSize(uiFontSize(12)).fontColor($r('app.color.text_tertiary'))
              TextInput({ placeholder: '不限', text: this.goalMaxTurns })
                .type(InputType.Number)
                .height(40)
                .fontSize(uiFontSize(14))
                .backgroundColor($r('app.color.composer_surface'))
                .border({ width: 1, color: $r('app.color.composer_border') })
                .borderRadius(UI_RADIUS_CONTROL)
                .onChange((value: string) => {
                  this.goalMaxTurns = value;
                })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Column({ space: 5 }) {
              Text('token 预算').fontSize(uiFontSize(12)).fontColor($r('app.color.text_tertiary'))
              TextInput({ placeholder: '不限', text: this.goalBudgetTokens })
                .type(InputType.Number)
                .height(40)
                .fontSize(uiFontSize(14))
                .backgroundColor($r('app.color.composer_surface'))
                .border({ width: 1, color: $r('app.color.composer_border') })
                .borderRadius(UI_RADIUS_CONTROL)
                .onChange((value: string) => {
                  this.goalBudgetTokens = value;
                })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Column({ space: 5 }) {
              Text('无进展轮数').fontSize(uiFontSize(12)).fontColor($r('app.color.text_tertiary'))
              TextInput({ placeholder: '3', text: this.goalNoProgressLimit })
                .type(InputType.Number)
                .height(40)
                .fontSize(uiFontSize(14))
                .backgroundColor($r('app.color.composer_surface'))
                .border({ width: 1, color: $r('app.color.composer_border') })
                .borderRadius(UI_RADIUS_CONTROL)
                .onChange((value: string) => {
                  this.goalNoProgressLimit = value;
                })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')

          Button(this.goalActionBusy ? '正在启动…' : '开始目标')
            .width('100%')
            .height(44)
            .fontSize(uiFontSize(15))
            .fontColor($r('app.color.chat_cta_text'))
            .backgroundColor($r('app.color.chat_cta'))
            .borderRadius(UI_RADIUS_CONTROL)
            .enabled(!this.goalActionBusy && !this.isCreationBlockingRemoteOps()
              && this.goalObjective.trim().length > 0)
            .clickEffect(UI_CLICK_EFFECT)
            .onClick(() => {
              void this.startGoal();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16, bottom: 28 })
      } else {
        Column({ space: 14 }) {
          Row({ space: 8 }) {
            Circle()
              .width(8)
              .height(8)
              .fill(this.goalState.status === 'active'
                ? $r('app.color.chat_status_accent')
                : $r('app.color.text_tertiary'))
            Text(this.goalStatusText(this.goalState.status))
              .fontSize(uiFontSize(14))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
          }
          .width('100%')

          Text(this.goalState.objective)
            .fontSize(uiFontSize(17))
            .lineHeight(uiLineHeight(25))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')

          Text(`${this.goalState.currentTurns} 轮 · ${this.goalState.cumulativeTokens} tokens`)
            .fontSize(uiFontSize(13))
            .lineHeight(uiLineHeight(20))
            .fontColor($r('app.color.text_secondary'))
            .width('100%')

          if (this.goalState.lastReason.length > 0) {
            Text(this.goalState.lastReason)
              .fontSize(uiFontSize(13))
              .lineHeight(uiLineHeight(20))
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
          }

          Row({ space: 10 }) {
            if (this.goalState.status === 'active'
              || this.goalState.status === 'paused'
              || this.goalState.status === 'blocked'
              || this.goalState.status === 'usageLimited') {
              Button(this.goalState.status === 'active' ? '暂停' : '继续')
                .height(42)
                .layoutWeight(1)
                .fontColor($r('app.color.text_primary'))
                .backgroundColor($r('app.color.bg_chip'))
                .borderRadius(UI_RADIUS_CONTROL)
                .enabled(!this.goalActionBusy && !this.isCreationBlockingRemoteOps())
                .clickEffect(UI_CLICK_EFFECT)
                .onClick(() => {
                  void this.pauseOrResumeGoal();
                })
            }
            Button('终止')
              .height(42)
              .layoutWeight(1)
              .fontColor($r('app.color.danger'))
              .backgroundColor($r('app.color.bg_chip'))
              .borderRadius(UI_RADIUS_CONTROL)
              .enabled(!this.goalActionBusy && !this.isCreationBlockingRemoteOps())
              .clickEffect(UI_CLICK_EFFECT)
              .onClick(() => this.confirmClearGoal())
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 20, bottom: 28 })
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  // ─── 渲染项分派 ─────────────────────────────────────────────────────────────

  @Builder
  renderItem(item: RenderItem) {
    if (item.type === 'message') {
      if ((item as RenderMessageItem).kind === 'system'
        && (item as RenderMessageItem).message !== undefined
        && (item as RenderMessageItem).message?.systemCardType === 'compact') {
        this.compactBoundaryBlock(item as RenderMessageItem)
      } else if ((item as RenderMessageItem).message !== undefined
        && (item as RenderMessageItem).message?.systemCardType === 'auto-resume') {
        this.autoResumeBlock(item as RenderMessageItem)
      } else if ((item as RenderMessageItem).message?.systemCardType.length) {
        this.systemCardBlock(item as RenderMessageItem)
      } else {
        this.messageBlock(item as RenderMessageItem)
      }
    } else if (item.type === 'thinking') {
      this.thinkingBlock(item as RenderThinkingItem)
    } else if (item.type === 'tool_group') {
      this.toolGroupBlock(item as RenderToolGroupItem)
    } else if (item.type === 'tool_media') {
      this.toolMediaBlock(item as RenderToolMediaItem)
    } else if (item.type === 'agent_task') {
      this.agentTaskBlock(item as RenderAgentTaskItem)
    } else if (item.type === 'subagent_group') {
      this.subagentGroupBlock(item as RenderSubagentGroupItem)
    } else if (item.type === 'todo') {
      this.todoBlock(item as RenderTodoCardItem)
    } else if (item.type === 'work_group') {
      this.workGroupBlock(item as RenderWorkGroupItem)
    }
  }

  private agentTaskStatus(item: RenderAgentTaskItem): string {
    return deriveAgentTaskStatus(
      item.update?.status ?? '',
      item.tool?.toolName ?? '',
      item.tool?.inputRaw ?? '',
      item.tool?.resultText ?? '',
    );
  }

  private agentTaskProvider(item: RenderAgentTaskItem): string {
    if (item.update !== null) return item.update.provider;
    if (item.tool !== null && item.tool.toolName.startsWith('collab:')) return 'codex';
    if (item.tool !== null && item.tool.toolName === 'subagent') return 'pi';
    return 'claude-code';
  }

  private agentTaskInputValue(item: RenderAgentTaskItem, keys: string[]): string {
    if (item.tool === null || item.tool.inputRaw.length === 0) return '';
    try {
      const parsed = JSON.parse(item.tool.inputRaw) as Object;
      if (parsed === undefined || parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return '';
      const record = parsed as Record<string, Object>;
      for (let i = 0; i < keys.length; i++) {
        const value = readStr(record, keys[i]);
        if (value.length > 0) return summarizeText(value, 120);
      }
    } catch (e) {
      return '';
    }
    return '';
  }

  private agentTaskTitle(item: RenderAgentTaskItem): string {
    if (item.update !== null && item.update.title.length > 0) return item.update.title;
    const input = this.agentTaskInputValue(item, ['description', 'name', 'task', 'prompt']);
    return input.length > 0 ? input : 'Agent 任务';
  }

  private agentTaskDescription(item: RenderAgentTaskItem): string {
    if (item.update !== null && item.update.description.length > 0) return item.update.description;
    return this.agentTaskInputValue(item, ['prompt', 'description', 'task']);
  }

  private agentTaskSummary(item: RenderAgentTaskItem): string {
    if (item.tool !== null && item.tool.resultText.length > 0) return item.tool.resultText;
    return item.update !== null ? item.update.summary : '';
  }

  private agentTaskStatusLabel(status: string): string {
    if (status === 'completed') return '已完成';
    if (status === 'failed') return '失败';
    if (status === 'stopped') return '已停止';
    return '运行中';
  }

  private compactMetric(value: number): string {
    if (value >= 1000000) return `${Math.round(value / 100000) / 10}m`;
    if (value >= 1000) return `${Math.round(value / 100) / 10}k`;
    return `${Math.max(0, Math.round(value))}`;
  }

  private agentTaskSubtitle(item: RenderAgentTaskItem): string {
    const parts: string[] = [
      modelAgentLabel(this.agentTaskProvider(item)),
      this.agentTaskStatusLabel(this.agentTaskStatus(item)),
    ];
    const usage = item.update?.usage;
    if (usage !== null && usage !== undefined) {
      if (usage.totalTokens > 0) parts.push(`${this.compactMetric(usage.totalTokens)} tokens`);
      if (usage.toolUses > 0) parts.push(`${Math.round(usage.toolUses)} 次工具调用`);
      if (usage.durationMs > 0) parts.push(this.formatDuration(usage.durationMs));
    }
    return parts.join(' · ');
  }

  private agentTaskHasDetails(item: RenderAgentTaskItem): boolean {
    return this.agentTaskDescription(item).length > 0
      || this.agentTaskSummary(item).length > 0
      || (item.update !== null && (item.update.workflowProgress.length > 0
        || item.update.outputFile.length > 0 || item.update.lastToolName.length > 0));
  }

  @Builder
  agentTaskBlock(item: RenderAgentTaskItem) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        if (this.agentTaskStatus(item) === 'running') {
          LoadingProgress().width(16).height(16).color($r('app.color.text_tertiary'))
        } else if (this.agentTaskStatus(item) === 'failed') {
          SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
            .fontSize(uiFontSize(16))
            .fontColor([$r('app.color.danger')])
        } else {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(uiFontSize(15))
            .fontColor([$r('app.color.text_tertiary')])
        }
        Column({ space: 1 }) {
          Text(this.agentTaskTitle(item))
            .fontSize(uiFontSize(14))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.agentTaskSubtitle(item))
            .fontSize(uiFontSize(12))
            .fontColor(this.agentTaskStatus(item) === 'failed'
              ? $r('app.color.danger') : $r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (this.agentTaskHasDetails(item)) {
          this.disclosureChevron(
            this.isIn(this.expandedTools, item.key), $r('app.color.text_tertiary'))
        }
      }
      .width('100%')
      .clickEffect(this.agentTaskHasDetails(item) ? UI_LIST_CLICK_EFFECT : undefined)
      .onClick(() => {
        if (this.agentTaskHasDetails(item)) this.toggleToolDetails(item.key);
      })

      if (this.agentTaskHasDetails(item) && this.isIn(this.expandedTools, item.key)) {
        Column({ space: 6 }) {
          if (this.agentTaskDescription(item).length > 0) {
            Text(this.agentTaskDescription(item))
              .fontSize(uiFontSize(12))
              .lineHeight(uiLineHeight(18))
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }
          if (item.update !== null && item.update.workflowProgress.length > 0) {
            ForEach(item.update.workflowProgress, (step: WorkflowProgressEntry) => {
              Row({ space: 6 }) {
                Text(step.state === 'done' ? '✓' : (step.state === 'error' ? '!' : '•'))
                  .fontSize(uiFontSize(12))
                  .fontColor(step.state === 'error'
                    ? $r('app.color.danger') : $r('app.color.text_tertiary'))
                Text(step.label.length > 0 ? step.label : (step.title.length > 0 ? step.title : '工作步骤'))
                  .fontSize(uiFontSize(12))
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
              }
              .width('100%')
            }, (step: WorkflowProgressEntry) => `${item.key}-${step.type}-${step.index}`)
          }
          if (this.agentTaskSummary(item).length > 0) {
            Text(this.agentTaskSummary(item))
              .fontSize(uiFontSize(12))
              .fontFamily('monospace')
              .lineHeight(uiLineHeight(18))
              .fontColor($r('app.color.chat_text_secondary'))
              .maxLines(12)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          if (item.update !== null && item.update.lastToolName.length > 0) {
            Text(`最近工具：${item.update.lastToolName}`)
              .fontSize(uiFontSize(11))
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
          }
        }
        .width('100%')
        .padding({ left: 24, top: 2 })
        .transition(uiRevealTransition())
      }
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 10, bottom: 10 })
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.border') })
    .borderRadius(UI_RADIUS_CONTAINER)
    .margin({ top: 3, bottom: 3 })
  }

  private subagentTitle(item: RenderSubagentGroupItem): string {
    if (item.update !== null && item.update.title.length > 0) return item.update.title;
    if (item.description.length > 0) return item.description;
    if (item.subagentType.length > 0) return item.subagentType;
    return '子 Agent';
  }

  @Builder
  subagentGroupBlock(item: RenderSubagentGroupItem) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        if (item.status === 'running') {
          LoadingProgress().width(15).height(15).color($r('app.color.text_tertiary'))
        } else {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(uiFontSize(14))
            .fontColor([$r('app.color.text_tertiary')])
        }
        Column({ space: 1 }) {
          Text(this.subagentTitle(item))
            .fontSize(uiFontSize(14))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(item.status === 'running'
            ? '正在协作' : (item.durationMs >= 0 ? `已完成 · ${this.formatDuration(item.durationMs)}` : '已完成'))
            .fontSize(uiFontSize(12))
            .fontColor($r('app.color.text_tertiary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        this.disclosureChevron(
          this.isIn(this.expandedWorkGroups, item.key), $r('app.color.text_tertiary'))
      }
      .width('100%')
      .constraintSize({ minHeight: 38 })
      .clickEffect(UI_LIST_CLICK_EFFECT)
      .onClick(() => this.toggleWorkGroup(item.key))

      if (this.isIn(this.expandedWorkGroups, item.key)) {
        Column({ space: 5 }) {
          ForEach(item.children, (child: RenderItem) => {
            this.renderItem(child)
          }, (child: RenderItem) => this.renderItemNodeKey(child, `${item.key}-`))
          if (item.summary.length > 0) {
            Text(item.summary)
              .fontSize(uiFontSize(12))
              .lineHeight(uiLineHeight(18))
              .fontColor($r('app.color.chat_text_secondary'))
              .maxLines(12)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .padding({ top: 4 })
          }
        }
        .width('100%')
        .padding({ left: 12, top: 2, bottom: 2 })
        .border({ width: { left: 2 }, color: { left: $r('app.color.border') } })
        .transition(uiRevealTransition())
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 5, bottom: 5 })
  }

  /** 工具产出的媒体：独立于工作过程折叠块，保留完整可见结果。 */
  @Builder
  toolMediaBlock(item: RenderToolMediaItem) {
    Column({ space: 6 }) {
      Text('媒体结果')
        .fontSize(uiFontSize(12))
        .fontColor($r('app.color.text_tertiary'))
      if (item.images.length > 0) {
        List({ space: 8 }) {
          ForEach(item.images, (ref: RemoteImageRef) => {
            ListItem() {
              this.toolMediaImage(ref)
            }
          }, (ref: RemoteImageRef) => `${item.key}-${ref.url}`)
        }
        .listDirection(Axis.Horizontal)
        .height(176)
        .width('100%')
      }
      if (item.media.length > 0) {
        ForEach(item.media, (payload: RenderMediaPayload) => {
          if (payload.kind !== 'image') {
            this.toolMediaFile(payload)
          }
        }, (payload: RenderMediaPayload) => `${item.key}-${payload.kind}-${payload.url}`)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  toolMediaFile(payload: RenderMediaPayload) {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(payload.kind === 'video'
          ? $r('sys.symbol.play') : $r('sys.symbol.waveform'))
          .fontSize(uiFontSize(18))
          .fontColor([$r('app.color.text_primary')])
      }
      .width(36)
      .height(36)
      .backgroundColor($r('app.color.bg_chip'))
      .borderRadius(UI_RADIUS_CONTROL)
      Column({ space: 2 }) {
        Text(payload.title.length > 0 ? payload.title : (payload.kind === 'video' ? '视频' : '音频'))
          .fontSize(uiFontSize(14))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(payload.kind === 'video' ? '点击播放视频' : '点击播放音频')
          .fontSize(uiFontSize(12))
          .fontColor($r('app.color.text_tertiary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      this.disclosureChevron(false, $r('app.color.text_tertiary'))
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.border') })
    .borderRadius(UI_RADIUS_CONTAINER)
    .clickEffect(UI_LIST_CLICK_EFFECT)
    .onClick(() => void this.openToolMedia(payload))
  }

  @Builder
  toolMediaImage(ref: RemoteImageRef) {
    if ((this.imageSources.get(ref.url) ?? '').length > 0) {
      Image(this.imageSources.get(ref.url) ?? '')
        .width(220)
        .height(165)
        .borderRadius(UI_RADIUS_CONTROL)
        .objectFit(ImageFit.Contain)
        .clickEffect(UI_CLICK_EFFECT)
        .onClick(() => this.openImagePreview(ref))
        .onError(() => this.handleNativeImageError(ref.url, ref))
    } else if (this.imageStatus(ref.url) === 'error') {
      this.mediaErrorFrame(220, 165, () => this.retryImage(ref.url, ref))
    } else {
      Row({ space: 6 }) {
        LoadingProgress()
          .width(16)
          .height(16)
        Text(ref.originalName.length > 0 ? ref.originalName : '图片')
          .fontSize(uiFontSize(12))
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width(220)
      .height(165)
      .justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.bg_chip'))
      .borderRadius(UI_RADIUS_CONTROL)
    }
  }

  /** 折叠入口统一使用旋转的右箭头，避免切换两个 glyph 时产生跳帧。 */
  @Builder
  disclosureChevron(expanded: boolean, tint: Resource) {
    SymbolGlyph($r('sys.symbol.chevron_right'))
      .fontSize(uiFontSize(13))
      .fontColor([tint])
      .width(16)
      .rotate({ angle: expanded ? 90 : 0 })
      .animation({ duration: UI_MOTION_FAST, curve: UI_CURVE_MOVE })
  }

  /**
   * 工作过程折叠面板：历史默认折叠，活动中的 work_group 保留 Mobile 同款
   * 收起态实时步骤预览；点击后展示完整 thinking / tool 行。
   */
  @Builder
  workGroupBlock(item: RenderWorkGroupItem) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        if (item.isStreaming) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color($r('app.color.text_tertiary'))
        } else {
          SymbolGlyph($r('sys.symbol.layer'))
            .fontSize(uiFontSize(14))
            .fontColor([$r('app.color.text_tertiary')])
            .width(16)
        }
        Text(this.workGroupTitle(item))
          .fontSize(uiFontSize(14))
          .lineHeight(uiLineHeight(20))
          .fontColor($r('app.color.chat_text_secondary'))
          .layoutWeight(1)
        if (item.isStreaming) {
          Text(this.formatDuration(this.workElapsedMs(item)))
            .fontSize(uiFontSize(12))
            .fontColor($r('app.color.text_tertiary'))
        }
        this.disclosureChevron(
          this.isIn(this.expandedWorkGroups, item.key),
          $r('app.color.text_tertiary'),
        )
      }
      .constraintSize({ minHeight: 22 })
      .padding({ top: 2, bottom: 2 })
      .clickEffect(UI_LIST_CLICK_EFFECT)
      .onClick(() => {
        this.toggleWorkGroup(item.key);
      })
      .width('100%')

      if (item.isStreaming
        && !this.isIn(this.expandedWorkGroups, item.key)
        && workPreviewRows(item).length > 0) {
        Column() {
          ForEach(workPreviewRows(item), (row: WorkPreviewRow) => {
            this.workPreviewRow(row)
          }, (row: WorkPreviewRow) => `${item.key}-${row.key}`)
        }
        .width('100%')
        .padding({ left: 10, top: 2, bottom: 2 })
        .border({ width: { left: 2 }, color: { left: $r('app.color.border') } })
        .transition(uiRevealTransition())
      }

      if (this.isIn(this.expandedWorkGroups, item.key)) {
        Column({ space: 4 }) {
          ForEach(item.children, (child: RenderItem) => {
            // shared/Desktop 的 outer work_group 展开后直接展示活动内容；Harmony
            // 模型为保持时长边界可能保留一层 nested work_group，这里只展开它的
            // chrome，不再给用户第二个“已工作”折叠入口。
            this.workGroupChild(child)
          }, (child: RenderItem) => `${item.key}-${child.key}`)
        }
        .width('100%')
        .padding({ left: 10, top: 2, bottom: 2 })
        .border({ width: { left: 2 }, color: { left: $r('app.color.border') } })
        .transition(uiRevealTransition())
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  workPreviewRow(row: WorkPreviewRow) {
    if (row.kind === 'tool' && row.tool !== null && row.action !== null) {
      // Mobile 的 collapsedBody 仍使用完整 ToolActionRow：收起态最近步骤也可
      // 直接展开命令、输出和 diff，并与工作组完整展开态共享同一个稳定 key。
      this.toolRow(row.tool as RenderToolItem, row.action as ToolActionPresentation)
    } else {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.wand_and_stars'))
          .fontSize(uiFontSize(14))
          .fontColor([$r('app.color.text_tertiary')])
          .width(16)
        Text(row.text)
          .fontSize(uiFontSize(14))
          .lineHeight(uiLineHeight(20))
          .fontStyle(FontStyle.Italic)
          .fontColor($r('app.color.chat_text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .constraintSize({ minHeight: 28 })
      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
    }
  }

  @Builder
  workGroupChild(child: RenderItem) {
    if (child.type === 'work_group') {
      ForEach((child as RenderWorkGroupItem).children, (nested: RenderItem) => {
        this.workGroupChild(nested)
      }, (nested: RenderItem) => `${child.key}-${nested.key}`)
    } else {
      this.renderItem(child)
    }
  }

  private autoResumePresentation(item: RenderMessageItem): AutoResumePresentation {
    const data: Record<string, Object> = {};
    if (item.message !== undefined) return deriveAutoResumePresentation(
      item.message.systemCardData, item.autoResumeInFlight);
    return deriveAutoResumePresentation(data, item.autoResumeInFlight);
  }

  private autoResumeExpandKey(item: RenderMessageItem): string {
    return `auto-resume:${item.key}`;
  }

  private autoResumeLabel(item: RenderMessageItem): string {
    const state = this.autoResumePresentation(item).state;
    if (state === 'live') {
      const info = this.autoResumePresentation(item);
      return info.attempt > 0 && info.maxAttempts > 0
        ? `正在自动续跑（${info.attempt}/${info.maxAttempts}）…`
        : '正在自动续跑…';
    }
    if (state === 'succeeded') return '自动续跑已恢复';
    if (state === 'failed') return '自动续跑失败';
    return '自动续跑';
  }

  @Builder
  autoResumeBlock(item: RenderMessageItem) {
    if (this.autoResumePresentation(item).state === 'separator') {
      Row({ space: 8 }) {
        Divider().color($r('app.color.border')).layoutWeight(1)
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(uiFontSize(11))
            .fontColor([$r('app.color.text_tertiary')])
          Text('自动续跑')
            .fontSize(uiFontSize(11))
            .fontColor($r('app.color.text_tertiary'))
        }
        .padding({ left: 9, right: 9, top: 5, bottom: 5 })
        .backgroundColor($r('app.color.bg_chip'))
        .border({ width: 1, color: $r('app.color.border') })
        .borderRadius(UI_RADIUS_PILL)
        Divider().color($r('app.color.border')).layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
    } else {
      Column({ space: 7 }) {
        Row({ space: 8 }) {
          if (this.autoResumePresentation(item).state === 'live') {
            LoadingProgress()
              .width(16)
              .height(16)
              .color($r('app.color.warn'))
          } else if (this.autoResumePresentation(item).state === 'succeeded') {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(uiFontSize(15))
              .fontColor([$r('app.color.success')])
          } else if (this.autoResumePresentation(item).state === 'failed') {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(uiFontSize(14))
              .fontColor([$r('app.color.danger')])
          } else {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(uiFontSize(15))
              .fontColor([$r('app.color.text_tertiary')])
          }
          Text(this.autoResumeLabel(item))
            .fontSize(uiFontSize(13))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.autoResumePresentation(item).state === 'failed'
              ? $r('app.color.danger') : $r('app.color.text_primary'))
            .maxLines(1)
          if (this.autoResumePresentation(item).summary.length > 0) {
            Text(this.autoResumePresentation(item).summary)
              .fontSize(uiFontSize(12))
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          } else {
            Blank().layoutWeight(1)
          }
          if (this.autoResumePresentation(item).canExpand) {
            this.disclosureChevron(
              this.isIn(this.expandedTextBlocks, this.autoResumeExpandKey(item)),
              $r('app.color.text_tertiary'))
          }
        }
        .width('100%')
        .constraintSize({ minHeight: 30 })
        .clickEffect(this.autoResumePresentation(item).canExpand ? UI_LIST_CLICK_EFFECT : undefined)
        .onClick(() => {
          if (this.autoResumePresentation(item).canExpand) {
            this.toggleTextBlock(this.autoResumeExpandKey(item));
          }
        })

        if (this.autoResumePresentation(item).canExpand
          && this.isIn(this.expandedTextBlocks, this.autoResumeExpandKey(item))) {
          Column({ space: 6 }) {
            if (this.autoResumePresentation(item).error.length > 0) {
              Text('中断原因')
                .fontSize(uiFontSize(11))
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
              Text(this.autoResumePresentation(item).error)
                .fontSize(uiFontSize(12))
                .lineHeight(uiLineHeight(18))
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
            }
            if (this.autoResumePresentation(item).attempt > 0
              && this.autoResumePresentation(item).maxAttempts > 0) {
              Text(`第 ${this.autoResumePresentation(item).attempt}/${this.autoResumePresentation(item).maxAttempts} 次尝试`)
                .fontSize(uiFontSize(11))
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
            }
            if (this.autoResumePresentation(item).sessionTotal > 0) {
              Text(`本任务累计自动续跑 ${this.autoResumePresentation(item).sessionTotal} 次`)
                .fontSize(uiFontSize(11))
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 24, right: 4, top: 2 })
          .transition(uiRevealTransition())
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 12, right: 12, top: 9, bottom: 9 })
      .backgroundColor($r('app.color.bg_chip'))
      .border({ width: 1, color: $r('app.color.border') })
      .borderRadius(UI_RADIUS_CONTROL)
    }
  }

  /** 自动压缩边界：与 Desktop CompactBoundaryCard 同款“分隔线 + 居中 chip”。 */
  @Builder
  compactBoundaryBlock(item: RenderMessageItem) {
    Row({ space: 8 }) {
      Divider()
        .color($r('app.color.border'))
        .layoutWeight(1)
      Row({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.layer'))
          .fontSize(uiFontSize(11))
          .fontColor([$r('app.color.text_tertiary')])
        Text(this.compactBoundaryLabel(item))
          .fontSize(uiFontSize(11))
          .fontColor($r('app.color.text_tertiary'))
      }
      .padding({ left: 9, right: 9, top: 5, bottom: 5 })
      .backgroundColor($r('app.color.bg_chip'))
      .border({ width: 1, color: $r('app.color.border') })
      .borderRadius(UI_RADIUS_PILL)
      Divider()
        .color($r('app.color.border'))
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }

  private systemCardPresentation(item: RenderMessageItem): SystemCardPresentation {
    if (item.message === undefined) return deriveSystemCardPresentation('', {});
    return deriveSystemCardPresentation(
      item.message.systemCardType,
      item.message.systemCardData,
    );
  }

  @Builder
  systemCardBlock(item: RenderMessageItem) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        SymbolGlyph(this.systemCardPresentation(item).danger
          ? $r('sys.symbol.exclamationmark_circle') : $r('sys.symbol.flag'))
          .fontSize(uiFontSize(15))
          .fontColor([this.systemCardPresentation(item).danger
            ? $r('app.color.danger') : $r('app.color.text_secondary')])
        Text(this.systemCardPresentation(item).title)
          .fontSize(uiFontSize(13))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.systemCardPresentation(item).danger
            ? $r('app.color.danger') : $r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      if (this.systemCardPresentation(item).subtitle.length > 0) {
        Text(this.systemCardPresentation(item).subtitle)
          .fontSize(uiFontSize(12))
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
      if (this.systemCardPresentation(item).body.length > 0) {
        Text(this.systemCardPresentation(item).body)
          .fontSize(uiFontSize(13))
          .lineHeight(uiLineHeight(20))
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .maxLines(12)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      ForEach(this.systemCardPresentation(item).rows, (row: SystemCardRow) => {
        Row({ space: 12 }) {
          Text(row.label)
            .fontSize(uiFontSize(11))
            .fontColor($r('app.color.text_tertiary'))
            .width(72)
          Text(row.value)
            .fontSize(uiFontSize(12))
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
        }
        .width('100%')
      }, (row: SystemCardRow) => `${row.label}-${row.value}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.border') })
    .borderRadius(UI_RADIUS_CONTAINER)
  }

  /** 历史消息图片缩略图（点击全屏预览）。 */
  @Builder
  imageThumb(ref: RemoteImageRef) {
    if ((this.imageSources.get(ref.url) ?? '').length > 0) {
      Image(this.imageSources.get(ref.url) ?? '')
        .width(88)
        .height(88)
        .borderRadius(UI_RADIUS_CONTROL)
        .objectFit(ImageFit.Contain)
        .clickEffect(UI_CLICK_EFFECT)
        .onClick(() => this.openImagePreview(ref))
        .onError(() => this.handleNativeImageError(ref.url, ref))
    } else if (this.imageStatus(ref.url) === 'error') {
      this.mediaErrorFrame(88, 88, () => this.retryImage(ref.url, ref))
    } else {
      Row() {
        LoadingProgress().width(16).height(16)
      }
      .width(88)
      .height(88)
      .justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.bg_chip'))
      .borderRadius(UI_RADIUS_CONTROL)
    }
  }

  @Builder
  mediaErrorFrame(width: number, height: number, retry: () => void) {
    Column({ space: 5 }) {
      SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
        .fontSize(uiFontSize(17))
        .fontColor([$r('app.color.text_tertiary')])
      Text('加载失败 · 重试')
        .fontSize(uiFontSize(11))
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
    }
    .width(width)
    .height(height)
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.bg_chip'))
    .borderRadius(UI_RADIUS_CONTROL)
    .clickEffect(UI_CLICK_EFFECT)
    .onClick(retry)
  }

  /** 交互卡分派（按 kind）。 */
  @Builder
  pendingInteractionSwitcher() {
    Row({ space: 8 }) {
      Text(`待处理 ${this.pendingInteractions.length} 个`)
        .fontSize(uiFontSize(12))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
      Scroll() {
        Row({ space: 6 }) {
          ForEach(this.pendingInteractions, (item: PendingInteraction, index?: number) => {
            Button(`${(index ?? 0) + 1} · ${interactionKindLabel(item.kind)}`)
              .type(ButtonType.Normal)
              .height(30)
              .padding({ left: 12, right: 12 })
              .fontSize(uiFontSize(12))
              .fontWeight(FontWeight.Medium)
              .fontColor(item.requestId === this.activeInteractionRequestId
                ? $r('app.color.chat_cta_text') : $r('app.color.text_secondary'))
              .backgroundColor(item.requestId === this.activeInteractionRequestId
                ? $r('app.color.chat_cta') : $r('app.color.bg_chip'))
              .borderRadius(UI_RADIUS_PILL)
              .clickEffect(UI_CLICK_EFFECT)
              .onClick(() => this.selectPendingInteraction(item.requestId))
          }, (item: PendingInteraction) => item.requestId)
        }
      }
      .layoutWeight(1)
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .constraintSize({ minHeight: 34 })
  }

  /** 交互卡分派（按 kind）。 */
  @Builder
  pendingInteractionCard(item: PendingInteraction) {
    if (item.kind === 'permission') {
      this.permissionCard(item)
    } else if (item.kind === 'ask_user_question') {
      this.askUserCard(item)
    } else if (item.kind === 'plan_review') {
      this.planReviewCard(item)
    } else if (item.kind === 'issue_confirm') {
      this.desktopOnlyInteractionCard(item, 'Issue 确认', '请回到电脑端确认标题与正文后再继续。')
    } else if (item.kind === 'plugin_setup') {
      this.pluginSetupCard(item)
    } else {
      Text(`交互请求（${item.kind}）`)
        .fontSize(uiFontSize(13))
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .padding(14)
        .backgroundColor($r('app.color.bg_card'))
        .border({ width: 1, color: $r('app.color.border') })
        .borderRadius(UI_RADIUS_CONTAINER)
    }
  }

  @Builder
  desktopOnlyInteractionCard(item: PendingInteraction, title: string, message: string) {
    Column({ space: 10 }) {
      this.interactionCardHeader($r('sys.symbol.doc_text'), title)
      Text(message)
        .fontSize(uiFontSize(13))
        .lineHeight(uiLineHeight(19))
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      if (this.requestStr(item, 'title').length > 0) {
        Text(this.requestStr(item, 'title'))
          .fontSize(uiFontSize(13))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding(10)
          .backgroundColor($r('app.color.bg_chip'))
          .borderRadius(UI_RADIUS_CONTROL)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.border') })
    .borderRadius(UI_RADIUS_CONTAINER)
    .transition(uiOverlayTransition())
  }

  @Builder
  pluginSetupCard(item: PendingInteraction) {
    Column({ space: 10 }) {
      this.interactionCardHeader($r('sys.symbol.gearshape'), '插件配置')
      Text(this.pluginSetupTitle(item))
        .fontSize(uiFontSize(14))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Text(this.requestBool(item, 'terminal')
        ? '电脑端已完成这次配置。'
        : '敏感配置和授权需要在电脑端完成，这里仅显示进度。')
        .fontSize(uiFontSize(13))
        .lineHeight(uiLineHeight(19))
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      if (this.pluginSetupCanCancel(item)) {
        Row() {
          Row().layoutWeight(1)
          this.interactionSecondaryButton('取消请求', true,
            () => this.resolveInteraction(item, this.pluginSetupCancelDecision(item)),
            !AppServices.instance.interactions.isResolving(item.requestId))
        }
        .width('100%')
      }
      if (AppServices.instance.interactions.resolveError(item.requestId).length > 0) {
        Text(AppServices.instance.interactions.resolveError(item.requestId))
          .fontSize(uiFontSize(12))
          .fontColor($r('app.color.danger'))
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.border') })
    .borderRadius(UI_RADIUS_CONTAINER)
    .transition(uiOverlayTransition())
  }

  /** 交互卡统一头部：图标 + 标题。 */
  @Builder
  interactionCardHeader(symbol: Resource, title: string) {
    Row({ space: 8 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(symbol)
          .fontSize(uiFontSize(16))
          .fontColor([$r('app.color.text_primary')])
      }
      .width(28)
      .height(28)
      .backgroundColor($r('app.color.bg_chip'))
      .borderRadius(UI_RADIUS_CONTROL)
      Text(title)
        .fontSize(uiFontSize(14))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
    }
    .width('100%')
  }

  /** 交互卡次要按钮（拒绝 / 跳过）：描边胶囊。 */
  @Builder
  interactionSecondaryButton(label: string, danger: boolean, action: () => void, enabled: boolean = true) {
    Button(label)
      .type(ButtonType.Normal)
      .height(34)
      .fontSize(uiFontSize(13))
      .fontWeight(FontWeight.Medium)
      .fontColor(danger ? $r('app.color.danger') : $r('app.color.text_primary'))
      .backgroundColor($r('app.color.bg_card'))
      .border({ width: 1, color: $r('app.color.border') })
      .borderRadius(UI_RADIUS_PILL)
      .padding({ left: 16, right: 16 })
      .enabled(enabled)
      .opacity(enabled ? 1 : 0.55)
      .clickEffect(UI_CLICK_EFFECT)
      .onClick(action)
  }

  /** 交互卡主按钮（允许 / 提交 / 批准）：实心反色胶囊。 */
  @Builder
  interactionPrimaryButton(label: string, action: () => void, enabled: boolean = true) {
    Button(label)
      .type(ButtonType.Normal)
      .height(34)
      .fontSize(uiFontSize(13))
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.chat_cta_text'))
      .backgroundColor($r('app.color.chat_cta'))
      .borderRadius(UI_RADIUS_PILL)
      .padding({ left: 16, right: 16 })
      .enabled(enabled)
      .opacity(enabled ? 1 : 0.55)
      .clickEffect(UI_CLICK_EFFECT)
      .onClick(action)
  }

  /** Permission 卡：允许一次 / 始终允许 / 拒绝。 */
  @Builder
  permissionCard(item: PendingInteraction) {
    Column({ space: 10 }) {
      this.interactionCardHeader($r('sys.symbol.lock'), '权限请求')
      Text(this.permissionIsArmed(item) ? '确认高风险操作' : this.permissionToolName(item))
        .fontSize(uiFontSize(14))
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      if (this.permissionInputSummary(item).length > 0) {
        Text(this.permissionInputSummary(item))
          .fontSize(uiFontSize(12))
          .lineHeight(uiLineHeight(17))
          .fontColor($r('app.color.text_secondary'))
          .maxLines(12)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .copyOption(CopyOptions.LocalDevice)
          .width('100%')
      }
      if (this.permissionRiskText(item).length > 0) {
        Text(this.permissionIsArmed(item)
          ? '再次点击“确认允许”才会执行；不确定时请选择拒绝。'
          : this.permissionRiskText(item))
          .fontSize(uiFontSize(12))
          .lineHeight(uiLineHeight(17))
          .fontColor($r('app.color.chat_status_accent'))
          .width('100%')
      }
      Row({ space: 8 }) {
        this.interactionSecondaryButton('拒绝', true,
          () => this.handlePermissionDecision(item, 'deny'),
          !this.interactionBusy(item))
        Row().layoutWeight(1)
        this.interactionPrimaryButton(this.permissionIsArmed(item) ? '确认允许' : '允许一次',
          () => this.handlePermissionDecision(item, 'allow-once'),
          !this.interactionBusy(item))
        if (this.permissionCanAlwaysAllow(item)) {
          this.interactionPrimaryButton('始终允许',
            () => this.handlePermissionDecision(item, 'always-allow'),
            !this.interactionBusy(item))
        }
      }
      .width('100%')
      if (AppServices.instance.interactions.resolveError(item.requestId).length > 0) {
        Text(AppServices.instance.interactions.resolveError(item.requestId))
          .fontSize(uiFontSize(12))
          .fontColor($r('app.color.danger'))
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.border') })
    .borderRadius(UI_RADIUS_CONTAINER)
    .transition(uiOverlayTransition())
  }

  /** Ask User 卡：问题 + 选项（单选/多选）+ 自定义输入 + 提交。 */
  @Builder
  askUserCard(item: PendingInteraction) {
    Column({ space: 10 }) {
      this.interactionCardHeader($r('sys.symbol.ellipsis_message'), '请确认')
      if (this.askQuestionCount(item) === 0) {
        Text('问题内容暂不可用，可继续让电脑端处理。')
          .fontSize(uiFontSize(13))
          .lineHeight(uiLineHeight(19))
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        Row() {
          Row().layoutWeight(1)
          this.interactionPrimaryButton('继续',
            () => this.resolveInteraction(item, this.askEmptyDecision()),
            !this.interactionBusy(item))
        }
        .width('100%')
      } else {
        Row({ space: 8 }) {
          Text(`问题 ${this.askCurrentIndex(item) + 1} / ${this.askQuestionCount(item)}`)
            .fontSize(uiFontSize(12))
            .fontColor($r('app.color.text_tertiary'))
          Text(this.askMultiSelect(item) ? '可多选' : '单选')
            .fontSize(uiFontSize(12))
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')

        Text(this.askQuestion(item))
          .fontSize(uiFontSize(14))
          .lineHeight(uiLineHeight(20))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')

        if (this.askOptionRows(item).length > 0) {
          ForEach(this.askOptionRows(item), (opt: AskOptionPresentation) => {
            Row({ space: 8 }) {
              Stack({ alignContent: Alignment.Center }) {
                if (this.isAskSelected(item, opt.label)) {
                  SymbolGlyph($r('sys.symbol.checkmark'))
                    .fontSize(uiFontSize(12))
                    .fontColor([$r('app.color.chat_cta_text')])
                }
              }
              .width(18)
              .height(18)
              .backgroundColor(this.isAskSelected(item, opt.label)
                ? $r('app.color.chat_cta') : Color.Transparent)
              .border({ width: 1, color: $r('app.color.border') })
              .borderRadius(this.askMultiSelect(item) ? UI_RADIUS_CONTROL : UI_RADIUS_PILL)
              Column({ space: 2 }) {
                Text(opt.label)
                  .fontSize(uiFontSize(13))
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .width('100%')
                if (opt.description.length > 0) {
                  Text(opt.description)
                    .fontSize(uiFontSize(12))
                    .lineHeight(uiLineHeight(17))
                    .fontColor($r('app.color.text_secondary'))
                    .width('100%')
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .constraintSize({ minHeight: 40 })
            .padding({ left: 10, right: 10 })
            .backgroundColor(this.isAskSelected(item, opt.label)
              ? $r('app.color.bg_chip') : Color.Transparent)
            .border({ width: 1, color: $r('app.color.border') })
            .borderRadius(UI_RADIUS_CONTROL)
            .enabled(!this.interactionBusy(item))
            .clickEffect(UI_CLICK_EFFECT)
            .onClick(() => this.toggleAskSelection(item, opt.label))
          }, (opt: AskOptionPresentation) =>
            `${item.requestId}-${this.askCurrentIndex(item)}-${opt.label}`)
        }

        TextInput({ placeholder: '自定义回答…', text: this.askCustomInput(item) })
          .onChange((v: string) => this.updateAskCustomInput(item, v))
          .fontSize(uiFontSize(13))
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_placeholder'))
          .caretColor($r('app.color.chat_input_caret'))
          .height(40)
          .padding({ left: 12, right: 12 })
          .backgroundColor($r('app.color.bg_page'))
          .border({ width: 1, color: $r('app.color.border') })
          .borderRadius(UI_RADIUS_PILL)
          .enabled(!this.interactionBusy(item))

        if (AppServices.instance.interactions.resolveError(item.requestId).length > 0) {
          Text(AppServices.instance.interactions.resolveError(item.requestId))
            .fontSize(uiFontSize(12))
            .fontColor($r('app.color.danger'))
            .width('100%')
        }

        Row({ space: 8 }) {
          if (this.askCurrentIndex(item) > 0) {
            this.interactionSecondaryButton('上一题', false,
              () => this.moveAskQuestion(item, -1), !this.interactionBusy(item))
          }
          this.interactionSecondaryButton('跳过', false,
            () => this.skipAskQuestion(item), !this.interactionBusy(item))
          Row().layoutWeight(1)
          this.interactionPrimaryButton(this.askIsLast(item) ? '提交回答' : '下一题',
            () => this.submitAskQuestion(item),
            !this.interactionBusy(item) && this.askCurrentAnswer(item).trim().length > 0)
        }
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.border') })
    .borderRadius(UI_RADIUS_CONTAINER)
    .transition(uiOverlayTransition())
  }

  /** Plan Review 卡：计划查看 + 批准 / 反馈拒绝。 */
  @Builder
  planReviewCard(item: PendingInteraction) {
    Column({ space: 10 }) {
      this.interactionCardHeader($r('sys.symbol.doc_text'), '计划审批')
      if (this.planEvidence(item).filePath.length > 0) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.doc'))
            .fontSize(uiFontSize(15))
            .fontColor([$r('app.color.text_secondary')])
          Column({ space: 1 }) {
            Text(this.planEvidence(item).fileName)
              .fontSize(uiFontSize(12))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(this.planEvidence(item).compactPath)
              .fontSize(uiFontSize(11))
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 7, bottom: 7 })
        .backgroundColor($r('app.color.bg_chip'))
        .borderRadius(UI_RADIUS_CONTROL)
        .clickEffect(UI_CLICK_EFFECT)
        .onClick(() => this.copyPlainText(this.planEvidence(item).filePath, '已复制计划文件路径'))
      }
      if (this.planEvidence(item).outlineItems.length > 0) {
        Scroll() {
          Row({ space: 6 }) {
            Text('目录')
              .fontSize(uiFontSize(11))
              .fontColor($r('app.color.text_tertiary'))
            ForEach(this.planEvidence(item).outlineItems, (outline: PlanOutlinePresentation) => {
              Text(outline.title)
                .fontSize(uiFontSize(11))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_secondary'))
                .maxLines(1)
                .padding({ left: 9, right: 9, top: 5, bottom: 5 })
                .backgroundColor($r('app.color.bg_chip'))
                .borderRadius(UI_RADIUS_PILL)
            }, (outline: PlanOutlinePresentation) => outline.id)
            if (this.planEvidence(item).outlineOverflowCount > 0) {
              Text(`+${this.planEvidence(item).outlineOverflowCount}`)
                .fontSize(uiFontSize(11))
                .fontColor($r('app.color.text_tertiary'))
            }
          }
        }
        .width('100%')
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
      }
      Row({ space: 8 }) {
        Text(this.planDraftEdited(item) ? '已编辑' : '请检查完整计划后再批准')
          .fontSize(uiFontSize(12))
          .fontColor($r('app.color.text_tertiary'))
          .layoutWeight(1)
        Button(this.planDraft(item).editMode ? '完成编辑' : '编辑')
          .type(ButtonType.Normal)
          .height(30)
          .padding({ left: 12, right: 12 })
          .fontSize(uiFontSize(12))
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.bg_chip'))
          .borderRadius(UI_RADIUS_PILL)
          .enabled(!this.interactionBusy(item))
          .onClick(() => this.togglePlanEdit(item))
        if (!this.planDraft(item).editMode) {
          Button(this.planDraft(item).expanded ? '收起' : '查看全文')
            .type(ButtonType.Normal)
            .height(30)
            .padding({ left: 12, right: 12 })
            .fontSize(uiFontSize(12))
            .fontColor($r('app.color.text_primary'))
            .backgroundColor($r('app.color.bg_chip'))
            .borderRadius(UI_RADIUS_PILL)
            .onClick(() => this.togglePlanExpanded(item))
        }
      }
      .width('100%')

      if (this.planDraft(item).editMode) {
        TextArea({ text: this.planText(item), placeholder: '输入计划内容' })
          .fontSize(uiFontSize(12))
          .lineHeight(uiLineHeight(18))
          .fontColor($r('app.color.code_text'))
          .caretColor($r('app.color.chat_input_caret'))
          .height(220)
          .padding(10)
          .backgroundColor($r('app.color.bg_code'))
          .border({ width: 1, color: $r('app.color.border') })
          .borderRadius(UI_RADIUS_CONTROL)
          .enabled(!this.interactionBusy(item))
          .onChange((value: string) => this.updatePlanText(item, value))
      } else {
        Text(this.planText(item).length > 0 ? this.planText(item) : '计划内容为空')
          .fontSize(uiFontSize(12))
          .lineHeight(uiLineHeight(18))
          .fontColor($r('app.color.code_text'))
          .maxLines(this.planDraft(item).expanded ? 1000 : 8)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding(10)
          .backgroundColor($r('app.color.bg_code'))
          .border({ width: 1, color: $r('app.color.border') })
          .borderRadius(UI_RADIUS_CONTROL)
      }

      if (this.planDraft(item).feedbackOpen) {
        TextArea({ text: this.planDraft(item).feedback, placeholder: '说明需要修改的内容…' })
          .fontSize(uiFontSize(13))
          .lineHeight(uiLineHeight(19))
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_placeholder'))
          .caretColor($r('app.color.chat_input_caret'))
          .constraintSize({ minHeight: 76, maxHeight: 140 })
          .padding(10)
          .backgroundColor($r('app.color.bg_page'))
          .border({ width: 1, color: $r('app.color.border') })
          .borderRadius(UI_RADIUS_CONTROL)
          .enabled(!this.interactionBusy(item))
          .onChange((value: string) => this.updatePlanFeedback(item, value))
      }

      if (AppServices.instance.interactions.resolveError(item.requestId).length > 0) {
        Text(AppServices.instance.interactions.resolveError(item.requestId))
          .fontSize(uiFontSize(12))
          .fontColor($r('app.color.danger'))
          .width('100%')
      }

      Row({ space: 8 }) {
        this.interactionSecondaryButton(this.planDraft(item).feedbackOpen ? '提交反馈' : '反馈修改', true,
          () => this.requestPlanFeedback(item),
          !this.interactionBusy(item)
            && (!this.planDraft(item).feedbackOpen || this.planDraft(item).feedback.trim().length > 0))
        Row().layoutWeight(1)
        this.interactionPrimaryButton('批准计划',
          () => this.resolveInteraction(item, this.planDecision(item, true)),
          !this.interactionBusy(item) && this.planText(item).trim().length > 0)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.border') })
    .borderRadius(UI_RADIUS_CONTAINER)
    .transition(uiOverlayTransition())
  }

  private hasVisibleMessageBody(item: RenderMessageItem): boolean {
    return item.body.trim().length > 0 || item.mdBlocks.length > 0 || item.segments.length > 0;
  }

  private attachmentTitle(file: RemoteSerializedAttachment): string {
    if (file.name.length > 0) return file.name;
    if (file.originalName.length > 0) return file.originalName;
    return '附件';
  }

  private attachmentMeta(file: RemoteSerializedAttachment): string {
    const parts: string[] = [];
    if (file.ext.length > 0) parts.push(file.ext.toUpperCase());
    else if (file.category.length > 0) parts.push(file.category.toUpperCase());
    if (file.size > 0) parts.push(this.fileSizeLabel(file.size));
    return parts.length > 0 ? parts.join(' · ') : '文件';
  }

  private fileSizeLabel(bytes: number): string {
    if (bytes < 1024) return `${Math.round(bytes)} B`;
    if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }

  private async openMessageFile(file: RemoteSerializedAttachment): Promise<void> {
    const raw = file.url.length > 0 ? file.url : file.path;
    const url = await this.resolveDownloadableUrl(raw, file.mimeType, false);
    if (url.length === 0) {
      promptAction.showToast({ message: '暂时无法预览这个文件' });
      return;
    }
    this.openUrl(url);
  }

  private async openToolMedia(payload: RenderMediaPayload): Promise<void> {
    const url = await this.resolveDownloadableUrl(payload.url, payload.mimeType, true);
    if (url.length === 0) {
      promptAction.showToast({ message: '媒体暂时不可用，请稍后重试' });
      return;
    }
    this.openUrl(url);
  }

  private async resolveDownloadableUrl(raw: string, mimeType: string, skipCache: boolean): Promise<string> {
    const url = normalizeImageUrlScheme(raw.trim());
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    const parsed = parseAttachmentOssRef(url);
    if (parsed !== null) {
      try {
        return await this.resolveOssUrl(parsed.ossKey);
      } catch (e) {
        return '';
      }
    }
    if (!/^(?:xdt-image|xdt-video|xdt-audio|cindy-media|xdt-file):\/\//i.test(url)) return '';
    try {
      const fetched = await AppServices.instance.messages.fetchRemoteMedia(
        this.deviceId, url, false, skipCache);
      if (fetched.ossKey.length > 0) return await this.resolveOssUrl(fetched.ossKey);
      if (fetched.inlineBase64.length > 0 && mimeType.toLowerCase().startsWith('image/')) {
        const resolvedMime = mimeType.length > 0 ? mimeType : fetched.mimeType;
        return `data:${resolvedMime};base64,${fetched.inlineBase64}`;
      }
      return '';
    } catch (e) {
      return '';
    }
  }

  private messageVerticalPadding(item: RenderMessageItem): number {
    if (item.kind !== 'user') return 4;
    return item.body.length > 140 || item.body.includes('\n') ? 12 : 8;
  }

  private hasMessageActions(item: RenderMessageItem): boolean {
    return item.kind === 'user'
      || (item.kind === 'assistant' && item.isTurnFinalAssistant);
  }

  private collapsedMessageLines(item: RenderMessageItem): number {
    return collapsedUserMessageLineLimit(
      item.message !== undefined && item.message.automationOrigin,
    );
  }

  private plainMessageExpandKey(item: RenderMessageItem): string {
    return `plain-${item.key}`;
  }

  /**
   * ArkUI 当前没有把 Markdown 子树的真实行数回传给父层；按字符显示宽度做与
   * Mobile 首轮粗筛同用途的保守估算。CJK 计一格，ASCII 计半格，约 21 格/行。
   */
  private estimatedUserMessageLines(text: string): number {
    const rows = text.replace(/\r\n/g, '\n').split('\n');
    let total = 0;
    for (let rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      const row = rows[rowIndex];
      let units = 0;
      for (let i = 0; i < row.length; i++) {
        units += row.charCodeAt(i) > 255 ? 1 : 0.5;
      }
      total += Math.max(1, Math.ceil(units / 21));
    }
    return total;
  }

  /** 结构化粘贴段继续走 chip；这里补普通 user 长消息的整条收起。 */
  private shouldCollapsePlainUserMessage(item: RenderMessageItem): boolean {
    if (item.kind !== 'user' || item.body.trim().length === 0) return false;
    for (let i = 0; i < item.segments.length; i++) {
      if (item.segments[i].isPasted) return false;
    }
    const automation = item.message !== undefined && item.message.automationOrigin;
    return this.estimatedUserMessageLines(item.body) > (automation ? 4 : 14);
  }

  @Builder
  collapsedPlainUserMessage(item: RenderMessageItem) {
    Text(item.body)
      .fontSize(uiFontSize(17))
      .lineHeight(uiLineHeight(26))
      .maxLines(this.collapsedMessageLines(item))
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .width('100%')
    Text('展开全文')
      .fontSize(uiFontSize(12))
      .lineHeight(uiLineHeight(18))
      .fontColor($r('app.color.accent'))
      .padding({ top: 4, bottom: 4 })
      .clickEffect(UI_CLICK_EFFECT)
      .onClick(() => {
        this.toggleTextBlock(this.plainMessageExpandKey(item));
      })
  }

  @Builder
  messageActionButton(symbol: Resource, action: () => void) {
    Button() {
      SymbolGlyph(symbol)
        .fontSize(uiFontSize(14))
        .fontColor([$r('app.color.chat_text_secondary')])
    }
    .type(ButtonType.Circle)
    .width(32)
    .height(32)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .clickEffect(UI_ICON_CLICK_EFFECT)
    .onClick(action)
  }

  @Builder
  messageBlock(item: RenderMessageItem) {
    Column({ space: 2 }) {
      if (item.kind === 'user'
        && item.message !== undefined
        && item.message.automationOrigin) {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.timer'))
            .fontSize(uiFontSize(12))
            .fontColor([$r('app.color.text_tertiary')])
          Text('由自动化发送')
            .fontSize(uiFontSize(12))
            .lineHeight(uiLineHeight(16))
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('86%')
        .justifyContent(FlexAlign.End)
        .alignSelf(ItemAlign.End)
      }

      // iOS 把附件放在文字气泡外；纯附件消息不会留下空白气泡。
      if (item.images.length > 0) {
        List({ space: 6 }) {
          ForEach(item.images, (ref: RemoteImageRef) => {
            ListItem() {
              this.imageThumb(ref)
            }
          }, (ref: RemoteImageRef) => ref.url)
        }
        .listDirection(Axis.Horizontal)
        .height(88)
        .width(item.kind === 'user' ? '86%' : '100%')
        .alignSelf(item.kind === 'user' ? ItemAlign.End : ItemAlign.Start)
      }

      if (item.files.length > 0) {
        List({ space: 6 }) {
          ForEach(item.files, (file: RemoteSerializedAttachment) => {
            ListItem() {
              this.messageFileChip(file)
            }
          }, (file: RemoteSerializedAttachment) => `${item.key}-${file.path}-${file.name}`)
        }
        .listDirection(Axis.Horizontal)
        .height(58)
        .width(item.kind === 'user' ? '86%' : '100%')
        .alignSelf(item.kind === 'user' ? ItemAlign.End : ItemAlign.Start)
      }

      if (this.hasVisibleMessageBody(item)) {
        Column({ space: 4 }) {
          // 普通 user/assistant 没有身份前缀；系统卡保留必要元信息。
          if (item.kind !== 'user' && item.kind !== 'assistant') {
            Row({ space: 8 }) {
              Text(item.label)
                .fontSize(uiFontSize(11))
                .fontColor(this.labelColor(item.kind))
              Text(this.timeLabel(item.message !== undefined ? item.message.createdAt : ''))
                .fontSize(uiFontSize(11))
                .fontColor($r('app.color.text_tertiary'))
            }
            .width('100%')
          }

          if (this.shouldCollapsePlainUserMessage(item)
            && !this.isIn(this.expandedTextBlocks, this.plainMessageExpandKey(item))) {
            this.collapsedPlainUserMessage(item)
          } else if (item.kind === 'user' && item.segments.length > 1) {
            ForEach(item.segments, (seg: RenderTextSegment) => {
              if (seg.isPasted) {
                this.pastedChip(item, seg)
              } else if (seg.mdBlocks.length > 0) {
                this.mdBlocks(seg.mdBlocks)
              }
            }, (seg: RenderTextSegment) => `${item.key}-${seg.seq}`)
          } else if (item.kind === 'user' && item.segments.length > 0 && item.segments[0].isPasted) {
            this.pastedBlock(item, item.segments[0])
          } else if (item.mdBlocks.length > 0) {
            this.mdBlocks(item.mdBlocks)
          }

          if (this.shouldCollapsePlainUserMessage(item)
            && this.isIn(this.expandedTextBlocks, this.plainMessageExpandKey(item))) {
            Text('收起')
              .fontSize(uiFontSize(12))
              .lineHeight(uiLineHeight(18))
              .fontColor($r('app.color.accent'))
              .padding({ top: 4, bottom: 4 })
              .clickEffect(UI_CLICK_EFFECT)
              .onClick(() => {
                this.toggleTextBlock(this.plainMessageExpandKey(item));
              })
          }

          if (item.kind === 'assistant'
            && item.message !== undefined
            && item.message.isStreaming) {
            Text('生成中')
              .fontSize(uiFontSize(12))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.chat_text_secondary'))
              .opacity(0.72)
          }
        }
        .constraintSize({ maxWidth: item.kind === 'user' ? '86%' : '100%' })
        .alignItems(HorizontalAlign.Start)
        .alignSelf(item.kind === 'user' ? ItemAlign.End : ItemAlign.Start)
        .backgroundColor(item.kind === 'user' ? $r('app.color.bg_card') : Color.Transparent)
        .borderRadius(item.kind === 'user' ? UI_RADIUS_CONTAINER : 0)
        .border({
          width: item.kind === 'user' ? 1 : 0,
          color: $r('app.color.chat_bubble_border'),
        })
        .padding({
          left: item.kind === 'user' ? 12 : 0,
          right: item.kind === 'user' ? 12 : 0,
          top: this.messageVerticalPadding(item),
          bottom: this.messageVerticalPadding(item),
        })
      }

      // iOS 操作栏顺序：user 为时间→复制→分叉→更多，assistant 为复制→分叉→更多→时间→用量。
      if (this.hasMessageActions(item)) {
        Row({ space: 2 }) {
          if (item.kind === 'user') {
            Text(this.timeLabel(item.message !== undefined ? item.message.createdAt : ''))
              .fontSize(uiFontSize(12))
              .lineHeight(uiLineHeight(24))
              .fontColor($r('app.color.chat_text_secondary'))
              .margin({ right: 2 })
          }
          this.messageActionButton($r('sys.symbol.rectangle_on_rectangle'), () => this.copyMessage(item))
          if (this.canFork(item)) {
            this.messageActionButton($r('sys.symbol.split'), () => this.confirmFork(item))
          }
          this.messageActionButton($r('sys.symbol.ellipsis_circle'), () => this.showMessageActions(item))
          if (item.kind === 'assistant') {
            Text(this.timeLabel(item.message !== undefined ? item.message.createdAt : ''))
              .fontSize(uiFontSize(12))
              .lineHeight(uiLineHeight(24))
              .fontColor($r('app.color.chat_text_secondary'))
              .margin({ left: 2 })
            if (this.turnTokensLabel(item).length > 0) {
              Text(this.turnTokensLabel(item))
                .fontSize(uiFontSize(12))
                .lineHeight(uiLineHeight(24))
                .fontColor($r('app.color.chat_text_secondary'))
            }
          }
        }
        .height(32)
        .alignSelf(item.kind === 'user' ? ItemAlign.End : ItemAlign.Start)
      }
    }
    .width('100%')
    .alignItems(item.kind === 'user' ? HorizontalAlign.End : HorizontalAlign.Start)
  }

  @Builder
  messageFileChip(file: RemoteSerializedAttachment) {
    Row({ space: 8 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.doc_text'))
          .fontSize(uiFontSize(16))
          .fontColor([$r('app.color.text_secondary')])
      }
      .width(32)
      .height(32)
      .backgroundColor($r('app.color.bg_chip'))
      .borderRadius(UI_RADIUS_CONTROL)
      Column({ space: 1 }) {
        Text(this.attachmentTitle(file))
          .fontSize(uiFontSize(13))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.attachmentMeta(file))
          .fontSize(uiFontSize(11))
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      this.disclosureChevron(false, $r('app.color.text_tertiary'))
    }
    .width(230)
    .height(56)
    .padding({ left: 8, right: 8 })
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.border') })
    .borderRadius(UI_RADIUS_CONTAINER)
    .clickEffect(UI_LIST_CLICK_EFFECT)
    .onClick(() => void this.openMessageFile(file))
  }

  /** 粘贴段 chip：文件图标 + display 摘要，点击展开全文（对齐 iOS InlineReferenceChip）。 */
  @Builder
  pastedChip(item: RenderMessageItem, seg: RenderTextSegment) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text('▤')
          .fontSize(uiFontSize(14))
          .fontColor($r('app.color.text_tertiary'))
        Text(seg.display.length > 0 ? seg.display : `已粘贴文本（${seg.text.length} 字）`)
          .fontSize(uiFontSize(13))
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        this.disclosureChevron(
          this.isIn(this.expandedTextBlocks, `${item.key}-${seg.seq}`),
          $r('app.color.text_tertiary'),
        )
      }
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .backgroundColor($r('app.color.bg_chip'))
      .borderRadius(UI_RADIUS_CONTROL)
      .width('100%')
      .clickEffect(UI_LIST_CLICK_EFFECT)
      .onClick(() => {
        this.toggleTextBlock(`${item.key}-${seg.seq}`);
      })

      if (this.isIn(this.expandedTextBlocks, `${item.key}-${seg.seq}`)) {
        this.mdBlocks(seg.mdBlocks)
        Text('收起')
          .fontSize(uiFontSize(12))
          .fontColor($r('app.color.accent'))
          .padding({ top: 4, bottom: 4 })
          .clickEffect(UI_CLICK_EFFECT)
          .onClick(() => {
            this.toggleTextBlock(`${item.key}-${seg.seq}`);
          })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  pastedBlock(item: RenderMessageItem, seg: RenderTextSegment) {
    Column({ space: 4 }) {
      if (this.isIn(this.expandedTextBlocks, `${item.key}-${seg.seq}`)) {
        this.mdBlocks(seg.mdBlocks)
        Text('收起')
          .fontSize(uiFontSize(12))
          .fontColor($r('app.color.accent'))
          .padding({ top: 4, bottom: 4 })
          .clickEffect(UI_CLICK_EFFECT)
          .onClick(() => {
            this.toggleTextBlock(`${item.key}-${seg.seq}`);
          })
      } else {
        // 自动化消息使用更紧的 4/3 行策略；手打消息保持 14/10。
        Text(seg.text)
          .fontSize(uiFontSize(17))
          .lineHeight(uiLineHeight(26))
          .maxLines(this.collapsedMessageLines(item))
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .clickEffect(UI_LIST_CLICK_EFFECT)
          .onClick(() => {
            this.toggleTextBlock(`${item.key}-${seg.seq}`);
          })
        Text('展开全文')
          .fontSize(uiFontSize(12))
          .fontColor($r('app.color.accent'))
          .padding({ top: 4, bottom: 4 })
          .clickEffect(UI_CLICK_EFFECT)
          .onClick(() => {
            this.toggleTextBlock(`${item.key}-${seg.seq}`);
          })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  thinkingBlock(item: RenderThinkingItem) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        this.disclosureChevron(
          this.isIn(this.expandedThinking, item.key),
          $r('app.color.chat_text_secondary'),
        )
        Text(this.thinkingTitle(item))
          .fontSize(uiFontSize(14))
          .lineHeight(uiLineHeight(20))
          .fontColor($r('app.color.chat_text_secondary'))
      }
      .width('100%')
      .constraintSize({ minHeight: 32 })
      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
      .clickEffect(UI_LIST_CLICK_EFFECT)
      .onClick(() => {
        this.toggleThinkingBlock(item.key);
      })

      if (this.isIn(this.expandedThinking, item.key)) {
        if (item.redacted) {
          Text('思考内容已隐藏')
            .fontSize(uiFontSize(12))
            .fontStyle(FontStyle.Italic)
            .fontColor($r('app.color.text_secondary'))
        } else if (item.body.trim().length > 0) {
          // Thinking 正文使用 12/18 斜体小字和 2vp rail，不继承普通消息 17/26 档。
          Text(item.body)
            .fontSize(uiFontSize(12))
            .lineHeight(uiLineHeight(18))
            .fontStyle(FontStyle.Italic)
            .fontColor($r('app.color.chat_text_secondary'))
            .width('100%')
            .padding({ left: 12, top: 2, bottom: 2 })
            .border({ width: { left: 2 }, color: { left: $r('app.color.composer_border') } })
            .transition(uiRevealTransition())
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 2, bottom: 2 })
  }

  @Builder
  toolGroupBlock(item: RenderToolGroupItem) {
    Column({ space: 2 }) {
      // work_group 展开后只显示每个真实调用行；tool_group 自己再加“调用 bash”
      // 标题会与行标题叠加，历史数据里尤其容易形成重复的 Bash 行。
      ForEach(item.tools, (t: RenderToolItem) => {
        this.projectedToolRows(t)
      }, (t: RenderToolItem) => `${item.key}-${t.seq}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 4, bottom: 4 })
  }

  private toolKey(t: RenderToolItem): string {
    return t.toolUseId.length > 0 ? t.toolUseId : `${t.toolName}-${t.seq}`;
  }

  private toolActionKey(t: RenderToolItem, action: ToolActionPresentation): string {
    return `${this.toolKey(t)}:action:${action.actionIndex}`;
  }

  private toolHasDetails(t: RenderToolItem, action: ToolActionPresentation): boolean {
    return action.detail.length > 0 || (t.hasResult && t.resultText.length > 0) || t.diff !== null;
  }

  private diffLines(value: string, prefix: string): string {
    const lines = value.replace(/\r\n/g, '\n').split('\n');
    const out: string[] = [];
    const limit = Math.min(lines.length, 80);
    for (let i = 0; i < limit; i++) out.push(`${prefix}${lines[i]}`);
    if (lines.length > limit) out.push(`${prefix}…`);
    return out.join('\n');
  }

  @Builder
  projectedToolRows(t: RenderToolItem) {
    ForEach(projectToolUseActions(t.toolName, t.inputRaw, t.inputText),
      (action: ToolActionPresentation) => {
        this.toolRow(t, action)
      },
      (action: ToolActionPresentation) => this.toolActionKey(t, action))
  }

  @Builder
  toolRow(t: RenderToolItem, action: ToolActionPresentation) {
    Column({ space: 2 }) {
      Row({ space: 6 }) {
        if (t.hasError) {
          SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
            .fontSize(uiFontSize(15))
            .fontColor([$r('app.color.danger')])
            .width(16)
        } else if (t.hasResult) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(uiFontSize(14))
            .fontColor([$r('app.color.text_tertiary')])
            .width(16)
        } else {
          LoadingProgress()
            .width(14)
            .height(14)
            .color($r('app.color.text_tertiary'))
            .margin({ left: 1, right: 1 })
        }
        Text(action.label)
          .fontSize(uiFontSize(14))
          .lineHeight(uiLineHeight(20))
          .fontColor($r('app.color.chat_text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.toolHasDetails(t, action)) {
          this.disclosureChevron(
            this.isIn(this.expandedTools, this.toolActionKey(t, action)),
            $r('app.color.text_tertiary'),
          )
        }
      }
      .width('100%')
      .constraintSize({ minHeight: 28 })
      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
      .clickEffect(this.toolHasDetails(t, action) ? UI_LIST_CLICK_EFFECT : undefined)
      .onClick(() => {
        if (this.toolHasDetails(t, action)) {
          this.toggleToolDetails(this.toolActionKey(t, action));
        }
      })

      if (this.toolHasDetails(t, action)
        && this.isIn(this.expandedTools, this.toolActionKey(t, action))) {
        Column({ space: 4 }) {
          if (action.detail.length > 0) {
            Text(action.detail)
              .fontSize(uiFontSize(12))
              .fontFamily('monospace')
              .fontColor($r('app.color.chat_text_secondary'))
              .lineHeight(uiLineHeight(18))
              .width('100%')
          }
          if (t.hasResult && t.resultText.length > 0) {
            Text(t.resultText)
              .fontSize(uiFontSize(12))
              .fontFamily('monospace')
              .fontColor($r('app.color.chat_text_secondary'))
              .lineHeight(uiLineHeight(18))
              .width('100%')
          }
          if (t.diff !== null) {
            this.diffCard(t.diff as RenderDiffPayload)
          }
        }
        .width('100%')
        .padding(8)
        .margin({ left: 8, right: 8, bottom: 4 })
        .backgroundColor($r('app.color.bg_code'))
        .border({ width: 1, color: $r('app.color.composer_border') })
        .borderRadius(UI_RADIUS_CONTAINER)
        .transition(uiRevealTransition())
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  diffCard(diff: RenderDiffPayload) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.doc_text'))
          .fontSize(uiFontSize(14))
          .fontColor([$r('app.color.text_secondary')])
        Text(diff.filePath)
          .fontSize(uiFontSize(12))
          .fontFamily('monospace')
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(`+${diff.insertions}`)
          .fontSize(uiFontSize(11))
          .fontColor($r('app.color.success'))
        Text(`−${diff.deletions}`)
          .fontSize(uiFontSize(11))
          .fontColor($r('app.color.danger'))
      }
      .width('100%')
      ForEach(diff.segments, (segment: RenderDiffSegment) => {
        if (segment.label.length > 0) {
          Text(segment.label)
            .fontSize(uiFontSize(11))
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }
        if (segment.oldString.length > 0) {
          Text(this.diffLines(segment.oldString, '− '))
            .fontSize(uiFontSize(11))
            .fontFamily('monospace')
            .fontColor($r('app.color.danger'))
            .lineHeight(uiLineHeight(17))
            .maxLines(12)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .padding(6)
            .backgroundColor($r('app.color.bg_chip'))
            .borderRadius(UI_RADIUS_CONTROL)
        }
        if (segment.newString.length > 0) {
          Text(this.diffLines(segment.newString, '+ '))
            .fontSize(uiFontSize(11))
            .fontFamily('monospace')
            .fontColor($r('app.color.success'))
            .lineHeight(uiLineHeight(17))
            .maxLines(12)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .padding(6)
            .backgroundColor($r('app.color.bg_chip'))
            .borderRadius(UI_RADIUS_CONTROL)
        }
      }, (segment: RenderDiffSegment) => segment.key)
    }
    .width('100%')
    .padding(8)
    .backgroundColor($r('app.color.bg_page'))
    .border({ width: 1, color: $r('app.color.border') })
    .borderRadius(UI_RADIUS_CONTAINER)
  }

  @Builder
  todoBlock(item: RenderTodoCardItem) {
    Column() {
      Row({ space: 8 }) {
        this.disclosureChevron(
          this.todoCardExpanded(item.key), $r('app.color.text_tertiary'))
        SymbolGlyph($r('sys.symbol.list_bullet'))
          .fontSize(uiFontSize(16))
          .fontColor([$r('app.color.text_secondary')])
          .width(18)
        Text(this.todoTitle(item))
          .fontSize(uiFontSize(14))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .constraintSize({ minHeight: this.todoCardCompact(item) ? 42 : 46 })
      .padding({ left: 10, right: 10 })
      .clickEffect(UI_LIST_CLICK_EFFECT)
      .onClick(() => this.toggleTodoCard(item.key))

      if (this.todoCardExpanded(item.key)) {
        Column() {
          ForEach(item.todos, (t: RenderTodoItem) => {
            Row({ space: 10 }) {
              this.todoStatusIcon(t.status, item.isStreaming)
              Text(t.content)
                .fontSize(uiFontSize(14))
                .lineHeight(uiLineHeight(20))
                .fontColor(t.status === 'pending'
                  ? $r('app.color.text_tertiary') : $r('app.color.text_primary'))
                .opacity(t.status === 'completed' ? 0.72 : 1)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%')
            .constraintSize({ minHeight: this.todoCardCompact(item) ? 38 : 42 })
            .padding({ left: 12, right: 12, top: 4, bottom: 4 })
            .alignItems(VerticalAlign.Center)
          }, (t: RenderTodoItem) => `${item.key}-${t.seq}`)
        }
        .width('100%')
        .padding({ bottom: 6 })
        .border({ width: { top: 1 }, color: { top: $r('app.color.border') } })
        .transition(uiRevealTransition())
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(UI_RADIUS_CONTAINER)
    .border({ width: 1, color: $r('app.color.border') })
    .margin({ top: 4, bottom: 4 })
  }

  private todoCardCompact(item: RenderTodoCardItem): boolean {
    return (this.messageAreaWidth > 0 && this.messageAreaWidth <= 360)
      || item.todos.length > 3;
  }

  @Builder
  todoStatusIcon(status: string, streaming: boolean) {
    Stack({ alignContent: Alignment.Center }) {
      if (status === 'completed') {
        Circle()
          .width(TODO_STATUS_ICON_SIZE)
          .height(TODO_STATUS_ICON_SIZE)
          .fill($r('app.color.text_primary'))
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(uiFontSize(TODO_STATUS_CHECKMARK_SIZE))
          .fontColor([$r('app.color.bg_card')])
      } else if (status === 'in_progress' && streaming) {
        TodoRunningStatusIcon()
      } else if (status === 'in_progress') {
        Circle()
          .width(TODO_STATUS_ICON_SIZE)
          .height(TODO_STATUS_ICON_SIZE)
          .fill(Color.Transparent)
          .stroke($r('app.color.text_secondary'))
          .strokeWidth(TODO_STATUS_STROKE_WIDTH)
        Circle()
          .width(TODO_STATUS_ACTIVE_DOT_SIZE)
          .height(TODO_STATUS_ACTIVE_DOT_SIZE)
          .fill($r('app.color.text_secondary'))
      } else {
        Circle()
          .width(TODO_STATUS_ICON_SIZE)
          .height(TODO_STATUS_ICON_SIZE)
          .fill(Color.Transparent)
          .stroke($r('app.color.text_tertiary'))
          .strokeWidth(TODO_STATUS_STROKE_WIDTH)
      }
    }
    .width(20)
    .height(20)
  }

  // ─── Markdown 渲染 ──────────────────────────────────────────────────────────

  private hasImageToken(tokens: InlineToken[]): boolean {
    for (let i = 0; i < tokens.length; i++) {
      if (tokens[i].kind === 'image') return true;
    }
    return false;
  }

  private markdownImageWidth(token: InlineToken): number {
    return Math.min(token.width > 0 ? token.width : 220, 260);
  }

  private markdownImageHeight(token: InlineToken): number {
    const width = this.markdownImageWidth(token);
    if (token.width > 0 && token.height > 0) {
      return Math.min(260, Math.max(1, Math.round(width * token.height / token.width)));
    }
    return token.height > 0 ? Math.min(token.height, 260) : Math.round(width * 0.75);
  }

  @Builder
  mdInlineContent(
    tokens: InlineToken[], fontSize: number, lineHeight: number,
    heading: boolean, secondary: boolean,
  ) {
    Column({ space: 4 }) {
      ForEach(groupInlineTokens(tokens), (group: InlineTokenGroup) => {
        if (group.image !== null) {
          this.mdInlineImage(group.image)
        } else {
          this.inlineTokensText(group.tokens, fontSize, lineHeight, heading, secondary)
        }
      }, (group: InlineTokenGroup) => `${group.key}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  mdInlineImage(token: InlineToken) {
    if ((this.imageSources.get(token.url) ?? '').length > 0) {
      Image(this.imageSources.get(token.url) ?? '')
        .width(this.markdownImageWidth(token))
        .height(this.markdownImageHeight(token))
        .objectFit(ImageFit.Contain)
        .borderRadius(UI_RADIUS_CONTROL)
        .clickEffect(UI_CLICK_EFFECT)
        .onClick(() => this.openInlineImagePreview(token.url))
        .onError(() => this.handleNativeImageError(token.url, this.markdownImageRef(token)))
    } else if (this.imageStatus(token.url) === 'error') {
      this.mediaErrorFrame(this.markdownImageWidth(token), this.markdownImageHeight(token),
        () => this.retryImage(token.url, this.markdownImageRef(token)))
    } else {
      Row({ space: 6 }) {
        LoadingProgress()
          .width(14)
          .height(14)
        Text(token.value.length > 0 ? token.value : '图片')
          .fontSize(uiFontSize(12))
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width(this.markdownImageWidth(token))
      .height(32)
      .padding({ left: 8, right: 8 })
      .backgroundColor($r('app.color.bg_chip'))
      .borderRadius(UI_RADIUS_CONTROL)
    }
  }

  @Builder
  mdBlocks(blocks: MdBlock[]) {
    ForEach(blocks, (b: MdBlock) => {
      this.mdBlock(b)
    }, (b: MdBlock) => `${b.type}-${b.seq}`)
  }

  @Builder
  mdBlock(b: MdBlock) {
    if (b.type === 'heading') {
      this.mdInlineContent(
        b.inlineTokens,
        b.level <= 1 ? 20 : (b.level === 2 ? 18 : 17),
        b.level <= 2 ? 28 : 26,
        true,
        false,
      )
    } else if (b.type === 'paragraph') {
      if (this.hasImageToken(b.inlineTokens)) {
        this.mdInlineContent(b.inlineTokens, 17, 26, false, false)
      } else {
        this.inlineText(b.text)
      }
    } else if (b.type === 'list') {
      Column({ space: 2 }) {
        ForEach(b.items, (it: string, idx?: number) => {
          Row({ space: 6 }) {
            this.markdownListMarker(b, idx ?? 0)
            if (this.hasImageToken(b.itemTokens[idx ?? 0] ?? [])) {
              this.mdInlineContent(b.itemTokens[idx ?? 0] ?? [], 17, 26, false, false)
            } else {
              this.inlineText(it)
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }, (it: string, idx?: number) => `${b.seq}:${idx ?? 0}:${it}`)
      }
      .padding({ top: 2, bottom: 2 })
    } else if (b.type === 'quote') {
      if (this.hasImageToken(b.inlineTokens)) {
        Row() {
          this.mdInlineContent(b.inlineTokens, 14, 22, false, true)
        }
        .width('100%')
        .padding({ left: 10 })
        .border({ width: { left: 3 }, color: { left: $r('app.color.border') } })
      } else {
        Row() {
          this.inlineTokensText(b.inlineTokens, 14, 22, false, true)
        }
          .padding({ left: 10 })
          .border({ width: { left: 3 }, color: { left: $r('app.color.border') } })
          .width('100%')
      }
    } else if (b.type === 'math') {
      this.richSourceBlock('公式', b.code, 'math')
    } else if (b.type === 'code'
      && (b.lang.toLowerCase() === 'mermaid' || b.lang.toLowerCase() === 'math'
        || b.lang.toLowerCase() === 'latex' || b.lang.toLowerCase() === 'tex'
        || b.lang.toLowerCase() === 'html' || b.lang.toLowerCase() === 'diff')) {
      this.richSourceBlock(
        b.lang.toLowerCase() === 'mermaid' ? 'Mermaid 图表'
          : (b.lang.toLowerCase() === 'html' ? 'HTML 预览'
            : (b.lang.toLowerCase() === 'diff' ? '变更内容' : '公式')),
        b.code,
        b.lang.toLowerCase(),
      )
    } else if (b.type === 'code') {
      Column({ space: 4 }) {
        Text(b.code)
          .fontSize(uiFontSize(12))
          .fontFamily('monospace')
          .fontColor($r('app.color.code_text'))
          .lineHeight(uiLineHeight(18))
          .padding(10)
          .backgroundColor($r('app.color.bg_code'))
          .border({ width: 1, color: $r('app.color.border') })
          .borderRadius(UI_RADIUS_CONTAINER)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .width('100%')
      .padding({ top: 2, bottom: 2 })
    } else if (b.type === 'table') {
      this.tableBlock(b)
    } else if (b.type === 'divider') {
      Divider()
        .color($r('app.color.border'))
        .margin({ top: 6, bottom: 6 })
    }
  }

  @Builder
  markdownListMarker(b: MdBlock, index: number) {
    if ((b.itemChecked[index] ?? -1) >= 0) {
      Row() {
        if ((b.itemChecked[index] ?? 0) === 1) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(uiFontSize(11))
            .fontColor([$r('app.color.accent')])
        }
      }
      .width(17)
      .height(17)
      .justifyContent(FlexAlign.Center)
      .border({ width: 1, color: (b.itemChecked[index] ?? 0) === 1
        ? $r('app.color.accent') : $r('app.color.border') })
      .borderRadius(4)
      .margin({ top: 4 })
    } else {
      Text(b.itemOrdered[index] === true
        ? (b.itemMarkers[index] ?? `${index + 1}.`) : '•')
        .fontSize(uiFontSize(17))
        .fontColor($r('app.color.text_secondary'))
    }
  }

  @Builder
  richSourceBlock(title: string, source: string, kind: string) {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.doc_text'))
          .fontSize(uiFontSize(13)).fontColor([$r('app.color.text_secondary')])
        Text(title).fontSize(uiFontSize(12)).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary')).layoutWeight(1)
        Text(kind === 'html' ? '静态安全模式' : '源码')
          .fontSize(uiFontSize(10)).fontColor($r('app.color.text_tertiary'))
      }.width('100%')
      Text(source)
        .fontSize(uiFontSize(kind === 'math' || kind === 'latex' || kind === 'tex' ? 14 : 12))
        .fontFamily(kind === 'math' || kind === 'latex' || kind === 'tex' ? 'serif' : 'monospace')
        .fontColor($r('app.color.code_text')).lineHeight(uiLineHeight(19))
        .maxLines(24).textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%').padding(10).backgroundColor($r('app.color.bg_code'))
        .borderRadius(UI_RADIUS_CONTROL)
    }
    .width('100%').padding(10).backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.border') }).borderRadius(UI_RADIUS_CONTAINER)
  }

  private tableHeaderTokens(b: MdBlock, index: number): InlineToken[] {
    return b.headerTokens[index] ?? [];
  }

  private tableRowCellTokens(b: MdBlock, rowIndex: number, cellIndex: number): InlineToken[] {
    const row = b.rowTokens[rowIndex];
    return row === undefined ? [] : (row[cellIndex] ?? []);
  }

  private tableColumnWidths(b: MdBlock): number[] {
    const cached = this.tableColumnWidthCache.get(b);
    if (cached !== undefined) return cached;
    const compact = this.messageAreaWidth > 0 && this.messageAreaWidth <= 360;
    const available = this.messageAreaWidth > 0
      ? Math.max(280, this.messageAreaWidth - (compact ? 48 : 64)) : 0;
    const widths = buildMarkdownTableColumnWidths(
      b.headerTokens, b.rowTokens, compact ? 96 : 112, 220, available);
    this.tableColumnWidthCache.set(b, widths);
    return widths;
  }

  private tableColumnIndexes(b: MdBlock): number[] {
    const count = this.tableColumnWidths(b).length;
    const out: number[] = [];
    for (let i = 0; i < count; i++) out.push(i);
    return out;
  }

  private tableContentWidth(b: MdBlock): number {
    const widths = this.tableColumnWidths(b);
    let total = 0;
    for (let i = 0; i < widths.length; i++) total += widths[i];
    return total;
  }

  @Builder
  tableBlock(b: MdBlock) {
    Scroll() {
      Column() {
        Row() {
          ForEach(this.tableColumnIndexes(b), (hIndex: number) => {
            Row() {
              if (this.hasImageToken(this.tableHeaderTokens(b, hIndex))) {
                this.mdInlineContent(this.tableHeaderTokens(b, hIndex), 17, 26, false, false)
              } else {
                this.inlineText(b.headers[hIndex] ?? '')
              }
            }
            .width(this.tableColumnWidths(b)[hIndex])
            .padding({ left: 10, right: 10, top: 7, bottom: 7 })
            .backgroundColor($r('app.color.bg_chip'))
            .border({ width: { right: 1, bottom: 1 }, color: $r('app.color.border') })
          }, (hIndex: number) => `${b.seq}-h-${hIndex}`)
        }
        .width(this.tableContentWidth(b))

        ForEach(b.rows, (row: string[], rowIndex?: number) => {
          Row() {
            ForEach(this.tableColumnIndexes(b), (cellIndex: number) => {
              Row() {
                if (this.hasImageToken(this.tableRowCellTokens(b, rowIndex ?? 0, cellIndex))) {
                  this.mdInlineContent(
                    this.tableRowCellTokens(b, rowIndex ?? 0, cellIndex), 17, 26, false, false)
                } else {
                  this.inlineText(row[cellIndex] ?? '')
                }
              }
              .width(this.tableColumnWidths(b)[cellIndex])
              .padding({ left: 10, right: 10, top: 7, bottom: 7 })
              .border({ width: { right: 1, bottom: 1 }, color: $r('app.color.border') })
            }, (cellIndex: number) => `${b.seq}-${rowIndex ?? 0}-${cellIndex}`)
          }
          .width(this.tableContentWidth(b))
        }, (row: string[], rowIndex?: number) => `${b.seq}-r-${rowIndex ?? 0}`)
      }
      .width(this.tableContentWidth(b))
      .border({ width: { left: 1, top: 1 }, color: $r('app.color.border') })
    }
    .width('100%')
    .scrollable(ScrollDirection.Horizontal)
  }

  @Builder
  inlineText(text: string) {
    this.inlineTokensText(tokenizeInline(text), 17, 26, false, false)
  }

  @Builder
  inlineTokensText(
    tokens: InlineToken[], fontSize: number, lineHeight: number,
    heading: boolean, secondary: boolean,
  ) {
    Text() {
      ForEach(tokens, (t: InlineToken) => {
        if (t.kind === 'code') {
          Span(t.value)
            .fontFamily('monospace')
            .fontColor($r('app.color.code_text'))
            .textBackgroundStyle({ color: $r('app.color.bg_chip') })
        } else if (t.kind === 'strong') {
          Span(t.value)
            .fontWeight(FontWeight.Bold)
        } else if (t.kind === 'emphasis') {
          Span(t.value)
            .fontStyle(FontStyle.Italic)
        } else if (t.kind === 'strikethrough') {
          Span(t.value)
            .decoration({ type: TextDecorationType.LineThrough })
        } else if (t.kind === 'math') {
          Span(t.value)
            .fontFamily('serif')
            .fontStyle(FontStyle.Italic)
            .fontColor($r('app.color.code_text'))
        } else if (t.kind === 'link' && this.isLocalReference(t.url)) {
          // Desktop 将文件路径、代码文件名等本地引用显示为中性的 code chip，
          // 只有真正的外部链接使用 accent；这样不会把 .ets / HAP 误染成蓝色。
          Span(t.value)
            .fontFamily('monospace')
            .fontColor($r('app.color.code_text'))
            .textBackgroundStyle({ color: $r('app.color.bg_chip') })
            .decoration({ type: TextDecorationType.Underline })
            .onClick(() => this.openUrl(t.url))
        } else if (t.kind === 'link') {
          Span(t.value)
            .fontColor($r('app.color.text_primary'))
            .decoration({ type: TextDecorationType.Underline })
            .onClick(() => this.openUrl(t.url))
        } else {
          Span(t.value)
        }
      }, (t: InlineToken) => `${t.seq}`)
    }
    .fontSize(uiFontSize(fontSize))
    .lineHeight(uiLineHeight(lineHeight))
    .fontWeight(heading ? FontWeight.Medium : FontWeight.Regular)
    .fontColor(secondary ? $r('app.color.text_secondary') : $r('app.color.text_primary'))
    .textAlign(TextAlign.Start)
    .width('100%')
  }

  // ─── 样式/工具 ──────────────────────────────────────────────────────────────

  private isLocalReference(url: string): boolean {
    const lower = url.toLowerCase();
    return !lower.startsWith('http://')
      && !lower.startsWith('https://')
      && !lower.startsWith('mailto:')
      && !lower.startsWith('#');
  }

  private labelColor(kind: string): Resource {
    switch (kind) {
      case 'error':
        return $r('app.color.danger');
      case 'agent_switch':
        return $r('app.color.accent');
      case 'user':
        return $r('app.color.text_secondary');
      default:
        return $r('app.color.text_secondary');
    }
  }

  private pad2(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }

  /** 与 Mobile messageActions 同口径：一分钟内、分钟、小时，再回退日期时间。 */
  private timeLabel(iso: string): string {
    const timestamp = new Date(iso).getTime();
    if (!Number.isFinite(timestamp)) return '';
    const now = Date.now();
    const diff = Math.max(0, now - timestamp);
    if (diff < 60000) return '刚刚';
    if (diff < 3600000) return `${Math.floor(diff / 60000)} 分钟前`;
    if (diff < 86400000) return `${Math.floor(diff / 3600000)} 小时前`;
    const date = new Date(timestamp);
    const current = new Date(now);
    const prefix = date.getFullYear() === current.getFullYear()
      ? `${this.pad2(date.getMonth() + 1)}-${this.pad2(date.getDate())}`
      : `${date.getFullYear()}-${this.pad2(date.getMonth() + 1)}-${this.pad2(date.getDate())}`;
    return `${prefix} ${this.pad2(date.getHours())}:${this.pad2(date.getMinutes())}`;
  }

  private turnTokensLabel(item: RenderMessageItem): string {
    if (item.kind !== 'assistant' || item.message === undefined) return '';
    const usage = readObj(item.message.agentMeta, 'turnUsageDetails');
    const total = readNum(usage, 'totalTokens', 0);
    if (total <= 0) return '';
    if (total >= 1000000) {
      const value = total >= 10000000 ? (total / 1000000).toFixed(1) : (total / 1000000).toFixed(2);
      return `${value.endsWith('.0') ? value.slice(0, -2) : value}M tokens`;
    }
    if (total >= 1000) {
      const value = total >= 10000 ? (total / 1000).toFixed(1) : (total / 1000).toFixed(2);
      return `${value.endsWith('.0') ? value.slice(0, -2) : value}K tokens`;
    }
    return `${Math.floor(total)} tokens`;
  }

  private sessionTitle(): string {
    const s = this.session();
    if (s !== undefined && s.title.length > 0) {
      return s.title;
    }
    return '任务';
  }

  // ─── 消息动作（复制 / Fork / Rewind）───────────────────────────────────────

  /** Fork 条件（对齐 mobile）：assistant 消息，或非首条的 user 消息。 */
  private canFork(item: RenderMessageItem): boolean {
    if (item.kind === 'assistant') {
      return true;
    }
    return item.kind === 'user' && !this.isFirstUserMessage(item);
  }

  /** Rewind 条件（对齐 mobile）：仅 user 消息且非首条。 */
  private canRewind(item: RenderMessageItem): boolean {
    return item.kind === 'user' && !this.isFirstUserMessage(item);
  }

  /** 判断是否为消息流中的首条 user 消息。 */
  private isFirstUserMessage(item: RenderMessageItem): boolean {
    for (let i = 0; i < this.items.length; i++) {
      const it = this.items[i];
      if (it.type === 'message') {
        const m = it as RenderMessageItem;
        if (m.kind === 'user') {
          return m.key === item.key;
        }
      }
    }
    return false;
  }

  private copyPlainText(value: string, successMessage: string): void {
    if (value.length === 0) return;
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, value);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      promptAction.showToast({ message: successMessage });
    }).catch(() => {
      promptAction.showToast({ message: '复制失败' });
    });
  }

  private showProjectActions(): void {
    if (this.isCreationBlockingRemoteOps()) return;
    const workingDir = this.session()?.workingDir ?? '';
    if (workingDir.length === 0) return;
    this.getUIContext().showActionSheet({
      title: '项目文件',
      message: workingDir,
      sheets: [{
        title: '复制项目路径',
        action: () => this.copyPlainText(workingDir, '已复制项目路径'),
      }],
    });
  }

  private showSessionActions(): void {
    if (this.isCreationBlockingRemoteOps()) return;
    this.sessionRenameDraft = this.sessionTitle();
    this.sessionRenameMode = false;
    uiAnimateState(this.getUIContext(), () => {
      this.sessionActionOpen = true;
    });
  }

  private closeSessionActions(): void {
    if (this.sessionActionBusy) return;
    uiAnimateFastState(this.getUIContext(), () => {
      this.sessionActionOpen = false;
      this.sessionRenameMode = false;
    });
  }

  private openSessionTree(): void {
    if (this.isCreationBlockingRemoteOps()) return;
    this.sessionActionOpen = false;
    this.sessionTreeOpen = true;
    this.sessionTreeError = '';
    void this.loadSessionTree();
  }

  private closeSessionTree(): void {
    if (this.sessionTreeSwitchingId.length > 0) return;
    this.sessionTreeGeneration += 1;
    this.sessionTreeOpen = false;
  }

  private async loadSessionTree(): Promise<void> {
    if (this.isCreationBlockingRemoteOps()) return;
    const generation = ++this.sessionTreeGeneration;
    this.sessionTreeLoading = true;
    this.sessionTreeError = '';
    try {
      const result = await this.invokeContextRpc('maker:get-session-tree', [this.sessionId]);
      if (generation !== this.sessionTreeGeneration || !this.sessionTreeOpen) return;
      const tree = parsePiSessionTree(result);
      if (tree === null) throw new Error('invalid tree');
      this.sessionTree = tree;
    } catch (e) {
      if (generation === this.sessionTreeGeneration) this.sessionTreeError = '暂时无法读取任务分支';
    } finally {
      if (generation === this.sessionTreeGeneration) this.sessionTreeLoading = false;
    }
  }

  private async navigateSessionTree(entryId: string): Promise<void> {
    if (this.sessionStreaming || this.sessionTreeSwitchingId.length > 0
      || this.sessionTree?.leafId === entryId || this.isCreationBlockingRemoteOps()) return;
    const generation = ++this.sessionTreeGeneration;
    this.sessionTreeSwitchingId = entryId;
    this.sessionTreeError = '';
    const options: Record<string, Object> = {};
    try {
      const raw = await this.invokeContextRpc(
        'maker:navigate-session-tree', [this.sessionId, entryId, options]);
      if (generation !== this.sessionTreeGeneration || !this.sessionTreeOpen) return;
      const result = parsePiNavigateResult(raw);
      if (result === null) throw new Error('invalid result');
      if (result.cancelled) return;
      if (result.tree !== null) this.sessionTree = result.tree;
      if (result.draftText.length > 0) this.setComposerDocument(textComposerDocument(result.draftText));
      const replaced = await AppServices.instance.messages.replaceSessionWindow(this.deviceId, this.sessionId);
      if (generation !== this.sessionTreeGeneration) return;
      if (!replaced) throw new Error('history replace failed');
      await Promise.all([
        AppServices.instance.tasks.loadSessions(this.deviceId),
        AppServices.instance.interactions.refreshPending(this.deviceId, this.sessionId),
        AppServices.instance.inputQueue.refresh(this.deviceId, this.sessionId),
      ]);
      this.sessionTreeOpen = false;
    } catch (e) {
      if (generation === this.sessionTreeGeneration) this.sessionTreeError = '切换分支失败，请重试';
    } finally {
      if (generation === this.sessionTreeGeneration) this.sessionTreeSwitchingId = '';
    }
  }

  private async patchCurrentSession(patch: SessionMetaPatch, leaveDetail: boolean = false): Promise<boolean> {
    if (this.sessionActionBusy || this.isCreationBlockingRemoteOps()) return false;
    this.sessionActionBusy = true;
    const ok = await AppServices.instance.tasks.patchSession(this.deviceId, this.sessionId, patch);
    this.sessionActionBusy = false;
    if (!ok) {
      promptAction.showToast({ message: '任务更新失败，请重试' });
      return false;
    }
    this.closeSessionActions();
    if (leaveDetail && !this.isEmbedded()) router.back();
    return true;
  }

  private saveSessionRename(): void {
    const title = this.sessionRenameDraft.trim();
    if (title.length === 0) return;
    const patch = new SessionMetaPatch();
    patch.title = title;
    void this.patchCurrentSession(patch);
  }

  private async generateSessionRename(): Promise<void> {
    if (this.sessionActionBusy || this.isCreationBlockingRemoteOps()) return;
    this.sessionActionBusy = true;
    const title = await AppServices.instance.tasks.regenerateTitle(this.deviceId, this.sessionId);
    this.sessionActionBusy = false;
    if (title.length === 0) {
      promptAction.showToast({ message: '暂时无法生成标题' });
      return;
    }
    this.sessionRenameDraft = title;
    this.sessionRenameMode = true;
  }

  private toggleSessionPinned(): void {
    const session = this.session();
    if (session === undefined) return;
    const patch = new SessionMetaPatch();
    patch.pinnedAt = session.pinnedAt.length > 0 ? null : new Date().toISOString();
    void this.patchCurrentSession(patch);
  }

  private archiveOrRestoreSession(): void {
    const session = this.session();
    if (session === undefined) return;
    const patch = new SessionMetaPatch();
    patch.status = session.status === 'archived' ? 'active' : 'archived';
    if (patch.status === 'archived') patch.pinnedAt = null;
    void this.patchCurrentSession(patch, patch.status === 'archived');
  }

  private confirmDeleteSession(): void {
    if (this.isCreationBlockingRemoteOps()) return;
    this.getUIContext().showAlertDialog({
      title: '删除任务？',
      message: '删除后将从任务列表移除。此操作无法在鸿蒙端撤销。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.danger'),
        action: () => {
          const patch = new SessionMetaPatch();
          patch.status = 'deleted';
          void this.patchCurrentSession(patch, true);
        },
      },
    });
  }

  private addMessageToComposer(item: RenderMessageItem): void {
    const body = item.body.trim();
    if (body.length === 0) return;
    const next = this.input.trim().length === 0 ? body : `${this.input}\n\n${body}`;
    this.setComposerDocument(reconcileComposerProjectedText(this.composerDocument, next));
    promptAction.showToast({ message: '已添加到输入框' });
  }

  private messageActionItem(): RenderMessageItem | null {
    for (let i = 0; i < this.items.length; i++) {
      const candidate = this.items[i];
      if (candidate.type === 'message' && candidate.key === this.messageActionItemKey) {
        return candidate as RenderMessageItem;
      }
    }
    return null;
  }

  private closeMessageActions(): void {
    uiAnimateFastState(this.getUIContext(), () => {
      this.messageActionItemKey = '';
    });
  }

  private selectMessageAction(action: () => void): void {
    this.closeMessageActions();
    // 与 iOS 一致先完成 Sheet 退场，再执行 toast / 二次确认，避免两层弹窗叠在一起。
    setTimeout(action, UI_MOTION_FAST);
  }

  private copyMessageLink(item: RenderMessageItem): void {
    const clientId = item.message?.clientId ?? '';
    if (clientId.length === 0) {
      promptAction.showToast({ message: '无法定位消息' });
      return;
    }
    const link = `cindy://session/${encodeURIComponent(this.sessionId)}?message=${encodeURIComponent(clientId)}`;
    this.copyPlainText(link, '已复制消息链接');
  }

  private confirmDeleteMessage(item: RenderMessageItem): void {
    const clientId = item.message?.clientId ?? '';
    if (clientId.length === 0 || this.sessionStreaming || this.messageActionBusyId.length > 0) return;
    this.getUIContext().showAlertDialog({
      title: '删除消息？',
      message: item.kind === 'assistant' ? '这会删除同一轮中的全部 AI 输出。' : '这条消息将从任务记录中移除。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.danger'),
        action: () => void this.deleteMessage(clientId),
      },
    });
  }

  private async deleteMessage(clientId: string): Promise<void> {
    this.messageActionBusyId = clientId;
    try {
      const deleted = await AppServices.instance.messages.deleteMessage(
        this.deviceId, this.sessionId, clientId);
      if (deleted.length === 0) throw new Error('empty delete result');
      await AppServices.instance.messages.reloadSession(this.deviceId, this.sessionId);
      promptAction.showToast({ message: deleted.length > 1 ? `已删除 ${deleted.length} 条消息` : '消息已删除' });
    } catch (e) {
      promptAction.showToast({ message: '删除失败，请稍后重试' });
    } finally {
      this.messageActionBusyId = '';
    }
  }

  private showMessageActions(item: RenderMessageItem): void {
    uiAnimateState(this.getUIContext(), () => {
      this.messageActionItemKey = item.key;
    });
  }

  @Builder
  messageActionLayer() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.task_list_overlay'))
        .onClick(() => this.closeMessageActions())

      Column({ space: 8 }) {
        Column() {
          this.messageActionOption('添加到对话', $r('sys.symbol.ellipsis_message'), false, () => {
            const item = this.messageActionItem();
            if (item !== null) this.selectMessageAction(() => this.addMessageToComposer(item));
          })
          this.messageActionOption('复制当前消息链接', $r('sys.symbol.link'), false, () => {
            const item = this.messageActionItem();
            if (item !== null) this.selectMessageAction(() => this.copyMessageLink(item));
          })
          if (this.messageActionItem() !== null && this.canRewind(this.messageActionItem() as RenderMessageItem)) {
            this.messageActionOption('回到此处', $r('sys.symbol.arrow_clockwise'), false, () => {
              const item = this.messageActionItem();
              if (item !== null) this.selectMessageAction(() => this.confirmRewind(item));
            })
          }
          if (!this.sessionStreaming) {
            Divider()
              .strokeWidth(0.5)
              .color($r('app.color.message_action_border'))
            this.messageActionOption('删除本条消息', $r('sys.symbol.trash'), true, () => {
              const item = this.messageActionItem();
              if (item !== null) this.selectMessageAction(() => this.confirmDeleteMessage(item));
            })
          }
        }
        .width('100%')
        .backgroundColor($r('app.color.message_action_surface'))
        .backgroundBlurStyle(BlurStyle.Thin)
        .border({ width: 0.5, color: $r('app.color.message_action_border') })
        .borderRadius(UI_RADIUS_CONTAINER)

        Button('取消')
          .type(ButtonType.Normal)
          .width('100%')
          .height(54)
          .fontSize(uiFontSize(16))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.message_action_text'))
          .backgroundColor($r('app.color.message_action_surface'))
          .backgroundBlurStyle(BlurStyle.Thin)
          .border({ width: 0.5, color: $r('app.color.message_action_border') })
          .borderRadius(UI_RADIUS_CONTAINER)
          .clickEffect(UI_LIST_CLICK_EFFECT)
          .onClick(() => this.closeMessageActions())
      }
      .width('calc(100% - 24vp)')
      .constraintSize({ maxWidth: 620 })
      .margin({ left: 12, right: 12, bottom: 12 })
      .transition(uiOverlayTransition())
    }
    .width('100%')
    .height('100%')
    .position({ x: 0, y: 0 })
    .zIndex(98)
  }

  @Builder
  messageActionOption(label: string, symbol: Resource, danger: boolean, action: () => void) {
    Button() {
      Row({ space: 12 }) {
        SymbolGlyph(symbol)
          .fontSize(uiFontSize(22))
          .fontColor([danger ? $r('app.color.danger') : $r('app.color.message_action_text')])
          .width(24)
        Text(label)
          .fontSize(uiFontSize(16))
          .fontWeight(FontWeight.Medium)
          .fontColor(danger ? $r('app.color.danger') : $r('app.color.message_action_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
      }
      .width('100%')
    }
    .type(ButtonType.Normal)
    .width('100%')
    .height(54)
    .padding({ left: 16, right: 16 })
    .backgroundColor(Color.Transparent)
    .clickEffect(UI_LIST_CLICK_EFFECT)
    .enabled(this.messageActionBusyId.length === 0)
    .opacity(this.messageActionBusyId.length === 0 ? 1 : 0.42)
    .onClick(action)
  }

  private copyMessage(item: RenderMessageItem): void {
    this.copyPlainText(item.body, '已复制');
  }

  private confirmFork(item: RenderMessageItem): void {
    this.resolveClientId(item).then((clientId: string) => {
      if (clientId.length === 0) {
        promptAction.showToast({ message: '无法定位消息' });
        return;
      }
      AlertDialog.show({
        title: '分叉任务',
        message: '将以这条消息为起点创建新任务，原任务保持不变。',
        primaryButton: {
          value: '取消',
          action: () => {
          },
        },
        secondaryButton: {
          value: '分叉',
          action: () => this.doFork(clientId),
        },
      });
    });
  }

  private confirmRewind(item: RenderMessageItem): void {
    this.resolveClientId(item).then((clientId: string) => {
      if (clientId.length === 0) {
        promptAction.showToast({ message: '无法定位消息' });
        return;
      }
      void this.previewRewind(clientId, item.body);
    });
  }

  private rewindPreviewMessage(preview: RewindPreview): string {
    const lines: string[] = ['将回退到这条消息，之后的消息会被移除。'];
    if (preview.filesChanged.length > 0) {
      lines.push(`文件影响：${preview.filesChanged.length} 个文件，+${preview.insertions} / -${preview.deletions}`);
      const limit = Math.min(4, preview.filesChanged.length);
      for (let i = 0; i < limit; i++) lines.push(`• ${preview.filesChanged[i]}`);
      if (preview.filesChanged.length > limit) lines.push(`另有 ${preview.filesChanged.length - limit} 个文件`);
    }
    if (!preview.canRewind) {
      lines.push(preview.error.length > 0
        ? `文件无法恢复：${preview.error}。仍可只回退对话。`
        : '文件无法恢复，仍可只回退对话。');
    }
    return lines.join('\n');
  }

  private async previewRewind(clientId: string, draftText: string): Promise<void> {
    try {
      const preview = await AppServices.instance.messages.rewindPreview(
        this.deviceId, this.sessionId, clientId);
      AlertDialog.show({
        title: '回退任务',
        message: this.rewindPreviewMessage(preview),
        primaryButton: { value: '取消', action: () => {} },
        secondaryButton: {
          value: preview.canRewind ? '回退' : '只回退对话',
          action: () => void this.doRewind(clientId, draftText),
        },
      });
    } catch (e) {
      AlertDialog.show({
        title: '回退任务',
        message: '暂时无法读取文件影响。你仍可回退对话，之后的消息会被移除。',
        primaryButton: { value: '取消', action: () => {} },
        secondaryButton: { value: '继续回退', action: () => void this.doRewind(clientId, draftText) },
      });
    }
  }

  /** 取消息的 clientId（messages:list 返回完整行，含 clientId）。 */
  private resolveClientId(item: RenderMessageItem): Promise<string> {
    const msg = item.message;
    return Promise.resolve(msg !== undefined ? msg.clientId : '');
  }

  // ─── 历史图片（懒解析 OSS URL / 缩略图 / 全屏预览）─────────────────────────

  /** 遍历当前消息流的图片引用，补齐附件和 Markdown 图片的可加载 URL。 */
  private ensureImageUrls(): void {
    for (let i = 0; i < this.items.length; i++) {
      const item = this.items[i];
      if (item.type === 'tool_media') {
        const media = item as RenderToolMediaItem;
        for (let j = 0; j < media.images.length; j++) {
          const ref = media.images[j];
          this.ensureImageSource(ref.url, ref);
        }
        continue;
      }
      if (item.type !== 'message') continue;
      const message = item as RenderMessageItem;
      for (let j = 0; j < message.images.length; j++) {
        const ref = message.images[j];
        this.ensureImageSource(ref.url, ref);
      }
      const blocks: MdBlock[] = [];
      if (message.segments.length > 0) {
        for (let j = 0; j < message.segments.length; j++) {
          const segment = message.segments[j];
          for (let k = 0; k < segment.mdBlocks.length; k++) blocks.push(segment.mdBlocks[k]);
        }
      } else {
        for (let j = 0; j < message.mdBlocks.length; j++) blocks.push(message.mdBlocks[j]);
      }
      for (let j = 0; j < blocks.length; j++) {
        const block = blocks[j];
        this.ensureInlineImageSources(block.inlineTokens);
        for (let k = 0; k < block.itemTokens.length; k++) {
          this.ensureInlineImageSources(block.itemTokens[k]);
        }
        for (let k = 0; k < block.headerTokens.length; k++) {
          this.ensureInlineImageSources(block.headerTokens[k]);
        }
        for (let k = 0; k < block.rowTokens.length; k++) {
          const rowTokens = block.rowTokens[k];
          for (let c = 0; c < rowTokens.length; c++) {
            this.ensureInlineImageSources(rowTokens[c]);
          }
        }
      }
    }
  }

  private ensureInlineImageSources(tokens: InlineToken[]): void {
    for (let i = 0; i < tokens.length; i++) {
      const token = tokens[i];
      if (token.kind !== 'image' || token.url.length === 0) continue;
      const ref = this.markdownImageRef(token);
      this.ensureImageSource(token.url, ref);
    }
  }

  private ensureImageSource(key: string, ref: RemoteImageRef): void {
    if (key.length === 0) return;
    const current = this.imageStates.get(key);
    if (current !== undefined && current.sourceKey === ref.url
      && (current.status === 'loading' || current.status === 'ready' || current.status === 'error')) return;
    const intent = beginRemoteMediaResolve(current, ref.url);
    this.setImageState(key, intent.state);
    this.startImageResolve(key, ref, intent);
  }

  private startImageResolve(key: string, ref: RemoteImageRef, intent: RemoteMediaResolveIntent): void {
    const pending = this.resolveImageUrl(ref, intent.forceRefresh, intent.skipCache);
    this.imageResolutions.set(key, pending);
    pending.then((url: string) => {
      const current = this.imageStates.get(key);
      if (current === undefined) return;
      const nextState = remoteMediaResolveReady(current, intent.generation, url);
      this.setImageState(key, nextState);
      if (nextState.status === 'ready') {
        const next = new Map(this.imageSources);
        next.set(key, nextState.resolvedUrl);
        this.imageSources = next;
      }
      this.imageResolutions.delete(key);
    }).catch((error: Error) => {
      const current = this.imageStates.get(key);
      if (current !== undefined) {
        this.setImageState(key, remoteMediaResolveFailed(current, intent.generation, error.message));
      }
      this.imageResolutions.delete(key);
    });
  }

  private setImageState(key: string, state: RemoteMediaViewState): void {
    const next = new Map(this.imageStates);
    next.set(key, state);
    this.imageStates = next;
  }

  private imageStatus(key: string): string {
    return this.imageStates.get(key)?.status ?? 'idle';
  }

  private handleNativeImageError(key: string, ref: RemoteImageRef): void {
    const current = this.imageStates.get(key);
    if (current === undefined) return;
    const recovery = beginNativeMediaRecovery(current);
    const sources = new Map(this.imageSources);
    sources.delete(key);
    this.imageSources = sources;
    if (recovery !== null) {
      this.setImageState(key, recovery.state);
      this.startImageResolve(key, ref, recovery);
      return;
    }
    this.setImageState(key, failNativeMediaLoad(current));
  }

  private retryImage(key: string, ref: RemoteImageRef): void {
    const current = this.imageStates.get(key);
    if (current === undefined) {
      this.ensureImageSource(key, ref);
      return;
    }
    const intent = beginManualMediaRetry(current);
    this.setImageState(key, intent.state);
    this.startImageResolve(key, ref, intent);
  }

  private markdownImageRef(token: InlineToken): RemoteImageRef {
    const ref = new RemoteImageRef();
    ref.url = this.normalizeMarkdownImageUrl(token.url);
    ref.originalName = token.value;
    return ref;
  }

  /**
   * Markdown 图片地址只在被控端媒体链路消费点解析：相对路径绑定当前 session
   * workingDir，SSH 上下文绑定当前 session 的 remoteHostId，绝不把远端绝对路径
   * 当成 Harmony 本机路径。
   */
  private normalizeMarkdownImageUrl(raw: string): string {
    const url = normalizeImageUrlScheme(raw.trim());
    if (url.startsWith('http://') || url.startsWith('https://')
      || /^data:image\//i.test(url) || parseAttachmentOssRef(url) !== null
      || url.startsWith('xdt-image://') || url.startsWith('cindy-media://')) {
      return url;
    }
    // 绝对 Windows / UNC 路径不是 URI scheme；其它显式 scheme（尤其
    // javascript:/vbscript:）不能降级成 workingDir 下的相对文件名。
    if (!isAbsoluteMediaPath(url) && /^[A-Za-z][A-Za-z0-9+.-]*:/.test(url)
      && !url.startsWith('file://') && !url.startsWith('xdt-file://')) {
      return '';
    }
    const session = this.session();
    const workingDir = session !== undefined ? session.workingDir : '';
    const remoteHostId = session !== undefined ? session.remoteHostId : '';
    let path = url;
    if (url.startsWith('xdt-file://')) {
      const query = url.indexOf('?');
      const encodedPath = query >= 0 ? queryValue(url.slice(query + 1), 'path') : '';
      if (encodedPath.length === 0) return '';
      path = encodedPath;
    } else if (url.startsWith('file://')) {
      path = url.slice('file://'.length);
      if (path.startsWith('localhost/')) path = path.slice('localhost'.length);
      try {
        path = decodeURIComponent(path);
      } catch (e) {
        return '';
      }
    }
    if (!isAbsoluteMediaPath(path)) {
      if (workingDir.length === 0) return '';
      const relative = path.startsWith('./') ? path.slice(2) : path;
      path = workingDir.endsWith('/') || workingDir.endsWith('\\')
        ? `${workingDir}${relative}`
        : `${workingDir}/${relative}`;
    }
    let normalized = `xdt-file://open?path=${encodeURIComponent(path)}`;
    if (remoteHostId.length > 0) {
      if (workingDir.length === 0) return '';
      normalized += `&sessionId=${encodeURIComponent(this.sessionId)}`
        + `&remoteHostId=${encodeURIComponent(remoteHostId)}`
        + `&workdir=${encodeURIComponent(workingDir)}`;
    }
    return normalized;
  }

  /**
   * 解析图片引用为可加载 URL：
   * - http(s) 直链直接使用；
   * - cindy/xdt OSS 引用走 presign-get；
   * - Desktop 本地媒体引用走 device-link:media:fetch，再兼容 inline 缩略图和 OSS。
   */
  private resolveImageUrl(
    ref: RemoteImageRef,
    forceRefresh: boolean = false,
    skipCache: boolean = false,
  ): Promise<string> {
    const url = normalizeImageUrlScheme(ref.url.trim());
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return Promise.resolve(url);
    }
    if (/^data:image\//i.test(url)) {
      return Promise.resolve(url);
    }
    const parsed = parseAttachmentOssRef(url);
    if (parsed !== null) {
      if (forceRefresh) this.ossUrlCache.delete(parsed.ossKey);
      return this.resolveOssUrl(parsed.ossKey).catch(() => {
        return '';
      });
    }
    if (!this.isDesktopLocalImageUrl(url)) {
      return Promise.resolve('');
    }

    return AppServices.instance.messages.fetchRemoteMedia(this.deviceId, url, true, skipCache).then(
      (fetched: RemoteMediaFetchResult) => {
        if (fetched.inlineBase64.length > 0) {
          const mimeType = fetched.mimeType.length > 0
            ? fetched.mimeType
            : (ref.mimeType.length > 0 ? ref.mimeType : 'image/webp');
          if (!isImageMimeType(mimeType)) return '';
          return `data:${mimeType};base64,${fetched.inlineBase64}`;
        }
        if (fetched.ossKey.length === 0) {
          return '';
        }
        if (forceRefresh) this.ossUrlCache.delete(fetched.ossKey);
        return this.resolveOssUrl(fetched.ossKey);
      },
    ).catch(() => {
      return '';
    });
  }

  /** 解析被控端历史媒体 URL 的最小图片 scheme 集合。 */
  private isDesktopLocalImageUrl(url: string): boolean {
    return /^(?:xdt-image|cindy-media|xdt-file):\/\//i.test(url);
  }

  /** OSS key → 临时可加载地址，并在页面生命周期内复用。 */
  private resolveOssUrl(ossKey: string): Promise<string> {
    const cached = this.ossUrlCache.get(ossKey);
    if (cached !== undefined) {
      return Promise.resolve(cached);
    }
    return AppServices.instance.auth.getAccessToken().then((token: string | null) => {
      if (token === null || token.length === 0) {
        throw new Error('未登录');
      }
      return presignGet(ossKey, token);
    }).then((getUrl: string) => {
      this.ossUrlCache.set(ossKey, getUrl);
      return getUrl;
    });
  }

  /** 用系统浏览器打开链接（Markdown 链接点击）。 */
  private openUrl(url: string): void {
    if (url.length === 0) {
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    context.startAbility({
      action: 'ohos.want.action.viewData',
      uri: url,
    }).catch(() => {
      promptAction.showToast({ message: '无法打开链接' });
    });
  }

  private openInlineImagePreview(url: string): void {
    const src = this.imageSources.get(url) ?? '';
    if (src.length > 0) {
      uiAnimateFastState(this.getUIContext(), () => {
        this.previewImageUrl = src;
      });
    }
  }

  private openImagePreview(ref: RemoteImageRef): void {
    const src = this.imageSources.get(ref.url) ?? '';
    if (src.length > 0) {
      uiAnimateFastState(this.getUIContext(), () => {
        this.previewImageUrl = src;
      });
    }
  }

  // ─── 交互确认（Permission / Ask User / Plan Review）──────────────────────────

  private resolveInteraction(item: PendingInteraction, decision: Record<string, Object>): void {
    this.clearArmedPermission();
    AppServices.instance.interactions.resolve(
      this.deviceId, item.sessionId, item.requestId, decision).catch(() => {
      promptAction.showToast({ message: '提交失败，请重试' });
    });
  }

  private interactionBusy(item: PendingInteraction): boolean {
    return AppServices.instance.interactions.isResolving(item.requestId);
  }

  private requestStr(item: PendingInteraction, key: string): string {
    const v = item.raw[key];
    return typeof v === 'string' ? v : '';
  }

  private requestObj(item: PendingInteraction, key: string): Record<string, Object> {
    const v = item.raw[key];
    if (v !== undefined && typeof v === 'object' && !Array.isArray(v)) {
      return v as Record<string, Object>;
    }
    return {};
  }

  private requestBool(item: PendingInteraction, key: string): boolean {
    const v = item.raw[key];
    return v === true;
  }

  private pluginSetupTitle(item: PendingInteraction): string {
    const ghostName = this.requestStr(item, 'ghostName');
    if (ghostName.length > 0) return ghostName;
    const pluginName = this.requestStr(item, 'pluginName');
    return pluginName.length > 0 ? pluginName : '等待电脑端配置';
  }

  private pluginSetupCanCancel(item: PendingInteraction): boolean {
    if (this.requestBool(item, 'terminal')) return false;
    const revision = item.raw['revision'];
    return typeof revision === 'number' && Number.isInteger(revision) && revision >= 0;
  }

  private pluginSetupCancelDecision(item: PendingInteraction): Record<string, Object> {
    const decision: Record<string, Object> = {};
    decision['kind'] = 'plugin_setup';
    decision['action'] = 'cancel';
    decision['expectedRevision'] = typeof item.raw['revision'] === 'number' ? item.raw['revision'] : 0;
    return decision;
  }

  // ── Permission ──
  private permissionToolName(item: PendingInteraction): string {
    const toolName = this.requestStr(item, 'toolName');
    return toolName.length > 0 ? toolName : '工具调用';
  }

  private permissionInputSummary(item: PendingInteraction): string {
    const input = this.requestObj(item, 'input');
    if (Object.keys(input).length === 0) {
      return '';
    }
    const command = typeof input['command'] === 'string' ? input['command'] as string : '';
    if (command.length > 0) return command.slice(0, 12000);
    return JSON.stringify(input).slice(0, 12000);
  }

  private permissionCanAlwaysAllow(item: PendingInteraction): boolean {
    return permissionCanAlwaysAllow(item.raw);
  }

  private permissionDecision(item: PendingInteraction, behavior: string): Record<string, Object> {
    return buildPermissionDecision(item.raw, behavior);
  }

  private permissionRiskText(item: PendingInteraction): string {
    return permissionRiskSummary(item.raw);
  }

  private permissionIsArmed(item: PendingInteraction): boolean {
    return this.armedPermissionRequestId === item.requestId
      && this.armedPermissionAction === 'allow-once'
      && this.armedPermissionFingerprint === permissionRequestFingerprint(item.raw, 'allow-once');
  }

  private clearArmedPermission(): void {
    this.armedPermissionRequestId = '';
    this.armedPermissionAction = '';
    this.armedPermissionFingerprint = '';
  }

  private handlePermissionDecision(item: PendingInteraction, action: string): void {
    if (this.interactionBusy(item)) return;
    if (action === 'deny') {
      this.clearArmedPermission();
      this.resolveInteraction(item, this.permissionDecision(item, action));
      return;
    }
    if (this.permissionRiskText(item).length > 0
      && this.armedPermissionFingerprint !== permissionRequestFingerprint(item.raw, action)) {
      this.armedPermissionRequestId = item.requestId;
      this.armedPermissionAction = action;
      this.armedPermissionFingerprint = permissionRequestFingerprint(item.raw, action);
      return;
    }
    this.resolveInteraction(item, this.permissionDecision(item, action));
  }

  // ── Ask User ──
  private askQuestions(item: PendingInteraction): Record<string, Object>[] {
    const raw = item.raw['questions'];
    const out: Record<string, Object>[] = [];
    if (Array.isArray(raw)) {
      const list: Object[] = raw as Object[];
      for (let i = 0; i < list.length; i++) {
        const value = list[i];
        if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) continue;
        const question = value as Record<string, Object>;
        if (typeof question['question'] === 'string' && (question['question'] as string).length > 0) {
          out.push(question);
        }
      }
    }
    return out;
  }

  private askQuestionCount(item: PendingInteraction): number {
    return this.askQuestions(item).length;
  }

  private askDraft(item: PendingInteraction): AskUserDraft {
    return this.askDraftSnapshots.get(item.requestId) ?? new AskUserDraft();
  }

  /** 点击处理使用 Store 返回的副本，避免原地修改 @State Map 中的快照对象。 */
  private mutableAskDraft(item: PendingInteraction): AskUserDraft {
    return AppServices.instance.interactions.readAskDraft(item.requestId) ?? new AskUserDraft();
  }

  private saveAskDraft(item: PendingInteraction, draft: AskUserDraft): void {
    AppServices.instance.interactions.saveAskDraft(item.requestId, draft);
    // Store notify 会同步所有 TaskPage；这里再显式换 Map 引用，保证本次点击当帧可见。
    const snapshot = AppServices.instance.interactions.readAskDraft(item.requestId);
    const next = new Map(this.askDraftSnapshots);
    if (snapshot === null) next.delete(item.requestId);
    else next.set(item.requestId, snapshot);
    this.askDraftSnapshots = next;
  }

  private askCurrentIndex(item: PendingInteraction): number {
    const count = this.askQuestionCount(item);
    if (count === 0) return 0;
    return Math.min(Math.max(this.askDraft(item).currentIndex, 0), count - 1);
  }

  private currentAskQuestion(item: PendingInteraction): Record<string, Object> {
    const questions = this.askQuestions(item);
    return questions.length === 0 ? {} : questions[this.askCurrentIndex(item)];
  }

  private askQuestion(item: PendingInteraction): string {
    const q = this.currentAskQuestion(item);
    const v = q['question'];
    return typeof v === 'string' ? v : '';
  }

  private askMultiSelect(item: PendingInteraction): boolean {
    const q = this.currentAskQuestion(item);
    return q['multiSelect'] === true;
  }

  private askOptionRows(item: PendingInteraction): AskOptionPresentation[] {
    return askOptionPresentations(this.currentAskQuestion(item));
  }

  private askOptions(item: PendingInteraction): string[] {
    const out: string[] = [];
    const rows = this.askOptionRows(item);
    for (let i = 0; i < rows.length; i++) out.push(rows[i].label);
    return out;
  }

  private askCustomInput(item: PendingInteraction): string {
    return this.askDraft(item).customInput;
  }

  private isAskSelected(item: PendingInteraction, label: string): boolean {
    return this.askDraft(item).selectedLabels.indexOf(label) >= 0;
  }

  private toggleAskSelection(item: PendingInteraction, label: string): void {
    const draft = this.mutableAskDraft(item);
    if (!this.askMultiSelect(item)) {
      draft.selectedLabels = [label];
      draft.customInput = '';
      draft.showCustomInput = false;
    } else {
      const idx = draft.selectedLabels.indexOf(label);
      if (idx >= 0) {
        draft.selectedLabels = draft.selectedLabels.slice(0, idx).concat(draft.selectedLabels.slice(idx + 1));
      } else {
        draft.selectedLabels = draft.selectedLabels.concat([label]);
      }
    }
    this.recordCurrentAskAnswer(item, draft);
    this.saveAskDraft(item, draft);
  }

  private updateAskCustomInput(item: PendingInteraction, value: string): void {
    const draft = this.mutableAskDraft(item);
    draft.customInput = value;
    draft.showCustomInput = value.length > 0;
    if (!this.askMultiSelect(item) && value.length > 0) draft.selectedLabels = [];
    this.recordCurrentAskAnswer(item, draft);
    this.saveAskDraft(item, draft);
  }

  private askCurrentAnswer(item: PendingInteraction): string {
    return this.answerFromAskDraft(item, this.askDraft(item));
  }

  private answerFromAskDraft(item: PendingInteraction, draft: AskUserDraft): string {
    const custom = draft.customInput.trim();
    if (!this.askMultiSelect(item)) {
      if (custom.length > 0) return custom;
      return draft.selectedLabels.length > 0 ? draft.selectedLabels[0] : '';
    }
    const selected: string[] = [];
    const options = this.askOptions(item);
    for (let i = 0; i < options.length; i++) {
      if (draft.selectedLabels.indexOf(options[i]) >= 0) selected.push(options[i]);
    }
    if (custom.length > 0) selected.push(custom);
    return selected.length > 0 ? JSON.stringify(selected) : '';
  }

  private recordCurrentAskAnswer(item: PendingInteraction, draft: AskUserDraft): void {
    const question = this.askQuestion(item);
    if (question.length > 0) draft.answers.set(question, this.answerFromAskDraft(item, draft));
  }

  private restoreAskControls(item: PendingInteraction, draft: AskUserDraft): void {
    draft.selectedLabels = [];
    draft.customInput = '';
    draft.showCustomInput = false;
    const answer = draft.answers.get(this.askQuestionAt(item, draft.currentIndex)) ?? '';
    if (answer.length === 0) return;
    const options = this.askOptionsAt(item, draft.currentIndex);
    if (this.askMultiSelectAt(item, draft.currentIndex)) {
      try {
        const parsed = JSON.parse(answer) as Object;
        if (!Array.isArray(parsed)) return;
        const values = parsed as Object[];
        for (let i = 0; i < values.length; i++) {
          if (typeof values[i] !== 'string') continue;
          const value = values[i] as string;
          if (options.indexOf(value) >= 0) draft.selectedLabels.push(value);
          else if (draft.customInput.length === 0) draft.customInput = value;
        }
        draft.showCustomInput = draft.customInput.length > 0;
      } catch (e) {
      }
      return;
    }
    if (options.indexOf(answer) >= 0) {
      draft.selectedLabels = [answer];
    } else {
      draft.customInput = answer;
      draft.showCustomInput = true;
    }
  }

  private askQuestionAt(item: PendingInteraction, index: number): string {
    const questions = this.askQuestions(item);
    if (index < 0 || index >= questions.length) return '';
    const value = questions[index]['question'];
    return typeof value === 'string' ? value : '';
  }

  private askMultiSelectAt(item: PendingInteraction, index: number): boolean {
    const questions = this.askQuestions(item);
    return index >= 0 && index < questions.length && questions[index]['multiSelect'] === true;
  }

  private askOptionsAt(item: PendingInteraction, index: number): string[] {
    const questions = this.askQuestions(item);
    if (index < 0 || index >= questions.length) return [];
    const raw = questions[index]['options'];
    const out: string[] = [];
    if (!Array.isArray(raw)) return out;
    const options = raw as Object[];
    for (let i = 0; i < options.length; i++) {
      if (options[i] === null || typeof options[i] !== 'object' || Array.isArray(options[i])) continue;
      const label = (options[i] as Record<string, Object>)['label'];
      if (typeof label === 'string' && label.length > 0) out.push(label);
    }
    return out;
  }

  private moveAskQuestion(item: PendingInteraction, delta: number): void {
    const draft = this.mutableAskDraft(item);
    this.recordCurrentAskAnswer(item, draft);
    const max = Math.max(0, this.askQuestionCount(item) - 1);
    draft.currentIndex = Math.min(Math.max(draft.currentIndex + delta, 0), max);
    this.restoreAskControls(item, draft);
    this.saveAskDraft(item, draft);
  }

  private askIsLast(item: PendingInteraction): boolean {
    return this.askCurrentIndex(item) >= this.askQuestionCount(item) - 1;
  }

  private submitAskQuestion(item: PendingInteraction): void {
    const draft = this.mutableAskDraft(item);
    const answer = this.answerFromAskDraft(item, draft);
    if (answer.trim().length === 0) return;
    this.recordCurrentAskAnswer(item, draft);
    if (!this.askIsLast(item)) {
      draft.currentIndex += 1;
      this.restoreAskControls(item, draft);
      this.saveAskDraft(item, draft);
      return;
    }
    this.resolveInteraction(item, this.askDecisionFromDraft(draft));
  }

  private skipAskQuestion(item: PendingInteraction): void {
    const draft = this.mutableAskDraft(item);
    draft.answers.set(this.askQuestion(item), '');
    if (!this.askIsLast(item)) {
      draft.currentIndex += 1;
      this.restoreAskControls(item, draft);
      this.saveAskDraft(item, draft);
      return;
    }
    this.resolveInteraction(item, this.askDecisionFromDraft(draft));
  }

  private askDecisionFromDraft(draft: AskUserDraft): Record<string, Object> {
    const answers: Record<string, Object> = {};
    draft.answers.forEach((value: string, key: string) => {
      answers[key] = value;
    });
    const d: Record<string, Object> = {};
    d['kind'] = 'ask_user_question';
    d['answers'] = answers;
    return d;
  }

  private askEmptyDecision(): Record<string, Object> {
    const d: Record<string, Object> = {};
    const answers: Record<string, Object> = {};
    d['kind'] = 'ask_user_question';
    d['answers'] = answers;
    return d;
  }

  // ── Plan Review ──
  private planDraft(item: PendingInteraction): PlanReviewDraft {
    const existing = AppServices.instance.interactions.readPlanDraft(item.requestId);
    if (existing !== null) return existing;
    const draft = new PlanReviewDraft();
    draft.planText = this.requestStr(item, 'plan');
    return draft;
  }

  private planText(item: PendingInteraction): string {
    return this.planDraft(item).planText;
  }

  private planEvidence(item: PendingInteraction): PlanReviewEvidencePresentation {
    return buildPlanReviewEvidence(
      this.planText(item), this.requestStr(item, 'planFilePath'), 3);
  }

  private planDraftEdited(item: PendingInteraction): boolean {
    return this.planText(item) !== this.requestStr(item, 'plan');
  }

  private togglePlanEdit(item: PendingInteraction): void {
    const draft = this.planDraft(item);
    draft.editMode = !draft.editMode;
    if (draft.editMode) draft.expanded = true;
    AppServices.instance.interactions.savePlanDraft(item.requestId, draft);
  }

  private togglePlanExpanded(item: PendingInteraction): void {
    const draft = this.planDraft(item);
    draft.expanded = !draft.expanded;
    AppServices.instance.interactions.savePlanDraft(item.requestId, draft);
  }

  private updatePlanText(item: PendingInteraction, value: string): void {
    const draft = this.planDraft(item);
    draft.planText = value;
    AppServices.instance.interactions.savePlanDraft(item.requestId, draft);
  }

  private updatePlanFeedback(item: PendingInteraction, value: string): void {
    const draft = this.planDraft(item);
    draft.feedback = value;
    AppServices.instance.interactions.savePlanDraft(item.requestId, draft);
  }

  private requestPlanFeedback(item: PendingInteraction): void {
    const draft = this.planDraft(item);
    if (!draft.feedbackOpen) {
      draft.feedbackOpen = true;
      AppServices.instance.interactions.savePlanDraft(item.requestId, draft);
      return;
    }
    if (draft.feedback.trim().length === 0) return;
    this.resolveInteraction(item, this.planDecision(item, false));
  }

  private planDecision(item: PendingInteraction, approved: boolean): Record<string, Object> {
    const draft = this.planDraft(item);
    const d: Record<string, Object> = {};
    d['kind'] = 'plan_review';
    d['behavior'] = approved ? 'allow' : 'deny';
    if (approved) {
      d['editedPlan'] = draft.planText;
    } else {
      d['reason'] = draft.feedback.trim();
    }
    return d;
  }

  private doFork(clientId: string): void {
    AppServices.instance.messages.fork(this.deviceId, this.sessionId, clientId).then((newSessionId: string) => {
      if (newSessionId.length > 0) {
        promptAction.showToast({ message: '已创建新任务' });
        // 返回任务列表（列表会刷新显示新任务）。嵌入式详情留在右侧，等待列表选择状态更新。
        if (!this.isEmbedded()) router.back();
      } else {
        promptAction.showToast({ message: '分叉失败' });
      }
    }).catch(() => {
      promptAction.showToast({ message: '分叉失败' });
    });
  }

  private async doRewind(clientId: string, draftText: string): Promise<void> {
    try {
      const session = await AppServices.instance.messages.rewindCommit(
        this.deviceId, this.sessionId, clientId);
      if (session === null || session.id.length === 0) throw new Error('invalid rewind result');
      AppServices.instance.tasks.upsertSession(this.deviceId, session);
      await AppServices.instance.messages.reloadSession(this.deviceId, this.sessionId);
      this.setComposerDocument(textComposerDocument(draftText));
      promptAction.showToast({ message: '已回退，可编辑原消息后重新发送' });
    } catch (e) {
      promptAction.showToast({ message: '回退失败' });
    }
  }
}

/** 独立详情路由入口；宽屏双栏直接使用上面的可嵌入内容组件。 */
@Entry
@Component
struct TaskPage {
  build() {
    Column() {
      TaskPageContent()
    }
    .width('100%')
    .height('100%')
  }
}
