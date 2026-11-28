import { CompanionStrip, readCompanionCompact, writeCompanionCompact } from '../components/companions/CompanionStrip';
import { SplitHandle } from '../components/common/SplitHandle';
import { requestProjectSettingsClose } from '../components/projects/ProjectSettingsPanel';
import { WorkdirBrowser, workdirBrowserSheetOptions } from './files/WorkdirBrowser';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RelayRoute } from '../core/device-link/RelayRoute';
import { PluginEngineMark } from '../components/PluginEngineMark';
import { PluginEngine, findPluginEngine, isPluginEngineSession } from '../core/plugin-engines/PluginEngines';
import { ProjectSymbol } from '../components/projects/ProjectSymbol';
import { IncomingShareSurface } from '../components/IncomingShareSurface';
import { IncomingShareDestination } from '../core/incoming-share/IncomingShareStore';
import { UsageDashboardPanel } from '../components/UsageDashboardPanel';
import { TeammateAvatar } from '../components/TeammateAvatar';
import { CompanionCreateMenu, CompanionHostOption } from '../components/companions/CompanionCreateMenu';
import {
  UiSheetExtras, uiConfirm, uiConfirmCopy, uiMenuOptions, uiOverlayBuildId, uiOverlayTrace, uiSheetOptions, uiToast,
} from '../components/common/UiOverlay';
import { TeammateRosterEntry } from '../core/tasks/TeammateRoster';
import { ProjectMachine, projectMachineLabel } from '../core/tasks/ProjectMachineIdentity';
import { deviceDisplayName } from '../core/tasks/DeviceDisplayName';
/**
 * 任务聚合首页。
 *
 * 对齐 iOS：首页直接聚合所有可控制电脑的任务，标题下拉可按设备筛选并切换项目分组；
 * 页面存活期间订阅各设备的 sessions topic，列表数据始终来自被控端权威快照。
 *
 * 视觉遵循 Cindy 设计系统：页面平坦 Surface、1px Board 分隔、12vp 容器圆角、
 * 胶囊交互元素；行点击使用系统 clickEffect 弹性反馈，菜单淡入淡出。
 */

import {
  KeyboardAvoidMode,
  LengthMetrics,
  router,
  SymbolGlyphModifier,
  window,
} from '@kit.ArkUI';
import {
  BlurStrategy,
  DividerMode,
  HdsAnimationMode,
  HdsBarLayoutMode,
  HdsBarStyle,
  HdsNavigation,
  HdsNavigationTitleMode,
  HdsTabs,
  HdsTabsController,
  ScrollEffectType,
  hdsMaterial,
} from '@kit.UIDesignKit';
import { AppServices } from '../core/AppServices';
import { harmonyV12String } from '../core/HarmonyStrings';
import { PresenceSnapshot } from '../core/device-link/DlProtocol';
import { RemoteSession, readStr, sessionProjectDirectory } from '../core/tasks/TaskModels';
import { HomeModulePanel, HomeModuleRequest } from '../components/HomeModulePanel';
import { SessionLiveActivity, SessionMetaPatch } from '../core/tasks/TaskStore';
import {
  listTaskSearchProjects,
  TaskSearchAgentFilter,
  TaskSearchFilters,
  TaskSearchLastActivityFilter,
  TaskSearchOrigin,
  TaskSearchProjectOption,
  TaskSearchRequest,
  TaskSearchResult,
  TaskSearchSortBy,
  TaskSearchStatus,
  TaskSearchStatusFilter,
  TASK_SEARCH_DEBOUNCE_MS,
  taskSearchActiveFilterCount,
} from '../core/tasks/TaskSearchStore';
import {
  TaskProjectOrderMode,
  TaskProjectOrderProject,
  TaskProjectOrderSnapshot,
  reconcileTaskProjectOrder,
  reorderVisibleTaskProjectOrder,
  taskProjectOrderKey,
} from '../core/tasks/TaskProjectOrderStore';
import { TaskListPreferences } from '../core/tasks/TaskListPreferenceStore';
import {
  TASK_LIST_RECONCILE_INTERVAL_MS,
  TaskListReconcileBackoff,
} from '../core/tasks/TaskListReconcilePolicy';
import { OrcaTaskDetail } from './TaskPage';
import { ORCA_DETAIL_MIN_WIDTH } from './TaskSplitLayout';
import {
  ResidentTaskPane, rememberResidentTaskPane, residentPaneSurvives, residentTaskPaneKey,
} from '../core/tasks/ResidentTaskPanes';
import { NewSessionPageContent } from './NewSessionPage';
import {
  consumeTaskSplitRouteSelection,
  effectiveTaskSafeWindow,
  isWideTaskLayout,
  TaskSafeWindowSize,
  TASK_SPLIT_DIVIDER_WIDTH,
  taskDetailKeyboardInset,
  taskDetailPaneWidth,
  taskListPaneWidth,
  taskSplitDrag,
} from './TaskSplitLayout';
import { readTaskWindowMetrics } from './TaskWindowMetrics';
import {
  compareTaskListLabels,
  compareTaskSessionsForList,
  resolveTaskRightStatus,
  taskActivityAt,
  taskDisplayTitle,
  taskListEntryPresentationState,
  taskListCategory,
  taskIsAutomation,
  taskListShouldShowFloatingBarAtBoundary,
  stableTaskKeys,
  TaskListCategory,
  TaskRightStatusKind,
  TaskListSortMode,
  taskPreviewText,
  taskProjectName,
  taskRelativeTime,
  taskVisibleInTaskList,
} from './TaskListPresentation';
import {
  UI_ICON_CLICK_EFFECT,
  UI_LIST_CLICK_EFFECT,
  UI_CURVE_MOVE,
  UI_MOTION_FAST,
  UI_RADIUS_CONTAINER,
  UI_RADIUS_CONTROL,
  UI_RADIUS_PILL,
  uiAnimateFastState,
  uiAnimateState,
  uiOverlayTransition,
  uiRevealTransition,
} from '../components/UiKit';

const LIST_INSET = 16;
const FLOATING_BAR_BOTTOM_MARGIN = 0;
const FLOATING_BAR_HEIGHT = 52;
const FLOATING_BAR_CONTENT_INSET = 72;
/** 累计一小段明确的浏览位移再切换浮栏，避免单帧抖动造成忽隐忽现。 */
const FLOATING_BAR_HIDE_DISTANCE = 10;
const FLOATING_BAR_SHOW_DISTANCE = 8;
const FLOATING_BAR_FLING_VELOCITY = 240;
const FLOATING_BAR_SCROLL_NOISE = 0.25;
/** 两侧 HdsNavigation 的 MINI 标题栏共用 56vp 内容高；分割线从其下方开始。 */
const SPLIT_HEADER_HEIGHT = 56;
/** 微信式分割提示：视觉紧凑，透明命中区仍保持可拖拽。 */
/** 左侧标题栏不向列表内容额外延伸，避免首条会话落入标题栏的磨砂蒙层。 */
const LIST_HEADER_MASK_EXTRA_HEIGHT = 0;
/** 项目组内联展示的任务数上限，超出后由「查看全部」展开。 */
const PROJECT_INLINE_LIMIT = 5;

class TaskListEntry {
  key: string = '';
  deviceId: string = '';
  deviceName: string = '';
  session: RemoteSession = new RemoteSession();
}

class TaskProjectGroup {
  key: string = '';
  deviceId: string = '';
  workingDir: string = '';
  title: string = '';
  latestActivityAt: string = '';
  entries: TaskListEntry[] = [];
}

@Entry
@Component
struct TaskListPage {
  @State devices: PresenceSnapshot[] = [];
  @State entries: TaskListEntry[] = [];
  @State @Watch('usageCardScopeChanged') selectedDeviceId: string = '';
  @State private activeUsageCardId: string = '';
  @State private projectFolderMenuKey: string = '';
  @State private projectFolderOpen: boolean = false;
  @State private projectFolderDevice: string = '';
  @State private projectFolderRoot: string = '';
  @State private moduleRequest: HomeModuleRequest | null = null;
  private readonly closeHomeModule: () => void = (): void => { this.moduleRequest = null; };
  @State selectedSessionDeviceId: string = '';
  @State selectedSessionId: string = '';
  @State selectedMessageClientId: string = '';
  @State residentPanes: ResidentTaskPane[] = [];
  /**
   * 每次选择任务都递增，让同一常驻实例对「同一条消息再点一次」也重新定位。
   * 常驻实例由 ForEach 按任务 key 复用，不能靠替换 pane 对象传入新的定位目标。
   */
  @State selectedMessageRevision: number = 0;
  /** 新任务只在当前页面保留本地草稿；宽屏放在右栏，窄屏覆盖整页。 */
  @State newSessionDraftOpen: boolean = false;
  private draftComposerBack: (() => boolean) | undefined = undefined;
  @State newSessionDraftDeviceId: string = '';
  @State scopeMenuOpen: boolean = false;
  @State sortMenuOpen: boolean = false;
  @State private pluginIconEngines: Map<string, PluginEngine[]> = new Map<string, PluginEngine[]>();
  private pluginIconTargets: string = '';
  private pluginIconOwner: string = '';
  private pluginIconGeneration: number = 0;
  @State activeListTab: TaskListCategory = 'projects';
  @State private usageOpen: boolean = false;
  @State sortMode: TaskListSortMode = 'recency';
  /** 多设备范围使用本机账本；单设备范围优先使用被控端账本。 */
  @State projectOrderMode: TaskProjectOrderMode = 'activity';
  @State projectManualOrder: string[] = [];
  @State projectOrderHostLoaded: boolean = false;
  @State projectOrderHostAvailable: boolean = true;
  @State projectOrderSyncing: boolean = false;
  @State projectOrderPendingMode: string = '';
  @State projectOrderPendingKeys: string[] = [];
  @State projectOrderDraggingKey: string = '';
  @State searchOpen: boolean = false;
  @State searchQuery: string = '';
  @State taskSearchStatus: TaskSearchStatus = 'idle';
  @State taskSearchResults: TaskSearchResult[] = [];
  @State taskSearchUsedCacheFallback: boolean = false;
  @State taskSearchFilterOpen: boolean = false;
  @State taskSearchStatusFilter: TaskSearchStatusFilter = 'all';
  @State taskSearchAgentFilter: TaskSearchAgentFilter = 'all';
  @State taskSearchLastActivityFilter: TaskSearchLastActivityFilter = 'all';
  @State taskSearchSortBy: TaskSearchSortBy = 'relevance';
  @State taskSearchProjectKeys: string[] = [];
  @State refreshing: boolean = false;
  @State sessionActionBusy: boolean = false;
  @State bulkMode: boolean = false;
  @State selectedEntryKeys: string[] = [];
  // 置顶和单个项目组每次打开应用默认收起；手动展开状态只在本页面存活期间保留。
  @State private teammateCompact: boolean = false;
  private teammatePreferenceOwner: string = '';
  private teammatePreferenceRevision: number = 0;
  private rosterEligible: Set<string> = new Set();
  private rosterQueue: Set<string> = new Set();
  private rosterDraining: boolean = false;
  @State private visibleTeammates: TeammateRosterEntry[] = [];
  @State private visibleTeammateKeys: string[] = [];
  @State private visibleTeammateByKey: Map<string, TeammateRosterEntry> = new Map();
  private teammateDevicesKey: string = '';
  private teammateSessionKeys: Set<string> = new Set();
  private teammateProjectionCount: number = 0;
  private teammateBuildCount: number = 0;
  private teammateBuildMs: number = 0;
  @State teammateRoster: TeammateRosterEntry[] = [];
  private residentBackHandlers: Map<string, () => boolean> = new Map();
  private rosterReadInFlight: Map<string, boolean> = new Map();
  private groupCreateToken: number = 0;
  /** 新建任务页发起的新建项目保存后回传给草稿：「设备\n目录\n序号」。 */
  @State private draftCreatedProject: string = '';
  private draftCreatedProjectToken: number = 0;
  private rosterTimers: Map<string, number> = new Map();
  /** 新建伙伴后待打开的那一个（见 companionCreated）。 */
  private pendingTeammateDevice: string = '';
  private pendingTeammateBot: string = '';
  private pendingTeammateScope: string = '';
  private pendingTeammateEpoch: number = -1;
  private pendingTeammateTimer: number = -1;
  @State pinnedCollapsed: boolean = true;
  @State collapsedProjectKeys: string[] = [];
  @State expandedProjectKeys: string[] = [];
  private projectCollapseInitialized: boolean = false;
  private savedOpenProjectKeys: string[] = [];
  private preferencesHydrated: boolean = false;
  private selectedDeviceNameHint: string = '';
  @State connectionStatus: string = 'connecting';
  @State now: number = Date.now();
  @State viewportWidth: number = 0;
  @State viewportHeight: number = 0;
  @State safeWindowWidth: number = 0;
  @State safeWindowHeight: number = 0;
  /** 窗口避让区读取失败；为 true 时分栏退回按页面尺寸判断。 */
  @State safeWindowMetricsUnavailable: boolean = false;
  /** 系统分屏或悬浮窗时一律单栏（D-015）。 */
  @State safeWindowMultiWindow: boolean = false;
  private windowStatusListening: boolean = false;
  @State requestedListPaneWidth: number = 0;
  /**
   * 双栏时用户收起了任务列表（详情标题栏最左侧按钮）。只保存在本次页面生命周期内，
   * 退出双栏即恢复展开；与列表宽度一样不写入偏好（D-015）。
   */
  @State private listPaneFullscreen: boolean = false;
  @State private dividerOverrun: number = 0;
  @State listPaneCollapsed: boolean = false;
  @State keyboardHeight: number = 0;

  private routeParamsInitialized: boolean = false;
  private unsubs: Array<() => void> = [];
  private clockTimer: number = -1;
  private taskListReconcileTimer: number = -1;
  private taskListLoadInFlight: Map<string, Promise<boolean>> = new Map();
  private taskListReconcileBackoff: TaskListReconcileBackoff = new TaskListReconcileBackoff();
  private taskListReconcileGeneration: number = 0;
  private taskSearchGeneration: number = 0;
  private taskSearchTimer: number = -1;
  /** 上次发起搜索时的条件；任务列表推送只在条件真的变化时才重搜（对齐 Mobile 的依赖项）。 */
  private lastTaskSearchKey: string = '';
  private projectOrderScopeGeneration: number = 0;
  private projectOrderSuppressClick: boolean = false;
  private projectDragStartY: number = 0;
  private projectDragStartIndex: number = -1;
  private projectDragStartOrder: string[] = [];
  private projectDragMoved: boolean = false;
  private dividerTouchId: number = -1;
  private dividerTouchStartX: number = 0;
  private dividerTouchStartWidth: number = 0;
  private singlePaneNavigationPending: boolean = false;
  private pageActive: boolean = false;
  /** 页面重进后，旧的刷新/任务操作 Promise 不能再改写新页面状态。 */
  private pageLifecycleGeneration: number = 0;
  /** Display order is a view snapshot, not task truth; reset for a new scope or deliberate refresh. */
  private displayOrderScope: string = '';
  private displayEntryKeys: string[] = [];
  private displayProjectKeys: string[] = [];
  private keyboardWindow: window.Window | null = null;
  private keyboardHeightListening: boolean = false;
  private avoidAreaListening: boolean = false;
  private avoidAreaListener: (options: window.AvoidAreaOptions) => void =
    (options: window.AvoidAreaOptions): void => {
      if (options.type === window.AvoidAreaType.TYPE_KEYBOARD) return;
      const wasSplit = this.splitLayoutEnabled();
      this.refreshSafeWindowMetrics();
      this.handleSplitLayoutChange(wasSplit);
    };
  private windowStatusListener: (status: window.WindowStatusType) => void =
    (_status: window.WindowStatusType): void => {
      const wasSplit = this.splitLayoutEnabled();
      this.refreshSafeWindowMetrics();
      this.handleSplitLayoutChange(wasSplit);
    };
  private keyboardHeightListener: (height: number) => void = (height: number): void => {
    // 输入法出现时 ArkUI 可能按当前焦点重新应用页面级避让。展开分栏与窄屏新建草稿
    // 都由业务内容消费一次键盘高度，避免系统 OFFSET 只托起光标却遮住 Composer 工具栏。
    if (this.splitLayoutEnabled() || this.newSessionDraftOpen) {
      this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.NONE);
    }
    this.keyboardHeight = Math.max(0, this.getUIContext().px2vp(height));
  };
  private listTabController: HdsTabsController = new HdsTabsController();
  private projectsScroller: Scroller = new Scroller();
  private dialoguesScroller: Scroller = new Scroller();
  private usageScroller: Scroller = new Scroller();
  private automationsScroller: Scroller = new Scroller();
  private listTabsAppeared: boolean = false;
  private floatingBarHidden: boolean = false;
  /** 正数表示向列表末尾浏览，负数表示回看上方；方向改变时重新累计。 */
  private floatingBarScrollIntent: number = 0;
  private floatingBarScrolling: boolean = false;
  private initialListTabIndex: number = 0;
  private residentAccountEpoch: number = -1;
  private residentSessionStatuses: Map<string, string> = new Map();
  aboutToAppear(): void {
    this.pageLifecycleGeneration += 1;
    this.resetDisplayOrder();
    this.pageActive = true;
    this.singlePaneNavigationPending = false;
    this.taskListReconcileGeneration += 1;
    this.residentAccountEpoch = AppServices.instance.auth.sessionEpoch;
    if (!this.routeParamsInitialized) {
      const params = (router.getParams() ?? {}) as Record<string, Object>;
      this.selectedDeviceId = readStr(params, 'deviceId');
      this.selectedSessionDeviceId = readStr(params, 'deviceId');
      this.selectedSessionId = readStr(params, 'sessionId');
      this.routeParamsInitialized = true;
    }
    const splitRouteSelection = consumeTaskSplitRouteSelection();
    if (splitRouteSelection !== null) {
      this.selectedDeviceId = splitRouteSelection.deviceId;
      this.selectedSessionDeviceId = splitRouteSelection.deviceId;
      this.selectedSessionId = splitRouteSelection.sessionId;
      this.selectedMessageClientId = splitRouteSelection.messageClientId;
      this.selectedMessageRevision += 1;
    }
    this.hydratePreferences();
    this.initialListTabIndex = this.listTabIndex(this.activeListTab);
    this.connectionStatus = AppServices.instance.client.getStatus();
    this.restoreTeammateView();
    this.refreshTeammates();
    // KeyboardAvoidMode 是 UIContext 级状态；从新建页等单栏页面返回时，
    // 必须按当前主从布局重新声明，不能沿用上一页的 OFFSET。
    this.updateKeyboardAvoidance();
    void this.observeKeyboardHeight();

    this.unsubs.push(AppServices.instance.tasks.onChanged(() => {
      this.refreshProjection();
    }));
    this.unsubs.push(AppServices.instance.teammateRoster.onChanged((device: string): void => {
      this.scheduleTeammateRead(device);
    }));
    this.unsubs.push(AppServices.instance.taskProjectAliases.onChanged(() => this.refreshProjection()));
    this.unsubs.push(AppServices.instance.auth.onChanged(() => {
      this.syncResidentAccount();
      this.resetPluginIconOwner();
      this.prefetchPluginIcons(this.entries, this.devices);
    }));
    this.unsubs.push(AppServices.instance.interactions.onChanged(() => {
      this.refreshProjection();
    }));
    this.unsubs.push(AppServices.instance.messages.onRunningStateChanged(() => {
      this.refreshProjection();
    }));
    this.unsubs.push(AppServices.instance.taskProjectOrder.onChanged((deviceId: string) => {
      if (deviceId !== this.selectedDeviceId) return;
      const snapshot = AppServices.instance.taskProjectOrder.snapshot(deviceId);
      this.projectOrderHostLoaded = snapshot !== undefined;
      this.projectOrderHostAvailable = this.isUsableHostProjectOrder(snapshot);
      this.projectOrderPendingKeys = [];
      this.projectOrderSyncing = false;
      this.refreshProjection();
    }));
    this.unsubs.push(AppServices.instance.onStatus((status: string) => {
      this.connectionStatus = status;
      if (status !== 'online') {
        this.pluginIconTargets = '';
        this.pluginIconGeneration++;
      } else {
        this.prefetchPluginIcons(this.entries, this.devices);
      }
      if (status === 'online') {
        if (this.selectedDeviceId.length > 0) void this.refreshProjectOrderForScope();
        this.refreshTeammates();
      } else {
        // 连接代次变化时，旧主机快照不能继续作为当前正本；页面暂时使用本机投影。
        this.projectOrderScopeGeneration += 1;
        this.projectOrderHostLoaded = false;
        this.projectOrderHostAvailable = true;
        this.projectOrderPendingKeys = [];
        this.projectOrderSyncing = false;
        this.refreshProjection();
      }
    }));
    this.unsubs.push(AppServices.instance.onModulePush((_device: string, channel: string,
      payload: Object | undefined): void => {
      if (channel !== 'app-foreground') return;
      this.pluginIconTargets = '';
      this.pluginIconGeneration++;
      if (payload === true) {
        this.prefetchPluginIcons(this.entries, this.devices);
        this.refreshTeammates();
      }
    }));
    this.unsubs.push(AppServices.instance.onDeepLink(() => {
      this.tryOpenPendingDeepLink();
    }));

    this.refreshProjection();
    void this.refreshProjectOrderForScope();
    AppServices.instance.syncSessionSubscriptions();
    // Mobile 同源语义：进入列表先做一轮权威对账；push 仍是实时主路径。
    void this.refreshTaskList(false);
    this.clockTimer = setInterval(() => {
      this.now = Date.now();
    }, 60_000);
    // best-effort push 可能在弱网/订阅恢复窗口丢失；前台可见时低频补拉最终收敛。
    this.taskListReconcileTimer = setInterval(() => {
      this.reconcileTaskLists();
    }, TASK_LIST_RECONCILE_INTERVAL_MS);
  }

  aboutToDisappear(): void {
    this.pageLifecycleGeneration += 1;
    this.pageActive = false;
    this.pluginIconTargets = '';
    this.pluginIconGeneration++;
    this.residentPanes = [];
    this.taskListReconcileGeneration += 1;
    this.cancelTaskSearch();
    for (const unsubscribe of this.unsubs) {
      unsubscribe();
    }
    this.unsubs = [];
    if (this.clockTimer >= 0) {
      clearInterval(this.clockTimer);
      this.clockTimer = -1;
    }
    if (this.taskListReconcileTimer >= 0) {
      clearInterval(this.taskListReconcileTimer);
      this.taskListReconcileTimer = -1;
    }
    this.taskListLoadInFlight.clear();
    this.taskListReconcileBackoff.clear();
    this.refreshing = false;
    this.sessionActionBusy = false;
    this.stopKeyboardHeightObservation();
    this.keyboardHeight = 0;
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);
    this.listTabsAppeared = false;
    this.floatingBarHidden = false;
    void AppServices.instance.taskListPreferences.flush();
    this.scopeMenuOpen = false;
    this.sortMenuOpen = false;
    this.taskSearchFilterOpen = false;
    this.projectOrderScopeGeneration += 1;
    this.projectOrderPendingKeys = [];
    this.projectOrderDraggingKey = '';
    this.clearRosterTimers();
  }

  onBackPress(): boolean {
    if (this.moduleRequest !== null) {
      if (this.moduleRequest.kind === 'project' && requestProjectSettingsClose(this.closeHomeModule)) return true;
      this.closeHomeModule();
      return true;
    }
    if (this.taskSearchFilterOpen) {
      this.closeTaskSearchFilter();
      return true;
    }
    if (this.scopeMenuOpen) {
      this.closeScopeMenu();
      return true;
    }
    if (this.sortMenuOpen) {
      this.closeSortMenu();
      return true;
    }
    if (this.newSessionDraftOpen) {
      if (this.draftComposerBack?.()) return true;
      this.newSessionDraftOpen = false;
      this.updateKeyboardAvoidance();
      this.ensureWideSelection();
      return true;
    }
    if (this.usageOpen) { this.closeUsage(); return true; }
    if (this.listPaneFullscreen && this.splitLayoutEnabled()) {
      this.toggleListPane();
      return true;
    }
    if (this.splitLayoutEnabled()) {
      const key = residentTaskPaneKey(this.residentAccountEpoch, this.selectedSessionDeviceId, this.selectedSessionId);
      return this.residentBackHandlers.get(key)?.() ?? false;
    }
    return false;
  }

  private hydratePreferences(): void {
    if (this.preferencesHydrated) return;
    this.preferencesHydrated = true;
    const prefs = AppServices.instance.taskListPreferences.read();
    if (this.selectedDeviceId.length === 0) this.selectedDeviceId = prefs.selectedDeviceId;
    this.selectedDeviceNameHint = prefs.selectedDeviceName;
    this.activeListTab = prefs.activeListTab as TaskListCategory;
    this.sortMode = prefs.sortMode as TaskListSortMode;
    this.searchQuery = prefs.searchQuery;
    this.searchOpen = prefs.searchQuery.length > 0;
    this.projectOrderMode = prefs.projectOrder === 'custom' ? 'custom' : 'activity';
    this.projectManualOrder = prefs.manualProjectOrder.slice();
    this.savedOpenProjectKeys = prefs.openProjectKeys.slice();
    this.expandedProjectKeys = prefs.fullyExpandedProjectKeys.slice();
    this.pinnedCollapsed = prefs.pinnedCollapsed;
  }

  private persistPreferences(): void {
    if (!this.preferencesHydrated) return;
    const prefs = new TaskListPreferences();
    prefs.selectedDeviceId = this.selectedDeviceId;
    prefs.selectedDeviceName = this.selectedDeviceLabel();
    prefs.activeListTab = this.activeListTab;
    prefs.sortMode = this.sortMode;
    prefs.searchQuery = this.searchQuery.slice(0, 256);
    prefs.projectOrder = this.projectOrderMode;
    prefs.manualProjectOrder = this.projectManualOrder.slice();
    const groups = this.projectGroups();
    for (let i = 0; i < groups.length; i++) {
      if (!this.projectCollapsed(groups[i].key)) prefs.openProjectKeys.push(groups[i].key);
    }
    prefs.fullyExpandedProjectKeys = this.expandedProjectKeys.slice();
    prefs.pinnedCollapsed = this.pinnedCollapsed;
    AppServices.instance.taskListPreferences.save(prefs);
  }

  private resetDisplayOrder(scope: string = ''): void {
    this.displayOrderScope = scope;
    this.displayEntryKeys = [];
    this.displayProjectKeys = [];
  }

  private refreshProjection(): void {
    this.syncResidentAccount();
    if (AppServices.instance.taskAccountTransition.active) {
      this.devices = [];
      this.entries = [];
      return;
    }
    const devices = AppServices.instance.tasks.deviceList;
    this.reconcileTeammateDevices(devices);
    const next: TaskListEntry[] = [];
    for (let deviceIndex = 0; deviceIndex < devices.length; deviceIndex++) {
      const device = devices[deviceIndex];
      if (!device.remoteControlEnabled) continue;
      const sessions = AppServices.instance.tasks.getSessions(device.deviceId);
      for (let sessionIndex = 0; sessionIndex < sessions.length; sessionIndex++) {
        const session = sessions[sessionIndex];
        if (session.status === 'deleted') continue;
        const entry = new TaskListEntry();
        entry.key = `${device.deviceId}:${session.id}`;
        entry.deviceId = device.deviceId;
        entry.deviceName = this.displayDeviceName(device.deviceId, device.deviceName, devices);
        entry.session = session;
        if (session.orcaRole === 'worker') continue;
        next.push(entry);
      }
    }
    if (this.sortMode !== 'default') {
      next.sort((a: TaskListEntry, b: TaskListEntry) => {
        const result = compareTaskSessionsForList(a.session, b.session, this.sortMode);
        if (result !== 0) return result;
        return a.key.localeCompare(b.key);
      });
    }
    const scope = JSON.stringify([AppServices.instance.auth.cacheAccountId, this.selectedDeviceId,
      this.activeListTab, this.sortMode, this.searchOpen ? this.searchQuery : '']);
    if (scope !== this.displayOrderScope) this.resetDisplayOrder(scope);
    const byKey = new Map<string, TaskListEntry>();
    for (const entry of next) byKey.set(entry.key, entry);
    this.displayEntryKeys = stableTaskKeys(next.map((entry: TaskListEntry) => entry.key), this.displayEntryKeys);
    const stable: TaskListEntry[] = [];
    for (const key of this.displayEntryKeys) {
      const entry = byKey.get(key);
      if (entry !== undefined) stable.push(entry);
    }
    this.devices = devices;
    this.updateTeammateProjection();
    this.entries = stable;
    this.prefetchPluginIcons(stable, devices);
    const groups = this.projectGroupsFrom(stable);
    this.displayProjectKeys = groups.map((group: TaskProjectGroup) => group.key);
    this.pruneResidentPanes();
    this.reconcileTaskSearchProjectKeys();
    this.collapseProjectGroupsOnce();
    this.ensureWideSelection();
    // 选中的已删除任务要等 ensureWideSelection 换走选择后才能释放。
    this.pruneResidentPanes();
    this.tryOpenPendingDeepLink();
    // 运行中的任务每隔几秒就推送一次活动；只有搜索条件或范围变化才重搜，
    // 否则结果会被反复清空、重新请求，点结果后的定位也会被挤在请求队列后面。
    if (this.taskSearchActive() && this.taskSearchInputsKey() !== this.lastTaskSearchKey) {
      this.scheduleTaskSearch();
    }
  }

  /**
   * 首次拿到会话数据时让各项目组默认收起；之后的数据刷新不覆盖用户手动展开的状态。
   */
  private collapseProjectGroupsOnce(): void {
    if (this.projectCollapseInitialized) return;
    if (this.entries.length === 0) return;
    this.projectCollapseInitialized = true;
    const keys: string[] = [];
    for (const group of this.projectGroups()) keys.push(group.key);
    this.collapsedProjectKeys = keys.filter((key: string) => this.savedOpenProjectKeys.indexOf(key) < 0);
  }

  /** 释放已删除或刚被归档的常驻任务，判定规则见 residentPaneSurvives。 */
  private pruneResidentPanes(): void {
    this.residentPanes = this.residentPanes.filter((pane: ResidentTaskPane): boolean => {
      const sessions = AppServices.instance.tasks.getSessions(pane.deviceId);
      const session = sessions.find((item: RemoteSession): boolean => item.id === pane.sessionId);
      const previous = this.residentSessionStatuses.get(pane.key);
      const selected = pane.deviceId === this.selectedSessionDeviceId && pane.sessionId === this.selectedSessionId;
      const survives = residentPaneSurvives(previous, session?.status, sessions.length, selected);
      if (session !== undefined) this.residentSessionStatuses.set(pane.key, session.status);
      else if (!survives) this.residentSessionStatuses.delete(pane.key);
      return survives;
    });
  }

  private ensureWideSelection(): void {
    if (this.usageOpen) return;
    if (AppServices.instance.taskAccountTransition.active) return;
    if (!this.splitLayoutEnabled()) return;
    if (this.newSessionDraftOpen) return;
    if (AppServices.instance.client.hasScopedPeer(this.selectedSessionDeviceId)) return;
    if (this.teammateSessionKeys.has(this.selectedTaskKey())) {
      this.rememberSelectedTask();
      return;
    }
    if (this.taskSearchActive()) {
      // 搜索请求尚未完成时保留当前详情，避免每次输入一个字符右栏闪空；
      // 结果落地后再按当前 Tab 选择首条搜索结果。
      if (this.taskSearchStatus !== 'ready') return;
      const results = this.taskSearchResultsForCategory(this.activeListTab);
      for (let i = 0; i < results.length; i++) {
        if (results[i].deviceId === this.selectedSessionDeviceId
          && results[i].session.id === this.selectedSessionId) {
          this.rememberSelectedTask();
          return;
        }
      }
      if (results.length === 0) {
        this.selectedSessionDeviceId = '';
        this.selectedSessionId = '';
        this.selectedMessageClientId = '';
        return;
      }
      this.setSelectedTask(results[0].deviceId, results[0].session.id, results[0].contentMessageClientId);
      return;
    }
    const scoped = this.activeListEntries();
    for (let i = 0; i < scoped.length; i++) {
      if (scoped[i].deviceId === this.selectedSessionDeviceId
        && scoped[i].session.id === this.selectedSessionId) {
        this.rememberSelectedTask();
        return;
      }
    }
    if (scoped.length === 0) {
      this.selectedSessionDeviceId = '';
      this.selectedSessionId = '';
      this.selectedMessageClientId = '';
      return;
    }
    this.setSelectedTask(scoped[0].deviceId, scoped[0].session.id, '');
  }

  private handleAreaChange(_oldArea: Area, newArea: Area): void {
    const widthValue = newArea.width;
    const heightValue = newArea.height;
    const width = typeof widthValue === 'number' ? widthValue : 0;
    const height = typeof heightValue === 'number' ? heightValue : 0;
    if (!Number.isFinite(width) || width <= 0 || !Number.isFinite(height) || height <= 0) return;
    if (width === this.viewportWidth && height === this.viewportHeight) return;
    const wasSplit = this.splitLayoutEnabled();
    this.viewportWidth = width;
    this.viewportHeight = height;
    this.refreshSafeWindowMetrics();
    this.handleSplitLayoutChange(wasSplit);
  }

  private handleSplitLayoutChange(wasSplit: boolean): void {
    const splitEnabled = this.splitLayoutEnabled();
    if (splitEnabled) this.ensureWideSelection();
    const wasListFullscreen = this.listPaneFullscreen;
    if (wasSplit && !splitEnabled) {
      this.residentPanes = [];
      this.listPaneCollapsed = false;
      this.listPaneFullscreen = false;
      this.resetDividerTouch();
    }
    if (wasSplit && !splitEnabled && !this.newSessionDraftOpen && !wasListFullscreen && !this.usageOpen) {
      void this.openSelectedTaskAfterSplitExit();
    }
    this.updateKeyboardAvoidance();
  }

  /** 折叠或横转竖退出双栏时，保持用户正在查看的任务详情，而不是退回列表。 */
  private async openSelectedTaskAfterSplitExit(): Promise<void> {
    if (this.singlePaneNavigationPending || this.newSessionDraftOpen) return;
    const lifecycleGeneration = this.pageLifecycleGeneration;
    if (!this.pageActive) return;
    const deviceId = this.selectedSessionDeviceId;
    const sessionId = this.selectedSessionId;
    const messageClientId = this.selectedMessageClientId;
    this.singlePaneNavigationPending = true;
    try {
      if (deviceId.length === 0 || sessionId.length === 0) return;
      if (messageClientId.length > 0) {
        await router.pushUrl({
          url: 'pages/TaskPage',
          params: {
            deviceId: deviceId,
            sessionId: sessionId,
            message: messageClientId,
          },
        });
      } else {
        await router.pushUrl({
          url: 'pages/TaskPage',
          params: {
            deviceId: deviceId,
            sessionId: sessionId,
          },
        });
      }
    } finally {
      if (lifecycleGeneration === this.pageLifecycleGeneration) {
        this.singlePaneNavigationPending = false;
      }
    }
  }

  private splitLayoutEnabled(): boolean {
    const safe = this.safeWindowSize();
    return isWideTaskLayout(this.viewportWidth, safe.width, safe.height, this.safeWindowMultiWindow);
  }

  private refreshSafeWindowMetrics(): void {
    if (this.keyboardWindow === null) return;
    try {
      const metrics = readTaskWindowMetrics(this.keyboardWindow, (value: number): number =>
        this.getUIContext().px2vp(value));
      this.safeWindowWidth = metrics.safeWidth;
      this.safeWindowHeight = metrics.safeHeight;
      this.safeWindowMultiWindow = metrics.multiWindow;
      this.safeWindowMetricsUnavailable = false;
    } catch (_error) {
      this.safeWindowMetricsUnavailable = true;
    }
  }

  /** 读取窗口失败时退回页面尺寸判断分栏；状态翻转需按普通布局变化处理。 */
  private markSafeWindowMetricsUnavailable(): void {
    if (this.safeWindowMetricsUnavailable) return;
    const wasSplit = this.splitLayoutEnabled();
    this.safeWindowMetricsUnavailable = true;
    this.handleSplitLayoutChange(wasSplit);
  }

  private safeWindowSize(): TaskSafeWindowSize {
    return effectiveTaskSafeWindow(this.viewportWidth, this.viewportHeight,
      this.safeWindowWidth, this.safeWindowHeight, this.safeWindowMetricsUnavailable);
  }

  private updateKeyboardAvoidance(): void {
    if (this.splitLayoutEnabled() || this.newSessionDraftOpen) {
      this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.NONE);
      void this.observeKeyboardHeight();
      return;
    }
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);
    this.keyboardHeight = 0;
  }

  private async observeKeyboardHeight(): Promise<void> {
    if (this.keyboardHeightListening) return;
    const hostContext = this.getUIContext().getHostContext();
    if (hostContext === undefined) {
      this.markSafeWindowMetricsUnavailable();
      return;
    }
    try {
      const hostWindow = await window.getLastWindow(hostContext);
      if (!this.pageActive || this.keyboardHeightListening) return;
      this.keyboardWindow = hostWindow;
      hostWindow.on('keyboardHeightChange', this.keyboardHeightListener);
      this.keyboardHeightListening = true;
      try {
        hostWindow.on('avoidAreaChange', this.avoidAreaListener);
        this.avoidAreaListening = true;
      } catch (_error) {
        this.avoidAreaListening = false;
      }
      try {
        hostWindow.on('windowStatusChange', this.windowStatusListener);
        this.windowStatusListening = true;
      } catch (_error) {
        this.windowStatusListening = false;
      }
      const wasSplit = this.splitLayoutEnabled();
      this.refreshSafeWindowMetrics();
      this.handleSplitLayoutChange(wasSplit);
    } catch (_err) {
      this.markSafeWindowMetricsUnavailable();
      // 监听不可用时宁可回退为全页避让，也不能让输入框被键盘遮住。
      if (this.pageActive && (this.splitLayoutEnabled() || this.newSessionDraftOpen)) {
        this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);
      }
    }
  }

  private stopKeyboardHeightObservation(): void {
    if (this.keyboardWindow === null) return;
    try {
      if (this.keyboardHeightListening) this.keyboardWindow.off('keyboardHeightChange', this.keyboardHeightListener);
      if (this.avoidAreaListening) this.keyboardWindow.off('avoidAreaChange', this.avoidAreaListener);
      if (this.windowStatusListening) this.keyboardWindow.off('windowStatusChange', this.windowStatusListener);
    } catch (_err) {
      // 页面退出时监听已被系统清理，不影响后续路由恢复默认避让。
    }
    this.keyboardWindow = null;
    this.keyboardHeightListening = false;
    this.avoidAreaListening = false;
    this.windowStatusListening = false;
  }

  private floatingBarBottomMargin(): number {
    // HdsTabs 已按系统安全区定位，业务层只保留视觉间距，不能重复叠加手势区高度。
    return FLOATING_BAR_BOTTOM_MARGIN;
  }

  private floatingBarContentInset(): number {
    return FLOATING_BAR_CONTENT_INSET;
  }

  private detailComposerBottomInset(): number {
    return FLOATING_BAR_BOTTOM_MARGIN;
  }

  private detailKeyboardInset(): number {
    const safe = this.safeWindowSize();
    return taskDetailKeyboardInset(this.viewportWidth, safe.width, safe.height, this.keyboardHeight,
      this.safeWindowMultiWindow);
  }

  private newSessionKeyboardInset(): number {
    // 宽屏继续只抬右栏；窄屏草稿覆盖整页时直接消费实际键盘高度，
    // 确保正文、工具栏和发送按钮作为完整 Composer 一起停在键盘上方。
    return this.splitLayoutEnabled() ? this.detailKeyboardInset() : this.keyboardHeight;
  }

  private listPaneWidth(): number {
    if (this.listPaneFullscreen && !this.newSessionDraftOpen) return this.viewportWidth;
    return taskListPaneWidth(this.viewportWidth, this.requestedListPaneWidth);
  }

  private detailPaneWidth(): number {
    if (!this.listPaneShown() && !this.usageOpen) return this.viewportWidth;
    return taskDetailPaneWidth(this.viewportWidth, this.requestedListPaneWidth);
  }

  /**
   * 列表是否可见。没有选中任务或正在新建任务时必须显示列表，否则详情栏没有收起按钮，
   * 用户会被困在没有任务列表的界面里。
   */
  private listPaneShown(): boolean {
    return !this.splitLayoutEnabled() || !this.listPaneCollapsed
      || this.selectedTaskKey().length === 0 || this.newSessionDraftOpen;
  }

  private toggleListPane(): void {
    if (!this.splitLayoutEnabled()) return;
    uiAnimateState(this.getUIContext(), () => {
      if (this.listPaneFullscreen) {
        this.listPaneFullscreen = false;
        this.listPaneCollapsed = false;
      } else {
        this.listPaneCollapsed = !this.listPaneCollapsed;
      }
    });
  }

  private selectedTaskKey(): string {
    if (this.selectedSessionDeviceId.length === 0 || this.selectedSessionId.length === 0) return '';
    return `${this.selectedSessionDeviceId}:${this.selectedSessionId}`;
  }

  private rememberSelectedTask(): void {
    if (AppServices.instance.taskAccountTransition.active || !this.splitLayoutEnabled()) return;
    const key = residentTaskPaneKey(this.residentAccountEpoch, this.selectedSessionDeviceId, this.selectedSessionId);
    const last = this.residentPanes[this.residentPanes.length - 1];
    if (last !== undefined && last.key === key && last.messageClientId === this.selectedMessageClientId) return;
    this.residentPanes = rememberResidentTaskPane(this.residentPanes, this.residentAccountEpoch,
      this.selectedSessionDeviceId, this.selectedSessionId, this.selectedMessageClientId);
    const sessions = AppServices.instance.tasks.getSessions(this.selectedSessionDeviceId);
    const session = sessions.find((item: RemoteSession): boolean => item.id === this.selectedSessionId);
    if (session !== undefined) this.residentSessionStatuses.set(key, session.status);
    const kept = new Set<string>(this.residentPanes.map((pane: ResidentTaskPane): string => pane.key));
    this.residentSessionStatuses.forEach((_status: string, identity: string): void => {
      if (!kept.has(identity)) this.residentSessionStatuses.delete(identity);
    });
  }

  private syncResidentAccount(): void {
    const epoch = AppServices.instance.auth.sessionEpoch;
    if (epoch === this.residentAccountEpoch) return;
    this.residentAccountEpoch = epoch;
    this.closeUsage();
    this.moduleRequest = null;
    this.teammateRoster = [];
    this.updateTeammateProjection(true);
    this.clearRosterTimers();
    if (this.pageActive) this.restoreTeammateView();
    this.residentPanes = [];
    this.residentSessionStatuses.clear();
    this.selectedSessionDeviceId = '';
    this.selectedSessionId = '';
    this.selectedMessageClientId = '';
    this.cancelTaskSearch();
    if (AppServices.instance.taskAccountTransition.active) {
      this.selectedDeviceId = '';
      this.taskSearchProjectKeys = [];
      this.taskListReconcileGeneration += 1;
      this.taskListLoadInFlight.clear();
      this.taskListReconcileBackoff.clear();
      this.projectOrderScopeGeneration += 1;
    }
  }

  private setSelectedTask(deviceId: string, sessionId: string, messageClientId: string): void {
    if (AppServices.instance.taskAccountTransition.active) return;
    this.listPaneFullscreen = false;
    this.closeUsage();
    this.moduleRequest = null;
    this.selectedSessionDeviceId = deviceId;
    this.selectedSessionId = sessionId;
    this.selectedMessageClientId = messageClientId;
    this.selectedMessageRevision += 1;
    this.rememberSelectedTask();
  }

  private paneSelected(pane: ResidentTaskPane): boolean {
    return this.moduleRequest === null && !this.newSessionDraftOpen && pane.deviceId === this.selectedSessionDeviceId
      && pane.sessionId === this.selectedSessionId;
  }

  private entrySelected(entry: TaskListEntry): boolean {
    return this.splitLayoutEnabled() && !this.newSessionDraftOpen
      && entry.deviceId === this.selectedSessionDeviceId
      && entry.session.id === this.selectedSessionId;
  }

  private selectSession(entry: TaskListEntry): void {
    this.closeUsage();
    this.newSessionDraftOpen = false;
    this.updateKeyboardAvoidance();
    this.setSelectedTask(entry.deviceId, entry.session.id, '');
  }

  private tryOpenUsageCard(): void {
    const target = AppServices.instance.consumeUsageCardTarget();
    if (target === null) return;
    this.moduleRequest = null;
    this.newSessionDraftOpen = false;
    this.activeUsageCardId = target.formId;
    this.selectedDeviceId = target.deviceId;
    this.openUsage();
  }

  private usageCardScopeChanged(): void {
    if (!this.activeUsageCardId || !this.usageOpen) return;
    const device = this.selectedDeviceId;
    if (device && !AppServices.instance.tasks.deviceList.some((row: PresenceSnapshot): boolean =>
      row.deviceId === device && row.remoteControlEnabled)) return;
    void AppServices.instance.usageCards?.configure(this.activeUsageCardId, device).catch((): void => {});
  }

  private tryOpenPendingDeepLink(): void {
    const shared = AppServices.instance.consumeSharedTaskOpen();
    if (shared !== null) {
      this.moduleRequest = null; this.newSessionDraftOpen = false;
      this.setSelectedTask(shared.peer, shared.sessionId, '');
      if (!this.splitLayoutEnabled()) void router.pushUrl({ url: 'pages/TaskPage', params: { deviceId: shared.peer, sessionId: shared.sessionId } });
      return;
    }
    const invitation = AppServices.instance.consumeModuleInvitation();
    if (invitation !== null) {
      const request = new HomeModuleRequest(); request.kind = invitation.kind; request.invitation = invitation.invitation;
      request.deviceId = this.moduleDevice(); this.newSessionDraftOpen = false; this.moduleRequest = request; return;
    }
    this.tryOpenUsageCard();
    if (AppServices.instance.hasPendingRelayLink()) {
      void router.pushUrl({ url: 'pages/SettingsPage' });
      return;
    }
    if (AppServices.instance.taskAccountTransition.active) return;
    const intent = AppServices.instance.peekPendingDeepLink();
    if (intent === null) return;
    const devices = AppServices.instance.tasks.deviceList;
    let deviceId = '';
    let targetSession: RemoteSession | null = null;
    for (let i = 0; i < devices.length && deviceId.length === 0; i++) {
      const sessions = AppServices.instance.tasks.getSessions(devices[i].deviceId);
      for (let sessionIndex = 0; sessionIndex < sessions.length; sessionIndex++) {
        if (sessions[sessionIndex].id !== intent.sessionId) continue;
        deviceId = devices[i].deviceId;
        targetSession = sessions[sessionIndex];
        break;
      }
    }
    if (deviceId.length === 0 || targetSession === null) return;
    AppServices.instance.consumePendingDeepLink();
    if (this.splitLayoutEnabled()) {
      this.setActiveListTab(taskListCategory(targetSession));
      if (this.selectedDeviceId.length > 0) this.selectedDeviceId = deviceId;
      this.setSelectedTask(deviceId, intent.sessionId, intent.messageClientId);
      this.persistPreferences();
      return;
    }
    router.pushUrl({
      url: 'pages/TaskPage',
      params: {
        deviceId: deviceId,
        sessionId: intent.sessionId,
        message: intent.messageClientId,
      },
    });
  }

  private openUsage(): void {
    this.moduleRequest = null;
    this.newSessionDraftOpen = false;
    this.listPaneFullscreen = false;
    this.usageOpen = true;
    this.updateKeyboardAvoidance();
  }

  private closeUsage(): void {
    this.usageOpen = false;
    this.activeUsageCardId = '';
  }

  private sidebarCategory(): TaskListCategory { return this.activeListTab; }

  private setActiveListTab(tab: TaskListCategory): void {
    this.moduleRequest = null;
    this.closeUsage();
    const index = this.listTabIndex(tab);
    if (this.activeListTab !== tab) {
      this.floatingBarScrolling = false;
      this.floatingBarScrollIntent = 0;
    }
    this.activeListTab = tab;
    if (!this.listTabsAppeared) {
      this.initialListTabIndex = index;
      return;
    }
    this.listTabController.changeIndex(index);
  }

  private listTabIndex(tab: TaskListCategory): number {
    if (tab === 'dialogues') return 1;
    if (tab === 'automations') return 2;
    return 0;
  }

  private listTabCategory(index: number): TaskListCategory {
    if (index === 1) return 'dialogues';
    if (index === 2) return 'automations';
    return 'projects';
  }

  private handleListTabChange(index: number): void {
    const category = this.listTabCategory(index);
    if (category === this.activeListTab) return;
    this.closeUsage();
    this.activeListTab = category;
    this.floatingBarScrolling = false;
    this.floatingBarScrollIntent = 0;
    const visibleCount = this.taskSearchActive()
      ? this.taskSearchResultsForCategory(category).length
      : this.scopedEntries().length;
    if (visibleCount === 0) this.showFloatingBar();
    else this.restoreFloatingBarAtBoundary(category);
    this.ensureWideSelection();
    this.persistPreferences();
  }

  private handleListTabsAppear(): void {
    this.listTabsAppeared = true;
    this.listTabController.changeIndex(this.listTabIndex(this.activeListTab));
    // HdsTabsController 会保留上一次动画状态；每次进入页面都明确恢复默认显示态。
    this.floatingBarHidden = false;
    this.floatingBarScrolling = false;
    this.floatingBarScrollIntent = 0;
    this.listTabController.applyShowAnimation(HdsAnimationMode.SCROLL_ANIMATION);
  }

  private scrollerForCategory(category: TaskListCategory): Scroller {
    if (category === 'dialogues') return this.dialoguesScroller;
    if (category === 'automations') return this.automationsScroller;
    return this.projectsScroller;
  }

  private isFloatingBarScrollSource(category: TaskListCategory): boolean {
    return this.pageActive && this.activeListTab === category;
  }

  private restoreFloatingBarAtBoundary(category: TaskListCategory): void {
    if (!this.isFloatingBarScrollSource(category) || this.floatingBarScrolling) return;
    const scroller = this.scrollerForCategory(category);
    if (taskListShouldShowFloatingBarAtBoundary(scroller.currentOffset().yOffset, scroller.isAtEnd())) {
      this.showFloatingBar();
    }
  }

  private handleTaskListScrollStart(category: TaskListCategory): void {
    if (!this.isFloatingBarScrollSource(category)) return;
    this.floatingBarScrolling = true;
    this.floatingBarScrollIntent = 0;
  }

  private handleTaskListScrollStop(category: TaskListCategory): void {
    if (!this.isFloatingBarScrollSource(category)) return;
    this.floatingBarScrolling = false;
    this.floatingBarScrollIntent = 0;
    this.restoreFloatingBarAtBoundary(category);
  }

  private handleTaskListScroll(
    category: TaskListCategory,
    scrollOffset: number,
    scrollState: ScrollState,
  ): void {
    if (!this.isFloatingBarScrollSource(category) || scrollState !== ScrollState.Scroll
      || Math.abs(scrollOffset) < FLOATING_BAR_SCROLL_NOISE) return;

    // 内容向上为正，回看上方为负。惯性和布局回调不能改变底栏意图。
    if (this.floatingBarScrollIntent * scrollOffset < 0) this.floatingBarScrollIntent = 0;
    this.floatingBarScrollIntent += scrollOffset;
    if (this.floatingBarScrollIntent >= FLOATING_BAR_HIDE_DISTANCE) {
      this.hideFloatingBar();
      this.floatingBarScrollIntent = 0;
    } else if (this.floatingBarScrollIntent <= -FLOATING_BAR_SHOW_DISTANCE) {
      this.showFloatingBar();
      this.floatingBarScrollIntent = 0;
    }
  }

  private handleTaskListDragRelease(category: TaskListCategory, velocity: number): void {
    if (!this.isFloatingBarScrollSource(category) || !this.floatingBarScrolling) return;
    // 快速短甩来不及累计位移时保留方向。边界恢复统一等滚动结束。
    if (velocity >= FLOATING_BAR_FLING_VELOCITY) this.hideFloatingBar();
    else if (velocity <= -FLOATING_BAR_FLING_VELOCITY) this.showFloatingBar();
    this.floatingBarScrollIntent = 0;
  }

  private hideFloatingBar(): void {
    if (this.floatingBarHidden || !this.listTabsAppeared) return;
    this.floatingBarHidden = true;
    this.listTabController.applyHideAnimation(HdsAnimationMode.SCROLL_ANIMATION);
  }

  private showFloatingBar(): void {
    if (!this.floatingBarHidden || !this.listTabsAppeared) return;
    this.floatingBarHidden = false;
    this.listTabController.applyShowAnimation(HdsAnimationMode.SCROLL_ANIMATION);
  }

  private resetDividerTouch(): void {
    this.dividerTouchId = -1;
    this.dividerOverrun = 0;
  }

  private canDragTaskDivider(): boolean {
    return this.splitLayoutEnabled() && !this.listPaneFullscreen && !this.newSessionDraftOpen &&
      this.moduleRequest === null && (this.listPaneShown() || this.usageOpen);
  }

  private handleDividerTouch(event: TouchEvent): void {
    if (event.type === TouchType.Cancel || !this.canDragTaskDivider()) {
      this.resetDividerTouch();
      return;
    }
    if (event.type === TouchType.Down && this.dividerTouchId < 0) {
      const point = event.changedTouches[0];
      if (!point) return;
      this.dividerTouchId = point.id;
      this.dividerTouchStartX = point.displayX;
      this.dividerTouchStartWidth = this.listPaneWidth();
      return;
    }
    const point = event.changedTouches.find((touch: TouchObject): boolean => touch.id === this.dividerTouchId);
    if (!point || (event.type !== TouchType.Move && event.type !== TouchType.Up)) return;
    const drag = taskSplitDrag(this.viewportWidth, this.dividerTouchStartWidth, point.displayX - this.dividerTouchStartX);
    this.requestedListPaneWidth = drag.width;
    const canFocusDetail = this.selectedTaskKey().length > 0 && !this.usageOpen
      && !this.listPaneCollapsed;
    const target = this.usageOpen || (drag.target === 'detail' && !canFocusDetail) ? 'none' : drag.target;
    if (event.type === TouchType.Move) {
      this.dividerOverrun = !this.usageOpen && (canFocusDetail || drag.overrun > 0) ?
        drag.overrun : 0;
      return;
    }
    this.resetDividerTouch();
    if (target === 'detail') this.toggleListPane();
    if (target === 'list') {
      uiAnimateState(this.getUIContext(), () => {
        this.listPaneFullscreen = true;
        this.listPaneCollapsed = false;
      });
    }
  }

  private deviceCanOpen(device: PresenceSnapshot): boolean {
    return device.online && device.remoteControlEnabled;
  }

  private openSession(entry: TaskListEntry): void {
    if (this.bulkMode) {
      this.toggleBulkEntry(entry);
      return;
    }
    this.selectSession(entry);
    if (this.splitLayoutEnabled()) {
      if (entry.session.orcaRole === 'lead' && this.detailPaneWidth() < ORCA_DETAIL_MIN_WIDTH) {
        this.listPaneCollapsed = true;
      }
      return;
    }
    router.pushUrl({
      url: 'pages/TaskPage',
      params: { deviceId: entry.deviceId, sessionId: entry.session.id },
    });
  }

  /** 搜索结果先种入摘要，再异步用 sessions:get 对账；这样旧任务也能立即进入详情。 */
  private openTaskSearchResult(result: TaskSearchResult): void {
    let cached: RemoteSession | undefined = undefined;
    const sessions = AppServices.instance.tasks.getSessions(result.deviceId);
    for (let i = 0; i < sessions.length; i++) {
      if (sessions[i].id === result.session.id) {
        cached = sessions[i];
        break;
      }
    }
    if (cached === undefined) {
      AppServices.instance.tasks.upsertSession(result.deviceId, result.session);
    }
    for (let i = 0; i < this.devices.length; i++) {
      if (this.devices[i].deviceId === result.deviceId && this.deviceCanOpen(this.devices[i])) {
        void AppServices.instance.tasks.loadSession(result.deviceId, result.session.id);
        break;
      }
    }

    const session = cached ?? result.session;
    this.setSelectedTask(result.deviceId, session.id, result.contentMessageClientId);
    this.setActiveListTab(taskListCategory(session));
    this.persistPreferences();
    if (this.splitLayoutEnabled()) return;
    const params: Record<string, Object> = {};
    params['deviceId'] = result.deviceId;
    params['sessionId'] = session.id;
    if (result.contentMessageClientId.length > 0) params['message'] = result.contentMessageClientId;
    void router.pushUrl({ url: 'pages/TaskPage', params });
  }

  private openSettings(): void {
    router.pushUrl({ url: 'pages/SettingsPage' });
  }

  private moduleDevice(): string {
    if (this.selectedDeviceId) return this.selectedDeviceId;
    const available = this.devices.filter((device: PresenceSnapshot): boolean => this.deviceCanOpen(device));
    return available.length === 1 ? available[0].deviceId : '';
  }

  private openModule(kind: string): void {
    const request = new HomeModuleRequest();
    request.kind = kind;
    request.deviceId = this.moduleDevice();
    request.create = kind === 'project';
    if (kind !== 'chat' && kind !== 'shared' && !request.deviceId) {
      uiToast(this.getUIContext(), this.v12String('v139_home_choose_computer'));
      return;
    }
    this.newSessionDraftOpen = false;
    this.moduleRequest = request;
  }

  @Builder
  projectFolderMenu(group: TaskProjectGroup) {
    Menu() {
      if (AppServices.instance.canReadWorkdir(group.deviceId, group.workingDir)) {
        MenuItem({ content: '浏览文件夹' }).onClick((): void => {
          this.projectFolderMenuKey = '';
          this.projectFolderDevice = group.deviceId;
          this.projectFolderRoot = group.workingDir;
          this.projectFolderOpen = true;
        })
      }
      MenuItem({ content: '项目设置' }).onClick((): void => {
        this.projectFolderMenuKey = '';
        this.openProjectSettings(group);
      })
    }
  }

  @Builder
  projectFolderSheet() {
    WorkdirBrowser({
      device: this.projectFolderDevice,
      workdir: this.projectFolderRoot,
      deviceName: this.devices.find((peer: PresenceSnapshot): boolean =>
        peer.deviceId === this.projectFolderDevice)?.deviceName ?? '',
      close: (): void => { this.projectFolderOpen = false; },
    })
  }

  private openProjectSettings(group: TaskProjectGroup): void {
    const request = new HomeModuleRequest();
    request.kind = 'project'; request.deviceId = group.deviceId; request.title = group.title;
    const remoteHost = group.entries[0]?.session.remoteHostId ?? '';
    request.projectKey = remoteHost
      ? 'remote:' + encodeURIComponent(remoteHost) + ':' + group.workingDir : 'local:' + group.workingDir;
    this.newSessionDraftOpen = false; this.moduleRequest = request;
  }

  // 列表顶部不再放文字按钮行（对齐 Mobile 首页）：
  // - 新建项目：新建任务页项目选择器末尾（NewSessionPage → openProjectCreateFromDraft）；
  // - 资源：标题「所有任务」下拉菜单里的「资源」项（scopeMenuContent）；
  // - 群聊：「伙伴」标题行的「+」；共享任务暂不提供首页入口（底层 SharedTasksPanel / SharedTaskRuntime 保留）。

  /** 新建任务页项目选择器的「新建项目」：在草稿上方打开现有新建项目面板，草稿文字和附件保持不变。 */
  private openProjectCreateFromDraft(deviceId: string): void {
    if (deviceId.length === 0) return;
    const request = new HomeModuleRequest();
    request.kind = 'project';
    request.deviceId = deviceId;
    request.create = true;
    this.moduleRequest = request;
  }

  /** 「+ → 新建群聊」选定电脑后，直接进入该电脑的现有新建群聊流程（ChatHomePanel create）。 */
  private openGroupCreate(deviceId: string): void {
    const request = new HomeModuleRequest();
    request.kind = 'chat';
    request.deviceId = deviceId;
    request.createToken = ++this.groupCreateToken;
    this.newSessionDraftOpen = false;
    this.moduleRequest = request;
  }

  /** 「+ → 加入群聊」：链接交给现有邀请预览（ChatInvitePanel），是否加入仍由用户在预览里确认。 */
  private openGroupInvitation(link: string): void {
    const request = new HomeModuleRequest();
    request.kind = 'chat';
    request.invitation = link;
    request.deviceId = this.moduleDevice();
    this.newSessionDraftOpen = false;
    this.moduleRequest = request;
  }

  /** 新建群聊可选的电脑：与 Mobile groupTargets 一致，只列在线且可控制的电脑，不受首页电脑筛选限制。 */
  private companionGroupHosts(): CompanionHostOption[] {
    return this.devices
      .filter((device: PresenceSnapshot): boolean => this.deviceCanOpen(device))
      .map((device: PresenceSnapshot): CompanionHostOption => {
        const option = new CompanionHostOption();
        option.deviceId = device.deviceId;
        option.name = this.displayDeviceName(device.deviceId, device.deviceName);
        return option;
      });
  }

  private openNewSession(): void {
    this.closeUsage();
    this.moduleRequest = null;
    this.newSessionDraftDeviceId = this.selectedDeviceId;
    this.newSessionDraftOpen = true;
    this.updateKeyboardAvoidance();
  }

  /** 菜单开合统一走轻量可见性动效，保证浮层进退场完整播放。 */
  private animateMenu(apply: () => void): void {
    uiAnimateFastState(this.getUIContext(), apply);
  }

  // 系统菜单（bindMenu）自带出入场动效：开关状态直接赋值，不再包 animateTo，避免与系统动效叠加。
  private openDeviceScopeMenu(): void {
    uiOverlayTrace('scope-menu', 'open');
    this.sortMenuOpen = false;
    this.scopeMenuOpen = true;
  }

  private closeScopeMenu(): void {
    this.scopeMenuOpen = false;
  }

  private openSortMenu(): void {
    uiOverlayTrace('sort-menu', 'open');
    this.scopeMenuOpen = false;
    this.sortMenuOpen = true;
  }

  private closeSortMenu(): void {
    this.sortMenuOpen = false;
  }

  private selectSortMode(mode: TaskListSortMode): void {
    this.sortMenuOpen = false;
    this.animateMenu(() => {
      this.sortMode = mode;
    });
    this.resetDisplayOrder();
    this.refreshProjection();
    this.persistPreferences();
  }

  private hostProjectOrderSnapshot(): TaskProjectOrderSnapshot | undefined {
    if (this.selectedDeviceId.length === 0 || !this.projectOrderHostLoaded) return undefined;
    return AppServices.instance.taskProjectOrder.snapshot(this.selectedDeviceId);
  }

  /** 没有 owner stamp 的旧主机只能作为本机排序的旁路数据，不能被写入。 */
  private isUsableHostProjectOrder(snapshot: TaskProjectOrderSnapshot | undefined): boolean {
    return snapshot !== undefined && snapshot.available && snapshot.ownerStamp !== undefined;
  }

  private displayedProjectOrderMode(): TaskProjectOrderMode {
    if (this.projectOrderPendingMode === 'custom') return 'custom';
    if (this.projectOrderPendingMode === 'activity') return 'activity';
    const snapshot = this.hostProjectOrderSnapshot();
    if (this.isUsableHostProjectOrder(snapshot)) {
      return snapshot?.authoritative && snapshot.projectOrder === 'custom' ? 'custom' : 'activity';
    }
    return this.projectOrderMode;
  }

  /** 顺序包含当前筛选范围之外的键，拖动可见项目时会把它们留在原有槽位。 */
  private displayedProjectOrderKeys(): string[] {
    if (this.projectOrderPendingKeys.length > 0) return this.projectOrderPendingKeys.slice();
    const snapshot = this.hostProjectOrderSnapshot();
    if (this.isUsableHostProjectOrder(snapshot)
      && snapshot?.authoritative && snapshot.projectOrder === 'custom') {
      return AppServices.instance.taskProjectOrder.controllerKeys(this.selectedDeviceId);
    }
    if (this.isUsableHostProjectOrder(snapshot)) {
      // 按最近活动时列表不消费手动序，但切换模式仍要把主机已有隐藏键原样带回。
      return AppServices.instance.taskProjectOrder.controllerKeys(this.selectedDeviceId);
    }
    return this.projectManualOrder.slice();
  }

  private projectOrderVisibleKeys(groups: TaskProjectGroup[] = this.projectGroups()): string[] {
    const keys: string[] = [];
    for (let i = 0; i < groups.length; i++) keys.push(groups[i].key);
    return keys;
  }

  private projectOrderProjects(): TaskProjectOrderProject[] {
    const groups = this.projectGroupsFrom(this.deviceScopedEntries());
    const projects: TaskProjectOrderProject[] = [];
    for (let i = 0; i < groups.length; i++) {
      const project = new TaskProjectOrderProject();
      project.key = groups[i].key;
      project.deviceId = groups[i].deviceId;
      project.workingDir = groups[i].workingDir;
      projects.push(project);
    }
    return projects;
  }

  private async refreshProjectOrderForScope(): Promise<void> {
    const generation = ++this.projectOrderScopeGeneration;
    const deviceId = this.selectedDeviceId;
    this.projectOrderPendingMode = '';
    this.projectOrderPendingKeys = [];
    this.projectOrderSyncing = false;
    if (deviceId.length === 0) {
      this.projectOrderHostLoaded = true;
      this.projectOrderHostAvailable = true;
      this.refreshProjection();
      return;
    }

    const cached = AppServices.instance.taskProjectOrder.snapshot(deviceId);
    this.projectOrderHostLoaded = cached !== undefined;
    this.projectOrderHostAvailable = this.isUsableHostProjectOrder(cached);
    this.refreshProjection();
    const result = await AppServices.instance.taskProjectOrder.fetch(deviceId);
    if (!this.pageActive || generation !== this.projectOrderScopeGeneration
      || deviceId !== this.selectedDeviceId) return;
    const snapshot = result.snapshot
      ?? AppServices.instance.taskProjectOrder.snapshot(deviceId);
    this.projectOrderHostLoaded = snapshot !== undefined;
    this.projectOrderHostAvailable = this.isUsableHostProjectOrder(snapshot);
    this.projectOrderSyncing = false;
    this.refreshProjection();
  }

  private async applyProjectOrderToHost(
    mode: TaskProjectOrderMode,
    order: string[],
  ): Promise<void> {
    const deviceId = this.selectedDeviceId;
    const generation = this.projectOrderScopeGeneration;
    this.projectOrderSyncing = true;
    const result = await AppServices.instance.taskProjectOrder.apply(
      deviceId,
      order,
      this.projectOrderProjects(),
      mode,
    );
    if (!this.pageActive || generation !== this.projectOrderScopeGeneration
      || deviceId !== this.selectedDeviceId) return;
    this.projectOrderSyncing = false;
    this.projectOrderPendingMode = '';
    this.projectOrderPendingKeys = [];
    if (result.kind === 'ok') {
      const snapshot = result.snapshot
        ?? AppServices.instance.taskProjectOrder.snapshot(deviceId);
      this.projectOrderHostLoaded = snapshot !== undefined;
      this.projectOrderHostAvailable = this.isUsableHostProjectOrder(snapshot);
      if (!this.projectOrderHostAvailable) {
        this.projectOrderMode = mode;
        if (mode === 'custom') this.projectManualOrder = order.slice();
        this.persistPreferences();
      }
      this.refreshProjection();
      return;
    }
    if (result.kind === 'unavailable') {
      // 老 Desktop 没有该 channel 时静默转为查看端本机账本，保留用户刚完成的排序。
      this.projectOrderHostLoaded = true;
      this.projectOrderHostAvailable = false;
      this.projectOrderMode = mode;
      if (mode === 'custom') this.projectManualOrder = order.slice();
      this.persistPreferences();
      this.refreshProjection();
      return;
    }
    uiToast(this.getUIContext(), this.v12String('v12_project_order_sync_failed'));
    this.refreshProjection();
  }

  private selectProjectOrderMode(mode: TaskProjectOrderMode): void {
    this.closeSortMenu();
    const visibleKeys = this.projectOrderVisibleKeys();
    if (visibleKeys.length === 0) return;
    const currentOrder = reconcileTaskProjectOrder(
      this.displayedProjectOrderKeys(),
      visibleKeys,
    );
    if (this.isUsableHostProjectOrder(this.hostProjectOrderSnapshot())) {
      this.projectOrderPendingMode = mode;
      this.projectOrderPendingKeys = mode === 'custom' ? currentOrder.slice() : [];
      void this.applyProjectOrderToHost(mode, currentOrder);
      return;
    }
    this.projectOrderMode = mode;
    if (mode === 'custom') this.projectManualOrder = currentOrder;
    this.projectOrderPendingMode = '';
    this.projectOrderPendingKeys = [];
    this.refreshProjection();
    this.persistPreferences();
  }

  private handleProjectOrderTouch(group: TaskProjectGroup, event: TouchEvent): void {
    if (this.displayedProjectOrderMode() !== 'custom' || this.projectOrderSyncing) return;
    if (event.type === TouchType.Cancel) {
      this.projectOrderDraggingKey = '';
      this.projectDragStartIndex = -1;
      this.projectDragMoved = false;
      this.projectOrderPendingKeys = [];
      return;
    }
    if (event.changedTouches.length === 0) return;
    const point = event.changedTouches[0];
    if (event.type === TouchType.Down) {
      const groups = this.projectGroups();
      const index = groups.findIndex((value: TaskProjectGroup) => value.key === group.key);
      if (index < 0) return;
      this.projectDragStartY = point.displayY;
      this.projectDragStartIndex = index;
      this.projectDragStartOrder = reconcileTaskProjectOrder(
        this.displayedProjectOrderKeys(),
        this.projectOrderVisibleKeys(groups),
      );
      this.projectDragMoved = false;
      this.projectOrderDraggingKey = group.key;
      return;
    }
    if (this.projectDragStartIndex < 0) return;
    if (event.type === TouchType.Move) {
      const deltaY = point.displayY - this.projectDragStartY;
      if (!this.projectDragMoved && Math.abs(deltaY) < 8) return;
      this.projectDragMoved = true;
      const groups = this.projectGroups();
      const visibleKeys = this.projectOrderVisibleKeys(groups);
      const targetIndex = Math.max(0, Math.min(
        visibleKeys.length - 1,
        this.projectDragStartIndex + Math.round(deltaY / 52),
      ));
      const next = reorderVisibleTaskProjectOrder(
        this.projectDragStartOrder,
        visibleKeys,
        group.key,
        targetIndex,
      );
      // 触摸已经越过点击阈值，但目标索引可能又回到原位；此时保留原顺序，
      // 不能让松手路径把空数组提交给 Desktop。
      this.projectOrderPendingKeys = next ?? this.projectDragStartOrder.slice();
      return;
    }
    if (event.type === TouchType.Up) {
      const moved = this.projectDragMoved;
      const order = this.projectOrderPendingKeys.length > 0
        ? this.projectOrderPendingKeys.slice() : this.projectDragStartOrder.slice();
      this.projectOrderDraggingKey = '';
      this.projectDragStartIndex = -1;
      this.projectDragMoved = false;
      if (!moved) {
        this.projectOrderPendingKeys = [];
        return;
      }
      this.projectOrderSuppressClick = true;
      if (order.length === 0) {
        this.projectOrderPendingKeys = [];
        return;
      }
      if (this.isUsableHostProjectOrder(this.hostProjectOrderSnapshot())) {
        this.projectOrderPendingMode = 'custom';
        void this.applyProjectOrderToHost('custom', order);
      } else {
        this.projectOrderMode = 'custom';
        this.projectManualOrder = order;
        this.projectOrderPendingKeys = [];
        this.refreshProjection();
        this.persistPreferences();
      }
    }
  }

  private selectDevice(deviceId: string): void {
    this.animateMenu(() => {
      this.selectedDeviceId = deviceId;
      if (this.moduleRequest?.kind === 'chat') {
        const request = new HomeModuleRequest(); request.kind = 'chat'; request.deviceId = deviceId; this.moduleRequest = request;
      }
      this.reconcileTaskSearchProjectKeys();
    });
    this.scopeMenuOpen = false;
    void this.refreshProjectOrderForScope();
    this.ensureWideSelection();
    if (this.taskSearchActive()) this.scheduleTaskSearch();
    this.persistPreferences();
  }

  private selectedDeviceLabel(): string {
    if (this.selectedDeviceId.length === 0) return '所有任务';
    for (let i = 0; i < this.devices.length; i++) {
      if (this.devices[i].deviceId === this.selectedDeviceId) {
        return this.displayDeviceName(this.devices[i].deviceId, this.devices[i].deviceName);
      }
    }
    const resolved = AppServices.instance.tasks.getDeviceName(this.selectedDeviceId);
    return this.displayDeviceName(this.selectedDeviceId, resolved || this.selectedDeviceNameHint);
  }

  private displayDeviceName(deviceId: string, name: string, devices: PresenceSnapshot[] = this.devices): string {
    const names = new Map<string, string>();
    for (const device of devices) names.set(device.deviceId, device.deviceName);
    return deviceDisplayName(deviceId, name, this.v12String('v134_unnamed_computer'), names);
  }

  private deviceScopedEntries(): TaskListEntry[] {
    if (this.selectedDeviceId.length === 0) return this.entries;
    const out: TaskListEntry[] = [];
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].deviceId === this.selectedDeviceId) out.push(this.entries[i]);
    }
    return out;
  }

  private scopedEntries(): TaskListEntry[] {
    const source = this.deviceScopedEntries();
    const out: TaskListEntry[] = [];
    for (let i = 0; i < source.length; i++) {
      const entry = source[i];
      if (!this.entryVisibleInList(entry) || !this.entryMatchesSearch(entry)) continue;
      out.push(entry);
    }
    return out;
  }

  private entryVisibleInList(entry: TaskListEntry): boolean {
    // 状态筛选移除后，归档任务默认不混入列表，但仍可通过当前分类的搜索找到。
    return taskVisibleInTaskList(entry.session, this.searchQuery.trim().length > 0);
  }

  private entryMatchesSearch(entry: TaskListEntry): boolean {
    const query = this.searchQuery.trim().toLowerCase();
    if (query.length === 0) return true;
    const session = entry.session;
    const haystack = [
      taskDisplayTitle(session),
      session.workingDir,
      session.worktreePath,
      session.model,
      session.agentKind,
      session.status,
      session.source,
      session.preview,
      entry.deviceName,
    ].join('\n').toLowerCase();
    return haystack.indexOf(query) >= 0;
  }

  private taskSearchActive(): boolean {
    return this.searchQuery.trim().length > 0;
  }

  private taskSearchResultsForCategory(category: TaskListCategory): TaskSearchResult[] {
    const out: TaskSearchResult[] = [];
    for (let i = 0; i < this.taskSearchResults.length; i++) {
      const result = this.taskSearchResults[i];
      if (this.selectedDeviceId.length > 0 && result.deviceId !== this.selectedDeviceId) continue;
      if (taskListCategory(result.session) === category) out.push(result);
    }
    return out;
  }

  private taskSearchProjects(): TaskSearchProjectOption[] {
    const out: TaskSearchProjectOption[] = [];
    for (let i = 0; i < this.devices.length; i++) {
      const device = this.devices[i];
      if (!device.remoteControlEnabled) continue;
      if (this.selectedDeviceId.length > 0 && device.deviceId !== this.selectedDeviceId) continue;
      const projects = listTaskSearchProjects(
        device.deviceId,
        this.displayDeviceName(device.deviceId, device.deviceName),
        AppServices.instance.tasks.getSessions(device.deviceId),
      );
      for (let projectIndex = 0; projectIndex < projects.length; projectIndex++) {
        const alias = this.projectAlias(device.deviceId, projects[projectIndex].workingDir);
        if (alias.length > 0) projects[projectIndex].title = alias;
        out.push(projects[projectIndex]);
      }
    }
    return out;
  }

  private reconcileTaskSearchProjectKeys(): void {
    if (this.taskSearchProjectKeys.length === 0) return;
    const projects = this.taskSearchProjects();
    const visibleKeys: string[] = [];
    for (let i = 0; i < projects.length; i++) visibleKeys.push(projects[i].key);
    const next = this.taskSearchProjectKeys.filter((key: string) => visibleKeys.indexOf(key) >= 0);
    if (next.length !== this.taskSearchProjectKeys.length) this.taskSearchProjectKeys = next;
  }

  private taskSearchOrigins(): TaskSearchOrigin[] {
    const projects = this.taskSearchProjects();
    const dirsByDevice: Map<string, string[]> = new Map();
    for (let i = 0; i < projects.length; i++) {
      const project = projects[i];
      if (this.taskSearchProjectKeys.indexOf(project.key) < 0) continue;
      const dirs = dirsByDevice.get(project.deviceId) ?? [];
      const remoteWorkingDirs = project.remoteWorkingDirs.length > 0
        ? project.remoteWorkingDirs : [project.workingDir];
      for (let dirIndex = 0; dirIndex < remoteWorkingDirs.length; dirIndex++) {
        const remoteWorkingDir = remoteWorkingDirs[dirIndex];
        if (remoteWorkingDir.length > 0 && dirs.indexOf(remoteWorkingDir) < 0) dirs.push(remoteWorkingDir);
      }
      dirsByDevice.set(project.deviceId, dirs);
    }
    const out: TaskSearchOrigin[] = [];
    for (let i = 0; i < this.devices.length; i++) {
      const device = this.devices[i];
      if (!device.remoteControlEnabled) continue;
      if (this.selectedDeviceId.length > 0 && device.deviceId !== this.selectedDeviceId) continue;
      if (this.taskSearchProjectKeys.length > 0 && !dirsByDevice.has(device.deviceId)) continue;
      const origin = new TaskSearchOrigin();
      origin.deviceId = device.deviceId;
      origin.deviceName = this.displayDeviceName(device.deviceId, device.deviceName);
      origin.reachable = this.deviceCanOpen(device);
      const dirs = dirsByDevice.get(device.deviceId);
      origin.workingDirs = dirs === undefined ? null : dirs.slice();
      out.push(origin);
    }
    return out;
  }

  private taskSearchRequest(): TaskSearchRequest {
    const request = new TaskSearchRequest();
    request.query = this.searchQuery.trim();
    request.sortBy = this.taskSearchSortBy;
    const filters = new TaskSearchFilters();
    filters.status = this.taskSearchStatusFilter;
    filters.agentKind = this.taskSearchAgentFilter;
    filters.lastActivity = this.taskSearchLastActivityFilter;
    request.filters = filters;
    return request;
  }

  /** 决定搜索结果的全部输入：关键词、排序与筛选、设备范围与项目范围。 */
  private taskSearchInputsKey(): string {
    const origins = this.taskSearchOrigins().map((origin: TaskSearchOrigin): string => JSON.stringify([
      origin.deviceId, origin.deviceName, origin.reachable,
      origin.workingDirs === null ? null : origin.workingDirs.slice().sort(),
    ])).sort();
    return JSON.stringify([this.taskSearchRequest(), origins]);
  }

  private scheduleTaskSearch(): void {
    this.lastTaskSearchKey = this.taskSearchInputsKey();
    this.taskSearchGeneration += 1;
    const generation = this.taskSearchGeneration;
    if (this.taskSearchTimer >= 0) {
      clearTimeout(this.taskSearchTimer);
      this.taskSearchTimer = -1;
    }
    const query = this.searchQuery.trim();
    if (query.length === 0) {
      this.taskSearchStatus = 'idle';
      this.taskSearchResults = [];
      this.taskSearchUsedCacheFallback = false;
      this.ensureWideSelection();
      return;
    }
    this.taskSearchStatus = 'searching';
    this.taskSearchResults = [];
    this.taskSearchUsedCacheFallback = false;
    this.taskSearchTimer = setTimeout(() => {
      this.taskSearchTimer = -1;
      void this.runTaskSearch(generation, query);
    }, TASK_SEARCH_DEBOUNCE_MS);
  }

  private async runTaskSearch(generation: number, query: string): Promise<void> {
    const request = this.taskSearchRequest();
    const origins = this.taskSearchOrigins();
    try {
      const page = await AppServices.instance.taskSearch.search(origins, request);
      if (!this.pageActive || generation !== this.taskSearchGeneration
        || query !== this.searchQuery.trim()) return;
      this.taskSearchResults = page.results.slice();
      this.taskSearchUsedCacheFallback = page.usedCacheFallback;
      this.taskSearchStatus = 'ready';
      this.ensureWideSelection();
    } catch (_error) {
      if (!this.pageActive || generation !== this.taskSearchGeneration
        || query !== this.searchQuery.trim()) return;
      this.taskSearchResults = [];
      this.taskSearchUsedCacheFallback = true;
      this.taskSearchStatus = 'ready';
      this.ensureWideSelection();
    }
  }

  private cancelTaskSearch(): void {
    this.lastTaskSearchKey = '';
    this.taskSearchGeneration += 1;
    if (this.taskSearchTimer >= 0) {
      clearTimeout(this.taskSearchTimer);
      this.taskSearchTimer = -1;
    }
    this.taskSearchStatus = 'idle';
    this.taskSearchResults = [];
    this.taskSearchUsedCacheFallback = false;
    this.taskSearchFilterOpen = false;
  }

  private taskSearchCoverageLabel(): string {
    if (!this.taskSearchUsedCacheFallback) return '';
    return this.v12String('v12_cached_search_only');
  }

  private v12String(name: string, ...args: Array<string | number>): string {
    return harmonyV12String(this.getUIContext().getHostContext(), name, ...args);
  }

  private taskSearchFilterCount(): number {
    return taskSearchActiveFilterCount(this.taskSearchFilters(), this.taskSearchProjectKeys);
  }

  private taskSearchFilters(): TaskSearchFilters {
    const filters = new TaskSearchFilters();
    filters.status = this.taskSearchStatusFilter;
    filters.agentKind = this.taskSearchAgentFilter;
    filters.lastActivity = this.taskSearchLastActivityFilter;
    return filters;
  }

  private openTaskSearchFilter(): void {
    uiOverlayTrace('search-filter', 'open');
    this.scopeMenuOpen = false;
    this.sortMenuOpen = false;
    this.taskSearchFilterOpen = true;
  }

  private closeTaskSearchFilter(): void {
    this.taskSearchFilterOpen = false;
  }

  private selectTaskSearchStatus(value: TaskSearchStatusFilter): void {
    this.taskSearchStatusFilter = value;
    this.scheduleTaskSearch();
  }

  private selectTaskSearchAgent(value: TaskSearchAgentFilter): void {
    this.taskSearchAgentFilter = value;
    this.scheduleTaskSearch();
  }

  private selectTaskSearchLastActivity(value: TaskSearchLastActivityFilter): void {
    this.taskSearchLastActivityFilter = value;
    this.scheduleTaskSearch();
  }

  private selectTaskSearchSort(value: TaskSearchSortBy): void {
    this.taskSearchSortBy = value;
    this.scheduleTaskSearch();
  }

  private toggleTaskSearchProject(key: string): void {
    const index = this.taskSearchProjectKeys.indexOf(key);
    if (index >= 0) {
      this.taskSearchProjectKeys = this.taskSearchProjectKeys.filter((item: string) => item !== key);
    } else {
      this.taskSearchProjectKeys = this.taskSearchProjectKeys.concat([key]);
    }
    this.scheduleTaskSearch();
  }

  private resetTaskSearchFilters(): void {
    this.taskSearchStatusFilter = 'all';
    this.taskSearchAgentFilter = 'all';
    this.taskSearchLastActivityFilter = 'all';
    this.taskSearchSortBy = 'relevance';
    this.taskSearchProjectKeys = [];
    this.scheduleTaskSearch();
  }

  private toggleSearch(): void {
    const nextOpen = !this.searchOpen;
    uiAnimateFastState(this.getUIContext(), () => {
      this.searchOpen = nextOpen;
      if (!nextOpen) this.searchQuery = '';
    });
    if (!nextOpen) this.cancelTaskSearch();
    this.ensureWideSelection();
    this.persistPreferences();
  }

  private async refreshTaskList(visible: boolean): Promise<boolean> {
    if (this.refreshing) return false;
    const lifecycleGeneration = this.pageLifecycleGeneration;
    if (visible) this.refreshing = true;
    let deviceSnapshotLoaded = false;
    let eligibleCount = 0;
    let loadedCount = 0;
    try {
      if (AppServices.instance.client.getStatus() !== 'online') {
        AppServices.instance.client.connectNow('task-list-refresh', true);
        try {
          await AppServices.instance.client.waitUntilOnline(5000);
        } catch (_err) {
          if (visible && this.pageActive && lifecycleGeneration === this.pageLifecycleGeneration) {
            uiToast(this.getUIContext(), '连接电脑后才能刷新任务');
          }
          return false;
        }
      }
      // 与 Mobile 手动刷新同源：先刷新设备管理面，再按最新设备快照拉任务列表。
      deviceSnapshotLoaded = await AppServices.instance.loadDevices();
      AppServices.instance.syncSessionSubscriptions();
      const devices = AppServices.instance.tasks.deviceList;
      const loads: Array<Promise<boolean>> = [];
      for (let i = 0; i < devices.length; i++) {
        if (!devices[i].online || !devices[i].remoteControlEnabled) continue;
        eligibleCount += 1;
        // 用户主动刷新必须发起新的权威拉取；已有的订阅初拉或周期对账不能冒充本次刷新。
        // TaskStore 的 per-device revision 会让更早请求的迟到响应自动失权。
        loads.push(this.loadTaskListSingleFlight(devices[i].deviceId, visible));
      }
      const outcomes = await Promise.all(loads);
      if (!this.pageActive || lifecycleGeneration !== this.pageLifecycleGeneration) return false;
      for (let i = 0; i < outcomes.length; i++) {
        if (outcomes[i]) loadedCount += 1;
      }
      const success = deviceSnapshotLoaded && (eligibleCount === 0 || loadedCount === eligibleCount);
      if (visible && success) {
        this.resetDisplayOrder();
        this.refreshProjection();
      }
      if (visible) this.refreshTeammates();
      if (visible && !success) uiToast(this.getUIContext(), '部分任务刷新失败，请重试');
      return success;
    } catch (_error) {
      if (visible && this.pageActive && lifecycleGeneration === this.pageLifecycleGeneration) {
        uiToast(this.getUIContext(), '部分任务刷新失败，请重试');
      }
      return false;
    } finally {
      if (visible && lifecycleGeneration === this.pageLifecycleGeneration) this.refreshing = false;
    }
  }

  /** 页面内所有列表补拉按设备合并，避免手动刷新与周期对账互相判旧。 */
  private loadTaskListSingleFlight(deviceId: string, forceFresh: boolean = false): Promise<boolean> {
    const existing = this.taskListLoadInFlight.get(deviceId);
    if (!forceFresh && existing !== undefined) return existing;
    const request = AppServices.instance.tasks.loadSessions(deviceId);
    this.taskListLoadInFlight.set(deviceId, request);
    void request.finally(() => {
      if (this.taskListLoadInFlight.get(deviceId) === request) {
        this.taskListLoadInFlight.delete(deviceId);
      }
    });
    return request;
  }

  /** 10 秒 anti-entropy：每设备 single-flight，失败指数退避到最多 2 分钟。 */
  private reconcileTaskLists(): void {
    if (this.connectionStatus !== 'online') return;
    const devices = AppServices.instance.tasks.deviceList;
    const eligibleDeviceIds: Set<string> = new Set();
    for (let i = 0; i < devices.length; i++) {
      const device = devices[i];
      if (!device.online || !device.remoteControlEnabled) continue;
      eligibleDeviceIds.add(device.deviceId);
      if (this.taskListLoadInFlight.has(device.deviceId)
        || !this.taskListReconcileBackoff.shouldAttempt(device.deviceId)) {
        continue;
      }
      const generation = this.taskListReconcileGeneration;
      void this.loadTaskListSingleFlight(device.deviceId)
        .then((loaded: boolean) => {
          if (generation !== this.taskListReconcileGeneration) return;
          this.taskListReconcileBackoff.report(device.deviceId, loaded);
        })
        .catch((_err: Error) => {
          if (generation !== this.taskListReconcileGeneration) return;
          this.taskListReconcileBackoff.report(device.deviceId, false);
        });
    }
    this.taskListReconcileBackoff.retainOnly(eligibleDeviceIds);
  }

  private entryForKey(key: string): TaskListEntry | null {
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].key === key) return this.entries[i];
    }
    return null;
  }

  private async applySessionPatch(entry: TaskListEntry, patch: SessionMetaPatch): Promise<boolean> {
    const lifecycleGeneration = this.pageLifecycleGeneration;
    this.sessionActionBusy = true;
    const ok = await AppServices.instance.tasks.patchSession(entry.deviceId, entry.session.id, patch);
    if (!this.pageActive || lifecycleGeneration !== this.pageLifecycleGeneration) return false;
    this.sessionActionBusy = false;
    if (!ok) uiToast(this.getUIContext(), '任务更新失败，请重试');
    return ok;
  }

  private async togglePinned(entry: TaskListEntry): Promise<void> {
    const patch = new SessionMetaPatch();
    patch.pinnedAt = entry.session.pinnedAt.length > 0 ? null : new Date().toISOString();
    await this.applySessionPatch(entry, patch);
  }

  private async archiveOrRestore(entry: TaskListEntry): Promise<void> {
    const patch = new SessionMetaPatch();
    if (entry.session.status === 'archived') {
      patch.status = 'active';
    } else {
      patch.status = 'archived';
      patch.pinnedAt = null;
    }
    await this.applySessionPatch(entry, patch);
  }

  private beginBulkSelection(entry: TaskListEntry): void {
    this.bulkMode = true;
    if (this.selectedEntryKeys.indexOf(entry.key) < 0) {
      this.selectedEntryKeys = this.selectedEntryKeys.concat([entry.key]);
    }
  }

  private toggleBulkEntry(entry: TaskListEntry): void {
    const index = this.selectedEntryKeys.indexOf(entry.key);
    if (index >= 0) {
      this.selectedEntryKeys = this.selectedEntryKeys.filter((key: string) => key !== entry.key);
      if (this.selectedEntryKeys.length === 0) this.bulkMode = false;
    } else {
      this.selectedEntryKeys = this.selectedEntryKeys.concat([entry.key]);
    }
  }

  private cancelBulkSelection(): void {
    this.bulkMode = false;
    this.selectedEntryKeys = [];
  }

  private bulkAction(action: string): void {
    const count = this.selectedEntryKeys.length;
    if (count === 0 || this.sessionActionBusy) return;
    const lifecycleGeneration = this.pageLifecycleGeneration;
    const keys = this.selectedEntryKeys.slice();
    const copy = uiConfirmCopy(`处理 ${count} 个任务？`,
      action === 'delete' ? '选中的任务将被删除。' : '将对选中的适用任务执行此操作。', '继续', '取消', action === 'delete');
    void uiConfirm(this.getUIContext(), copy).then((confirmed: boolean): void => {
      if (!confirmed || !this.pageActive || lifecycleGeneration !== this.pageLifecycleGeneration) return;
      void this.applyBulkAction(action, lifecycleGeneration, keys);
    });
  }

  private async applyBulkAction(
    action: string,
    lifecycleGeneration: number,
    selectedKeys: string[],
  ): Promise<void> {
    if (this.sessionActionBusy || !this.pageActive
      || lifecycleGeneration !== this.pageLifecycleGeneration) return;
    this.sessionActionBusy = true;
    const keys = selectedKeys.slice();
    const retained: string[] = [];
    let failed = 0;
    let skipped = 0;
    try {
      for (let i = 0; i < keys.length; i++) {
        if (!this.pageActive || lifecycleGeneration !== this.pageLifecycleGeneration) return;
        const entry = this.entryForKey(keys[i]);
        if (entry === null) continue;
        const patch = new SessionMetaPatch();
        if (action === 'pin') {
          if (entry.session.status !== 'active' || entry.session.pinnedAt.length > 0) {
            retained.push(keys[i]);
            skipped += 1;
            continue;
          }
          patch.pinnedAt = new Date().toISOString();
        } else if (action === 'unpin') {
          if (entry.session.pinnedAt.length === 0) {
            retained.push(keys[i]);
            skipped += 1;
            continue;
          }
          patch.pinnedAt = null;
        } else if (action === 'archive') {
          if (entry.session.status !== 'active') {
            retained.push(keys[i]);
            skipped += 1;
            continue;
          }
          patch.status = 'archived';
          patch.pinnedAt = null;
        } else if (action === 'restore') {
          if (entry.session.status !== 'archived') {
            retained.push(keys[i]);
            skipped += 1;
            continue;
          }
          patch.status = 'active';
        } else if (action === 'delete') {
          patch.status = 'deleted';
        }
        const ok = await AppServices.instance.tasks.patchSession(entry.deviceId, entry.session.id, patch);
        if (!this.pageActive || lifecycleGeneration !== this.pageLifecycleGeneration) return;
        if (!ok) {
          failed += 1;
          retained.push(keys[i]);
        }
      }
      this.selectedEntryKeys = retained;
      this.bulkMode = retained.length > 0;
      if (failed > 0 || skipped > 0) {
        const parts: string[] = [];
        if (failed > 0) parts.push(`${failed} 个失败`);
        if (skipped > 0) parts.push(`${skipped} 个不适用`);
        uiToast(this.getUIContext(), `${parts.join('，')}，已保留选择`);
      }
    } finally {
      if (lifecycleGeneration === this.pageLifecycleGeneration) this.sessionActionBusy = false;
    }
  }

  private pinnedEntries(category: TaskListCategory): TaskListEntry[] {
    const out: TaskListEntry[] = [];
    const scoped = this.scopedEntries();
    for (let i = 0; i < scoped.length; i++) {
      if (scoped[i].session.pinnedAt.length > 0
        && taskListCategory(scoped[i].session) === category
        && (category !== 'dialogues' || !this.isTeammateConversation(scoped[i]))) {
        out.push(scoped[i]);
      }
    }
    return out;
  }

  private regularEntries(): TaskListEntry[] {
    const out: TaskListEntry[] = [];
    const scoped = this.scopedEntries();
    for (let i = 0; i < scoped.length; i++) {
      if (scoped[i].session.pinnedAt.length === 0) out.push(scoped[i]);
    }
    return out;
  }

  private projectGroups(): TaskProjectGroup[] {
    return this.projectGroupsFrom(this.regularEntries());
  }

  private projectAlias(deviceId: string, workingDir: string): string {
    const key = taskProjectOrderKey(deviceId, workingDir);
    const members = AppServices.instance.tasks.getSessions(deviceId).filter((session: RemoteSession): boolean =>
      session.status !== 'deleted' && session.orcaRole !== 'worker' && taskListCategory(session) === 'projects'
        && taskProjectOrderKey(deviceId, sessionProjectDirectory(session)) === key);
    return AppServices.instance.taskProjectAliases.resolve(deviceId, members);
  }

  private projectGroupsFrom(entries: TaskListEntry[]): TaskProjectGroup[] {
    const groups: Map<string, TaskProjectGroup> = new Map();
    for (let i = 0; i < entries.length; i++) {
      const entry = entries[i];
      const session = entry.session;
      if (taskListCategory(session) !== 'projects') continue;
      const projectDir = sessionProjectDirectory(session);
      const key = taskProjectOrderKey(entry.deviceId, projectDir);
      let group = groups.get(key);
      if (group === undefined) {
        group = new TaskProjectGroup();
        group.key = key;
        group.deviceId = entry.deviceId;
        group.workingDir = projectDir;
        group.title = taskProjectName(projectDir);
        group.latestActivityAt = taskActivityAt(session);
        groups.set(key, group);
      }
      group.entries.push(entry);
      const activityAt = taskActivityAt(session);
      if (activityAt > group.latestActivityAt) group.latestActivityAt = activityAt;
    }
    const out: TaskProjectGroup[] = [];
    groups.forEach((group: TaskProjectGroup) => out.push(group));
    if (this.displayedProjectOrderMode() === 'custom') {
      const manualOrder = reconcileTaskProjectOrder(
        this.displayedProjectOrderKeys(),
        this.projectOrderVisibleKeys(out),
      );
      const rank = new Map<string, number>();
      for (let i = 0; i < manualOrder.length; i++) rank.set(manualOrder[i], i);
      out.sort((a: TaskProjectGroup, b: TaskProjectGroup) => {
        const aRank = rank.get(a.key);
        const bRank = rank.get(b.key);
        if (aRank !== undefined && bRank !== undefined && aRank !== bRank) return aRank - bRank;
        if (aRank !== undefined) return -1;
        if (bRank !== undefined) return 1;
        return a.key.localeCompare(b.key);
      });
    } else if (this.sortMode !== 'default') {
      out.sort((a: TaskProjectGroup, b: TaskProjectGroup) => {
        if (this.sortMode === 'alphabetic') {
          const titleResult = compareTaskListLabels(a.title, b.title);
          if (titleResult !== 0) return titleResult;
        } else if (a.latestActivityAt !== b.latestActivityAt) {
          return a.latestActivityAt > b.latestActivityAt ? -1 : 1;
        }
        return a.key.localeCompare(b.key);
      });
    }
    if (this.displayProjectKeys.length > 0 && this.displayedProjectOrderMode() !== 'custom') {
      const orderedKeys = stableTaskKeys(out.map((group: TaskProjectGroup) => group.key), this.displayProjectKeys);
      const byKey = new Map<string, TaskProjectGroup>();
      for (const group of out) byKey.set(group.key, group);
      out.length = 0;
      for (const key of orderedKeys) {
        const group = byKey.get(key);
        if (group !== undefined) out.push(group);
      }
    }
    for (const group of out) {
      const alias = this.projectAlias(group.deviceId, group.workingDir);
      if (alias.length > 0) group.title = alias;
    }
    return out;
  }

  private dialogueEntries(): TaskListEntry[] {
    const out: TaskListEntry[] = [];
    const entries = this.regularEntries();
    for (let i = 0; i < entries.length; i++) {
      if (taskListCategory(entries[i].session) === 'dialogues' && !this.isTeammateConversation(entries[i])) {
        out.push(entries[i]);
      }
    }
    return out;
  }

  private flatCategoryEntries(category: TaskListCategory): TaskListEntry[] {
    if (category === 'dialogues') return this.dialogueEntries();
    if (category === 'automations') return this.regularEntries().filter((entry: TaskListEntry): boolean =>
      taskListCategory(entry.session) === 'automations');
    return [];
  }

  private sessionEntryRenderKey(prefix: string, entry: TaskListEntry): string {
    const state = taskListEntryPresentationState(entry.session, this.taskRightStatusKind(entry));
    return JSON.stringify([prefix, entry.key, state, this.agentDeviceLabel(entry)]);
  }

  private agentDeviceLabel(entry: TaskListEntry): string {
    const deviceId = entry.session.agentDeviceId;
    if (deviceId.length === 0) return '';
    const device = this.devices.find((item: PresenceSnapshot): boolean => item.deviceId === deviceId);
    return this.displayDeviceName(deviceId, device?.deviceName ?? '');
  }

  private projectGroupRenderKey(group: TaskProjectGroup): string {
    // 外层项目节点也会捕获旧 entries；成员不仅新增/移除，任一行的可见状态变化
    // 都必须进入外层 key，否则内部 ForEach 连重新计算 key 的机会都没有。
    let key = JSON.stringify(['project', group.key, group.title, this.projectMachineLabel(group)]);
    for (let i = 0; i < group.entries.length; i++) {
      key += `:${this.sessionEntryRenderKey('member', group.entries[i])}`;
    }
    return key;
  }

  /** 当前分类可见的任务；置顶任务只出现在自身所属分类。 */
  private activeListEntries(): TaskListEntry[] {
    const out: TaskListEntry[] = [];
    const pinned = this.pinnedEntries(this.activeListTab);
    for (let i = 0; i < pinned.length; i++) out.push(pinned[i]);
    if (this.activeListTab !== 'projects') {
      const flatEntries = this.flatCategoryEntries(this.activeListTab);
      for (let i = 0; i < flatEntries.length; i++) out.push(flatEntries[i]);
      return out;
    }
    const groups = this.projectGroups();
    for (let groupIndex = 0; groupIndex < groups.length; groupIndex++) {
      for (let entryIndex = 0; entryIndex < groups[groupIndex].entries.length; entryIndex++) {
        out.push(groups[groupIndex].entries[entryIndex]);
      }
    }
    return out;
  }

  private allProjectsCollapsed(): boolean {
    const groups = this.projectGroups();
    if (groups.length === 0) return false;
    for (let i = 0; i < groups.length; i++) {
      if (!this.projectCollapsed(groups[i].key)) return false;
    }
    return true;
  }

  private toggleAllProjects(): void {
    const groups = this.projectGroups();
    if (groups.length === 0) return;
    if (this.allProjectsCollapsed()) {
      uiAnimateState(this.getUIContext(), () => {
        this.collapsedProjectKeys = [];
      });
      this.persistPreferences();
      return;
    }
    const keys: string[] = [];
    for (let i = 0; i < groups.length; i++) keys.push(groups[i].key);
    uiAnimateState(this.getUIContext(), () => {
      this.collapsedProjectKeys = keys;
    });
    this.persistPreferences();
  }

  private toggleAllProjectsFromMenu(): void {
    this.closeSortMenu();
    this.toggleAllProjects();
  }

  private projectCollapsed(key: string): boolean {
    return this.collapsedProjectKeys.indexOf(key) >= 0;
  }

  private toggleProject(key: string): void {
    const index = this.collapsedProjectKeys.indexOf(key);
    uiAnimateState(this.getUIContext(), () => {
      if (index >= 0) {
        this.collapsedProjectKeys = this.collapsedProjectKeys.filter((value: string) => value !== key);
      } else {
        this.collapsedProjectKeys = this.collapsedProjectKeys.concat([key]);
      }
    });
    this.persistPreferences();
  }

  private projectFullyExpanded(key: string): boolean {
    return this.expandedProjectKeys.indexOf(key) >= 0;
  }

  private visibleProjectEntries(group: TaskProjectGroup): TaskListEntry[] {
    if (this.projectFullyExpanded(group.key) || group.entries.length <= PROJECT_INLINE_LIMIT) {
      return group.entries;
    }
    return group.entries.slice(0, PROJECT_INLINE_LIMIT);
  }

  private toggleProjectExpanded(key: string): void {
    uiAnimateState(this.getUIContext(), () => {
      if (this.projectFullyExpanded(key)) {
        this.expandedProjectKeys = this.expandedProjectKeys.filter((value: string) => value !== key);
      } else {
        this.expandedProjectKeys = this.expandedProjectKeys.concat([key]);
      }
    });
    this.persistPreferences();
  }

  private availableDeviceCount(): number {
    let count = 0;
    for (let i = 0; i < this.devices.length; i++) {
      if (this.deviceCanOpen(this.devices[i])) count += 1;
    }
    return count;
  }

  private emptyTitle(): string {
    if (this.connectionStatus === 'connecting') return '正在连接电脑';
    if (this.taskSearchActive()) return '没有找到相关任务';
    if (this.devices.length === 0) return '还没有可控制的电脑';
    if (this.availableDeviceCount() === 0) return '电脑当前不可用';
    return '暂无任务';
  }

  private emptyCopy(): string {
    if (this.connectionStatus === 'connecting') return '连接后将自动同步任务';
    if (this.taskSearchActive()) return '换个关键词试试';
    if (this.devices.length === 0) return '请确认电脑端 Cindy 已登录并开启远程控制';
    if (this.availableDeviceCount() === 0) return '请将电脑上线并开启远程控制';
    if (this.selectedDeviceId.length > 0) return '这台电脑当前没有任务';
    return '新任务会显示在这里';
  }

  private activeTabEmptyTitle(category: TaskListCategory): string {
    if (category === 'projects') {
      return this.taskSearchActive() ? '没有找到相关项目任务' : '暂无项目任务';
    }
    if (category === 'dialogues') {
      return this.taskSearchActive() ? '没有找到相关对话任务' : '暂无对话任务';
    }
    return this.taskSearchActive() ? '没有找到相关自动化' : '暂无自动化';
  }

  private activeTabEmptyCopy(category: TaskListCategory): string {
    if (this.taskSearchActive()) return '换个关键词试试';
    if (category === 'projects') return '新建项目任务后会显示在这里';
    if (category === 'dialogues') return '新建对话任务后会显示在这里';
    return '自动化运行后会显示在这里';
  }

  build() {
    Stack() {
      // Keep the project folder sheet mounted independently of search and list filters.
      Column() {}
        .width(0)
        .height(0)
        .bindSheet($$this.projectFolderOpen, this.projectFolderSheet(),
          workdirBrowserSheetOptions((): void => { this.projectFolderOpen = false; }))

      Row() {
        this.taskListPane()
        if (this.splitLayoutEnabled()) {
          Stack() {
            Column() { this.detailPane() }
              .width('100%').height('100%')
              .visibility(this.usageOpen || this.listPaneFullscreen ? Visibility.None : Visibility.Visible)
            if (this.usageOpen) { this.usageDestination() }
          }
          .width(this.detailPaneWidth())
          .height('100%')
          .visibility(this.listPaneFullscreen && !this.newSessionDraftOpen ? Visibility.None : Visibility.Visible)
        }
      }
      .width('100%')
      .height('100%')

      if (this.usageOpen && !this.splitLayoutEnabled()) {
        this.usageDestination()
      }

      if (this.moduleRequest !== null) {
        HomeModulePanel({ request: this.moduleRequest, localCompanions: this.scopedTeammates(),
          onClose: this.closeHomeModule,
          onLocalCompanion: (entry: TeammateRosterEntry): void => this.openTeammate(entry),
          onChooseComputer: (): void => this.openDeviceScopeMenu(),
          onOpenTask: (device: string, session: string, message?: string): void => {
            this.setSelectedTask(device, session, message ?? '');
            if (!this.splitLayoutEnabled()) void router.pushUrl({ url: 'pages/TaskPage', params: { deviceId: device, sessionId: session, messageClientId: message ?? '' } });
          },
          onProjectSaved: (device: string, key: string): void => {
            const created = this.moduleRequest?.create === true;
            const fromDraft = this.newSessionDraftOpen;
            this.moduleRequest = null;
            AppServices.instance.taskProjectAliases.refresh(device);
            if (created && key.startsWith('local:')) {
              AppServices.instance.newSessionPreferences.save(device, 'project', key.slice(6));
              if (fromDraft) {
                // 从新建任务页发起：回到同一个草稿并选中新项目，不改首页电脑筛选。
                this.draftCreatedProject = device + '\n' + key.slice(6) + '\n' + (++this.draftCreatedProjectToken);
                return;
              }
              this.selectedDeviceId = device;
              this.openNewSession();
            }
          },
        }).width(this.splitLayoutEnabled() ? this.detailPaneWidth() : '100%').height('100%')
          .position({ x: this.splitLayoutEnabled() ? this.listPaneWidth() : 0, y: 0 })
          // 从新建任务页打开新建项目时，面板盖在草稿上方；其余入口打开前都会先关闭草稿。
          .zIndex(this.newSessionDraftOpen ? 1 : 0)
      }

      // 新任务草稿始终由同一个节点持有：窄屏覆盖整页，宽屏只覆盖详情栏。
      // 旋转或折叠只更新尺寸，避免组件重建时释放尚未发送的附件。
      if (this.newSessionDraftOpen) {
        NewSessionPageContent({
          registerComposerBack: (handler: (() => boolean) | undefined): void => { this.draftComposerBack = handler; },
          paneDeviceId: this.newSessionDraftDeviceId,
          paneKeyboardInset: this.newSessionKeyboardInset(),
          paneComposerBottomInset: this.detailComposerBottomInset(),
          embedded: this.splitLayoutEnabled(),
          createdProject: this.draftCreatedProject,
          onCreateProject: (deviceId: string): void => this.openProjectCreateFromDraft(deviceId),
          onClose: (): void => {
            this.newSessionDraftOpen = false;
            this.updateKeyboardAvoidance();
            this.ensureWideSelection();
          },
          onSessionStarted: (deviceId: string, sessionId: string): void => {
            this.newSessionDraftOpen = false;
            this.updateKeyboardAvoidance();
            this.setSelectedTask(deviceId, sessionId, '');
            if (!this.splitLayoutEnabled()) {
              void router.pushUrl({
                url: 'pages/TaskPage',
                params: { deviceId: deviceId, sessionId: sessionId },
              });
            }
          },
        })
          .width(this.splitLayoutEnabled()
            ? this.detailPaneWidth() : '100%')
          .height('100%')
          .position({ x: this.splitLayoutEnabled() ? this.listPaneWidth() : 0, y: 0 })
          .transition(uiRevealTransition())
      }

      if (this.canDragTaskDivider()) {
        this.splitDivider()
      }

      IncomingShareSurface({
        activeDeviceId: this.newSessionDraftOpen ? this.newSessionDraftDeviceId
          : this.splitLayoutEnabled() && this.moduleRequest === null && !this.usageOpen ? this.selectedSessionDeviceId : '',
        activeSessionId: this.newSessionDraftOpen ? '' : this.selectedSessionId,
        onOpen: (target: IncomingShareDestination): void => {
        if (target.ownerKey !== AppServices.instance.usageCardOwner) return;
        this.moduleRequest = null;
        this.selectedDeviceId = target.deviceId;
        if (target.sessionId.length === 0) this.openNewSession();
        else {
          this.newSessionDraftOpen = false;
          this.setSelectedTask(target.deviceId, target.sessionId, '');
          if (!this.splitLayoutEnabled()) void router.pushUrl({ url: 'pages/TaskPage',
            params: { deviceId: target.deviceId, sessionId: target.sessionId } });
        }
      } })

      if (this.bulkMode) {
        this.bulkActionBar()
      }
    }
    .backgroundColor($r('app.color.bg_page'))
    .width('100%')
    .height('100%')
    .expandSafeArea(
      this.splitLayoutEnabled()
        ? [SafeAreaType.SYSTEM, SafeAreaType.KEYBOARD]
        : [SafeAreaType.SYSTEM],
      this.splitLayoutEnabled()
        ? [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]
        : [SafeAreaEdge.BOTTOM],
    )
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.handleAreaChange(oldArea, newArea);
    })
  }

  @Builder
  taskListPane() {
    HdsNavigation() {
      Column() {
      if (this.connectionStatus !== 'online') {
        this.connectionBanner()
      }
      if (this.searchOpen && (!this.usageOpen || this.splitLayoutEnabled())) {
        this.taskSearchField()
      }
      HdsTabs({ controller: this.listTabController, index: this.initialListTabIndex }) {
        TabContent() {
          this.taskListTabPage('projects')
        }
        // HdsTabs 内部使用 Swiper 承载 TabContent；允许当前列表延伸至
        // HdsNavigation 标题栏后方，标题材质才能采样到真实列表内容。
        .clip(false)
        .tabBar(this.taskListTabBarStyle(
          '项目',
          $r('sys.symbol.folder'),
        ))

        TabContent() {
          this.taskListTabPage('dialogues')
        }
        .clip(false)
        .tabBar(this.taskListTabBarStyle(
          this.v12String('v138_communication'),
          $r('sys.symbol.ellipsis_message'),
        ))

        TabContent() {
          this.taskListTabPage('automations')
        }
        .clip(false)
        .tabBar(this.taskListTabBarStyle(
          this.v12String('v12_automation'),
          $r('sys.symbol.bolt'),
        ))
      }
      .barPosition(BarPosition.End)
      .vertical(false)
      .scrollable(false)
      .barHeight(FLOATING_BAR_HEIGHT)
      .barOverlap(true)
      .divider({ mode: DividerMode.NONE })
      .barFloatingStyle({
        barBottomMargin: this.floatingBarBottomMargin(),
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
        },
        adaptToHandedness: true,
        thermoCtrl: true,
        miniBar: {
          miniBarBuilder: () => this.newSessionMiniBar(),
          miniBarStyle: HdsBarStyle.COLLAPSE,
          enableMiniBarBackground: true,
          enableMiniBarClip: true,
          barLayoutMode: HdsBarLayoutMode.HORIZONTAL,
        },
      })
      .onChange((index: number) => this.handleListTabChange(index))
      .layoutWeight(1)
      .width('100%')
      .clip(false)
      .backgroundColor(this.splitLayoutEnabled() ? Color.Transparent : $r('app.color.bg_page'))
      .onAppear(() => this.handleListTabsAppear())
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.splitLayoutEnabled() ? Color.Transparent : $r('app.color.bg_page'))
    }
    .titleBar({
      enableComponentSafeArea: true,
      style: this.splitLayoutEnabled() ? {
        scrollEffectOpts: {
          enableScrollEffect: true,
          // 展开双栏与右侧详情使用同一种标题栏材质；可见差异由后方内容决定，
          // 不再用另一套渐变参数模拟相似效果。
          scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
          blurEffectiveStartOffset: LengthMetrics.vp(0),
          blurEffectiveEndOffset: LengthMetrics.vp(20),
        },
        blurStrategy: BlurStrategy.ADAPTIVE,
        thermoCtrl: true,
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
        },
      } : {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
          blurEffectiveStartOffset: LengthMetrics.vp(0),
          blurEffectiveEndOffset: LengthMetrics.vp(20),
        },
        originalStyle: {
          backgroundStyle: {
            maskExtraHeight: LIST_HEADER_MASK_EXTRA_HEIGHT,
          },
        },
        scrollEffectStyle: {
          backgroundStyle: {
            maskExtraHeight: LIST_HEADER_MASK_EXTRA_HEIGHT,
          },
        },
        blurStrategy: BlurStrategy.ADAPTIVE,
        thermoCtrl: true,
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
        },
      },
      content: {
        title: { mainTitle: '' },
        stackBuilder: (): void => this.pageHeader(),
      },
    })
    .hideBackButton(true)
    .hideToolBar(true)
    // 页面自身已经负责主从双栏；禁止 HdsNavigation 在大于 600vp 时再次进入 Auto Split，
    // 否则它会把当前列表当成 navBar，并在右侧生成一块没有 NavDestination 的空内容区。
    .mode(NavigationMode.Stack)
    .titleMode(HdsNavigationTitleMode.MINI)
    // HdsNavigation 嵌套 HdsTabs 时只能绑定当前可见页的 Scroller；同时绑定
    // 三个隐藏页会让标题栏读取到错误的滚动/模糊状态。
    .bindToScrollable([this.scrollerForCategory(this.activeListTab)])
    .width(this.splitLayoutEnabled() ? this.listPaneWidth() : '100%')
    .height('100%')
    .backgroundColor(this.splitLayoutEnabled() ? Color.Transparent : $r('app.color.bg_page'))
    // 收起时只隐藏、不销毁，展开后列表滚动位置与 Tab 状态保持不变。
    .visibility(this.usageOpen || this.listPaneShown() ? Visibility.Visible : Visibility.None)
  }

  private clearRosterTimers(): void {
    this.rosterTimers.forEach((timer: number): void => { clearTimeout(timer); });
    this.rosterTimers.clear();
    this.rosterQueue.clear();
    this.rosterEligible.clear();
    this.rosterReadInFlight.forEach((_queued: boolean, device: string) => this.rosterReadInFlight.set(device, false));
    this.clearPendingTeammate();
  }

  /**
   * 新建伙伴成功后（Mobile openCreatedTeammate）：鸿蒙没有伙伴详情页，改为等新伙伴带着主对话出现在
   * 列表里时，用现有 openTeammate 打开它的对话。只记一个；切换电脑范围、切换账号或 30 秒内没出现就放弃。
   * 只依赖已有的列表刷新，不新增请求或轮询。
   */
  private companionCreated(deviceId: string, botId: string): void {
    this.clearPendingTeammate();
    this.pendingTeammateDevice = deviceId;
    this.pendingTeammateBot = botId;
    this.pendingTeammateScope = this.selectedDeviceId;
    this.pendingTeammateEpoch = AppServices.instance.auth.sessionEpoch;
    this.pendingTeammateTimer = setTimeout(() => {
      this.pendingTeammateTimer = -1;
      this.clearPendingTeammate();
    }, 30000);
    if (!this.openPendingTeammate(deviceId)) this.scheduleTeammateRead(deviceId);
  }

  private clearPendingTeammate(): void {
    if (this.pendingTeammateTimer >= 0) clearTimeout(this.pendingTeammateTimer);
    this.pendingTeammateTimer = -1;
    this.pendingTeammateDevice = '';
    this.pendingTeammateBot = '';
  }

  private openPendingTeammate(device: string): boolean {
    if (!this.pendingTeammateBot || this.pendingTeammateDevice !== device) return false;
    if (this.pendingTeammateEpoch !== AppServices.instance.auth.sessionEpoch
      || this.pendingTeammateScope !== this.selectedDeviceId) {
      this.clearPendingTeammate();
      return false;
    }
    const row = this.scopedTeammates().find((item: TeammateRosterEntry) =>
      item.deviceId === device && item.id === this.pendingTeammateBot);
    if (row === undefined) return false;
    this.clearPendingTeammate();
    this.openTeammate(row);
    return true;
  }

  private restoreTeammateView(): void {
    const owner = AppServices.instance.usageCardOwner;
    if (owner === this.teammatePreferenceOwner) return;
    this.teammatePreferenceOwner = owner;
    this.teammateCompact = false;
    const context = this.getUIContext().getHostContext();
    const revision = ++this.teammatePreferenceRevision;
    if (!owner || context === undefined) return;
    void readCompanionCompact(context, owner).then((value: boolean): void => {
      if (this.pageActive && revision === this.teammatePreferenceRevision && owner === AppServices.instance.usageCardOwner) {
        this.teammateCompact = value;
      }
    }).catch((): void => {});
  }

  private toggleTeammateView(): void {
    ++this.teammatePreferenceRevision;
    uiAnimateState(this.getUIContext(), () => {
      this.teammateCompact = !this.teammateCompact;
    });
    const owner = this.teammatePreferenceOwner;
    const context = this.getUIContext().getHostContext();
    if (context !== undefined && owner && owner === AppServices.instance.usageCardOwner) {
      writeCompanionCompact(context, owner, this.teammateCompact);
    }
  }

  private reconcileTeammateDevices(devices: PresenceSnapshot[]): void {
    const online = new Set<string>();
    for (const device of devices) {
      if (device.online && device.remoteControlEnabled) {
        online.add(device.deviceId);
        if (!this.rosterEligible.has(device.deviceId)) this.scheduleTeammateRead(device.deviceId);
      }
    }
    this.rosterEligible = online;
  }

  private refreshTeammates(): void {
    void this.drainTeammateReads();
    for (const device of AppServices.instance.tasks.deviceList) {
      if (device.online && device.remoteControlEnabled) this.scheduleTeammateRead(device.deviceId);
    }
  }

  private scheduleTeammateRead(device: string): void {
    if (!this.pageActive || !AppServices.instance.appInForeground || this.connectionStatus !== 'online'
      || !this.teammateDeviceOnline(device)) return;
    if (this.rosterReadInFlight.has(device)) {
      this.rosterReadInFlight.set(device, true);
      return;
    }
    if (this.rosterTimers.has(device) || this.rosterQueue.has(device)) return;
    // Merge bursts over 250ms and keep one follow-up if the host changes during the read.
    const timer = setTimeout(() => {
      this.rosterTimers.delete(device);
      this.rosterQueue.add(device);
      void this.drainTeammateReads();
    }, 250);
    this.rosterTimers.set(device, timer);
  }

  private async drainTeammateReads(): Promise<void> {
    if (this.rosterDraining) return;
    this.rosterDraining = true;
    try {
      while (this.rosterQueue.size > 0 && this.pageActive && AppServices.instance.appInForeground) {
        const next = this.rosterQueue.values().next();
        if (next.done) break;
        this.rosterQueue.delete(next.value);
        await this.readTeammates(next.value);
      }
    } finally {
      this.rosterDraining = false;
    }
  }

  private async readTeammates(device: string): Promise<void> {
    if (!this.pageActive || !AppServices.instance.appInForeground || this.connectionStatus !== 'online'
      || !this.teammateDeviceOnline(device)) return;
    const services = AppServices.instance;
    const epoch = services.auth.sessionEpoch;
    const lifecycle = this.pageLifecycleGeneration;
    this.rosterReadInFlight.set(device, false);
    try {
      const rows = await services.teammateRoster.list(device);
      if (!this.pageActive || lifecycle !== this.pageLifecycleGeneration
        || epoch !== services.auth.sessionEpoch || this.connectionStatus !== 'online'
        || !this.teammateDeviceOnline(device)) return;
      this.mergeTeammateRoster(device, rows);
      this.openPendingTeammate(device);
    } catch (_error) {
      // Keep verified rows when a request is interrupted. Old hosts may lack the collection.
    } finally {
      const queued = this.rosterReadInFlight.get(device) === true;
      this.rosterReadInFlight.delete(device);
      if (queued) this.scheduleTeammateRead(device);
    }
  }

  private teammateDeviceOnline(device: string): boolean {
    return AppServices.instance.tasks.deviceList.some((entry: PresenceSnapshot) =>
      entry.deviceId === device && entry.online && entry.remoteControlEnabled);
  }

  private mergeTeammateRoster(device: string, rows: TeammateRosterEntry[]): void {
    const previous = this.teammateRoster.filter((row: TeammateRosterEntry): boolean => row.deviceId === device);
    const old = new Map<string, TeammateRosterEntry>();
    previous.forEach((row: TeammateRosterEntry): void => { old.set(this.teammateKey(row), row); });
    const next = rows.map((row: TeammateRosterEntry): TeammateRosterEntry => {
      const prior = old.get(this.teammateKey(row));
      if (prior && prior.name === row.name && prior.preview === row.preview && prior.avatarKind === row.avatarKind &&
        prior.avatarValue === row.avatarValue && prior.avatarFallback === row.avatarFallback &&
        prior.timestamp === row.timestamp && prior.running === row.running && prior.replyAt === row.replyAt &&
        prior.readAt === row.readAt) return prior;
      return row;
    });
    if (previous.length === next.length && next.every((row: TeammateRosterEntry): boolean => old.get(this.teammateKey(row)) === row)) return;
    this.teammateRoster = this.teammateRoster.filter((row: TeammateRosterEntry): boolean => row.deviceId !== device).concat(next);
    this.updateTeammateProjection(true);
  }

  private updateTeammateProjection(force: boolean = false): void {
    const allowed = new Set<string>();
    for (const device of this.devices) if (device.remoteControlEnabled) allowed.add(device.deviceId);
    const key = JSON.stringify(Array.from(allowed).sort());
    if (!force && key === this.teammateDevicesKey) return;
    this.teammateDevicesKey = key;
    const start = Date.now();
    const rows = this.teammateRoster.filter((row: TeammateRosterEntry): boolean => allowed.has(row.deviceId))
      .sort((a: TeammateRosterEntry, b: TeammateRosterEntry): number => b.timestamp - a.timestamp || a.name.localeCompare(b.name));
    const byKey = new Map<string, TeammateRosterEntry>();
    this.teammateSessionKeys = new Set<string>();
    for (const row of rows) {
      byKey.set(this.teammateKey(row), row);
      this.teammateSessionKeys.add(row.deviceId + ':' + row.session.id);
    }
    const keys = Array.from(byKey.keys());
    if (keys.length !== this.visibleTeammateKeys.length ||
      keys.some((id: string, index: number): boolean => id !== this.visibleTeammateKeys[index])) this.visibleTeammateKeys = keys;
    this.visibleTeammateByKey = byKey;
    this.visibleTeammates = rows;
    hilog.debug(0, 'CindyCompanionPerf', 'projection count=%{public}d rows=%{public}d ms=%{public}d',
      ++this.teammateProjectionCount, rows.length, Date.now() - start);
  }

  private scopedTeammates(): TeammateRosterEntry[] { return this.visibleTeammates; }

  private isTeammateConversation(entry: TaskListEntry): boolean {
    return this.teammateSessionKeys.has(entry.key);
  }

  private teammateDeviceLabel(row: TeammateRosterEntry): string {
    const device = this.devices.find((item: PresenceSnapshot) => item.deviceId === row.deviceId);
    return this.displayDeviceName(row.deviceId, device?.deviceName ?? '');
  }

  private teammateAvatarOnline(row: TeammateRosterEntry): boolean {
    return this.connectionStatus === 'online' && this.devices.some((device: PresenceSnapshot) =>
      device.deviceId === row.deviceId && device.online && device.remoteControlEnabled);
  }

  private teammateRunning(row: TeammateRosterEntry): boolean {
    return this.teammateStatus(row) === 'running';
  }

  private teammateKey(row: TeammateRosterEntry): string {
    return JSON.stringify([row.deviceId, row.id, row.session.id]);
  }

  private teammateRenderKeys(): string[] {
    const started = Date.now();
    const keys = this.visibleTeammateKeys;
    this.teammateBuildMs += Date.now() - started;
    if (++this.teammateBuildCount % 32 === 1) {
      hilog.debug(0, 'CindyCompanionPerf', 'list_build_evaluations count=%{public}d input_ms=%{public}d rows=%{public}d',
        this.teammateBuildCount, this.teammateBuildMs, keys.length);
    }
    return keys;
  }

  private openTeammate(row: TeammateRosterEntry): void {
    if (this.bulkMode || !this.pageActive || AppServices.instance.taskAccountTransition.active ||
      !this.visibleTeammateByKey.has(this.teammateKey(row))) return;
    const services = AppServices.instance;
    const start = Date.now();
    const epoch = services.auth.sessionEpoch;
    const lifecycle = this.pageLifecycleGeneration;
    hilog.info(0, 'CindyCompanionPerf', 'open_start');
    if (!services.tasks.seedTeammateSession(row.deviceId, row.session) ||
      epoch !== services.auth.sessionEpoch || lifecycle !== this.pageLifecycleGeneration) {
      hilog.info(0, 'CindyCompanionPerf', 'open_rejected roster_seed');
      uiToast(this.getUIContext(), this.v12String('v138_open_failed'));
      return;
    }
    const entry = new TaskListEntry();
    entry.deviceId = row.deviceId;
    entry.session = services.tasks.findSessionById(row.session.id, row.deviceId) ?? row.session;
    entry.key = row.deviceId + ':' + row.session.id;
    services.teammateRoster.expectVisible(row);
    if (this.entrySelected(entry)) services.teammateRoster.noteVisible(row.deviceId, row.session.id);
    this.openSession(entry);
    hilog.info(0, 'CindyCompanionPerf', 'open_selected ms=%{public}d', Date.now() - start);
    if (this.teammateAvatarOnline(row)) {
      // Existing metadata read is advisory. List snapshot revisions or peer
      // failure must not delay the tap or assign the selection again.
      void services.openLink(row.deviceId).then((): Promise<RemoteSession | undefined> => {
        if (epoch !== services.auth.sessionEpoch || !this.teammateDeviceOnline(row.deviceId)) return Promise.resolve(undefined);
        return services.tasks.loadSession(row.deviceId, row.session.id, 'bot');
      }).then((session: RemoteSession | undefined): void => {
        hilog.info(0, 'CindyCompanionPerf', 'open_metadata result=%{public}s ms=%{public}d',
          session === undefined ? 'unavailable_or_stale' : 'verified', Date.now() - start);
      }).catch((): void => { hilog.info(0, 'CindyCompanionPerf', 'open_metadata link_unavailable'); });
    }
  }

  @Builder
  usageDestination() {
    Column() {
      Row() {
        this.headerSymbolButton($r('sys.symbol.chevron_left'), () => this.closeUsage(), this.v12String('v139_home_restore'))
        Text($r('app.string.usage_title')).fontSize(18).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary')).layoutWeight(1)
      }.width('100%').height(56).padding({ left: 8, right: 20 })
      UsageDashboardPanel({ active: this.usageOpen,
        pinnedDeviceId: this.activeUsageCardId ? this.selectedDeviceId : '', scroller: this.usageScroller })
        .layoutWeight(1)
    }.width('100%').height('100%').backgroundColor($r('app.color.bg_page'))
  }

  @Builder
  taskListTabPage(category: TaskListCategory, scrollCategory: TaskListCategory = category) {
    Refresh({ refreshing: this.refreshing && this.activeListTab === category }) {
      if (this.taskSearchActive()) {
        if (this.taskSearchStatus === 'searching') {
          this.buildTaskSearchLoading()
        } else if (this.taskSearchResultsForCategory(category).length === 0) {
          this.activeTabEmptyState(category)
        } else {
          this.buildTaskSearchEntries(category, scrollCategory)
        }
      } else if (category !== 'projects' && category !== 'dialogues' && this.scopedEntries().length === 0) {
        this.buildTaskListEmpty(category)
      } else {
        this.buildTaskListEntries(category, scrollCategory)
      }
    }
    .onRefreshing((): void => {
      if (this.activeListTab === category && (!this.usageOpen || this.splitLayoutEnabled())) void this.refreshTaskList(true);
    })
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  private taskListTabBarStyle(label: string, icon: Resource): BottomTabBarStyle {
    return new BottomTabBarStyle({
      normal: new SymbolGlyphModifier(icon)
        .fontSize(22)
        .fontColor([$r('app.color.text_secondary')]),
      selected: new SymbolGlyphModifier(icon)
        .fontSize(22)
        .fontColor([$r('app.color.accent')]),
    }, label)
      .labelStyle({
        font: { size: 11, weight: FontWeight.Medium },
        selectedColor: $r('app.color.text_primary'),
        unselectedColor: $r('app.color.text_secondary'),
        maxLines: 1,
      })
      .layoutMode(LayoutMode.VERTICAL)
      .padding({ left: 4, right: 4, top: 4, bottom: 4 });
  }

  @Builder
  newSessionMiniBar() {
    Button() {
      SymbolGlyph($r('sys.symbol.plus'))
        .fontSize(22)
        .fontColor([$r('app.color.text_primary')])
    }
    .type(ButtonType.Circle)
    .width(FLOATING_BAR_HEIGHT)
    .height(FLOATING_BAR_HEIGHT)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .clickEffect(UI_ICON_CLICK_EFFECT)
    .accessibilityText('新建任务')
    .onClick(() => this.openNewSession())
  }

  @Builder
  splitDivider() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Blank()
          .height(SPLIT_HEADER_HEIGHT)
        Row()
          .width(1)
          .layoutWeight(1)
          .backgroundColor($r('app.color.border'))
      }
      .width(1)
      .height('100%')

      SplitHandle({ overrun: this.dividerOverrun })
    }
    .width(TASK_SPLIT_DIVIDER_WIDTH)
    .height('100%')
    .position({ x: this.listPaneWidth() - TASK_SPLIT_DIVIDER_WIDTH / 2, y: 0 })
    // 命中区跨在交界线两侧；只有中部指示符可见，整列不铺底。
    .backgroundColor(Color.Transparent)
    .onTouch((event: TouchEvent) => {
      this.handleDividerTouch(event);
    })
  }

  @Builder
  detailPane() {
    Stack() {
      if (this.selectedTaskKey().length === 0) {
        this.emptyDetailPane()
      }
      ForEach(this.residentPanes, (pane: ResidentTaskPane) => {
        // 定位目标与版本号从父级 @State 读取：同 key 复用实例时，替换 pane 对象不会重新执行这里。
        OrcaTaskDetail({
          registerBack: (handler: (() => boolean) | undefined): void => {
            if (handler) this.residentBackHandlers.set(pane.key, handler);
            else this.residentBackHandlers.delete(pane.key);
          },
          paneDeviceId: pane.deviceId,
          allowSideBySide: !this.safeWindowMultiWindow,
          paneSessionId: pane.sessionId,
          paneMessageClientId: this.paneSelected(pane) ? this.selectedMessageClientId : '',
          paneMessageRevision: this.paneSelected(pane) ? this.selectedMessageRevision : 0,
          paneActive: this.paneSelected(pane) && !this.usageOpen && !this.listPaneFullscreen,
          paneListCollapsed: !this.listPaneShown(),
          onTogglePaneList: (): void => this.toggleListPane(),
          paneComposerBottomInset: this.detailComposerBottomInset(),
          paneKeyboardInset: this.detailKeyboardInset(),
        })
          .width('100%')
          .height('100%')
          .visibility(this.paneSelected(pane) ? Visibility.Visible : Visibility.Hidden)
          .hitTestBehavior(this.paneSelected(pane) ? HitTestMode.Default : HitTestMode.None)
          .accessibilityLevel(this.paneSelected(pane) ? 'auto' : 'no-hide-descendants')
      }, (pane: ResidentTaskPane) => pane.key)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  emptyDetailPane() {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.rectangle_stack'))
        .fontSize(28)
        .fontColor([$r('app.color.text_tertiary')])
      Text('选择一个任务')
        .fontSize(15)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.bg_page'))
  }

  @Builder
  pageHeader() {
    Row({ space: 8 }) {
      Button() {
        Row({ space: 6 }) {
          Text(this.selectedDeviceLabel())
            .fontSize(18)
            .lineHeight(24)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(13)
            .fontColor([$r('app.color.text_secondary')])
        }
        .width('100%')
      }
      .type(ButtonType.Normal)
      .layoutWeight(1)
      .height(44)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .clickEffect(UI_ICON_CLICK_EFFECT)
      .onClick(() => {
        this.openDeviceScopeMenu();
      })
      .bindMenu(this.scopeMenuOpen, this.scopeMenuContent(),
        uiMenuOptions((): void => { this.scopeMenuOpen = false; }, Placement.BottomLeft, 'scope-menu'))

      this.headerSymbolButton($r('sys.symbol.gauge_with_dots_needle_33percent'),
        () => this.openUsage(), this.v12String('usage_tab'))
      this.sortHeaderButton()
      this.headerSymbolButton($r('sys.symbol.magnifyingglass'), () => this.toggleSearch(), this.v12String('v138_search'))
      if (this.listPaneFullscreen) {
        this.headerSymbolButton($r('sys.symbol.open_sidebar'), () => this.toggleListPane(),
          this.v12String('v139_home_restore'))
      }
      this.headerSymbolButton(
        $r('sys.symbol.gearshape'),
        () => this.openSettings(),
        '设置',
      )
    }
    .width('100%')
    .height(56)
    .padding({ left: LIST_INSET, right: LIST_INSET, bottom: 8 })
  }

  @Builder
  headerSymbolButton(symbol: Resource, action: () => void, accessibilityLabel: string = '') {
    Button() {
      SymbolGlyph(symbol)
        .fontSize(18)
        .fontColor([$r('app.color.text_primary')])
    }
    .type(ButtonType.Circle)
    .width(40)
    .height(40)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .clickEffect(UI_ICON_CLICK_EFFECT)
    .accessibilityText(accessibilityLabel)
    .onClick(action)
  }

  /** 排序按钮：系统操作菜单（见 docs/overlay-standard.md §3.1），无自绘遮罩。 */
  @Builder
  sortHeaderButton() {
    Button() {
      SymbolGlyph($r('sys.symbol.slider_horizontal_2'))
        .fontSize(18)
        .fontColor([$r('app.color.text_primary')])
    }
    .type(ButtonType.Circle)
    .width(40)
    .height(40)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .clickEffect(UI_ICON_CLICK_EFFECT)
    .accessibilityText(this.v12String('v138_sort'))
    .onClick(() => this.openSortMenu())
    .bindMenu(this.sortMenuOpen, this.sortMenuContent(),
      uiMenuOptions((): void => { this.sortMenuOpen = false; }, Placement.BottomRight, 'sort-menu'))
  }

  @Builder
  connectionBanner() {
    Row({ space: 8 }) {
      Circle()
        .width(8)
        .height(8)
        .fill(this.connectionStatus === 'connecting'
          ? $r('app.color.warn')
          : $r('app.color.text_tertiary'))
      Text(this.connectionStatus === 'connecting' ? '正在连接电脑…' : '连接已断开，任务可能不是最新状态')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(36)
    .padding({ left: LIST_INSET, right: LIST_INSET })
    .border({ width: { bottom: 1 }, color: { bottom: $r('app.color.border') } })
  }

  @Builder
  taskSearchField() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(16)
        .fontColor([$r('app.color.text_secondary')])
      TextInput({ placeholder: $r('app.string.v12_search_placeholder'), text: this.searchQuery })
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_placeholder'))
        .caretColor($r('app.color.accent'))
        .backgroundColor(Color.Transparent)
        .layoutWeight(1)
        .height(40)
        .padding(0)
        .onChange((value: string) => {
          this.searchQuery = value;
          this.scheduleTaskSearch();
          this.ensureWideSelection();
          this.persistPreferences();
        })
      if (this.searchQuery.length > 0) {
        Button() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(13)
            .fontColor([$r('app.color.text_secondary')])
        }
        .type(ButtonType.Circle)
        .width(32)
        .height(32)
        .padding(0)
        .backgroundColor(Color.Transparent)
        .accessibilityText($r('app.string.v12_clear_search'))
        .onClick(() => {
          this.searchQuery = '';
          this.cancelTaskSearch();
          this.ensureWideSelection();
          this.persistPreferences();
        })
      }
      this.taskSearchFilterButton()
    }
    .width('calc(100% - 32vp)')
    .height(44)
    .margin({ left: LIST_INSET, right: LIST_INSET, bottom: 6 })
    .padding({ left: 12, right: 8 })
    .backgroundColor($r('app.color.bg_chip'))
    .borderRadius(UI_RADIUS_PILL)
    .transition(uiRevealTransition())
  }

  @Builder
  taskSearchFilterButton() {
    Button() {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.slider_horizontal_2'))
          .fontSize(16)
          .fontColor([$r('app.color.text_secondary')])
        if (this.taskSearchFilterCount() > 0) {
          Circle()
            .width(6)
            .height(6)
            .fill($r('app.color.accent'))
            .position({ x: 12, y: 1 })
        }
      }
      .width(24)
      .height(24)
    }
    .type(ButtonType.Circle)
    .width(32)
    .height(32)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .clickEffect(UI_ICON_CLICK_EFFECT)
    .accessibilityText($r('app.string.v12_search_filter'))
    .onClick(() => this.openTaskSearchFilter())
    .bindSheet($$this.taskSearchFilterOpen, this.taskSearchFilterSheet(), this.taskSearchFilterSheetOptions())
  }

  @Builder
  buildTaskListEmpty(category: TaskListCategory) {
    Column({ space: 8 }) {
      Text(this.emptyTitle())
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text(this.emptyCopy())
        .fontSize(13)
        .lineHeight(19)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 32, right: 32, bottom: 80 })
    .onAppear(() => {
      if (this.isFloatingBarScrollSource(category)) this.showFloatingBar();
    })
  }

  @Builder
  communicationSectionTitle(title: string) {
    Text(title)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .padding({ left: LIST_INSET + 14, right: LIST_INSET + 14, top: 14, bottom: 6 })
  }

  /**
   * 「伙伴」标题行：右侧「+」对齐 Mobile HomeTeammatesSection 的新建入口
   * （新建伙伴 / 新建群聊 / 加入群聊）。新建伙伴可选的电脑与新建群聊同一口径（在线且可控制）；
   * 不支持新建伙伴的旧版电脑由表单里的提示说明。
   */
  private teammateStatus(row: TeammateRosterEntry): TaskRightStatusKind {
    if (!this.teammateAvatarOnline(row)) return 'time';
    const activity = AppServices.instance.tasks.getLiveActivity(row.session.id, row.deviceId);
    return resolveTaskRightStatus(activity?.phase ?? '', activity?.attention === true,
      AppServices.instance.interactions.getPending(row.session.id, row.deviceId).length,
      row.running || AppServices.instance.messages.isSessionRunning(row.session.id, row.deviceId));
  }

  private teammateDot(row: TeammateRosterEntry): Resource | null {
    const status = this.teammateStatus(row);
    if (status === 'error') return $r('app.color.danger');
    if (status === 'waiting' || row.replyAt > Math.max(0, row.readAt)) return $r('app.color.accent');
    return status === 'running' ? $r('app.color.text_secondary') : null;
  }

  private teammateStatusLabel(row: TeammateRosterEntry): string {
    if (!this.teammateAvatarOnline(row)) return ', ' + this.v12String('v138_offline');
    if (row.replyAt > Math.max(0, row.readAt)) return ', ' + this.v12String('v138_unread');
    if (this.teammateStatus(row) === 'running') return ', ' + this.v12String('teammate_activity_running');
    return '';
  }

  @Builder
  teammateSection() {
    ListItem() { this.teammateSectionHeader() }
    if (this.teammateCompact) {
      ListItem() {
        CompanionStrip({
          addMenu: (): void => { this.teammateAddMenu(); },
          online: (row: TeammateRosterEntry): boolean => this.teammateAvatarOnline(row),
          status: (row: TeammateRosterEntry): Resource | null => this.teammateDot(row),
          statusLabel: (row: TeammateRosterEntry): string => this.teammateStatusLabel(row),
          open: (row: TeammateRosterEntry): void => this.openTeammate(row),
          keys: this.visibleTeammateKeys,
          byKey: this.visibleTeammateByKey,
        })
      }.transition(uiRevealTransition())
    } else if (this.scopedTeammates().length === 0) {
      ListItem() {
        Text(this.v12String('v138_no_teammates')).fontSize(13).fontColor($r('app.color.text_secondary'))
          .width('100%').padding({ left: LIST_INSET + 14, right: LIST_INSET + 14, top: 8, bottom: 12 })
      }
    } else {
      ForEach(this.teammateRenderKeys(), (key: string) => {
        ListItem() {
          if (this.visibleTeammateByKey.has(key)) this.teammateRow(this.visibleTeammateByKey.get(key) as TeammateRosterEntry)
        }.transition(uiRevealTransition())
      }, (key: string): string => key)
    }
  }

  @Builder
  teammateAddMenu() {
    CompanionCreateMenu({
      companionHosts: this.companionGroupHosts(),
      groupHosts: this.companionGroupHosts(),
      onCreateCompanion: (deviceId: string, botId: string): void => this.companionCreated(deviceId, botId),
      onCreateGroup: (deviceId: string): void => this.openGroupCreate(deviceId),
      onJoinGroup: (link: string): void => this.openGroupInvitation(link),
    })
  }

  @Builder
  teammateSectionHeader() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.person_2')).fontSize(20).fontColor([$r('app.color.text_secondary')]).width(24)
      Text(this.v12String('v138_teammates'))
        .fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      if (!this.teammateCompact) {
        this.teammateAddMenu()
      }
      Text(`${this.scopedTeammates().length}`)
        .fontSize(12).fontColor($r('app.color.text_tertiary'))
      Button({ type: ButtonType.Normal }) {
        Row() {
          this.collapseChevron(this.teammateCompact)
        }.width('100%').justifyContent(FlexAlign.End)
      }.width(44).height(44).padding(0).backgroundColor(Color.Transparent)
        .clickEffect(UI_ICON_CLICK_EFFECT)
        .accessibilityText(this.v12String(this.teammateCompact ? 'home_companion_expand' : 'home_companion_compact'))
        .onClick((): void => this.toggleTeammateView())
    }
    .width('100%')
    .height(52)
    .padding({ left: LIST_INSET, right: LIST_INSET })
  }

  @Builder
  teammateRow(row: TeammateRosterEntry) {
    Row({ space: 10 }) {
      TeammateAvatar({ teammate: row, online: this.teammateAvatarOnline(row), diameter: 44 })
        .opacity(this.teammateAvatarOnline(row) ? 1 : 0.55)
      Column({ space: 4 }) {
        Text(row.name)
          .fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.teammateDeviceLabel(row))
          .fontSize(12).fontColor($r('app.color.text_secondary'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.teammateRunning(row)) {
          Text($r('app.string.teammate_activity_running')).fontSize(12).fontColor($r('app.color.text_secondary'))
        } else if (row.preview.length > 0) {
          Text(row.preview).fontSize(12).fontColor($r('app.color.text_secondary'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.teammateDot(row) !== null) {
        Circle().width(8).height(8).fill(this.teammateDot(row) ?? $r('app.color.text_tertiary'))
          .accessibilityText(this.teammateStatusLabel(row))
      }
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(12)
        .fontColor([$r('app.color.text_tertiary')])
    }
    .constraintSize({ minHeight: 56 })
    .padding({ left: 14, right: 14, top: 9, bottom: 9 })
    .margin({ left: LIST_INSET, right: LIST_INSET, bottom: 2 })
    .backgroundColor(this.selectedSessionDeviceId === row.deviceId && this.selectedSessionId === row.session.id
      && this.splitLayoutEnabled() ? $r('app.color.bg_chip') : Color.Transparent)
    .borderRadius(UI_RADIUS_CONTAINER)
    .clickEffect(UI_LIST_CLICK_EFFECT)
    .onClick(() => this.openTeammate(row))
  }

  @Builder
  buildTaskListEntries(category: TaskListCategory, scrollCategory: TaskListCategory = category) {
    // 滑动只负责露出操作按钮；不要配置 actionAreaDistance / onAction，
    // 避免长距离滑动松手时直接置顶或归档，所有操作都必须由按钮点击触发。
    List({ scroller: this.scrollerForCategory(scrollCategory) }) {
      if (category === 'projects' || category === 'dialogues') {
        this.teammateSection()
      }
      if (category === 'dialogues') {
        ListItem() { this.communicationSectionTitle(this.v12String('v138_chats')) }
      }
      if (this.pinnedEntries(category).length > 0) {
        ListItem() {
          this.sectionHeader(
            this.pinnedCollapsed,
            '置顶',
            `${this.pinnedEntries(category).length}`,
            $r('sys.symbol.pin'),
            () => {
              uiAnimateState(this.getUIContext(), () => {
                this.pinnedCollapsed = !this.pinnedCollapsed;
              });
              this.persistPreferences();
            })
        }
        if (!this.pinnedCollapsed) {
          ForEach(this.pinnedEntries(category), (entry: TaskListEntry) => {
            ListItem() {
              this.sessionEntry(entry, false)
            }
            .swipeAction({
              start: {
                builder: () => {
                  this.swipePinAction(entry)
                },
              },
              end: {
                builder: () => {
                  this.swipeArchiveAction(entry)
                },
              },
              edgeEffect: SwipeEdgeEffect.Spring,
            })
          }, (entry: TaskListEntry) => this.sessionEntryRenderKey('pinned', entry))
        }
      }

      if (category === 'projects') {
        if (this.projectGroups().length > 0) {
          ForEach(this.projectGroups(), (group: TaskProjectGroup) => {
            ListItemGroup() {
              ListItem() {
                this.projectGroupHeader(group)
              }
              if (!this.projectCollapsed(group.key)) {
                ForEach(this.visibleProjectEntries(group), (entry: TaskListEntry) => {
                  ListItem() {
                    this.sessionEntry(entry, true)
                  }
                  .swipeAction({
                    start: {
                      builder: () => {
                        this.swipePinAction(entry)
                      },
                    },
                    end: {
                      builder: () => {
                        this.swipeArchiveAction(entry)
                      },
                    },
                    edgeEffect: SwipeEdgeEffect.Spring,
                  })
                }, (entry: TaskListEntry) => this.sessionEntryRenderKey('project', entry))
                if (group.entries.length > PROJECT_INLINE_LIMIT) {
                  ListItem() {
                    this.projectViewAllRow(group)
                  }
                }
              }
              ListItem() {
                this.projectGroupDivider()
              }
            }
          }, (group: TaskProjectGroup) => this.projectGroupRenderKey(group))
        } else {
          ListItem() {
            this.activeTabEmptyState(category)
          }
        }
      } else {
        if (this.flatCategoryEntries(category).length > 0) {
          ForEach(this.flatCategoryEntries(category), (entry: TaskListEntry) => {
            ListItem() {
              this.sessionEntry(entry, false)
            }
            .swipeAction({
              start: {
                builder: () => {
                  this.swipePinAction(entry)
                },
              },
              end: {
                builder: () => {
                  this.swipeArchiveAction(entry)
                },
              },
              edgeEffect: SwipeEdgeEffect.Spring,
            })
          }, (entry: TaskListEntry) => this.sessionEntryRenderKey(category, entry))
        } else {
          ListItem() {
            this.activeTabEmptyState(category)
          }
        }
      }

    }
    .width('100%')
    .layoutWeight(1)
    .contentEndOffset(this.floatingBarContentInset())
    .padding({ top: 8 })
    .clip(false)
    .cachedCount(3, true)
    .scrollBar(BarState.Off)
    // Spring 无强度参数；Fade 保留触底反馈，但不会把整列内容明显拉离边界。
    .edgeEffect(EdgeEffect.Fade, { alwaysEnabled: false, effectEdge: EffectEdge.END })
    .onScrollStart(() => this.handleTaskListScrollStart(scrollCategory))
    .onDidScroll((scrollOffset: number, scrollState: ScrollState) => {
      this.handleTaskListScroll(scrollCategory, scrollOffset, scrollState);
    })
    .onWillStopDragging((velocity: number) => this.handleTaskListDragRelease(scrollCategory, velocity))
    .onScrollStop(() => this.handleTaskListScrollStop(scrollCategory))
    // 初次布局和短列表仍可恢复底栏，滚动途中则等待停稳。
    .onReachStart(() => this.restoreFloatingBarAtBoundary(scrollCategory))
    .onReachEnd(() => this.restoreFloatingBarAtBoundary(scrollCategory))
  }

  @Builder
  buildTaskSearchLoading() {
    Column({ space: 10 }) {
      LoadingProgress()
        .width(24)
        .height(24)
        .color($r('app.color.text_secondary'))
      Text($r('app.string.v12_searching_tasks'))
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ bottom: 72 })
  }

  @Builder
  buildTaskSearchEntries(category: TaskListCategory, scrollCategory: TaskListCategory = category) {
    List({ scroller: this.scrollerForCategory(scrollCategory) }) {
      if (this.taskSearchCoverageLabel().length > 0) {
        ListItem() {
          this.taskSearchCoverageNotice()
        }
      }
      ForEach(this.taskSearchResultsForCategory(category), (result: TaskSearchResult) => {
        ListItem() {
          this.taskSearchResultRow(result)
        }
      }, (result: TaskSearchResult) => this.taskSearchResultRenderKey(result))
    }
    .width('100%')
    .layoutWeight(1)
    .contentEndOffset(this.floatingBarContentInset())
    .padding({ top: 8 })
    .clip(false)
    .cachedCount(3, true)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Fade, { alwaysEnabled: false, effectEdge: EffectEdge.END })
    .onScrollStart(() => this.handleTaskListScrollStart(scrollCategory))
    .onDidScroll((scrollOffset: number, scrollState: ScrollState) => {
      this.handleTaskListScroll(scrollCategory, scrollOffset, scrollState);
    })
    .onWillStopDragging((velocity: number) => this.handleTaskListDragRelease(scrollCategory, velocity))
    .onScrollStop(() => this.handleTaskListScrollStop(scrollCategory))
    // 初次布局和短列表仍可恢复底栏，滚动途中则等待停稳。
    .onReachStart(() => this.restoreFloatingBarAtBoundary(scrollCategory))
    .onReachEnd(() => this.restoreFloatingBarAtBoundary(scrollCategory))
  }

  @Builder
  taskSearchCoverageNotice() {
    Row() {
      Text($r('app.string.v12_cached_search_only'))
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(30)
    .padding({ left: LIST_INSET, right: LIST_INSET })
  }

  @Builder
  taskSearchResultRow(result: TaskSearchResult) {
    Row({ space: 10 }) {
      this.agentMark(result.session, result.deviceId,
        AppServices.instance.messages.isSessionRunning(result.session.id, result.deviceId))
      Column({ space: 4 }) {
        Row({ space: 10 }) {
          Text(taskDisplayTitle(result.session))
            .fontSize(15)
            .lineHeight(20)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (taskRelativeTime(taskActivityAt(result.session), this.now).length > 0) {
            Text(taskRelativeTime(taskActivityAt(result.session), this.now))
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
          }
        }
        .width('100%')
        if (taskPreviewText(result.contentPreview).length > 0) {
          Text(taskPreviewText(result.contentPreview))
            .fontSize(12)
            .lineHeight(16)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        Text(this.taskSearchResultSubtitle(result))
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('auto')
    .constraintSize({ minHeight: result.contentPreview.length > 0 ? 78 : 62 })
    .padding({ left: 14, right: 14, top: 9, bottom: 9 })
    .margin({ left: LIST_INSET, right: LIST_INSET, bottom: 8 })
    .backgroundColor(this.selectedSessionDeviceId === result.deviceId
      && this.selectedSessionId === result.session.id
      ? $r('app.color.bg_chip') : Color.Transparent)
    .borderRadius(UI_RADIUS_CONTAINER)
    .clickEffect(UI_LIST_CLICK_EFFECT)
    .onClick(() => this.openTaskSearchResult(result))
  }

  private taskSearchResultSubtitle(result: TaskSearchResult): string {
    const current = this.devices.find((item: PresenceSnapshot): boolean => item.deviceId === result.deviceId);
    const device = this.displayDeviceName(result.deviceId, current?.deviceName ?? result.deviceName);
    const projectDir = sessionProjectDirectory(result.session);
    const project = result.session.workingDir.length > 0
      ? (this.projectAlias(result.deviceId, projectDir) || taskProjectName(projectDir))
      : taskIsAutomation(result.session)
        ? this.v12String('v12_automation') : this.v12String('v12_dialogue');
    return `${device} · ${project}`;
  }

  private taskSearchResultRenderKey(result: TaskSearchResult): string {
    return JSON.stringify([result.deviceId, result.session.id, result.matchKind,
      result.contentMessageClientId, this.taskSearchResultSubtitle(result)]);
  }

  @Builder
  activeTabEmptyState(category: TaskListCategory) {
    Column({ space: 8 }) {
      Text(this.activeTabEmptyTitle(category))
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text(this.activeTabEmptyCopy(category))
        .fontSize(13)
        .lineHeight(19)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .constraintSize({ minHeight: 180 })
    .justifyContent(FlexAlign.Center)
    .padding({ left: 24, right: 24 })
  }

  /**
   * 分区头：折叠箭头统一为 chevron_right 旋转 90°，箭头方向变化有 150ms 过渡。
   */
  @Builder
  sectionHeader(collapsed: boolean, title: string, count: string, icon: Resource, action: () => void) {
    Row({ space: 8 }) {
      this.collapseChevron(collapsed)
      SymbolGlyph(icon)
        .fontSize(16)
        .fontColor([$r('app.color.text_secondary')])
      Text(title)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      Text(count)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .height(44)
    .padding({ left: LIST_INSET, right: LIST_INSET })
    .clickEffect(UI_LIST_CLICK_EFFECT)
    .onClick(action)
  }

  @Builder
  collapseChevron(collapsed: boolean) {
    SymbolGlyph($r('sys.symbol.chevron_right'))
      .fontSize(12)
      .fontColor([$r('app.color.text_tertiary')])
      .width(16)
      .rotate({ angle: collapsed ? 0 : 90 })
      .animation({ duration: UI_MOTION_FAST, curve: UI_CURVE_MOVE })
  }

  /**
   * 任务行：置顶/对话区的独立行与项目组内行共用同一份内容与选中态；
   * inGroup 行通过标题对齐和缩进表达项目层级。
   */
  @Builder
  sessionEntry(entry: TaskListEntry, inGroup: boolean) {
    this.sessionRow(entry, inGroup)
  }

  @Builder
  sessionRow(entry: TaskListEntry, inGroup: boolean) {
    Row({ space: 10 }) {
      if (this.bulkMode) {
        this.bulkSelectionMark(this.selectedEntryKeys.indexOf(entry.key) >= 0)
      } else {
        this.agentMark(entry.session, entry.deviceId, this.taskRightStatusKind(entry) === 'running')
      }
      Column({ space: 4 }) {
        Row({ space: 10 }) {
          Text(taskDisplayTitle(entry.session))
            .fontSize(15)
            .lineHeight(20)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          this.taskRightStatus(entry)
        }
        .width('100%')

        if (entry.session.agentDeviceId.length > 0) {
          Text(harmonyV12String(this.getUIContext().getHostContext(), 'v132_agent_location', this.agentDeviceLabel(entry)))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .lineHeight(16)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (taskPreviewText(entry.session.preview).length > 0) {
          Text(taskPreviewText(entry.session.preview))
            .fontSize(12)
            .lineHeight(16)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('auto')
    .constraintSize({
      minHeight: taskPreviewText(entry.session.preview).length > 0 ? 72 : 56,
    })
    .padding({ left: 14, right: 14, top: 9, bottom: 9 })
    .margin(inGroup
      ? { left: 6, right: 6, bottom: 2 }
      : { left: LIST_INSET, right: LIST_INSET, bottom: 8 })
    .backgroundColor(this.entrySelected(entry) || this.selectedEntryKeys.indexOf(entry.key) >= 0
      ? $r('app.color.bg_chip')
      : Color.Transparent)
    .borderRadius(UI_RADIUS_CONTAINER)
    .clickEffect(UI_LIST_CLICK_EFFECT)
    .gesture(
      LongPressGesture({ repeat: false })
        .onAction(() => this.beginBulkSelection(entry)),
    )
    .onClick(() => this.openSession(entry))
  }

  @Builder
  bulkSelectionMark(selected: boolean) {
    Stack({ alignContent: Alignment.Center }) {
      if (selected) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(13)
          .fontColor([$r('app.color.chat_cta_text')])
      }
    }
    .width(24)
    .height(24)
    .backgroundColor(selected ? $r('app.color.chat_cta') : Color.Transparent)
    .border({ width: 1, color: selected ? $r('app.color.chat_cta') : $r('app.color.border') })
    .borderRadius(UI_RADIUS_CONTROL)
  }

  @Builder
  swipePinAction(entry: TaskListEntry) {
    Column({ space: 4 }) {
      SymbolGlyph($r('sys.symbol.pin'))
        .fontSize(17)
        .fontColor([$r('app.color.chat_cta_text')])
      Text(entry.session.pinnedAt.length > 0 ? '取消置顶' : '置顶')
        .fontSize(11)
        .fontColor($r('app.color.chat_cta_text'))
    }
    .width(76)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.chat_cta'))
    .onClick(() => {
      void this.togglePinned(entry);
    })
  }

  @Builder
  swipeArchiveAction(entry: TaskListEntry) {
    Column({ space: 4 }) {
      SymbolGlyph($r('sys.symbol.archivebox'))
        .fontSize(17)
        .fontColor([$r('app.color.chat_cta_text')])
      Text(entry.session.status === 'archived' ? '取消归档' : '归档')
        .fontSize(11)
        .fontColor($r('app.color.chat_cta_text'))
    }
    .width(76)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.text_secondary'))
    .onClick(() => {
      void this.archiveOrRestore(entry);
    })
  }

  private taskRightStatusKind(entry: TaskListEntry): TaskRightStatusKind {
    const activity = AppServices.instance.tasks.getLiveActivity(entry.session.id, entry.deviceId);
    return resolveTaskRightStatus(
      activity?.phase ?? '',
      activity?.attention === true,
      AppServices.instance.interactions.getPending(entry.session.id, entry.deviceId).length,
      AppServices.instance.messages.isSessionRunning(entry.session.id, entry.deviceId),
    );
  }

  @Builder
  taskRightStatus(entry: TaskListEntry) {
    if (this.taskRightStatusKind(entry) === 'running') {
      Row({ space: 4 }) {
        LoadingProgress()
          .width(13)
          .height(13)
          .color($r('app.color.text_secondary'))
        Text('运行中')
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
      }
    } else if (this.taskRightStatusKind(entry) === 'waiting') {
      Row({ space: 5 }) {
        Circle().width(7).height(7).fill($r('app.color.accent'))
        Text('待处理')
          .fontSize(11)
          .fontColor($r('app.color.accent'))
      }
    } else if (this.taskRightStatusKind(entry) === 'error') {
      Row({ space: 5 }) {
        Circle().width(7).height(7).fill($r('app.color.danger'))
        Text('失败')
          .fontSize(11)
          .fontColor($r('app.color.danger'))
      }
    } else if (this.taskRightStatusKind(entry) === 'done') {
      Row({ space: 5 }) {
        Circle().width(7).height(7).fill($r('app.color.success'))
        Text('已完成')
          .fontSize(11)
          .fontColor($r('app.color.success'))
      }
    } else {
      Text(taskRelativeTime(taskActivityAt(entry.session), this.now))
        .fontSize(11)
        .lineHeight(16)
        .fontColor($r('app.color.text_tertiary'))
    }
  }

  private projectMachineLabel(group: TaskProjectGroup): string {
    const visible: ProjectMachine[] = [];
    for (const device of this.devices) {
      const machine = new ProjectMachine();
      machine.deviceId = device.deviceId;
      machine.name = device.deviceName;
      machine.online = device.online;
      visible.push(machine);
    }
    return projectMachineLabel(group.deviceId, this.selectedDeviceId, visible,
      harmonyV12String(this.getUIContext().getHostContext(), 'v131_offline'), this.v12String('v134_unnamed_computer'));
  }

  private projectNativeKey(group: TaskProjectGroup): string {
    const remote = group.entries[0]?.session.remoteHostId ?? '';
    return remote ? 'remote:' + encodeURIComponent(remote) + ':' + group.workingDir : 'local:' + group.workingDir;
  }
  private projectIcon(group: TaskProjectGroup): string {
    return AppServices.instance.taskProjectAliases.icon(group.deviceId, this.projectNativeKey(group));
  }
  private projectIconImage(group: TaskProjectGroup): string {
    return AppServices.instance.taskProjectAliases.image(group.deviceId, this.projectNativeKey(group));
  }

  @Builder
  projectGroupHeader(group: TaskProjectGroup) {
    Row({ space: 8 }) {
      if (this.projectIconImage(group)) {
        Image(this.projectIconImage(group)).width(24).height(24).objectFit(ImageFit.Contain).borderRadius(6)
      } else if (this.projectIcon(group).startsWith('symbol:')) {
        ProjectSymbol({ name: this.projectIcon(group).split(':')[1] }).width(24).height(24)
      } else if (this.projectIcon(group).startsWith('text:')) {
        Text(this.projectIcon(group).split(':')[1]).width(24).fontSize(19).textAlign(TextAlign.Center)
      } else {
        SymbolGlyph($r('sys.symbol.folder')).fontSize(20).fontColor([$r('app.color.text_secondary')]).width(24)
      }
      Text(AppServices.instance.taskProjectAliases.alias(group.deviceId, this.projectNativeKey(group)) || group.title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.projectMachineLabel(group).length > 0) {
        Text(this.projectMachineLabel(group))
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .constraintSize({ maxWidth: '38%' })
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      Text(`${group.entries.length}`)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.gearshape')).fontSize(16).fontColor([$r('app.color.text_secondary')])
      }.width(44).height(44).backgroundColor(Color.Transparent)
        .accessibilityText(this.v12String('v139_home_project'))
        .onClick((): void => { this.projectFolderMenuKey = group.key; })
        .bindMenu(this.projectFolderMenuKey === group.key, this.projectFolderMenu(group),
          uiMenuOptions((): void => {
            if (this.projectFolderMenuKey === group.key) this.projectFolderMenuKey = '';
          }))
      if (this.displayedProjectOrderMode() === 'custom') {
        SymbolGlyph($r('sys.symbol.slider_horizontal_2'))
          .fontSize(16)
          .fontColor([$r('app.color.text_tertiary')])
          .opacity(this.projectOrderDraggingKey === group.key ? 0.55 : 1)
      }
      this.collapseChevron(this.projectCollapsed(group.key))
    }
    .width('100%')
    .height(52)
    .padding({ left: LIST_INSET, right: LIST_INSET })
    .backgroundColor(this.projectOrderDraggingKey === group.key
      ? $r('app.color.bg_chip') : Color.Transparent)
    .clickEffect(UI_LIST_CLICK_EFFECT)
    .onClick(() => {
      if (this.projectOrderSuppressClick) {
        this.projectOrderSuppressClick = false;
        return;
      }
      this.toggleProject(group.key);
    })
    .onTouch((event: TouchEvent) => {
      this.handleProjectOrderTouch(group, event);
    })
  }

  @Builder
  projectGroupDivider() {
    Divider()
      .strokeWidth(0.5)
      .color($r('app.color.border'))
      .margin({ left: LIST_INSET, right: LIST_INSET })
  }

  @Builder
  projectViewAllRow(group: TaskProjectGroup) {
    Row({ space: 8 }) {
      Text(this.projectFullyExpanded(group.key) ? '收起' : `查看全部 ${group.entries.length} 个任务`)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
        .layoutWeight(1)
      SymbolGlyph(this.projectFullyExpanded(group.key)
        ? $r('sys.symbol.chevron_up')
        : $r('sys.symbol.chevron_right'))
        .fontSize(13)
        .fontColor([$r('app.color.text_tertiary')])
    }
    .width('100%')
    .height(44)
    .padding({ left: 54, right: LIST_INSET })
    .border({ width: { top: 1 }, color: { top: $r('app.color.border') } })
    .clickEffect(UI_LIST_CLICK_EFFECT)
    .onClick(() => this.toggleProjectExpanded(group.key))
  }

  private resetPluginIconOwner(): void {
    const app = AppServices.instance;
    const owner = JSON.stringify([app.auth.sessionEpoch, RelayRoute.instance.generation]);
    if (owner === this.pluginIconOwner) return;
    this.pluginIconOwner = owner;
    this.pluginIconTargets = '';
    this.pluginIconGeneration++;
    this.pluginIconEngines = new Map<string, PluginEngine[]>();
  }

  private prefetchPluginIcons(entries: TaskListEntry[], devices: PresenceSnapshot[]): void {
    const app = AppServices.instance;
    this.resetPluginIconOwner();
    if (!this.pageActive || !app.appInForeground || !app.auth.isLoggedIn || app.taskAccountTransition.active
      || app.client.getStatus() !== 'online') return;
    const online = new Set<string>();
    devices.forEach((device: PresenceSnapshot): void => {
      if (device.online && device.remoteControlEnabled) online.add(device.deviceId);
    });
    const targets = new Set<string>();
    entries.forEach((entry: TaskListEntry): void => {
      if (entry.session.status !== 'active' || !isPluginEngineSession(entry.session.agentKind, entry.session.providerId)) return;
      if (online.has(entry.deviceId)) targets.add(entry.deviceId);
      // Mobile looks up the task host first. A remotely installed engine may exist
      // only on the execution device, so also hydrate that peer's catalogue.
      const executionDevice = entry.session.agentDeviceId;
      if (executionDevice && executionDevice !== entry.deviceId && online.has(executionDevice)) targets.add(executionDevice);
    });
    const ids = Array.from(targets).sort();
    const signature = JSON.stringify(ids);
    if (signature === this.pluginIconTargets) return;
    this.pluginIconTargets = signature;
    const generation = ++this.pluginIconGeneration;
    void this.loadPluginIcons(ids, generation, entries);
  }

  private async loadPluginIcons(ids: string[], generation: number, entries: TaskListEntry[]): Promise<void> {
    for (const id of ids) {
      if (generation !== this.pluginIconGeneration) return;
      const engines = await AppServices.instance.pluginEngines.load(id);
      if (generation !== this.pluginIconGeneration) return;
      if (engines.length > 0) {
        const next = new Map<string, PluginEngine[]>(this.pluginIconEngines);
        next.set(id, engines);
        this.pluginIconEngines = next;
      }
    }
    if (generation !== this.pluginIconGeneration || ids.length === 0) return;
    let hostIcons = 0;
    let executionIcons = 0;
    let missingIcon = 0;
    for (const entry of entries) {
      if (entry.session.status !== 'active' || !isPluginEngineSession(entry.session.agentKind, entry.session.providerId)) continue;
      const host = this.pluginIconOnDevice(entry.deviceId, entry.session.providerId);
      if (host) hostIcons++;
      else if (this.pluginIconOnDevice(entry.session.agentDeviceId, entry.session.providerId)) executionIcons++;
      else missingIcon++;
    }
    hilog.debug(0, 'CindyPluginMark', 'catalog_match host=%{public}d execution=%{public}d missing=%{public}d',
      hostIcons, executionIcons, missingIcon);
  }

  private pluginIconOnDevice(deviceId: string, providerId: string): string {
    return findPluginEngine(this.pluginIconEngines.get(deviceId) ?? [], providerId)?.iconDataUrl ?? '';
  }

  private pluginIconUrl(session: RemoteSession, deviceId: string): string {
    return this.pluginIconOnDevice(deviceId, session.providerId)
      || this.pluginIconOnDevice(session.agentDeviceId, session.providerId);
  }

  @Builder
  agentMark(session: RemoteSession, deviceId: string, running: boolean) {
    Stack({ alignContent: Alignment.Center }) {
      if (session.agentKind === 'codex' || session.agentKind === 'cc' || session.agentKind === 'claude-code') {
        Image(session.agentKind === 'codex' ? $r('app.media.usage_provider_openai')
          : $r('app.media.usage_provider_anthropic'))
          .width(24).height(24).objectFit(ImageFit.Contain)
      } else if (isPluginEngineSession(session.agentKind, session.providerId)) {
        PluginEngineMark({ iconDataUrl: this.pluginIconUrl(session, deviceId),
          markSize: 24, monochrome: true, running: running,
          remoteExecution: !!session.agentDeviceId && session.agentDeviceId !== deviceId })
      } else {
        Text(session.agentKind === 'pi' ? 'Pi' : 'AI')
          .fontSize(session.agentKind === 'pi' ? 12 : 9)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary'))
      }
    }
    .width(28)
    .height(28)
    .backgroundColor(session.agentKind === 'cc' || session.agentKind === 'claude-code' || session.agentKind === 'codex'
      || isPluginEngineSession(session.agentKind, session.providerId) ? Color.Transparent : $r('app.color.bg_chip'))
    .borderRadius(UI_RADIUS_CONTROL)
  }

  @Builder
  bulkActionBar() {
    Row({ space: 6 }) {
      Button('取消')
        .height(38)
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
        .backgroundColor($r('app.color.bg_chip'))
        .borderRadius(UI_RADIUS_PILL)
        .onClick(() => this.cancelBulkSelection())
      Text(`已选 ${this.selectedEntryKeys.length}`)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      this.bulkActionButton('置顶', () => this.bulkAction('pin'))
      this.bulkActionButton('归档', () => this.bulkAction('archive'))
      this.bulkActionButton('取消归档', () => this.bulkAction('restore'))
      this.bulkActionButton('删除', () => this.bulkAction('delete'), true)
    }
    .width('calc(100% - 24vp)')
    .height(58)
    .padding({ left: 10, right: 10 })
    .margin({ left: 12, right: 12, bottom: 12 })
    .backgroundColor($r('app.color.task_list_menu_surface'))
    .border({ width: 1, color: $r('app.color.border') })
    .borderRadius(UI_RADIUS_CONTAINER)
    .position({ x: 12, y: 'calc(100% - 70vp)' })
    .transition(uiOverlayTransition())
  }

  @Builder
  bulkActionButton(label: string, action: () => void, danger: boolean = false) {
    Button(label)
      .height(34)
      .padding({ left: 10, right: 10 })
      .fontSize(12)
      .fontColor(danger ? $r('app.color.danger') : $r('app.color.text_primary'))
      .backgroundColor($r('app.color.bg_chip'))
      .borderRadius(UI_RADIUS_PILL)
      .enabled(!this.sessionActionBusy)
      .onClick(action)
  }

  /** 排序菜单：任务排序一组；项目页再加项目排序（组脚说明同步状态）与展开 / 收起全部项目。 */
  @Builder
  sortMenuContent() {
    Menu() {
      MenuItemGroup() {
        this.sortMenuItem('最近优先', 'recency')
        this.sortMenuItem('字母排序', 'alphabetic')
        this.sortMenuItem('默认排序', 'default')
      }
      if (this.activeListTab === 'projects') {
        if (this.projectOrderMenuHasFooter()) {
          MenuItemGroup({ header: $r('app.string.v12_project_order'), footer: this.projectOrderMenuFooter() }) {
            this.projectOrderMenuItem(this.v12String('v12_recent_project_order'), 'activity')
            this.projectOrderMenuItem(this.v12String('v12_custom_project_order'), 'custom')
          }
        } else {
          MenuItemGroup({ header: $r('app.string.v12_project_order') }) {
            this.projectOrderMenuItem(this.v12String('v12_recent_project_order'), 'activity')
            this.projectOrderMenuItem(this.v12String('v12_custom_project_order'), 'custom')
          }
        }
        MenuItemGroup() {
          MenuItem({
            symbolStartIcon: new SymbolGlyphModifier(this.allProjectsCollapsed()
              ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_up')),
            content: this.allProjectsCollapsed()
              ? $r('app.string.v12_expand_project') : $r('app.string.v12_collapse_project'),
          })
            .enabled(this.projectGroups().length > 0)
            .onClick(() => this.toggleAllProjectsFromMenu())
        }
      }
    }
    .id(uiOverlayBuildId('sort-menu'))
  }

  @Builder
  sortMenuItem(label: string, mode: TaskListSortMode) {
    MenuItem({ content: label })
      .selected(this.sortMode === mode)
      .selectIcon(true)
      .onClick(() => this.selectSortMode(mode))
  }

  @Builder
  projectOrderMenuItem(label: string, mode: TaskProjectOrderMode) {
    MenuItem({ content: label })
      .selected(this.displayedProjectOrderMode() === mode)
      .selectIcon(true)
      .enabled(!this.projectOrderSyncing)
      .onClick(() => this.selectProjectOrderMode(mode))
  }

  private projectOrderMenuHasFooter(): boolean {
    return this.projectOrderSyncing || (this.selectedDeviceId.length > 0 && !this.projectOrderHostAvailable)
      || this.displayedProjectOrderMode() === 'custom';
  }

  /** 原面板里的项目排序说明行改为组脚：同步中 / 仅本机生效 / 拖动排序提示，三者互斥。 */
  private projectOrderMenuFooter(): ResourceStr {
    if (this.projectOrderSyncing) return $r('app.string.v12_syncing_project_order');
    if (this.selectedDeviceId.length > 0 && !this.projectOrderHostAvailable) return $r('app.string.v12_local_project_order');
    if (this.displayedProjectOrderMode() === 'custom') return $r('app.string.v12_drag_project_order');
    return '';
  }

  /** 搜索筛选是多选、可重置的长列表：用底部表单（docs/overlay-standard.md §3.2），选择后不关闭。 */
  private taskSearchFilterSheetOptions(): SheetOptions {
    const extras = new UiSheetExtras();
    extras.detents = [SheetSize.MEDIUM, SheetSize.LARGE];
    extras.traceTag = 'search-filter';
    return uiSheetOptions($r('app.string.v12_search_filter'), (): void => { this.taskSearchFilterOpen = false; },
      SheetSize.FIT_CONTENT, extras);
  }

  @Builder
  taskSearchFilterSheet() {
    Column() {
      if (this.taskSearchFilterCount() > 0) {
        Row() {
          Blank()
          Button($r('app.string.v12_reset'), { type: ButtonType.Capsule })
            .height(36)
            .padding({ left: 12, right: 12 })
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .backgroundColor($r('app.color.bg_chip'))
            .onClick(() => this.resetTaskSearchFilters())
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 4 })
      }
      Scroll() {
        Column() {
          this.taskSearchFilterSectionTitle(this.v12String('v12_search_sort'))
          this.taskSearchFilterOption(this.v12String('v12_search_relevance'), this.taskSearchSortBy === 'relevance',
            () => this.selectTaskSearchSort('relevance'))
          this.taskSearchFilterOption(this.v12String('v12_search_recent_activity'), this.taskSearchSortBy === 'activityDesc',
            () => this.selectTaskSearchSort('activityDesc'))
          this.taskSearchFilterOption(this.v12String('v12_search_earliest_activity'), this.taskSearchSortBy === 'activityAsc',
            () => this.selectTaskSearchSort('activityAsc'))

          this.taskSearchFilterSectionTitle(this.v12String('v12_search_status'))
          this.taskSearchFilterOption(this.v12String('v12_search_all_status'), this.taskSearchStatusFilter === 'all',
            () => this.selectTaskSearchStatus('all'))
          this.taskSearchFilterOption(this.v12String('v12_search_active'), this.taskSearchStatusFilter === 'active',
            () => this.selectTaskSearchStatus('active'))
          this.taskSearchFilterOption(this.v12String('v12_search_archived'), this.taskSearchStatusFilter === 'archived',
            () => this.selectTaskSearchStatus('archived'))

          this.taskSearchFilterSectionTitle(this.v12String('v12_search_agent'))
          this.taskSearchFilterOption(this.v12String('v12_search_all_agents'), this.taskSearchAgentFilter === 'all',
            () => this.selectTaskSearchAgent('all'))
          this.taskSearchFilterOption(this.v12String('v12_search_agent_claude_code'),
            this.taskSearchAgentFilter === 'cc',
            () => this.selectTaskSearchAgent('cc'))
          this.taskSearchFilterOption(this.v12String('v12_search_agent_codex'),
            this.taskSearchAgentFilter === 'codex',
            () => this.selectTaskSearchAgent('codex'))
          this.taskSearchFilterOption(this.v12String('v12_search_agent_pi'),
            this.taskSearchAgentFilter === 'pi',
            () => this.selectTaskSearchAgent('pi'))

          this.taskSearchFilterSectionTitle(this.v12String('v12_search_time'))
          this.taskSearchFilterOption(this.v12String('v12_search_any_time'), this.taskSearchLastActivityFilter === 'all',
            () => this.selectTaskSearchLastActivity('all'))
          this.taskSearchFilterOption(this.v12String('v12_search_past_one_day'), this.taskSearchLastActivityFilter === '1d',
            () => this.selectTaskSearchLastActivity('1d'))
          this.taskSearchFilterOption(this.v12String('v12_search_past_three_days'), this.taskSearchLastActivityFilter === '3d',
            () => this.selectTaskSearchLastActivity('3d'))
          this.taskSearchFilterOption(this.v12String('v12_search_past_seven_days'), this.taskSearchLastActivityFilter === '7d',
            () => this.selectTaskSearchLastActivity('7d'))
          this.taskSearchFilterOption(this.v12String('v12_search_past_thirty_days'), this.taskSearchLastActivityFilter === '30d',
            () => this.selectTaskSearchLastActivity('30d'))

          this.taskSearchFilterSectionTitle(this.v12String('v12_search_project'))
          ForEach(this.taskSearchProjects(), (project: TaskSearchProjectOption) => {
            this.taskSearchFilterOption(
              `${project.title} · ${project.deviceName}`,
              this.taskSearchProjectKeys.indexOf(project.key) >= 0,
              () => this.toggleTaskSearchProject(project.key),
              `${project.count}`,
            )
          }, (project: TaskSearchProjectOption) => JSON.stringify(['search-project', project.key,
            project.title, project.deviceName, project.count]))
          if (this.taskSearchProjects().length === 0) {
            Text($r('app.string.v12_no_synced_projects'))
              .fontSize(13)
              .fontColor($r('app.color.text_tertiary'))
              .padding({ left: 10, top: 8, bottom: 8 })
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12, bottom: 24 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  taskSearchFilterSectionTitle(label: string) {
    Text(label)
      .fontSize(12)
      .fontColor($r('app.color.text_tertiary'))
      .height(32)
      .padding({ left: 10, top: 12 })
  }

  @Builder
  taskSearchFilterOption(
    label: string,
    selected: boolean,
    action: () => void,
    count: string = '',
  ) {
    Row({ space: 8 }) {
      this.menuCheck(selected)
      Text(label)
        .fontSize(14)
        .fontWeight(selected ? FontWeight.Medium : FontWeight.Regular)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (count.length > 0) {
        Text(count)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
      }
    }
    .width('100%')
    .height(42)
    .padding({ left: 10, right: 10 })
    .backgroundColor(selected ? $r('app.color.bg_chip') : Color.Transparent)
    .borderRadius(UI_RADIUS_CONTROL)
    .clickEffect(UI_LIST_CLICK_EFFECT)
    .onClick(action)
  }

  /**
   * 「所有任务 ⌄」电脑范围菜单：系统 Menu（bindMenu）承载，阴影、背景、点外部关闭由系统处理，
   * 不再自画只盖住应用窗口的遮罩。分组：范围（所有任务 / 资源）与电脑列表。
   */
  @Builder
  scopeMenuContent() {
    Menu() {
      MenuItemGroup() {
        MenuItem({
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.rectangle_stack')),
          content: '所有任务',
        })
          .selected(this.selectedDeviceId.length === 0)
          .selectIcon(true)
          .onClick(() => this.selectDevice(''))
        // 「资源」：Mobile 在同一下拉里按电脑声明的 home-scope 集合逐项列出；鸿蒙暂无首页集合发现，
        // 先做单一入口，打开当前选中电脑的现有资源面板（差异见 docs/decision-log.md）。
        MenuItem({
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.square_grid_2x2')),
          content: this.v12String('v139_home_resources'),
        })
          .selectIcon(true)
          .onClick(() => {
            this.scopeMenuOpen = false;
            this.openModule('resources');
          })
      }
      if (this.devices.length > 0) {
        MenuItemGroup() {
          ForEach(this.devices, (device: PresenceSnapshot) => {
            MenuItem({
              symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.display')),
              content: this.displayDeviceName(device.deviceId, device.deviceName),
              labelInfo: this.deviceCanOpen(device) ? undefined : this.v12String('v131_offline'),
            })
              .selected(this.selectedDeviceId === device.deviceId)
              .selectIcon(true)
              .onClick(() => this.selectDevice(device.deviceId))
          }, (device: PresenceSnapshot) => JSON.stringify(['scope', device.deviceId,
            this.displayDeviceName(device.deviceId, device.deviceName), device.online, device.remoteControlEnabled,
            this.selectedDeviceId === device.deviceId]))
        }
      }
    }
    .id(uiOverlayBuildId('scope-menu'))
  }

  @Builder
  menuCheck(selected: boolean) {
    Stack({ alignContent: Alignment.Center }) {
      if (selected) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(14)
          .fontColor([$r('app.color.text_primary')])
      }
    }
    .width(18)
    .height(18)
  }
}
